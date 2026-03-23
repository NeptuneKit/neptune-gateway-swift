import Foundation
import Vapor

public enum NeptuneGatewayVersion {
    public static let current = "2.0.0-alpha.1"
}

private struct GatewayStoreKey: StorageKey {
    typealias Value = GatewayStore
}

public enum NeptuneGatewaySwiftApp {
    public static func makeApplication(
        environment: Environment = .development,
        hostname: String = "127.0.0.1",
        port: Int = 18765,
        storageURL: URL? = nil,
        storeConfiguration: GatewayStoreConfiguration = .default
    ) throws -> Application {
        let app = Application(environment)
        app.http.server.configuration.hostname = hostname
        app.http.server.configuration.port = port
        try configure(app, storageURL: storageURL, storeConfiguration: storeConfiguration)
        return app
    }

    public static func configure(
        _ app: Application,
        storageURL: URL? = nil,
        storeConfiguration: GatewayStoreConfiguration = .default
    ) throws {
        app.storage[GatewayStoreKey.self] = try GatewayStore(storageURL: storageURL, configuration: storeConfiguration)
        try registerRoutes(on: app)
    }

    private static func registerRoutes(on app: Application) throws {
        app.post("v2", "logs:ingest") { req async throws -> Response in
            let ingestRecords = try decodeIngestRecords(from: req)
            let accepted = try await req.gatewayStore.ingest(ingestRecords)
            let response = IngestResponse(accepted: accepted)
            return try await response.encodeResponse(status: .accepted, for: req)
        }

        app.get("v2", "logs") { req async throws -> Response in
            let query = try parseLogQuery(from: req)
            let format = req.query[String.self, at: "format"]?.lowercased() ?? "json"

            let waitMs = max(0, req.query[Int.self, at: "waitMs"] ?? 0)
            let result = try await waitForQueryIfNeeded(store: req.gatewayStore, query: query, waitMs: waitMs)

            if format == "text" {
                return textResponse(for: result)
            }

            if format == "ndjson" {
                let lines = try result.records.map { record in
                    let data = try JSONEncoder().encode(record)
                    return String(decoding: data, as: UTF8.self)
                }.joined(separator: "\n")
                let buffer = ByteBuffer(string: lines.isEmpty ? "" : lines + "\n")
                return Response(
                    status: .ok,
                    headers: HTTPHeaders([("Content-Type", "application/x-ndjson; charset=utf-8")]),
                    body: .init(buffer: buffer)
                )
            }

            return try await result.encodeResponse(for: req)
        }

        app.get("v2", "metrics") { req async throws -> MetricsResponse in
            let snapshot = try await req.gatewayStore.metrics()
            return MetricsResponse(
                ingestAcceptedTotal: snapshot.ingestAcceptedTotal,
                sourceCount: snapshot.sourceCount,
                droppedOverflow: snapshot.droppedOverflow,
                totalRecords: snapshot.totalRecords,
                retainedRecordCount: snapshot.retainedRecordCount,
                retentionMaxRecordCount: snapshot.retentionMaxRecordCount,
                retentionMaxAgeSeconds: snapshot.retentionMaxAgeSeconds,
                retentionDroppedTotal: snapshot.retentionDroppedTotal
            )
        }

        app.get("v2", "sources") { req async throws -> SourceResponse in
            SourceResponse(items: try await req.gatewayStore.sources())
        }

        app.get("v2", "health") { _ async throws -> HealthResponse in
            HealthResponse(status: "ok", version: NeptuneGatewayVersion.current)
        }

        app.get("v2", "gateway", "discovery") { req async throws -> DiscoveryResponse in
            DiscoveryResponse(
                host: req.application.http.server.configuration.hostname,
                port: req.application.http.server.configuration.port,
                version: NeptuneGatewayVersion.current
            )
        }
    }

    private static func decodeIngestRecords(from req: Request) throws -> [IngestLogRecord] {
        let contentType = req.headers.contentType?.description.lowercased() ?? "application/json"
        let body = req.body.data ?? ByteBuffer()
        let data = Data(buffer: body)

        guard !data.isEmpty else {
            return []
        }

        let decoder = JSONDecoder()

        if contentType.contains("application/x-ndjson") {
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var parsed: [IngestLogRecord] = []

            for line in lines {
                guard let lineData = line.data(using: .utf8) else {
                    throw Abort(.badRequest, reason: "Invalid NDJSON payload.")
                }
                parsed.append(try decoder.decode(IngestLogRecord.self, from: lineData))
            }
            return parsed
        }

        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [Any] {
            var parsed: [IngestLogRecord] = []
            for item in array {
                let itemData = try JSONSerialization.data(withJSONObject: item)
                parsed.append(try decoder.decode(IngestLogRecord.self, from: itemData))
            }
            return parsed
        }

        return [try decoder.decode(IngestLogRecord.self, from: data)]
    }

    private static func parseLogQuery(from req: Request) throws -> LogQuery {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func parseDate(_ name: String) throws -> Date? {
            guard let raw = req.query[String.self, at: name], !raw.isEmpty else { return nil }
            guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw Abort(.badRequest, reason: "Invalid '\(name)' date-time value.")
            }
            return date
        }

        let limit = min(max(req.query[Int.self, at: "limit"] ?? 200, 1), 1_000)

        return LogQuery(
            limit: limit,
            beforeId: req.query[Int64.self, at: "beforeId"],
            afterId: req.query[Int64.self, at: "afterId"],
            platform: req.query[String.self, at: "platform"],
            appId: req.query[String.self, at: "appId"],
            sessionId: req.query[String.self, at: "sessionId"],
            level: req.query[String.self, at: "level"],
            contains: req.query[String.self, at: "contains"],
            since: try parseDate("since"),
            until: try parseDate("until")
        )
    }

    private static func waitForQueryIfNeeded(store: GatewayStore, query: LogQuery, waitMs: Int) async throws -> QueryResponse {
        let initial = try await store.query(query)
        guard initial.records.isEmpty, waitMs > 0, query.afterId != nil else {
            return initial
        }

        _ = try await store.waitForNewerRecord(matching: query, waitMs: waitMs)
        return try await store.query(query)
    }

    private static func textResponse(for result: QueryResponse) -> Response {
        let lines = result.records.map { record in
            [
                record.timestamp,
                record.level,
                record.platform,
                record.message.replacingOccurrences(of: "\n", with: "\\n")
            ].joined(separator: "\t")
        }.joined(separator: "\n")
        let buffer = ByteBuffer(string: lines.isEmpty ? "" : lines + "\n")
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/plain; charset=utf-8")]),
            body: .init(buffer: buffer)
        )
    }
}

private extension Request {
    var gatewayStore: GatewayStore {
        guard let store = application.storage[GatewayStoreKey.self] else {
            fatalError("GatewayStore not configured")
        }
        return store
    }
}
