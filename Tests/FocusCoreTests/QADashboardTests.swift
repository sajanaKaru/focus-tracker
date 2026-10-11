import XCTest
@testable import FocusCore

@MainActor
final class QADashboardTests: XCTestCase {
    private func makeStore() -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: RecordingTransport { _ in (200, "{}") }, tokenProvider: { "t" })
    }

    @discardableResult
    private func add(
        _ store: AppStore, _ number: Int, deployed: String?, status: TicketStatus = .testing, deployment: DeploymentMark? = nil
    ) -> Ticket {
        let fields = deployed.map { [CustomField(name: "Status", value: $0, kind: .select, project: "Board")] }
        let ticket = Ticket(
            title: "T\(number)", status: status, fields: fields,
            github: GitHubRef(repo: "me/a", number: number, url: "https://github.com/me/a/issues/\(number)"), deployment: deployment
        )
        store.insertTicketForTest(ticket)
        return ticket
    }

    func testPipelineCountsPerEnvironmentAndLive() {
        let store = makeStore()
        let ready = add(store, 1, deployed: "Deployed to Beta")
        store.addTestCase(ticketID: ready.id, title: "a")

        let testing = add(store, 2, deployed: "Deployed to Beta")
        let tc = store.addTestCase(ticketID: testing.id, title: "a")!
        store.setResult(caseID: tc.id, environment: .beta, status: .pass)

        let failed = add(store, 3, deployed: "Deployed to Alpha")
        let fc = store.addTestCase(ticketID: failed.id, title: "a")!
        store.setResult(caseID: fc.id, environment: .alpha, status: .fail, at: Date(timeIntervalSinceNow: -100))
        store.postVerdict(ticketID: failed.id, environment: .alpha, outcome: .fail, returnToInProgress: false)

        add(store, 4, deployed: "Deployed to Live", status: .done)

        let pipeline = store.qaPipeline()
        XCTAssertEqual(pipeline.rows.map(\.environment), [.alpha, .alpha2, .beta])
        XCTAssertEqual(pipeline.rows[0].failed, 1)
        XCTAssertEqual(pipeline.rows[2].ready, 1)
        XCTAssertEqual(pipeline.rows[2].testing, 1)
        XCTAssertEqual(pipeline.liveCount, 1)
    }

    func testProgressCountsResultsAndVerdictsInTheRange() {
        let store = makeStore()
        let t = add(store, 1, deployed: "Deployed to Beta")
        let c1 = store.addTestCase(ticketID: t.id, title: "a")!
        let c2 = store.addTestCase(ticketID: t.id, title: "b")!
        let now = Date()
        store.testResults.append(TestResult(caseID: c1.id, ticketID: t.id, environment: .beta, status: .pass, testedAt: now))
        store.testResults.append(TestResult(caseID: c2.id, ticketID: t.id, environment: .beta, status: .fail, testedAt: now))
        store.testResults.append(TestResult(caseID: c1.id, ticketID: t.id, environment: .beta, status: .pass, testedAt: now.addingTimeInterval(-2 * 86_400)))
        store.testVerdicts.append(TestVerdict(ticketID: t.id, environment: .beta, outcome: .pass, summary: "", tester: "me", testedAt: now))
        store.testVerdicts.append(TestVerdict(ticketID: t.id, environment: .beta, outcome: .fail, summary: "", tester: "me", testedAt: now))

        let range = DateInterval(start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(3_600))
        XCTAssertEqual(store.qaProgress(in: range), QAProgress(passed: 1, failed: 1, verified: 1))
    }

    func testRetestListFlagsTicketsRedeployedSinceTheFailure() {
        let store = makeStore()
        let failedAt = Date(timeIntervalSinceNow: -3_600)
        let redeployed = DeploymentMark(environment: .beta, statusName: "Deployed to Beta", movedAt: Date(timeIntervalSinceNow: -60))
        let notYet = DeploymentMark(environment: .beta, statusName: "Deployed to Beta", movedAt: Date(timeIntervalSinceNow: -7_200))
        let a = add(store, 1, deployed: nil, status: .inProgress, deployment: redeployed)
        let b = add(store, 2, deployed: nil, status: .inProgress, deployment: notYet)
        let done = add(store, 3, deployed: nil, status: .done, deployment: notYet)
        for ticket in [a, b, done] {
            let c = store.addTestCase(ticketID: ticket.id, title: "case")!
            store.testResults.append(TestResult(caseID: c.id, ticketID: ticket.id, environment: .beta, status: .fail, testedAt: failedAt))
            store.testVerdicts.append(TestVerdict(ticketID: ticket.id, environment: .beta, outcome: .fail, summary: "", tester: "me", testedAt: failedAt))
        }

        let list = store.qaRetestList()
        XCTAssertEqual(list.map(\.ticket.id), [a.id, b.id])
        XCTAssertEqual(list.map(\.redeployed), [true, false])
        XCTAssertEqual(list[0].failedCases, 1)
        XCTAssertEqual(list[0].failedAt, failedAt)
    }

    func testRecentBugsAreNewestFirstAndLimited() {
        let store = makeStore()
        let t = add(store, 1, deployed: "Deployed to Beta")
        for i in 0..<12 {
            store.bugReports.append(BugReport(ticketID: t.id, environment: .beta, title: "Bug \(i)", createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        let bugs = store.qaRecentBugs(limit: 10)
        XCTAssertEqual(bugs.count, 10)
        XCTAssertEqual(bugs.first?.title, "Bug 11")
        XCTAssertEqual(bugs.last?.title, "Bug 2")
    }
}
