import Foundation

public enum TestResultStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pass, fail, blocked, skipped

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pass: "Pass"
        case .fail: "Fail"
        case .blocked: "Blocked"
        case .skipped: "Skipped"
        }
    }

    public var symbol: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.circle.fill"
        case .blocked: "minus.circle.fill"
        case .skipped: "forward.circle.fill"
        }
    }
}

public enum VerdictOutcome: String, Codable, Sendable {
    case pass, fail

    public var title: String { self == .pass ? "Passed" : "Failed" }
    var labelSuffix: String { self == .pass ? "passed" : "failed" }
}

public enum BugSeverity: String, Codable, CaseIterable, Identifiable, Sendable {
    case critical, high, medium, low

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct TestCase: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var ticketID: UUID
    public var title: String
    public var steps: String
    public var expected: String
    public var createdAt: Date
    /// For regression cases: what existing behavior could break and why.
    public var risk: String
    public var isRegression: Bool

    public init(
        id: UUID = UUID(), ticketID: UUID, title: String, steps: String = "", expected: String = "", createdAt: Date = Date(),
        risk: String = "", isRegression: Bool = false
    ) {
        self.id = id
        self.ticketID = ticketID
        self.title = title
        self.steps = steps
        self.expected = expected
        self.createdAt = createdAt
        self.risk = risk
        self.isRegression = isRegression
    }

    private enum CodingKeys: String, CodingKey {
        case id, ticketID, title, steps, expected, createdAt, risk, isRegression
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ticketID = try c.decode(UUID.self, forKey: .ticketID)
        title = try c.decode(String.self, forKey: .title)
        steps = try c.decode(String.self, forKey: .steps)
        expected = try c.decode(String.self, forKey: .expected)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        risk = try c.decodeIfPresent(String.self, forKey: .risk) ?? ""
        isRegression = try c.decodeIfPresent(Bool.self, forKey: .isRegression) ?? false
    }
}

public struct TestResult: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var caseID: UUID
    public var ticketID: UUID
    public var environment: DeploymentEnvironment?
    public var status: TestResultStatus
    public var note: String
    public var testedAt: Date

    public init(id: UUID = UUID(), caseID: UUID, ticketID: UUID, environment: DeploymentEnvironment?, status: TestResultStatus, note: String = "", testedAt: Date = Date()) {
        self.id = id
        self.caseID = caseID
        self.ticketID = ticketID
        self.environment = environment
        self.status = status
        self.note = note
        self.testedAt = testedAt
    }
}

public struct TestVerdict: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var ticketID: UUID
    public var environment: DeploymentEnvironment?
    public var outcome: VerdictOutcome
    public var summary: String
    public var build: String
    public var tester: String
    public var testedAt: Date

    public init(id: UUID = UUID(), ticketID: UUID, environment: DeploymentEnvironment?, outcome: VerdictOutcome, summary: String, build: String = "", tester: String, testedAt: Date = Date()) {
        self.id = id
        self.ticketID = ticketID
        self.environment = environment
        self.outcome = outcome
        self.summary = summary
        self.build = build
        self.tester = tester
        self.testedAt = testedAt
    }
}

public enum BugState: Codable, Equatable, Hashable, Sendable {
    case draft
    case created
    case failed(String)
}

/// A bug found while testing a ticket; once created it points at its own GitHub issue.
public struct BugReport: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var ticketID: UUID
    public var environment: DeploymentEnvironment?
    public var title: String
    public var severity: BugSeverity
    public var build: String
    public var steps: String
    public var expected: String
    public var actual: String
    public var links: String
    public var createdAt: Date
    public var issueNumber: Int?
    public var issueURL: String?
    public var state: BugState

    public init(
        id: UUID = UUID(), ticketID: UUID, environment: DeploymentEnvironment?, title: String, severity: BugSeverity = .medium,
        build: String = "", steps: String = "", expected: String = "", actual: String = "", links: String = "",
        createdAt: Date = Date(), issueNumber: Int? = nil, issueURL: String? = nil, state: BugState = .draft
    ) {
        self.id = id
        self.ticketID = ticketID
        self.environment = environment
        self.title = title
        self.severity = severity
        self.build = build
        self.steps = steps
        self.expected = expected
        self.actual = actual
        self.links = links
        self.createdAt = createdAt
        self.issueNumber = issueNumber
        self.issueURL = issueURL
        self.state = state
    }
}

public enum QAState: Equatable, Sendable {
    case noCases, ready, testing, failed, verified
}

public struct QASummary: Equatable, Sendable {
    public var pass = 0
    public var fail = 0
    public var blocked = 0
    public var skipped = 0
    public var notRun = 0

    public var total: Int { pass + fail + blocked + skipped + notRun }

