import XCTest
import XCTVapor
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
        retention: GatewayStoreConfiguration = .default
    ) throws -> Application {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        return try NeptuneGatewaySwift.makeApplication(
            environment: .testing,
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

    func testIngestThenQueryReturnsRecord() throws {
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

    func testNDJSONIngestMatchesJSONCount() throws {
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)
        try Self.ingest(app: app, body: "\(sampleRecord)\n\(sampleRecord.replacingOccurrences(of: "\"sessionId\":\"s-1\"", with: "\"sessionId\":\"s-2\""))\n", contentType: HTTPMediaType(type: "application", subType: "x-ndjson"))

        try app.test(.GET, "v2/metrics") { response in
            let payload = try response.content.decode(MetricsResponse.self)
            XCTAssertEqual(payload.ingestAcceptedTotal, 3)
            XCTAssertEqual(payload.totalRecords, 3)
        }
    }

    func testAfterIdWaitMsTimesOutWithEmptyRecords() throws {
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

    func testStorePersistsAcrossApplicationInstances() throws {
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
        let retention = GatewayStoreConfiguration(maxRecordCount: 2, maxAge: 60 * 60 * 24)
        let app = try makeApplication(retention: retention)
        defer { app.shutdown() }

        let oldRecord = sampleRecord.replacingOccurrences(of: "2026-03-23T12:00:00Z", with: "2001-01-01T00:00:00Z")

        try Self.ingest(app: app, body: oldRecord, contentType: .json)
        try Self.ingest(app: app, body: sampleRecord, contentType: .json)
        try Self.ingest(app: app, body: newerRecord, contentType: .json)

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
        let app = try makeApplication()
        defer { app.shutdown() }

        try Self.ingest(app: app, body: sampleRecord, contentType: .json)

        try app.test(.GET, "v2/metrics") { response in
            let payload = try response.content.decode(MetricsResponse.self)
            XCTAssertEqual(payload.ingestAcceptedTotal, 1)
            XCTAssertEqual(payload.totalRecords, 1)
            XCTAssertEqual(payload.retainedRecordCount, 1)
            XCTAssertEqual(payload.retentionMaxRecordCount, 200000)
            XCTAssertEqual(payload.retentionMaxAgeSeconds, 60 * 60 * 24 * 14)
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
}
