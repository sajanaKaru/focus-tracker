import Foundation

public enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAI, anthropic, gemini, copilot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .copilot: "GitHub Copilot"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .anthropic: "claude-sonnet-4-5"
        case .gemini: "gemini-2.5-flash"
        case .copilot: "auto"
        }
    }

    public var keychainAccount: String { "ai-key-\(rawValue)" }

    /// Copilot signs in through the Copilot CLI instead of a key.
    public var usesAPIKey: Bool { self != .copilot }
}

public struct DraftCase: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var steps: String
    public var expected: String

    public init(title: String, steps: String = "", expected: String = "") {
        self.title = title
        self.steps = steps
        self.expected = expected
    }
}

public enum AIError: LocalizedError, Equatable {
    case missingKey(AIProvider)
    case unauthorized(AIProvider)
    case rateLimited(AIProvider)
    case http(Int, AIProvider)
    case invalidModel
    case modelNotFound(String, AIProvider, String)
    case unreadableReply
    case noCases
    case copilotNotInstalled
    case copilotNotSignedIn
    case copilotNoEnabledModels
    case copilotFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let p): "Add a \(p.title) API key in Settings."
        case .unauthorized(let p): "\(p.title) rejected the API key. Check it in Settings."
        case .rateLimited(let p): "\(p.title) rate limit reached. Try again later."
        case .http(let code, let p): "\(p.title) returned HTTP \(code)."
        case .invalidModel: "The model name is not valid. Check it in Settings."
        case .modelNotFound(let m, let p, let detail): "\(p.title) returned 404 for model \"\(m)\": \(detail)"
        case .unreadableReply: "The AI reply could not be read. Try again."
        case .noCases: "The AI returned no test cases."
        case .copilotNotInstalled: "GitHub Copilot CLI not found. Install it or set its path in Settings."
        case .copilotNotSignedIn: "Run `copilot login` in a terminal, then try again."
        case .copilotNoEnabledModels: "Your GitHub Copilot account has no enabled models."
        case .copilotFailed(let message): "GitHub Copilot: \(message)"
        }
    }
}

public struct DraftPrompt: Equatable, Sendable {
    public var system: String
    public var user: String

    static let maxTicketBody = 4000
    static let maxPRBody = 3000
    static let maxFiles = 100
    static let maxPatchPerFile = 4000
    static let maxPatchTotal = 24000

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }

    public static func make(ticketKey: String, title: String, body: String, pullRequests: [PullRequestDetail]) -> DraftPrompt {
        var system = """
        You are a QA engineer. From the ticket and pull request details, write concise manual test cases that verify the change. \
        Cover the main behavior, edge cases and likely regressions. \
        Reply with JSON only, in this shape: {"cases":[{"title":"...","steps":["..."],"expected":"..."}]}. \
        Write 3 to 10 cases. Do not invent features that are not described.
        """
        if pullRequests.contains(where: { $0.patches.contains { !($0.patch ?? "").isEmpty } }) {
            system += " Use the code changes to make steps and expected results specific, and do not invent behavior that is not visible in them."
        }
        var user = "Ticket \(ticketKey): \(title)\n\n\(clip(body, maxTicketBody))\n"
        if pullRequests.isEmpty {
            user += "\nNo linked pull request.\n"
        }
        var codeBudget = maxPatchTotal
        for pr in pullRequests {
            user += "\nPull request \(pr.repo)#\(pr.number): \(pr.title)\n\(clip(pr.body, maxPRBody))\n"
            let files = pr.files.prefix(maxFiles)
            if !files.isEmpty {
                user += "Changed files:\n" + files.joined(separator: "\n") + "\n"
                if pr.files.count > maxFiles { user += "…and \(pr.files.count - maxFiles) more\n" }
            }
            user += codeSection(pr.patches, budget: &codeBudget)
        }
        return DraftPrompt(system: system, user: user)
    }

    /// Patch text shared across all pull requests by one budget; lockfiles, generated files and images are left out.
    private static func codeSection(_ patches: [PullRequestFilePatch], budget: inout Int) -> String {
        var out = ""
        var hidden = 0
        for file in patches {
            guard let patch = file.patch, !patch.isEmpty, !isNoise(file.path) else { continue }
            guard budget > 0 else { hidden += 1; continue }
            let text = clip(patch, min(maxPatchPerFile, budget))
            budget -= text.count
            out += "--- \(file.path) (\(file.status))\n\(text)\n"
        }
        if hidden > 0 { out += "…and \(hidden) more changed files not shown\n" }
        return out.isEmpty ? "" : "Code changes:\n" + out
    }

    private static let noiseNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "package.resolved", "podfile.lock", "cargo.lock",
        "composer.lock", "gemfile.lock", "go.sum"
    ]
    private static let noiseSuffixes = [
        ".lock", ".min.js", ".min.css", ".map", ".pbxproj", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".pdf"
    ]
    private static let noiseFolders: Set<String> = ["node_modules", "dist", "pods", ".build"]

    private static func isNoise(_ path: String) -> Bool {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        guard let name = parts.last else { return true }
        return noiseNames.contains(name) || noiseSuffixes.contains { name.hasSuffix($0) } || !noiseFolders.isDisjoint(with: parts.dropLast())
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}

