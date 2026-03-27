import XCTest
import XCTVapor
import STJSON
@testable import NeptuneGatewaySwift

final class GatewayRoutesTests: XCTestCase {
    private let sampleRecord = """
    {"timestamp":"2026-03-23T12:00:00Z","level":"info","message":"boot ok","platform":"ios","appId":"demo.app","sessionId":"s-1","deviceId":"d-1","category":"lifecycle","attributes":{"screen":"home"},"source":{"sdkName":"sdk","sdkVersion":"0.1.0","file":"App.swift","function":"boot()","line":12}}
    """
    private let newerRecord = """
    {"timestamp":"2026-03-23T12:01:00Z","level":"info","message":"boot later","platform":"ios","appId":"demo.app","sessionId":"s-1","deviceId":"d-1","category":"lifecycle","attributes":{"screen":"home"},"source":{"sdkName":"sdk","sdkVersion":"0.1.0","file":"App.swift","function":"bootLater()","line":13}}
    """

    private func makeApplication(
        file: StaticString = #filePath,
        line: UInt = #line,
        retention: GatewayStoreConfiguration = .default,
        hostname: String = "127.0.0.1",
        advertiseHost: String? = nil
    ) throws -> Application {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        return try NeptuneGatewaySwift.makeApplication(
            environment: .testing,
            hostname: hostname,
            advertiseHost: advertiseHost,
            storageURL: databaseURL,
            storeConfiguration: retention
        )
    }

