# Role Dashboards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Today a role-specific dashboard: unchanged for Dev, a testing dashboard with a day plan for QA, and a team delivery dashboard for PM.

**Architecture:** `TodayView` becomes a switch on `store.role`; the current view is renamed `DevTodayView`. All numbers come from pure `AppStore` queries in FocusCore (`AppStore+QADashboard.swift`, `AppStore+QAPlan.swift`, `AppStore+PMDashboard.swift`) that views only render. PM syncs every open issue in the repos configured in Settings; tickets gain `assignees` and `remoteUpdatedAt`.

**Tech Stack:** Swift 6 package, SwiftUI (macOS 14), XCTest. FocusCore is the testable module; FocusTracker is the app target.

**Spec:** `docs/superpowers/specs/2026-10-12-role-dashboards-design.md`

## Global Constraints

- Dev's Today page must behave exactly as before (only the struct name and the extracted time-log section change).
- New stored fields are optional so existing `data.json` files decode: `Ticket.assignees: [String]?`, `Ticket.remoteUpdatedAt: Date?`, snapshot `qaDayPlans: [DayPlan]?`.
- Do not change `AppStore.merge`: a ticket missing from a fetch is marked remote-closed and Done, as today.
- QA and PM are today-only (no day navigator). Cards do not deep-link to other tabs; tapping a ticket sets `selectedTicketID`.
- Named constants: QA 10 minutes per case without a passing result (minimum 10), 30 minutes for a ticket with no cases; stale = in flight and `remoteUpdatedAt` more than 3 days ago.
- Comments: only where the code cannot show the reason, one short line.
- Never launch `build/FocusTracker.app` (it loads the real `data.json` and token and can write to GitHub). Verify with `swift build` and `swift test`.
- Do not run `git commit` or `git push` unless the user asks.
- `rm` is aliased to `npm run rm` in this shell; use `command rm` if a delete is needed.
- `ActivityTests.testManualActivityCountsInTotalsAndLog` fails only in the first ~30 minutes after local midnight (pre-existing).

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FocusCore/Models.swift` (modify) | `Ticket.assignees`, `Ticket.remoteUpdatedAt` |
| `Sources/FocusCore/GitHubClient.swift` (modify) | `RemoteIssue` fields, DTO decoding, `fetchOpenIssues`, shared paging helper |
| `Sources/FocusCore/AppStore.swift` (modify) | copy new fields on sync, `syncsTeamIssues`, `roleDidChange`, `qaDayPlans` storage |
| `Sources/FocusCore/AppStore+QADashboard.swift` (create) | QA pipeline, progress, retest list, recent bugs |
| `Sources/FocusCore/AppStore+QAPlan.swift` (create) | `QAPlanner`, QA plan candidates, suggest, toggle |
| `Sources/FocusCore/AppStore+PMDashboard.swift` (create) | PM sprint progress, pipeline, risks, workload, incoming, summary |
| `Sources/FocusTracker/TodayView.swift` (rewrite) | thin role switch |
| `Sources/FocusTracker/DevTodayView.swift` (create via move) | the current Today page, renamed |
| `Sources/FocusTracker/DayTimeLogSection.swift` (create) | time log extracted from Dev Today, shared with QA |
| `Sources/FocusTracker/DashboardCards.swift` (create) | `DashboardBar`, `CapacityBar`, `TicketListCard`, `timeGreeting`, `todaySheet` |
| `Sources/FocusTracker/QATodayView.swift`, `QATestPlanCard.swift` (create) | QA dashboard |
| `Sources/FocusTracker/PMTodayView.swift` (create) | PM dashboard |
| `Sources/FocusTracker/RootView.swift` (modify) | sync on role change |
| `Tests/FocusCoreTests/RoleDashboardDataTests.swift`, `QADashboardTests.swift`, `QAPlanTests.swift`, `PMDashboardTests.swift` (create) | tests |

---

### Task 1: Assignees and last activity on tickets

**Files:**
- Modify: `Sources/FocusCore/Models.swift` (Ticket)
- Modify: `Sources/FocusCore/GitHubClient.swift` (`RemoteIssue`, `IssueDTO`)
- Modify: `Sources/FocusCore/AppStore.swift` (`copyContent`, `merge`)
- Create: `Tests/FocusCoreTests/RoleDashboardDataTests.swift`

**Interfaces:**
- Produces: `Ticket.assignees: [String]?`, `Ticket.remoteUpdatedAt: Date?` (init params `assignees:`, `remoteUpdatedAt:` last, default nil); `RemoteIssue.assignees: [String]`, `RemoteIssue.updatedAt: Date?` (init params `assignees:`, `updatedAt:` last).

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/RoleDashboardDataTests.swift`:

```swift
import XCTest
@testable import FocusCore

private struct StubTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, [String: String], String)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, headers, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private func issueJSON(number: Int, repo: String = "me/a", assignees: [String] = ["alice"], pr: Bool = false) -> String {
    let logins = assignees.map { #"{"login": "\#($0)"}"# }.joined(separator: ",")
    return """
    {"number": \(number), "title": "Issue \(number)", "body": null, "state": "open",
     "html_url": "https://github.com/\(repo)/issues/\(number)",
     "repository_url": "https://api.github.com/repos/\(repo)", "node_id": "I_\(number)",
     "updated_at": "2026-10-10T09:30:00Z", "assignees": [\(logins)],
     "labels": []\(pr ? #", "pull_request": {}"# : "")}
    """
}

final class TicketDataTests: XCTestCase {
    func testTicketWithoutNewFieldsStillDecodes() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "title": "T", "body": "", "status": "todo", "priority": 0, "labels": [],
         "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticket = try decoder.decode(Ticket.self, from: Data(json.utf8))
        XCTAssertNil(ticket.assignees)
        XCTAssertNil(ticket.remoteUpdatedAt)
    }

    func testClientReadsAssigneesAndUpdatedAt() async throws {
        let client = GitHubClient(token: "t", transport: StubTransport { _ in (200, [:], "[\(issueJSON(number: 1, assignees: ["alice", "bob"]))]") })
        let issues = try await client.fetchAssignedIssues()
        XCTAssertEqual(issues[0].assignees, ["alice", "bob"])
        XCTAssertEqual(issues[0].updatedAt, ISO8601DateFormatter().date(from: "2026-10-10T09:30:00Z"))
    }

    func testMergeCopiesAssigneesOnInsertAndUpdate() {
        let updated = Date(timeIntervalSince1970: 1_000)
        func remote(_ assignees: [String]) -> RemoteIssue {
            RemoteIssue(repo: "me/a", number: 1, title: "T", url: "https://github.com/me/a/issues/1", assignees: assignees, updatedAt: updated)
        }
        var tickets = AppStore.merge(existing: [], remote: [remote(["alice"])])
        XCTAssertEqual(tickets[0].assignees, ["alice"])
        XCTAssertEqual(tickets[0].remoteUpdatedAt, updated)

        tickets = AppStore.merge(existing: tickets, remote: [remote(["bob"])])
        XCTAssertEqual(tickets[0].assignees, ["bob"])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TicketDataTests`
Expected: build FAIL (`assignees` / `updatedAt` not members).

- [ ] **Step 3: Implement**

`Models.swift`, in `Ticket` after `public var deployment: DeploymentMark?` add:

```swift
    /// GitHub logins the issue is assigned to; nil until the first sync that reports them.
    public var assignees: [String]?
    /// GitHub `updated_at`; `updatedAt` is rewritten on every sync, so it cannot show staleness.
    public var remoteUpdatedAt: Date?
```

In `Ticket.init` add parameters after `deployment: DeploymentMark? = nil` (add the comma):

```swift
        deployment: DeploymentMark? = nil,
        assignees: [String]? = nil,
        remoteUpdatedAt: Date? = nil
```

and at the end of the init body after `self.deployment = deployment`:

```swift
        self.assignees = assignees
        self.remoteUpdatedAt = remoteUpdatedAt
```

`GitHubClient.swift`, `RemoteIssue`: after `public var isOpen: Bool` add:

```swift
    public var assignees: [String]
    public var updatedAt: Date?
```

Replace its init signature's tail `isOpen: Bool = true) {` with `isOpen: Bool = true, assignees: [String] = [], updatedAt: Date? = nil) {` and add after `self.isOpen = isOpen`:

```swift
        self.assignees = assignees
        self.updatedAt = updatedAt
```

In `IssueDTO` add nested type and properties:

```swift
    struct AssigneeDTO: Decodable { let login: String }
```
```swift
    let assignees: [AssigneeDTO]?
    let updatedAt: Date?
```
(place the properties after `let pullRequest: PullRequestMarker?`), and in `toRemote()` change the last argument list:

