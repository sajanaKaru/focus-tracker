# QA Sprint Groups and Per-Milestone Plans Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group the QA Test plan by sprint (so an ended sprint still in QA shows first) and let QA keep a separate plan per GitHub milestone.

**Architecture:** Pure logic lives in FocusCore: sprint ordering/grouping on the existing `QAPlanCandidate` list, and a small stored `QAMilestonePlan` record whose tickets and progress are derived live from workspace tickets. The SwiftUI `QATestPlanCard` becomes a two-tab section (Today | Milestones). Both tabs toggle the same per-day `DayPlan` through the existing `toggleQAPlanned`.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation (`@Observable AppStore`), XCTest (`swift test`).

**Spec:** `docs/superpowers/specs/2026-10-14-qa-sprint-milestone-plan-design.md`

## Global Constraints

- `AppStore` is `@MainActor @Observable`; tests are `@MainActor final class ... : XCTestCase` using `@testable import FocusCore`.
- New persisted field is optional in the snapshot (`qaMilestonePlans: [QAMilestonePlan]?`, loaded `?? []`) so existing `data.json` files load unchanged.
- At most one non-archived plan per milestone title; milestones are matched by title (as `liveArchive()` does).
- Tickets are matched to plans only through `ticket.milestone?.title`; tickets without a milestone never appear in the Milestones tab.
- Do not launch `build/FocusTracker.app` (it loads the real `data.json` and GitHub token). UI is verified with `swift build` only.
- Shell: `rm` is aliased to `npm run rm`; use `command rm` if deleting anything.
- Known limitation (accepted): progress counts tickets currently in QA stages. A ticket that moves to Live leaves the plan.
- Commit on the current branch (`main`) after each task.

---

## File Structure

- Modify `Sources/FocusCore/AppStore+QAPlan.swift`: sprint on `QAPlanCandidate`, sprint ordering and grouping, `qaCandidates(includeVerified:)`.
- Modify `Sources/FocusCore/QA.swift`: add `QAMilestonePlan` and `QAMilestoneProgress`.
- Modify `Sources/FocusCore/AppStore.swift`: `qaMilestonePlans` property and snapshot persistence.
- Create `Sources/FocusCore/AppStore+QAMilestonePlan.swift`: plan CRUD, plannable milestones, progress derivation.
- Modify `Sources/FocusTracker/QATestPlanCard.swift`: tab container, Today tab with sprint groups, shared ticket row.
- Create `Sources/FocusTracker/QAMilestonePlansView.swift`: Milestones tab.
- Create `Tests/FocusCoreTests/QAPlanFixtures.swift`, `QASprintPlanTests.swift`, `QAMilestonePlanTests.swift`.

---

### Task 1: Sprint ordering and groups

**Files:**
- Modify: `Sources/FocusCore/AppStore+QAPlan.swift`
- Create: `Tests/FocusCoreTests/QAPlanFixtures.swift`
- Create: `Tests/FocusCoreTests/QASprintPlanTests.swift`

**Interfaces:**
- Consumes: existing `QAPlanner`, `QAPlanCandidate`, `AppStore.qaQueue(environment:)`, `AppStore.qaSummary`.
- Produces:
  - `QAPlanCandidate.sprint: CustomField?`
  - `QAPlanner.sprint(of: Ticket) -> CustomField?`
  - `QAPlanner.groupBySprint(_ candidates: [QAPlanCandidate]) -> [QASprintGroup]`
  - `struct QASprintGroup: Identifiable, Equatable, Sendable { sprint: CustomField?; candidates: [QAPlanCandidate]; id: String; estimateMinutes: Int; isEnded(at:) -> Bool; isCurrent(at:) -> Bool }`
  - `AppStore.qaPlanSprintGroups() -> [QASprintGroup]`
  - `AppStore.qaCandidates(includeVerified: Bool) -> [QAPlanCandidate]` (internal; used by Task 3)
  - Test fixtures: `QAPlanFixtures.makeStore(url:)`, `.sprint(_:start:end:)`, `.add(_:_:cases:sprints:milestone:)`, `.verify(_:_:)`, `.fail(_:_:)`

- [ ] **Step 1: Write the fixtures and the failing tests**

Create `Tests/FocusCoreTests/QAPlanFixtures.swift`:

```swift
import Foundation
@testable import FocusCore

@MainActor
enum QAPlanFixtures {
    static func makeStore(url: URL? = nil) -> (AppStore, URL) {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        defaults.set(7, forKey: PrefKey.workDays)
        defaults.set(60, forKey: PrefKey.workingMinutes)
        defaults.set(100, forKey: PrefKey.focusPercent)
        let storeURL = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: storeURL, defaults: defaults, transport: RecordingTransport { _ in (200, "{}") }, tokenProvider: { "t" })
        return (store, storeURL)
    }

    static func sprint(_ name: String, start: Date, end: Date) -> CustomField {
        CustomField(name: "Sprint", value: name, kind: .iteration, project: "Board", start: start, end: end)
    }

    /// A ticket deployed to Beta (so it is a QA candidate) with `cases` untested cases.
    @discardableResult
    static func add(_ store: AppStore, _ number: Int, cases: Int = 1, sprints: [CustomField] = [], milestone: Milestone? = nil) -> Ticket {
        let ticket = Ticket(
            title: "T\(number)", status: .testing, milestone: milestone,
            fields: [CustomField(name: "Status", value: "Deployed to Beta", kind: .select, project: "Board")] + sprints,
            github: GitHubRef(repo: "me/a", number: number, url: "https://github.com/me/a/issues/\(number)")
        )
        store.insertTicketForTest(ticket)
        for i in 0..<cases { store.addTestCase(ticketID: ticket.id, title: "case \(i)") }
        return ticket
    }

    static func verify(_ store: AppStore, _ ticket: Ticket) {
        store.testVerdicts.append(TestVerdict(ticketID: ticket.id, environment: .beta, outcome: .pass, summary: "ok", tester: "qa"))
    }

    static func fail(_ store: AppStore, _ ticket: Ticket) {
        store.testVerdicts.append(TestVerdict(ticketID: ticket.id, environment: .beta, outcome: .fail, summary: "bad", tester: "qa"))
    }
}
```

