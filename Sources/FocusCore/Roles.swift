import Foundation

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case today, tickets, board, pullRequests, specialWork, reports, actionLog, qaQueue

    public var id: String { rawValue }
}

public enum UserRole: String, CaseIterable, Identifiable, Sendable {
    case dev, qa, pm

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dev: "Developer"
        case .qa: "QA"
        case .pm: "Project Manager"
        }
    }

    public var profile: RoleProfile {
        switch self {
        case .dev:
            RoleProfile(
                sections: [.today, .tickets, .board, .pullRequests, .specialWork, .reports, .actionLog], landing: .today,
                statusOrder: [.inProgress, .inReview, .todo, .testing, .backlog, .done], captureKind: .bug
            )
        case .qa:
            RoleProfile(
                sections: [.today, .qaQueue, .tickets, .board, .reports, .actionLog], landing: .qaQueue,
                statusOrder: [.testing, .inReview, .inProgress, .todo, .backlog, .done], captureKind: .bug
            )
        case .pm:
            RoleProfile(
                sections: [.today, .qaQueue, .tickets, .board, .reports, .actionLog], landing: .board,
                statusOrder: [.inProgress, .inReview, .testing, .todo, .backlog, .done], captureKind: .request
            )
        }
    }
}

/// What a role sees first: tabs, landing view, status group order and the default quick-capture type.
public struct RoleProfile: Equatable, Sendable {
    public var sections: [AppSection]
    public var landing: AppSection
    public var statusOrder: [TicketStatus]
    public var captureKind: QuickCaptureKind
}

public enum DeploymentEnvironment: String, Codable, CaseIterable, Identifiable, Sendable {
    case alpha, alpha2, beta, live

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .alpha: "Alpha"
        case .alpha2: "Alpha2"
        case .beta: "Beta"
        case .live: "Live"
        }
    }

    /// Recognises "Deployed to Alpha2"-style project Status names; "Ready for Beta" and the like are not deployments.
    public init?(statusName: String) {
        let name = statusName.lowercased()
        guard name.contains("deploy") else { return nil }
        let compact = name.filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        if compact.contains("alpha2") { self = .alpha2 }
        else if name.contains("alpha") { self = .alpha }
        else if name.contains("beta") { self = .beta }
        else if name.contains("live") || name.contains("production") { self = .live }
        else { return nil }
    }
}

extension Ticket {
    /// Environment named by the project Status; nil for local tickets and non-deployment statuses.
    public var environment: DeploymentEnvironment? {
        projectStatusField.flatMap { DeploymentEnvironment(statusName: $0.value) }
    }
}
