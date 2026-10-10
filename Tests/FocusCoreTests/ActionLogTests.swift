import XCTest
@testable import FocusCore

@MainActor
final class ActionLogTests: XCTestCase {
    private func makeStore() -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url)
    }

    func testChangesListsOnlyDifferences() {
        let old = Ticket(title: "A", status: .todo, labels: ["bug"], milestone: Milestone(title: "v1"))
        var new = old
        new.status = .done
        new.labels = ["bug", "ui"]
        new.milestone = nil

        let changes = old.changes(to: new)

        XCTAssertEqual(Set(changes.map(\.field)), ["Status", "Labels", "Milestone"])
        let labels = changes.first { $0.field == "Labels" }!
        XCTAssertEqual(labels.oldList, ["bug"])
        XCTAssertEqual(labels.newList, ["bug", "ui"])
        let milestone = changes.first { $0.field == "Milestone" }!
        XCTAssertEqual(milestone.old, "v1")
        XCTAssertEqual(milestone.new, "None")
        XCTAssertTrue(old.changes(to: old).isEmpty)
    }
}
