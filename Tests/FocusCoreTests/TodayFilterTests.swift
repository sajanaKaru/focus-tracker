import XCTest
@testable import FocusCore

final class TodayFilterTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func sprint(_ name: String, startingDaysAgo: Double, length: Int = 14) -> CustomField {
        let start = Date().addingTimeInterval(-startingDaysAgo * day)
        return CustomField(name: "Sprint", value: name, kind: .iteration, project: "P", start: start, end: start.addingTimeInterval(Double(length) * day))
    }

    private func inProgress(_ title: String, repo: String = "me/a", milestone: String? = nil, sprint: CustomField? = nil) -> Ticket {
        Ticket(
            title: title, status: .inProgress, milestone: milestone.map { Milestone(title: $0) },
            fields: sprint.map { [$0] }, github: GitHubRef(repo: repo, number: 1, url: "u")
        )
    }

    func testCurrentSprintFilterKeepsOnlyTicketsInTheRunningSprint() {
        let current = inProgress("Now", sprint: sprint("Sprints 11", startingDaysAgo: 3))
        let old = inProgress("Old", sprint: sprint("Sprints 9", startingDaysAgo: 40))
        let none = inProgress("None")
        let filter = TicketFilter(sprint: .current)

        XCTAssertEqual([current, old, none].filter { filter.matches($0) }.map(\.title), ["Now"])
    }

    func testRepoSprintAndMilestoneCombine() {
        let match = inProgress("Match", repo: "acme/api", milestone: "v2", sprint: sprint("Sprints 11", startingDaysAgo: 3))
        let otherRepo = inProgress("Other repo", repo: "acme/web", milestone: "v2", sprint: sprint("Sprints 11", startingDaysAgo: 3))
        let otherMilestone = inProgress("Other milestone", repo: "acme/api", milestone: "v1", sprint: sprint("Sprints 11", startingDaysAgo: 3))
        let filter = TicketFilter(repo: "acme/api", milestone: .named("v2"), sprint: .current)

        XCTAssertEqual([match, otherRepo, otherMilestone].filter { filter.matches($0) }.map(\.title), ["Match"])
    }
}
