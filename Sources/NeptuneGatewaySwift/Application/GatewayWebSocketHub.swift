import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOWebSocket
import Vapor
import WebSocketKit

public struct GatewayWebSocketConfiguration: Sendable, Equatable {
    public var heartbeatInterval: TimeInterval
    public var heartbeatTimeout: TimeInterval
    public var commandSummaryDelay: TimeInterval
    public var commandCallbackTimeout: TimeInterval

    public init(
        heartbeatInterval: TimeInterval = 15,
        heartbeatTimeout: TimeInterval = 45,
        commandSummaryDelay: TimeInterval = 10,
        commandCallbackTimeout: TimeInterval = 3
    ) {
        self.heartbeatInterval = max(0, heartbeatInterval)
        self.heartbeatTimeout = max(0, heartbeatTimeout)
        self.commandSummaryDelay = max(0, commandSummaryDelay)
        self.commandCallbackTimeout = max(0.1, commandCallbackTimeout)
    }

    public static let `default` = GatewayWebSocketConfiguration()
}

enum GatewayWSRole: String, Sendable {
    case inspector
    case sdk
    case unknown
}

struct GatewayWSClientTarget: Codable, Sendable {
    let platforms: [String]?
    let appIds: [String]?
    let sessionIds: [String]?
    let deviceIds: [String]?
}

struct GatewayWSClientContext: Codable, Sendable {
    let clientId: String
    let role: String
    let platform: String?
    let appId: String?
    let sessionId: String?
    let deviceId: String?
}

private extension GatewayBusClient {
    var context: GatewayWSClientContext {
        GatewayWSClientContext(
            clientId: recipientID,
            role: GatewayWSRole.sdk.rawValue,
            platform: platform,
            appId: appId,
            sessionId: sessionId,
            deviceId: deviceId
        )
    }
}

private struct GatewayWSInboundMessage: Decodable {
    let type: String
    let requestId: String?
    let commandId: String?
    let role: String?
    let platform: String?
    let appId: String?
    let sessionId: String?
    let deviceId: String?
    let command: JSONValue?
    let payload: JSONValue?
    let data: JSONValue?
    let message: String?
    let target: GatewayWSClientTarget?
    let record: LogRecord?
}

private struct GatewayWSCommandAcceptedAck: Encodable {
    let type: String = "ack"
    let requestId: String?
    let commandId: String
    let accepted: Bool
    let delivered: Int
}

private struct GatewayWSCommandAckEvent: Encodable {
    let type: String = "event.command_ack"
    let requestId: String?
    let commandId: String
    let command: String
    let status: String
    let message: String?
    let timestamp: String
    let client: GatewayWSClientContext
}

private struct GatewayWSCommandSummaryEvent: Encodable {
    let type: String = "event.command_summary"
    let requestId: String?
    let commandId: String
    let command: String
    let delivered: Int
    let acked: Int
    let timeout: Int
}

private struct GatewayWSErrorEvent: Encodable {
    let type: String = "error"
    let code: String
    let requestId: String?
    let commandId: String?
    let message: String
}

private struct GatewayWSLogRecordEvent: Encodable {
    let type: String = "event.log_record"
    let topic: String = "log_record"
    let topicId: Int = 101
    let record: LogRecord
}

typealias GatewayCommandRecipientsResolver = @Sendable (GatewayWSClientTarget?) async -> [GatewayBusClient]

final class GatewayWebSocketHub: @unchecked Sendable {
    private struct Client {
        let socket: WebSocket
        var role: GatewayWSRole
        var platform: String?
        var appId: String?
        var sessionId: String?
        var deviceId: String?
        var heartbeatNonce: UInt64
        var heartbeatTask: Scheduled<Void>?

        func context(clientID: UUID) -> GatewayWSClientContext {
            GatewayWSClientContext(
                clientId: clientID.uuidString,
                role: role.rawValue,
                platform: platform,
                appId: appId,
                sessionId: sessionId,
                deviceId: deviceId
            )
        }
    }

    private struct ClientSnapshot {
        let id: UUID
        let socket: WebSocket
        let role: GatewayWSRole
        let context: GatewayWSClientContext
    }

    private struct PendingCommand {
        let commandId: String
        let requestId: String?
        let command: String
        let inspectorID: UUID
        let deliveredRecipientIDs: Set<String>
        var ackedRecipientIDs: Set<String>
        var summaryTask: Scheduled<Void>?
    }

    private enum GatewayWSErrorCode: String {
        case invalidPayload = "invalid_payload"
        case invalidTarget = "invalid_target"
        case unsupportedCommand = "unsupported_command"
        case forbiddenRole = "forbidden_role"
    }

    private let lock = NIOLock()
    private var clients: [UUID: Client] = [:]
    private var pendingCommands: [String: PendingCommand] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let configuration: GatewayWebSocketConfiguration
    private var resolveRecipients: GatewayCommandRecipientsResolver?
    private var messageBus: GatewayMessageBus?

