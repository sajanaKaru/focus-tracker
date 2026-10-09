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
