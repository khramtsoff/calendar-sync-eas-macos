# CalendarSync Development

This document is for contributors and maintainers. User-facing setup and usage
instructions live in [README.md](README.md).

## Requirements

| Requirement | Version |
|---|---|
| macOS | 14 or later |
| Xcode | 15 or later |
| Swift | 5 mode |

Optional tools:

- **XcodeGen** - generate `CalendarSync.xcodeproj` from `project.yml`
  (`brew install xcodegen`).
- **fswatch** - run `make watch` for local rebuild/relaunch loops
  (`brew install fswatch`).
- **GitHub CLI** - publish GitHub releases (`brew install gh`).

## Commands

Use the commands from `Makefile`:

```sh
make project          # generate CalendarSync.xcodeproj
make build            # generate project and build Debug
make run              # build, stop a running app instance, launch Debug app
make watch            # rebuild/relaunch on source changes; requires fswatch
make kill             # stop the running app
make clean            # remove build and dist artifacts
```

## Xcode Project

`CalendarSync.xcodeproj` is generated and must not be committed. Generate it
from `project.yml` when needed:

```sh
xcodegen generate
open CalendarSync.xcodeproj
```

## Architecture

```text
SwiftUI UI
    |
    v
SyncEngine (@MainActor)
    |
    |-- EASClient
    |-- CalendarBridge
    |-- SyncStateStore
    `-- SyncLog
```

## Key Files

| File | Purpose |
|---|---|
| `CalendarSync/App/CalendarSyncApp.swift` | App entry point, `MenuBarExtra`, settings scene |
| `CalendarSync/UI/SettingsView.swift` | Account, sync, log, and advanced settings |
| `CalendarSync/UI/MenuBarContentView.swift` | Menu-bar popover actions/status |
| `CalendarSync/Sync/SyncEngine.swift` | Sync orchestration, timers, reset actions |
| `CalendarSync/EAS/EASClient.swift` | ActiveSync HTTP client, probe, provision, sync commands |
| `CalendarSync/CalendarSync/CalendarBridge.swift` | EventKit calendar/event writes |
| `CalendarSync/Storage/AppSettings.swift` | UserDefaults-backed settings |
| `CalendarSync/Storage/Keychain.swift` | Password storage |
| `CalendarSync/Storage/SyncState.swift` | Sync state persistence |

## Security Notes

- Passwords are stored only in macOS Keychain.
- Sync state is stored in
  `~/Library/Application Support/CalendarSync/sync-state.json`.
- Do not commit secrets, passwords, tokens, cookies, or real private server
  URLs.
- Notarization credentials are stored in a `notarytool` Keychain profile.
- The app currently supports Basic Auth only; OAuth Bearer, NTLM, and Negotiate
  are diagnosed but not implemented.

## Versioning

The repository-level release version is stored in:

```sh
VERSION
```

`make release` reads this file by default. You can override it explicitly:

```sh
make release VERSION=1.2.3
```

## Release Notes

Release notes are required and stored in:

```sh
RELEASE_NOTES.md
```

Before publishing a release, add a section matching the release version:

```md
## 1.2.3
```

## Local Release

Prerequisites:

1. Install the Developer ID Application certificate and private key for team
   `JF25G9C7A8` in Keychain Access.
2. Authenticate GitHub CLI:
   ```sh
   gh auth login
   ```
3. Store Apple notarization credentials in Keychain using an app-specific
   password:
   ```sh
   xcrun notarytool store-credentials calendarsync-notary \
     --apple-id "APPLE_ID_EMAIL" \
     --team-id JF25G9C7A8 \
     --password "APP_SPECIFIC_PASSWORD"
   ```

Build, sign, notarize, staple, zip, publish the GitHub Release, and update the
Homebrew tap:

```sh
make release
```

Useful individual targets:

```sh
make check-signing
make dist
make publish-github
make publish-homebrew
```

The Homebrew target writes cask `calendar-sync` to
`https://github.com/khramtsoff/homebrew-brew`.

## Agent Release Semantics

- "Подготовь релиз" means update `VERSION`, update `RELEASE_NOTES.md`, and run
  `make dist`; do not publish unless explicitly requested.
- "Выпусти релиз" means run the full local release flow: `make release`.
