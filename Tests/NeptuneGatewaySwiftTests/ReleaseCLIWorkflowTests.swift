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
        XCTAssertTrue(content.contains("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$"), content)
        XCTAssertTrue(content.contains("Generate release notes snippet"), content)
        XCTAssertTrue(content.contains("body_path: ${{ runner.temp }}/release-notes.md"), content)
        XCTAssertTrue(content.contains("git log --no-merges --max-count=10 --pretty=format:'- %s (%h)'"), content)
        XCTAssertTrue(content.contains("softprops/action-gh-release@v2"), content)
        XCTAssertTrue(content.contains("./scripts/build-cli-release.sh"), content)
        XCTAssertTrue(content.contains("fail_on_unmatched_files: true"), content)
    }
}
