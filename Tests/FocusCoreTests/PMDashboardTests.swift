import XCTest
@testable import FocusCore

@MainActor
final class PMDashboardTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func makeStore() -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: RecordingTransport { _ in (200, "{}") }, tokenProvider: { "t" })
    }

    @discardableResult
    private func add(
        _ store: AppStore, _ number: Int, status: TicketStatus = .todo, fields: [CustomField]? = nil, milestone: Milestone? = nil,
        dueDate: Date? = nil, estimateMinutes: Int? = nil, assignees: [String]? = nil, remoteUpdatedAt: Date? = nil, local: Bool = false,
        isQuickCapture: Bool? = nil, createdAt: Date = Date(), deployment: DeploymentMark? = nil, title: String? = nil
    ) -> Ticket {
        let ticket = Ticket(
            title: title ?? "T\(number)", status: status, milestone: milestone, fields: fields, dueDate: dueDate,
            estimateMinutes: estimateMinutes, createdAt: createdAt,
            github: local ? nil : GitHubRef(repo: "me/a", number: number, url: "https://github.com/me/a/issues/\(number)"),
            isQuickCapture: isQuickCapture, deployment: deployment, assignees: assignees, remoteUpdatedAt: remoteUpdatedAt
        )
        store.insertTicketForTest(ticket)
        return ticket
    }

    /// Anchored to `store.now`, the same reference the production code uses, so `daysLeft` is stable across midnight.
    private func sprint(_ store: AppStore, _ name: String, endsInDays days: Int = 5) -> [CustomField] {
        let end = Calendar.current.date(byAdding: .day, value: days, to: store.now)!
        return [CustomField(name: "Sprint", value: name, kind: .iteration, project: "Board", start: store.now.addingTimeInterval(-5 * day), end: end)]
    }

    private func beta() -> [CustomField] {
        [CustomField(name: "Status", value: "Deployed to Beta", kind: .select, project: "Board")]
    }

    // MARK: Sprint progress

    func testSprintProgressCountsTheCurrentSprintIncludingDone() {
        let store = makeStore()
        add(store, 1, status: .done, fields: sprint(store, "Sprint 12"))
        add(store, 2, status: .inProgress, fields: sprint(store, "Sprint 12"))
        add(store, 3, status: .todo, fields: sprint(store, "Sprint 12"))
        add(store, 4, status: .todo)
        let progress = store.pmSprintProgress()
        XCTAssertEqual(progress?.name, "Sprint 12")
        XCTAssertEqual(progress?.total, 3)
        XCTAssertEqual(progress?.done, 1)
        XCTAssertEqual(progress?.byStatus[.inProgress], 1)
        XCTAssertEqual(progress?.daysLeft, 5)
        XCTAssertEqual(progress?.fraction ?? 0, 1.0 / 3.0, accuracy: 0.001)
    }

    func testSprintProgressFallsBackToTheEarliestDueOpenMilestone() {
        let store = makeStore()
        add(store, 1, status: .done, milestone: Milestone(title: "M2", dueOn: Date().addingTimeInterval(10 * day)))
        add(store, 2, milestone: Milestone(title: "M1", dueOn: Date().addingTimeInterval(3 * day)))
        add(store, 3, milestone: Milestone(title: "M1", dueOn: Date().addingTimeInterval(3 * day)))
        add(store, 4, milestone: Milestone(title: "Old", isOpen: false))
        let progress = store.pmSprintProgress()
        XCTAssertEqual(progress?.name, "M1")
        XCTAssertEqual(progress?.total, 2)
    }

    func testSprintProgressIsNilWithNeitherSprintNorMilestone() {
        let store = makeStore()
        add(store, 1)
        XCTAssertNil(store.pmSprintProgress())
    }

    // MARK: Pipeline

    func testPipelineCountsAndReadyToPromote() {
        let store = makeStore()
        let verified = add(store, 1, status: .testing, fields: beta())
        let c = store.addTestCase(ticketID: verified.id, title: "a")!
        store.testResults.append(TestResult(caseID: c.id, ticketID: verified.id, environment: .beta, status: .pass, testedAt: Date(timeIntervalSinceNow: -100)))
        store.testVerdicts.append(TestVerdict(ticketID: verified.id, environment: .beta, outcome: .pass, summary: "", tester: "me"))
        add(store, 2, status: .testing, fields: beta())
        add(store, 3, status: .done, fields: [CustomField(name: "Status", value: "Deployed to Live", kind: .select, project: "Board")])

        let rows = store.pmPipeline()
        XCTAssertEqual(rows.map(\.environment), [.alpha, .alpha2, .beta, .live])
        XCTAssertEqual(rows[2].count, 2)
        XCTAssertEqual(rows[2].readyToPromote, 1)
        XCTAssertEqual(rows[3].count, 1)
        XCTAssertEqual(rows[3].readyToPromote, 0)
        XCTAssertEqual(rows[0].count, 0)
    }

    // MARK: Risks

    func testRisksAreOrderedOverdueFailedQAThenStale() {
        let store = makeStore()
        let stale = add(store, 1, status: .inProgress, remoteUpdatedAt: Date().addingTimeInterval(-4 * day))
        add(store, 2, status: .inProgress, remoteUpdatedAt: Date().addingTimeInterval(-1 * day))
        add(store, 3, status: .inProgress)
        let overdue = add(store, 4, dueDate: Date().addingTimeInterval(-2 * day))
        add(store, 5, status: .done, dueDate: Date().addingTimeInterval(-2 * day))
        let failed = add(store, 6, status: .testing, fields: beta())
        let c = store.addTestCase(ticketID: failed.id, title: "a")!
        store.testResults.append(TestResult(caseID: c.id, ticketID: failed.id, environment: .beta, status: .fail, testedAt: Date(timeIntervalSinceNow: -100)))
        store.testVerdicts.append(TestVerdict(ticketID: failed.id, environment: .beta, outcome: .fail, summary: "", tester: "me"))

        let risks = store.pmRisks()
        XCTAssertEqual(risks.map(\.ticket.id), [overdue.id, failed.id, stale.id])
        XCTAssertEqual(risks.map(\.reason), [.overdue, .failedQA, .stale])
    }

    func testAnOverdueOpenMilestoneMakesItsTicketsOverdue() {
        let store = makeStore()
        let ticket = add(store, 1, milestone: Milestone(title: "M", dueOn: Date().addingTimeInterval(-2 * day)))
        XCTAssertEqual(store.pmRisks().map(\.ticket.id), [ticket.id])
    }

    // MARK: Workload

    func testWorkloadGroupsOpenGitHubTicketsByAssignee() {
        let store = makeStore()
        add(store, 1, status: .inProgress, estimateMinutes: 60, assignees: ["alice"])
        add(store, 2, estimateMinutes: 30, assignees: ["alice", "bob"])
        add(store, 3, assignees: [])
        add(store, 4, status: .done, assignees: ["alice"])
        add(store, 5, assignees: nil, local: true)

        let rows = store.pmWorkload()
        XCTAssertEqual(rows.map(\.assignee), ["alice", "bob", WorkloadRow.unassigned])
        XCTAssertEqual(rows[0].open, 2)
        XCTAssertEqual(rows[0].inFlight, 1)
        XCTAssertEqual(rows[0].estimateMinutes, 90)
        XCTAssertEqual(rows[1].estimateMinutes, 30)
        XCTAssertTrue(rows[2].isUnassigned)
        XCTAssertEqual(rows[2].open, 1)
    }

    // MARK: Incoming

    func testIncomingListsUnplannedBacklogAndQuickCaptures() {
        let store = makeStore()
        let backlog = add(store, 1, status: .backlog, createdAt: Date(timeIntervalSince1970: 10))
        add(store, 2, status: .backlog, fields: sprint(store, "Sprint 12"))
        let quick = add(store, 3, status: .todo, isQuickCapture: true, createdAt: Date(timeIntervalSince1970: 20))
        add(store, 4, status: .todo)
        add(store, 5, status: .done, isQuickCapture: true)

        XCTAssertEqual(store.pmIncoming().map(\.id), [quick.id, backlog.id])
        XCTAssertEqual(store.pmIncoming(limit: 1).map(\.id), [quick.id])
    }

    // MARK: Summary

    func testSummaryHasProgressInFlightAtRiskAndReadyToPromote() {
        let store = makeStore()
        add(store, 1, status: .done, fields: sprint(store, "Sprint 12"))
        add(store, 2, status: .inProgress, fields: sprint(store, "Sprint 12"), dueDate: Date().addingTimeInterval(-2 * day))

        let sections = store.pmSummarySections()
        XCTAssertEqual(sections.map(\.title), ["Progress", "In flight", "At risk"])
        XCTAssertEqual(sections[0].items[0].text, "Sprint 12: 1/2 done (50%), 5 days left")
        XCTAssertEqual(sections[1].items[0].text, "https://github.com/me/a/issues/2")
        XCTAssertEqual(sections[2].items[0].notes, ["T2", "Overdue"])

        let text = store.pmSummaryText()
        XCTAssertTrue(text.contains("Progress\n- Sprint 12: 1/2 done (50%), 5 days left"))
        XCTAssertTrue(store.pmSummaryHTML().contains("<a href=\"https://github.com/me/a/issues/2\">"))
    }

    func testSummaryEscapesHTMLAndHandlesNothingToReport() {
        let store = makeStore()
        XCTAssertEqual(store.pmSummaryText().hasSuffix("(nothing to report)"), true)

        add(store, 1, status: .inProgress, local: true, title: "A & <b>")
        XCTAssertTrue(store.pmSummaryHTML().contains("A &amp; &lt;b&gt;"))
    }
}
