import Foundation
import os

/// Persistent sync state: PolicyKey, FolderHierarchy SyncKey, per-folder SyncKey,
/// dedicated EKCalendar identifier, and EAS ServerId -> EKEvent identifier mapping.
///
/// Stored as a single JSON file under Application Support so it can be wiped
/// atomically by `SyncEngine.deleteCalendar()`.
struct SyncState: Codable, Equatable {
    /// Returned by Provision after Phase 2 ack. "0" means unprovisioned.
    var policyKey: String = "0"

    /// SyncKey for the FolderSync command (folder hierarchy itself).
    var folderHierarchySyncKey: String = "0"

    /// Per-EAS-folder SyncKey. "0" triggers an initial sync that returns no items.
    var folderSyncKeys: [String: String] = [:]

    /// EAS folder metadata cached from FolderSync (for UI / re-resolution).
    var folders: [FolderInfo] = []

    /// EAS ServerId -> EventKit calendar item identifier. EventKit owns this
    /// identifier, so it is persisted after the event is saved.
    var serverIdToEventExternalId: [String: String] = [:]

    /// Identifier of the dedicated `EKCalendar` we mirror events into.
    var dedicatedCalendarIdentifier: String?

    var lastSuccessfulSyncAt: Date?

    /// Last detected EAS protocol version (e.g. "14.1").
    var negotiatedProtocolVersion: String?

    struct FolderInfo: Codable, Equatable, Identifiable {
        var id: String { serverId }
        let serverId: String
        let parentId: String
        let displayName: String
        let type: Int
        var isCalendar: Bool {
            // EAS FolderHierarchy types for calendar folders.
            //   8: DefaultCalendarFolder
            //  13: UserCreatedCalendarFolder
            //  15: UserCreatedGenericFolder containing calendar items (rare)
            return type == 8 || type == 13
        }
    }
}

/// Persists `SyncState` under `~/Library/Application Support/MailClient/sync-state.json`.
final class SyncStateStore {
    static let shared = SyncStateStore()

    private let log = Logger(subsystem: "com.mailclient.MailClient", category: "SyncStateStore")
    private let queue = DispatchQueue(label: "com.mailclient.SyncStateStore", qos: .utility)
    private let fileURL: URL
    private var cached: SyncState

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.cached = Self.load(from: url)
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("MailClient", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync-state.json")
    }

    private static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        do {
            return try JSONDecoder().decode(SyncState.self, from: data)
        } catch {
            return SyncState()
        }
    }

    /// Snapshot. Reads are inexpensive; for atomic edits use `mutate`.
    func snapshot() -> SyncState {
        queue.sync { cached }
    }

    /// Mutates state in place and persists. Returns the new value.
    @discardableResult
    func mutate(_ block: (inout SyncState) -> Void) -> SyncState {
        queue.sync {
            block(&cached)
            persistLocked()
            return cached
        }
    }

    /// Replaces the whole state (used by hard-reset).
    func replace(with newState: SyncState) {
        queue.sync {
            cached = newState
            persistLocked()
        }
    }

    private func persistLocked() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cached)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to persist sync state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
