# GitHub Copilot Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** QA can draft test cases with the models enabled for the user's GitHub Copilot account, via a new `GitHub Copilot` AI provider that needs no API key.

**Architecture:** A new `CopilotACPClient` drives `copilot --acp` (Agent Client Protocol, newline-delimited JSON-RPC over stdio) behind an injectable `ACPChannel`, so tests use a scripted fake. It lists enabled models from the `session/new` reply and drafts cases through `session/prompt`, cancelling every permission request. `AIProvider` gains `.copilot`, `AppStore` routes drafting to the ACP client, and Settings gets a model picker and CLI path field.

**Tech Stack:** Swift 5.9 tools (Swift 5 language mode), SwiftUI, XCTest, `Foundation.Process`, Swift concurrency.

**Spec:** `docs/superpowers/specs/2026-10-13-copilot-provider-design.md`

## Global Constraints

- Swift package, macOS 14+; `FocusCore` has no UI imports. Tests run with `swift test`.
- The saved GitHub token is a classic PAT (`ghp_`) and is never sent to Copilot; Copilot uses the CLI's own login (`copilot login`).
- Permission requests from the agent are answered with the `cancelled` outcome; no file-system or terminal client capabilities are advertised.
- 90 s timeout for a CLI call; the process is always killed on completion, timeout, or cancellation.
- `AIProvider.copilot` has title `GitHub Copilot` and `defaultModel` `auto`.
- Error copy: not found = `GitHub Copilot CLI not found. Install it or set its path in Settings.`; not signed in = ``Run `copilot login` in a terminal, then try again.``
- `hasAIKey` is always true for `.copilot`.
- Notes: `rm` is aliased to `npm run rm` in this shell, use `command rm`. `await` cannot be used inside XCTAssert autoclosures. Do not launch `build/FocusTracker.app` to test (it loads the real data file and GitHub token).

---

### Task 1: Provider, errors, and model parsing

**Files:**
- Modify: `Sources/FocusCore/AICaseDrafter.swift`
- Create: `Sources/FocusCore/CopilotCLI.swift`
- Modify: `Tests/FocusCoreTests/AICaseDrafterTests.swift:13-18` and `:91`
- Create: `Tests/FocusCoreTests/CopilotModelTests.swift`

**Interfaces:**
- Produces: `AIProvider.copilot`, `AIProvider.usesAPIKey: Bool`, `AIError.copilotNotInstalled | .copilotNotSignedIn | .copilotNoEnabledModels | .copilotFailed(String)`, `CopilotModel { id, name, usage, label }`, `CopilotModel.enabled(in: [String: Any]) -> [CopilotModel]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FocusCoreTests/CopilotModelTests.swift`:

```swift
import XCTest
@testable import FocusCore

final class CopilotModelTests: XCTestCase {
    private func result(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testKeepsOnlyEnabledModelsAndDropsDuplicates() {
        let models = CopilotModel.enabled(in: result(#"""
        {"models":{"availableModels":[
          {"modelId":"auto","name":"Auto"},
          {"modelId":"auto","name":"Auto","_meta":{"copilotEnablement":"enabled","copilotUsage":"1x"}},
          {"modelId":"gpt-x","name":"GPT X","_meta":{"copilotEnablement":"disabled"}},
          {"modelId":"claude-y","name":"Claude Y","_meta":{"copilotEnablement":"enabled","copilotUsage":"15x"}},
          {"modelId":"claude-y","name":"Claude Y","_meta":{"copilotEnablement":"enabled","copilotUsage":"15x"}}
        ]}}
        """#))
        XCTAssertEqual(models.map(\.id), ["auto", "claude-y"])
        XCTAssertEqual(models[1].label, "Claude Y (15x)")
    }

    func testNoModelsKeyYieldsAnEmptyList() {
        XCTAssertTrue(CopilotModel.enabled(in: result("{}")).isEmpty)
    }

    func testLabelWithoutUsageIsJustTheName() {
        let models = CopilotModel.enabled(in: result(#"{"models":{"availableModels":[{"modelId":"m","name":"M","_meta":{"copilotEnablement":"enabled"}}]}}"#))
        XCTAssertEqual(models.first?.label, "M")
    }

    func testCopilotProviderDoesNotUseAnAPIKey() {
        XCTAssertFalse(AIProvider.copilot.usesAPIKey)
        XCTAssertTrue(AIProvider.openAI.usesAPIKey)
        XCTAssertEqual(AIProvider.copilot.title, "GitHub Copilot")
        XCTAssertEqual(AIProvider.copilot.defaultModel, "auto")
    }

    func testCopilotErrorMessages() {
        XCTAssertEqual(AIError.copilotNotInstalled.errorDescription, "GitHub Copilot CLI not found. Install it or set its path in Settings.")
        XCTAssertEqual(AIError.copilotNotSignedIn.errorDescription, "Run `copilot login` in a terminal, then try again.")
        XCTAssertTrue(AIError.copilotFailed("boom").localizedDescription.contains("boom"))
    }
}
```

