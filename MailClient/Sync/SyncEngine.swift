import Foundation
import Combine

enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .syncing: return "Syncing…"
        case .error(let m): return "Error: \(m)"
        }
    }
}

/// High-level sync orchestrator. Owns the periodic timer, surfaces a
/// `@Published` status and last-sync metadata to the UI, and serializes
/// all sync work onto a single `Task`.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var negotiatedVersion: String?
    @Published private(set) var calendarFolders: [SyncState.FolderInfo] = []

    private let settings: AppSettings
    private let stateStore: SyncStateStore
    private let log: SyncLog
    private let bridge: CalendarBridge
    private let keychain: Keychain
    private var timer: Timer?
    private var inflight: Task<Void, Never>?

    init() {
        self.settings = .shared
        self.stateStore = .shared
        self.log = .shared
        self.bridge = CalendarBridge()
        self.keychain = Keychain()
        let snap = SyncStateStore.shared.snapshot()
        self.lastSyncAt = snap.lastSuccessfulSyncAt
        self.negotiatedVersion = snap.negotiatedProtocolVersion
        self.calendarFolders = snap.folders.filter { $0.isCalendar }
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inflight?.cancel()
        inflight = nil
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard settings.autoSyncEnabled else { return }
        let interval = TimeInterval(max(settings.syncIntervalSeconds, 30))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runOnce() }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    // MARK: - Public actions

    /// Triggers a sync. Coalesces back-to-back invocations.
    ///
    /// We tracked "in flight" via `Task.isCancelled` previously, which is
    /// wrong: a completed-but-not-cancelled `Task` still reports
    /// `isCancelled == false`, so the guard would lock out every subsequent
    /// click forever. Now we explicitly nil the slot when the task ends.
    func runOnce() {
        if inflight != nil {
            log.debug("Sync requested while one is in flight; ignoring.")
            return
        }
        let task = Task { [weak self] in
            await self?.performSync()
            self?.inflight = nil
        }
        inflight = task
    }

    /// Cancels the currently running sync (if any). Useful when the network
    /// stalls or the user wants to abort.
    func cancelInflight() {
        guard let task = inflight else { return }
        task.cancel()
        inflight = nil
        log.warn("Sync cancelled by user.")
        Task { await setStatus(.idle) }
    }

    /// Probe + return capabilities; used by the "Test connection" button.
    func probe() async -> Result<EASCapabilities, Error> {
        do {
            let client = try makeClient()
            let caps = try await client.probe()
            if let v = caps.chosenVersion {
                stateStore.mutate { $0.negotiatedProtocolVersion = v }
                negotiatedVersion = v
            }
            return .success(caps)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Reset / wipe

    func resetSyncKeys() {
        bridge.resetSyncKeys()
        log.info("SyncKey reset (events kept). Next sync will be initial.")
        let snap = stateStore.snapshot()
        calendarFolders = snap.folders.filter { $0.isCalendar }
    }

    /// Replaces the device fingerprint with a fresh randomised iPhone profile.
    /// Because `DeviceId` changes, the server treats us as a brand-new device,
    /// so we also reset every sync key locally to avoid 4xx-status mismatches.
    func regenerateFingerprint() {
        settings.regenerateFingerprint()
        bridge.resetSyncKeys()
        let fp = settings.fingerprint
        log.info("New fingerprint: \(fp.model) / \(fp.os) / id=\(fp.deviceId.prefix(8))…")
    }

    func wipeAllEvents() async {
        do {
            try bridge.wipeAllEvents()
            log.info("Wiped all events from dedicated calendar.")
        } catch {
            log.error("Wipe failed: \(error.localizedDescription)")
        }
    }

    func deleteCalendar() async {
        do {
            try bridge.deleteCalendar()
            log.info("Deleted dedicated calendar and full sync state.")
            calendarFolders = []
            lastSyncAt = nil
            negotiatedVersion = nil
        } catch {
            log.error("Delete calendar failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func makeClient() throws -> EASClient {
        let pwd = (try? keychain.password(account: settings.keychainAccount)) ?? ""
        return try EASClient(
            host: settings.host,
            principal: settings.effectiveEmail,
            authLogin: settings.effectiveAuthLogin,
            password: pwd,
            fingerprint: settings.fingerprint
        )
    }

    private func performSync() async {
        guard !settings.host.isEmpty, !settings.effectiveEmail.isEmpty else {
            await setStatus(.error("Configure host & email in Settings."))
            return
        }
        guard let _ = try? keychain.password(account: settings.keychainAccount) else {
            await setStatus(.error("No password stored for \(settings.keychainAccount)."))
            return
        }

        do {
            try await bridge.requestAccess()
        } catch {
            await setStatus(.error("Calendar access denied."))
            log.error(error.localizedDescription)
            return
        }

        await setStatus(.syncing)
        log.info("Sync started.")

        do {
            let client = try makeClient()
            let version = try await negotiateVersion(client: client)
            negotiatedVersion = version
            stateStore.mutate { $0.negotiatedProtocolVersion = version }

            try await ensureProvisioned(client: client, version: version)
            try await runFolderSync(client: client, version: version)
            try await runCalendarSyncs(client: client, version: version)

            let now = Date()
            stateStore.mutate { $0.lastSuccessfulSyncAt = now }
            lastSyncAt = now
            await setStatus(.idle)
            log.info("Sync complete.")
        } catch {
            await setStatus(.error(error.localizedDescription))
            log.error("Sync failed: \(error.localizedDescription)")
        }
    }

    private func negotiateVersion(client: EASClient) async throws -> String {
        if !settings.pinnedProtocolVersion.isEmpty {
            return settings.pinnedProtocolVersion
        }
        if let cached = stateStore.snapshot().negotiatedProtocolVersion, !cached.isEmpty {
            return cached
        }
        let caps = try await client.probe()
        if let v = caps.chosenVersion { return v }
        throw EASError.noProtocolVersionsOffered
    }

    private func ensureProvisioned(client: EASClient, version: String) async throws {
        let snap = stateStore.snapshot()
        if snap.policyKey != "0" { return }
        log.info("Provisioning…")
        let key = try await client.provision(protocolVersion: version)
        stateStore.mutate { $0.policyKey = key }
    }

    private func runFolderSync(client: EASClient, version: String) async throws {
        let snap = stateStore.snapshot()
        let result = try await client.folderSync(
            protocolVersion: version,
            policyKey: snap.policyKey,
            syncKey: snap.folderHierarchySyncKey
        )

        if result.status != 1 {
            throw EASError.status("FolderSync", result.status)
        }

        stateStore.mutate { state in
            state.folderHierarchySyncKey = result.newSyncKey
            for f in result.added {
                state.folders.removeAll { $0.serverId == f.serverId }
                state.folders.append(.init(serverId: f.serverId, parentId: f.parentId,
                                           displayName: f.displayName, type: f.type))
            }
            for f in result.updated {
                state.folders.removeAll { $0.serverId == f.serverId }
                state.folders.append(.init(serverId: f.serverId, parentId: f.parentId,
                                           displayName: f.displayName, type: f.type))
            }
            for id in result.deleted {
                state.folders.removeAll { $0.serverId == id }
                state.folderSyncKeys.removeValue(forKey: id)
            }
        }
        let after = stateStore.snapshot()
        calendarFolders = after.folders.filter { $0.isCalendar }
        log.info("FolderSync OK (folders: \(after.folders.count), calendars: \(self.calendarFolders.count))")
    }

    private func runCalendarSyncs(client: EASClient, version: String) async throws {
        let folders = stateStore.snapshot().folders.filter { $0.isCalendar }
        for folder in folders {
            try await syncFolder(client: client, version: version, folder: folder)
        }
    }

    private func syncFolder(client: EASClient, version: String, folder: SyncState.FolderInfo) async throws {
        let collectionId = folder.serverId
        var syncKey = stateStore.snapshot().folderSyncKeys[collectionId] ?? "0"
        var safetyCounter = 0
        var includeClass = false

        if syncKey == "0" {
            // Initial Sync handshake: server returns no items, only a fresh SyncKey.
            //
            // Some Exchange deployments (2010/2013 Hub and certain 2019 CAS
            // configurations) reject 14.x initial Sync without `Class` with
            // status 4 (protocol error). Detect that and retry once with
            // `<Class>Calendar</Class>` added.
            var initial = try await client.sync(
                collectionId: collectionId,
                syncKey: "0",
                protocolVersion: version,
                policyKey: stateStore.snapshot().policyKey,
                includeClass: false
            )
            if let r = initial, r.status == 4 {
                log.warn("\(folder.displayName): initial Sync got status 4; retrying with <Class>Calendar</Class>.")
                includeClass = true
                initial = try await client.sync(
                    collectionId: collectionId,
                    syncKey: "0",
                    protocolVersion: version,
                    policyKey: stateStore.snapshot().policyKey,
                    includeClass: true
                )
            }
            guard let r = initial else { throw EASError.unexpectedResponse("Empty initial Sync response") }
            switch EASStatus.classify(r.status) {
            case .success:
                syncKey = r.newSyncKey
                stateStore.mutate { $0.folderSyncKeys[collectionId] = syncKey }
            default:
                throw EASError.status("Sync(initial)", r.status)
            }
        }

        repeat {
            safetyCounter += 1
            if safetyCounter > 50 {
                log.warn("Safety stop after 50 Sync iterations on \(folder.displayName)")
                return
            }
            let result = try await client.sync(
                collectionId: collectionId,
                syncKey: syncKey,
                protocolVersion: version,
                policyKey: stateStore.snapshot().policyKey,
                includeClass: includeClass
            )
            guard let r = result else {
                log.info("\(folder.displayName): no changes.")
                return
            }

            switch EASStatus.classify(r.status) {
            case .success:
                if !r.changes.isEmpty {
                    try bridge.apply(r.changes)
                    log.info("\(folder.displayName): applied \(r.changes.count) change(s).")
                }
                syncKey = r.newSyncKey
                stateStore.mutate { $0.folderSyncKeys[collectionId] = syncKey }
                if !r.moreAvailable { return }
            case .syncKeyInvalid:
                log.warn("\(folder.displayName): SyncKey invalid - resetting and retrying once.")
                stateStore.mutate { $0.folderSyncKeys[collectionId] = "0" }
                return
            case .provisioningNeeded:
                let key = try await client.provision(protocolVersion: version)
                stateStore.mutate { $0.policyKey = key }
            default:
                throw EASError.status("Sync(\(folder.displayName))", r.status)
            }
        } while true
    }

    private func setStatus(_ s: SyncStatus) async {
        self.status = s
    }
}
