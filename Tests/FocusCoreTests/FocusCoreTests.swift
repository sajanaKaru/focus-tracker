import XCTest
@testable import FocusCore

private struct MockTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, [String: String], String)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

private func issueJSON(number: Int, repo: String, pr: Bool = false) -> String {
    """
    {"number": \(number), "title": "Issue \(number)", "body": null,
     "html_url": "https://github.com/\(repo)/issues/\(number)",
     "repository_url": "https://api.github.com/repos/\(repo)",
     "labels": [{"name": "bug"}]\(pr ? ", \"pull_request\": {}" : "")}
    """
}

final class GitHubClientTests: XCTestCase {
    func testFetchesAndFiltersPullRequestsAndRepos() async throws {
        let body = "[\(issueJSON(number: 1, repo: "me/a")), \(issueJSON(number: 2, repo: "me/a", pr: true)), \(issueJSON(number: 3, repo: "me/b"))]"
        let client = GitHubClient(token: "t", transport: MockTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
            return (200, [:], body)
        })

        let all = try await client.fetchAssignedIssues()
        XCTAssertEqual(all.map(\.number), [1, 3])
        XCTAssertEqual(all[0].repo, "me/a")
        XCTAssertEqual(all[0].labels, ["bug"])

        let onlyB = try await client.fetchAssignedIssues(repos: ["me/b"])
        XCTAssertEqual(onlyB.map(\.number), [3])

        let withPRs = try await client.fetchAssignedIssues(includePullRequests: true)
        XCTAssertEqual(withPRs.count, 3)
    }

    func testFollowsPaginationOnlyOnGitHubHost() async throws {
        let client = GitHubClient(token: "t", transport: MockTransport { request in
            if request.url?.absoluteString.contains("page=2") == true {
                return (200, [:], "[\(issueJSON(number: 2, repo: "me/a"))]")
            }
            return (200, ["Link": "<https://api.github.com/issues?page=2>; rel=\"next\""], "[\(issueJSON(number: 1, repo: "me/a"))]")
        })
        let issues = try await client.fetchAssignedIssues()
        XCTAssertEqual(issues.map(\.number), [1, 2])

        XCTAssertNil(GitHubClient.nextURL(from: "<https://evil.example/x>; rel=\"next\""))
    }

    func testUnauthorizedMapsToError() async {
        let client = GitHubClient(token: "bad", transport: MockTransport { _ in (401, [:], "{}") })
        do {
            _ = try await client.fetchAssignedIssues()
            XCTFail("expected error")
        } catch {
            guard case GitHubError.unauthorized = error else { return XCTFail("wrong error \(error)") }
        }
    }
}

final class MergeTests: XCTestCase {
    private func remote(_ n: Int, title: String = "T") -> RemoteIssue {
        RemoteIssue(repo: "me/a", number: n, title: title, url: "https://github.com/me/a/issues/\(n)")
    }

    func testInsertsAndPreservesLocalFields() {
        var tickets = AppStore.merge(existing: [], remote: [remote(1)])
        XCTAssertEqual(tickets.count, 1)

        tickets[0].status = .inReview
        tickets = AppStore.merge(existing: tickets, remote: [remote(1, title: "Renamed")])

        XCTAssertEqual(tickets.count, 1)
        XCTAssertEqual(tickets[0].title, "Renamed")
        XCTAssertEqual(tickets[0].status, .inReview)
    }

    func testMissingRemoteIsMarkedDoneAndReopenedWhenReturns() {
        var tickets = AppStore.merge(existing: [], remote: [remote(1)])
        tickets = AppStore.merge(existing: tickets, remote: [])
        XCTAssertEqual(tickets[0].status, .done)
        XCTAssertTrue(tickets[0].github!.remoteClosed)

        tickets = AppStore.merge(existing: tickets, remote: [remote(1)])
        XCTAssertEqual(tickets[0].status, .todo)
        XCTAssertFalse(tickets[0].github!.remoteClosed)
    }

    func testLocallyDoneStaysDoneWhileOpenOnGitHub() {
        var tickets = AppStore.merge(existing: [], remote: [remote(1)])
        tickets[0].status = .done
        tickets = AppStore.merge(existing: tickets, remote: [remote(1)])
        XCTAssertEqual(tickets[0].status, .done)
    }

    func testLocalTicketsUntouched() {
        let local = Ticket(title: "Local")
        let merged = AppStore.merge(existing: [local], remote: [])
        XCTAssertEqual(merged, [local])
    }
}

