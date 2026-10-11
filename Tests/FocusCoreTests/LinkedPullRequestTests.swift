import XCTest
@testable import FocusCore

final class LinkedPullRequestTests: XCTestCase {
    private let linked = """
    {"data":{"repository":{"issue":{"timelineItems":{"nodes":[
      {"source":{"number":9,"title":"Add login","url":"https://github.com/me/a/pull/9","state":"OPEN","repository":{"nameWithOwner":"me/a"}}},
      {"subject":{"number":9,"title":"Add login","url":"https://github.com/me/a/pull/9","state":"OPEN","repository":{"nameWithOwner":"me/a"}}},
      {"source":{"number":3,"title":"Fix typo","url":"https://github.com/me/b/pull/3","state":"MERGED","repository":{"nameWithOwner":"me/b"}}},
      {"source":{}},
      {}, null
    ]}}}}}
    """

    func testDecodesLinkedPullRequestsDedupedAndSkippingNonPullRequests() async throws {
        let transport = RecordingTransport { _ in (200, self.linked) }
        let result = try await GitHubClient(token: "t", transport: transport).fetchLinkedPullRequests(repo: "me/a", number: 4)

        XCTAssertEqual(result.map(\.id), ["me/a#9", "me/b#3"])
        XCTAssertEqual(result[1].state, "MERGED")
        XCTAssertEqual(result[0].title, "Add login")
        XCTAssertEqual(transport.requests[0].url?.path, "/graphql")
        let variables = transport.json(0)?["variables"] as? [String: Any]
        XCTAssertEqual(variables?["owner"] as? String, "me")
        XCTAssertEqual(variables?["name"] as? String, "a")
        XCTAssertEqual(variables?["number"] as? Int, 4)
    }

    func testNoLinkedPullRequests() async throws {
        let body = #"{"data":{"repository":{"issue":{"timelineItems":{"nodes":[]}}}}}"#
        let transport = RecordingTransport { _ in (200, body) }
        let result = try await GitHubClient(token: "t", transport: transport).fetchLinkedPullRequests(repo: "me/a", number: 4)
        XCTAssertTrue(result.isEmpty)
    }

    func testMissingIssueThrows() async {
        let transport = RecordingTransport { _ in (200, #"{"data":{"repository":{"issue":null}}}"#) }
        do {
            _ = try await GitHubClient(token: "t", transport: transport).fetchLinkedPullRequests(repo: "me/a", number: 4)
            XCTFail("expected failure")
        } catch {
            guard case GitHubError.invalidResponse = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testGraphQLErrorsSurface() async {
        let transport = RecordingTransport { _ in (200, #"{"errors":[{"message":"Bad things"}]}"#) }
        do {
            _ = try await GitHubClient(token: "t", transport: transport).fetchLinkedPullRequests(repo: "me/a", number: 4)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Bad things")
        }
    }

    func testRejectsARepoWithoutOwner() async {
        let transport = RecordingTransport { _ in (200, "{}") }
        do {
            _ = try await GitHubClient(token: "t", transport: transport).fetchLinkedPullRequests(repo: "justname", number: 1)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testDecodesPullRequestDetail() async throws {
        let body = #"{"data":{"repository":{"pullRequest":{"title":"Add login","body":null,"files":{"nodes":[{"path":"a.swift"},null,{"path":"b.swift"}]}}}}}"#
        let transport = RecordingTransport { _ in (200, body) }
        let detail = try await GitHubClient(token: "t", transport: transport).fetchPullRequestDetail(repo: "me/a", number: 9)
        XCTAssertEqual(detail, PullRequestDetail(repo: "me/a", number: 9, title: "Add login", body: "", files: ["a.swift", "b.swift"]))
    }
}