```swift
            isOpen: state != "closed",
            assignees: assignees?.map(\.login) ?? [],
            updatedAt: updatedAt
        )
```

`AppStore.swift`, `copyContent`: after `ticket.issueType = issue.issueType` add:

```swift
        ticket.assignees = issue.assignees
        ticket.remoteUpdatedAt = issue.updatedAt
```

In `merge`, the `Ticket(` created for a new issue: after `github: GitHubRef(repo: issue.repo, number: issue.number, url: issue.url, isPullRequest: issue.isPullRequest)` inside that initializer add (comma before):

```swift
                    github: GitHubRef(repo: issue.repo, number: issue.number, url: issue.url, isPullRequest: issue.isPullRequest),
                    assignees: issue.assignees,
                    remoteUpdatedAt: issue.updatedAt
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter TicketDataTests`
Expected: PASS. Then `swift test` for the whole suite: all pass.

---

### Task 2: PM team sync

**Files:**
- Modify: `Sources/FocusCore/GitHubClient.swift` (`fetchAssignedIssues`, new `fetchOpenIssues`)
- Modify: `Sources/FocusCore/AppStore.swift` (`syncGitHub`, `syncsTeamIssues`, `roleDidChange`)
- Modify: `Sources/FocusTracker/RootView.swift` (`onChange(of: store.role)`)
- Test: `Tests/FocusCoreTests/RoleDashboardDataTests.swift`

**Interfaces:**
- Consumes: Task 1 `RemoteIssue.assignees`.
- Produces: `GitHubClient.fetchOpenIssues(repos: [String], includePullRequests: Bool = false) async throws -> [RemoteIssue]`; `AppStore.syncsTeamIssues: Bool`; `AppStore.roleDidChange(from: UserRole) async`.

- [ ] **Step 1: Write the failing tests**

Append to `RoleDashboardDataTests.swift`:

```swift
final class FetchOpenIssuesTests: XCTestCase {
    func testPagesPerRepoAndSkipsPullRequests() async throws {
        let paths = PathLog()
        let client = GitHubClient(token: "t", transport: StubTransport { request in
            paths.add(request.url!.absoluteString)
            if request.url!.absoluteString.contains("page=2") {
                return (200, [:], "[\(issueJSON(number: 2))]")
            }
            return (
                200, ["Link": #"<https://api.github.com/repos/me/a/issues?page=2>; rel="next""#],
                "[\(issueJSON(number: 1)), \(issueJSON(number: 3, pr: true))]"
            )
        })
        let issues = try await client.fetchOpenIssues(repos: ["me/a"])
        XCTAssertEqual(issues.map(\.number), [1, 2])
        XCTAssertTrue(paths.all.first!.contains("/repos/me/a/issues"))
        XCTAssertTrue(paths.all.first!.contains("state=open"))

        let withPRs = try await client.fetchOpenIssues(repos: ["me/a"], includePullRequests: true)
        XCTAssertEqual(withPRs.map(\.number), [1, 3, 2])
    }

    func testSkipsNamesThatAreNotOwnerSlashName() async throws {
        let paths = PathLog()
        let client = GitHubClient(token: "t", transport: StubTransport { request in
            paths.add(request.url!.absoluteString)
            return (200, [:], "[]")
        })
        _ = try await client.fetchOpenIssues(repos: ["../x", "me/a/b", "me", "me/ok-1.x"])
        XCTAssertEqual(paths.all.count, 1)
        XCTAssertTrue(paths.all[0].contains("/repos/me/ok-1.x/issues"))
    }
}

private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
final class RoleSyncTests: XCTestCase {
    private func makeStore(repos: String?, role: UserRole) -> (AppStore, RecordingTransport) {
        let issue = issueJSON(number: 1)
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            if path == "/issues" || path == "/repos/me/a/issues" { return (200, "[\(issue)]") }
            if path == "/graphql" { return (200, #"{"data":{"nodes":[{"id":"I_1","projectItems":{"nodes":[]}}]}}"#) }
            return (200, "{}")
        }
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        if let repos { defaults.set(repos, forKey: PrefKey.repos) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: defaults, transport: transport, tokenProvider: { "t" })
        store.role = role
        return (store, transport)
    }

    private func paths(_ transport: RecordingTransport) -> [String] { transport.requests.compactMap { $0.url?.path } }

    func testPMWithReposSyncsTheWholeRepo() async {
        let (store, transport) = makeStore(repos: "me/a", role: .pm)
        XCTAssertTrue(store.syncsTeamIssues)
        await store.syncGitHub()
        XCTAssertTrue(paths(transport).contains("/repos/me/a/issues"))
        XCTAssertFalse(paths(transport).contains("/issues"))
        XCTAssertEqual(store.tickets[0].assignees, ["alice"])
    }

    func testPMWithoutReposAndOtherRolesSyncAssignedIssues() async {
        for (repos, role) in [(nil, UserRole.pm), ("me/a", .dev), ("me/a", .qa)] as [(String?, UserRole)] {
            let (store, transport) = makeStore(repos: repos, role: role)
            XCTAssertFalse(store.syncsTeamIssues)
            await store.syncGitHub()
            XCTAssertTrue(paths(transport).contains("/issues"), "\(role)")
            XCTAssertFalse(paths(transport).contains("/repos/me/a/issues"), "\(role)")
        }
    }

    func testRoleChangeSyncsOnlyWhenCrossingPM() async {
        let (store, transport) = makeStore(repos: "me/a", role: .qa)
        await store.roleDidChange(from: .dev)
        XCTAssertTrue(transport.requests.isEmpty)

        store.role = .pm
        await store.roleDidChange(from: .qa)
        XCTAssertTrue(paths(transport).contains("/repos/me/a/issues"))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "FetchOpenIssuesTests|RoleSyncTests"`
Expected: build FAIL (`fetchOpenIssues`, `syncsTeamIssues`, `roleDidChange` not defined).

- [ ] **Step 3: Implement the client**

In `GitHubClient.swift` replace the whole `fetchAssignedIssues` function (from its doc comment through its closing brace) with:

```swift
    /// Open issues assigned to the authenticated user across all accessible repos.
    /// `repos` (lowercased "owner/name") restricts the result when non-empty.
    public func fetchAssignedIssues(repos: Set<String> = [], includePullRequests: Bool = false) async throws -> [RemoteIssue] {
        var components = URLComponents(string: "https://\(Self.apiHost)/issues")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "assigned"),
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: "100")
        ]
        return try await collectIssues(from: components.url, includePullRequests: includePullRequests) {
            repos.isEmpty || repos.contains($0.repo.lowercased())
        }
    }

    /// Open issues in each "owner/name" repo, whoever they are assigned to. Other names are skipped.
    public func fetchOpenIssues(repos: [String], includePullRequests: Bool = false) async throws -> [RemoteIssue] {
        var result: [RemoteIssue] = []
        for repo in repos where Self.isRepoName(repo) {
            var components = URLComponents(string: "https://\(Self.apiHost)/repos/\(repo)/issues")!
            components.queryItems = [
                URLQueryItem(name: "state", value: "open"),
                URLQueryItem(name: "per_page", value: "100")
            ]
            result += try await collectIssues(from: components.url, includePullRequests: includePullRequests) { _ in true }
        }
        return result
    }

    private func collectIssues(from start: URL?, includePullRequests: Bool, keep: (RemoteIssue) -> Bool) async throws -> [RemoteIssue] {
        var next = start
        var result: [RemoteIssue] = []
        var pages = 0

        while let url = next, pages < maxPages {
            let (data, response) = try await get(url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([IssueDTO].self, from: data)
            for item in items {
                guard let issue = item.toRemote() else { continue }
                if issue.isPullRequest && !includePullRequests { continue }
                if !keep(issue) { continue }
                result.append(issue)
            }
            next = Self.nextURL(from: response.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return result
    }

    /// The repo name goes into the request path, so only plain owner/name pairs are accepted.
    static func isRepoName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        }
    }
```

- [ ] **Step 4: Implement the store changes**

In `AppStore.swift` `syncGitHub()`, replace

```swift
            let remote = try await client.fetchAssignedIssues(repos: configuredRepos, includePullRequests: includePRs)
```

with

```swift
            let remote: [RemoteIssue]
            if syncsTeamIssues {
                remote = try await client.fetchOpenIssues(repos: configuredRepos.sorted(), includePullRequests: includePRs)
            } else {
                remote = try await client.fetchAssignedIssues(repos: configuredRepos, includePullRequests: includePRs)
            }
```

After the `configuredRepos` property add:

