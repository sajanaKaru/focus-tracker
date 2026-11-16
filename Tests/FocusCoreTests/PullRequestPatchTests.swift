import XCTest
@testable import FocusCore

final class PullRequestPatchTests: XCTestCase {
    private let page = #"[{"filename":"Sources/Login.swift","status":"modified","patch":"@@ -1 +1 @@\n-old\n+new"},{"filename":"logo.png","status":"added"}]"#

    private func files(_ count: Int) -> String {
        let items = (0..<count).map { #"{"filename":"f\#($0).swift","status":"added","patch":"+x"}"# }
        return "[" + items.joined(separator: ",") + "]"
    }

    func testFetchesPatchesAndKeepsMissingOnesAsNil() async throws {
        let transport = RecordingTransport { _ in (200, self.page) }
        let result = try await GitHubClient(token: "gh-token", transport: transport).fetchPullRequestPatches(repo: "me/a", number: 9)

        XCTAssertEqual(result.map(\.path), ["Sources/Login.swift", "logo.png"])
        XCTAssertEqual(result[0].status, "modified")
        XCTAssertEqual(result[0].patch, "@@ -1 +1 @@\n-old\n+new")
        XCTAssertNil(result[1].patch)

        let request = transport.requests[0]
        XCTAssertEqual(request.url?.host, "api.github.com")
        XCTAssertEqual(request.url?.path, "/repos/me/a/pulls/9/files")
        XCTAssertTrue(request.url?.query?.contains("per_page=100") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gh-token")
    }

    func testFollowsPagesUntilAShortPageAndStopsAtThree() async throws {
        let full = files(100), short = files(2)
        let transport = RecordingTransport { request in
            request.url?.query?.contains("page=2") == true ? (200, short) : (200, full)
        }
        let result = try await GitHubClient(token: "t", transport: transport).fetchPullRequestPatches(repo: "me/a", number: 9)
        XCTAssertEqual(result.count, 102)
        XCTAssertEqual(transport.requests.count, 2)

        let endless = RecordingTransport { _ in (200, full) }
        let capped = try await GitHubClient(token: "t", transport: endless).fetchPullRequestPatches(repo: "me/a", number: 9)
        XCTAssertEqual(capped.count, 300)
        XCTAssertEqual(endless.requests.count, 3)
    }

    func testRejectsARepoThatCouldChangeTheURL() async {
        let transport = RecordingTransport { _ in (200, "[]") }
        for repo in ["me/a?x=1", "me/a#frag", "me/../a", "me"] {
            do {
                _ = try await GitHubClient(token: "t", transport: transport).fetchPullRequestPatches(repo: repo, number: 9)
                XCTFail("expected failure for \(repo)")
            } catch {
                guard case .invalidResponse? = error as? GitHubError else { XCTFail("wrong error for \(repo): \(error)"); continue }
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testHTTPErrorsSurface() async {
        let transport = RecordingTransport { _ in (403, "{}") }
        do {
            _ = try await GitHubClient(token: "t", transport: transport).fetchPullRequestPatches(repo: "me/a", number: 9)
            XCTFail("expected failure")
        } catch {
            guard case .http(403)? = error as? GitHubError else { return XCTFail("wrong error: \(error)") }
        }
    }
}
