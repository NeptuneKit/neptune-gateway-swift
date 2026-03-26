import ArgumentParser
import Foundation
import Vapor

public struct NeptuneGatewayCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "neptune",
        abstract: "Neptune v2 gateway server and log proxy tools.",
        subcommands: [
            ServeCommand.self,
            ClientsCommand.self,
            LogsCommand.self,
        ],
        defaultSubcommand: ServeCommand.self
    )

    public init() {}
}

public struct ClientsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "clients",
        abstract: "Client registry utilities.",
        subcommands: [ClientsListCommand.self],
        defaultSubcommand: ClientsListCommand.self
    )

    public init() {}
}

public struct ClientsListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List online clients from the gateway."
    )

    @ArgumentParser.Option(name: .long, help: "Gateway base URL.")
    var gateway: String = "http://127.0.0.1:18765"

    @ArgumentParser.Option(name: .long, help: "Output format.")
    var format: ClientOutputFormat = .text

    public init() {}

    public mutating func run() throws {
        let response = try GatewayClientsFetcher(gatewayBaseURL: gateway).listClients()
        let output = switch format {
        case .text: ClientListRenderer.renderText(response.items)
        case .json: try ClientListRenderer.renderJSON(response)
        case .yaml: try ClientListRenderer.renderYAML(response)
        }
        FileHandle.standardOutput.write(Data(output.utf8))
    }
}

public struct ServeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the Neptune v2 gateway server."
    )

    @ArgumentParser.Option(name: .long, help: "Gateway host.")
    var host: String = ProcessInfo.processInfo.environment["NEPTUNE_HOST"] ?? "127.0.0.1"

    @ArgumentParser.Option(name: .long, help: "Gateway port.")
    var port: Int = Int(ProcessInfo.processInfo.environment["NEPTUNE_PORT"] ?? "18765") ?? 18765

    @ArgumentParser.Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Enable mDNS publish for gateway discovery."
    )
    var mdns: Bool = GatewayMDNSConfiguration.parseEnabled(
        from: ProcessInfo.processInfo.environment["NEPTUNE_MDNS_ENABLED"]
    )

    @ArgumentParser.Option(name: .long, help: "mDNS service name.")
    var mdnsServiceName: String = ProcessInfo.processInfo.environment["NEPTUNE_MDNS_SERVICE_NAME"]
        ?? GatewayMDNSConfiguration.defaultServiceName

    @ArgumentParser.Option(name: .long, help: "mDNS service type.")
    var mdnsServiceType: String = ProcessInfo.processInfo.environment["NEPTUNE_MDNS_SERVICE_TYPE"]
        ?? "_neptune._tcp."

    @ArgumentParser.Option(name: .long, help: "mDNS service domain.")
    var mdnsDomain: String = ProcessInfo.processInfo.environment["NEPTUNE_MDNS_DOMAIN"] ?? "local."

    @ArgumentParser.Option(
        name: .long,
        help: "Advertised host returned by /v2/gateway/discovery."
    )
    var advertiseHost: String = ProcessInfo.processInfo.environment["NEPTUNE_ADVERTISE_HOST"] ?? ""

    public init() {}

    public mutating func validate() throws {
        guard (1...65535).contains(port) else {
            throw ValidationError("--port must be between 1 and 65535")
        }
    }

    public mutating func run() throws {
        let executable = CommandLine.arguments.first ?? "neptune"
        let environmentName = ProcessInfo.processInfo.environment["VAPOR_ENV"] ?? "development"
        let environment = Environment(name: environmentName, arguments: [executable, "serve"])
        let app = try NeptuneGatewaySwift.makeApplication(
            environment: environment,
            hostname: host,
            port: port,
            advertiseHost: normalizeAdvertiseHost(advertiseHost)
        )
        let mdnsPublisher = GatewayMDNSPublisher(
            configuration: GatewayMDNSConfiguration(
                enabled: mdns,
                serviceType: mdnsServiceType,
                domain: mdnsDomain,
                serviceName: mdnsServiceName
            ),
            port: port,
            log: { message in
                app.logger.info("\(message)")
            }
        )
        mdnsPublisher.startIfEnabled()
        defer { mdnsPublisher.stop() }
        try app.run()
    }

    private func normalizeAdvertiseHost(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public struct LogsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Stream and proxy platform logs into the Neptune gateway."
    )

    @ArgumentParser.Flag(name: .long, help: "Deprecated no-op. `logs` defaults to streaming behavior.")
    var stream = false

    @OptionGroup var options: ProxyCommonOptions
    @ArgumentParser.Argument(parsing: .captureForPassthrough) var passthrough: [String] = []

    public init() {}

    public mutating func run() throws {
        guard let deviceID = options.deviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceID.isEmpty else {
            try GatewayLogsPushTailer.streamAll(
                gatewayBaseURL: options.gateway,
                appID: options.appID,
                sessionID: options.sessionID
            )
            return
        }

        let clients = try GatewayClientsFetcher(gatewayBaseURL: options.gateway).listClients().items
        let selectedClient = try LogsStreamClientResolver.resolve(
            from: clients,
            deviceID: deviceID,
            appID: options.appID,
            sessionID: options.sessionID
        )

        let platform = selectedClient.platform.lowercased()
        let (runnerPlatform, baseCommand): (ProxyPlatform, [String]) = switch platform {
        case "ios":
            (.ios, ["/usr/bin/log", "stream"])
        case "android":
            (.android, ["/usr/bin/env", "adb", "logcat"])
        case "harmony":
            (.harmony, ["/usr/bin/env", "hdc", "hilog"])
        default:
            throw ValidationError("Unsupported platform '\(selectedClient.platform)' for deviceId \(selectedClient.deviceId).")
        }

        var resolvedOptions = options
        if resolvedOptions.appID == nil {
            resolvedOptions.appID = selectedClient.appId
        }
        if resolvedOptions.sessionID == nil {
            resolvedOptions.sessionID = selectedClient.sessionId
        }
        resolvedOptions.deviceID = selectedClient.deviceId

        try GatewayProxyRunner.run(
            configuration: .init(
                platform: runnerPlatform,
                command: baseCommand + passthrough,
                options: resolvedOptions
            )
        )
    }
}