    /// e.g. "7/10 passed, 1 failed".
    public var text: String {
        guard total > 0 else { return "No test cases" }
        var text = "\(pass)/\(total) passed"
        if fail > 0 { text += ", \(fail) failed" }
        if blocked > 0 { text += ", \(blocked) blocked" }
        return text
    }
}

public enum QA {
    private static func latestByCase(_ results: [TestResult], caseIDs: Set<UUID>, environment: DeploymentEnvironment?) -> [UUID: TestResult] {
        var latest: [UUID: TestResult] = [:]
        for result in results where caseIDs.contains(result.caseID) && result.environment == environment {
            if let current = latest[result.caseID], current.testedAt > result.testedAt { continue }
            latest[result.caseID] = result
        }
        return latest
    }

    public static func summary(cases: [TestCase], results: [TestResult], environment: DeploymentEnvironment?) -> QASummary {
        let latest = latestByCase(results, caseIDs: Set(cases.map(\.id)), environment: environment)
        var summary = QASummary()
        for testCase in cases {
            switch latest[testCase.id]?.status {
            case .pass?: summary.pass += 1
            case .fail?: summary.fail += 1
            case .blocked?: summary.blocked += 1
            case .skipped?: summary.skipped += 1
            case nil: summary.notRun += 1
            }
        }
        return summary
    }

    /// `verdicts` and `results` may include other tickets and environments. A verdict stands until a newer result is recorded.
    public static func state(cases: [TestCase], results: [TestResult], verdicts: [TestVerdict], environment: DeploymentEnvironment?) -> QAState {
        guard !cases.isEmpty else { return .noCases }
        let ids = Set(cases.map(\.id))
        let envResults = results.filter { ids.contains($0.caseID) && $0.environment == environment }
        let latestVerdict = verdicts.filter { $0.environment == environment }.max { $0.testedAt < $1.testedAt }
        if let verdict = latestVerdict, !envResults.contains(where: { $0.testedAt > verdict.testedAt }) {
            return verdict.outcome == .pass ? .verified : .failed
        }
        return envResults.isEmpty ? .ready : .testing
    }

    // MARK: Labels

    public static func label(environment: DeploymentEnvironment?, outcome: VerdictOutcome) -> String {
        "qa:" + (environment.map { "\($0.rawValue)-" } ?? "") + outcome.labelSuffix
    }

    /// Either outcome's label for exactly this environment; other environments' labels are not matched.
    public static func isVerdictLabel(_ name: String, environment: DeploymentEnvironment?) -> Bool {
        name == label(environment: environment, outcome: .pass) || name == label(environment: environment, outcome: .fail)
    }

    // MARK: Markdown

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func verdictComment(
        outcome: VerdictOutcome, environment: DeploymentEnvironment?, tester: String, date: Date, build: String,
        cases: [TestCase], results: [TestResult], bugNumbers: [Int]
    ) -> String {
        let scope = environment.map { " (\($0.title))" } ?? ""
        var lines = ["**QA result\(scope): \(outcome.title.uppercased())**"]
        var byline = "Tested by @\(tester) on \(day(date))"
        let trimmedBuild = build.trimmingCharacters(in: .whitespaces)
        if !trimmedBuild.isEmpty { byline += " — build \(trimmedBuild)" }
        lines.append(byline)

        let latest = latestByCase(results, caseIDs: Set(cases.map(\.id)), environment: environment)
        if !cases.isEmpty {
            let rows = cases.map { (testCase: $0, result: latest[$0.id]) }
            // Failures first so the reader sees what went wrong without scrolling.
            let ordered = outcome == .fail
                ? rows.filter { $0.result?.status == .fail || $0.result?.status == .blocked } + rows.filter { !($0.result?.status == .fail || $0.result?.status == .blocked) }
                : rows
            lines += ["", "| Case | Result | Note |", "|---|---|---|"]
            for row in ordered {
                lines.append("| \(cell(row.testCase.title)) | \(row.result?.status.title ?? "Not run") | \(cell(row.result?.note ?? "")) |")
            }
        }
        if !bugNumbers.isEmpty {
            lines += ["", "Bugs: " + bugNumbers.map { "#\($0)" }.joined(separator: ", ")]
        }
        return lines.joined(separator: "\n")
    }

    public static func bugBody(_ bug: BugReport, ticketKey: String) -> String {
        var context = "Found while testing \(ticketKey)"
        let details = [bug.environment?.title, bug.build.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "build \(bug.build.trimmingCharacters(in: .whitespaces))"].compactMap { $0 }
        if !details.isEmpty { context += " (" + details.joined(separator: ", ") + ")" }
        var parts = [context, "**Severity:** \(bug.severity.title)"]
        for (heading, text) in [("Steps to reproduce", bug.steps), ("Expected", bug.expected), ("Actual", bug.actual), ("Links", bug.links)] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append("### \(heading)\n\(trimmed)") }
        }
        return parts.joined(separator: "\n\n")
    }
}
