import FocusCore
import SwiftUI

struct TicketDetailView: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    var onPlan: () -> Void = {}
    @State private var editing: LogEdit?

    var body: some View {
        if let ticket = store.ticket(ticketID) {
            let isRemote = ticket.github != nil
            Form {
                Section {
                    if isRemote {
                        Text(ticket.title).font(.title2.bold()).textSelection(.enabled)
                    } else {
                        TextField("Title", text: field(\.title))
                            .font(.title3.weight(.semibold))
                    }
                    FlowLayout {
                        StatusBadge(status: ticket.status)
                        MetaChips(ticket: ticket)
                        LabelChips(ticket: ticket, limit: 8)
                    }
                    if let gh = ticket.github, let url = URL(string: gh.url) {
                        Link(destination: url) { Label("\(gh.repo)#\(gh.number) on GitHub", systemImage: "arrow.up.right.square") }
                        if gh.remoteClosed {
                            Text("No longer assigned to you or closed on GitHub.").font(.caption).foregroundStyle(Theme.warning)
                        }
                    }
                    Button(action: onPlan) { Label("Plan", systemImage: "checklist") }
                }

                Section("Details") {
                    Picker("Status", selection: Binding(get: { ticket.status }, set: { store.setStatus(ticketID, $0) })) {
                        ForEach(TicketStatus.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Priority", selection: field(\.priority)) {
                        ForEach(Priority.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Due date", isOn: Binding(
                        get: { ticket.dueDate != nil },
                        set: { on in store.update(ticketID) { $0.dueDate = on ? Date() : nil } }
                    ))
                    if let due = ticket.dueDate {
                        DatePicker("Due", selection: Binding(get: { due }, set: { d in store.update(ticketID) { $0.dueDate = d } }), displayedComponents: .date)
                    }
                    Stepper(
                        "Estimate: \(ticket.effectiveEstimateMinutes.map { Format.short(TimeInterval($0 * 60)) } ?? "none")",
                        value: Binding(
                            get: { ticket.effectiveEstimateMinutes ?? 0 },
                            set: { store.setEstimate(ticketID, minutes: $0) }
                        ),
                        in: 0...6000,
                        step: 15
                    )
                    if let source = ticket.estimateField {
                        Text("Synced with \"\(source.name)\" in \(source.project)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if ticket.milestone != nil || !ticket.allFields.isEmpty {
                    GitHubFieldsSection(ticket: ticket)
                }

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
                                Button { store.deleteEntry(entry.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                            .font(.callout)
                        case .note(let note):
                            NoteRow(note: note) { store.deleteNote(note.id) }
                        case .activity:
                            EmptyView()
                        }
                    }
                }

                if !isRemote {
                    Section {
                        Button("Delete ticket", role: .destructive) { store.deleteTicket(ticketID) }
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(item: $editing) { EditLogSheet(target: $0) }
            .task(id: ticketID) { await store.refreshTicket(ticketID) }
        } else {
            ContentUnavailableView("Ticket not found", systemImage: "questionmark.circle")
        }
    }

    private func field<T>(_ keyPath: WritableKeyPath<Ticket, T>) -> Binding<T> {
        Binding(
            get: { store.ticket(ticketID)![keyPath: keyPath] },
            set: { value in store.update(ticketID) { $0[keyPath: keyPath] = value } }
        )
    }
}