```swift
    /// PM sees every open issue in the configured repos; other roles, and PM without repos, sync issues assigned to the user.
    public var syncsTeamIssues: Bool { role == .pm && !configuredRepos.isEmpty }

    /// Switching into or out of PM changes which issues are fetched, so refresh once.
    public func roleDidChange(from old: UserRole) async {
        guard (old == .pm) != (role == .pm), tokenProvider() != nil else { return }
        await syncGitHub()
    }
```

In `RootView.swift` replace

```swift
        .onChange(of: store.role) {
            if let selection, !visibleItems.contains(selection) { self.selection = nil }
        }
```

with

```swift
        .onChange(of: store.role) { old, _ in
            if let selection, !visibleItems.contains(selection) { self.selection = nil }
            Task { await store.roleDidChange(from: old) }
        }
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter "FetchOpenIssuesTests|RoleSyncTests|GitHubClientTests"` then `swift build`.
Expected: PASS and build succeeds.

---

### Task 3: QA dashboard queries

**Files:**
- Create: `Sources/FocusCore/AppStore+QADashboard.swift`
- Create: `Tests/FocusCoreTests/QADashboardTests.swift`

**Interfaces:**
- Produces:
  - `QAPipelineRow { environment: DeploymentEnvironment, ready, testing, failed, verified: Int }` (`Identifiable`, id = environment) and `QAPipeline { rows: [QAPipelineRow], liveCount: Int }`; `AppStore.qaPipeline() -> QAPipeline` (rows for Alpha, Alpha2, Beta).
  - `QAProgress { passed, failed, verified: Int }`; `AppStore.qaProgress(in: DateInterval) -> QAProgress`.
  - `RetestItem { ticket: Ticket, failedCases: Int, failedAt: Date, redeployed: Bool }` (`Identifiable`); `AppStore.qaRetestList() -> [RetestItem]`.
  - `AppStore.qaRecentBugs(limit: Int = 10) -> [BugReport]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/QADashboardTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter QADashboardTests`
Expected: build FAIL (`qaPipeline` etc. not defined).

- [ ] **Step 3: Implement**

Create `Sources/FocusCore/AppStore+QADashboard.swift`:

```swift
import Foundation

public struct QAPipelineRow: Identifiable, Equatable, Sendable {
    public var environment: DeploymentEnvironment
    public var ready = 0
    public var testing = 0
    public var failed = 0
    public var verified = 0

    public var id: DeploymentEnvironment { environment }
}

public struct QAPipeline: Equatable, Sendable {
    public var rows: [QAPipelineRow]
    /// Tickets already deployed to Live.
    public var liveCount: Int
}

public struct QAProgress: Equatable, Sendable {
    public var passed = 0
    public var failed = 0
    public var verified = 0
}

/// A ticket whose latest QA verdict for its environment is a failure.
public struct RetestItem: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var failedCases: Int
    public var failedAt: Date
    /// The ticket was deployed again after it failed, so it is ready to retest.
    public var redeployed: Bool

    public var id: UUID { ticket.id }
}

extension AppStore {
    public func qaPipeline() -> QAPipeline {
        let rows = [DeploymentEnvironment.alpha, .alpha2, .beta].map { environment -> QAPipelineRow in
            let queue = qaQueue(environment: environment)
            return QAPipelineRow(
                environment: environment, ready: queue.ready.count, testing: queue.testing.count,
                failed: queue.failed.count, verified: queue.verified.count
            )
        }
        return QAPipeline(rows: rows, liveCount: liveArchive().reduce(0) { $0 + $1.tickets.count })
    }

    public func qaProgress(in range: DateInterval) -> QAProgress {
        let ids = Set(workspaceTickets.map(\.id))
        let results = testResults.filter { ids.contains($0.ticketID) && range.contains($0.testedAt) }
        let verdicts = testVerdicts.filter { ids.contains($0.ticketID) && range.contains($0.testedAt) }
        return QAProgress(
            passed: results.filter { $0.status == .pass }.count,
            failed: results.filter { $0.status == .fail }.count,
            verified: verdicts.filter { $0.outcome == .pass }.count
        )
    }

    /// Redeployed tickets first, then the longest-failing.
    public func qaRetestList() -> [RetestItem] {
        let items = workspaceTickets.compactMap { ticket -> RetestItem? in
            let environment = ticket.environment
            guard ticket.status != .done, ticket.github?.remoteClosed != true,
                  qaState(ticketID: ticket.id, environment: environment) == .failed else { return nil }
            let verdictTimes = testVerdicts.filter { $0.ticketID == ticket.id && $0.environment == environment && $0.outcome == .fail }.map(\.testedAt)
            let resultTimes = testResults.filter { $0.ticketID == ticket.id && $0.environment == environment && $0.status == .fail }.map(\.testedAt)
            guard let failedAt = (verdictTimes + resultTimes).max() else { return nil }
            return RetestItem(
                ticket: ticket, failedCases: qaSummary(ticketID: ticket.id, environment: environment).fail, failedAt: failedAt,
                redeployed: ticket.deployment.map { $0.movedAt > failedAt } ?? false
            )
        }
        return items.sorted { $0.redeployed != $1.redeployed ? $0.redeployed : $0.failedAt < $1.failedAt }
    }

    public func qaRecentBugs(limit: Int = 10) -> [BugReport] {
        let ids = Set(workspaceTickets.map(\.id))
        return Array(bugReports.filter { ids.contains($0.ticketID) }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter QADashboardTests`
Expected: PASS.

---

### Task 4: QA test plan

**Files:**
- Modify: `Sources/FocusCore/AppStore.swift` (`qaDayPlans` storage and persistence)
- Create: `Sources/FocusCore/AppStore+QAPlan.swift`
- Create: `Tests/FocusCoreTests/QAPlanTests.swift`

**Interfaces:**
- Consumes: Task 3 nothing; existing `qaQueue`, `qaSummary`, `capacity(for:calendarBusy:)`, `DayPlan`, `record`, `save`.
- Produces:
  - `AppStore.qaDayPlans: [DayPlan]` (`public internal(set)`).
  - `QAPlanCandidate { ticket: Ticket, state: QAState, estimateMinutes: Int }` (`Identifiable`).
  - `QAPlanner.minutesPerCase = 10`, `QAPlanner.minutesWithoutCases = 30`, `QAPlanner.estimate(totalCases:remainingCases:) -> Int`, `QAPlanner.autoPick(_:capacityMinutes:) -> [UUID]`, `QAPlanner.plannedMinutes(_:ids:) -> Int`.
  - `AppStore.qaPlanCandidates() -> [QAPlanCandidate]` (failed, testing, ready; then most recently updated), `qaPlan(for:calendar:) -> DayPlan?`, `suggestQAPlan(for:calendarBusy:calendar:) -> DayPlan?`, `ensureQAPlan(for:calendarBusy:calendar:) -> DayPlan?`, `toggleQAPlanned(_:on:calendar:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/QAPlanTests.swift`:

```swift
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

    func testSuggestFillsCapacityAndLeavesTheDevPlanAlone() {
        let (store, _) = makeStore()
        for n in 1...3 { add(store, n, cases: 3) }
        let plan = store.suggestQAPlan(for: Date(), calendarBusy: [])
        XCTAssertEqual(plan?.ticketIDs.count, 2)
        XCTAssertEqual(store.qaPlan(for: Date())?.ticketIDs, plan?.ticketIDs)
        XCTAssertTrue(store.dayPlans.isEmpty)
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
        store.ensureQAPlan(for: Date(), calendarBusy: [])
        let inPlan = Set(store.qaPlan(for: Date())?.ticketIDs ?? [])
        XCTAssertEqual(inPlan, [a.id, b.id])

        store.toggleQAPlanned(a.id, on: Date())
        XCTAssertEqual(store.qaPlan(for: Date())?.ticketIDs, [b.id])
        store.toggleQAPlanned(a.id, on: Date())
        XCTAssertEqual(Set(store.qaPlan(for: Date())?.ticketIDs ?? []), [a.id, b.id])

        let (reloaded, _) = makeStore(url: url)
        XCTAssertEqual(Set(reloaded.qaPlan(for: Date())?.ticketIDs ?? []), [a.id, b.id])
    }

    func testPlannedMinutesSumsPlannedCandidates() {
        let a = QAPlanCandidate(ticket: Ticket(title: "a"), state: .ready, estimateMinutes: 20)
        let b = QAPlanCandidate(ticket: Ticket(title: "b"), state: .ready, estimateMinutes: 30)
        XCTAssertEqual(QAPlanner.plannedMinutes([a, b], ids: [a.id]), 20)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter QAPlanTests`
