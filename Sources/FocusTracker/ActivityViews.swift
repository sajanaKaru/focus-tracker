import FocusCore
import SwiftUI

enum TodaySheet: Identifiable {
    case add(AddActivitySheet.Choice)
    case calendar

    var id: String {
        switch self {
        case .add(let choice): "add-\(choice.rawValue)"
        case .calendar: "calendar"
        }
    }
}

struct AddToTodayMenu: View {
    @Binding var sheet: TodaySheet?

    var body: some View {
        Menu {
            Button { sheet = .add(.call) } label: { Label("Call", systemImage: Activity.Kind.call.symbol) }
            Button { sheet = .add(.meeting) } label: { Label("Meeting", systemImage: Activity.Kind.meeting.symbol) }
            Button { sheet = .add(.ticket) } label: { Label("Ticket time", systemImage: "ticket") }
            Button { sheet = .add(.other) } label: { Label("Other", systemImage: Activity.Kind.other.symbol) }
            Divider()
            Button { sheet = .calendar } label: { Label("Import from Calendar…", systemImage: "calendar") }
        } label: {
            Label("Add to today", systemImage: "plus")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 4)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fixedSize()
        .help("Log a call, meeting, ticket time or import from Calendar")
    }
}

struct AddActivitySheet: View {
    enum Choice: String, CaseIterable, Identifiable {
        case call, meeting, ticket, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .call: "Call"
            case .meeting: "Meeting"
            case .ticket: "Ticket"
            case .other: "Other"
            }
        }

        var kind: Activity.Kind? {
            switch self {
            case .call: .call
            case .meeting: .meeting
            case .other: .other
            case .ticket: nil
            }
        }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice
    @State private var title = ""
    @State private var ticketID: UUID?
    @State private var startNow = false
    @State private var start = Date().addingTimeInterval(-1_800)
    @State private var minutes = 30

    init(choice: Choice) { _choice = State(initialValue: choice) }

    private var isTicket: Bool { choice == .ticket }
    private var canAdd: Bool { !isTicket || ticketID != nil }

    var body: some View {
        Form {
            Section { Text("Add to today").font(.title2.weight(.bold)) }

            Picker("Type", selection: $choice) {
                ForEach(Choice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if isTicket {
                Picker("Ticket", selection: $ticketID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(store.tickets.filter { $0.status != .done }.sorted { $0.updatedAt > $1.updatedAt }) { ticket in
                        Text("\(ticket.displayKey)  \(ticket.title)").tag(UUID?.some(ticket.id))
                    }
                }
            } else {
                TextField("Title", text: $title, prompt: Text("e.g. Sprint planning"))
                Toggle("Start a live timer now", isOn: $startNow)
            }

            if isTicket || !startNow {
                DatePicker("Started", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                Stepper("Duration: \(Format.short(TimeInterval(minutes * 60)))", value: $minutes, in: 5...720, step: 5)
            }

            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                    .keyboardShortcut(.cancelAction)
                Button(action: add) { ShortcutLabel(title: startNow && !isTicket ? "Start" : "Add", keys: "↩") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }

    private func add() {
        if let kind = choice.kind {
            if startNow {
                store.startActivity(kind: kind, title: title)
            } else {
                let end = min(start.addingTimeInterval(TimeInterval(minutes * 60)), Date())
                store.addActivity(kind: kind, title: title, start: start, end: end)
            }
        } else if let ticketID {
            let end = min(start.addingTimeInterval(TimeInterval(minutes * 60)), Date())
            store.addManualEntry(ticketID: ticketID, duration: end.timeIntervalSince(start), endingAt: end)
        }
        dismiss()
    }
}

struct CalendarImportSheet: View {
    private enum Phase {
        case loading
        case loaded([CalendarEvent])
        case failed(String)
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.loading
    @State private var selected: Set<String> = []
    @State private var kinds: [String: Activity.Kind] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Calendar").font(.title2.weight(.bold))
            Text("Today's events that have already started. Pick the ones to add to your time log.")
                .font(.callout).foregroundStyle(.secondary)

            content

            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                    .keyboardShortcut(.cancelAction)
                Button(action: addSelected) { ShortcutLabel(title: "Add \(selected.count) selected", keys: "↩") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Can't read the calendar", systemImage: "calendar.badge.exclamationmark", description: Text(message))
        case .loaded(let events) where events.isEmpty:
            ContentUnavailableView("No events yet today", systemImage: "calendar", description: Text("Events that haven't started are not shown."))
        case .loaded(let events):
            List(events) { event in row(event) }
                .listStyle(.inset)
        }
    }

    private func row(_ event: CalendarEvent) -> some View {
        let imported = store.hasImported(calendarEventID: event.id, start: event.start)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected.contains(event.key) },
                set: { on in if on { selected.insert(event.key) } else { selected.remove(event.key) } }
            ))
            .labelsHidden()
            .disabled(imported)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).lineLimit(1)
                Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened)) · \(event.calendar)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if imported {
                Chip(text: "Added", color: Theme.success, symbol: "checkmark")
            } else {
                Picker("", selection: Binding(get: { kinds[event.key] ?? Self.guessKind(event) }, set: { kinds[event.key] = $0 })) {
                    ForEach(Activity.Kind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func load() async {
        do {
            phase = .loaded(try await CalendarService().startedEvents(on: Date()))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func addSelected() {
        guard case .loaded(let events) = phase else { return }
        for event in events where selected.contains(event.key) {
            store.addActivity(
                kind: kinds[event.key] ?? Self.guessKind(event),
                title: event.title,
                start: event.start,
                end: event.end,
                calendarEventID: event.id
            )
        }
        dismiss()
    }

    private static func guessKind(_ event: CalendarEvent) -> Activity.Kind {
        let title = event.title.lowercased()
        return title.contains("call") || title.contains("huddle") ? .call : .meeting
    }
}

struct ActivityRow: View {
    @Environment(AppStore.self) private var store
    let activity: Activity
    let range: DateInterval
    var onEdit: (() -> Void)?

    var body: some View {
        let end = activity.end?.formatted(date: .omitted, time: .shortened) ?? "now"
        HStack(spacing: 10) {
            Image(systemName: activity.kind.symbol).foregroundStyle(Theme.accentEnd).frame(width: 16)
            Text(activity.title).lineLimit(1)
            Chip(text: activity.kind.title, color: Theme.accentEnd)
            Spacer()
            Text("\(activity.start.formatted(date: .omitted, time: .shortened)) – \(end)")
                .foregroundStyle(.secondary)
            Text(Format.short(activity.duration(in: range, at: store.now)))
                .font(.callout.weight(.medium).monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            if let onEdit {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
            }
            Button { store.deleteActivity(activity.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A time entry or activity opened for editing.
enum LogEdit: Identifiable {
    case entry(TimeEntry)
    case activity(Activity)

    var id: UUID {
        switch self {
        case .entry(let entry): entry.id
        case .activity(let activity): activity.id
        }
    }
}

struct EditLogSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: LogEdit
    @State private var kind: Activity.Kind = .other
    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var isRunning = false

    private var isActivity: Bool { if case .activity = target { true } else { false } }
    private var isValid: Bool { start < (isRunning ? Date() : end) }

    var body: some View {
        Form {
            Section { Text(isActivity ? "Edit activity" : "Edit time entry").font(.title2.weight(.bold)) }

            if isActivity {
                Picker("Type", selection: $kind) {
                    ForEach(Activity.Kind.allCases) { Text($0.title).tag($0) }
                }
                TextField("Title", text: $title)
            }

            DatePicker("Started", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            if isRunning {
                Text("Still running").foregroundStyle(.secondary)
            } else {
                DatePicker("Ended", selection: $end, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                Text("Duration: \(Format.short(max(0, end.timeIntervalSince(start))))")
                    .foregroundStyle(isValid ? Color.secondary : Theme.danger)
            }

            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                    .keyboardShortcut(.cancelAction)
                Button(action: save) { ShortcutLabel(title: "Save", keys: "↩") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
        .onAppear(perform: load)
    }

    private func load() {
        switch target {
        case .entry(let entry):
            start = entry.start
            isRunning = entry.end == nil
            end = entry.end ?? Date()
        case .activity(let activity):
            kind = activity.kind
            title = activity.title
            start = activity.start
            isRunning = activity.end == nil
            end = activity.end ?? Date()
        }
    }

    private func save() {
        switch target {
        case .entry(let entry): store.updateEntry(entry.id, start: start, end: end)
        case .activity(let activity): store.updateActivity(activity.id, kind: kind, title: title, start: start, end: end)
        }
        dismiss()
    }
}
