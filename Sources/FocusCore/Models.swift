import Foundation

public enum TicketStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case backlog, todo, inProgress, inReview, done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .backlog: "Backlog"
        case .todo: "Todo"
        case .inProgress: "In Progress"
        case .inReview: "In Review"
        case .done: "Done"
        }
    }

    public var symbol: String {
        switch self {
        case .backlog: "tray"
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .inReview: "eye.circle"
        case .done: "checkmark.circle.fill"
        }
    }
}

public enum Priority: Int, Codable, CaseIterable, Identifiable, Sendable {
    case none = 0, low, medium, high, urgent

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }
}

public struct GitHubRef: Codable, Hashable, Sendable {
    public var repo: String
    public var number: Int
    public var url: String
    public var isPullRequest: Bool
    /// True once the issue is no longer in the assigned-open list (closed or reassigned).
    public var remoteClosed: Bool

    public var key: String { "\(repo.lowercased())#\(number)" }

    public init(repo: String, number: Int, url: String, isPullRequest: Bool = false, remoteClosed: Bool = false) {
        self.repo = repo
        self.number = number
        self.url = url
        self.isPullRequest = isPullRequest
        self.remoteClosed = remoteClosed
    }
}

public struct Milestone: Codable, Hashable, Sendable {
    public var title: String
    public var isOpen: Bool
    public var dueOn: Date?

    public init(title: String, isOpen: Bool = true, dueOn: Date? = nil) {
        self.title = title
        self.isOpen = isOpen
        self.dueOn = dueOn
    }
}

/// A GitHub field value on the issue: an organization issue field (Priority, Effort, Start date, Target date)
/// or a Projects (v2) field such as Sprint or RCA.
public struct CustomField: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, number, date, select, iteration }

    public static let issueFieldsGroup = "Issue fields"
    /// Text field that can be edited in the app and written back to GitHub.
    public static let rcaName = "RCA"

    public var name: String
    public var value: String
    public var kind: Kind
    public var project: String
    /// Iteration (sprint) window, or the date for `.date` fields; nil otherwise.
    public var start: Date?
    public var end: Date?
    /// GitHub option color name ("red") or hex for single-select values.
    public var color: String?

    public init(name: String, value: String, kind: Kind, project: String, start: Date? = nil, end: Date? = nil, color: String? = nil) {
        self.name = name
        self.value = value
        self.kind = kind
        self.project = project
        self.start = start
        self.end = end
        self.color = color
    }

    public func isCurrent(at date: Date) -> Bool {
        guard kind == .iteration, let start, let end else { return false }
        return start <= date && date < end
    }
}

public struct IssueType: Codable, Hashable, Sendable {
    public var name: String
    public var color: String?

    public init(name: String, color: String? = nil) {
        self.name = name
        self.color = color
    }
}

public struct Ticket: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var status: TicketStatus
    public var priority: Priority
    public var labels: [String]
    /// Label name -> hex color (no '#'), as reported by GitHub.
    public var labelColors: [String: String]?
    public var milestone: Milestone?
    public var fields: [CustomField]?
    public var issueType: IssueType?
    /// Organization issue fields (Priority, Effort, Start date, Target date, ...).
    public var issueFields: [CustomField]?
    public var dueDate: Date?
    public var estimateMinutes: Int?
    public var createdAt: Date
    public var updatedAt: Date
    public var github: GitHubRef?

    public init(
        id: UUID = UUID(),
        title: String,
        body: String = "",
        status: TicketStatus = .todo,
        priority: Priority = .none,
        labels: [String] = [],
        labelColors: [String: String]? = nil,
        milestone: Milestone? = nil,
        fields: [CustomField]? = nil,
        issueType: IssueType? = nil,
        issueFields: [CustomField]? = nil,
        dueDate: Date? = nil,
        estimateMinutes: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        github: GitHubRef? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.priority = priority
        self.labels = labels
        self.labelColors = labelColors
        self.milestone = milestone
        self.fields = fields
        self.issueType = issueType
        self.issueFields = issueFields
        self.dueDate = dueDate
        self.estimateMinutes = estimateMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.github = github
    }

    public var displayKey: String {
        guard let github else { return "Local" }
        return "\(github.repo)#\(github.number)"
    }

    /// Sprint (iteration) values from any project the issue belongs to.
    public var sprints: [CustomField] { (fields ?? []).filter { $0.kind == .iteration } }

    /// Issue fields first, then project fields.
    public var allFields: [CustomField] { (issueFields ?? []) + (fields ?? []) }

    public func field(named name: String) -> CustomField? {
        allFields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Project number field holding the estimate in hours, e.g. "Dev Estimated (in Hours)" or "Estimate (in Hours)".
    public var estimateField: CustomField? {
        let numbers = (fields ?? []).filter { $0.kind == .number && Double($0.value) != nil }
        return numbers.first { $0.name.localizedCaseInsensitiveContains("dev estimat") }
            ?? numbers.first { $0.name.localizedCaseInsensitiveContains("estimat") }
    }

    /// The GitHub estimate when the issue has one, otherwise the local estimate.
    public var effectiveEstimateMinutes: Int? {
        if let hours = estimateField.flatMap({ Double($0.value) }), hours > 0 { return Int((hours * 60).rounded()) }
        return estimateMinutes
    }
}

