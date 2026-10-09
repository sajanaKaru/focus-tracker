import Foundation

public struct PlanSettings: Equatable, Sendable {
    public var workingMinutes: Int
    public var focusFactor: Double
    public var defaultEstimateMinutes: Int

    public init(workingMinutes: Int = 480, focusFactor: Double = 0.75, defaultEstimateMinutes: Int = 60) {
        self.workingMinutes = workingMinutes
        self.focusFactor = focusFactor
        self.defaultEstimateMinutes = defaultEstimateMinutes
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
    case dueNow, dueSoon, sprintEnding, carriedOver, inProgress, priority, open

    public var title: String {
        switch self {
        case .dueNow: "Due now"
        case .dueSoon: "Due soon"
        case .sprintEnding: "Sprint ends soon"
        case .carriedOver: "Carried over"
        case .inProgress: "In progress"
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
    public static func capacity(day: DateInterval, busy: [DateInterval], settings: PlanSettings) -> Capacity {
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
