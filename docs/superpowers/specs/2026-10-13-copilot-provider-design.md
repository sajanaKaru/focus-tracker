# GitHub Copilot provider for test-case drafting

## Goal

Let QA draft test cases with the models enabled for the user's GitHub Copilot account, without an API key. Add "GitHub Copilot" as a fourth `AIProvider`.

## Findings that shape the design

- GitHub Models is retired (2026-07-30); there is no public REST call that detects Copilot from a token.
- The supported route is the Copilot CLI. The app's stored token is a classic PAT (`ghp_`), which the Copilot SDK and CLI do not accept, so Copilot uses the CLI's own login (`copilot login`).
- `copilot --acp` (Agent Client Protocol, newline-delimited JSON-RPC on stdio) answers `session/new` with `models.availableModels`. Each model has `_meta.copilotEnablement` (`enabled`) and `_meta.copilotUsage` (premium-request multiplier such as `1x`, `15x`). The list can contain duplicate ids (e.g. `auto`). Verified against CLI 1.0.96 on 2026-10-13.
- `copilot -p` needs `--allow-all-tools`, so it is not used.
- A Finder-launched app does not inherit the shell PATH (the CLI lives under nvm), so the executable must be located explicitly.

## Scope

In: provider, ACP client, CLI locator, model picker, errors, Settings UI, tests.
Out: streaming to the UI, session reuse or a persistent process, `ghp_` reuse or token exchange, reasoning-effort setting, any other CLI feature.

## Components

New file `Sources/FocusCore/CopilotCLI.swift`:

- `CopilotLocator`: returns the Settings override path if it is an executable file; otherwise runs `zsh -lic 'command -v copilot'` (interactive, so `.zshrc` and nvm load; 5 s limit), falls back to `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`, and caches the result. The launcher is a Node script, so the child process gets the executable's directory prepended to `PATH`.
- `CopilotModel`: `id`, `name`, `usage`. Built from `availableModels`, keeping only `copilotEnablement == "enabled"` (entries without the field are dropped) and deduplicating by id.
- `CopilotACPClient`: launches `copilot --acp --no-auto-update` in a fresh temporary directory behind an injectable transport protocol (real = `Process` + pipes; tests = scripted fake).
  - `availableModels()`: `initialize`, `session/new`, read models, terminate.
  - `draftCases(_:model:)`: `initialize`, `session/new`, `session/set_model` with the saved model if it is in the enabled list, otherwise with `auto` if that is enabled (otherwise the account default is kept), `session/prompt` with the system and user text combined, concatenate `agent_message_chunk` text until the prompt completes, terminate, then `AICaseClient.parseCases`. The model list comes from the same `session/new` reply, so no extra call is needed.
  - Every `session/request_permission` is answered with the protocol's `cancelled` outcome. File-system and terminal client capabilities are not advertised.
  - 90 s timeout; the process is killed on timeout, cancellation, or completion.

Changes to existing code:

- `AIProvider`: add `.copilot` (title "GitHub Copilot", `defaultModel` `"auto"`). `keychainAccount` is unused for it.
- `AIError`: add `copilotNotInstalled`, `copilotNotSignedIn`, `copilotNoEnabledModels`, `copilotFailed(String)`.
- `AppStore+QADrafts.swift`: `hasAIKey` is always true for `.copilot` (the button stays enabled and the draft error explains what is missing). `draftTestCases` skips the key lookup for `.copilot` and calls `CopilotACPClient`.
- `PrefKey`: add the CLI path override key.
- `SettingsView` AI tab: for `.copilot`, replace the Model text field with a picker of enabled models labelled `name (usage)` plus a Refresh button, add a CLI path field, hide the API key section, and show a note that Copilot uses its own login (`copilot login`). Extend the privacy note to cover Copilot.
- `TicketQASection`: the disabled-button help text says "Set up an AI provider in Settings" instead of naming an API key.

## Data flow

1. Settings opens or Refresh is pressed: `availableModels()` runs off the main thread and fills the picker. An empty selection means `auto`. A saved model that is no longer enabled is flagged in Settings and drafting falls back to `auto`.
2. QA presses Draft: `draftTestCases` builds the existing `DraftPrompt`, calls `CopilotACPClient.draftCases` with the saved model, and returns `[DraftCase]` for the existing review sheet. Nothing is saved until the user confirms.

## Errors

- CLI missing: "GitHub Copilot CLI not found. Install it or set its path in Settings."
- Not signed in (auth error from `session/new` or `session/prompt`): "Run `copilot login` in a terminal, then try again."
- No enabled models: `copilotNoEnabledModels`.
- Timeout, CLI exiting early, or any other CLI error: `copilotFailed` with the CLI's message. An unparseable reply: `unreadableReply`.
- Quota or rate limit: surfaced as `rateLimited` with the CLI's message.

## Testing

Unit tests with a scripted fake transport: model parsing, enabled filtering and de-duplication; a permission request is rejected; reply assembly from chunks; the saved model, `auto` fallback and no-`set_model` cases; not-installed and not-signed-in errors; timeout kills the process. One manual check against the real CLI (not the app bundle, which reads the real data file and token).

## Open points

- The exact ACP error shape for "not signed in" must be confirmed against a signed-out CLI during implementation; until then treat any `session/new` error mentioning authentication as `copilotNotSignedIn`.
