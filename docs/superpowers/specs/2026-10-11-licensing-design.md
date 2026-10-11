# Subscription Licensing (Firebase Auth) — Design

Date: 2026-10-11

## Context

Focus Tracker is growing from a personal developer tool into a multi-role app (Dev, PM, QA). All work data stays local in `data.json`. The only online dependency is a license check so the owner can suspend and re-enable users. This is sub-project 1 of 3, built in this order:

1. **Licensing** (this spec)
2. Roles and environment foundation (role chosen when a GitHub token is added; Alpha / Alpha2 / Beta / Live filters parsed from Status names)
3. QA Stage 1 (QA queue, test cases with per-environment results, bug reports, Pass/Fail write-back, Live release archive)

## Goal

Require a Firebase email/password sign-in. When the owner disables a user in the Firebase console, the app locks at its next check. Re-enabling restores access with all local data intact.

## Decisions

- Backend is Firebase Auth only. Suspend and re-enable use the console's Disable toggle.
- Called over REST with `URLSession` through the existing `HTTPTransport`; no Firebase SDK, `Package.swift` unchanged.
- No offline grace: if the license cannot be verified, the app is locked.
- Local data is never deleted or modified by the gate.
- Users are created only by the owner in the Firebase console. There is no in-app sign-up.
- No expiry dates, plans, Firestore, per-device limits or payments in v1.

## Components (FocusCore)

- `LicenseClient`: takes an `HTTPTransport` and a Firebase Web API key.
  - `signIn(email:password:)` → `identitytoolkit.googleapis.com/v1/accounts:signInWithPassword`
  - `refresh(refreshToken:)` → `securetoken.googleapis.com/v1/token`
  - `sendPasswordReset(email:)` → `accounts:sendOobCode` (`PASSWORD_RESET`)
  - Maps Firebase error messages to `LicenseError`: `.disabled` (`USER_DISABLED`), `.invalidCredentials`, `.sessionExpired` (`TOKEN_EXPIRED`, `USER_NOT_FOUND`, `INVALID_REFRESH_TOKEN`), `.unreachable` (transport failure).
- `LicenseStore` (`@Observable`): holds `state` and drives checks.
  - `LicenseState`: `signedOut`, `checking`, `active(email)`, `suspended`, `unreachable`.
  - `check()`: reads the refresh token from the Keychain; none → `signedOut`; otherwise `refresh`. Success → `active`; `.disabled` → `suspended`; `.sessionExpired` → clear token, `signedOut`; `.unreachable` → `unreachable`.
  - `signIn`, `signOut` (deletes the refresh token only), `resetPassword`.
  - Runs `check()` at launch, on app activation, and every 15 minutes while running.
- `Keychain`: new account name `firebase-refresh-token`. The password is never stored.

## App (FocusTracker target)

- `LicenseGate` wraps `RootView`: shows Checking, Sign in, Suspended or Unreachable instead of the app unless `state` is `active`.
- Background work is gated, not just the UI. `store.startAutoSync()` (currently in the window `.task`) starts only when `active` and stops when the state leaves `active`, so a locked app cannot sync or push edits to GitHub. The menu bar extra and Settings show only a locked message while not `active`.
- A running timer keeps its start time in `data.json`; locking does not stop or alter it.
- Settings gets an Account row: signed-in email and a Sign out button.

## Screens

| State | Content | Actions |
|---|---|---|
| Checking | Spinner | none |
| Sign in | Email, password, error line | Sign in, Forgot password |
| Suspended | "Your subscription is suspended. Contact the administrator." | Retry, Sign out |
| Unreachable | "Can't reach the license server." | Retry |

## Configuration

- Firebase Web API key stored in `scripts/Info.plist` (`FirebaseAPIKey`), read at launch. The key is public by design; access control is Firebase Auth.
- Debug builds (`#if DEBUG`) skip the gate so development and `swift test` are unaffected. Builds from `scripts/build-app.sh` always enforce it.

## Testing

With a mock `HTTPTransport` (existing `RecordingTransport` pattern in `TestSupport.swift`):

- Sign-in success stores the refresh token and gives `active`.
- Wrong password gives `.invalidCredentials`; no token stored.
- Sign-in or refresh returning `USER_DISABLED` gives `suspended`.
- Refresh with `TOKEN_EXPIRED`/`USER_NOT_FOUND` clears the token and gives `signedOut`.
- Transport failure gives `unreachable` and keeps the token.
- A re-check after suspension flips `active` to `suspended`; a re-check after re-enabling flips back to `active`.
- `signOut` removes the token and leaves `data.json` untouched.
- Password-reset request body is correct.

Keychain access is behind a small protocol in tests so no real Keychain is touched.

## Risks and limits

- Client-side enforcement in a locally built app can be bypassed by patching the binary or blocking the network. It deters casual use but is not copy protection.
- Without offline grace, users with no internet cannot open the app. Accepted by the owner.
- Detection latency is up to 15 minutes while the app is running.
- Already-issued ID tokens stay valid for up to an hour after a user is disabled, so the app must rely on the refresh call failing, never on a locally cached ID token.

## Delivery split

1. `LicenseClient`, `LicenseStore`, Keychain account, tests.
2. `LicenseGate` and screens, gated auto-sync, menu bar and Settings handling, Info.plist key, Account row.
