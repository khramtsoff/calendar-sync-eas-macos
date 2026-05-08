import Foundation

/// Parses the contents of an `<airsync:ApplicationData>` element for a calendar
/// item. The element body lives in the Calendar code page (with optional
/// AirSyncBase pieces for the body).
enum EASCalendarParser {
    static func parse(_ appData: WBXMLNode) -> EASCalendarItem {
        var item = EASCalendarItem()

        for child in appData.children {
            guard case .element(let name, _) = child else { continue }
            switch (name.page, name.name) {
            case (.calendar, "Subject"):    item.subject = child.stringValue
            case (.calendar, "Location"):   item.location = child.stringValue
            case (.calendar, "OrganizerName"): item.organizerName = child.stringValue
            case (.calendar, "OrganizerEmail"): item.organizerEmail = child.stringValue
            case (.calendar, "StartTime"):
                item.startTime = child.stringValue.flatMap(EASDateFormat.parse)
            case (.calendar, "EndTime"):
                item.endTime = child.stringValue.flatMap(EASDateFormat.parse)
            case (.calendar, "DtStamp"):
                item.dtStamp = child.stringValue.flatMap(EASDateFormat.parse)
            case (.calendar, "AllDayEvent"):
                item.allDay = (child.stringValue == "1")
            case (.calendar, "UID"):
                item.uid = child.stringValue
            case (.calendar, "ClientUid"):
                if item.uid == nil { item.uid = child.stringValue }
            case (.calendar, "Reminder"):
                item.reminderMinutes = Int(child.stringValue ?? "")
            case (.calendar, "Sensitivity"):
                item.sensitivity = Int(child.stringValue ?? "")
            case (.calendar, "BusyStatus"):
                item.busyStatus = Int(child.stringValue ?? "")
            case (.calendar, "MeetingStatus"):
                item.meetingStatus = Int(child.stringValue ?? "")
            case (.calendar, "ResponseRequested"):
                item.responseRequested = (child.stringValue == "1")
            case (.calendar, "TimeZone"):
                if let s = child.stringValue, let raw = Data(base64Encoded: s) {
                    item.timeZoneBlob = raw
                    item.resolvedTimeZone = TimezoneDecoder.decode(raw)
                } else if case .opaque(let data) = child.children.first {
                    item.timeZoneBlob = data
                    item.resolvedTimeZone = TimezoneDecoder.decode(data)
                }
            case (.calendar, "Attendees"):
                item.attendees = parseAttendees(child)
            case (.calendar, "Categories"):
                item.categories = parseCategories(child)
            case (.calendar, "Recurrence"):
                item.recurrence = parseRecurrence(child)
            case (.calendar, "Exceptions"):
                item.exceptions = parseExceptions(child)
            case (.airSyncBase, "Body"):
                if let data = child.child(.airSyncBase, "Data")?.stringValue {
                    item.body = data
                }
            default:
                break
            }
        }

        return item
    }

    private static func parseAttendees(_ node: WBXMLNode) -> [EASAttendee] {
        var out: [EASAttendee] = []
        for c in node.children(.calendar, "Attendee") {
            var a = EASAttendee()
            a.name = c.string(.calendar, "Name")
            a.email = c.string(.calendar, "Email")
            a.status = Int(c.string(.calendar, "AttendeeStatus") ?? "")
            a.type = Int(c.string(.calendar, "AttendeeType") ?? "")
            out.append(a)
        }
        return out
    }

    private static func parseCategories(_ node: WBXMLNode) -> [String] {
        node.children(.calendar, "Category").compactMap { $0.stringValue }
    }

    static func parseRecurrence(_ node: WBXMLNode) -> EASRecurrence? {
        guard let typeStr = node.string(.calendar, "Type"), let type = Int(typeStr) else { return nil }
        var r = EASRecurrence(type: type)
        if let s = node.string(.calendar, "Interval") { r.interval = Int(s) ?? 1 }
        r.dayOfWeek = node.string(.calendar, "DayOfWeek").flatMap(Int.init)
        r.dayOfMonth = node.string(.calendar, "DayOfMonth").flatMap(Int.init)
        r.weekOfMonth = node.string(.calendar, "WeekOfMonth").flatMap(Int.init)
        r.monthOfYear = node.string(.calendar, "MonthOfYear").flatMap(Int.init)
        r.firstDayOfWeek = node.string(.calendar, "FirstDayOfWeek").flatMap(Int.init)
        r.occurrences = node.string(.calendar, "Occurrences").flatMap(Int.init)
        r.until = node.string(.calendar, "Until").flatMap(EASDateFormat.parse)
        r.calendarType = node.string(.calendar, "CalendarType").flatMap(Int.init)
        if let leap = node.string(.calendar, "IsLeapMonth") { r.isLeapMonth = (leap == "1") }
        return r
    }

    private static func parseExceptions(_ node: WBXMLNode) -> [EASException] {
        var out: [EASException] = []
        for c in node.children(.calendar, "Exception") {
            var ex = EASException()
            ex.deleted = (c.string(.calendar, "Deleted") == "1")
            ex.startTime = c.string(.calendar, "ExceptionStartTime").flatMap(EASDateFormat.parse)
            // Exception may carry override fields inline (using Calendar tags).
            // Reuse the same parser by wrapping into a synthetic ApplicationData.
            if !ex.deleted {
                ex.item = parse(c)
            }
            out.append(ex)
        }
        return out
    }
}

/// EAS dates use ISO 8601 basic UTC: `yyyyMMdd'T'HHmmssZ`. All-day events use
/// `yyyyMMdd` (no time).
enum EASDateFormat {
    private static let utcFull: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static let utcDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static let utcExtended: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = utcFull.date(from: trimmed) { return d }
        if let d = utcDateOnly.date(from: trimmed) { return d }
        if let d = utcExtended.date(from: trimmed) { return d }
        return nil
    }
}
