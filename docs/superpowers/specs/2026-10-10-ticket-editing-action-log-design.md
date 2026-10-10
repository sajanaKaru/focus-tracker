# Ticket Editing, GitHub Write-back and Action Log — Design

Date: 2026-10-10

## Goal

Edit every ticket field in the app (status, priority, labels, milestone, target date, title, body, estimate, RCA), push each edit to GitHub immediately, and keep an action log of everything the user does, with old/new values, a GitHub sync badge, a detail view, and visible failure handling (banner + dashboard card).

## Decisions

- Edits apply locally, then push to GitHub immediately. Failures keep the local value, are marked `failed`, and can be retried.
- Status uses the org/project **Status** single-select options; board columns follow those options. Done also closes the issue.
- Priority is the org issue field **Priority** (replaces the local `Priority` enum). Due date is the org issue field **Target date** (replaces local `dueDate`).
- The log covers all user actions (ticket edits, timer, time entries, notes, plan comments, day plan changes, ticket deletion).
- Log entries are kept forever; the user can delete entries older than 60 days manually.

## Data model

```
ActionLogEntry: Codable, Identifiable
  id: UUID, timestamp: Date
  kind: ticketEdit | timer | timeEntry | note | planComment | dayPlan | ticketDelete | ...
  ticketID: UUID?, ticketKey: String?, ticketTitle: String?   // snapshots
  field: String?
  oldValue: String?, newValue: String?                        // display text
  oldList: [String]?, newList: [String]?                      // structured values (e.g. label arrays)
  sync: notApplicable | pending | synced(Date) | failed(String)
  githubDetail: String?                                       // request summary + result
```

Stored as `actionLog` in `data.json`; files without it load as empty. A ticket-level set of `unsyncedFields` prevents sync from overwriting failed values.

## Components (FocusCore)

- `ActionLog`: append, update sync state, query/filter, delete older than a cutoff.
- `TicketEditor`: capture old value, apply locally, append entry (`pending`), push via `GitHubClient`, mark `synced`/`failed`. Retry one entry or all failed entries.
- `GitHubClient` additions: set labels, set milestone, update title/body/state, set issue field value (Priority, Target date), set project Status; fetch repo labels, repo milestones, field options.
- `OptionsCache`: per-repo labels and milestones; Status/Priority/Target date options. Refreshed on sync and on demand.
- `AppStore.copyContent`/`merge`: skip fields listed in the ticket's `unsyncedFields`.
- Migration: map old `Ticket.priority` to org Priority options by name; fall back to old `dueDate` until Target date exists.

## GitHub mapping

| Field | Target |
|---|---|
| Labels | REST `PUT /repos/{r}/issues/{n}/labels` |
| Milestone | REST `PATCH /repos/{r}/issues/{n}` |
| Title / body | REST `PATCH /repos/{r}/issues/{n}` |
| Status | Project v2 Status single-select (GraphQL, existing `updateProjectField` path); Done also closes the issue |
| Priority | Org issue field Priority |
| Target date | Org issue field Target date |
| Estimate / RCA | Existing project field path |

Local-only tickets log as `notApplicable`.

## UI

- **Banner** (persistent, separate from transient `notice`): "N changes failed to sync to GitHub" with **Resync** and **Dismiss**. Dismiss hides the banner but keeps failed entries; it reappears on a new failure.
- **Today dashboard**: "Sync issues" card listing failed ticket/field/error with per-row Retry and a link to the ticket; stays until resolved.
- **Sidebar**: new Action Log item with a red failure count badge.
- **Action Log page**: filters (ticket, kind, sync state, date); rows show time, ticket, `field: old → new`, badge (Synced / Failed / Pending / none). Click opens a detail sheet (full old/new, labels as added/removed, GitHub request/result, error, Retry). Toolbar action "Delete entries older than 60 days" with confirmation.
- **Ticket detail**: pickers for Status, Priority, Milestone, Target date; label multi-select; title/body editing; a History section.
- Ticket rows and board cards show an "unsynced" marker.

## Testing

Using the mock `HTTPTransport`: entry creation with correct old/new; request construction per field; `pending`→`synced`/`failed`; sync does not overwrite failed fields; retry and resync; priority migration; legacy `data.json` loads; delete-older-than-60-days keeps newer entries.

## Delivery split

1. Log model, `TicketEditor`, tests.
2. GitHub write-back and options loading.
3. UI: pickers, Action Log page, banner, dashboard card.

## Risks

Writing org issue fields and the project Status needs a token with matching write access; failures surface as `failed` entries with GitHub's error text.
