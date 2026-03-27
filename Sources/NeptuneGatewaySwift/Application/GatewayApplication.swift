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

private struct GatewayClientLogRelayKey: StorageKey {
    typealias Value = GatewayClientLogRelay
}

private struct GatewayViewTreeStoreKey: StorageKey {
    typealias Value = GatewayViewTreeStore
}

private struct GatewayRuntimeStatsKey: StorageKey {
    typealias Value = GatewayRuntimeStats
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
        // Raw inspector payload can exceed Vapor's small default body limit.
        app.routes.defaultMaxBodySize = "2mb"
        app.storage[GatewayDiscoveryRuntimeConfigurationKey.self] = GatewayDiscoveryRuntimeConfiguration(
            advertiseHost: advertiseHost
        )
        let store = try GatewayStore(storageURL: storageURL, configuration: storeConfiguration)
        let clientRegistry = GatewayClientRegistry()
        let hub = GatewayWebSocketHub(configuration: webSocketConfiguration)
        let relay = GatewayClientLogRelay()
        let viewTreeStore = GatewayViewTreeStore()
        let runtimeStats = GatewayRuntimeStats()
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
        app.storage[GatewayClientLogRelayKey.self] = relay
        app.storage[GatewayViewTreeStoreKey.self] = viewTreeStore
        app.storage[GatewayRuntimeStatsKey.self] = runtimeStats
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
            let ingestRecords = try decodeIngestRecords(from: req)
            let accepted = ingestRecords.count
            if accepted > 0 {
                let baseID = await req.gatewayRuntimeStats.reserveSyntheticIDs(count: accepted)
                await req.gatewayRuntimeStats.incrementIngestAccepted(by: accepted)
                let emittedRecords = ingestRecords.enumerated().map { offset, record in
                    LogRecord(
                        id: baseID + Int64(offset),
                        timestamp: record.timestamp,
                        level: record.level,
                        message: record.message,
                        platform: record.platform,
                        appId: record.appId,
                        sessionId: record.sessionId,
                        deviceId: record.deviceId,
                        category: record.category,
                        attributes: record.attributes,
                        source: record.source
                    )
                }
                req.gatewayWebSocketHub.publishLogRecords(emittedRecords)
            }
            let response = IngestResponse(accepted: accepted)
            return try await response.encodeResponse(status: .accepted, for: req)
        }

        app.get("v2", "logs") { req async throws -> Response in
            let query = try parseLogQuery(from: req)
            let format = req.query[String.self, at: "format"]?.lowercased() ?? "json"
            let clients = await req.gatewayClientRegistry.listClients().filter { client in
                if let platform = query.platform, platform != client.platform {
                    return false
                }
                if let appId = query.appId, appId != client.appId {
                    return false
                }
                if let sessionId = query.sessionId, sessionId != client.sessionId {
                    return false
                }
                return true
            }
            let relayResult = await req.gatewayClientLogRelay.query(clients: clients, query: query)

            let result = relayResult.response

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

        app.post("v2", "ui-tree", "inspector") { req async throws -> Response in
            let payload = try req.content.decode(ViewTreeRawIngestRequest.self)
            guard !payload.platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !payload.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !payload.sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !payload.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw Abort(.badRequest, reason: "Missing required body fields: platform, appId, sessionId, deviceId, payload.")
            }
            await req.gatewayViewTreeStore.ingest(payload)
            return try await IngestResponse(accepted: 1).encodeResponse(status: .accepted, for: req)
        }

        app.get("v2", "ui-tree", "inspector") { req async throws -> InspectorSnapshot in
            guard let deviceId = req.query[String.self, at: "deviceId"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !deviceId.isEmpty
            else {
                throw Abort(.badRequest, reason: "Missing required query field: deviceId.")
            }
            let forceRefresh = Self.parseBooleanQueryFlag(req.query[String.self, at: "refresh"])
            let hasInspectorCache = await req.gatewayViewTreeStore.inspectorSnapshot(deviceId: deviceId) != nil
            if forceRefresh || !hasInspectorCache {
                await Self.backfillViewTreeFromClients(
                    req: req,
                    platform: nil,
                    appId: nil,
                    sessionId: nil,
                    deviceId: deviceId
                )
            }

            guard let snapshot = await req.gatewayViewTreeStore.inspectorSnapshot(deviceId: deviceId) else {
                throw Abort(.notFound, reason: "No available ui-tree inspector snapshot for requested client.")
            }
            return snapshot
        }

        app.get("v2", "ui-tree", "snapshot") { req async throws -> ViewTreeSnapshot in
            guard let platform = req.query[String.self, at: "platform"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !platform.isEmpty,
                  let appId = req.query[String.self, at: "appId"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !appId.isEmpty,
                  let sessionId = req.query[String.self, at: "sessionId"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionId.isEmpty
            else {
                throw Abort(.badRequest, reason: "Missing required query fields: platform, appId, sessionId.")
            }
            let deviceId = req.query[String.self, at: "deviceId"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let forceRefresh = Self.parseBooleanQueryFlag(req.query[String.self, at: "refresh"])
            let hasSnapshotCache = await req.gatewayViewTreeStore.snapshot(
                platform: platform,
                appId: appId,
                sessionId: sessionId,
                deviceId: deviceId
            ) != nil
            if forceRefresh || !hasSnapshotCache {
                await Self.backfillViewTreeFromClients(
                    req: req,
                    platform: platform,
                    appId: appId,
                    sessionId: sessionId,
                    deviceId: deviceId
                )
            }

            guard let snapshot = await req.gatewayViewTreeStore.snapshot(
                platform: platform,
                appId: appId,
                sessionId: sessionId,
                deviceId: deviceId
            ) else {
                throw Abort(.notFound, reason: "No available ui-tree snapshot for requested client.")
            }
            return snapshot
        }

        app.get("v2", "metrics") { req async throws -> MetricsResponse in
            let sourceCount = await req.gatewayClientRegistry.listClients().count
            return await req.gatewayRuntimeStats.snapshot(sourceCount: sourceCount)
        }

        app.get("v2", "sources") { req async throws -> SourceResponse in
            let clients = await req.gatewayClientRegistry.listClients()
            return SourceResponse(
                items: clients.map { client in
                    SourceSnapshot(
                        platform: client.platform,
                        appId: client.appId,
                        sessionId: client.sessionId,
                        deviceId: client.deviceId,
                        lastSeenAt: client.lastSeenAt
                    )
                }
            )
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

    private static func backfillViewTreeFromClients(
        req: Request,
        platform: String?,
        appId: String?,
        sessionId: String?,
        deviceId: String?
    ) async {
        func matchedTargets(from clients: [ClientSnapshot]) -> [ClientSnapshot] {
            clients.filter { client in
                if let platform, client.platform != platform { return false }
                if let appId, client.appId != appId { return false }
                if let sessionId, client.sessionId != sessionId { return false }
                if let deviceId, client.deviceId != deviceId { return false }
                return true
            }
        }

        let listedClients = await req.gatewayClientRegistry.listClients()
        let listedClientKeys = listedClients
            .map { "\($0.platform)|\($0.appId)|\($0.sessionId)|\($0.deviceId)" }
            .joined(separator: ",")
        req.logger.info("view-tree backfill listed clients=\(listedClientKeys)")
        var targets = matchedTargets(from: listedClients)
        if targets.isEmpty {
            // Client re-register and snapshot refresh may race. Retry once shortly.
            try? await Task.sleep(nanoseconds: 350_000_000)
            targets = matchedTargets(from: await req.gatewayClientRegistry.listClients())
        }
        req.logger.info("view-tree backfill start targets=\(targets.count) platform=\(platform ?? "*") appId=\(appId ?? "*") sessionId=\(sessionId ?? "*") deviceId=\(deviceId ?? "*")")

        for client in targets {
            await backfillViewTreeFromSingleClient(req: req, client: client)
        }
    }

    private static func backfillViewTreeFromSingleClient(req: Request, client: ClientSnapshot) async {
        guard let inspectorURL = inspectorEndpoint(callbackEndpoint: client.callbackEndpoint, deviceId: client.deviceId) else {
            req.logger.warning("view-tree backfill skipped: invalid inspector endpoint for \(client.platform)|\(client.appId)|\(client.deviceId) callback=\(client.callbackEndpoint)")
            return
        }

        do {
            let response = try await req.client.get(URI(string: inspectorURL))
            guard response.status == .ok else {
                req.logger.warning("view-tree backfill failed: inspector endpoint returned \(response.status.code) for \(client.platform)|\(client.appId)|\(client.deviceId) url=\(inspectorURL)")
                return
            }

            let inspector = try response.content.decode(InspectorSnapshot.self)
            guard inspector.available, let payload = inspector.payload else {
                req.logger.warning("view-tree backfill skipped: inspector unavailable for \(client.platform)|\(client.appId)|\(client.deviceId) snapshot=\(inspector.snapshotId)")
                return
            }

            let ingest = ViewTreeRawIngestRequest(
                platform: client.platform,
                appId: client.appId,
                sessionId: client.sessionId,
                deviceId: client.deviceId,
                snapshotId: inspector.snapshotId,
                capturedAt: inspector.capturedAt,
                payload: payload
            )
            await req.gatewayViewTreeStore.ingest(ingest)
            req.logger.info("view-tree backfill success for \(client.platform)|\(client.appId)|\(client.deviceId) snapshot=\(inspector.snapshotId)")
        } catch {
            req.logger.warning("view-tree backfill failed for \(client.platform)|\(client.appId)|\(client.deviceId) url=\(inspectorURL) error=\(error)")
        }
    }

    private static func inspectorEndpoint(callbackEndpoint: String, deviceId: String) -> String? {
        guard let callbackURL = URL(string: callbackEndpoint) else {
            return nil
        }
        guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/v2/ui-tree/inspector"
        components.queryItems = [URLQueryItem(name: "deviceId", value: deviceId)]
        return components.url?.absoluteString
    }

    private static func parseBooleanQueryFlag(_ rawValue: String?) -> Bool {
        guard let rawValue else {
            return false
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "1" || normalized == "true" || normalized == "yes"
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

        let length: Int?
        if let rawLength = req.query[Int.self, at: "length"], rawLength > 0 {
            length = min(rawLength, 10_000)
        } else {
            length = nil
        }

        return LogQuery(
            cursor: req.query[Int64.self, at: "cursor"],
            length: length,
            platform: req.query[String.self, at: "platform"],
            appId: req.query[String.self, at: "appId"],
            sessionId: req.query[String.self, at: "sessionId"],
            level: req.query[String.self, at: "level"],
            contains: req.query[String.self, at: "contains"],
            since: try parseDate("since"),
            until: try parseDate("until")
        )
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

    var gatewayClientLogRelay: GatewayClientLogRelay {
        guard let relay = application.storage[GatewayClientLogRelayKey.self] else {
            fatalError("GatewayClientLogRelay not configured")
        }
        return relay
    }

    var gatewayRuntimeStats: GatewayRuntimeStats {
        guard let stats = application.storage[GatewayRuntimeStatsKey.self] else {
            fatalError("GatewayRuntimeStats not configured")
        }
        return stats
    }

    var gatewayViewTreeStore: GatewayViewTreeStore {
        guard let store = application.storage[GatewayViewTreeStoreKey.self] else {
            fatalError("GatewayViewTreeStore not configured")
        }
        return store
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