    init(configuration: GatewayWebSocketConfiguration = .default) {
        self.configuration = configuration
    }

    func configureCommandPipeline(
        resolveRecipients: @escaping GatewayCommandRecipientsResolver,
        messageBus: GatewayMessageBus
    ) {
        lock.withLockVoid {
            self.resolveRecipients = resolveRecipients
            self.messageBus = messageBus
        }
    }

    @discardableResult
    func connect(_ socket: WebSocket) -> UUID {
        let clientID = UUID()
        lock.withLockVoid {
            clients[clientID] = Client(
                socket: socket,
                role: .unknown,
                platform: nil,
                appId: nil,
                sessionId: nil,
                deviceId: nil,
                heartbeatNonce: 0,
                heartbeatTask: nil
            )
        }
        refreshHeartbeatMonitor(for: clientID)
        return clientID
    }

    func disconnect(_ clientID: UUID) {
        lock.withLockVoid {
            guard let client = clients.removeValue(forKey: clientID) else {
                return
            }

            client.heartbeatTask?.cancel()

            let pendingIDs = pendingCommands.compactMap { commandID, state in
                state.inspectorID == clientID ? commandID : nil
            }
            for commandID in pendingIDs {
                pendingCommands.removeValue(forKey: commandID)?.summaryTask?.cancel()
            }
        }
    }

