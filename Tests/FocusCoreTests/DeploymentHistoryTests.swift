import XCTest
@testable import FocusCore

final class DeploymentHistoryTests: XCTestCase {
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func move(_ to: String, _ at: String, project: String = "Board", by: String? = "sajana") -> StatusMove {
        StatusMove(project: project, from: "Other", to: to, at: date(at), by: by)
    }

    // MARK: Names

    func testHistoryNamesRecogniseMergedToEnvironments() {
        XCTAssertEqual(DeploymentEnvironment(deploymentName: "💯 Merged to Beta"), .beta)
        XCTAssertEqual(DeploymentEnvironment(deploymentName: "Merged to Alpha"), .alpha)
        XCTAssertEqual(DeploymentEnvironment(deploymentName: "Merged to Alpha 2"), .alpha2)
        XCTAssertEqual(DeploymentEnvironment(deploymentName: "merged into alpha2"), .alpha2)
        XCTAssertEqual(DeploymentEnvironment(deploymentName: "Merged to Live"), .live)
        XCTAssertEqual(DeploymentEnvironment(deploymentName: "Deployed to Beta"), .beta)
    }

    func testHistoryNamesIgnoreNonDeployments() {
        for name in ["1️⃣ Prioritised", "Ready for Beta", "Merged", "Merged to main", "In Review", "Alpha testing", ""] {
            XCTAssertNil(DeploymentEnvironment(deploymentName: name), name)
        }
    }

    func testStatusMappingIsUnchangedByMergedNames() {
        XCTAssertNil(DeploymentEnvironment(statusName: "💯 Merged to Beta"))
        XCTAssertEqual(TicketStatus(optionName: "💯 Merged to Beta"), .done)
    }

    // MARK: Last deployment

    func testTheLastMoveToAnEnvironmentWinsWhateverTheOrder() {
        let moves = [
            move("Testing", "2026-01-18T09:00:00Z"),
            move("💯 Merged to Beta", "2026-01-16T09:00:00Z"),
            move("Merged to Alpha", "2026-01-10T09:00:00Z"),
            move("In Review", "2026-01-12T09:00:00Z")
        ]
        let mark = DeploymentHistory.lastDeployment(in: moves, project: nil)
        XCTAssertEqual(mark?.environment, .beta)
        XCTAssertEqual(mark?.statusName, "💯 Merged to Beta")
        XCTAssertEqual(mark?.movedAt, date("2026-01-16T09:00:00Z"))
        XCTAssertEqual(mark?.movedBy, "sajana")
    }

    func testRepeatedMovesToDifferentEnvironmentsUseTheLatest() {
        let moves = [move("Merged to Beta", "2026-01-16T09:00:00Z"), move("Merged to Alpha2", "2026-01-20T09:00:00Z")]
        XCTAssertEqual(DeploymentHistory.lastDeployment(in: moves, project: nil)?.environment, .alpha2)
    }

    func testNoEnvironmentMoveGivesNil() {
        XCTAssertNil(DeploymentHistory.lastDeployment(in: [move("In Review", "2026-01-12T09:00:00Z")], project: nil))
        XCTAssertNil(DeploymentHistory.lastDeployment(in: [], project: nil))
    }

    func testOnlyTheTicketsOwnProjectCountsWhenKnown() {
        let moves = [
            move("Merged to Beta", "2026-01-16T09:00:00Z", project: "Web"),
            move("Merged to Alpha", "2026-01-20T09:00:00Z", project: "Mobile")
        ]
        XCTAssertEqual(DeploymentHistory.lastDeployment(in: moves, project: "Web")?.environment, .beta)
        XCTAssertEqual(DeploymentHistory.lastDeployment(in: moves, project: nil)?.environment, .alpha)
        XCTAssertNil(DeploymentHistory.lastDeployment(in: moves, project: "Other"))
    }

    // MARK: Ticket.environment

