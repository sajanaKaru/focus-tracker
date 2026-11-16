import XCTest
@testable import FocusCore

@MainActor
final class QAPlanTests: XCTestCase {
    private func makeStore(url: URL? = nil) -> (AppStore, URL) {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        defaults.set(7, forKey: PrefKey.workDays)
        defaults.set(60, forKey: PrefKey.workingMinutes)
        defaults.set(100, forKey: PrefKey.focusPercent)
        let storeURL = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: storeURL, defaults: defaults, transport: RecordingTransport { _ in (200, "{}") }, tokenProvider: { "t" })
        return (store, storeURL)
    }

    @discardableResult
    private func add(_ store: AppStore, _ number: Int, cases: Int) -> Ticket {
        let ticket = Ticket(
            title: "T\(number)", status: .testing,
            fields: [CustomField(name: "Status", value: "Deployed to Beta", kind: .select, project: "Board")],
            github: GitHubRef(repo: "me/a", number: number, url: "https://github.com/me/a/issues/\(number)")
        )
        store.insertTicketForTest(ticket)
        for i in 0..<cases { store.addTestCase(ticketID: ticket.id, title: "case \(i)") }
        return ticket
    }

    func testEstimateRule() {
        XCTAssertEqual(QAPlanner.estimate(totalCases: 0, remainingCases: 0), 30)
        XCTAssertEqual(QAPlanner.estimate(totalCases: 4, remainingCases: 3), 30)
        XCTAssertEqual(QAPlanner.estimate(totalCases: 4, remainingCases: 0), 10)
    }

    func testCandidatesAreOrderedFailedThenTestingThenReadyWithoutDuplicates() {
        let (store, _) = makeStore()
        let ready = add(store, 1, cases: 2)
        let testing = add(store, 2, cases: 2)
        let failed = add(store, 3, cases: 1)
        let noCases = add(store, 4, cases: 0)

        let testingCase = store.testCases(for: testing.id)[0]
        store.setResult(caseID: testingCase.id, environment: .beta, status: .pass)
        let failedCase = store.testCases(for: failed.id)[0]
        store.setResult(caseID: failedCase.id, environment: .beta, status: .fail, at: Date(timeIntervalSinceNow: -100))
        store.postVerdict(ticketID: failed.id, environment: .beta, outcome: .fail, returnToInProgress: false)

        let candidates = store.qaPlanCandidates()
        XCTAssertEqual(candidates.count, 4)
        XCTAssertEqual(candidates.prefix(2).map(\.ticket.id), [failed.id, testing.id])
        let estimates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.ticket.id, $0.estimateMinutes) })
        XCTAssertEqual(estimates[failed.id], 10)
        XCTAssertEqual(estimates[testing.id], 10)
        XCTAssertEqual(estimates[ready.id], 20)
        XCTAssertEqual(estimates[noCases.id], 30)
    }

    func testSkippedCasesDoNotCountAsRemainingWork() {
        let (store, _) = makeStore()
        let ticket = add(store, 1, cases: 4)
        let cases = store.testCases(for: ticket.id)
        for testCase in cases.prefix(2) { store.setResult(caseID: testCase.id, environment: .beta, status: .pass) }
        for testCase in cases.suffix(2) { store.setResult(caseID: testCase.id, environment: .beta, status: .skipped) }

        XCTAssertEqual(store.qaPlanCandidates().first?.estimateMinutes, 10)
    }

    func testSkippedCasesAreLeftOutOfTheRemainingCount() {
        let (store, _) = makeStore()
        let mixed = add(store, 1, cases: 3)
        let mixedCases = store.testCases(for: mixed.id)
        store.setResult(caseID: mixedCases[0].id, environment: .beta, status: .pass)
        store.setResult(caseID: mixedCases[1].id, environment: .beta, status: .skipped)
        let skippedOnly = add(store, 2, cases: 3)
        store.setResult(caseID: store.testCases(for: skippedOnly.id)[0].id, environment: .beta, status: .skipped)

        let estimates = Dictionary(uniqueKeysWithValues: store.qaPlanCandidates().map { ($0.ticket.id, $0.estimateMinutes) })
        XCTAssertEqual(estimates[mixed.id], 10)
        XCTAssertEqual(estimates[skippedOnly.id], 20)
    }

    func testSuggestFillsCapacityAndLeavesTheDevPlanAlone() {
        let (store, _) = makeStore()
        for n in 1...3 { add(store, n, cases: 3) }
        let day = Date()
        let plan = store.suggestQAPlan(for: day, calendarBusy: [])
        XCTAssertEqual(plan?.ticketIDs.count, 2)
        XCTAssertEqual(store.qaPlan(for: day)?.ticketIDs, plan?.ticketIDs)
        XCTAssertTrue(store.dayPlans.isEmpty)
    }

    func testSuggestKeepsPlannedTicketsFromOtherWorkspaces() {
        let (store, _) = makeStore()
        add(store, 1, cases: 1)
        let day = Date()
        let elsewhere = UUID()
        store.qaDayPlans = [DayPlan(day: Calendar.current.startOfDay(for: day), ticketIDs: [elsewhere])]

        let plan = store.suggestQAPlan(for: day, calendarBusy: [])
        XCTAssertEqual(plan?.ticketIDs.count, 2)
        XCTAssertEqual(plan?.ticketIDs.last, elsewhere)
        XCTAssertEqual(store.qaDayPlans.count, 1)
    }

    func testSuggestAlwaysKeepsTheFirstCandidate() {
        let (store, _) = makeStore()
        add(store, 1, cases: 20)
        XCTAssertEqual(store.suggestQAPlan(for: Date(), calendarBusy: [])?.ticketIDs.count, 1)
    }

    func testToggleAddsAndRemovesAndPersists() {
        let (store, url) = makeStore()
        let a = add(store, 1, cases: 1)
        let b = add(store, 2, cases: 1)
        let day = Date()
        store.ensureQAPlan(for: day, calendarBusy: [])
        let inPlan = Set(store.qaPlan(for: day)?.ticketIDs ?? [])
        XCTAssertEqual(inPlan, [a.id, b.id])

        store.toggleQAPlanned(a.id, on: day)
        XCTAssertEqual(store.qaPlan(for: day)?.ticketIDs, [b.id])
        store.toggleQAPlanned(a.id, on: day)
        XCTAssertEqual(Set(store.qaPlan(for: day)?.ticketIDs ?? []), [a.id, b.id])

        let (reloaded, _) = makeStore(url: url)
        XCTAssertEqual(Set(reloaded.qaPlan(for: day)?.ticketIDs ?? []), [a.id, b.id])
    }

    func testPlannedMinutesSumsPlannedCandidates() {
        let a = QAPlanCandidate(ticket: Ticket(title: "a"), state: .ready, estimateMinutes: 20)
        let b = QAPlanCandidate(ticket: Ticket(title: "b"), state: .ready, estimateMinutes: 30)
        XCTAssertEqual(QAPlanner.plannedMinutes([a, b], ids: [a.id]), 20)
    }
}