Create `Tests/FocusCoreTests/QASprintPlanTests.swift`:

```swift
import XCTest
@testable import FocusCore

@MainActor
final class QASprintPlanTests: XCTestCase {
    private func days(_ n: Double) -> Date { Date(timeIntervalSinceNow: n * 86_400) }
    private func sprint11() -> CustomField { QAPlanFixtures.sprint("Sprint 11", start: days(-14), end: days(-1)) }
    private func sprint12() -> CustomField { QAPlanFixtures.sprint("Sprint 12", start: days(-1), end: days(13)) }

    func testCandidatesRunOldestSprintFirstAndNoSprintLast() {
        let (store, _) = QAPlanFixtures.makeStore()
        let none = QAPlanFixtures.add(store, 1)
        let in12 = QAPlanFixtures.add(store, 2, sprints: [sprint12()])
        let in11 = QAPlanFixtures.add(store, 3, sprints: [sprint11()])

        XCTAssertEqual(store.qaPlanCandidates().map(\.ticket.id), [in11.id, in12.id, none.id])
    }

    func testStateOrderIsKeptInsideASprint() {
        let (store, _) = QAPlanFixtures.makeStore()
        let ready = QAPlanFixtures.add(store, 1, sprints: [sprint11()])
        let failed = QAPlanFixtures.add(store, 2, sprints: [sprint11()])
        QAPlanFixtures.fail(store, failed)

        XCTAssertEqual(store.qaPlanCandidates().map(\.ticket.id), [failed.id, ready.id])
    }

    func testTicketInTwoSprintsUsesTheOneThatEndsLast() {
        let (store, _) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1, sprints: [sprint11(), sprint12()])

        XCTAssertEqual(store.qaPlanCandidates().first?.sprint?.value, "Sprint 12")
    }

    func testGroupsAreOrderedAndFlagEndedAndCurrentSprints() {
        let (store, _) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1)
        QAPlanFixtures.add(store, 2, sprints: [sprint12()])
        QAPlanFixtures.add(store, 3, sprints: [sprint11()], cases: 3)
        let now = Date()

        let groups = store.qaPlanSprintGroups()
        XCTAssertEqual(groups.map { $0.sprint?.value }, ["Sprint 11", "Sprint 12", nil])
        XCTAssertEqual(groups.map { $0.isEnded(at: now) }, [true, false, false])
        XCTAssertEqual(groups.map { $0.isCurrent(at: now) }, [false, true, false])
        XCTAssertEqual(groups.map(\.estimateMinutes), [30, 10, 10])
    }

    func testAutoPickTakesTheOldestSprintFirst() {
        let (store, _) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1, sprints: [sprint12()])
        let in11 = QAPlanFixtures.add(store, 2, sprints: [sprint11()])

        XCTAssertEqual(QAPlanner.autoPick(store.qaPlanCandidates(), capacityMinutes: 10), [in11.id])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QASprintPlanTests 2>&1 | tail -20`
Expected: build FAIL, e.g. "value of type 'QAPlanCandidate' has no member 'sprint'" and "has no member 'qaPlanSprintGroups'".

- [ ] **Step 3: Implement in `Sources/FocusCore/AppStore+QAPlan.swift`**

Replace the `QAPlanCandidate` struct with:

```swift
public struct QAPlanCandidate: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var state: QAState
    public var estimateMinutes: Int
    /// The ticket's latest sprint; nil when it has none.
    public var sprint: CustomField? = nil

    public var id: UUID { ticket.id }
}

/// Candidates in one sprint; a nil sprint collects tickets without one.
public struct QASprintGroup: Identifiable, Equatable, Sendable {
    public var sprint: CustomField?
    public var candidates: [QAPlanCandidate]

    public var id: String { sprint?.value ?? "" }
    public var estimateMinutes: Int { candidates.reduce(0) { $0 + $1.estimateMinutes } }

    public func isEnded(at now: Date) -> Bool { sprint?.end.map { $0 <= now } ?? false }
    public func isCurrent(at now: Date) -> Bool { sprint?.isCurrent(at: now) ?? false }
}
```

Inside `enum QAPlanner`, after `plannedMinutes`, add:

```swift
    /// Of a ticket's sprints, the one that ends last.
    public static func sprint(of ticket: Ticket) -> CustomField? {
        ticket.sprints.max { ($0.end ?? .distantPast) < ($1.end ?? .distantPast) }
    }

    /// Oldest sprint first; tickets without a sprint come last.
    static func sprintPrecedes(_ a: CustomField?, _ b: CustomField?) -> Bool {
        switch (a, b) {
        case (nil, _): return false
        case (_?, nil): return true
        case let (x?, y?):
            let (ex, ey) = (x.end ?? .distantFuture, y.end ?? .distantFuture)
            return ex != ey ? ex < ey : x.value < y.value
        }
    }

    /// Keeps the candidates' order inside each group.
    public static func groupBySprint(_ candidates: [QAPlanCandidate]) -> [QASprintGroup] {
        var groups: [QASprintGroup] = []
        for candidate in candidates {
            if let index = groups.firstIndex(where: { $0.sprint?.value == candidate.sprint?.value }) {
                groups[index].candidates.append(candidate)
            } else {
                groups.append(QASprintGroup(sprint: candidate.sprint, candidates: [candidate]))
            }
        }
        return groups.sorted { sprintPrecedes($0.sprint, $1.sprint) }
    }
```

In `extension AppStore`, replace the whole `qaPlanCandidates()` function (including its doc comment) with:

