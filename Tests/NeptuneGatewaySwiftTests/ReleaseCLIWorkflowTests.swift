import Foundation
import XCTest

final class ReleaseCLIWorkflowTests: XCTestCase {
    func testReleaseCliTagWorkflowUsesGitHubReleaseAndTagTriggers() throws {
        let workflowURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/release-cli-tag.yml")

        XCTAssertTrue(FileManager.default.fileExists(atPath: workflowURL.path), "Release workflow should exist.")

        let content = try String(contentsOf: workflowURL, encoding: .utf8)
        XCTAssertTrue(content.contains("workflow_dispatch"), content)
        XCTAssertTrue(content.contains("tags:\n      - 'v*'"), content)
        XCTAssertTrue(content.contains("softprops/action-gh-release@v2"), content)
        XCTAssertTrue(content.contains("./scripts/build-cli-release.sh"), content)
    }
}
