import XCTest
@testable import FocusCore

final class CollapseTests: XCTestCase {
    func testShortThreadStartsExpanded() {
        XCTAssertFalse(Collapse.commentsAreLong([]))
        XCTAssertFalse(Collapse.commentsAreLong(Array(repeating: "ok", count: 5)))
    }

    func testManyOrLongCommentsStartCollapsed() {
        XCTAssertTrue(Collapse.commentsAreLong(Array(repeating: "ok", count: 6)))
        XCTAssertTrue(Collapse.commentsAreLong([String(repeating: "a", count: 2001)]))
    }
}
