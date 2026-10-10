import Foundation

/// A slice of GitHub by repo owner: your own account is Personal, every other owner is an organization.
public enum Workspace: Hashable, Sendable {
    case all, personal, organization(String)

    public var title: String {
        switch self {
        case .all: "All workspaces"
        case .personal: "Personal"
        case .organization(let name): name
        }
    }

    public var storageValue: String {
        switch self {
        case .all: "all"
        case .personal: "personal"
        case .organization(let name): "org:\(name)"
        }
    }

    public init(storageValue: String?) {
        switch storageValue {
        case "personal": self = .personal
        case let value? where value.hasPrefix("org:"): self = .organization(String(value.dropFirst(4)))
        default: self = .all
        }
    }

    /// Workspace of an "owner/name" repo; `login` is the signed-in user.
    public static func of(repo: String, login: String) -> Workspace {
        let owner = repo.split(separator: "/").first.map(String.init) ?? repo
        return owner.caseInsensitiveCompare(login) == .orderedSame ? .personal : .organization(owner)
    }

    /// Items without a repo (local tickets) belong to Personal.
    public func contains(repo: String?, login: String) -> Bool {
        if self == .all { return true }
        guard let repo else { return self == .personal }
        switch (self, Workspace.of(repo: repo, login: login)) {
        case (.personal, .personal): return true
        case (.organization(let a), .organization(let b)): return a.caseInsensitiveCompare(b) == .orderedSame
        default: return false
        }
    }
}