    private func ticket(status: String?, deployment: DeploymentEnvironment? = nil) -> Ticket {
        let fields = status.map { [CustomField(name: "Status", value: $0, kind: .select, project: "Board")] }
        var ticket = Ticket(title: "T", fields: fields, github: GitHubRef(repo: "o/r", number: 1, url: "u"))
        ticket.deployment = deployment.map { DeploymentMark(environment: $0, statusName: "x", movedAt: Date(), movedBy: nil) }
        return ticket
    }

    func testEnvironmentFallsBackToHistoryWhenTheStatusMovedOn() {
        XCTAssertEqual(ticket(status: "In Progress", deployment: .beta).environment, .beta)
        XCTAssertEqual(ticket(status: nil, deployment: .alpha).environment, .alpha)
    }

    func testCurrentDeploymentStatusBeatsHistory() {
        XCTAssertEqual(ticket(status: "Deployed to Beta", deployment: .alpha).environment, .beta)
        XCTAssertEqual(ticket(status: "💯 Merged to Beta").environment, .beta)
    }

    func testNoHistoryAndNoDeploymentStatusMeansNoEnvironment() {
        XCTAssertNil(ticket(status: "In Progress").environment)
    }

    func testOlderDataFilesWithoutDeploymentStillLoad() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Ticket(title: "T"))) as! [String: Any]
        XCTAssertNil(object["deployment"])
        object["deployment"] = nil
        let decoded = try JSONDecoder().decode(Ticket.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.deployment)
    }

    func testDeploymentRoundTrips() throws {
        let mark = DeploymentMark(environment: .beta, statusName: "Merged to Beta", movedAt: Date(timeIntervalSince1970: 1_700_000_000), movedBy: "a")
        let data = try JSONEncoder().encode(Ticket(title: "T", deployment: mark))
        XCTAssertEqual(try JSONDecoder().decode(Ticket.self, from: data).deployment, mark)
    }
}

final class StatusMoveClientTests: XCTestCase {
    private let body = """
    {"data":{"nodes":[
      {"id":"I_1","timelineItems":{"nodes":[
        {"createdAt":"2026-01-10T09:00:00Z","previousStatus":"Prioritised","status":"Merged to Alpha","project":{"title":"Web"},"actor":{"login":"sajana"}},
        {"createdAt":"2026-01-16T09:00:00Z","previousStatus":"Merged to Alpha","status":"💯 Merged to Beta","project":{"title":"Web"},"actor":null},
        {}, null
      ]}},
      {"id":"I_2","timelineItems":{"nodes":[]}},
      {"id":"I_3"},
      null
    ]}}
    """

    func testDecodesMovesPerIssueAndToleratesGaps() async throws {
        let transport = RecordingTransport { _ in (200, self.body) }
        let result = try await GitHubClient(token: "t", transport: transport).fetchStatusMoves(nodeIDs: ["I_1", "I_2", "I_3"])

        XCTAssertEqual(result["I_1"]?.map(\.to), ["Merged to Alpha", "💯 Merged to Beta"])
        XCTAssertEqual(result["I_1"]?[0].from, "Prioritised")
        XCTAssertEqual(result["I_1"]?[0].project, "Web")
        XCTAssertEqual(result["I_1"]?[0].by, "sajana")
        XCTAssertNil(result["I_1"]?[1].by)
        XCTAssertEqual(result["I_2"], [])
        XCTAssertNil(result["I_3"])
        XCTAssertEqual(transport.requests[0].url?.path, "/graphql")
        let query = transport.json(0)?["query"] as? String ?? ""
        XCTAssertTrue(query.contains("PROJECT_V2_ITEM_STATUS_CHANGED_EVENT"))
    }

