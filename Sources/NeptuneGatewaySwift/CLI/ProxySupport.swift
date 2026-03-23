import Foundation

public enum ProxyPlatform: String, Sendable {
    case ios
    case android
    case harmony
}

public struct ProxyRecordDefaults: Sendable, Equatable {
    public let appID: String
    public let sessionID: String
    public let deviceID: String
    public let category: String

    public init(
        platform: ProxyPlatform,
        appID: String? = nil,
        sessionID: String? = nil,
        deviceID: String? = nil,
        category: String = "proxy"
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        self.appID = appID ?? "proxy.\(platform.rawValue)"
        self.sessionID = sessionID ?? "session.\(platform.rawValue).\(now)"
        self.deviceID = deviceID ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.category = category
    }
}

public struct GatewayProxyConfiguration: Sendable {
    public let platform: ProxyPlatform
    public let command: [String]
    public let options: ProxyCommonOptions

    public init(platform: ProxyPlatform, command: [String], options: ProxyCommonOptions) {
        self.platform = platform
        self.command = command
        self.options = options
    }
}

public enum GatewayCLIError: Error, CustomStringConvertible {
    case emptyCommand
    case invalidGatewayURL(String)

    public var description: String {
        switch self {
        case .emptyCommand:
            return "Proxy command must not be empty."
        case .invalidGatewayURL(let url):
            return "Invalid gateway URL: \(url)"
        }
    }
}

public enum GatewayProxyRunner {
    public static func run(configuration: GatewayProxyConfiguration) throws {
        guard let executable = configuration.command.first else {
            throw GatewayCLIError.emptyCommand
        }

        let defaults = ProxyRecordDefaults(
            platform: configuration.platform,
            appID: configuration.options.appID,
            sessionID: configuration.options.sessionID,
            deviceID: configuration.options.deviceID
        )
        let mapper = ProxyRecordMapper(platform: configuration.platform, defaults: defaults)
        let uploader = try configuration.options.raw ? nil : GatewayBatchUploader(baseURL: configuration.options.gateway)

        defer { uploader?.shutdown() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(configuration.command.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let accumulator = LineAccumulator()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            accumulator.append(data) { line in
                handleProxyLine(line, configuration: configuration, mapper: mapper, uploader: uploader)
            }
        }

        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        accumulator.finish { line in
            handleProxyLine(line, configuration: configuration, mapper: mapper, uploader: uploader)
        }
    }

    private static func handleProxyLine(
        _ line: String,
        configuration: GatewayProxyConfiguration,
        mapper: ProxyRecordMapper,
        uploader: GatewayBatchUploader?
    ) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        if configuration.options.raw {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            return
        }

        uploader?.append(mapper.map(line: line))
    }
}

public struct ProxyRecordMapper: Sendable {
    public let platform: ProxyPlatform
    public let defaults: ProxyRecordDefaults
    private let nowProvider: @Sendable () -> Date

    public init(
        platform: ProxyPlatform,
        defaults: ProxyRecordDefaults,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.platform = platform
        self.defaults = defaults
        self.nowProvider = nowProvider
    }

    public func map(line: String) -> IngestLogRecord {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return IngestLogRecord(
            timestamp: extractTimestamp(from: trimmed) ?? iso8601String(from: nowProvider()),
            level: detectLevel(in: trimmed),
            message: extractMessage(from: trimmed),
            platform: platform.rawValue,
            appId: defaults.appID,
            sessionId: defaults.sessionID,
            deviceId: defaults.deviceID,
            category: defaults.category,
            attributes: ["raw": trimmed],
            source: nil
        )
    }

    private func extractTimestamp(from line: String) -> String? {
        if let match = line.firstMatch(of: #/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})/#) {
            return String(match.output)
        }

        if let match = line.firstMatch(of: #/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{4}/#) {
            let raw = String(match.output)
            return convertAppleTimestamp(raw)
        }

        if let match = line.firstMatch(of: #/^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}/#) {
            return convertMonthDayTimestamp(String(match.output))
        }

        return nil
    }