In `Tests/FocusCoreTests/AICaseDrafterTests.swift`, add a `.copilot` arm to the exhaustive switch in `response(for:)` (after the `.gemini` line):

```swift
        case .copilot: ""
```

and change the loop in `testParsesFencedJSONAndBareArray` from `AIProvider.allCases` to:

```swift
        for provider in AIProvider.allCases.filter(\.usesAPIKey) {
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CopilotModelTests`
Expected: build FAIL (`CopilotModel`, `AIProvider.copilot` not defined).

- [ ] **Step 3: Write minimal implementation**

In `Sources/FocusCore/AICaseDrafter.swift`:

Replace `case openAI, anthropic, gemini` with `case openAI, anthropic, gemini, copilot`.

In `title` add `case .copilot: "GitHub Copilot"` after the `.gemini` arm; in `defaultModel` add `case .copilot: "auto"` after the `.gemini` arm. After the `keychainAccount` line add:

```swift
    /// Copilot signs in through the Copilot CLI instead of a key.
    public var usesAPIKey: Bool { self != .copilot }
```

In `AIError`, add cases after `case noCases`:

```swift
    case copilotNotInstalled
    case copilotNotSignedIn
    case copilotNoEnabledModels
    case copilotFailed(String)
```

and in `errorDescription` after the `.noCases` arm:

```swift
        case .copilotNotInstalled: "GitHub Copilot CLI not found. Install it or set its path in Settings."
        case .copilotNotSignedIn: "Run `copilot login` in a terminal, then try again."
        case .copilotNoEnabledModels: "Your GitHub Copilot account has no enabled models."
        case .copilotFailed(let message): "GitHub Copilot: \(message)"
```

In `AICaseClient.makeRequest`, add after the `.gemini` case body (before the closing brace of the `switch`):

```swift
        case .copilot:
            throw AIError.copilotFailed("Copilot drafts do not go through HTTP.")
```

In `replyText`, add after the `.gemini` arm:

```swift
        case .copilot:
            return nil
```

Create `Sources/FocusCore/CopilotCLI.swift`:

```swift
import Foundation

public struct CopilotModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let usage: String?

    /// Name plus the premium-request multiplier, e.g. "Claude Opus 5.5 (15x)".
    public var label: String { usage.map { "\(name) (\($0))" } ?? name }

    /// Models in a `session/new` result that this account can use, without duplicates.
    static func enabled(in result: [String: Any]) -> [CopilotModel] {
        let list = (result["models"] as? [String: Any])?["availableModels"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return list.compactMap { item in
            let meta = item["_meta"] as? [String: Any]
            guard meta?["copilotEnablement"] as? String == "enabled",
                  let id = item["modelId"] as? String, seen.insert(id).inserted else { return nil }
            return CopilotModel(id: id, name: (item["name"] as? String) ?? id, usage: meta?["copilotUsage"] as? String)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'CopilotModelTests|AICaseDrafterTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-10-13-copilot-provider-design.md docs/superpowers/plans/2026-10-13-copilot-provider.md Sources/FocusCore/AICaseDrafter.swift Sources/FocusCore/CopilotCLI.swift Tests/FocusCoreTests/AICaseDrafterTests.swift Tests/FocusCoreTests/CopilotModelTests.swift
git commit -m "feat: add GitHub Copilot provider type, errors and model parsing"
```

---

### Task 2: ACP client with a scripted fake

**Files:**
- Modify: `Sources/FocusCore/CopilotCLI.swift` (append)
- Create: `Tests/FocusCoreTests/CopilotTestSupport.swift`
- Create: `Tests/FocusCoreTests/CopilotACPClientTests.swift`

**Interfaces:**
- Consumes: `CopilotModel.enabled(in:)`, `AIError.copilot*`, `AICaseClient.parseCases(_:)`, `DraftPrompt`, `DraftCase`.
- Produces:
  - `protocol ACPChannel: Sendable { var lines: AsyncThrowingStream<Data, Error> { get }; func send(_ line: Data) throws; func close() }`
  - `struct CopilotACPClient: Sendable` with `init(timeout: TimeInterval = 90, open: @escaping @Sendable (URL) throws -> ACPChannel)`, `func availableModels() async throws -> [CopilotModel]`, `func draftCases(_ prompt: DraftPrompt, model: String) async throws -> [DraftCase]`. `open` receives the session working directory.
  - Test helper `ScriptedChannel` (`sent`, `methods`, `closed`, `ScriptedChannel.agent(models:chunks:beforeReply:fail:)`) and `ACPFixture.models`.

- [ ] **Step 1: Write the failing test and test support**

Create `Tests/FocusCoreTests/CopilotTestSupport.swift`:

