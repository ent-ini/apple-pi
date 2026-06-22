import Foundation
import SwiftUI

/// One Pi session that the user has open in a tab. The read-only MVP loads
/// the underlying `.jsonl` file once and exposes the events to the chat
/// view; live sends add transient user/assistant events while the backing
/// process or remote daemon streams updates.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id = UUID()
    var key: String
    @Published var title: String
    @Published private(set) var events: [SessionEvent] = []
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var loadError: String?
    @Published private(set) var isSending: Bool = false
    @Published private(set) var streamRevision: Int = 0

    /// Path to the on-disk jsonl, if this session is backed by a file. For
    /// brand-new sessions the path is assigned once the first turn creates it.
    private(set) var sessionPath: String?
    private(set) var sessionID: String?
    private(set) var launchRequest: PiLaunchRequest?
    private var eventLoader: (@Sendable () async throws -> [SessionEvent])?
    private var hasLoadedOnce = false
    private var lastLoadedModificationDate: Date?
    private var loadTask: Task<Void, Never>?

    private var persistedEvents: [SessionEvent] = []
    private var transientUserEvent: SessionEvent?
    private var transientAssistantEvent: SessionEvent?

    init(
        key: String,
        title: String,
        sessionID: String? = nil,
        sessionPath: String? = nil,
        launchRequest: PiLaunchRequest? = nil,
        eventLoader: (@Sendable () async throws -> [SessionEvent])? = nil
    ) {
        self.key = key
        self.title = title
        self.sessionID = sessionID
        self.sessionPath = sessionPath
        self.launchRequest = launchRequest
        self.eventLoader = eventLoader
    }

    var canSend: Bool {
        !isSending
    }

    func bindToSession(
        key: String? = nil,
        title: String? = nil,
        sessionID: String?,
        sessionPath: String?,
        eventLoader: (@Sendable () async throws -> [SessionEvent])?
    ) {
        if let key {
            self.key = key
        }
        if let title {
            self.title = title
        }
        self.sessionID = sessionID
        self.sessionPath = sessionPath
        self.eventLoader = eventLoader
        self.launchRequest = nil
    }

    func updateLaunchRequest(_ launchRequest: PiLaunchRequest?) {
        self.launchRequest = launchRequest
    }

    func beginSending(prompt: String, attachments: [ChatAttachment] = []) {
        loadError = nil
        isSending = true
        statusMessage = "Thinking..."

        var content: [ContentBlock] = attachments.map { attachment in
            switch attachment.kind {
            case .image:
                return .image(path: attachment.filePath, mime: attachment.mimeType)
            case .file, .audio:
                return .text("[File: \(attachment.displayName)]")
            }
        }
        if !prompt.isEmpty {
            content.append(.text(prompt))
        }

        transientUserEvent = .message(
            Message(
                id: UUID().uuidString,
                role: .user,
                content: content,
                model: nil,
                timestamp: Date(),
                parentId: nil
            ),
            lineIndex: Self.transientUserLineIndex
        )
        transientAssistantEvent = nil
        rebuildEvents()
    }

    func applyStreamingMessage(_ message: Message, isFinal: Bool) {
        guard message.role == .assistant else { return }
        transientAssistantEvent = .message(
            message,
            lineIndex: Self.transientAssistantLineIndex
        )
        statusMessage = isFinal ? "Finishing..." : "Streaming response..."
        rebuildEvents()
    }

    func finishSendingAndReload() {
        isSending = false
        statusMessage = "Refreshing session..."
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                self?.loadFromDisk(force: true)
            }
        }
    }

    func finishSendingWithError(_ message: String) {
        isSending = false
        loadError = message
        statusMessage = message
        transientUserEvent = nil
        transientAssistantEvent = nil
        rebuildEvents()
    }

    /// Reload the session from disk or remote API. Safe to call multiple
    /// times; replaces the current persisted event list.
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
                persistedEvents = parsed
                transientUserEvent = nil
                transientAssistantEvent = nil
                rebuildEvents()
                statusMessage = parsed.isEmpty ? "Session is empty." : "\(parsed.count) events"
                hasLoadedOnce = true
                lastLoadedModificationDate = modificationDate
                isLoading = false
                isSending = false
                loadTask = nil
            case .failed(let message):
                loadError = message
                statusMessage = "Failed to read session: \(message)"
                isLoading = false
                isSending = false
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

    private func rebuildEvents() {
        events = persistedEvents + [transientUserEvent, transientAssistantEvent].compactMap { $0 }
        streamRevision &+= 1
    }

    private static let transientUserLineIndex = Int.max - 1
    private static let transientAssistantLineIndex = Int.max
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
        sessionID: String? = nil,
        sessionPath: String? = nil,
        launchRequest: PiLaunchRequest? = nil,
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
            sessionID: sessionID,
            sessionPath: sessionPath,
            launchRequest: launchRequest,
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
        sessionID: String? = nil,
        sessionPath: String?,
        launchRequest: PiLaunchRequest? = nil,
        eventLoader: (@Sendable () async throws -> [SessionEvent])? = nil
    ) -> ChatSession {
        openTab(
            key: key,
            title: title,
            sessionID: sessionID,
            sessionPath: sessionPath,
            launchRequest: launchRequest,
            eventLoader: eventLoader
        )
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
