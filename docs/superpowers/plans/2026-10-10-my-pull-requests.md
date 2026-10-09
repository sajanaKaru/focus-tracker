# My Pull Requests Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Pull Requests" sidebar tab listing the open PRs I authored, grouped by what needs attention, with review, CI and conflict chips.

**Architecture:** A pure model and grouping layer in `FocusCore`, one GraphQL query in `GitHubClient`, an in-memory list plus load state in `AppStore` refreshed with the GitHub sync, and one SwiftUI view. Read-only; nothing is written to GitHub.

**Tech Stack:** Swift 5.9, SwiftUI, Observation, XCTest, GitHub GraphQL API. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-10-my-pull-requests-design.md`

## Global Constraints

- Platform: macOS 14+, Swift tools 5.9, no new package dependencies.
- Read-only: no GitHub writes; the pull request list is in memory only and never written to `data.json`.
- PR list = `is:pr is:open author:<login> archived:false sort:updated-desc`, first 100 results.
- Repo filter reuses `PrefKey.repos` (case-insensitive `owner/name`); empty means all repos.
- A pull request failure must never change `syncState` or the ticket sync.
- Unknown GitHub enum values map to the neutral case: review `waiting`, CI `noChecks`.
- Group evaluation order, first match wins: draft, needs action (changes requested, failing CI or conflicts), approved, otherwise waiting. Display order: needsAction, waiting, approved, drafts. Sorting: `updatedAt` descending, except `waiting` which is ascending.
- Tests are XCTest in `Tests/FocusCoreTests`; store tests are `@MainActor` and use a temp store URL and a throwaway `UserDefaults` suite.
- Comments: one short line, only for what the code cannot show.
- Shell note: `rm` is aliased to `npm run rm` in this terminal; use `command rm`.
- Run tests with `swift test` from `/Volumes/Dev/My Projects/focus-tracker`.

---

## File Structure

- Create `Sources/FocusCore/PullRequests.swift`: `ReviewState`, `CIState`, `PullRequestGroup`, `PullRequestItem`, `PullRequestSection`.
- Modify `Sources/FocusCore/GitHubClient.swift`: `fetchOpenPullRequests(authoredBy:)` and its DTOs.
- Modify `Sources/FocusCore/AppStore.swift`: `PullRequestsState`, list, refresh methods, shared `configuredRepos`, sync hook.
- Create `Sources/FocusTracker/PullRequestsView.swift`: the tab.
- Modify `Sources/FocusTracker/RootView.swift`: sidebar item and routing.
- Modify `README.md`: one note on token access.
- Create `Tests/FocusCoreTests/PullRequestModelTests.swift`, `PullRequestClientTests.swift`, `PullRequestStoreTests.swift`.

---

### Task 1: Pull request model and grouping

**Files:**
- Create: `Sources/FocusCore/PullRequests.swift`
- Test: `Tests/FocusCoreTests/PullRequestModelTests.swift` (create)

**Interfaces:**
- Produces:
  - `ReviewState { approved, changesRequested, waiting }` with `init(decision: String?)`
  - `CIState { passing, failing, pending, noChecks }` with `init(rollup: String?)`
  - `PullRequestGroup: Int, CaseIterable { needsAction, waiting, approved, drafts }` with `title: String`
  - `PullRequestItem` (`repo`, `number`, `title`, `url`, `isDraft`, `review`, `ci`, `hasConflicts`, `createdAt`, `updatedAt`, `id: String`, `group: PullRequestGroup`) with `init(repo:number:title:url:isDraft:review:ci:hasConflicts:createdAt:updatedAt:)`; `isDraft`, `review`, `ci` and `hasConflicts` default to false / `.waiting` / `.noChecks` / false
  - `PullRequestSection { group, items, id }` with `static func make(from: [PullRequestItem]) -> [PullRequestSection]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/PullRequestModelTests.swift`:

```swift
import XCTest
@testable import FocusCore

