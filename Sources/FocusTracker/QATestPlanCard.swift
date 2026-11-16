import FocusCore
import SwiftUI

/// The QA plan section: today's capacity plan grouped by sprint, and one plan per milestone.
struct QATestPlanCard: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case today = "Today", milestones = "Milestones"
        var id: String { rawValue }
    }

    @Binding var selectedTicketID: UUID?
    @State private var tab: Tab = .today
    @State private var calendarBusy: [DateInterval] = []
    @State private var calendarNote: String?
    @Environment(AppStore.self) private var store

    var body: some View {
        let candidates = store.qaPlanCandidates()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Test plan")
                Spacer()
                Picker("Plan view", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            switch tab {
            case .today: QATodayPlanTab(selectedTicketID: $selectedTicketID, calendarBusy: calendarBusy, calendarNote: calendarNote)
            case .milestones: QAMilestonePlansView(selectedTicketID: $selectedTicketID)
            }
        }
        .task(id: "\(candidates.isEmpty)|\(Calendar.current.startOfDay(for: store.now))") { await loadCalendarAndPlan(day: store.now) }
    }

    private func loadCalendarAndPlan(day: Date) async {
        do {
            calendarBusy = try await CalendarService().busyIntervals(on: day)
            calendarNote = nil
        } catch {
            calendarBusy = []
            calendarNote = "Calendar unavailable, so meetings are not subtracted. \(error.localizedDescription)"
        }
        store.ensureQAPlan(for: day, calendarBusy: calendarBusy)
    }
}

struct QATodayPlanTab: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    let calendarBusy: [DateInterval]
    let calendarNote: String?

    // Declared so the tab re-renders when a plan setting changes in Settings.
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.workDays) private var workDays = 5

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    var body: some View {
        let day = store.now
        let groups = store.qaPlanSprintGroups()
        let candidates = groups.flatMap(\.candidates)
        let plannedIDs = Set(store.qaPlan(for: day)?.ticketIDs ?? [])
        let capacity = store.capacity(for: day, calendarBusy: calendarBusy)
        let planned = QAPlanner.plannedMinutes(candidates, ids: plannedIDs)
        let over = planned > capacity.capacityMinutes
        let workingDay = store.planSettings.isWorkingDay(day)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(candidates.filter { plannedIDs.contains($0.id) }.count) of \(candidates.count) planned today")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Re-suggest") { store.suggestQAPlan(for: day, calendarBusy: calendarBusy) }
                    .buttonStyle(.secondary)
                    .disabled(candidates.isEmpty || !workingDay)
                    .help("Rebuild the plan from the tickets waiting for QA, oldest sprint first")
            }

            VStack(alignment: .leading, spacing: 6) {
                CapacityBar(planned: planned, capacity: capacity.capacityMinutes, over: over)
                HStack {
                    Text("Planned \(text(planned)) of \(text(capacity.capacityMinutes)) capacity")
                        .foregroundStyle(over ? Theme.warning : Color.primary)
                    Spacer()
                    Text("\(text(capacity.freeMinutes)) free after meetings").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                if over {
                    Label("Over capacity by \(text(planned - capacity.capacityMinutes))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                if !workingDay {
                    Text("Not a working day. Change this in Settings → Working days.").font(.caption).foregroundStyle(.secondary)
                }
                if let calendarNote { Text(calendarNote).font(.caption).foregroundStyle(.secondary) }
            }

            if candidates.isEmpty {
                EmptyHint(text: "Nothing waiting for QA.", symbol: "checklist")
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        header(group, now: day)
                        VStack(spacing: 0) {
                            ForEach(Array(group.candidates.enumerated()), id: \.element.id) { index, candidate in
                                if index > 0 { Divider() }
                                QAPlanTicketRow(
                                    candidate: candidate, planned: plannedIDs.contains(candidate.id), day: day,
                                    selectedTicketID: $selectedTicketID
                                )
                            }
                        }
                        .cardStyle(padding: 0)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func header(_ group: QASprintGroup, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(group.sprint?.value ?? "No sprint").font(.headline)
            if group.isEnded(at: now), let end = group.sprint?.end {
                Chip(text: "Ended \(end.formatted(date: .abbreviated, time: .omitted)), still in QA", color: Theme.warning)
            } else if group.isCurrent(at: now) {
                Chip(text: "Current", color: Theme.accent)
            }
            Spacer()
            Text("\(group.candidates.count) \(group.candidates.count == 1 ? "ticket" : "tickets") · ~\(text(group.estimateMinutes))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

}

/// One ticket in a QA plan. Verified tickets show a seal instead of the planned toggle; `onExclude` adds a remove button.
struct QAPlanTicketRow: View {
    @Environment(AppStore.self) private var store
    let candidate: QAPlanCandidate
    let planned: Bool
    let day: Date
    @Binding var selectedTicketID: UUID?
    var onExclude: (() -> Void)?

    var body: some View {
        let verified = candidate.state == .verified
        HStack(spacing: 10) {
            if verified {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success).frame(width: 22)
            } else {
                Toggle("", isOn: Binding(get: { planned }, set: { _ in store.toggleQAPlanned(candidate.id, on: day) }))
                    .labelsHidden()
                    .toggleStyle(RoundCheckStyle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.ticket.title).lineLimit(1)
                Text(candidate.ticket.displayKey).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: candidate.state.title, color: candidate.state.color)
            if let environment = candidate.ticket.environment { Chip(text: environment.title, color: environment.color) }
            if !verified {
                Text("~\(Format.short(TimeInterval(candidate.estimateMinutes * 60)))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let onExclude {
                Button(action: onExclude) { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Exclude from this plan")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .selectsTicket(candidate.id, selection: $selectedTicketID)
    }
}
