# Action Log Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record every user action in a persisted action log (old/new values, sync state), with failed-entry and prune helpers on `AppStore`.

**Architecture:** A new `ActionLog.swift` in `FocusCore` holds the value types (`ActionLogEntry`, `ActionKind`, `ActionSync`, `FieldChange`) and a `Ticket.changes(to:)` diff. `AppStore` owns `actionLog`, persists it in `Snapshot`, and exposes `record(...)`, `setActionSync(...)`, `failedActions`, `deleteActionLog(olderThan:)`. Existing mutating methods call `record`. GitHub push results (project field, plan comment) update the entry's sync state. This is plan 1 of 3: no new GitHub endpoints and no UI.

**Tech Stack:** Swift 5.9, SwiftUI/Observation, XCTest (`swift test`), macOS 14.

**Spec:** `docs/superpowers/specs/2026-10-10-ticket-editing-action-log-design.md`

## Global Constraints

- Log entries are kept forever; only `deleteActionLog(olderThan:)` (user-triggered) removes them.
- Old `data.json` files without `actionLog` must load (field is optional in `Snapshot`).
- Sync-driven changes (`merge`, `copyContent`, `refreshTicket`) are NOT logged; only user actions are.
- Tests build `AppStore(storeURL:defaults:tokenProvider:)` with a temp file and a throwaway `UserDefaults` suite; test classes are `@MainActor`.
- Shell: `rm` is aliased; use `command rm` if deleting files.
- Spec deviation: structured old/new payloads are stored as string lists (`oldList`/`newList`) instead of JSON `Data`.

---

## File Structure

- Create `Sources/FocusCore/ActionLog.swift`: value types and `Ticket.changes(to:)`.
- Modify `Sources/FocusCore/AppStore.swift`: storage, `record`, queries, persistence, logging calls in existing methods.
- Create `Tests/FocusCoreTests/ActionLogTests.swift`: all tests for this plan.

---

### Task 1: Log value types and ticket diff

**Files:**
- Create: `Sources/FocusCore/ActionLog.swift`
- Test: `Tests/FocusCoreTests/ActionLogTests.swift`

**Interfaces:**
- Produces:
  - `enum ActionKind: String, Codable, CaseIterable, Sendable` — `ticketCreate, ticketEdit, ticketDelete, timer, timeEntry, note, planComment, dayPlan, activity`
  - `enum ActionSync: Codable, Equatable, Sendable` — `notApplicable, pending, synced(Date), failed(String)`
  - `struct FieldChange: Equatable, Sendable` — `field, old, new: String?`, `oldList, newList: [String]?`
  - `struct ActionLogEntry: Codable, Identifiable, Equatable, Sendable` (fields below)
  - `Ticket.changes(to: Ticket) -> [FieldChange]` — compares title, body, status, priority, labels, milestone, dueDate, estimateMinutes

- [ ] **Step 1: Write the failing test**

Create `Tests/FocusCoreTests/ActionLogTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ActionLogTests`
Expected: FAIL to compile ("value of type 'Ticket' has no member 'changes'").

- [ ] **Step 3: Write minimal implementation**

Create `Sources/FocusCore/ActionLog.swift`:

```swift
import Foundation

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case ticketCreate, ticketEdit, ticketDelete, timer, timeEntry, note, planComment, dayPlan, activity
}

public enum ActionSync: Codable, Equatable, Sendable {
    case notApplicable
    case pending
    case synced(Date)
    case failed(String)
}

public struct FieldChange: Equatable, Sendable {
    public var field: String
    public var old: String?
    public var new: String?
    public var oldList: [String]?
    public var newList: [String]?
}

public struct ActionLogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var kind: ActionKind
    /// Snapshots, so the entry stays readable after the ticket is deleted.
    public var ticketID: UUID?
    public var ticketKey: String?
    public var ticketTitle: String?
    public var field: String?
    public var oldValue: String?
    public var newValue: String?
    public var oldList: [String]?
    public var newList: [String]?
    public var sync: ActionSync
    public var githubDetail: String?

    public init(
        id: UUID = UUID(), timestamp: Date = Date(), kind: ActionKind,
        ticketID: UUID? = nil, ticketKey: String? = nil, ticketTitle: String? = nil,
        field: String? = nil, oldValue: String? = nil, newValue: String? = nil,
        oldList: [String]? = nil, newList: [String]? = nil,
        sync: ActionSync = .notApplicable, githubDetail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.ticketID = ticketID
        self.ticketKey = ticketKey
        self.ticketTitle = ticketTitle
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.oldList = oldList
        self.newList = newList
        self.sync = sync
        self.githubDetail = githubDetail
    }
}

extension Ticket {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayText(_ date: Date?) -> String { date.map { dayFormatter.string(from: $0) } ?? "None" }
    private static func minutesText(_ minutes: Int?) -> String { minutes.map { "\($0) min" } ?? "None" }
    private static func listText(_ items: [String]) -> String { items.isEmpty ? "None" : items.joined(separator: ", ") }

    /// User-editable fields that differ between this ticket and `new`.
    public func changes(to new: Ticket) -> [FieldChange] {
        var result: [FieldChange] = []
        func text(_ field: String, _ old: String, _ new: String) {
            if old != new { result.append(FieldChange(field: field, old: old, new: new)) }
        }
        text("Title", title, new.title)
        text("Description", body, new.body)
        text("Status", status.title, new.status.title)
        text("Priority", priority.title, new.priority.title)
        text("Milestone", milestone?.title ?? "None", new.milestone?.title ?? "None")
        text("Due date", Self.dayText(dueDate), Self.dayText(new.dueDate))
        text("Estimate", Self.minutesText(estimateMinutes), Self.minutesText(new.estimateMinutes))
        if labels != new.labels {
            result.append(FieldChange(field: "Labels", old: Self.listText(labels), new: Self.listText(new.labels), oldList: labels, newList: new.labels))
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ActionLogTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/ActionLog.swift Tests/FocusCoreTests/ActionLogTests.swift
git commit -m "feat: action log value types and ticket diff"
```

---

### Task 2: Store, persistence, queries and pruning

**Files:**
- Modify: `Sources/FocusCore/AppStore.swift` (properties ~line 43-46, `Snapshot` ~1077, `load` ~1096, `save` ~1120)
- Test: `Tests/FocusCoreTests/ActionLogTests.swift`

**Interfaces:**
- Consumes: `ActionLogEntry`, `ActionKind`, `ActionSync` from Task 1.
- Produces on `AppStore`:
  - `public private(set) var actionLog: [ActionLogEntry]` (oldest first)
  - `@discardableResult func record(_ kind: ActionKind, ticket: Ticket? = nil, field: String? = nil, old: String? = nil, new: String? = nil, oldList: [String]? = nil, newList: [String]? = nil, sync: ActionSync = .notApplicable, detail: String? = nil, at date: Date = Date()) -> UUID` — appends; does NOT save (caller saves)
  - `public func setActionSync(_ id: UUID, _ sync: ActionSync, detail: String? = nil)` — updates and saves
  - `public var failedActions: [ActionLogEntry]`
  - `public func deleteActionLog(olderThan cutoff: Date) -> Int` — returns removed count, saves

- [ ] **Step 1: Write the failing tests**

Append inside `ActionLogTests`:

```swift
    func testRecordSnapshotsTicketAndPersists() {
        let (store, url) = makeStore()
        let ticket = Ticket(title: "Fix login", github: GitHubRef(repo: "me/a", number: 7, url: "u"))

        let id = store.record(.ticketEdit, ticket: ticket, field: "Status", old: "Todo", new: "Done", sync: .pending)

        let entry = store.actionLog.first { $0.id == id }!
        XCTAssertEqual(entry.ticketKey, "me/a#7")
        XCTAssertEqual(entry.ticketTitle, "Fix login")
        store.setActionSync(id, .synced(Date()), detail: "PATCH ok")

        let reloaded = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertEqual(reloaded.actionLog.count, 1)
        XCTAssertEqual(reloaded.actionLog[0].githubDetail, "PATCH ok")
        if case .synced = reloaded.actionLog[0].sync {} else { XCTFail("expected synced") }
    }

    func testFileWithoutActionLogLoads() throws {
        let json = #"{"tickets":[],"entries":[]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertTrue(store.actionLog.isEmpty)
    }

    func testFailedActionsAndPruning() {
        let (store, _) = makeStore()
        let old = Date().addingTimeInterval(-61 * 86_400)
        store.record(.note, field: "Note", new: "old", at: old)
        let failed = store.record(.ticketEdit, field: "Labels", sync: .pending)
        store.record(.ticketEdit, field: "Status", sync: .notApplicable)
        store.setActionSync(failed, .failed("403"))

        XCTAssertEqual(store.failedActions.map(\.id), [failed])
        let removed = store.deleteActionLog(olderThan: Date().addingTimeInterval(-60 * 86_400))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.actionLog.count, 2)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ActionLogTests`
Expected: FAIL to compile (`record` not found).

- [ ] **Step 3: Implement**

In `AppStore.swift`, after `public private(set) var dayPlans` add:

```swift
    public private(set) var actionLog: [ActionLogEntry] = []
```

Add a section before `// MARK: - Persistence`:

```swift
    // MARK: - Action log

    @discardableResult
    func record(
        _ kind: ActionKind, ticket: Ticket? = nil, field: String? = nil, old: String? = nil, new: String? = nil,
        oldList: [String]? = nil, newList: [String]? = nil, sync: ActionSync = .notApplicable,
        detail: String? = nil, at date: Date = Date()
    ) -> UUID {
        let entry = ActionLogEntry(
            timestamp: date, kind: kind, ticketID: ticket?.id, ticketKey: ticket?.displayKey, ticketTitle: ticket?.title,
            field: field, oldValue: old, newValue: new, oldList: oldList, newList: newList, sync: sync, githubDetail: detail
        )
        actionLog.append(entry)
        return entry.id
    }

    public func setActionSync(_ id: UUID, _ sync: ActionSync, detail: String? = nil) {
        guard let i = actionLog.firstIndex(where: { $0.id == id }) else { return }
        actionLog[i].sync = sync
        if let detail { actionLog[i].githubDetail = detail }
        save()
    }

    public var failedActions: [ActionLogEntry] {
        actionLog.filter { if case .failed = $0.sync { true } else { false } }
    }

    @discardableResult
    public func deleteActionLog(olderThan cutoff: Date) -> Int {
        let before = actionLog.count
        actionLog.removeAll { $0.timestamp < cutoff }
        save()
        return before - actionLog.count
    }
```