Expected: build FAIL (`QAPlanner` etc. not defined).

- [ ] **Step 3: Add storage in `AppStore.swift`**

After `public private(set) var dayPlans: [DayPlan] = []` add:

```swift
    /// Kept apart from `dayPlans` so a QA plan and a Dev plan for the same day never mix.
    public internal(set) var qaDayPlans: [DayPlan] = []
```

In `Snapshot`, after `var bugReports: [BugReport]?` add `var qaDayPlans: [DayPlan]?`. In `load()`, after `bugReports = snapshot.bugReports ?? []` add `qaDayPlans = snapshot.qaDayPlans ?? []`. In `save()` change `testVerdicts: testVerdicts, bugReports: bugReports` to `testVerdicts: testVerdicts, bugReports: bugReports, qaDayPlans: qaDayPlans`.

- [ ] **Step 4: Implement the plan**

Create `Sources/FocusCore/AppStore+QAPlan.swift`:

```swift
import Foundation

public struct QAPlanCandidate: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var state: QAState
    public var estimateMinutes: Int

    public var id: UUID { ticket.id }
}

public enum QAPlanner {
    public static let minutesPerCase = 10
    public static let minutesWithoutCases = 30

    /// `remainingCases` are the cases without a passing result.
    public static func estimate(totalCases: Int, remainingCases: Int) -> Int {
        totalCases == 0 ? minutesWithoutCases : max(minutesPerCase, remainingCases * minutesPerCase)
    }

    /// Takes candidates in order until the next one would not fit; always keeps the first.
    public static func autoPick(_ candidates: [QAPlanCandidate], capacityMinutes: Int) -> [UUID] {
        var remaining = capacityMinutes
        var picked: [UUID] = []
        for candidate in candidates {
            if candidate.estimateMinutes > remaining { break }
            remaining -= candidate.estimateMinutes
            picked.append(candidate.id)
        }
        if picked.isEmpty, let first = candidates.first { return [first.id] }
        return picked
    }

    public static func plannedMinutes(_ candidates: [QAPlanCandidate], ids: Set<UUID>) -> Int {
        candidates.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.estimateMinutes }
    }
}

extension AppStore {
    /// Tickets to test: failed first, then in testing, then ready; each group newest first.
    public func qaPlanCandidates() -> [QAPlanCandidate] {
        let environments: [DeploymentEnvironment?] = [nil, .alpha, .alpha2, .beta]
        let queues = environments.map { qaQueue(environment: $0) }
        let groups: [(QAState, [Ticket])] = [
            (.failed, queues.flatMap(\.failed)), (.testing, queues.flatMap(\.testing)), (.ready, queues.flatMap(\.ready))
        ]
        var seen = Set<UUID>()
        var result: [QAPlanCandidate] = []
        for (state, tickets) in groups {
            for ticket in tickets.sorted(by: { $0.updatedAt > $1.updatedAt }) where seen.insert(ticket.id).inserted {
                let summary = qaSummary(ticketID: ticket.id, environment: ticket.environment)
                let remaining = summary.total - summary.pass - summary.skipped
                result.append(QAPlanCandidate(
                    ticket: ticket, state: state,
                    estimateMinutes: QAPlanner.estimate(totalCases: summary.total, remainingCases: remaining)
                ))
            }
        }
        return result
    }

    public func qaPlan(for day: Date, calendar: Calendar = .current) -> DayPlan? {
        qaDayPlans.first { calendar.isDate($0.day, inSameDayAs: day) }
    }

    /// Returns the day's QA plan, creating it from the candidates the first time there are any.
    @discardableResult
    public func ensureQAPlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan? {
        qaPlan(for: day, calendar: calendar) ?? suggestQAPlan(for: day, calendarBusy: calendarBusy, calendar: calendar)
    }

    @discardableResult
    public func suggestQAPlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan? {
        let candidates = qaPlanCandidates()
        guard !candidates.isEmpty else { return nil }
        let capacity = capacity(for: day, calendarBusy: calendarBusy, calendar: calendar)
        let plan = DayPlan(
            day: calendar.startOfDay(for: day),
            ticketIDs: planSettings.isWorkingDay(day, calendar: calendar)
                ? QAPlanner.autoPick(candidates, capacityMinutes: capacity.capacityMinutes) : [],
            createdAt: Date()
        )
        qaDayPlans.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        qaDayPlans.append(plan)
        save()
        return plan
    }

    public func toggleQAPlanned(_ ticketID: UUID, on day: Date, calendar: Calendar = .current) {
        if let index = qaDayPlans.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            if let position = qaDayPlans[index].ticketIDs.firstIndex(of: ticketID) {
                qaDayPlans[index].ticketIDs.remove(at: position)
                record(.dayPlan, ticket: ticket(ticketID), field: "Removed from QA plan")
            } else {
                qaDayPlans[index].ticketIDs.append(ticketID)
                record(.dayPlan, ticket: ticket(ticketID), field: "Added to QA plan")
            }
        } else {
            qaDayPlans.append(DayPlan(day: calendar.startOfDay(for: day), ticketIDs: [ticketID]))
            record(.dayPlan, ticket: ticket(ticketID), field: "Added to QA plan")
        }
        save()
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter QAPlanTests`
Expected: PASS. Then `swift test --filter "QAStoreTests|BackupTests"` to confirm persistence is unaffected: PASS.

---

### Task 5: PM dashboard queries

**Files:**
- Create: `Sources/FocusCore/AppStore+PMDashboard.swift`
- Create: `Tests/FocusCoreTests/PMDashboardTests.swift`

**Interfaces:**
- Consumes: Task 1 `Ticket.assignees`, `Ticket.remoteUpdatedAt`; existing `qaState`, `DayPlanner.dueDate(of:)` (internal), `SummarySection`, `SummaryItem`.
- Produces:
  - `SprintProgress { name: String, total: Int, done: Int, byStatus: [TicketStatus: Int], daysLeft: Int?, fraction: Double }`; `AppStore.pmSprintProgress(calendar:) -> SprintProgress?`.
  - `PMPipelineRow { environment, count, readyToPromote: Int }` (`Identifiable`); `AppStore.pmPipeline() -> [PMPipelineRow]` (Alpha, Alpha2, Beta, Live).
  - `RiskReason: Int { overdue, failedQA, stale }` with `title`; `RiskItem { ticket, reason }`; `PMDashboard.staleDays = 3`; `AppStore.pmRisks() -> [RiskItem]`.
  - `WorkloadRow { assignee, open, inFlight, estimateMinutes }` with `isUnassigned`, `WorkloadRow.unassigned = "Unassigned"`; `AppStore.pmWorkload() -> [WorkloadRow]`.
  - `AppStore.pmIncoming(limit: Int = 8) -> [Ticket]`.
  - `AppStore.pmSummarySections() -> [SummarySection]`, `pmSummaryText() -> String`, `pmSummaryHTML() -> String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/PMDashboardTests.swift`:

```swift
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

    private func sprint(_ name: String, endsInDays days: Int = 5) -> [CustomField] {
        let end = Calendar.current.date(byAdding: .day, value: days, to: Date())!
        return [CustomField(name: "Sprint", value: name, kind: .iteration, project: "Board", start: Date().addingTimeInterval(-5 * day), end: end)]
    }

    private func beta() -> [CustomField] {
        [CustomField(name: "Status", value: "Deployed to Beta", kind: .select, project: "Board")]
    }

    // MARK: Sprint progress

    func testSprintProgressCountsTheCurrentSprintIncludingDone() {
        let store = makeStore()
        add(store, 1, status: .done, fields: sprint("Sprint 12"))
        add(store, 2, status: .inProgress, fields: sprint("Sprint 12"))
        add(store, 3, status: .todo, fields: sprint("Sprint 12"))
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
        add(store, 2, status: .backlog, fields: sprint("Sprint 12"))
        let quick = add(store, 3, status: .todo, isQuickCapture: true, createdAt: Date(timeIntervalSince1970: 20))
        add(store, 4, status: .todo)
        add(store, 5, status: .done, isQuickCapture: true)

        XCTAssertEqual(store.pmIncoming().map(\.id), [quick.id, backlog.id])
        XCTAssertEqual(store.pmIncoming(limit: 1).map(\.id), [quick.id])
    }

    // MARK: Summary

    func testSummaryHasProgressInFlightAtRiskAndReadyToPromote() {
        let store = makeStore()
        add(store, 1, status: .done, fields: sprint("Sprint 12"))
        add(store, 2, status: .inProgress, fields: sprint("Sprint 12"), dueDate: Date().addingTimeInterval(-2 * day))

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
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter PMDashboardTests`
Expected: build FAIL (`pmSprintProgress` etc. not defined).

