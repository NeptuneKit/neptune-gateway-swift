import Foundation

struct GatewayClientLogRelayResult: Sendable {
    let response: QueryResponse
    let forwardedRecords: [LogRecord]
}

actor GatewayClientLogRelay {
    func query(
        clients: [ClientSnapshot],
        query: LogQuery
    ) async -> GatewayClientLogRelayResult {
        guard !clients.isEmpty else {
            return GatewayClientLogRelayResult(
                response: QueryResponse(
                    records: [],
                    hasMore: false
                ),
                forwardedRecords: []
            )
        }

        let collected = await withTaskGroup(of: ClientQueryResult.self, returning: [ClientQueryResult].self) { group in
            for client in clients {
                group.addTask {
                    await self.querySingleClient(client, query: query)
                }
            }

            var output: [ClientQueryResult] = []
            for await item in group {
                output.append(item)
            }
            return output
        }

        var mergedByKey: [LogDedupKey: LogRecord] = [:]
        var failures: [QueryPartialFailure] = []
        for result in collected {
            switch result {
            case .success(let records):
                for record in records {
                    mergedByKey[LogDedupKey(record)] = record
                }
            case .failure(let failure):
                failures.append(failure)
            }
        }

        let mergedSorted = mergedByKey.values.sorted(by: compareRecords)
        let limitedRecords: [LogRecord]
        let hasMore: Bool
        if let length = query.length {
            limitedRecords = Array(mergedSorted.prefix(length))
            hasMore = mergedSorted.count > length
        } else {
            limitedRecords = mergedSorted
            hasMore = false
        }
        let meta = failures.isEmpty ? nil : QueryResponseMeta(partialFailures: failures)

        return GatewayClientLogRelayResult(
            response: QueryResponse(
                records: limitedRecords,
                hasMore: hasMore,
                meta: meta
            ),
            forwardedRecords: limitedRecords
        )
    }

    private func querySingleClient(_ client: ClientSnapshot, query: LogQuery) async -> ClientQueryResult {
        guard var components = logsURLComponents(from: client.callbackEndpoint) else {
            return .failure(
                QueryPartialFailure(
                    platform: client.platform,
                    appId: client.appId,
                    sessionId: client.sessionId,
                    deviceId: client.deviceId,
                    callbackEndpoint: client.callbackEndpoint,
                    reason: "invalid_callback_endpoint"
                )
            )
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "format", value: "json"))
        if let cursor = query.cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
        if let length = query.length {
            queryItems.append(URLQueryItem(name: "length", value: String(length)))
        }
        if let platform = query.platform {
            queryItems.append(URLQueryItem(name: "platform", value: platform))
        }
        if let appId = query.appId {
            queryItems.append(URLQueryItem(name: "appId", value: appId))
        }
        if let sessionId = query.sessionId {
            queryItems.append(URLQueryItem(name: "sessionId", value: sessionId))
        }
        if let level = query.level {
            queryItems.append(URLQueryItem(name: "level", value: level))
        }
        if let contains = query.contains, !contains.isEmpty {
            queryItems.append(URLQueryItem(name: "contains", value: contains))
        }
        if let since = query.since {
            queryItems.append(URLQueryItem(name: "since", value: iso8601(since)))
        }
        if let until = query.until {
            queryItems.append(URLQueryItem(name: "until", value: iso8601(until)))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            return .failure(clientFailure(client, reason: "invalid_logs_url"))
        }

        switch await fetchLogs(url: url, timeout: 5) {
        case .success(let records):
            return .success(records)
        case .failure(let error):
            return .failure(clientFailure(client, reason: error.reason))
        }
    }

    private func fetchLogs(url: URL, timeout: TimeInterval) async -> Result<[LogRecord], ClientLogFetchError> {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.reason("invalid_http_response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.reason("upstream_status_\(http.statusCode)"))
            }
            do {
                let decoded = try JSONDecoder().decode(ClientLogsResponse.self, from: data)
                return .success(decoded.records)
            } catch {
                return .failure(.reason("invalid_query_response"))
            }
        } catch {
            return .failure(.reason("request_failed"))
        }
    }

    private func logsURLComponents(from callbackEndpoint: String) -> URLComponents? {
        guard let endpointURL = URL(string: callbackEndpoint),
              var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let path = components.path
        if path.hasSuffix("/v2/client/command") {
            components.path = String(path.dropLast("/client/command".count)) + "/logs"
        } else if path.hasSuffix("/v2/logs") {
            return components
        } else if path.hasSuffix("/v2") {
            components.path = path + "/logs"
        } else {
            components.path = "/v2/logs"
        }
        return components
    }

    private func clientFailure(_ client: ClientSnapshot, reason: String) -> QueryPartialFailure {
        QueryPartialFailure(
            platform: client.platform,
            appId: client.appId,
            sessionId: client.sessionId,
            deviceId: client.deviceId,
            callbackEndpoint: client.callbackEndpoint,
            reason: reason
        )
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func compareRecords(_ lhs: LogRecord, _ rhs: LogRecord) -> Bool {
        let leftDate = parseDate(lhs.timestamp)
        let rightDate = parseDate(rhs.timestamp)
        if let leftDate, let rightDate, leftDate != rightDate {
            return leftDate < rightDate
        }

        let leftKey = LogDedupKey(lhs).sortKey
        let rightKey = LogDedupKey(rhs).sortKey
        if leftKey != rightKey {
            return leftKey < rightKey
        }
        return lhs.id < rhs.id
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct LogDedupKey: Hashable {
    let platform: String
    let appId: String
    let sessionId: String
    let deviceId: String
    let id: Int64

    init(_ record: LogRecord) {
        platform = record.platform
        appId = record.appId
        sessionId = record.sessionId
        deviceId = record.deviceId
        id = record.id
    }

    var sortKey: String {
        [platform, appId, sessionId, deviceId, String(id)].joined(separator: "|")
    }
}

private enum ClientQueryResult: Sendable {
    case success([LogRecord])
    case failure(QueryPartialFailure)
}

private enum ClientLogFetchError: Error, Sendable {
    case reason(String)

    var reason: String {
        switch self {
        case .reason(let value):
            return value
        }
    }
}

private struct ClientLogsResponse: Decodable {
    let records: [LogRecord]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case records
        case hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([LogRecord].self, forKey: .records)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}
