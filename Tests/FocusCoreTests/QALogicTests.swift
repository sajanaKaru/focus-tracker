import XCTest
@testable import FocusCore

final class QALogicTests: XCTestCase {
    private let ticketID = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func cases(_ n: Int) -> [TestCase] {
        (1...n).map { TestCase(ticketID: ticketID, title: "Case \($0)", createdAt: at(Double($0))) }
    }

    private func result(_ testCase: TestCase, _ status: TestResultStatus, _ env: DeploymentEnvironment?, at seconds: Double, note: String = "") -> TestResult {
        TestResult(caseID: testCase.id, ticketID: ticketID, environment: env, status: status, note: note, testedAt: at(seconds))
    }

    private func verdict(_ outcome: VerdictOutcome, _ env: DeploymentEnvironment?, at seconds: Double) -> TestVerdict {
        TestVerdict(ticketID: ticketID, environment: env, outcome: outcome, summary: "", tester: "qa", testedAt: at(seconds))
    }

    // MARK: Summary

    func testSummaryCountsLatestResultPerCaseAndEnvironment() {
        let c = cases(4)
        let results = [
            result(c[0], .fail, .beta, at: 10), result(c[0], .pass, .beta, at: 20),
            result(c[1], .fail, .beta, at: 10),
            result(c[2], .blocked, .beta, at: 10),
            result(c[3], .pass, .alpha, at: 10)
        ]
        let summary = QA.summary(cases: c, results: results, environment: .beta)
        XCTAssertEqual(summary, QASummary(pass: 1, fail: 1, blocked: 1, skipped: 0, notRun: 1))
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.text, "1/4 passed, 1 failed, 1 blocked")
    }

    func testSummaryTextForNoCasesAndAllPassed() {
        XCTAssertEqual(QA.summary(cases: [], results: [], environment: nil).text, "No test cases")
        let c = cases(2)
        let results = c.map { result($0, .pass, nil, at: 5) }
        XCTAssertEqual(QA.summary(cases: c, results: results, environment: nil).text, "2/2 passed")
    }

    func testResultsAreSeparatePerEnvironment() {
        let c = cases(1)
        let results = [result(c[0], .pass, .beta, at: 10)]
        XCTAssertEqual(QA.summary(cases: c, results: results, environment: .alpha2).notRun, 1)
        XCTAssertEqual(QA.summary(cases: c, results: results, environment: .beta).pass, 1)
    }

    // MARK: State

    func testStateProgression() {
        let c = cases(2)
        XCTAssertEqual(QA.state(cases: [], results: [], verdicts: [], environment: .beta), .noCases)
        XCTAssertEqual(QA.state(cases: c, results: [], verdicts: [], environment: .beta), .ready)
        XCTAssertEqual(QA.state(cases: c, results: [result(c[0], .pass, .beta, at: 10)], verdicts: [], environment: .beta), .testing)
    }

    func testVerdictStandsUntilNewerResult() {
        let c = cases(1)
        let results = [result(c[0], .pass, .beta, at: 10)]
        XCTAssertEqual(QA.state(cases: c, results: results, verdicts: [verdict(.pass, .beta, at: 20)], environment: .beta), .verified)
        XCTAssertEqual(QA.state(cases: c, results: results, verdicts: [verdict(.fail, .beta, at: 20)], environment: .beta), .failed)

        let retested = results + [result(c[0], .pass, .beta, at: 30)]
        XCTAssertEqual(QA.state(cases: c, results: retested, verdicts: [verdict(.fail, .beta, at: 20)], environment: .beta), .testing)
    }

    func testVerdictAndResultsInOtherEnvironmentsDoNotCount() {
        let c = cases(1)
        let verdicts = [verdict(.pass, .alpha, at: 20)]
        XCTAssertEqual(QA.state(cases: c, results: [result(c[0], .pass, .alpha, at: 10)], verdicts: verdicts, environment: .alpha2), .ready)
        XCTAssertEqual(QA.state(cases: c, results: [result(c[0], .pass, .alpha, at: 10)], verdicts: verdicts, environment: .alpha), .verified)
    }

    func testLatestVerdictWins() {
        let c = cases(1)
        let verdicts = [verdict(.fail, .beta, at: 20), verdict(.pass, .beta, at: 40)]
        XCTAssertEqual(QA.state(cases: c, results: [result(c[0], .pass, .beta, at: 10)], verdicts: verdicts, environment: .beta), .verified)
    }

    // MARK: Labels

    func testVerdictLabels() {
        XCTAssertEqual(QA.label(environment: .alpha2, outcome: .fail), "qa:alpha2-failed")
        XCTAssertEqual(QA.label(environment: .beta, outcome: .pass), "qa:beta-passed")
        XCTAssertEqual(QA.label(environment: nil, outcome: .pass), "qa:passed")
    }

    func testVerdictLabelMatchingIsPerEnvironment() {
        XCTAssertTrue(QA.isVerdictLabel("qa:beta-passed", environment: .beta))
        XCTAssertTrue(QA.isVerdictLabel("qa:beta-failed", environment: .beta))
        XCTAssertFalse(QA.isVerdictLabel("qa:alpha-passed", environment: .beta))
        XCTAssertFalse(QA.isVerdictLabel("qa:alpha2-passed", environment: .alpha))
        XCTAssertFalse(QA.isVerdictLabel("bug", environment: .beta))
        XCTAssertTrue(QA.isVerdictLabel("qa:passed", environment: nil))
        XCTAssertFalse(QA.isVerdictLabel("qa:beta-passed", environment: nil))
    }

    // MARK: Markdown

    func testPassComment() {
        let c = cases(2)
        let results = [result(c[0], .pass, .beta, at: 10), result(c[1], .pass, .beta, at: 11, note: "fine | ok")]
        let text = QA.verdictComment(outcome: .pass, environment: .beta, tester: "sajana", date: Date(timeIntervalSince1970: 993_600), build: "1.4.2", cases: c, results: results, bugNumbers: [])
        XCTAssertTrue(text.hasPrefix("**QA result (Beta): PASSED**\nTested by @sajana on 1970-01-12 — build 1.4.2"), text)
        XCTAssertTrue(text.contains("| Case 1 | Pass |  |"))
        XCTAssertTrue(text.contains("| Case 2 | Pass | fine \\| ok |"))
        XCTAssertFalse(text.contains("Bugs:"))
    }

    func testFailCommentListsFailuresFirstAndBugs() {
        let c = cases(3)
        let results = [result(c[0], .pass, .alpha2, at: 10), result(c[2], .fail, .alpha2, at: 11, note: "crashes")]
        let text = QA.verdictComment(outcome: .fail, environment: .alpha2, tester: "qa", date: at(0), build: "", cases: c, results: results, bugNumbers: [123, 124])
        XCTAssertTrue(text.contains("**QA result (Alpha2): FAILED**"))
        XCTAssertFalse(text.contains("build"))
        let failed = text.range(of: "| Case 3 |")!.lowerBound
        let passed = text.range(of: "| Case 1 |")!.lowerBound
        XCTAssertLessThan(failed, passed)
        XCTAssertTrue(text.contains("| Case 2 | Not run |  |"))
        XCTAssertTrue(text.hasSuffix("Bugs: #123, #124"))
    }

    func testCommentWithoutEnvironmentOrCases() {
        let text = QA.verdictComment(outcome: .pass, environment: nil, tester: "qa", date: at(0), build: "", cases: [], results: [], bugNumbers: [])
        XCTAssertTrue(text.hasPrefix("**QA result: PASSED**"))
        XCTAssertFalse(text.contains("| Case |"))
    }

    func testBugBody() {
        let bug = BugReport(
            ticketID: ticketID, environment: .beta, title: "Crash", severity: .high, build: "1.4.2",
            steps: "1. Open\n2. Tap", expected: "Works", actual: "Crashes", links: "https://x/y.png"
        )
        let body = QA.bugBody(bug, ticketKey: "me/a#7")
        XCTAssertTrue(body.hasPrefix("Found while testing me/a#7 (Beta, build 1.4.2)"))
        XCTAssertTrue(body.contains("**Severity:** High"))
        XCTAssertTrue(body.contains("### Steps to reproduce\n1. Open\n2. Tap"))
        XCTAssertTrue(body.contains("### Expected\nWorks"))
        XCTAssertTrue(body.contains("### Actual\nCrashes"))
        XCTAssertTrue(body.contains("### Links\nhttps://x/y.png"))
    }

    func testBugBodyOmitsEmptySections() {
        let body = QA.bugBody(BugReport(ticketID: ticketID, environment: nil, title: "T"), ticketKey: "me/a#7")
        XCTAssertEqual(body, "Found while testing me/a#7\n\n**Severity:** Medium")
    }

    // MARK: Codable

    func testModelsRoundTrip() throws {
        let bug = BugReport(ticketID: ticketID, environment: .alpha2, title: "B", issueNumber: 5, issueURL: "u", state: .failed("nope"))
        let data = try JSONEncoder().encode(bug)
        XCTAssertEqual(try JSONDecoder().decode(BugReport.self, from: data), bug)
        let result = TestResult(caseID: UUID(), ticketID: ticketID, environment: nil, status: .blocked)
        XCTAssertEqual(try JSONDecoder().decode(TestResult.self, from: JSONEncoder().encode(result)), result)
    }
}
