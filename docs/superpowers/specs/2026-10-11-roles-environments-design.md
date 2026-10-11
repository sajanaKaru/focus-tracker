# Roles and Deployment Environments — Foundation Design

Date: 2026-10-11

## Context

Sub-project 2 of 3 (licensing is done; QA Stage 1 follows). The app becomes usable by Dev, QA and PM. All data stays local; a role is a UI preference, not a security boundary. This stage adds the role model, role-driven navigation and ordering, and deployment environments as a filter. It adds no QA features.

## Goal

- Choose a role (Dev / QA / PM) in Settings; it controls the visible tabs, the landing view, the order of status groups and the default quick-capture type.
- Recognise Alpha, Alpha2, Beta and Live from project Status names and filter tickets by environment.

## Decisions

- Role is stored in `UserDefaults` (`PrefKey.role`), next to the token. Default is Dev, so existing installs behave as today.
- Role is picked in Settings → GitHub, above the token field. The picker applies immediately, with or without a saved token, so the role can change without re-entering the token.
- Environments are independent filters, not a pipeline. Environment comes from the ticket's project Status name only; the latest status wins.
- Role and environment are derived or preference data; nothing new is written to GitHub.

## Role profile (FocusCore)

`UserRole: dev, qa, pm` with a pure-data `RoleProfile`:

| | Dev | QA | PM |
|---|---|---|---|
| Sections | Today, Tickets, Board, Pull Requests, Data & Scripts, Reports, Action Log | Today, Tickets, Board, Reports, Action Log | Today, Tickets, Board, Reports, Action Log |
| Landing | Today | Tickets | Board |
| Status order in Tickets | In Progress, In Review, Todo, Testing, Backlog, Done | Testing, In Review, In Progress, Todo, Backlog, Done | In Progress, In Review, Testing, Todo, Backlog, Done |
| Default quick capture | Bug | Bug | Request |

`AppSection` (FocusCore) lists the sections; the app's `SidebarItem` maps to it. Done is always last.

## Environments (FocusCore)

- `DeploymentEnvironment: alpha, alpha2, beta, live` with `title`.
- `init?(statusName:)`: the lowercased name must contain "deploy" plus an environment word. `alpha2`, `alpha 2` and `alpha-2` map to Alpha2 and are checked before `alpha`; `beta` → Beta; `live`, `production` → Live. Anything else is nil, including "Ready for Beta" and "Ready for Live", which stay Done as they do today.
- `Ticket.environment` is computed from `projectStatusField?.value`; nothing is stored. Local tickets have none.
- `TicketStatus(optionName:)` gains a first rule: a deployed status in Alpha, Alpha2 or Beta maps to Testing, and Live maps to Done. Without it these names fall through to Todo.
- `TicketFilter.environment: DeploymentEnvironment?`; `isActive` and `matches` include it.

## App

- **Settings:** a Role picker at the top of the GitHub section.
- **Sidebar:** shows only the role's sections. At launch the selection is the role's landing. When the role changes and the current section is hidden, selection moves to the landing.
- **Tickets list:** group order follows the role's status order instead of the fixed `allCases.reversed()`.
- **FilterBar:** an Environment menu (All, Alpha, Alpha2, Beta, Live), disabled for the Local source like Milestone and Sprint. Choosing Live also shows Done tickets, since Live maps to Done.
- **Ticket rows:** an environment chip beside the status when the ticket has one.
- **Quick capture:** the initial type comes from the role profile in the sheet and the menu bar.
- **Board:** columns still follow the GitHub Status option order, which is the team's workflow. The role order is used only for the fallback columns when no options are loaded.

## Out of scope

- QA queue, test cases, bug reports, Pass/Fail write-back and the Live release archive (sub-project 3).
- A status filter or a Blocked status. The app has no Blocked status today; a "Blocked" project option still shows as a board column but maps to Todo.
- Role-based ordering in the Today view.
- Tying role to the Firebase account or restricting it from the console.

## Testing

- `RoleProfile`: sections, landing, status order (Done last, every status exactly once) and capture default for each role.
- `DeploymentEnvironment(statusName:)`: "Deployed to Alpha", "Deployed to Alpha2", "Deployed to Alpha 2", "Deployed to Beta", "Deployed to Live"; "Ready for Beta", "In Progress" and "Alpha testing" give nil.
- `TicketStatus(optionName:)`: deployed Alpha/Alpha2/Beta give Testing, deployed Live gives Done, and existing mappings are unchanged.
- `Ticket.environment` follows the project Status field and updates when it changes.
- `TicketFilter` environment: matches, `isActive`, and combined with milestone and source.
- `AppStore` role persists in `UserDefaults` and defaults to Dev.

## Risks

- Status names that don't contain "deploy" won't be recognised as environments; the rule is deliberately strict so ordinary names don't match by accident. If your team's names differ, the rule is one function to adjust.
- The role is a preference, so anyone can switch it in Settings.

## Delivery split

1. FocusCore: `UserRole`, `RoleProfile`, `DeploymentEnvironment`, status mapping, filter, role persistence, tests.
2. App: Settings picker, sidebar and landing, Tickets ordering, environment filter and chip, quick-capture default.
