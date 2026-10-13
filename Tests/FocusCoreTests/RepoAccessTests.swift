import XCTest
@testable import FocusCore

final class RepoAccessTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ft-repos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func checkout(_ relative: String) throws -> URL {
        let url = base.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return url
    }

    // MARK: Locator

    func testFindsCheckoutByNameOrOwnerAndName() throws {
        let flat = try checkout("app")
        XCTAssertEqual(RepoLocator.find(repo: "me/app", in: base.path)?.standardizedFileURL, flat.standardizedFileURL)
        let nested = try checkout("acme/site")
        XCTAssertEqual(RepoLocator.find(repo: "acme/site", in: base.path)?.standardizedFileURL, nested.standardizedFileURL)
    }

    func testIgnoresFoldersThatAreNotGitCheckouts() throws {
        try FileManager.default.createDirectory(at: base.appendingPathComponent("plain"), withIntermediateDirectories: true)
        XCTAssertNil(RepoLocator.find(repo: "me/plain", in: base.path))
        XCTAssertNil(RepoLocator.find(repo: "me/missing", in: base.path))
        XCTAssertNil(RepoLocator.find(repo: "me/app", in: ""))
    }

    func testRejectsRepoNamesThatEscapeTheFolder() throws {
        _ = try checkout("app")
        XCTAssertNil(RepoLocator.find(repo: "me/..", in: base.path))
        XCTAssertNil(RepoLocator.find(repo: "../app", in: base.path))
        XCTAssertNil(RepoLocator.find(repo: "me/app/extra", in: base.path))
    }

    // MARK: Policy

    private func call(_ kind: String, _ paths: [String]) -> [String: Any] {
        ["kind": kind, "locations": paths.map { ["path": $0] }]
    }

    func testAllowsReadsInsideTheCheckoutOnly() throws {
        let root = try checkout("app")
        XCTAssertTrue(RepoReadPolicy.allows(call("read", [root.path + "/Sources/A.swift"]), root: root))
        XCTAssertTrue(RepoReadPolicy.allows(call("read", ["Sources/A.swift"]), root: root))
        XCTAssertTrue(RepoReadPolicy.allows(call("search", [root.path]), root: root))
        XCTAssertFalse(RepoReadPolicy.allows(call("read", ["/etc/passwd"]), root: root))
        XCTAssertFalse(RepoReadPolicy.allows(call("read", [root.path + "/../other/secret.txt"]), root: root))
        XCTAssertFalse(RepoReadPolicy.allows(call("read", [root.path + "-evil/A.swift"]), root: root))
    }

    func testRefusesWritesCommandsAndUnknownCalls() throws {
        let root = try checkout("app")
        for kind in ["edit", "delete", "move", "execute", "fetch", "other"] {
            XCTAssertFalse(RepoReadPolicy.allows(call(kind, [root.path + "/A.swift"]), root: root), kind)
        }
        XCTAssertFalse(RepoReadPolicy.allows(call("read", []), root: root))
        XCTAssertFalse(RepoReadPolicy.allows(["locations": [["path": root.path]]], root: root))
    }

    func testRefusesSecretsAndGitInternals() throws {
        let root = try checkout("app")
        for path in [".env", ".env.local", "config/server.pem", "id_rsa", ".git/config", ".npmrc", "keys/app.key"] {
            XCTAssertFalse(RepoReadPolicy.allows(call("read", [root.path + "/" + path]), root: root), path)
        }
    }

    func testRefusesSymlinksThatLeaveTheCheckout() throws {
        let root = try checkout("app")
        let outside = base.appendingPathComponent("outside.txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        XCTAssertFalse(RepoReadPolicy.allows(call("read", [root.path + "/link.txt"]), root: root))
    }

    // MARK: Client

    private let reply = #"{"cases":[{"title":"Login works","steps":["Open"],"expected":"In"}]}"#
    private let permission = #"{"jsonrpc":"2.0","id":%d,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t","kind":"%@","locations":[{"path":"%@"}]},"options":[{"optionId":"no","name":"No","kind":"reject_once"},{"optionId":"yes","name":"Yes","kind":"allow_once"}]}}"#

    private func outcome(_ channel: ScriptedChannel, id: Int) -> [String: Any]? {
        let answer = channel.sent.first { ($0["id"] as? Int) == id && $0["method"] == nil }
        return (answer?["result"] as? [String: Any])?["outcome"] as? [String: Any]
    }

    func testRepositoryModeApprovesOnlySafeReadsAndKeepsTheCheckout() async throws {
        let root = try checkout("app")
        let safe = String(format: permission, 90, "read", root.path + "/A.swift")
        let outside = String(format: permission, 91, "read", "/etc/passwd")
        let write = String(format: permission, 92, "edit", root.path + "/A.swift")
        let channel = ScriptedChannel.agent(chunks: [reply], beforeReply: [safe, outside, write])
        let opened = OpenedDirectory()
        let client = CopilotACPClient(timeout: 5) { directory in opened.value = directory; return channel }

        let cases = try await client.draftCases(DraftPrompt(system: "SYS", user: "USER"), model: "auto", repository: root)

        XCTAssertEqual(cases.map(\.title), ["Login works"])
        XCTAssertEqual(opened.value?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(outcome(channel, id: 90)?["outcome"] as? String, "selected")
        XCTAssertEqual(outcome(channel, id: 90)?["optionId"] as? String, "yes")
        XCTAssertEqual(outcome(channel, id: 91)?["outcome"] as? String, "cancelled")
        XCTAssertEqual(outcome(channel, id: 92)?["outcome"] as? String, "cancelled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
        let prompt = (channel.sent.first { $0["method"] as? String == "session/prompt" }?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        XCTAssertTrue((prompt?.first?["text"] as? String)?.contains("local checkout") == true)
    }

    func testWithoutARepositoryEveryPermissionIsStillCancelled() async throws {
        let root = try checkout("app")
        let safe = String(format: permission, 90, "read", root.path + "/A.swift")
        let channel = ScriptedChannel.agent(chunks: [reply], beforeReply: [safe])
        _ = try await CopilotACPClient(timeout: 5) { _ in channel }.draftCases(DraftPrompt(system: "S", user: "U"), model: "auto")
        XCTAssertEqual(outcome(channel, id: 90)?["outcome"] as? String, "cancelled")
    }

    func testTextBeforeAToolCallIsDropped() async throws {
        let narration = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Let me look at { the code"}}}}"#
        let toolCall = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t"}}}"#
        let channel = ScriptedChannel.agent(chunks: [reply], beforeReply: [narration, toolCall])
        let cases = try await CopilotACPClient(timeout: 5) { _ in channel }
            .draftCases(DraftPrompt(system: "S", user: "U"), model: "auto", repository: try checkout("app"))
        XCTAssertEqual(cases.map(\.title), ["Login works"])
    }
}

private final class OpenedDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var value: URL? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
