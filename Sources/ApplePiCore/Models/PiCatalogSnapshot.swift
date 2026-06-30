import Foundation

public struct PiCatalogSnapshot: Sendable {
    public var projects: [PiProject]
    public var sessions: [PiSessionSummary]
    /// Human-readable notes about non-fatal problems encountered while
    /// building the snapshot, e.g. a session file that could not be
    /// read or a session file that exceeded the bounded line cap. The
    /// list is intentionally surfaced to the user via the status bar
    /// rather than swallowed — silent loss of sessions is worse than a
    /// short warning.
    public var warnings: [String]

    public init(projects: [PiProject], sessions: [PiSessionSummary], warnings: [String] = []) {
        self.projects = projects
        self.sessions = sessions
        self.warnings = warnings
    }
}
