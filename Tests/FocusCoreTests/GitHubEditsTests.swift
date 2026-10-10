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
}
