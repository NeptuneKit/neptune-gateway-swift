import Foundation
import SQLite3

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

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor GatewayStore {
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

        try database.transaction {
            for record in ingestRecords {
                try database.insert(record)
            }

            try database.incrementMetadata("ingestAcceptedTotal", by: ingestRecords.count)
            try pruneIfNeeded()
            try database.deleteOrphanSources()
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

    private func pruneIfNeeded() throws {
        if configuration.maxAge > 0 {
            let cutoff = Date().addingTimeInterval(-configuration.maxAge).timeIntervalSince1970
            let droppedByAge = try database.deleteRecords(olderThan: cutoff)
            if droppedByAge > 0 {
                try database.incrementMetadata("retentionDroppedTotal", by: droppedByAge)
            }
        }

        let overflow = try database.recordCount() - configuration.maxRecordCount
        if overflow > 0 {
            let droppedByOverflow = try database.deleteOldestRecords(limit: overflow)
            if droppedByOverflow > 0 {
                try database.incrementMetadata("retentionDroppedTotal", by: droppedByOverflow)
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
}

private final class SQLiteGatewayDatabase {
    private let db: OpaquePointer?
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let timestampParser: ISO8601DateFormatter

    init(storageURL: URL) throws {
        timestampParser = ISO8601DateFormatter()
        timestampParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var rawDB: OpaquePointer?
        let openResult = sqlite3_open_v2(
            storageURL.path,
            &rawDB,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard openResult == SQLITE_OK, let rawDB else {
            let message = rawDB.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            if let rawDB {
                sqlite3_close(rawDB)
            }
            throw SQLiteError(message: message)
        }

        self.db = rawDB

        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("""
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
        try execute("""
        CREATE INDEX IF NOT EXISTS records_filter_index
        ON records(platform, app_id, session_id, level, id);
        """)
        try execute("""
        CREATE INDEX IF NOT EXISTS records_timestamp_index
        ON records(timestamp_epoch, id);
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS sources (
            platform TEXT NOT NULL,
            app_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            PRIMARY KEY (platform, app_id, session_id, device_id)
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    func insert(_ record: IngestLogRecord) throws {
        let sql = """
        INSERT INTO records (
            timestamp, timestamp_epoch, level, message, platform, app_id, session_id, device_id, category,
            attributes_json, source_sdk_name, source_sdk_version, source_file, source_function, source_line
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(record.timestamp, to: statement, index: 1)
        try bind(timestampDate(for: record)?.timeIntervalSince1970, to: statement, index: 2)
        try bind(record.level, to: statement, index: 3)
        try bind(record.message, to: statement, index: 4)
        try bind(record.platform, to: statement, index: 5)
        try bind(record.appId, to: statement, index: 6)
        try bind(record.sessionId, to: statement, index: 7)
        try bind(record.deviceId, to: statement, index: 8)
        try bind(record.category, to: statement, index: 9)
        try bind(encodedJSONString(record.attributes), to: statement, index: 10)
        try bind(record.source?.sdkName, to: statement, index: 11)
        try bind(record.source?.sdkVersion, to: statement, index: 12)
        try bind(record.source?.file, to: statement, index: 13)
        try bind(record.source?.function, to: statement, index: 14)
        try bind(record.source?.line.map(Int64.init), to: statement, index: 15)

        try stepDone(statement)

        let sourceStatement = try prepare("""
        INSERT INTO sources (platform, app_id, session_id, device_id, last_seen_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(platform, app_id, session_id, device_id)
        DO UPDATE SET last_seen_at = excluded.last_seen_at;
        """)
        defer { sqlite3_finalize(sourceStatement) }

        try bind(record.platform, to: sourceStatement, index: 1)
        try bind(record.appId, to: sourceStatement, index: 2)
        try bind(record.sessionId, to: sourceStatement, index: 3)
        try bind(record.deviceId, to: sourceStatement, index: 4)
        try bind(record.timestamp, to: sourceStatement, index: 5)
        try stepDone(sourceStatement)
    }

    func fetchRecords(query: LogQuery) throws -> QueryResponse {
        var sql = """
        SELECT
            id, timestamp, level, message, platform, app_id, session_id, device_id, category,
            attributes_json, source_sdk_name, source_sdk_version, source_file, source_function, source_line
        FROM records
        WHERE 1 = 1
        """
        var bindings: [SQLiteBinding] = []

        if let beforeId = query.beforeId {
            sql += " AND id < ?"
            bindings.append(.int64(beforeId))
        }
        if let afterId = query.afterId {
            sql += " AND id > ?"
            bindings.append(.int64(afterId))
        }
        if let platform = query.platform {
            sql += " AND platform = ?"
            bindings.append(.text(platform))
        }
        if let appId = query.appId {
            sql += " AND app_id = ?"
            bindings.append(.text(appId))
        }
        if let sessionId = query.sessionId {
            sql += " AND session_id = ?"
            bindings.append(.text(sessionId))
        }
        if let level = query.level {
            sql += " AND level = ?"
            bindings.append(.text(level))
        }
        if let contains = query.contains?.lowercased(), !contains.isEmpty {
            sql += """
             AND (
                instr(lower(message), ?) > 0
                OR instr(lower(category), ?) > 0
                OR instr(lower(COALESCE(source_file, '')), ?) > 0
                OR instr(lower(COALESCE(source_function, '')), ?) > 0
             )
            """
            bindings.append(contentsOf: Array(repeating: .text(contains), count: 4))
        }
        if let since = query.since {
            sql += " AND (timestamp_epoch IS NULL OR timestamp_epoch >= ?)"
            bindings.append(.double(since.timeIntervalSince1970))
        }
        if let until = query.until {
            sql += " AND (timestamp_epoch IS NULL OR timestamp_epoch <= ?)"
            bindings.append(.double(until.timeIntervalSince1970))
        }

        sql += " ORDER BY id ASC LIMIT ?"
        bindings.append(.int64(Int64(query.limit + 1)))

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        var rows: [LogRecord] = []
        while true {
            let code = sqlite3_step(statement)
            switch code {
            case SQLITE_ROW:
                rows.append(try decodeRecord(from: statement))
            case SQLITE_DONE:
                let limited = Array(rows.prefix(query.limit))
                return QueryResponse(
                    records: limited,
                    nextCursor: limited.last.map { String($0.id) },
                    hasMore: rows.count > query.limit
                )
            default:
                throw sqliteError(messagePrefix: "Failed to fetch records")
            }
        }
    }

    func fetchSources() throws -> [SourceSnapshot] {
        let statement = try prepare("""
        SELECT platform, app_id, session_id, device_id, last_seen_at
        FROM sources
        ORDER BY last_seen_at DESC, platform ASC, app_id ASC, session_id ASC, device_id ASC
        """)
        defer { sqlite3_finalize(statement) }

        var items: [SourceSnapshot] = []
        while true {
            let code = sqlite3_step(statement)
            switch code {
            case SQLITE_ROW:
                items.append(
                    SourceSnapshot(
                        platform: columnString(statement, index: 0) ?? "",
                        appId: columnString(statement, index: 1) ?? "",
                        sessionId: columnString(statement, index: 2) ?? "",
                        deviceId: columnString(statement, index: 3) ?? "",
                        lastSeenAt: columnString(statement, index: 4) ?? ""
                    )
                )
            case SQLITE_DONE:
                return items
            default:
                throw sqliteError(messagePrefix: "Failed to fetch sources")
            }
        }
    }

    func metrics(
        retentionMaxRecordCount: Int,
        retentionMaxAgeSeconds: Int
    ) throws -> GatewayMetricsSnapshot {
        let ingestAcceptedTotal = try metadataInt(for: "ingestAcceptedTotal")
        let retentionDroppedTotal = try metadataInt(for: "retentionDroppedTotal")
        let totalRecords = try count(table: "records")
        let sourceCount = try count(table: "sources")

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

    func newestRecordID() throws -> Int64? {
        let statement = try prepare("SELECT MAX(id) FROM records;")
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, 0)
    }

    func recordCount() throws -> Int {
        try count(table: "records")
    }

    func deleteRecords(olderThan cutoff: TimeInterval) throws -> Int {
        let statement = try prepare("DELETE FROM records WHERE timestamp_epoch IS NOT NULL AND timestamp_epoch < ?;")
        defer { sqlite3_finalize(statement) }
        try bind(cutoff, to: statement, index: 1)
        try stepDone(statement)
        return Int(sqlite3_changes(db))
    }

    func deleteOldestRecords(limit: Int) throws -> Int {
        guard limit > 0 else {
            return 0
        }

        let statement = try prepare("""
        DELETE FROM records
        WHERE id IN (
            SELECT id FROM records
            ORDER BY id ASC
            LIMIT ?
        );
        """)
        defer { sqlite3_finalize(statement) }
        try bind(Int64(limit), to: statement, index: 1)
        try stepDone(statement)
        return Int(sqlite3_changes(db))
    }

    func deleteOrphanSources() throws {
        let statement = try prepare("""
        DELETE FROM sources
        WHERE NOT EXISTS (
            SELECT 1
            FROM records
            WHERE records.platform = sources.platform
              AND records.app_id = sources.app_id
              AND records.session_id = sources.session_id
              AND records.device_id = sources.device_id
        );
        """)
        defer { sqlite3_finalize(statement) }
        try stepDone(statement)
    }

    func incrementMetadata(_ key: String, by delta: Int) throws {
        guard delta != 0 else {
            return
        }

        let statement = try prepare("""
        INSERT INTO metadata (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + excluded.value AS TEXT);
        """)
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, index: 1)
        try bind(String(delta), to: statement, index: 2)
        try stepDone(statement)
    }

    private func decodeRecord(from statement: OpaquePointer?) throws -> LogRecord {
        let attributes: [String: String]?
        if let rawAttributes = columnString(statement, index: 9), !rawAttributes.isEmpty {
            guard let data = rawAttributes.data(using: .utf8) else {
                throw SQLiteError(message: "Invalid UTF-8 attributes payload.")
            }
            attributes = try jsonDecoder.decode([String: String].self, from: data)
        } else {
            attributes = nil
        }

        let source = decodeSource(
            sdkName: columnString(statement, index: 10),
            sdkVersion: columnString(statement, index: 11),
            file: columnString(statement, index: 12),
            function: columnString(statement, index: 13),
            line: columnInt64(statement, index: 14).map(Int.init)
        )

        return LogRecord(
            id: columnInt64(statement, index: 0) ?? 0,
            timestamp: columnString(statement, index: 1) ?? "",
            level: columnString(statement, index: 2) ?? "",
            message: columnString(statement, index: 3) ?? "",
            platform: columnString(statement, index: 4) ?? "",
            appId: columnString(statement, index: 5) ?? "",
            sessionId: columnString(statement, index: 6) ?? "",
            deviceId: columnString(statement, index: 7) ?? "",
            category: columnString(statement, index: 8) ?? "",
            attributes: attributes,
            source: source
        )
    }

    private func decodeSource(
        sdkName: String?,
        sdkVersion: String?,
        file: String?,
        function: String?,
        line: Int?
    ) -> SourceInfo? {
        guard sdkName != nil || sdkVersion != nil || file != nil || function != nil || line != nil else {
            return nil
        }
        return SourceInfo(
            sdkName: sdkName,
            sdkVersion: sdkVersion,
            file: file,
            function: function,
            line: line
        )
    }

    private func metadataInt(for key: String) throws -> Int {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, index: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        guard let raw = columnString(statement, index: 0), let value = Int(raw) else {
            return 0
        }
        return value
    }

    private func count(table: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM \(table);")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw SQLiteError(message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw sqliteError(messagePrefix: "Failed to prepare statement")
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw sqliteError(messagePrefix: "Failed to execute statement")
        }
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (index, binding) in bindings.enumerated() {
            try bind(binding, to: statement, index: Int32(index + 1))
        }
    }

    private func bind(_ binding: SQLiteBinding, to statement: OpaquePointer?, index: Int32) throws {
        switch binding {
        case .text(let value):
            try value.withCString { cString in
                try check(sqlite3_bind_text(statement, index, cString, -1, sqliteTransient))
            }
        case .int64(let value):
            try check(sqlite3_bind_int64(statement, index, value))
        case .double(let value):
            try check(sqlite3_bind_double(statement, index, value))
        case .null:
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer?, index: Int32) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        try value.withCString { cString in
            try check(sqlite3_bind_text(statement, index, cString, -1, sqliteTransient))
        }
    }

    private func bind(_ value: Int64?, to statement: OpaquePointer?, index: Int32) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        try check(sqlite3_bind_int64(statement, index, value))
    }

    private func bind(_ value: Int64, to statement: OpaquePointer?, index: Int32) throws {
        try check(sqlite3_bind_int64(statement, index, value))
    }

    private func bind(_ value: Double?, to statement: OpaquePointer?, index: Int32) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        try check(sqlite3_bind_double(statement, index, value))
    }

    private func bind(_ value: Double, to statement: OpaquePointer?, index: Int32) throws {
        try check(sqlite3_bind_double(statement, index, value))
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) throws {
        try value.withCString { cString in
            try check(sqlite3_bind_text(statement, index, cString, -1, sqliteTransient))
        }
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

    private func columnString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: cString, count: count), as: UTF8.self)
    }

    private func columnInt64(_ statement: OpaquePointer?, index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, index)
    }

    private func sqliteError(messagePrefix: String) -> SQLiteError {
        SQLiteError(message: "\(messagePrefix): \(String(cString: sqlite3_errmsg(db)))")
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
    }
}

private struct SQLiteError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private enum SQLiteBinding {
    case text(String)
    case int64(Int64)
    case double(Double)
    case null
}
