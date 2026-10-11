# AI-drafted test cases from ticket + PR — Design

Date: 2026-10-12

Extends QA Stage 1 (`2026-10-11-qa-stage1-design.md`).

## Goal

In a ticket's QA section, **Draft test cases** reads the ticket and its linked pull requests, asks an AI provider for test cases, and shows a preview sheet. QA ticks the cases to keep; only those become `TestCase` records. Nothing is pushed to GitHub.

## Decisions

- Providers: OpenAI, Anthropic, Gemini. The user picks the provider and model in Settings and stores one API key per provider in the Keychain.
- Sent to the provider: ticket key, title and body; for each selected PR its title, body and changed file paths (max 100). No diff.
- PRs are found through the issue timeline (`CrossReferencedEvent`, `ConnectedEvent`). QA ticks which linked PRs to include. A ticket without PRs is drafted from the ticket text alone.
- Drafts are never saved until confirmed.

## FocusCore

- `AICaseDrafter.swift`: `AIProvider`, `DraftCase`, `AIError`, `DraftPrompt` (builds and truncates the prompt), `AICaseClient` (one request shape per provider, tolerant response parser).
- `GitHubClient+LinkedPullRequests.swift`: `fetchLinkedPullRequests(repo:number:)`, `fetchPullRequestDetail(repo:number:)`.
- `AppStore+QADrafts.swift`: `linkedPullRequests(for:)`, `draftTestCases(ticketID:pullRequests:)`, `addDrafts(ticketID:_:)` (reuses `addTestCase`, so cases appear in the Action Log).
- `AppStore.init` gains `aiKeyProvider`; provider and model live in `UserDefaults` (`PrefKey.aiProvider`, `PrefKey.aiModelPrefix`).

## App

- Settings: "AI" section with provider picker, model field and key field with save and remove.
- Ticket QA section: "Draft test cases" button, disabled with a hint when the selected provider has no key. The `DraftCasesSheet` loads linked PRs, lets QA pick them, generates, and lists drafts with checkboxes.

## Errors

Missing key, 401, 429, other HTTP codes, an unreadable reply, and an empty result each give a specific message in the sheet, with retry.

## Tests

Prompt contents and truncation; request URL, headers and body per provider (the key goes only to that provider); response parsing including fenced JSON and garbage; linked-PR decoding with duplicates, non-PR sources and none; `addDrafts` saves only the selected drafts; missing key and HTTP error mapping.

## Out of scope

Diffs, streaming, saved drafts, auto-generation.
