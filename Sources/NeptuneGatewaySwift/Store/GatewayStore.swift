import Foundation

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

struct GatewayMetricsSnapshot: Sendable, Equatable {
    let ingestAcceptedTotal: Int
    let sourceCount: Int
    let droppedOverflow: Int
    let totalRecords: Int
}

struct LogQuery: Sendable {
    var limit: Int = 200
    var beforeId: Int64?
    var afterId: Int64?
    var platform: String?
    var appId: String?
    var sessionId: String?
    var level: String?
    var contains: String?
    var since: Date?
    var until: Date?
}

actor GatewayStore {
    private var nextID: Int64 = 1
    private var records: [LogRecord] = []
    private var ingestAcceptedTotal = 0
    private var droppedOverflow = 0
    private var lastSeenBySource: [SourceKey: SourceSnapshot] = [:]
    private let formatter = ISO8601DateFormatter()

    init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func ingest(_ ingestRecords: [IngestLogRecord]) -> Int {
        for record in ingestRecords {
            let stored = LogRecord(
                id: nextID,
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
            nextID += 1
            records.append(stored)
            lastSeenBySource[
                SourceKey(
                    platform: stored.platform,
                    appId: stored.appId,
                    sessionId: stored.sessionId,
                    deviceId: stored.deviceId
                )
            ] = SourceSnapshot(
                platform: stored.platform,
                appId: stored.appId,
                sessionId: stored.sessionId,
                deviceId: stored.deviceId,
                lastSeenAt: stored.timestamp
            )
        }
        ingestAcceptedTotal += ingestRecords.count
        return ingestRecords.count
    }

    func query(_ query: LogQuery) -> QueryResponse {
        let filtered = records.filter { record in
            if let beforeID = query.beforeId, record.id >= beforeID { return false }
            if let afterID = query.afterId, record.id <= afterID { return false }
            if let platform = query.platform, record.platform != platform { return false }
            if let appID = query.appId, record.appId != appID { return false }
            if let sessionID = query.sessionId, record.sessionId != sessionID { return false }
            if let level = query.level, record.level != level { return false }
            if let contains = query.contains?.lowercased(), !contains.isEmpty {
                let haystacks = [
                    record.message.lowercased(),
                    record.category.lowercased(),
                    record.source?.file?.lowercased() ?? "",
                    record.source?.function?.lowercased() ?? ""
                ]
                if haystacks.allSatisfy({ !$0.contains(contains) }) {
                    return false
                }
            }
            if let since = query.since, let timestamp = parseTimestamp(record.timestamp), timestamp < since {
                return false
            }
            if let until = query.until, let timestamp = parseTimestamp(record.timestamp), timestamp > until {
                return false
            }
            return true
        }

        let limited = Array(filtered.prefix(query.limit))
        let nextCursor = limited.last.map { String($0.id) }
        let hasMore = filtered.count > limited.count
        return QueryResponse(records: limited, nextCursor: nextCursor, hasMore: hasMore)
    }

    func metrics() -> GatewayMetricsSnapshot {
        GatewayMetricsSnapshot(
            ingestAcceptedTotal: ingestAcceptedTotal,
            sourceCount: lastSeenBySource.count,
            droppedOverflow: droppedOverflow,
            totalRecords: records.count
        )
    }

    func sources() -> [SourceSnapshot] {
        lastSeenBySource.values.sorted {
            if $0.lastSeenAt == $1.lastSeenAt {
                return "\($0.platform)|\($0.appId)|\($0.sessionId)|\($0.deviceId)"
                    < "\($1.platform)|\($1.appId)|\($1.sessionId)|\($1.deviceId)"
            }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    func newestID() -> Int64? {
        records.last?.id
    }

    private func parseTimestamp(_ value: String) -> Date? {
        formatter.date(from: value)
    }
}

private struct SourceKey: Hashable {
    let platform: String
    let appId: String
    let sessionId: String
    let deviceId: String
}
