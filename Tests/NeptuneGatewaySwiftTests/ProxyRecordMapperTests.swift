import XCTest
@testable import NeptuneGatewaySwift

final class ProxyRecordMapperTests: XCTestCase {
    func testAndroidLogcatLineMapsToIngestRecord() {
        let fixedCurrentDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 3, day: 23, hour: 0, minute: 0, second: 0)
        )!
        let defaults = ProxyRecordDefaults(
            platform: .android,
            appID: "demo.app",
            sessionID: "session-1",
            deviceID: "device-1"
        )
        let mapper = ProxyRecordMapper(
            platform: .android,
            defaults: defaults,
            nowProvider: { fixedCurrentDate }
        )

        let record = mapper.map(line: "03-23 12:34:56.789 I/ActivityManager(1234): Boot completed")

        XCTAssertEqual(record.platform, "android")
        XCTAssertEqual(record.appId, "demo.app")
        XCTAssertEqual(record.sessionId, "session-1")
        XCTAssertEqual(record.deviceId, "device-1")
        XCTAssertEqual(record.level, "info")
        XCTAssertEqual(record.category, "proxy")
        XCTAssertEqual(record.message, "Boot completed")
        XCTAssertEqual(record.attributes?["raw"], "03-23 12:34:56.789 I/ActivityManager(1234): Boot completed")
        XCTAssertTrue(record.timestamp.hasPrefix("2026-03-23T12:34:56"))
    }

    func testUnparseableLineFallsBackToInfoProxyRecord() {
        let fixedCurrentDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 3, day: 23, hour: 0, minute: 0, second: 0)
        )!
        let defaults = ProxyRecordDefaults(
            platform: .ios,
            appID: "proxy.ios",
            sessionID: "session-ios",
            deviceID: "device-ios"
        )
        let mapper = ProxyRecordMapper(
            platform: .ios,
            defaults: defaults,
            nowProvider: { fixedCurrentDate }
        )

        let record = mapper.map(line: "unexpected plain text without structure")

        XCTAssertEqual(record.level, "info")
        XCTAssertEqual(record.message, "unexpected plain text without structure")
        XCTAssertEqual(record.category, "proxy")
        XCTAssertTrue(record.timestamp.contains("T"))
    }
}
