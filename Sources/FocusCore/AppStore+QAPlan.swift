import Foundation

public struct QAPlanCandidate: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var state: QAState
    public var estimateMinutes: Int
    /// The ticket's latest sprint; nil when it has none.
    public var sprint: CustomField? = nil

    public var id: UUID { ticket.id }
}

/// Candidates in one sprint; a nil sprint collects tickets without one.
public struct QASprintGroup: Identifiable, Equatable, Sendable {
    public var sprint: CustomField?
    public var candidates: [QAPlanCandidate]

    public var id: String { sprint?.value ?? "" }
    public var estimateMinutes: Int { candidates.reduce(0) { $0 + $1.estimateMinutes } }

    public func isEnded(at now: Date) -> Bool { sprint?.end.map { $0 <= now } ?? false }
    public func isCurrent(at now: Date) -> Bool { sprint?.isCurrent(at: now) ?? false }
}

public enum QAPlanner {
    public static let minutesPerCase = 10
    public static let minutesWithoutCases = 30

    /// `remainingCases` are the cases not run, failed or blocked; skipped cases do not count.
    public static func estimate(totalCases: Int, remainingCases: Int) -> Int {
        totalCases == 0 ? minutesWithoutCases : max(minutesPerCase, remainingCases * minutesPerCase)
    }

    /// Takes candidates in order until the next one would not fit; always keeps the first.
    public static func autoPick(_ candidates: [QAPlanCandidate], capacityMinutes: Int) -> [UUID] {
        var remaining = capacityMinutes
        var picked: [UUID] = []
        for candidate in candidates {
            if candidate.estimateMinutes > remaining { break }
            remaining -= candidate.estimateMinutes
            picked.append(candidate.id)
        }
        if picked.isEmpty, let first = candidates.first { return [first.id] }
        return picked
    }

    public static func plannedMinutes(_ candidates: [QAPlanCandidate], ids: Set<UUID>) -> Int {
        candidates.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.estimateMinutes }
    }

    /// Of a ticket's sprints, the one that ends last.
    public static func sprint(of ticket: Ticket) -> CustomField? {
        ticket.sprints.max { ($0.end ?? .distantPast) < ($1.end ?? .distantPast) }
    }

    /// Oldest sprint first; tickets without a sprint come last.
    static func sprintPrecedes(_ a: CustomField?, _ b: CustomField?) -> Bool {
        switch (a, b) {
        case (nil, _): return false
        case (_?, nil): return true
        case let (x?, y?):
            let (ex, ey) = (x.end ?? .distantFuture, y.end ?? .distantFuture)
            return ex != ey ? ex < ey : x.value < y.value
        }
    }

    /// Keeps the candidates' order inside each group.
    public static func groupBySprint(_ candidates: [QAPlanCandidate]) -> [QASprintGroup] {
        var groups: [QASprintGroup] = []
        for candidate in candidates {
            if let index = groups.firstIndex(where: { $0.sprint?.value == candidate.sprint?.value }) {
                groups[index].candidates.append(candidate)
            } else {
                groups.append(QASprintGroup(sprint: candidate.sprint, candidates: [candidate]))
            }
        }
        return groups.sorted { sprintPrecedes($0.sprint, $1.sprint) }
    }
}

extension AppStore {
    /// Tickets to test: oldest sprint first, then failed, in testing, ready; each group newest first.
    public func qaPlanCandidates() -> [QAPlanCandidate] { qaCandidates(includeVerified: false) }

    public func qaPlanSprintGroups() -> [QASprintGroup] { QAPlanner.groupBySprint(qaPlanCandidates()) }

    func qaCandidates(includeVerified: Bool) -> [QAPlanCandidate] {
        let environments: [DeploymentEnvironment?] = [nil, .alpha, .alpha2, .beta]
        let queues = environments.map { qaQueue(environment: $0) }
        var groups: [(QAState, [Ticket])] = [
            (.failed, queues.flatMap(\.failed)), (.testing, queues.flatMap(\.testing)), (.ready, queues.flatMap(\.ready))
        ]
        if includeVerified { groups.append((.verified, queues.flatMap(\.verified))) }
        var seen = Set<UUID>()
        var result: [QAPlanCandidate] = []
        for (state, tickets) in groups {
            for ticket in tickets.sorted(by: { $0.updatedAt > $1.updatedAt }) where seen.insert(ticket.id).inserted {
                let summary = qaSummary(ticketID: ticket.id, environment: ticket.environment)
                let remaining = summary.notRun + summary.fail + summary.blocked
                result.append(QAPlanCandidate(
                    ticket: ticket, state: state,
                    estimateMinutes: QAPlanner.estimate(totalCases: summary.total, remainingCases: remaining),
                    sprint: QAPlanner.sprint(of: ticket)
                ))
            }
        }
        // Index tie-break keeps the state order inside a sprint.
        return result.enumerated().sorted { a, b in
            QAPlanner.sprintPrecedes(a.element.sprint, b.element.sprint)
                || (!QAPlanner.sprintPrecedes(b.element.sprint, a.element.sprint) && a.offset < b.offset)
        }.map(\.element)
    }

    public func qaPlan(for day: Date, calendar: Calendar = .current) -> DayPlan? {
        qaDayPlans.first { calendar.isDate($0.day, inSameDayAs: day) }
    }

    /// Returns the day's QA plan, creating it from the candidates the first time there are any.
    @discardableResult
    public func ensureQAPlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan? {
        qaPlan(for: day, calendar: calendar) ?? suggestQAPlan(for: day, calendarBusy: calendarBusy, calendar: calendar)
    }

    @discardableResult
    public func suggestQAPlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan? {
        let candidates = qaPlanCandidates()
        guard !candidates.isEmpty else { return nil }
        let capacity = capacity(for: day, calendarBusy: calendarBusy, calendar: calendar)
        let inWorkspace = Set(workspaceTickets.map(\.id))
        let hiddenPlanned = (qaPlan(for: day, calendar: calendar)?.ticketIDs ?? []).filter { !inWorkspace.contains($0) }
        let plan = DayPlan(
            day: calendar.startOfDay(for: day),
            ticketIDs: (planSettings.isWorkingDay(day, calendar: calendar)
                ? QAPlanner.autoPick(candidates, capacityMinutes: capacity.capacityMinutes) : []) + hiddenPlanned,
            createdAt: Date()
        )
        qaDayPlans.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        qaDayPlans.append(plan)
        save()
        return plan
    }

    public func toggleQAPlanned(_ ticketID: UUID, on day: Date, calendar: Calendar = .current) {
        if let index = qaDayPlans.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            if let position = qaDayPlans[index].ticketIDs.firstIndex(of: ticketID) {
                qaDayPlans[index].ticketIDs.remove(at: position)
                record(.dayPlan, ticket: ticket(ticketID), field: "Removed from QA plan")
            } else {
                qaDayPlans[index].ticketIDs.append(ticketID)
                record(.dayPlan, ticket: ticket(ticketID), field: "Added to QA plan")
            }
        } else {
            qaDayPlans.append(DayPlan(day: calendar.startOfDay(for: day), ticketIDs: [ticketID]))
            record(.dayPlan, ticket: ticket(ticketID), field: "Added to QA plan")
        }
        save()
    }
}
