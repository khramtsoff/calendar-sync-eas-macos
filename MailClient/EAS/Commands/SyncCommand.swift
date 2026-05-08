import Foundation

/// EAS Sync (MS-ASCMD 2.2.1.21) for a single Calendar collection.
///
/// We always request `Class = Calendar`, a 4-week filter, and HTML body
/// preference (most servers honour this and clients prefer rich text).
enum SyncCommand {

    /// Filter type 5 = 2 weeks back. We use 6 (1 month) by default which is a
    /// good trade-off for "actual meetings". MS-ASCMD §2.2.3.71.1.
    static let defaultFilterType = 6

    static func makeBody(collectionId: String,
                         syncKey: String,
                         windowSize: Int = 100,
                         filterType: Int = defaultFilterType,
                         protocolVersion: String = "14.1",
                         includeClass: Bool = false) throws -> Data {
        let isInitial = (syncKey == "0")

        var collectionChildren: [WBXMLNode] = [
            WBXMLBuilder.leaf(.airSync, "SyncKey", syncKey),
            WBXMLBuilder.leaf(.airSync, "CollectionId", collectionId)
        ]

        // `Class` placement matrix per MS-ASCMD §2.2.3.27:
        //   • 14.0 / 14.1 / 16.x: Class MUST NOT be present.
        //   • 12.1, non-initial:  Class is required (we always add).
        //   • 12.1, initial:      Class is optional, and many Exchange
        //     deployments treat its presence as a protocol error (top-level
        //     Status 4). So we omit by default on initial; the engine can
        //     ask us to include it via `includeClass: true` as a fallback.
        let shouldIncludeClass: Bool = {
            if includeClass { return true }
            if isInitial { return false }
            return protocolVersion.hasPrefix("12.")
        }()
        if shouldIncludeClass {
            collectionChildren.insert(WBXMLBuilder.leaf(.airSync, "Class", "Calendar"), at: 0)
        }

        if !isInitial {
            // Initial Sync MUST NOT include GetChanges/Options per spec; servers
            // will reject. Subsequent calls can.
            //
            // `<GetChanges/>` MUST be a self-closing element. If we emitted it
            // as an element with an empty STR_I child the WBXML on the wire
            // would be `53 03 00 01` (open + STR_I "" + null + end) which
            // Exchange rejects with top-level Status 4. The empty-children
            // form encodes as `53` only — exactly what the server expects.
            collectionChildren.append(WBXMLBuilder.el(.airSync, "GetChanges", []))
            collectionChildren.append(WBXMLBuilder.leaf(.airSync, "WindowSize", String(windowSize)))

            // BodyPreference (AirSyncBase) only makes sense for protocol
            // version 14.0+. On 12.x calendar collections, sending an
            // AirSyncBase block inside Options is rejected as malformed.
            if !protocolVersion.hasPrefix("12.") {
                collectionChildren.append(WBXMLBuilder.el(.airSync, "Options", [
                    WBXMLBuilder.leaf(.airSync, "FilterType", String(filterType)),
                    WBXMLBuilder.el(.airSyncBase, "BodyPreference", [
                        WBXMLBuilder.leaf(.airSyncBase, "Type", "1"),  // 1 = plain text
                        WBXMLBuilder.leaf(.airSyncBase, "TruncationSize", "32768")
                    ])
                ]))
            } else {
                // 12.x: just FilterType, no BodyPreference. EAS 12.x carries
                // calendar Body as a top-level <Body> string in Calendar
                // codepage, which the parser handles separately.
                collectionChildren.append(WBXMLBuilder.el(.airSync, "Options", [
                    WBXMLBuilder.leaf(.airSync, "FilterType", String(filterType))
                ]))
            }
        }

        let root = WBXMLBuilder.el(.airSync, "Sync", [
            WBXMLBuilder.el(.airSync, "Collections", [
                WBXMLBuilder.el(.airSync, "Collection", collectionChildren)
            ])
        ])
        return try WBXMLEncoder.encode(root)
    }

    /// Parse a Sync response. Returns nil for the special "no changes / 204
    /// No Content" path which servers signal as an empty body on 14.1+.
    static func parse(_ data: Data) throws -> EASSyncResult? {
        if data.isEmpty { return nil }
        let root: WBXMLNode
        do {
            root = try WBXMLDecoder.decode(data)
        } catch {
            throw EASError.wbxml(error)
        }

        // The Status at <Sync> level may exist; per-collection status lives
        // inside the Collection node. We surface the collection status.
        guard let collections = root.child(.airSync, "Collections"),
              let collection = collections.child(.airSync, "Collection") else {
            // Some servers reply only with top-level status (e.g. invalid syncKey).
            let topStatus = Int(root.string(.airSync, "Status") ?? "0") ?? 0
            if topStatus != 0 {
                return EASSyncResult(collectionId: "",
                                     newSyncKey: "0",
                                     status: topStatus,
                                     changes: [],
                                     moreAvailable: false)
            }
            throw EASError.unexpectedResponse("Sync response without Collection")
        }

        let collectionId = collection.string(.airSync, "CollectionId") ?? ""
        let newKey = collection.string(.airSync, "SyncKey") ?? "0"
        let status = Int(collection.string(.airSync, "Status") ?? "0") ?? 0
        let moreAvailable = collection.child(.airSync, "MoreAvailable") != nil

        var changes: [EASChange] = []
        if let cmds = collection.child(.airSync, "Commands") {
            for child in cmds.children {
                guard case .element(let name, _) = child, name.page == .airSync else { continue }
                switch name.name {
                case "Add", "Change":
                    guard let serverId = child.string(.airSync, "ServerId") else { continue }
                    let appData = child.child(.airSync, "ApplicationData")
                    let item = appData.map(EASCalendarParser.parse) ?? EASCalendarItem()
                    if name.name == "Add" {
                        changes.append(.add(serverId: serverId, item: item))
                    } else {
                        changes.append(.change(serverId: serverId, item: item))
                    }
                case "Delete", "SoftDelete":
                    if let serverId = child.string(.airSync, "ServerId") {
                        changes.append(.delete(serverId: serverId))
                    }
                default:
                    break
                }
            }
        }

        return EASSyncResult(
            collectionId: collectionId,
            newSyncKey: newKey,
            status: status,
            changes: changes,
            moreAvailable: moreAvailable
        )
    }
}
