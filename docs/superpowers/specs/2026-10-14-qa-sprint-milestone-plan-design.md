# QA plan: sprint groups and per-milestone plans

Date: 2026-10-14

## Problem

The QA "Test plan" card on the QA Today view builds one flat plan for today from every ticket in Testing or deployed to Alpha, Alpha2 or Beta. It ignores sprint and milestone. When developers finish a sprint (for example Sprint 11) but QA is still testing it, QA cannot see which sprint a ticket belongs to, and cannot plan a release (milestone) as a unit or run several releases side by side.

## Goals

- Show the plan grouped by sprint, with ended-but-still-in-QA sprints visible and first.
- Let QA create a separate plan per GitHub milestone, with its own tickets, target date and progress.
- Keep the daily capacity plan as the single source of "planned today".

## Non-goals

- Splitting daily capacity between milestones.
- Manually building a milestone plan from arbitrary tickets or pulling in tickets from other milestones.
- Writing plan data back to GitHub.
- Changing the QA Queue, Live archive or QA dashboard.

## Data model

New `QAMilestonePlan` (Codable, Identifiable, Hashable, Sendable) in FocusCore:

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | |
| `milestone` | `String` | Milestone title, matched like `liveArchive()` does |
| `targetDate` | `Date?` | Defaults to the milestone's `dueOn` when created |
| `excludedTicketIDs` | `[UUID]` | Tickets QA removed from the plan |
| `archived` | `Bool` | Hidden from the active list |
| `createdAt` | `Date` | |

`AppStore` gains `qaMilestonePlans: [QAMilestonePlan]`, persisted in the snapshot as an optional field (`qaMilestonePlans: [QAMilestonePlan]?`, loaded as `?? []`), the same way `qaDayPlans` is, so existing `data.json` files load unchanged. At most one non-archived plan exists per milestone title.

Nothing else is stored. A plan's tickets, progress and estimate are derived.

## Derivation (`AppStore+QAMilestonePlan.swift`)

- **Plan tickets:** `qaPlanCandidates()` filtered to `ticket.milestone?.title == plan.milestone` and not in `excludedTicketIDs`.
- **Progress:** verified count over total count, using `QAState`; per-state counts (failed, testing, ready, verified). A verified ticket stays in the plan so progress can reach 100%. Because `qaPlanCandidates()` omits verified tickets, the milestone derivation builds its list from the same queues with verified included, and ticks on verified tickets are not offered. Progress counts tickets currently in QA stages; a ticket deployed to Live leaves the plan, so the total shrinks as tickets ship (known limitation).
- **Estimate:** sum of `QAPlanner.estimate` over unverified plan tickets.
- **Sprint of a ticket:** among `ticket.sprints`, the one with the latest `end`; nil when the ticket has none.
- **Sprint groups:** candidates grouped by sprint value, ordered by sprint `end` ascending (oldest first); the no-sprint group is last. A group is "ended" when its `end` is before `now`. Each group carries ticket count and estimate.
- **Plannable milestones:** `milestoneTitles` minus titles that already have an active plan; open milestones first, closed last.
- **Overdue:** `targetDate < now` with unverified tickets remaining.

## Behavior changes to existing logic

- `QAPlanner.autoPick` input order becomes sprint order (oldest sprint first), then the existing failed, testing, ready order within a sprint. Capacity logic is unchanged.
- `toggleQAPlanned` is reused unchanged by both tabs; ticking a ticket in a milestone plan toggles it in today's `DayPlan`.
- Excluding a ticket from a milestone plan does not remove it from today's plan or from the Today tab.

## UI

`QATestPlanCard` becomes the Plan section with a `Today | Milestones` segmented control. The selected tab is view state only.

**Today tab:** the existing capacity bar, warnings and Re-suggest button, then candidates grouped by sprint. Each group header shows the sprint name, an "Ended <date>, still in QA" badge in the warning tint when ended, "current" when current, ticket count and estimate. Ticket rows are unchanged.

**Milestones tab:**
- "Plan a milestone" button opens a picker of plannable milestones; choosing one creates the plan.
- One card per active plan: milestone title, target date with days remaining (red when overdue), progress bar, "N of M verified", remaining estimate, per-state counts, and a "Show tickets" expander.
- Expanded rows use the same planned checkbox as the Today tab and open the ticket detail on click. A row action "Exclude from plan" adds to `excludedTicketIDs`.
- The `...` menu: Edit target date, Show excluded tickets (restore), Archive.
- Empty plan: "Nothing waiting for QA in this milestone" with Archive available.
- Tickets without a milestone never appear in this tab.

## Error handling and edge cases

- A milestone renamed or removed on GitHub leaves a plan with no matching tickets; it shows the empty state and can be archived.
- Creating a plan for a title that already has an active plan is prevented by the picker; the store method is a no-op in that case.
- Excluded ticket IDs that no longer exist are ignored.
- Tickets hidden from the workspace by the role/environment filters are not shown, consistent with `qaPlanCandidates()`.

## Testing

Unit tests in `Tests/FocusCoreTests`:
- Sprint selection (latest end wins), grouping order, ended flag, no-sprint group last.
- Milestone membership with exclusions; progress, per-state counts and estimate including verified tickets.
- Overdue flag.
- Plannable milestones excludes active plans, includes archived ones.
- Snapshot round-trip, and loading a snapshot without `qaMilestonePlans`.
- Toggling a milestone ticket changes today's `DayPlan`.
- `autoPick` ordering across sprints.

UI is verified by reading the SwiftUI code and building; the built app is not launched because it loads the real `data.json` and token.

## Files

- New: `Sources/FocusCore/AppStore+QAMilestonePlan.swift`, `Sources/FocusTracker/QAMilestonePlansView.swift`, tests.
- Changed: `QA.swift` (model), `AppStore.swift` (property and snapshot), `AppStore+QAPlan.swift` (ordering), `QATestPlanCard.swift` (tabs and sprint groups).
