import Foundation

extension AppStore {
    public var qaActiveMilestonePlans: [QAMilestonePlan] {
        qaMilestonePlans.filter { !$0.archived }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Milestones on workspace tickets that have no active plan: open first, then closed, each A-Z.
    public func qaPlannableMilestones() -> [Milestone] {
        let planned = Set(qaActiveMilestonePlans.map(\.milestone))
        var byTitle: [String: Milestone] = [:]
        for milestone in workspaceTickets.compactMap(\.milestone) where !planned.contains(milestone.title) {
            if let existing = byTitle[milestone.title], existing.dueOn != nil || milestone.dueOn == nil { continue }
            byTitle[milestone.title] = milestone
        }
        return byTitle.values.sorted {
            if $0.isOpen != $1.isOpen { return $0.isOpen }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    public func addQAMilestonePlan(_ milestone: Milestone) {
        guard !qaActiveMilestonePlans.contains(where: { $0.milestone == milestone.title }) else { return }
        qaMilestonePlans.append(QAMilestonePlan(milestone: milestone.title, targetDate: milestone.dueOn))
        save()
    }

    public func setQAMilestoneTarget(_ planID: UUID, _ date: Date?) {
        updateQAMilestonePlan(planID) { $0.targetDate = date }
    }

    public func excludeFromQAMilestonePlan(_ planID: UUID, ticketID: UUID) {
        updateQAMilestonePlan(planID) { if !$0.excludedTicketIDs.contains(ticketID) { $0.excludedTicketIDs.append(ticketID) } }
    }

    public func restoreToQAMilestonePlan(_ planID: UUID, ticketID: UUID) {
        updateQAMilestonePlan(planID) { $0.excludedTicketIDs.removeAll { $0 == ticketID } }
    }

    public func archiveQAMilestonePlan(_ planID: UUID) {
        updateQAMilestonePlan(planID) { $0.archived = true }
    }

    public func qaMilestoneProgress(for plan: QAMilestonePlan) -> QAMilestoneProgress {
        let excluded = Set(plan.excludedTicketIDs)
        let tickets = qaCandidates(includeVerified: true)
            .filter { $0.ticket.milestone?.title == plan.milestone && !excluded.contains($0.id) }
        return QAMilestoneProgress(plan: plan, tickets: tickets)
    }

    /// Tickets QA removed from the plan, so they can be restored; ids that no longer exist are skipped.
    public func qaExcludedTickets(for plan: QAMilestonePlan) -> [Ticket] {
        plan.excludedTicketIDs.compactMap { ticket($0) }
    }

    private func updateQAMilestonePlan(_ id: UUID, _ change: (inout QAMilestonePlan) -> Void) {
        guard let index = qaMilestonePlans.firstIndex(where: { $0.id == id }) else { return }
        change(&qaMilestonePlans[index])
        save()
    }
}
