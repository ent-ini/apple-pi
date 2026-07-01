import Foundation
import ApplePiCore
import ApplePiRemote

/// One open tab captured for persistence. Only remote daemon-backed sessions
/// are saved — `new:<UUID>`, `fork:<path>:<UUID>`, and legacy file-backed tabs
/// are filtered out so a fresh launch never needs local session files.
struct PersistedChatTab: Codable, Equatable, Sendable {
    var key: String
    var title: String
    /// The remote daemon's session ID. Legacy snapshots may have `nil`; restore
    /// ignores those tabs in the remote-only app.
    var sessionID: String?
}

/// Snapshot of the open tabs and selected tab for a single host. The
/// fingerprint is stored so a relaunch under a different host (or after
/// the user switches hosts) does not restore the previous host's
/// sessions.
struct PersistedChatTabsSnapshot: Codable, Equatable, Sendable {
    var hostFingerprint: String
    var tabs: [PersistedChatTab]
    var selectedTabKey: String?
}

/// Reads and writes the persisted chat tabs snapshot from
/// `UserDefaults`. The data is small and infrequently written, so a
/// single JSON blob keyed by `ApplePi.chatTabs` is the simplest
/// durable store. Decoding failures are treated as "no snapshot" so a
/// corrupt file never blocks app launch.
struct ChatTabPersistence {
    let defaults: UserDefaults
    let defaultsKey: String

    init(defaults: UserDefaults, defaultsKey: String = "ApplePi.chatTabs") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
    }

    func load() -> PersistedChatTabsSnapshot? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(PersistedChatTabsSnapshot.self, from: data)
    }

    func save(_ snapshot: PersistedChatTabsSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: defaultsKey)
    }
}

extension PiHostConfiguration {
    /// Stable string fingerprint used to scope the persisted chat tabs
    /// snapshot to a host. Built from the fields that determine *which*
    /// catalog and remote daemon a host points at. Adding a new field
    /// to the host struct is a deliberate decision to widen the
    /// fingerprint (existing snapshots are dropped for safety).
    ///
    /// Kept as a plain string concatenation (no hashing) so the result
    /// is trivially inspectable in tests and `defaults` dumps.
    var persistenceFingerprint: String {
        [
            mode.rawValue,
            agentDirectory,
            remoteDaemonURL,
            defaultWorkingDirectory
        ].joined(separator: "|")
    }
}
