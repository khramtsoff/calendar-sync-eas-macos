import Foundation

/// EAS code pages we need for calendar-only sync. Tag codes are taken from
/// MS-ASWBXML §2.1.2.
///
/// Pages we don't enumerate (Email, Contacts, Tasks, ...) are still parsed
/// safely - the decoder will switch to them and emit unknown tags as
/// `WBXMLNode.element("unknown_<code>")` which higher layers ignore.
enum WBXMLCodepage: UInt8 {
    case airSync = 0          // AirSync
    case contacts = 1
    case email = 2
    case airNotify = 3
    case calendar = 4         // Calendar
    case move = 5
    case getItemEstimate = 6
    case folderHierarchy = 7  // FolderHierarchy
    case meetingResponse = 8
    case tasks = 9
    case resolveRecipients = 10
    case validateCert = 11
    case contacts2 = 12
    case ping = 13
    case provision = 14       // Provision
    case search = 15
    case gal = 16
    case airSyncBase = 17     // AirSyncBase (Body, Attachments)
    case settings = 18        // Settings
    case documentLibrary = 19
    case itemOperations = 20
    case composeMail = 21
    case email2 = 22
    case notes = 23
    case rightsManagement = 24
    case find = 25
}

struct WBXMLTagDictionary {
    /// `[name -> code]` per page.
    let nameToCode: [WBXMLCodepage: [String: UInt8]]
    /// `[code -> name]` per page.
    let codeToName: [WBXMLCodepage: [UInt8: String]]

    static let shared: WBXMLTagDictionary = {
        var n2c: [WBXMLCodepage: [String: UInt8]] = [:]
        var c2n: [WBXMLCodepage: [UInt8: String]] = [:]
        for (page, tags) in tables {
            var pageN2C: [String: UInt8] = [:]
            var pageC2N: [UInt8: String] = [:]
            for (code, name) in tags {
                pageN2C[name] = code
                pageC2N[code] = name
            }
            n2c[page] = pageN2C
            c2n[page] = pageC2N
        }
        return WBXMLTagDictionary(nameToCode: n2c, codeToName: c2n)
    }()

    func code(for tag: String, page: WBXMLCodepage) -> UInt8? {
        nameToCode[page]?[tag]
    }

    func name(for code: UInt8, page: WBXMLCodepage) -> String? {
        codeToName[page]?[code]
    }
}

// MARK: - Tag tables

