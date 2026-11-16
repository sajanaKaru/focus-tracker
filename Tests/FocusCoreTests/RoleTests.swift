import XCTest
@testable import FocusCore

final class RoleTests: XCTestCase {
    func testDevKeepsEverySectionAndLandsOnToday() {
        let profile = UserRole.dev.profile
        XCTAssertEqual(profile.sections, [.today, .tickets, .board, .pullRequests, .specialWork, .reports, .actionLog, .backup])
        XCTAssertFalse(profile.sections.contains(.qaQueue))
        XCTAssertEqual(profile.landing, .today)
        XCTAssertEqual(profile.captureKind, .bug)
    }

    func testQAAndPMHideDeveloperSections() {
        for role in [UserRole.qa, .pm] {
            let sections = role.profile.sections
            XCTAssertFalse(sections.contains(.pullRequests), "\(role)")
            XCTAssertFalse(sections.contains(.specialWork), "\(role)")
            XCTAssertEqual(sections, [.today, .qaQueue, .tickets, .board, .reports, .actionLog, .backup], "\(role)")
        }
    }

    func testLandingAndCaptureDefaults() {
        XCTAssertEqual(UserRole.qa.profile.landing, .today)
        XCTAssertEqual(UserRole.pm.profile.landing, .today)
        XCTAssertEqual(UserRole.qa.profile.captureKind, .bug)
        XCTAssertEqual(UserRole.pm.profile.captureKind, .request)
    }

    func testEveryLandingIsAVisibleSection() {
        for role in UserRole.allCases {
            XCTAssertTrue(role.profile.sections.contains(role.profile.landing), "\(role)")
        }
    }

    func testStatusOrderCoversEveryStatusOnceWithDoneLast() {
        for role in UserRole.allCases {
            let order = role.profile.statusOrder
            XCTAssertEqual(Set(order), Set(TicketStatus.allCases), "\(role)")
            XCTAssertEqual(order.count, TicketStatus.allCases.count, "\(role)")
            XCTAssertEqual(order.last, .done, "\(role)")
        }
    }

    func testStatusOrderPerRole() {
        XCTAssertEqual(UserRole.dev.profile.statusOrder, [.inProgress, .inReview, .todo, .testing, .backlog, .done])
        XCTAssertEqual(UserRole.qa.profile.statusOrder, [.testing, .inReview, .inProgress, .todo, .backlog, .done])
        XCTAssertEqual(UserRole.pm.profile.statusOrder, [.inProgress, .inReview, .testing, .todo, .backlog, .done])
    }
}

final class DeploymentEnvironmentTests: XCTestCase {
    func testRecognisesDeployedStatuses() {
        XCTAssertEqual(DeploymentEnvironment(statusName: "Deployed to Alpha"), .alpha)
        XCTAssertEqual(DeploymentEnvironment(statusName: "Deployed to Alpha2"), .alpha2)
        XCTAssertEqual(DeploymentEnvironment(statusName: "Deployed to Alpha 2"), .alpha2)
        XCTAssertEqual(DeploymentEnvironment(statusName: "deployed to alpha-2"), .alpha2)
        XCTAssertEqual(DeploymentEnvironment(statusName: "Deployed to Beta"), .beta)
        XCTAssertEqual(DeploymentEnvironment(statusName: "Deployed to Live"), .live)
        XCTAssertEqual(DeploymentEnvironment(statusName: "Deployed to Production"), .live)
    }

    func testIgnoresOtherNames() {
        for name in ["Ready for Beta", "Ready for Live", "In Progress", "Alpha testing", "Deployed", ""] {
            XCTAssertNil(DeploymentEnvironment(statusName: name), name)
        }
    }

    func testStatusMapping() {
        XCTAssertEqual(TicketStatus(optionName: "Deployed to Alpha"), .testing)
        XCTAssertEqual(TicketStatus(optionName: "Deployed to Alpha2"), .testing)
        XCTAssertEqual(TicketStatus(optionName: "Deployed to Beta"), .testing)
        XCTAssertEqual(TicketStatus(optionName: "Deployed to Live"), .done)
    }

    func testExistingStatusMappingIsUnchanged() {
        XCTAssertEqual(TicketStatus(optionName: "Ready for Beta"), .done)
        XCTAssertEqual(TicketStatus(optionName: "In Progress"), .inProgress)
        XCTAssertEqual(TicketStatus(optionName: "Code Review"), .inReview)
        XCTAssertEqual(TicketStatus(optionName: "QA Testing"), .testing)
        XCTAssertEqual(TicketStatus(optionName: "Backlog"), .backlog)
    }

    private func ticket(status: String?) -> Ticket {
        let fields = status.map { [CustomField(name: "Status", value: $0, kind: .select, project: "Board")] }
        return Ticket(title: "T", fields: fields, github: GitHubRef(repo: "o/r", number: 1, url: "https://github.com/o/r/issues/1"))
    }

    func testTicketEnvironmentFollowsProjectStatus() {
        XCTAssertEqual(ticket(status: "Deployed to Beta").environment, .beta)
        XCTAssertNil(ticket(status: "In Progress").environment)
        XCTAssertNil(ticket(status: nil).environment)
        XCTAssertNil(Ticket(title: "Local").environment)
    }

    func testFilterByEnvironment() {
        let beta = ticket(status: "Deployed to Beta")
        let alpha = ticket(status: "Deployed to Alpha")
        var filter = TicketFilter()
        XCTAssertFalse(filter.isActive)
        filter.environment = .beta
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(beta))
        XCTAssertFalse(filter.matches(alpha))
        XCTAssertFalse(filter.matches(Ticket(title: "Local")))
    }

    func testEnvironmentCombinesWithOtherFilters() {
        let beta = ticket(status: "Deployed to Beta")
        var filter = TicketFilter(source: .local)
        filter.environment = .beta
        XCTAssertFalse(filter.matches(beta))
        filter.source = .github
        XCTAssertTrue(filter.matches(beta))
        filter.repo = "other/repo"
        XCTAssertFalse(filter.matches(beta))
    }
}

@MainActor
final class RolePersistenceTests: XCTestCase {
    private func makeStore(defaults: UserDefaults) -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
    }

    func testRoleDefaultsToDevAndPersists() {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        let store = makeStore(defaults: defaults)
        XCTAssertEqual(store.role, .dev)
        store.role = .qa
        XCTAssertEqual(makeStore(defaults: defaults).role, .qa)
    }

    func testUnknownStoredRoleFallsBackToDev() {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        defaults.set("admin", forKey: PrefKey.role)
        XCTAssertEqual(makeStore(defaults: defaults).role, .dev)
    }
}
