import FocusCore
import SwiftUI

struct TicketRow: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ticket.status.symbol)
                .font(.title3)
                .foregroundStyle(ticket.status.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(ticket.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .strikethrough(ticket.status == .done)
                    .foregroundStyle(ticket.status == .done ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(ticket.displayKey).font(.caption).foregroundStyle(.secondary)
                    MetaChips(ticket: ticket)
                    LabelChips(ticket: ticket, limit: 3)
                }
            }
            Spacer(minLength: 8)
            let tracked = store.trackedTime(for: ticket.id)
            if tracked >= 60 {
                Label(Format.short(tracked), systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            TimerButton(ticketID: ticket.id)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct TimerButton: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID

    var body: some View {
        let tracking = store.isTracking(ticketID)
        Button { store.toggle(ticketID) } label: {
            Image(systemName: tracking ? "stop.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tracking ? Theme.danger : Theme.accent)
                .frame(width: 28, height: 28)
                .background((tracking ? Theme.danger : Theme.accent).opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .help(tracking ? "Stop timer" : "Start timer")
    }
}

struct TicketsView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    var filter = TicketFilter()
    @State private var search = ""
    @State private var showDone = false

    var body: some View {
        let visible = store.tickets(matching: filter).filter { ticket in
            (showDone || ticket.status != .done)
                && (search.isEmpty
                    || ticket.title.localizedCaseInsensitiveContains(search)
                    || ticket.displayKey.localizedCaseInsensitiveContains(search))
        }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(TicketStatus.allCases.reversed().filter { $0 != .done } + [.done]) { status in
                    let group = visible.filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle().fill(status.color).frame(width: 8, height: 8)
                                Text(status.title).font(.subheadline.weight(.semibold))
                                Text("\(group.count)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ForEach(group) { ticket in
                                TicketRow(ticket: ticket)
                                    .cardStyle(padding: 10, selected: selectedTicketID == ticket.id)
                                    .hoverLift()
                                    .onTapGesture { selectedTicketID = ticket.id }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.pageBackground)
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView(
                    "No tickets",
                    systemImage: "tray",
                    description: Text(filter.isActive
                        ? "No tickets match the current filters."
                        : "Add a GitHub token in Settings and sync, or create a local ticket with ⌘N.")
                )
            }
        }
        .searchable(text: $search, prompt: "Search tickets")
        .toolbar {
            ToolbarItem { Toggle("Show done", isOn: $showDone) }
        }
    }
}
