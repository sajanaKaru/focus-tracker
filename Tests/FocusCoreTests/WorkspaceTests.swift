import XCTest
@testable import FocusCore

final class WorkspaceTests: XCTestCase {
    func testOwnerMapsToPersonalOrOrganization() {
        XCTAssertEqual(Workspace.of(repo: "Sajana/app", login: "sajana"), .personal)
        XCTAssertEqual(Workspace.of(repo: "acme/api", login: "sajana"), .organization("acme"))
    }

    func testContains() {
        XCTAssertTrue(Workspace.all.contains(repo: "acme/api", login: "sajana"))
        XCTAssertTrue(Workspace.personal.contains(repo: nil, login: "sajana"))
        XCTAssertFalse(Workspace.organization("acme").contains(repo: nil, login: "sajana"))
        XCTAssertTrue(Workspace.organization("ACME").contains(repo: "acme/api", login: "sajana"))
        XCTAssertFalse(Workspace.personal.contains(repo: "acme/api", login: "sajana"))
    }

    func testStorageRoundTrip() {
        for workspace in [Workspace.all, .personal, .organization("acme")] {
            XCTAssertEqual(Workspace(storageValue: workspace.storageValue), workspace)
        }
    }
}
