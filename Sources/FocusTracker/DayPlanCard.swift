import FocusCore
import SwiftUI

struct DayPlanCard: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var calendarBusy: [DateInterval] = []
    @State private var calendarNote: String?
    @State private var page = 0
    private let pageSize = 10

    // Declared so the card re-renders when a plan setting changes in Settings.
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.defaultEstimateMinutes) private var defaultEstimateMinutes = 60

    private var day: Date { store.now }

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    var body: some View {
        let candidates = store.planCandidates(for: day)
        let plannedIDs = Set(store.plan(for: day)?.ticketIDs ?? [])
        let capacity = store.capacity(for: day, calendarBusy: calendarBusy)
        let planned = DayPlanner.plannedMinutes(candidates, ids: plannedIDs)
        let over = planned > capacity.capacityMinutes

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
                if over {
                    Label("Over capacity by \(text(planned - capacity.capacityMinutes))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                if let calendarNote { Text(calendarNote).font(.caption).foregroundStyle(.secondary) }
            }

            if candidates.isEmpty {
                EmptyHint(text: "No open tickets to plan. Sync GitHub or add a ticket.", symbol: "checklist")
            } else {
                let pageCount = (candidates.count + pageSize - 1) / pageSize
                let current = min(page, pageCount - 1)
                let visible = candidates.dropFirst(current * pageSize).prefix(pageSize)
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { Divider() }
                        row(candidate, planned: plannedIDs.contains(candidate.id))
                    }
                }
                .cardStyle(padding: 0)
                if pageCount > 1 { pager(current: current, pageCount: pageCount) }
            }
        }
        .task(id: candidates.isEmpty) { await loadCalendarAndPlan() }
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

    private func row(_ candidate: PlanCandidate, planned: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { planned }, set: { _ in store.togglePlanned(candidate.id, on: day) }))
                .labelsHidden()
                .toggleStyle(RoundCheckStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.ticket.title).lineLimit(1)
                Text(candidate.ticket.displayKey).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
        case .priority: Theme.warning
        case .open: Theme.slate
        }
    }
}
