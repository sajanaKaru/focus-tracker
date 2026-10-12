import FocusCore
import SwiftUI

struct TicketDetailView: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    var onPlan: () -> Void = {}
    var onOpenPage: () -> Void = {}
    var onShowLog: () -> Void = {}
    @State private var confirmingDelete = false

    var body: some View {
        if let ticket = store.ticket(ticketID) {
            let isRemote = ticket.github != nil
            Form {
                Section {
                    TitleEditor(ticket: ticket).id(ticketID)
                    FlowLayout {
                        StatusBadge(status: ticket.status)
                        MetaChips(ticket: ticket)
                        LabelChips(ticket: ticket, limit: 8)
                        TicketSyncMarker(ticketID: ticketID)
                    }
                    if let gh = ticket.github, let url = URL(string: gh.url) {
                        Link(destination: url) { Label("\(gh.repo)#\(gh.number) on GitHub", systemImage: "arrow.up.right.square") }
                        if gh.remoteClosed {
                            Text("No longer assigned to you or closed on GitHub.").font(.caption).foregroundStyle(Theme.warning)
                        }
                    }
                    Button(action: onPlan) { Label("Plan", systemImage: "checklist") }
                    Button(action: onOpenPage) { Label("Open page", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .keyboardShortcut("o", modifiers: .command)
                        .help("Open the full ticket page (⌘O)")
                }

                TicketDetailsSection(ticket: ticket)

                if !ticket.specialWork.isEmpty {
                    Section("Work type") {
                        LabeledContent("Special work") {
                            FlowLayout {
                                ForEach(ticket.specialWork) { Chip(text: $0.title, color: Theme.accentEnd, symbol: $0.symbol) }
                            }
                        }
                    }
                }

                if ticket.milestone != nil || !ticket.allFields.isEmpty {
                    GitHubFieldsSection(ticket: ticket)
                }
                TicketTimeLogSection(ticket: ticket)

                TicketHistorySection(ticketID: ticketID, showAll: onShowLog)

                if !isRemote {
                    Section {
                        Button("Delete ticket", role: .destructive) { confirmingDelete = true }
                            .confirmDestructive(
                                $confirmingDelete, title: "Delete this ticket?",
                                message: "Its time entries and notes are deleted too. This can't be undone."
                            ) { store.deleteTicket(ticketID) }
                    }
                }
            }
            .formStyle(.grouped)
            .task(id: ticketID) {
                await store.refreshTicket(ticketID)
                await store.loadOptions()
            }
        } else {
            ContentUnavailableView("Ticket not found", systemImage: "questionmark.circle")
        }
    }
}

/// Status, priority, milestone, dates, labels and estimate; shared by the side panel and the ticket page.
struct TicketDetailsSection: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        Section("Details") {
            StatusEditor(ticket: ticket)
            PriorityEditor(ticket: ticket)
            MilestoneEditor(ticket: ticket)
            TargetDateEditor(ticket: ticket)
            LabelsEditor(ticket: ticket)
            Stepper(
                "Estimate: \(ticket.effectiveEstimateMinutes.map { Format.short(TimeInterval($0 * 60)) } ?? "none")",
                value: Binding(
                    get: { ticket.effectiveEstimateMinutes ?? 0 },
                    set: { store.setEstimate(ticket.id, minutes: $0) }
                ),
                in: 0...6000,
                step: 15
            )
            if let source = ticket.estimateField {
                Text("Synced with \"\(source.name)\" in \(source.project)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Timer, manual time, notes and the time-entry list; shared by the side panel and the ticket page.
struct TicketTimeLogSection: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket
    @State private var editing: LogEdit?

    var body: some View {
        let ticketID = ticket.id
        Section("Time log") {
            let tracked = store.trackedTime(for: ticketID)
            HStack {
                TimerButton(ticketID: ticketID)
                Text(Format.clock(tracked)).font(.title.weight(.semibold).monospacedDigit())
                Spacer()
                if let estimate = ticket.effectiveEstimateMinutes {
                    Text("of \(Format.short(TimeInterval(estimate * 60)))")
                        .foregroundStyle(tracked > TimeInterval(estimate * 60) ? Theme.danger : Color.secondary)
                }
            }
            HStack {
                Text("Add")
                ForEach([15, 30, 60], id: \.self) { minutes in
                    Button("+\(minutes)m") { store.addManualEntry(ticketID: ticketID, duration: TimeInterval(minutes * 60)) }
                }
            }
            NoteComposer(ticketID: ticketID).id(ticketID)
            ForEach(store.log(for: ticketID)) { item in
                switch item {
                case .time(let entry):
                    HStack {
                        Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 16)
                        Text(entry.start.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(Format.short(entry.duration(at: store.now))).monospacedDigit()
                        Button { editing = .entry(entry) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Edit")
                        DeleteButton(title: "Delete this time entry?") { store.deleteEntry(entry.id) }
                    }
                    .font(.callout)
                case .note(let note):
                    NoteRow(note: note) { store.deleteNote(note.id) }
                case .activity:
                    EmptyView()
                }
            }
        }
        .sheet(item: $editing) { EditLogSheet(target: $0) }
    }
}
