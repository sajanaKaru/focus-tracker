import Foundation

public struct QAQueue: Equatable, Sendable {
    public var ready: [Ticket] = []
    public var testing: [Ticket] = []
    public var failed: [Ticket] = []
    public var verified: [Ticket] = []

    public var isEmpty: Bool { ready.isEmpty && testing.isEmpty && failed.isEmpty && verified.isEmpty }
}

/// Live tickets under one milestone; a nil milestone collects tickets without one.
public struct LiveRelease: Identifiable, Equatable, Sendable {
    public var milestone: String?
    public var tickets: [Ticket]
    public var id: String { milestone ?? "" }
}

extension AppStore {
    // MARK: - Queries

    public func testCases(for ticketID: UUID) -> [TestCase] {
        testCases.filter { $0.ticketID == ticketID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func bugs(for ticketID: UUID) -> [BugReport] {
        bugReports.filter { $0.ticketID == ticketID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func latestResult(caseID: UUID, environment: DeploymentEnvironment?) -> TestResult? {
        testResults.filter { $0.caseID == caseID && $0.environment == environment }.max { $0.testedAt < $1.testedAt }
    }

    public func latestVerdict(ticketID: UUID, environment: DeploymentEnvironment?) -> TestVerdict? {
        testVerdicts.filter { $0.ticketID == ticketID && $0.environment == environment }.max { $0.testedAt < $1.testedAt }
    }

    public func qaSummary(ticketID: UUID, environment: DeploymentEnvironment?) -> QASummary {
        QA.summary(cases: testCases(for: ticketID), results: testResults.filter { $0.ticketID == ticketID }, environment: environment)
    }

    public func qaState(ticketID: UUID, environment: DeploymentEnvironment?) -> QAState {
        QA.state(
            cases: testCases(for: ticketID), results: testResults.filter { $0.ticketID == ticketID },
            verdicts: testVerdicts.filter { $0.ticketID == ticketID }, environment: environment
        )
    }

    /// Tickets to test. A specific environment lists tickets deployed there; nil lists everything in Testing.
    /// Tickets with no test cases yet count as ready so QA can add them.
    public func qaQueue(environment: DeploymentEnvironment?) -> QAQueue {
        var queue = QAQueue()
        let candidates = workspaceTickets
            .filter { ticket in
                guard ticket.environment != .live else { return false }
                return environment.map { ticket.environment == $0 } ?? (ticket.status == .testing)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        for ticket in candidates {
            switch qaState(ticketID: ticket.id, environment: ticket.environment) {
            case .noCases, .ready: queue.ready.append(ticket)
            case .testing: queue.testing.append(ticket)
            case .failed: queue.failed.append(ticket)
            case .verified: queue.verified.append(ticket)
            }
        }
        return queue
    }

    public var readyToTestCount: Int { qaQueue(environment: nil).ready.count }

    /// Tickets deployed to Live, grouped by milestone (named milestones A–Z, then tickets without one).
    public func liveArchive() -> [LiveRelease] {
        let live = workspaceTickets.filter { $0.environment == .live }
        let grouped = Dictionary(grouping: live) { $0.milestone?.title }
        let named = grouped.compactMap { key, tickets in key.map { LiveRelease(milestone: $0, tickets: tickets.sorted { $0.updatedAt > $1.updatedAt }) } }
            .sorted { ($0.milestone ?? "") < ($1.milestone ?? "") }
        let none = grouped[nil].map { [LiveRelease(milestone: nil, tickets: $0.sorted { $0.updatedAt > $1.updatedAt })] } ?? []
        return named + none
    }

    // MARK: - Test cases and results

    @discardableResult
    public func addTestCase(ticketID: UUID, title: String, steps: String = "", expected: String = "") -> TestCase? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ticket = ticket(ticketID) else { return nil }
        let testCase = TestCase(ticketID: ticketID, title: trimmed, steps: steps, expected: expected)
        testCases.append(testCase)
        record(.testCase, ticket: ticket, field: "Test case added", new: trimmed)
        save()
        return testCase
    }

    public func updateTestCase(_ id: UUID, title: String, steps: String, expected: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = testCases.firstIndex(where: { $0.id == id }) else { return }
        testCases[i].title = trimmed
        testCases[i].steps = steps
        testCases[i].expected = expected
        save()
    }

    public func deleteTestCase(_ id: UUID) {
        guard let testCase = testCases.first(where: { $0.id == id }) else { return }
        record(.testCase, ticket: ticket(testCase.ticketID), field: "Test case deleted", old: testCase.title)
        testCases.removeAll { $0.id == id }
        testResults.removeAll { $0.caseID == id }
        save()
    }

    public func setResult(caseID: UUID, environment: DeploymentEnvironment?, status: TestResultStatus, note: String = "", at date: Date = Date()) {
        guard let testCase = testCases.first(where: { $0.id == caseID }) else { return }
        let previous = latestResult(caseID: caseID, environment: environment)
        testResults.append(TestResult(caseID: caseID, ticketID: testCase.ticketID, environment: environment, status: status, note: note, testedAt: date))
        let scope = environment.map { " (\($0.title))" } ?? ""
        record(.testCase, ticket: ticket(testCase.ticketID), field: "Result\(scope): \(testCase.title)", old: previous?.status.title ?? "Not run", new: status.title)
        save()
    }

    // MARK: - Verdict

    /// Records the verdict, then pushes a summary comment and the `qa:` label. A failure can also send the ticket back to In Progress.
    @discardableResult
    public func postVerdict(
        ticketID: UUID, environment: DeploymentEnvironment?, outcome: VerdictOutcome, build: String = "",
        returnToInProgress: Bool = true, at date: Date = Date()
    ) -> TestVerdict? {
        guard let ticket = ticket(ticketID) else { return nil }
        let cases = testCases(for: ticketID)
        let results = testResults.filter { $0.ticketID == ticketID }
        let verdict = TestVerdict(
            ticketID: ticketID, environment: environment, outcome: outcome,
            summary: QA.summary(cases: cases, results: results, environment: environment).text,
            build: build.trimmingCharacters(in: .whitespaces), tester: githubLogin ?? "qa", testedAt: date
        )
        testVerdicts.append(verdict)
        save()

        let bugNumbers = bugs(for: ticketID).filter { $0.environment == environment }.compactMap(\.issueNumber)
        let body = QA.verdictComment(
            outcome: outcome, environment: environment, tester: verdict.tester, date: date, build: verdict.build,
            cases: cases, results: results, bugNumbers: bugNumbers
        )
        let scope = environment.map { " (\($0.title))" } ?? ""
        edit(ticketID, FieldChange(field: "QA verdict\(scope)", old: nil, new: outcome.title), remote: .comment(id: verdict.id, body: body)) { _ in }

        if ticket.github != nil {
            let old = self.ticket(ticketID)?.labels ?? ticket.labels
            let new = old.filter { !QA.isVerdictLabel($0, environment: environment) } + [QA.label(environment: environment, outcome: outcome)]
            if new != old {
                let change = FieldChange(
                    field: "Labels", old: old.isEmpty ? "None" : old.joined(separator: ", "), new: new.joined(separator: ", "),
                    oldList: old, newList: new
                )
                edit(ticketID, change, remote: .labels(new)) { $0.labels = new }
            }
        }
        if outcome == .fail && returnToInProgress { setStatus(ticketID, .inProgress) }
        return verdict
    }

    // MARK: - Bugs

    /// Saves the report and creates its GitHub issue in the ticket's repo. Returns nil when the ticket can't take a bug.
    @discardableResult
    public func reportBug(
        ticketID: UUID, environment: DeploymentEnvironment?, title: String, severity: BugSeverity, build: String = "",
        steps: String = "", expected: String = "", actual: String = "", links: String = ""
    ) async -> BugReport? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ticket = ticket(ticketID) else { return nil }
        guard ticket.github != nil else {
            notice = "Bugs are created in GitHub, so report them on a GitHub ticket."
            return nil
        }
        let bug = BugReport(
            ticketID: ticketID, environment: environment, title: trimmed, severity: severity,
            build: build, steps: steps, expected: expected, actual: actual, links: links
        )
        bugReports.append(bug)
        let entryID = record(.bugReport, ticket: ticket, field: "Bug reported", new: trimmed, sync: .pending, bugID: bug.id)
        save()
        await createBug(bug.id, entryID: entryID)
        return bugReports.first { $0.id == bug.id }
    }

    /// Re-sends a bug whose issue could not be created. Returns true when it now exists on GitHub.
    @discardableResult
    public func retryBug(_ id: UUID) async -> Bool {
        guard let bug = bugReports.first(where: { $0.id == id }), case .failed = bug.state else { return false }
        let entryID = actionLog.first { $0.bugID == id }?.id
            ?? record(.bugReport, ticket: ticket(bug.ticketID), field: "Bug reported", new: bug.title, sync: .pending, bugID: id)
        dismissedFailureIDs.remove(entryID)
        setActionSync(entryID, .pending)
        await createBug(id, entryID: entryID)
        return bugReports.first { $0.id == id }?.state == .created
    }

    private func createBug(_ bugID: UUID, entryID: UUID) async {
        guard let bug = bugReports.first(where: { $0.id == bugID }), let ticket = ticket(bug.ticketID), let gh = ticket.github else { return }

        func finish(_ state: BugState, number: Int? = nil, url: String? = nil) {
            guard let i = bugReports.firstIndex(where: { $0.id == bugID }) else { return }
            bugReports[i].state = state
            if let number { bugReports[i].issueNumber = number }
            if let url { bugReports[i].issueURL = url }
            save()
        }

        guard let token = tokenProvider(), !token.isEmpty else {
            let message = "Add a GitHub token in Settings to report bugs."
            finish(.failed(message))
            setActionSync(entryID, .failed(message))
            notice = message
            return
        }
        let hasBugLabel = labelOptions(for: ticket).contains { $0.name.caseInsensitiveCompare("bug") == .orderedSame }
        do {
            let created = try await GitHubClient(token: token, transport: transport).createIssue(
                repo: gh.repo, title: bug.title, body: QA.bugBody(bug, ticketKey: ticket.displayKey), labels: hasBugLabel ? ["bug"] : []
            )
            finish(.created, number: created.number, url: created.url)
            setActionSync(entryID, .synced(Date()), detail: "Created \(gh.repo)#\(created.number)")
        } catch {
            finish(.failed(error.localizedDescription))
            setActionSync(entryID, .failed(error.localizedDescription), detail: "Creating a bug in \(gh.repo) failed")
        }
    }
}
