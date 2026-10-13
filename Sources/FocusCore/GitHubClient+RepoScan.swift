import Foundation

extension GitHubClient {
    /// The commit a pull request's branch points at.
    func fetchPullRequestHead(repo: String, number: Int) async throws -> String {
        struct Payload: Decodable {
            struct Head: Decodable { let sha: String }
            let head: Head
        }
        let (owner, name) = try Self.ownerAndName(repo)
        let (data, _) = try await get(try Self.url("/repos/\(owner)/\(name)/pulls/\(number)"))
        let sha = try JSONDecoder().decode(Payload.self, from: data).head.sha
        guard Self.isCommitSHA(sha) else { throw GitHubError.invalidResponse }
        return sha
    }

    /// File paths at a commit, as one listing. GitHub may truncate very large trees.
    func fetchTreePaths(repo: String, sha: String) async throws -> [String] {
        struct Payload: Decodable {
            struct Entry: Decodable { let path: String; let type: String }
            let tree: [Entry]
        }
        let (owner, name) = try Self.ownerAndName(repo)
        guard Self.isCommitSHA(sha) else { throw GitHubError.invalidResponse }
        let (data, _) = try await get(try Self.url("/repos/\(owner)/\(name)/git/trees/\(sha)?recursive=1"))
        return try JSONDecoder().decode(Payload.self, from: data).tree.filter { $0.type == "blob" }.map(\.path)
    }

    /// A file's text at a commit, cut to `maxChars`; nil for binary content.
    func fetchFileText(repo: String, path: String, sha: String, maxChars: Int) async throws -> String? {
        let (owner, name) = try Self.ownerAndName(repo)
        guard Self.isCommitSHA(sha) else { throw GitHubError.invalidResponse }
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "" }
        guard !encoded.contains(where: \.isEmpty) else { throw GitHubError.invalidResponse }
        let url = try Self.url("/repos/\(owner)/\(name)/contents/\(encoded.joined(separator: "/"))?ref=\(sha)")
        var raw = request(for: url)
        raw.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await send(raw)
        let head = data.prefix(maxChars * 4)
        guard !head.contains(0) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        return text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
    }

    private static func url(_ pathAndQuery: String) throws -> URL {
        guard let url = URL(string: "https://\(apiHost)\(pathAndQuery)") else { throw GitHubError.invalidResponse }
        return url
    }

    private static func ownerAndName(_ repo: String) throws -> (String, String) {
        let parts = repo.split(separator: "/").map(String.init)
        let safe = #"^[A-Za-z0-9._-]+$"#
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: safe, options: .regularExpression) != nil && $0 != "." && $0 != ".." }) else {
            throw GitHubError.invalidResponse
        }
        return (parts[0], parts[1])
    }

    private static func isCommitSHA(_ sha: String) -> Bool {
        sha.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
    }
}

/// Builds the "scan the GitHub repository" prompts: the AI picks related files from the file list, then their text is added to the final prompt.
public enum RepoScan {
    static let maxPaths = 2500
    static let maxFiles = 8
    static let maxFileChars = 6000
    static let maxTotalChars = 30000

    /// Source-like paths only: no lockfiles, generated files, build folders or secrets.
    static func candidatePaths(_ all: [String]) -> [String] {
        Array(all.filter { !DraftPrompt.isNoise($0) && !RepoReadPolicy.isSensitive(path: $0) }.sorted().prefix(maxPaths))
    }

    static func selectionPrompt(from base: DraftPrompt, paths: [String]) -> DraftPrompt {
        let system = """
        You are a QA engineer preparing a test analysis. From the ticket, the pull request and the repository's file list, \
        choose up to \(maxFiles) files you need to read to understand what the change touches or could affect: callers, shared helpers, \
        related features and existing tests. Pick only paths from the list. \
        Reply with JSON only, in this shape: {"files":["path/one","path/two"]}.
        """
        return DraftPrompt(system: system, user: base.user + "\nRepository files:\n" + paths.joined(separator: "\n") + "\n")
    }

    /// Paths from the reply that exist in `allowed`, without duplicates, at most `maxFiles`.
    static func parseSelection(_ text: String, allowed: Set<String>) -> [String] {
        for candidate in AICaseClient.jsonCandidates(in: text) {
            guard let data = candidate.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            guard let names = (value as? [String]) ?? (value as? [String: Any])?["files"] as? [String] else { continue }
            var seen = Set<String>()
            return Array(names.filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(maxFiles))
        }
        return []
    }

    static func section(repo: String, files: [(path: String, text: String)]) -> String {
        guard !files.isEmpty else { return "" }
        return "\nRelated files in \(repo) (read from GitHub at the pull request's latest commit):\n"
            + files.map { "--- \($0.path)\n\($0.text)\n" }.joined()
    }
}
