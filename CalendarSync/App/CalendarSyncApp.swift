import SwiftUI

@main
struct CalendarSyncApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var engine = SyncEngine.shared
    @StateObject private var log = SyncLog.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(log)
                .task { engine.startIfEnabled() }
        } label: {
            Image(systemName: menuBarSymbol(for: engine.status))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(log)
                .frame(minWidth: 540, minHeight: 520)
        }
    }

    private func menuBarSymbol(for status: SyncStatus) -> String {
        switch status {
        case .idle:    return "calendar"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .error:   return "exclamationmark.triangle"
        }
    }
}
