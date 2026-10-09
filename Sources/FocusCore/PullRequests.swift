import Foundation

public enum ReviewState: Equatable, Sendable {
    case approved, changesRequested, waiting

    /// From GitHub's `reviewDecision`; no decision or an unknown value counts as waiting.
    public init(decision: String?) {
        switch decision {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        default: self = .waiting
        }
    }
}

public enum CIState: Equatable, Sendable {
    case passing, failing, pending, noChecks

    /// From the state of the last commit's `statusCheckRollup`.
    public init(rollup: String?) {
        switch rollup {
        case "SUCCESS": self = .passing
        case "FAILURE", "ERROR": self = .failing
        case "PENDING", "EXPECTED": self = .pending
        default: self = .noChecks
        }
    }
}

/// Raw values are the display order.
public enum PullRequestGroup: Int, CaseIterable, Sendable {
    case needsAction, waiting, approved, drafts

    public var title: String {
        switch self {
        case .needsAction: "Needs action"
        case .waiting: "Waiting for review"
        case .approved: "Approved"
        case .drafts: "Drafts"
        }
    }
}

public struct PullRequestItem: Identifiable, Equatable, Sendable {
    public var repo: String
    public var number: Int
    public var title: String
    public var url: String
    public var isDraft: Bool
    public var review: ReviewState
    public var ci: CIState
    public var hasConflicts: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { "\(repo.lowercased())#\(number)" }

    public var group: PullRequestGroup {
        if isDraft { return .drafts }
        if review == .changesRequested || ci == .failing || hasConflicts { return .needsAction }
        if review == .approved { return .approved }
        return .waiting
    }

    public init(
        repo: String, number: Int, title: String, url: String, isDraft: Bool = false,
        review: ReviewState = .waiting, ci: CIState = .noChecks, hasConflicts: Bool = false,
        createdAt: Date, updatedAt: Date
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.review = review
        self.ci = ci
        self.hasConflicts = hasConflicts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PullRequestSection: Identifiable, Equatable, Sendable {
    public var group: PullRequestGroup
    public var items: [PullRequestItem]

    public var id: Int { group.rawValue }

    /// Non-empty groups in display order; waiting shows the stalest first, the rest the most recent first.
    public static func make(from items: [PullRequestItem]) -> [PullRequestSection] {
        PullRequestGroup.allCases.compactMap { group in
            let members = items.filter { $0.group == group }
            guard !members.isEmpty else { return nil }
            let sorted = group == .waiting
                ? members.sorted { $0.updatedAt < $1.updatedAt }
                : members.sorted { $0.updatedAt > $1.updatedAt }
            return PullRequestSection(group: group, items: sorted)
        }
    }
}