```swift
import Foundation
@testable import FocusCore

enum ACPFixture {
    /// Duplicate `auto`, one disabled model, as the real CLI reports.
    static let models = #"{"availableModels":[{"modelId":"auto","name":"Auto"},{"modelId":"auto","name":"Auto","_meta":{"copilotEnablement":"enabled","copilotUsage":"1x"}},{"modelId":"claude-y","name":"Claude Y","_meta":{"copilotEnablement":"enabled","copilotUsage":"15x"}},{"modelId":"gpt-x","name":"GPT X","_meta":{"copilotEnablement":"disabled"}}],"currentModelId":"claude-y"}"#

    static func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}

/// Stands in for the Copilot CLI: every line the client sends is answered by `respond`.
final class ScriptedChannel: ACPChannel, @unchecked Sendable {
    typealias Responder = @Sendable (_ method: String?, _ message: [String: Any]) -> [String]

    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let respond: Responder
    private let lock = NSLock()
    private var storedSent: [[String: Any]] = []
    private var storedClosed = false

    var sent: [[String: Any]] { lock.withLock { storedSent } }
    var closed: Bool { lock.withLock { storedClosed } }
    var methods: [String] { sent.compactMap { $0["method"] as? String } }

    init(respond: @escaping Responder) {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream { captured = $0 }
        continuation = captured
        self.respond = respond
    }

    func send(_ line: Data) throws {
        let message = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        lock.withLock { storedSent.append(message) }
        for reply in respond(message["method"] as? String, message) { continuation.yield(Data(reply.utf8)) }
    }

    func close() {
        lock.withLock { storedClosed = true }
        continuation.finish()
    }

    /// A well-behaved agent. `fail` maps a method name to an error message returned for that method.
    static func agent(
        models: String = ACPFixture.models, chunks: [String] = [], beforeReply: [String] = [], fail: [String: String] = [:]
    ) -> ScriptedChannel {
        ScriptedChannel { method, message in
            guard let method, let id = message["id"] else { return [] }
            func reply(_ result: String) -> String { #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"# }
            if let text = fail[method] {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":\#(ACPFixture.jsonString(text))}}"#]
            }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "session/new": return [reply(#"{"sessionId":"s1","models":\#(models)}"#)]
            case "session/set_model": return [reply("{}")]
            case "session/prompt":
                let updates = chunks.map {
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":\#(ACPFixture.jsonString($0))}}}}"#
                }
                return beforeReply + updates + [reply(#"{"stopReason":"end_turn"}"#)]
            default: return []
            }
        }
    }
}
```

Create `Tests/FocusCoreTests/CopilotACPClientTests.swift`:

```swift
import XCTest
@testable import FocusCore

final class CopilotACPClientTests: XCTestCase {
    private let reply = #"{"cases":[{"title":"Login works","steps":["Open"],"expected":"In"}]}"#
    private let prompt = DraftPrompt(system: "SYS", user: "USER")

    private func client(_ channel: ScriptedChannel, timeout: TimeInterval = 5) -> CopilotACPClient {
        CopilotACPClient(timeout: timeout) { _ in channel }
    }

    private func message(_ channel: ScriptedChannel, method: String) -> [String: Any]? {
        channel.sent.first { $0["method"] as? String == method }
    }

    private func params(_ channel: ScriptedChannel, method: String) -> [String: Any] {
        message(channel, method: method)?["params"] as? [String: Any] ?? [:]
    }

    func testListsEnabledModelsWithoutPrompting() async throws {
        let channel = ScriptedChannel.agent()
        let models = try await client(channel).availableModels()
        XCTAssertEqual(models.map(\.id), ["auto", "claude-y"])
        XCTAssertEqual(channel.methods, ["initialize", "session/new"])
        XCTAssertTrue(channel.closed)
    }

    func testDraftsCasesFromStreamedChunks() async throws {
        let channel = ScriptedChannel.agent(chunks: [String(reply.prefix(20)), String(reply.dropFirst(20))])
        let cases = try await client(channel).draftCases(prompt, model: "claude-y")
        XCTAssertEqual(cases.map(\.title), ["Login works"])
        let blocks = params(channel, method: "session/prompt")["prompt"] as? [[String: Any]]
        XCTAssertTrue((blocks?.first?["text"] as? String)?.hasPrefix("SYS\n\nUSER") == true)
        XCTAssertTrue(channel.closed)
    }

    func testSelectsTheSavedModelWhenItIsEnabled() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        _ = try await client(channel).draftCases(prompt, model: "claude-y")
        XCTAssertEqual(params(channel, method: "session/set_model")["modelId"] as? String, "claude-y")
    }

    func testFallsBackToAutoWhenTheSavedModelIsNotEnabled() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        _ = try await client(channel).draftCases(prompt, model: "gpt-x")
        XCTAssertEqual(params(channel, method: "session/set_model")["modelId"] as? String, "auto")
    }

    func testKeepsTheAccountDefaultWhenAutoIsNotOffered() async throws {
        let models = #"{"availableModels":[{"modelId":"claude-y","name":"Claude Y","_meta":{"copilotEnablement":"enabled"}}]}"#
        let channel = ScriptedChannel.agent(models: models, chunks: [reply])
        _ = try await client(channel).draftCases(prompt, model: "gone")
        XCTAssertNil(message(channel, method: "session/set_model"))
    }

    func testCancelsEveryPermissionRequest() async throws {
        let request = #"{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"s1"}}"#
        let channel = ScriptedChannel.agent(chunks: [reply], beforeReply: [request])
        _ = try await client(channel).draftCases(prompt, model: "auto")
        let answer = channel.sent.first { ($0["id"] as? Int) == 99 && $0["method"] == nil }
        let outcome = (answer?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["outcome"] as? String, "cancelled")
    }

    func testSignInProblemsMapToNotSignedIn() async {
        let channel = ScriptedChannel.agent(fail: ["session/new": "Authentication required"])
        do {
            _ = try await client(channel).availableModels()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotNotSignedIn)
        }
        XCTAssertTrue(channel.closed)
    }

    func testQuotaErrorsMapToRateLimited() async {
        let channel = ScriptedChannel.agent(fail: ["session/prompt": "Premium request quota exceeded"])
        do {
            _ = try await client(channel).draftCases(prompt, model: "auto")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .rateLimited(.copilot))
        }
    }

    func testOtherCLIErrorsKeepTheirMessage() async {
        let channel = ScriptedChannel.agent(fail: ["session/prompt": "boom"])
        do {
            _ = try await client(channel).draftCases(prompt, model: "auto")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotFailed("boom"))
        }
    }

    func testAnAccountWithoutEnabledModelsFails() async {
        let channel = ScriptedChannel.agent(models: #"{"availableModels":[]}"#)
        do {
            _ = try await client(channel).availableModels()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotNoEnabledModels)
        }
    }

    func testUnreadableAnswerFails() async {
        let channel = ScriptedChannel.agent(chunks: ["sorry, I can't"])
        do {
            _ = try await client(channel).draftCases(prompt, model: "auto")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .unreadableReply)
        }
    }

    func testTimeoutKillsTheProcess() async {
        let channel = ScriptedChannel { _, _ in [] }
        do {
            _ = try await client(channel, timeout: 0.2).availableModels()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotFailed("The Copilot CLI did not respond in time."))
        }
        XCTAssertTrue(channel.closed)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CopilotACPClientTests`