final class PullRequestModelTests: XCTestCase {
    private func pr(
        _ number: Int, draft: Bool = false, review: ReviewState = .waiting, ci: CIState = .noChecks,
        conflicts: Bool = false, updated: Double = 0
    ) -> PullRequestItem {
        PullRequestItem(
            repo: "me/a", number: number, title: "PR \(number)", url: "https://github.com/me/a/pull/\(number)",
            isDraft: draft, review: review, ci: ci, hasConflicts: conflicts,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    func testReviewDecisionMapping() {
        XCTAssertEqual(ReviewState(decision: "APPROVED"), .approved)
        XCTAssertEqual(ReviewState(decision: "CHANGES_REQUESTED"), .changesRequested)
        XCTAssertEqual(ReviewState(decision: "REVIEW_REQUIRED"), .waiting)
        XCTAssertEqual(ReviewState(decision: nil), .waiting)
        XCTAssertEqual(ReviewState(decision: "SOMETHING_NEW"), .waiting)
    }

    func testCIStateMapping() {
        XCTAssertEqual(CIState(rollup: "SUCCESS"), .passing)
        XCTAssertEqual(CIState(rollup: "FAILURE"), .failing)
        XCTAssertEqual(CIState(rollup: "ERROR"), .failing)
        XCTAssertEqual(CIState(rollup: "PENDING"), .pending)
        XCTAssertEqual(CIState(rollup: "EXPECTED"), .pending)
        XCTAssertEqual(CIState(rollup: nil), .noChecks)
        XCTAssertEqual(CIState(rollup: "WEIRD"), .noChecks)
    }

    func testGroupPrecedence() {
        XCTAssertEqual(pr(1, draft: true, ci: .failing).group, .drafts)
        XCTAssertEqual(pr(2, review: .changesRequested).group, .needsAction)
        XCTAssertEqual(pr(3, review: .approved, ci: .failing).group, .needsAction)
        XCTAssertEqual(pr(4, review: .approved, conflicts: true).group, .needsAction)
        XCTAssertEqual(pr(5, review: .approved, ci: .passing).group, .approved)
        XCTAssertEqual(pr(6, ci: .pending).group, .waiting)
        XCTAssertEqual(pr(7).group, .waiting)
    }

    func testSectionsAreOrderedSortedAndSkipEmptyGroups() {
        let items = [
            pr(1, updated: 10), pr(2, updated: 30), pr(3, updated: 20),
            pr(4, review: .approved, updated: 5), pr(5, review: .approved, updated: 9),
            pr(6, draft: true, updated: 1),
        ]
        let sections = PullRequestSection.make(from: items)

        XCTAssertEqual(sections.map(\.group), [.waiting, .approved, .drafts])
        XCTAssertEqual(sections[0].items.map(\.number), [1, 3, 2], "waiting: oldest activity first")
        XCTAssertEqual(sections[1].items.map(\.number), [5, 4], "others: newest activity first")
        XCTAssertEqual(PullRequestSection.make(from: []).count, 0)
    }

    func testNeedsActionComesFirst() {
        let sections = PullRequestSection.make(from: [pr(1), pr(2, review: .changesRequested)])
        XCTAssertEqual(sections.map(\.group), [.needsAction, .waiting])
    }

    func testIdentityIsCaseInsensitiveOnTheRepo() {
        XCTAssertEqual(pr(9).id, "me/a#9")
        var other = pr(9)
        other.repo = "ME/A"
        XCTAssertEqual(other.id, "me/a#9")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PullRequestModelTests`
Expected: build FAIL with "cannot find 'ReviewState' in scope".

- [ ] **Step 3: Implement**

Create `Sources/FocusCore/PullRequests.swift`:

```swift
import Foundation

public enum ReviewState: Equatable, Sendable {
    case approved, changesRequested, waiting

    /// From GitHub's `reviewDecision`; no decision or an unknown value counts as waiting.
    public init(decision: String?) {
        switch decision {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        default: self = .waiting
        }
    }
}

public enum CIState: Equatable, Sendable {
    case passing, failing, pending, noChecks

    /// From the state of the last commit's `statusCheckRollup`.
    public init(rollup: String?) {
        switch rollup {
        case "SUCCESS": self = .passing
        case "FAILURE", "ERROR": self = .failing
        case "PENDING", "EXPECTED": self = .pending
        default: self = .noChecks
        }
    }
}

/// Raw values are the display order.
public enum PullRequestGroup: Int, CaseIterable, Sendable {
    case needsAction, waiting, approved, drafts

    public var title: String {
        switch self {
        case .needsAction: "Needs action"
        case .waiting: "Waiting for review"
        case .approved: "Approved"
        case .drafts: "Drafts"
        }
    }
}

public struct PullRequestItem: Identifiable, Equatable, Sendable {
    public var repo: String
    public var number: Int
    public var title: String
    public var url: String
    public var isDraft: Bool
    public var review: ReviewState
    public var ci: CIState
    public var hasConflicts: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { "\(repo.lowercased())#\(number)" }

    public var group: PullRequestGroup {
        if isDraft { return .drafts }
        if review == .changesRequested || ci == .failing || hasConflicts { return .needsAction }
        if review == .approved { return .approved }
        return .waiting
    }

    public init(
        repo: String, number: Int, title: String, url: String, isDraft: Bool = false,
        review: ReviewState = .waiting, ci: CIState = .noChecks, hasConflicts: Bool = false,
        createdAt: Date, updatedAt: Date
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.review = review
        self.ci = ci
        self.hasConflicts = hasConflicts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PullRequestSection: Identifiable, Equatable, Sendable {
    public var group: PullRequestGroup
    public var items: [PullRequestItem]

    public var id: Int { group.rawValue }

    /// Non-empty groups in display order; waiting shows the stalest first, the rest the most recent first.
    public static func make(from items: [PullRequestItem]) -> [PullRequestSection] {
        PullRequestGroup.allCases.compactMap { group in
            let members = items.filter { $0.group == group }
            guard !members.isEmpty else { return nil }
            let sorted = group == .waiting
                ? members.sorted { $0.updatedAt < $1.updatedAt }
                : members.sorted { $0.updatedAt > $1.updatedAt }
            return PullRequestSection(group: group, items: sorted)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PullRequestModelTests`
Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/PullRequests.swift Tests/FocusCoreTests/PullRequestModelTests.swift
git commit -m "feat: add pull request model with grouping and sorting"
```

---

### Task 2: GraphQL fetch of my open pull requests

**Files:**
- Modify: `Sources/FocusCore/GitHubClient.swift` (new method inside `GitHubClient`, DTOs at the end of the file)
- Test: `Tests/FocusCoreTests/PullRequestClientTests.swift` (create)

**Interfaces:**
- Consumes: Task 1 types; existing private `GitHubClient.graphQL(_:variables:)`, `GitHubError.graphQL`, `GitHubError.invalidResponse`.
- Produces: `GitHubClient.fetchOpenPullRequests(authoredBy login: String) async throws -> (items: [PullRequestItem], total: Int)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/PullRequestClientTests.swift`:

```swift
import XCTest
@testable import FocusCore

private struct BodyTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (Data(handler(request).utf8), response)
    }
}

final class PullRequestClientTests: XCTestCase {
    private let sample = """
    {"data":{"search":{"issueCount":2,"nodes":[
      {"number":12,"title":"Add login","url":"https://github.com/me/a/pull/12","isDraft":false,
       "createdAt":"2026-10-01T08:00:00Z","updatedAt":"2026-10-08T09:30:00Z",
       "reviewDecision":"CHANGES_REQUESTED","mergeable":"CONFLICTING",
       "repository":{"nameWithOwner":"me/a"},
       "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
      {"number":7,"title":"Draft thing","url":"https://github.com/me/b/pull/7","isDraft":true,
       "createdAt":"2026-10-05T08:00:00Z","updatedAt":"2026-10-05T08:00:00Z",
       "reviewDecision":null,"mergeable":"UNKNOWN",
       "repository":{"nameWithOwner":"me/b"},
       "commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}},
      {}, null
    ]}}}
    """

    func testParsesPullRequestsAndSkipsEmptyNodes() async throws {
        let client = GitHubClient(token: "t", transport: BodyTransport { _ in self.sample })
        let result = try await client.fetchOpenPullRequests(authoredBy: "octo")

        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.items.count, 2)

        let first = result.items[0]
        XCTAssertEqual(first.repo, "me/a")
        XCTAssertEqual(first.number, 12)
        XCTAssertEqual(first.title, "Add login")
        XCTAssertEqual(first.url, "https://github.com/me/a/pull/12")
        XCTAssertEqual(first.review, .changesRequested)
        XCTAssertEqual(first.ci, .failing)
        XCTAssertTrue(first.hasConflicts)
        XCTAssertFalse(first.isDraft)
        XCTAssertEqual(first.updatedAt, ISO8601DateFormatter().date(from: "2026-10-08T09:30:00Z"))

        let second = result.items[1]
        XCTAssertTrue(second.isDraft)
        XCTAssertEqual(second.review, .waiting)
        XCTAssertEqual(second.ci, .noChecks)
        XCTAssertFalse(second.hasConflicts)
    }

    func testSendsAnAuthoredOpenPullRequestSearchToGraphQL() async throws {
        final class Seen: @unchecked Sendable { var path = ""; var body = "" }
        let seen = Seen()
        let client = GitHubClient(token: "t", transport: BodyTransport { request in
            seen.path = request.url?.path ?? ""
            seen.body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return self.sample
        })
        _ = try await client.fetchOpenPullRequests(authoredBy: "octo")

        XCTAssertEqual(seen.path, "/graphql")
        XCTAssertTrue(seen.body.contains("is:pr is:open author:octo"))
        XCTAssertTrue(seen.body.contains("statusCheckRollup"))
    }

    func testUnknownEnumValuesFallBackToNeutral() async throws {
        let body = """
        {"data":{"search":{"issueCount":1,"nodes":[
          {"number":1,"title":"T","url":"https://github.com/me/a/pull/1","isDraft":false,
           "createdAt":"2026-10-01T08:00:00Z","updatedAt":"2026-10-01T08:00:00Z",
           "reviewDecision":"SOMETHING_NEW","mergeable":"SOMETHING_ELSE",
           "repository":{"nameWithOwner":"me/a"},
           "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"WEIRD"}}}]}}
        ]}}}
        """
        let client = GitHubClient(token: "t", transport: BodyTransport { _ in body })
        let item = try await client.fetchOpenPullRequests(authoredBy: "octo").items[0]
        XCTAssertEqual(item.review, .waiting)
        XCTAssertEqual(item.ci, .noChecks)
        XCTAssertFalse(item.hasConflicts)
    }

    func testGraphQLErrorWithoutDataIsThrown() async {
        let body = #"{"errors":[{"message":"Resource not accessible by personal access token"}]}"#
        let client = GitHubClient(token: "t", transport: BodyTransport { _ in body })
        do {
            _ = try await client.fetchOpenPullRequests(authoredBy: "octo")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Resource not accessible by personal access token")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PullRequestClientTests`
Expected: build FAIL with "value of type 'GitHubClient' has no member 'fetchOpenPullRequests'".

- [ ] **Step 3: Implement**

In `Sources/FocusCore/GitHubClient.swift`, add inside `struct GitHubClient`, directly before `private func graphQL(...)`:

```swift
    /// Open pull requests authored by `login` (first 100, most recently updated first) with review, CI and conflict state.
    public func fetchOpenPullRequests(authoredBy login: String) async throws -> (items: [PullRequestItem], total: Int) {
        let search = "is:pr is:open author:\(login) archived:false sort:updated-desc"
        let data = try await graphQL(Self.pullRequestsQuery, variables: ["q": search])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(PullRequestsEnvelope.self, from: data)
        if envelope.data == nil, let message = envelope.errors?.first?.message { throw GitHubError.graphQL(message) }
        guard let result = envelope.data?.search else { throw GitHubError.invalidResponse }
        return (result.nodes.compactMap { $0?.toItem() }, result.issueCount)
    }

    private static let pullRequestsQuery = """
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 100) {
        issueCount
        nodes {
          ... on PullRequest {
            number title url isDraft createdAt updatedAt reviewDecision mergeable
            repository { nameWithOwner }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """
```

At the end of the file, add:

```swift
private struct PullRequestsEnvelope: Decodable {
    struct Failure: Decodable { let message: String }
    struct Search: Decodable {
        let issueCount: Int
        let nodes: [Node?]
    }
    struct Node: Decodable {
        struct Repository: Decodable { let nameWithOwner: String }
        struct Commits: Decodable {
            struct CommitNode: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable { let state: String }
                    let statusCheckRollup: Rollup?
                }
                let commit: Commit
            }
            let nodes: [CommitNode?]?
        }

        let number: Int?
        let title: String?
        let url: String?
        let isDraft: Bool?
        let createdAt: Date?
        let updatedAt: Date?
        let reviewDecision: String?
        let mergeable: String?
        let repository: Repository?
        let commits: Commits?

        func toItem() -> PullRequestItem? {
            guard let number, let title, let url, let repo = repository?.nameWithOwner,
                  let createdAt, let updatedAt else { return nil }
            let lastCommit = commits?.nodes?.compactMap { $0 }.first
            return PullRequestItem(
                repo: repo, number: number, title: title, url: url,
                isDraft: isDraft ?? false,
                review: ReviewState(decision: reviewDecision),
                ci: CIState(rollup: lastCommit?.commit.statusCheckRollup?.state),
                hasConflicts: mergeable == "CONFLICTING",
                createdAt: createdAt, updatedAt: updatedAt
            )
        }
    }
    struct Data: Decodable { let search: Search? }

    let data: Data?
    let errors: [Failure]?
}
```

Note: the nested type named `Data` shadows `Foundation.Data` only inside `PullRequestsEnvelope`; if the compiler complains, rename it `Payload` (and the `let data: Payload?` property type).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PullRequestClientTests`
Expected: 4 tests PASS. Then `swift test` and expect everything to pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/GitHubClient.swift Tests/FocusCoreTests/PullRequestClientTests.swift
git commit -m "feat: fetch my open pull requests with one GraphQL search"
```

---

### Task 3: Store state, refresh and sync hook

**Files:**
- Modify: `Sources/FocusCore/AppStore.swift` (`SyncState` area, properties, new MARK section, `syncGitHub`)
- Test: `Tests/FocusCoreTests/PullRequestStoreTests.swift` (create)

**Interfaces:**
- Consumes: Task 1 `PullRequestItem`, `PullRequestSection.make`; Task 2 `GitHubClient.fetchOpenPullRequests(authoredBy:)`; existing `GitHubClient.currentUser()`.
- Produces (all on `AppStore`, `@MainActor`):
  - `public enum PullRequestsState: Equatable, Sendable { case idle, loading, loaded(Date, total: Int), failed(String) }`
  - `public private(set) var pullRequests: [PullRequestItem]`, `public private(set) var pullRequestsState: PullRequestsState`
  - `public var pullRequestSections: [PullRequestSection]`
  - `public func refreshPullRequests() async`
  - `public func refreshPullRequestsIfStale(maxAge: TimeInterval = 120) async`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/PullRequestStoreTests.swift`:

```swift
import XCTest
@testable import FocusCore

private struct RoutedTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, String)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        return (Data(body.utf8), response)
    }
}

private final class Counter: @unchecked Sendable {
    var requests = 0
    var failing = false
}

@MainActor
final class PullRequestStoreTests: XCTestCase {
    private let pullRequestsJSON = """
    {"data":{"search":{"issueCount":2,"nodes":[
      {"number":12,"title":"A","url":"https://github.com/me/a/pull/12","isDraft":false,
       "createdAt":"2026-10-01T08:00:00Z","updatedAt":"2026-10-08T09:30:00Z","reviewDecision":"APPROVED","mergeable":"MERGEABLE",
       "repository":{"nameWithOwner":"me/a"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}},
      {"number":7,"title":"B","url":"https://github.com/me/b/pull/7","isDraft":false,
       "createdAt":"2026-10-05T08:00:00Z","updatedAt":"2026-10-05T08:00:00Z","reviewDecision":null,"mergeable":"MERGEABLE",
       "repository":{"nameWithOwner":"me/b"},"commits":{"nodes":[]}}
    ]}}}
    """

    private func makeStore(
        token: String? = "t", repos: String? = nil, counter: Counter = Counter(), graphQL: String? = nil
    ) -> (AppStore, UserDefaults, Counter) {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        if let repos { defaults.set(repos, forKey: PrefKey.repos) }
        let json = graphQL ?? pullRequestsJSON
        let transport = RoutedTransport { request in
            counter.requests += 1
            if counter.failing { return (401, "{}") }
            switch request.url?.path ?? "" {
            case "/user": return (200, #"{"login":"octo"}"#)
            case "/graphql": return (200, json)
            default: return (200, "[]")
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: defaults, transport: transport, tokenProvider: { token })
        return (store, defaults, counter)
    }

    func testWithoutATokenTheStateFails() async {
        let (store, _, counter) = makeStore(token: nil)
        await store.refreshPullRequests()
        XCTAssertEqual(store.pullRequestsState, .failed("Add a GitHub token in Settings."))
        XCTAssertEqual(counter.requests, 0)
    }

    func testLoadsAllRepositoriesWhenNoFilterIsSet() async {
        let (store, _, _) = makeStore()
        XCTAssertEqual(store.pullRequestsState, .idle)
        await store.refreshPullRequests()

        XCTAssertEqual(store.pullRequests.map(\.number), [12, 7])
        guard case .loaded(_, let total) = store.pullRequestsState else { return XCTFail("expected loaded") }
        XCTAssertEqual(total, 2)
        XCTAssertEqual(store.pullRequestSections.map(\.group), [.waiting, .approved])
    }

    func testAppliesTheConfiguredRepositoryFilterCaseInsensitively() async {
        let (store, _, _) = makeStore(repos: "ME/A")
        await store.refreshPullRequests()
        XCTAssertEqual(store.pullRequests.map(\.number), [12])
    }

    func testAFailedRefreshKeepsThePreviousList() async {
        let counter = Counter()
        let (store, _, _) = makeStore(counter: counter)
        await store.refreshPullRequests()
        XCTAssertEqual(store.pullRequests.count, 2)

        counter.failing = true
        await store.refreshPullRequests()

        XCTAssertEqual(store.pullRequests.count, 2)
        guard case .failed(let message) = store.pullRequestsState else { return XCTFail("expected failed") }
        XCTAssertEqual(message, "GitHub rejected the token. Check it in Settings.")
    }

    func testPermissionErrorsExplainWhatAccessIsNeeded() async {
        let body = #"{"errors":[{"message":"Resource not accessible by personal access token"}]}"#
        let (store, _, _) = makeStore(graphQL: body)
        await store.refreshPullRequests()
        guard case .failed(let message) = store.pullRequestsState else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("Resource not accessible"))
        XCTAssertTrue(message.contains("Pull requests: Read"))
    }

    func testRefreshIfStaleSkipsRecentDataAndRefreshesOldData() async {
        let (store, _, counter) = makeStore()
        await store.refreshPullRequests()
        let afterFirst = counter.requests

        await store.refreshPullRequestsIfStale()
        XCTAssertEqual(counter.requests, afterFirst)

        await store.refreshPullRequestsIfStale(maxAge: 0)
        XCTAssertGreaterThan(counter.requests, afterFirst)
    }

    func testAPullRequestFailureDoesNotAffectTheTicketSync() async {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        let transport = RoutedTransport { request in
            switch request.url?.path ?? "" {
            case "/issues": return (200, "[]")
            case "/user": return (401, "{}")
            default: return (200, "{}")
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: defaults, transport: transport, tokenProvider: { "t" })

        await store.syncGitHub()

        guard case .succeeded(_, let count) = store.syncState else { return XCTFail("expected the ticket sync to succeed") }
        XCTAssertEqual(count, 0)
        guard case .failed = store.pullRequestsState else { return XCTFail("expected the pull request load to fail") }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PullRequestStoreTests`
Expected: build FAIL with "value of type 'AppStore' has no member 'refreshPullRequests'".

- [ ] **Step 3: Implement**

In `Sources/FocusCore/AppStore.swift`:

1. After `public enum SyncState ... { ... }` add:

```swift
public enum PullRequestsState: Equatable, Sendable {
    case idle
    case loading
    case loaded(Date, total: Int)
    case failed(String)
}
```

2. In the stored properties of `AppStore`, after `public private(set) var dayPlans: [DayPlan] = []` add:

```swift
    public private(set) var pullRequests: [PullRequestItem] = []
    public private(set) var pullRequestsState: PullRequestsState = .idle
```

3. In `syncGitHub()`, replace the inline repo parsing

```swift
            let repos = Set(
                (defaults.string(forKey: PrefKey.repos) ?? "")
                    .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    .map { $0.lowercased() }
            )
            let includePRs = defaults.bool(forKey: PrefKey.includePRs)
            let client = GitHubClient(token: token, transport: transport)
            let remote = try await client.fetchAssignedIssues(repos: repos, includePullRequests: includePRs)
```

with

```swift
            let includePRs = defaults.bool(forKey: PrefKey.includePRs)
            let client = GitHubClient(token: token, transport: transport)
            let remote = try await client.fetchAssignedIssues(repos: configuredRepos, includePullRequests: includePRs)
```

and, as the last statement of `syncGitHub()` (after the `do { ... } catch { ... }` block, still inside the function), add:

```swift
        await refreshPullRequests()
```

4. Directly after `syncGitHub()` (before `withProjectFields`), add:

```swift
    /// Lowercased "owner/name" entries from Settings; empty means every repo.
    private var configuredRepos: Set<String> {
        Set(
            (defaults.string(forKey: PrefKey.repos) ?? "")
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map { $0.lowercased() }
        )
    }

    // MARK: - My pull requests

    public var pullRequestSections: [PullRequestSection] { PullRequestSection.make(from: pullRequests) }

    /// Loads my open pull requests; a failure keeps the previous list and never touches the ticket sync state.
    public func refreshPullRequests() async {
        guard pullRequestsState != .loading else { return }
        guard let token = tokenProvider(), !token.isEmpty else {
            pullRequestsState = .failed("Add a GitHub token in Settings.")
            return
        }
        pullRequestsState = .loading
        do {
            let client = GitHubClient(token: token, transport: transport)
            let login = try await client.currentUser()
            let result = try await client.fetchOpenPullRequests(authoredBy: login)
            let repos = configuredRepos
            pullRequests = repos.isEmpty ? result.items : result.items.filter { repos.contains($0.repo.lowercased()) }
            pullRequestsState = .loaded(Date(), total: result.total)
        } catch {
            pullRequestsState = .failed(Self.pullRequestMessage(for: error))
        }
    }

    public func refreshPullRequestsIfStale(maxAge: TimeInterval = 120) async {
        if case .loaded(let date, _) = pullRequestsState, Date().timeIntervalSince(date) < maxAge { return }
        await refreshPullRequests()
    }

    private static func pullRequestMessage(for error: Error) -> String {
        let message = error.localizedDescription
        var needsAccess = message.localizedCaseInsensitiveContains("not accessible")
        if case GitHubError.http(let code) = error, code == 403 || code == 404 { needsAccess = true }
        return needsAccess ? "\(message) Needs Pull requests: Read (and Commit statuses / Checks: Read for CI)." : message
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests PASS (the existing `testRefreshTicketUpdatesOnlyThatTicketAndMarksClosed` still passes; its extra PR request just fails quietly).

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/AppStore.swift Tests/FocusCoreTests/PullRequestStoreTests.swift
git commit -m "feat: load my pull requests into the store alongside the GitHub sync"
```

---

### Task 4: Pull Requests tab

**Files:**
- Create: `Sources/FocusTracker/PullRequestsView.swift`
- Modify: `Sources/FocusTracker/RootView.swift` (`SidebarItem`, `sidebarContent`)
- Modify: `README.md` (one note)

**Interfaces:**
- Consumes: `AppStore.pullRequestSections`, `pullRequestsState`, `refreshPullRequests()`, `refreshPullRequestsIfStale()`; `PullRequestItem`, `PullRequestGroup`; existing `PageHeader`, `SectionTitle`, `EmptyHint`, `Chip`, `FlowLayout`, `Theme`, `.cardStyle`, `.buttonStyle(.secondary)`.
- Produces: `PullRequestsView`; `SidebarItem.pullRequests`.

UI is verified by building and running the app; there is no UI test target.

- [ ] **Step 1: Create the view**

Create `Sources/FocusTracker/PullRequestsView.swift`:

```swift
import FocusCore
import SwiftUI

struct PullRequestsView: View {
    @Environment(AppStore.self) private var store

    private var loading: Bool { store.pullRequestsState == .loading }

    var body: some View {
        let sections = store.pullRequestSections
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: "Pull Requests", subtitle: subtitle)
                    Spacer()
                    Button { Task { await store.refreshPullRequests() } } label: {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.secondary)
                    .controlSize(.large)
                    .disabled(loading)
                    .help("Reload your open pull requests")
                }

                if case .failed(let message) = store.pullRequestsState {
                    EmptyHint(text: message, symbol: "exclamationmark.triangle")
                }
                if sections.isEmpty, case .loaded = store.pullRequestsState {
                    EmptyHint(text: "No open pull requests.", symbol: "arrow.triangle.pull")
                }

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: section.group.title, count: section.items.count)
                        VStack(spacing: 0) {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                PullRequestRow(item: item)
                            }
                        }
                        .cardStyle(padding: 0)
                    }
                }

                if case .loaded(_, let total) = store.pullRequestsState, total > 100 {
                    Text("Showing the first 100 of \(total).").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        .task { await store.refreshPullRequestsIfStale() }
    }

    private var subtitle: String {
        switch store.pullRequestsState {
        case .loaded(let date, _): "Updated \(date.formatted(.relative(presentation: .named)))"
        case .loading: "Loading…"
        default: "Open pull requests you authored"
        }
    }
}

private struct PullRequestRow: View {
    let item: PullRequestItem

    private var destination: URL? {
        guard let url = URL(string: item.url), url.scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        if let destination {
            Link(destination: destination) { content }
                .buttonStyle(.plain)
                .help("Open on GitHub")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(item.repo)#\(item.number) · updated \(item.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            FlowLayout { chips }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var chips: some View {
        if item.isDraft {
            Chip(text: "Draft", color: Theme.slate, symbol: "pencil")
        } else {
            switch item.review {
            case .approved: Chip(text: "Approved", color: Theme.success, symbol: "checkmark.circle.fill")
            case .changesRequested: Chip(text: "Changes requested", color: Theme.danger, symbol: "xmark.circle.fill")
            case .waiting: Chip(text: "Waiting", color: Theme.warning, symbol: "clock")
            }
        }
        switch item.ci {
        case .passing: Chip(text: "Checks passing", color: Theme.success, symbol: "checkmark")
        case .failing: Chip(text: "Checks failing", color: Theme.danger, symbol: "xmark")
        case .pending: Chip(text: "Checks running", color: Theme.info, symbol: "circle.dotted")
        case .noChecks: EmptyView()
        }
        if item.hasConflicts {
            Chip(text: "Conflicts", color: Theme.danger, symbol: "exclamationmark.triangle.fill")
        }
    }
}
```

- [ ] **Step 2: Add the sidebar item**

In `Sources/FocusTracker/RootView.swift`:

Replace the `SidebarItem` cases and symbols:

```swift
enum SidebarItem: String, CaseIterable, Identifiable {
    case today = "Today"
    case tickets = "Tickets"
    case board = "Board"
    case pullRequests = "Pull Requests"
    case reports = "Reports"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .tickets: "list.bullet.rectangle"
        case .board: "rectangle.split.3x1"
        case .pullRequests: "arrow.triangle.pull"
        case .reports: "chart.bar"
        }
    }
}
```

In `sidebarContent`, add the case before `.reports`:

```swift
        case .pullRequests: PullRequestsView()
```

- [ ] **Step 3: Add the README note**

In `README.md`, under "GitHub setup", add after step 3:

```markdown
The Pull Requests tab lists your open PRs (grouped by what needs attention). A fine-grained token needs Pull requests: Read, plus Commit statuses and Checks: Read for the CI chip; a classic `repo` token covers both. The repo restriction above applies to this tab too.
```

- [ ] **Step 4: Build and run all tests**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS. If `Link` styling or `.buttonStyle(.secondary)` fails to resolve, check `Sources/FocusTracker/DesignSystem.swift` (`extension ButtonStyle where Self == SecondaryButtonStyle`).

- [ ] **Step 5: Verify in the app**

Run: `./scripts/build-app.sh && open build/FocusTracker.app`

Check by hand:
1. A "Pull Requests" item appears after Board in the sidebar.
2. Opening it loads your PRs; the subtitle reads "Updated ...".
3. PRs are grouped (Needs action, Waiting for review, Approved, Drafts); chips match each PR on GitHub.
4. Clicking a row opens the PR in the browser.
5. Refresh reloads; with a Settings repo filter set, only those repos are listed.
6. With a token lacking PR access, the tab shows the "Needs Pull requests: Read" message and the rest of the app still syncs.

- [ ] **Step 6: Commit**

```bash
git add Sources/FocusTracker/PullRequestsView.swift Sources/FocusTracker/RootView.swift README.md
git commit -m "feat: add the Pull Requests tab"
```

---

## Self-Review Notes

- **Spec coverage:** model, mapping and grouping (Task 1); one GraphQL query with the exact search, 100 limit, errors and unknown values (Task 2); in-memory state, repo filter, stale refresh, sync hook that never changes `syncState`, permission hint (Task 3); sidebar item, grouped rows, chips, Refresh, empty/failed/over-100 states, open-in-browser (Task 4).
- **Spec changes made while planning:** `CIState.none` became `.noChecks` (it would clash with `Optional.none`); the grouped list is a `PullRequestSection` struct instead of tuples; the stale-refresh method was added to the Store section.
- **Type consistency:** `PullRequestItem`, `PullRequestSection.make(from:)`, `fetchOpenPullRequests(authoredBy:)`, `PullRequestsState`, `pullRequestSections`, `refreshPullRequests()` and `refreshPullRequestsIfStale(maxAge:)` use the same names and signatures in every task.
