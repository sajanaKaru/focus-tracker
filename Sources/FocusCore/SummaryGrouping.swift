import Foundation

/// Defines how tickets are grouped when generating daily summaries.
public enum SummaryGroupingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case byType = "byType"
    case byStatus = "byStatus"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .byType: "Type / Label"
        case .byStatus: "Status / Stage"
        }
    }
}

/// Classifies tickets into summary categories based on labels, issue types, or workflow status.
public struct SummaryClassifier {
    public static func category(for ticket: Ticket, mode: SummaryGroupingMode) -> String {
        switch mode {
        case .byStatus:
            return ticket.field(named: "Status")?.value ?? ticket.status.title
        case .byType:
            return typeCategory(for: ticket)
        }
    }

    private static func typeCategory(for ticket: Ticket) -> String {
        let normalizedLabels = ticket.labels.map { normalizeLabel($0) }

        // Priority 1: Bugs (takes precedence over other labels/types)
        if normalizedLabels.contains(where: { isBug($0) }) {
            return "Bugs"
        }
        if let typeName = ticket.issueType?.name.trimmingCharacters(in: .whitespacesAndNewlines), !typeName.isEmpty {
            if isBug(normalizeLabel(typeName)) { return "Bugs" }
        }

        // Priority 1.5: Explicit GitHub issueType if non-bug
        if let typeName = ticket.issueType?.name.trimmingCharacters(in: .whitespacesAndNewlines), !typeName.isEmpty {
            if let matched = matchStandardType(typeName) { return matched }
        }

        // Check custom field "Type"
        if let customType = ticket.field(named: "Type")?.value, !customType.isEmpty {
            if let matched = matchStandardType(customType) { return matched }
        }

        // Priority 2: Features / Enhancements
        if normalizedLabels.contains(where: { isFeature($0) }) {
            return "Features"
        }

        // Priority 3: Changes / Improvements
        if normalizedLabels.contains(where: { isChange($0) }) {
            return "Changes"
        }

        // Priority 4: Tasks / Chores / Refactoring
        if normalizedLabels.contains(where: { isTask($0) }) {
            return "Tasks"
        }

        // Fallback for tickets without recognized type label
        return "General Tasks"
    }

    public static func normalizeLabel(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["type:", "type/", "kind:", "kind/"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    private static func matchStandardType(_ string: String) -> String? {
        let s = normalizeLabel(string)
        if isBug(s) { return "Bugs" }
        if isFeature(s) { return "Features" }
        if isChange(s) { return "Changes" }
        if isTask(s) { return "Tasks" }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.capitalized
    }

    private static func isBug(_ s: String) -> Bool {
        s == "bug" || s == "defect" || s == "fix" || s == "hotfix" || s.contains("bug") || s.contains("defect")
    }

    private static func isFeature(_ s: String) -> Bool {
        s == "feature" || s == "enhancement" || s == "feat" || s.contains("feature") || s.contains("enhancement")
    }

    private static func isChange(_ s: String) -> Bool {
        s == "change" || s == "improvement" || s == "mod" || s.contains("improvement") || (s.contains("change") && !s.contains("exchange"))
    }

    private static func isTask(_ s: String) -> Bool {
        s == "task" || s == "chore" || s == "refactor" || s == "maintenance" || s == "cleanup" || s.contains("task") || s.contains("chore") || s.contains("refactor")
    }
}
