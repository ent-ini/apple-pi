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
    @Published private(set) var runtimeState: SessionRuntimeState?
    @Published private(set) var availableModels: [PiModelOption] = []

    /// Path to the on-disk jsonl, if this session is backed by a file. For
    /// brand-new sessions the path is assigned once the first turn creates it.
    private(set) var sessionPath: String?
    private(set) var sessionID: String?
    private(set) var launchRequest: PiLaunchRequest?
    private var eventLoader: (@Sendable () async throws -> [SessionEvent])?
    private var hasLoadedOnce = false
    private var lastLoadedModificationDate: Date?
    private var loadTask: Task<Void, Never>?
    /// The in-flight send task, if any. `PiAppState.sendMessage`
    /// assigns the task it spawns so the store can cancel it when
    /// the tab is closed. The task body clears the reference on
    /// completion (success, error, or cancellation). The setter is
    /// intentionally `internal` rather than `private(set)` because
    /// the only legitimate writer lives in a different file
    /// (`PiAppState`).
    var sendTask: Task<Void, Never>?

    private var persistedEvents: [SessionEvent] = []
    private var transientUserEvent: SessionEvent?
    private var transientAssistantEvent: SessionEvent?
    private var transientStreamEvents: [SessionEvent] = []

    var lastPersistedLineIndex: Int {
        persistedEvents.last?.lineIndex ?? -1
    }

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

    /// True while a send task is associated with this session. The
    /// store uses this to decide whether closing the tab needs to
    /// cancel work in flight.
    var hasActiveSend: Bool { sendTask != nil }

    /// Cancel the active send task, if any, and drop the reference.
    /// Safe to call from any state, including when no task is running.
    /// The task body still runs to completion but its cancellation
    /// handler is responsible for tearing down the underlying process
    /// or HTTP stream.
    func cancelSend() {
        if let task = sendTask {
            task.cancel()
        }
        sendTask = nil
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

    func updateRuntimeState(_ runtimeState: SessionRuntimeState?) {
        self.runtimeState = runtimeState
    }

    func updateAvailableModels(_ availableModels: [PiModelOption]) {
        self.availableModels = availableModels
    }

    func beginSending(prompt: String, attachments: [ChatAttachment] = []) {
        loadError = nil
        isSending = true
        statusMessage = "Thinking..."

        var content: [ContentBlock] = attachments.map { attachment in
            switch attachment.kind {
            case .image:
                return .image(path: attachment.filePath, mime: attachment.mimeType)
            case .file:
                return .text(
                    "<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Binary file attached: \(attachment.displayName.xmlEscapedForPrompt)]</file>"
                )
            case .audio:
                return .text(
                    "<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Audio attachment: \(attachment.displayName.xmlEscapedForPrompt)]</file>"
                )
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
        transientAssistantEvent = .message(
            Message(
                id: UUID().uuidString,
                role: .assistant,
                content: [],
                model: nil,
                timestamp: nil,
                parentId: nil
            ),
            lineIndex: Self.transientAssistantLineIndex
        )
        transientStreamEvents = []
        rebuildEvents()
    }

    func applyStreamingEvents(_ events: [SessionEvent], isFinal: Bool) {
        var nextStreamEvents = transientStreamEvents

        for event in events {
            switch event {
            case .message(let message, _):
                guard message.role == .assistant else { continue }
                transientAssistantEvent = .message(
                    message,
                    lineIndex: Self.transientAssistantLineIndex
                )
            case .toolCall(let call, _):
                let transientEvent = SessionEvent.toolCall(call, lineIndex: nextTransientLineIndex(for: nextStreamEvents.count))
                upsertTransientStreamEvent(transientEvent, into: &nextStreamEvents)
            case .toolResult(let result, _):
                let transientEvent = SessionEvent.toolResult(result, lineIndex: nextTransientLineIndex(for: nextStreamEvents.count))
                upsertTransientStreamEvent(transientEvent, into: &nextStreamEvents)
            case .meta, .other:
                continue
            }
        }

        transientStreamEvents = nextStreamEvents
        statusMessage = isFinal ? "Finishing..." : "Streaming response..."
        rebuildEvents()
    }

    func finishSendingAndReload() {
        isSending = false
        statusMessage = "Refreshing session..."
        loadFromDisk(force: true)
    }

    /// Mark the current send as cancelled without showing an error to
    /// the user. Called from `PiAppState.sendMessage` when the task
    /// body observes `CancellationError` (e.g. the tab was closed
    /// mid-send). Clears transient UI state so the composer is usable
    /// again.
    func finishSendingCancelled() {
        isSending = false
        statusMessage = ""
        transientUserEvent = nil
        transientAssistantEvent = nil
        transientStreamEvents = []
        rebuildEvents()
    }

    func finishSendingWithError(_ message: String) {
        isSending = false
        loadError = message
        statusMessage = message
        transientUserEvent = nil
        transientAssistantEvent = nil
        transientStreamEvents = []
        rebuildEvents()
    }

    func appendPersistedEvents(_ newEvents: [SessionEvent]) {
        let filtered = newEvents.filter { $0.lineIndex > lastPersistedLineIndex }
        guard !filtered.isEmpty else { return }
        persistedEvents.append(contentsOf: filtered)
        reconcileTransientEvents(with: persistedEvents)
        rebuildEvents()
        statusMessage = "\(persistedEvents.count) events"
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
                isSending = false
                loadTask = nil
            case .notBackedByFile:
                statusMessage = "Session is not backed by a file yet."
                isLoading = false
                isSending = false
                loadTask = nil
            case .loaded(let parsed, let modificationDate):
                persistedEvents = parsed
                reconcileTransientEvents(with: parsed)
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
        events = persistedEvents + visibleTransientEvents
        streamRevision &+= 1
    }

    private var visibleTransientEvents: [SessionEvent] {
        ([transientUserEvent].compactMap { $0 } + transientStreamEvents + [transientAssistantEvent].compactMap { $0 })
            .filter { shouldDisplayTransientEvent($0) }
    }

    private func shouldDisplayTransientEvent(_ transientEvent: SessionEvent) -> Bool {
        switch transientEvent {
        case .message:
            return !latestPersistedMessage(matches: transientEvent, in: persistedEvents)
        case .toolCall(let call, _):
            return !persistedEvents.contains { event in
                guard case .toolCall(let persistedCall, _) = event else { return false }
                return persistedCall.id == call.id
            }
        case .toolResult(let result, _):
            return !persistedEvents.contains { event in
                guard case .toolResult(let persistedResult, _) = event else { return false }
                return persistedResult.id == result.id
                    || (!result.callId.isEmpty
                        && persistedResult.callId == result.callId
                        && persistedResult.output == result.output)
            }
        case .meta, .other:
            return true
        }
    }

    private func reconcileTransientEvents(with persisted: [SessionEvent]) {
        if let transientUserEvent,
           latestPersistedMessage(matches: transientUserEvent, in: persisted) {
            self.transientUserEvent = nil
        }
        if let transientAssistantEvent,
           latestPersistedMessage(matches: transientAssistantEvent, in: persisted) {
            self.transientAssistantEvent = nil
        }
        transientStreamEvents.removeAll { event in
            switch event {
            case .message:
                return latestPersistedMessage(matches: event, in: persisted)
            case .toolCall(let call, _):
                return persisted.contains { persistedEvent in
                    guard case .toolCall(let persistedCall, _) = persistedEvent else { return false }
                    return persistedCall.id == call.id
                }
            case .toolResult(let result, _):
                return persisted.contains { persistedEvent in
                    guard case .toolResult(let persistedResult, _) = persistedEvent else { return false }
                    return persistedResult.id == result.id
                        || (!result.callId.isEmpty
                            && persistedResult.callId == result.callId
                            && persistedResult.output == result.output)
                }
            case .meta, .other:
                return false
            }
        }
    }

    private func upsertTransientStreamEvent(_ event: SessionEvent, into events: inout [SessionEvent]) {
        let matches: (SessionEvent) -> Bool = {
            switch (event, $0) {
            case (.toolCall(let lhs, _), .toolCall(let rhs, _)):
                return lhs.id == rhs.id
            case (.toolResult(let lhs, _), .toolResult(let rhs, _)):
                return lhs.id == rhs.id || (!lhs.callId.isEmpty && lhs.callId == rhs.callId)
            default:
                return false
            }
        }
        if let index = events.firstIndex(where: matches) {
            events[index] = event
        } else {
            events.append(event)
        }
    }

    private func nextTransientLineIndex(for offset: Int) -> Int {
        Self.transientStreamLineIndexBase + offset
    }

    private func latestPersistedMessage(matches transientEvent: SessionEvent, in persisted: [SessionEvent]) -> Bool {
        guard case .message(let transientMessage, _) = transientEvent else { return false }
        guard let persistedMessage = persisted.reversed().compactMap({ event -> Message? in
            guard case .message(let message, let lineIndex) = event,
                  lineIndex < Self.transientUserLineIndex,
                  message.role == transientMessage.role else {
                return nil
            }
            return message
        }).first else {
            return false
        }

        if persistedMessage.id == transientMessage.id {
            return true
        }

        let transientSignature = messageSignature(for: transientMessage)
        let persistedSignature = messageSignature(for: persistedMessage)
        if !transientSignature.isEmpty, transientSignature == persistedSignature {
            return true
        }

        guard persistedMessage.content == transientMessage.content else {
            return false
        }
        if let transientTimestamp = transientMessage.timestamp,
           let persistedTimestamp = persistedMessage.timestamp {
            return abs(persistedTimestamp.timeIntervalSince(transientTimestamp)) < 30
        }
        return persistedMessage.parentId == transientMessage.parentId
    }

    private func messageSignature(for message: Message) -> String {
        message.content.compactMap { block -> String? in
            switch block {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .thinking(let text, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : "[thinking]\(trimmed)"
            case .image(let path, _):
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : "[image]\(trimmed)"
            }
        }
        .joined(separator: "\n")
    }

    private static let transientStreamLineIndexBase = Int.max - 1_000
    private static let transientUserLineIndex = Int.max - 1
    private static let transientAssistantLineIndex = Int.max
}

private extension String {
    var xmlEscapedForPrompt: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Multi-session store. Holds the list of open Pi sessions and the
/// currently selected tab. Replaces the old `TerminalWorkspaceStore`.
@MainActor
final class ChatSessionStore: ObservableObject {
    private let maximumCachedTabs = 40

    @Published private(set) var tabs: [ChatSession] = []
    @Published var selectedTabID: ChatSession.ID?

    /// Fired when a tab is closed (or its underlying process exits). The
    /// catalog layer uses this to schedule a refresh so newly created
    /// sessions show up in the sidebar.
    var onSessionExit: (() -> Void)?

    /// Fired on any mutation that affects the set of open tabs or the
    /// selected tab. The persistence layer hooks into this to keep the
    /// on-disk snapshot in sync. Not fired for transient state such as
    /// per-tab `loadError` or `isSending` because those are part of the
    /// runtime session, not the persisted shape.
    var onTabsChanged: (() -> Void)?

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
            existing.bindToSession(
                key: key,
                title: title,
                sessionID: sessionID,
                sessionPath: sessionPath,
                eventLoader: eventLoader
            )
            existing.updateLaunchRequest(launchRequest)
            select(existing)
            if existing.events.isEmpty, (sessionPath != nil || eventLoader != nil) {
                existing.loadFromDisk()
            }
            return existing
        }

        // Chat-first UX: keep previously opened conversations alive in
        // memory so switching away and back preserves streaming state,
        // scroll position, and already loaded content.
        let session = ChatSession(
            key: key,
            title: title,
            sessionID: sessionID,
            sessionPath: sessionPath,
            launchRequest: launchRequest,
            eventLoader: eventLoader
        )
        tabs.append(session)
        select(session)
        if sessionPath != nil || eventLoader != nil {
            session.loadFromDisk()
        }
        trimCachedTabsIfNeeded()
        onTabsChanged?()
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
        // Cancel any in-flight send before removing the tab so the
        // underlying process / HTTP stream is torn down promptly. The
        // task body is responsible for the rest of the cleanup; here
        // we just make sure we don't leak a detached process.
        tab.cancelSend()
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
        onTabsChanged?()
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
        // Cancel active sends across every tab before wiping the list.
        // The task bodies finish on their own and quietly observe the
        // cancellation.
        for tab in tabs {
            tab.cancelSend()
        }
        tabs.removeAll()
        selectedTabID = nil
        if notify { onSessionExit?() }
        onTabsChanged?()
    }

    func select(_ tab: ChatSession) {
        selectedTabID = tab.id
        if let index = tabs.firstIndex(where: { $0.id == tab.id }), index != tabs.count - 1 {
            let cached = tabs.remove(at: index)
            tabs.append(cached)
        }
        onTabsChanged?()
    }

    private func trimCachedTabsIfNeeded() {
        while tabs.count > maximumCachedTabs {
            guard let index = tabs.firstIndex(where: { $0.id != selectedTabID && !$0.hasActiveSend }) else {
                break
            }
            tabs.remove(at: index)
        }
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
