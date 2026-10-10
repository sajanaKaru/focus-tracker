import XCTest
@testable import FocusCore

@MainActor
final class TicketEditingTests: XCTestCase {
    private let lookup = """
    {"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"id":"PVT_1","title":"Board","fields":{"nodes":[
      {"id":"F_ST","name":"Status","options":[{"id":"o1","name":"Todo","color":"GRAY"},{"id":"o2","name":"In Progress","color":"YELLOW"},{"id":"o3","name":"Done","color":"GREEN"}]}]}}}]}}}}}
    """
    private let orgFields = #"[{"id":9,"name":"Priority","data_type":"single_select","options":[{"id":1,"name":"P1 - High","color":"red"},{"id":2,"name":"P3 - Low","color":"green"}]},{"id":8,"name":"Target date","data_type":"date","options":null}]"#

    private func makeStore() -> (AppStore, RecordingTransport, UUID) {
        let lookup = self.lookup
        let orgFields = self.orgFields
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if path == "/graphql" { return body.contains("updateProjectV2ItemFieldValue") ? (200, #"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"x"}}}}"#) : (200, lookup) }
            if path == "/orgs/me/issue-fields" { return (200, orgFields) }
            if path == "/repos/me/a/labels" { return (200, #"[{"name":"bug","color":"d73a4a"},{"name":"ui","color":"0075ca"}]"#) }
            if path == "/repos/me/a/milestones" { return (200, #"[{"number":3,"title":"v3","state":"open","due_on":null}]"#) }
            if path.hasSuffix("/issue-field-values") { return (200, "[]") }
            return (200, "{}")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        store.insertTicketForTest(Ticket(
            title: "A", labels: ["bug"], labelColors: ["bug": "d73a4a"], milestone: Milestone(title: "v1"),
            fields: [CustomField(name: "Status", value: "Todo", kind: .select, project: "Board")],
            github: GitHubRef(repo: "me/a", number: 1, url: "u")
        ))
        return (store, transport, store.tickets[0].id)
    }

    func testSetLabelsLogsListsAndPushes() async {
        let (store, transport, id) = makeStore()
        store.setLabels(id, ["bug", "ui"])
        await store.settlePushes()

        let entry = store.actionLog.last { $0.field == "Labels" }!
        XCTAssertEqual(entry.oldList, ["bug"])
        XCTAssertEqual(entry.newList, ["bug", "ui"])
        XCTAssertEqual(transport.requests.last?.url?.path, "/repos/me/a/issues/1/labels")
        XCTAssertEqual(store.tickets[0].labels, ["bug", "ui"])
    }

    func testSetMilestoneAndClear() async {
        let (store, transport, id) = makeStore()
        store.setMilestone(id, MilestoneOption(number: 3, title: "v3"))
        await store.settlePushes()
        XCTAssertEqual(store.tickets[0].milestone?.title, "v3")
        XCTAssertEqual(transport.json(transport.requests.count - 1)?["milestone"] as? Int, 3)

        store.setMilestone(id, nil)
        await store.settlePushes()
        XCTAssertNil(store.tickets[0].milestone)
        XCTAssertTrue(transport.json(transport.requests.count - 1)?["milestone"] is NSNull)
        XCTAssertEqual(store.actionLog.last { $0.field == "Milestone" }?.newValue, "None")
    }

    func testSetPriorityOptionUpdatesOrgFieldAndEnum() async {
        let (store, transport, id) = makeStore()
        store.setPriorityOption(id, option: "P1 - High")
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].priority, .high)
        XCTAssertEqual(store.tickets[0].field(named: "Priority")?.value, "P1 - High")
        let put = transport.requests.last { $0.httpMethod == "PUT" }
        XCTAssertEqual(put?.url?.path, "/repos/me/a/issues/1/issue-field-values")
        if case .synced = store.actionLog.last!.sync {} else { XCTFail("expected synced") }
    }

    func testSetTargetDateWritesOrgFieldAndDueDate() async {
        let (store, transport, id) = makeStore()
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1))!

        store.setTargetDate(id, date)
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].dueDate, date)
        XCTAssertEqual(store.tickets[0].field(named: "Target date")?.value, "2026-12-01")
        let put = transport.requests.last { $0.httpMethod == "PUT" }!
        XCTAssertTrue(String(data: put.httpBody!, encoding: .utf8)!.contains("2026-12-01"))
    }

