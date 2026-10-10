import XCTest
@testable import FocusCore

final class SpecialWorkTests: XCTestCase {
    private func ticket(_ labels: [String], url: String? = nil) -> Ticket {
        Ticket(title: "t", labels: labels, github: url.map { GitHubRef(repo: "acme/api", number: 1, url: $0) })
    }

    func testLabelsMatchIgnoringCaseAndSeparators() {
        XCTAssertEqual(ticket(["Data Migration"]).specialWork, [.dataMigration])
        XCTAssertEqual(ticket(["data-migration"]).specialWork, [.dataMigration])
        XCTAssertEqual(ticket(["Script"]).specialWork, [.script])
        XCTAssertEqual(ticket(["Script", "datamigration"]).specialWork, [.dataMigration, .script])
        XCTAssertTrue(ticket(["bug", "scripting"]).specialWork.isEmpty)
    }

    func testLinkTextIsCategorisedAndSkipsLocalAndDuplicates() {
        let a = ticket(["Data Migration"], url: "https://github.com/acme/api/issues/1")
        let b = ticket(["Script"], url: "https://github.com/acme/api/issues/2")
        let c = ticket(["Script"], url: "https://github.com/acme/api/issues/3")
        let local = ticket(["Script"])
        XCTAssertEqual(
            SpecialWork.linkText(for: [(.dataMigration, [a, a]), (.script, [b, local, c])]),
            """
            Data migrations:
                 https://github.com/acme/api/issues/1
            Scripts:
                 https://github.com/acme/api/issues/2
                 https://github.com/acme/api/issues/3
            """
        )
        XCTAssertEqual(SpecialWork.linkText(for: [(.dataMigration, []), (.script, [local])]), "")
    }
}
