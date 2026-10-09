# Focus Tracker

Personal macOS app (SwiftUI): GitHub assigned tickets, time tracking, board, reports, menu bar timer.

## Run

```sh
swift test                    # unit tests
./scripts/build-app.sh        # creates build/FocusTracker.app
open build/FocusTracker.app
```

Requires macOS 14+ and Xcode / Swift 5.9+.

## GitHub setup

1. Create a personal access token (fine-grained: Issues → Read, or classic: `repo`).
2. App → Settings (⌘,) → paste the token → **Save & Sync**. The token is stored in the Keychain.
3. Optionally restrict to repos (`owner/name, owner/other`) and include assigned pull requests.

Open issues assigned to you are synced every N minutes (and with ⌘R). Issues that are closed or reassigned are marked Done.
Local fields (status, priority, notes, estimate, time entries) are never overwritten by a sync.

Data is stored in `~/Library/Application Support/FocusTracker/data.json`.

## Next stages

- Google Calendar (personal): via macOS Calendar/EventKit with the Google account added in System Settings → Internet Accounts.
- Push status back to GitHub (close issue, comment), focus mode, time blocking.