- [ ] **Step 3: Implement**

Create `Sources/FocusCore/AppStore+PMDashboard.swift`:

```swift
import Foundation

public enum PMDashboard {
    /// An in-flight ticket with no GitHub activity for this many days is stale.
    public static let staleDays = 3
}

public struct SprintProgress: Equatable, Sendable {
    public var name: String
    public var total: Int
    public var done: Int
    public var byStatus: [TicketStatus: Int]
    public var daysLeft: Int?

    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

public struct PMPipelineRow: Identifiable, Equatable, Sendable {
    public var environment: DeploymentEnvironment
    public var count: Int
    public var readyToPromote: Int

    public var id: DeploymentEnvironment { environment }
}

/// The raw value ranks the reason: lower is more urgent.
public enum RiskReason: Int, Sendable {
    case overdue, failedQA, stale

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .failedQA: "Failed QA"
        case .stale: "Stale"
        }
    }
}

public struct RiskItem: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var reason: RiskReason

    public var id: UUID { ticket.id }
}

public struct WorkloadRow: Identifiable, Equatable, Sendable {
    public static let unassigned = "Unassigned"

    public var assignee: String
    public var open: Int
    public var inFlight: Int
    public var estimateMinutes: Int

    public var id: String { assignee }
    public var isUnassigned: Bool { assignee == Self.unassigned }
}

extension AppStore {
    private var openWorkspaceTickets: [Ticket] {
        workspaceTickets.filter { $0.status != .done && $0.github?.remoteClosed != true }
    }

    // MARK: - Sprint

    /// The current sprint (the one most tickets are in), else the open milestone due first; nil with neither.
    public func pmSprintProgress(calendar: Calendar = .current) -> SprintProgress? {
        let all = workspaceTickets
        var counts: [String: Int] = [:]
        var ends: [String: Date] = [:]
        for ticket in all {
            for sprint in ticket.sprints where sprint.isCurrent(at: now) {
                counts[sprint.value, default: 0] += 1
                if let end = sprint.end { ends[sprint.value] = end }
            }
        }
        if let name = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key {
            let scope = all.filter { ticket in ticket.sprints.contains { $0.value == name && $0.isCurrent(at: now) } }
            return progress(name: name, tickets: scope, end: ends[name], calendar: calendar)
        }

        let groups = Dictionary(grouping: all.filter { $0.milestone?.isOpen == true }) { $0.milestone!.title }
        let due: (String) -> Date? = { groups[$0]?.first?.milestone?.dueOn }
        let title = groups.keys.min { lhs, rhs in
            switch (due(lhs), due(rhs)) {
            case let (l?, r?): l != r ? l < r : lhs < rhs
            case (_?, nil): true
            case (nil, _?): false
            default: lhs < rhs
            }
        }
        guard let title, let tickets = groups[title] else { return nil }
        return progress(name: title, tickets: tickets, end: due(title), calendar: calendar)
    }

    private func progress(name: String, tickets: [Ticket], end: Date?, calendar: Calendar) -> SprintProgress {
        var byStatus: [TicketStatus: Int] = [:]
        for ticket in tickets { byStatus[ticket.status, default: 0] += 1 }
        let daysLeft = end.map {
            max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: $0)).day ?? 0)
        }
        return SprintProgress(name: name, total: tickets.count, done: byStatus[.done] ?? 0, byStatus: byStatus, daysLeft: daysLeft)
    }

    // MARK: - Pipeline

    public func pmPipeline() -> [PMPipelineRow] {
        let tickets = workspaceTickets
        return DeploymentEnvironment.allCases.map { environment in
            let inEnvironment = tickets.filter { $0.environment == environment }
            let ready = environment == .live ? 0 : inEnvironment.filter { qaState(ticketID: $0.id, environment: environment) == .verified }.count
            return PMPipelineRow(environment: environment, count: inEnvironment.count, readyToPromote: ready)
        }
    }

    // MARK: - Risks

    public func pmRisks(calendar: Calendar = .current) -> [RiskItem] {
        let today = calendar.startOfDay(for: now)
        let staleBefore = now.addingTimeInterval(-Double(PMDashboard.staleDays) * 86_400)
        let items = openWorkspaceTickets.compactMap { ticket -> RiskItem? in
            let due = DayPlanner.dueDate(of: ticket)
            let milestoneDue = ticket.milestone.flatMap { $0.isOpen ? $0.dueOn : nil }
            if let date = [due, milestoneDue].compactMap({ $0 }).min(), date < today { return RiskItem(ticket: ticket, reason: .overdue) }
            if qaState(ticketID: ticket.id, environment: ticket.environment) == .failed { return RiskItem(ticket: ticket, reason: .failedQA) }
            if ticket.status.isInFlight, let updated = ticket.remoteUpdatedAt, updated < staleBefore { return RiskItem(ticket: ticket, reason: .stale) }
            return nil
        }
        return items.sorted { $0.reason != $1.reason ? $0.reason.rawValue < $1.reason.rawValue : $0.ticket.title < $1.ticket.title }
    }

    // MARK: - Workload

    /// Open GitHub tickets per assignee; a ticket with several assignees counts for each.
    public func pmWorkload() -> [WorkloadRow] {
        var rows: [String: WorkloadRow] = [:]
        for ticket in openWorkspaceTickets where ticket.github != nil {
            let logins = (ticket.assignees ?? []).isEmpty ? [WorkloadRow.unassigned] : ticket.assignees!
            for login in logins {
                var row = rows[login] ?? WorkloadRow(assignee: login, open: 0, inFlight: 0, estimateMinutes: 0)
                row.open += 1
                if ticket.status.isInFlight { row.inFlight += 1 }
                row.estimateMinutes += ticket.effectiveEstimateMinutes ?? 0
                rows[login] = row
            }
        }
        return rows.values.sorted {
            if $0.open != $1.open { return $0.open > $1.open }
            if $0.isUnassigned != $1.isUnassigned { return $1.isUnassigned }
            return $0.assignee.localizedCaseInsensitiveCompare($1.assignee) == .orderedAscending
        }
    }

    // MARK: - Incoming

    /// Backlog tickets outside any sprint, and quick captures; newest first.
    public func pmIncoming(limit: Int = 8) -> [Ticket] {
        let incoming = openWorkspaceTickets.filter { ($0.status == .backlog && $0.sprints.isEmpty) || $0.isQuickCapture == true }
        return Array(incoming.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    // MARK: - Summary

    public func pmSummarySections() -> [SummarySection] {
        func item(_ ticket: Ticket, note: String? = nil) -> SummaryItem {
            var notes = ticket.github == nil ? [] : [ticket.title]
            if let note { notes.append(note) }
            return SummaryItem(text: ticket.github?.url ?? ticket.title, isLink: ticket.github != nil, notes: notes)
        }

        var sections: [SummarySection] = []
        if let progress = pmSprintProgress() {
            var text = "\(progress.name): \(progress.done)/\(progress.total) done (\(Int((progress.fraction * 100).rounded()))%)"
            if let left = progress.daysLeft { text += ", \(left) day\(left == 1 ? "" : "s") left" }
            sections.append(SummarySection(title: "Progress", items: [SummaryItem(text: text)]))
        }
        let inFlight = openWorkspaceTickets.filter { $0.status.isInFlight }.sorted { $0.displayKey < $1.displayKey }.prefix(15)
        if !inFlight.isEmpty { sections.append(SummarySection(title: "In flight", items: inFlight.map { item($0) })) }
        let risks = pmRisks()
        if !risks.isEmpty { sections.append(SummarySection(title: "At risk", items: risks.map { item($0.ticket, note: $0.reason.title) })) }
        let promote = workspaceTickets.filter { ticket in
            guard let environment = ticket.environment, environment != .live else { return false }
            return qaState(ticketID: ticket.id, environment: environment) == .verified
        }
        if !promote.isEmpty {
            sections.append(SummarySection(title: "Ready to promote", items: promote.map { item($0, note: $0.environment?.title) }))
        }
        return sections
    }

    public func pmSummaryText() -> String {
        let heading = now.formatted(date: .complete, time: .omitted) + "\n--------\n"
        let sections = pmSummarySections()
        guard !sections.isEmpty else { return heading + "(nothing to report)" }
        return heading + sections.map { section in
            ([section.title] + section.items.flatMap { ["- \($0.text)"] + $0.notes.map { "  - \($0)" } }).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    public func pmSummaryHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let heading = "<div>\(esc(now.formatted(date: .complete, time: .omitted)))</div><div>--------</div>"
        let sections = pmSummarySections()
        guard !sections.isEmpty else { return heading + "<p>(nothing to report)</p>" }
        return heading + sections.map { section in
            let items = section.items.map { item -> String in
                let label = item.isLink && item.text.hasPrefix("https://") ? "<a href=\"\(esc(item.text))\">\(esc(item.text))</a>" : esc(item.text)
                let notes = item.notes.isEmpty ? "" : "<ul>" + item.notes.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
                return "<li>\(label)\(notes)</li>"
            }.joined()
            return "<div>\(esc(section.title))</div><ul>\(items)</ul>"
        }.joined()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PMDashboardTests`