    func testBatchesOf50() async throws {
        let transport = RecordingTransport { _ in (200, #"{"data":{"nodes":[]}}"#) }
        _ = try await GitHubClient(token: "t", transport: transport).fetchStatusMoves(nodeIDs: (0..<120).map { "I_\($0)" })
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testGraphQLErrorWithoutDataIsThrown() async {
        let transport = RecordingTransport { _ in (200, #"{"errors":[{"message":"Unknown type"}]}"#) }
        do {
            _ = try await GitHubClient(token: "t", transport: transport).fetchStatusMoves(nodeIDs: ["I_1"])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Unknown type")
        }
    }
}

@MainActor
final class DeploymentSyncTests: XCTestCase {
    private let issue = """
    {"number": 1, "title": "One", "body": null, "state": "open", "html_url": "https://github.com/me/a/issues/1",
     "repository_url": "https://api.github.com/repos/me/a", "node_id": "I_1", "labels": []}
    """
    private let moves = """
    {"data":{"nodes":[{"id":"I_1","timelineItems":{"nodes":[
      {"createdAt":"2026-01-10T09:00:00Z","previousStatus":"Prioritised","status":"Merged to Alpha","project":{"title":"Web"},"actor":{"login":"sajana"}},
      {"createdAt":"2026-01-16T09:00:00Z","previousStatus":"Merged to Alpha","status":"💯 Merged to Beta","project":{"title":"Web"},"actor":{"login":"sajana"}},
      {"createdAt":"2026-01-18T09:00:00Z","previousStatus":"💯 Merged to Beta","status":"QA Testing","project":{"title":"Web"},"actor":{"login":"qa"}}
    ]}}]}}
    """

    private func makeStore(timeline: @escaping @Sendable () -> (Int, String)) -> AppStore {
        let issue = self.issue
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            if path == "/issues" { return (200, "[\(issue)]") }
            if path == "/repos/me/a/issues/1" { return (200, issue) }
            if path == "/graphql" {
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                if body.contains("timelineItems") { return timeline() }
                return (200, #"{"data":{"nodes":[{"id":"I_1","projectItems":{"nodes":[]}}]}}"#)
            }
            return (200, "{}")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
    }

    func testSyncFindsTheEnvironmentFromTheLastDeploymentMove() async {
        let moves = self.moves
        let store = makeStore { (200, moves) }
        await store.syncGitHub()

        let ticket = store.tickets[0]
        XCTAssertEqual(ticket.deployment?.environment, .beta)
        XCTAssertEqual(ticket.environment, .beta)
        XCTAssertEqual(ticket.deployment?.statusName, "💯 Merged to Beta")
        XCTAssertEqual(ticket.deployment?.movedBy, "sajana")
    }

    func testTicketAppearsInTheBetaQueueAfterItsStatusMovedOn() async {
        let moves = self.moves
        let store = makeStore { (200, moves) }
        await store.syncGitHub()

        XCTAssertEqual(store.qaQueue(environment: .beta).ready.count, 1)
        XCTAssertTrue(store.qaQueue(environment: .alpha).ready.isEmpty)
    }

    func testAFailedHistoryFetchKeepsThePreviousDeployment() async {
        let moves = self.moves
        let failing = Switch(false)
        let store = makeStore { failing.isOn ? (500, "{}") : (200, moves) }
        await store.syncGitHub()
        XCTAssertEqual(store.tickets[0].deployment?.environment, .beta)

        failing.isOn = true
        await store.syncGitHub()
        XCTAssertEqual(store.tickets[0].deployment?.environment, .beta)
        XCTAssertNotNil(store.tickets[0].github)
    }

    func testNoDeploymentMovesClearsTheDeployment() async {
        let withMoves = self.moves
        let empty = #"{"data":{"nodes":[{"id":"I_1","timelineItems":{"nodes":[]}}]}}"#
        let cleared = Switch(false)
        let store = makeStore { cleared.isOn ? (200, empty) : (200, withMoves) }
        await store.syncGitHub()
        cleared.isOn = true
        await store.syncGitHub()
        XCTAssertNil(store.tickets[0].deployment)
    }

    func testRefreshTicketUpdatesTheDeployment() async {
        let moves = self.moves
        let store = makeStore { (200, moves) }
        await store.syncGitHub()
        let id = store.tickets[0].id
        store.clearDeploymentForTest(id)
        XCTAssertNil(store.tickets[0].deployment)

        await store.refreshTicket(id, minimumInterval: 0)
        XCTAssertEqual(store.tickets[0].deployment?.environment, .beta)
    }
}