public struct TicketFilter: Equatable, Sendable {
    public enum MilestoneChoice: Hashable, Sendable { case any, ongoing, none, named(String) }
    public enum SprintChoice: Hashable, Sendable { case any, current, none, named(String) }

    public var repo: String?
    public var milestone: MilestoneChoice = .any
    public var sprint: SprintChoice = .any

    public init(repo: String? = nil, milestone: MilestoneChoice = .any, sprint: SprintChoice = .any) {
        self.repo = repo
        self.milestone = milestone
        self.sprint = sprint
    }

    public var isActive: Bool { repo != nil || milestone != .any || sprint != .any }

    public func matches(_ ticket: Ticket, now: Date = Date()) -> Bool {
        if let repo, ticket.github?.repo.lowercased() != repo.lowercased() { return false }

        switch milestone {
        case .any: break
        case .ongoing: if ticket.milestone?.isOpen != true { return false }
        case .none: if ticket.milestone != nil { return false }
        case .named(let title): if ticket.milestone?.title != title { return false }
        }

        switch sprint {
        case .any: break
        case .current: if !ticket.sprints.contains(where: { $0.isCurrent(at: now) }) { return false }
        case .none: if !ticket.sprints.isEmpty { return false }
        case .named(let name): if !ticket.sprints.contains(where: { $0.value == name }) { return false }
        }
        return true
    }
}

public struct TicketNote: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var ticketID: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), ticketID: UUID, text: String, createdAt: Date = Date()) {
        self.id = id
        self.ticketID = ticketID
        self.text = text
        self.createdAt = createdAt
    }
}

/// A Markdown comment drafted on a ticket's plan page; `postedAt` is set once it has been sent to GitHub.
public struct PlanComment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var ticketID: UUID
    public var text: String
    public var createdAt: Date
    public var postedAt: Date?

    public init(id: UUID = UUID(), ticketID: UUID, text: String, createdAt: Date = Date(), postedAt: Date? = nil) {
        self.id = id
        self.ticketID = ticketID
        self.text = text
        self.createdAt = createdAt
        self.postedAt = postedAt
    }
}

/// Time spent on something that isn't a ticket: a call, a meeting, etc.
public struct Activity: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case call, meeting, other

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .call: "Call"
            case .meeting: "Meeting"
            case .other: "Other"
            }
        }

        public var symbol: String {
            switch self {
            case .call: "phone.fill"
            case .meeting: "person.2.fill"
            case .other: "ellipsis.circle.fill"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var start: Date
    public var end: Date?
    /// Set when imported from the Calendar, to avoid importing the same event twice.
    public var calendarEventID: String?

    public init(id: UUID = UUID(), kind: Kind, title: String, start: Date, end: Date? = nil, calendarEventID: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.start = start
        self.end = end
        self.calendarEventID = calendarEventID
    }

    public func duration(at now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    /// Seconds of this activity that fall inside `interval`.
    public func duration(in interval: DateInterval, at now: Date) -> TimeInterval {
        let s = max(start, interval.start)
        let e = min(end ?? now, interval.end)
        return max(0, e.timeIntervalSince(s))
    }
}

/// One row of a time log: tracked time, a note, or a non-ticket activity, ordered by `date`.
public enum LogItem: Identifiable, Hashable, Sendable {
    case time(TimeEntry)
    case note(TicketNote)
    case activity(Activity)

    public var id: UUID {
        switch self {
        case .time(let entry): entry.id
        case .note(let note): note.id
        case .activity(let activity): activity.id
        }
    }

    public var date: Date {
        switch self {
        case .time(let entry): entry.start
        case .note(let note): note.createdAt
        case .activity(let activity): activity.start
        }
    }
}

public struct TimeEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var ticketID: UUID
    public var start: Date
    public var end: Date?

    public init(id: UUID = UUID(), ticketID: UUID, start: Date, end: Date? = nil) {
        self.id = id
        self.ticketID = ticketID
        self.start = start
        self.end = end
    }

    public func duration(at now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    /// Seconds of this entry that fall inside `interval`.
    public func duration(in interval: DateInterval, at now: Date) -> TimeInterval {
        let s = max(start, interval.start)
        let e = min(end ?? now, interval.end)
        return max(0, e.timeIntervalSince(s))
    }
}

/// The tickets the user committed to on one calendar day.
public struct DayPlan: Identifiable, Codable, Hashable, Sendable {
    /// Start of the day.
    public var day: Date
    public var ticketIDs: [UUID]

    public var id: Date { day }

    public init(day: Date, ticketIDs: [UUID] = []) {
        self.day = day
        self.ticketIDs = ticketIDs
    }
}
