import Foundation

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case ticketCreate, ticketEdit, ticketDelete, timer, timeEntry, note, planComment, dayPlan, activity
}

public enum ActionSync: Codable, Equatable, Sendable {
    case notApplicable
    case pending
    case synced(Date)
    case failed(String)
}

public struct FieldChange: Equatable, Sendable {
    public var field: String
    public var old: String?
    public var new: String?
    public var oldList: [String]?
    public var newList: [String]?
}

public struct ActionLogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var kind: ActionKind
    /// Snapshots, so the entry stays readable after the ticket is deleted.
    public var ticketID: UUID?
    public var ticketKey: String?
    public var ticketTitle: String?
    public var field: String?
    public var oldValue: String?
    public var newValue: String?
    public var oldList: [String]?
    public var newList: [String]?
    public var sync: ActionSync
    public var githubDetail: String?
    /// The GitHub change this entry pushed; lets a failed entry be retried.
    public var remote: RemoteEdit?
    public init(
        id: UUID = UUID(), timestamp: Date = Date(), kind: ActionKind,
        ticketID: UUID? = nil, ticketKey: String? = nil, ticketTitle: String? = nil,
        field: String? = nil, oldValue: String? = nil, newValue: String? = nil,
        oldList: [String]? = nil, newList: [String]? = nil,
        sync: ActionSync = .notApplicable, githubDetail: String? = nil, remote: RemoteEdit? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.ticketID = ticketID
        self.ticketKey = ticketKey
        self.ticketTitle = ticketTitle
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.oldList = oldList
        self.newList = newList
        self.sync = sync
        self.githubDetail = githubDetail
        self.remote = remote
    }
}

extension Ticket {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayText(_ date: Date?) -> String { date.map { dayFormatter.string(from: $0) } ?? "None" }
    private static func minutesText(_ minutes: Int?) -> String { minutes.map { "\($0) min" } ?? "None" }
    private static func listText(_ items: [String]) -> String { items.isEmpty ? "None" : items.joined(separator: ", ") }

    /// User-editable fields that differ between this ticket and `new`.
    public func changes(to new: Ticket) -> [FieldChange] {
        var result: [FieldChange] = []
        func text(_ field: String, _ old: String, _ new: String) {
            if old != new { result.append(FieldChange(field: field, old: old, new: new)) }
        }
        text("Title", title, new.title)
        text("Description", body, new.body)
        text("Status", status.title, new.status.title)
        text("Priority", priority.title, new.priority.title)
        text("Milestone", milestone?.title ?? "None", new.milestone?.title ?? "None")
        text("Due date", Self.dayText(dueDate), Self.dayText(new.dueDate))
        text("Estimate", Self.minutesText(estimateMinutes), Self.minutesText(new.estimateMinutes))
        if labels != new.labels {
            result.append(FieldChange(field: "Labels", old: Self.listText(labels), new: Self.listText(new.labels), oldList: labels, newList: new.labels))
        }
        return result
    }
}