    func handleText(_ text: String, from clientID: UUID) {
        guard let payload = text.data(using: .utf8) else {
            sendError(
                .invalidPayload,
                "Invalid UTF-8 message payload.",
                to: clientID,
                requestId: nil,
                commandId: nil
            )
            return
        }

        let inbound: GatewayWSInboundMessage
        do {
            inbound = try decoder.decode(GatewayWSInboundMessage.self, from: payload)
        } catch {
            sendError(
                .invalidPayload,
                "Invalid JSON payload.",
                to: clientID,
                requestId: nil,
                commandId: nil
            )
            return
        }

        switch inbound.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hello":
            handleHello(inbound, from: clientID)
        case "heartbeat":
            handleHeartbeat(inbound, from: clientID)
        case "command.send":
            handleCommandSend(inbound, from: clientID)
        case "event.log_record":
            handleLogRecordRelay(inbound, from: clientID)
        default:
            sendError(
                .unsupportedCommand,
                "Unsupported ws message type '\(inbound.type)'.",
                to: clientID,
                requestId: inbound.requestId,
                commandId: inbound.commandId
            )
        }
    }

    func publishLogRecords(_ records: [LogRecord]) {
        guard !records.isEmpty else {
            return
        }

        let recipients = snapshotClients().filter { $0.role == .inspector }
        for record in records {
            let event = GatewayWSLogRecordEvent(record: record)
            recipients.forEach { send(event, to: $0.socket) }
        }
    }

    private func handleHello(_ message: GatewayWSInboundMessage, from clientID: UUID) {
        guard let roleRaw = normalizeText(message.role),
              let role = GatewayWSRole(rawValue: roleRaw.lowercased()),
              role != .unknown else {
            sendError(
                .invalidPayload,
                "Invalid or missing hello role.",
                to: clientID,
                requestId: message.requestId,
                commandId: message.commandId
            )
            return
        }

        let updated = lock.withLock { () -> Bool in
            guard var current = clients[clientID] else {
                return false
            }
            current.role = role
            current.platform = normalizeText(message.platform)
            current.appId = normalizeText(message.appId)
            current.sessionId = normalizeText(message.sessionId)
            current.deviceId = normalizeText(message.deviceId)
            clients[clientID] = current
            return true
        }

        guard updated else {
            return
        }

        refreshHeartbeatMonitor(for: clientID)
    }

    private func handleHeartbeat(_ message: GatewayWSInboundMessage, from clientID: UUID) {
        guard let role = snapshotClient(clientID)?.role, role != .unknown else {
            sendError(
                .invalidPayload,
                "Client must send hello before heartbeat.",
                to: clientID,
                requestId: message.requestId,
                commandId: message.commandId
            )
            return
        }

        refreshHeartbeatMonitor(for: clientID)
    }

    private func handleCommandSend(_ message: GatewayWSInboundMessage, from clientID: UUID) {
        guard let sender = snapshotClient(clientID) else {
            return
        }
        guard sender.role == .inspector else {
            sendError(
                .forbiddenRole,
                "Only inspector clients can send commands.",
                to: clientID,
                requestId: message.requestId,
                commandId: message.commandId
            )
            return
        }

        if let target = message.target, !target.hasAnyCondition {
            sendError(
                .invalidTarget,
                "Command target must include at least one non-empty condition.",
                to: clientID,
                requestId: message.requestId,
                commandId: message.commandId
            )
            return
        }

        let rawCommand = message.command ?? message.payload ?? message.data ?? message.message.map(JSONValue.string)
        guard let command = Self.extractCommand(from: rawCommand), command == "ping" else {
            sendError(
                .unsupportedCommand,
                "Unsupported command. v2 currently supports only 'ping'.",
                to: clientID,
                requestId: message.requestId,
                commandId: message.commandId
            )
            return
        }

        let commandId = normalizeText(message.commandId)
            ?? normalizeText(message.requestId)
            ?? UUID().uuidString
        let requestId = normalizeText(message.requestId)

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.processCommandSend(
                sender: sender,
                target: message.target,
                command: command,
                commandId: commandId,
                requestId: requestId
            )
        }
    }

    private func handleLogRecordRelay(_ message: GatewayWSInboundMessage, from clientID: UUID) {
        guard let sender = snapshotClient(clientID) else {
            return
        }
        guard sender.role == .sdk else {
            sendError(
                .forbiddenRole,
                "Only sdk clients can publish log records.",
                to: clientID,
                requestId: message.requestId,
                commandId: message.commandId
            )
            return
        }
        guard let record = message.record else {
            sendError(
                .invalidPayload,
                "event.log_record payload missing record.",
                to: clientID,
                requestId: message.requestId,
                commandId: message.commandId
            )
            return
        }
        publishLogRecords([record])
    }

    private func processCommandSend(
        sender: ClientSnapshot,
        target: GatewayWSClientTarget?,
        command: String,
        commandId: String,
        requestId: String?
    ) async {
        guard let resolver = lock.withLock({ resolveRecipients }) else {
            sendError(
                .invalidPayload,
                "Command pipeline is not configured.",
                to: sender.id,
                requestId: requestId,
                commandId: commandId
            )
            return
        }

        let recipients = await resolver(target)
        let deliveredRecipientIDs = Set(recipients.map(\.recipientID))

        lock.withLockVoid {
            pendingCommands[commandId] = PendingCommand(
                commandId: commandId,
                requestId: requestId,
                command: command,
                inspectorID: sender.id,
                deliveredRecipientIDs: deliveredRecipientIDs,
                ackedRecipientIDs: [],
                summaryTask: nil
            )
        }

        let summaryTask: Scheduled<Void> = sender.socket.eventLoop.scheduleTask(
            in: Self.delay(from: configuration.commandSummaryDelay)
        ) { [weak self] in
            guard let self else {
                return
            }
            self.finishCommandSummary(commandId: commandId)
        }

        lock.withLockVoid {
            pendingCommands[commandId]?.summaryTask = summaryTask
        }

        send(
            GatewayWSCommandAcceptedAck(
                requestId: requestId,
                commandId: commandId,
                accepted: true,
                delivered: recipients.count
            ),
            to: sender.socket
        )

        guard !recipients.isEmpty else {
            return
        }

        guard let messageBus = lock.withLock({ messageBus }) else {
            return
        }

        let request = BusEnvelope(
            requestId: requestId ?? commandId,
            command: command,
            payload: nil,
            timestamp: Self.iso8601Now()
        )

        Task { [weak self] in
            guard let self else {
                return
            }
            _ = await messageBus.dispatch(request, to: recipients) { client, ack in
                self.recordCallbackAck(
                    commandId: commandId,
                    recipient: client,
                    ack: ack
                )
            }
        }
    }

    private func recordCallbackAck(
        commandId: String,
        recipient: GatewayBusClient,
        ack: BusAck
    ) {
        guard let pending = acknowledgeCommand(commandId: commandId, recipientID: recipient.recipientID) else {
            return
        }

        guard let inspector = snapshotClient(pending.inspectorID) else {
            return
        }

        send(
            GatewayWSCommandAckEvent(
                requestId: pending.requestId,
                commandId: pending.commandId,
                command: pending.command,
                status: Self.ackStatus(from: ack.status),
                message: normalizeText(ack.message),
                timestamp: normalizeText(ack.timestamp) ?? Self.iso8601Now(),
                client: recipient.context
            ),
            to: inspector.socket
        )
    }

    private func acknowledgeCommand(commandId: String, recipientID: String) -> PendingCommand? {
        lock.withLock {
            guard var state = pendingCommands[commandId] else {
                return nil
            }
            guard state.deliveredRecipientIDs.contains(recipientID) else {
                return nil
            }
            guard state.ackedRecipientIDs.insert(recipientID).inserted else {
                return nil
            }
            pendingCommands[commandId] = state
            return state
        }
    }

    private func finishCommandSummary(commandId: String) {
        let summary = lock.withLock { () -> PendingCommand? in
            guard let state = pendingCommands.removeValue(forKey: commandId) else {
                return nil
            }
            state.summaryTask?.cancel()
            return state
        }

        guard let summary else {
            return
        }

        let delivered = summary.deliveredRecipientIDs.count
        let acked = summary.ackedRecipientIDs.count
        let timeout = max(0, delivered - acked)

        guard let inspector = snapshotClient(summary.inspectorID) else {
            return
        }

        send(
            GatewayWSCommandSummaryEvent(
                requestId: summary.requestId,
                commandId: summary.commandId,
                command: summary.command,
                delivered: delivered,
                acked: acked,
                timeout: timeout
            ),
            to: inspector.socket
        )
    }

    private func sendError(
        _ code: GatewayWSErrorCode,
        _ message: String,
        to clientID: UUID,
        requestId: String?,
        commandId: String?
    ) {
        guard let client = snapshotClient(clientID) else {
            return
        }

        send(
            GatewayWSErrorEvent(
                code: code.rawValue,
                requestId: requestId,
                commandId: commandId,
                message: message
            ),
            to: client.socket
        )
    }

    private func refreshHeartbeatMonitor(for clientID: UUID) {
        guard let snapshot = lock.withLock({ () -> (socket: WebSocket, nonce: UInt64)? in
            guard var current = clients[clientID] else {
                return nil
            }
            current.heartbeatNonce &+= 1
            let nonce = current.heartbeatNonce
            current.heartbeatTask?.cancel()
            clients[clientID] = current
            return (current.socket, nonce)
        }) else {
            return
        }

        let task = snapshot.socket.eventLoop.scheduleTask(in: Self.delay(from: configuration.heartbeatTimeout)) { [weak self] in
            guard let self else {
                return
            }
            self.expireHeartbeat(clientID: clientID, expectedNonce: snapshot.nonce)
        }

        lock.withLockVoid {
            guard var current = clients[clientID] else {
                task.cancel()
                return
            }
            guard current.heartbeatNonce == snapshot.nonce else {
                task.cancel()
                return
            }
            current.heartbeatTask = task
            clients[clientID] = current
        }
    }

    private func expireHeartbeat(clientID: UUID, expectedNonce: UInt64) {
        let socket = lock.withLock { () -> WebSocket? in
            guard var client = clients[clientID], client.heartbeatNonce == expectedNonce else {
                return nil
            }
            clients.removeValue(forKey: clientID)
            client.heartbeatTask?.cancel()

            let pendingIDs = pendingCommands.compactMap { commandID, state in
                state.inspectorID == clientID ? commandID : nil
            }
            for commandID in pendingIDs {
                pendingCommands.removeValue(forKey: commandID)?.summaryTask?.cancel()
            }

            return client.socket
        }

        socket?.close(code: WebSocketErrorCode.goingAway, promise: nil)
    }

    private func snapshotClient(_ clientID: UUID) -> ClientSnapshot? {
        lock.withLock {
            guard let client = clients[clientID] else {
                return nil
            }
            return ClientSnapshot(
                id: clientID,
                socket: client.socket,
                role: client.role,
                context: client.context(clientID: clientID)
            )
        }
    }

    private func snapshotClients() -> [ClientSnapshot] {
        lock.withLock {
            clients.map { clientID, client in
                ClientSnapshot(
                    id: clientID,
                    socket: client.socket,
                    role: client.role,
                    context: client.context(clientID: clientID)
                )
            }
        }
    }

    private static func delay(from seconds: TimeInterval) -> TimeAmount {
        let clamped = max(0, seconds)
        let nanoseconds = Int64((clamped * 1_000_000_000).rounded())
        return .nanoseconds(nanoseconds)
    }

    private static func ackStatus(from raw: String?) -> String {
        guard let normalized = normalizeText(raw)?.lowercased() else {
            return "ok"
        }
        return normalized == "error" ? "error" : "ok"
    }

    private static func extractCommand(from value: JSONValue?) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case .string(let raw):
            return normalizeText(raw)?.lowercased()
        case .object(let object):
            if let commandValue = object["command"], let command = extractCommand(from: commandValue) {
                return command
            }
            if let nameValue = object["name"], let command = extractCommand(from: nameValue) {
                return command
            }
            return nil
        default:
            return nil
        }
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func send<T: Encodable>(_ payload: T, to socket: WebSocket) {
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            return
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return
        }

        socket.eventLoop.execute {
            socket.send(text)
        }
    }
}

private extension GatewayWSClientTarget {
    var hasAnyCondition: Bool {
        Self.hasAnyValue(platforms)
            || Self.hasAnyValue(appIds)
            || Self.hasAnyValue(sessionIds)
            || Self.hasAnyValue(deviceIds)
    }

    private static func hasAnyValue(_ values: [String]?) -> Bool {
        guard let values else {
            return false
        }
        return values.contains { value in
            normalizeText(value) != nil
        }
    }
}

private func normalizeText(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }
}
