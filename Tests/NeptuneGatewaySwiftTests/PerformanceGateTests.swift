import Foundation
import XCTest
@testable import NeptuneGatewaySwift

final class PerformanceGateTests: XCTestCase {
    func testGatewayStoreHandles100kConcurrentIngestAndQuery() async throws {
        try Self.requirePerformanceGateEnabled()

        let totalRecords = 100_000
        let workerCount = 20
        let recordsPerWorker = totalRecords / workerCount
        let storageURL = Self.makeStorageURL()

        defer {
            try? FileManager.default.removeItem(at: storageURL)
        }

        let store = try GatewayStore(
            storageURL: storageURL,
            configuration: GatewayStoreConfiguration(
                maxRecordCount: totalRecords + 1,
                maxAge: 0
            )
        )

        let clock = ContinuousClock()
        let ingestStart = clock.now

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<workerCount {
                group.addTask {
                    let startIndex = workerIndex * recordsPerWorker
                    let batch = Self.makeBatch(startIndex: startIndex, count: recordsPerWorker)
                    _ = try await store.ingest(batch)
                }
            }

            try await group.waitForAll()
        }

        let ingestDuration = clock.now - ingestStart

        let queryStart = clock.now
        let response = try await store.query(LogQuery(limit: totalRecords))
        let queryDuration = clock.now - queryStart

        XCTAssertEqual(response.records.count, totalRecords)
        XCTAssertFalse(response.hasMore)
        XCTAssertEqual(response.nextCursor, String(totalRecords))

        let ids = response.records.map(\.id)
        XCTAssertEqual(ids.first, 1)
        XCTAssertEqual(ids.last, Int64(totalRecords))
        XCTAssertEqual(Set(ids).count, totalRecords)
        XCTAssertTrue(zip(ids, ids.dropFirst()).allSatisfy { $0.0 < $0.1 }, "Record IDs must remain strictly increasing.")

        try await withThrowingTaskGroup(of: [Int64].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let snapshot = try await store.query(LogQuery(limit: totalRecords))
                    return snapshot.records.map(\.id)
                }
            }

            var snapshots: [[Int64]] = []
            for try await snapshot in group {
                snapshots.append(snapshot)
            }

            XCTAssertEqual(snapshots.count, 4)
            for snapshot in snapshots {
                XCTAssertEqual(snapshot, ids)
            }
        }

        print(
            """
            Performance gate passed:
              ingest=\(Self.format(duration: ingestDuration))
              query=\(Self.format(duration: queryDuration))
              records=\(totalRecords)
            """
        )
    }
}

private extension PerformanceGateTests {
    static func requirePerformanceGateEnabled() throws {
        guard ProcessInfo.processInfo.environment["NEPTUNE_GATEWAY_PERF_GATE"] == "1" else {
            throw XCTSkip("Set NEPTUNE_GATEWAY_PERF_GATE=1 to run the 100k performance gate.")
        }
    }

    static func makeStorageURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("neptune-gateway-perf-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    static func makeBatch(startIndex: Int, count: Int) -> [IngestLogRecord] {
        var records: [IngestLogRecord] = []
        records.reserveCapacity(count)

        for offset in 0..<count {
            let sequence = startIndex + offset
            records.append(
                IngestLogRecord(
                    timestamp: "2026-03-23T12:00:00Z",
                    level: "info",
                    message: "perf-\(sequence)",
                    platform: "ios",
                    appId: "perf.gate",
                    sessionId: "perf-session",
                    deviceId: "perf-device",
                    category: "performance"
                )
            )
        }

        return records
    }

    static func format(duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.3fs", seconds + attoseconds)
    }
}
