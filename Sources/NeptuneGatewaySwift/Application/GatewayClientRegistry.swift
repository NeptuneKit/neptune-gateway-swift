import Foundation
import Vapor

actor GatewayClientRegistry {
    private struct ClientKey: Hashable {
        let platform: String
        let appId: String
        let deviceId: String
    }

    private struct RegisteredClient {
        let key: ClientKey
        let sessionId: String
        let callbackEndpoint: String
        let preferredTransports: [ClientTransport]
        let usbmuxdHint: USBMuxdHint?
        let lastSeenAt: Date
        let expiresAt: Date
    }

    private struct SelectionState {
        var keys: Set<ClientKey>
        var updatedAt: Date
    }

    private let ttlSeconds: TimeInterval
    private var clients: [ClientKey: RegisteredClient] = [:]
    private var selection = SelectionState(keys: [], updatedAt: .distantPast)

    init(ttlSeconds: TimeInterval = 120) {
        self.ttlSeconds = max(1, ttlSeconds)
    }

    func register(_ request: ClientRegisterRequest, now: Date = Date()) throws -> ClientSnapshot {
        let key = try normalizedKey(
            platform: request.platform,
            appId: request.appId,
            deviceId: request.deviceId
        )
        let sessionId = optional(request.sessionId) ?? "unknown"
        let endpoint = try normalizedEndpoint(request.callbackEndpoint)
        let preferredTransports = try normalizedPreferredTransports(request.preferredTransports)
        let usbmuxdHint = try normalizedUSBMuxdHint(request.usbmuxdHint, preferredTransports: preferredTransports)
        let expiresAt = normalizedExpiration(from: request.expiresAt, now: now)

        let registered = RegisteredClient(
            key: key,
            sessionId: sessionId,
            callbackEndpoint: endpoint,
            preferredTransports: preferredTransports,
            usbmuxdHint: usbmuxdHint,
            lastSeenAt: now,
            expiresAt: expiresAt
        )
        clients[key] = registered

        purgeExpired(now: now)
        return snapshot(from: clients[key] ?? registered, now: now)
    }

    func listClients(now: Date = Date()) -> [ClientSnapshot] {
        purgeExpired(now: now)
        return clients.values
            .map { snapshot(from: $0, now: now) }
            .sorted { lhs, rhs in
                if lhs.selected != rhs.selected {
                    return lhs.selected && !rhs.selected
                }
                if lhs.platform != rhs.platform {
                    return lhs.platform < rhs.platform
                }
                if lhs.appId != rhs.appId {
                    return lhs.appId < rhs.appId
                }
                if lhs.deviceId != rhs.deviceId {
                    return lhs.deviceId < rhs.deviceId
                }
                return lhs.sessionId < rhs.sessionId
            }
    }

    func replaceSelected(with selectors: [ClientSelector], now: Date = Date()) throws -> ClientsSelectedResponse {
        let normalized = try selectors.map { selector in
            try normalizedKey(
                platform: selector.platform,
                appId: selector.appId,
                deviceId: selector.deviceId
            )
        }

        selection = SelectionState(keys: Set(normalized), updatedAt: now)

        let items = normalized.map {
            ClientSelector(platform: $0.platform, appId: $0.appId, deviceId: $0.deviceId)
        }
        return ClientsSelectedResponse(
            items: items,
            selectedCount: items.count,
            updatedAt: Self.iso8601(now)
        )
    }

    func selectedOnlineClients(matching target: GatewayWSClientTarget?, now: Date = Date()) -> [ClientSnapshot] {
        purgeExpired(now: now)

        return clients.values
            .filter { selection.keys.contains($0.key) }
            .filter { client in
                guard let target else {
                    return true
                }
                return Self.matches(client: client, target: target)
            }
            .map { snapshot(from: $0, now: now) }
    }

    func cleanupExpired(now: Date = Date()) {
        purgeExpired(now: now)
    }

    private func snapshot(from client: RegisteredClient, now: Date) -> ClientSnapshot {
        let ttl = max(0, Int(client.expiresAt.timeIntervalSince(now)))
        return ClientSnapshot(
            platform: client.key.platform,
            appId: client.key.appId,
            sessionId: client.sessionId,
            deviceId: client.key.deviceId,
            callbackEndpoint: client.callbackEndpoint,
            preferredTransports: client.preferredTransports,
            usbmuxdHint: client.usbmuxdHint,
            lastSeenAt: Self.iso8601(client.lastSeenAt),
            expiresAt: Self.iso8601(client.expiresAt),
            ttlSeconds: ttl,
            selected: selection.keys.contains(client.key)
        )
    }

    private func purgeExpired(now: Date) {
        clients = clients.filter { _, client in
            client.expiresAt > now
        }
    }

    private func normalizedKey(platform: String, appId: String, deviceId: String) throws -> ClientKey {
        ClientKey(
            platform: try required(platform, name: "platform"),
            appId: try required(appId, name: "appId"),
            deviceId: try required(deviceId, name: "deviceId")
        )
    }

    private func normalizedEndpoint(_ value: String) throws -> String {
        let endpoint = try required(value, name: "callbackEndpoint")
        guard
            let url = URL(string: endpoint),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host?.isEmpty == false
        else {
            throw Abort(.badRequest, reason: "callbackEndpoint must be a valid absolute http(s) URL.")
        }
        return endpoint
    }

    private func normalizedPreferredTransports(_ transports: [ClientTransport]?) throws -> [ClientTransport] {
        guard let transports else {
            return [.httpCallback]
        }

        guard !transports.isEmpty else {
            throw Abort(.badRequest, reason: "preferredTransports must not be empty.")
        }

        var ordered: [ClientTransport] = []
        for transport in transports where !ordered.contains(transport) {
            ordered.append(transport)
        }
        return ordered.isEmpty ? [.httpCallback] : ordered
    }

    private func normalizedUSBMuxdHint(
        _ hint: USBMuxdHint?,
        preferredTransports: [ClientTransport]
    ) throws -> USBMuxdHint? {
        if let hint, hint.deviceID <= 0 {
            throw Abort(.badRequest, reason: "usbmuxdHint.deviceID must be greater than 0.")
        }
        if preferredTransports.contains(.usbmuxdHTTP), hint == nil {
            throw Abort(.badRequest, reason: "usbmuxdHint is required when preferredTransports includes usbmuxdHTTP.")
        }
        return hint
    }

    private func required(_ value: String, name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "\(name) must not be empty.")
        }
        return trimmed
    }

    private func optional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedExpiration(from iso8601: String?, now: Date) -> Date {
        let fallback = now.addingTimeInterval(ttlSeconds)
        guard let iso8601 else {
            return fallback
        }
        guard let parsed = Self.parseISO8601(iso8601) else {
            return fallback
        }
        let maxExpires = now.addingTimeInterval(ttlSeconds)
        return min(max(parsed, now), maxExpires)
    }

    private static func matches(client: RegisteredClient, target: GatewayWSClientTarget) -> Bool {
        if let platforms = normalizedSet(target.platforms), !platforms.contains(client.key.platform) {
            return false
        }
        if let appIds = normalizedSet(target.appIds), !appIds.contains(client.key.appId) {
            return false
        }
        if let sessionIds = normalizedSet(target.sessionIds), !sessionIds.contains(client.sessionId) {
            return false
        }
        if let deviceIds = normalizedSet(target.deviceIds), !deviceIds.contains(client.key.deviceId) {
            return false
        }
        return true
    }

    private static func normalizedSet(_ values: [String]?) -> Set<String>? {
        guard let values else {
            return nil
        }
        let normalized = values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return normalized.isEmpty ? nil : Set(normalized)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
