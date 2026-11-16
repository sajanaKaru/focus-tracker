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

    // MARK: PATH lookup and override robustness

    private func makeDirectory(under base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = base.appendingPathComponent("ft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @discardableResult
    private func makeCopilot(in directory: URL, executable: Bool = true) throws -> URL {
        let file = directory.appendingPathComponent("copilot")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        return file
    }

    func testFindsAnExecutableOnThePath() throws {
        let directory = try makeDirectory()
        let file = try makeCopilot(in: directory)
        XCTAssertEqual(CopilotLocator.executableOnPath(searchPath: "/nonexistent-ft:" + directory.path)?.path, file.path)
    }

    func testIgnoresANonExecutableFileOnThePath() throws {
        let directory = try makeDirectory()
        try makeCopilot(in: directory, executable: false)
        XCTAssertNil(CopilotLocator.executableOnPath(searchPath: directory.path))
    }

    func testSkipsADirectoryNamedCopilotOnThePath() throws {
        let directory = try makeDirectory()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("copilot"), withIntermediateDirectories: true)
        XCTAssertNil(CopilotLocator.executableOnPath(searchPath: directory.path))
    }

    func testSkipsEmptyAndRelativePathEntries() throws {
        let directory = try makeDirectory()
        try makeCopilot(in: directory)
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        XCTAssertNil(CopilotLocator.executableOnPath(searchPath: ":.:bin"))
        XCTAssertNil(CopilotLocator.executableOnPath(searchPath: nil))
    }

    func testTheFirstMatchOnThePathWins() throws {
        let first = try makeDirectory()
        let second = try makeDirectory()
        let expected = try makeCopilot(in: first)
        try makeCopilot(in: second)
        XCTAssertEqual(CopilotLocator.executableOnPath(searchPath: [first.path, second.path].joined(separator: ":"))?.path, expected.path)
    }

    func testAnOverrideExpandsTilde() async throws {
        let directory = try makeDirectory(under: URL(fileURLWithPath: NSHomeDirectory()))
        let file = try makeCopilot(in: directory)
        let tilde = "~" + file.path.dropFirst(NSHomeDirectory().count)
        let located = await CopilotLocator.locate(override: tilde)
        XCTAssertEqual(located?.path, file.path)
    }

    func testADirectoryOverrideIsRejected() async throws {
        let directory = try makeDirectory()
        let located = await CopilotLocator.locate(override: directory.path)
        XCTAssertNil(located)
    }
}
