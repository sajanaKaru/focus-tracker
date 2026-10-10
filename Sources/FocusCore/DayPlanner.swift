import Foundation

public struct PlanSettings: Equatable, Sendable {
    public var workingMinutes: Int
    public var focusFactor: Double
    public var defaultEstimateMinutes: Int
    /// 5 = Monday to Friday, 6 = Monday to Saturday, 7 = every day.
    public var workDays: Int

    public init(workingMinutes: Int = 480, focusFactor: Double = 0.75, defaultEstimateMinutes: Int = 60, workDays: Int = 7) {
        self.workingMinutes = workingMinutes
        self.focusFactor = focusFactor
        self.defaultEstimateMinutes = defaultEstimateMinutes
        self.workDays = workDays
    }

    public func isWorkingDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        switch workDays {
        case 7...: return true
        case 6: return weekday != 1
        default: return (2...6).contains(weekday)
        }
    }

    /// The first working day after `date`, at the start of that day.
    public func nextWorkingDay(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        for offset in 1...7 {
            if let next = calendar.date(byAdding: .day, value: offset, to: start), isWorkingDay(next, calendar: calendar) { return next }
        }
        return start
    }
}

public struct Capacity: Equatable, Sendable {
    /// Working time left after meetings and logged activities.
    public var freeMinutes: Int
    /// Free time scaled by the focus factor.
    public var capacityMinutes: Int
}

/// Why a ticket is suggested; the raw value is its rank (lower is stronger).
public enum PlanReason: Int, Sendable {
    case dueNow, carriedOver, inProgress, dueSoon, sprintEnding, inSprint, priority, open

    public var title: String {
        switch self {
        case .dueNow: "Due now"
        case .carriedOver: "Carried over"
        case .inProgress: "In progress"
        case .dueSoon: "Due soon"
        case .sprintEnding: "Sprint ends soon"
        case .inSprint: "In sprint"
        case .priority: "Priority"
        case .open: "Open"
        }
    }
}

public struct PlanCandidate: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var reason: PlanReason
    /// Estimate still to do: the ticket estimate minus time already tracked and work planned on earlier days.
    public var estimateMinutes: Int
    /// True when the ticket has no estimate and the default was used.
    public var estimatedByApp: Bool
    public var trackedMinutes: Int = 0
    /// Time earlier planned days are expected to use of this ticket; projected, never saved.
    public var plannedAheadMinutes: Int = 0

    public var id: UUID { ticket.id }
}

/// How today is going: planned vs. unplanned time and what is left of the capacity.
public struct DayLoad: Equatable, Sendable {
    /// Ticket time today on planned tickets.
    public var plannedTrackedMinutes: Int
    /// Ticket time today off the plan plus ad-hoc (non-calendar) activities.
    public var unplannedMinutes: Int
    /// Estimate left on planned, unfinished tickets.
    public var remainingPlannedMinutes: Int
    /// Capacity left today; negative when overloaded.
    public var remainingTodayMinutes: Int

    public var isOverloaded: Bool { remainingTodayMinutes < 0 }
    public var overloadMinutes: Int { max(0, -remainingTodayMinutes) }
}

public enum DayPlanner {
    public static func capacity(day: DateInterval, busy: [DateInterval], settings: PlanSettings, calendar: Calendar = .current) -> Capacity {
        guard settings.isWorkingDay(day.start, calendar: calendar) else { return Capacity(freeMinutes: 0, capacityMinutes: 0) }
        let free = max(0, settings.workingMinutes - busyMinutes(busy, within: day))
        return Capacity(freeMinutes: free, capacityMinutes: Int((Double(free) * settings.focusFactor).rounded()))
    }

    /// Minutes covered by the union of `busy`, clipped to `day`.
    static func busyMinutes(_ busy: [DateInterval], within day: DateInterval) -> Int {
        let clipped = busy
            .compactMap { $0.intersection(with: day) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in clipped {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                if let open = current { total += open.duration }
                current = interval
            }
        }
        if let open = current { total += open.duration }
        return Int((total / 60).rounded())
    }

    public static func rank(
        tickets: [Ticket], carriedOver: Set<UUID>, now: Date, settings: PlanSettings, calendar: Calendar = .current,
        trackedMinutes: [UUID: Int] = [:], plannedAheadMinutes: [UUID: Int] = [:]
    ) -> [PlanCandidate] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let soonLimit = calendar.date(byAdding: .day, value: 3, to: today) ?? today

        func reason(for ticket: Ticket) -> PlanReason {
            let due = dueDate(of: ticket)
            if let due, due < tomorrow { return .dueNow }
            if carriedOver.contains(ticket.id) { return .carriedOver }
            if ticket.status.isInFlight { return .inProgress }
            if let due, due < soonLimit { return .dueSoon }
            if ticket.sprints.contains(where: { $0.isCurrent(at: now) && ($0.end ?? .distantFuture) < soonLimit }) {
                return .sprintEnding
            }
            if ticket.sprints.contains(where: { $0.isCurrent(at: now) }) { return .inSprint }
            return ticket.priority == .none ? .open : .priority
        }