Expected: build FAIL (`ACPChannel`, `CopilotACPClient` not defined).

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/FocusCore/CopilotCLI.swift`:

```swift
/// A line-oriented JSON channel to the Copilot CLI running as an Agent Client Protocol server.
public protocol ACPChannel: Sendable {
    /// One complete JSON message per element; finishes when the process ends.
    var lines: AsyncThrowingStream<Data, Error> { get }
    /// Sends one JSON message; the channel adds the newline.
    func send(_ line: Data) throws
    /// Stops the process. Safe to call more than once.
    func close()
}

struct ACPSession {
    let id: String
    let models: [CopilotModel]
}

/// One JSON-RPC conversation. Not reentrant: one request at a time.
final class ACPConversation: @unchecked Sendable {
    private let channel: ACPChannel
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
    private var nextID = 0
    private(set) var text = ""

    init(_ channel: ACPChannel) {
        self.channel = channel
        iterator = channel.lines.makeAsyncIterator()
    }

    func start(directory: URL) async throws -> ACPSession {
        _ = try await request("initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any]()])
        let result = try await request("session/new", ["cwd": directory.path, "mcpServers": [Any]()])
        guard let id = result["sessionId"] as? String else { throw AIError.copilotFailed("The Copilot CLI did not start a session.") }
        let models = CopilotModel.enabled(in: result)
        guard !models.isEmpty else { throw AIError.copilotNoEnabledModels }
        return ACPSession(id: id, models: models)
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while let line = try await iterator.next() {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let incoming = message["method"] as? String {
                try handle(incoming, message)
            } else if (message["id"] as? Int) == id {
                if let error = message["error"] as? [String: Any] { throw Self.map(error) }
                return message["result"] as? [String: Any] ?? [:]
            }
        }
        throw AIError.copilotFailed("The Copilot CLI exited unexpectedly.")
    }

    private func handle(_ method: String, _ message: [String: Any]) throws {
        let id = message["id"]
        if method == "session/update", id == nil {
            let update = (message["params"] as? [String: Any])?["update"] as? [String: Any]
            if update?["sessionUpdate"] as? String == "agent_message_chunk",
               let chunk = (update?["content"] as? [String: Any])?["text"] as? String {
                text += chunk
            }
        } else if let id, method == "session/request_permission" {
            try write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
        } else if let id {
            try write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not supported"]])
        }
    }

    private func write(_ object: [String: Any]) throws {
        try channel.send(JSONSerialization.data(withJSONObject: object))
    }

    static func map(_ error: [String: Any]) -> AIError {
        let message = (error["message"] as? String) ?? "Unknown error"
        let lower = message.lowercased()
        if ["auth", "log in", "login", "sign in", "signed in"].contains(where: lower.contains) { return .copilotNotSignedIn }
        if ["rate limit", "quota", "limit reached"].contains(where: lower.contains) { return .rateLimited(.copilot) }
        return .copilotFailed(String(message.prefix(300)))
    }
}

public struct CopilotACPClient: Sendable {
    let timeout: TimeInterval
    let open: @Sendable (URL) throws -> ACPChannel

