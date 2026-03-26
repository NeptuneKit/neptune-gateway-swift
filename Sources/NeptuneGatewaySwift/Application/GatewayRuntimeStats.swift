import Foundation

actor GatewayRuntimeStats {
    private var ingestAcceptedTotal: Int = 0
    private var nextSyntheticRecordID: Int64 = 1

    func reserveSyntheticIDs(count: Int) -> Int64 {
        let safeCount = max(0, count)
        let start = nextSyntheticRecordID
        nextSyntheticRecordID += Int64(safeCount)
        return start
    }

    func incrementIngestAccepted(by count: Int) {
        ingestAcceptedTotal += max(0, count)
    }

    func snapshot(sourceCount: Int) -> MetricsResponse {
        MetricsResponse(
            ingestAcceptedTotal: ingestAcceptedTotal,
            sourceCount: sourceCount,
            retainedRecordCount: 0,
            retentionMaxRecordCount: 0,
            retentionMaxAgeSeconds: 0,
            retentionDroppedTotal: 0
        )
    }
}
