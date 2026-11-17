import Foundation

extension Ticket {
    public var planCategory: PlanTicketCategory {
        if isQuickCapture == true {
            return .quickCapture
        }
        if let typeName = issueType?.name.lowercased() {
            if typeName.contains("bug") || typeName.contains("defect") { return .bug }
            if typeName.contains("feat") || typeName.contains("story") || typeName.contains("enhancement") { return .feature }
            if typeName.contains("task") || typeName.contains("chore") || typeName.contains("subtask") || typeName.contains("sub-task") { return .task }
        }
        for label in labels {
            let lower = label.lowercased()
            if lower == "bug" || lower.starts(with: "bug/") || lower.starts(with: "type: bug") || lower.starts(with: "type/bug") { return .bug }
            if lower == "feature" || lower == "enhancement" || lower.starts(with: "feature/") || lower.starts(with: "type/feature") || lower.starts(with: "type: feature") { return .feature }
            if lower == "task" || lower == "chore" || lower.starts(with: "task/") || lower.starts(with: "type/task") || lower.starts(with: "type: task") { return .task }
        }
        return .other
    }
}
