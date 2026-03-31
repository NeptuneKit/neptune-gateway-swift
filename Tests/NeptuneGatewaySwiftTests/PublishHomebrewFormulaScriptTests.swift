import Foundation
import XCTest

final class PublishHomebrewFormulaScriptTests: XCTestCase {
    func testPublishHomebrewFormulaScriptSelfCheckRuns() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = projectRoot.appendingPathComponent("scripts/publish-homebrew-formula.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path), "Publish script should exist.")

        let releaseTag = "v9.9.9-test"
        let checksumDir = projectRoot.appendingPathComponent("dist/cli-release", isDirectory: true)
        let checksumFile = checksumDir.appendingPathComponent("neptune-\(releaseTag).sha256")
        try FileManager.default.createDirectory(at: checksumDir, withIntermediateDirectories: true)
        try "0123456789abcdef  neptune-\(releaseTag)\n".write(to: checksumFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: checksumFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "--release-tag", releaseTag, "--self-check"]
        process.currentDirectoryURL = projectRoot
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOMEBREW_TAP_REPO": "linhay/homebrew-neptune",
            "HOMEBREW_TAP_TOKEN": "test-token"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("self-check ok: publish-homebrew-formula"), output)
    }
}