    private func convertAppleTimestamp(_ value: String) -> String? {
        let formatters = [
            "yyyy-MM-dd HH:mm:ss.SSSSSSZ",
            "yyyy-MM-dd HH:mm:ss.SSSZ",
            "yyyy-MM-dd HH:mm:ssZ",
        ].map { pattern -> DateFormatter in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            return formatter
        }

        for formatter in formatters {
            if let date = formatter.date(from: value) {
                return iso8601String(from: date)
            }
        }
        return nil
    }

    private func convertMonthDayTimestamp(_ value: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let year = Calendar.current.component(.year, from: nowProvider())
        return formatter.date(from: "\(year)-\(value)").map(iso8601String(from:))
    }

    private func detectLevel(in line: String) -> String {
        let lowercased = line.lowercased()

        if lowercased.contains("critical") || lowercased.contains(" fault ") {
            return "critical"
        }
        if lowercased.contains("error") || line.contains(" E/") || line.contains(" E ") {
            return "error"
        }
        if lowercased.contains("warning") || lowercased.contains(" warn ") || line.contains(" W/") || line.contains(" W ") {
            return "warning"
        }
        if lowercased.contains("notice") {
            return "notice"
        }
        if lowercased.contains("debug") || line.contains(" D/") || line.contains(" D ") {
            return "debug"
        }
        if lowercased.contains("trace") || line.contains(" V/") || line.contains(" V ") {
            return "trace"
        }
        return "info"
    }

    private func extractMessage(from line: String) -> String {
        switch platform {
        case .android:
            if let range = line.firstRange(of: #/[VDIWEF]\/[^:]+:\s*/#) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .harmony:
            if let range = line.firstRange(of: #/\s[VDIWEF]\s+[^:]+:\s*/#) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .ios:
            if let range = line.firstRange(of: #/\]:\s*/#) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return line
    }

    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

final class GatewayBatchUploader: @unchecked Sendable {
    private static let batchSize = 50
    private static let flushInterval: TimeInterval = 1.0

    private let gatewayURL: URL
    private let queue = DispatchQueue(label: "NeptuneGatewaySwift.GatewayBatchUploader")
    private let timer: DispatchSourceTimer
    private var buffered: [IngestLogRecord] = []

    init(baseURL: String) throws {
        guard var components = URLComponents(string: baseURL) else {
            throw GatewayCLIError.invalidGatewayURL(baseURL)
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "v2", "logs:ingest"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else {
            throw GatewayCLIError.invalidGatewayURL(baseURL)
        }
        self.gatewayURL = url
        self.timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flushLocked()
        }
        timer.resume()
    }

    func append(_ record: IngestLogRecord) {
        queue.async {
            self.buffered.append(record)
            if self.buffered.count >= Self.batchSize {
                self.flushLocked()
            }
        }
    }

    func shutdown() {
        queue.sync {
            self.flushLocked()
            self.timer.cancel()
        }
    }

    private func flushLocked() {
        guard !buffered.isEmpty else { return }

        let snapshot = buffered
        buffered.removeAll(keepingCapacity: true)

        do {
            var request = URLRequest(url: gatewayURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(snapshot)
            request.timeoutInterval = 5

            let semaphore = DispatchSemaphore(value: 0)
            var resultError: Error?
            var statusCode = -1
            URLSession.shared.dataTask(with: request) { _, response, error in
                resultError = error
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                semaphore.signal()
            }.resume()
            semaphore.wait()

            if let resultError {
                throw resultError
            }

            guard (200...299).contains(statusCode) else {
                throw URLError(.badServerResponse)
            }
        } catch {
            FileHandle.standardError.write(Data("gateway upload failed: \(error)\n".utf8))
            buffered.insert(contentsOf: snapshot, at: 0)
        }
    }
}

final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data, onLine: (String) -> Void) {
        lock.lock()
        buffer.append(data)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                lock.unlock()
                onLine(line)
                lock.lock()
            }
        }

        lock.unlock()
    }

    func finish(onLine: (String) -> Void) {
        lock.lock()
        let remainder = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        if !remainder.isEmpty, let line = String(data: remainder, encoding: .utf8) {
            onLine(line)
        }
    }
}