In `Snapshot` add `var actionLog: [ActionLogEntry]?`. In `load()` after `dayPlans = ...` add `actionLog = snapshot.actionLog ?? []`. In `save()` pass `actionLog: actionLog` to the `Snapshot(...)` initializer (last argument).

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ActionLogTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/AppStore.swift Tests/FocusCoreTests/ActionLogTests.swift
git commit -m "feat: persist action log in store with failed/prune helpers"
```

---

### Task 3: Log ticket edits and creation

**Files:**
- Modify: `Sources/FocusCore/AppStore.swift` (`addTicket` ~436, `update` ~443, `addQuickCapture` ~1015, `deleteTicket` ~505)
- Test: `Tests/FocusCoreTests/ActionLogTests.swift`

**Interfaces:**
- Consumes: `Ticket.changes(to:)`, `record`.
- Produces: every `update(_:_:)` call logs one `.ticketEdit` entry per changed field (sync `.notApplicable` here; plan 2 upgrades it to `.pending`/`.synced` for GitHub tickets). `addTicket`/`addQuickCapture` log `.ticketCreate`; `deleteTicket` logs `.ticketDelete` and keeps old entries.

- [ ] **Step 1: Write the failing tests**

```swift
    func testUpdateLogsEachChangedField() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")

        store.update(t.id) { $0.labels = ["bug"]; $0.status = .done }

        let edits = store.actionLog.filter { $0.kind == .ticketEdit && $0.ticketID == t.id }
        XCTAssertEqual(Set(edits.compactMap(\.field)), ["Labels", "Status"])
        let status = edits.first { $0.field == "Status" }!
        XCTAssertEqual(status.oldValue, "Todo")
        XCTAssertEqual(status.newValue, "Done")
    }

    func testNoOpUpdateLogsNothing() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")
        let before = store.actionLog.count
        store.update(t.id) { $0.title = "A" }
        XCTAssertEqual(store.actionLog.count, before)
    }

    func testCreateAndDeleteAreLoggedAndEntriesSurviveDelete() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "Gone soon")
        store.deleteTicket(t.id)

        let kinds = store.actionLog.filter { $0.ticketID == t.id }.map(\.kind)
        XCTAssertEqual(kinds, [.ticketCreate, .ticketDelete])
        XCTAssertEqual(store.actionLog.last?.ticketTitle, "Gone soon")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ActionLogTests`
Expected: FAIL (no entries logged).

- [ ] **Step 3: Implement**

Replace `addTicket`, `update`, and the start of `deleteTicket`:

```swift
    public func addTicket(title: String, priority: Priority = .none) -> Ticket {
        let ticket = Ticket(title: title, priority: priority)
        tickets.append(ticket)
        record(.ticketCreate, ticket: ticket, new: title)
        save()
        return ticket
    }

    public func update(_ id: UUID, _ change: (inout Ticket) -> Void) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        let before = tickets[i]
        change(&tickets[i])
        tickets[i].updatedAt = Date()
        for c in before.changes(to: tickets[i]) {
            record(.ticketEdit, ticket: tickets[i], field: c.field, old: c.old, new: c.new, oldList: c.oldList, newList: c.newList)
        }
        save()
    }
```

In `deleteTicket`, before `tickets.removeAll`:

```swift
        if let ticket = ticket(id) { record(.ticketDelete, ticket: ticket, old: ticket.title) }
```

In `addQuickCapture`, after `tickets.append(ticket)`:

```swift
        record(.ticketCreate, ticket: ticket, new: trimmed)
```

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS (ActivityTests.testManualActivityCountsInTotalsAndLog may fail only within 30 min after local midnight; pre-existing).

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/AppStore.swift Tests/FocusCoreTests/ActionLogTests.swift
git commit -m "feat: log ticket creation, edits and deletion"
```

---

### Task 4: Log timers, time entries, notes, plan comments, day plan, activities

**Files:**
- Modify: `Sources/FocusCore/AppStore.swift` (functions listed below)
- Test: `Tests/FocusCoreTests/ActionLogTests.swift`

**Interfaces:**
- Consumes: `record`.
- Produces entries (`kind`, `field`, `new`/`old`):
  - `start` → `.timer`, "Timer started"
  - `stop` → `.timer`, "Timer stopped", `new` = duration as "N min"
  - `addManualEntry` → `.timeEntry`, "Manual entry added", `new` = "N min"
  - `deleteEntry` → `.timeEntry`, "Entry deleted"
  - `updateEntry` → `.timeEntry`, "Entry edited"
  - `addNote`/`deleteNote` → `.note`, "Note added"/"Note deleted", text in `new`/`old`
  - `addPlanComment`/`deletePlanComment` → `.planComment`, "Plan comment added"/"Plan comment deleted"
  - `togglePlanned` → `.dayPlan`, "Added to day plan"/"Removed from day plan"
  - `deferToTomorrow` → `.dayPlan`, "Deferred to tomorrow"
  - `startActivity`/`stopActivity`/`addActivity`/`deleteActivity` → `.activity`, "Activity started"/"stopped"/"added"/"deleted", title in `new`/`old`

- [ ] **Step 1: Write the failing tests**

