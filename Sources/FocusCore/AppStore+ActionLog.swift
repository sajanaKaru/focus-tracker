import Foundation

extension AppStore {
    public func actionLog(for ticketID: UUID) -> [ActionLogEntry] {
        actionLog.filter { $0.ticketID == ticketID }.sorted { $0.timestamp > $1.timestamp }
    }

    public func failedActions(for ticketID: UUID) -> [ActionLogEntry] {
        failedActions.filter { $0.ticketID == ticketID }
    }

    public func syncStatus(for ticketID: UUID) -> TicketSyncStatus {
        if !failedActions(for: ticketID).isEmpty { return .failed }
        return ticket(ticketID)?.unsynced?.isEmpty == false ? .syncing : .synced
    }

    public func actionLogCount(olderThan cutoff: Date) -> Int {
        actionLog.filter { $0.timestamp < cutoff }.count
    }

    /// Failed entries the user hasn't dismissed from the banner yet.
    public var failureBannerCount: Int {
        failedActions.filter { !dismissedFailureIDs.contains($0.id) }.count
    }
}
