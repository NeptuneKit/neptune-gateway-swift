import XCTest
@testable import NeptuneGatewaySwift

final class GatewayMDNSConfigurationTests: XCTestCase {
    func testParseEnabledDefaultsToTrue() {
        XCTAssertTrue(GatewayMDNSConfiguration.parseEnabled(from: nil))
        XCTAssertTrue(GatewayMDNSConfiguration.parseEnabled(from: ""))
        XCTAssertTrue(GatewayMDNSConfiguration.parseEnabled(from: "invalid"))
    }

    func testParseEnabledUnderstandsBooleanStrings() {
        XCTAssertTrue(GatewayMDNSConfiguration.parseEnabled(from: "true"))
        XCTAssertTrue(GatewayMDNSConfiguration.parseEnabled(from: "on"))
        XCTAssertTrue(GatewayMDNSConfiguration.parseEnabled(from: "1"))

        XCTAssertFalse(GatewayMDNSConfiguration.parseEnabled(from: "false"))
        XCTAssertFalse(GatewayMDNSConfiguration.parseEnabled(from: "off"))
        XCTAssertFalse(GatewayMDNSConfiguration.parseEnabled(from: "0"))
    }

    func testConfigurationNormalizesTypeAndDomain() {
        let config = GatewayMDNSConfiguration(
            enabled: true,
            serviceType: "_neptune._tcp",
            domain: "local",
            serviceName: "gateway-dev"
        )

        XCTAssertEqual(config.serviceType, "_neptune._tcp.")
        XCTAssertEqual(config.domain, "local.")
        XCTAssertEqual(config.serviceName, "gateway-dev")
    }
}