/// Subset of MS-ASWBXML tag tables. Codes are the low 6 bits of the wire token
/// (the WITH_CONTENT bit 0x40 is added at encode time when the element has
/// children).
private let tables: [WBXMLCodepage: [(UInt8, String)]] = [
    .airSync: [
        (0x05, "Sync"),
        (0x06, "Responses"),
        (0x07, "Add"),
        (0x08, "Change"),
        (0x09, "Delete"),
        (0x0A, "Fetch"),
        (0x0B, "SyncKey"),
        (0x0C, "ClientId"),
        (0x0D, "ServerId"),
        (0x0E, "Status"),
        (0x0F, "Collection"),
        (0x10, "Class"),
        (0x12, "CollectionId"),
        (0x13, "GetChanges"),
        (0x14, "MoreAvailable"),
        (0x15, "WindowSize"),
        (0x16, "Commands"),
        (0x17, "Options"),
        (0x18, "FilterType"),
        (0x1B, "Conflict"),
        (0x1C, "Collections"),
        (0x1D, "ApplicationData"),
        (0x1E, "DeletesAsMoves"),
        (0x20, "Supported"),
        (0x21, "SoftDelete"),
        (0x22, "MIMESupport"),
        (0x23, "MIMETruncation"),
        (0x24, "Wait"),
        (0x25, "Limit"),
        (0x26, "Partial"),
        (0x27, "ConversationMode"),
        (0x28, "MaxItems"),
        (0x29, "HeartbeatInterval")
    ],
    .calendar: [
        (0x05, "TimeZone"),
        (0x06, "AllDayEvent"),
        (0x07, "Attendees"),
        (0x08, "Attendee"),
        (0x09, "Email"),
        (0x0A, "Name"),
        (0x0D, "BusyStatus"),
        (0x0E, "Categories"),
        (0x0F, "Category"),
        (0x11, "DtStamp"),
        (0x12, "EndTime"),
        (0x13, "Exception"),
        (0x14, "Exceptions"),
        (0x15, "Deleted"),
        (0x16, "ExceptionStartTime"),
        (0x17, "Location"),
        (0x18, "MeetingStatus"),
        (0x19, "OrganizerEmail"),
        (0x1A, "OrganizerName"),
        (0x1B, "Recurrence"),
        (0x1C, "Type"),
        (0x1D, "Until"),
        (0x1E, "Occurrences"),
        (0x1F, "Interval"),
        (0x20, "DayOfWeek"),
        (0x21, "DayOfMonth"),
        (0x22, "WeekOfMonth"),
        (0x23, "MonthOfYear"),
        (0x24, "Reminder"),
        (0x25, "Sensitivity"),
        (0x26, "Subject"),
        (0x27, "StartTime"),
        (0x28, "UID"),
        (0x29, "AttendeeStatus"),
        (0x2A, "AttendeeType"),
        (0x33, "DisallowNewTimeProposal"),
        (0x34, "ResponseRequested"),
        (0x35, "AppointmentReplyTime"),
        (0x36, "ResponseType"),
        (0x37, "CalendarType"),
        (0x38, "IsLeapMonth"),
        (0x39, "FirstDayOfWeek"),
        (0x3A, "OnlineMeetingConfLink"),
        (0x3B, "OnlineMeetingExternalLink"),
        (0x3C, "ClientUid")
    ],
    .folderHierarchy: [
        (0x07, "DisplayName"),
        (0x08, "ServerId"),
        (0x09, "ParentId"),
        (0x0A, "Type"),
        (0x0C, "Status"),
        (0x0E, "Changes"),
        (0x0F, "Add"),
        (0x10, "Delete"),
        (0x11, "Update"),
        (0x12, "SyncKey"),
        (0x13, "FolderCreate"),
        (0x14, "FolderDelete"),
        (0x15, "FolderUpdate"),
        (0x16, "FolderSync"),
        (0x17, "Count")
    ],
    .provision: [
        (0x05, "Provision"),
        (0x06, "Policies"),
        (0x07, "Policy"),
        (0x08, "PolicyType"),
        (0x09, "PolicyKey"),
        (0x0A, "Data"),
        (0x0B, "Status"),
        (0x0C, "RemoteWipe"),
        (0x0D, "EASProvisionDoc"),
        (0x0E, "DevicePasswordEnabled"),
        (0x18, "DeviceInformation"),
        (0x19, "Model"),
        (0x1A, "IMEI"),
        (0x1B, "FriendlyName"),
        (0x1C, "OS"),
        (0x1D, "OSLanguage"),
        (0x1E, "PhoneNumber"),
        (0x1F, "UserAgent"),
        (0x20, "EnableOutboundSMS"),
        (0x21, "MobileOperator"),
        (0x22, "PrimarySmtpAddress"),
        (0x23, "Mos"),
        (0x24, "SetInformation")
    ],
    .settings: [
        (0x05, "Settings"),
        (0x06, "Status"),
        (0x07, "Get"),
        (0x08, "Set"),
        (0x09, "Oof"),
        (0x0A, "OofState"),
        (0x12, "DevicePassword"),
        (0x13, "Password"),
        (0x14, "DeviceInformation"),
        (0x15, "Model"),
        (0x16, "IMEI"),
        (0x17, "FriendlyName"),
        (0x18, "OS"),
        (0x19, "OSLanguage"),
        (0x1A, "PhoneNumber"),
        (0x1B, "UserInformation"),
        (0x1C, "EmailAddresses"),
        (0x1D, "SmtpAddress"),
        (0x1E, "UserAgent"),
        (0x1F, "EnableOutboundSMS"),
        (0x20, "MobileOperator"),
        (0x21, "PrimarySmtpAddress"),
        (0x22, "Accounts"),
        (0x23, "Account"),
        (0x24, "AccountId"),
        (0x25, "AccountName"),
        (0x26, "UserDisplayName"),
        (0x27, "SendDisabled"),
        (0x29, "RightsManagementInformation")
    ],
    .airSyncBase: [
        (0x05, "BodyPreference"),
        (0x06, "Type"),
        (0x07, "TruncationSize"),
        (0x08, "AllOrNone"),
        (0x0A, "Body"),
        (0x0B, "Data"),
        (0x0C, "EstimatedDataSize"),
        (0x0D, "Truncated"),
        (0x0E, "Attachments"),
        (0x0F, "Attachment"),
        (0x10, "DisplayName"),
        (0x11, "FileReference"),
        (0x12, "Method"),
        (0x13, "ContentId"),
        (0x14, "ContentLocation"),
        (0x15, "IsInline"),
        (0x16, "NativeBodyType"),
        (0x17, "ContentType"),
        (0x18, "Preview"),
        (0x19, "BodyPartPreference"),
        (0x1A, "BodyPart"),
        (0x1B, "Status")
    ]
]

/// Special WBXML tokens (MS-ASWBXML 2.1.2.1).
enum WBXMLToken {
    static let switchPage: UInt8 = 0x00
    static let end: UInt8       = 0x01
    static let entity: UInt8    = 0x02
    static let str_i: UInt8     = 0x03  // inline NUL-terminated UTF-8
    static let literal: UInt8   = 0x04
    static let opaque: UInt8    = 0xC3  // mb_u_int32 length + bytes
    static let withContent: UInt8 = 0x40
    static let withAttrs: UInt8 = 0x80
}
