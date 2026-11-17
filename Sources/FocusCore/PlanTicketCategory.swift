import Foundation

public enum PlanTicketCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case feature = "Feature"
    case bug = "Bug"
    case task = "Task"
    case quickCapture = "Quick Capture"
    case other = "Other"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .feature: return "star.fill"
        case .bug: return "ladybug.fill"
        case .task: return "checkmark.square"
        case .quickCapture: return "bolt.fill"
        case .other: return "tag.fill"
        }
    }
}
