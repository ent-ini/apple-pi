import Foundation
import SwiftUI

/// One Pi session that the user has open in a tab. The read-only MVP loads
/// the underlying `.jsonl` file once and exposes the events to the chat
/// view; the next iteration will start the `pi` process in the background
/// and stream new events from its jsonl as they appear.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id = UUID()
    let key: String
    @Published var title: String
    @Published private(set) var events: [SessionEvent] = []
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var loadError: String?

    /// Path to the on-disk jsonl, if this session is backed by a file. For
    /// brand-new sessions the path is assigned once the file is created.
    let sessionPath: String?
    private let eventLoader: (() throws -> [SessionEvent])?

    init(
        key: String,
        title: String,
        sessionPath: String? = nil,
        eventLoader: (() throws -> [SessionEvent])? = nil
    ) {
        self.key = key
        self.title = title
        self.sessionPath = sessionPath
        self.eventLoader = eventLoader
    }

    /// Reload the session from disk. Safe to call multiple times; replaces
    /// the current event list.
    func loadFromDisk() {
        isLoading = true
        loadError = nil
        do {
            let parsed: [SessionEvent]
            if let eventLoader {
                parsed = try eventLoader()
            } else if let sessionPath {
                parsed = try SessionEventParser.parse(fileURL: URL(fileURLWithPath: sessionPath))
            } else {
                statusMessage = "Session is not backed by a file yet."
                isLoading = false
                return
            }
            events = parsed
            statusMessage = parsed.isEmpty ? "Session is empty." : "\(parsed.count) events"
        } catch {
            loadError = error.localizedDescription
            statusMessage = "Failed to read session: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Replace the title (e.g. when the user renames the tab).
    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
    }
}

/// Multi-session store. Holds the list of open Pi sessions and the
/// currently selected tab. Replaces the old `TerminalWorkspaceStore`.
@MainActor
final class ChatSessionStore: ObservableObject {
    @Published private(set) var tabs: [ChatSession] = []
    @Published var selectedTabID: ChatSession.ID?

    /// Fired when a tab is closed (or its underlying process exits). The
    /// catalog layer uses this to schedule a refresh so newly created
    /// sessions show up in the sidebar.
    var onSessionExit: (() -> Void)?

    var selectedTab: ChatSession? {
        guard let selectedTabID else { return nil }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    var hasTabs: Bool { !tabs.isEmpty }

    // MARK: - Tab management

    @discardableResult
    func openTab(
        key: String,
        title: String,
        sessionPath: String? = nil,
        eventLoader: (() throws -> [SessionEvent])? = nil
    ) -> ChatSession {
        if let existing = tabs.first(where: { $0.key == key }) {
            select(existing)
            existing.loadFromDisk()
            return existing
        }
        let session = ChatSession(
            key: key,
            title: title,
            sessionPath: sessionPath,
            eventLoader: eventLoader
        )
        tabs.append(session)
        select(session)
        session.loadFromDisk()
        return session
    }

    @discardableResult
    func openOrSelectTab(
        key: String,
        title: String,
        sessionPath: String?,
        eventLoader: (() throws -> [SessionEvent])? = nil
    ) -> ChatSession {
        openTab(key: key, title: title, sessionPath: sessionPath, eventLoader: eventLoader)
    }

    func close(_ tab: ChatSession) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasSelected = selectedTabID == tab.id
        tabs.remove(at: index)
        if wasSelected {
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                let fallback = tabs[max(0, index - 1)]
                selectedTabID = fallback.id
            }
        }
        onSessionExit?()
    }

    /// Close every open tab. Used when the host changes so the user does
    /// not see stale conversations from the previous host. After this call
    /// `selectedTabID` is `nil` and the workspace is empty.
    ///
    /// - Parameter notify: when `true` (the default) `onSessionExit` fires
    ///   so observers can schedule a catalog refresh. Pass `false` when
    ///   the caller is already triggering a refresh itself (e.g.
    ///   `PiAppState.clearCatalog` immediately calls `refreshCatalog`
    ///   afterwards).
    func closeAll(notify: Bool = true) {
        guard !tabs.isEmpty else { return }
        tabs.removeAll()
        selectedTabID = nil
        if notify { onSessionExit?() }
    }

    func select(_ tab: ChatSession) {
        selectedTabID = tab.id
    }
}
