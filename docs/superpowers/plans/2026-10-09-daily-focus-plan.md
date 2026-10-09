# Daily Focus Plan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Plan" card to the Today view that suggests a ranked set of tickets fitting today's real capacity (working time minus meetings, times a focus factor).

**Architecture:** A pure `DayPlanner` in `FocusCore` computes capacity, ranks tickets and auto-picks within capacity. `AppStore` persists one `DayPlan` per day in `data.json` and exposes plan APIs. The SwiftUI layer adds three settings, a calendar busy-interval query and a `DayPlanCard` on `TodayView`.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation, EventKit, XCTest. macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-09-daily-focus-plan-design.md`

## Global Constraints

- Defaults: daily working time 8h (480 min), focus factor 75%, default estimate 1h (60 min).
- Eligible tickets: status Todo, In Progress or In Review, and `github?.remoteClosed != true`. Done and Backlog are excluded.
- Ranking signals, strongest first: overdue/due today, due within 2 days, current sprint ends within 2 days, carried over, In Progress/In Review, priority. Within the same signal: higher priority first, then oldest `updatedAt`.
- Due date = `Ticket.dueDate`, else the "Target date" issue field's `start`.
- Calendar: timed events only; exclude cancelled and declined; overlapping intervals (events and logged activities) count once; free time never below zero.
- If calendar access fails, treat calendar busy time as zero and show a note on the card.
- The plan is created once (first time Today has at least one candidate) and never rearranged except by the user ("Re-suggest" rebuilds it).
- Persistence is in `~/Library/Application Support/FocusTracker/data.json`; new snapshot fields must be optional so older files still load.
- The workspace is not a git repository: "checkpoint" steps run the test suite instead of committing.
- Run tests with `swift test` from `/Volumes/Dev/My Projects/focus-tracker`. Build the app with `./scripts/build-app.sh`.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FocusCore/DayPlanner.swift` (new) | `PlanSettings`, `Capacity`, `PlanReason`, `PlanCandidate`, and pure `DayPlanner` functions |
| `Sources/FocusCore/Models.swift` (modify) | add `DayPlan` |
| `Sources/FocusCore/AppStore.swift` (modify) | `PrefKey` entries, `dayPlans` state, persistence, plan APIs |
| `Sources/FocusTracker/CalendarService.swift` (modify) | `busyIntervals(on:)` |
| `Sources/FocusTracker/SettingsView.swift` (modify) | "Daily plan" section |
| `Sources/FocusTracker/DayPlanCard.swift` (new) | the Plan card |
| `Sources/FocusTracker/TodayView.swift` (modify) | show the card on today |
| `Tests/FocusCoreTests/DayPlannerTests.swift` (new) | planner tests |
| `Tests/FocusCoreTests/DayPlanStoreTests.swift` (new) | store tests |

---

### Task 1: Capacity calculation

**Files:**
- Create: `Sources/FocusCore/DayPlanner.swift`
- Test: `Tests/FocusCoreTests/DayPlannerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct PlanSettings: Equatable, Sendable { workingMinutes: Int; focusFactor: Double; defaultEstimateMinutes: Int; init(workingMinutes: Int = 480, focusFactor: Double = 0.75, defaultEstimateMinutes: Int = 60) }`
  - `public struct Capacity: Equatable, Sendable { freeMinutes: Int; capacityMinutes: Int }`
  - `DayPlanner.capacity(day: DateInterval, busy: [DateInterval], settings: PlanSettings) -> Capacity`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/DayPlannerTests.swift`:

```swift
import XCTest
@testable import FocusCore

