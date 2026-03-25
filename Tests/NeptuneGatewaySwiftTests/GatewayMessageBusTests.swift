import XCTest
@testable import NeptuneGatewaySwift

final class GatewayMessageBusTests: XCTestCase {
    func testMessageBusSelectsPreferredAdapterAndFallsBack() async throws {
        let recorder = AdapterCallRecorder()
        let webSocket = StubTransportAdapter(
            transport: .webSocket,
            recorder: recorder
        ) { _, _ in
            nil
        }
        let http = StubTransportAdapter(
            transport: .httpCallback,
            recorder: recorder
        ) { client, envelope in
            BusAck(
                requestId: envelope.requestId,
                command: envelope.command,
                status: "ok",
                message: client.recipientID,
                timestamp: "2026-03-25T10:00:00Z",
                recipientID: client.recipientID,
                transport: .httpCallback
            )
        }
        let bus = GatewayMessageBus(adapters: [webSocket, http])
        let client = GatewayBusClient(
            recipientID: "ios|demo.app|device-1",
            platform: "ios",
            appId: "demo.app",
            sessionId: "session-1",
            deviceId: "device-1",
            callbackEndpoint: "http://127.0.0.1:18080",
            preferredTransports: [.webSocket, .httpCallback],
            usbmuxdHint: nil
        )
        let envelope = BusEnvelope(
            requestId: "request-1",
            command: "ping",
            payload: nil,
            timestamp: "2026-03-25T10:00:00Z"
        )

        let ack = await bus.send(envelope, to: client)

        XCTAssertEqual(recorder.snapshot(), [.webSocket, .httpCallback])
        XCTAssertEqual(ack?.transport, .httpCallback)
        XCTAssertEqual(ack?.recipientID, client.recipientID)
        XCTAssertEqual(ack?.status, "ok")
    }

    func testMessageBusAggregatesAckCountsAcrossRecipients() async throws {
        let recorder = AdapterCallRecorder()
        let http = StubTransportAdapter(
            transport: .httpCallback,
            recorder: recorder
        ) { client, envelope in
            guard client.deviceId != "device-timeout" else {
                return nil
            }
            return BusAck(
                requestId: envelope.requestId,
                command: envelope.command,
                status: client.deviceId == "device-error" ? "error" : "ok",
                message: client.deviceId,
                timestamp: "2026-03-25T10:00:00Z",
                recipientID: client.recipientID,
                transport: .httpCallback
            )
        }
        let bus = GatewayMessageBus(adapters: [http])
        let envelope = BusEnvelope(
            requestId: "request-2",
            command: "ping",
            payload: nil,
            timestamp: "2026-03-25T10:00:00Z"
        )
        let clients = [
            GatewayBusClient(
                recipientID: "ios|demo.app|device-ok",
                platform: "ios",
                appId: "demo.app",
                sessionId: "session-ok",
                deviceId: "device-ok",
                callbackEndpoint: "http://127.0.0.1:18080",
                preferredTransports: [.httpCallback],
                usbmuxdHint: nil
            ),
            GatewayBusClient(
                recipientID: "ios|demo.app|device-error",
                platform: "ios",
                appId: "demo.app",
                sessionId: "session-error",
                deviceId: "device-error",
                callbackEndpoint: "http://127.0.0.1:18080",
                preferredTransports: [.httpCallback],
                usbmuxdHint: nil
            ),
            GatewayBusClient(
                recipientID: "ios|demo.app|device-timeout",
                platform: "ios",
                appId: "demo.app",
                sessionId: "session-timeout",
                deviceId: "device-timeout",
                callbackEndpoint: "http://127.0.0.1:18080",
                preferredTransports: [.httpCallback],
                usbmuxdHint: nil
            ),
        ]

        let summary = await bus.dispatch(envelope, to: clients)

        XCTAssertEqual(summary.deliveredCount, 3)
        XCTAssertEqual(summary.ackedCount, 2)
        XCTAssertEqual(summary.timeoutCount, 1)
        XCTAssertEqual(summary.acks.compactMap(\.recipientID).sorted(), [
            "ios|demo.app|device-error",
            "ios|demo.app|device-ok",
        ])
        XCTAssertEqual(recorder.snapshot().count, 3)
    }
}

final class USBMuxdHTTPAdapterTests: XCTestCase {
    func testConnectRequestUsesLittleEndianHeaderAndByteSwappedPort() throws {
        let request = try USBMuxdHTTPAdapter.makeConnectRequest(
            deviceID: 7,
            port: 8100
        )

        XCTAssertEqual(request.readLittleEndianUInt32(at: 4), 1)
        XCTAssertEqual(request.readLittleEndianUInt32(at: 8), 8)
        XCTAssertEqual(request.readLittleEndianUInt32(at: 12), 1)
        XCTAssertEqual(request.readLittleEndianUInt32(at: 0), UInt32(request.count))

        let plistData = request.dropFirst(16)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(plist["MessageType"] as? String, "Connect")
        XCTAssertEqual(plist["DeviceID"] as? Int, 7)
        XCTAssertEqual(plist["PortNumber"] as? Int, Int(UInt16(8100).byteSwapped))
    }