Expected: PASS. If `testSummaryHasProgressInFlightAtRiskAndReadyToPromote` fails on `daysLeft` near midnight, rerun after the first half hour of the day (same known flake family); do not loosen the assertion.

---

### Task 6: Today switch, Dev rename and shared time log

**Files:**
- Move: `Sources/FocusTracker/TodayView.swift` to `Sources/FocusTracker/DevTodayView.swift`
- Create: `Sources/FocusTracker/TodayView.swift` (switch)
- Create: `Sources/FocusTracker/DayTimeLogSection.swift`
- Create: `Sources/FocusTracker/DashboardCards.swift`

**Interfaces:**
- Produces: `TodayView(selectedTicketID: Binding<UUID?>, filter: Binding<TicketFilter>)` (same signature RootView uses); `DayTimeLogSection(day: Date, isToday: Bool)`; `DashboardBar(segments: [DashboardBar.Segment])` with `Segment(value: Int, color: Color)`; `CapacityBar(planned: Int, capacity: Int, over: Bool)`; `TicketListCard(tickets:selectedTicketID:trailing:)`; `timeGreeting(_ date: Date) -> String`; `View.todaySheet(_: Binding<TodaySheet?>)`. Task 7 and 8 consume these.

- [ ] **Step 1: Move the file**

Run: `git mv Sources/FocusTracker/TodayView.swift Sources/FocusTracker/DevTodayView.swift`

- [ ] **Step 2: Rename the struct**

In `DevTodayView.swift` change `struct TodayView: View {` to `struct DevTodayView: View {`.

- [ ] **Step 3: Extract the time log**

Create `Sources/FocusTracker/DayTimeLogSection.swift`:

```swift
import FocusCore
import SwiftUI

/// The day's time entries, notes and activities, with edit and delete.
struct DayTimeLogSection: View {
    @Environment(AppStore.self) private var store
    let day: Date
    let isToday: Bool
    @State private var editing: LogEdit?

    var body: some View {
        let range = store.dayRange(for: day)
        let log = store.log(in: range)

        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Time log", count: log.count)
            if log.isEmpty {
                EmptyHint(text: isToday ? "No time tracked yet." : "No time tracked on this day.", symbol: "clock")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(log.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        logRow(item, range: range)
                    }
                }
                .cardStyle(padding: 0)
            }
        }
        .sheet(item: $editing) { EditLogSheet(target: $0) }
    }

    @ViewBuilder
    private func logRow(_ item: LogItem, range: DateInterval) -> some View {
        switch item {
        case .time(let entry):
            if let ticket = store.ticket(entry.ticketID) { timeRow(entry: entry, ticket: ticket, range: range) }
        case .note(let note):
            if let ticket = store.ticket(note.ticketID) {
                NoteRow(note: note, ticketTitle: ticket.title) { store.deleteNote(note.id) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        case .activity(let activity):
            ActivityRow(activity: activity, range: range) { editing = .activity(activity) }
        }
    }

    private func timeRow(entry: TimeEntry, ticket: Ticket, range: DateInterval) -> some View {
        let end = entry.end?.formatted(date: .omitted, time: .shortened) ?? "now"
        return HStack(spacing: 10) {
            Circle().fill(ticket.status.color).frame(width: 8, height: 8)
            Text(ticket.title).lineLimit(1)
            Spacer()
            Text("\(entry.start.formatted(date: .omitted, time: .shortened)) – \(end)")
                .foregroundStyle(.secondary)
            Text(Format.short(entry.duration(in: range, at: store.now)))
                .font(.callout.weight(.medium).monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            Button { editing = .entry(entry) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit")
            DeleteButton(title: "Delete this time entry?") { store.deleteEntry(entry.id) }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
```

In `DevTodayView.swift`:

1. Remove the state line `@State private var editing: LogEdit?`.
2. In `body`, remove `let log = store.log(in: range)`.
3. Replace the whole block

```swift
                if !isFuture {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Time log", count: log.count)
                        ...
                    }
                }
```

(the one that ends right before `.padding(24)`) with:

```swift
                if !isFuture { DayTimeLogSection(day: day, isToday: isToday) }
```

4. Remove `.sheet(item: $editing) { EditLogSheet(target: $0) }` after the `.sheet(item: $sheet) { ... }` block.
5. Delete the private functions `logRow(_:range:)` and `timeRow(entry:ticket:range:)` at the bottom of the struct.

- [ ] **Step 4: Create the shared cards**

Create `Sources/FocusTracker/DashboardCards.swift`:

```swift
import FocusCore
import SwiftUI

func timeGreeting(_ date: Date) -> String {
    switch Calendar.current.component(.hour, from: date) {
    case 5..<12: "Good morning"
    case 12..<18: "Good afternoon"
    default: "Good evening"
    }
}

/// A single stacked bar; segments with no value are skipped.
struct DashboardBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        var value: Int
        var color: Color
    }

    let segments: [Segment]

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.value }, 1)
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments.filter { $0.value > 0 }) { segment in
                    Rectangle().fill(segment.color).frame(width: proxy.size.width * CGFloat(segment.value) / CGFloat(total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.08))
        .clipShape(Capsule())
    }
}

struct CapacityBar: View {
    let planned: Int
    let capacity: Int
    let over: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = min(Double(planned) / Double(max(capacity, 1)), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(over ? Theme.warningGradient : Theme.accentGradient)
                    .frame(width: planned > 0 ? max(8, proxy.size.width * fraction) : 0)
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: planned)
        .accessibilityElement()
        .accessibilityLabel("Planned \(Format.short(TimeInterval(planned * 60))) of \(Format.short(TimeInterval(capacity * 60))) capacity")
    }
}

/// A card of ticket rows; tapping a row selects the ticket.
struct TicketListCard<Trailing: View>: View {
    let tickets: [Ticket]
    @Binding var selectedTicketID: UUID?
    let trailing: (Ticket) -> Trailing

    init(tickets: [Ticket], selectedTicketID: Binding<UUID?>, @ViewBuilder trailing: @escaping (Ticket) -> Trailing) {
        self.tickets = tickets
        _selectedTicketID = selectedTicketID
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tickets.enumerated()), id: \.element.id) { index, ticket in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    Image(systemName: ticket.status.symbol).foregroundStyle(ticket.status.color).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticket.title).lineLimit(1)
                        Text(ticket.displayKey).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    trailing(ticket)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { selectedTicketID = ticket.id }
            }
        }
        .cardStyle(padding: 0)
    }
}

extension View {
    /// The sheets the Today header opens: add an activity, import calendar events, log an unplanned item.
    func todaySheet(_ sheet: Binding<TodaySheet?>) -> some View {
        self.sheet(item: sheet) { value in
            switch value {
            case .add(let choice): AddActivitySheet(choice: choice)
            case .calendar: CalendarImportSheet()
            case .unplanned: QuickCaptureSheet()
            }
        }
    }
}
```

- [ ] **Step 5: Create the switch**

Create `Sources/FocusTracker/TodayView.swift`:

```swift
import FocusCore
import SwiftUI

/// Today differs by role; Dev keeps the original page.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @Binding var filter: TicketFilter

    var body: some View {
        switch store.role {
        case .dev: DevTodayView(selectedTicketID: $selectedTicketID, filter: $filter)
        case .qa: QATodayView(selectedTicketID: $selectedTicketID)
        case .pm: PMTodayView(selectedTicketID: $selectedTicketID)
        }
    }
}
```

`QATodayView` and `PMTodayView` do not exist yet: create temporary placeholders so the build stays green, and replace them in Tasks 7 and 8. Create `Sources/FocusTracker/QATodayView.swift`:

```swift
import SwiftUI

struct QATodayView: View {
    @Binding var selectedTicketID: UUID?

    var body: some View { Text("QA") }
}
```

and `Sources/FocusTracker/PMTodayView.swift`:

```swift
import SwiftUI

struct PMTodayView: View {
    @Binding var selectedTicketID: UUID?

    var body: some View { Text("PM") }
}
```

- [ ] **Step 6: Build and run the suite**

