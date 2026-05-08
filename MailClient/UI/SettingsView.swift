import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var log: SyncLog

    @State private var password: String = ""
    @State private var passwordLoaded = false
    @State private var probeMessage: String?
    @State private var probeIsError: Bool = false
    @State private var saveStatus: String?
    @State private var dangerAction: DangerAction?
    @State private var showRegenerateConfirm = false

    private let keychain = Keychain()

    var body: some View {
        TabView {
            accountTab.tabItem { Label("Account", systemImage: "person.circle") }
            syncTab.tabItem    { Label("Sync",    systemImage: "arrow.triangle.2.circlepath") }
            logTab.tabItem     { Label("Log",     systemImage: "text.alignleft") }
            advancedTab.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .padding(20)
        .task { loadPasswordOnce() }
    }

    // MARK: - Account

    private var accountTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exchange ActiveSync server").font(.headline)

            Form {
                TextField("Host", text: $settings.host, prompt: Text("owa.domain.com"))
                    .help("EAS endpoint hostname. The /Microsoft-Server-ActiveSync path is appended automatically.")
                TextField("Email", text: $settings.email, prompt: Text("user@domain.com"))
                    .help("Mailbox identity. Sent as ?User= URL parameter. Usually an SMTP address.")
                TextField("Domain", text: $settings.domain, prompt: Text("london (optional)"))
                    .help("AD short / NetBIOS domain name, exactly as iPhone Mail asks for it. Lowercase usually matches what the server expects. Leave empty if your server doesn't want a domain prefix.")
                TextField("Username", text: $settings.authLogin, prompt: Text("USER_2"))
                    .help("AD samAccountName. Combined with Domain as `domain\\username` for HTTP Basic auth, exactly like the iPhone.")
                SecureField("Password", text: $password, prompt: Text("Password"))
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save credentials") { savePassword() }
                Button("Test connection")  { testConnection() }
                    .disabled(settings.host.isEmpty || settings.effectiveEmail.isEmpty || password.isEmpty)
                if let s = saveStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let m = probeMessage {
                Text(m)
                    .font(.callout)
                    .foregroundStyle(probeIsError ? .red : .secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(probeIsError ? Color.red.opacity(0.1) : Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()
        }
    }

    // MARK: - Sync

    private var syncTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync schedule").font(.headline)

            Toggle("Enable periodic sync", isOn: $settings.autoSyncEnabled)
                .onChange(of: settings.autoSyncEnabled) { engine.scheduleTimer() }

            HStack {
                Text("Interval")
                Picker("", selection: $settings.syncIntervalSeconds) {
                    Text("1 min").tag(60)
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                    Text("1 hour").tag(3600)
                }
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: settings.syncIntervalSeconds) { engine.scheduleTimer() }
            }

            Divider()

            Text("Status").font(.headline)
            row("Status", engine.status.label)
            row("Protocol", engine.negotiatedVersion ?? "—")
            row("Last sync", engine.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Never")
            row("Calendars", engine.calendarFolders.isEmpty ? "—" :
                engine.calendarFolders.map(\.displayName).joined(separator: ", "))

            HStack {
                Button("Sync now") { engine.runOnce() }
                    .disabled(engine.status == .syncing)
            }

            Spacer()
        }
    }

    // MARK: - Log

    private var logTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent activity").font(.headline)
                Spacer()
                Button("Clear") { log.clear() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(log.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(timeString(entry.timestamp))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.level.rawValue.uppercased())
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 44, alignment: .leading)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: .infinity)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: log.entries.count) {
                    if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Advanced (Danger zone)

    private var advancedTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Protocol").font(.headline)
            HStack {
                Text("Pinned EAS version")
                Picker("", selection: $settings.pinnedProtocolVersion) {
                    Text("Auto-detect").tag("")
                    Text("14.1").tag("14.1")
                    Text("14.0").tag("14.0")
                    Text("12.1").tag("12.1")
                }
                .labelsHidden()
                .frame(width: 160)
            }

            Divider()

            Text("Reminders").font(.headline)
            Toggle("Remind about every synced event", isOn: $settings.forceReminderEnabled)
            HStack {
                Text("Alert")
                Picker("", selection: $settings.forcedReminderMinutes) {
                    Text("At event time").tag(0)
                    Text("1 minute before").tag(1)
                    Text("5 minutes before").tag(5)
                }
                .labelsHidden()
                .frame(width: 180)
                .disabled(!settings.forceReminderEnabled)
            }

            Divider()

            deviceFingerprintSection

            Divider()

            Text("Local calendar").font(.headline)
            Text("These actions affect only the dedicated 'Exchange (synced)' calendar created by this app. Your other calendars are not touched.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Re-sync") { dangerAction = .reSync }
                Button("Wipe events") { dangerAction = .wipeEvents }
                Button(role: .destructive) { dangerAction = .deleteCalendar } label: {
                    Text("Delete calendar")
                }
            }
            .confirmationDialog(
                dangerAction?.title ?? "",
                isPresented: Binding(get: { dangerAction != nil }, set: { if !$0 { dangerAction = nil } }),
                titleVisibility: .visible,
                actions: {
                    if let action = dangerAction {
                        Button(action.confirmLabel, role: action.role) { perform(action) }
                    }
                    Button("Cancel", role: .cancel) {}
                },
                message: { Text(dangerAction?.message ?? "") }
            )

            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var deviceFingerprintSection: some View {
        let fp = settings.fingerprint
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Device fingerprint").font(.headline)
                Spacer()
                Button {
                    showRegenerateConfirm = true
                } label: {
                    Label("Regenerate", systemImage: "die.face.5")
                }
            }

            Text("EAS sees this Mac as the iPhone profile below. Regenerating produces a fresh DeviceId and picks a new model/OS combo; the next sync will be initial.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                fpRow("DeviceId",     fp.deviceId)
                fpRow("DeviceType",   fp.deviceType)
                fpRow("Model",        fp.model)
                fpRow("OS",           fp.os)
                fpRow("Language",     fp.osLanguage)
                fpRow("User-Agent",   fp.userAgent)
                fpRow("FriendlyName", fp.friendlyName)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .confirmationDialog(
            "Regenerate device fingerprint?",
            isPresented: $showRegenerateConfirm,
            titleVisibility: .visible,
            actions: {
                Button("Regenerate") {
                    engine.regenerateFingerprint()
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("A new DeviceId and a random iPhone model/OS will be assigned. The server will treat this Mac as a brand-new device, so all SyncKeys are reset; the next sync will be initial.")
            }
        )
    }

    @ViewBuilder
    private func fpRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
    }

    // MARK: - Helpers

    private enum DangerAction: Identifiable {
        case reSync, wipeEvents, deleteCalendar
        var id: String { String(describing: self) }
        var title: String {
            switch self {
            case .reSync: return "Re-sync from scratch?"
            case .wipeEvents: return "Wipe all synced events?"
            case .deleteCalendar: return "Delete the synced calendar?"
            }
        }
        var message: String {
            switch self {
            case .reSync:
                return "Resets SyncKey only. Existing events stay; the next sync will be initial."
            case .wipeEvents:
                return "Removes every event from the dedicated calendar and resets SyncKey. The calendar container is kept."
            case .deleteCalendar:
                return "Removes the dedicated calendar entirely and clears all sync state. Your other calendars are not touched."
            }
        }
        var confirmLabel: String {
            switch self {
            case .reSync: return "Re-sync"
            case .wipeEvents: return "Wipe events"
            case .deleteCalendar: return "Delete"
            }
        }
        var role: ButtonRole? {
            switch self {
            case .deleteCalendar, .wipeEvents: return .destructive
            case .reSync: return nil
            }
        }
    }

    private func perform(_ action: DangerAction) {
        switch action {
        case .reSync:
            engine.resetSyncKeys()
        case .wipeEvents:
            Task { await engine.wipeAllEvents() }
        case .deleteCalendar:
            Task { await engine.deleteCalendar() }
        }
        dangerAction = nil
    }

    private func loadPasswordOnce() {
        guard !passwordLoaded else { return }
        passwordLoaded = true
        let account = settings.keychainAccount
        if !account.isEmpty {
            password = (try? keychain.password(account: account)) ?? ""
        }
    }

    private func savePassword() {
        let account = settings.keychainAccount
        guard !account.isEmpty else {
            saveStatus = "Set an email or login first."
            return
        }
        do {
            if password.isEmpty {
                try keychain.deletePassword(account: account)
                saveStatus = "Password cleared."
            } else {
                try keychain.setPassword(password, account: account)
                saveStatus = "Saved to Keychain."
            }
        } catch {
            saveStatus = "Keychain error: \(error.localizedDescription)"
        }
    }

    /// Generates a `curl -v -X OPTIONS …` invocation matching what the app
    /// would send. The user can paste it into Terminal to rule out client
    /// bugs and verify their credentials directly against the server.
    private func copyCurlToClipboard() {
        let host = settings.host.hasPrefix("http") ? settings.host : "https://\(settings.host)"
        let url = "\(host.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/Microsoft-Server-ActiveSync"
        let login = settings.effectiveAuthLogin
        let ua = settings.fingerprint.userAgent
        let safeLogin = login.replacingOccurrences(of: "'", with: "'\"'\"'")
        let safePwd = password.replacingOccurrences(of: "'", with: "'\"'\"'")
        let curl = """
        curl -v -X OPTIONS '\(url)' \\
          -u '\(safeLogin):\(safePwd)' \\
          -H 'User-Agent: \(ua)' \\
          -H 'MS-ASProtocolVersion: 14.1'
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(curl, forType: .string)
        saveStatus = "curl copied — paste into Terminal."
    }

    private func testConnection() {
        savePassword()
        probeMessage = "Probing…"
        probeIsError = false
        Task {
            let result = await engine.probe()
            await MainActor.run {
                switch result {
                case .success(let caps):
                    let versions = caps.protocolVersions.joined(separator: ", ")
                    let chosen = caps.chosenVersion ?? "(none)"
                    let auth = caps.authChallenge ?? "(none)"
                    probeMessage = "OK\nVersions: \(versions)\nChosen: \(chosen)\nAuth: \(auth)"
                    probeIsError = false
                case .failure(let error):
                    probeMessage = "Failed: \(error.localizedDescription)"
                    probeIsError = true
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func color(for level: SyncLog.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        case .debug: return .blue
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
