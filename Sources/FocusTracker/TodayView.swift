import AppKit
import FocusCore
import SwiftUI

struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var sheet: TodaySheet?
    @State private var editing: LogEdit?
    /// nil follows the current day, including across midnight.
    @State private var chosenDay: Date?
    @State private var copied = false
    @State private var showDatePicker = false

    private var day: Date { chosenDay ?? store.now }
    private var isToday: Bool { Calendar.current.isDate(day, inSameDayAs: store.now) }
    private var isFuture: Bool { Calendar.current.startOfDay(for: day) > Calendar.current.startOfDay(for: store.now) }
    private var todayRange: DateInterval { store.dayRange(for: day) }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { day },
            set: { newValue in
                chosenDay = Calendar.current.isDate(newValue, inSameDayAs: store.now) ? nil : newValue
                showDatePicker = false
            }
        )
    }

    private func shiftDay(_ offset: Int) {
        guard let shifted = Calendar.current.date(byAdding: .day, value: offset, to: day) else { return }
        dayBinding.wrappedValue = shifted
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.daySummaryText(for: day, includeDate: true, includeTomorrow: isToday), forType: .string)
        NSPasteboard.general.setString(store.daySummaryHTML(for: day, includeDate: true, includeTomorrow: isToday), forType: .html)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var dayLabel: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var dayNavigator: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Button { shiftDay(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .help("Previous day (⌘[)")
                .keyboardShortcut("[", modifiers: .command)

                Divider().frame(height: 16)

                Button { showDatePicker.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                        Text(dayLabel).fontWeight(.medium)
                    }
                    .frame(minWidth: 120, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .help("Pick a day")
                .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
                    DatePicker("Day", selection: dayBinding, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                }

                Divider().frame(height: 16)

                Button { shiftDay(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .help("Next day (⌘])")
                .keyboardShortcut("]", modifiers: .command)
            }
            .buttonStyle(.plain)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))

            Button("Today") { chosenDay = nil }
                .buttonStyle(.secondary)
                .controlSize(.large)
                .disabled(isToday)
                .help("Jump back to today")
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: store.now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        let range = todayRange
        let active = store.tickets.filter { $0.status == .inProgress || $0.status == .inReview }
        let log = store.log(in: range)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: isToday ? greeting : day.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                        subtitle: day.formatted(date: .complete, time: .omitted)
                    )
                    Spacer()
                    if isToday {
                        HStack(spacing: 10) {
                            Button { sheet = .unplanned } label: { Label("Unplanned", systemImage: "bolt.fill") }
                                .buttonStyle(.secondary)
                                .controlSize(.large)
                                .help("Log a bug or request that wasn't planned and start its timer")
                            AddToTodayMenu(sheet: $sheet)
                        }
                    }
                }

                HStack(spacing: 10) {
                    dayNavigator
                    Spacer()
                    Button(action: copySummary) {
                        Label(
                            copied ? "Copied" : (isToday ? "Copy today's summary" : "Copy summary"),
                            systemImage: copied ? "checkmark" : "doc.on.clipboard"
                        )
                    }
                    .controlSize(.large)
                    .buttonStyle(.secondary)
                    .help("Copy the summary for the selected day")
                    .disabled(isFuture)
                }

                if !isFuture {
                    HStack(spacing: 14) {
                        StatCard(title: isToday ? "Tracked today" : "Tracked", value: Format.short(store.trackedTime(in: range)), symbol: "timer", tint: Theme.accent)
                        StatCard(title: "Active tickets", value: "\(active.count)", symbol: "bolt.fill", tint: Theme.warning)
                        StatCard(title: "Calls & meetings", value: Format.short(store.activityTime(in: range)), symbol: "phone.fill", tint: Theme.accentEnd)
                    }
                }

                if isToday || isFuture { DayPlanCard(selectedTicketID: $selectedTicketID, day: day) }

                if isToday {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "In progress", count: active.count)
                        if active.isEmpty {
                            EmptyHint(text: "Nothing in progress. Start a timer from Tickets.", symbol: "moon.zzz")
                        }
                        ForEach(active) { ticket in
                            TicketRow(ticket: ticket)
                                .cardStyle(padding: 10, selected: selectedTicketID == ticket.id)
                                .hoverLift()
                                .onTapGesture { selectedTicketID = ticket.id }
                        }
                    }
                }

                if !isFuture {
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
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add(let choice): AddActivitySheet(choice: choice)
            case .calendar: CalendarImportSheet()
            case .unplanned: QuickCaptureSheet()
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
            Button { store.deleteEntry(entry.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
