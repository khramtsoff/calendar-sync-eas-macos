# CalendarSync — EAS Calendar Bridge for macOS

Menu-bar app that talks to a custom Exchange ActiveSync (EAS) server and
mirrors calendar events into a dedicated, app-controlled local calendar in
the system Calendar.app.

The protocol target is desktop, but EAS itself is mobile-only. This app acts
as a personal proxy: it speaks EAS to your server and writes a read-only
shadow into macOS Calendar via EventKit.

## Features

- Pure-Swift WBXML codec covering the EAS code pages used for sync
  (`AirSync`, `Calendar`, `FolderHierarchy`, `Provision`, `Settings`,
  `AirSyncBase`).
- Auto-detected protocol version via `OPTIONS /Microsoft-Server-ActiveSync`
  (priority 14.1, fall back to 14.0 / 12.1).
- Provision (two-phase) with retry on `449 / status 142,144`.
- FolderSync + per-calendar incremental Sync with `MoreAvailable` paging.
- Recurrence (Type 0..6) → `EKRecurrenceRule`.
- EAS TimeZone blob → IANA `TimeZone` (Windows zone map + offset matching).
- Dedicated `Exchange (synced)` local calendar — your other calendars are
  never touched.
- Three reset levels in Settings → Advanced:
  1. Re-sync (clear SyncKey only)
  2. Wipe events (events + ServerId map)
  3. Delete calendar (full hard reset)
- Credentials in Keychain, sync state in `~/Library/Application Support/CalendarSync/sync-state.json`.

## Requirements

- macOS 13 or newer (14+ recommended for the modern EventKit access API).
- Xcode 15+ (uses Swift 5 mode).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for generating the
  Xcode project from `project.yml`:
  ```sh
  brew install xcodegen
  ```

## Build

```sh
xcodegen generate
open CalendarSync.xcodeproj
```

Or from the command line:

```sh
xcodegen generate
xcodebuild -project CalendarSync.xcodeproj -scheme CalendarSync -configuration Debug build
```

## Run

1. First launch shows nothing visible — the app is `LSUIElement = true`.
   Look at the top right of the menu bar for the calendar icon.
2. Click the icon → `Settings…`.
3. Fill in `Host` (full URL like `https://mail.example.com`), username,
   password. Hit `Save credentials` then `Test connection`.
4. Open the menu and press `Sync now`, or wait for the timer.
5. Open Calendar.app — you should see a new calendar called
   **Exchange (synced)** under "On My Mac" with your meetings.

## Project layout

```
CalendarSync/
├── App/                CalendarSyncApp.swift (MenuBarExtra + Settings scenes)
├── UI/                 MenuBar / Settings views
├── Storage/            Keychain, AppSettings, SyncState
├── WBXML/              Pure-Swift codec
├── EAS/                EASClient + Commands (Provision/FolderSync/Sync) + parser
├── CalendarSync/       EventKit bridge, recurrence and timezone mappers
├── Sync/               SyncEngine actor + ring-buffer log
└── Resources/          Info.plist, entitlements
```

## Diagnostics

`Settings → Log` shows a live tail. The same lines are emitted to unified
logging:

```sh
log stream --predicate 'subsystem == "com.calendarsync.CalendarSync"'
```

## Known limitations / not in MVP

- Read-only mirroring; no events flow back to EAS.
- No Mail / Contacts / Tasks (calendar only by design).
- No `Ping` long-poll yet — sync is a periodic pull.
- No Autodiscover — supply the EAS URL explicitly.
- OAuth Bearer auth has only a header hook; today the app uses Basic.
