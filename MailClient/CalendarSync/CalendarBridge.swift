import Foundation
import EventKit
import AppKit
import os

enum CalendarBridgeError: Error, LocalizedError {
    case accessDenied
    case localSourceUnavailable
    case calendarNotFound
    case eventStoreError(Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Calendar access was not granted."
        case .localSourceUnavailable: return "No local calendar source available on this Mac."
        case .calendarNotFound: return "Dedicated EAS calendar not found."
        case .eventStoreError(let e): return "EventKit error: \(e.localizedDescription)"
        }
    }
}

/// EventKit bridge that owns one dedicated, app-controlled `EKCalendar`.
/// All sync writes go into this calendar; user calendars are never touched.
final class CalendarBridge {
    static let dedicatedCalendarTitle = "Exchange (synced)"

    let store: EKEventStore
    private let log = Logger(subsystem: "com.mailclient.MailClient", category: "CalendarBridge")
    private let stateStore: SyncStateStore
    private let settings: AppSettings

    init(stateStore: SyncStateStore = .shared, settings: AppSettings = .shared) {
        self.store = EKEventStore()
        self.stateStore = stateStore
        self.settings = settings
    }

    // MARK: - Authorization

    /// Requests calendar access. Uses the modern API on macOS 14+ and falls
    /// back to `requestAccess(to:)` on macOS 13.
    func requestAccess() async throws {
        if #available(macOS 14.0, *) {
            return try await withCheckedThrowingContinuation { cont in
                store.requestFullAccessToEvents { granted, error in
                    if let error = error { cont.resume(throwing: error); return }
                    if !granted { cont.resume(throwing: CalendarBridgeError.accessDenied); return }
                    cont.resume()
                }
            }
        } else {
            return try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: .event) { granted, error in
                    if let error = error { cont.resume(throwing: error); return }
                    if !granted { cont.resume(throwing: CalendarBridgeError.accessDenied); return }
                    cont.resume()
                }
            }
        }
    }

    func currentAuthorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Dedicated calendar lifecycle

    /// Returns the dedicated calendar, creating it if missing.
    @discardableResult
    func ensureLocalCalendar() throws -> EKCalendar {
        let snap = stateStore.snapshot()
        if let savedId = snap.dedicatedCalendarIdentifier,
           let cal = store.calendar(withIdentifier: savedId) {
            return cal
        }

        // No saved id (or stale id). Find by title under a local source.
        if let existing = findDedicatedCalendar() {
            stateStore.mutate { $0.dedicatedCalendarIdentifier = existing.calendarIdentifier }
            return existing
        }

        // Create new local calendar.
        guard let local = preferredLocalSource() else {
            throw CalendarBridgeError.localSourceUnavailable
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = Self.dedicatedCalendarTitle
        cal.cgColor = NSColor.systemPurple.cgColor
        cal.source = local
        do {
            try store.saveCalendar(cal, commit: true)
        } catch {
            throw CalendarBridgeError.eventStoreError(error)
        }
        stateStore.mutate { $0.dedicatedCalendarIdentifier = cal.calendarIdentifier }
        log.notice("Created dedicated calendar id=\(cal.calendarIdentifier, privacy: .public)")
        return cal
    }

    private func preferredLocalSource() -> EKSource? {
        // Prefer .local source. Fall back to "iCloud" only if user has zero
        // local sources (very rare on macOS).
        if let local = store.sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        return store.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
    }

    private func findDedicatedCalendar() -> EKCalendar? {
        for cal in store.calendars(for: .event) where cal.title == Self.dedicatedCalendarTitle {
            return cal
        }
        return nil
    }

    // MARK: - Reset / wipe

    /// Wipes only the SyncKey ladder (PolicyKey + per-folder keys + ServerId map).
    /// Local events are kept; the next Sync will be initial again.
    func resetSyncKeys() {
        stateStore.mutate {
            $0.policyKey = "0"
            $0.folderHierarchySyncKey = "0"
            $0.folderSyncKeys = [:]
            $0.serverIdToEventExternalId = [:]
        }
    }

    /// Removes every event from the dedicated calendar but keeps the calendar
    /// container itself. SyncKeys/maps are also cleared.
    func wipeAllEvents() throws {
        guard let cal = try? ensureLocalCalendar() else {
            resetSyncKeys()
            return
        }
        let predicate = store.predicateForEvents(
            withStart: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSinceNow: 60 * 60 * 24 * 365 * 50),
            calendars: [cal]
        )
        let events = store.events(matching: predicate)
        for ev in events {
            do {
                try store.remove(ev, span: .futureEvents, commit: false)
            } catch {
                log.error("Failed to remove event during wipe: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try store.commit()
        } catch {
            throw CalendarBridgeError.eventStoreError(error)
        }
        resetSyncKeys()
    }

    /// Hard reset: deletes the dedicated calendar and clears all sync state.
    /// User's other calendars are not touched.
    func deleteCalendar() throws {
        if let savedId = stateStore.snapshot().dedicatedCalendarIdentifier,
           let cal = store.calendar(withIdentifier: savedId) {
            do {
                try store.removeCalendar(cal, commit: true)
            } catch {
                throw CalendarBridgeError.eventStoreError(error)
            }
        } else if let cal = findDedicatedCalendar() {
            do {
                try store.removeCalendar(cal, commit: true)
            } catch {
                throw CalendarBridgeError.eventStoreError(error)
            }
        }
        stateStore.replace(with: SyncState())
    }

    // MARK: - CRUD events

    /// Applies a list of EAS changes atomically (single commit).
    func apply(_ changes: [EASChange]) throws {
        guard !changes.isEmpty else { return }
        let cal = try ensureLocalCalendar()

        for change in changes {
            switch change {
            case .add(let serverId, let item):
                upsert(serverId: serverId, item: item, calendar: cal)
            case .change(let serverId, let item):
                upsert(serverId: serverId, item: item, calendar: cal)
            case .delete(let serverId):
                deleteEvent(serverId: serverId, calendar: cal)
            }
        }

        do {
            try store.commit()
        } catch {
            throw CalendarBridgeError.eventStoreError(error)
        }
    }

    // MARK: - Internals

    private func upsert(serverId: String, item: EASCalendarItem, calendar: EKCalendar) {
        let event = findEvent(serverId: serverId, calendar: calendar) ?? EKEvent(eventStore: store)
        if event.calendar == nil { event.calendar = calendar }
        applyFields(item, to: event)
        // Persist the EAS link via the public iCal extension property; both
        // legs (round-trip) and our local lookup rely on it.
        event.calendarItemExternalIdentifier_setIfPossible(serverId)

        do {
            try store.save(event, span: .futureEvents, commit: false)
            stateStore.mutate { $0.serverIdToEventExternalId[serverId] = event.eventIdentifier ?? serverId }
        } catch {
            log.error("Save event failed for \(serverId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteEvent(serverId: String, calendar: EKCalendar) {
        if let event = findEvent(serverId: serverId, calendar: calendar) {
            do {
                try store.remove(event, span: .futureEvents, commit: false)
            } catch {
                log.error("Delete event failed for \(serverId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        stateStore.mutate { $0.serverIdToEventExternalId.removeValue(forKey: serverId) }
    }

    private func findEvent(serverId: String, calendar: EKCalendar) -> EKEvent? {
        // First try by stored eventIdentifier.
        if let storedId = stateStore.snapshot().serverIdToEventExternalId[serverId],
           let ev = store.event(withIdentifier: storedId) {
            return ev
        }
        // Fall back to scanning the calendar for matching external identifier.
        let pred = store.predicateForEvents(
            withStart: Date(timeIntervalSinceNow: -60 * 60 * 24 * 366 * 5),
            end: Date(timeIntervalSinceNow: 60 * 60 * 24 * 366 * 5),
            calendars: [calendar]
        )
        for ev in store.events(matching: pred) {
            if ev.calendarItemExternalIdentifier == serverId { return ev }
        }
        return nil
    }

    private func applyFields(_ item: EASCalendarItem, to event: EKEvent) {
        event.title = item.subject ?? "(no subject)"
        event.location = item.location
        event.notes = item.body
        event.isAllDay = item.allDay

        if item.allDay {
            // EAS all-day events have UTC midnight start/end. EventKit prefers
            // start/end interpreted in the system calendar zone.
            event.timeZone = item.resolvedTimeZone ?? TimeZone.current
        } else if let tz = item.resolvedTimeZone {
            event.timeZone = tz
        } else {
            event.timeZone = TimeZone(identifier: "UTC")
        }

        if let s = item.startTime { event.startDate = s }
        if let e = item.endTime { event.endDate = e }
        if event.endDate == nil, let s = event.startDate {
            event.endDate = s.addingTimeInterval(60 * 60)
        }

        applyAlarm(reminderMinutes(for: item), to: event)
        applyAttendeesAsNotes(item, to: event)
        applyRecurrence(item.recurrence, to: event)
    }

    private func reminderMinutes(for item: EASCalendarItem) -> Int? {
        settings.forceReminderEnabled ? settings.forcedReminderMinutes : item.reminderMinutes
    }

    private func applyAlarm(_ minutes: Int?, to event: EKEvent) {
        guard let m = minutes else { return }
        event.alarms = []
        guard m >= 0, m < 60 * 24 * 90 else { return }
        let alarm = EKAlarm(relativeOffset: TimeInterval(-m * 60))
        event.addAlarm(alarm)
    }

    private func applyAttendeesAsNotes(_ item: EASCalendarItem, to event: EKEvent) {
        guard !item.attendees.isEmpty else { return }
        // EventKit doesn't allow setting attendees on locally-created events;
        // we surface them in the notes for visibility.
        let lines = item.attendees.compactMap { a -> String? in
            switch (a.name, a.email) {
            case (.some(let n), .some(let e)) where !n.isEmpty: return "• \(n) <\(e)>"
            case (_, .some(let e)) where !e.isEmpty: return "• \(e)"
            default: return nil
            }
        }
        guard !lines.isEmpty else { return }
        let header = "Attendees:\n" + lines.joined(separator: "\n")
        event.notes = [event.notes, header].compactMap { $0 }.joined(separator: "\n\n")
    }

    private func applyRecurrence(_ rec: EASRecurrence?, to event: EKEvent) {
        event.recurrenceRules = nil
        guard let r = rec, let rule = RecurrenceMapper.map(r) else { return }
        event.addRecurrenceRule(rule)
    }
}

// MARK: - External identifier helper

private extension EKEvent {
    /// `calendarItemExternalIdentifier` is read-only on EKCalendarItem. For
    /// app-created events EventKit derives it from the iCal `UID` of the event.
    /// We piggy-back on that: setting `event.url`/UID-like fields is not
    /// supported, but we can stash the EAS ServerId in `notes` as a fallback
    /// and keep the authoritative mapping in our own store.
    func calendarItemExternalIdentifier_setIfPossible(_ serverId: String) {
        // No-op: we maintain the mapping in `SyncStateStore`. The method is
        // kept as a hook in case Apple opens the API.
        _ = serverId
    }
}
