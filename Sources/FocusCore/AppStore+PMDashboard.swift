import Foundation

public enum PMDashboard {
    /// An in-flight ticket with no GitHub activity for this many days is stale.
    public static let staleDays = 3
}

public struct SprintProgress: Equatable, Sendable {
    public var name: String
    public var total: Int
    public var done: Int
    public var byStatus: [TicketStatus: Int]
    public var daysLeft: Int?

    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

public struct PMPipelineRow: Identifiable, Equatable, Sendable {
    public var environment: DeploymentEnvironment
    public var count: Int
    public var readyToPromote: Int

    public var id: DeploymentEnvironment { environment }
}

/// The raw value ranks the reason: lower is more urgent.
public enum RiskReason: Int, Sendable {
    case overdue, failedQA, stale

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .failedQA: "Failed QA"
        case .stale: "Stale"
        }
    }
}

public struct RiskItem: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var reason: RiskReason

    public var id: UUID { ticket.id }
}

public struct WorkloadRow: Identifiable, Equatable, Sendable {
    public static let unassigned = "Unassigned"

    public var assignee: String
    public var open: Int
    public var inFlight: Int
    public var estimateMinutes: Int

    public var id: String { assignee }
    public var isUnassigned: Bool { assignee == Self.unassigned }
}

extension AppStore {
    private var openWorkspaceTickets: [Ticket] {
        workspaceTickets.filter { $0.status != .done && $0.github?.remoteClosed != true }
    }

    // MARK: - Sprint

    /// The current sprint (the one most tickets are in), else the open milestone due first; nil with neither.
    public func pmSprintProgress(calendar: Calendar = .current) -> SprintProgress? {
        let all = workspaceTickets
        var counts: [String: Int] = [:]
        var ends: [String: Date] = [:]
        for ticket in all {
            for sprint in ticket.sprints where sprint.isCurrent(at: now) {
                counts[sprint.value, default: 0] += 1
                if let end = sprint.end { ends[sprint.value] = end }
            }
        }
        if let name = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key {
            let scope = all.filter { ticket in ticket.sprints.contains { $0.value == name && $0.isCurrent(at: now) } }
            return progress(name: name, tickets: scope, end: ends[name], calendar: calendar)
        }

        let groups = Dictionary(grouping: all.filter { $0.milestone?.isOpen == true }) { $0.milestone!.title }
        let due: (String) -> Date? = { groups[$0]?.first?.milestone?.dueOn }
        let title = groups.keys.min { lhs, rhs in
            switch (due(lhs), due(rhs)) {
            case let (l?, r?): l != r ? l < r : lhs < rhs
            case (_?, nil): true
            case (nil, _?): false
            default: lhs < rhs
            }
        }
        guard let title, let tickets = groups[title] else { return nil }
        return progress(name: title, tickets: tickets, end: due(title), calendar: calendar)
    }

