import Foundation
import Vapor

public enum NeptuneGatewayVersion {
    public static let current = "2.0.0-alpha.1"
}

public enum NeptuneGatewaySwiftApp {
    public static func makeApplication(
        environment: Environment = .development,
        hostname: String = "127.0.0.1",
        port: Int = 18765
    ) throws -> Application {
        let app = Application(environment)
        app.http.server.configuration.hostname = hostname
        app.http.server.configuration.port = port
        try configure(app)
        return app
    }

    public static func configure(_ app: Application) throws {
        try registerRoutes(on: app)
    }

    private static func registerRoutes(on app: Application) throws {
        app.post("v2", "logs:ingest") { req async throws -> Response in
            let accepted = try acceptedCount(from: req)
            let response = IngestResponse(accepted: accepted)
            return try await response.encodeResponse(status: .accepted, for: req)
        }

        app.get("v2", "logs") { req async throws -> QueryResponse in
            _ = req.query[String.self, at: "limit"]
            _ = req.query[String.self, at: "beforeId"]
            _ = req.query[String.self, at: "afterId"]
            _ = req.query[String.self, at: "platform"]
            _ = req.query[String.self, at: "appId"]
            _ = req.query[String.self, at: "sessionId"]
            _ = req.query[String.self, at: "level"]
            _ = req.query[String.self, at: "contains"]
            _ = req.query[String.self, at: "since"]
            _ = req.query[String.self, at: "until"]
            _ = req.query[String.self, at: "format"]
            _ = req.query[String.self, at: "waitMs"]
            return QueryResponse(records: [], nextCursor: nil, hasMore: false)
        }

        app.get("v2", "metrics") { _ async throws -> MetricsResponse in
            MetricsResponse(ingestAcceptedTotal: 0, sourceCount: 0)
        }

        app.get("v2", "sources") { _ async throws -> SourceResponse in
            SourceResponse(items: [])
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

    private static func acceptedCount(from req: Request) throws -> Int {
        let contentType = req.headers.contentType?.description.lowercased() ?? "application/json"
        let body = req.body.data ?? ByteBuffer()
        let data = Data(buffer: body)

        guard !data.isEmpty else {
            return 0
        }

        let decoder = JSONDecoder()

        if contentType.contains("application/x-ndjson") {
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for line in lines {
                guard let lineData = line.data(using: .utf8) else {
                    throw Abort(.badRequest, reason: "Invalid NDJSON payload.")
                }
                _ = try decoder.decode(IngestLogRecord.self, from: lineData)
            }
            return lines.count
        }

        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [Any] {
            for item in array {
                let itemData = try JSONSerialization.data(withJSONObject: item)
                _ = try decoder.decode(IngestLogRecord.self, from: itemData)
            }
            return array.count
        }

        _ = try decoder.decode(IngestLogRecord.self, from: data)
        return 1
    }
}
