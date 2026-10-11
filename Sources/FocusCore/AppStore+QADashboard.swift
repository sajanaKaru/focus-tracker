import Foundation

public struct QAPipelineRow: Identifiable, Equatable, Sendable {
    public var environment: DeploymentEnvironment
    public var ready = 0
    public var testing = 0
    public var failed = 0
    public var verified = 0

    public var id: DeploymentEnvironment { environment }
}

public struct QAPipeline: Equatable, Sendable {
    public var rows: [QAPipelineRow]
    /// Tickets already deployed to Live.
    public var liveCount: Int
}

public struct QAProgress: Equatable, Sendable {
    public var passed = 0
    public var failed = 0
    public var verified = 0
}

/// A ticket whose latest QA verdict for its environment is a failure.
public struct RetestItem: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var failedCases: Int
    public var failedAt: Date
    /// The ticket was deployed again after it failed, so it is ready to retest.
    public var redeployed: Bool

    public var id: UUID { ticket.id }
}

extension AppStore {
    public func qaPipeline() -> QAPipeline {
        let rows = [DeploymentEnvironment.alpha, .alpha2, .beta].map { environment -> QAPipelineRow in
            let queue = qaQueue(environment: environment)
            return QAPipelineRow(
                environment: environment,
                ready: queue.ready.count,
                testing: queue.testing.count,
                failed: queue.failed.count,
                verified: queue.verified.count
            )
        }
        return QAPipeline(rows: rows, liveCount: liveArchive().reduce(0) { $0 + $1.tickets.count })
    }

    public func qaProgress(in range: DateInterval) -> QAProgress {
        let ids = Set(workspaceTickets.map(\.id))
        let results = testResults.filter { ids.contains($0.ticketID) && range.contains($0.testedAt) }
        let verdicts = testVerdicts.filter { ids.contains($0.ticketID) && range.contains($0.testedAt) }
        return QAProgress(
            passed: results.filter { $0.status == .pass }.count,
            failed: results.filter { $0.status == .fail }.count,
            verified: verdicts.filter { $0.outcome == .pass }.count
        )
    }

    /// Redeployed tickets first, then the longest-failing.
    public func qaRetestList() -> [RetestItem] {
        let items = workspaceTickets.compactMap { ticket -> RetestItem? in
            let environment = ticket.environment
            guard ticket.status != .done, ticket.github?.remoteClosed != true,
                  qaState(ticketID: ticket.id, environment: environment) == .failed else { return nil }
            let verdictTimes = testVerdicts
                .filter { $0.ticketID == ticket.id && $0.environment == environment && $0.outcome == .fail }
                .map(\.testedAt)
            let resultTimes = testResults
                .filter { $0.ticketID == ticket.id && $0.environment == environment && $0.status == .fail }
                .map(\.testedAt)
            guard let failedAt = (verdictTimes + resultTimes).max() else { return nil }
            return RetestItem(
                ticket: ticket,
                failedCases: qaSummary(ticketID: ticket.id, environment: environment).fail,
                failedAt: failedAt,
                redeployed: ticket.deployment.map { $0.movedAt > failedAt } ?? false
            )
        }
        return items.sorted { $0.redeployed != $1.redeployed ? $0.redeployed : $0.failedAt < $1.failedAt }
    }

    public func qaRecentBugs(limit: Int = 10) -> [BugReport] {
        let ids = Set(workspaceTickets.map(\.id))
        return Array(bugReports.filter { ids.contains($0.ticketID) }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}
