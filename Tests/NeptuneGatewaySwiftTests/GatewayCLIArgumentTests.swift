import XCTest
@testable import NeptuneGatewaySwift

final class GatewayCLIArgumentTests: XCTestCase {
    func testIOSStreamArgumentsParse() throws {
        let command = try NeptuneGatewayCommand.parseAsRoot([
            "logs", "proxy", "ios", "stream",
            "--raw",
            "--gateway", "http://127.0.0.1:19999",
            "--app-id", "demo.app",
            "--session-id", "session-1",
            "--device-id", "device-1",
        ])

        guard let streamCommand = command as? IOSStreamProxyCommand else {
            return XCTFail("Expected IOSStreamProxyCommand.")
        }

        XCTAssertTrue(streamCommand.options.raw)
        XCTAssertEqual(streamCommand.options.gateway, "http://127.0.0.1:19999")
        XCTAssertEqual(streamCommand.options.appID, "demo.app")
        XCTAssertEqual(streamCommand.options.sessionID, "session-1")
        XCTAssertEqual(streamCommand.options.deviceID, "device-1")
    }

    func testServeArgumentsParseWithMDNSFlags() throws {
        let command = try NeptuneGatewayCommand.parseAsRoot([
            "serve",
            "--host", "0.0.0.0",
            "--port", "18766",
            "--no-mdns",
            "--advertise-host", "linhey.local",
            "--mdns-service-name", "gateway-dev",
            "--mdns-service-type", "_neptune._tcp.",
            "--mdns-domain", "local.",
        ])

        guard let serveCommand = command as? ServeCommand else {
            return XCTFail("Expected ServeCommand.")
        }

        XCTAssertEqual(serveCommand.host, "0.0.0.0")
        XCTAssertEqual(serveCommand.port, 18766)
        XCTAssertFalse(serveCommand.mdns)
        XCTAssertEqual(serveCommand.advertiseHost, "linhey.local")
        XCTAssertEqual(serveCommand.mdnsServiceName, "gateway-dev")
        XCTAssertEqual(serveCommand.mdnsServiceType, "_neptune._tcp.")
        XCTAssertEqual(serveCommand.mdnsDomain, "local.")
    }
}
