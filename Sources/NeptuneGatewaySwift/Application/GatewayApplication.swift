import Foundation
import Vapor

public enum NeptuneGatewayVersion {
    public static let current = "2.0.0-alpha.1"
}

private struct GatewayStoreKey: StorageKey {
    typealias Value = GatewayStore
}

private struct GatewayWebSocketHubKey: StorageKey {
    typealias Value = GatewayWebSocketHub
}

private struct GatewayClientRegistryKey: StorageKey {
    typealias Value = GatewayClientRegistry
}

private struct GatewayMessageBusKey: StorageKey {
    typealias Value = GatewayMessageBus
}

private struct GatewayDiscoveryRuntimeConfigurationKey: StorageKey {
    typealias Value = GatewayDiscoveryRuntimeConfiguration
}

private struct GatewayDiscoveryRuntimeConfiguration: Sendable {
    let advertiseHost: String?

    init(advertiseHost: String?) {
        let normalized = advertiseHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.advertiseHost = (normalized?.isEmpty == false) ? normalized : nil
    }
}

public enum NeptuneGatewaySwiftApp {
    public static func makeApplication(
        environment: Environment = .development,
        hostname: String = "127.0.0.1",
        port: Int = 18765,
        advertiseHost: String? = nil,
        storageURL: URL? = nil,
        storeConfiguration: GatewayStoreConfiguration = .default,
        webSocketConfiguration: GatewayWebSocketConfiguration = .default
    ) throws -> Application {
        let app = Application(environment)
        app.http.server.configuration.hostname = hostname
        app.http.server.configuration.port = port
        try configure(
            app,
            advertiseHost: advertiseHost,
            storageURL: storageURL,
            storeConfiguration: storeConfiguration,
            webSocketConfiguration: webSocketConfiguration
        )
        return app
    }

    public static func configure(
        _ app: Application,
        advertiseHost: String? = nil,
        storageURL: URL? = nil,
        storeConfiguration: GatewayStoreConfiguration = .default,
        webSocketConfiguration: GatewayWebSocketConfiguration = .default
    ) throws {
        configureCORS(on: app)
        app.storage[GatewayDiscoveryRuntimeConfigurationKey.self] = GatewayDiscoveryRuntimeConfiguration(
            advertiseHost: advertiseHost
        )
        let store = try GatewayStore(storageURL: storageURL, configuration: storeConfiguration)
        let clientRegistry = GatewayClientRegistry()
        let hub = GatewayWebSocketHub(configuration: webSocketConfiguration)
        let messageBus = GatewayMessageBus(
            adapters: [
                WebSocketAdapter(),
                USBMuxdHTTPAdapter(timeout: webSocketConfiguration.commandCallbackTimeout),
                HTTPCallbackAdapter(timeout: webSocketConfiguration.commandCallbackTimeout),
            ]
        )
        hub.configureCommandPipeline(
            resolveRecipients: { target in
                let selected = await clientRegistry.selectedOnlineClients(matching: target)
                return selected.map { snapshot in
                    GatewayBusClient(
                        recipientID: [snapshot.platform, snapshot.appId, snapshot.deviceId].joined(separator: "|"),
                        platform: snapshot.platform,
                        appId: snapshot.appId,
                        sessionId: snapshot.sessionId,
                        deviceId: snapshot.deviceId,
                        callbackEndpoint: snapshot.callbackEndpoint,
                        preferredTransports: snapshot.preferredTransports,
                        usbmuxdHint: snapshot.usbmuxdHint
                    )
                }
            },
            messageBus: messageBus
        )

        app.storage[GatewayStoreKey.self] = store
        app.storage[GatewayClientRegistryKey.self] = clientRegistry
        app.storage[GatewayWebSocketHubKey.self] = hub
        app.storage[GatewayMessageBusKey.self] = messageBus
        app.lifecycle.use(
            GatewayClientRegistryCleanupLifecycleHandler(
                registry: clientRegistry,
                interval: 30
            )
        )
        try registerRoutes(on: app)
    }

    private static func configureCORS(on app: Application) {
        let configuration = CORSMiddleware.Configuration(
            allowedOrigin: .all,
            allowedMethods: [.GET, .POST, .PUT, .OPTIONS],
            allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
        )
        app.middleware.use(CORSMiddleware(configuration: configuration))
    }

