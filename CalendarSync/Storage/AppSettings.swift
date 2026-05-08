import Foundation
import Combine

/// Plain-stored, user-configurable settings.
///
/// Password lives in `Keychain` and is never written to UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    @Published var host: String {
        didSet { defaults.set(host, forKey: Keys.host) }
    }

    /// Mailbox identity. Sent as `?User=` and shown as the account label.
    /// Typically an email address (`john@example.com`).
    @Published var email: String {
        didSet { defaults.set(email, forKey: Keys.email) }
    }

    /// AD short / NetBIOS domain name (e.g. `london`). Optional. When set, it
    /// is prefixed to the username for HTTP Basic auth as `domain\username`,
    /// exactly as iPhone Mail composes the credential when the user fills in
    /// separate Domain + Username fields. Leave empty if your server doesn't
    /// want a domain prefix.
    @Published var domain: String {
        didSet { defaults.set(domain, forKey: Keys.domain) }
    }

    /// AD samAccountName / username for HTTP Basic auth (e.g. `USER_2`). If
    /// `domain` is empty, this value is sent verbatim and may itself contain
    /// a `\`, `@` or any other shape your server expects.
    @Published var authLogin: String {
        didSet { defaults.set(authLogin, forKey: Keys.authLogin) }
    }

    /// Effective principal sent in `?User=` (always non-empty when configured).
    var effectiveEmail: String {
        email.isEmpty ? effectiveAuthLogin : email
    }

    /// Effective login sent in HTTP Basic. Composed as:
    ///   `<domain>\<authLogin>` when both parts are filled,
    ///   `<authLogin>` (verbatim) when domain is empty,
    ///   `<email>` as a last-resort fallback for the simplest servers.
    var effectiveAuthLogin: String {
        let user = authLogin.isEmpty ? email : authLogin
        if domain.isEmpty { return user }
        return "\(domain)\\\(user)"
    }

    /// Keychain account key. We bind to a stable id (the username + domain)
    /// so changing the email doesn't lose the saved password.
    var keychainAccount: String {
        if !authLogin.isEmpty {
            return domain.isEmpty ? authLogin : "\(domain)\\\(authLogin)"
        }
        return email
    }

    /// Full device fingerprint sent to the server. Initialised to a random
    /// iPhone profile on first launch and persisted as JSON.
    @Published var fingerprint: DeviceFingerprint {
        didSet { saveFingerprint() }
    }

    /// Convenience accessor: keeps existing call sites that just need the id.
    var deviceId: String { fingerprint.deviceId }

    /// Sync interval in seconds. Default 5 min.
    @Published var syncIntervalSeconds: Int {
        didSet { defaults.set(syncIntervalSeconds, forKey: Keys.syncInterval) }
    }

    @Published var autoSyncEnabled: Bool {
        didSet { defaults.set(autoSyncEnabled, forKey: Keys.autoSyncEnabled) }
    }

    /// Pinned EAS protocol version. Empty string == auto-detect via OPTIONS.
    @Published var pinnedProtocolVersion: String {
        didSet { defaults.set(pinnedProtocolVersion, forKey: Keys.pinnedVersion) }
    }

    /// When enabled, local Calendar.app alarms are forced for every synced
    /// event, regardless of the reminder value returned by Exchange.
    @Published var forceReminderEnabled: Bool {
        didSet { defaults.set(forceReminderEnabled, forKey: Keys.forceReminderEnabled) }
    }

    /// Minutes before event start. `0` means at start time.
    @Published var forcedReminderMinutes: Int {
        didSet { defaults.set(forcedReminderMinutes, forKey: Keys.forcedReminderMinutes) }
    }

    /// When enabled, meeting links found in the event body are copied into
    /// empty local location / URL fields.
    @Published var extractMeetingLinksEnabled: Bool {
        didSet { defaults.set(extractMeetingLinksEnabled, forKey: Keys.extractMeetingLinksEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyDefaultsIfNeeded(to: defaults)
        self.host = defaults.string(forKey: Keys.host) ?? ""

        // Migration: pre-split versions had a single `username` field used as
        // both principal and Basic-auth login. Seed both new fields from it
        // so existing users keep working without retyping. If the legacy or
        // saved auth login is in `domain\user` form and the domain field is
        // empty, split it across the new Domain + Username inputs so the new
        // four-field UI shows the values where the user actually expects to
        // see them.
        let legacyUsername = defaults.string(forKey: Keys.legacyUsername) ?? ""
        self.email = defaults.string(forKey: Keys.email) ?? legacyUsername

        let savedAuthLogin = defaults.string(forKey: Keys.authLogin) ?? legacyUsername
        let savedDomain = defaults.string(forKey: Keys.domain) ?? ""
        if savedDomain.isEmpty, savedAuthLogin.contains("\\") {
            let parts = savedAuthLogin.split(separator: "\\", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                self.domain = parts[0]
                self.authLogin = parts[1]
            } else {
                self.domain = ""
                self.authLogin = savedAuthLogin
            }
        } else {
            self.domain = savedDomain
            self.authLogin = savedAuthLogin
        }

        self.syncIntervalSeconds = defaults.object(forKey: Keys.syncInterval) as? Int ?? 300
        self.autoSyncEnabled = defaults.object(forKey: Keys.autoSyncEnabled) as? Bool ?? true
        self.pinnedProtocolVersion = defaults.string(forKey: Keys.pinnedVersion) ?? ""
        self.forceReminderEnabled = defaults.object(forKey: Keys.forceReminderEnabled) as? Bool ?? false
        self.forcedReminderMinutes = defaults.object(forKey: Keys.forcedReminderMinutes) as? Int ?? 5
        self.extractMeetingLinksEnabled = defaults.object(forKey: Keys.extractMeetingLinksEnabled) as? Bool ?? true

        // Try to restore an existing fingerprint. Migrate legacy deviceId-only
        // installs by preserving the id but pairing it with a fresh iPhone
        // profile so the server keeps the same device "row".
        if let data = defaults.data(forKey: Keys.fingerprint),
           let fp = try? JSONDecoder().decode(DeviceFingerprint.self, from: data) {
            self.fingerprint = fp
        } else {
            var fp = DeviceFingerprint.randomIPhone()
            if let legacyId = defaults.string(forKey: Keys.legacyDeviceId), !legacyId.isEmpty {
                fp.deviceId = legacyId
            }
            self.fingerprint = fp
            if let data = try? JSONEncoder().encode(fp) {
                defaults.set(data, forKey: Keys.fingerprint)
            }
        }
    }

    /// Replaces the current fingerprint with a fresh randomised iPhone profile.
    /// Note: this changes `DeviceId`, which from the server's POV is a brand new
    /// device — the next sync will be initial (FolderSync from `0`).
    func regenerateFingerprint() {
        fingerprint = DeviceFingerprint.randomIPhone()
    }

    /// Targeted edit (e.g. user wants to keep DeviceId but pick a new model).
    func mutateFingerprint(_ block: (inout DeviceFingerprint) -> Void) {
        var copy = fingerprint
        block(&copy)
        fingerprint = copy
    }

    private func saveFingerprint() {
        if let data = try? JSONEncoder().encode(fingerprint) {
            defaults.set(data, forKey: Keys.fingerprint)
        }
    }

    private static func migrateLegacyDefaultsIfNeeded(to defaults: UserDefaults) {
        let legacyBundleIdentifier = "com.mailclient.MailClient"
        guard Bundle.main.bundleIdentifier != legacyBundleIdentifier else { return }
        guard let legacyDefaults = UserDefaults(suiteName: "com.mailclient.MailClient") else { return }
        for key in Keys.all {
            guard defaults.object(forKey: key) == nil,
                  let legacyValue = legacyDefaults.object(forKey: key) else {
                continue
            }
            defaults.set(legacyValue, forKey: key)
        }
    }

    private enum Keys {
        static let host = "eas.host"
        static let email = "eas.email"
        static let domain = "eas.domain"
        static let authLogin = "eas.authLogin"
        static let legacyUsername = "eas.username"
        static let legacyDeviceId = "eas.deviceId"
        static let fingerprint = "eas.fingerprint"
        static let syncInterval = "eas.syncIntervalSeconds"
        static let autoSyncEnabled = "eas.autoSyncEnabled"
        static let pinnedVersion = "eas.pinnedProtocolVersion"
        static let forceReminderEnabled = "calendar.forceReminderEnabled"
        static let forcedReminderMinutes = "calendar.forcedReminderMinutes"
        static let extractMeetingLinksEnabled = "calendar.extractMeetingLinksEnabled"

        static let all = [
            host,
            email,
            domain,
            authLogin,
            legacyUsername,
            legacyDeviceId,
            fingerprint,
            syncInterval,
            autoSyncEnabled,
            pinnedVersion,
            forceReminderEnabled,
            forcedReminderMinutes,
            extractMeetingLinksEnabled
        ]
    }
}