```swift
    func testTimerAndTimeEntryActionsAreLogged() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")

        store.start(t.id)
        store.stop()
        store.addManualEntry(ticketID: t.id, duration: 1800)
        let entryID = store.entries.last!.id
        store.deleteEntry(entryID)

        let fields = store.actionLog.filter { $0.ticketID == t.id && ($0.kind == .timer || $0.kind == .timeEntry) }.compactMap(\.field)
        XCTAssertEqual(fields, ["Timer started", "Timer stopped", "Manual entry added", "Entry deleted"])
        XCTAssertEqual(store.actionLog.first { $0.field == "Manual entry added" }?.newValue, "30 min")
    }

    func testNotesPlanCommentsAndDayPlanAreLogged() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")

        store.addNote(ticketID: t.id, text: "remember")
        store.deleteNote(store.notes[0].id)
        store.addPlanComment(ticketID: t.id, text: "do x")
        store.deletePlanComment(store.planComments[0].id)
        store.togglePlanned(t.id, on: Date())
        store.togglePlanned(t.id, on: Date())

        let fields = store.actionLog.filter { [.note, .planComment, .dayPlan].contains($0.kind) }.compactMap(\.field)
        XCTAssertEqual(fields, ["Note added", "Note deleted", "Plan comment added", "Plan comment deleted", "Added to day plan", "Removed from day plan"])
        XCTAssertEqual(store.actionLog.first { $0.field == "Note added" }?.newValue, "remember")
    }

    func testActivityActionsAreLogged() {
        let (store, _) = makeStore()
        store.startActivity(kind: .call, title: "Standup")
        store.stopActivity()
        store.deleteActivity(store.activities[0].id)

        let fields = store.actionLog.filter { $0.kind == .activity }.compactMap(\.field)
        XCTAssertEqual(fields, ["Activity started", "Activity stopped", "Activity deleted"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ActionLogTests`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add a private helper next to `record`:

```swift
    private static func minutesText(_ seconds: TimeInterval) -> String { "\(Int((seconds / 60).rounded())) min" }
```

Edits in `AppStore.swift` (add each call before the final `save()` of the function unless noted):

- `start`: after `entries.append(TimeEntry(ticketID: ticketID, start: started))` add `record(.timer, ticket: tickets[i], field: "Timer started", at: started)`.
- `stop`: after `entries[i].end = max(end, entries[i].start)` add
  ```swift
  record(.timer, ticket: ticket(entries[i].ticketID), field: "Timer stopped", new: Self.minutesText(entries[i].end!.timeIntervalSince(entries[i].start)), at: entries[i].end!)
  ```
- `addManualEntry`: after `entries.append(...)` add `record(.timeEntry, ticket: ticket(ticketID), field: "Manual entry added", new: Self.minutesText(duration))`.
- `deleteEntry`: first line `if let e = entries.first(where: { $0.id == id }) { record(.timeEntry, ticket: ticket(e.ticketID), field: "Entry deleted", old: Self.minutesText((e.end ?? now).timeIntervalSince(e.start))) }`.
- `updateEntry`: after the `guard start < ...` add `record(.timeEntry, ticket: ticket(entries[i].ticketID), field: "Entry edited", old: "\(entries[i].start.formatted()) – \((entries[i].end ?? now).formatted())", new: "\(start.formatted()) – \((newEnd ?? now).formatted())")` (before the assignments).
- `addNote`: after `notes.append(...)` add `record(.note, ticket: ticket(ticketID), field: "Note added", new: trimmed)`.
- `deleteNote`: first line `if let n = notes.first(where: { $0.id == id }) { record(.note, ticket: ticket(n.ticketID), field: "Note deleted", old: n.text) }`.
- `addPlanComment`: after append add `record(.planComment, ticket: ticket(ticketID), field: "Plan comment added", new: trimmed)`.
- `deletePlanComment`: first line `if let c = planComments.first(where: { $0.id == id }) { record(.planComment, ticket: ticket(c.ticketID), field: "Plan comment deleted", old: c.text) }`.
- `togglePlanned`: in the branch that removes from the plan add `record(.dayPlan, ticket: ticket(ticketID), field: "Removed from day plan")`; in the branch appending to an existing plan and in the branch creating a new plan add `record(.dayPlan, ticket: ticket(ticketID), field: "Added to day plan")`.
- `deferToTomorrow`: before `save()` add `record(.dayPlan, ticket: ticket(ticketID), field: "Deferred to tomorrow")`.
- `startActivity`: after `activities.append(...)` add `record(.activity, field: "Activity started", new: activities.last?.title)`.
- `stopActivity`: after setting `end` add `record(.activity, field: "Activity stopped", old: activities[i].title)`.
- `addActivity`: after append add `record(.activity, field: "Activity added", new: activities.last?.title)`.
- `deleteActivity`: first line `if let a = activities.first(where: { $0.id == id }) { record(.activity, field: "Activity deleted", old: a.title) }`.

