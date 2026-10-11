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

    func testFetchesThrowInsteadOfReturningPartialResultsWhenPagesRunOut() async {
        let client = GitHubClient(token: "t", transport: StubTransport { _ in
            (200, ["Link": #"<https://api.github.com/issues?page=2>; rel="next""#], "[\(issueJSON(number: 1))]")
        })
        do {
            _ = try await client.fetchOpenIssues(repos: ["me/a"])
            XCTFail("expected error")
        } catch {
            guard case GitHubError.truncated = error else { return XCTFail("wrong error \(error)") }
        }
        do {
            _ = try await client.fetchAssignedIssues()
            XCTFail("expected error")
        } catch {
            guard case GitHubError.truncated = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testLastAllowedPageWithoutNextLinkIsNotTruncated() async throws {
        let pages = PathLog()
        let client = GitHubClient(token: "t", transport: StubTransport { request in
            pages.add(request.url!.absoluteString)
            let page = pages.all.count
            let link: [String: String] = page < 20 ? ["Link": #"<https://api.github.com/issues?page=\#(page + 1)>; rel="next""#] : [:]
            return (200, link, "[\(issueJSON(number: page))]")
        })
        let issues = try await client.fetchAssignedIssues()
        XCTAssertEqual(issues.count, 20)
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

    func testRoleChangeDuringASyncTriggersOneFollowUpSyncForTheNewScope() async {
        let transport = GatedTransport(RecordingTransport { request in
            let path = request.url?.path ?? ""
            if path == "/repos/me/a/issues" { return (200, "[\(issueJSON(number: 1)), \(issueJSON(number: 2))]") }
            if path == "/issues" { return (200, "[\(issueJSON(number: 1))]") }
            if path == "/graphql" { return (200, #"{"data":{"nodes":[]}}"#) }
            return (200, "{}")
        })
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        defaults.set("me/a", forKey: PrefKey.repos)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: defaults, transport: transport, tokenProvider: { "t" })
        store.role = .pm

        let running = Task { await store.syncGitHub() }
        while !transport.isHeld { await Task.yield() }
        store.role = .dev
        await store.roleDidChange(from: .pm)
        transport.release()
        await running.value

        let syncPaths = transport.recording.requests.compactMap { $0.url?.path }.filter { $0 == "/issues" || $0 == "/repos/me/a/issues" }
        XCTAssertEqual(syncPaths, ["/repos/me/a/issues", "/issues"])
        XCTAssertEqual(store.tickets.first { $0.github?.number == 1 }?.status == .done, false)
        XCTAssertEqual(store.tickets.first { $0.github?.number == 2 }?.status, .done)
    }
}

/// Holds the first request until `release()` so a test can change state while a sync is in flight.
private final class GatedTransport: HTTPTransport, @unchecked Sendable {
    let recording: RecordingTransport
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var gated = false
    private var released = false

    init(_ recording: RecordingTransport) { self.recording = recording }

    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }

    func release() {
        lock.lock()
        released = true
        let held = continuation
        continuation = nil
        lock.unlock()
        held?.resume()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            lock.lock()
            if gated || released {
                lock.unlock()
                held.resume()
            } else {
                gated = true
                continuation = held
                lock.unlock()
            }
        }
        return try await recording.send(request)
    }
}
