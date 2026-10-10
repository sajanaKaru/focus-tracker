import Foundation

public enum IssueFieldValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
}

/// One change to push to GitHub; stored on the log entry so a failed push can be retried.
public enum RemoteEdit: Codable, Equatable, Sendable {
    case labels([String])
    case milestone(number: Int?)
    case title(String)
    case body(String)
    case state(open: Bool)
    case issueField(name: String, value: IssueFieldValue?)
    case projectField(project: String, field: String, value: ProjectFieldValue)

    /// What the edit overwrites; repeated edits of the same slot are coalesced.
    public var slot: String {
        switch self {
        case .labels: "labels"
        case .milestone: "milestone"
        case .title: "title"
        case .body: "body"
        case .state: "state"
        case .issueField(let name, _): "issueField:\(name)"
        case .projectField(let project, let field, _): "project:\(project):\(field)"
        }
    }
}

extension Priority {
    /// Maps an org Priority option name ("P1 - High", "Critical") to the app's levels.
    public init(optionName: String) {
        let n = optionName.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["urgent", "critical", "blocker", "p0"]) { self = .urgent }
        else if has(["high", "p1"]) { self = .high }
        else if has(["medium", "normal", "p2"]) { self = .medium }
        else if has(["low", "minor", "p3"]) { self = .low }
        else { self = .none }
    }
}

extension TicketStatus {
    /// Maps a project Status option name to the app's statuses.
    public init(optionName: String) {
        let n = optionName.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        let isDev = n.split { !$0.isLetter }.contains("dev")
        if has(["done", "complete", "closed", "shipped", "released", "merged"]) { self = .done }
        else if has(["review", "qa", "testing"]) { self = .inReview }
        else if has(["not started", "to do", "todo"]) { self = .todo }
        else if isDev || has(["progress", "doing", "started", "develop"]) { self = .inProgress }
        else if has(["backlog", "icebox", "triage"]) { self = .backlog }
        else { self = .todo }
    }
}

extension Ticket {
    /// The Projects (v2) single-select named "Status".
    public var projectStatusField: CustomField? {
        (fields ?? []).first { $0.name == "Status" && $0.kind == .select }
    }
}

extension Date {
    /// `yyyy-MM-dd` in the local calendar, the format GitHub date fields use.
    var isoDay: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}
