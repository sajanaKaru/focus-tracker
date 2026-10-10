import XCTest
@testable import FocusCore

@MainActor
final class IssueCommentTests: XCTestCase {
    private let page = """
    [{"id": 11, "body": "First **comment**", "html_url": "https://github.com/me/a/issues/1#issuecomment-11",
      "created_at": "2026-10-09T08:00:00Z", "updated_at": "2026-10-09T09:00:00Z", "user": {"login": "alice"}},
     {"id": 12, "body": null, "html_url": "https://github.com/me/a/issues/1#issuecomment-12",
      "created_at": "2026-10-10T08:00:00Z", "updated_at": "2026-10-10T08:00:00Z", "user": null}]
    """

    private func makeStore(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) -> (AppStore, RecordingTransport, UUID) {
        let transport = RecordingTransport(handler)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        store.insertTicketForTest(Ticket(title: "A", github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        store.insertTicketForTest(Ticket(title: "Local"))
        return (store, transport, store.tickets[0].id)
    }

    func testFetchCommentsDecodesAuthorBodyAndMissingUser() async throws {
        let page = self.page
        let client = GitHubClient(token: "t", transport: RecordingTransport { _ in (200, page) })

        let comments = try await client.fetchComments(repo: "me/a", number: 1)

        XCTAssertEqual(comments.map(\.id), [11, 12])
        XCTAssertEqual(comments[0].author, "alice")
        XCTAssertEqual(comments[0].body, "First **comment**")
        XCTAssertEqual(comments[1].author, "ghost")
        XCTAssertEqual(comments[1].body, "")
        XCTAssertTrue(comments[0].createdAt < comments[1].createdAt)
    }

    func testLoadCommentsCachesThrottlesAndForceReloads() async {
        let page = self.page
        let (store, transport, id) = makeStore { _ in (200, page) }

        await store.loadComments(id)
        XCTAssertEqual(store.issueComments[id]?.count, 2)
        XCTAssertNil(store.commentsError[id])
        XCTAssertEqual(transport.requests.first?.url?.path, "/repos/me/a/issues/1/comments")

        await store.loadComments(id)
        XCTAssertEqual(transport.requests.count, 1, "second call within the interval is skipped")

        await store.loadComments(id, minimumInterval: 0)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(store.commentsLoading.isEmpty)
    }

    func testLoadCommentsFailureKeepsCachedCommentsAndRecordsError() async {
        let failing = Switch(false)
        let page = self.page
        let (store, _, id) = makeStore { _ in failing.isOn ? (500, "{}") : (200, page) }
        await store.loadComments(id)

        failing.isOn = true
        await store.loadComments(id, minimumInterval: 0)

        XCTAssertEqual(store.issueComments[id]?.count, 2)
        XCTAssertNotNil(store.commentsError[id])
    }

    func testLocalTicketsAndMissingTokenDoNothing() async {
        let page = self.page
        let (store, transport, _) = makeStore { _ in (200, page) }
        let local = store.tickets[1].id

        await store.loadComments(local)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(store.issueComments[local])
    }
}
