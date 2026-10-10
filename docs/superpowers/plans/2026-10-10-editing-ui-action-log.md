# Ticket Editing and Action Log UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app its editing UI (status, priority, milestone, target date, labels, title, description), an Action Log page with a detail sheet, a failure banner with Resync/Dismiss, a Today "Sync issues" card, per-ticket sync markers, and a board whose columns follow the org project Status options.

**Architecture:** Testable logic goes into `FocusCore` (`ActionLogFilter`, entry summaries/badges, banner dismissal state, per-ticket sync status, board columns); SwiftUI views in `Sources/FocusTracker` only call it. UI is verified with `swift build` plus the `FocusCore` tests (no UI test target exists).

**Tech Stack:** Swift 5.9, SwiftUI (macOS 14), Observation, XCTest (`swift test`).

**Spec:** `docs/superpowers/specs/2026-10-10-ticket-editing-action-log-design.md`
**Builds on:** `2026-10-10-action-log-core.md` and `2026-10-10-github-writeback-options.md` (both done: `actionLog`, `failedActions`, `retry`, `resyncFailed`, `deleteActionLog(olderThan:)`, `remoteOptions`, typed setters `setStatusOption/setStatus/setPriorityOption/setPriority/setTargetDate/setMilestone/setLabels/setTitle/setBody`, `labelOptions/milestoneOptions/priorityOptions/statusOptions(for:)`, `loadOptions`).

## Global Constraints

- The banner has exactly two actions: **Resync** (retries every failed entry) and **Dismiss** (hides the banner; failed entries stay in the Today card and the log; the banner returns when a new failure appears or a retried entry fails again).
- Entries are kept forever; the only deletion is the explicit "Delete entries older than 60 days" action, behind a confirmation dialog.
- Text fields commit on submit/focus loss (not per keystroke) so the log has one entry per edit.
- Any API used from `Sources/FocusTracker` must be `public` in `FocusCore`.
- Use existing design pieces: `Chip`, `LabelChip`, `FlowLayout`, `cardStyle`, `SectionTitle`, `EmptyHint`, `IconTile`, `confirmDestructive`, `Theme.*`, `.buttonStyle(.secondary)`.
- No emojis in UI text. Shell: `rm` is aliased; use `command rm`.
- Run `swift test` and `swift build` after every task; commit after each.

---

## File Structure

- Create `Sources/FocusCore/ActionLogPresentation.swift`: titles, badges, summaries, `ActionLogFilter`, `TicketSyncStatus`.
- Create `Sources/FocusCore/AppStore+ActionLog.swift`: per-ticket queries, banner count, board columns.
- Modify `Sources/FocusCore/AppStore.swift`: `dismissedFailureIDs`, `dismissFailureBanner`, `retry` un-dismisses, drop the duplicate `notice` on push failure.
- Modify `Sources/FocusCore/AppStore+Editing.swift`: label edits debounce.
- Create `Sources/FocusTracker/SyncViews.swift`: `SyncBadge`, `TicketSyncMarker`, `FailureBanner`, `SyncIssuesCard`.
- Create `Sources/FocusTracker/ActionLogView.swift`: `EntryRef`, `ActionLogView`, `ActionLogRow`, `ActionDetailSheet`.
- Create `Sources/FocusTracker/TicketEditors.swift`: editors used by the detail view.
- Modify `Sources/FocusTracker/{Theme,RootView,TodayView,TicketsView,BoardView,TicketDetailView}.swift`.
- Create tests: `Tests/FocusCoreTests/ActionLogPresentationTests.swift`, `Tests/FocusCoreTests/BoardColumnTests.swift`.

---

### Task 1: Core presentation, filter, banner state, sync status

**Files:**
- Create: `Sources/FocusCore/ActionLogPresentation.swift`, `Sources/FocusCore/AppStore+ActionLog.swift`
- Modify: `Sources/FocusCore/AppStore.swift`
- Test: `Tests/FocusCoreTests/ActionLogPresentationTests.swift`

**Interfaces:**
- Produces:
  - `ActionKind.title: String`
  - `ActionSync.badgeTitle: String?`, `.isFailed: Bool`, `.isPending: Bool`, `.errorMessage: String?`
  - `ActionLogEntry.summary: String`, `ActionLogEntry.labelChanges: (added: [String], removed: [String])?`
  - `enum SyncFilter: String, CaseIterable, Identifiable { all, failed, pending, synced, local }` with `title`
  - `struct ActionLogFilter: Equatable { ticketID, kinds, sync, query, since; init(ticketID:kinds:sync:query:since:); func apply(to:) -> [ActionLogEntry] }` (newest first)
  - `enum TicketSyncStatus { synced, syncing, failed }`
  - `AppStore.actionLog(for:) -> [ActionLogEntry]` (newest first), `failedActions(for:)`, `syncStatus(for:) -> TicketSyncStatus`, `actionLogCount(olderThan:) -> Int`
  - `AppStore.failureBannerCount: Int`, `dismissFailureBanner()`, `dismissedFailureIDs`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/ActionLogPresentationTests.swift`:

```swift
import XCTest
@testable import FocusCore

