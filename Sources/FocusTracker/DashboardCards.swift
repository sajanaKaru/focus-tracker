import FocusCore
import SwiftUI

func timeGreeting(_ date: Date) -> String {
    switch Calendar.current.component(.hour, from: date) {
    case 5..<12: "Good morning"
    case 12..<18: "Good afternoon"
    default: "Good evening"
    }
}

/// A single stacked bar; segments with no value are skipped.
struct DashboardBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        var value: Int
        var color: Color
    }

    let segments: [Segment]

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.value }, 1)
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments.filter { $0.value > 0 }) { segment in
                    Rectangle().fill(segment.color).frame(width: proxy.size.width * CGFloat(segment.value) / CGFloat(total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.08))
        .clipShape(Capsule())
    }
}

struct CapacityBar: View {
    let planned: Int
    let capacity: Int
    let over: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = min(Double(planned) / Double(max(capacity, 1)), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(over ? Theme.warningGradient : Theme.accentGradient)
                    .frame(width: planned > 0 ? max(8, proxy.size.width * fraction) : 0)
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: planned)
        .accessibilityElement()
        .accessibilityLabel("Planned \(Format.short(TimeInterval(planned * 60))) of \(Format.short(TimeInterval(capacity * 60))) capacity")
    }
}

/// A card of ticket rows; tapping a row selects the ticket.
struct TicketListCard<Trailing: View>: View {
    let tickets: [Ticket]
    @Binding var selectedTicketID: UUID?
    let trailing: (Ticket) -> Trailing

    init(tickets: [Ticket], selectedTicketID: Binding<UUID?>, @ViewBuilder trailing: @escaping (Ticket) -> Trailing) {
        self.tickets = tickets
        _selectedTicketID = selectedTicketID
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tickets.enumerated()), id: \.element.id) { index, ticket in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    Image(systemName: ticket.status.symbol).foregroundStyle(ticket.status.color).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticket.title).lineLimit(1)
                        Text(ticket.displayKey).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    trailing(ticket)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .selectsTicket(ticket.id, selection: $selectedTicketID)
            }
        }
        .cardStyle(padding: 0)
    }
}

extension View {
    /// The sheets the Today header opens: add an activity, import calendar events, log an unplanned item.
    func todaySheet(_ sheet: Binding<TodaySheet?>) -> some View {
        self.sheet(item: sheet) { value in
            switch value {
            case .add(let choice): AddActivitySheet(choice: choice)
            case .calendar: CalendarImportSheet()
            case .unplanned: QuickCaptureSheet()
            }
        }
    }
}