    func testHealthEndpointReturns200() throws {
        let app = try NeptuneGatewaySwift.makeApplication(environment: .testing)
        defer { app.shutdown() }

        try app.test(.GET, "v2/health") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(try response.content.decode(HealthResponse.self).status, "ok")
        }
    }

    func testDiscoveryEndpointUsesAdvertiseHostOverride() throws {
        let app = try makeApplication(hostname: "0.0.0.0", advertiseHost: "linhey.local")
        defer { app.shutdown() }

        try app.test(.GET, "v2/gateway/discovery", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .host, value: "10.0.2.2:18765")
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(DiscoveryResponse.self)
            XCTAssertEqual(payload.host, "linhey.local")
            XCTAssertEqual(payload.port, 18765)
        })
    }

    func testDiscoveryEndpointUsesRequestHostHeaderWhenListeningOnAllInterfaces() throws {
        let app = try makeApplication(hostname: "0.0.0.0")
        defer { app.shutdown() }

        try app.test(.GET, "v2/gateway/discovery", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .host, value: "10.0.2.2:18765")
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(DiscoveryResponse.self)
            XCTAssertEqual(payload.host, "10.0.2.2")
            XCTAssertEqual(payload.port, 18765)
        })
    }

    func testWebSocketEndpointIsRegistered() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try app.test(.GET, "v2/ws") { response in
            XCTAssertNotEqual(response.status, .notFound)
        }
    }

    func testWebSocketHelloAndIngestPublishesLogsUpdatedSignalToInspector() async throws {
        let app = try makeRunningApplication()

        let inspectorCapture = WebSocketCapture()
        let inspectorSocket = try await connectWebSocket(
            app: app,
            capture: inspectorCapture
        )

        try await inspectorSocket.send(#"{"type":"hello","role":"inspector"}"#)

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)

        try await Task.sleep(for: .milliseconds(150))

        let frames = try Self.decodeFrames(from: inspectorCapture.snapshot())
        let signal = try XCTUnwrap(frames.first(where: { $0.type == "logs.updated" }))
        XCTAssertEqual(signal.deviceId, "d-1")
    }

    func testWebSocketRejectsUnsupportedLogRelayEvents() async throws {
        let app = try makeRunningApplication()

        let inspectorCapture = WebSocketCapture()
        let inspectorSocket = try await connectWebSocket(app: app, capture: inspectorCapture)
        try await inspectorSocket.send(#"{"type":"hello","role":"inspector"}"#)

        let sdkCapture = WebSocketCapture()
        let sdkSocket = try await connectWebSocket(app: app, capture: sdkCapture)
        try await sdkSocket.send(#"{"type":"hello","role":"sdk","platform":"ios","appId":"demo.app","sessionId":"s-1","deviceId":"d-1"}"#)
        try await sdkSocket.send(
            #"""
            {"type":"event.log_record","record":{"id":99,"timestamp":"2026-03-25T11:47:30Z","level":"info","message":"relay-from-sdk","platform":"ios","appId":"demo.app","sessionId":"s-1","deviceId":"d-1","category":"test"}}
            """#
        )

        try await Task.sleep(for: .milliseconds(120))

        let frames = try Self.decodeFrames(from: inspectorCapture.snapshot())
        XCTAssertNil(frames.first(where: { $0.type == "event.log_record" }))
    }

    func testCommandSendDispatchesToSelectedOnlineClientAndSummarizesAckedCommand() async throws {
        let configuration = GatewayWebSocketConfiguration(
            heartbeatInterval: 0.05,
            heartbeatTimeout: 0.5,
            commandSummaryDelay: 0.12
        )
        let app = try makeRunningApplication(webSocketConfiguration: configuration)

        let callbackCapture = CallbackCapture()
        let callbackEndpoint = try makeCallbackServer(capture: callbackCapture)

        try registerClient(
            app: app,
            platform: "ios",
            appId: "demo.app",
            sessionId: "s-1",
            deviceId: "d-1",
            callbackEndpoint: callbackEndpoint
        )
        try registerClient(
            app: app,
            platform: "android",
            appId: "demo.app",
            sessionId: "s-2",
            deviceId: "d-2",
            callbackEndpoint: "http://127.0.0.1:1"
        )
        try selectClients(
            app: app,
            selectors: [ClientSelector(platform: "ios", appId: "demo.app", deviceId: "d-1")]
        )

        let inspectorCapture = WebSocketCapture()
        let inspectorSocket = try await connectWebSocket(app: app, capture: inspectorCapture)

        try await inspectorSocket.send(#"{"type":"hello","role":"inspector"}"#)
        try await inspectorSocket.send(#"{"type":"command.send","requestId":"request-1","command":"ping"}"#)

        try await Task.sleep(for: .milliseconds(300))

        let inspectorFrames = try Self.decodeFrames(from: inspectorCapture.snapshot())

        let acceptedAck = try XCTUnwrap(inspectorFrames.first(where: { $0.type == "ack" }))
        XCTAssertEqual(acceptedAck.accepted, true)
        XCTAssertEqual(acceptedAck.delivered, 1)
        XCTAssertEqual(acceptedAck.requestId, "request-1")
        XCTAssertEqual(acceptedAck.commandId, "request-1")

        let ackEvent = try XCTUnwrap(inspectorFrames.first(where: { $0.type == "event.command_ack" }))
        XCTAssertEqual(ackEvent.requestId, "request-1")
        XCTAssertEqual(ackEvent.commandId, "request-1")
        XCTAssertEqual(ackEvent.command, "ping")
        XCTAssertEqual(ackEvent.status, "ok")

        let summaryEvent = try XCTUnwrap(inspectorFrames.first(where: { $0.type == "event.command_summary" }))
        XCTAssertEqual(summaryEvent.delivered, 1)
        XCTAssertEqual(summaryEvent.acked, 1)
        XCTAssertEqual(summaryEvent.timeout, 0)
        XCTAssertEqual(summaryEvent.requestId, "request-1")
        XCTAssertEqual(summaryEvent.commandId, "request-1")
        XCTAssertEqual(summaryEvent.command, "ping")
        XCTAssertEqual(callbackCapture.snapshot().count, 1)
    }

    func testCommandSendSupportsCallbackEndpointWithEmbeddedCommandPath() async throws {
        let configuration = GatewayWebSocketConfiguration(
            heartbeatInterval: 0.05,
            heartbeatTimeout: 0.5,
            commandSummaryDelay: 0.12
        )
        let app = try makeRunningApplication(webSocketConfiguration: configuration)
        let callbackCapture = CallbackCapture()
        let callbackBase = try makeCallbackServer(capture: callbackCapture)

        try registerClient(
            app: app,
            platform: "ios",
            appId: "demo.app",
            sessionId: "s-embed-path",
            deviceId: "d-embed-path",
            callbackEndpoint: callbackBase + "/v2/client/command"
        )
        try selectClients(
            app: app,
            selectors: [ClientSelector(platform: "ios", appId: "demo.app", deviceId: "d-embed-path")]
        )

        let inspectorCapture = WebSocketCapture()
        let inspectorSocket = try await connectWebSocket(app: app, capture: inspectorCapture)

        try await inspectorSocket.send(#"{"type":"hello","role":"inspector"}"#)
        try await inspectorSocket.send(#"{"type":"command.send","requestId":"request-embed-path","command":"ping"}"#)

        try await Task.sleep(for: .milliseconds(300))

        let frames = try Self.decodeFrames(from: inspectorCapture.snapshot())
        let summary = try XCTUnwrap(frames.first(where: {
            $0.type == "event.command_summary" && $0.requestId == "request-embed-path"
        }))
        XCTAssertEqual(summary.delivered, 1)
        XCTAssertEqual(summary.acked, 1)
        XCTAssertEqual(summary.timeout, 0)
        XCTAssertEqual(callbackCapture.snapshot().count, 1)
    }

    func testCommandSendFromSdkReturnsForbiddenRole() async throws {
        let app = try makeRunningApplication()

        let capture = WebSocketCapture()
        let socket = try await connectWebSocket(app: app, capture: capture)
        try await socket.send(#"{"type":"hello","role":"sdk","platform":"ios","appId":"demo.app","sessionId":"s-1","deviceId":"d-1"}"#)
        try await socket.send(#"{"type":"command.send","requestId":"request-2","target":{"platforms":["ios"]}}"#)

        try await Task.sleep(for: .milliseconds(120))

        let errorFrame = try XCTUnwrap(Self.decodeFrames(from: capture.snapshot()).last(where: { $0.type == "error" }))
        XCTAssertEqual(errorFrame.code, "forbidden_role")
    }

    func testCommandAckFromInspectorReturnsUnsupportedCommand() async throws {
        let app = try makeRunningApplication()

        let capture = WebSocketCapture()
        let socket = try await connectWebSocket(app: app, capture: capture)
        try await socket.send(#"{"type":"hello","role":"inspector"}"#)
        try await socket.send(#"{"type":"command.ack","commandId":"cmd-1"}"#)

        try await Task.sleep(for: .milliseconds(120))

        let errorFrame = try XCTUnwrap(Self.decodeFrames(from: capture.snapshot()).last(where: { $0.type == "error" }))
        XCTAssertEqual(errorFrame.code, "unsupported_command")
    }

    func testCommandSendWithoutTargetUsesSelectedClients() async throws {
        let app = try makeRunningApplication()

        let capture = WebSocketCapture()
        let socket = try await connectWebSocket(app: app, capture: capture)
        try await socket.send(#"{"type":"hello","role":"inspector"}"#)
        try await socket.send(#"{"type":"command.send","requestId":"request-3","command":"ping"}"#)

        try await Task.sleep(for: .milliseconds(120))

        let ackFrame = try XCTUnwrap(Self.decodeFrames(from: capture.snapshot()).first(where: { $0.type == "ack" }))
        XCTAssertEqual(ackFrame.requestId, "request-3")
        XCTAssertEqual(ackFrame.delivered, 0)
    }

    func testCommandSendWithEmptyTargetReturnsInvalidTarget() async throws {
        let app = try makeRunningApplication()

        let capture = WebSocketCapture()
        let socket = try await connectWebSocket(app: app, capture: capture)
        try await socket.send(#"{"type":"hello","role":"inspector"}"#)
        try await socket.send(#"{"type":"command.send","requestId":"request-4","command":"ping","target":{"platforms":[]}}"#)

        try await Task.sleep(for: .milliseconds(120))

        let errorFrame = try XCTUnwrap(Self.decodeFrames(from: capture.snapshot()).last(where: { $0.type == "error" }))
        XCTAssertEqual(errorFrame.code, "invalid_target")
    }

    func testUnsupportedMessageReturnsUnsupportedCommand() async throws {
        let app = try makeRunningApplication()

        let capture = WebSocketCapture()
        let socket = try await connectWebSocket(app: app, capture: capture)
        try await socket.send(#"{"type":"hello","role":"inspector"}"#)
        try await socket.send(#"{"type":"broadcast","message":"hello"}"#)

        try await Task.sleep(for: .milliseconds(120))

        let errorFrame = try XCTUnwrap(Self.decodeFrames(from: capture.snapshot()).last(where: { $0.type == "error" }))
        XCTAssertEqual(errorFrame.code, "unsupported_command")
    }

    func testInvalidJSONReturnsInvalidPayload() async throws {
        let app = try makeRunningApplication()

        let capture = WebSocketCapture()
        let socket = try await connectWebSocket(app: app, capture: capture)
        try await socket.send(#"{"type":"hello","role":"inspector"}"#)
        try await socket.send(#"{"#)

        try await Task.sleep(for: .milliseconds(120))

        let errorFrame = try XCTUnwrap(Self.decodeFrames(from: capture.snapshot()).last(where: { $0.type == "error" }))
        XCTAssertEqual(errorFrame.code, "invalid_payload")
    }

    func testHeartbeatTimeoutClosesConnection() async throws {
        let configuration = GatewayWebSocketConfiguration(
            heartbeatInterval: 0.05,
            heartbeatTimeout: 0.1,
            commandSummaryDelay: 0.1
        )
        let app = try makeRunningApplication(webSocketConfiguration: configuration)

        let capture = WebSocketCapture()
        let socket = try await connectWebSocket(app: app, capture: capture)
        try await socket.send(#"{"type":"hello","role":"sdk","platform":"ios","appId":"demo.app","sessionId":"s-1","deviceId":"d-1"}"#)

        try await Task.sleep(for: .milliseconds(260))

        XCTAssertTrue(socket.isClosed)
    }

    func testMetricsEndpointIncludesCORSHeadersForInspectorOrigin() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try app.test(.GET, "v2/metrics", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .origin, value: "http://127.0.0.1:4173")
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.headers.first(name: .accessControlAllowOrigin), "*")
        })
    }

    func testLogsEndpointReturnsRecordsField() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try app.test(.GET, "v2/logs") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertNotNil(payload.records)
            XCTAssertEqual(payload.records.count, 0)
        }
    }

    func testLogsFanOutAcrossOnlineClientsAndAggregatesSorted() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let logsAEndpoint = try makeClientLogsServer { req in
            let cursor = req.query[Int64.self, at: "cursor"]
            let records = [
                LogRecord(
                    id: 2,
                    timestamp: "2026-03-23T12:01:00Z",
                    level: "info",
                    message: "ios-2",
                    platform: "ios",
                    appId: "demo.app",
                    sessionId: "s-ios",
                    deviceId: "d-ios",
                    category: "client"
                )
            ].filter { record in
                guard let cursor else { return true }
                return record.id > cursor
            }
            return QueryResponse(records: records, hasMore: false)
        }

        let logsBEndpoint = try makeClientLogsServer { req in
            let cursor = req.query[Int64.self, at: "cursor"]
            let records = [
                LogRecord(
                    id: 1,
                    timestamp: "2026-03-23T12:00:00Z",
                    level: "info",
                    message: "android-1",
                    platform: "android",
                    appId: "demo.app",
                    sessionId: "s-android",
                    deviceId: "d-android",
                    category: "client"
                )
            ].filter { record in
                guard let cursor else { return true }
                return record.id > cursor
            }
            return QueryResponse(records: records, hasMore: false)
        }

        try registerClient(app: app, platform: "ios", appId: "demo.app", sessionId: "s-ios", deviceId: "d-ios", callbackEndpoint: logsAEndpoint)
        try registerClient(app: app, platform: "android", appId: "demo.app", sessionId: "s-android", deviceId: "d-android", callbackEndpoint: logsBEndpoint)

        try app.test(.GET, "v2/logs?length=10") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 2)
            XCTAssertEqual(payload.records.map(\.message), ["android-1", "ios-2"])
        }
    }

    func testLogsAllUpstreamFailuresStillReturn200WithPartialFailures() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try registerClient(
            app: app,
            platform: "ios",
            appId: "demo.app",
            sessionId: "s-failed",
            deviceId: "d-failed",
            callbackEndpoint: "http://127.0.0.1:1/v2/client/command"
        )

        try app.test(.GET, "v2/logs?cursor=9&length=10") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 0)
            XCTAssertEqual(payload.meta?.partialFailures.count, 1)
        }
    }

    func testLogsLengthCanBeEmptyWhenUpstreamReturnsNoRecords() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let endpoint = try makeClientLogsServer { req in
            XCTAssertNil(req.query[Int.self, at: "length"])
            return QueryResponse(records: [], hasMore: false)
        }

        try registerClient(app: app, platform: "ios", appId: "demo.app", sessionId: "s-timeout", deviceId: "d-timeout", callbackEndpoint: endpoint)

        try app.test(.GET, "v2/logs?cursor=11") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 0)
        }
    }

    func testLogsFilterRoutesToMatchingClientOnly() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let iosEndpoint = try makeClientLogsServer { _ in
            QueryResponse(records: [
                LogRecord(
                    id: 3,
                    timestamp: "2026-03-23T12:03:00Z",
                    level: "info",
                    message: "ios-only",
                    platform: "ios",
                    appId: "demo.app",
                    sessionId: "s-ios-only",
                    deviceId: "d-ios-only",
                    category: "client"
                )
            ], hasMore: false)
        }

        let androidEndpoint = try makeClientLogsServer { _ in
            QueryResponse(records: [
                LogRecord(
                    id: 4,
                    timestamp: "2026-03-23T12:04:00Z",
                    level: "info",
                    message: "android-only",
                    platform: "android",
                    appId: "demo.app",
                    sessionId: "s-android-only",
                    deviceId: "d-android-only",
                    category: "client"
                )
            ], hasMore: false)
        }

        try registerClient(app: app, platform: "ios", appId: "demo.app", sessionId: "s-ios-only", deviceId: "d-ios-only", callbackEndpoint: iosEndpoint)
        try registerClient(app: app, platform: "android", appId: "demo.app", sessionId: "s-android-only", deviceId: "d-android-only", callbackEndpoint: androidEndpoint)

        try app.test(.GET, "v2/logs?platform=ios") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 1)
            XCTAssertEqual(payload.records.first?.platform, "ios")
            XCTAssertEqual(payload.records.first?.message, "ios-only")
        }
    }

    func testViewTreeInspectorEndpointReturnsIngestedRawPayload() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let rawPayload = """
        {
          "platform": "harmony",
          "appId": "demo.app",
          "sessionId": "s-view",
          "deviceId": "d-view",
          "snapshotId": "inspector-1",
          "capturedAt": "2026-03-26T12:00:01Z",
          "payload": {
            "$type": "root",
            "$children": []
          }
        }
        """
        try app.test(.POST, "v2/ui-tree/inspector", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: rawPayload)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .accepted)
        })

        try app.test(.GET, "v2/ui-tree/inspector?deviceId=d-view") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(InspectorSnapshot.self)
            XCTAssertEqual(payload.snapshotId, "inspector-1")
            XCTAssertEqual(payload.platform, "harmony")
            XCTAssertEqual(payload.available, true)
            if let object = payload.payload?.dictionary {
                XCTAssertEqual(object["$type"]?.string, "root")
            } else {
                return XCTFail("Expected object payload")
            }
        }
    }

    func testViewTreeSnapshotEndpointBuildsFromIngestedRawPayload() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let rawPayload = """
        {
          "platform": "harmony",
          "appId": "demo.app",
          "sessionId": "s-view",
          "deviceId": "d-view",
          "snapshotId": "raw-1",
          "capturedAt": "2026-03-26T12:00:00Z",
          "payload": {
            "roots": [
              {
                "id": "root",
                "name": "RootView",
                "children": [
                  {
                    "id": "child",
                    "parentId": "root",
                    "name": "Text",
                    "style": {}
                  }
                ]
              }
            ]
          }
        }
        """

        try app.test(.POST, "v2/ui-tree/inspector", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: rawPayload)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .accepted)
        })

        try app.test(.GET, "v2/ui-tree/snapshot?platform=harmony&appId=demo.app&sessionId=s-view") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ViewTreeSnapshot.self)
            XCTAssertEqual(payload.platform, "harmony")
            XCTAssertEqual(payload.roots.count, 1)
            XCTAssertEqual(payload.roots.first?.children.count, 1)
            XCTAssertEqual(payload.roots.first?.visible, true)
            XCTAssertEqual(payload.roots.first?.children.first?.children.count, 0)
            XCTAssertEqual(payload.roots.first?.children.first?.visible, true)
            XCTAssertEqual(payload.roots.first?.children.first?.style?.borderWidth, 0)
            XCTAssertEqual(payload.roots.first?.children.first?.style?.zIndex, 0)
        }
    }

    func testViewTreeSnapshotEndpointMapsHarmonyInspectorContentChildrenAndRect() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let rawPayload = """
        {
          "platform": "harmony",
          "appId": "demo.app",
          "sessionId": "s-harmony",
          "deviceId": "d-harmony",
          "snapshotId": "raw-harmony-1",
          "capturedAt": "2026-03-27T12:00:00Z",
          "payload": {
            "type": "root",
            "content": {
              "$resolution": "3.5",
              "$children": [
                {
                  "$ID": 7,
                  "$type": "Text",
                  "$rect": "[269.00, 293.00],[1051.00,539.00]",
                  "$attrs": {
                    "content": "Neptune SDK Harmony Demo",
                    "fontColor": "#FFF2F7FF",
                    "backgroundColor": "#00000000",
                    "fontSize": 30,
                    "lineHeight": 40,
                    "letterSpacing": 1,
                    "platformFontScale": 1,
                    "fontWeightRaw": "FontWeight.Bold",
                    "zIndex": 2,
                    "visible": true
                  },
                  "$children": []
                }
              ]
            }
          }
        }
        """

        try app.test(.POST, "v2/ui-tree/inspector", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: rawPayload)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .accepted)
        })

        try app.test(.GET, "v2/ui-tree/snapshot?platform=harmony&appId=demo.app&sessionId=s-harmony&deviceId=d-harmony") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ViewTreeSnapshot.self)
            XCTAssertEqual(payload.platform, "harmony")
            XCTAssertEqual(payload.roots.count, 1)
            let root = try XCTUnwrap(payload.roots.first)
            XCTAssertEqual(root.id, "7")
            XCTAssertEqual(root.name, "Text")
            XCTAssertEqual(root.text, "Neptune SDK Harmony Demo")
            XCTAssertEqual(root.visible, true)
            let frame = try XCTUnwrap(root.frame)
            XCTAssertEqual(frame.x, 76.85714285714286, accuracy: 0.0001)
            XCTAssertEqual(frame.y, 83.71428571428571, accuracy: 0.0001)
            XCTAssertEqual(frame.width, 223.42857142857142, accuracy: 0.0001)
            XCTAssertEqual(frame.height, 70.28571428571429, accuracy: 0.0001)
            XCTAssertEqual(root.style?.textColor, "#F2F7FFFF")
            XCTAssertEqual(root.style?.backgroundColor, "#00000000")
            XCTAssertEqual(root.style?.fontSize, 30)
            XCTAssertEqual(root.style?.lineHeight, 40)
            XCTAssertEqual(root.style?.letterSpacing, 1)
            XCTAssertEqual(root.style?.fontWeightRaw, "FontWeight.Bold")
            XCTAssertEqual(root.style?.zIndex, 2)
            XCTAssertEqual(root.style?.typographyUnit, "dp")
            XCTAssertEqual(root.style?.sourceTypographyUnit, "fp")
        }
    }

    func testViewTreeSnapshotEndpointAppliesHarmonyButtonDefaultsInGateway() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let rawPayload = """
        {
          "platform": "harmony",
          "appId": "demo.app",
          "sessionId": "s-harmony-button",
          "deviceId": "d-harmony-button",
          "snapshotId": "raw-harmony-button-1",
          "capturedAt": "2026-03-27T12:00:00Z",
          "payload": {
            "type": "root",
            "content": {
              "$resolution": "3.5",
              "$children": [
                {
                  "$ID": 18,
                  "$type": "Button",
                  "$rect": "[140.00, 1515.00],[1174.00,1704.00]",
                  "$attrs": {
                    "content": "发现并上报",
                    "backgroundColor": "#FF74D3F7",
                    "fontColor": "#FF04121C",
                    "fontSize": 16,
                    "fontWeightRaw": "FontWeight.Bold",
                    "borderRadius": "0.00vp",
                    "visible": true
                  },
                  "$children": []
                }
              ]
            }
          }
        }
        """

        try app.test(.POST, "v2/ui-tree/inspector", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: rawPayload)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .accepted)
        })

        try app.test(.GET, "v2/ui-tree/snapshot?platform=harmony&appId=demo.app&sessionId=s-harmony-button&deviceId=d-harmony-button") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ViewTreeSnapshot.self)
            let root = try XCTUnwrap(payload.roots.first)
            XCTAssertEqual(root.name, "Button")
            XCTAssertEqual(root.text, "发现并上报")
            XCTAssertEqual(root.style?.textAlign, "Alignment.Center")
            let borderRadius = try XCTUnwrap(root.style?.borderRadius)
            XCTAssertEqual(borderRadius, 27, accuracy: 0.0001)
        }
    }

    func testViewTreeSnapshotEndpointMapsHarmonyFillAndStrokeToStandardStyle() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let rawPayload = """
        {
          "platform": "harmony",
          "appId": "demo.app",
          "sessionId": "s-harmony-fill-stroke",
          "deviceId": "d-harmony-fill-stroke",
          "snapshotId": "raw-harmony-fill-stroke-1",
          "capturedAt": "2026-03-27T12:00:00Z",
          "payload": {
            "type": "root",
            "content": {
              "$resolution": "3.5",
              "$children": [
                {
                  "$ID": 31,
                  "$type": "Rect",
                  "$rect": "[160.00, 420.00],[220.00,480.00]",
                  "$attrs": {
                    "fill": "#FF74D3F7",
                    "stroke": "#FF000000",
                    "strokeWidth": 2,
                    "visible": true
                  },
                  "$children": []
                }
              ]
            }
          }
        }
        """

        try app.test(.POST, "v2/ui-tree/inspector", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: rawPayload)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .accepted)
        })

        try app.test(.GET, "v2/ui-tree/snapshot?platform=harmony&appId=demo.app&sessionId=s-harmony-fill-stroke&deviceId=d-harmony-fill-stroke") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ViewTreeSnapshot.self)
            let root = try XCTUnwrap(payload.roots.first)
            XCTAssertEqual(root.name, "Rect")
            XCTAssertEqual(root.style?.backgroundColor, "#74D3F7FF")
            XCTAssertEqual(root.style?.borderColor, "#000000FF")
            XCTAssertEqual(root.style?.borderWidth, 2)
        }
    }

    func testViewTreeSnapshotEndpointAutoBackfillsFromClientInspector() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let callbackEndpoint = try makeClientInspectorServer { _ in
            let raw = """
            {
              "snapshotId": "client-inspector-1",
              "capturedAt": "2026-03-27T12:00:00Z",
              "platform": "ios",
              "available": true,
              "payload": {
                "roots": [
                  {
                    "id": "root-auto",
                    "name": "UIView",
                    "children": [
                      {
                        "id": "label-auto",
                        "name": "UILabel",
                        "text": "Auto backfill text",
                        "children": []
                      }
                    ]
                  }
                ]
              }
            }
            """
            return try JSONDecoder().decode(InspectorSnapshot.self, from: Data(raw.utf8))
        }

        try registerClient(
            app: app,
            platform: "ios",
            appId: "demo.auto.backfill",
            sessionId: "session-auto",
            deviceId: "device-auto",
            callbackEndpoint: callbackEndpoint
        )

        try app.test(.GET, "v2/ui-tree/snapshot?platform=ios&appId=demo.auto.backfill&sessionId=session-auto&deviceId=device-auto") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ViewTreeSnapshot.self)
            XCTAssertEqual(payload.platform, "ios")
            XCTAssertEqual(payload.roots.count, 1)
            XCTAssertEqual(payload.roots.first?.name, "UIView")
            XCTAssertEqual(payload.roots.first?.children.first?.name, "UILabel")
            XCTAssertEqual(payload.roots.first?.children.first?.text, "Auto backfill text")
        }

        try app.test(.GET, "v2/ui-tree/inspector?deviceId=device-auto") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(InspectorSnapshot.self)
            XCTAssertEqual(payload.snapshotId, "client-inspector-1")
            XCTAssertEqual(payload.available, true)
        }
    }

    func testViewTreeSnapshotRefreshForcesBackfillEvenWhenCacheExists() throws {
        final class CallCounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }

        let counter = CallCounterBox()
        let app = try makeApplication()
        defer { app.shutdown() }

        let callbackEndpoint = try makeClientInspectorServer { _ in
            let callIndex = counter.next()
            let text = callIndex == 1 ? "Old cache value" : "Fresh refresh value"
            let raw = """
            {
              "snapshotId": "client-inspector-\(callIndex)",
              "capturedAt": "2026-03-27T12:00:0\(callIndex)Z",
              "platform": "ios",
              "available": true,
              "payload": {
                "roots": [
                  {
                    "id": "root-refresh",
                    "name": "UIView",
                    "children": [
                      {
                        "id": "label-refresh",
                        "name": "UILabel",
                        "text": "\(text)",
                        "children": []
                      }
                    ]
                  }
                ]
              }
            }
            """
            return try JSONDecoder().decode(InspectorSnapshot.self, from: Data(raw.utf8))
        }

        try registerClient(
            app: app,
            platform: "ios",
            appId: "demo.refresh.backfill",
            sessionId: "session-refresh",
            deviceId: "device-refresh",
            callbackEndpoint: callbackEndpoint
        )

        try app.test(.GET, "v2/ui-tree/snapshot?platform=ios&appId=demo.refresh.backfill&sessionId=session-refresh&deviceId=device-refresh") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ViewTreeSnapshot.self)
            XCTAssertEqual(payload.roots.first?.children.first?.text, "Old cache value")
        }

        try app.test(.GET, "v2/ui-tree/snapshot?platform=ios&appId=demo.refresh.backfill&sessionId=session-refresh&deviceId=device-refresh&refresh=1") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ViewTreeSnapshot.self)
            XCTAssertEqual(payload.roots.first?.children.first?.text, "Fresh refresh value")
        }
    }

    func testViewTreeSnapshotEndpointRequiresPlatformAppIdAndSessionId() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try app.test(.GET, "v2/ui-tree/snapshot?platform=harmony&appId=demo.app") { response in
            XCTAssertEqual(response.status, .badRequest)
        }
    }

    func testViewTreeInspectorEndpointRequiresDeviceId() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try app.test(.GET, "v2/ui-tree/inspector?platform=harmony&appId=demo.app") { response in
            XCTAssertEqual(response.status, .badRequest)
        }
    }

    func testIngestThenQueryReturnsRecord() throws {
        throw XCTSkip("obsolete: gateway no longer stores logs locally")
        let app = try makeApplication()
        defer { app.shutdown() }

        try app.test(.POST, "v2/logs:ingest", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: sampleRecord)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .accepted)
        })

        try app.test(.GET, "v2/logs") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 1)
            XCTAssertEqual(payload.records.first?.id, 1)
            XCTAssertEqual(payload.records.first?.message, "boot ok")
        }
    }

    func testJSONArrayIngestReturnsAllRecords() throws {
        throw XCTSkip("obsolete: gateway no longer stores logs locally")
        let app = try makeApplication()
        defer { app.shutdown() }

        let payload = """
        [\(sampleRecord),\(newerRecord)]
        """

        try Self.ingest(app: app, body: payload, contentType: .json)

        try app.test(.GET, "v2/logs") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 2)
            XCTAssertEqual(payload.records.map(\.message), ["boot ok", "boot later"])
        }
    }

    func testPlatformFilterReturnsMatchingRecordsOnly() throws {
        throw XCTSkip("obsolete: gateway query now fan-outs to clients instead of local store")
        let app = try makeApplication()
        defer { app.shutdown() }

        let androidRecord = sampleRecord.replacingOccurrences(of: "\"platform\":\"ios\"", with: "\"platform\":\"android\"")
            .replacingOccurrences(of: "\"message\":\"boot ok\"", with: "\"message\":\"android boot\"")

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)
        try Self.ingest(app: app, body: androidRecord, contentType: .json)

        try app.test(.GET, "v2/logs?platform=ios") { response in
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.map(\.platform), ["ios"])
            XCTAssertEqual(payload.records.map(\.message), ["boot ok"])
        }
    }

    func testSourcesEndpointReturnsDistinctSourcesAndRetentionRemovesOrphans() throws {
        throw XCTSkip("obsolete: gateway sources now come from online clients")
        let retention = GatewayStoreConfiguration(maxRecordCount: 1, maxAge: 60 * 60 * 24 * 14)
        let app = try makeApplication(retention: retention)
        defer { app.shutdown() }

        let secondRecord = newerRecord
            .replacingOccurrences(of: "\"sessionId\":\"s-1\"", with: "\"sessionId\":\"s-2\"")
            .replacingOccurrences(of: "\"deviceId\":\"d-1\"", with: "\"deviceId\":\"d-2\"")

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)
        try Self.ingest(app: app, body: secondRecord, contentType: .json)

        try app.test(.GET, "v2/sources") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(SourceResponse.self)
            XCTAssertEqual(payload.items.count, 1)
            XCTAssertEqual(payload.items.first?.platform, "ios")
            XCTAssertEqual(payload.items.first?.appId, "demo.app")
            XCTAssertEqual(payload.items.first?.sessionId, "s-2")
            XCTAssertEqual(payload.items.first?.deviceId, "d-2")
            XCTAssertEqual(payload.items.first?.lastSeenAt, "2026-03-23T12:01:00Z")
        }
    }

    func testAfterIdFilterReturnsOnlyNewerRecordsWithoutWaiting() throws {
        throw XCTSkip("obsolete: gateway no longer stores logs locally")
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: """
        [\(sampleRecord),\(newerRecord)]
        """, contentType: .json)

        try app.test(.GET, "v2/logs?afterId=1") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 1)
            XCTAssertEqual(payload.records.first?.id, 2)
            XCTAssertEqual(payload.records.first?.message, "boot later")
            XCTAssertFalse(payload.hasMore)
        }
    }

    func testNDJSONIngestMatchesJSONCount() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)
        try Self.ingest(app: app, body: "\(sampleRecord)\n\(sampleRecord.replacingOccurrences(of: "\"sessionId\":\"s-1\"", with: "\"sessionId\":\"s-2\""))\n", contentType: HTTPMediaType(type: "application", subType: "x-ndjson"))

        try app.test(.GET, "v2/metrics") { response in
            let payload = try response.content.decode(MetricsResponse.self)
            XCTAssertEqual(payload.ingestAcceptedTotal, 3)
            XCTAssertEqual(payload.sourceCount, 0)
        }
    }

    func testClientsRegisterListAndSelectedFlow() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try registerClient(
            app: app,
            platform: "ios",
            appId: "demo.app",
            sessionId: "s-1",
            deviceId: "d-1",
            callbackEndpoint: "http://127.0.0.1:18080"
        )

        try app.test(.GET, "v2/clients") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ClientListResponse.self)
            XCTAssertEqual(payload.items.count, 1)
            XCTAssertEqual(payload.items.first?.selected, false)
            XCTAssertGreaterThan(payload.items.first?.ttlSeconds ?? 0, 0)
        }

        try selectClients(
            app: app,
            selectors: [ClientSelector(platform: "ios", appId: "demo.app", deviceId: "d-1")]
        )

        try app.test(.GET, "v2/clients") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ClientListResponse.self)
            XCTAssertEqual(payload.items.count, 1)
            XCTAssertEqual(payload.items.first?.selected, true)
        }
    }

    func testClientsRegisterWithExpiredTimestampIsOfflineImmediately() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try registerClient(
            app: app,
            platform: "ios",
            appId: "demo.app",
            sessionId: "s-expired",
            deviceId: "d-expired",
            callbackEndpoint: "http://127.0.0.1:18080",
            expiresAt: "2001-01-01T00:00:00Z"
        )

        try app.test(.GET, "v2/clients") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(ClientListResponse.self)
            XCTAssertTrue(payload.items.isEmpty)
        }
    }

    func testClientsRegisterRejectsLegacyCommandURLAliasWithoutCallbackEndpoint() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let payload: [String: String] = [
            "platform": "ios",
            "appId": "demo.app",
            "sessionId": "s-command-url",
            "deviceId": "d-command-url",
            "commandUrl": "http://127.0.0.1:18080/v2/client/command",
        ]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        try app.test(.POST, "v2/clients:register", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: body)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .badRequest)
        })
    }

    func testClientsRegisterRejectsLegacyCallbackBaseURLAndPathWithoutCallbackEndpoint() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let payload: [String: String] = [
            "platform": "harmony",
            "appId": "demo.app",
            "sessionId": "s-callback-base",
            "deviceId": "d-callback-base",
            "callbackBaseUrl": "http://127.0.0.1:19090",
            "callbackPath": "/v2/client/command",
        ]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        try app.test(.POST, "v2/clients:register", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: body)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .badRequest)
        })
    }

    func testClientsRegisterPersistsPreferredTransportsAndUSBMuxdHint() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let body = """
        {
          "platform": "ios",
          "appId": "demo.app",
          "sessionId": "s-preferred",
          "deviceId": "d-preferred",
          "callbackEndpoint": "http://127.0.0.1:18080/v2/client/command",
          "preferredTransports": ["usbmuxdHTTP", "httpCallback"],
          "usbmuxdHint": {
            "deviceID": 17
          }
        }
        """

        try app.test(.POST, "v2/clients:register", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: body)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            let registerResponse = try response.content.decode(ClientRegisterResponse.self)
            XCTAssertEqual(registerResponse.client.callbackEndpoint, "http://127.0.0.1:18080/v2/client/command")
            XCTAssertEqual(registerResponse.client.preferredTransports, [.usbmuxdHTTP, .httpCallback])
            XCTAssertEqual(registerResponse.client.usbmuxdHint?.deviceID, 17)
        })
    }

    func testClientsRegisterRejectsUSBMuxdTransportWithoutHint() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        let body = """
        {
          "platform": "ios",
          "appId": "demo.app",
          "sessionId": "s-usbmuxd-missing-hint",
          "deviceId": "d-usbmuxd-missing-hint",
          "callbackEndpoint": "http://127.0.0.1:18080/v2/client/command",
          "preferredTransports": ["usbmuxdHTTP"]
        }
        """

        try app.test(.POST, "v2/clients:register", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: body)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .badRequest)
        })
    }

    func testTextFormatReturnsPlainTextLines() throws {
        throw XCTSkip("obsolete: gateway no longer stores logs locally")
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: """
        [\(sampleRecord),\(newerRecord)]
        """, contentType: .json)

        try app.test(.GET, "v2/logs?format=text") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.headers.contentType?.type, "text")
            XCTAssertEqual(response.headers.contentType?.subType, "plain")

            let body = response.body.string
            let lines = body
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)

            XCTAssertEqual(lines.count, 2)
            XCTAssertEqual(lines[0], "2026-03-23T12:00:00Z\tinfo\tios\tboot ok")
            XCTAssertEqual(lines[1], "2026-03-23T12:01:00Z\tinfo\tios\tboot later")
        }
    }

    func testAfterIdWaitMsTimesOutWithEmptyRecords() throws {
        throw XCTSkip("obsolete: wait behavior is validated via client fan-out tests")
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)

        let start = Date()
        try app.test(.GET, "v2/logs?afterId=1&waitMs=150") { response in
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 0)
            XCTAssertFalse(payload.hasMore)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
    }

    func testAfterIdWaitMsReturnsNewRecordWhenItArrives() throws {
        throw XCTSkip("obsolete: wait behavior is validated via client fan-out tests")
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)

        let laterRecord = newerRecord
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            try? Self.ingest(app: app, body: laterRecord, contentType: .json)
        }

        try app.test(.GET, "v2/logs?afterId=1&waitMs=600") { response in
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 1)
            XCTAssertEqual(payload.records.first?.message, "boot later")
            XCTAssertEqual(payload.records.first?.id, 2)
        }
    }

    func testAfterIdWaitMsWithFilterIgnoresNonMatchingRecordUntilMatchArrives() throws {
        throw XCTSkip("obsolete: wait behavior is validated via client fan-out tests")
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)

        let androidRecord = newerRecord
            .replacingOccurrences(of: "\"platform\":\"ios\"", with: "\"platform\":\"android\"")
            .replacingOccurrences(of: "\"message\":\"boot later\"", with: "\"message\":\"android later\"")
        let iosRecord = newerRecord
            .replacingOccurrences(of: "\"message\":\"boot later\"", with: "\"message\":\"ios after filter\"")

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(60)) {
            try? Self.ingest(app: app, body: androidRecord, contentType: .json)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(140)) {
            try? Self.ingest(app: app, body: iosRecord, contentType: .json)
        }

        try app.test(.GET, "v2/logs?afterId=1&platform=ios&waitMs=500") { response in
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 1)
            XCTAssertEqual(payload.records.first?.platform, "ios")
            XCTAssertEqual(payload.records.first?.message, "ios after filter")
        }
    }

    func testStoreWaitForNewerRecordReturnsFalseOnTimeout() async throws {
        throw XCTSkip("obsolete: waitForNewerRecord removed with strict cursor/length contract")
    }

    func testStoreWaitForNewerRecordReturnsTrueWhenIngestedLater() async throws {
        throw XCTSkip("obsolete: waitForNewerRecord removed with strict cursor/length contract")
    }

    func testStorePersistsAcrossApplicationInstances() throws {
        throw XCTSkip("obsolete for route contract: gateway no longer serves persisted logs")
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }

        do {
            let app = try NeptuneGatewaySwift.makeApplication(
                environment: .testing,
                storageURL: databaseURL,
                storeConfiguration: .default
            )
            defer { app.shutdown() }

            try Self.ingest(app: app, body: sampleRecord, contentType: .json)
        }

        do {
            let app = try NeptuneGatewaySwift.makeApplication(
                environment: .testing,
                storageURL: databaseURL,
                storeConfiguration: .default
            )
            defer { app.shutdown() }

            try app.test(.GET, "v2/logs") { response in
                let payload = try response.content.decode(QueryResponse.self)
                XCTAssertEqual(payload.records.count, 1)
                XCTAssertEqual(payload.records.first?.message, "boot ok")
            }
        }
    }

    func testRetentionPrunesOldRecordsAndOverflow() throws {
        throw XCTSkip("obsolete for route contract: gateway no longer exposes local retention")
        let retention = GatewayStoreConfiguration(maxRecordCount: 2, maxAge: 60 * 60 * 24)
        let app = try makeApplication(retention: retention)
        defer { app.shutdown() }

        let oldRecord = sampleRecord.replacingOccurrences(of: "2026-03-23T12:00:00Z", with: "2001-01-01T00:00:00Z")
        let recentRecord = sampleRecord.replacingOccurrences(of: "2026-03-23T12:00:00Z", with: "2026-03-24T12:00:00Z")
        let recentNewerRecord = newerRecord.replacingOccurrences(of: "2026-03-23T12:01:00Z", with: "2026-03-24T12:01:00Z")

        try Self.ingest(app: app, body: oldRecord, contentType: .json)
        try Self.ingest(app: app, body: recentRecord, contentType: .json)
        try Self.ingest(app: app, body: recentNewerRecord, contentType: .json)

        try app.test(.GET, "v2/logs") { response in
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 2)
            XCTAssertEqual(payload.records.map(\.message), ["boot ok", "boot later"])
            XCTAssertEqual(payload.records.first?.id, 2)
            XCTAssertEqual(payload.records.last?.id, 3)
        }

        try app.test(.GET, "v2/metrics") { response in
            let payload = try response.content.decode(MetricsResponse.self)
            XCTAssertEqual(payload.retainedRecordCount, 2)
            XCTAssertEqual(payload.retentionMaxRecordCount, 2)
            XCTAssertEqual(payload.retentionMaxAgeSeconds, 60 * 60 * 24)
            XCTAssertEqual(payload.retentionDroppedTotal, 1)
        }
    }

    func testMetricsExposeRetentionStateWithoutBreakingExistingFields() throws {
        throw XCTSkip("obsolete: metrics no longer expose totalRecords/droppedOverflow")
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)

        try app.test(.GET, "v2/metrics") { response in
            let payload = try response.content.decode(MetricsResponse.self)
            XCTAssertEqual(payload.ingestAcceptedTotal, 1)
            XCTAssertEqual(payload.retainedRecordCount, 0)
            XCTAssertEqual(payload.retentionMaxRecordCount, 0)
            XCTAssertEqual(payload.retentionMaxAgeSeconds, 0)
        }
    }

    private static func ingest(app: Application, body: String, contentType: HTTPMediaType) throws {
        try app.test(.POST, "v2/logs:ingest", beforeRequest: { request in
            request.headers.contentType = contentType
            request.body = .init(string: body)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .accepted)
        })
    }

    private func registerClient(
        app: Application,
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        callbackEndpoint: String,
        expiresAt: String? = nil
    ) throws {
        var payload: [String: String] = [
            "platform": platform,
            "appId": appId,
            "sessionId": sessionId,
            "deviceId": deviceId,
            "callbackEndpoint": callbackEndpoint,
        ]
        if let expiresAt {
            payload["expiresAt"] = expiresAt
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        let body = String(decoding: data, as: UTF8.self)

        try app.test(.POST, "v2/clients:register", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: body)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            let registerResponse = try response.content.decode(ClientRegisterResponse.self)
            XCTAssertEqual(registerResponse.client.platform, platform)
            XCTAssertEqual(registerResponse.client.appId, appId)
            XCTAssertEqual(registerResponse.client.deviceId, deviceId)
        })
    }

    private func selectClients(
        app: Application,
        selectors: [ClientSelector]
    ) throws {
        let payload = ClientsSelectedRequest(items: selectors)
        let body = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)

        try app.test(.PUT, "v2/clients:selected", beforeRequest: { request in
            request.headers.contentType = .json
            request.body = .init(string: body)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            let result = try response.content.decode(ClientsSelectedResponse.self)
            XCTAssertEqual(result.selectedCount, selectors.count)
        })
    }

    private func makeCallbackServer(capture: CallbackCapture) throws -> String {
        let app = Application(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.post("v2", "client", "command") { req async throws -> GatewayCommandAck in
            let payload = try req.content.decode(GatewayCommandRequest.self)
            capture.append(payload)
            return GatewayCommandAck(
                requestId: payload.requestId,
                command: payload.command,
                status: "ok",
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
        }

        try app.start()
        addTeardownBlock {
            app.shutdown()
        }

        guard let port = app.http.server.shared.localAddress?.port else {
            XCTFail("callback server did not start")
            throw NSError(domain: "GatewayRoutesTests", code: 2)
        }
        return "http://127.0.0.1:\(port)"
    }

    private func makeClientLogsServer(
        handler: @escaping @Sendable (Request) throws -> QueryResponse
    ) throws -> String {
        let app = Application(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.get("v2", "logs") { req async throws -> QueryResponse in
            try handler(req)
        }

        try app.start()
        addTeardownBlock {
            app.shutdown()
        }

        guard let port = app.http.server.shared.localAddress?.port else {
            XCTFail("client logs server did not start")
            throw NSError(domain: "GatewayRoutesTests", code: 3)
        }
        return "http://127.0.0.1:\(port)/v2/client/command"
    }

    private func makeClientInspectorServer(
        handler: @escaping @Sendable (Request) throws -> InspectorSnapshot
    ) throws -> String {
        let app = Application(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.get("v2", "ui-tree", "inspector") { req async throws -> InspectorSnapshot in
            try handler(req)
        }

        try app.start()
        addTeardownBlock {
            app.shutdown()
        }

        guard let port = app.http.server.shared.localAddress?.port else {
            XCTFail("client inspector server did not start")
            throw NSError(domain: "GatewayRoutesTests", code: 5)
        }
        return "http://127.0.0.1:\(port)/v2/client/command"
    }

    private func makeRecord(from json: String) throws -> IngestLogRecord {
        try JSONDecoder().decode(IngestLogRecord.self, from: Data(json.utf8))
    }

    private func makeRunningApplication(
        retention: GatewayStoreConfiguration = .default,
        webSocketConfiguration: GatewayWebSocketConfiguration = .default
    ) throws -> Application {
        let databaseURL = temporaryDatabaseURL()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        let app = try NeptuneGatewaySwift.makeApplication(
            environment: .testing,
            hostname: "127.0.0.1",
            port: 0,
            storageURL: databaseURL,
            storeConfiguration: retention,
            webSocketConfiguration: webSocketConfiguration
        )
        app.environment.arguments = ["serve"]
        try app.start()
        addTeardownBlock {
            app.shutdown()
        }
        return app
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func connectWebSocket(
        app: Application,
        capture: WebSocketCapture,
        onText: (@Sendable (WebSocket, String) -> Void)? = nil
    ) async throws -> WebSocket {
        guard let port = app.http.server.shared.localAddress?.port else {
            XCTFail("Web server is not listening")
            throw NSError(domain: "GatewayRoutesTests", code: 1)
        }

        let socket = try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    try await WebSocket.connect(
                        to: "ws://127.0.0.1:\(port)/v2/ws",
                        on: app.eventLoopGroup
                    ) { socket in
                        socket.onText { socket, text in
                            capture.append(text)
                            onText?(socket, text)
                        }
                        continuation.resume(returning: socket)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        addTeardownBlock {
            _ = socket.close()
        }
        return socket
    }

    private static func decodeFrames(from messages: [String]) throws -> [WebSocketEnvelope] {
        try messages.map(Self.decodeFrame)
    }

    private static func decodeFrame(_ message: String) throws -> WebSocketEnvelope {
        try JSONDecoder().decode(WebSocketEnvelope.self, from: Data(message.utf8))
    }
}

private final class WebSocketCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private final class CallbackCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [GatewayCommandRequest] = []

    func append(_ request: GatewayCommandRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [GatewayCommandRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class WebSocketHandle: @unchecked Sendable {
    var socket: WebSocket?
}

private struct WebSocketEnvelope: Decodable {
    let type: String
    let topic: String?
    let topicId: Int?
    let ts: String?
    let deviceId: String?
    let code: String?
    let requestId: String?
    let commandId: String?
    let command: String?
    let status: String?
    let accepted: Bool?
    let delivered: Int?
    let acked: Int?
    let timeout: Int?
    let target: GatewayWSClientTarget?
    let from: GatewayWSClientContext?
    let record: WSLogRecord?
}

private struct WSLogRecord: Decodable {
    let id: Int64?
    let message: String?
    let platform: String?
}
