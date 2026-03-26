import XCTest
@testable import NeptuneGatewaySwift

final class GatewayCLIArgumentTests: XCTestCase {
    func testClientsListArgumentsParse() throws {
        let command = try NeptuneGatewayCommand.parseAsRoot([
            "clients", "list",
            "--gateway", "http://127.0.0.1:19999",
            "--format", "json",
        ])

        guard let clientsCommand = command as? ClientsListCommand else {
            return XCTFail("Expected ClientsListCommand.")
        }

        XCTAssertEqual(clientsCommand.gateway, "http://127.0.0.1:19999")
        XCTAssertEqual(clientsCommand.format, .json)
    }

    func testClientsListSupportsYMLAlias() throws {
        let command = try NeptuneGatewayCommand.parseAsRoot([
            "clients", "list",
            "--format", "yml",
        ])

        guard let clientsCommand = command as? ClientsListCommand else {
            return XCTFail("Expected ClientsListCommand.")
        }

        XCTAssertEqual(clientsCommand.format, .yaml)
    }

    func testClientsDefaultSubcommandParsesToList() throws {
        let command = try NeptuneGatewayCommand.parseAsRoot(["clients"])
        XCTAssertTrue(command is ClientsListCommand)
    }

    func testLogsParsesWithoutStreamFlag() throws {
        let command = try NeptuneGatewayCommand.parseAsRoot(["logs"])
        XCTAssertTrue(command is LogsCommand)
    }

    func testLogsStreamArgumentsParse() throws {
        let command = try NeptuneGatewayCommand.parseAsRoot([
            "logs", "--stream",
            "--raw",
            "--gateway", "http://127.0.0.1:19999",
            "--app-id", "demo.app",
            "--session-id", "session-1",
            "--device-id", "device-1",
        ])

        guard let streamCommand = command as? LogsCommand else {
            return XCTFail("Expected LogsCommand.")
        }

        XCTAssertTrue(streamCommand.stream)
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