    /// `open` starts the agent with the given working directory.
    public init(timeout: TimeInterval = 90, open: @escaping @Sendable (URL) throws -> ACPChannel) {
        self.timeout = timeout
        self.open = open
    }

    public func availableModels() async throws -> [CopilotModel] {
        try await run { conversation, directory in
            try await conversation.start(directory: directory).models
        }
    }

    public func draftCases(_ prompt: DraftPrompt, model: String) async throws -> [DraftCase] {
        let text = try await run { conversation, directory in
            let session = try await conversation.start(directory: directory)
            if let target = Self.modelToSelect(model, in: session.models) {
                _ = try await conversation.request("session/set_model", ["sessionId": session.id, "modelId": target])
            }
            let message = prompt.system + "\n\n" + prompt.user + "\n\nDo not use tools or read files; answer from the text above."
            _ = try await conversation.request("session/prompt", ["sessionId": session.id, "prompt": [["type": "text", "text": message]]])
            return conversation.text
        }
        let cases = try AICaseClient.parseCases(text)
        guard !cases.isEmpty else { throw AIError.noCases }
        return cases
    }

    /// The saved model if enabled, else `auto` if offered, else nil (keep the account default).
    static func modelToSelect(_ saved: String, in models: [CopilotModel]) -> String? {
        if models.contains(where: { $0.id == saved }) { return saved }
        return models.contains(where: { $0.id == "auto" }) ? "auto" : nil
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (ACPConversation, URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focustracker-copilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = try open(directory)
        defer { channel.close() }
        let conversation = ACPConversation(channel)
        let limit = timeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body(conversation, directory) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                throw AIError.copilotFailed("The Copilot CLI did not respond in time.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AIError.copilotFailed("The Copilot CLI did not reply.") }
            return first
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CopilotACPClientTests`
Expected: PASS (all 11 tests). If `testTimeoutKillsTheProcess` reports `exited unexpectedly` instead of the timeout message, the body child woke before the timer error was observed: keep the channel open until the group has finished (it is, via the outer `defer`) and re-check that nothing calls `channel.close()` inside the group.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/CopilotCLI.swift Tests/FocusCoreTests/CopilotTestSupport.swift Tests/FocusCoreTests/CopilotACPClientTests.swift
git commit -m "feat: add Copilot ACP client for model listing and case drafting"
```

---

### Task 3: CLI locator and process channel

**Files:**
- Create: `Sources/FocusCore/CopilotProcess.swift`
- Create: `Tests/FocusCoreTests/CopilotLocatorTests.swift`

**Interfaces:**
- Consumes: `ACPChannel`.
- Produces: `CopilotLocator.locate(override: String?) async -> URL?`, `CopilotLocator.path(fromShellOutput: String) -> String?`, `final class ProcessACPChannel: ACPChannel` with `init(executable: URL, directory: URL) throws`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FocusCoreTests/CopilotLocatorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CopilotLocatorTests`
Expected: build FAIL (`CopilotLocator` not defined).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/FocusCore/CopilotProcess.swift`:

```swift
import Foundation

public enum CopilotLocator {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        var value: URL? {
            get { lock.withLock { url } }
            set { lock.withLock { url = newValue } }
        }
    }

    private static let cache = Cache()

    /// The Settings override wins; otherwise the CLI found through the user's login shell, then common install folders.
    public static func locate(override: String?) async -> URL? {
        if let path = override?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let cached = cache.value, FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        let found = await Task.detached { detect() }.value
        cache.value = found
        return found
    }

    /// Shell start-up files may print banners, so only the last absolute path counts.
    static func path(fromShellOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    private static func detect() -> URL? {
        if let path = shellLookup(), FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        let fallbacks = ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot", NSHomeDirectory() + "/.local/bin/copilot"]
        return fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Interactive login shell, so `.zshrc` (where nvm usually lives) is loaded. A Finder-launched app has no such PATH.
    private static func shellLookup() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v copilot"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return path(fromShellOutput: String(decoding: data, as: UTF8.self))
    }
}

/// Runs `copilot --acp` as a child process and exposes its stdout as JSON lines.
final class ProcessACPChannel: ACPChannel, @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(executable: URL, directory: URL) throws {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream { captured = $0 }
        continuation = captured
        let stream = captured!

        process.executableURL = executable
        process.arguments = ["--acp", "--no-auto-update"]
        process.currentDirectoryURL = directory
        // The launcher is a Node script (`#!/usr/bin/env node`); a GUI app's PATH does not include nvm's node.
        var environment = ProcessInfo.processInfo.environment
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()

        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stream.finish()
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                stream.yield(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
    }

    func send(_ line: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: line + Data([0x0A]))
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        continuation.finish()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CopilotLocatorTests`
Expected: PASS. Then `swift build` to confirm `ProcessACPChannel` compiles. Its behaviour against the real CLI is checked in Task 6.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/CopilotProcess.swift Tests/FocusCoreTests/CopilotLocatorTests.swift
git commit -m "feat: locate the Copilot CLI and run it as an ACP process"
```

---

### Task 4: Store wiring

**Files:**
- Modify: `Sources/FocusCore/AppStore.swift` (`PrefKey`, `aiKeyProvider` property, `init`)
- Modify: `Sources/FocusCore/AppStore+QADrafts.swift`
- Create: `Tests/FocusCoreTests/QACopilotStoreTests.swift`

**Interfaces:**
- Consumes: `CopilotACPClient`, `CopilotLocator`, `ProcessACPChannel`, `ScriptedChannel`.
- Produces: `PrefKey.copilotPath`, `AppStore.init(..., copilotChannel: (@Sendable (URL) throws -> ACPChannel)? = nil)`, `AppStore.copilotModels() async throws -> [CopilotModel]`; `draftTestCases` and `hasAIKey` handle `.copilot`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FocusCoreTests/QACopilotStoreTests.swift`:

```swift
import XCTest
@testable import FocusCore

@MainActor
final class QACopilotStoreTests: XCTestCase {
    private let reply = #"{"cases":[{"title":"Login works","steps":"Open","expected":"In"},{"title":"Bad password"}]}"#

    private func makeStore(_ channel: ScriptedChannel) -> (AppStore, RecordingTransport) {
        let transport = RecordingTransport { _ in (404, "{}") }
        let store = AppStore(
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json"),
            defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport,
            tokenProvider: { "gh-token" }, aiKeyProvider: { _ in nil },
            copilotChannel: { _ in channel }
        )
        store.setAIProvider(.copilot)
        return (store, transport)
    }

    private func addTicket(_ store: AppStore) -> Ticket {
        let ticket = Ticket(title: "Login", body: "Users sign in", github: nil)
        store.insertTicketForTest(ticket)
        return ticket
    }

    func testCopilotNeedsNoAPIKey() {
        let (store, _) = makeStore(.agent())
        XCTAssertTrue(store.hasAIKey)
    }

    func testDraftsThroughCopilotWithoutAnyHTTPRequestOrGitHubToken() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        let (store, transport) = makeStore(channel)
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])

        XCTAssertEqual(drafts.map(\.title), ["Login works", "Bad password"])
        XCTAssertTrue(store.testCases(for: ticket.id).isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: channel.sent), as: UTF8.self)
        XCTAssertTrue(wire.contains("Users sign in"))
        XCTAssertFalse(wire.contains("gh-token"))
    }

