# QA Stage 1 — Design

Date: 2026-10-11

## Context

Sub-project 3 of 3. Licensing and roles/environments are on `main`. QA members test tickets deployed to Alpha, Alpha2 or Beta, record results locally, and share a verdict with Devs and PMs through GitHub. All QA data stays in `data.json`; only verdicts and bug reports are pushed, and only when QA clicks.

## Goal

- A QA queue that shows what is deployed where, with environment chips (Alpha, Alpha2, Beta, Live).
- Test cases per ticket with a result per environment.
- Structured bug reports that become real GitHub issues linked to the ticket under test.
- A Pass or Fail verdict that posts a comment and a label, using the existing edit pipeline.
- Live as an archive of released tickets grouped by milestone.

## Decisions

- Environments are independent. Results, verdicts and labels are keyed per environment; a pass on Beta never counts for Alpha2.
- Nothing is pushed in the background. Each push is an explicit button, goes through `AppStore.edit(...)`, and appears in the Action Log with Pending / Synced / Failed and Retry.
- Test cases and results are local only. The team sees verdicts, labels, bug issues and the comment text.
- Pass leaves the ticket's status alone, since moving to Live is the team's release process. Fail offers "Move back to In Progress" (on by default) using the existing status change.
- Bugs are not added as local tickets. The sync marks any issue not assigned to you as closed, so a created bug would be marked Done on the next sync. A bug is stored as a `BugReport` record with its issue number and link.
- GitHub's REST API has no image upload for issues, so a bug has a "Links / screenshots" text field for URLs instead of attachments.

## Data model (FocusCore, `QA.swift`)

All persisted as optional keys in the `data.json` snapshot, so older files load unchanged.

```
TestCase        id, ticketID, title, steps, expected, createdAt
TestResultStatus  pass | fail | blocked | skipped          (no result = not run)
TestResult      id, caseID, ticketID, environment: DeploymentEnvironment?, status, note, testedAt
TestVerdict     id, ticketID, environment?, outcome: pass | fail, summary, testedAt, tester, build
BugReport       id, ticketID, environment?, title, severity, build, steps, expected, actual,
                links, createdAt, issueNumber?, issueURL?, state: draft | created | failed(String)
```

- The latest `TestResult` per (case, environment) wins.
- `Severity: critical, high, medium, low`.
- A verdict is superseded when any result for the same ticket and environment is recorded after it, so the ticket returns to Testing for a re-test.

### Derived state (pure functions)

`QAState` for a ticket in an environment, in priority order:
1. `noCases` — the ticket has no test cases.
2. `verified` — latest verdict is Pass and nothing newer.
3. `failed` — latest verdict is Fail and nothing newer.
4. `testing` — at least one result, no standing verdict.
5. `ready` — has cases, no results.

`QASummary` counts pass, fail, blocked, skipped and not run for a ticket in an environment.

## Store (AppStore+QA.swift)

- `addTestCase`, `updateTestCase`, `deleteTestCase`
- `setResult(caseID:environment:status:note:)`
- `summary(ticketID:environment:)`, `qaState(ticketID:environment:)`
- `queue(environment:)` → groups Ready, Testing, Failed, Verified; `liveArchive()` → Live tickets grouped by milestone
- `postVerdict(ticketID:environment:outcome:build:returnToInProgress:)`: records a `TestVerdict`, then two edits through `edit(...)`: a comment (new `RemoteEdit.comment(id:body:)`, unique slot so comments never coalesce) and the labels change. A Fail with the toggle on also calls the existing status change.
- `reportBug(...)` saves a draft `BugReport`, then `GitHubClient.createIssue` (new) and stores the number and URL; on failure it keeps the draft with the error. `retryBug(id)`.
- New action kinds: `.testCase` (case added, deleted, result set) and `.bugReport`.
- `tickets` and `save()` access is widened from `private` to internal so the extension file can use them.

### Verdict comment (markdown)

```
**QA result (Beta): PASSED**
Tested by @login on 2026-10-11 — build 1.4.2

| Case | Result | Note |
| ... |

Bugs: #123, #124
```

Fail lists failed and blocked cases first.

### Labels

Verdict labels are `qa:<env>-passed` and `qa:<env>-failed` (for example `qa:alpha2-failed`), or `qa:passed` / `qa:failed` when there is no environment. Posting a verdict removes the other outcome's label for that environment and keeps all other labels. GitHub creates labels that don't yet exist.

## GitHub client additions

- `createIssue(repo:title:body:labels:) -> (number, url)` — `POST /repos/{repo}/issues`. Labels: `bug` only when the repo already has it, otherwise none.
- `RemoteEdit.comment(id:body:)` handled in `apply` with the existing `postComment`.

## Roles

- New `AppSection.qaQueue` ("QA Queue").
- QA sections: Today, QA Queue, Tickets, Board, Reports, Action Log; landing QA Queue.
- PM sections: add QA Queue after Today; landing stays Board.
- Dev: unchanged; QA results are visible in the ticket detail.

## App

- **QA Queue view**: environment chips along the top (All, Alpha, Alpha2, Beta, Live). For Alpha, Alpha2 and Beta, tickets whose environment matches, in groups Ready to test, Testing, Failed, Verified, each row showing the summary ("7/10 passed, 1 failed"). Tickets with no test cases yet are listed under Ready to test so QA can add cases. "All" shows every Testing ticket, including those with no environment. Live shows released tickets grouped by milestone, read-only. The sidebar badge counts Ready to test.
- **Ticket detail**: a QA section for GitHub tickets, shown for every role.
  - Environment picker, defaulting to the ticket's environment.
  - Test case list: title, steps, expected, a result control (Pass, Fail, Blocked, Skip) and a note.
  - Add case form.
  - Pass and Fail buttons that open a confirm sheet with a comment preview, build field and the move-back toggle.
  - Bug list with a Report bug button and a bug sheet (title, severity, environment, build, steps, expected, actual, links).
- **Action Log**: the new kinds show with the existing badges, detail sheet and Retry.

## Out of scope (Stage 2)

Re-test runs per build, regression suites, release sign-off, QA metrics reports, image upload, test case import/export, assigning bugs to developers.

## Testing

Pure logic and store tests, using the existing `RecordingTransport`:

- `QAState` and `QASummary` for each case, including a result newer than a verdict, and results kept separate per environment.
- Queue grouping, environment filtering, and the Live archive grouping by milestone.
- Verdict comment markdown for pass, fail and blocked cases, and the bug list.
- `postVerdict`: comment request body, label request replaces only the same environment's qa label and keeps others, move-back changes status only on Fail with the toggle on, entries logged as pending then synced, and a failure marks the entry failed with a working retry.
- `reportBug`: request body and labels, number and URL stored, failure keeps a draft with the error, retry succeeds.
- Persistence round trip and a legacy file without the new keys.
- Roles: QA and PM sections include the QA Queue; updated `RoleTests`.

## Risks

- Verdict labels create new labels in your repositories the first time they are used.
- The comment and labels need a token with issues write access; the status move needs project write access. Failures show in the Action Log with Retry.
- With no image upload, QA must host screenshots elsewhere and paste links.

## Delivery split

1. FocusCore model and derived state, persistence, tests.
2. Store operations, GitHub client additions, action kinds, tests.
3. Roles update (`AppSection.qaQueue`) and tests.
4. App: QA Queue view and sidebar badge.
5. App: ticket QA section, verdict sheet, bug sheet.
