import Foundation

public struct ProjectStatusOption: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var status: TicketStatus
    public var color: String?

    public init(name: String, status: TicketStatus, color: String? = nil) {
        self.name = name
        self.status = status
        self.color = color
    }
}