public struct ProxyCommonOptions: ParsableArguments, Sendable {
    @ArgumentParser.Flag(name: .long, help: "Print raw proxied lines without reporting to the gateway.")
    public var raw = false

    @ArgumentParser.Option(name: .long, help: "Gateway base URL.")
    public var gateway: String = "http://127.0.0.1:18765"

    @ArgumentParser.Option(name: .long, help: "Override appId for normalized records.")
    public var appID: String?

    @ArgumentParser.Option(name: .long, help: "Override sessionId for normalized records.")
    public var sessionID: String?

    @ArgumentParser.Option(name: .long, help: "Override deviceId for normalized records.")
    public var deviceID: String?

    public init() {}
}

enum LogsStreamClientResolver {
    static func resolve(
        from clients: [ClientSnapshot],
        deviceID: String,
        appID: String?,
        sessionID: String?
    ) throws -> ClientSnapshot {
        let normalizedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppID = appID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)

        let matched = clients.filter { client in
            guard client.deviceId == normalizedDeviceID else { return false }
            if let normalizedAppID, !normalizedAppID.isEmpty, client.appId != normalizedAppID {
                return false
            }
            if let normalizedSessionID, !normalizedSessionID.isEmpty, client.sessionId != normalizedSessionID {
                return false
            }
            return true
        }

        guard !matched.isEmpty else {
            throw ValidationError(
                "No online client matches deviceId=\(normalizedDeviceID)"
                + (normalizedAppID?.isEmpty == false ? ", appId=\(normalizedAppID!)" : "")
                + (normalizedSessionID?.isEmpty == false ? ", sessionId=\(normalizedSessionID!)" : "")
                + "."
            )
        }

        let uniquePlatforms = Set(matched.map { $0.platform.lowercased() })
        guard uniquePlatforms.count == 1 else {
            let platformDesc = uniquePlatforms.sorted().joined(separator: ", ")
            throw ValidationError(
                "DeviceId \(normalizedDeviceID) matches multiple platforms (\(platformDesc)). "
                + "Please add --app-id/--session-id to disambiguate."
            )
        }

        return matched[0]
    }
}

enum GatewayLogsPushTailer {
    private struct OutboundMessage: Encodable {
        let type: String
        let role: String?
        let appId: String?
        let sessionId: String?
        let deviceId: String?
    }

    private struct InboundMessage: Decodable {
        let type: String
        let deviceId: String?
    }

