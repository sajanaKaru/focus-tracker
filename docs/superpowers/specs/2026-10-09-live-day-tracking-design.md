# Live Day Tracking — Design

## Goal

Keep the daily plan honest after the morning. Plans drift because estimates are wrong, unplanned work (bugs, requests, interruptions) arrives, and nothing shows the drift until the evening. The app tracks planned vs. unplanned time live, helps the user react, reviews the day, and later learns from the collected data.

## Phases

1. **A1 — Live day**: unplanned detection, quick capture, live capacity, defer, "new since planning".
2. **A2 — End-of-day review**.
3. **B — Learn and adapt**: unplanned buffer and estimate correction. Starts after about 2 weeks of A data.

Each phase gets its own implementation plan. This spec covers all three; B is gated on data volume.

Out of scope: time blocking on a timeline, writing anything back to GitHub, notifications other than the optional wrap-up reminder.

## Definitions

- **Planned ticket (for day D)**: ticket in the `DayPlan` of D.
- **Unplanned time (day D)**: tracked time on tickets not in D's plan, plus ad-hoc `Activity` entries (no `calendarEventID`) in D. Calendar-imported meetings are not unplanned; capacity already subtracts them.
- Unplanned is **derived** from `TimeEntry`, `Activity` and `DayPlan`. It is never stored.
- **Remaining planned work** = sum over planned, not-Done tickets of max(0, estimate − tracked time today and earlier). Estimate = `effectiveEstimateMinutes`, else the default estimate.
- **Remaining today** = capacity − tracked time today − remaining planned work. Negative means overloaded.

## Phase A1 — Live day

### Quick capture
- "Unplanned" button on the Today view and in the menu bar.
- Sheet: type (Bug, Request, Interrupt) and title.
- Creates a local `Ticket` (`isQuickCapture = true`, label equals the type) and starts its timer. Not added to the plan, so its time counts as unplanned.
- It can later be linked to a GitHub issue or stay local.

### Live capacity bar (Plan card)
Shows done planned time, remaining planned work, unplanned time, and remaining today. The bar turns amber when remaining today < 0, with the text "N over. Defer something?".

### Defer
When overloaded, the lowest-ranked planned, not-started tickets show "Move to tomorrow". It unchecks the ticket in today's plan; the existing carry-over logic surfaces it tomorrow.

### New since planning
After a GitHub sync, issues that were not candidates when today's plan was created appear in a "New since planning" strip with "Add to plan" and "Ignore". Ignored ids are kept per day. Work started on such a ticket without adding it counts as unplanned.

## Phase A2 — End-of-day review

- "Wrap up day" button on Today, plus an optional reminder at a configurable time (default off).
- Shows planned done vs. planned total, unplanned items with time, and estimate vs. actual per ticket worked today.
- Per unfinished ticket: Done, Carry to tomorrow, or Drop from plan.
- Where actual differs from the estimate by more than 50%: "Set estimate to actual (1h 40m)".
- Reuses `daySummaryText` / `standupText` for copying the daily report.
- Estimate vs. actual is derived; no new storage.

## Phase B — Learn and adapt

Pure functions in `FocusCore`; each adjustment is shown in the UI and can be switched off in Settings.

1. **Unplanned buffer**: average unplanned share of working time over the last 10 working days. Requires at least 5 days with logged time, else 0. Reserved from capacity; the card says "Reserved 1h 30m for unplanned (10-day average)". Overridable in Settings.
2. **Estimate correction**: median of actual ÷ estimate over finished tickets, grouped by repo (issue type as a fallback), requiring at least 5 samples per group. The plan shows "1h → ~1.6h (adjusted)". Tickets with no estimate use the median actual of similar finished tickets instead of the flat default. Toggle in Settings.

## Data

- `Ticket.isQuickCapture: Bool?` (optional, decoded as false when missing, so existing `data.json` loads).
- `DayPlan.ignoredNewTicketIDs: [UUID]?` (optional, same reason).
- Settings (`PrefKey`): wrap-up reminder time, unplanned buffer mode (auto/manual/off), estimate correction on/off.
- Nothing else is stored.

## Components

- `FocusCore/DayPlanner.swift`: add pure `DayLoad` (planned/unplanned split, remaining work, remaining today, overload, defer candidates), `DayReview` (A2), `UnplannedBuffer` and `EstimateCorrection` (B).
- `FocusCore/Models.swift`: the two optional fields above.
- `FocusCore/AppStore.swift`: `addQuickCapture(type:title:)`, `deferToTomorrow(_:)`, `ignoreNew(_:)`, `newSincePlanning(for:)`.
- `FocusTracker/DayPlanCard.swift`: live bar, defer action, new-since-planning strip.
- `FocusTracker/MenuBarView.swift` and a quick-capture sheet.
- `FocusTracker/TodayView.swift`: wrap-up entry point and review view (A2).
- `FocusTracker/SettingsView.swift`: new settings.

## Error handling

- Calendar access denied: capacity uses logged activities only (existing behavior), and the card keeps its note.
- Too little history for B: buffer is 0 and correction is off, with a note ("needs 5+ days of data").
- A running timer at midnight is split by the existing day-interval clipping.

## Testing

Unit tests first in `Tests/FocusCoreTests`:
- Unplanned derivation: off-plan ticket time, ad-hoc activities counted, calendar-imported ones excluded.
- Remaining-work math: never negative, Done excluded, default estimate used.
- Overload detection and defer candidates.
- Quick-capture creates a ticket outside the plan.
- New-since-planning detection and ignore.
- Backward-compatible decoding of old `data.json`.
- Review: estimate vs. actual deltas.
- B: threshold gating (too few samples gives no adjustment), median math, grouping fallback.

The UI is verified by building and running the app.
