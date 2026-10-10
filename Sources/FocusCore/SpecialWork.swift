import Foundation

/// Tickets labelled for data migrations or scripts, which are tracked together on their own page.
public enum SpecialWork: String, CaseIterable, Identifiable, Sendable {
    case dataMigration, script

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dataMigration: "Data migration"
        case .script: "Script"
        }
    }

    public var symbol: String {
        switch self {
        case .dataMigration: "externaldrive.fill.badge.timemachine"
        case .script: "terminal.fill"
        }
    }

    /// Labels compare without case, spaces, dashes or underscores, so "Data Migration" and "data-migration" both match.
    private var names: Set<String> {
        switch self {
        case .dataMigration: ["datamigration", "datamigrations"]
        case .script: ["script", "scripts"]
        }
    }

    public func matches(_ ticket: Ticket) -> Bool {
        ticket.labels.contains { names.contains(Self.normalized($0)) }
    }

    private static func normalized(_ label: String) -> String {
        label.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Plural heading used when listing links, e.g. "Data migrations".
    public var heading: String {
        switch self {
        case .dataMigration: "Data migrations"
        case .script: "Scripts"
        }
    }

    /// Links grouped under a "Heading:" line, one indented link per line; local tickets and empty groups are skipped.
    public static func linkText(for groups: [(SpecialWork, [Ticket])]) -> String {
        groups.compactMap { kind, tickets -> String? in
            var seen = Set<String>()
            let links = tickets.compactMap { $0.github?.url }.filter { seen.insert($0).inserted }
            guard !links.isEmpty else { return nil }
            return (["\(kind.heading):"] + links.map { "     \($0)" }).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

extension Ticket {
    public var specialWork: [SpecialWork] { SpecialWork.allCases.filter { $0.matches(self) } }
}
