import AppKit
import FocusCore
import SwiftUI

extension TicketStatus {
    var color: Color {
        switch self {
        case .backlog: Theme.slate
        case .todo: Theme.info
        case .inProgress: Theme.warning
        case .inReview: Theme.accentEnd
        case .done: Theme.success
        }
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .none: Theme.slate
        case .low: Theme.teal
        case .medium: Theme.warning
        case .high: Theme.orange
        case .urgent: Theme.danger
        }
    }
}

enum Theme {
    static let accent = Color(hex: 0x6366F1)
    static let accentEnd = Color(hex: 0x8B5CF6)
    static let success = Color(hex: 0x10B981)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xF43F5E)
    static let info = Color(hex: 0x3B82F6)
    static let orange = Color(hex: 0xF97316)
    static let teal = Color(hex: 0x14B8A6)
    static let slate = Color(hex: 0x94A3B8)

    static let accentGradient = LinearGradient(colors: [Theme.accent, Theme.accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warningGradient = LinearGradient(colors: [Theme.warning, Theme.orange], startPoint: .leading, endPoint: .trailing)
    static let activityGradient = LinearGradient(colors: [Theme.teal, Color(hex: 0x06B6D4)], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let pageBackground = Color.adaptive(light: 0xF6F6FB, dark: 0x14141C)
    static let sidebarBackground = Color.adaptive(light: 0xECECF4, dark: 0x1A1A24)
    static let cardBackground = Color.adaptive(light: 0xFFFFFF, dark: 0x1C1C26)
    static let radius: CGFloat = 16
}

private struct CardStyle: ViewModifier {
    var padding: CGFloat
    var selected: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        content
            .padding(padding)
            .background(Theme.cardBackground, in: shape)
            .background(selected ? Theme.accent.opacity(0.07) : Color.clear, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.07), lineWidth: selected ? 1.5 : 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 10, y: 4)
    }
}

extension View {
    func cardStyle(padding: CGFloat = 14, selected: Bool = false) -> some View {
        modifier(CardStyle(padding: padding, selected: selected))
    }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct LabelChip: View {
    let name: String
    var hex: String?

    var body: some View {
        if let rgb = Self.rgb(hex) {
            let light = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b > 0.6
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(light ? Color.black.opacity(0.85) : Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(red: rgb.r, green: rgb.g, blue: rgb.b), in: Capsule())
        } else {
            Chip(text: name)
        }
    }

    static func rgb(_ hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard let hex, hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

struct LabelChips: View {
    let ticket: Ticket
    var limit = 3

    var body: some View {
        ForEach(ticket.labels.prefix(limit), id: \.self) { LabelChip(name: $0, hex: ticket.labelColors?[$0]) }
    }
}

struct MetaChips: View {
    let ticket: Ticket

    var body: some View {
        if let type = ticket.issueType {
            Chip(text: type.name, color: GitHubColor.color(type.color) ?? .secondary, symbol: "tag.fill")
        }
        if let priority = ticket.field(named: "Priority") {
            FieldChip(field: priority)
        } else {
            PriorityBadge(priority: ticket.priority)
        }
        if let effort = ticket.field(named: "Effort") {
            FieldChip(field: effort)
        }
        if let milestone = ticket.milestone {
            Chip(text: milestone.title, color: milestone.isOpen ? Theme.accent : Theme.slate, symbol: "flag.checkered")
        }
        ForEach(Array(ticket.sprints.enumerated()), id: \.offset) { _, sprint in
            Chip(text: sprint.value, color: sprint.isCurrent(at: Date()) ? Theme.teal : Theme.slate, symbol: "repeat")
        }
    }
}

enum GitHubColor {
    /// GitHub color names ("red") or 6-digit hex.
    static func color(_ name: String?) -> Color? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        switch name {
        case "gray", "grey": return Theme.slate
        case "blue": return Theme.info
        case "green": return Theme.success
        case "yellow": return Color(red: 0.72, green: 0.53, blue: 0.04)
        case "orange": return Theme.orange
        case "red": return Theme.danger
        case "pink": return .pink
        case "purple": return Theme.accentEnd
        default:
            guard let rgb = LabelChip.rgb(name) else { return nil }
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
    }

    /// Fallback for Priority options that carry no color.
    static func priority(_ value: String) -> Color? {
        switch value.lowercased() {
        case "urgent", "critical", "p0": Theme.danger
        case "high", "p1": Theme.orange
        case "medium", "p2": Color(red: 0.72, green: 0.53, blue: 0.04)
        case "low", "p3": Theme.teal
        default: nil
        }
    }
}

/// A GitHub field value as a badge: colored for single-select options, a calendar chip for dates.
struct FieldChip: View {
    let field: CustomField

    var body: some View {
        switch field.kind {
        case .select:
            let isPriority = field.name.caseInsensitiveCompare("Priority") == .orderedSame
            let color = GitHubColor.color(field.color) ?? (isPriority ? GitHubColor.priority(field.value) : nil) ?? .secondary
            Chip(text: field.value, color: color, symbol: Self.symbol(for: field.name))
        case .date:
            Chip(text: dateText, color: .secondary, symbol: "calendar")
        case .iteration:
            Chip(text: field.value, color: field.isCurrent(at: Date()) ? Theme.teal : Theme.slate, symbol: "repeat")
        case .number, .text:
            Chip(text: field.value, color: .secondary)
        }
    }

    private var dateText: String {
        field.start?.formatted(.dateTime.month(.abbreviated).day().year()) ?? field.value
    }

    private static func symbol(for name: String) -> String? {
        switch name.lowercased() {
        case "priority": "flag.fill"
        case "effort": "speedometer"
        default: nil
        }
    }
}

/// Lays children out left to right and wraps to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

struct ShortcutLabel: View {
    let title: String
    let keys: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(keys).foregroundStyle(.secondary)
        }
    }
}

struct StatusBadge: View {
    let status: TicketStatus
    var body: some View { Chip(text: status.title, color: status.color, symbol: status.symbol) }
}

struct PriorityBadge: View {
    let priority: Priority

    var body: some View {
        if priority != .none {
            Chip(text: priority.title, color: priority.color, symbol: "flag.fill")
        }
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.largeTitle.weight(.bold))
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

struct SectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .hoverLift()
    }
}

struct EmptyHint: View {
    let text: String
    var symbol = "tray"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
