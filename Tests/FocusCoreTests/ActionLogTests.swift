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

    func testUpdateLogsEachChangedField() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")

        store.update(t.id) { $0.labels = ["bug"]; $0.status = .done }

        let edits = store.actionLog.filter { $0.kind == .ticketEdit && $0.ticketID == t.id }
        XCTAssertEqual(Set(edits.compactMap(\.field)), ["Labels", "Status"])
        let status = edits.first { $0.field == "Status" }!
        XCTAssertEqual(status.oldValue, "Todo")
        XCTAssertEqual(status.newValue, "Done")
    }

    func testNoOpUpdateLogsNothing() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")
        let before = store.actionLog.count
        store.update(t.id) { $0.title = "A" }
        XCTAssertEqual(store.actionLog.count, before)
    }

    func testCreateAndDeleteAreLoggedAndEntriesSurviveDelete() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "Gone soon")
        store.deleteTicket(t.id)

        let kinds = store.actionLog.filter { $0.ticketID == t.id }.map(\.kind)
        XCTAssertEqual(kinds, [.ticketCreate, .ticketDelete])
        XCTAssertEqual(store.actionLog.last?.ticketTitle, "Gone soon")
    }

    func testTimerAndTimeEntryActionsAreLogged() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")

        store.start(t.id)
        store.stop()
        store.addManualEntry(ticketID: t.id, duration: 1800)
        let entryID = store.entries.last!.id
        store.deleteEntry(entryID)

        let fields = store.actionLog.filter { $0.ticketID == t.id && ($0.kind == .timer || $0.kind == .timeEntry) }.compactMap(\.field)
        XCTAssertEqual(fields, ["Timer started", "Timer stopped", "Manual entry added", "Entry deleted"])
        XCTAssertEqual(store.actionLog.first { $0.field == "Manual entry added" }?.newValue, "30 min")
    }

    func testNotesPlanCommentsAndDayPlanAreLogged() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")

        store.addNote(ticketID: t.id, text: "remember")
        store.deleteNote(store.notes[0].id)
        store.addPlanComment(ticketID: t.id, text: "do x")
        store.deletePlanComment(store.planComments[0].id)
        store.togglePlanned(t.id, on: Date())
        store.togglePlanned(t.id, on: Date())

        let fields = store.actionLog.filter { [.note, .planComment, .dayPlan].contains($0.kind) }.compactMap(\.field)
        XCTAssertEqual(fields, ["Note added", "Note deleted", "Plan comment added", "Plan comment deleted", "Added to day plan", "Removed from day plan"])
        XCTAssertEqual(store.actionLog.first { $0.field == "Note added" }?.newValue, "remember")
    }

    func testActivityActionsAreLogged() {
        let (store, _) = makeStore()
        store.startActivity(kind: .call, title: "Standup")
        store.stopActivity()
        store.deleteActivity(store.activities[0].id)

        let fields = store.actionLog.filter { $0.kind == .activity }.compactMap(\.field)
        XCTAssertEqual(fields, ["Activity started", "Activity stopped", "Activity deleted"])
    }

    private func makeStore(status: Int, body: String = "{}") -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(
            storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!,
            transport: ScriptedTransport { _ in (status, body) }, tokenProvider: { "t" }
        )
    }

    func testPostPlanSuccessMarksEntrySynced() async {
        let store = makeStore(status: 201)
        store.insertTicketForTest(Ticket(title: "A", github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        let id = store.tickets[0].id
        store.addPlanComment(ticketID: id, text: "plan")

        let ok = await store.postPlan(id)

        XCTAssertTrue(ok)
        let entry = store.actionLog.last { $0.field == "Plan posted to GitHub" }!
        if case .synced = entry.sync {} else { XCTFail("expected synced, got \(entry.sync)") }
    }

    func testPostPlanFailureMarksEntryFailed() async {
        let store = makeStore(status: 403)
        store.insertTicketForTest(Ticket(title: "A", github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        let id = store.tickets[0].id
        store.addPlanComment(ticketID: id, text: "plan")

        let ok = await store.postPlan(id)

        XCTAssertFalse(ok)
        XCTAssertEqual(store.failedActions.count, 1)
        XCTAssertEqual(store.failedActions[0].field, "Plan posted to GitHub")
    }

    func testProjectFieldPushIsCoalescedAndLogged() {
        let store = makeStore(status: 500)
        let field = CustomField(name: "RCA", value: "old", kind: .text, project: "P")
        store.insertTicketForTest(Ticket(title: "A", fields: [field], github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        let id = store.tickets[0].id

        store.setProjectField(id, name: "RCA", project: "P", to: .text("a"), delay: .milliseconds(200))
        store.setProjectField(id, name: "RCA", project: "P", to: .text("ab"), delay: .milliseconds(200))

        let entries = store.actionLog.filter { $0.field == "RCA" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].oldValue, "old")
        XCTAssertEqual(entries[0].newValue, "ab")
        XCTAssertEqual(entries[0].sync, .pending)
    }

    func testProjectFieldOnLocalTicketIsNotApplicable() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "Local")
        store.setProjectField(t.id, name: "RCA", project: "P", to: .text("x"))

        let entry = store.actionLog.last { $0.field == "RCA" }!
        XCTAssertEqual(entry.sync, .notApplicable)
    }
}

private struct ScriptedTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, String)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (code, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!)
    }
}
