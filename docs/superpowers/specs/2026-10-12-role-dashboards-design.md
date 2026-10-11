# Role Dashboards — Design

Date: 2026-10-12

## Context

Today and the day plan are built for Dev: in-dev tickets, a capacity plan over ranked tickets and a time log. QA and PM land on the same page. Roles (2026-10-11) already control tabs, status order and capture default; this change makes Today a real dashboard per role. Dev is unchanged.

## Goal

- Dev: current Today page, unchanged.
- QA: a testing dashboard with a day plan of tickets to test.
- PM: a delivery dashboard with team-wide data.
- Scope is Today and the day plan only. Reports, the per-ticket Plan page, and sidebar labels are out of scope.

## Decisions

- `TodayView` becomes a switch on `store.role`. The current view is renamed `DevTodayView` with no behaviour change. New `QATodayView` and `PMTodayView` are composed of small cards.
- Every number comes from a pure, tested function in FocusCore. Views only render.
- QA and PM are today-only. There is no day navigator for them (Dev keeps it).
- Tapping a ticket in any card opens the ticket inspector, as in Dev. Cards do not deep-link to other tabs.
- The Unplanned button and sync-issues card stay on all three roles. Quick capture already defaults by role.

## Data layer (FocusCore)

### Assignees and last activity

- `Ticket.assignees: [String]?` (GitHub logins) and `Ticket.remoteUpdatedAt: Date?` (GitHub `updated_at`). Both optional, so existing `data.json` decodes unchanged. Both default to nil in `Ticket.init`.
- `RemoteIssue.assignees: [String]` and `RemoteIssue.updatedAt: Date?`, read from `IssueDTO` (`assignees[].login`, `updated_at`). Both the `/issues?filter=assigned` and `/repos/{repo}/issues` responses contain them.
- `copyContent` copies both from the remote issue on every sync. They are not editable locally and are never pushed.
- `Ticket.updatedAt` is rewritten on every sync, so it cannot show staleness; `remoteUpdatedAt` is used instead. It is empty until the next sync.

### PM team sync

Today the sync fetches only issues assigned to the signed-in user, so a PM would see one person's tickets.

- `GitHubClient.fetchOpenIssues(repos: [String], includePullRequests: Bool)`: for each repo, `GET /repos/{repo}/issues?state=open&per_page=100`, paged with the existing `Link` logic and `maxPages`.
- `AppStore.syncGitHub()` uses it when `role == .pm` and `configuredRepos` is not empty. Otherwise it uses `fetchAssignedIssues` as today, so PM with no repos configured behaves like Dev and the dashboard says so.
- `merge` is unchanged. A ticket missing from the fetch is marked remote-closed and Done, exactly as today. Switching from PM back to Dev therefore returns to the assigned-only set after the next sync, and tickets that come back on a later PM sync are reopened by the existing rule.
- Changing role into or out of PM triggers one `syncGitHub()` (from the existing `onChange(of: store.role)` in `RootView`) when a token exists.

## QA dashboard

All queries are on `AppStore` in `AppStore+QADashboard.swift` and use `workspaceTickets` and the existing `qaQueue`, `qaState`, `testResults`, `testVerdicts` and `bugReports`.

| Card | Source |
|---|---|
| Stat cards: tracked today, cases passed/failed today, tickets verified today | `trackedTime(in:)`; `testResults` with `testedAt` in the day grouped by status; `testVerdicts` with outcome pass in the day |
| Test pipeline | one row per Alpha, Alpha2, Beta from `qaQueue(environment:)`: ready, testing, failed, verified counts. Live row: ticket count from `liveArchive()` |
| Failed & retest | open tickets whose `qaState` for their environment is `.failed`. Shows failed-case count and "Redeployed" when `ticket.deployment.movedAt` is later than the last failed verdict. Redeployed first, then oldest failure |
| Bugs reported | `bugReports` on workspace tickets, newest first (10), with state: Draft, Failed to create, Created (link to the issue). Remote open or closed state is not stored, so none is shown |
| Today's test plan | see below |
| Time log | same list as Dev |

### QA test plan

- Candidates: tickets from the Alpha, Alpha2, Beta and all-environment queues in `ready`, `testing` or `failed`, de-duplicated, not live. Order: failed, testing, ready, then most recently updated.
- Estimate per ticket: 10 minutes per case that is not run, failed or blocked (skipped and passing cases do not count), at least 10 minutes; 30 minutes when the ticket has no cases. Both are named constants in one place.
- Capacity: existing `capacity(for:calendarBusy:)` (working hours, focus factor, calendar and logged activities).
- Plan storage: a separate `qaDayPlans: [DayPlan]` list in the store file, optional on decode. A separate list keeps QA and Dev plans for the same day from mixing when the role is switched.
- Operations mirror Dev's, today only: suggest (greedy by order until capacity is full, always keeps the first), toggle a ticket, planned versus capacity bar. No carry-over ranking and no deferral.
- `QATestPlanCard` shows the capacity bar, a checklist of candidates with the estimate, and a Re-suggest button. It uses the same visual components as `DayPlanCard`.

