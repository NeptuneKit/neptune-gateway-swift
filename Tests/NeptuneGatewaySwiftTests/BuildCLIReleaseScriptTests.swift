import Foundation
import XCTest

final class BuildCLIReleaseScriptTests: XCTestCase {
    func testBuildCliReleaseScriptSelfCheckRuns() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build-cli-release.sh")

        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path), "Release script should exist.")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "--self-check"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("self-check ok: neptune"), output)
    }
}