Run: `swift build`
Expected: build succeeds (the Dev page compiles with the extracted section).
Run: `swift test`
Expected: all pass.

---

### Task 7: QA dashboard views

**Files:**
- Modify (replace placeholder): `Sources/FocusTracker/QATodayView.swift`
- Create: `Sources/FocusTracker/QATestPlanCard.swift`

**Interfaces:**
- Consumes: Task 3 and 4 store APIs; Task 6 `timeGreeting`, `CapacityBar`, `TicketListCard`, `DayTimeLogSection`, `todaySheet`.
- Produces: `QATodayView(selectedTicketID:)`, `QATestPlanCard(selectedTicketID:)`.

- [ ] **Step 1: Create the test plan card**

Create `Sources/FocusTracker/QATestPlanCard.swift`:

```swift
import FocusCore
import SwiftUI

struct QATestPlanCard: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var calendarBusy: [DateInterval] = []
    @State private var calendarNote: String?

    // Declared so the card re-renders when a plan setting changes in Settings.
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.workDays) private var workDays = 5

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    var body: some View {
        let day = store.now
        let candidates = store.qaPlanCandidates()
        let plannedIDs = Set(store.qaPlan(for: day)?.ticketIDs ?? [])
        let capacity = store.capacity(for: day, calendarBusy: calendarBusy)
        let planned = QAPlanner.plannedMinutes(candidates, ids: plannedIDs)
        let over = planned > capacity.capacityMinutes
        let workingDay = store.planSettings.isWorkingDay(day)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Test plan", count: candidates.filter { plannedIDs.contains($0.id) }.count)
                Spacer()
                Button("Re-suggest") { store.suggestQAPlan(for: day, calendarBusy: calendarBusy) }
                    .buttonStyle(.secondary)
                    .disabled(candidates.isEmpty || !workingDay)
                    .help("Rebuild the plan from the tickets waiting for QA")
            }

            VStack(alignment: .leading, spacing: 6) {
                CapacityBar(planned: planned, capacity: capacity.capacityMinutes, over: over)
                HStack {
                    Text("Planned \(text(planned)) of \(text(capacity.capacityMinutes)) capacity")
                        .foregroundStyle(over ? Theme.warning : Color.primary)
                    Spacer()
                    Text("\(text(capacity.freeMinutes)) free after meetings").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                if over {
                    Label("Over capacity by \(text(planned - capacity.capacityMinutes))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                if !workingDay {
                    Text("Not a working day. Change this in Settings → Working days.").font(.caption).foregroundStyle(.secondary)
                }
                if let calendarNote { Text(calendarNote).font(.caption).foregroundStyle(.secondary) }
            }

            if candidates.isEmpty {
                EmptyHint(text: "Nothing waiting for QA.", symbol: "checklist")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { Divider() }
                        row(candidate, planned: plannedIDs.contains(candidate.id), day: day)
                    }
                }
                .cardStyle(padding: 0)
            }
        }
        .task(id: "\(candidates.isEmpty)|\(Calendar.current.startOfDay(for: day))") { await loadCalendarAndPlan(day: day) }
    }

    private func row(_ candidate: QAPlanCandidate, planned: Bool, day: Date) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { planned }, set: { _ in store.toggleQAPlanned(candidate.id, on: day) }))
                .labelsHidden()
                .toggleStyle(RoundCheckStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.ticket.title).lineLimit(1)
                Text(candidate.ticket.displayKey).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: candidate.state.title, color: candidate.state.color)
            if let environment = candidate.ticket.environment { Chip(text: environment.title, color: environment.color) }
            Text("~\(text(candidate.estimateMinutes))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { selectedTicketID = candidate.id }
    }

    private func loadCalendarAndPlan(day: Date) async {
        do {
            calendarBusy = try await CalendarService().busyIntervals(on: day)
            calendarNote = nil
        } catch {
            calendarBusy = []
            calendarNote = "Calendar unavailable, so meetings are not subtracted. \(error.localizedDescription)"
        }
        store.ensureQAPlan(for: day, calendarBusy: calendarBusy)
    }
}
```

- [ ] **Step 2: Replace the QA placeholder**

Overwrite `Sources/FocusTracker/QATodayView.swift`:

```swift
import FocusCore
import SwiftUI

struct QATodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var sheet: TodaySheet?

    var body: some View {
        let range = store.dayRange(for: store.now)
        let progress = store.qaProgress(in: range)
        let pipeline = store.qaPipeline()
        let retest = store.qaRetestList()
        let retestByID = Dictionary(uniqueKeysWithValues: retest.map { ($0.id, $0) })
        let bugs = store.qaRecentBugs()

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: timeGreeting(store.now), subtitle: store.now.formatted(date: .complete, time: .omitted))
                    Spacer()
                    HStack(spacing: 10) {
                        Button { sheet = .unplanned } label: { Label("Unplanned", systemImage: "bolt.fill") }
                            .buttonStyle(.secondary)
                            .controlSize(.large)
                            .help("Log a bug or request that wasn't planned and start its timer")
                        AddToTodayMenu(sheet: $sheet)
                    }
                }

                SyncIssuesCard(selectedTicketID: $selectedTicketID)

                HStack(spacing: 14) {
                    StatCard(title: "Tracked today", value: Format.short(store.trackedTime(in: range)), symbol: "timer", tint: Theme.accent)
                    StatCard(title: "Cases passed", value: "\(progress.passed)", symbol: "checkmark.circle.fill", tint: Theme.success)
                    StatCard(title: "Cases failed", value: "\(progress.failed)", symbol: "xmark.circle.fill", tint: Theme.danger)
                    StatCard(title: "Verified", value: "\(progress.verified)", symbol: "checkmark.seal.fill", tint: Theme.teal)
                }

                QATestPlanCard(selectedTicketID: $selectedTicketID)

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Test pipeline")
                    pipelineCard(pipeline)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Failed & retest", count: retest.count)
                    if retest.isEmpty {
                        EmptyHint(text: "No failed tickets waiting for a retest.", symbol: "checkmark.circle")
                    } else {
                        TicketListCard(tickets: retest.map(\.ticket), selectedTicketID: $selectedTicketID) { ticket in
                            if let item = retestByID[ticket.id] {
                                HStack(spacing: 6) {
                                    if item.redeployed { Chip(text: "Redeployed", color: Theme.info) }
                                    Chip(text: "\(item.failedCases) failed", color: Theme.danger)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Bugs reported", count: bugs.count)
                    if bugs.isEmpty {
                        EmptyHint(text: "No bugs reported yet.", symbol: "ladybug")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(bugs.enumerated()), id: \.element.id) { index, bug in
                                if index > 0 { Divider() }
                                bugRow(bug)
                            }
                        }
                        .cardStyle(padding: 0)
                    }
                }

                DayTimeLogSection(day: store.now, isToday: true)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        .todaySheet($sheet)
    }

    private func pipelineCard(_ pipeline: QAPipeline) -> some View {
        VStack(spacing: 0) {
            ForEach(pipeline.rows) { row in
                HStack(spacing: 8) {
                    Text(row.environment.title).font(.callout.weight(.semibold)).frame(width: 70, alignment: .leading)
                    Chip(text: "Ready \(row.ready)", color: row.ready > 0 ? Theme.info : Theme.slate)
                    Chip(text: "Testing \(row.testing)", color: row.testing > 0 ? Theme.warning : Theme.slate)
                    Chip(text: "Failed \(row.failed)", color: row.failed > 0 ? Theme.danger : Theme.slate)
                    Chip(text: "Verified \(row.verified)", color: row.verified > 0 ? Theme.success : Theme.slate)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }
            HStack(spacing: 8) {
                Text("Live").font(.callout.weight(.semibold)).frame(width: 70, alignment: .leading)
                Text("\(pipeline.liveCount) released").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .cardStyle(padding: 0)
    }

    private func bugRow(_ bug: BugReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "ladybug.fill").foregroundStyle(Theme.danger).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(bug.title).lineLimit(1)
                Text(store.ticket(bug.ticketID)?.displayKey ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: bug.severity.title, color: Theme.warning)
            switch bug.state {
            case .draft: Chip(text: "Draft", color: Theme.slate)
            case .created: Chip(text: "Created", color: Theme.success)
            case .failed: Chip(text: "Failed to create", color: Theme.danger)
            }
            if let urlString = bug.issueURL, let url = URL(string: urlString), url.scheme == "https" {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open the issue on GitHub")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { selectedTicketID = bug.ticketID }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds. `QAState.title` / `QAState.color` and `DeploymentEnvironment.color` are existing extensions in `QAQueueView.swift` and `Theme.swift`. If the build reports an ambiguous or missing member, fix at the call site; do not change those extensions.

---

### Task 8: PM dashboard view

**Files:**
- Modify (replace placeholder): `Sources/FocusTracker/PMTodayView.swift`

**Interfaces:**
- Consumes: Task 2 `store.syncsTeamIssues`; Task 5 store APIs; Task 6 `timeGreeting`, `DashboardBar`, `TicketListCard`, `todaySheet`.
- Produces: `PMTodayView(selectedTicketID:)`.

- [ ] **Step 1: Replace the PM placeholder**

Overwrite `Sources/FocusTracker/PMTodayView.swift`:

```swift
import AppKit
import FocusCore
import SwiftUI