    func testUSBMuxdAdapterReturnsAckAfterHandshakeAndHTTPResponse() async throws {
        let factory = MockUSBMuxdConnectionFactory(
            connection: MockUSBMuxdConnection(
                reads: [
                    try USBMuxdHTTPAdapter.makeResultResponse(number: 0),
                    Data("""
                    HTTP/1.1 200 OK\r
                    Content-Length: 153\r
                    Content-Type: application/json\r
                    Connection: close\r
                    \r
                    {"requestId":"request-3","command":"ping","status":"ok","message":"usb","timestamp":"2026-03-25T10:00:00Z","recipientID":"ios|demo.app|device-1","transport":"usbmuxdHTTP"}
                    """.utf8),
                ]
            )
        )
        let adapter = USBMuxdHTTPAdapter(connectionFactory: factory)
        let client = GatewayBusClient(
            recipientID: "ios|demo.app|device-1",
            platform: "ios",
            appId: "demo.app",
            sessionId: "session-1",
            deviceId: "device-1",
            callbackEndpoint: "http://device.local:8100/v2/client/command",
            preferredTransports: [.usbmuxdHTTP],
            usbmuxdHint: USBMuxdHint(deviceID: 9)
        )
        let envelope = BusEnvelope(
            requestId: "request-3",
            command: "ping",
            payload: ["probe": "1"],
            timestamp: "2026-03-25T10:00:00Z"
        )

        let ack = await adapter.send(envelope, to: client)

        XCTAssertEqual(ack?.transport, .usbmuxdHTTP)
        XCTAssertEqual(ack?.status, "ok")
        let request = try XCTUnwrap(factory.connection.writes.first)
        XCTAssertEqual(request.readLittleEndianUInt32(at: 4), 1)
        XCTAssertEqual(request.readLittleEndianUInt32(at: 8), 8)
        let plistData = request.dropFirst(16)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["DeviceID"] as? Int, 9)
        XCTAssertEqual(plist["PortNumber"] as? Int, Int(UInt16(8100).byteSwapped))
        let httpRequest = String(decoding: factory.connection.writes[1], as: UTF8.self)
        XCTAssertTrue(httpRequest.contains("POST /v2/client/command HTTP/1.1"))
        XCTAssertTrue(httpRequest.contains("\"command\":\"ping\""))
    }

    func testUSBMuxdAdapterReturnsNilWhenHandshakeFails() async throws {
        let factory = MockUSBMuxdConnectionFactory(
            connection: MockUSBMuxdConnection(
                reads: [try USBMuxdHTTPAdapter.makeResultResponse(number: 5)]
            )
        )
        let adapter = USBMuxdHTTPAdapter(connectionFactory: factory)
        let client = GatewayBusClient(
            recipientID: "ios|demo.app|device-2",
            platform: "ios",
            appId: "demo.app",
            sessionId: "session-2",
            deviceId: "device-2",
            callbackEndpoint: "http://device.local:8100/v2/client/command",
            preferredTransports: [.usbmuxdHTTP],
            usbmuxdHint: USBMuxdHint(deviceID: 10)
        )
        let envelope = BusEnvelope(
            requestId: "request-4",
            command: "ping",
            payload: nil,
            timestamp: "2026-03-25T10:00:00Z"
        )

        let ack = await adapter.send(envelope, to: client)

        XCTAssertNil(ack)
        XCTAssertEqual(factory.connection.writes.count, 1)
    }
}

private final class AdapterCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClientTransport] = []

    func append(_ transport: ClientTransport) {
        lock.lock()
        values.append(transport)
        lock.unlock()
    }

    func snapshot() -> [ClientTransport] {
        lock.lock()
        let current = values
        lock.unlock()
        return current
    }
}

private struct StubTransportAdapter: ClientTransportAdapter {
    let transport: ClientTransport
    let recorder: AdapterCallRecorder
    let responder: @Sendable (GatewayBusClient, BusEnvelope) async -> BusAck?

    func send(_ envelope: BusEnvelope, to client: GatewayBusClient) async -> BusAck? {
        recorder.append(transport)
        return await responder(client, envelope)
    }
}

private final class MockUSBMuxdConnectionFactory: USBMuxdConnectionFactory, @unchecked Sendable {
    let connection: MockUSBMuxdConnection

    init(connection: MockUSBMuxdConnection) {
        self.connection = connection
    }

    func connect(to path: String) throws -> USBMuxdConnection {
        connection.connectedPath = path
        return connection
    }
}

private final class MockUSBMuxdConnection: USBMuxdConnection, @unchecked Sendable {
    private var reads: [Data]
    private(set) var writes: [Data] = []
    var connectedPath: String?

    init(reads: [Data]) {
        self.reads = reads
    }

    func write(_ data: Data) throws {
        writes.append(data)
    }

    func read(maxBytes: Int) throws -> Data {
        guard !reads.isEmpty else {
            return Data()
        }

        var first = reads.removeFirst()
        guard first.count > maxBytes else {
            return first
        }

        let prefix = first.prefix(maxBytes)
        first.removeFirst(maxBytes)
        reads.insert(first, at: 0)
        return Data(prefix)
    }

    func close() {}
}

private extension Data {
    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: UInt32.self)
        }
    }
}