```swift
    /// Tickets to test: oldest sprint first, then failed, in testing, ready; each group newest first.
    public func qaPlanCandidates() -> [QAPlanCandidate] { qaCandidates(includeVerified: false) }

    public func qaPlanSprintGroups() -> [QASprintGroup] { QAPlanner.groupBySprint(qaPlanCandidates()) }

    func qaCandidates(includeVerified: Bool) -> [QAPlanCandidate] {
        let environments: [DeploymentEnvironment?] = [nil, .alpha, .alpha2, .beta]
        let queues = environments.map { qaQueue(environment: $0) }
        var groups: [(QAState, [Ticket])] = [
            (.failed, queues.flatMap(\.failed)), (.testing, queues.flatMap(\.testing)), (.ready, queues.flatMap(\.ready))
        ]
        if includeVerified { groups.append((.verified, queues.flatMap(\.verified))) }
        var seen = Set<UUID>()
        var result: [QAPlanCandidate] = []
        for (state, tickets) in groups {
            for ticket in tickets.sorted(by: { $0.updatedAt > $1.updatedAt }) where seen.insert(ticket.id).inserted {
                let summary = qaSummary(ticketID: ticket.id, environment: ticket.environment)
                let remaining = summary.notRun + summary.fail + summary.blocked
                result.append(QAPlanCandidate(
                    ticket: ticket, state: state,
                    estimateMinutes: QAPlanner.estimate(totalCases: summary.total, remainingCases: remaining),
                    sprint: QAPlanner.sprint(of: ticket)
                ))
            }
        }
        // Index tie-break keeps the state order inside a sprint.
        return result.enumerated().sorted { a, b in
            QAPlanner.sprintPrecedes(a.element.sprint, b.element.sprint)
                || (!QAPlanner.sprintPrecedes(b.element.sprint, a.element.sprint) && a.offset < b.offset)
        }.map(\.element)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "QASprintPlanTests|QAPlanTests" 2>&1 | grep -E "Executed|error|failed"`