    private static let length = 200

    static func streamAll(
        gatewayBaseURL: String,
        appID: String?,
        sessionID: String?
    ) throws {
        let wsURL = try makeWebSocketURL(from: gatewayBaseURL)
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: wsURL)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try send(
            OutboundMessage(type: "hello", role: "inspector", appId: appID, sessionId: sessionID, deviceId: nil),
            to: task
        )

        let heartbeatTimer = DispatchSource.makeTimerSource(queue: .global())
        heartbeatTimer.schedule(deadline: .now() + 10, repeating: 10)
        heartbeatTimer.setEventHandler {
            try? send(OutboundMessage(type: "heartbeat", role: nil, appId: nil, sessionId: nil, deviceId: nil), to: task)
        }
        heartbeatTimer.resume()
        defer { heartbeatTimer.cancel() }

        var cursor: Int64?
        while true {
            let payload = try receiveString(from: task)
            guard let data = payload.data(using: .utf8) else { continue }
            guard let inbound = try? JSONDecoder().decode(InboundMessage.self, from: data) else { continue }
            guard inbound.type == "logs.updated" else { continue }

            let response = try fetch(
                gatewayBaseURL: gatewayBaseURL,
                cursor: cursor,
                appID: appID,
                sessionID: sessionID
            )
            for record in response.records {
                let line = "\(record.timestamp)\t\(record.level)\t\(record.platform)\t[\(record.appId)] \(record.deviceId)\t\(record.message)\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            }
            if let newestID = response.records.map(\.id).max() {
                cursor = newestID
            }
        }
    }

    private static func makeWebSocketURL(from gatewayBaseURL: String) throws -> URL {
        guard var components = URLComponents(string: gatewayBaseURL) else {
            throw ValidationError("Invalid gateway URL: \(gatewayBaseURL)")
        }
        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            components.scheme = "ws"
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "v2", "ws"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let wsURL = components.url else {
            throw ValidationError("Invalid gateway URL: \(gatewayBaseURL)")
        }
        return wsURL
    }

    private static func fetch(
        gatewayBaseURL: String,
        cursor: Int64?,
        appID: String?,
        sessionID: String?
    ) throws -> QueryResponse {
        guard var components = URLComponents(string: gatewayBaseURL) else {
            throw ValidationError("Invalid gateway URL: \(gatewayBaseURL)")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "v2", "logs"].filter { !$0.isEmpty }.joined(separator: "/")
        var queryItems: [URLQueryItem] = [
            .init(name: "format", value: "json"),
            .init(name: "length", value: String(length)),
        ]
        if let cursor {
            queryItems.append(.init(name: "cursor", value: String(cursor)))
        }
        if let appID, !appID.isEmpty {
            queryItems.append(.init(name: "appId", value: appID))
        }
        if let sessionID, !sessionID.isEmpty {
            queryItems.append(.init(name: "sessionId", value: sessionID))
        }
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw ValidationError("Invalid gateway URL: \(gatewayBaseURL)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8

        let semaphore = DispatchSemaphore(value: 0)
        var resultError: Error?
        var statusCode = -1
        var responseData = Data()
        URLSession.shared.dataTask(with: request) { data, response, error in
            resultError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            responseData = data ?? Data()
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let resultError {
            throw resultError
        }
        guard (200...299).contains(statusCode) else {
            let body = String(decoding: responseData.prefix(500), as: UTF8.self)
            throw ValidationError("Gateway /v2/logs returned HTTP \(statusCode): \(body)")
        }
        return try JSONDecoder().decode(QueryResponse.self, from: responseData)
    }

    private static func send<T: Encodable>(_ payload: T, to task: URLSessionWebSocketTask) throws {
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("Failed to encode websocket payload.")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var resultError: Error?
        task.send(.string(text)) { error in
            resultError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let resultError {
            throw resultError
        }
    }

    private static func receiveString(from task: URLSessionWebSocketTask) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var resultError: Error?
        var outputText: String?
        task.receive { result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    outputText = text
                case .data(let data):
                    outputText = String(decoding: data, as: UTF8.self)
                @unknown default:
                    outputText = nil
                }
            case .failure(let error):
                resultError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let resultError {
            throw resultError
        }
        guard let outputText else {
            throw ValidationError("Received unsupported websocket message.")
        }
        return outputText
    }
}
