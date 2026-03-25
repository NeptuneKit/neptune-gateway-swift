import Foundation
import Vapor

public struct SourceInfo: Content, Sendable {
    public let sdkName: String?
    public let sdkVersion: String?
    public let file: String?
    public let function: String?
    public let line: Int?

    public init(
        sdkName: String? = nil,
        sdkVersion: String? = nil,
        file: String? = nil,
        function: String? = nil,
        line: Int? = nil
    ) {
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.file = file
        self.function = function
        self.line = line
    }
}

public struct IngestLogRecord: Content, Sendable {
    public let timestamp: String
    public let level: String
    public let message: String
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let category: String
    public let attributes: [String: String]?
    public let source: SourceInfo?

    public init(
        timestamp: String,
        level: String,
        message: String,
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        category: String,
        attributes: [String: String]? = nil,
        source: SourceInfo? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.category = category
        self.attributes = attributes
        self.source = source
    }
}

public struct LogRecord: Content, Sendable {
    public let id: Int64
    public let timestamp: String
    public let level: String
    public let message: String
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let category: String
    public let attributes: [String: String]?
    public let source: SourceInfo?

    public init(
        id: Int64,
        timestamp: String,
        level: String,
        message: String,
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        category: String,
        attributes: [String: String]? = nil,
        source: SourceInfo? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.category = category
        self.attributes = attributes
        self.source = source
    }
}

public struct QueryResponse: Content, Sendable {
    public let records: [LogRecord]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(records: [LogRecord], nextCursor: String?, hasMore: Bool) {
        self.records = records
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct IngestResponse: Content, Sendable {
    public let accepted: Int

    public init(accepted: Int) {
        self.accepted = accepted
    }
}

public struct MetricsResponse: Content, Sendable {
    public let ingestAcceptedTotal: Int
    public let sourceCount: Int
    public let droppedOverflow: Int
    public let totalRecords: Int
    public let retainedRecordCount: Int
    public let retentionMaxRecordCount: Int
    public let retentionMaxAgeSeconds: Int
    public let retentionDroppedTotal: Int

    public init(
        ingestAcceptedTotal: Int,
        sourceCount: Int,
        droppedOverflow: Int,
        totalRecords: Int,
        retainedRecordCount: Int? = nil,
        retentionMaxRecordCount: Int = 200_000,
        retentionMaxAgeSeconds: Int = 60 * 60 * 24 * 14,
        retentionDroppedTotal: Int? = nil
    ) {
        self.ingestAcceptedTotal = ingestAcceptedTotal
        self.sourceCount = sourceCount
        self.droppedOverflow = droppedOverflow
        self.totalRecords = totalRecords
        self.retainedRecordCount = retainedRecordCount ?? totalRecords
        self.retentionMaxRecordCount = retentionMaxRecordCount
        self.retentionMaxAgeSeconds = retentionMaxAgeSeconds
        self.retentionDroppedTotal = retentionDroppedTotal ?? droppedOverflow
    }
}

public struct SourceSnapshot: Codable, Sendable, Equatable {
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let lastSeenAt: String

    public init(platform: String, appId: String, sessionId: String, deviceId: String, lastSeenAt: String) {
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.lastSeenAt = lastSeenAt
    }
}

public struct SourceResponse: Content, Sendable {
    public let items: [SourceSnapshot]

    public init(items: [SourceSnapshot]) {
        self.items = items
    }
}

public struct HealthResponse: Content, Sendable {
    public let status: String
    public let version: String

    public init(status: String, version: String) {
        self.status = status
        self.version = version
    }
}

public struct DiscoveryResponse: Content, Sendable {
    public let host: String
    public let port: Int
    public let version: String

    public init(host: String, port: Int, version: String) {
        self.host = host
        self.port = port
        self.version = version
    }
}

public struct ClientRegisterRequest: Content, Sendable {
    public let platform: String
    public let appId: String
    public let sessionId: String?
    public let deviceId: String
    public let callbackEndpoint: String
    public let expiresAt: String?

    public init(
        platform: String,
        appId: String,
        sessionId: String? = nil,
        deviceId: String,
        callbackEndpoint: String,
        expiresAt: String? = nil
    ) {
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.callbackEndpoint = callbackEndpoint
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case platform
        case appId
        case sessionId
        case deviceId
        case callbackEndpoint
        case callbackUrl
        case commandUrl
        case callbackBaseUrl
        case callbackPath
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let platform = try container.decode(String.self, forKey: .platform)
        let appId = try container.decode(String.self, forKey: .appId)
        let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        let deviceId = try container.decode(String.self, forKey: .deviceId)
        let callbackBaseUrl = try container.decodeIfPresent(String.self, forKey: .callbackBaseUrl)
        let callbackPath = try container.decodeIfPresent(String.self, forKey: .callbackPath)
        let callbackFromBaseAndPath: String? = {
            guard let callbackBaseUrl else { return nil }
            guard var components = URLComponents(string: callbackBaseUrl) else { return nil }
            if let callbackPath, !callbackPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let normalizedPath = callbackPath.hasPrefix("/") ? callbackPath : "/" + callbackPath
                components.path = normalizedPath
            }
            return components.url?.absoluteString
        }()
        let callbackEndpointRaw =
            try container.decodeIfPresent(String.self, forKey: .callbackEndpoint)
            ?? container.decodeIfPresent(String.self, forKey: .callbackUrl)
            ?? container.decodeIfPresent(String.self, forKey: .commandUrl)
            ?? callbackFromBaseAndPath
        guard let callbackEndpoint = callbackEndpointRaw else {
            throw DecodingError.keyNotFound(
                CodingKeys.callbackEndpoint,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing callback endpoint fields."
                )
            )
        }
        let expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)

