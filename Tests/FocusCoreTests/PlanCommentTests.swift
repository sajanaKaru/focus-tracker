import XCTest
@testable import FocusCore

@MainActor
final class PlanCommentTests: XCTestCase {
    private func makeStore(status: Int = 201) -> (AppStore, RecordingTransport, UUID) {
        let transport = RecordingTransport { _ in (status, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        store.insertTicketForTest(Ticket(title: "A", github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        return (store, transport, store.tickets[0].id)
    }

    func testUpdateEditsDraftAndLogsOldAndNew() {
        let (store, _, id) = makeStore()
        store.addPlanComment(ticketID: id, text: "first")
        let comment = store.planComments[0]

        XCTAssertTrue(store.updatePlanComment(comment.id, text: "  first, revised  "))

        XCTAssertEqual(store.planComments[0].text, "first, revised")
        let entry = store.actionLog.last { $0.field == "Plan comment edited" }!
        XCTAssertEqual(entry.oldValue, "first")
        XCTAssertEqual(entry.newValue, "first, revised")
        XCTAssertEqual(entry.kind, .planComment)
    }

    func testUpdateRejectsEmptyUnchangedAndPostedComments() async {
        let (store, _, id) = makeStore()
        store.addPlanComment(ticketID: id, text: "keep")
        let commentID = store.planComments[0].id

        XCTAssertFalse(store.updatePlanComment(commentID, text: "   "))
        XCTAssertFalse(store.updatePlanComment(commentID, text: "keep"))
        XCTAssertEqual(store.planComments[0].text, "keep")

        await store.postPlan(id)
        XCTAssertFalse(store.updatePlanComment(commentID, text: "changed after posting"))
        XCTAssertEqual(store.planComments[0].text, "keep")
    }

    func testPostingOneCommentLeavesTheOthersUnposted() async throws {
        let (store, transport, id) = makeStore()
        store.addPlanComment(ticketID: id, text: "first", at: Date(timeIntervalSince1970: 1))
        store.addPlanComment(ticketID: id, text: "second", at: Date(timeIntervalSince1970: 2))
        let second = store.planComments(for: id)[1]

        let ok = await store.postPlan(id, only: second.id)

        XCTAssertTrue(ok)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.json(0)?["body"] as? String, "second")
        XCTAssertNotNil(store.planComments(for: id)[1].postedAt)
        XCTAssertNil(store.planComments(for: id)[0].postedAt)
        XCTAssertEqual(store.unpostedPlanComments(for: id).map(\.text), ["first"])
        let entry = store.actionLog.last { $0.field == "Plan comment posted to GitHub" }!
        if case .synced = entry.sync {} else { XCTFail("expected synced") }
    }

    func testFailedSinglePostKeepsCommentUnposted() async {
        let (store, _, id) = makeStore(status: 403)
        store.addPlanComment(ticketID: id, text: "only")
        let commentID = store.planComments[0].id

        let ok = await store.postPlan(id, only: commentID)

        XCTAssertFalse(ok)
        XCTAssertNil(store.planComments[0].postedAt)
        XCTAssertEqual(store.failedActions.count, 1)
    }

    func testPostingAllStillPostsEverythingAsOneComment() async {
        let (store, transport, id) = makeStore()
        store.addPlanComment(ticketID: id, text: "a", at: Date(timeIntervalSince1970: 1))
        store.addPlanComment(ticketID: id, text: "b", at: Date(timeIntervalSince1970: 2))

        await store.postPlan(id)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.json(0)?["body"] as? String, "a\(AppStore.planCommentSeparator)b")
        XCTAssertTrue(store.unpostedPlanComments(for: id).isEmpty)
    }
}
