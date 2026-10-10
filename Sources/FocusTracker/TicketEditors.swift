import FocusCore
import SwiftUI

struct StatusEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        let options = store.statusOptions(for: ticket)
        if let field = ticket.projectStatusField, !options.isEmpty {
            Picker("Status", selection: Binding(
                get: { field.value },
                set: { store.setStatusOption(ticket.id, project: field.project, option: $0) }
            )) {
                if !options.contains(where: { $0.name == field.value }) { Text(field.value).tag(field.value) }
                ForEach(options, id: \.name) { Text($0.name).tag($0.name) }
            }
        } else {
            Picker("Status", selection: Binding(get: { ticket.status }, set: { store.setStatus(ticket.id, $0) })) {
                ForEach(TicketStatus.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

struct PriorityEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        let options = store.priorityOptions(for: ticket)
        if ticket.github != nil, !options.isEmpty {
            let current = ticket.field(named: "Priority")?.value ?? ""
            Picker("Priority", selection: Binding(
                get: { current },
                set: { store.setPriorityOption(ticket.id, option: $0.isEmpty ? nil : $0) }
            )) {
                Text("None").tag("")
                if !current.isEmpty, !options.contains(where: { $0.name == current }) { Text(current).tag(current) }
                ForEach(options, id: \.name) { Text($0.name).tag($0.name) }
            }
        } else {
            Picker("Priority", selection: Binding(get: { ticket.priority }, set: { store.setPriority(ticket.id, $0) })) {
                ForEach(Priority.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

struct MilestoneEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        if ticket.github != nil {
            let options = store.milestoneOptions(for: ticket)
            let current = ticket.milestone?.title ?? ""
            Picker("Milestone", selection: Binding(
                get: { current },
                set: { title in
                    if title.isEmpty {
                        store.setMilestone(ticket.id, nil)
                    } else if let option = options.first(where: { $0.title == title }) {
                        store.setMilestone(ticket.id, option)
                    }
                }
            )) {
                Text("None").tag("")
                if !current.isEmpty, !options.contains(where: { $0.title == current }) { Text(current).tag(current) }
                ForEach(options, id: \.title) { Text($0.isOpen ? $0.title : "\($0.title) (closed)").tag($0.title) }
            }
        }
    }
}

struct TargetDateEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        let label = ticket.github != nil ? "Target date" : "Due date"
        Toggle(label, isOn: Binding(
            get: { ticket.dueDate != nil },
            set: { store.setTargetDate(ticket.id, $0 ? Date() : nil) }
        ))
        if let due = ticket.dueDate {
            DatePicker("Date", selection: Binding(get: { due }, set: { store.setTargetDate(ticket.id, $0) }), displayedComponents: .date)
        }
    }
}

struct LabelsEditor: View {
    let ticket: Ticket
    @State private var showing = false

    var body: some View {
        LabeledContent("Labels") {
            HStack(alignment: .top) {
                FlowLayout { LabelChips(ticket: ticket, limit: 30) }
                Button { showing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit labels")
                    .popover(isPresented: $showing, arrowEdge: .bottom) { LabelPicker(ticketID: ticket.id) }
            }
        }
    }
}

private struct LabelPicker: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    @State private var search = ""
    @State private var newLabel = ""

    var body: some View {
        if let ticket = store.ticket(ticketID) {
            let options = store.labelOptions(for: ticket)
            let names = options.map(\.name) + ticket.labels.filter { label in !options.contains { $0.name == label } }
            let shown = search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(search) }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter labels", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shown, id: \.self) { name in
                            Toggle(isOn: Binding(
                                get: { ticket.labels.contains(name) },
                                set: { on in
                                    var labels = store.ticket(ticketID)?.labels ?? []
                                    if on, !labels.contains(name) { labels.append(name) }
                                    if !on { labels.removeAll { $0 == name } }
                                    store.setLabels(ticketID, labels)
                                }
                            )) {
                                LabelChip(name: name, hex: ticket.labelColors?[name] ?? options.first { $0.name == name }?.color)
                            }
                            .toggleStyle(.checkbox)
                        }
                        if shown.isEmpty { Text("No labels").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                if ticket.github == nil {
                    HStack {
                        TextField("New label", text: $newLabel).textFieldStyle(.roundedBorder).onSubmit(add)
                        Button("Add", action: add).disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else if options.isEmpty {
                    Text("Labels load after the next GitHub sync.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 280)
        }
    }

    private func add() {
        let name = newLabel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, var labels = store.ticket(ticketID)?.labels, !labels.contains(name) else { return }
        labels.append(name)
        store.setLabels(ticketID, labels)
        newLabel = ""
    }
}

/// Commits on Return or when the field loses focus, so one edit is one log entry.
struct TitleEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket
    @State private var draft: String
    @FocusState private var focused: Bool

    init(ticket: Ticket) {
        self.ticket = ticket
        _draft = State(initialValue: ticket.title)
    }

    var body: some View {
        TextField("Title", text: $draft)
            .font(.title3.weight(.semibold))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: ticket.title) { _, new in if !focused { draft = new } }
    }

    private func commit() {
        store.setTitle(ticket.id, draft)
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = ticket.title }
    }
}

struct DescriptionSection: View {
    let ticket: Ticket
    @State private var editing = false

    var body: some View {
        Section("Description") {
            if ticket.body.isEmpty {
                Text("No description").foregroundStyle(.secondary)
            } else {
                DescriptionView(markdown: ticket.body)
            }
            Button { editing = true } label: { Label("Edit description", systemImage: "pencil") }
        }
        .sheet(isPresented: $editing) { EditDescriptionSheet(ticketID: ticket.id, initial: ticket.body) }
    }
}

private struct EditDescriptionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ticketID: UUID
    @State private var draft: String

    init(ticketID: UUID, initial: String) {
        self.ticketID = ticketID
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit description").font(.title3.weight(.semibold))
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.setBody(ticketID, draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft == store.ticket(ticketID)?.body)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct TicketHistorySection: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    var showAll: () -> Void
    @State private var opened: EntryRef?

    var body: some View {
        let entries = store.actionLog(for: ticketID)
        if !entries.isEmpty {
            Section("History") {
                ForEach(entries.prefix(6)) { entry in
                    Button { opened = EntryRef(id: entry.id) } label: {
                        HStack(spacing: 8) {
                            Text(entry.summary).lineLimit(1)
                            Spacer(minLength: 6)
                            SyncBadge(sync: entry.sync)
                            Text(entry.timestamp, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if entries.count > 6 {
                    Button("Show all \(entries.count) in Action Log", action: showAll)
                }
            }
            .sheet(item: $opened) { ref in ActionDetailSheet(entryID: ref.id) { _ in } }
        }
    }
}