public struct AICaseClient: Sendable {
    let provider: AIProvider
    let model: String
    let apiKey: String
    let transport: HTTPTransport

    public init(provider: AIProvider, model: String, apiKey: String, transport: HTTPTransport = URLSessionTransport()) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    public func draftCases(_ prompt: DraftPrompt) async throws -> [DraftCase] {
        let request = try makeRequest(prompt)
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw AIError.unauthorized(provider)
        case 429: throw AIError.rateLimited(provider)
        case 404: throw AIError.modelNotFound(model, provider, Self.errorDetail(data))
        default: throw AIError.http(response.statusCode, provider)
        }
        guard let text = replyText(data) else { throw AIError.unreadableReply }
        let cases = try Self.parseCases(text)
        guard !cases.isEmpty else { throw AIError.noCases }
        return cases
    }

    private static func errorDetail(_ data: Data) -> String {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (root?["error"] as? [String: Any])?["message"] as? String
        return String((message ?? String(decoding: data, as: UTF8.self)).prefix(300))
    }

    // MARK: Requests

    private func makeRequest(_ prompt: DraftPrompt) throws -> URLRequest {
        let url: URL
        let payload: [String: Any]
        var headers: [String: String] = ["Content-Type": "application/json"]
        switch provider {
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            headers["Authorization"] = "Bearer \(apiKey)"
            payload = [
                "model": model,
                "response_format": ["type": "json_object"],
                "messages": [["role": "system", "content": prompt.system], ["role": "user", "content": prompt.user]]
            ]
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
            payload = [
                "model": model, "max_tokens": 4096, "system": prompt.system,
                "messages": [["role": "user", "content": prompt.user]]
            ]
        case .gemini:
            guard model.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil, model != ".", model != ".." else {
                throw AIError.invalidModel
            }
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            headers["x-goog-api-key"] = apiKey
            payload = [
                "systemInstruction": ["parts": [["text": prompt.system]]],
                "contents": [["role": "user", "parts": [["text": prompt.user]]]],
                "generationConfig": ["responseMimeType": "application/json"]
            ]
        case .copilot:
            throw AIError.copilotFailed("Copilot drafts do not go through HTTP.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    // MARK: Responses

    private func replyText(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch provider {
        case .openAI:
            let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            return message?["content"] as? String
        case .anthropic:
            let blocks = root["content"] as? [[String: Any]]
            return blocks?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .gemini:
            let content = (root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
            return (content?["parts"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .copilot:
            return nil
        }
    }

    /// Accepts `{"cases":[…]}` or a bare array, inside optional prose or code fences.
    static func parseCases(_ text: String) throws -> [DraftCase] {
        guard let json = jsonSlice(of: text), let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { throw AIError.unreadableReply }
        let items: [[String: Any]]
        if let array = value as? [[String: Any]] {
            items = array
        } else if let object = value as? [String: Any], let array = object["cases"] as? [[String: Any]] {
            items = array
        } else {
            throw AIError.unreadableReply
        }
        return items.compactMap { item in
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return DraftCase(title: title, steps: stepsText(item["steps"]), expected: (item["expected"] as? String) ?? "")
        }
    }

    private static func stepsText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let list = value as? [String] else { return "" }
        return list.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    private static func jsonSlice(of text: String) -> String? {
        let openers: [(Character, Character)] = [("{", "}"), ("[", "]")]
        let candidates = openers.compactMap { open, close -> (String.Index, String.Index)? in
            guard let start = text.firstIndex(of: open), let end = text.lastIndex(of: close), start < end else { return nil }
            return (start, end)
        }
        guard let best = candidates.min(by: { $0.0 < $1.0 }) else { return nil }
        return String(text[best.0...best.1])
    }
}