        self.init(
            platform: platform,
            appId: appId,
            sessionId: sessionId,
            deviceId: deviceId,
            callbackEndpoint: callbackEndpoint,
            expiresAt: expiresAt
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platform, forKey: .platform)
        try container.encode(appId, forKey: .appId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(callbackEndpoint, forKey: .callbackEndpoint)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }
}

public struct ClientSnapshot: Content, Sendable, Equatable {
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let callbackEndpoint: String
    public let lastSeenAt: String
    public let expiresAt: String
    public let ttlSeconds: Int
    public let selected: Bool

    public init(
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        callbackEndpoint: String,
        lastSeenAt: String,
        expiresAt: String,
        ttlSeconds: Int,
        selected: Bool
    ) {
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.callbackEndpoint = callbackEndpoint
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
        self.ttlSeconds = ttlSeconds
        self.selected = selected
    }
}

public struct ClientRegisterResponse: Content, Sendable {
    public let client: ClientSnapshot

    public init(client: ClientSnapshot) {
        self.client = client
    }
}

public struct ClientListResponse: Content, Sendable {
    public let items: [ClientSnapshot]

    public init(items: [ClientSnapshot]) {
        self.items = items
    }
}

public struct ClientSelector: Content, Sendable, Hashable {
    public let platform: String
    public let appId: String
    public let deviceId: String

    public init(platform: String, appId: String, deviceId: String) {
        self.platform = platform
        self.appId = appId
        self.deviceId = deviceId
    }
}

public struct ClientsSelectedRequest: Content, Sendable {
    public let items: [ClientSelector]

    public init(items: [ClientSelector]) {
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case selected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent([ClientSelector].self, forKey: .items) {
            self.items = items
            return
        }
        if let selected = try container.decodeIfPresent([ClientSelector].self, forKey: .selected) {
            self.items = selected
            return
        }
        self.items = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
    }
}

public struct ClientsSelectedResponse: Content, Sendable {
    public let items: [ClientSelector]
    public let selectedCount: Int
    public let updatedAt: String

    public init(items: [ClientSelector], selectedCount: Int, updatedAt: String) {
        self.items = items
        self.selectedCount = selectedCount
        self.updatedAt = updatedAt
    }
}

public struct GatewayCommandRequest: Content, Sendable {
    public let requestId: String
    public let command: String
    public let payload: [String: String]?
    public let timestamp: String

    public init(
        requestId: String,
        command: String,
        payload: [String: String]? = nil,
        timestamp: String
    ) {
        self.requestId = requestId
        self.command = command
        self.payload = payload
        self.timestamp = timestamp
    }
}

public struct GatewayCommandAck: Content, Sendable {
    public let requestId: String
    public let command: String
    public let status: String
    public let message: String?
    public let timestamp: String

    public init(
        requestId: String,
        command: String,
        status: String,
        message: String? = nil,
        timestamp: String
    ) {
        self.requestId = requestId
        self.command = command
        self.status = status
        self.message = message
        self.timestamp = timestamp
    }
}
