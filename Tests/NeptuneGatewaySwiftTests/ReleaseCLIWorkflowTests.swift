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
        XCTAssertTrue(content.contains("tags:\n      - '*'"), content)
        XCTAssertTrue(content.contains("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$"), content)
        XCTAssertTrue(content.contains("^[0-9]{4}\\.[0-9]{1,2}\\.[0-9]{1,2}(\\.[0-9]+)?$"), content)
        XCTAssertTrue(content.contains("Generate release notes snippet"), content)
        XCTAssertTrue(content.contains("body_path: ${{ runner.temp }}/release-notes.md"), content)
        XCTAssertTrue(content.contains("git log --no-merges --max-count=10 --pretty=format:'- %s (%h)'"), content)
        XCTAssertTrue(content.contains("softprops/action-gh-release@v2"), content)
        XCTAssertTrue(content.contains("./scripts/build-cli-release.sh"), content)
        XCTAssertTrue(content.contains("Publish Homebrew Formula"), content)
        XCTAssertTrue(content.contains("./scripts/publish-homebrew-formula.sh --release-tag"), content)
        XCTAssertTrue(content.contains("linhay/homebrew-tap"), content)
        XCTAssertTrue(content.contains("HOMEBREW_TAP_REPO"), content)
        XCTAssertTrue(content.contains("HOMEBREW_TAP_TOKEN"), content)
        XCTAssertTrue(content.contains("fail_on_unmatched_files: true"), content)
    }
}
