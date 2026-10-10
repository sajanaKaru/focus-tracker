import XCTest
@testable import FocusCore

final class GitHubEditsTests: XCTestCase {
    private let lookup = """
    {"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"id":"PVT_1","title":"Board","fields":{"nodes":[
      {"id":"F_RCA","name":"RCA"},
      {"id":"F_ST","name":"Status","options":[{"id":"o1","name":"Todo","color":"GRAY"},{"id":"o2","name":"Done","color":"GREEN"}]}]}}}]}}}}}
    """

    func testOptionReads() async throws {
        let lookup = self.lookup
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            if path == "/repos/me/a/labels" { return (200, #"[{"name":"bug","color":"d73a4a"},{"name":"ui","color":"0075ca"}]"#) }
            if path == "/repos/me/a/milestones" { return (200, #"[{"number":3,"title":"v3","state":"open","due_on":"2026-12-01T08:00:00Z"},{"number":2,"title":"v2","state":"closed","due_on":null}]"#) }
            if path == "/orgs/me/issue-fields" { return (200, #"[{"id":9,"name":"Priority","data_type":"single_select","options":[{"id":1,"name":"High","color":"red"}]},{"id":8,"name":"Target date","data_type":"date","options":null}]"#) }
            return (200, lookup)
        }
        let client = GitHubClient(token: "t", transport: transport)

        let labels = try await client.fetchLabels(repo: "me/a")
        XCTAssertEqual(labels, [LabelOption(name: "bug", color: "d73a4a"), LabelOption(name: "ui", color: "0075ca")])
        let milestones = try await client.fetchMilestones(repo: "me/a")
        XCTAssertEqual(milestones.map(\.title), ["v3", "v2"])
        XCTAssertEqual(milestones.map(\.isOpen), [true, false])
        XCTAssertNotNil(milestones[0].dueOn)
        let defs = try await client.fetchOrgIssueFields(org: "me")
        XCTAssertEqual(defs[0], IssueFieldDefinition(id: 9, name: "Priority", dataType: "single_select", options: [FieldOption(name: "High", color: "red")]))
        XCTAssertEqual(defs[1].options, [])
        let status = try await client.fetchProjectOptions(repo: "me/a", number: 1, field: "Status")
        XCTAssertEqual(status["Board"]?.map(\.name), ["Todo", "Done"])
        XCTAssertEqual(status["Board"]?.first?.color, "gray")
        let orgRequest = transport.requests.first { $0.url?.path == "/orgs/me/issue-fields" }
        XCTAssertEqual(orgRequest?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testProjectOptionWriteSendsOptionID() async throws {
        let lookup = self.lookup
        let transport = RecordingTransport { request in
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("updateProjectV2ItemFieldValue") == true
                ? (200, #"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"x"}}}}"#)
                : (200, lookup)
        }
        let client = GitHubClient(token: "t", transport: transport)

        try await client.updateProjectField(repo: "me/a", number: 1, project: "Board", field: "Status", value: .option("Done"))

        let variables = transport.json(1)?["variables"] as? [String: Any]
        XCTAssertEqual((variables?["value"] as? [String: Any])?["singleSelectOptionId"] as? String, "o2")
        XCTAssertEqual(variables?["field"] as? String, "F_ST")
    }

    func testUnknownOptionThrows() async {
        let lookup = self.lookup
        let client = GitHubClient(token: "t", transport: RecordingTransport { _ in (200, lookup) })
        do {
            try await client.updateProjectField(repo: "me/a", number: 1, project: "Board", field: "Status", value: .option("Nope"))
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nope"))
        }
    }

    private func method(_ t: RecordingTransport, _ i: Int) -> String { t.requests[i].httpMethod ?? "" }

    func testApplyLabelsMilestoneTitleAndState() async throws {
        let transport = RecordingTransport { _ in (200, "{}") }
        let client = GitHubClient(token: "t", transport: transport)

        try await client.apply(.labels(["bug", "ui"]), repo: "me/a", number: 1)
        try await client.apply(.milestone(number: 3), repo: "me/a", number: 1)
        try await client.apply(.milestone(number: nil), repo: "me/a", number: 1)
        try await client.apply(.title("New"), repo: "me/a", number: 1)
        try await client.apply(.state(open: false), repo: "me/a", number: 1)
        try await client.apply(.state(open: true), repo: "me/a", number: 1)

        XCTAssertEqual(method(transport, 0), "PUT")
        XCTAssertEqual(transport.requests[0].url?.path, "/repos/me/a/issues/1/labels")
        XCTAssertEqual(transport.json(0)?["labels"] as? [String], ["bug", "ui"])
        XCTAssertEqual(method(transport, 1), "PATCH")
        XCTAssertEqual(transport.requests[1].url?.path, "/repos/me/a/issues/1")
        XCTAssertEqual(transport.json(1)?["milestone"] as? Int, 3)
        XCTAssertTrue(transport.json(2)?["milestone"] is NSNull)
        XCTAssertEqual(transport.json(3)?["title"] as? String, "New")
        XCTAssertEqual(transport.json(4)?["state"] as? String, "closed")
        XCTAssertEqual(transport.json(4)?["state_reason"] as? String, "completed")
        XCTAssertEqual(transport.json(5)?["state"] as? String, "open")
    }

    func testSetIssueFieldKeepsOtherValuesAndUsesOrgFieldID() async throws {
        let current = """
        [{"issue_field_id":1,"issue_field_name":"Priority","data_type":"single_select","value":"High","single_select_option":{"id":10,"name":"High","color":"red"}},
         {"issue_field_id":5,"issue_field_name":"Points","data_type":"number","value":3}]
        """
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.hasSuffix("/issue-field-values") { return (200, current) }
            if request.httpMethod == "GET", path == "/orgs/me/issue-fields" { return (200, #"[{"id":8,"name":"Target date","data_type":"date","options":null}]"#) }
            return (200, "[]")
        }
        let client = GitHubClient(token: "t", transport: transport)

        try await client.setIssueField(repo: "me/a", number: 1, name: "Target date", value: .string("2026-12-01"))

        let put = transport.requests.last!
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.path, "/repos/me/a/issues/1/issue-field-values")
        XCTAssertEqual(put.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        let body = try JSONSerialization.jsonObject(with: put.httpBody!) as! [String: Any]
        let values = body["issue_field_values"] as! [[String: Any]]
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.first { ($0["field_id"] as? Int) == 1 }?["value"] as? String, "High")
        XCTAssertEqual(values.first { ($0["field_id"] as? Int) == 5 }?["value"] as? Int, 3)
        XCTAssertEqual(values.first { ($0["field_id"] as? Int) == 8 }?["value"] as? String, "2026-12-01")
    }

    func testClearIssueFieldDeletesOnlyThatValue() async throws {
        let current = #"[{"issue_field_id":4,"issue_field_name":"Target date","data_type":"date","value":"2026-10-20"}]"#
        let transport = RecordingTransport { request in
            request.httpMethod == "GET" ? (200, current) : (204, "")
        }
        let client = GitHubClient(token: "t", transport: transport)

        try await client.apply(.issueField(name: "Target date", value: nil), repo: "me/a", number: 1)

        let last = transport.requests.last!
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(last.url?.path, "/repos/me/a/issues/1/issue-field-values/4")
    }

    func testMissingOrgFieldThrows() async {
        let client = GitHubClient(token: "t", transport: RecordingTransport { _ in (200, "[]") })
        do {
            try await client.setIssueField(repo: "me/a", number: 1, name: "Target date", value: .string("2026-12-01"))
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Target date"))
        }
    }

    func testApplyProjectFieldForwardsToProjectMutation() async throws {
        let lookup = self.lookup
        let transport = RecordingTransport { request in
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("updateProjectV2ItemFieldValue") == true
                ? (200, #"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"x"}}}}"#)
                : (200, lookup)
        }
        let client = GitHubClient(token: "t", transport: transport)
        try await client.apply(.projectField(project: "Board", field: "Status", value: .option("Done")), repo: "me/a", number: 1)
        XCTAssertEqual(transport.requests.count, 2)
    }
}
