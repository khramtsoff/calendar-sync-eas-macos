import Foundation

/// Decodes the EAS `<calendar:TimeZone>` blob, defined in MS-ASDTYPE 2.6.4.
///
/// The blob is 172 bytes:
///   bias (LONG, 4 bytes, little-endian, minutes west of UTC)
///   standardName       (WCHAR[32]   = 64 bytes, UTF-16LE NUL-padded)
///   standardDate       (SYSTEMTIME, 16 bytes)
///   standardBias       (LONG)
///   daylightName       (WCHAR[32])
///   daylightDate       (SYSTEMTIME)
///   daylightBias       (LONG)
///
/// SYSTEMTIME (Win32 layout):
///   wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds   (each 2 bytes LE)
enum TimezoneDecoder {
    static let blobSize = 172

    /// Best-effort: try to map the blob to a real `TimeZone` via the bias.
    /// We don't synthesize custom DST rules - macOS already has IANA zones for
    /// every region we'd ever see, so we just match by total UTC offset and
    /// (when possible) the standard name.
    static func decode(_ data: Data) -> TimeZone? {
        guard data.count >= blobSize else { return nil }
        let bias = readInt32LE(data, offset: 0)
        let standardName = readWChar(data, offset: 4, length: 32)
        let standardBias = readInt32LE(data, offset: 84)
        let daylightName = readWChar(data, offset: 88, length: 32)
        // The Microsoft convention: a missing daylight rule has month==0 in
        // the SYSTEMTIME fields. We use that to detect whether DST applies.
        let daylightMonth = readUInt16LE(data, offset: 168 + 2) // wMonth in daylightDate
        let daylightActive = daylightMonth != 0

        // Total offset: standard time = -(bias + standardBias) minutes from UTC.
        let standardOffsetMinutes = -(bias + standardBias)
        let standardOffsetSeconds = standardOffsetMinutes * 60

        if let byName = matchByName(standardName) ?? matchByName(daylightName) {
            return byName
        }
        if let byOffset = matchByOffsetWithDST(seconds: standardOffsetSeconds, hasDST: daylightActive) {
            return byOffset
        }
        return TimeZone(secondsFromGMT: standardOffsetSeconds)
    }

    // MARK: - Heuristics

    private static func matchByName(_ name: String) -> TimeZone? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 1. Direct IANA name match (rare in EAS, but possible).
        if let tz = TimeZone(identifier: trimmed) { return tz }
        // 2. Map common Windows display names. EAS servers usually fill these.
        if let mapped = WindowsZoneMap.lookup(displayName: trimmed) {
            return TimeZone(identifier: mapped)
        }
        return nil
    }

    private static func matchByOffsetWithDST(seconds: Int, hasDST: Bool) -> TimeZone? {
        let candidates = TimeZone.knownTimeZoneIdentifiers.compactMap { TimeZone(identifier: $0) }
        // Filter to ones that have the same standard offset right now.
        let now = Date()
        let matching = candidates.filter { $0.secondsFromGMT(for: now) - ($0.daylightSavingTimeOffset(for: now) > 0 ? Int($0.daylightSavingTimeOffset(for: now)) : 0) == seconds }
        if matching.isEmpty { return nil }
        if hasDST {
            return matching.first { $0.nextDaylightSavingTimeTransition(after: now) != nil }
        }
        return matching.first { $0.nextDaylightSavingTimeTransition(after: now) == nil } ?? matching.first
    }

    // MARK: - Byte helpers

    private static func readInt32LE(_ d: Data, offset: Int) -> Int {
        let b0 = Int(d[d.startIndex + offset])
        let b1 = Int(d[d.startIndex + offset + 1])
        let b2 = Int(d[d.startIndex + offset + 2])
        let b3 = Int(d[d.startIndex + offset + 3])
        let unsigned = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
        return Int(Int32(bitPattern: unsigned))
    }

    private static func readUInt16LE(_ d: Data, offset: Int) -> UInt16 {
        let b0 = UInt16(d[d.startIndex + offset])
        let b1 = UInt16(d[d.startIndex + offset + 1])
        return b0 | (b1 << 8)
    }

    private static func readWChar(_ d: Data, offset: Int, length: Int) -> String {
        var chars: [UInt16] = []
        chars.reserveCapacity(length)
        for i in 0..<length {
            let v = readUInt16LE(d, offset: offset + i * 2)
            if v == 0 { break }
            chars.append(v)
        }
        return String(utf16CodeUnits: chars, count: chars.count)
    }
}

/// Hand-curated subset of Windows -> IANA mappings for the most common EAS
/// timezones. Authoritative mapping lives in CLDR
/// (windowsZones.xml); we ship a useful subset and fall back to offset matching.
enum WindowsZoneMap {
    private static let table: [String: String] = [
        "UTC": "UTC",
        "GMT Standard Time": "Europe/London",
        "British Summer Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Warsaw",
        "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw",
        "E. Europe Standard Time": "Europe/Bucharest",
        "FLE Standard Time": "Europe/Helsinki",
        "GTB Standard Time": "Europe/Bucharest",
        "Russian Standard Time": "Europe/Moscow",
        "Belarus Standard Time": "Europe/Minsk",
        "Russia TZ 2 Standard Time": "Europe/Moscow",
        "Russia TZ 3 Standard Time": "Europe/Samara",
        "Russia TZ 4 Standard Time": "Asia/Yekaterinburg",
        "Russia TZ 5 Standard Time": "Asia/Omsk",
        "Russia TZ 6 Standard Time": "Asia/Krasnoyarsk",
        "Russia TZ 7 Standard Time": "Asia/Irkutsk",
        "Russia TZ 8 Standard Time": "Asia/Yakutsk",
        "Russia TZ 9 Standard Time": "Asia/Vladivostok",
        "Russia TZ 10 Standard Time": "Asia/Magadan",
        "Russia TZ 11 Standard Time": "Asia/Kamchatka",
        "Eastern Standard Time": "America/New_York",
        "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Eastern Standard Time": "America/Indiana/Indianapolis",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Alaskan Standard Time": "America/Anchorage",
        "China Standard Time": "Asia/Shanghai",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "Singapore Standard Time": "Asia/Singapore",
        "India Standard Time": "Asia/Kolkata",
        "Iran Standard Time": "Asia/Tehran",
        "Arabian Standard Time": "Asia/Dubai",
        "Arab Standard Time": "Asia/Riyadh",
        "Israel Standard Time": "Asia/Jerusalem",
        "Egypt Standard Time": "Africa/Cairo",
        "South Africa Standard Time": "Africa/Johannesburg",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane",
        "Cen. Australia Standard Time": "Australia/Adelaide",
        "W. Australia Standard Time": "Australia/Perth",
        "New Zealand Standard Time": "Pacific/Auckland"
    ]

    static func lookup(displayName: String) -> String? {
        table[displayName]
    }
}
