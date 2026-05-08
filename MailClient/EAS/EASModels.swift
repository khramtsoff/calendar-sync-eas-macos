import Foundation

enum EASError: Error, LocalizedError {
    case invalidHost(String)
    case http(Int, Data?)
    case authRequired(challenge: String?, bodyExcerpt: String?)
    case provisioningRequired
    case provisioningFailed(Int)
    case status(String, Int)             // command name, status code
    case noProtocolVersionsOffered
    case unexpectedResponse(String)
    case wbxml(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidHost(let h): return "Invalid host: \(h)"
        case .http(let code, _): return "HTTP \(code)"
        case .authRequired(let challenge, let body):
            var pieces: [String] = ["HTTP 401: server rejected credentials."]
            if let c = challenge, !c.isEmpty {
                pieces.append("WWW-Authenticate: \(c)")
            }
            if let scheme = primaryAuthScheme(from: challenge) {
                switch scheme.lowercased() {
                case "ntlm", "negotiate":
                    pieces.append("This server uses \(scheme), which this client does not support — it speaks Basic Auth only.")
                case "bearer":
                    pieces.append("Server expects an OAuth Bearer token; Basic Auth with a password will not work.")
                case "basic":
                    var hint = "Server accepts Basic. Common login formats to try:\n  • user@\(realm(from: challenge) ?? "domain")\n  • \(realm(from: challenge).map { $0.uppercased() + "\\user" } ?? "DOMAIN\\user")\n  • just  user  (no domain prefix)\nIf all formats fail, ActiveSync may be disabled for this mailbox (admin runs `Set-CASMailbox -ActiveSyncEnabled $true`)."
                    if let r = realm(from: challenge) {
                        hint += "\nServer realm: \(r)"
                    }
                    pieces.append(hint)
                default:
                    break
                }
            }
            if let b = body, !b.isEmpty {
                pieces.append("Body: \(b)")
            }
            return pieces.joined(separator: "\n")
        case .provisioningRequired: return "Server requires Provision before sync"
        case .provisioningFailed(let s): return "Provision failed (status \(s))"
        case .status(let cmd, let s): return "\(cmd) returned status \(s)"
        case .noProtocolVersionsOffered: return "Server didn't advertise MS-ASProtocolVersions"
        case .unexpectedResponse(let m): return "Unexpected EAS response: \(m)"
        case .wbxml(let e): return "WBXML: \(e.localizedDescription)"
        case .transport(let e): return "Transport: \(e.localizedDescription)"
        }
    }

    /// First token in `WWW-Authenticate`, e.g. "Basic", "NTLM", "Negotiate", "Bearer".
    private func primaryAuthScheme(from header: String?) -> String? {
        guard let header = header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    /// Extracts `realm="..."` value from a `WWW-Authenticate` header.
    private func realm(from header: String?) -> String? {
        guard let header = header else { return nil }
        guard let range = header.range(of: #"realm="([^"]+)""#, options: .regularExpression) else { return nil }
        let match = header[range]
        guard let inner = match.range(of: #""([^"]+)""#, options: .regularExpression) else { return nil }
        let quoted = match[inner]
        return String(quoted.dropFirst().dropLast())
    }
}

/// Result of an `OPTIONS /Microsoft-Server-ActiveSync` probe.
struct EASCapabilities: Equatable {
    let protocolVersions: [String]      // e.g. ["2.5","12.0","14.0","14.1"]
    let supportedCommands: [String]     // e.g. ["Sync","Provision","FolderSync"]
    let authChallenge: String?          // raw WWW-Authenticate header
    /// Best-effort: max version we both support, capped at 14.1 (we don't ship 16.x parsers).
    let chosenVersion: String?
}

/// One folder from a FolderSync response.
struct EASFolder: Equatable {
    let serverId: String
    let parentId: String
    let displayName: String
    let type: Int
}

/// FolderSync result.
struct EASFolderSyncResult {
    let newSyncKey: String
    let added: [EASFolder]
    let updated: [EASFolder]
    let deleted: [String]    // serverIds
    let status: Int
}

/// One change emitted by a Calendar Sync command.
enum EASChange {
    case add(serverId: String, item: EASCalendarItem)
    case change(serverId: String, item: EASCalendarItem)
    case delete(serverId: String)
}

struct EASSyncResult {
    let collectionId: String
    let newSyncKey: String
    let status: Int
    let changes: [EASChange]
    let moreAvailable: Bool
}

// MARK: - Calendar item model

/// Mid-fidelity calendar item parsed from EAS WBXML.
struct EASCalendarItem: Equatable {
    var subject: String?
    var location: String?
    var body: String?
    var organizerName: String?
    var organizerEmail: String?
    var startTime: Date?
    var endTime: Date?
    var allDay: Bool = false
    var dtStamp: Date?
    var uid: String?
    var timeZoneBlob: Data?              // raw EAS TimeZone field (base64-decoded)
    var resolvedTimeZone: TimeZone?
    var reminderMinutes: Int?
    var sensitivity: Int?
    var busyStatus: Int?
    var meetingStatus: Int?
    var responseRequested: Bool?
    var attendees: [EASAttendee] = []
    var categories: [String] = []
    var recurrence: EASRecurrence?
    var exceptions: [EASException] = []
}

struct EASAttendee: Equatable {
    var name: String?
    var email: String?
    /// 1=Unknown, 2=Tentative, 3=Accept, 4=Decline, 5=NotResponded
    var status: Int?
    /// 1=Required, 2=Optional, 3=Resource
    var type: Int?
}

struct EASException: Equatable {
    var deleted: Bool = false
    var startTime: Date?       // ExceptionStartTime: original occurrence time
    var item: EASCalendarItem? // override fields
}

/// EAS Recurrence (MS-ASCAL 2.2.2.45).
///
/// Recurrence Type:
///   0 = Daily
///   1 = Weekly
///   2 = Monthly (DayOfMonth)
///   3 = Monthly (WeekOfMonth + DayOfWeek)
///   5 = Yearly (DayOfMonth + MonthOfYear)
///   6 = Yearly (WeekOfMonth + DayOfWeek + MonthOfYear)
struct EASRecurrence: Equatable {
    var type: Int
    var interval: Int = 1
    /// Bitfield: 1=Sun, 2=Mon, 4=Tue, 8=Wed, 16=Thu, 32=Fri, 64=Sat, 127=Weekday-of-month special.
    var dayOfWeek: Int?
    var dayOfMonth: Int?
    var weekOfMonth: Int?
    var monthOfYear: Int?
    var firstDayOfWeek: Int?
    var occurrences: Int?
    var until: Date?
    var calendarType: Int?
    var isLeapMonth: Bool?
}
