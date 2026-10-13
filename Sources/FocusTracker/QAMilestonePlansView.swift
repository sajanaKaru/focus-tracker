import FocusCore
import SwiftUI

/// The Milestones tab: one card per milestone plan with its progress, target date and tickets.
struct QAMilestonePlansView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?

    var body: some View {
        let plans = store.qaActiveMilestonePlans
        let plannable = store.qaPlannableMilestones()

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(plans.count) \(plans.count == 1 ? "milestone plan" : "milestone plans")")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(plannable, id: \.title) { milestone in
                        Button(milestone.isOpen ? milestone.title : "\(milestone.title) (closed)") { store.addQAMilestonePlan(milestone) }
                    }
                } label: {
                    Label("Plan a milestone", systemImage: "plus")
                }
                .fixedSize()
                .disabled(plannable.isEmpty)
                .help(plannable.isEmpty ? "Every milestone already has a plan" : "Start a test plan for a milestone")
            }

            if plans.isEmpty {
                EmptyHint(text: "No milestone plans yet. Plan a milestone to track its tickets as one release.", symbol: "flag.checkered")
            } else {
                ForEach(plans) { plan in
                    MilestonePlanCard(plan: plan, selectedTicketID: $selectedTicketID)
                }
            }
        }
    }
}

private struct MilestonePlanCard: View {
    @Environment(AppStore.self) private var store
    let plan: QAMilestonePlan
    @Binding var selectedTicketID: UUID?
    @State private var expanded = false
    @State private var editingTarget = false
    @State private var targetDraft = Date()

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    var body: some View {
        let now = store.now
        let progress = store.qaMilestoneProgress(for: plan)
        let overdue = progress.isOverdue(at: now)
        let plannedIDs = Set(store.qaPlan(for: now)?.ticketIDs ?? [])

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered").foregroundStyle(Theme.accent)
                Text(plan.milestone).font(.headline)
                Spacer()
                targetLabel(progress, overdue: overdue, now: now)
                menu
            }

            if progress.tickets.isEmpty {
                Text("Nothing waiting for QA in this milestone.").font(.callout).foregroundStyle(.secondary)
            } else {
                DashboardBar(segments: [
                    .init(value: progress.verified, color: Theme.success),
                    .init(value: progress.count(.testing), color: Theme.info),
                    .init(value: progress.count(.failed), color: Theme.danger)
                ])
                Text("\(progress.verified) of \(progress.total) verified · ~\(text(progress.remainingMinutes)) remaining")
                    .font(.callout.monospacedDigit())
                HStack(spacing: 6) {
                    Chip(text: "Failed \(progress.count(.failed))", color: Theme.danger)
                    Chip(text: "Testing \(progress.count(.testing))", color: Theme.info)
                    Chip(text: "Ready \(progress.count(.ready))", color: Theme.warning)
                    Chip(text: "Verified \(progress.verified)", color: Theme.success)
                    Spacer()
                    Button(expanded ? "Hide tickets" : "Show tickets") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
                if expanded {
                    VStack(spacing: 0) {
                        ForEach(Array(progress.tickets.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { Divider() }
                            QAPlanTicketRow(
                                candidate: candidate, planned: plannedIDs.contains(candidate.id), day: now,
                                selectedTicketID: $selectedTicketID,
                                onExclude: { store.excludeFromQAMilestonePlan(plan.id, ticketID: candidate.id) }
                            )
                        }
                    }
                    .cardStyle(padding: 0)
                }
            }
        }
        .cardStyle()
        .popover(isPresented: $editingTarget) { targetEditor }
    }

    private func targetLabel(_ progress: QAMilestoneProgress, overdue: Bool, now: Date) -> some View {
        Group {
            if let target = plan.targetDate {
                let days = progress.daysRemaining(at: now) ?? 0
                let when = days == 0 ? "today" : days > 0 ? "in \(days)d" : overdue ? "\(-days)d overdue" : "passed"
                Text("Target \(target.formatted(date: .abbreviated, time: .omitted)) · \(when)")
                    .foregroundStyle(overdue ? Theme.danger : Color.secondary)
            } else {
                Text("No target date").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
    }

    private var menu: some View {
        let excluded = store.qaExcludedTickets(for: plan)
        return Menu {
            Button("Edit target date…") {
                targetDraft = plan.targetDate ?? store.now
                editingTarget = true
            }
            if !excluded.isEmpty {
                Menu("Excluded tickets") {
                    ForEach(excluded) { ticket in
                        Button("Restore \(ticket.title)") { store.restoreToQAMilestonePlan(plan.id, ticketID: ticket.id) }
                    }
                }
            }
            Divider()
            Button("Archive plan") { store.archiveQAMilestonePlan(plan.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Target date", selection: $targetDraft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Clear") {
                    store.setQAMilestoneTarget(plan.id, nil)
                    editingTarget = false
                }
                Spacer()
                Button("Save") {
                    store.setQAMilestoneTarget(plan.id, Calendar.current.startOfDay(for: targetDraft))
                    editingTarget = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}
