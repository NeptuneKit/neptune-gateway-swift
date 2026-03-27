import Foundation
import XCTest
import STJSON
@testable import NeptuneGatewaySwift

final class GatewayViewTreeMockFixturesTests: XCTestCase {
    func testRawIngestFixturesDecodeToModel() throws {
        let fixtures = try rawFixtureURLs()
        XCTAssertFalse(fixtures.isEmpty, "Expected at least one raw ingest fixture in mocks/ui-tree.")

        let decoder = JSONDecoder()
        for fixture in fixtures {
            let data = try Data(contentsOf: fixture)
            let model = try decoder.decode(ViewTreeRawIngestRequest.self, from: data)
            XCTAssertFalse(model.platform.isEmpty, "platform is empty in \(fixture.lastPathComponent)")
            XCTAssertFalse(model.appId.isEmpty, "appId is empty in \(fixture.lastPathComponent)")
            XCTAssertFalse(model.sessionId.isEmpty, "sessionId is empty in \(fixture.lastPathComponent)")
            XCTAssertFalse(model.deviceId.isEmpty, "deviceId is empty in \(fixture.lastPathComponent)")

            if !(model.payload.type == .dictionary || model.payload.type == .array) {
                XCTFail("payload must be object/array in \(fixture.lastPathComponent)")
            }
        }
    }

    private func rawFixtureURLs() throws -> [URL] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureDir = repoRoot.appendingPathComponent("mocks/ui-tree", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: fixtureDir,
            includingPropertiesForKeys: nil
        )
        return entries
            .filter { $0.lastPathComponent.hasSuffix("-raw-ingest-request.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
