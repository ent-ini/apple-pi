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
    private let eventLoader: (@Sendable () async throws -> [SessionEvent])?
    private var hasLoadedOnce = false
    private var lastLoadedModificationDate: Date?
    private var loadTask: Task<Void, Never>?

    init(
        key: String,
        title: String,
        sessionPath: String? = nil,
        eventLoader: (@Sendable () async throws -> [SessionEvent])? = nil
    ) {
        self.key = key
        self.title = title
        self.sessionPath = sessionPath
        self.eventLoader = eventLoader
    }

    /// Reload the session from disk. Safe to call multiple times; replaces
    /// the current event list.
    func loadFromDisk(force: Bool = false) {
        guard !isLoading else { return }

        let sessionPath = self.sessionPath
        let eventLoader = self.eventLoader
        let previousLoadedOnce = hasLoadedOnce
        let previousModificationDate = lastLoadedModificationDate

        isLoading = true
        loadError = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                await SessionLoadWorker.load(
                    sessionPath: sessionPath,
                    eventLoader: eventLoader,
                    force: force,
                    previousLoadedOnce: previousLoadedOnce,
                    previousModificationDate: previousModificationDate
                )
            }.value

            guard let self else { return }
            switch outcome {
            case .skipped:
                isLoading = false
                loadTask = nil
            case .notBackedByFile:
                statusMessage = "Session is not backed by a file yet."
                isLoading = false
                loadTask = nil
            case .loaded(let parsed, let modificationDate):
                events = parsed
                statusMessage = parsed.isEmpty ? "Session is empty." : "\(parsed.count) events"
                hasLoadedOnce = true
                lastLoadedModificationDate = modificationDate
                isLoading = false
                loadTask = nil
            case .failed(let message):
                loadError = message
                statusMessage = "Failed to read session: \(message)"
                isLoading = false
                loadTask = nil
            }
        }
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
        eventLoader: (@Sendable () async throws -> [SessionEvent])? = nil
    ) -> ChatSession {
        if let existing = tabs.first(where: { $0.key == key }) {
            select(existing)
            existing.loadFromDisk()
            return existing
        }

        // Single-session UX: opening a different conversation replaces the
        // previous one instead of accumulating horizontal tabs.
        closeAll(notify: false)

        let session = ChatSession(
            key: key,
            title: title,
            sessionPath: sessionPath,
            eventLoader: eventLoader
        )
        tabs = [session]
        select(session)
        session.loadFromDisk()
        return session
    }

    @discardableResult
    func openOrSelectTab(
        key: String,
        title: String,
        sessionPath: String?,
        eventLoader: (@Sendable () async throws -> [SessionEvent])? = nil
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

private enum SessionLoadOutcome: Sendable {
    case skipped
    case notBackedByFile
    case loaded([SessionEvent], modificationDate: Date?)
    case failed(String)
}

private enum SessionLoadWorker {
    static func load(
        sessionPath: String?,
        eventLoader: (@Sendable () async throws -> [SessionEvent])?,
        force: Bool,
        previousLoadedOnce: Bool,
        previousModificationDate: Date?
    ) async -> SessionLoadOutcome {
        do {
            let parsed: [SessionEvent]
            let modificationDate: Date?

            if let eventLoader {
                if !force && previousLoadedOnce {
                    return .skipped
                }
                parsed = try await eventLoader()
                modificationDate = nil
            } else if let sessionPath {
                let fileURL = URL(fileURLWithPath: sessionPath)
                let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                modificationDate = resourceValues?.contentModificationDate
                if !force && previousLoadedOnce && modificationDate == previousModificationDate {
                    return .skipped
                }
                parsed = try SessionEventParser.parse(fileURL: fileURL)
            } else {
                return .notBackedByFile
            }

            return .loaded(parsed, modificationDate: modificationDate)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
