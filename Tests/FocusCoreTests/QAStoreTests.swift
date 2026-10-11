import XCTest
@testable import FocusCore

@MainActor
final class QAStoreTests: XCTestCase {
    private let repo = "me/a"

    private func makeStore(
        storeURL: URL? = nil,
        _ handler: @escaping @Sendable (URLRequest) -> (Int, String) = { _ in (200, "{}") }
    ) -> (AppStore, RecordingTransport, URL) {
        let transport = RecordingTransport(handler)
        let url = storeURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        return (store, transport, url)
    }

    @discardableResult
    private func addTicket(
        _ store: AppStore, number: Int = 1, status: String? = "Deployed to Beta", labels: [String] = ["bug"],
        milestone: String? = nil, ticketStatus: TicketStatus = .testing
    ) -> UUID {
        let fields = status.map { [CustomField(name: "Status", value: $0, kind: .select, project: "Board")] }
        let ticket = Ticket(
            title: "Ticket \(number)", status: ticketStatus, labels: labels, milestone: milestone.map { Milestone(title: $0) }, fields: fields,
            github: GitHubRef(repo: repo, number: number, url: "https://github.com/me/a/issues/\(number)")
        )
        store.insertTicketForTest(ticket)
        return ticket.id
    }

    private func requests(_ transport: RecordingTransport, method: String, suffix: String) -> [URLRequest] {
        transport.requests.filter { $0.httpMethod == method && ($0.url?.path ?? "").hasSuffix(suffix) }
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    // MARK: Cases and results

    func testCasesResultsAndSummaryPerEnvironment() {
        let (store, _, _) = makeStore()
        let id = addTicket(store)
        let a = store.addTestCase(ticketID: id, title: "  Login works ", steps: "1. Open", expected: "Signed in")!
        let b = store.addTestCase(ticketID: id, title: "Logout works")!
        XCTAssertEqual(a.title, "Login works")
        XCTAssertNil(store.addTestCase(ticketID: id, title: "   "))
        XCTAssertNil(store.addTestCase(ticketID: UUID(), title: "Orphan"))

        store.setResult(caseID: a.id, environment: .beta, status: .fail, at: Date(timeIntervalSince1970: 10))
        store.setResult(caseID: a.id, environment: .beta, status: .pass, at: Date(timeIntervalSince1970: 20))
        store.setResult(caseID: b.id, environment: .alpha2, status: .blocked, note: "no env")

        XCTAssertEqual(store.qaSummary(ticketID: id, environment: .beta), QASummary(pass: 1, fail: 0, blocked: 0, skipped: 0, notRun: 1))
        XCTAssertEqual(store.qaSummary(ticketID: id, environment: .alpha2).blocked, 1)
        XCTAssertEqual(store.latestResult(caseID: a.id, environment: .beta)?.status, .pass)
        XCTAssertEqual(store.qaState(ticketID: id, environment: .beta), .testing)
        XCTAssertEqual(store.qaState(ticketID: id, environment: .alpha), .ready)
        XCTAssertTrue(store.actionLog.contains { $0.kind == .testCase && $0.field == "Result (Beta): Login works" && $0.oldValue == "Fail" && $0.newValue == "Pass" })
    }

    func testDeletingCaseRemovesItsResultsAndDeletingTicketRemovesQAData() {
        let (store, _, _) = makeStore()
        let id = addTicket(store)
        let a = store.addTestCase(ticketID: id, title: "A")!
        store.setResult(caseID: a.id, environment: .beta, status: .pass)
        store.deleteTestCase(a.id)
        XCTAssertTrue(store.testCases.isEmpty)
        XCTAssertTrue(store.testResults.isEmpty)

        let b = store.addTestCase(ticketID: id, title: "B")!
        store.setResult(caseID: b.id, environment: nil, status: .pass)
        store.postVerdict(ticketID: id, environment: nil, outcome: .pass)
        store.deleteTicket(id)
        XCTAssertTrue(store.testCases.isEmpty && store.testResults.isEmpty && store.testVerdicts.isEmpty)
    }

    func testQADataPersistsAndLegacyFilesLoad() throws {
        let (store, _, url) = makeStore()
        let id = addTicket(store)
        let a = store.addTestCase(ticketID: id, title: "A")!
        store.setResult(caseID: a.id, environment: .beta, status: .pass, note: "ok")
        store.postVerdict(ticketID: id, environment: .beta, outcome: .pass)
        await_settle(store)

        let (reloaded, _, _) = makeStore(storeURL: url)
        XCTAssertEqual(reloaded.testCases.count, 1)
        XCTAssertEqual(reloaded.testResults.first?.note, "ok")
        XCTAssertEqual(reloaded.testVerdicts.count, 1)
        XCTAssertEqual(reloaded.qaState(ticketID: id, environment: .beta), .verified)

        let legacy = #"{"tickets":[],"entries":[]}"#
        let legacyURL = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
        let (old, _, _) = makeStore(storeURL: legacyURL)
        XCTAssertTrue(old.testCases.isEmpty && old.bugReports.isEmpty && old.testVerdicts.isEmpty)
        XCTAssertNil(old.notice)
    }

    private func await_settle(_ store: AppStore) {
        let done = expectation(description: "settled")
        Task { await store.settlePushes(); done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: Queue and archive

    func testQueueGroupsByStateAndEnvironment() {
        let (store, _, _) = makeStore()
        let noCases = addTicket(store, number: 1)
        let testing = addTicket(store, number: 2)
        let failed = addTicket(store, number: 3)
        let verified = addTicket(store, number: 4)
        let otherEnv = addTicket(store, number: 5, status: "Deployed to Alpha")
        addTicket(store, number: 6, status: "Deployed to Live", ticketStatus: .done)
        let qaTesting = addTicket(store, number: 7, status: "QA Testing")

        let caseT = store.addTestCase(ticketID: testing, title: "t")!
        store.setResult(caseID: caseT.id, environment: .beta, status: .pass)
        for id in [failed, verified, otherEnv, qaTesting] { store.addTestCase(ticketID: id, title: "c") }
        let caseF = store.testCases(for: failed)[0]
        store.setResult(caseID: caseF.id, environment: .beta, status: .fail, at: Date(timeIntervalSince1970: 1))
        store.postVerdict(ticketID: failed, environment: .beta, outcome: .fail, returnToInProgress: false, at: Date(timeIntervalSince1970: 2))
        let caseV = store.testCases(for: verified)[0]
        store.setResult(caseID: caseV.id, environment: .beta, status: .pass, at: Date(timeIntervalSince1970: 1))
        store.postVerdict(ticketID: verified, environment: .beta, outcome: .pass, at: Date(timeIntervalSince1970: 2))

        let beta = store.qaQueue(environment: .beta)
        XCTAssertEqual(Set(beta.ready.map(\.id)), [noCases])
        XCTAssertEqual(beta.testing.map(\.id), [testing])
        XCTAssertEqual(beta.failed.map(\.id), [failed])
        XCTAssertEqual(beta.verified.map(\.id), [verified])

        XCTAssertEqual(store.qaQueue(environment: .alpha).ready.map(\.id), [otherEnv])
        XCTAssertTrue(store.qaQueue(environment: .alpha2).isEmpty)
        XCTAssertTrue(store.qaQueue(environment: .live).isEmpty)

        let all = store.qaQueue(environment: nil)
        XCTAssertEqual(Set(all.ready.map(\.id)), [noCases, otherEnv, qaTesting])
        XCTAssertEqual(store.readyToTestCount, 3)
        await_settle(store)
    }

    func testLiveArchiveGroupsByMilestone() {
        let (store, _, _) = makeStore()
        let b1 = addTicket(store, number: 1, status: "Deployed to Live", milestone: "v2", ticketStatus: .done)
        let a1 = addTicket(store, number: 2, status: "Deployed to Live", milestone: "v1", ticketStatus: .done)
        let a2 = addTicket(store, number: 3, status: "Deployed to Live", milestone: "v1", ticketStatus: .done)
        let none = addTicket(store, number: 4, status: "Deployed to Live", ticketStatus: .done)
        addTicket(store, number: 5, status: "Deployed to Beta", milestone: "v1")

        let archive = store.liveArchive()
        XCTAssertEqual(archive.map(\.milestone), ["v1", "v2", nil])
        XCTAssertEqual(Set(archive[0].tickets.map(\.id)), [a1, a2])
        XCTAssertEqual(archive[1].tickets.map(\.id), [b1])
        XCTAssertEqual(archive[2].tickets.map(\.id), [none])
    }

    // MARK: Verdict

    func testPassVerdictPostsCommentAndReplacesOnlyThisEnvironmentsLabel() async {
        let (store, transport, _) = makeStore()
        let id = addTicket(store, labels: ["bug", "qa:beta-failed", "qa:alpha-failed"])
        let c = store.addTestCase(ticketID: id, title: "Login")!
        store.setResult(caseID: c.id, environment: .beta, status: .pass)

        let verdict = store.postVerdict(ticketID: id, environment: .beta, outcome: .pass, build: "1.4.2")
        await store.settlePushes()

        XCTAssertEqual(verdict?.summary, "1/1 passed")
        let comments = requests(transport, method: "POST", suffix: "/issues/1/comments")
        XCTAssertEqual(comments.count, 1)
        let text = body(comments[0])["body"] as? String ?? ""
        XCTAssertTrue(text.contains("**QA result (Beta): PASSED**"), text)
        XCTAssertTrue(text.contains("build 1.4.2"))
        XCTAssertTrue(text.contains("| Login | Pass |  |"))

        let labels = requests(transport, method: "PUT", suffix: "/issues/1/labels")
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(body(labels[0])["labels"] as? [String], ["bug", "qa:alpha-failed", "qa:beta-passed"])
        XCTAssertEqual(store.ticket(id)?.labels, ["bug", "qa:alpha-failed", "qa:beta-passed"])
        XCTAssertEqual(store.ticket(id)?.status, .testing, "a pass leaves the status alone")
        XCTAssertTrue(store.failedActions.isEmpty)
        XCTAssertEqual(store.actionLog.filter { if case .synced = $0.sync { true } else { false } }.count, 2)
        XCTAssertEqual(store.qaState(ticketID: id, environment: .beta), .verified)
    }

    func testFailVerdictMovesBackToInProgressOnlyWhenAsked() async {
        let (store, _, _) = makeStore()
        let id = addTicket(store, status: nil)
        let other = addTicket(store, number: 2, status: nil)

        store.postVerdict(ticketID: id, environment: nil, outcome: .fail)
        store.postVerdict(ticketID: other, environment: nil, outcome: .fail, returnToInProgress: false)
        await store.settlePushes()

        XCTAssertEqual(store.ticket(id)?.status, .inProgress)
        XCTAssertEqual(store.ticket(other)?.status, .testing)
        XCTAssertEqual(store.ticket(id)?.labels, ["bug", "qa:failed"])
    }

    func testVerdictOnLocalTicketOnlyRecordsLocally() async {
        let (store, transport, _) = makeStore()
        let local = Ticket(title: "Local", status: .testing)
        store.insertTicketForTest(local)
        XCTAssertNotNil(store.postVerdict(ticketID: local.id, environment: nil, outcome: .pass))
        await store.settlePushes()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(store.testVerdicts.count, 1)
        XCTAssertEqual(store.ticket(local.id)?.labels, [])
    }

    func testFailedCommentIsRetryable() async {
        let failing = Switch(true)
        let (store, transport, _) = makeStore { request in
            if request.httpMethod == "POST", failing.isOn { return (403, #"{"message":"Resource not accessible"}"#) }
            return (200, "{}")
        }
        let id = addTicket(store)
        store.postVerdict(ticketID: id, environment: .beta, outcome: .pass)
        await store.settlePushes()

        XCTAssertEqual(store.failedActions.count, 1)
        XCTAssertEqual(store.testVerdicts.count, 1, "the verdict itself stays recorded")

        failing.isOn = false
        let ok = await store.retry(store.failedActions[0].id)
        XCTAssertTrue(ok)
        XCTAssertTrue(store.failedActions.isEmpty)
        XCTAssertEqual(requests(transport, method: "POST", suffix: "/comments").count, 2)
    }

    // MARK: Bugs

    private let createdJSON = #"{"number":42,"html_url":"https://github.com/me/a/issues/42"}"#

    func testReportBugCreatesLinkedIssue() async {
        let created = createdJSON
        let (store, transport, _) = makeStore { _ in (201, created) }
        let id = addTicket(store)

        let bug = await store.reportBug(
            ticketID: id, environment: .beta, title: " Crash on save ", severity: .high, build: "1.4.2",
            steps: "1. Save", expected: "Saves", actual: "Crashes", links: "https://x/y.png"
        )

        XCTAssertEqual(bug?.state, .created)
        XCTAssertEqual(bug?.issueNumber, 42)
        XCTAssertEqual(bug?.issueURL, "https://github.com/me/a/issues/42")
        let posts = requests(transport, method: "POST", suffix: "/me/a/issues")
        XCTAssertEqual(posts.count, 1)
        let payload = body(posts[0])
        XCTAssertEqual(payload["title"] as? String, "Crash on save")
        XCTAssertNil(payload["labels"], "no bug label is sent unless the repo has one")
        let text = payload["body"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("Found while testing me/a#1 (Beta, build 1.4.2)"), text)
        XCTAssertTrue(text.contains("**Severity:** High"))
        XCTAssertTrue(text.contains("### Links\nhttps://x/y.png"))
        XCTAssertEqual(store.actionLog.last?.kind, .bugReport)
        if case .synced = store.actionLog.last!.sync {} else { XCTFail("expected synced") }
        XCTAssertTrue(store.tickets.allSatisfy { $0.id == id }, "a bug is not added as a ticket")
    }

    func testBugGetsBugLabelWhenRepoHasOne() async {
        let created = createdJSON
        let (store, transport, _) = makeStore { _ in (201, created) }
        var options = RemoteOptions()
        options.labels[repo] = [LabelOption(name: "Bug", color: "d73a4a")]
        store.storeOptions(options)
        let id = addTicket(store)

        await store.reportBug(ticketID: id, environment: nil, title: "B", severity: .low)
        XCTAssertEqual(body(requests(transport, method: "POST", suffix: "/me/a/issues")[0])["labels"] as? [String], ["bug"])
    }

    func testFailedBugKeepsDraftAndRetries() async {
        let failing = Switch(true)
        let created = createdJSON
        let (store, _, _) = makeStore { _ in failing.isOn ? (422, #"{"message":"Validation Failed"}"#) : (201, created) }
        let id = addTicket(store)

        let bug = await store.reportBug(ticketID: id, environment: .beta, title: "Crash", severity: .medium)
        guard case .failed? = bug?.state else { return XCTFail("expected a failed bug, got \(String(describing: bug?.state))") }
        XCTAssertNil(bug?.issueNumber)
        XCTAssertEqual(store.failedActions.count, 1)

        failing.isOn = false
        let ok = await store.retry(store.failedActions[0].id)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.bugs(for: id)[0].state, .created)
        XCTAssertEqual(store.bugs(for: id)[0].issueNumber, 42)
        XCTAssertTrue(store.failedActions.isEmpty)
        XCTAssertEqual(store.bugReports.count, 1, "retry reuses the same report")
    }

    func testBugOnLocalTicketIsRefused() async {
        let (store, transport, _) = makeStore()
        let local = Ticket(title: "Local")
        store.insertTicketForTest(local)
        let bug = await store.reportBug(ticketID: local.id, environment: nil, title: "B", severity: .low)
        XCTAssertNil(bug)
        XCTAssertNotNil(store.notice)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(store.bugReports.isEmpty)
    }

    func testVerdictCommentListsCreatedBugsForThatEnvironment() async {
        let created = createdJSON
        let (store, transport, _) = makeStore { request in
            request.url?.path.hasSuffix("/me/a/issues") == true ? (201, created) : (200, "{}")
        }
        let id = addTicket(store)
        await store.reportBug(ticketID: id, environment: .beta, title: "Crash", severity: .high)
        await store.reportBug(ticketID: id, environment: .alpha, title: "Other env", severity: .low)

        store.postVerdict(ticketID: id, environment: .beta, outcome: .fail)
        await store.settlePushes()

        let text = body(requests(transport, method: "POST", suffix: "/issues/1/comments")[0])["body"] as? String ?? ""
        XCTAssertEqual(text.components(separatedBy: "#42").count - 1, 1, "only the Beta bug is listed")
        XCTAssertTrue(text.contains("Bugs: #42"))
    }
}
