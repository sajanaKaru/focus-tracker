import XCTest
@testable import FocusCore

@MainActor
final class ActionLogTests: XCTestCase {
    private func makeStore() -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url)
    }

    func testChangesListsOnlyDifferences() {
        let old = Ticket(title: "A", status: .todo, labels: ["bug"], milestone: Milestone(title: "v1"))
        var new = old
        new.status = .done
        new.labels = ["bug", "ui"]
        new.milestone = nil

        let changes = old.changes(to: new)

        XCTAssertEqual(Set(changes.map(\.field)), ["Status", "Labels", "Milestone"])
        let labels = changes.first { $0.field == "Labels" }!
        XCTAssertEqual(labels.oldList, ["bug"])
        XCTAssertEqual(labels.newList, ["bug", "ui"])
        let milestone = changes.first { $0.field == "Milestone" }!
        XCTAssertEqual(milestone.old, "v1")
        XCTAssertEqual(milestone.new, "None")
        XCTAssertTrue(old.changes(to: old).isEmpty)
    }

    func testRecordSnapshotsTicketAndPersists() {
        let (store, url) = makeStore()
        let ticket = Ticket(title: "Fix login", github: GitHubRef(repo: "me/a", number: 7, url: "u"))

        let id = store.record(.ticketEdit, ticket: ticket, field: "Status", old: "Todo", new: "Done", sync: .pending)

        let entry = store.actionLog.first { $0.id == id }!
        XCTAssertEqual(entry.ticketKey, "me/a#7")
        XCTAssertEqual(entry.ticketTitle, "Fix login")
        store.setActionSync(id, .synced(Date()), detail: "PATCH ok")

        let reloaded = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertEqual(reloaded.actionLog.count, 1)
        XCTAssertEqual(reloaded.actionLog[0].githubDetail, "PATCH ok")
        if case .synced = reloaded.actionLog[0].sync {} else { XCTFail("expected synced") }
    }

    func testFileWithoutActionLogLoads() throws {
        let json = #"{"tickets":[],"entries":[]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertTrue(store.actionLog.isEmpty)
    }

    func testFailedActionsAndPruning() {
        let (store, _) = makeStore()
        let old = Date().addingTimeInterval(-61 * 86_400)
        store.record(.note, field: "Note", new: "old", at: old)
        let failed = store.record(.ticketEdit, field: "Labels", sync: .pending)
        store.record(.ticketEdit, field: "Status", sync: .notApplicable)
        store.setActionSync(failed, .failed("403"))

        XCTAssertEqual(store.failedActions.map(\.id), [failed])
        let removed = store.deleteActionLog(olderThan: Date().addingTimeInterval(-60 * 86_400))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.actionLog.count, 2)
    }
}
