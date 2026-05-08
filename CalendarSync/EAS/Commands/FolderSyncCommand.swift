import Foundation

/// EAS FolderSync (MS-ASCMD 2.2.1.7) - retrieves and incrementally updates
/// the user's folder hierarchy.
enum FolderSyncCommand {
    static func makeBody(syncKey: String) throws -> Data {
        let root = WBXMLBuilder.el(.folderHierarchy, "FolderSync", [
            WBXMLBuilder.leaf(.folderHierarchy, "SyncKey", syncKey)
        ])
        return try WBXMLEncoder.encode(root)
    }

    static func parse(_ data: Data) throws -> EASFolderSyncResult {
        let root: WBXMLNode
        do {
            root = try WBXMLDecoder.decode(data)
        } catch {
            throw EASError.wbxml(error)
        }
        let status = Int(root.string(.folderHierarchy, "Status") ?? "0") ?? 0
        let newKey = root.string(.folderHierarchy, "SyncKey") ?? "0"
        var added: [EASFolder] = []
        var updated: [EASFolder] = []
        var deleted: [String] = []

        if let changes = root.child(.folderHierarchy, "Changes") {
            for child in changes.children {
                guard case .element(let name, _) = child else { continue }
                guard name.page == .folderHierarchy else { continue }
                switch name.name {
                case "Add":
                    if let f = parseFolder(child) { added.append(f) }
                case "Update":
                    if let f = parseFolder(child) { updated.append(f) }
                case "Delete":
                    if let id = child.string(.folderHierarchy, "ServerId") { deleted.append(id) }
                default:
                    break
                }
            }
        }

        return EASFolderSyncResult(
            newSyncKey: newKey,
            added: added,
            updated: updated,
            deleted: deleted,
            status: status
        )
    }

    private static func parseFolder(_ node: WBXMLNode) -> EASFolder? {
        guard let serverId = node.string(.folderHierarchy, "ServerId"),
              let displayName = node.string(.folderHierarchy, "DisplayName"),
              let typeStr = node.string(.folderHierarchy, "Type"),
              let type = Int(typeStr) else { return nil }
        let parent = node.string(.folderHierarchy, "ParentId") ?? "0"
        return EASFolder(serverId: serverId, parentId: parent, displayName: displayName, type: type)
    }
}
