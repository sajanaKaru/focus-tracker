# My Pull Requests Tab — Design

## Goal

See the open pull requests I authored in one place, grouped by what needs my attention, without opening GitHub. Read-only.

## Scope

In: a "Pull Requests" sidebar tab, one GraphQL query, review/CI/conflict chips, grouping, repo filter from Settings, refresh.

Out (later): PRs where I am asked to review, merge or re-request-review actions, linking a PR to its ticket, notifications, more than 100 PRs.

## Data

`FocusCore/PullRequests.swift` (new):

- `PullRequestItem`: `id` (`repo#number` lowercased), `repo` (`owner/name`), `number`, `title`, `url`, `isDraft`, `review: ReviewState`, `ci: CIState`, `hasConflicts`, `createdAt`, `updatedAt`.
- `ReviewState`: `approved`, `changesRequested`, `waiting`.
- `CIState`: `passing`, `failing`, `pending`, `none`.
- `PullRequestGroup`: `needsAction`, `waiting`, `approved`, `drafts`, in this display order.

### Mapping from GitHub

| GitHub field | Value | App value |
|---|---|---|
| `reviewDecision` | `APPROVED` | `approved` |
| | `CHANGES_REQUESTED` | `changesRequested` |
| | `REVIEW_REQUIRED`, null | `waiting` |
| `commits(last:1).nodes[0].commit.statusCheckRollup.state` | `SUCCESS` | `passing` |
| | `FAILURE`, `ERROR` | `failing` |
| | `PENDING`, `EXPECTED` | `pending` |
| | missing | `none` |
| `mergeable` | `CONFLICTING` | `hasConflicts = true` |
| | `MERGEABLE`, `UNKNOWN` | `hasConflicts = false` |

### Grouping

Evaluated in this order, first match wins:

1. `isDraft` → `drafts`
2. `review == changesRequested` or `ci == failing` or `hasConflicts` → `needsAction`
3. `review == approved` → `approved`
4. otherwise → `waiting`

Sorting inside a group: `updatedAt` descending, except `waiting`, which is `updatedAt` ascending so stale PRs surface first.

## Fetching

`GitHubClient.fetchMyOpenPullRequests(login:) async throws -> (items: [PullRequestItem], total: Int)`:

- The login comes from the existing `currentUser()`.
- One GraphQL request: `search(query: "is:pr is:open author:<login> archived:false sort:updated-desc", type: ISSUE, first: 100)` selecting, on `PullRequest`: `number title url isDraft createdAt updatedAt reviewDecision mergeable repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }`, and `issueCount`.
- GraphQL `errors` become `GitHubError.graphQL(message)`; HTTP 401/403 reuse the existing error handling.

## Store

`AppStore` (in memory only, never written to `data.json`):

- `pullRequests: [PullRequestItem]`, `pullRequestsState: PullRequestsState` (`idle`, `loading`, `loaded(Date, total: Int)`, `failed(String)`).
- `refreshPullRequests() async`: needs a token (else `failed("Add a GitHub token in Settings.")`); fetches; applies the repo filter from `PrefKey.repos` (case-insensitive `owner/name`; empty means all repos); sets state. Ignores a call while already `loading`.
- `syncGitHub()` calls `refreshPullRequests()` after the ticket sync. A failure there only sets `pullRequestsState` and never changes `syncState`.
- `pullRequestGroups: [(PullRequestGroup, [PullRequestItem])]` returns non-empty groups in display order with the sorting above.

## UI

- `SidebarItem.pullRequests = "Pull Requests"` (symbol `arrow.triangle.pull`), placed after Board.
- `FocusTracker/PullRequestsView.swift` (new): page header with last-updated time and a Refresh button; sections per group with a count; rows show the title, `repo#number`, an age ("2d"), and chips for review (Waiting / Approved / Changes requested), CI (Passing / Failing / Running), Conflicts and Draft. Clicking a row opens the URL in the browser.
- The view refreshes on appear when state is `idle` or the data is older than 120 seconds.
- Empty state: "No open pull requests." Failed state: the message plus, for permission errors, the hint "Needs Pull requests: Read (and Commit statuses / Checks: Read for CI)". When `total > 100`: "Showing the first 100 of N."

## Error handling

- No token: message in the tab, no request.
- Network or GraphQL failure: message and the previous list stays visible.
- Unknown enum values from GitHub map to the neutral case (`waiting`, `none`) so a new GitHub value never breaks the tab.

## Testing

Unit tests in `Tests/FocusCoreTests` (written first), using the existing mock `HTTPTransport`:

- Parsing a sample response covering draft, every review decision, every CI state, conflicts, and missing `statusCheckRollup`.
- Unknown enum values fall back to neutral.
- Grouping order and precedence (a draft with failing CI is a draft) and sorting, including `waiting` oldest-first.
- Repo filter: matches case-insensitively, empty means all.
- Store: no token gives `failed`; success gives `loaded` with the filtered list; failure keeps the previous list; a PR failure leaves `syncState` untouched.

The UI is verified by building and running the app.