## PM dashboard

Queries live in `AppStore+PMDashboard.swift`.

| Card | Definition |
|---|---|
| Sprint progress | Scope: workspace tickets in the current sprint, including Done. With no current sprint, the open milestone with the earliest due date. With neither, an empty state. Shows done/total, a status breakdown bar and days left. Issues already closed before the first sync are not in the app, so Done can be undercounted |
| Release pipeline | per environment (Alpha, Alpha2, Beta, Live) the count of workspace tickets with that `environment`. "Ready to promote" is the count with `qaState == .verified` in Alpha, Alpha2 and Beta |
| Blocked & at-risk | open tickets with a reason: Overdue (`DayPlanner.dueDate` before today, or the open milestone's `dueOn` before today), Failed QA, Stale (in flight and `remoteUpdatedAt` more than 3 days ago; skipped when nil). Ordered Overdue, Failed QA, Stale. 3 days is a named constant |
| Workload | open tickets grouped by `assignees` login ("Unassigned" when empty): open count, in-flight count, summed estimate (`effectiveEstimateMinutes`). Sorted by open count; the bar is relative to the largest |
| Incoming requests | open tickets that are Backlog with no sprint, or `isQuickCapture`; 8 most recent by `createdAt`. `createdAt` is the first sync, not the GitHub creation date |
| Stand-up summary | "Copy status summary" builds `SummarySection`s: progress, in flight, at-risk, ready to promote. Plain text and HTML on the pasteboard like `daySummaryText` / `daySummaryHTML` |

When the sync is assigned-only (PM with no repos set), a notice card says team-wide cards need repos in Settings, and Workload shows only the user.

## Views (FocusTracker)

- `TodayView.swift`: thin switch. `DevTodayView.swift`: the current code, renamed.
- New: `QATodayView.swift`, `QATestPlanCard.swift`, `PMTodayView.swift`, `DashboardCards.swift` (progress bar, pipeline row, workload row, ticket-list card).
- Reused: `PageHeader`, `StatCard`, `SectionTitle`, `EmptyHint`, `TicketRow`, `cardStyle`, `SyncIssuesCard`, `QuickCaptureSheet`.
- Page width and padding match Dev (900 pt max, 24 pt).

## Out of scope

- Reports, per-ticket Plan page, sidebar labels, deep links from cards to other tabs.
- Remote open or closed state of bug issues; QA estimates edited by the user.
- Per-person time tracking for PM (only the local user's time is known).
- Changing Dev behaviour.

## Testing

FocusCore tests (`swift test`):

- `Ticket` decodes a JSON without `assignees` or `remoteUpdatedAt`; round-trips with them.
- `IssueDTO` via `GitHubClient` with `RecordingTransport`: assignees and `updated_at` decoded; `fetchOpenIssues` pages and skips pull requests unless included.
- `syncGitHub` as PM with repos set calls `/repos/{repo}/issues`; as Dev or PM without repos calls `/issues?filter=assigned`.
- QA: pipeline counts per environment; passed/failed/verified in a day range; retest list with and without redeployment; bugs list order and state; test plan candidates order, estimates, suggest within capacity, toggle, and separation from `dayPlans`.
- PM: sprint scope with a current sprint, with only a milestone, and with neither; pipeline and ready-to-promote counts; each risk reason and ordering; workload grouping with unassigned tickets; incoming list; summary sections.

Views are verified by `swift build` only. Do not launch `build/FocusTracker.app`: it loads the real `data.json` and token and can write to GitHub.

## Risks

- A whole-repo sync fetches issue and project fields per issue, so large repos make syncs slower. The repos list in Settings bounds it.
- Stale and Workload depend on `remoteUpdatedAt` and `assignees`, which are empty until the first sync after the update.
- QA estimates are a heuristic (10 minutes per case); the plan is a guide, not a commitment.

## Delivery split

1. FocusCore data: assignees, `remoteUpdatedAt`, `fetchOpenIssues`, PM sync scope, role-change sync. Tests.
2. FocusCore QA dashboard and test plan queries. Tests.
3. FocusCore PM dashboard queries and summary. Tests.
4. App: `TodayView` switch and `DevTodayView` rename; `QATodayView` and `QATestPlanCard`; `PMTodayView` and shared cards.
