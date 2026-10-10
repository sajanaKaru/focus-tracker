import FocusCore
import SwiftUI

struct EntryRef: Identifiable {
    let id: UUID
}

struct ActionLogView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @Binding var filter: ActionLogFilter
    @State private var opened: EntryRef?
    @State private var confirmingPrune = false

    private static let pruneDays = 60

    private var cutoff: Date {
        Calendar.current.date(byAdding: .day, value: -Self.pruneDays, to: store.now) ?? .distantPast
    }

    private var kindBinding: Binding<ActionKind?> {
        Binding(get: { filter.kinds.first }, set: { filter.kinds = $0.map { [$0] } ?? [] })
    }

    var body: some View {
        let entries = filter.apply(to: store.actionLog)
        let oldCount = store.actionLogCount(olderThan: cutoff)

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    PageHeader(title: "Action Log", subtitle: "Everything you change in the app, with what it was before.")
                    Spacer()
                    Button { confirmingPrune = true } label: { Label("Delete older than \(Self.pruneDays) days", systemImage: "trash") }
                        .buttonStyle(.secondary)
                        .disabled(oldCount == 0)
                        .help(oldCount == 0 ? "No entries are older than \(Self.pruneDays) days" : "Delete \(oldCount) old entries")
                }
                filters
            }
            .padding(20)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("No actions found", systemImage: "list.clipboard", description: Text("Changes you make in the app show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    Button { opened = EntryRef(id: entry.id) } label: { ActionLogRow(entry: entry) }
                        .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .background(Theme.pageBackground)
        .sheet(item: $opened) { ref in
            ActionDetailSheet(entryID: ref.id) { selectedTicketID = $0 }
        }
        .confirmDestructive(
            $confirmingPrune,
            title: "Delete \(oldCount) entries older than \(Self.pruneDays) days?",
            message: "Newer entries are kept. This can't be undone.",
            confirmLabel: "Delete"
        ) { store.deleteActionLog(olderThan: cutoff) }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            TextField("Search ticket, field or value", text: $filter.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Picker("Type", selection: kindBinding) {
                Text("All types").tag(ActionKind?.none)
                ForEach(ActionKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(width: 150)
            Picker("Sync", selection: $filter.sync) {
                ForEach(SyncFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            if let id = filter.ticketID {
                let label = store.ticket(id)?.displayKey ?? store.actionLog.last { $0.ticketID == id }?.ticketKey ?? "Ticket"
                Button { filter.ticketID = nil } label: { Label(label, systemImage: "xmark.circle.fill") }
                    .buttonStyle(.secondary)
                    .help("Show all tickets")
            }
            Spacer()
        }
    }
}

struct ActionLogRow: View {
    let entry: ActionLogEntry

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: entry.kind.symbol, tint: entry.kind.tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.summary).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if let key = entry.ticketKey { Text(key).font(.caption).foregroundStyle(.secondary) }
                    if let title = entry.ticketTitle { Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            SyncBadge(sync: entry.sync)
            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ActionDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entryID: UUID
    var openTicket: (UUID) -> Void
    @State private var retrying = false

    var body: some View {
        if let entry = store.actionLog.first(where: { $0.id == entryID }) {
            VStack(spacing: 0) {
                HStack {
                    IconTile(symbol: entry.kind.symbol, tint: entry.kind.tint, size: 32)
                    Text(entry.kind.title).font(.title3.weight(.semibold))
                    SyncBadge(sync: entry.sync)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(16)
                Divider()
                Form {
                    Section("Action") {
                        LabeledContent("When", value: entry.timestamp.formatted(date: .complete, time: .standard))
                        if let field = entry.field { LabeledContent("What", value: field) }
                        if let key = entry.ticketKey {
                            LabeledContent("Ticket") {
                                if let id = entry.ticketID, store.ticket(id) != nil {
                                    Button("\(key) · \(entry.ticketTitle ?? "")") {
                                        openTicket(id)
                                        dismiss()
                                    }
                                    .buttonStyle(.link)
                                } else {
                                    Text("\(key) · \(entry.ticketTitle ?? "") (deleted)").foregroundStyle(.secondary)
                                }
                            }
                        } else if let title = entry.ticketTitle {
                            LabeledContent("Ticket", value: title)
                        }
                    }
                    if entry.oldValue != nil || entry.newValue != nil {
                        Section("Change") {
                            HStack(alignment: .top, spacing: 12) {
                                valueBox("Before", entry.oldValue)
                                valueBox("After", entry.newValue)
                            }
                            if let changes = entry.labelChanges, !(changes.added.isEmpty && changes.removed.isEmpty) {
                                FlowLayout {
                                    ForEach(changes.added, id: \.self) { Chip(text: "+ \($0)", color: Theme.success) }
                                    ForEach(changes.removed, id: \.self) { Chip(text: "− \($0)", color: Theme.danger) }
                                }
                            }
                        }
                    }
                    if entry.sync != .notApplicable || entry.githubDetail != nil {
                        Section("GitHub") {
                            LabeledContent("Status") { SyncBadge(sync: entry.sync) }
                            if case .synced(let date) = entry.sync {
                                LabeledContent("Synced at", value: date.formatted(date: .abbreviated, time: .standard))
                            }
                            if let detail = entry.githubDetail {
                                LabeledContent("Request") { Text(detail).multilineTextAlignment(.trailing).textSelection(.enabled) }
                            }
                            if let message = entry.sync.errorMessage {
                                LabeledContent("Error") {
                                    Text(message).foregroundStyle(Theme.danger).multilineTextAlignment(.trailing).textSelection(.enabled)
                                }
                            }
                            if entry.sync.isFailed {
                                Button {
                                    retrying = true
                                    Task {
                                        await store.retry(entry.id)
                                        retrying = false
                                    }
                                } label: {
                                    if retrying { ProgressView().controlSize(.small) } else { Label("Retry", systemImage: "arrow.clockwise") }
                                }
                                .disabled(retrying || entry.remote == nil)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(width: 560, height: 520)
        } else {
            ContentUnavailableView("Entry not found", systemImage: "questionmark.circle").frame(width: 360, height: 200)
        }
    }

    private func valueBox(_ title: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text ?? "None")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }
}