    func testSetStatusOptionPushesProjectFieldAndClosesIssueOnDone() async {
        let (store, transport, id) = makeStore()

        store.setStatusOption(id, project: "Board", option: "Done")
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].status, .done)
        XCTAssertEqual(store.tickets[0].projectStatusField?.value, "Done")
        let closed = transport.requests.contains { $0.httpMethod == "PATCH" && $0.url?.path == "/repos/me/a/issues/1" }
        XCTAssertTrue(closed)
        XCTAssertTrue(Set(store.actionLog.compactMap(\.field)).isSuperset(of: ["Status", "Issue state"]))

        store.setStatusOption(id, project: "Board", option: "In Progress")
        await store.settlePushes()
        XCTAssertEqual(store.tickets[0].status, .inProgress)
        XCTAssertEqual(store.actionLog.last { $0.field == "Issue state" }?.newValue, "Open")
    }

    func testPullRequestsAreNeverClosedByStatus() async {
        let (store, transport, _) = makeStore()
        store.insertTicketForTest(Ticket(title: "PR", github: GitHubRef(repo: "me/a", number: 2, url: "u", isPullRequest: true)))
        let pr = store.tickets[1].id

        store.setStatus(pr, .done)
        await store.settlePushes()

        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PATCH" })
    }

    func testTitleAndBodyEdits() async {
        let (store, transport, id) = makeStore()
        store.setTitle(id, "  New title ")
        store.setBody(id, "Body")
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].title, "New title")
        XCTAssertEqual(store.tickets[0].body, "Body")
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "PATCH" }.count, 2)
        store.setTitle(id, "   ")
        XCTAssertEqual(store.tickets[0].title, "New title")
    }

    func testLoadOptionsCachesAndPersists() async {
        let (store, _, id) = makeStore()
        await store.loadOptions(force: true)

        let t = store.ticket(id)!
        XCTAssertEqual(store.labelOptions(for: t).map(\.name), ["bug", "ui"])
        XCTAssertEqual(store.milestoneOptions(for: t).map(\.title), ["v3"])
        XCTAssertEqual(store.priorityOptions(for: t).map(\.name), ["P1 - High", "P3 - Low"])
        XCTAssertEqual(store.statusOptions(for: t).map(\.name), ["Todo", "In Progress", "Done"])
    }

    func testLoadOptionsIsThrottledAndTolerantOfFailures() async {
        let (store, transport, _) = makeStore()
        await store.loadOptions(force: true)
        let count = transport.requests.count
        await store.loadOptions()
        XCTAssertEqual(transport.requests.count, count)

        let failing = RecordingTransport { _ in (500, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let other = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: failing, tokenProvider: { "t" })
        other.insertTicketForTest(Ticket(title: "A", github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        await other.loadOptions(force: true)
        XCTAssertEqual(other.remoteOptions, RemoteOptions())
    }

    func testSetPriorityMapsToOrgOptionWhenCached() async {
        let (store, _, id) = makeStore()
        await store.loadOptions(force: true)

        store.setPriority(id, .low)
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].field(named: "Priority")?.value, "P3 - Low")
        XCTAssertEqual(store.tickets[0].priority, .low)
    }

    func testSetStatusUsesCachedOptionAndLocalTicketsStayLocal() async {
        let (store, transport, id) = makeStore()
        await store.loadOptions(force: true)
        let before = transport.requests.count

        store.setStatus(id, .inProgress)
        await store.settlePushes()
        XCTAssertEqual(store.tickets[0].projectStatusField?.value, "In Progress")
        XCTAssertGreaterThan(transport.requests.count, before)

        let local = store.addTicket(title: "Local")
        let count = transport.requests.count
        store.setStatus(local.id, .done)
        await store.settlePushes()
        XCTAssertEqual(store.ticket(local.id)?.status, .done)
        XCTAssertEqual(transport.requests.count, count)
    }
}