Note: `start` calls `stop()`/`stopActivity()` first, so switching timers logs the stop of the previous one. That is intended.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusCore/AppStore.swift Tests/FocusCoreTests/ActionLogTests.swift
git commit -m "feat: log timers, entries, notes, plan comments, day plan, activities"
```

---

### Task 5: Record GitHub push results (project fields and posted plan)

**Files:**
- Modify: `Sources/FocusCore/AppStore.swift` (`setProjectField` ~456, `postPlan` ~541, new `@ObservationIgnored private var pendingEntryIDs`)
- Test: `Tests/FocusCoreTests/ActionLogTests.swift`

**Interfaces:**
- Consumes: `record`, `setActionSync`.
- Produces: `setProjectField` writes one `.ticketEdit` entry (field = project field name) with sync `.pending` → `.synced(date)` / `.failed(message)` for GitHub tickets with a token, or `.notApplicable` otherwise. Repeated debounced calls for the same `id|project|name` update the existing pending entry's `newValue` instead of adding entries. `postPlan` writes a `.planComment` entry "Plan posted to GitHub" with the same states.
- Existing behavior kept: a failed project-field write still sets `notice` and calls `refreshTicket` (plan 2 replaces the revert with keep-and-retry).

- [ ] **Step 1: Write the failing tests**

Add a stub transport to the test file (top level, `private`):

```swift
private struct ScriptedTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, String)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (code, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!)
    }
}
```

Tests (adapt the setup helper by creating the store with `transport:` and `tokenProvider: { "t" }`):

```swift
    private func makeStore(status: Int, body: String = "{}") -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(
            storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!,
            transport: ScriptedTransport { _ in (status, body) }, tokenProvider: { "t" }
        )
    }

    func testPostPlanSuccessMarksEntrySynced() async {
        let store = makeStore(status: 201)
        store.insertTicketForTest(Ticket(title: "A", github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        let id = store.tickets[0].id
        store.addPlanComment(ticketID: id, text: "plan")

        let ok = await store.postPlan(id)

        XCTAssertTrue(ok)
        let entry = store.actionLog.last { $0.field == "Plan posted to GitHub" }!
        if case .synced = entry.sync {} else { XCTFail("expected synced, got \(entry.sync)") }
    }

    func testPostPlanFailureMarksEntryFailed() async {
        let store = makeStore(status: 403)
        store.insertTicketForTest(Ticket(title: "A", github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        let id = store.tickets[0].id
        store.addPlanComment(ticketID: id, text: "plan")

        let ok = await store.postPlan(id)

        XCTAssertFalse(ok)
        XCTAssertEqual(store.failedActions.count, 1)
        XCTAssertEqual(store.failedActions[0].field, "Plan posted to GitHub")
    }

    func testProjectFieldPushIsCoalescedAndLogged() async throws {
        let store = makeStore(status: 500)
        let field = CustomField(name: "RCA", value: "old", kind: .text, project: "P")
        store.insertTicketForTest(Ticket(title: "A", fields: [field], github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        let id = store.tickets[0].id

        store.setProjectField(id, name: "RCA", project: "P", to: .text("a"), delay: .milliseconds(200))
        store.setProjectField(id, name: "RCA", project: "P", to: .text("ab"), delay: .milliseconds(200))

        let entries = store.actionLog.filter { $0.field == "RCA" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].oldValue, "old")
        XCTAssertEqual(entries[0].newValue, "ab")
        XCTAssertEqual(entries[0].sync, .pending)
    }
```

`insertTicketForTest` does not exist: add `func insertTicketForTest(_ t: Ticket) { tickets.append(t) }` to `AppStore` as an internal (non-public) method, next to `record`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ActionLogTests`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add property: `@ObservationIgnored private var pendingEntryIDs: [String: UUID] = [:]`.

In `setProjectField`, before the `update(id)` call capture `let oldText = ticket(id)?.fields?.first { $0.project == project && $0.name == name }?.value ?? "None"`. After the `update(id)` call and the `guard let gh = ... else { ... }`, restructure so the entry is recorded in both cases:

```swift
        let canPush = ticket(id)?.github != nil && !(tokenProvider() ?? "").isEmpty
        let key = "\(id)|\(project)|\(name)"
        if canPush, let existing = pendingEntryIDs[key], let i = actionLog.firstIndex(where: { $0.id == existing }), actionLog[i].sync == .pending {
            actionLog[i].newValue = text
            actionLog[i].timestamp = Date()
            save()
        } else {
            let entryID = record(.ticketEdit, ticket: ticket(id), field: name, old: oldText, new: text, sync: canPush ? .pending : .notApplicable)
            if canPush { pendingEntryIDs[key] = entryID }
            save()
        }
        guard canPush, let gh = ticket(id)?.github, let token = tokenProvider() else { return }
```

Remove the old `let key = ...` and the old guard line. Inside the task, track the entry: `let entryID = pendingEntryIDs[key]`. On success after `try await client.updateProjectField(...)`: `if let entryID { setActionSync(entryID, .synced(Date()), detail: "Updated \(name) in project \(project)") }`. In `catch`: `if let entryID { setActionSync(entryID, .failed(error.localizedDescription), detail: "Update \(name) in project \(project) failed") }`. At the end where `pendingPushes[key] = nil` also set `pendingEntryIDs[key] = nil` (only when not cancelled, same condition).

In `postPlan`, after computing `body` and before the `do`, record:

```swift
        let entryID = record(.planComment, ticket: ticket(ticketID), field: "Plan posted to GitHub", new: body, sync: .pending)
        save()
```

On failure (in `catch`, before setting `notice`): `setActionSync(entryID, .failed(error.localizedDescription))`. On success after the `do/catch`: `setActionSync(entryID, .synced(Date()), detail: "Comment posted on \(gh.repo)#\(gh.number)")`.

Also, in the missing-token guard of `postPlan`, leave behavior unchanged (nothing logged).

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Build the app**

Run: `swift build`
Expected: builds (UI is unchanged; `update(_:_:)` signature is unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/FocusCore/AppStore.swift Tests/FocusCoreTests/ActionLogTests.swift
git commit -m "feat: record GitHub push results in the action log"
```

---

## Self-Review

- Spec coverage for this plan: log model (Task 1), persistence/legacy load/prune/failed (Task 2), ticket edits + creation + deletion (Task 3), all other user actions (Task 4), sync badge state transitions for existing GitHub writes (Task 5). Remaining spec items go to plan 2 (GitHub write endpoints, org options, Status/Priority/Target date mapping, keep-on-failure + retry/resync, `unsyncedFields`) and plan 3 (pickers, Action Log page, banner, dashboard card, sidebar badge).
- Names used across tasks: `record`, `setActionSync`, `failedActions`, `deleteActionLog(olderThan:)`, `ActionSync`, `FieldChange`, `Ticket.changes(to:)`, `pendingEntryIDs` — consistent.
