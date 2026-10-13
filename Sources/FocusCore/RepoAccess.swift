import Foundation

/// Finds the local checkout of a GitHub repository under a folder the user chose.
public enum RepoLocator {
    /// `<folder>/<name>` or `<folder>/<owner>/<name>`, only when it is a git checkout.
    public static func find(repo: String, in folder: String) -> URL? {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy(isSafeComponent) else { return nil }
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath, isDirectory: true)
        let candidates = [base.appendingPathComponent(parts[1], isDirectory: true),
                          base.appendingPathComponent(parts[0], isDirectory: true).appendingPathComponent(parts[1], isDirectory: true)]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        name != "." && name != ".." && name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}

/// Decides which Copilot tool calls are allowed while it works inside a repository checkout: read-only, inside the checkout, never secrets.
enum RepoReadPolicy {
    private static let secretSuffixes = [".pem", ".key", ".p12", ".pfx", ".keystore", ".mobileprovision"]
    private static let secretNames: Set<String> = ["id_rsa", "id_ed25519", "credentials", "credentials.json", ".npmrc", ".netrc"]

    static func allows(_ toolCall: [String: Any], root: URL) -> Bool {
        guard let kind = toolCall["kind"] as? String, kind == "read" || kind == "search" else { return false }
        let paths = (toolCall["locations"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
        return !paths.isEmpty && paths.allSatisfy { isReadable($0, root: root) }
    }

    static func isReadable(_ path: String, root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard target == base || target.hasPrefix(base + "/") else { return false }
        let components = target.dropFirst(base.count).split(separator: "/").map(String.init)
        return !isSensitive(components)
    }

    /// `.git` internals, env files and keys, for a repo-relative path.
    static func isSensitive(path: String) -> Bool {
        isSensitive(path.split(separator: "/").map(String.init))
    }

    private static func isSensitive(_ components: [String]) -> Bool {
        let lower = components.map { $0.lowercased() }
        guard !lower.contains(".git") else { return true }
        guard let name = lower.last else { return false }
        return name.hasPrefix(".env") || secretNames.contains(name) || secretSuffixes.contains { name.hasSuffix($0) }
    }
}
