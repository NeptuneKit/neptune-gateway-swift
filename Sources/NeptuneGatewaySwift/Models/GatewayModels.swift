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

    public init(ingestAcceptedTotal: Int, sourceCount: Int, droppedOverflow: Int, totalRecords: Int) {
        self.ingestAcceptedTotal = ingestAcceptedTotal
        self.sourceCount = sourceCount
        self.droppedOverflow = droppedOverflow
        self.totalRecords = totalRecords
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
