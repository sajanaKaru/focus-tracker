import Foundation

/// Buckets tickets by GitHub issue type or label; one ticket can fall in several.
public enum TicketCategory: String, CaseIterable, Identifiable, Sendable {
    case bug, feature, customer, task, change

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bug: "Bugs"
        case .feature: "Features"
        case .customer: "Customer reported"
        case .task: "Tasks"
        case .change: "Changes"
        }
    }

    private var names: Set<String> {
        switch self {
        case .bug: ["bug"]
        case .feature: ["feature"]
        case .customer: ["customer reported", "customer request"]
        case .task: ["task"]
        case .change: ["change", "enhancement", "ux improvement"]
        }
    }

    public func matches(_ ticket: Ticket) -> Bool {
        let tags = ([ticket.issueType?.name].compactMap { $0 } + ticket.labels)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return tags.contains { names.contains($0) }
    }
}

public struct CategoryStat: Identifiable, Sendable {
    public struct Entry: Identifiable, Sendable {
        public var ticket: Ticket
        public var seconds: TimeInterval
        public var id: UUID { ticket.id }
    }

    /// nil is the bucket for tickets that match no category.
    public var category: TicketCategory?
    public var entries: [Entry]

    public var id: String { category?.rawValue ?? "other" }
    public var title: String { category?.title ?? "Other" }
    public var seconds: TimeInterval { entries.reduce(0) { $0 + $1.seconds } }
    public var doneCount: Int { entries.filter { $0.ticket.status == .done }.count }
}

public enum ReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case thisWeek, lastWeek, thisMonth, lastMonth, last30Days, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thisWeek: "This week"
        case .lastWeek: "Last week"
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .last30Days: "Last 30 days"
        case .custom: "Custom range"
        }
    }

    /// `custom` holds the first and last day to include.
    public func interval(now: Date, calendar: Calendar = .current, custom: ClosedRange<Date>? = nil) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        func shifted(_ component: Calendar.Component, _ value: Int) -> Date {
            calendar.date(byAdding: component, value: value, to: now) ?? now
        }
        func containing(_ component: Calendar.Component, _ date: Date) -> DateInterval {
            calendar.dateInterval(of: component, for: date) ?? DateInterval(start: today, duration: 86_400)
        }
        switch self {
        case .thisWeek: return containing(.weekOfYear, now)
        case .lastWeek: return containing(.weekOfYear, shifted(.weekOfYear, -1))
        case .thisMonth: return containing(.month, now)
        case .lastMonth: return containing(.month, shifted(.month, -1))
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        case .custom:
            guard let custom else { return containing(.month, now) }
            let start = calendar.startOfDay(for: custom.lowerBound)
            let lastDay = calendar.startOfDay(for: custom.upperBound)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay)
        }
    }
}
