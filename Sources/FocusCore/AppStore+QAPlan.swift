import Foundation

public struct QAPlanCandidate: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var state: QAState
    public var estimateMinutes: Int

    public var id: UUID { ticket.id }
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
}

extension AppStore {
    /// Tickets to test: failed first, then in testing, then ready; each group newest first.
    public func qaPlanCandidates() -> [QAPlanCandidate] {
        let environments: [DeploymentEnvironment?] = [nil, .alpha, .alpha2, .beta]
        let queues = environments.map { qaQueue(environment: $0) }
        let groups: [(QAState, [Ticket])] = [
            (.failed, queues.flatMap(\.failed)), (.testing, queues.flatMap(\.testing)), (.ready, queues.flatMap(\.ready))
        ]
        var seen = Set<UUID>()
        var result: [QAPlanCandidate] = []
        for (state, tickets) in groups {
            for ticket in tickets.sorted(by: { $0.updatedAt > $1.updatedAt }) where seen.insert(ticket.id).inserted {
                let summary = qaSummary(ticketID: ticket.id, environment: ticket.environment)
                let remaining = summary.notRun + summary.fail + summary.blocked
                result.append(QAPlanCandidate(
                    ticket: ticket, state: state,
                    estimateMinutes: QAPlanner.estimate(totalCases: summary.total, remainingCases: remaining)
                ))
            }
        }
        return result
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
