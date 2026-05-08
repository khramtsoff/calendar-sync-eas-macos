import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MailClient EAS Bridge").font(.headline)
                Spacer()
                statusBadge
            }
            Divider()

            row("Server",   settings.host.isEmpty ? "—" : settings.host)
            row("Account",  settings.effectiveEmail.isEmpty ? "—" : settings.effectiveEmail)
            row("Protocol", engine.negotiatedVersion ?? "—")
            row("Last sync", engine.lastSyncAt.map(Self.relative) ?? "Never")
            row("Calendars", engine.calendarFolders.isEmpty
                ? "—"
                : engine.calendarFolders.map(\.displayName).joined(separator: ", "))

            Divider()

            if engine.status == .syncing {
                Button {
                    engine.cancelInflight()
                } label: {
                    Label("Cancel sync", systemImage: "xmark.circle")
                }
                .keyboardShortcut(".")
            } else {
                Button {
                    engine.runOnce()
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }

            Button {
                openCalendarApp()
            } label: {
                Label("Open Calendar.app", systemImage: "calendar")
            }

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch engine.status {
        case .idle:
            Label("Idle", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .syncing:
            Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.tint)
                .font(.caption)
        case .error(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).lineLimit(1).truncationMode(.tail)
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func openCalendarApp() {
        if let url = URL(string: "ical://") {
            NSWorkspace.shared.open(url)
        }
    }
}
