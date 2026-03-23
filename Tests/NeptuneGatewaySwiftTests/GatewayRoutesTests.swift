import XCTest
import XCTVapor
@testable import NeptuneGatewaySwift

final class GatewayRoutesTests: XCTestCase {
    private let sampleRecord = """
    {"timestamp":"2026-03-23T12:00:00Z","level":"info","message":"boot ok","platform":"ios","appId":"demo.app","sessionId":"s-1","deviceId":"d-1","category":"lifecycle","attributes":{"screen":"home"},"source":{"sdkName":"sdk","sdkVersion":"0.1.0","file":"App.swift","function":"boot()","line":12}}
    """

    func testHealthEndpointReturns200() throws {
        let app = try NeptuneGatewaySwift.makeApplication(environment: .testing)
        defer { app.shutdown() }

        try app.test(.GET, "v2/health") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(try response.content.decode(HealthResponse.self).status, "ok")
        }
    }

    func testLogsEndpointReturnsRecordsField() throws {
        let app = try NeptuneGatewaySwift.makeApplication(environment: .testing)
        defer { app.shutdown() }

        try app.test(.GET, "v2/logs") { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertNotNil(payload.records)
            XCTAssertEqual(payload.records.count, 0)
        }
    }

    func testIngestThenQueryReturnsRecord() throws {
        let app = try NeptuneGatewaySwift.makeApplication(environment: .testing)
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

    func testPlatformFilterReturnsMatchingRecordsOnly() throws {
        let app = try NeptuneGatewaySwift.makeApplication(environment: .testing)
        defer { app.shutdown() }

        let androidRecord = sampleRecord.replacingOccurrences(of: "\"platform\":\"ios\"", with: "\"platform\":\"android\"")
            .replacingOccurrences(of: "\"message\":\"boot ok\"", with: "\"message\":\"android boot\"")

        try ingest(app: app, body: sampleRecord, contentType: .json)
        try ingest(app: app, body: androidRecord, contentType: .json)

        try app.test(.GET, "v2/logs?platform=ios") { response in
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.map(\.platform), ["ios"])
            XCTAssertEqual(payload.records.map(\.message), ["boot ok"])
        }
    }

    func testNDJSONIngestMatchesJSONCount() throws {
        let app = try NeptuneGatewaySwift.makeApplication(environment: .testing)
        defer { app.shutdown() }

        try ingest(app: app, body: sampleRecord, contentType: .json)
        try ingest(app: app, body: "\(sampleRecord)\n\(sampleRecord.replacingOccurrences(of: "\"sessionId\":\"s-1\"", with: "\"sessionId\":\"s-2\""))\n", contentType: HTTPMediaType(type: "application", subType: "x-ndjson"))

        try app.test(.GET, "v2/metrics") { response in
            let payload = try response.content.decode(MetricsResponse.self)
            XCTAssertEqual(payload.ingestAcceptedTotal, 3)
            XCTAssertEqual(payload.totalRecords, 3)
        }
    }

    func testAfterIdWaitMsTimesOutWithEmptyRecords() throws {
        let app = try NeptuneGatewaySwift.makeApplication(environment: .testing)
        defer { app.shutdown() }

        try ingest(app: app, body: sampleRecord, contentType: .json)

        let start = Date()
        try app.test(.GET, "v2/logs?afterId=1&waitMs=150") { response in
            let payload = try response.content.decode(QueryResponse.self)
            XCTAssertEqual(payload.records.count, 0)
            XCTAssertFalse(payload.hasMore)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
    }

    private func ingest(app: Application, body: String, contentType: HTTPMediaType) throws {
        try app.test(.POST, "v2/logs:ingest", beforeRequest: { request in
            request.headers.contentType = contentType
            request.body = .init(string: body)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .accepted)
        })
    }
}
