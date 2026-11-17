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
    @State private var activeTypeFilter: Set<String>? = nil
    @State private var activeStatusFilter: Set<String>? = nil
    private let pageSize = 10

    // Declared so the card re-renders when a plan setting changes in Settings.
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.defaultEstimateMinutes) private var defaultEstimateMinutes = 60
    @AppStorage(PrefKey.workDays) private var workDays = 5

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    /// "tomorrow", or the weekday of the next working day (for example "Monday" after a Friday).
    private var nextWorkDayName: String {
        let calendar = Calendar.current
        let next = store.planSettings.nextWorkingDay(after: day)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return calendar.isDate(next, inSameDayAs: tomorrow) ? "tomorrow" : next.formatted(.dateTime.weekday(.wide))
    }

    var body: some View {
        let candidates = store.planCandidates(for: day, typeFilter: effectiveTypeFilter, statusFilter: effectiveStatusFilter)
        let plannedIDs = Set(store.plan(for: day)?.ticketIDs ?? [])
        let capacity = store.capacity(for: day, calendarBusy: calendarBusy)
        let planned = DayPlanner.plannedMinutes(candidates, ids: plannedIDs, capacityMinutes: capacity.capacityMinutes)
        let over = planned > capacity.capacityMinutes
        let isToday = Calendar.current.isDate(day, inSameDayAs: store.now)
        let workingDay = store.planSettings.isWorkingDay(day)
        let load = store.dayLoad(for: day, calendarBusy: calendarBusy)
        let deferIDs = isToday && workingDay ? Set(store.deferCandidates(for: day, calendarBusy: calendarBusy)) : []
        let fresh = isToday ? store.newSincePlanning(for: day) : []

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Plan", count: candidates.filter { plannedIDs.contains($0.id) }.count)
                Spacer()
                Button("Re-suggest") { store.suggestPlan(for: day, calendarBusy: calendarBusy) }
                    .buttonStyle(.secondary)
                    .disabled(candidates.isEmpty || !workingDay)
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
                    liveSection(load, workingDay: workingDay)
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
            VStack(alignment: .leading, spacing: 6) {
                typeFilterChipsBar
                statusFilterChipsBar
            }
            if effectiveTypeFilter.isEmpty {
                EmptyHint(
                    text: "No ticket types selected. Adjust your filters or settings to see candidates.",
                    symbol: "line.3.horizontal.decrease.circle"
                )
            } else if effectiveStatusFilter.isEmpty {
                VStack(spacing: 8) {
                    EmptyHint(
                        text: "No project statuses selected. Adjust your filters or settings to see candidates.",
                        symbol: "line.3.horizontal.decrease.circle"
                    )
                    Button("Reset Status Filters") {
                        activeStatusFilter = nil
                        page = 0
                    }
                    .buttonStyle(.secondary)
                }
            } else if candidates.isEmpty {
                VStack(spacing: 8) {
                    EmptyHint(
                        text: workingDay
                            ? ((effectiveTypeFilter.count < PlanTicketCategory.allCases.count || effectiveStatusFilter.count < store.workspaceProjectStatuses.count) ? "No open tickets match the selected filters." : "No open tickets to plan. Sync GitHub or add a ticket.")
                            : "Nothing to plan on a day off. Carried-over tickets show on \(nextWorkDayName).",
                        symbol: (effectiveTypeFilter.count < PlanTicketCategory.allCases.count || effectiveStatusFilter.count < store.workspaceProjectStatuses.count) ? "line.3.horizontal.decrease" : "checklist"
                    )
                    if effectiveStatusFilter.count < store.workspaceProjectStatuses.count || activeStatusFilter != nil {
                        Button("Reset Status Filters") {
                            activeStatusFilter = nil
                            page = 0
                        }
                        .buttonStyle(.secondary)
                    }
                }
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
                HStack(spacing: 5) {
                    Image(systemName: candidate.ticket.planCategory.iconName)
                        .imageScale(.small)
                        .help(candidate.ticket.planCategory.rawValue)
                    Text(candidate.ticket.displayKey)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if canDefer {
                Button { store.deferToTomorrow(candidate.id, from: day) } label: {
                    Label(nextWorkDayName.capitalized, systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(.secondary)
                .help("Move to \(nextWorkDayName)")
            }
            LabelChip(name: store.statusName(for: candidate.ticket), hex: candidate.ticket.projectStatusField?.color)
            Chip(text: candidate.reason.title, color: candidate.reason.color)
            Text("\(candidate.estimatedByApp ? "~" : "")\(text(candidate.estimateMinutes))\(candidate.trackedMinutes > 0 || candidate.plannedAheadMinutes > 0 ? " left" : "")")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(rowEstimateHelp(candidate))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .selectsTicket(candidate.id, selection: $selectedTicketID)
    }

    private func liveSection(_ load: DayLoad, workingDay: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                liveStat("Planned done", load.plannedTrackedMinutes)
                liveStat("Planned left", load.remainingPlannedMinutes)
                liveStat("Unplanned", load.unplannedMinutes)
                Spacer()
                if workingDay {
                    Text(load.isOverloaded ? "\(text(load.overloadMinutes)) over" : "\(text(load.remainingTodayMinutes)) left today")
                        .foregroundStyle(load.isOverloaded ? Theme.warning : Color.primary)
                }
            }
            .font(.caption.monospacedDigit())
            if workingDay && load.isOverloaded {
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
                    .selectsTicket(candidate.id, selection: $selectedTicketID)
                }
            }
            .cardStyle(padding: 0)
            if fresh.count > 5 {
                Text("+\(fresh.count - 5) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rowEstimateHelp(_ candidate: PlanCandidate) -> String {
        let base = candidate.estimatedByApp ? "Estimated by the app: no estimate on this ticket" : "Ticket estimate"
        var notes: [String] = []
        if candidate.trackedMinutes > 0 { notes.append("\(text(candidate.trackedMinutes)) already tracked") }
        if candidate.plannedAheadMinutes > 0 { notes.append("\(text(candidate.plannedAheadMinutes)) planned on earlier days") }
        return ([base] + notes).joined(separator: ". ")
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

    private var effectiveTypeFilter: Set<String> {
        activeTypeFilter ?? store.planSettings.includedTicketTypes
    }

    private var isAllSelected: Bool {
        PlanTicketCategory.allCases.allSatisfy { effectiveTypeFilter.contains($0.rawValue) }
    }

    private var typeFilterChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(title: "All Types", symbol: nil, isSelected: isAllSelected) {
                    activeTypeFilter = Set(PlanTicketCategory.allCases.map(\.rawValue))
                    page = 0
                }
                ForEach(PlanTicketCategory.allCases) { category in
                    filterChip(
                        title: category.rawValue,
                        symbol: category.iconName,
                        isSelected: effectiveTypeFilter.contains(category.rawValue)
                    ) {
                        toggleCategoryFilter(category)
                        page = 0
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func toggleCategoryFilter(_ category: PlanTicketCategory) {
        if isAllSelected {
            activeTypeFilter = [category.rawValue]
        } else if effectiveTypeFilter.contains(category.rawValue) {
            var updated = effectiveTypeFilter
            updated.remove(category.rawValue)
            activeTypeFilter = updated
        } else {
            var updated = effectiveTypeFilter
            updated.insert(category.rawValue)
            activeTypeFilter = updated
        }
    }

    private var defaultProjectStatuses: Set<String> {
        let statuses = store.workspaceProjectStatuses
        return (!store.isPlanProjectStatusesConfigured && store.planIncludedProjectStatuses.isEmpty)
            ? Set(statuses.filter { $0.status != .done }.map(\.id))
            : store.planIncludedProjectStatuses
    }

    private var effectiveStatusFilter: Set<String> {
        activeStatusFilter ?? defaultProjectStatuses
    }

    private var isAllStatusesSelected: Bool {
        let statuses = store.workspaceProjectStatuses
        return statuses.allSatisfy { opt in
            effectiveStatusFilter.contains(where: {
                $0.caseInsensitiveCompare(opt.id) == .orderedSame ||
                $0.caseInsensitiveCompare(opt.name) == .orderedSame
            })
        }
    }

    private var statusFilterChipsBar: some View {
        let multipleProjects = store.workspaceProjectStatusesByProject.count > 1
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(title: "All Statuses", symbol: nil, isSelected: isAllStatusesSelected) {
                    activeStatusFilter = Set(store.workspaceProjectStatuses.map(\.id))
                    page = 0
                }
                ForEach(store.workspaceProjectStatuses) { opt in
                    let isSelected = effectiveStatusFilter.contains(where: {
                        $0.caseInsensitiveCompare(opt.id) == .orderedSame ||
                        $0.caseInsensitiveCompare(opt.name) == .orderedSame
                    })
                    let title = multipleProjects ? "\(opt.project): \(opt.name)" : opt.name
                    statusChip(opt: opt, title: title, isSelected: isSelected) {
                        toggleStatusFilter(opt.id)
                        page = 0
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func toggleStatusFilter(_ statusKey: String) {
        if isAllStatusesSelected {
            activeStatusFilter = [statusKey]
        } else if effectiveStatusFilter.contains(where: { $0.caseInsensitiveCompare(statusKey) == .orderedSame }) {
            let updated = effectiveStatusFilter.filter { $0.caseInsensitiveCompare(statusKey) != .orderedSame }
            activeStatusFilter = updated
        } else {
            var updated = effectiveStatusFilter
            updated.insert(statusKey)
            activeStatusFilter = updated
        }
    }

    private func statusChip(opt: ProjectStatusOption, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color = opt.color, let rgb = LabelChip.rgb(color) {
                    Circle()
                        .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                        .frame(width: 6, height: 6)
                } else {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 6, height: 6)
                }
                Text(title)
            }
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func filterChip(title: String, symbol: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .imageScale(.small)
                }
                Text(title)
            }
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
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
