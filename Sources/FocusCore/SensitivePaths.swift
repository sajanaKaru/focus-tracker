import Foundation

/// Repo-relative paths that must never be sent to an AI provider: `.git` internals, env files and keys.
enum SensitivePaths {
    private static let suffixes = [".pem", ".key", ".p12", ".pfx", ".keystore", ".mobileprovision"]
    private static let names: Set<String> = ["id_rsa", "id_ed25519", "credentials", "credentials.json", ".npmrc", ".netrc"]

    static func matches(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        guard !parts.contains(".git") else { return true }
        guard let name = parts.last else { return false }
        return name.hasPrefix(".env") || names.contains(name) || suffixes.contains { name.hasSuffix($0) }
    }
}
