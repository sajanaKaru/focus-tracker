import XCTest
@testable import FocusCore

final class PullRequestModelTests: XCTestCase {
    private func pr(
        _ number: Int, draft: Bool = false, review: ReviewState = .waiting, ci: CIState = .noChecks,
        conflicts: Bool = false, updated: Double = 0
    ) -> PullRequestItem {
        PullRequestItem(
            repo: "me/a", number: number, title: "PR \(number)", url: "https://github.com/me/a/pull/\(number)",
            isDraft: draft, review: review, ci: ci, hasConflicts: conflicts,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    func testReviewDecisionMapping() {
        XCTAssertEqual(ReviewState(decision: "APPROVED"), .approved)
        XCTAssertEqual(ReviewState(decision: "CHANGES_REQUESTED"), .changesRequested)
        XCTAssertEqual(ReviewState(decision: "REVIEW_REQUIRED"), .waiting)
        XCTAssertEqual(ReviewState(decision: nil), .waiting)
        XCTAssertEqual(ReviewState(decision: "SOMETHING_NEW"), .waiting)
    }

    func testCIStateMapping() {
        XCTAssertEqual(CIState(rollup: "SUCCESS"), .passing)
        XCTAssertEqual(CIState(rollup: "FAILURE"), .failing)
        XCTAssertEqual(CIState(rollup: "ERROR"), .failing)
        XCTAssertEqual(CIState(rollup: "PENDING"), .pending)
        XCTAssertEqual(CIState(rollup: "EXPECTED"), .pending)
        XCTAssertEqual(CIState(rollup: nil), .noChecks)
        XCTAssertEqual(CIState(rollup: "WEIRD"), .noChecks)
    }

    func testGroupPrecedence() {
        XCTAssertEqual(pr(1, draft: true, ci: .failing).group, .drafts)
        XCTAssertEqual(pr(2, review: .changesRequested).group, .needsAction)
        XCTAssertEqual(pr(3, review: .approved, ci: .failing).group, .needsAction)
        XCTAssertEqual(pr(4, review: .approved, conflicts: true).group, .needsAction)
        XCTAssertEqual(pr(5, review: .approved, ci: .passing).group, .approved)
        XCTAssertEqual(pr(6, ci: .pending).group, .waiting)
        XCTAssertEqual(pr(7).group, .waiting)
    }

    func testSectionsAreOrderedSortedAndSkipEmptyGroups() {
        let items = [
            pr(1, updated: 10), pr(2, updated: 30), pr(3, updated: 20),
            pr(4, review: .approved, updated: 5), pr(5, review: .approved, updated: 9),
            pr(6, draft: true, updated: 1),
        ]
        let sections = PullRequestSection.make(from: items)

        XCTAssertEqual(sections.map(\.group), [.waiting, .approved, .drafts])
        XCTAssertEqual(sections[0].items.map(\.number), [1, 3, 2], "waiting: oldest activity first")
        XCTAssertEqual(sections[1].items.map(\.number), [5, 4], "others: newest activity first")
        XCTAssertEqual(PullRequestSection.make(from: []).count, 0)
    }

    func testNeedsActionComesFirst() {
        let sections = PullRequestSection.make(from: [pr(1), pr(2, review: .changesRequested)])
        XCTAssertEqual(sections.map(\.group), [.needsAction, .waiting])
    }

    func testIdentityIsCaseInsensitiveOnTheRepo() {
        XCTAssertEqual(pr(9).id, "me/a#9")
        var other = pr(9)
        other.repo = "ME/A"
        XCTAssertEqual(other.id, "me/a#9")
    }
}