Expected: all pass (the existing `QAPlanTests` still pass because its tickets have no sprint, so order is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/AppStore+QAPlan.swift Tests/FocusCoreTests/QAPlanFixtures.swift Tests/FocusCoreTests/QASprintPlanTests.swift
git commit -m "feat: order QA plan candidates by sprint and group them"
```

---

### Task 2: Milestone plan model, persistence and management

**Files:**
- Modify: `Sources/FocusCore/QA.swift` (add `QAMilestonePlan` before `public enum QAState`)
- Modify: `Sources/FocusCore/AppStore.swift` (property, snapshot)
- Create: `Sources/FocusCore/AppStore+QAMilestonePlan.swift`
- Create: `Tests/FocusCoreTests/QAMilestonePlanTests.swift`

**Interfaces:**
- Consumes: `QAPlanFixtures` (Task 1), `AppStore.save()`, `AppStore.workspaceTickets`, `AppStore.ticket(_:)`.
- Produces:
  - `struct QAMilestonePlan: Identifiable, Codable, Hashable, Sendable { id: UUID; milestone: String; targetDate: Date?; excludedTicketIDs: [UUID]; archived: Bool; createdAt: Date; init(id:milestone:targetDate:excludedTicketIDs:archived:createdAt:) }`
  - `AppStore.qaMilestonePlans: [QAMilestonePlan]` (`public internal(set)`)
  - `AppStore.qaActiveMilestonePlans: [QAMilestonePlan]`
  - `AppStore.qaPlannableMilestones() -> [Milestone]`
  - `AppStore.addQAMilestonePlan(_ milestone: Milestone)`
  - `AppStore.setQAMilestoneTarget(_ planID: UUID, _ date: Date?)`
  - `AppStore.excludeFromQAMilestonePlan(_ planID: UUID, ticketID: UUID)`
  - `AppStore.restoreToQAMilestonePlan(_ planID: UUID, ticketID: UUID)`
  - `AppStore.archiveQAMilestonePlan(_ planID: UUID)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/QAMilestonePlanTests.swift`:

```swift
import XCTest
@testable import FocusCore

@MainActor
final class QAMilestonePlanTests: XCTestCase {
    private func milestone(_ title: String, open: Bool = true, due: Date? = nil) -> Milestone {
        Milestone(title: title, isOpen: open, dueOn: due)
    }

    func testAddingAPlanUsesTheMilestoneDueDateAndPersists() {
        let (store, url) = QAPlanFixtures.makeStore()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        store.addQAMilestonePlan(milestone("Release 2.4", due: due))

        XCTAssertEqual(store.qaActiveMilestonePlans.map(\.milestone), ["Release 2.4"])
        XCTAssertEqual(store.qaActiveMilestonePlans.first?.targetDate, due)

        let (reloaded, _) = QAPlanFixtures.makeStore(url: url)
        XCTAssertEqual(reloaded.qaMilestonePlans.map(\.id), store.qaMilestonePlans.map(\.id))
        XCTAssertEqual(reloaded.qaMilestonePlans.first?.targetDate, due)
    }

    func testAddingTheSameMilestoneTwiceIsIgnoredUntilTheFirstPlanIsArchived() {
        let (store, _) = QAPlanFixtures.makeStore()
        store.addQAMilestonePlan(milestone("R1"))
        store.addQAMilestonePlan(milestone("R1"))
        XCTAssertEqual(store.qaMilestonePlans.count, 1)

        store.archiveQAMilestonePlan(store.qaMilestonePlans[0].id)
        XCTAssertTrue(store.qaActiveMilestonePlans.isEmpty)
        store.addQAMilestonePlan(milestone("R1"))
        XCTAssertEqual(store.qaActiveMilestonePlans.count, 1)
        XCTAssertEqual(store.qaMilestonePlans.count, 2)
    }

    func testPlannableMilestonesListOpenFirstAndSkipActivePlans() {
        let (store, _) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1, milestone: milestone("Release 2.5"))
        QAPlanFixtures.add(store, 2, milestone: milestone("Release 2.4"))
        QAPlanFixtures.add(store, 3, milestone: milestone("Old", open: false))
        QAPlanFixtures.add(store, 4)

        XCTAssertEqual(store.qaPlannableMilestones().map(\.title), ["Release 2.4", "Release 2.5", "Old"])
        store.addQAMilestonePlan(milestone("Release 2.4"))
        XCTAssertEqual(store.qaPlannableMilestones().map(\.title), ["Release 2.5", "Old"])
    }

    func testPlannableMilestonePrefersTheCopyWithADueDate() {
        let (store, _) = QAPlanFixtures.makeStore()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        QAPlanFixtures.add(store, 1, milestone: milestone("R1"))
        QAPlanFixtures.add(store, 2, milestone: milestone("R1", due: due))

        XCTAssertEqual(store.qaPlannableMilestones().first?.dueOn, due)
    }

    func testExcludeRestoreTargetAndArchive() {
        let (store, _) = QAPlanFixtures.makeStore()
        store.addQAMilestonePlan(milestone("R1"))
        let id = store.qaMilestonePlans[0].id
        let ticket = UUID()

        store.excludeFromQAMilestonePlan(id, ticketID: ticket)
        store.excludeFromQAMilestonePlan(id, ticketID: ticket)
        XCTAssertEqual(store.qaMilestonePlans[0].excludedTicketIDs, [ticket])
        store.restoreToQAMilestonePlan(id, ticketID: ticket)
        XCTAssertEqual(store.qaMilestonePlans[0].excludedTicketIDs, [])

        let target = Date(timeIntervalSince1970: 1_800_000_000)
        store.setQAMilestoneTarget(id, target)
        XCTAssertEqual(store.qaMilestonePlans[0].targetDate, target)
        store.setQAMilestoneTarget(id, nil)
        XCTAssertNil(store.qaMilestonePlans[0].targetDate)

        store.archiveQAMilestonePlan(id)
        XCTAssertTrue(store.qaMilestonePlans[0].archived)
    }

    func testLoadsFilesWithoutMilestonePlans() throws {
        let (store, url) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1)
        store.addQAMilestonePlan(milestone("R1"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(json["qaMilestonePlans"])
        json["qaMilestonePlans"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let (reloaded, _) = QAPlanFixtures.makeStore(url: url)
        XCTAssertTrue(reloaded.qaMilestonePlans.isEmpty)
        XCTAssertEqual(reloaded.tickets.count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QAMilestonePlanTests 2>&1 | tail -20`
Expected: build FAIL, "has no member 'addQAMilestonePlan'".

- [ ] **Step 3: Add the model to `Sources/FocusCore/QA.swift`**

Insert immediately before `public enum QAState: Equatable, Sendable {`:

```swift
/// A QA test plan for one GitHub milestone; its tickets and progress are derived, only the choices QA made are stored.
public struct QAMilestonePlan: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var milestone: String
    public var targetDate: Date?
    public var excludedTicketIDs: [UUID]
    public var archived: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(), milestone: String, targetDate: Date? = nil, excludedTicketIDs: [UUID] = [],
        archived: Bool = false, createdAt: Date = Date()
    ) {
        self.id = id
        self.milestone = milestone
        self.targetDate = targetDate
        self.excludedTicketIDs = excludedTicketIDs
        self.archived = archived
        self.createdAt = createdAt
    }
}

```

- [ ] **Step 4: Persist in `Sources/FocusCore/AppStore.swift`**

Four edits:

1. After `public internal(set) var qaDayPlans: [DayPlan] = []` add:
```swift
    public internal(set) var qaMilestonePlans: [QAMilestonePlan] = []
```
2. In `Snapshot`, change `        var qaDayPlans: [DayPlan]?\n    }` to:
```swift
        var qaDayPlans: [DayPlan]?
        var qaMilestonePlans: [QAMilestonePlan]?
    }
```
3. In `apply`, after `qaDayPlans = snapshot.qaDayPlans ?? []` add:
```swift
        qaMilestonePlans = snapshot.qaMilestonePlans ?? []
```
4. In `save`, change `testVerdicts: testVerdicts, bugReports: bugReports, qaDayPlans: qaDayPlans` to:
```swift
                testVerdicts: testVerdicts, bugReports: bugReports, qaDayPlans: qaDayPlans, qaMilestonePlans: qaMilestonePlans
```

- [ ] **Step 5: Create `Sources/FocusCore/AppStore+QAMilestonePlan.swift`**

```swift
import Foundation

extension AppStore {
    public var qaActiveMilestonePlans: [QAMilestonePlan] {
        qaMilestonePlans.filter { !$0.archived }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Milestones on workspace tickets that have no active plan: open first, then closed, each A-Z.
    public func qaPlannableMilestones() -> [Milestone] {
        let planned = Set(qaActiveMilestonePlans.map(\.milestone))
        var byTitle: [String: Milestone] = [:]
        for milestone in workspaceTickets.compactMap(\.milestone) where !planned.contains(milestone.title) {
            if let existing = byTitle[milestone.title], existing.dueOn != nil || milestone.dueOn == nil { continue }
            byTitle[milestone.title] = milestone
        }
        return byTitle.values.sorted {
            if $0.isOpen != $1.isOpen { return $0.isOpen }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    public func addQAMilestonePlan(_ milestone: Milestone) {
        guard !qaActiveMilestonePlans.contains(where: { $0.milestone == milestone.title }) else { return }
        qaMilestonePlans.append(QAMilestonePlan(milestone: milestone.title, targetDate: milestone.dueOn))
        save()
    }

    public func setQAMilestoneTarget(_ planID: UUID, _ date: Date?) {
        updateQAMilestonePlan(planID) { $0.targetDate = date }
    }

    public func excludeFromQAMilestonePlan(_ planID: UUID, ticketID: UUID) {
        updateQAMilestonePlan(planID) { if !$0.excludedTicketIDs.contains(ticketID) { $0.excludedTicketIDs.append(ticketID) } }
    }

    public func restoreToQAMilestonePlan(_ planID: UUID, ticketID: UUID) {
        updateQAMilestonePlan(planID) { $0.excludedTicketIDs.removeAll { $0 == ticketID } }
    }

    public func archiveQAMilestonePlan(_ planID: UUID) {
        updateQAMilestonePlan(planID) { $0.archived = true }
    }

    private func updateQAMilestonePlan(_ id: UUID, _ change: (inout QAMilestonePlan) -> Void) {
        guard let index = qaMilestonePlans.firstIndex(where: { $0.id == id }) else { return }
        change(&qaMilestonePlans[index])
        save()
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter QAMilestonePlanTests 2>&1 | grep -E "Executed|error|failed"`
Expected: 6 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/FocusCore/QA.swift Sources/FocusCore/AppStore.swift Sources/FocusCore/AppStore+QAMilestonePlan.swift Tests/FocusCoreTests/QAMilestonePlanTests.swift
git commit -m "feat: store per-milestone QA plans"
```

---

### Task 3: Milestone plan progress

**Files:**
- Modify: `Sources/FocusCore/QA.swift` (add `QAMilestoneProgress` after `QAMilestonePlan`)
- Modify: `Sources/FocusCore/AppStore+QAMilestonePlan.swift`
- Modify: `Tests/FocusCoreTests/QAMilestonePlanTests.swift`

**Interfaces:**
- Consumes: `AppStore.qaCandidates(includeVerified:)`, `QAPlanCandidate` (Task 1); `QAMilestonePlan` and its store methods (Task 2); `AppStore.toggleQAPlanned`, `AppStore.qaPlan(for:)`.
- Produces:
  - `struct QAMilestoneProgress: Equatable, Sendable { plan: QAMilestonePlan; tickets: [QAPlanCandidate]; total: Int; verified: Int; fraction: Double; remainingMinutes: Int; count(_ state: QAState) -> Int; daysRemaining(at:calendar:) -> Int?; isOverdue(at:calendar:) -> Bool }`
  - `AppStore.qaMilestoneProgress(for plan: QAMilestonePlan) -> QAMilestoneProgress`
  - `AppStore.qaExcludedTickets(for plan: QAMilestonePlan) -> [Ticket]`

- [ ] **Step 1: Write the failing tests**

Append inside `QAMilestonePlanTests` (before the final `}`):

```swift
    func testProgressCountsStatesEstimateAndSkipsOtherMilestonesAndExclusions() {
        let (store, _) = QAPlanFixtures.makeStore()
        let r1 = milestone("R1")
        let failed = QAPlanFixtures.add(store, 1, cases: 1, milestone: r1)
        QAPlanFixtures.fail(store, failed)
        let testing = QAPlanFixtures.add(store, 2, cases: 2, milestone: r1)
        store.setResult(caseID: store.testCases(for: testing.id)[0].id, environment: .beta, status: .pass)
        QAPlanFixtures.add(store, 3, cases: 3, milestone: r1)
        let verified = QAPlanFixtures.add(store, 4, cases: 1, milestone: r1)
        QAPlanFixtures.verify(store, verified)
        QAPlanFixtures.add(store, 5, cases: 1, milestone: milestone("R2"))
        let excluded = QAPlanFixtures.add(store, 6, cases: 1, milestone: r1)

        store.addQAMilestonePlan(r1)
        let plan = store.qaMilestonePlans[0]
        XCTAssertEqual(store.qaMilestoneProgress(for: plan).total, 5)

        store.excludeFromQAMilestonePlan(plan.id, ticketID: excluded.id)
        let progress = store.qaMilestoneProgress(for: store.qaMilestonePlans[0])
        XCTAssertEqual(progress.total, 4)
        XCTAssertEqual(progress.verified, 1)
        XCTAssertEqual(progress.count(.failed), 1)
        XCTAssertEqual(progress.count(.testing), 1)
        XCTAssertEqual(progress.count(.ready), 1)
        XCTAssertEqual(progress.remainingMinutes, 50)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(store.qaExcludedTickets(for: store.qaMilestonePlans[0]).map(\.id), [excluded.id])
    }

    func testPlanWithNoMatchingTicketsIsEmpty() {
        let (store, _) = QAPlanFixtures.makeStore()
        store.addQAMilestonePlan(milestone("Gone"))
        let progress = store.qaMilestoneProgress(for: store.qaMilestonePlans[0])
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.fraction, 0)
    }

    func testOverdueNeedsAPassedTargetAndUnverifiedTickets() {
        let ticket = Ticket(title: "t")
        let ready = QAPlanCandidate(ticket: ticket, state: .ready, estimateMinutes: 10)
        let done = QAPlanCandidate(ticket: ticket, state: .verified, estimateMinutes: 10)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!

        func progress(_ target: Date?, _ tickets: [QAPlanCandidate]) -> QAMilestoneProgress {
            QAMilestoneProgress(plan: QAMilestonePlan(milestone: "R", targetDate: target), tickets: tickets)
        }
        XCTAssertTrue(progress(yesterday, [ready]).isOverdue(at: now))
        XCTAssertFalse(progress(yesterday, [done]).isOverdue(at: now))
        XCTAssertFalse(progress(now, [ready]).isOverdue(at: now))
        XCTAssertFalse(progress(nil, [ready]).isOverdue(at: now))
        XCTAssertEqual(progress(tomorrow, [ready]).daysRemaining(at: now), 1)
        XCTAssertEqual(progress(yesterday, [ready]).daysRemaining(at: now), -1)
        XCTAssertNil(progress(nil, [ready]).daysRemaining(at: now))
    }

    func testPlanningAMilestoneTicketUpdatesTodaysPlan() {
        let (store, _) = QAPlanFixtures.makeStore()
        let ticket = QAPlanFixtures.add(store, 1, milestone: milestone("R1"))
        let day = Date()

        store.toggleQAPlanned(ticket.id, on: day)
        XCTAssertEqual(store.qaPlan(for: day)?.ticketIDs, [ticket.id])
        store.toggleQAPlanned(ticket.id, on: day)
        XCTAssertEqual(store.qaPlan(for: day)?.ticketIDs, [])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QAMilestonePlanTests 2>&1 | tail -20`
Expected: build FAIL, "cannot find 'QAMilestoneProgress' in scope".

- [ ] **Step 3: Add `QAMilestoneProgress` to `Sources/FocusCore/QA.swift`**

Insert directly after the `QAMilestonePlan` struct:

```swift
/// A milestone plan's tickets (verified ones included) with the numbers shown on its card.
public struct QAMilestoneProgress: Equatable, Sendable {
    public var plan: QAMilestonePlan
    public var tickets: [QAPlanCandidate]

    public var total: Int { tickets.count }
    public var verified: Int { count(.verified) }
    public var fraction: Double { total == 0 ? 0 : Double(verified) / Double(total) }
    public var remainingMinutes: Int { tickets.filter { $0.state != .verified }.reduce(0) { $0 + $1.estimateMinutes } }

    public func count(_ state: QAState) -> Int { tickets.filter { $0.state == state }.count }

    public func daysRemaining(at now: Date, calendar: Calendar = .current) -> Int? {
        guard let target = plan.targetDate else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day
    }

    public func isOverdue(at now: Date, calendar: Calendar = .current) -> Bool {
        (daysRemaining(at: now, calendar: calendar) ?? 0) < 0 && verified < total
    }
}

```

- [ ] **Step 4: Add the store queries**

In `Sources/FocusCore/AppStore+QAMilestonePlan.swift`, add before `private func updateQAMilestonePlan`:

```swift
    public func qaMilestoneProgress(for plan: QAMilestonePlan) -> QAMilestoneProgress {
        let excluded = Set(plan.excludedTicketIDs)
        let tickets = qaCandidates(includeVerified: true)
            .filter { $0.ticket.milestone?.title == plan.milestone && !excluded.contains($0.id) }
        return QAMilestoneProgress(plan: plan, tickets: tickets)
    }

    /// Tickets QA removed from the plan, so they can be restored; ids that no longer exist are skipped.
    public func qaExcludedTickets(for plan: QAMilestonePlan) -> [Ticket] {
        plan.excludedTicketIDs.compactMap { ticket($0) }
    }
```

- [ ] **Step 5: Run the full test suite**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed"`
Expected: 0 failures. (`ActivityTests.testManualActivityCountsInTotalsAndLog` can fail in the first ~30 min after local midnight; that is pre-existing.)

- [ ] **Step 6: Commit**

```bash
git add Sources/FocusCore/QA.swift Sources/FocusCore/AppStore+QAMilestonePlan.swift Tests/FocusCoreTests/QAMilestonePlanTests.swift
git commit -m "feat: derive QA milestone plan progress"
```

---

### Task 4: Plan section tabs and sprint groups (Today tab)

**Files:**
- Modify (replace entire contents): `Sources/FocusTracker/QATestPlanCard.swift`

**Interfaces:**
- Consumes: `AppStore.qaPlanSprintGroups()`, `QASprintGroup`, existing `store.capacity(for:calendarBusy:)`, `store.ensureQAPlan`, `store.suggestQAPlan`, `store.toggleQAPlanned`; `QAMilestonePlansView(selectedTicketID:)` from Task 5 (Task 5 must land in the same build; if building this task alone, add a temporary `struct QAMilestonePlansView: View { @Binding var selectedTicketID: UUID?; var body: some View { EmptyView() } }` in `QAMilestonePlansView.swift` and let Task 5 replace it).
- Produces: `QATestPlanCard(selectedTicketID:)` (same call site in `QATodayView`), `QATodayPlanTab`, `QAPlanTicketRow(candidate:planned:day:selectedTicketID:onExclude:)` (reused by Task 5).

- [ ] **Step 1: Create the temporary Milestones view so the target builds**

Create `Sources/FocusTracker/QAMilestonePlansView.swift`:

```swift
import FocusCore
import SwiftUI

struct QAMilestonePlansView: View {
    @Binding var selectedTicketID: UUID?

    var body: some View { EmptyView() }
}
```

- [ ] **Step 2: Replace `Sources/FocusTracker/QATestPlanCard.swift`**

```swift
import FocusCore
import SwiftUI

/// The QA plan section: today's capacity plan grouped by sprint, and one plan per milestone.
struct QATestPlanCard: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case today = "Today", milestones = "Milestones"
        var id: String { rawValue }
    }

    @Binding var selectedTicketID: UUID?
    @State private var tab: Tab = .today

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Test plan")
                Spacer()
                Picker("Plan view", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            switch tab {
            case .today: QATodayPlanTab(selectedTicketID: $selectedTicketID)
            case .milestones: QAMilestonePlansView(selectedTicketID: $selectedTicketID)
            }
        }
    }
}

struct QATodayPlanTab: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var calendarBusy: [DateInterval] = []
    @State private var calendarNote: String?

    // Declared so the tab re-renders when a plan setting changes in Settings.
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.workDays) private var workDays = 5

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    var body: some View {
        let day = store.now
        let groups = store.qaPlanSprintGroups()
        let candidates = groups.flatMap(\.candidates)
        let plannedIDs = Set(store.qaPlan(for: day)?.ticketIDs ?? [])
        let capacity = store.capacity(for: day, calendarBusy: calendarBusy)
        let planned = QAPlanner.plannedMinutes(candidates, ids: plannedIDs)
        let over = planned > capacity.capacityMinutes
        let workingDay = store.planSettings.isWorkingDay(day)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(candidates.filter { plannedIDs.contains($0.id) }.count) of \(candidates.count) planned today")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Re-suggest") { store.suggestQAPlan(for: day, calendarBusy: calendarBusy) }
                    .buttonStyle(.secondary)
                    .disabled(candidates.isEmpty || !workingDay)
                    .help("Rebuild the plan from the tickets waiting for QA, oldest sprint first")
            }

            VStack(alignment: .leading, spacing: 6) {
                CapacityBar(planned: planned, capacity: capacity.capacityMinutes, over: over)
                HStack {
                    Text("Planned \(text(planned)) of \(text(capacity.capacityMinutes)) capacity")
                        .foregroundStyle(over ? Theme.warning : Color.primary)
                    Spacer()
                    Text("\(text(capacity.freeMinutes)) free after meetings").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                if over {
                    Label("Over capacity by \(text(planned - capacity.capacityMinutes))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                if !workingDay {
                    Text("Not a working day. Change this in Settings → Working days.").font(.caption).foregroundStyle(.secondary)
                }
                if let calendarNote { Text(calendarNote).font(.caption).foregroundStyle(.secondary) }
            }

            if candidates.isEmpty {
                EmptyHint(text: "Nothing waiting for QA.", symbol: "checklist")
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        header(group, now: day)
                        VStack(spacing: 0) {
                            ForEach(Array(group.candidates.enumerated()), id: \.element.id) { index, candidate in
                                if index > 0 { Divider() }
                                QAPlanTicketRow(
                                    candidate: candidate, planned: plannedIDs.contains(candidate.id), day: day,
                                    selectedTicketID: $selectedTicketID
                                )
                            }
                        }
                        .cardStyle(padding: 0)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .task(id: "\(candidates.isEmpty)|\(Calendar.current.startOfDay(for: day))") { await loadCalendarAndPlan(day: day) }
    }

    private func header(_ group: QASprintGroup, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(group.sprint?.value ?? "No sprint").font(.headline)
            if group.isEnded(at: now), let end = group.sprint?.end {
                Chip(text: "Ended \(end.formatted(date: .abbreviated, time: .omitted)), still in QA", color: Theme.warning)
            } else if group.isCurrent(at: now) {
                Chip(text: "Current", color: Theme.accent)
            }
            Spacer()
            Text("\(group.candidates.count) \(group.candidates.count == 1 ? "ticket" : "tickets") · ~\(text(group.estimateMinutes))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func loadCalendarAndPlan(day: Date) async {
        do {
            calendarBusy = try await CalendarService().busyIntervals(on: day)
            calendarNote = nil
        } catch {
            calendarBusy = []
            calendarNote = "Calendar unavailable, so meetings are not subtracted. \(error.localizedDescription)"
        }
        store.ensureQAPlan(for: day, calendarBusy: calendarBusy)
    }
}

/// One ticket in a QA plan. Verified tickets show a seal instead of the planned toggle; `onExclude` adds a remove button.
struct QAPlanTicketRow: View {
    @Environment(AppStore.self) private var store
    let candidate: QAPlanCandidate
    let planned: Bool
    let day: Date
    @Binding var selectedTicketID: UUID?
    var onExclude: (() -> Void)?

    var body: some View {
        let verified = candidate.state == .verified
        HStack(spacing: 10) {
            if verified {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success).frame(width: 22)
            } else {
                Toggle("", isOn: Binding(get: { planned }, set: { _ in store.toggleQAPlanned(candidate.id, on: day) }))
                    .labelsHidden()
                    .toggleStyle(RoundCheckStyle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.ticket.title).lineLimit(1)
                Text(candidate.ticket.displayKey).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: candidate.state.title, color: candidate.state.color)
            if let environment = candidate.ticket.environment { Chip(text: environment.title, color: environment.color) }
            if !verified {
                Text("~\(Format.short(TimeInterval(candidate.estimateMinutes * 60)))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let onExclude {
                Button(action: onExclude) { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Exclude from this plan")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .selectsTicket(candidate.id, selection: $selectedTicketID)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!` with no errors. If `QAState.title`/`.color` are not found, they are defined in `Sources/FocusTracker/QAQueueView.swift` (`extension QAState`), so the cause is something else; read the error.

- [ ] **Step 4: Commit**

```bash
git add Sources/FocusTracker/QATestPlanCard.swift Sources/FocusTracker/QAMilestonePlansView.swift
git commit -m "feat: group the QA test plan by sprint and add plan tabs"
```

---

### Task 5: Milestones tab

**Files:**
- Modify (replace entire contents): `Sources/FocusTracker/QAMilestonePlansView.swift`

**Interfaces:**
- Consumes: `AppStore.qaActiveMilestonePlans`, `qaPlannableMilestones()`, `addQAMilestonePlan`, `setQAMilestoneTarget`, `excludeFromQAMilestonePlan`, `restoreToQAMilestonePlan`, `archiveQAMilestonePlan`, `qaMilestoneProgress(for:)`, `qaExcludedTickets(for:)`, `qaPlan(for:)`; `QAPlanTicketRow` (Task 4); existing `DashboardBar`, `Chip`, `EmptyHint`, `cardStyle`, `Theme`.
- Produces: `QAMilestonePlansView(selectedTicketID:)`.

- [ ] **Step 1: Replace `Sources/FocusTracker/QAMilestonePlansView.swift`**

```swift
import FocusCore
import SwiftUI

/// The Milestones tab: one card per milestone plan with its progress, target date and tickets.
struct QAMilestonePlansView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?

    var body: some View {
        let plans = store.qaActiveMilestonePlans
        let plannable = store.qaPlannableMilestones()

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(plans.count) \(plans.count == 1 ? "milestone plan" : "milestone plans")")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(plannable, id: \.title) { milestone in
                        Button(milestone.isOpen ? milestone.title : "\(milestone.title) (closed)") { store.addQAMilestonePlan(milestone) }
                    }
                } label: {
                    Label("Plan a milestone", systemImage: "plus")
                }
                .fixedSize()
                .disabled(plannable.isEmpty)
                .help(plannable.isEmpty ? "Every milestone already has a plan" : "Start a test plan for a milestone")
            }

            if plans.isEmpty {
                EmptyHint(text: "No milestone plans yet. Plan a milestone to track its tickets as one release.", symbol: "flag.checkered")
            } else {
                ForEach(plans) { plan in
                    MilestonePlanCard(plan: plan, selectedTicketID: $selectedTicketID)
                }
            }
        }
    }
}

private struct MilestonePlanCard: View {
    @Environment(AppStore.self) private var store
    let plan: QAMilestonePlan
    @Binding var selectedTicketID: UUID?
    @State private var expanded = false
    @State private var editingTarget = false
    @State private var targetDraft = Date()

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    var body: some View {
        let now = store.now
        let progress = store.qaMilestoneProgress(for: plan)
        let overdue = progress.isOverdue(at: now)
        let plannedIDs = Set(store.qaPlan(for: now)?.ticketIDs ?? [])

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered").foregroundStyle(Theme.accent)
                Text(plan.milestone).font(.headline)
                Spacer()
                targetLabel(progress, overdue: overdue, now: now)
                menu
            }

            if progress.tickets.isEmpty {
                Text("Nothing waiting for QA in this milestone.").font(.callout).foregroundStyle(.secondary)
            } else {
                DashboardBar(segments: [
                    .init(value: progress.verified, color: Theme.success),
                    .init(value: progress.count(.testing), color: Theme.info),
                    .init(value: progress.count(.failed), color: Theme.danger)
                ])
                Text("\(progress.verified) of \(progress.total) verified · ~\(text(progress.remainingMinutes)) remaining")
                    .font(.callout.monospacedDigit())
                HStack(spacing: 6) {
                    Chip(text: "Failed \(progress.count(.failed))", color: Theme.danger)
                    Chip(text: "Testing \(progress.count(.testing))", color: Theme.info)
                    Chip(text: "Ready \(progress.count(.ready))", color: Theme.warning)
                    Chip(text: "Verified \(progress.verified)", color: Theme.success)
                    Spacer()
                    Button(expanded ? "Hide tickets" : "Show tickets") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
                if expanded {
                    VStack(spacing: 0) {
                        ForEach(Array(progress.tickets.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { Divider() }
                            QAPlanTicketRow(
                                candidate: candidate, planned: plannedIDs.contains(candidate.id), day: now,
                                selectedTicketID: $selectedTicketID,
                                onExclude: { store.excludeFromQAMilestonePlan(plan.id, ticketID: candidate.id) }
                            )
                        }
                    }
                    .cardStyle(padding: 0)
                }
            }
        }
        .cardStyle()
        .popover(isPresented: $editingTarget) { targetEditor }
    }

    private func targetLabel(_ progress: QAMilestoneProgress, overdue: Bool, now: Date) -> some View {
        Group {
            if let target = plan.targetDate {
                let days = progress.daysRemaining(at: now) ?? 0
                let when = days == 0 ? "today" : days > 0 ? "in \(days)d" : overdue ? "\(-days)d overdue" : "passed"
                Text("Target \(target.formatted(date: .abbreviated, time: .omitted)) · \(when)")
                    .foregroundStyle(overdue ? Theme.danger : Color.secondary)
            } else {
                Text("No target date").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
    }

    private var menu: some View {
        let excluded = store.qaExcludedTickets(for: plan)
        return Menu {
            Button("Edit target date…") {
                targetDraft = plan.targetDate ?? store.now
                editingTarget = true
            }
            if !excluded.isEmpty {
                Menu("Excluded tickets") {
                    ForEach(excluded) { ticket in
                        Button("Restore \(ticket.title)") { store.restoreToQAMilestonePlan(plan.id, ticketID: ticket.id) }
                    }
                }
            }
            Divider()
            Button("Archive plan") { store.archiveQAMilestonePlan(plan.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Target date", selection: $targetDraft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Clear") {
                    store.setQAMilestoneTarget(plan.id, nil)
                    editingTarget = false
                }
                Spacer()
                Button("Save") {
                    store.setQAMilestoneTarget(plan.id, Calendar.current.startOfDay(for: targetDraft))
                    editingTarget = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`. Likely fix points if not: `DashboardBar.Segment` memberwise init is `Segment(value:color:)` (the `id` has a default), so `.init(value:color:)` should resolve; if the compiler cannot infer, write `DashboardBar.Segment(value:color:)`.

- [ ] **Step 3: Run the full test suite**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed"`
Expected: 0 failures.

- [ ] **Step 4: Manual check (do not launch the built app)**

Read `QATestPlanCard.swift` and `QAMilestonePlansView.swift` once against the spec's UI section: Today tab has sprint headers with Ended/Current chip, count and estimate; Milestones tab has the Plan a milestone menu, per-plan card with target date (red when overdue), progress bar, state counts, Show tickets with Exclude, and the menu with Edit target date / Excluded tickets / Archive; empty plan text.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusTracker/QAMilestonePlansView.swift
git commit -m "feat: add the QA milestone plans tab"
```

---

## Self-Review

**Spec coverage**
- Data model fields, optional snapshot, one active plan per title: Task 2.
- Plan tickets, progress, estimate (unverified only), sprint choice, sprint groups, ended/current, plannable milestones, overdue: Tasks 1 and 3.
- `autoPick` sprint order: Task 1 (`testAutoPickTakesTheOldestSprintFirst`).
- `toggleQAPlanned` reused; excluding does not touch today's plan: Task 3 test and Task 5 (`onExclude` only calls `excludeFromQAMilestonePlan`).
- Today tab (groups, badges, count, estimate) and Milestones tab (picker, cards, expander, exclude, menu, empty state, overdue colour): Tasks 4 and 5.
- Edge cases: renamed or removed milestone shows the empty state and can be archived (Task 3 `testPlanWithNoMatchingTicketsIsEmpty`, Task 5); stale excluded IDs ignored (`compactMap`); duplicate plan no-op (Task 2).
- Tests listed in the spec: all present; the snapshot round trip and the missing-key load are in Task 2.

**Placeholder scan:** none; every code step has full code.

**Type consistency:** `qaCandidates(includeVerified:)`, `QAPlanCandidate.sprint`, `QASprintGroup`, `qaPlanSprintGroups()`, `QAMilestonePlan`, `QAMilestoneProgress` members, store method names and `QAPlanTicketRow` parameters match between the Interfaces blocks, the tests and the UI code.