final class DayPlannerTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private var base: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 9))! }
    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }
    private var day: DateInterval { DateInterval(start: base, end: at(24)) }
    private func span(_ from: Double, _ to: Double) -> DateInterval { DateInterval(start: at(from), end: at(to)) }

    // MARK: Capacity

    func testCapacityWithNoMeetingsAppliesFocusFactor() {
        let result = DayPlanner.capacity(day: day, busy: [], settings: PlanSettings())
        XCTAssertEqual(result.freeMinutes, 480)
        XCTAssertEqual(result.capacityMinutes, 360)
    }

    func testOverlappingBusyIntervalsCountOnce() {
        let settings = PlanSettings(focusFactor: 1)
        let result = DayPlanner.capacity(day: day, busy: [span(9, 10), span(9.5, 10.5)], settings: settings)
        XCTAssertEqual(result.freeMinutes, 480 - 90)
    }

    func testBusyIntervalsAreClippedToTheDay() {
        let settings = PlanSettings(focusFactor: 1)
        let result = DayPlanner.capacity(day: day, busy: [span(-1, 1)], settings: settings)
        XCTAssertEqual(result.freeMinutes, 480 - 60)
    }

    func testFreeTimeNeverGoesBelowZero() {
        let result = DayPlanner.capacity(day: day, busy: [span(8, 20)], settings: PlanSettings())
        XCTAssertEqual(result.freeMinutes, 0)
        XCTAssertEqual(result.capacityMinutes, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DayPlannerTests`
Expected: build FAIL with "cannot find 'DayPlanner' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/FocusCore/DayPlanner.swift`:

```swift
import Foundation

public struct PlanSettings: Equatable, Sendable {
    public var workingMinutes: Int
    public var focusFactor: Double
    public var defaultEstimateMinutes: Int

    public init(workingMinutes: Int = 480, focusFactor: Double = 0.75, defaultEstimateMinutes: Int = 60) {
        self.workingMinutes = workingMinutes
        self.focusFactor = focusFactor
        self.defaultEstimateMinutes = defaultEstimateMinutes
    }
}

public struct Capacity: Equatable, Sendable {
    /// Working time left after meetings and logged activities.
    public var freeMinutes: Int
    /// Free time scaled by the focus factor.
    public var capacityMinutes: Int
}

public enum DayPlanner {
    public static func capacity(day: DateInterval, busy: [DateInterval], settings: PlanSettings) -> Capacity {
        let free = max(0, settings.workingMinutes - busyMinutes(busy, within: day))
        return Capacity(freeMinutes: free, capacityMinutes: Int((Double(free) * settings.focusFactor).rounded()))
    }

    /// Minutes covered by the union of `busy`, clipped to `day`.
    static func busyMinutes(_ busy: [DateInterval], within day: DateInterval) -> Int {
        let clipped = busy
            .compactMap { $0.intersection(with: day) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in clipped {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                if let open = current { total += open.duration }
                current = interval
            }
        }
        if let open = current { total += open.duration }
        return Int((total / 60).rounded())
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DayPlannerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Checkpoint**

Run: `swift test`
Expected: all existing tests still PASS.

---

### Task 2: Ranking and auto-pick

**Files:**
- Modify: `Sources/FocusCore/DayPlanner.swift`
- Test: `Tests/FocusCoreTests/DayPlannerTests.swift`

**Interfaces:**
- Consumes: `PlanSettings` from Task 1; existing `Ticket`, `TicketStatus`, `Priority`, `CustomField`.
- Produces:
  - `public enum PlanReason: Int, Sendable { case dueNow, dueSoon, sprintEnding, carriedOver, inProgress, priority, open; var title: String }`
  - `public struct PlanCandidate: Identifiable, Equatable, Sendable { ticket: Ticket; reason: PlanReason; estimateMinutes: Int; estimatedByApp: Bool; id: UUID }`
  - `DayPlanner.rank(tickets: [Ticket], carriedOver: Set<UUID>, now: Date, settings: PlanSettings, calendar: Calendar = .current) -> [PlanCandidate]`
  - `DayPlanner.autoPick(_ candidates: [PlanCandidate], capacityMinutes: Int) -> [UUID]`
  - `DayPlanner.plannedMinutes(_ candidates: [PlanCandidate], ids: Set<UUID>) -> Int`

- [ ] **Step 1: Write the failing tests**

Append inside `DayPlannerTests` (before the closing brace):

```swift
    // MARK: Ranking

    private func ticket(
        _ title: String,
        status: TicketStatus = .todo,
        priority: Priority = .none,
        fields: [CustomField]? = nil,
        issueFields: [CustomField]? = nil,
        due: Date? = nil,
        estimate: Int? = nil,
        updated: Double = 0,
        github: GitHubRef? = nil
    ) -> Ticket {
        Ticket(
            title: title, status: status, priority: priority, fields: fields, issueFields: issueFields,
            dueDate: due, estimateMinutes: estimate, updatedAt: at(-1000 + updated), github: github
        )
    }

    private func rank(_ tickets: [Ticket], carried: Set<UUID> = []) -> [PlanCandidate] {
        DayPlanner.rank(tickets: tickets, carriedOver: carried, now: at(9), settings: PlanSettings(), calendar: cal)
    }

    func testRankingOrderFollowsSignalStrength() {
        let sprint = CustomField(name: "Sprint", value: "S1", kind: .iteration, project: "P", start: at(-100), end: at(30))
        let carried = ticket("carried")
        let tickets = [
            ticket("plain"),
            ticket("high", priority: .high),
            ticket("doing", status: .inProgress),
            carried,
            ticket("sprint", fields: [sprint]),
            ticket("soon", due: at(24 + 6)),
            ticket("today", due: at(15), updated: 1),
            ticket("overdue", due: at(-48)),
        ]
        let ranked = rank(tickets, carried: [carried.id])
        XCTAssertEqual(ranked.map(\.ticket.title), ["overdue", "today", "soon", "sprint", "carried", "doing", "high", "plain"])
        XCTAssertEqual(ranked.map(\.reason), [.dueNow, .dueNow, .dueSoon, .sprintEnding, .carriedOver, .inProgress, .priority, .open])
    }

    func testWithinSameSignalHigherPriorityThenOldestWins() {
        let ranked = rank([
            ticket("new low", priority: .low, updated: 5),
            ticket("old low", priority: .low, updated: 1),
            ticket("urgent", priority: .urgent, updated: 9),
        ])
        XCTAssertEqual(ranked.map(\.ticket.title), ["urgent", "old low", "new low"])
    }

    func testIneligibleTicketsAreExcluded() {
        let closed = GitHubRef(repo: "o/r", number: 1, url: "", remoteClosed: true)
        let ranked = rank([
            ticket("backlog", status: .backlog),
            ticket("done", status: .done),
            ticket("closed", github: closed),
            ticket("ok", status: .inReview),
        ])
        XCTAssertEqual(ranked.map(\.ticket.title), ["ok"])
    }

    func testEstimateFallsBackToDefaultAndIsMarked() {
        let ranked = rank([ticket("own", estimate: 30, updated: 1), ticket("none", updated: 2)])
        XCTAssertEqual(ranked[0].estimateMinutes, 30)
        XCTAssertFalse(ranked[0].estimatedByApp)
        XCTAssertEqual(ranked[1].estimateMinutes, 60)
        XCTAssertTrue(ranked[1].estimatedByApp)
    }

    func testTargetDateIssueFieldCountsAsDueDate() {
        let target = CustomField(name: "Target date", value: "", kind: .date, project: CustomField.issueFieldsGroup, start: at(10))
        let ranked = rank([ticket("t", issueFields: [target])])
        XCTAssertEqual(ranked.first?.reason, .dueNow)
    }

    // MARK: Auto-pick

    func testAutoPickStopsBeforeExceedingCapacity() {
        let ranked = rank([
            ticket("a", priority: .urgent, estimate: 120),
            ticket("b", priority: .high, estimate: 120),
            ticket("c", priority: .low, estimate: 120),
        ])
        let picked = DayPlanner.autoPick(ranked, capacityMinutes: 240)
        XCTAssertEqual(picked, ranked.prefix(2).map(\.id))
        XCTAssertEqual(DayPlanner.plannedMinutes(ranked, ids: Set(picked)), 240)
    }

    func testAutoPickAlwaysKeepsTheFirstCandidate() {
        let ranked = rank([ticket("big", estimate: 600)])
        XCTAssertEqual(DayPlanner.autoPick(ranked, capacityMinutes: 60), ranked.map(\.id))
        XCTAssertEqual(DayPlanner.autoPick([], capacityMinutes: 60), [])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DayPlannerTests`
Expected: build FAIL with "cannot find 'PlanCandidate'" / "has no member 'rank'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/FocusCore/DayPlanner.swift`, add above `public enum DayPlanner`:

```swift
/// Why a ticket is suggested; the raw value is its rank (lower is stronger).
public enum PlanReason: Int, Sendable {
    case dueNow, dueSoon, sprintEnding, carriedOver, inProgress, priority, open

    public var title: String {
        switch self {
        case .dueNow: "Due now"
        case .dueSoon: "Due soon"
        case .sprintEnding: "Sprint ends soon"
        case .carriedOver: "Carried over"
        case .inProgress: "In progress"
        case .priority: "Priority"
        case .open: "Open"
        }
    }
}

public struct PlanCandidate: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var reason: PlanReason
    public var estimateMinutes: Int
    /// True when the ticket has no estimate and the default was used.
    public var estimatedByApp: Bool

    public var id: UUID { ticket.id }
}
```

Add inside `DayPlanner`:

```swift
    public static func rank(
        tickets: [Ticket], carriedOver: Set<UUID>, now: Date, settings: PlanSettings, calendar: Calendar = .current
    ) -> [PlanCandidate] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let soonLimit = calendar.date(byAdding: .day, value: 3, to: today) ?? today

        func reason(for ticket: Ticket) -> PlanReason {
            if let due = dueDate(of: ticket) {
                if due < tomorrow { return .dueNow }
                if due < soonLimit { return .dueSoon }
            }
            if ticket.sprints.contains(where: { $0.isCurrent(at: now) && ($0.end ?? .distantFuture) < soonLimit }) {
                return .sprintEnding
            }
            if carriedOver.contains(ticket.id) { return .carriedOver }
            if ticket.status == .inProgress || ticket.status == .inReview { return .inProgress }
            return ticket.priority == .none ? .open : .priority
        }

        return tickets
            .filter { [.todo, .inProgress, .inReview].contains($0.status) && $0.github?.remoteClosed != true }
            .map { ticket -> PlanCandidate in
                let estimate = ticket.effectiveEstimateMinutes
                return PlanCandidate(
                    ticket: ticket,
                    reason: reason(for: ticket),
                    estimateMinutes: estimate ?? settings.defaultEstimateMinutes,
                    estimatedByApp: estimate == nil
                )
            }
            .sorted {
                if $0.reason != $1.reason { return $0.reason.rawValue < $1.reason.rawValue }
                if $0.ticket.priority != $1.ticket.priority { return $0.ticket.priority.rawValue > $1.ticket.priority.rawValue }
                return $0.ticket.updatedAt < $1.ticket.updatedAt
            }
    }

    /// Takes candidates in rank order until the next one would not fit; always keeps the first.
    public static func autoPick(_ candidates: [PlanCandidate], capacityMinutes: Int) -> [UUID] {
        var remaining = capacityMinutes
        var picked: [UUID] = []
        for candidate in candidates {
            if candidate.estimateMinutes > remaining { break }
            remaining -= candidate.estimateMinutes
            picked.append(candidate.id)
        }
        if picked.isEmpty, let first = candidates.first { return [first.id] }
        return picked
    }

    public static func plannedMinutes(_ candidates: [PlanCandidate], ids: Set<UUID>) -> Int {
        candidates.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.estimateMinutes }
    }

    /// The local due date, else the GitHub "Target date" issue field.
    static func dueDate(of ticket: Ticket) -> Date? {
        ticket.dueDate ?? ticket.field(named: "Target date")?.start
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DayPlannerTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Checkpoint**

Run: `swift test`
Expected: all tests PASS.

---

### Task 3: Day plan model, preferences and store persistence

**Files:**
- Modify: `Sources/FocusCore/Models.swift` (append `DayPlan` at end of file)
- Modify: `Sources/FocusCore/AppStore.swift` (`PrefKey` at lines 5-10; state near line 32; `Snapshot`/`load`/`save` near lines 628-680; new methods under a `// MARK: - Day plan` section placed before `// MARK: - Persistence`)
- Test: `Tests/FocusCoreTests/DayPlanStoreTests.swift`

**Interfaces:**
- Consumes: `DayPlanner`, `PlanSettings`, `Capacity`, `PlanCandidate` from Tasks 1-2.
- Produces:
  - `public struct DayPlan: Identifiable, Codable, Hashable, Sendable { day: Date; ticketIDs: [UUID]; id: Date }`
  - `PrefKey.workingMinutes = "planWorkingMinutes"`, `PrefKey.focusPercent = "planFocusPercent"`, `PrefKey.defaultEstimateMinutes = "planDefaultEstimateMinutes"`
  - On `AppStore`:
    - `public private(set) var dayPlans: [DayPlan]`
    - `public var planSettings: PlanSettings`
    - `public func plan(for day: Date, calendar: Calendar = .current) -> DayPlan?`
    - `public func planCandidates(for day: Date, calendar: Calendar = .current) -> [PlanCandidate]`
    - `public func capacity(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> Capacity`
    - `@discardableResult public func ensurePlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan?`
    - `@discardableResult public func suggestPlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan?`
    - `public func togglePlanned(_ ticketID: UUID, on day: Date, calendar: Calendar = .current)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/DayPlanStoreTests.swift`:

```swift
import XCTest
@testable import FocusCore

@MainActor
final class DayPlanStoreTests: XCTestCase {
    private func makeStore() -> (AppStore, URL, UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url, defaults)
    }

    @discardableResult
    private func addTicket(_ store: AppStore, _ title: String, _ priority: Priority, minutes: Int) -> Ticket {
        let ticket = store.addTicket(title: title, priority: priority)
        store.update(ticket.id) { $0.estimateMinutes = minutes }
        return store.ticket(ticket.id)!
    }

    func testSettingsDefaultsAndOverrides() {
        let (store, _, defaults) = makeStore()
        XCTAssertEqual(store.planSettings, PlanSettings(workingMinutes: 480, focusFactor: 0.75, defaultEstimateMinutes: 60))

        defaults.set(360, forKey: PrefKey.workingMinutes)
        defaults.set(50, forKey: PrefKey.focusPercent)
        defaults.set(30, forKey: PrefKey.defaultEstimateMinutes)
        XCTAssertEqual(store.planSettings, PlanSettings(workingMinutes: 360, focusFactor: 0.5, defaultEstimateMinutes: 30))
    }

    func testCapacitySubtractsLoggedActivities() {
        let (store, _, _) = makeStore()
        let start = Calendar.current.startOfDay(for: Date())
        store.addActivity(kind: .meeting, title: "Sync", start: start.addingTimeInterval(9 * 3600), end: start.addingTimeInterval(10 * 3600))
        let capacity = store.capacity(for: Date(), calendarBusy: [DateInterval(start: start.addingTimeInterval(9.5 * 3600), end: start.addingTimeInterval(11 * 3600))])
        XCTAssertEqual(capacity.freeMinutes, 480 - 120)
    }

    func testEnsurePlanPicksWithinCapacityAndIsCreatedOnce() {
        let (store, _, _) = makeStore()
        let a = addTicket(store, "a", .urgent, minutes: 120)
        let b = addTicket(store, "b", .high, minutes: 120)
        let c = addTicket(store, "c", .medium, minutes: 120)
        addTicket(store, "d", .low, minutes: 120)

        let plan = store.ensurePlan(for: Date(), calendarBusy: [])
        XCTAssertEqual(plan?.ticketIDs, [a.id, b.id, c.id])

        addTicket(store, "e", .urgent, minutes: 30)
        XCTAssertEqual(store.ensurePlan(for: Date(), calendarBusy: [])?.ticketIDs, [a.id, b.id, c.id])
    }

    func testNoPlanIsCreatedWithoutCandidates() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.ensurePlan(for: Date(), calendarBusy: []))
        XCTAssertNil(store.plan(for: Date()))
    }

    func testTogglePlannedAddsAndRemoves() {
        let (store, _, _) = makeStore()
        let a = addTicket(store, "a", .none, minutes: 60)
        store.togglePlanned(a.id, on: Date())
        XCTAssertEqual(store.plan(for: Date())?.ticketIDs, [a.id])
        store.togglePlanned(a.id, on: Date())
        XCTAssertEqual(store.plan(for: Date())?.ticketIDs, [])
    }

    func testSuggestPlanRebuildsAnExistingPlan() {
        let (store, _, _) = makeStore()
        let a = addTicket(store, "a", .urgent, minutes: 60)
        let b = addTicket(store, "b", .low, minutes: 60)
        store.togglePlanned(b.id, on: Date())
        XCTAssertEqual(store.suggestPlan(for: Date(), calendarBusy: [])?.ticketIDs, [a.id, b.id])
        XCTAssertEqual(store.dayPlans.count, 1)
    }

    func testUnfinishedTicketsFromEarlierPlanAreCarriedOver() {
        let (store, _, _) = makeStore()
        let carried = addTicket(store, "carried", .none, minutes: 60)
        let finished = addTicket(store, "finished", .none, minutes: 60)
        addTicket(store, "other", .low, minutes: 60)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        store.togglePlanned(carried.id, on: yesterday)
        store.togglePlanned(finished.id, on: yesterday)
        store.setStatus(finished.id, .done)

        let candidates = store.planCandidates(for: Date())
        XCTAssertEqual(candidates.first?.ticket.id, carried.id)
        XCTAssertEqual(candidates.first?.reason, .carriedOver)
        XCTAssertFalse(candidates.contains { $0.ticket.id == finished.id })
    }

    func testPlansPersistAcrossReload() {
        let (store, url, defaults) = makeStore()
        let a = addTicket(store, "a", .none, minutes: 60)
        store.togglePlanned(a.id, on: Date())

        let reloaded = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        XCTAssertEqual(reloaded.plan(for: Date())?.ticketIDs, [a.id])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DayPlanStoreTests`
Expected: build FAIL with "value of type 'AppStore' has no member 'planSettings'".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/FocusCore/Models.swift`:

```swift
/// The tickets the user committed to on one calendar day.
public struct DayPlan: Identifiable, Codable, Hashable, Sendable {
    /// Start of the day.
    public var day: Date
    public var ticketIDs: [UUID]

    public var id: Date { day }

    public init(day: Date, ticketIDs: [UUID] = []) {
        self.day = day
        self.ticketIDs = ticketIDs
    }
}
```

In `Sources/FocusCore/AppStore.swift`:

1. Add to `PrefKey`:

```swift
    public static let workingMinutes = "planWorkingMinutes"
    public static let focusPercent = "planFocusPercent"
    public static let defaultEstimateMinutes = "planDefaultEstimateMinutes"
```

2. Add state after `public private(set) var activities: [Activity] = []`:

```swift
    public private(set) var dayPlans: [DayPlan] = []
```

3. Add `var dayPlans: [DayPlan]?` to `Snapshot`, then in `load()` after `planComments = snapshot.planComments ?? []` add `dayPlans = snapshot.dayPlans ?? []`, and change the `Snapshot(...)` call in `save()` to:

```swift
let data = try encoder.encode(Snapshot(tickets: tickets, entries: entries, notes: notes, planComments: planComments, activities: activities, dayPlans: dayPlans))
```

4. Add before `// MARK: - Persistence`:

```swift
    // MARK: - Day plan

    public var planSettings: PlanSettings {
        let working = defaults.object(forKey: PrefKey.workingMinutes) as? Int ?? 480
        let focus = defaults.object(forKey: PrefKey.focusPercent) as? Int ?? 75
        let estimate = defaults.object(forKey: PrefKey.defaultEstimateMinutes) as? Int ?? 60
        return PlanSettings(workingMinutes: working, focusFactor: Double(focus) / 100, defaultEstimateMinutes: estimate)
    }

    public func plan(for day: Date, calendar: Calendar = .current) -> DayPlan? {
        dayPlans.first { calendar.isDate($0.day, inSameDayAs: day) }
    }

    /// Ranked suggestions for `day`; tickets from the most recent earlier plan that are still open rank as carried over.
    public func planCandidates(for day: Date, calendar: Calendar = .current) -> [PlanCandidate] {
        let start = calendar.startOfDay(for: day)
        let earlier = dayPlans.filter { $0.day < start }.max { $0.day < $1.day }
        let carried = Set((earlier?.ticketIDs ?? []).filter { ticket($0).map { $0.status != .done } ?? false })
        return DayPlanner.rank(tickets: tickets, carriedOver: carried, now: now, settings: planSettings, calendar: calendar)
    }

    public func capacity(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> Capacity {
        let logged = activities.compactMap { activity -> DateInterval? in
            let end = activity.end ?? now
            return end > activity.start ? DateInterval(start: activity.start, end: end) : nil
        }
        return DayPlanner.capacity(day: dayRange(for: day, calendar: calendar), busy: calendarBusy + logged, settings: planSettings)
    }

    /// Returns the day's plan, creating it from the suggestions the first time there are any.
    @discardableResult
    public func ensurePlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan? {
        plan(for: day, calendar: calendar) ?? suggestPlan(for: day, calendarBusy: calendarBusy, calendar: calendar)
    }

    /// Builds the plan from the ranked suggestions, replacing any existing plan for the day.
    @discardableResult
    public func suggestPlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan? {
        let candidates = planCandidates(for: day, calendar: calendar)
        guard !candidates.isEmpty else { return nil }
        let capacity = capacity(for: day, calendarBusy: calendarBusy, calendar: calendar)
        let plan = DayPlan(
            day: calendar.startOfDay(for: day),
            ticketIDs: DayPlanner.autoPick(candidates, capacityMinutes: capacity.capacityMinutes)
        )
        dayPlans.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        dayPlans.append(plan)
        save()
        return plan
    }

    public func togglePlanned(_ ticketID: UUID, on day: Date, calendar: Calendar = .current) {
        if let index = dayPlans.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            if let position = dayPlans[index].ticketIDs.firstIndex(of: ticketID) {
                dayPlans[index].ticketIDs.remove(at: position)
            } else {
                dayPlans[index].ticketIDs.append(ticketID)
            }
        } else {
            dayPlans.append(DayPlan(day: calendar.startOfDay(for: day), ticketIDs: [ticketID]))
        }
        save()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DayPlanStoreTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Checkpoint**

Run: `swift test`
Expected: all tests PASS (including legacy-file tests, since `dayPlans` is optional in the snapshot).

---

### Task 4: Calendar busy intervals and settings UI

**Files:**
- Modify: `Sources/FocusTracker/CalendarService.swift` (add method inside `CalendarService`)
- Modify: `Sources/FocusTracker/SettingsView.swift`

**Interfaces:**
- Consumes: `PrefKey.workingMinutes`, `PrefKey.focusPercent`, `PrefKey.defaultEstimateMinutes` from Task 3; existing `Format.short(_:)`.
- Produces: `CalendarService.busyIntervals(on day: Date) async throws -> [DateInterval]` (throws `CalendarError.denied`).

- [ ] **Step 1: Add the calendar query**

In `CalendarService`, after `startedEvents`:

```swift
    /// Timed events on `day` that the user has not cancelled or declined, as busy intervals.
    func busyIntervals(on day: Date) async throws -> [DateInterval] {
        guard try await eventStore.requestFullAccessToEvents() else { throw CalendarError.denied }

        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

        return eventStore.events(matching: predicate)
            .filter { event in
                let declined = event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
                return !event.isAllDay && event.status != .canceled && !declined && event.endDate > event.startDate
            }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }
```

- [ ] **Step 2: Add the settings**

In `SettingsView`, add next to the other `@AppStorage` properties:

```swift
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.defaultEstimateMinutes) private var defaultEstimateMinutes = 60
```

Add a section after the "Focus" section:

```swift
            Section("Daily plan") {
                Stepper("Daily working time: \(Format.short(TimeInterval(workingMinutes * 60)))", value: $workingMinutes, in: 60...960, step: 30)
                Stepper("Focus factor: \(focusPercent)%", value: $focusPercent, in: 30...100, step: 5)
                Stepper("Default estimate: \(Format.short(TimeInterval(defaultEstimateMinutes * 60)))", value: $defaultEstimateMinutes, in: 15...480, step: 15)
                Text("Capacity = (working time − meetings) × focus factor. Tickets without an estimate count as the default estimate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

Change `.frame(width: 520, height: 420)` to `.frame(width: 520, height: 560)`.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds with no errors.

- [ ] **Step 4: Checkpoint**

Run: `swift test`
Expected: all tests PASS.

---

### Task 5: Plan card on the Today view

**Files:**
- Create: `Sources/FocusTracker/DayPlanCard.swift`
- Modify: `Sources/FocusTracker/TodayView.swift` (insert the card in the main `VStack`, between the stat-card `HStack` and `if isToday { VStack ... "In progress" ... }`)

**Interfaces:**
- Consumes: `AppStore.planCandidates/plan/capacity/ensurePlan/suggestPlan/togglePlanned`, `DayPlanner.plannedMinutes`, `CalendarService.busyIntervals(on:)`, existing `SectionTitle`, `Chip`, `cardStyle`, `EmptyHint`, `Format.short`.
- Produces: `struct DayPlanCard: View` with `init(selectedTicketID: Binding<UUID?>)`.

- [ ] **Step 1: Create the card**

Create `Sources/FocusTracker/DayPlanCard.swift`:

```swift
import FocusCore
import SwiftUI

struct DayPlanCard: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var calendarBusy: [DateInterval] = []
    @State private var calendarNote: String?

    // Declared so the card re-renders when a plan setting changes in Settings.
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.defaultEstimateMinutes) private var defaultEstimateMinutes = 60

    private var day: Date { store.now }

    private func text(_ minutes: Int) -> String { Format.short(TimeInterval(minutes * 60)) }

    var body: some View {
        let candidates = store.planCandidates(for: day)
        let plannedIDs = Set(store.plan(for: day)?.ticketIDs ?? [])
        let capacity = store.capacity(for: day, calendarBusy: calendarBusy)
        let planned = DayPlanner.plannedMinutes(candidates, ids: plannedIDs)
        let over = planned > capacity.capacityMinutes

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Plan", count: candidates.filter { plannedIDs.contains($0.id) }.count)
                Spacer()
                Button("Re-suggest") { store.suggestPlan(for: day, calendarBusy: calendarBusy) }
                    .disabled(candidates.isEmpty)
                    .help("Rebuild the plan from the ranked suggestions")
            }

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(min(planned, max(capacity.capacityMinutes, 1))), total: Double(max(capacity.capacityMinutes, 1)))
                    .tint(over ? .orange : .accentColor)
                HStack {
                    Text("Planned \(text(planned)) of \(text(capacity.capacityMinutes)) capacity")
                        .foregroundStyle(over ? .orange : .primary)
                    Spacer()
                    Text("\(text(capacity.freeMinutes)) free after meetings").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                if over {
                    Label("Over capacity by \(text(planned - capacity.capacityMinutes))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let calendarNote { Text(calendarNote).font(.caption).foregroundStyle(.secondary) }
            }

            if candidates.isEmpty {
                EmptyHint(text: "No open tickets to plan. Sync GitHub or add a ticket.", symbol: "checklist")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { Divider() }
                        row(candidate, planned: plannedIDs.contains(candidate.id))
                    }
                }
                .cardStyle(padding: 0)
            }
        }
        .task(id: candidates.isEmpty) { await loadCalendarAndPlan() }
    }

    private func row(_ candidate: PlanCandidate, planned: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { planned }, set: { _ in store.togglePlanned(candidate.id, on: day) }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.ticket.title).lineLimit(1)
                Text(candidate.ticket.displayKey).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: candidate.reason.title, color: candidate.reason.color)
            Text("\(candidate.estimatedByApp ? "~" : "")\(text(candidate.estimateMinutes))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(candidate.estimatedByApp ? "Estimated by the app: no estimate on this ticket" : "Ticket estimate")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { selectedTicketID = candidate.id }
    }

    private func loadCalendarAndPlan() async {
        do {
            calendarBusy = try await CalendarService().busyIntervals(on: day)
            calendarNote = nil
        } catch {
            calendarBusy = []
            calendarNote = "Calendar unavailable, so meetings are not subtracted. \(error.localizedDescription)"
        }
        store.ensurePlan(for: day, calendarBusy: calendarBusy)
    }
}

private extension PlanReason {
    var color: Color {
        switch self {
        case .dueNow: .red
        case .dueSoon: .orange
        case .sprintEnding: .teal
        case .carriedOver: .purple
        case .inProgress: .blue
        case .priority: .yellow
        case .open: .secondary
        }
    }
}
```

- [ ] **Step 2: Show it on Today**

In `TodayView.body`, between the stat-card `HStack` and `if isToday { VStack ... }`, add:

```swift
                if isToday { DayPlanCard(selectedTicketID: $selectedTicketID) }
```

- [ ] **Step 3: Build and run the tests**

Run: `swift test && ./scripts/build-app.sh`
Expected: tests PASS; the script prints success and creates `build/FocusTracker.app`.

- [ ] **Step 4: Manual verification**

Run: `open build/FocusTracker.app`, then check on the Today view:
1. The Plan card shows a capacity bar and ranked rows; the top rows are pre-checked and fit within capacity.
2. Unchecking and checking a row updates "Planned ... of ... capacity"; checking enough rows turns the bar orange with the over-capacity label.
3. Quit and reopen: the same rows are still checked. "Re-suggest" resets them.
4. Settings (⌘,) → Daily plan: changing working time updates the capacity on the card.
5. Deny Calendar access in System Settings: the card shows the "Calendar unavailable" note and still works.

---

## Self-Review

- **Spec coverage:** settings and defaults (Tasks 3, 4); capacity with merged overlaps, clipping, floor at zero, focus factor (Task 1); calendar excludes cancelled and declined (Task 4); ranking with all six signals, priority/updatedAt ties, Target date (Task 2); auto-pick with first-candidate fallback and create-once plan (Tasks 2, 3); carry-over from the most recent earlier plan (Task 3); persistence with optional snapshot field (Task 3); Plan card with capacity bar, reasons, estimate marks, over-capacity warning, Re-suggest, calendar-failure note (Task 5).
- **Placeholders:** none.
- **Type consistency:** `PlanSettings`, `Capacity`, `PlanReason`, `PlanCandidate`, `DayPlanner.rank/autoPick/plannedMinutes/capacity` and the `AppStore` method names are used identically across tasks.
