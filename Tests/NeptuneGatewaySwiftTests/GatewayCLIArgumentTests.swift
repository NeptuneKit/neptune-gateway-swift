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
}