        return tickets
            .filter { ($0.status == .todo || $0.status.isInFlight) && $0.github?.remoteClosed != true }
            .map { ticket -> PlanCandidate in
                let tracked = trackedMinutes[ticket.id] ?? 0
                let ahead = plannedAheadMinutes[ticket.id] ?? 0
                return PlanCandidate(
                    ticket: ticket,
                    reason: reason(for: ticket),
                    estimateMinutes: max(0, remainingMinutes(of: ticket, tracked: tracked, settings: settings) - ahead),
                    estimatedByApp: ticket.effectiveEstimateMinutes == nil,
                    trackedMinutes: tracked,
                    plannedAheadMinutes: ahead
                )
            }
            .sorted {
                if $0.reason != $1.reason { return $0.reason.rawValue < $1.reason.rawValue }
                if $0.ticket.priority != $1.ticket.priority { return $0.ticket.priority.rawValue > $1.ticket.priority.rawValue }
                return $0.ticket.updatedAt < $1.ticket.updatedAt
            }
    }

    /// Estimate minus time already tracked, never below zero; the default estimate stands in when the ticket has none.
    public static func remainingMinutes(of ticket: Ticket, tracked: Int, settings: PlanSettings) -> Int {
        max(0, (ticket.effectiveEstimateMinutes ?? settings.defaultEstimateMinutes) - tracked)
    }

    /// How much of each ticket the given planned days (oldest first) are expected to use up, assuming each plan is followed.
    /// Planned tickets on a day share its capacity in order; tickets missing from `remaining` are ignored.
    public static func plannedAhead(
        plans: [(capacityMinutes: Int, ticketIDs: [UUID])], remaining: [UUID: Int]
    ) -> [UUID: Int] {
        var ahead: [UUID: Int] = [:]
        for plan in plans {
            var capacityLeft = plan.capacityMinutes
            for id in plan.ticketIDs {
                guard let total = remaining[id] else { continue }
                let used = min(max(0, total - (ahead[id] ?? 0)), capacityLeft)
                guard used > 0 else { continue }
                ahead[id, default: 0] += used
                capacityLeft -= used
            }
        }
        return ahead
    }

    /// Takes candidates in rank order until the next one would not fit; always keeps the first.
    public static func autoPick(_ candidates: [PlanCandidate], capacityMinutes: Int) -> [UUID] {
        var remaining = capacityMinutes
        var picked: [UUID] = []
        for candidate in candidates {
            if candidate.estimateMinutes > remaining {
                // Unfinished work bigger than the day is still planned and takes what is left.
                if candidate.reason == .carriedOver || candidate.reason == .inProgress { picked.append(candidate.id) }
                break
            }
            remaining -= candidate.estimateMinutes
            picked.append(candidate.id)
        }
        if picked.isEmpty, let first = candidates.first { return [first.id] }
        return picked
    }

    /// With `capacityMinutes`, each ticket counts at most one day's capacity.
    public static func plannedMinutes(_ candidates: [PlanCandidate], ids: Set<UUID>, capacityMinutes: Int? = nil) -> Int {
        candidates.filter { ids.contains($0.id) }.reduce(0) { $0 + min($1.estimateMinutes, capacityMinutes ?? .max) }
    }

    public static func load(
        plannedIDs: Set<UUID>, tickets: [Ticket], entries: [TimeEntry], activities: [Activity],
        capacityMinutes: Int, day: DateInterval, now: Date, settings: PlanSettings
    ) -> DayLoad {
        func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }

        let byTicket = Dictionary(grouping: entries, by: \.ticketID)
        let todayByTicket = byTicket.mapValues { $0.reduce(0) { $0 + $1.duration(in: day, at: now) } }
        let totalByTicket = byTicket.mapValues { $0.reduce(0) { $0 + $1.duration(at: now) } }

        let ticketToday = todayByTicket.values.reduce(0, +)
        let plannedToday = plannedIDs.reduce(0.0) { $0 + (todayByTicket[$1] ?? 0) }
        let adHoc = activities.filter { $0.calendarEventID == nil }.reduce(0.0) { $0 + $1.duration(in: day, at: now) }

        var remainingPlanned = 0
        let dayLeft = max(0, capacityMinutes - minutes(ticketToday))
        for ticket in tickets where plannedIDs.contains(ticket.id) && ticket.status != .done {
            let estimate = ticket.effectiveEstimateMinutes ?? settings.defaultEstimateMinutes
            // A ticket bigger than the rest of the day only takes the rest of the day.
            remainingPlanned += min(max(0, estimate - minutes(totalByTicket[ticket.id] ?? 0)), dayLeft)
        }

        return DayLoad(
            plannedTrackedMinutes: minutes(plannedToday),
            unplannedMinutes: minutes(ticketToday - plannedToday + adHoc),
            remainingPlannedMinutes: remainingPlanned,
            remainingTodayMinutes: capacityMinutes - minutes(ticketToday) - remainingPlanned
        )
    }

    /// Lowest-ranked planned tickets that were not started, just enough to cover `overloadMinutes`.
    public static func deferCandidates(
        _ candidates: [PlanCandidate], plannedIDs: Set<UUID>, startedIDs: Set<UUID>, overloadMinutes: Int
    ) -> [UUID] {
        guard overloadMinutes > 0 else { return [] }
        var covered = 0
        var result: [UUID] = []
        for candidate in candidates.reversed() where plannedIDs.contains(candidate.id) && !startedIDs.contains(candidate.id) {
            result.append(candidate.id)
            covered += candidate.estimateMinutes
            if covered >= overloadMinutes { break }
        }
        return result
    }

    /// The local due date, else the GitHub "Target date" issue field.
    static func dueDate(of ticket: Ticket) -> Date? {
        ticket.dueDate ?? ticket.field(named: "Target date")?.start
    }
}
