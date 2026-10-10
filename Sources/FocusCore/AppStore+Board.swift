import Foundation

public struct BoardColumn: Identifiable, Equatable, Sendable {
    public var name: String
    public var status: TicketStatus
    public var color: String?
    public var id: String { name }

    public init(name: String, status: TicketStatus, color: String? = nil) {
        self.name = name
        self.status = status
        self.color = color
    }
}

extension AppStore {
    public var boardColumns: [BoardColumn] {
        let projects = Set(workspaceTickets.compactMap { $0.projectStatusField?.project })
        var columns: [BoardColumn] = []
        for project in projects.sorted() {
            for option in remoteOptions.projectStatus[project] ?? [] where !columns.contains(where: { $0.name.caseInsensitiveCompare(option.name) == .orderedSame }) {
                columns.append(BoardColumn(name: option.name, status: TicketStatus(optionName: option.name), color: option.color))
            }
        }
        return columns.isEmpty ? TicketStatus.allCases.map { BoardColumn(name: $0.title, status: $0) } : columns
    }

    /// The column a ticket sits in: its own Status option when it matches, else the first column with its status.
    public func column(for ticket: Ticket, in columns: [BoardColumn]) -> String {
        if let value = ticket.projectStatusField?.value,
           let match = columns.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
            return match.name
        }
        return (columns.first { $0.status == ticket.status } ?? columns.first)?.name ?? ticket.status.title
    }

    public func moveTicket(_ id: UUID, toColumn column: BoardColumn) {
        guard let ticket = ticket(id) else { return }
        if let field = ticket.projectStatusField,
           let option = remoteOptions.projectStatus[field.project]?.first(where: { $0.name.caseInsensitiveCompare(column.name) == .orderedSame }) {
            setStatusOption(id, project: field.project, option: option.name)
        } else {
            setStatus(id, column.status)
        }
        if column.status == .done && isTracking(id) { stop() }
    }
}
