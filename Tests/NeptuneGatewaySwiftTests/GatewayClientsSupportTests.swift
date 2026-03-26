import XCTest
@testable import NeptuneGatewaySwift

final class GatewayClientsSupportTests: XCTestCase {
    func testClientsURLBuildsWithBasePath() throws {
        let fetcher = GatewayClientsFetcher(gatewayBaseURL: "http://127.0.0.1:18765/api")
        let url = try fetcher.clientsURL()
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:18765/api/v2/clients")
    }

    func testRenderTextWithEmptyItems() {
        XCTAssertEqual(ClientListRenderer.renderText([]), "No online clients.\n")
    }

    func testRenderTextWithOneClient() {
        let item = ClientSnapshot(
            platform: "ios",
            appId: "demo.app",
            sessionId: "session-1",
            deviceId: "device-1",
            callbackEndpoint: "http://127.0.0.1:28888/v2/client/command",
            preferredTransports: [.httpCallback, .webSocket],
            usbmuxdHint: USBMuxdHint(deviceID: 123, socketPath: "/var/run/usbmuxd"),
            lastSeenAt: "2026-03-26T10:00:00Z",
            expiresAt: "2026-03-26T10:02:00Z",
            ttlSeconds: 120,
            selected: true
        )

        let rendered = ClientListRenderer.renderText([item])
        XCTAssertEqual(rendered, "- [ios-demo.app] device-1\n")
    }

    func testRenderJSONContainsItems() throws {
        let response = ClientListResponse(
            items: [
                ClientSnapshot(
                    platform: "android",
                    appId: "demo.android",
                    sessionId: "session-a",
                    deviceId: "device-a",
                    callbackEndpoint: "http://127.0.0.1:29999/v2/client/command",
                    preferredTransports: [.httpCallback],
                    usbmuxdHint: nil,
                    lastSeenAt: "2026-03-26T10:10:00Z",
                    expiresAt: "2026-03-26T10:12:00Z",
                    ttlSeconds: 120,
                    selected: false
                )
            ]
        )

        let json = try ClientListRenderer.renderJSON(response)
        XCTAssertTrue(json.contains("\"items\""))
        let decoded = try JSONDecoder().decode(ClientListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.items.first?.platform, "android")
        XCTAssertEqual(decoded.items.first?.callbackEndpoint, "http://127.0.0.1:29999/v2/client/command")
    }

    func testRenderYAMLGroupsByDeviceID() throws {
        let response = ClientListResponse(
            items: [
                ClientSnapshot(
                    platform: "ios",
                    appId: "demo.ios",
                    sessionId: "session-ios",
                    deviceId: "device-shared",
                    callbackEndpoint: "http://127.0.0.1:18888/v2/client/command",
                    preferredTransports: [.httpCallback],
                    usbmuxdHint: nil,
                    lastSeenAt: "2026-03-26T10:20:00Z",
                    expiresAt: "2026-03-26T10:22:00Z",
                    ttlSeconds: 120,
                    selected: false
                ),
                ClientSnapshot(
                    platform: "android",
                    appId: "demo.android",
                    sessionId: "session-android",
                    deviceId: "device-shared",
                    callbackEndpoint: "http://127.0.0.1:19999/v2/client/command",
                    preferredTransports: [.httpCallback],
                    usbmuxdHint: nil,
                    lastSeenAt: "2026-03-26T10:21:00Z",
                    expiresAt: "2026-03-26T10:23:00Z",
                    ttlSeconds: 120,
                    selected: true
                ),
            ]
        )

        let yaml = try ClientListRenderer.renderYAML(response)
        XCTAssertTrue(yaml.contains("device-shared:"))
        XCTAssertTrue(yaml.contains("platform: ios"))
        XCTAssertTrue(yaml.contains("platform: android"))
    }

    func testLogsStreamResolverMatchesByDeviceID() throws {
        let clients = [
            ClientSnapshot(
                platform: "ios",
                appId: "demo.ios",
                sessionId: "session-ios",
                deviceId: "device-1",
                callbackEndpoint: "http://127.0.0.1:18888/v2/client/command",
                preferredTransports: [.httpCallback],
                usbmuxdHint: nil,
                lastSeenAt: "2026-03-26T10:20:00Z",
                expiresAt: "2026-03-26T10:22:00Z",
                ttlSeconds: 120,
                selected: false
            ),
        ]
        let resolved = try LogsStreamClientResolver.resolve(from: clients, deviceID: "device-1", appID: nil, sessionID: nil)
        XCTAssertEqual(resolved.platform, "ios")
        XCTAssertEqual(resolved.appId, "demo.ios")
    }

    func testLogsStreamResolverThrowsOnAmbiguousPlatform() {
        let clients = [
            ClientSnapshot(
                platform: "ios",
                appId: "demo.ios",
                sessionId: "session-ios",
                deviceId: "device-1",
                callbackEndpoint: "http://127.0.0.1:18888/v2/client/command",
                preferredTransports: [.httpCallback],
                usbmuxdHint: nil,
                lastSeenAt: "2026-03-26T10:20:00Z",
                expiresAt: "2026-03-26T10:22:00Z",
                ttlSeconds: 120,
                selected: false
            ),
            ClientSnapshot(
                platform: "android",
                appId: "demo.android",
                sessionId: "session-android",
                deviceId: "device-1",
                callbackEndpoint: "http://127.0.0.1:18889/v2/client/command",
                preferredTransports: [.httpCallback],
                usbmuxdHint: nil,
                lastSeenAt: "2026-03-26T10:20:00Z",
                expiresAt: "2026-03-26T10:22:00Z",
                ttlSeconds: 120,
                selected: false
            ),
        ]

        XCTAssertThrowsError(
            try LogsStreamClientResolver.resolve(from: clients, deviceID: "device-1", appID: nil, sessionID: nil)
        )
    }
}
