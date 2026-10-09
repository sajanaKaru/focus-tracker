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
    case dueNow, dueSoon, sprintEnding, carriedOver, inProgress, inSprint, priority, open

    public var title: String {
        switch self {
        case .dueNow: "Due now"
        case .dueSoon: "Due soon"
        case .sprintEnding: "Sprint ends soon"
        case .carriedOver: "Carried over"
        case .inProgress: "In progress"
        case .inSprint: "In sprint"
        case .priority: "Priority"
        case .open: "Open"
        }
    }
}

public struct PlanCandidate: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var reason: PlanReason
    public var estimateMinutes: Int
    /// True when the ticket has no estimate and the default was used.
    public var estimatedByApp: Bool

    public var id: UUID { ticket.id }
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
        tickets: [Ticket], carriedOver: Set<UUID>, now: Date, settings: PlanSettings, calendar: Calendar = .current
    ) -> [PlanCandidate] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let soonLimit = calendar.date(byAdding: .day, value: 3, to: today) ?? today

        func reason(for ticket: Ticket) -> PlanReason {
            if let due = dueDate(of: ticket) {
                if due < tomorrow { return .dueNow }
                if due < soonLimit { return .dueSoon }
            }
            if ticket.sprints.contains(where: { $0.isCurrent(at: now) && ($0.end ?? .distantFuture) < soonLimit }) {
                return .sprintEnding
            }
            if carriedOver.contains(ticket.id) { return .carriedOver }
            if ticket.status == .inProgress || ticket.status == .inReview { return .inProgress }
            if ticket.sprints.contains(where: { $0.isCurrent(at: now) }) { return .inSprint }
            return ticket.priority == .none ? .open : .priority
        }

        return tickets
            .filter { [.todo, .inProgress, .inReview].contains($0.status) && $0.github?.remoteClosed != true }
            .map { ticket -> PlanCandidate in
                let estimate = ticket.effectiveEstimateMinutes
                return PlanCandidate(
                    ticket: ticket,
                    reason: reason(for: ticket),
                    estimateMinutes: estimate ?? settings.defaultEstimateMinutes,
                    estimatedByApp: estimate == nil
                )
            }
            .sorted {
                if $0.reason != $1.reason { return $0.reason.rawValue < $1.reason.rawValue }
                if $0.ticket.priority != $1.ticket.priority { return $0.ticket.priority.rawValue > $1.ticket.priority.rawValue }
                return $0.ticket.updatedAt < $1.ticket.updatedAt
            }
    }

    /// Takes candidates in rank order until the next one would not fit; always keeps the first.
    public static func autoPick(_ candidates: [PlanCandidate], capacityMinutes: Int) -> [UUID] {
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

    public static func plannedMinutes(_ candidates: [PlanCandidate], ids: Set<UUID>) -> Int {
        candidates.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.estimateMinutes }
    }

    /// The local due date, else the GitHub "Target date" issue field.
    static func dueDate(of ticket: Ticket) -> Date? {
        ticket.dueDate ?? ticket.field(named: "Target date")?.start
    }
}
