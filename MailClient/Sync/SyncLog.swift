import Foundation
import os
import Combine

/// In-memory ring buffer of recent sync events. Surfaces to the UI via
/// `@Published`. Backed by `os.Logger` so the same lines also land in unified
/// logging (`log stream --predicate 'subsystem == "com.mailclient.MailClient"'`).
@MainActor
final class SyncLog: ObservableObject {
    nonisolated static let shared = SyncLog()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String
    }

    enum Level: String {
        case info, warn, error, debug
    }

    @Published private(set) var entries: [Entry] = []
    private let capacity: Int
    private let osLog = Logger(subsystem: "com.mailclient.MailClient", category: "SyncLog")

    nonisolated init(capacity: Int = 500) {
        self.capacity = capacity
    }

    nonisolated func info(_ message: String) {
        osLog.info("\(message, privacy: .public)")
        Task { @MainActor in self.append(.info, message) }
    }

    nonisolated func warn(_ message: String) {
        osLog.warning("\(message, privacy: .public)")
        Task { @MainActor in self.append(.warn, message) }
    }

    nonisolated func error(_ message: String) {
        osLog.error("\(message, privacy: .public)")
        Task { @MainActor in self.append(.error, message) }
    }

    nonisolated func debug(_ message: String) {
        osLog.debug("\(message, privacy: .public)")
        Task { @MainActor in self.append(.debug, message) }
    }

    func clear() {
        entries.removeAll()
    }

    private func append(_ level: Level, _ message: String) {
        entries.append(Entry(timestamp: Date(), level: level, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}
