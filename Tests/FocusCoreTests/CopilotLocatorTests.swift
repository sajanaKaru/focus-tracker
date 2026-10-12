import XCTest
@testable import FocusCore

final class CopilotLocatorTests: XCTestCase {
    func testAnOverridePathMustBeExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("copilot")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)

        let notExecutable = await CopilotLocator.locate(override: file.path)
        XCTAssertNil(notExecutable)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let executable = await CopilotLocator.locate(override: " \(file.path) ")
        XCTAssertEqual(executable?.path, file.path)
    }

    func testTakesTheLastAbsolutePathFromNoisyShellOutput() {
        let output = "Welcome back\nUpdating oh-my-zsh...\n/Users/me/.nvm/versions/node/v20/bin/copilot\n"
        XCTAssertEqual(CopilotLocator.path(fromShellOutput: output), "/Users/me/.nvm/versions/node/v20/bin/copilot")
        XCTAssertNil(CopilotLocator.path(fromShellOutput: "copilot not found\n"))
        XCTAssertNil(CopilotLocator.path(fromShellOutput: ""))
    }
}
