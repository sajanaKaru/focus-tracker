import XCTest
@testable import FocusCore

final class CopilotProcessChannelTests: XCTestCase {
    func testSendToExitedProcessThrowsInsteadOfRaisingSIGPIPE() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("exits.sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let channel = try ProcessACPChannel(executable: script, directory: dir)
        for try await _ in channel.lines {}
        try await Task.sleep(nanoseconds: 200_000_000)

        var threw = false
        do { try channel.send(Data("{}".utf8)) } catch { threw = true }
        XCTAssertTrue(threw)
        channel.close()
    }
}
