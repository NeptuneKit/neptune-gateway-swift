import Foundation
import GRDB

public struct GatewayStoreConfiguration: Sendable, Equatable {
    public var maxRecordCount: Int
    public var maxAge: TimeInterval

    public init(maxRecordCount: Int = 200_000, maxAge: TimeInterval = 60 * 60 * 24 * 14) {
        self.maxRecordCount = max(0, maxRecordCount)
        self.maxAge = max(0, maxAge)
    }

    public static let `default` = GatewayStoreConfiguration()
}

struct GatewayMetricsSnapshot: Sendable, Equatable {
    let ingestAcceptedTotal: Int
    let sourceCount: Int
    let droppedOverflow: Int
    let totalRecords: Int
    let retainedRecordCount: Int
    let retentionMaxRecordCount: Int
    let retentionMaxAgeSeconds: Int
    let retentionDroppedTotal: Int
}

struct LogQuery: Sendable {
    var cursor: Int64?
    var length: Int?
    var platform: String?
    var appId: String?
    var sessionId: String?
    var level: String?
    var contains: String?
    var since: Date?
    var until: Date?
}

actor GatewayStore {
    private struct InsertedRecord {
        let id: Int64
        let record: IngestLogRecord
    }

    private let database: SQLiteGatewayDatabase
    private let configuration: GatewayStoreConfiguration

    init(
        storageURL: URL? = nil,
        configuration: GatewayStoreConfiguration = .default
    ) throws {
        let resolvedURL = storageURL ?? Self.makeDefaultStorageURL()
        self.database = try SQLiteGatewayDatabase(storageURL: resolvedURL)
        self.configuration = configuration
    }

    func ingest(_ ingestRecords: [IngestLogRecord]) throws -> Int {
        guard !ingestRecords.isEmpty else {
            return 0
        }

        try database.transaction { db in
            for record in ingestRecords {
                try database.insert(record, db: db)
            }

            try database.incrementMetadata("ingestAcceptedTotal", by: ingestRecords.count, db: db)
            try pruneIfNeeded(db: db)
            try database.deleteOrphanSources(db: db)
        }

        return ingestRecords.count
    }

    func query(_ query: LogQuery) throws -> QueryResponse {
        try database.fetchRecords(query: query)
    }

    func metrics() throws -> GatewayMetricsSnapshot {
        try database.metrics(
            retentionMaxRecordCount: configuration.maxRecordCount,
            retentionMaxAgeSeconds: Int(configuration.maxAge)
        )
    }

    func sources() throws -> [SourceSnapshot] {
        try database.fetchSources()
    }

    func newestID() throws -> Int64? {
        try database.newestRecordID()
    }

    private func pruneIfNeeded(db: Database) throws {
        if configuration.maxAge > 0 {
            let cutoff = Date().addingTimeInterval(-configuration.maxAge).timeIntervalSince1970
            let droppedByAge = try database.deleteRecords(olderThan: cutoff, db: db)
            if droppedByAge > 0 {
                try database.incrementMetadata("retentionDroppedTotal", by: droppedByAge, db: db)
            }
        }

        let overflow = try database.recordCount(db: db) - configuration.maxRecordCount
        if overflow > 0 {
            let droppedByOverflow = try database.deleteOldestRecords(limit: overflow, db: db)
            if droppedByOverflow > 0 {
                try database.incrementMetadata("retentionDroppedTotal", by: droppedByOverflow, db: db)
            }
        }
    }

    private static func makeDefaultStorageURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neptune-gateway", isDirectory: true)
        return directory
            .appendingPathComponent("gateway-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func recordMatchesQuery(_ query: LogQuery, insertedRecord: InsertedRecord) -> Bool {
        let record = insertedRecord.record

        if let cursor = query.cursor, insertedRecord.id <= cursor {
            return false
        }
        if let platform = query.platform, record.platform != platform {
            return false
        }
        if let appID = query.appId, record.appId != appID {
            return false
        }
        if let sessionID = query.sessionId, record.sessionId != sessionID {
            return false
        }
        if let level = query.level, record.level != level {
            return false
        }
        if let contains = query.contains?.lowercased(), !contains.isEmpty {
            let searchable = [
                record.message,
                record.category,
                record.source?.file ?? "",
                record.source?.function ?? ""
            ].map { $0.lowercased() }
            guard searchable.contains(where: { $0.contains(contains) }) else {
                return false
            }
        }

        let timestamp = parsedTimestamp(record.timestamp)
        if let since = query.since, let timestamp, timestamp < since {
            return false
        }
        if let until = query.until, let timestamp, timestamp > until {
            return false
        }

        return true
    }

    private func parsedTimestamp(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private final class SQLiteGatewayDatabase {
    private let queue: DatabaseQueue
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let timestampParser: ISO8601DateFormatter

    init(storageURL: URL) throws {
        timestampParser = ISO8601DateFormatter()
        timestampParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }

        queue = try DatabaseQueue(path: storageURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(queue)
    }

    func transaction<T>(_ body: (Database) throws -> T) throws -> T {
        try queue.write(body)
    }

    func insert(_ record: IngestLogRecord) throws {
        try queue.inDatabase { db in
            try insert(record, db: db)
        }
    }

    func fetchRecords(query: LogQuery) throws -> QueryResponse {
        var sql = """
        SELECT
            id, timestamp, level, message, platform, app_id, session_id, device_id, category,
            attributes_json, source_sdk_name, source_sdk_version, source_file, source_function, source_line
        FROM records
        WHERE 1 = 1
        """
        var arguments = StatementArguments()

        if let cursor = query.cursor {
            sql += " AND id > @cursor"
            arguments += ["cursor": cursor]
        }
        if let platform = query.platform {
            sql += " AND platform = @platform"
            arguments += ["platform": platform]
        }
        if let appId = query.appId {
            sql += " AND app_id = @appId"
            arguments += ["appId": appId]
        }
        if let sessionId = query.sessionId {
            sql += " AND session_id = @sessionId"
            arguments += ["sessionId": sessionId]
        }
        if let level = query.level {
            sql += " AND level = @level"
            arguments += ["level": level]
        }
        if let contains = query.contains?.lowercased(), !contains.isEmpty {
            sql += """
             AND (
                instr(lower(message), @contains) > 0
                OR instr(lower(category), @contains) > 0
                OR instr(lower(COALESCE(source_file, '')), @contains) > 0
                OR instr(lower(COALESCE(source_function, '')), @contains) > 0
             )
            """
            arguments += ["contains": contains]
        }
        if let since = query.since {
            sql += " AND (timestamp_epoch IS NULL OR timestamp_epoch >= @since)"
            arguments += ["since": since.timeIntervalSince1970]
        }
        if let until = query.until {
            sql += " AND (timestamp_epoch IS NULL OR timestamp_epoch <= @until)"
            arguments += ["until": until.timeIntervalSince1970]
        }

        sql += " ORDER BY id ASC"
        if let length = query.length {
            sql += " LIMIT @length"
            arguments += ["length": length + 1]
        }

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments)
        }
        let records = try rows.map(decodeRecord)
        let limited: [LogRecord]
        let hasMore: Bool
        if let length = query.length {
            limited = Array(records.prefix(length))
            hasMore = records.count > length
        } else {
            limited = records
            hasMore = false
        }
        return QueryResponse(
            records: limited,
            hasMore: hasMore
        )
    }

    func fetchSources() throws -> [SourceSnapshot] {
        try queue.read { db in
            try StoredSourceSnapshot.fetchAll(
                db,
                sql: """
                SELECT platform, app_id, session_id, device_id, last_seen_at
                FROM sources
                ORDER BY last_seen_at DESC, platform ASC, app_id ASC, session_id ASC, device_id ASC
                """
            ).map(\.snapshot)
        }
    }

    func metrics(
        retentionMaxRecordCount: Int,
        retentionMaxAgeSeconds: Int
    ) throws -> GatewayMetricsSnapshot {
        try queue.read { db in
            let ingestAcceptedTotal = try metadataInt(for: "ingestAcceptedTotal", db: db)
            let retentionDroppedTotal = try metadataInt(for: "retentionDroppedTotal", db: db)
            let totalRecords = try count(table: "records", db: db)
            let sourceCount = try count(table: "sources", db: db)

            return GatewayMetricsSnapshot(
                ingestAcceptedTotal: ingestAcceptedTotal,
                sourceCount: sourceCount,
                droppedOverflow: retentionDroppedTotal,
                totalRecords: totalRecords,
                retainedRecordCount: totalRecords,
                retentionMaxRecordCount: retentionMaxRecordCount,
                retentionMaxAgeSeconds: retentionMaxAgeSeconds,
                retentionDroppedTotal: retentionDroppedTotal
            )
        }
    }

    func newestRecordID() throws -> Int64? {
        try queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM records;")
        }
    }

    func recordCount() throws -> Int {
        try queue.read { db in
            try recordCount(db: db)
        }
    }

    func deleteRecords(olderThan cutoff: TimeInterval) throws -> Int {
        try queue.inDatabase { db in
            try deleteRecords(olderThan: cutoff, db: db)
        }
    }

    func deleteOldestRecords(limit: Int) throws -> Int {
        guard limit > 0 else {
            return 0
        }

        return try queue.inDatabase { db in
            try deleteOldestRecords(limit: limit, db: db)
        }
    }

    func deleteOrphanSources() throws {
        try queue.inDatabase { db in
            try deleteOrphanSources(db: db)
        }
    }

    func incrementMetadata(_ key: String, by delta: Int) throws {
        guard delta != 0 else {
            return
        }

        try queue.inDatabase { db in
            try incrementMetadata(key, by: delta, db: db)
        }
    }

    private func decodeRecord(from row: Row) throws -> LogRecord {
        try StoredLogRecord(row: row).record(jsonDecoder: jsonDecoder)
    }

    private func metadataInt(for key: String, db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = ?;", arguments: [key]) ?? 0
    }

    func recordCount(db: Database) throws -> Int {
        try count(table: "records", db: db)
    }

    func insert(_ record: IngestLogRecord, db: Database) throws {
        let timestampEpoch = timestampDate(for: record)?.timeIntervalSince1970
        let attributesJSON = encodedJSONString(record.attributes)

        try db.execute(
            sql: """
            INSERT INTO records (
                timestamp, timestamp_epoch, level, message, platform, app_id, session_id, device_id, category,
                attributes_json, source_sdk_name, source_sdk_version, source_file, source_function, source_line
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            arguments: [
                record.timestamp,
                timestampEpoch,
                record.level,
                record.message,
                record.platform,
                record.appId,
                record.sessionId,
                record.deviceId,
                record.category,
                attributesJSON,
                record.source?.sdkName,
                record.source?.sdkVersion,
                record.source?.file,
                record.source?.function,
                record.source?.line,
            ]
        )

        try db.execute(
            sql: """
            INSERT INTO sources (platform, app_id, session_id, device_id, last_seen_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(platform, app_id, session_id, device_id)
            DO UPDATE SET last_seen_at = excluded.last_seen_at;
            """,
            arguments: [
                record.platform,
                record.appId,
                record.sessionId,
                record.deviceId,
                record.timestamp,
            ]
        )
    }

    func deleteRecords(olderThan cutoff: TimeInterval, db: Database) throws -> Int {
        try db.execute(
            sql: "DELETE FROM records WHERE timestamp_epoch IS NOT NULL AND timestamp_epoch < ?;",
            arguments: [cutoff]
        )
        return try Int.fetchOne(db, sql: "SELECT changes();") ?? 0
    }

    func deleteOldestRecords(limit: Int, db: Database) throws -> Int {
        try db.execute(
            sql: """
            DELETE FROM records
            WHERE id IN (
                SELECT id FROM records
                ORDER BY id ASC
                LIMIT ?
            );
            """,
            arguments: [limit]
        )
        return try Int.fetchOne(db, sql: "SELECT changes();") ?? 0
    }

    func deleteOrphanSources(db: Database) throws {
        try db.execute(
            sql: """
            DELETE FROM sources
            WHERE NOT EXISTS (
                SELECT 1
                FROM records
                WHERE records.platform = sources.platform
                  AND records.app_id = sources.app_id
                  AND records.session_id = sources.session_id
                  AND records.device_id = sources.device_id
            );
            """
        )
    }

    func incrementMetadata(_ key: String, by delta: Int, db: Database) throws {
        guard delta != 0 else {
            return
        }

        try db.execute(
            sql: """
            INSERT INTO metadata (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + excluded.value AS TEXT);
            """,
            arguments: [key, String(delta)]
        )
    }

    private func count(table: String, db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table);") ?? 0
    }

    private func encodedJSONString(_ attributes: [String: String]?) -> String? {
        guard let attributes else {
            return nil
        }
        guard let data = try? jsonEncoder.encode(attributes) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func timestampDate(for record: IngestLogRecord) -> Date? {
        timestampParser.date(from: record.timestamp) ?? ISO8601DateFormatter().date(from: record.timestamp)
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                timestamp_epoch REAL,
                level TEXT NOT NULL,
                message TEXT NOT NULL,
                platform TEXT NOT NULL,
                app_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                category TEXT NOT NULL,
                attributes_json TEXT,
                source_sdk_name TEXT,
                source_sdk_version TEXT,
                source_file TEXT,
                source_function TEXT,
                source_line INTEGER
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS records_filter_index
            ON records(platform, app_id, session_id, level, id);
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS records_timestamp_index
            ON records(timestamp_epoch, id);
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sources (
                platform TEXT NOT NULL,
                app_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                PRIMARY KEY (platform, app_id, session_id, device_id)
            );
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
        }
        return migrator
    }
}

private struct StoredLogRecord: FetchableRecord {
    let id: Int64
    let timestamp: String
    let level: String
    let message: String
    let platform: String
    let appId: String
    let sessionId: String
    let deviceId: String
    let category: String
    let attributesJSON: String?
    let sourceSDKName: String?
    let sourceSDKVersion: String?
    let sourceFile: String?
    let sourceFunction: String?
    let sourceLine: Int?

    init(row: Row) {
        id = row["id"]
        timestamp = row["timestamp"]
        level = row["level"]
        message = row["message"]
        platform = row["platform"]
        appId = row["app_id"]
        sessionId = row["session_id"]
        deviceId = row["device_id"]
        category = row["category"]
        attributesJSON = row["attributes_json"]
        sourceSDKName = row["source_sdk_name"]
        sourceSDKVersion = row["source_sdk_version"]
        sourceFile = row["source_file"]
        sourceFunction = row["source_function"]
        sourceLine = row["source_line"]
    }

    func record(jsonDecoder: JSONDecoder) throws -> LogRecord {
        let attributes: [String: String]?
        if let attributesJSON, !attributesJSON.isEmpty {
            guard let data = attributesJSON.data(using: .utf8) else {
                throw GatewayStoreError(message: "Invalid UTF-8 attributes payload.")
            }
            attributes = try jsonDecoder.decode([String: String].self, from: data)
        } else {
            attributes = nil
        }

        let source = SourceInfo(
            sdkName: sourceSDKName,
            sdkVersion: sourceSDKVersion,
            file: sourceFile,
            function: sourceFunction,
            line: sourceLine
        )
        let normalizedSource: SourceInfo? = if sourceSDKName != nil || sourceSDKVersion != nil || sourceFile != nil || sourceFunction != nil || sourceLine != nil {
            source
        } else {
            nil
        }

        return LogRecord(
            id: id,
            timestamp: timestamp,
            level: level,
            message: message,
            platform: platform,
            appId: appId,
            sessionId: sessionId,
            deviceId: deviceId,
            category: category,
            attributes: attributes,
            source: normalizedSource
        )
    }
}

private struct StoredSourceSnapshot: FetchableRecord {
    let platform: String
    let appId: String
    let sessionId: String
    let deviceId: String
    let lastSeenAt: String

    init(row: Row) {
        platform = row["platform"]
        appId = row["app_id"]
        sessionId = row["session_id"]
        deviceId = row["device_id"]
        lastSeenAt = row["last_seen_at"]
    }

    var snapshot: SourceSnapshot {
        SourceSnapshot(
            platform: platform,
            appId: appId,
            sessionId: sessionId,
            deviceId: deviceId,
            lastSeenAt: lastSeenAt
        )
    }
}

private struct GatewayStoreError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}