    private static func registerRoutes(on app: Application) throws {
        app.post("v2", "logs:ingest") { req async throws -> Response in
            let previousNewestID = try await req.gatewayStore.newestID()
            let ingestRecords = try decodeIngestRecords(from: req)
            let accepted = try await req.gatewayStore.ingest(ingestRecords)
            if accepted > 0 {
                let insertedRecords = try await req.gatewayStore.query(
                    LogQuery(
                        limit: accepted,
                        beforeId: nil,
                        afterId: previousNewestID,
                        platform: nil,
                        appId: nil,
                        sessionId: nil,
                        level: nil,
                        contains: nil,
                        since: nil,
                        until: nil
                    )
                ).records
                req.gatewayWebSocketHub.publishLogRecords(insertedRecords)
            }
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

        app.post("v2", "clients:register") { req async throws -> ClientRegisterResponse in
            let payload = try req.content.decode(ClientRegisterRequest.self)
            let snapshot = try await req.gatewayClientRegistry.register(payload)
            return ClientRegisterResponse(client: snapshot)
        }

        app.get("v2", "clients") { req async throws -> ClientListResponse in
            ClientListResponse(items: await req.gatewayClientRegistry.listClients())
        }

        app.put("v2", "clients:selected") { req async throws -> ClientsSelectedResponse in
            let payload = try req.content.decode(ClientsSelectedRequest.self)
            return try await req.gatewayClientRegistry.replaceSelected(with: payload.items)
        }

        app.get("v2", "health") { _ async throws -> HealthResponse in
            HealthResponse(status: "ok", version: NeptuneGatewayVersion.current)
        }

        app.get("v2", "gateway", "discovery") { req async throws -> DiscoveryResponse in
            DiscoveryResponse(
                host: resolveDiscoveryHost(for: req),
                port: req.application.http.server.configuration.port,
                version: NeptuneGatewayVersion.current
            )
        }

        app.webSocket("v2", "ws") { req, webSocket in
            let clientID = req.gatewayWebSocketHub.connect(webSocket)
            webSocket.onText { _, text in
                req.gatewayWebSocketHub.handleText(text, from: clientID)
            }
            webSocket.onClose.whenComplete { _ in
                req.gatewayWebSocketHub.disconnect(clientID)
            }
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

    private static func resolveDiscoveryHost(for req: Request) -> String {
        if let advertiseHost = req.gatewayDiscoveryRuntimeConfiguration.advertiseHost {
            return advertiseHost
        }

        if let host = hostFromHeader(req.headers.first(name: .host)) {
            return host
        }

        let configuredHost = req.application.http.server.configuration.hostname
        if configuredHost == "0.0.0.0" || configuredHost == "::" || configuredHost == "[::]" || configuredHost.isEmpty {
            return "127.0.0.1"
        }
        return configuredHost
    }

    private static func hostFromHeader(_ rawHost: String?) -> String? {
        guard let rawHost = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHost.isEmpty else {
            return nil
        }

        let candidate = rawHost.contains("://") ? rawHost : "http://\(rawHost)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return nil
        }
        return host
    }
}

private extension Request {
    var gatewayStore: GatewayStore {
        guard let store = application.storage[GatewayStoreKey.self] else {
            fatalError("GatewayStore not configured")
        }
        return store
    }

    var gatewayWebSocketHub: GatewayWebSocketHub {
        guard let hub = application.storage[GatewayWebSocketHubKey.self] else {
            fatalError("GatewayWebSocketHub not configured")
        }
        return hub
    }

    var gatewayClientRegistry: GatewayClientRegistry {
        guard let registry = application.storage[GatewayClientRegistryKey.self] else {
            fatalError("GatewayClientRegistry not configured")
        }
        return registry
    }

    var gatewayMessageBus: GatewayMessageBus {
        guard let messageBus = application.storage[GatewayMessageBusKey.self] else {
            fatalError("GatewayMessageBus not configured")
        }
        return messageBus
    }

    var gatewayDiscoveryRuntimeConfiguration: GatewayDiscoveryRuntimeConfiguration {
        guard let configuration = application.storage[GatewayDiscoveryRuntimeConfigurationKey.self] else {
            return GatewayDiscoveryRuntimeConfiguration(advertiseHost: nil)
        }
        return configuration
    }
}

private struct GatewayClientRegistryCleanupLifecycleHandler: LifecycleHandler {
    let registry: GatewayClientRegistry
    let interval: TimeInterval

    func didBoot(_ application: Application) throws {
        let interval = max(1, Int64(self.interval.rounded()))
        let task = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                await registry.cleanupExpired()
            }
        }

        application.lifecycle.use(
            GatewayClientRegistryCleanupCancellationLifecycleHandler(task: task)
        )
    }
}

private struct GatewayClientRegistryCleanupCancellationLifecycleHandler: LifecycleHandler {
    let task: Task<Void, Never>

    func shutdown(_ application: Application) {
        task.cancel()
    }
}
