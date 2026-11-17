import Foundation

public struct ProjectStatusOption: Identifiable, Hashable, Sendable {
    /// Qualified unique identifier guaranteeing zero collision across projects.
    public var id: String { Self.qualifiedKey(project: project, name: name) }
    public var project: String
    public var name: String
    public var status: TicketStatus
    public var color: String?

    public init(project: String = "General", name: String, status: TicketStatus, color: String? = nil) {
        self.project = project
        self.name = name
        self.status = status
        self.color = color
    }

    public static func qualifiedKey(project: String, name: String) -> String {
        "\(project)/\(name)"
    }
}
