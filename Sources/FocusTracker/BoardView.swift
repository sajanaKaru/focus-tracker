import FocusCore
import SwiftUI

struct BoardView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    var filter = TicketFilter()
    @State private var targetedStatus: TicketStatus?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(TicketStatus.allCases) { status in
                    column(status)
                }
            }
            .padding(20)
        }
        .background(Theme.pageBackground)
    }

    private func column(_ status: TicketStatus) -> some View {
        let items = store.tickets(matching: filter).filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
        let targeted = targetedStatus == status
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(status.color).frame(width: 9, height: 9)
                Text(status.title).font(.headline)
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
        .background(targeted ? status.color.opacity(0.14) : status.color.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(targeted ? status.color.opacity(0.6) : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            for raw in ids {
                if let id = UUID(uuidString: raw) { store.setStatus(id, status) }
            }
            return !ids.isEmpty
        } isTargeted: { targetedStatus = $0 ? status : (targetedStatus == status ? nil : targetedStatus) }
    }

    private func card(_ ticket: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ticket.title).font(.body.weight(.medium)).lineLimit(3)
            if ticket.priority != .none || !ticket.labels.isEmpty || ticket.milestone != nil || ticket.issueType != nil || !ticket.allFields.isEmpty {
                FlowLayout {
                    MetaChips(ticket: ticket)
                    LabelChips(ticket: ticket, limit: 2)
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
