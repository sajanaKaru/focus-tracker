import XCTest
@testable import FocusCore

private struct StubTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (Data(handler(request).utf8), response)
    }
}

final class FilterAndFieldsTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func ticket(repo: String = "me/a", milestone: Milestone? = nil, sprint: CustomField? = nil) -> Ticket {
        Ticket(title: "T", milestone: milestone, fields: sprint.map { [$0] }, github: GitHubRef(repo: repo, number: 1, url: "u"))
    }

    private func sprint(_ name: String, startingDaysAgo: Double, length: Int = 14) -> CustomField {
        let start = Date().addingTimeInterval(-startingDaysAgo * day)
        return CustomField(name: "Sprint", value: name, kind: .iteration, project: "P", start: start, end: start.addingTimeInterval(Double(length) * day))
    }

    func testMilestoneFilter() {
        let open = ticket(milestone: Milestone(title: "v1"))
        let closed = ticket(milestone: Milestone(title: "v0", isOpen: false))
        let none = ticket()

        XCTAssertEqual([open, closed, none].filter { TicketFilter(milestone: .ongoing).matches($0) }, [open])
        XCTAssertEqual([open, closed, none].filter { TicketFilter(milestone: .none).matches($0) }, [none])
        XCTAssertEqual([open, closed, none].filter { TicketFilter(milestone: .named("v0")).matches($0) }, [closed])
    }

    func testSprintAndRepoFilter() {
        let current = ticket(sprint: sprint("Sprint 5", startingDaysAgo: 3))
        let past = ticket(repo: "me/b", sprint: sprint("Sprint 4", startingDaysAgo: 30))
        let all = [current, past]

        XCTAssertEqual(all.filter { TicketFilter(sprint: .current).matches($0) }, [current])
        XCTAssertEqual(all.filter { TicketFilter(sprint: .named("Sprint 4")).matches($0) }, [past])
        XCTAssertEqual(all.filter { TicketFilter(repo: "ME/B").matches($0) }, [past])
        XCTAssertFalse(TicketFilter().isActive)
    }

    func testSourceFilter() {
        let synced = ticket()
        let local = Ticket(title: "Local")
        let both = [synced, local]

        XCTAssertEqual(both.filter { TicketFilter(source: .local).matches($0) }, [local])
        XCTAssertEqual(both.filter { TicketFilter(source: .github).matches($0) }, [synced])
        XCTAssertEqual(both.filter { TicketFilter().matches($0) }, both)
        XCTAssertTrue(TicketFilter(source: .local).isActive)
    }

    func testIssueMilestoneIsDecoded() async throws {
        let body = """
        [{"number": 1, "title": "A", "body": null, "html_url": "https://github.com/me/a/issues/1",
          "repository_url": "https://api.github.com/repos/me/a", "node_id": "I_1", "labels": [],
          "milestone": {"title": "v1", "state": "open", "due_on": "2026-12-01T08:00:00Z"}}]
        """
        let client = GitHubClient(token: "t", transport: StubTransport { _ in body })
        let issue = try await client.fetchAssignedIssues()[0]
        XCTAssertEqual(issue.nodeID, "I_1")
        XCTAssertEqual(issue.milestone?.title, "v1")
        XCTAssertEqual(issue.milestone?.isOpen, true)
        XCTAssertNotNil(issue.milestone?.dueOn)
    }

    func testProjectFieldsAreParsed() async throws {
        let body = """
        {"data": {"nodes": [{"id": "I_1", "projectItems": {"nodes": [{"project": {"title": "Roadmap"},
          "fieldValues": {"nodes": [
            {"text": "Fix bug", "field": {"name": "Title"}},
            {"title": "Sprint 5", "startDate": "2026-10-05", "duration": 14, "field": {"name": "Sprint"}},
            {"number": 5, "field": {"name": "Estimate"}},
            {"name": "High", "field": {"name": "Priority"}},
            {"text": "Cache race", "field": {"name": "RCA"}},
            {}
          ]}}]}}, null]}}
        """
        let client = GitHubClient(token: "t", transport: StubTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return body
        })
        let fields = try await client.fetchProjectFields(nodeIDs: ["I_1"])["I_1"] ?? []

        XCTAssertEqual(fields.map(\.name), ["Sprint", "Estimate", "Priority", "RCA"])
        XCTAssertEqual(fields[0].kind, .iteration)
        XCTAssertEqual(fields[0].value, "Sprint 5")
        XCTAssertNotNil(fields[0].end)
        XCTAssertEqual(fields[1].value, "5")
        XCTAssertEqual(fields[3].value, "Cache race")
        XCTAssertEqual(fields[0].project, "Roadmap")
    }

    func testEmptyRCAFieldIsStillListed() async throws {
        let body = """
        {"data": {"nodes": [{"id": "I_1", "projectItems": {"nodes": [{"project": {"title": "Delenta-i", "rca": {"name": "RCA"}},
          "fieldValues": {"nodes": [{"number": 2, "field": {"name": "Dev Estimated (in Hours)"}}]}}]}}]}}
        """
        let client = GitHubClient(token: "t", transport: StubTransport { _ in body })
        let fields = try await client.fetchProjectFields(nodeIDs: ["I_1"])["I_1"] ?? []

        XCTAssertEqual(fields.map(\.name), ["Dev Estimated (in Hours)", "RCA"])
        XCTAssertEqual(fields[1].value, "")
        XCTAssertEqual(fields[1].kind, .text)
    }

    func testPostCommentSendsBodyToIssueComments() async throws {
        final class Seen: @unchecked Sendable { var url: String?; var method: String?; var body: String? }
        let seen = Seen()
        let client = GitHubClient(token: "t", transport: StubTransport { request in
            seen.url = request.url?.absoluteString
            seen.method = request.httpMethod
            seen.body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return "{}"
        })

        try await client.postComment(repo: "me/a", number: 7, body: "- [ ] step")

        XCTAssertEqual(seen.url, "https://api.github.com/repos/me/a/issues/7/comments")
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.body, #"{"body":"- [ ] step"}"#)
    }

    func testEstimateMergesGitHubFieldWithLocalEstimate() {
        let dev = CustomField(name: "Dev Estimated (in Hours)", value: "1.5", kind: .number, project: "P")
        let actual = CustomField(name: "Dev Actual Time Spend (in Hours)", value: "6", kind: .number, project: "P")

        XCTAssertEqual(Ticket(title: "T", fields: [actual, dev], estimateMinutes: 30).effectiveEstimateMinutes, 90)
        XCTAssertEqual(Ticket(title: "T", fields: [actual], estimateMinutes: 30).effectiveEstimateMinutes, 30)
        XCTAssertNil(Ticket(title: "T").effectiveEstimateMinutes)
    }

    func testUpdateProjectFieldLooksUpIDsThenWritesValue() async throws {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let log = Log()
        let lookup = """
        {"data": {"repository": {"issue": {"projectItems": {"nodes": [
          {"id": "ITEM_1", "project": {"id": "PVT_1", "title": "Delenta-i", "fields": {"nodes": [{"id": "F_1", "name": "RCA"}, {}]}}}]}}}}}
        """
        let client = GitHubClient(token: "t", transport: StubTransport { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            log.add(body)
            return body.contains("updateProjectV2ItemFieldValue") ? #"{"data": {}}"# : lookup
        })

        try await client.updateProjectField(repo: "me/a", number: 7, project: "Delenta-i", field: "RCA", value: .text("Cache race"))

        let bodies = log.all
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("\"number\":7"))
        XCTAssertTrue(bodies[1].contains("F_1") && bodies[1].contains("ITEM_1") && bodies[1].contains("PVT_1"))
        XCTAssertTrue(bodies[1].contains("Cache race"))

        do {
            try await client.updateProjectField(repo: "me/a", number: 7, project: "Other", field: "RCA", value: .text("x"))
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not in the \"Other\" project"))
        }
    }

    func testGraphQLErrorWithoutDataIsThrown() async {
        let body = #"{"data": {"nodes": [null]}, "errors": [{"message": "Resource not accessible"}]}"#
        let client = GitHubClient(token: "t", transport: StubTransport { _ in body })
        do {
            _ = try await client.fetchProjectFields(nodeIDs: ["I_1"])
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Resource not accessible")
        }
    }

    @MainActor
    func testRefreshTicketUpdatesOnlyThatTicketAndMarksClosed() async {
        func issue(_ title: String, state: String) -> String {
            """
            {"number": 1, "title": "\(title)", "body": null, "state": "\(state)", "html_url": "https://github.com/me/a/issues/1",
             "repository_url": "https://api.github.com/repos/me/a", "node_id": "I_1", "labels": [],
             "milestone": {"title": "v2", "state": "open"}}
            """
        }
        let oldIssue = "[\(issue("Old", state: "open"))]"
        let closedIssue = issue("New title", state: "closed")
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path == "/issues" { return oldIssue }
            if path == "/graphql" { return #"{"data": {"nodes": [{"id": "I_1", "projectItems": {"nodes": []}}]}}"# }
            return closedIssue
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        await store.syncGitHub()
        let id = store.tickets[0].id
        XCTAssertEqual(store.tickets[0].title, "Old")

        await store.refreshTicket(id)

        XCTAssertEqual(store.tickets[0].title, "New title")
        XCTAssertEqual(store.tickets[0].milestone?.title, "v2")
        XCTAssertEqual(store.tickets[0].status, .done)
        XCTAssertTrue(store.tickets[0].github!.remoteClosed)
    }

    func testIssueFieldsAndTypeAreParsed() async throws {
        let fieldsBody = """
        [{"issue_field_id": 1, "issue_field_name": "Priority", "node_id": "a", "data_type": "single_select", "value": "High",
          "single_select_option": {"id": 10, "name": "High", "color": "orange"}},
         {"issue_field_id": 2, "issue_field_name": "Effort", "node_id": "b", "data_type": "single_select", "value": "Low",
          "single_select_option": {"id": 11, "name": "Low", "color": "green"}},
         {"issue_field_id": 3, "issue_field_name": "Start date", "node_id": "c", "data_type": "date", "value": "2026-10-05"},
         {"issue_field_id": 4, "issue_field_name": "Target date", "node_id": "d", "data_type": "date", "value": "2026-10-20"},
         {"issue_field_id": 5, "issue_field_name": "Points", "node_id": "e", "data_type": "number", "value": 3}]
        """
        let issueBody = """
        [{"number": 1, "title": "A", "body": null, "html_url": "https://github.com/me/a/issues/1",
          "repository_url": "https://api.github.com/repos/me/a", "labels": [], "type": {"name": "Bug", "color": "red"}}]
        """
        let client = GitHubClient(token: "t", transport: StubTransport { request in
            request.url?.path.hasSuffix("/issue-field-values") == true ? fieldsBody : issueBody
        })

        let issue = try await client.fetchAssignedIssues()[0]
        XCTAssertEqual(issue.issueType, IssueType(name: "Bug", color: "red"))

        let fields = try await client.fetchIssueFields(repo: "me/a", number: 1)
        XCTAssertEqual(fields.map(\.name), ["Priority", "Effort", "Start date", "Target date", "Points"])
        XCTAssertEqual(fields[0].value, "High")
        XCTAssertEqual(fields[0].color, "orange")
        XCTAssertEqual(fields[2].kind, .date)
        XCTAssertNotNil(fields[3].start)
        XCTAssertEqual(fields[4].value, "3")
        XCTAssertEqual(fields[0].project, CustomField.issueFieldsGroup)

        var ticket = Ticket(title: "A", issueFields: fields)
        XCTAssertEqual(ticket.field(named: "priority")?.value, "High")
        ticket.fields = [CustomField(name: "Sprint", value: "S1", kind: .iteration, project: "P")]
        XCTAssertEqual(ticket.allFields.count, 6)

        let bulk = await client.fetchIssueFields(for: [issue])
        XCTAssertEqual(bulk[issue.key]?.count, 5)
    }

    func testMergeKeepsPreviousFieldsWhenNotFetched() {
        var issue = RemoteIssue(repo: "me/a", number: 1, title: "T", url: "u", milestone: Milestone(title: "v1"), fields: [CustomField(name: "RCA", value: "x", kind: .text, project: "P")])
        var tickets = AppStore.merge(existing: [], remote: [issue])
        XCTAssertEqual(tickets[0].fields?.count, 1)

        issue.fields = nil
        tickets = AppStore.merge(existing: tickets, remote: [issue])
        XCTAssertEqual(tickets[0].fields?.count, 1)
        XCTAssertEqual(tickets[0].milestone?.title, "v1")
    }
}