struct PMTodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var sheet: TodaySheet?
    @State private var copied = false

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.pmSummaryText(), forType: .string)
        NSPasteboard.general.setString(store.pmSummaryHTML(), forType: .html)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    var body: some View {
        let progress = store.pmSprintProgress()
        let pipeline = store.pmPipeline()
        let risks = store.pmRisks()
        let riskByID = Dictionary(uniqueKeysWithValues: risks.map { ($0.id, $0) })
        let workload = store.pmWorkload()
        let incoming = store.pmIncoming()

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: timeGreeting(store.now), subtitle: store.now.formatted(date: .complete, time: .omitted))
                    Spacer()
                    HStack(spacing: 10) {
                        Button(action: copySummary) {
                            Label(copied ? "Copied" : "Copy status summary", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                        }
                        .buttonStyle(.secondary)
                        .controlSize(.large)
                        .help("Copy a status summary for the team")
                        Button { sheet = .unplanned } label: { Label("Request", systemImage: "bubble.left.fill") }
                            .buttonStyle(.secondary)
                            .controlSize(.large)
                            .help("Log a request that wasn't planned")
                    }
                }

                SyncIssuesCard(selectedTicketID: $selectedTicketID)

                if !store.syncsTeamIssues {
                    EmptyHint(
                        text: "Add repositories in Settings → GitHub to sync the whole team's issues. Until then these cards show only your own tickets.",
                        symbol: "person.2"
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Sprint progress")
                    sprintCard(progress)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Release pipeline")
                    pipelineCard(pipeline)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Blocked & at risk", count: risks.count)
                    if risks.isEmpty {
                        EmptyHint(text: "Nothing overdue, failed or stale.", symbol: "checkmark.circle")
                    } else {
                        TicketListCard(tickets: risks.map(\.ticket), selectedTicketID: $selectedTicketID) { ticket in
                            if let risk = riskByID[ticket.id] { Chip(text: risk.reason.title, color: risk.reason.color) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Workload", count: workload.count)
                    if workload.isEmpty {
                        EmptyHint(text: "No open tickets.", symbol: "person.2")
                    } else {
                        let maxOpen = workload.map(\.open).max() ?? 1
                        VStack(spacing: 0) {
                            ForEach(Array(workload.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider() }
                                workloadRow(row, maxOpen: maxOpen)
                            }
                        }
                        .cardStyle(padding: 0)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Incoming requests", count: incoming.count)
                    if incoming.isEmpty {
                        EmptyHint(text: "No new requests to triage.", symbol: "tray")
                    } else {
                        TicketListCard(tickets: incoming, selectedTicketID: $selectedTicketID) { ticket in
                            if ticket.isQuickCapture == true { Chip(text: "Quick capture", color: Theme.info) }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        .todaySheet($sheet)
    }

    @ViewBuilder
    private func sprintCard(_ progress: SprintProgress?) -> some View {
        if let progress {
            let order: [TicketStatus] = [.done, .testing, .inReview, .inProgress, .todo, .backlog]
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(progress.name).font(.headline)
                    Spacer()
                    if let left = progress.daysLeft {
                        Text("\(left) day\(left == 1 ? "" : "s") left").font(.callout).foregroundStyle(.secondary)
                    }
                }
                DashboardBar(segments: order.map { .init(value: progress.byStatus[$0] ?? 0, color: $0.color) })
                HStack {
                    Text("\(progress.done) of \(progress.total) done").font(.callout.monospacedDigit())
                    Spacer()
                    Text(progress.fraction.formatted(.percent.precision(.fractionLength(0)))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                FlowLayout {
                    ForEach(order.filter { (progress.byStatus[$0] ?? 0) > 0 }) { status in
                        Chip(text: "\(status.title) \(progress.byStatus[status] ?? 0)", color: status.color)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        } else {
            EmptyHint(text: "No current sprint or open milestone with tickets.", symbol: "flag")
        }
    }

    private func pipelineCard(_ rows: [PMPipelineRow]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                VStack(spacing: 4) {
                    Text(row.environment.title).font(.callout.weight(.semibold)).foregroundStyle(row.environment.color)
                    Text("\(row.count)").font(.title.weight(.semibold).monospacedDigit())
                    Text(row.environment == .live ? "released" : "\(row.readyToPromote) ready to promote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .cardStyle(padding: 0)
    }

    private func workloadRow(_ row: WorkloadRow, maxOpen: Int) -> some View {
        HStack(spacing: 12) {
            Text(row.assignee)
                .lineLimit(1)
                .foregroundStyle(row.isUnassigned ? Color.secondary : Color.primary)
                .frame(width: 130, alignment: .leading)
            GeometryReader { proxy in
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: max(8, proxy.size.width * CGFloat(row.open) / CGFloat(max(maxOpen, 1))))
            }
            .frame(height: 8)
            Text("\(row.open) open").font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
            Text("\(row.inFlight) in flight").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
            Text(row.estimateMinutes > 0 ? Format.short(TimeInterval(row.estimateMinutes * 60)) : "–")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private extension RiskReason {
    var color: Color {
        switch self {
        case .overdue: Theme.danger
        case .failedQA: Theme.orange
        case .stale: Theme.warning
        }
    }
}
```

The Request button reuses `QuickCaptureSheet`, which already defaults its type to Request for PM.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds. `.init(value:color:)` in `DashboardBar(segments:)` infers `DashboardBar.Segment`; if inference fails, write `DashboardBar.Segment(value:color:)` explicitly.

---

### Task 9: Full verification

**Files:** none modified unless a check fails.

- [ ] **Step 1: Run the full suite**

Run: `swift test`
Expected: all tests pass (the known midnight-window `ActivityTests` flake aside).

- [ ] **Step 2: Build the app target**

Run: `swift build`
Expected: succeeds with no new warnings in the files changed by this plan. Check with `get_errors` on `Sources/FocusTracker` and `Sources/FocusCore`.

- [ ] **Step 3: Check Dev is untouched**

Run: `git diff --stat -M HEAD -- Sources/FocusTracker/DevTodayView.swift Sources/FocusTracker/TodayView.swift`
Expected: `DevTodayView.swift` shows as a rename of `TodayView.swift` whose only changes are the struct name, the removed `editing` state, the removed `let log`, the `DayTimeLogSection` call, and the deleted `logRow` / `timeRow` helpers.

- [ ] **Step 4: Report**

Tell the user: the dashboards are built and verified by build and tests only; the app was not launched because it uses the real `data.json` and token. Suggest they switch roles in Settings → GitHub to review each dashboard, and that PM needs repositories set there for team-wide data. Remind them the work is uncommitted.

---

## Self-Review

**Spec coverage:** assignees and `remoteUpdatedAt` (Task 1); PM team sync, fallback and role-change sync (Task 2); QA pipeline, progress, retest, bugs (Task 3); QA plan, separate storage, estimates, suggest and toggle (Task 4); PM sprint, pipeline, risks, workload, incoming, summary (Task 5); switch, Dev rename, shared time log (Task 6); QA and PM views including the assigned-only notice (Tasks 7, 8); verification (Task 9). The spec's "Stat cards: tracked today, cases passed/failed, verified" is in `QATodayView`.

**Placeholders:** none except the deliberate temporary view placeholders in Task 6, replaced in Tasks 7 and 8. Task 5 Step 1 has one conditional instruction to confirm two setter names; it states the fallback concretely.

**Type consistency:** `QAPlanCandidate`, `QAPlanner`, `qaPlan(for:)`, `ensureQAPlan`, `suggestQAPlan`, `toggleQAPlanned` match between Tasks 4 and 7. `RetestItem.id`, `QAPipeline.rows`, `PMPipelineRow.readyToPromote`, `WorkloadRow.isUnassigned`, `RiskReason.title` match between Tasks 3, 5, 7, 8. `DashboardBar.Segment`, `CapacityBar`, `TicketListCard`, `todaySheet`, `timeGreeting` are defined in Task 6 and used in Tasks 7 and 8.