    func testUsesTheSavedCopilotModel() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        let (store, _) = makeStore(channel)
        store.setAIModel("claude-y", for: .copilot)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
        let setModel = channel.sent.first { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual((setModel?["params"] as? [String: Any])?["modelId"] as? String, "claude-y")
    }

    func testDefaultsToAutoWhenNoModelIsSaved() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        let (store, _) = makeStore(channel)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
        let setModel = channel.sent.first { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual((setModel?["params"] as? [String: Any])?["modelId"] as? String, "auto")
    }

    func testListsTheEnabledModels() async throws {
        let (store, _) = makeStore(.agent())
        let models = try await store.copilotModels()
        XCTAssertEqual(models.map(\.id), ["auto", "claude-y"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter QACopilotStoreTests`
Expected: build FAIL (`copilotChannel` argument and `copilotModels()` not defined).

- [ ] **Step 3: Write minimal implementation**

In `Sources/FocusCore/AppStore.swift`:

- In `PrefKey`, add after `aiModelPrefix`:

```swift
    public static let copilotPath = "copilotPath"
```

- After the `aiKeyProvider` property add:

```swift
    @ObservationIgnored let copilotChannel: (@Sendable (URL) throws -> ACPChannel)?
```

- In `init`, change the last parameter list to:

```swift
        aiKeyProvider: @escaping (AIProvider) -> String? = { Keychain.get(account: $0.keychainAccount) },
        copilotChannel: (@Sendable (URL) throws -> ACPChannel)? = nil
    ) {
```

and after `self.aiKeyProvider = aiKeyProvider` add `self.copilotChannel = copilotChannel`.

In `Sources/FocusCore/AppStore+QADrafts.swift`:

Replace `public var hasAIKey: Bool { aiKey(for: aiProvider) != nil }` with:

```swift
    /// Copilot has no key to check; a missing or signed-out CLI is reported when drafting.
    public var hasAIKey: Bool { !aiProvider.usesAPIKey || aiKey(for: aiProvider) != nil }
```

In `draftTestCases`, replace

```swift
        guard let key = aiKey(for: provider) else { throw AIError.missingKey(provider) }
```

with

```swift
        let key = aiKey(for: provider)
        if provider.usesAPIKey, key == nil { throw AIError.missingKey(provider) }
```

and replace the last two lines of the function (`let client = AICaseClient(...)` / `return try await client.draftCases(prompt)`) with:

```swift
        if provider == .copilot {
            return try await copilotClient().draftCases(prompt, model: aiModel(for: provider))
        }
        let client = AICaseClient(provider: provider, model: aiModel(for: provider), apiKey: key ?? "", transport: transport)
        return try await client.draftCases(prompt)
```

Add before `addDrafts`:

```swift
    /// Models enabled for the signed-in Copilot account.
    public func copilotModels() async throws -> [CopilotModel] {
        try await copilotClient().availableModels()
    }

    private func copilotClient() async throws -> CopilotACPClient {
        if let copilotChannel { return CopilotACPClient(open: copilotChannel) }
        guard let executable = await CopilotLocator.locate(override: defaults.string(forKey: PrefKey.copilotPath)) else {
            throw AIError.copilotNotInstalled
        }
        return CopilotACPClient(open: { try ProcessACPChannel(executable: executable, directory: $0) })
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS for the whole suite (the known midnight-only `ActivityTests.testManualActivityCountsInTotalsAndLog` failure is pre-existing).

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/AppStore.swift Sources/FocusCore/AppStore+QADrafts.swift Tests/FocusCoreTests/QACopilotStoreTests.swift
git commit -m "feat: route test-case drafting through Copilot when selected"
```

---

### Task 5: Settings UI and ticket button text

**Files:**
- Modify: `Sources/FocusTracker/SettingsView.swift` (state, `aiTab`, `loadAI`)
- Modify: `Sources/FocusTracker/TicketQASection.swift:41-43`

**Interfaces:**
- Consumes: `AppStore.copilotModels()`, `CopilotModel.label`, `PrefKey.copilotPath`, `AIProvider.copilot`.
- Produces: none (UI only).

No unit tests: views are not covered by the test target. Verification is a clean `swift build` plus the manual check in Task 6.

- [ ] **Step 1: Add state**

In `SettingsView`, after `@AppStorage(PrefKey.aiProvider) ...` add:

```swift
    @AppStorage(PrefKey.copilotPath) private var copilotPath = ""
```

and after `@State private var aiMessage: String?` add:

```swift
    @State private var copilotModels: [CopilotModel] = []
    @State private var copilotStatus: String?
    @State private var copilotLoading = false
```

- [ ] **Step 2: Replace `aiTab` and `loadAI`**

Replace the whole `private var aiTab: some View { ... }` with:

```swift
    private var aiTab: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $aiProviderRaw) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: aiProviderRaw) { loadAI() }
                if aiProvider == .copilot {
                    copilotModelPicker
                } else {
                    TextField("Model", text: $aiModel, prompt: Text(aiProvider.defaultModel))
                        .onChange(of: aiModel) { store.setAIModel(aiModel, for: aiProvider) }
                    Text("Leave the model empty to use \(aiProvider.defaultModel).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if aiProvider == .copilot {
                copilotSection
            } else {
                Section("API key") {
                    SecureField("\(aiProvider.title) API key", text: $aiKey)
                        .focused($focus, equals: .aiKey)
                        .onSubmit { saveAIKey() }
                    HStack(spacing: 8) {
                        if let aiMessage {
                            Text(aiMessage).foregroundStyle(.secondary)
                        } else if aiHasKey {
                            Label("Key saved in the Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        } else {
                            Text("Paste a key and press Return to save it.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if aiHasKey {
                            Button("Remove key", role: .destructive) {
                                Keychain.delete(account: aiProvider.keychainAccount)
                                aiHasKey = false
                                aiMessage = "Key removed."
                            }
                            .buttonStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    Text("Drafting sends the ticket text and linked pull requests' titles, descriptions and changed file names to the selected provider. Keys are stored in the macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadAI() }
    }

    private var copilotModelPicker: some View {
        Picker("Model", selection: $aiModel) {
            Text("Auto").tag("")
            if !aiModel.isEmpty, !copilotModels.isEmpty, !copilotModels.contains(where: { $0.id == aiModel }) {
                Text("\(aiModel) (not enabled)").tag(aiModel)
            }
            ForEach(copilotModels.filter { $0.id != "auto" }) { Text($0.label).tag($0.id) }
        }
        .onChange(of: aiModel) { store.setAIModel(aiModel, for: aiProvider) }
    }

    private var copilotSection: some View {
        Section("GitHub Copilot") {
            TextField("CLI path", text: $copilotPath, prompt: Text("Detected automatically"))
            HStack(spacing: 8) {
                Button("Refresh models") { Task { await loadCopilotModels() } }
                    .buttonStyle(.secondary)
                    .disabled(copilotLoading)
                if copilotLoading { ProgressView().controlSize(.small) }
                if let copilotStatus { Text(copilotStatus).foregroundStyle(.secondary) }
            }
            .font(.callout)
            Text("Uses the models enabled for your Copilot account through the Copilot CLI. Sign in once with `copilot login` in a terminal; the GitHub token saved in this app is not used. Drafting sends the ticket text and linked pull requests' titles, descriptions and changed file names to GitHub Copilot.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
```

Replace `loadAI()` with:

```swift
    private func loadAI() {
        aiModel = store.aiModel(for: aiProvider) == aiProvider.defaultModel ? "" : store.aiModel(for: aiProvider)
        aiHasKey = aiProvider.usesAPIKey && Keychain.get(account: aiProvider.keychainAccount) != nil
        aiKey = ""
        aiMessage = nil
        if aiProvider == .copilot { Task { await loadCopilotModels() } }
    }

    private func loadCopilotModels() async {
        copilotLoading = true
        copilotStatus = nil
        defer { copilotLoading = false }
        do {
            copilotModels = try await store.copilotModels()
            copilotStatus = "\(copilotModels.filter { $0.id != "auto" }.count) models enabled"
        } catch {
            copilotStatus = error.localizedDescription
        }
    }
```

- [ ] **Step 3: Update the ticket button help**

In `Sources/FocusTracker/TicketQASection.swift` replace

```swift
                .help(store.hasAIKey ? "Draft cases from the ticket and its pull requests" : "Add an AI API key in Settings")
```

with

```swift
                .help(store.hasAIKey ? "Draft cases from the ticket and its pull requests" : "Set up an AI provider in Settings")
```

- [ ] **Step 4: Build and run the suite**

Run: `swift build && swift test`
Expected: build succeeds with no new warnings in the files above; tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusTracker/SettingsView.swift Sources/FocusTracker/TicketQASection.swift
git commit -m "feat: GitHub Copilot model picker and CLI path in AI settings"
```

---

### Task 6: Check against the real CLI (throwaway)

**Files:**
- Create then delete: `Tests/FocusCoreTests/ZZCopilotLiveProbe.swift`

This runs the real `copilot` with the locator and process channel but never touches `data.json`, the Keychain, or the app bundle. Listing models is free. The optional draft in Step 3 consumes one premium request.

- [ ] **Step 1: Write the probe**

```swift
import XCTest
@testable import FocusCore

final class ZZCopilotLiveProbe: XCTestCase {
    func testLive() async throws {
        let executable = await CopilotLocator.locate(override: nil)
        print("LOCATED", executable?.path ?? "nil")
        let client = CopilotACPClient { try ProcessACPChannel(executable: executable!, directory: $0) }
        let models = try await client.availableModels()
        print("MODELS", models.map(\.label))
    }

    func testSignedOutErrorShape() async throws {
        setenv("COPILOT_GITHUB_TOKEN", "invalid", 1)
        let executable = await CopilotLocator.locate(override: nil)
        let client = CopilotACPClient { try ProcessACPChannel(executable: executable!, directory: $0) }
        do { _ = try await client.availableModels() } catch { print("SIGNED-OUT ERROR", error) }
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter ZZCopilotLiveProbe 2>&1 | grep -E "LOCATED|MODELS|SIGNED-OUT|error:|passed|failed"`
Expected: `LOCATED` prints the nvm path; `MODELS` lists the account's enabled models. Record the `SIGNED-OUT ERROR` text: if it is not `copilotNotSignedIn`, add the observed keyword to the list in `ACPConversation.map` (and a test in `CopilotACPClientTests`), which closes the spec's open point.

- [ ] **Step 3 (optional): Live draft**

Add `let cases = try await client.draftCases(DraftPrompt(system: "Reply with JSON only: {\"cases\":[{\"title\":\"t\",\"steps\":[\"s\"],\"expected\":\"e\"}]}", user: "Ticket: login"), model: "auto"); print("CASES", cases)` to `testLive`, run again, and confirm one case comes back.

- [ ] **Step 4: Delete the probe and finish**

```bash
command rm Tests/FocusCoreTests/ZZCopilotLiveProbe.swift
swift test
git status --short
```

Expected: suite PASS, working tree clean (apart from any `ACPConversation.map` change; commit that with `git commit -am "fix: recognise observed Copilot sign-in error text"`).

---

## Self-Review

**Spec coverage**
- Provider `.copilot`, `defaultModel` `auto`, `usesAPIKey`: Task 1.
- Errors incl. `copilotFailed`: Task 1; mapping and timeout: Task 2.
- `CopilotModel` enabled filter and de-duplication: Task 1.
- `CopilotACPClient` (models, drafting, `set_model` rules, `cancelled` permission outcome, 90 s timeout, process killed): Task 2.
- `CopilotLocator` (override, `zsh -lic`, fallbacks, cache, PATH for the Node launcher) and process channel: Task 3.
- `hasAIKey` always true, store routing, `PrefKey.copilotPath`: Task 4.
- Settings picker, Refresh, CLI path, login note, privacy note, ticket help text: Task 5.
- Real-CLI check and the spec's open point (signed-out error shape): Task 6.
- Spec says an unparseable reply is `unreadableReply`: covered by `testUnreadableAnswerFails`.

**Placeholder scan:** none; every code step shows the code.

**Type consistency:** `ACPChannel`, `CopilotACPClient(timeout:open:)`, `availableModels()`, `draftCases(_:model:)`, `CopilotModel.enabled(in:)`, `CopilotLocator.locate(override:)`, `ProcessACPChannel(executable:directory:)`, `AppStore.copilotModels()`, `PrefKey.copilotPath` and the `copilotChannel` init parameter keep the same names and signatures across Tasks 1 to 5.
