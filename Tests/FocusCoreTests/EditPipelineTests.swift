import XCTest
@testable import FocusCore

@MainActor
final class EditPipelineTests: XCTestCase {
    private let issueJSON = #"{"number":1,"title":"A","body":null,"state":"open","html_url":"u","repository_url":"https://api.github.com/repos/me/a","node_id":"I_1","labels":[{"name":"bug","color":"d73a4a"}],"milestone":null}"#

    private func makeStore(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) -> (AppStore, RecordingTransport, UUID) {
        let transport = RecordingTransport(handler)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        store.insertTicketForTest(Ticket(title: "A", labels: ["bug"], github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        return (store, transport, store.tickets[0].id)
    }

    private func editLabels(_ store: AppStore, _ id: UUID, to labels: [String]) {
        let old = store.ticket(id)!.labels
        store.edit(id, FieldChange(field: "Labels", old: old.joined(separator: ", "), new: labels.joined(separator: ", "), oldList: old, newList: labels), remote: .labels(labels)) { $0.labels = labels }
    }

    func testSuccessfulPushMarksSynced() async {
        let (store, transport, id) = makeStore { _ in (200, "{}") }

        editLabels(store, id, to: ["bug", "ui"])
        XCTAssertEqual(store.actionLog.last?.sync, .pending)
        await store.settlePushes()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].httpMethod, "PUT")
        if case .synced = store.actionLog.last!.sync {} else { XCTFail("expected synced") }
        XCTAssertNil(store.tickets[0].unsynced?.first)
        XCTAssertEqual(store.actionLog.last?.remote, .labels(["bug", "ui"]))
    }

    func testFailedPushKeepsLocalValueAndSurvivesSync() async {
        let failing = Switch(true)
        let issue = issueJSON
        let (store, _, id) = makeStore { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "PUT" { return failing.isOn ? (422, #"{"message":"Validation Failed"}"#) : (200, "{}") }
            if path == "/graphql" { return (200, #"{"data":{"nodes":[{"id":"I_1","projectItems":{"nodes":[]}}]}}"#) }
            if path.hasSuffix("/issue-field-values") { return (200, "[]") }
            return (200, issue)
        }

        editLabels(store, id, to: ["bug", "ui"])
        await store.settlePushes()

        XCTAssertEqual(store.failedActions.count, 1)
        XCTAssertEqual(store.tickets[0].labels, ["bug", "ui"])
        XCTAssertEqual(store.tickets[0].unsynced, ["Labels"])

        await store.refreshTicket(id, minimumInterval: 0)
        XCTAssertEqual(store.tickets[0].labels, ["bug", "ui"], "sync must not overwrite an unsynced field")

        failing.isOn = false
        let ok = await store.retry(store.failedActions[0].id)
        XCTAssertTrue(ok)
        XCTAssertTrue(store.failedActions.isEmpty)
        XCTAssertTrue((store.tickets[0].unsynced ?? []).isEmpty)

        await store.refreshTicket(id, minimumInterval: 0)
        XCTAssertEqual(store.tickets[0].labels, ["bug"], "once synced, GitHub is the source again")
    }

    func testResyncRetriesEveryFailedEntry() async {
        let failing = Switch(true)
        let (store, _, id) = makeStore { request in
            request.httpMethod == nil || request.httpMethod == "GET" ? (200, "{}") : (failing.isOn ? (500, "{}") : (200, "{}"))
        }
        editLabels(store, id, to: ["x"])
        await store.settlePushes()
        store.edit(id, FieldChange(field: "Title", old: "A", new: "B"), remote: .title("B")) { $0.title = "B" }
        await store.settlePushes()
        XCTAssertEqual(store.failedActions.count, 2)

        failing.isOn = false
        await store.resyncFailed()

        XCTAssertTrue(store.failedActions.isEmpty)
    }

    func testNewEditSupersedesOlderFailedEntry() async {
        let failing = Switch(true)
        let (store, _, id) = makeStore { _ in failing.isOn ? (500, "{}") : (200, "{}") }
        editLabels(store, id, to: ["x"])
        await store.settlePushes()
        XCTAssertEqual(store.failedActions.count, 1)

        failing.isOn = false
        editLabels(store, id, to: ["y"])
        await store.settlePushes()

        XCTAssertTrue(store.failedActions.isEmpty)
        XCTAssertTrue((store.tickets[0].unsynced ?? []).isEmpty)
    }

    func testRepeatedEditsAreCoalescedIntoOneEntry() {
        let (store, _, id) = makeStore { _ in (200, "{}") }
        store.edit(id, FieldChange(field: "Title", old: "A", new: "B"), remote: .title("B"), delay: .milliseconds(300)) { $0.title = "B" }
        store.edit(id, FieldChange(field: "Title", old: "B", new: "BC"), remote: .title("BC"), delay: .milliseconds(300)) { $0.title = "BC" }

        let entries = store.actionLog.filter { $0.field == "Title" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].oldValue, "A")
        XCTAssertEqual(entries[0].newValue, "BC")
        XCTAssertEqual(entries[0].remote, .title("BC"))
    }

    func testLocalTicketEditIsNotPushed() async {
        let transport = RecordingTransport { _ in (200, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        let t = store.addTicket(title: "Local")
        store.edit(t.id, FieldChange(field: "Title", old: "Local", new: "L2"), remote: .title("L2")) { $0.title = "L2" }
        await store.settlePushes()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(store.actionLog.last { $0.field == "Title" }?.sync, .notApplicable)
    }

    func testFailedProjectFieldWriteKeepsLocalValue() async {
        let (store, _, id) = makeStore { _ in (200, #"{"errors":[{"message":"nope"}]}"#) }
        store.update(id) { $0.fields = [CustomField(name: "RCA", value: "old", kind: .text, project: "P")] }

        store.setProjectField(id, name: "RCA", project: "P", to: .text("new"))
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].fields?.first?.value, "new")
        XCTAssertEqual(store.failedActions.first?.field, "RCA")
        XCTAssertEqual(store.tickets[0].unsynced, ["RCA"])
    }

    func testSyncDoesNotOverwriteAnEditStillInFlight() {
        let (store, _, id) = makeStore { _ in (200, "{}") }
        store.edit(id, FieldChange(field: "Title", old: "A", new: "B"), remote: .title("B"), delay: .seconds(5)) { $0.title = "B" }

        let remote = RemoteIssue(repo: "me/a", number: 1, title: "A", url: "u")
        let merged = AppStore.merge(existing: store.tickets, remote: [remote])[0]

        XCTAssertEqual(merged.title, "B")
    }

    func testSyncDerivesPriorityDueDateAndStatusFromFields() {
        let target = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        let issue = RemoteIssue(
            repo: "me/a", number: 1, title: "A", url: "u",
            fields: [CustomField(name: "Status", value: "In Review", kind: .select, project: "Board")],
            issueFields: [
                CustomField(name: "Priority", value: "P1 - High", kind: .select, project: CustomField.issueFieldsGroup),
                CustomField(name: "Target date", value: "2026-12-01", kind: .date, project: CustomField.issueFieldsGroup, start: target)
            ]
        )

        let merged = AppStore.merge(existing: [], remote: [issue])[0]

        XCTAssertEqual(merged.priority, .high)
        XCTAssertEqual(merged.dueDate, target)
        XCTAssertEqual(merged.status, .inReview)

        var kept = merged
        kept.unsynced = ["Priority"]
        kept.priority = .low
        let again = AppStore.merge(existing: [kept], remote: [issue])[0]
        XCTAssertEqual(again.priority, .low)
        XCTAssertEqual(again.status, .inReview)
    }
}
