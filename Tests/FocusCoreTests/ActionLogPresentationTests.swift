import XCTest
@testable import FocusCore

@MainActor
final class ActionLogPresentationTests: XCTestCase {
    private func makeStore(status: Int = 500) -> (AppStore, UUID) {
        let transport = RecordingTransport { _ in (status, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        store.insertTicketForTest(Ticket(title: "A", labels: ["bug"], github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        return (store, store.tickets[0].id)
    }

    private func failedEntry(_ store: AppStore, _ ticket: UUID, field: String = "Labels") -> UUID {
        let t = store.ticket(ticket)
        let id = store.record(.ticketEdit, ticket: t, field: field, old: "a", new: "b", sync: .pending)
        store.setActionSync(id, .failed("403"))
        return id
    }

    func testSummaryAndBadges() {
        XCTAssertEqual(ActionLogEntry(kind: .ticketEdit, field: "Status", oldValue: "Todo", newValue: "Done").summary, "Status: Todo → Done")
        XCTAssertEqual(ActionLogEntry(kind: .note, field: "Note added", newValue: "hi").summary, "Note added: hi")
        XCTAssertEqual(ActionLogEntry(kind: .note, field: "Note deleted", oldValue: "hi").summary, "Note deleted (hi)")
        XCTAssertEqual(ActionLogEntry(kind: .timer, field: "Timer started").summary, "Timer started")
        XCTAssertEqual(ActionLogEntry(kind: .dayPlan).summary, "Day plan")
        XCTAssertNil(ActionSync.notApplicable.badgeTitle)
        XCTAssertEqual(ActionSync.pending.badgeTitle, "Pending")
        XCTAssertEqual(ActionSync.synced(Date()).badgeTitle, "Synced")
        XCTAssertEqual(ActionSync.failed("x").errorMessage, "x")
        XCTAssertTrue(ActionSync.failed("x").isFailed)
    }

    func testLabelChanges() {
        let entry = ActionLogEntry(kind: .ticketEdit, field: "Labels", oldList: ["bug", "ui"], newList: ["ui", "api"])
        XCTAssertEqual(entry.labelChanges?.added, ["api"])
        XCTAssertEqual(entry.labelChanges?.removed, ["bug"])
        XCTAssertNil(ActionLogEntry(kind: .ticketEdit, field: "Status").labelChanges)
    }

    func testFilterAppliesAllCriteriaNewestFirst() {
        let t1 = UUID(), t2 = UUID()
        let now = Date()
        let a = ActionLogEntry(timestamp: now.addingTimeInterval(-300), kind: .ticketEdit, ticketID: t1, ticketKey: "me/a#1", ticketTitle: "Login bug", field: "Labels", sync: .failed("x"))
        let b = ActionLogEntry(timestamp: now.addingTimeInterval(-200), kind: .note, ticketID: t2, ticketTitle: "Other", field: "Note added", newValue: "hello", sync: .notApplicable)
        let c = ActionLogEntry(timestamp: now.addingTimeInterval(-100), kind: .ticketEdit, ticketID: t1, ticketKey: "me/a#1", field: "Status", sync: .synced(now))
        let all = [a, b, c]

        XCTAssertEqual(ActionLogFilter().apply(to: all).map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(ActionLogFilter(ticketID: t1).apply(to: all).map(\.id), [c.id, a.id])
        XCTAssertEqual(ActionLogFilter(kinds: [.note]).apply(to: all).map(\.id), [b.id])
        XCTAssertEqual(ActionLogFilter(sync: .failed).apply(to: all).map(\.id), [a.id])
        XCTAssertEqual(ActionLogFilter(sync: .synced).apply(to: all).map(\.id), [c.id])
        XCTAssertEqual(ActionLogFilter(sync: .local).apply(to: all).map(\.id), [b.id])
        XCTAssertEqual(ActionLogFilter(query: "LOGIN").apply(to: all).map(\.id), [a.id])
        XCTAssertEqual(ActionLogFilter(query: "hello").apply(to: all).map(\.id), [b.id])
        XCTAssertEqual(ActionLogFilter(since: now.addingTimeInterval(-150)).apply(to: all).map(\.id), [c.id])
    }

    func testPerTicketQueriesAndSyncStatus() {
        let (store, id) = makeStore()
        XCTAssertEqual(store.syncStatus(for: id), .synced)

        let failed = failedEntry(store, id)
        XCTAssertEqual(store.failedActions(for: id).map(\.id), [failed])
        XCTAssertEqual(store.syncStatus(for: id), .failed)
        XCTAssertEqual(store.actionLog(for: id).first?.id, failed)

        store.setActionSync(failed, .synced(Date()))
        XCTAssertEqual(store.syncStatus(for: id), .synced)

        store.update(id) { $0.unsynced = ["Title"] }
        XCTAssertEqual(store.syncStatus(for: id), .syncing)
    }

    func testBannerDismissalAndReappearance() async {
        let (store, id) = makeStore()
        store.edit(id, FieldChange(field: "Labels", old: "bug", new: "x"), remote: .labels(["x"])) { $0.labels = ["x"] }
        await store.settlePushes()
        XCTAssertEqual(store.failureBannerCount, 1)

        store.dismissFailureBanner()
        XCTAssertEqual(store.failureBannerCount, 0)
        XCTAssertEqual(store.failedActions.count, 1, "dismiss keeps the failed entry")

        _ = failedEntry(store, id, field: "Title")
        XCTAssertEqual(store.failureBannerCount, 1, "a new failure re-shows the banner")

        store.dismissFailureBanner()
        XCTAssertEqual(store.failureBannerCount, 0)
        let labels = store.failedActions.first { $0.field == "Labels" }!.id
        let ok = await store.retry(labels)
        XCTAssertFalse(ok)
        XCTAssertEqual(store.failureBannerCount, 1, "a retried entry that fails again re-shows the banner")
    }

    func testCountOlderThan() {
        let (store, _) = makeStore()
        store.record(.note, field: "Note added", at: Date().addingTimeInterval(-70 * 86_400))
        store.record(.note, field: "Note added")
        XCTAssertEqual(store.actionLogCount(olderThan: Date().addingTimeInterval(-60 * 86_400)), 1)
    }
}
