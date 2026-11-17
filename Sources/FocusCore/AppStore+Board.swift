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
    /// Tickets for the board. Ones no longer assigned to you or closed on GitHub are left off; they stay in the ticket list.
    public func boardTickets(matching filter: TicketFilter) -> [Ticket] {
        tickets(matching: filter).filter { $0.github?.remoteClosed != true }
    }

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

    /// Discovers all project status options grouped by project, preserving project
    /// grouping and remote option ordering with fallback to standard TicketStatus titles.
    public var workspaceProjectStatusesByProject: [(project: String, statuses: [ProjectStatusOption])] {
        let projects = Set(workspaceTickets.compactMap { $0.projectStatusField?.project })
            .union(remoteOptions.projectStatus.keys)
        var grouped: [(project: String, statuses: [ProjectStatusOption])] = []

        for project in projects.sorted() {
            var options: [ProjectStatusOption] = []
            for opt in remoteOptions.projectStatus[project] ?? [] {
                if !options.contains(where: { $0.name.caseInsensitiveCompare(opt.name) == .orderedSame }) {
                    options.append(ProjectStatusOption(project: project, name: opt.name, status: TicketStatus(optionName: opt.name), color: opt.color))
                }
            }
            for ticket in workspaceTickets where ticket.projectStatusField?.project == project {
                if let val = ticket.projectStatusField?.value,
                   !options.contains(where: { $0.name.caseInsensitiveCompare(val) == .orderedSame }) {
                    options.append(ProjectStatusOption(project: project, name: val, status: ticket.status, color: ticket.projectStatusField?.color))
                }
            }
            if !options.isEmpty {
                grouped.append((project: project, statuses: options))
            }
        }

        if grouped.isEmpty {
            let defaults = TicketStatus.allCases.map {
                ProjectStatusOption(project: "General", name: $0.title, status: $0, color: nil)
            }
            return [("General", defaults)]
        }
        return grouped
    }

    /// Discovers all unique project status options across all projects.
    public var workspaceProjectStatuses: [ProjectStatusOption] {
        workspaceProjectStatusesByProject.flatMap(\.statuses)
    }

    /// Resolves the ticket's qualified status key (e.g. "Project Alpha/In Dev" or "General/Todo").
    public func qualifiedStatusKey(for ticket: Ticket) -> String {
        let project = ticket.projectStatusField?.project ?? "General"
        let name = ticket.projectStatusField?.value ?? ticket.status.title
        return ProjectStatusOption.qualifiedKey(project: project, name: name)
    }

    /// Resolves the ticket's active project status name.
    public func statusName(for ticket: Ticket) -> String {
        ticket.projectStatusField?.value ?? ticket.status.title
    }
}
