import Foundation

extension ActionKind {
    public var title: String {
        switch self {
        case .ticketCreate: "Ticket created"
        case .ticketEdit: "Ticket edit"
        case .ticketDelete: "Ticket deleted"
        case .timer: "Timer"
        case .timeEntry: "Time entry"
        case .note: "Note"
        case .planComment: "Plan comment"
        case .dayPlan: "Day plan"
        case .activity: "Activity"
        }
    }
}

extension ActionSync {
    public var badgeTitle: String? {
        switch self {
        case .notApplicable: nil
        case .pending: "Pending"
        case .synced: "Synced"
        case .failed: "Failed"
        }
    }

    public var isFailed: Bool { if case .failed = self { true } else { false } }
    public var isPending: Bool { if case .pending = self { true } else { false } }
    public var errorMessage: String? { if case .failed(let message) = self { message } else { nil } }
}

extension ActionLogEntry {
    /// One line describing the action, e.g. "Status: Todo → Done".
    public var summary: String {
        let name = field ?? kind.title
        switch (oldValue, newValue) {
        case (let old?, let new?): return "\(name): \(old) → \(new)"
        case (nil, let new?): return "\(name): \(new)"
        case (let old?, nil): return "\(name) (\(old))"
        case (nil, nil): return name
        }
    }

    public var labelChanges: (added: [String], removed: [String])? {
        guard let oldList, let newList else { return nil }
        return (newList.filter { !oldList.contains($0) }, oldList.filter { !newList.contains($0) })
    }
}

public enum SyncFilter: String, CaseIterable, Identifiable, Sendable {
    case all, failed, pending, synced, local

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .failed: "Failed"
        case .pending: "Pending"
        case .synced: "Synced"
        case .local: "Local only"
        }
    }
}

public struct ActionLogFilter: Equatable, Sendable {
    public var ticketID: UUID?
    /// Empty means every kind.
    public var kinds: Set<ActionKind>
    public var sync: SyncFilter
    public var query: String
    public var since: Date?

    public init(ticketID: UUID? = nil, kinds: Set<ActionKind> = [], sync: SyncFilter = .all, query: String = "", since: Date? = nil) {
        self.ticketID = ticketID
        self.kinds = kinds
        self.sync = sync
        self.query = query
        self.since = since
    }

    /// Matching entries, newest first.
    public func apply(to entries: [ActionLogEntry]) -> [ActionLogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            if let ticketID, entry.ticketID != ticketID { return false }
            if !kinds.isEmpty, !kinds.contains(entry.kind) { return false }
            if let since, entry.timestamp < since { return false }
            switch sync {
            case .all: break
            case .failed: if !entry.sync.isFailed { return false }
            case .pending: if !entry.sync.isPending { return false }
            case .synced: if case .synced = entry.sync {} else { return false }
            case .local: if entry.sync != .notApplicable { return false }
            }
            guard !needle.isEmpty else { return true }
            return [entry.ticketKey, entry.ticketTitle, entry.field, entry.oldValue, entry.newValue]
                .contains { $0?.localizedCaseInsensitiveContains(needle) == true }
        }
        .sorted { $0.timestamp > $1.timestamp }
    }
}

public enum TicketSyncStatus: Equatable, Sendable {
    case synced, syncing, failed
}