@MainActor
final class ActionLogPresentationTests: XCTestCase {
    private func makeStore(status: Int = 500) -> (AppStore, UUID) {
        let transport = RecordingTransport { _ in (status, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        store.insertTicketForTest(Ticket(title: "A", labels: ["bug"], github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        return (store, store.tickets[0].id)
    }

    private func failedEntry(_ store: AppStore, _ ticket: UUID, field: String = "Labels") -> UUID {
        let t = store.ticket(ticket)
        let id = store.record(.ticketEdit, ticket: t, field: field, old: "a", new: "b", sync: .pending)
        store.setActionSync(id, .failed("403"))
        return id
    }

    func testSummaryAndBadges() {
        XCTAssertEqual(ActionLogEntry(kind: .ticketEdit, field: "Status", oldValue: "Todo", newValue: "Done").summary, "Status: Todo → Done")
        XCTAssertEqual(ActionLogEntry(kind: .note, field: "Note added", newValue: "hi").summary, "Note added: hi")
        XCTAssertEqual(ActionLogEntry(kind: .note, field: "Note deleted", oldValue: "hi").summary, "Note deleted (hi)")
        XCTAssertEqual(ActionLogEntry(kind: .timer, field: "Timer started").summary, "Timer started")
        XCTAssertEqual(ActionLogEntry(kind: .dayPlan).summary, "Day plan")
        XCTAssertNil(ActionSync.notApplicable.badgeTitle)
        XCTAssertEqual(ActionSync.pending.badgeTitle, "Pending")
        XCTAssertEqual(ActionSync.synced(Date()).badgeTitle, "Synced")
        XCTAssertEqual(ActionSync.failed("x").errorMessage, "x")
        XCTAssertTrue(ActionSync.failed("x").isFailed)
    }

    func testLabelChanges() {
        let entry = ActionLogEntry(kind: .ticketEdit, field: "Labels", oldList: ["bug", "ui"], newList: ["ui", "api"])
        XCTAssertEqual(entry.labelChanges?.added, ["api"])
        XCTAssertEqual(entry.labelChanges?.removed, ["bug"])
        XCTAssertNil(ActionLogEntry(kind: .ticketEdit, field: "Status").labelChanges)
    }

    func testFilterAppliesAllCriteriaNewestFirst() {
        let t1 = UUID(), t2 = UUID()
        let now = Date()
        let a = ActionLogEntry(timestamp: now.addingTimeInterval(-300), kind: .ticketEdit, ticketID: t1, ticketKey: "me/a#1", ticketTitle: "Login bug", field: "Labels", sync: .failed("x"))
        let b = ActionLogEntry(timestamp: now.addingTimeInterval(-200), kind: .note, ticketID: t2, ticketTitle: "Other", field: "Note added", newValue: "hello", sync: .notApplicable)
        let c = ActionLogEntry(timestamp: now.addingTimeInterval(-100), kind: .ticketEdit, ticketID: t1, ticketKey: "me/a#1", field: "Status", sync: .synced(now))
        let all = [a, b, c]

        XCTAssertEqual(ActionLogFilter().apply(to: all).map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(ActionLogFilter(ticketID: t1).apply(to: all).map(\.id), [c.id, a.id])
        XCTAssertEqual(ActionLogFilter(kinds: [.note]).apply(to: all).map(\.id), [b.id])
        XCTAssertEqual(ActionLogFilter(sync: .failed).apply(to: all).map(\.id), [a.id])
        XCTAssertEqual(ActionLogFilter(sync: .synced).apply(to: all).map(\.id), [c.id])
        XCTAssertEqual(ActionLogFilter(sync: .local).apply(to: all).map(\.id), [b.id])
        XCTAssertEqual(ActionLogFilter(query: "LOGIN").apply(to: all).map(\.id), [a.id])
        XCTAssertEqual(ActionLogFilter(query: "hello").apply(to: all).map(\.id), [b.id])
        XCTAssertEqual(ActionLogFilter(since: now.addingTimeInterval(-150)).apply(to: all).map(\.id), [c.id])
    }

    func testPerTicketQueriesAndSyncStatus() {
        let (store, id) = makeStore()
        XCTAssertEqual(store.syncStatus(for: id), .synced)

        let failed = failedEntry(store, id)
        XCTAssertEqual(store.failedActions(for: id).map(\.id), [failed])
        XCTAssertEqual(store.syncStatus(for: id), .failed)
        XCTAssertEqual(store.actionLog(for: id).first?.id, failed)

        store.update(id) { $0.unsynced = nil }
        store.setActionSync(failed, .synced(Date()))
        XCTAssertEqual(store.syncStatus(for: id), .synced)

        store.update(id) { $0.unsynced = ["Title"] }
        XCTAssertEqual(store.syncStatus(for: id), .syncing)
    }

    func testBannerDismissalAndReappearance() async {
        let (store, id) = makeStore()
        let first = failedEntry(store, id)
        XCTAssertEqual(store.failureBannerCount, 1)

        store.dismissFailureBanner()
        XCTAssertEqual(store.failureBannerCount, 0)
        XCTAssertEqual(store.failedActions.count, 1, "dismiss keeps the failed entry")

        _ = failedEntry(store, id, field: "Title")
        XCTAssertEqual(store.failureBannerCount, 1, "a new failure re-shows the banner")

        store.dismissFailureBanner()
        store.edit(id, FieldChange(field: "Labels", old: "a", new: "b"), remote: .labels(["b"])) { $0.labels = ["b"] }
        await store.settlePushes()
        _ = await store.retry(first)
        XCTAssertGreaterThan(store.failureBannerCount, 0, "a retried entry that fails again re-shows the banner")
    }

    func testCountOlderThan() {
        let (store, _) = makeStore()
        store.record(.note, field: "Note added", at: Date().addingTimeInterval(-70 * 86_400))
        store.record(.note, field: "Note added")
        XCTAssertEqual(store.actionLogCount(olderThan: Date().addingTimeInterval(-60 * 86_400)), 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ActionLogPresentationTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

`Sources/FocusCore/ActionLogPresentation.swift`:

```swift
import Foundation

extension ActionKind {
    public var title: String {
        switch self {
        case .ticketCreate: "Ticket created"
        case .ticketEdit: "Ticket edit"
        case .ticketDelete: "Ticket deleted"
        case .timer: "Timer"
        case .timeEntry: "Time entry"
        case .note: "Note"
        case .planComment: "Plan comment"
        case .dayPlan: "Day plan"
        case .activity: "Activity"
        }
    }
}

extension ActionSync {
    public var badgeTitle: String? {
        switch self {
        case .notApplicable: nil
        case .pending: "Pending"
        case .synced: "Synced"
        case .failed: "Failed"
        }
    }

    public var isFailed: Bool { if case .failed = self { true } else { false } }
    public var isPending: Bool { if case .pending = self { true } else { false } }
    public var errorMessage: String? { if case .failed(let message) = self { message } else { nil } }
}

extension ActionLogEntry {
    /// One line describing the action, e.g. "Status: Todo → Done".
    public var summary: String {
        let name = field ?? kind.title
        switch (oldValue, newValue) {
        case (let old?, let new?): return "\(name): \(old) → \(new)"
        case (nil, let new?): return "\(name): \(new)"
        case (let old?, nil): return "\(name) (\(old))"
        case (nil, nil): return name
        }
    }

    public var labelChanges: (added: [String], removed: [String])? {
        guard let oldList, let newList else { return nil }
        return (newList.filter { !oldList.contains($0) }, oldList.filter { !newList.contains($0) })
    }
}

public enum SyncFilter: String, CaseIterable, Identifiable, Sendable {
    case all, failed, pending, synced, local

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .failed: "Failed"
        case .pending: "Pending"
        case .synced: "Synced"
        case .local: "Local only"
        }
    }
}

public struct ActionLogFilter: Equatable, Sendable {
    public var ticketID: UUID?
    /// Empty means every kind.
    public var kinds: Set<ActionKind>
    public var sync: SyncFilter
    public var query: String
    public var since: Date?

    public init(ticketID: UUID? = nil, kinds: Set<ActionKind> = [], sync: SyncFilter = .all, query: String = "", since: Date? = nil) {
        self.ticketID = ticketID
        self.kinds = kinds
        self.sync = sync
        self.query = query
        self.since = since
    }

    /// Matching entries, newest first.
    public func apply(to entries: [ActionLogEntry]) -> [ActionLogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            if let ticketID, entry.ticketID != ticketID { return false }
            if !kinds.isEmpty, !kinds.contains(entry.kind) { return false }
            if let since, entry.timestamp < since { return false }
            switch sync {
            case .all: break
            case .failed: if !entry.sync.isFailed { return false }
            case .pending: if !entry.sync.isPending { return false }
            case .synced: if case .synced = entry.sync {} else { return false }
            case .local: if entry.sync != .notApplicable { return false }
            }
            guard !needle.isEmpty else { return true }
            return [entry.ticketKey, entry.ticketTitle, entry.field, entry.oldValue, entry.newValue]
                .contains { $0?.localizedCaseInsensitiveContains(needle) == true }
        }
        .sorted { $0.timestamp > $1.timestamp }
    }
}

public enum TicketSyncStatus: Equatable, Sendable {
    case synced, syncing, failed
}
```

`Sources/FocusCore/AppStore+ActionLog.swift`:

```swift
import Foundation

extension AppStore {
    public func actionLog(for ticketID: UUID) -> [ActionLogEntry] {
        actionLog.filter { $0.ticketID == ticketID }.sorted { $0.timestamp > $1.timestamp }
    }

    public func failedActions(for ticketID: UUID) -> [ActionLogEntry] {
        failedActions.filter { $0.ticketID == ticketID }
    }

    public func syncStatus(for ticketID: UUID) -> TicketSyncStatus {
        if !failedActions(for: ticketID).isEmpty { return .failed }
        return ticket(ticketID)?.unsynced?.isEmpty == false ? .syncing : .synced
    }

    public func actionLogCount(olderThan cutoff: Date) -> Int {
        actionLog.filter { $0.timestamp < cutoff }.count
    }

    /// Failed entries the user hasn't dismissed from the banner yet.
    public var failureBannerCount: Int {
        failedActions.filter { !dismissedFailureIDs.contains($0.id) }.count
    }
}
```

In `AppStore.swift`: add `public private(set) var dismissedFailureIDs: Set<UUID> = []` next to `actionLog`; next to `failedActions` add

```swift
    public func dismissFailureBanner() {
        dismissedFailureIDs.formUnion(failedActions.map(\.id))
    }
```

and make `retry` start with `dismissedFailureIDs.remove(entryID)` (first statement, before the `guard`). In `push`'s `catch`, delete the line `notice = "Couldn't update \(field) on GitHub (\(error.localizedDescription))."` (the banner and Sync issues card replace it).

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: action log filter, summaries, per-ticket sync status and banner state"
```

---

### Task 2: Board columns from project Status options

**Files:**
- Modify: `Sources/FocusCore/AppStore+ActionLog.swift` (rename not needed; add to a new file) — Create `Sources/FocusCore/AppStore+Board.swift`
- Test: `Tests/FocusCoreTests/BoardColumnTests.swift`

**Interfaces:**
- Produces:
  - `struct BoardColumn: Identifiable, Equatable, Sendable { name: String; status: TicketStatus; color: String?; id: String { name } }`
  - `AppStore.boardColumns: [BoardColumn]` — Status options of the projects used by workspace tickets (projects sorted by title, option order kept, duplicate names merged case-insensitively); the five `TicketStatus` columns when no options are cached
  - `AppStore.column(for: Ticket, in: [BoardColumn]) -> String` (column name)
  - `AppStore.moveTicket(_ id: UUID, toColumn: BoardColumn)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/BoardColumnTests.swift`:

```swift
import XCTest
@testable import FocusCore

@MainActor
final class BoardColumnTests: XCTestCase {
    private func makeStore() -> AppStore {
        let transport = RecordingTransport { _ in (200, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
    }

    private func statusTicket(_ value: String, project: String = "Board", number: Int = 1) -> Ticket {
        Ticket(
            title: "T\(number)",
            fields: [CustomField(name: "Status", value: value, kind: .select, project: project)],
            github: GitHubRef(repo: "me/a", number: number, url: "u")
        )
    }

    func testDefaultsToFiveStatuses() {
        let store = makeStore()
        XCTAssertEqual(store.boardColumns.map(\.name), TicketStatus.allCases.map(\.title))
    }

    func testColumnsFollowProjectOptionsAndMergeProjects() {
        let store = makeStore()
        store.insertTicketForTest(statusTicket("Todo", project: "Board", number: 1))
        store.insertTicketForTest(statusTicket("Review", project: "Ops", number: 2))
        var options = RemoteOptions()
        options.projectStatus["Board"] = [FieldOption(name: "Todo", color: "gray"), FieldOption(name: "In Progress", color: "yellow"), FieldOption(name: "Done", color: "green")]
        options.projectStatus["Ops"] = [FieldOption(name: "todo"), FieldOption(name: "Review")]
        options.projectStatus["Unused"] = [FieldOption(name: "Nope")]
        store.storeOptions(options)

        let columns = store.boardColumns
        XCTAssertEqual(columns.map(\.name), ["Todo", "In Progress", "Done", "Review"])
        XCTAssertEqual(columns.map(\.status), [.todo, .inProgress, .done, .inReview])
        XCTAssertEqual(columns[0].color, "gray")
    }

    func testTicketColumnAndMove() async {
        let store = makeStore()
        store.insertTicketForTest(statusTicket("In Progress"))
        store.insertTicketForTest(Ticket(title: "Local", status: .done))
        var options = RemoteOptions()
        options.projectStatus["Board"] = [FieldOption(name: "Todo"), FieldOption(name: "In Progress"), FieldOption(name: "Done")]
        store.storeOptions(options)
        let columns = store.boardColumns

        XCTAssertEqual(store.column(for: store.tickets[0], in: columns), "In Progress")
        XCTAssertEqual(store.column(for: store.tickets[1], in: columns), "Done")

        let remoteID = store.tickets[0].id
        store.moveTicket(remoteID, toColumn: columns[0])
        await store.settlePushes()
        XCTAssertEqual(store.ticket(remoteID)?.projectStatusField?.value, "Todo")
        XCTAssertEqual(store.ticket(remoteID)?.status, .todo)

        let localID = store.tickets[1].id
        store.moveTicket(localID, toColumn: columns[1])
        XCTAssertEqual(store.ticket(localID)?.status, .inProgress)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BoardColumnTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

`Sources/FocusCore/AppStore+Board.swift`:

```swift
import Foundation

public struct BoardColumn: Identifiable, Equatable, Sendable {
    public var name: String
    public var status: TicketStatus
    public var color: String?
    public var id: String { name }

    public init(name: String, status: TicketStatus, color: String? = nil) {
        self.name = name
        self.status = status
        self.color = color
    }
}

extension AppStore {
    public var boardColumns: [BoardColumn] {
        let projects = Set(workspaceTickets.compactMap { $0.projectStatusField?.project })
        var columns: [BoardColumn] = []
        for project in projects.sorted() {
            for option in remoteOptions.projectStatus[project] ?? [] where !columns.contains(where: { $0.name.caseInsensitiveCompare(option.name) == .orderedSame }) {
                columns.append(BoardColumn(name: option.name, status: TicketStatus(optionName: option.name), color: option.color))
            }
        }
        return columns.isEmpty ? TicketStatus.allCases.map { BoardColumn(name: $0.title, status: $0) } : columns
    }

    /// The column a ticket sits in: its own Status option when it matches, else the first column with its status.
    public func column(for ticket: Ticket, in columns: [BoardColumn]) -> String {
        if let value = ticket.projectStatusField?.value,
           let match = columns.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
            return match.name
        }
        return (columns.first { $0.status == ticket.status } ?? columns.first)?.name ?? ticket.status.title
    }

    public func moveTicket(_ id: UUID, toColumn column: BoardColumn) {
        guard let ticket = ticket(id) else { return }
        if let field = ticket.projectStatusField,
           remoteOptions.projectStatus[field.project]?.contains(where: { $0.name.caseInsensitiveCompare(column.name) == .orderedSame }) == true {
            let option = remoteOptions.projectStatus[field.project]?.first { $0.name.caseInsensitiveCompare(column.name) == .orderedSame }?.name ?? column.name
            setStatusOption(id, project: field.project, option: option)
        } else {
            setStatus(id, column.status)
        }
        if column.status == .done && isTracking(id) { stop() }
    }
}
```

(`setStatus` already stops the timer for Done; the extra `stop()` covers the project-option path.)

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: board columns follow project Status options"
```

---

### Task 3: Sync views, failure banner, Today card, markers

**Files:**
- Create: `Sources/FocusTracker/SyncViews.swift`
- Modify: `Sources/FocusTracker/Theme.swift` (kind symbols/tints), `RootView.swift` (banner), `TodayView.swift` (card), `TicketsView.swift` (marker)
- Test: build only.

**Interfaces:**
- Consumes: Task 1 APIs.
- Produces: `SyncBadge(sync:)`, `TicketSyncMarker(ticketID:)`, `FailureBanner()`, `SyncIssuesCard(selectedTicketID:)`, `ActionKind.symbol`/`.tint`.

- [ ] **Step 1: Implement**

Append to `Theme.swift`:

```swift
extension ActionKind {
    var symbol: String {
        switch self {
        case .ticketCreate: "plus.circle.fill"
        case .ticketEdit: "pencil.circle.fill"
        case .ticketDelete: "trash.circle.fill"
        case .timer: "timer"
        case .timeEntry: "clock.fill"
        case .note: "note.text"
        case .planComment: "text.bubble.fill"
        case .dayPlan: "calendar"
        case .activity: "phone.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ticketCreate: Theme.success
        case .ticketEdit: Theme.accent
        case .ticketDelete: Theme.danger
        case .timer, .timeEntry: Theme.warning
        case .note, .planComment: Theme.info
        case .dayPlan: Theme.teal
        case .activity: Theme.accentEnd
        }
    }
}
```

Create `Sources/FocusTracker/SyncViews.swift`:

```swift
import FocusCore
import SwiftUI

struct SyncBadge: View {
    let sync: ActionSync

    var body: some View {
        switch sync {
        case .notApplicable: EmptyView()
        case .pending: Chip(text: "Pending", color: Theme.warning, symbol: "arrow.triangle.2.circlepath")
        case .synced: Chip(text: "Synced", color: Theme.success, symbol: "checkmark.circle.fill")
        case .failed: Chip(text: "Failed", color: Theme.danger, symbol: "exclamationmark.triangle.fill")
        }
    }
}

/// Shows on a ticket whose last change hasn't reached GitHub yet.
struct TicketSyncMarker: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID

    var body: some View {
        switch store.syncStatus(for: ticketID) {
        case .synced: EmptyView()
        case .syncing: Chip(text: "Syncing", color: Theme.warning, symbol: "arrow.triangle.2.circlepath")
        case .failed: Chip(text: "Not synced", color: Theme.danger, symbol: "exclamationmark.triangle.fill")
        }
    }
}

struct FailureBanner: View {
    @Environment(AppStore.self) private var store
    @State private var resyncing = false

    var body: some View {
        let count = store.failureBannerCount
        if count > 0 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text(count == 1 ? "1 change failed to sync to GitHub" : "\(count) changes failed to sync to GitHub")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    resyncing = true
                    Task {
                        await store.resyncFailed()
                        resyncing = false
                    }
                } label: {
                    if resyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Resync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.secondary)
                .disabled(resyncing)
                Button("Dismiss") { store.dismissFailureBanner() }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.danger.opacity(0.12))
        }
    }
}

/// Today-page list of every change that failed to reach GitHub, with per-row Retry.
struct SyncIssuesCard: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var retrying: Set<UUID> = []
    @State private var resyncingAll = false

    var body: some View {
        let failed = store.failedActions
        if !failed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "Sync issues", count: failed.count)
                    Spacer()
                    Button {
                        resyncingAll = true
                        Task {
                            await store.resyncFailed()
                            resyncingAll = false
                        }
                    } label: {
                        if resyncingAll { ProgressView().controlSize(.small) } else { Label("Resync all", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .buttonStyle(.secondary)
                    .disabled(resyncingAll)
                }
                VStack(spacing: 0) {
                    ForEach(Array(failed.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        row(entry)
                    }
                }
                .cardStyle(padding: 0)
            }
        }
    }

    private func row(_ entry: ActionLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.ticketTitle ?? entry.ticketKey ?? "Ticket").font(.body.weight(.medium)).lineLimit(1)
                Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let message = entry.sync.errorMessage {
                    Text(message).font(.caption).foregroundStyle(Theme.danger).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if let id = entry.ticketID, store.ticket(id) != nil {
                Button("Open") { selectedTicketID = id }.buttonStyle(.borderless)
            }
            Button {
                retrying.insert(entry.id)
                Task {
                    await store.retry(entry.id)
                    retrying.remove(entry.id)
                }
            } label: {
                if retrying.contains(entry.id) { ProgressView().controlSize(.small) } else { Text("Retry") }
            }
            .buttonStyle(.secondary)
            .disabled(retrying.contains(entry.id))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
```

`RootView.swift` detail column: put `FailureBanner()` directly above `NoticeBanner()`:

```swift
            VStack(spacing: 0) {
                FailureBanner()
                NoticeBanner()
                ActiveTimerBar()
                content
            }
```

`TodayView.swift`: directly after the header `HStack` that contains `PageHeader`/`AddToTodayMenu` (before the day-navigator `HStack`), insert `SyncIssuesCard(selectedTicketID: $selectedTicketID)`.

`TicketsView.swift` `TicketRow`: after `LabelChips(ticket: ticket, limit: 3)` add `TicketSyncMarker(ticketID: ticket.id)`.

- [ ] **Step 2: Build and test**

Run: `swift build` then `swift test`
Expected: both succeed.

- [ ] **Step 3: Commit**

```bash
git add -A Sources
git commit -m "feat: failure banner, Sync issues card and ticket sync markers"
```

---

### Task 4: Action Log page, detail sheet, sidebar item

**Files:**
- Create: `Sources/FocusTracker/ActionLogView.swift`
- Modify: `Sources/FocusTracker/RootView.swift`
- Test: build only.

**Interfaces:**
- Consumes: `ActionLogFilter`, `SyncBadge`, `ActionKind.symbol/tint`, `store.actionLogCount`, `store.deleteActionLog`, `store.retry`.
- Produces: `EntryRef`, `ActionLogView(selectedTicketID:filter:)`, `ActionLogRow(entry:)`, `ActionDetailSheet(entryID:openTicket:)`, `SidebarItem.actionLog`.

- [ ] **Step 1: Implement**

Create `Sources/FocusTracker/ActionLogView.swift`:

```swift
import FocusCore
import SwiftUI

struct EntryRef: Identifiable {
    let id: UUID
}

struct ActionLogView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @Binding var filter: ActionLogFilter
    @State private var opened: EntryRef?
    @State private var confirmingPrune = false

    private static let pruneDays = 60

    private var cutoff: Date {
        Calendar.current.date(byAdding: .day, value: -Self.pruneDays, to: store.now) ?? .distantPast
    }

    private var kindBinding: Binding<ActionKind?> {
        Binding(get: { filter.kinds.first }, set: { filter.kinds = $0.map { [$0] } ?? [] })
    }

    var body: some View {
        let entries = filter.apply(to: store.actionLog)
        let oldCount = store.actionLogCount(olderThan: cutoff)

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    PageHeader(title: "Action Log", subtitle: "Everything you change in the app, with what it was before.")
                    Spacer()
                    Button { confirmingPrune = true } label: { Label("Delete older than \(Self.pruneDays) days", systemImage: "trash") }
                        .buttonStyle(.secondary)
                        .disabled(oldCount == 0)
                        .help(oldCount == 0 ? "No entries are older than \(Self.pruneDays) days" : "Delete \(oldCount) old entries")
                }
                filters
            }
            .padding(20)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("No actions found", systemImage: "list.clipboard", description: Text("Changes you make in the app show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    Button { opened = EntryRef(id: entry.id) } label: { ActionLogRow(entry: entry) }
                        .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .background(Theme.pageBackground)
        .sheet(item: $opened) { ref in
            ActionDetailSheet(entryID: ref.id) { selectedTicketID = $0 }
        }
        .confirmDestructive(
            $confirmingPrune,
            title: "Delete \(oldCount) entries older than \(Self.pruneDays) days?",
            message: "Newer entries are kept. This can't be undone.",
            confirmLabel: "Delete"
        ) { store.deleteActionLog(olderThan: cutoff) }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            TextField("Search ticket, field or value", text: $filter.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Picker("Type", selection: kindBinding) {
                Text("All types").tag(ActionKind?.none)
                ForEach(ActionKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(width: 150)
            Picker("Sync", selection: $filter.sync) {
                ForEach(SyncFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            if let id = filter.ticketID {
                let label = store.ticket(id)?.displayKey ?? store.actionLog.last { $0.ticketID == id }?.ticketKey ?? "Ticket"
                Button { filter.ticketID = nil } label: { Label(label, systemImage: "xmark.circle.fill") }
                    .buttonStyle(.secondary)
                    .help("Show all tickets")
            }
            Spacer()
        }
    }
}

struct ActionLogRow: View {
    let entry: ActionLogEntry

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: entry.kind.symbol, tint: entry.kind.tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.summary).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if let key = entry.ticketKey { Text(key).font(.caption).foregroundStyle(.secondary) }
                    if let title = entry.ticketTitle { Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            SyncBadge(sync: entry.sync)
            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ActionDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entryID: UUID
    var openTicket: (UUID) -> Void
    @State private var retrying = false

    var body: some View {
        if let entry = store.actionLog.first(where: { $0.id == entryID }) {
            VStack(spacing: 0) {
                HStack {
                    IconTile(symbol: entry.kind.symbol, tint: entry.kind.tint, size: 32)
                    Text(entry.kind.title).font(.title3.weight(.semibold))
                    SyncBadge(sync: entry.sync)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(16)
                Divider()
                Form {
                    Section("Action") {
                        LabeledContent("When", value: entry.timestamp.formatted(date: .complete, time: .standard))
                        if let field = entry.field { LabeledContent("What", value: field) }
                        if let key = entry.ticketKey {
                            LabeledContent("Ticket") {
                                if let id = entry.ticketID, store.ticket(id) != nil {
                                    Button("\(key) · \(entry.ticketTitle ?? "")") {
                                        openTicket(id)
                                        dismiss()
                                    }
                                    .buttonStyle(.link)
                                } else {
                                    Text("\(key) · \(entry.ticketTitle ?? "") (deleted)").foregroundStyle(.secondary)
                                }
                            }
                        } else if let title = entry.ticketTitle {
                            LabeledContent("Ticket", value: title)
                        }
                    }
                    if entry.oldValue != nil || entry.newValue != nil {
                        Section("Change") {
                            HStack(alignment: .top, spacing: 12) {
                                valueBox("Before", entry.oldValue)
                                valueBox("After", entry.newValue)
                            }
                            if let changes = entry.labelChanges, !(changes.added.isEmpty && changes.removed.isEmpty) {
                                FlowLayout {
                                    ForEach(changes.added, id: \.self) { Chip(text: "+ \($0)", color: Theme.success) }
                                    ForEach(changes.removed, id: \.self) { Chip(text: "− \($0)", color: Theme.danger) }
                                }
                            }
                        }
                    }
                    if entry.sync != .notApplicable || entry.githubDetail != nil {
                        Section("GitHub") {
                            LabeledContent("Status") { SyncBadge(sync: entry.sync) }
                            if case .synced(let date) = entry.sync {
                                LabeledContent("Synced at", value: date.formatted(date: .abbreviated, time: .standard))
                            }
                            if let detail = entry.githubDetail {
                                LabeledContent("Request") { Text(detail).multilineTextAlignment(.trailing).textSelection(.enabled) }
                            }
                            if let message = entry.sync.errorMessage {
                                LabeledContent("Error") {
                                    Text(message).foregroundStyle(Theme.danger).multilineTextAlignment(.trailing).textSelection(.enabled)
                                }
                            }
                            if entry.sync.isFailed {
                                Button {
                                    retrying = true
                                    Task {
                                        await store.retry(entry.id)
                                        retrying = false
                                    }
                                } label: {
                                    if retrying { ProgressView().controlSize(.small) } else { Label("Retry", systemImage: "arrow.clockwise") }
                                }
                                .disabled(retrying || entry.remote == nil)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(width: 560, height: 520)
        } else {
            ContentUnavailableView("Entry not found", systemImage: "questionmark.circle").frame(width: 360, height: 200)
        }
    }

    private func valueBox(_ title: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text ?? "None")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }
}
```

`RootView.swift`:
- `SidebarItem`: add `case actionLog = "Action Log"` after `.reports`, symbol `"list.clipboard"`.
- `SidebarRow`: add `var badgeAlert = false`; in the badge capsule use `badgeAlert ? Theme.danger : (selected ? Theme.accent : Color.secondary)` for the text and `badgeAlert ? Theme.danger.opacity(0.15) : (selected ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.07))` for the background.
- `RootView`: add `@State private var logFilter = ActionLogFilter()`; sidebar rows pass `badgeAlert: item == .actionLog`; `badge(for:)` gets `case .actionLog: store.failedActions.count`; `sidebarContent` gets `case .actionLog: ActionLogView(selectedTicketID: $selectedTicketID, filter: $logFilter)`; the inspector's `TicketDetailView` gets `onShowLog: { logFilter = ActionLogFilter(ticketID: id); selection = .actionLog }` (parameter added in Task 5; until then omit this argument).

- [ ] **Step 2: Build and test**

Run: `swift build` then `swift test`
Expected: both succeed.

- [ ] **Step 3: Commit**

```bash
git add -A Sources
git commit -m "feat: Action Log page, detail sheet and sidebar item with failure badge"
```

---

### Task 5: Ticket editing UI

**Files:**
- Create: `Sources/FocusTracker/TicketEditors.swift`
- Modify: `Sources/FocusTracker/TicketDetailView.swift`, `Sources/FocusCore/AppStore+Editing.swift`, `Sources/FocusTracker/RootView.swift`
- Test: build + existing tests (core debounce change is covered by `TicketEditingTests`).

**Interfaces:**
- Consumes: typed setters, option accessors, `loadOptions`, `ActionDetailSheet`, `EntryRef`, `TicketSyncMarker`.
- Produces: `StatusEditor`, `PriorityEditor`, `MilestoneEditor`, `TargetDateEditor`, `LabelsEditor`, `TitleEditor`, `DescriptionSection`, `TicketHistorySection`; `TicketDetailView(ticketID:onPlan:onShowLog:)`.

- [ ] **Step 1: Implement**

`AppStore+Editing.swift` `setLabels`: add `delay: .milliseconds(800)` to its `edit(...)` call so quick toggles collapse into one entry and one request.

Create `Sources/FocusTracker/TicketEditors.swift`:

```swift
import FocusCore
import SwiftUI

struct StatusEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        let options = store.statusOptions(for: ticket)
        if let field = ticket.projectStatusField, !options.isEmpty {
            Picker("Status", selection: Binding(
                get: { field.value },
                set: { store.setStatusOption(ticket.id, project: field.project, option: $0) }
            )) {
                if !options.contains(where: { $0.name == field.value }) { Text(field.value).tag(field.value) }
                ForEach(options, id: \.name) { Text($0.name).tag($0.name) }
            }
        } else {
            Picker("Status", selection: Binding(get: { ticket.status }, set: { store.setStatus(ticket.id, $0) })) {
                ForEach(TicketStatus.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

struct PriorityEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        let options = store.priorityOptions(for: ticket)
        if ticket.github != nil, !options.isEmpty {
            let current = ticket.field(named: "Priority")?.value ?? ""
            Picker("Priority", selection: Binding(
                get: { current },
                set: { store.setPriorityOption(ticket.id, option: $0.isEmpty ? nil : $0) }
            )) {
                Text("None").tag("")
                if !current.isEmpty, !options.contains(where: { $0.name == current }) { Text(current).tag(current) }
                ForEach(options, id: \.name) { Text($0.name).tag($0.name) }
            }
        } else {
            Picker("Priority", selection: Binding(get: { ticket.priority }, set: { store.setPriority(ticket.id, $0) })) {
                ForEach(Priority.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

struct MilestoneEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        if ticket.github != nil {
            let options = store.milestoneOptions(for: ticket)
            let current = ticket.milestone?.title ?? ""
            Picker("Milestone", selection: Binding(
                get: { current },
                set: { title in
                    if title.isEmpty {
                        store.setMilestone(ticket.id, nil)
                    } else if let option = options.first(where: { $0.title == title }) {
                        store.setMilestone(ticket.id, option)
                    }
                }
            )) {
                Text("None").tag("")
                if !current.isEmpty, !options.contains(where: { $0.title == current }) { Text(current).tag(current) }
                ForEach(options, id: \.title) { Text($0.isOpen ? $0.title : "\($0.title) (closed)").tag($0.title) }
            }
        }
    }
}

struct TargetDateEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        let label = ticket.github != nil ? "Target date" : "Due date"
        Toggle(label, isOn: Binding(
            get: { ticket.dueDate != nil },
            set: { store.setTargetDate(ticket.id, $0 ? Date() : nil) }
        ))
        if let due = ticket.dueDate {
            DatePicker("Date", selection: Binding(get: { due }, set: { store.setTargetDate(ticket.id, $0) }), displayedComponents: .date)
        }
    }
}

struct LabelsEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket
    @State private var showing = false

    var body: some View {
        LabeledContent("Labels") {
            HStack(alignment: .top) {
                FlowLayout { LabelChips(ticket: ticket, limit: 30) }
                Button { showing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit labels")
                    .popover(isPresented: $showing, arrowEdge: .bottom) { LabelPicker(ticketID: ticket.id) }
            }
        }
    }
}

private struct LabelPicker: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    @State private var search = ""
    @State private var newLabel = ""

    var body: some View {
        if let ticket = store.ticket(ticketID) {
            let options = store.labelOptions(for: ticket)
            let names = options.map(\.name) + ticket.labels.filter { label in !options.contains { $0.name == label } }
            let shown = search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(search) }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter labels", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shown, id: \.self) { name in
                            Toggle(isOn: Binding(
                                get: { ticket.labels.contains(name) },
                                set: { on in
                                    var labels = store.ticket(ticketID)?.labels ?? []
                                    if on, !labels.contains(name) { labels.append(name) }
                                    if !on { labels.removeAll { $0 == name } }
                                    store.setLabels(ticketID, labels)
                                }
                            )) {
                                LabelChip(name: name, hex: ticket.labelColors?[name] ?? options.first { $0.name == name }?.color)
                            }
                            .toggleStyle(.checkbox)
                        }
                        if shown.isEmpty { Text("No labels").foregroundStyle(.secondary) }
                    }
                }
                .frame(maxHeight: 260)
                if ticket.github == nil {
                    HStack {
                        TextField("New label", text: $newLabel).textFieldStyle(.roundedBorder).onSubmit(add)
                        Button("Add", action: add).disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else if options.isEmpty {
                    Text("Labels load after the next GitHub sync.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 280)
        }
    }

    private func add() {
        let name = newLabel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, var labels = store.ticket(ticketID)?.labels, !labels.contains(name) else { return }
        labels.append(name)
        store.setLabels(ticketID, labels)
        newLabel = ""
    }
}

/// Commits on Return or when the field loses focus, so one edit is one log entry.
struct TitleEditor: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket
    @State private var draft: String
    @FocusState private var focused: Bool

    init(ticket: Ticket) {
        self.ticket = ticket
        _draft = State(initialValue: ticket.title)
    }

    var body: some View {
        TextField("Title", text: $draft)
            .font(.title3.weight(.semibold))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: ticket.title) { _, new in if !focused { draft = new } }
    }

    private func commit() {
        store.setTitle(ticket.id, draft)
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = ticket.title }
    }
}

struct DescriptionSection: View {
    let ticket: Ticket
    @State private var editing = false

    var body: some View {
        Section {
            if ticket.body.isEmpty {
                Text("No description").foregroundStyle(.secondary)
            } else {
                DescriptionView(markdown: ticket.body)
            }
            Button { editing = true } label: { Label("Edit description", systemImage: "pencil") }
        } header: {
            Text("Description")
        }
        .sheet(isPresented: $editing) { EditDescriptionSheet(ticketID: ticket.id, initial: ticket.body) }
    }
}

private struct EditDescriptionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ticketID: UUID
    @State private var draft: String

    init(ticketID: UUID, initial: String) {
        self.ticketID = ticketID
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit description").font(.title3.weight(.semibold))
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.setBody(ticketID, draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft == store.ticket(ticketID)?.body)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct TicketHistorySection: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    var showAll: () -> Void
    @State private var opened: EntryRef?

    var body: some View {
        let entries = store.actionLog(for: ticketID)
        if !entries.isEmpty {
            Section("History") {
                ForEach(entries.prefix(6)) { entry in
                    Button { opened = EntryRef(id: entry.id) } label: {
                        HStack(spacing: 8) {
                            Text(entry.summary).lineLimit(1)
                            Spacer(minLength: 6)
                            SyncBadge(sync: entry.sync)
                            Text(entry.timestamp, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if entries.count > 6 {
                    Button("Show all \(entries.count) in Action Log", action: showAll)
                }
            }
            .sheet(item: $opened) { ref in ActionDetailSheet(entryID: ref.id) { _ in } }
        }
    }
}
```

`TicketDetailView.swift` changes:
- Add `var onShowLog: () -> Void = {}`.
- Header section: replace the `if isRemote { Text(ticket.title)... } else { TextField(...) }` block with `TitleEditor(ticket: ticket).id(ticketID)`; after `LabelChips(ticket: ticket, limit: 8)` add `TicketSyncMarker(ticketID: ticketID)`.
- Replace everything inside `Section("Details") { ... }` up to (not including) the `Stepper(` with:
  ```swift
  StatusEditor(ticket: ticket)
  PriorityEditor(ticket: ticket)
  MilestoneEditor(ticket: ticket)
  TargetDateEditor(ticket: ticket)
  LabelsEditor(ticket: ticket)
  ```
  keep the estimate `Stepper` and its caption.
- After the `Details` section add `DescriptionSection(ticket: ticket)`.
- Replace `if ticket.milestone != nil || !ticket.allFields.isEmpty { GitHubFieldsSection(...) }` unchanged, then after the "Time log" section add `TicketHistorySection(ticketID: ticketID, showAll: onShowLog)`.
- `.task(id: ticketID) { await store.refreshTicket(ticketID); await store.loadOptions() }`.
- Delete the now-unused private `field(_:)` helper if nothing references it.

`RootView.swift` inspector: `TicketDetailView(ticketID: id, onPlan: { planTicketID = id }, onShowLog: { logFilter = ActionLogFilter(ticketID: id); selection = .actionLog })`.

- [ ] **Step 2: Build and test**

Run: `swift build` then `swift test`
Expected: both succeed.

- [ ] **Step 3: Commit**

```bash
git add -A Sources
git commit -m "feat: ticket editing UI for status, priority, milestone, target date, labels, title, description"
```

---

### Task 6: Board columns UI, unsynced marker, options loading, app build

**Files:**
- Modify: `Sources/FocusTracker/BoardView.swift`
- Test: build, full tests, `./scripts/build-app.sh`.

**Interfaces:**
- Consumes: `store.boardColumns`, `store.column(for:in:)`, `store.moveTicket`, `GitHubColor.color`, `TicketSyncMarker`.

- [ ] **Step 1: Implement**

Rewrite `BoardView` to use columns:

```swift
struct BoardView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    var filter = TicketFilter()
    @State private var targetedColumn: String?

    var body: some View {
        let columns = store.boardColumns
        let tickets = store.tickets(matching: filter)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(columns) { column in
                    columnView(column, tickets: tickets.filter { store.column(for: $0, in: columns) == column.name })
                }
            }
            .padding(20)
        }
        .background(Theme.pageBackground)
        .task { await store.loadOptions() }
    }

    private func columnView(_ column: BoardColumn, tickets: [Ticket]) -> some View {
        let items = tickets.sorted { $0.updatedAt > $1.updatedAt }
        let tint = GitHubColor.color(column.color) ?? column.status.color
        let targeted = targetedColumn == column.name
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 9, height: 9)
                Text(column.name).font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { card($0) }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? tint.opacity(0.14) : tint.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(targeted ? tint.opacity(0.6) : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            for raw in ids {
                if let id = UUID(uuidString: raw) { store.moveTicket(id, toColumn: column) }
            }
            return !ids.isEmpty
        } isTargeted: { targetedColumn = $0 ? column.name : (targetedColumn == column.name ? nil : targetedColumn) }
    }
```

keep `card(_:)` as is, except add `TicketSyncMarker(ticketID: ticket.id)` inside the `FlowLayout` after `LabelChips` and widen its condition so the card shows the chips row when `store.syncStatus(for: ticket.id) != .synced` too.

- [ ] **Step 2: Full verification**

Run: `swift test` — expected all pass.
Run: `swift build` — expected success.
Run: `./scripts/build-app.sh` — expected exit 0 (rebuilds `build/FocusTracker.app`).

- [ ] **Step 3: Commit**

```bash
git add -A Sources
git commit -m "feat: board columns follow project statuses; sync marker on cards"
```

---

## Self-Review

- Spec coverage: banner with Resync/Dismiss, dashboard "Sync issues" card, sidebar failure badge (Tasks 3–4); Action Log page with filters, sync badge, detail sheet with old/new, label add/remove, GitHub request/result/error and Retry, 60-day delete (Task 4); ticket History section (Task 5); pickers for status/priority/milestone/target date/labels, title and description editing (Task 5); unsynced marker on rows/cards (Tasks 3, 6); board columns from org project Status (Tasks 2, 6).
- Not verifiable here: visual layout (no UI tests). The user should look at the app after the build.
- Names used across tasks: `ActionLogFilter`, `SyncFilter`, `TicketSyncStatus`, `failureBannerCount`, `dismissFailureBanner`, `actionLog(for:)`, `syncStatus(for:)`, `actionLogCount(olderThan:)`, `BoardColumn`, `boardColumns`, `column(for:in:)`, `moveTicket(_:toColumn:)`, `EntryRef`, `SyncBadge`, `TicketSyncMarker` — consistent.
