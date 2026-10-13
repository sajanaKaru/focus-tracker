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

    /// Files at a commit with their sizes, as one listing. GitHub may truncate very large trees.
    func fetchTreeFiles(repo: String, sha: String) async throws -> [RepoFile] {
        struct Payload: Decodable {
            struct Entry: Decodable { let path: String; let type: String; let size: Int? }
            let tree: [Entry]
        }
        let (owner, name) = try Self.ownerAndName(repo)
        guard Self.isCommitSHA(sha) else { throw GitHubError.invalidResponse }
        let (data, _) = try await get(try Self.url("/repos/\(owner)/\(name)/git/trees/\(sha)?recursive=1"))
        return try JSONDecoder().decode(Payload.self, from: data).tree
            .filter { $0.type == "blob" }
            .map { RepoFile(path: $0.path, size: $0.size ?? 0) }
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

struct RepoFile: Equatable, Sendable {
    let path: String
    let size: Int
}

/// Builds the repository-scan prompts: the AI picks related files from the file list, then their text is added to the final prompt.
public enum RepoScan {
    static let maxPaths = 2500
    static let maxListChars = 40000
    static let maxFileBytes = 200_000
    static let maxFiles = 8
    static let maxFileChars = 6000
    static let maxTotalChars = 30000

    /// Readable source files, those nearest the changed files first, within the list limits. No lockfiles, generated files, big files or secrets.
    static func candidatePaths(_ files: [RepoFile], near changed: [String]) -> [String] {
        func directories(_ path: String) -> [String] {
            let parts = path.split(separator: "/").dropLast().map(String.init)
            return parts.indices.map { parts[...$0].joined(separator: "/") }
        }
        let changedDirs = Set(changed.flatMap(directories))
        // Depth of the deepest directory this file shares with a changed file.
        func closeness(_ path: String) -> Int {
            directories(path).lastIndex { changedDirs.contains($0) }.map { $0 + 1 } ?? 0
        }
        let ranked = files
            .filter { $0.size <= maxFileBytes && !DraftPrompt.isNoise($0.path) && !SensitivePaths.matches($0.path) }
            .map { (path: $0.path, score: closeness($0.path)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        var result: [String] = []
        var chars = 0
        for item in ranked {
            guard result.count < maxPaths, chars + item.path.count + 1 <= maxListChars else { break }
            result.append(item.path)
            chars += item.path.count + 1
        }
        return result
    }

    static func selectionPrompt(from base: DraftPrompt, repo: String, number: Int, paths: [String]) -> DraftPrompt {
        let system = """
        You are a QA engineer preparing a test analysis. From the ticket, the pull request and the repository's file list, \
        choose up to \(maxFiles) files you need to read to understand what the change touches or could affect: callers, shared helpers, \
        related features and existing tests. Pick only paths from the list. \
        Reply with JSON only, in this shape: {"files":["path/one","path/two"]}.
        """
        let list = "\nFiles in \(repo) at the latest commit of pull request #\(number), those nearest the change first:\n"
        return DraftPrompt(system: system, user: base.user + list + paths.joined(separator: "\n") + "\n")
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