    private func progress(name: String, tickets: [Ticket], end: Date?, calendar: Calendar) -> SprintProgress {
        var byStatus: [TicketStatus: Int] = [:]
        for ticket in tickets { byStatus[ticket.status, default: 0] += 1 }
        let daysLeft = end.map {
            max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: $0)).day ?? 0)
        }
        return SprintProgress(name: name, total: tickets.count, done: byStatus[.done] ?? 0, byStatus: byStatus, daysLeft: daysLeft)
    }

    // MARK: - Pipeline

    public func pmPipeline() -> [PMPipelineRow] {
        let tickets = workspaceTickets
        return DeploymentEnvironment.allCases.map { environment in
            let inEnvironment = tickets.filter { $0.environment == environment }
            let ready = environment == .live ? 0 : inEnvironment.filter { qaState(ticketID: $0.id, environment: environment) == .verified }.count
            return PMPipelineRow(environment: environment, count: inEnvironment.count, readyToPromote: ready)
        }
    }

    // MARK: - Risks

    public func pmRisks(calendar: Calendar = .current) -> [RiskItem] {
        let today = calendar.startOfDay(for: now)
        let staleBefore = now.addingTimeInterval(-Double(PMDashboard.staleDays) * 86_400)
        let items = openWorkspaceTickets.compactMap { ticket -> RiskItem? in
            let due = DayPlanner.dueDate(of: ticket)
            let milestoneDue = ticket.milestone.flatMap { $0.isOpen ? $0.dueOn : nil }
            if let date = [due, milestoneDue].compactMap({ $0 }).min(), date < today { return RiskItem(ticket: ticket, reason: .overdue) }
            if qaState(ticketID: ticket.id, environment: ticket.environment) == .failed { return RiskItem(ticket: ticket, reason: .failedQA) }
            if ticket.status.isInFlight, let updated = ticket.remoteUpdatedAt, updated < staleBefore { return RiskItem(ticket: ticket, reason: .stale) }
            return nil
        }
        return items.sorted { $0.reason != $1.reason ? $0.reason.rawValue < $1.reason.rawValue : $0.ticket.title < $1.ticket.title }
    }

    // MARK: - Workload

    /// Open GitHub tickets per assignee; a ticket with several assignees counts for each.
    public func pmWorkload() -> [WorkloadRow] {
        var rows: [String: WorkloadRow] = [:]
        for ticket in openWorkspaceTickets where ticket.github != nil {
            let logins = (ticket.assignees ?? []).isEmpty ? [WorkloadRow.unassigned] : ticket.assignees!
            for login in logins {
                var row = rows[login] ?? WorkloadRow(assignee: login, open: 0, inFlight: 0, estimateMinutes: 0)
                row.open += 1
                if ticket.status.isInFlight { row.inFlight += 1 }
                row.estimateMinutes += ticket.effectiveEstimateMinutes ?? 0
                rows[login] = row
            }
        }
        return rows.values.sorted {
            if $0.open != $1.open { return $0.open > $1.open }
            if $0.isUnassigned != $1.isUnassigned { return $1.isUnassigned }
            return $0.assignee.localizedCaseInsensitiveCompare($1.assignee) == .orderedAscending
        }
    }

    // MARK: - Incoming

    /// Backlog tickets outside any sprint, and quick captures; newest first.
    public func pmIncoming(limit: Int = 8) -> [Ticket] {
        let incoming = openWorkspaceTickets.filter { ($0.status == .backlog && $0.sprints.isEmpty) || $0.isQuickCapture == true }
        return Array(incoming.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    // MARK: - Summary

    public func pmSummarySections() -> [SummarySection] {
        func item(_ ticket: Ticket, note: String? = nil) -> SummaryItem {
            var notes = ticket.github == nil ? [] : [ticket.title]
            if let note { notes.append(note) }
            return SummaryItem(text: ticket.github?.url ?? ticket.title, isLink: ticket.github != nil, notes: notes)
        }

        var sections: [SummarySection] = []
        if let progress = pmSprintProgress() {
            var text = "\(progress.name): \(progress.done)/\(progress.total) done (\(Int((progress.fraction * 100).rounded()))%)"
            if let left = progress.daysLeft { text += ", \(left) day\(left == 1 ? "" : "s") left" }
            sections.append(SummarySection(title: "Progress", items: [SummaryItem(text: text)]))
        }
        let inFlight = openWorkspaceTickets.filter { $0.status.isInFlight }.sorted { $0.displayKey < $1.displayKey }.prefix(15)
        if !inFlight.isEmpty { sections.append(SummarySection(title: "In flight", items: inFlight.map { item($0) })) }
        let risks = pmRisks()
        if !risks.isEmpty { sections.append(SummarySection(title: "At risk", items: risks.map { item($0.ticket, note: $0.reason.title) })) }
        let promote = workspaceTickets.filter { ticket in
            guard let environment = ticket.environment, environment != .live else { return false }
            return qaState(ticketID: ticket.id, environment: environment) == .verified
        }
        if !promote.isEmpty {
            sections.append(SummarySection(title: "Ready to promote", items: promote.map { item($0, note: $0.environment?.title) }))
        }
        return sections
    }

    public func pmSummaryText() -> String {
        let heading = now.formatted(date: .complete, time: .omitted) + "\n--------\n"
        let sections = pmSummarySections()
        guard !sections.isEmpty else { return heading + "(nothing to report)" }
        return heading + sections.map { section in
            ([section.title] + section.items.flatMap { ["- \($0.text)"] + $0.notes.map { "  - \($0)" } }).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    public func pmSummaryHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let heading = "<div>\(esc(now.formatted(date: .complete, time: .omitted)))</div><div>--------</div>"
        let sections = pmSummarySections()
        guard !sections.isEmpty else { return heading + "<p>(nothing to report)</p>" }
        return heading + sections.map { section in
            let items = section.items.map { item -> String in
                let label = item.isLink && item.text.hasPrefix("https://") ? "<a href=\"\(esc(item.text))\">\(esc(item.text))</a>" : esc(item.text)
                let notes = item.notes.isEmpty ? "" : "<ul>" + item.notes.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
                return "<li>\(label)\(notes)</li>"
            }.joined()
            return "<div>\(esc(section.title))</div><ul>\(items)</ul>"
        }.joined()
    }
}
