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
    private var segments = [""]

    /// The last stretch of text with JSON in it (the answer comes after any tool calls), else everything.
    var answer: String {
        segments.last { !AICaseClient.jsonCandidates(in: $0).isEmpty } ?? segments.joined()
    }

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
            let type = update?["sessionUpdate"] as? String
            if type == "agent_message_chunk", let chunk = (update?["content"] as? [String: Any])?["text"] as? String {
                segments[segments.count - 1] += chunk
            } else if type == "tool_call" {
                segments.append("")
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
        // Rate limits first: "rate limit exceeded for authenticated user" is not a sign-in problem.
        if ["rate limit", "rate-limit", "too many requests", "quota", "limit reached"].contains(where: lower.contains) { return .rateLimited(.copilot) }
        let signedOut = ["authentication", "unauthenticated", "not authenticated", "unauthorized", "auth required", "log in", "login", "sign in", "signed in"]
        if signedOut.contains(where: lower.contains) { return .copilotNotSignedIn }
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
        let text = try await complete(prompt, model: model)
        let cases = try AICaseClient.parseCases(text, regression: prompt.regression)
        guard !cases.isEmpty else { throw AIError.noCases }
        return cases
    }

    /// The raw reply text. Copilot gets an empty folder and is told not to use tools.
    public func complete(_ prompt: DraftPrompt, model: String) async throws -> String {
        try await run { conversation, directory in
            let session = try await conversation.start(directory: directory)
            if let target = Self.modelToSelect(model, in: session.models) {
                _ = try await conversation.request("session/set_model", ["sessionId": session.id, "modelId": target])
            }
            let message = prompt.system + "\n\n" + prompt.user + "\n\nDo not use tools or read files; answer from the text above."
            _ = try await conversation.request("session/prompt", ["sessionId": session.id, "prompt": [["type": "text", "text": message]]])
            return conversation.answer
        }
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
        do {
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
        } catch {
            // A cancelled stream ends early, which would otherwise read as the CLI exiting.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
