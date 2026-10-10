import FocusCore
import SwiftUI

struct BoardView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    var filter = TicketFilter()
    @State private var targetedColumn: String?

    var body: some View {
        let columns = store.boardColumns
        let tickets = store.tickets(matching: filter)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(columns) { column in
                    columnView(column, tickets: tickets.filter { store.column(for: $0, in: columns) == column.name })
                }
            }
            .padding(20)
        }
        .background(Theme.pageBackground)
        .task { await store.loadOptions() }
    }

    private func columnView(_ column: BoardColumn, tickets: [Ticket]) -> some View {
        let items = tickets.sorted { $0.updatedAt > $1.updatedAt }
        let tint = GitHubColor.color(column.color) ?? column.status.color
        let targeted = targetedColumn == column.name
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 9, height: 9)
                Text(column.name).font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { card($0) }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? tint.opacity(0.14) : tint.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(targeted ? tint.opacity(0.6) : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            for raw in ids {
                if let id = UUID(uuidString: raw) { store.moveTicket(id, toColumn: column) }
            }
            return !ids.isEmpty
        } isTargeted: { targetedColumn = $0 ? column.name : (targetedColumn == column.name ? nil : targetedColumn) }
    }

    private func card(_ ticket: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ticket.title).font(.body.weight(.medium)).lineLimit(3)
            if ticket.priority != .none || !ticket.labels.isEmpty || ticket.milestone != nil || ticket.issueType != nil || !ticket.allFields.isEmpty || store.syncStatus(for: ticket.id) != .synced {
                FlowLayout {
                    MetaChips(ticket: ticket)
                    LabelChips(ticket: ticket, limit: 2)
                    TicketSyncMarker(ticketID: ticket.id)
                }
            }
            HStack {
                Text(ticket.displayKey).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                let tracked = store.trackedTime(for: ticket.id)
                if tracked >= 60 {
                    Label(Format.short(tracked), systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TimerButton(ticketID: ticket.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 12, selected: selectedTicketID == ticket.id)
        .hoverLift()
        .onTapGesture { selectedTicketID = ticket.id }
        .draggable(ticket.id.uuidString)
    }
}
