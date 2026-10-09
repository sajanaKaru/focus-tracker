import XCTest
@testable import FocusCore

private struct BodyTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (Data(handler(request).utf8), response)
    }
}

final class PullRequestClientTests: XCTestCase {
    private let sample = """
    {"data":{"search":{"issueCount":2,"nodes":[
      {"number":12,"title":"Add login","url":"https://github.com/me/a/pull/12","isDraft":false,
       "createdAt":"2026-10-01T08:00:00Z","updatedAt":"2026-10-08T09:30:00Z",
       "reviewDecision":"CHANGES_REQUESTED","mergeable":"CONFLICTING",
       "repository":{"nameWithOwner":"me/a"},
       "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
      {"number":7,"title":"Draft thing","url":"https://github.com/me/b/pull/7","isDraft":true,
       "createdAt":"2026-10-05T08:00:00Z","updatedAt":"2026-10-05T08:00:00Z",
       "reviewDecision":null,"mergeable":"UNKNOWN",
       "repository":{"nameWithOwner":"me/b"},
       "commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}},
      {}, null
    ]}}}
    """

    func testParsesPullRequestsAndSkipsEmptyNodes() async throws {
        let client = GitHubClient(token: "t", transport: BodyTransport { _ in self.sample })
        let result = try await client.fetchOpenPullRequests(authoredBy: "octo")

        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.items.count, 2)

        let first = result.items[0]
        XCTAssertEqual(first.repo, "me/a")
        XCTAssertEqual(first.number, 12)
        XCTAssertEqual(first.title, "Add login")
        XCTAssertEqual(first.url, "https://github.com/me/a/pull/12")
        XCTAssertEqual(first.review, .changesRequested)
        XCTAssertEqual(first.ci, .failing)
        XCTAssertTrue(first.hasConflicts)
        XCTAssertFalse(first.isDraft)
        XCTAssertEqual(first.updatedAt, ISO8601DateFormatter().date(from: "2026-10-08T09:30:00Z"))

        let second = result.items[1]
        XCTAssertTrue(second.isDraft)
        XCTAssertEqual(second.review, .waiting)
        XCTAssertEqual(second.ci, .noChecks)
        XCTAssertFalse(second.hasConflicts)
    }

    func testSendsAnAuthoredOpenPullRequestSearchToGraphQL() async throws {
        final class Seen: @unchecked Sendable { var path = ""; var body = "" }
        let seen = Seen()
        let client = GitHubClient(token: "t", transport: BodyTransport { request in
            seen.path = request.url?.path ?? ""
            seen.body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return self.sample
        })
        _ = try await client.fetchOpenPullRequests(authoredBy: "octo")

        XCTAssertEqual(seen.path, "/graphql")
        XCTAssertTrue(seen.body.contains("is:pr is:open author:octo"))
        XCTAssertTrue(seen.body.contains("statusCheckRollup"))
    }

    func testUnknownEnumValuesFallBackToNeutral() async throws {
        let body = """
        {"data":{"search":{"issueCount":1,"nodes":[
          {"number":1,"title":"T","url":"https://github.com/me/a/pull/1","isDraft":false,
           "createdAt":"2026-10-01T08:00:00Z","updatedAt":"2026-10-01T08:00:00Z",
           "reviewDecision":"SOMETHING_NEW","mergeable":"SOMETHING_ELSE",
           "repository":{"nameWithOwner":"me/a"},
           "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"WEIRD"}}}]}}
        ]}}}
        """
        let client = GitHubClient(token: "t", transport: BodyTransport { _ in body })
        let item = try await client.fetchOpenPullRequests(authoredBy: "octo").items[0]
        XCTAssertEqual(item.review, .waiting)
        XCTAssertEqual(item.ci, .noChecks)
        XCTAssertFalse(item.hasConflicts)
    }

    func testGraphQLErrorWithoutDataIsThrown() async {
        let body = #"{"errors":[{"message":"Resource not accessible by personal access token"}]}"#
        let client = GitHubClient(token: "t", transport: BodyTransport { _ in body })
        do {
            _ = try await client.fetchOpenPullRequests(authoredBy: "octo")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Resource not accessible by personal access token")
        }
    }
}
