import FocusCore
import SwiftUI

struct DayPlanCard: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    let day: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var calendarBusy: [DateInterval] = []
    @State private var calendarNote: String?
    @State private var page = 0
    @State private var search = ""
    private let pageSize = 10

    // Declared so the card re-renders when a plan setting changes in Settings.
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.defaultEstimateMinutes) private var defaultEstimateMinutes = 60
    @AppStorage(PrefKey.workDays) private var workDays = 5

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    var body: some View {
        let candidates = store.planCandidates(for: day)
        let plannedIDs = Set(store.plan(for: day)?.ticketIDs ?? [])
        let capacity = store.capacity(for: day, calendarBusy: calendarBusy)
        let planned = DayPlanner.plannedMinutes(candidates, ids: plannedIDs)
        let over = planned > capacity.capacityMinutes
        let isToday = Calendar.current.isDate(day, inSameDayAs: store.now)
        let load = store.dayLoad(for: day, calendarBusy: calendarBusy)
        let deferIDs = isToday ? Set(store.deferCandidates(for: day, calendarBusy: calendarBusy)) : []
        let fresh = isToday ? store.newSincePlanning(for: day) : []

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Plan", count: candidates.filter { plannedIDs.contains($0.id) }.count)
                Spacer()
                Button("Re-suggest") { store.suggestPlan(for: day, calendarBusy: calendarBusy) }
                    .buttonStyle(.secondary)
                    .disabled(candidates.isEmpty)
                    .help("Rebuild the plan from the ranked suggestions")
            }

            VStack(alignment: .leading, spacing: 6) {
                capacityBar(planned: planned, capacity: capacity.capacityMinutes, over: over)
                HStack {
                    Text("Planned \(text(planned)) of \(text(capacity.capacityMinutes)) capacity")
                        .foregroundStyle(over ? Theme.warning : Color.primary)
                    Spacer()
                    Text("\(text(capacity.freeMinutes)) free after meetings").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                if isToday {
                    liveSection(load)
                } else if over {
                    Label("Over capacity by \(text(planned - capacity.capacityMinutes))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                if !store.planSettings.isWorkingDay(day) {
                    Text("Not a working day. Change this in Settings → Working days.").font(.caption).foregroundStyle(.secondary)
                }
                if let calendarNote { Text(calendarNote).font(.caption).foregroundStyle(.secondary) }
            }

            if !fresh.isEmpty { newStrip(fresh) }
            if candidates.isEmpty {
                EmptyHint(text: "No open tickets to plan. Sync GitHub or add a ticket.", symbol: "checklist")
            } else {
                searchField
                let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = query.isEmpty ? candidates : candidates.filter {
                    $0.ticket.title.localizedCaseInsensitiveContains(query)
                        || $0.ticket.displayKey.localizedCaseInsensitiveContains(query)
                }
                let pageCount = max(1, (matches.count + pageSize - 1) / pageSize)
                let current = min(page, pageCount - 1)
                let visible = matches.dropFirst(current * pageSize).prefix(pageSize)
                if matches.isEmpty {
                    EmptyHint(text: "No tickets match \"\(query)\".", symbol: "magnifyingglass")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { Divider() }
                            row(candidate, planned: plannedIDs.contains(candidate.id), canDefer: deferIDs.contains(candidate.id))
                        }
                    }
                    .cardStyle(padding: 0)
                }
                if pageCount > 1 { pager(current: current, pageCount: pageCount) }
            }
        }
        .task(id: "\(candidates.isEmpty)|\(Calendar.current.startOfDay(for: day))") { await loadCalendarAndPlan() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search plan", text: $search)
                .textFieldStyle(.plain)
                .onChange(of: search) { page = 0 }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func pager(current: Int, pageCount: Int) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Button { page = current - 1 } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.secondary)
                .disabled(current == 0)
                .help("Previous page")
            Text("Page \(current + 1) of \(pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { page = current + 1 } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.secondary)
                .disabled(current >= pageCount - 1)
                .help("Next page")
            Spacer()
        }
    }

    private func row(_ candidate: PlanCandidate, planned: Bool, canDefer: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { planned }, set: { _ in store.togglePlanned(candidate.id, on: day) }))
                .labelsHidden()
                .toggleStyle(RoundCheckStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.ticket.title).lineLimit(1)
                Text(candidate.ticket.displayKey).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if canDefer {
                Button { store.deferToTomorrow(candidate.id, from: day) } label: {
                    Label("Tomorrow", systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(.secondary)
                .help("Move to tomorrow")
            }
            Chip(text: candidate.reason.title, color: candidate.reason.color)
            Text("\(candidate.estimatedByApp ? "~" : "")\(text(candidate.estimateMinutes))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(candidate.estimatedByApp ? "Estimated by the app: no estimate on this ticket" : "Ticket estimate")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { selectedTicketID = candidate.id }
    }

    private func liveSection(_ load: DayLoad) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                liveStat("Planned done", load.plannedTrackedMinutes)
                liveStat("Planned left", load.remainingPlannedMinutes)
                liveStat("Unplanned", load.unplannedMinutes)
                Spacer()
                Text(load.isOverloaded ? "\(text(load.overloadMinutes)) over" : "\(text(load.remainingTodayMinutes)) left today")
                    .foregroundStyle(load.isOverloaded ? Theme.warning : Color.primary)
            }
            .font(.caption.monospacedDigit())
            if load.isOverloaded {
                Label("Over by \(text(load.overloadMinutes)). Defer something?", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private func liveStat(_ title: String, _ minutes: Int) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(text(minutes))
        }
    }

    private func newStrip(_ fresh: [PlanCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEW SINCE PLANNING")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(fresh.prefix(5).enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.ticket.title).lineLimit(1)
                            Text(candidate.ticket.displayKey).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add to plan") { store.togglePlanned(candidate.id, on: day) }.buttonStyle(.secondary)
                        Button("Ignore") { store.ignoreNew(candidate.id, on: day) }.buttonStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedTicketID = candidate.id }
                }
            }
            .cardStyle(padding: 0)
            if fresh.count > 5 {
                Text("+\(fresh.count - 5) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func capacityBar(planned: Int, capacity: Int, over: Bool) -> some View {
        let fraction = min(Double(planned) / Double(max(capacity, 1)), 1)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(over ? Theme.warningGradient : Theme.accentGradient)
                    .frame(width: planned > 0 ? max(8, proxy.size.width * fraction) : 0)
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: planned)
        .accessibilityElement()
        .accessibilityLabel("Planned \(text(planned)) of \(text(capacity)) capacity")
    }

    private func loadCalendarAndPlan() async {
        do {
            calendarBusy = try await CalendarService().busyIntervals(on: day)
            calendarNote = nil
        } catch {
            calendarBusy = []
            calendarNote = "Calendar unavailable, so meetings are not subtracted. \(error.localizedDescription)"
        }
        store.ensurePlan(for: day, calendarBusy: calendarBusy)
    }
}

private extension PlanReason {
    var color: Color {
        switch self {
        case .dueNow: Theme.danger
        case .dueSoon: Theme.orange
        case .sprintEnding: Theme.teal
        case .carriedOver: Theme.accentEnd
        case .inProgress: Theme.info
        case .inSprint: Theme.accent
        case .priority: Theme.warning
        case .open: Theme.slate
        }
    }
}
