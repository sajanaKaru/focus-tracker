# Daily Focus Plan — Design

## Goal

Remove the "what should I work on today?" decision and stop overcommitting. The app suggests a ranked set of tickets that fits today's real capacity; the user adjusts it.

## Scope

In: capacity calculation, ranked suggestions, auto-pick within capacity, persisted day plan, carry-over, new settings, Plan card on the Today view.

Out (later): time blocking on a timeline, estimates learned from history, menu bar integration, writing anything back to GitHub.

## Settings

Stored with `@AppStorage` using new `PrefKey` entries.

| Setting | Default |
|---|---|
| Daily working time | 8h |
| Focus factor | 75% |
| Default estimate (ticket has none) | 1h |

## Capacity

- Free time = working time − union of (today's timed calendar events, excluding cancelled and declined ones ∪ logged calls/meetings today). Overlapping intervals count once. Free time never goes below zero.
- Capacity = free time × focus factor.
- Planned = sum of checked tickets' `effectiveEstimateMinutes`, using the default estimate when nil. Tickets using the default are marked "estimated by app".
- Remaining = capacity − planned. Negative remaining shows a warning (amber capacity bar).

## Ranking

Eligible: status is Todo, In Progress or In Review, and not `remoteClosed`. Done and Backlog are excluded.

Signals, highest weight first; the strongest present signal is shown as the reason:

1. Overdue or due today
2. Due within 2 days
3. Current sprint ends within 2 days
4. Carried over (in yesterday's plan, not Done)
5. Already In Progress / In Review
6. Priority (Urgent → Low)

Within the same signal: higher priority first, then oldest `updatedAt`.

Due date = `Ticket.dueDate`, else the GitHub "Target date" issue field. Sprint end = the `end` of a current iteration field.

## Auto-pick

Walk the ranked list and pre-check tickets until the next one would exceed remaining capacity; if even the first does not fit, pre-check just the first. The plan is created once, the first time Today is opened with at least one candidate, and is never rearranged afterwards (syncs only refresh the candidate list). The user can check or uncheck any ticket, or press "Re-suggest" to rebuild the plan.

## Data

`DayPlan { day: Date (start of day), ticketIDs: [UUID] }`, persisted in `data.json` with the existing tickets. Carry-over = tickets in the most recent earlier plan that are not Done.

## Components

- `FocusCore/DayPlanner.swift` (new): pure functions for free time, capacity, ranking, auto-pick.
- `FocusCore/Models.swift`: add `DayPlan`.
- `FocusCore/AppStore.swift`: hold and persist plans.
- `FocusTracker/SettingsView.swift`, `PrefKey`: the three settings.
- `FocusTracker/CalendarService.swift`: add a method returning all of the day's events (current method returns only started events).
- `FocusTracker/TodayView.swift`: Plan card with capacity bar, ranked list with checkboxes, estimate and reason per row.

## Error handling

If calendar access is denied or fails, treat calendar time as zero and show a note on the card. Capacity then uses logged activities only.

## Testing

Unit tests in `Tests/FocusCoreTests` (written first): interval overlap merging, focus factor, default estimate, ranking order and ties, eligibility filtering, carry-over, auto-pick stops at capacity, an existing plan is not rearranged, plans persist across reloads. The UI is verified by building and running the app.
