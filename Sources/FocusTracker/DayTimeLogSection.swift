import FocusCore
import SwiftUI

/// The day's time entries, notes and activities, with edit and delete.
struct DayTimeLogSection: View {
    @Environment(AppStore.self) private var store
    let day: Date
    let isToday: Bool
    @State private var editing: LogEdit?

    var body: some View {
        let range = store.dayRange(for: day)
        let log = store.log(in: range)

        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Time log", count: log.count)
            if log.isEmpty {
                EmptyHint(text: isToday ? "No time tracked yet." : "No time tracked on this day.", symbol: "clock")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(log.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        logRow(item, range: range)
                    }
                }
                .cardStyle(padding: 0)
            }
        }
        .sheet(item: $editing) { EditLogSheet(target: $0) }
    }

    @ViewBuilder
    private func logRow(_ item: LogItem, range: DateInterval) -> some View {
        switch item {
        case .time(let entry):
            if let ticket = store.ticket(entry.ticketID) { timeRow(entry: entry, ticket: ticket, range: range) }
        case .note(let note):
            if let ticket = store.ticket(note.ticketID) {
                NoteRow(note: note, ticketTitle: ticket.title) { store.deleteNote(note.id) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        case .activity(let activity):
            ActivityRow(activity: activity, range: range) { editing = .activity(activity) }
        }
    }

    private func timeRow(entry: TimeEntry, ticket: Ticket, range: DateInterval) -> some View {
        let end = entry.end?.formatted(date: .omitted, time: .shortened) ?? "now"
        return HStack(spacing: 10) {
            Circle().fill(ticket.status.color).frame(width: 8, height: 8)
            Text(ticket.title).lineLimit(1)
            Spacer()
            Text("\(entry.start.formatted(date: .omitted, time: .shortened)) – \(end)")
                .foregroundStyle(.secondary)
            Text(Format.short(entry.duration(in: range, at: store.now)))
                .font(.callout.weight(.medium).monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            Button { editing = .entry(entry) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit")
            DeleteButton(title: "Delete this time entry?") { store.deleteEntry(entry.id) }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