@MainActor
final class StoreTests: XCTestCase {
    private func makeStore(idle: @escaping () -> TimeInterval = { 0 }) -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }, idleSeconds: idle), url)
    }

    func testStartMovesTodoToInProgressAndSwitchesTimers() {
        let (store, _) = makeStore()
        let a = store.addTicket(title: "A")
        let b = store.addTicket(title: "B")

        store.start(a.id)
        XCTAssertEqual(store.ticket(a.id)?.status, .inProgress)
        store.start(b.id)

        XCTAssertFalse(store.isTracking(a.id))
        XCTAssertTrue(store.isTracking(b.id))
        XCTAssertEqual(store.entries.filter { $0.end == nil }.count, 1)
        store.stop()
    }

    func testPersistenceRoundTripKeepsRunningTimer() {
        let (store, url) = makeStore()
        let t = store.addTicket(title: "A")
        store.start(t.id)

        let reloaded = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertEqual(reloaded.tickets.count, 1)
        XCTAssertTrue(reloaded.isTracking(t.id))
        reloaded.stop()
        store.stop()
    }

    func testIdleStopsTimerAndTrimsIdleTime() {
        let (store, _) = makeStore(idle: { 20 * 60 })
        let t = store.addTicket(title: "A")
        store.start(t.id)
        store.checkIdle()

        XCTAssertNil(store.activeEntry)
        XCTAssertNotNil(store.notice)
        XCTAssertEqual(store.entries[0].end, store.entries[0].start, "end is clamped to start when idle exceeds elapsed time")
    }

    func testDurationWithinIntervalClips() {
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = TimeEntry(ticketID: UUID(), start: start, end: start.addingTimeInterval(600))
        let window = DateInterval(start: start.addingTimeInterval(300), end: start.addingTimeInterval(1_000))
        XCTAssertEqual(entry.duration(in: window, at: start), 300)
    }

    func testManualEntryAndDeleteTicketRemovesEntries() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")
        store.addManualEntry(ticketID: t.id, duration: 1_800)
        XCTAssertEqual(store.trackedTime(for: t.id), 1_800, accuracy: 1)
        store.deleteTicket(t.id)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testNotesAppearInLogAndPersist() {
        let (store, url) = makeStore()
        let t = store.addTicket(title: "A")
        store.addNote(ticketID: t.id, text: "  first  ")
        store.addNote(ticketID: t.id, text: "   ")
        store.addNote(ticketID: t.id, text: "second", at: Date().addingTimeInterval(5))
        store.addManualEntry(ticketID: t.id, duration: 600, endingAt: Date().addingTimeInterval(-3_600))

        let log = store.log(for: t.id)
        XCTAssertEqual(log.count, 3)
        guard case .note(let newest) = log[0], case .time = log[2] else { return XCTFail("unexpected order") }
        XCTAssertEqual(newest.text, "second")
        XCTAssertEqual(store.notes.map(\.text).sorted(), ["first", "second"])

        let reloaded = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertEqual(reloaded.notes.count, 2)

        store.deleteTicket(t.id)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testPlanCommentsPostAsOneCommentAndAreMarkedPosted() async {
        final class Sent: @unchecked Sendable { var bodies: [String] = [] }
        let sent = Sent()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(
            storeURL: url,
            defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!,
            transport: MockTransport { request in
                sent.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
                return (201, [:], "{}")
            },
            tokenProvider: { "t" }
        )
        let t = store.addTicket(title: "A")
        store.update(t.id) { $0.github = GitHubRef(repo: "me/a", number: 7, url: "u") }
        store.addPlanComment(ticketID: t.id, text: " step one ", at: Date())
        store.addPlanComment(ticketID: t.id, text: "   ")
        store.addPlanComment(ticketID: t.id, text: "step two", at: Date().addingTimeInterval(1))

        let ok = await store.postPlan(t.id)

        XCTAssertTrue(ok)
        XCTAssertEqual(sent.bodies, [#"{"body":"step one\n\n---\n\nstep two"}"#])
        XCTAssertTrue(store.unpostedPlanComments(for: t.id).isEmpty)
        let again = await store.postPlan(t.id)
        XCTAssertFalse(again)
        XCTAssertEqual(sent.bodies.count, 1)

        let reloaded = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertEqual(reloaded.planComments(for: t.id).count, 2)
        store.deleteTicket(t.id)
        XCTAssertTrue(store.planComments.isEmpty)
    }

    func testLegacyNotesStringMigratesToNote() throws {
        let id = UUID()
        let json = """
        {"tickets": [{"id": "\(id.uuidString)", "title": "Old", "body": "", "notes": "keep me", "status": "todo",
          "priority": 0, "labels": [], "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z"}],
         "entries": []}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)

        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertEqual(store.tickets.count, 1)
        XCTAssertEqual(store.notes.map(\.text), ["keep me"])
        XCTAssertEqual(store.notes.first?.ticketID, id)
    }
}
