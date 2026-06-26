import Foundation
import AppKit
import SwiftUI

typealias PiCatalogLoader = @Sendable (PiHostConfiguration, String?) async throws -> PiCatalogSnapshot

@MainActor
final class PiAppState: ObservableObject {
    @Published var host = PiHostConfiguration() {
        didSet {
            guard !isLoadingPersistedState else { return }
            // Any change to `host` (mode, hostname, user, port, identity file,
            // auth method) means the previous catalog and open tabs reference
            // a different machine. Always reset to a known-empty state and
            // kick off a fresh catalog load — never reuse the old project
            // working directory as filter context, since it is meaningless
            // on the new host.
            clearCatalog()
            saveHost()
            refreshConfigurationSummary()
            refreshCatalog(usesActiveProjectContext: false)
            // The previous host's stream is torn down inside `clearCatalog`;
            // start a fresh one for the new host.
            if startsBackgroundWork {
                startCatalogLiveUpdates()
            }
        }
    }
    @Published private(set) var projects: [PiProject] = []
    @Published private(set) var sessions: [PiSessionSummary] = []
    @Published var selection: PiSelection?
    @Published var sessionSearchText = ""
    @Published private(set) var pendingSessionSearchFocusRequest = false
    @Published private(set) var sessionSearchFocusRequestID = 0
    @Published var statusMessage = "Ready"
    @Published var isLoadingCatalog = false
    @Published var showsNewSessionSheet = false
    @Published var newSessionWorkingDirectory = ""
    @Published var newSessionName = ""
    @Published var newSessionIsTemporary = false
    @Published private(set) var remoteDirectoryEntries: [RemoteDirectoryEntry] = []
    @Published private(set) var remoteDirectoryPath = ""
    @Published private(set) var remoteDirectoryParent: String?
    @Published private(set) var remoteDirectoryStatus = ""
    @Published private(set) var isLoadingRemoteDirectory = false
    @Published private(set) var configurationSummary = PiConfigurationSummary.empty(host: PiHostConfiguration())
    @Published var appearance = AppAppearance() {
        didSet {
            saveAppearance()
        }
    }
    @Published private(set) var shortcutPreferences = AppShortcutPreferences() {
        didSet {
            guard !isLoadingPersistedState else { return }
            saveShortcutPreferences()
        }
    }
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var sendingSessionKeys: Set<String> = []
    @Published private(set) var unreadSessionKeys: Set<String> = []
    @Published private(set) var sessionActivityOverrides: [String: Date] = [:]

    let chatWorkspace = ChatSessionStore()

    private let configurationService: PiConfigurationService
    private let updateCheckService: UpdateCheckService
    private let remoteDirectoryService: RemoteDirectoryService
    private let catalogLoader: PiCatalogLoader
    private let defaults: UserDefaults
    private let hostDefaultsKey = "ApplePi.host"
    private let appearanceDefaultsKey = "ApplePi.appearance"
    private let shortcutDefaultsKey = "ApplePi.shortcuts"
    private let chatTabDefaultsKey = "ApplePi.chatTabs"
    private let lastUpdateCheckKey = "ApplePi.updateCheck.lastCheckedAt"
    private let updateCheckInterval: TimeInterval = 24 * 60 * 60
    private let startsBackgroundWork: Bool
    private let chatTabPersistence: ChatTabPersistence
    private var isLoadingPersistedState = false
    private var catalogRefreshID = UUID()
    private var remoteDirectoryRefreshID = UUID()
    private var catalogPollingTask: Task<Void, Never>?
    private var selectedSessionPollingTask: Task<Void, Never>?
    private var selectedSessionStreamTask: Task<Void, Never>?
    private var activityObservers: [NSObjectProtocol] = []
    private var isApplicationActive = true
    private var isCatalogStreamConnected = false
    /// Long-lived task that subscribes to the daemon's `/sessions/stream`
    /// SSE endpoint and pushes full catalog snapshots into `projects` /
    /// `sessions`. `nil` whenever the current host doesn't use the daemon
    /// transport or the task is not running.
    private var catalogStreamTask: Task<Void, Never>?
    /// Pending debounced save for the chat tabs snapshot. A single task
    /// is reused so a burst of mutations only writes once.
    private var chatTabsSaveTask: Task<Void, Never>?
    private var sessionDefaultsCache: [String: SessionDefaultsSnapshot] = [:]
    private var availableModelsCache: [PiModelOption] = []
    private var availableModelsCacheLoadedAt: Date?
    private var isLoadingAvailableModels = false
    private var pendingThinkingLevelBySessionKey: [String: String] = [:]
    private var thinkingLevelMutationVersionBySessionKey: [String: Int] = [:]

    init(
        defaults: UserDefaults = Foundation.UserDefaults(suiteName: nil) ?? Foundation.UserDefaults(),
        configurationService: PiConfigurationService = PiConfigurationService(),
        updateCheckService: UpdateCheckService = UpdateCheckService(),
        remoteDirectoryService: RemoteDirectoryService = RemoteDirectoryService(),
        catalogLoader: @escaping PiCatalogLoader = { host, activeProjectDirectory in
            try await PiSessionCatalogService().loadCatalog(
                host: host,
                activeProjectDirectory: activeProjectDirectory
            )
        },
        startsBackgroundWork: Bool = true
    ) {
        self.defaults = defaults
        self.configurationService = configurationService
        self.updateCheckService = updateCheckService
        self.remoteDirectoryService = remoteDirectoryService
        self.catalogLoader = catalogLoader
        self.startsBackgroundWork = startsBackgroundWork
        self.chatTabPersistence = ChatTabPersistence(
            defaults: defaults,
            defaultsKey: chatTabDefaultsKey
        )

        isLoadingPersistedState = true
        loadHost()
        loadAppearance()
        loadShortcutPreferences()
        isLoadingPersistedState = false

        chatWorkspace.onSessionExit = { [weak self] in
            self?.scheduleCatalogRefresh()
        }
        // Persist whenever the user mutates the set of open tabs or
        // changes which one is selected. The save is debounced inside
        // `schedulePersistedChatTabsSave` so a burst of streaming
        // events only writes once.
        chatWorkspace.onTabsChanged = { [weak self] in
            self?.schedulePersistedChatTabsSave()
            self?.restartSelectedSessionEventStream()
        }
        // Restore previously open tabs before kicking off the catalog
        // refresh. A fingerprint mismatch (different host) is a no-op
        // and the snapshot is simply overwritten on the first save.
        restorePersistedChatTabs()
        refreshConfigurationSummary()
        if startsBackgroundWork {
            refreshCatalog()
            runUpdateCheckIfNeeded()
        }
        // The live subscription is independent of the one-shot refresh:
        // it stays alive across app sessions for daemon-backed hosts.
        if startsBackgroundWork {
            startApplicationActivityObservers()
            startCatalogLiveUpdates()
            startCatalogAdaptivePolling()
            startSelectedSessionEventPolling()
            restartSelectedSessionEventStream()
        }
    }

    func dismissAvailableUpdate() {
        availableUpdate = nil
    }

    /// Called from the app termination notification. Cancels background
    /// catalog work and active sends before the process exits, so a local
    /// `pi --mode rpc` child does not survive as an orphan when the user
    /// quits Apple Pi mid-turn.
    func shutdownForTermination() {
        catalogRefreshID = UUID()
        stopCatalogLiveUpdates()
        stopCatalogAdaptivePolling()
        selectedSessionPollingTask?.cancel()
        selectedSessionPollingTask = nil
        stopSelectedSessionEventStream()
        savePersistedChatTabs()
        for tab in chatWorkspace.tabs {
            tab.cancelSend()
        }
    }

    private func runUpdateCheckIfNeeded() {
        let last = defaults.object(forKey: lastUpdateCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= updateCheckInterval else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                if let update = try await updateCheckService.checkForUpdate() {
                    self.availableUpdate = update
                }
                defaults.set(Date(), forKey: lastUpdateCheckKey)
            } catch {
                // Fail silently: the pill stays hidden, the next launch retries the check.
            }
        }
    }

    var selectedProject: PiProject? {
        guard case .project(let id) = selection else { return nil }
        return projects.first(where: { $0.id == id })
    }

    var selectedSession: PiSessionSummary? {
        guard case .session(let id) = selection else { return nil }
        return sessions.first(where: { $0.id == id || $0.filePath == id })
    }

    var activeProject: PiProject? {
        if let selectedProject { return selectedProject }
        if let selectedSession {
            return projects.first(where: { $0.id == selectedSession.projectID })
        }
        return projects.first
    }

    var filteredProjects: [PiProject] {
        projects
    }

    func sessions(for project: PiProject) -> [PiSessionSummary] {
        sessions
            .filter { $0.projectID == project.id }
            .sorted { effectiveLastActivity(for: $0) > effectiveLastActivity(for: $1) }
    }

    func filteredSessions(for project: PiProject?) -> [PiSessionSummary] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSessions: [PiSessionSummary]
        if query.isEmpty {
            guard let project else { return [] }
            baseSessions = sessions(for: project)
        } else {
            baseSessions = sessions.sorted { effectiveLastActivity(for: $0) > effectiveLastActivity(for: $1) }
        }

        guard !query.isEmpty else { return baseSessions }
        return baseSessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query) ||
            session.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    func effectiveLastActivity(for session: PiSessionSummary) -> Date {
        sessionAliases(for: session)
            .compactMap { sessionActivityOverrides[$0] }
            .max()
            .map { max($0, session.modifiedAt) }
            ?? session.modifiedAt
    }

    func isSessionSending(_ session: PiSessionSummary) -> Bool {
        !sendingSessionKeys.isDisjoint(with: Set(sessionAliases(for: session)))
    }

    func hasUnreadIndicator(_ session: PiSessionSummary) -> Bool {
        !isSessionSending(session) && !unreadSessionKeys.isDisjoint(with: Set(sessionAliases(for: session)))
    }

    var hasActiveSessionSearch: Bool {
        sessionSearchText.nilIfBlank != nil
    }

    func shortcut(for action: AppShortcutAction) -> AppShortcut {
        shortcutPreferences.binding(for: action)
    }

    func updateShortcut(_ shortcut: AppShortcut, for action: AppShortcutAction) {
        var next = shortcutPreferences
        next.set(shortcut, for: action)
        shortcutPreferences = next
    }

    func requestSessionSearchFocus() {
        pendingSessionSearchFocusRequest = true
        sessionSearchFocusRequestID &+= 1
    }

    func consumeSessionSearchFocusRequest() {
        pendingSessionSearchFocusRequest = false
    }

    func updateAppearance(_ update: (inout AppAppearance) -> Void) {
        var next = appearance
        update(&next)
        appearance = next
    }

    func updateNotificationPreferences(_ update: (inout TerminalNotificationPreferences) -> Void) {
        var next = appearance
        update(&next.notifications)
        appearance = next

        guard next.notifications.isEnabled else { return }
        Task {
            _ = await NativeNotificationPresenter.shared.prepareAuthorization(
                for: next.notifications
            )
        }
    }

    func sendTestNotification() async -> TerminalNotificationDeliveryResult {
        await NativeNotificationPresenter.shared.present(
            title: "pi-app",
            body: "OSC 777 notifications are ready.",
            preferences: appearance.notifications
        )
    }

    func refreshCatalog(usesActiveProjectContext: Bool = true, quietly: Bool = false) {
        isLoadingCatalog = true
        let refreshID = UUID()
        catalogRefreshID = refreshID
        let currentHost = host
        let activeProjectDirectory = usesActiveProjectContext ? activeProject?.workingDirectory : nil
        let catalogLoader = catalogLoader
        Task.detached {
            do {
                let snapshot = try await catalogLoader(currentHost, activeProjectDirectory)
                await MainActor.run {
                    guard self.catalogRefreshID == refreshID else { return }
                    self.projects = snapshot.projects
                    self.sessions = snapshot.sessions
                    self.isLoadingCatalog = false
                    if !quietly {
                        self.statusMessage = PiAppState.catalogStatusMessage(
                            sessionCount: snapshot.sessions.count,
                            warnings: snapshot.warnings
                        )
                    }
                    self.repairSelectionIfNeeded()
                    self.refreshConfigurationSummary()
                    self.prefetchSessionDefaultsForCurrentContext()
                }
            } catch {
                await MainActor.run {
                    guard self.catalogRefreshID == refreshID else { return }
                    self.isLoadingCatalog = false
                    if !quietly {
                        self.statusMessage = error.localizedDescription
                        // Drop the stale data so the user is not looking at the
                        // old host's projects while the error banner is up.
                        self.projects = []
                        self.sessions = []
                        self.selection = nil
                    }
                }
            }
        }
    }

    func select(_ selection: PiSelection) {
        self.selection = selection
        if case .session = selection, let selectedSession {
            markSessionRead(selectedSession)
        }
        refreshConfigurationSummary()
        prefetchSessionDefaultsForCurrentContext()
        if case .session = selection, let selectedSession {
            resume(selectedSession)
        }
    }

    var selectedWorkingDirectory: String? {
        selectedSession?.workingDirectory ?? selectedProject?.workingDirectory
    }

    private var fallbackWorkingDirectory: String {
        host.usesRemoteDaemonTransport || host.mode == .remoteSSH ? "~" : NSHomeDirectory()
    }

    private var preferredWorkingDirectory: String {
        selectedWorkingDirectory?.nilIfBlank ?? fallbackWorkingDirectory
    }

    private func sessionDefaultsCacheKey(for workingDirectory: String?) -> String {
        let raw = workingDirectory?.nilIfBlank ?? fallbackWorkingDirectory
        return (raw as NSString).expandingTildeInPath
    }

    private func cacheSessionDefaults(_ snapshot: SessionDefaultsSnapshot, for workingDirectory: String?) {
        sessionDefaultsCache[sessionDefaultsCacheKey(for: workingDirectory)] = snapshot
        if !snapshot.availableModels.isEmpty {
            availableModelsCache = snapshot.availableModels
            availableModelsCacheLoadedAt = Date()
        }
    }

    @discardableResult
    private func applyBestKnownSessionDefaults(to session: ChatSession) -> Bool {
        guard session.sessionID == nil,
              let request = session.launchRequest else {
            return false
        }

        guard let snapshot = sessionDefaultsCache[sessionDefaultsCacheKey(for: request.workingDirectory)] else {
            return false
        }

        var nextRequest = request
        if nextRequest.initialModelProvider == nil { nextRequest.initialModelProvider = snapshot.runtimeState.provider }
        if nextRequest.initialModelID == nil { nextRequest.initialModelID = snapshot.runtimeState.modelID }
        if nextRequest.initialThinkingLevel == nil { nextRequest.initialThinkingLevel = snapshot.runtimeState.thinkingLevel }
        session.updateLaunchRequest(nextRequest)
        session.updateRuntimeState(snapshot.runtimeState)
        if session.availableModels.isEmpty {
            session.updateAvailableModels(snapshot.availableModels)
        }
        return true
    }

    private func prefetchSessionDefaultsForCurrentContext() {
        guard host.usesRemoteDaemonTransport else { return }
        let workingDirectory = preferredWorkingDirectory
        let cacheKey = sessionDefaultsCacheKey(for: workingDirectory)
        if sessionDefaultsCache[cacheKey] != nil { return }

        let remoteHost = host
        Task { [weak self] in
            do {
                let snapshot = try await RemoteDaemonClient().loadSessionDefaults(
                    host: remoteHost,
                    workingDirectory: workingDirectory
                )
                await MainActor.run {
                    guard let self, self.host == remoteHost else { return }
                    self.cacheSessionDefaults(snapshot, for: workingDirectory)
                }
            } catch {
                // Best-effort warmup only.
            }
        }
    }

    func presentNewSessionInFolder(isTemporary: Bool = false) {
        newSessionWorkingDirectory = preferredWorkingDirectory
        newSessionName = ""
        newSessionIsTemporary = isTemporary
        showsNewSessionSheet = true
        prepareRemoteDirectoryBrowserIfNeeded()
    }

    func openNewSession() {
        openNewSession(
            workingDirectory: newSessionWorkingDirectory.nilIfBlank,
            sessionName: newSessionName.nilIfBlank,
            isTemporary: newSessionIsTemporary
        )
        resetNewSessionSheet()
    }

    func openNewSessionInCurrentFolder() {
        openNewSession(
            workingDirectory: preferredWorkingDirectory,
            sessionName: nil,
            isTemporary: false
        )
    }

    func openTemporarySessionInCurrentFolder() {
        openNewSession(
            workingDirectory: preferredWorkingDirectory,
            sessionName: nil,
            isTemporary: true
        )
    }

    func openNewSession(in workingDirectory: String?, isTemporary: Bool = false) {
        openNewSession(
            workingDirectory: workingDirectory,
            sessionName: nil,
            isTemporary: isTemporary
        )
    }

    func chooseNewSessionFolder() {
        guard !host.usesRemoteDaemonTransport && host.mode == .local else {
            refreshRemoteDirectory()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = newSessionWorkingDirectory.nilIfBlank.map { URL(fileURLWithPath: $0.expandingTilde) }
        if panel.runModal() == .OK, let url = panel.url {
            newSessionWorkingDirectory = url.path
        }
    }

    func refreshRemoteDirectory() {
        guard host.usesRemoteDaemonTransport || host.mode == .remoteSSH else { return }
        loadRemoteDirectory(newSessionWorkingDirectory.nilIfBlank ?? remoteDirectoryPath.nilIfBlank ?? "~")
    }

    func openRemoteDirectory(_ entry: RemoteDirectoryEntry) {
        newSessionWorkingDirectory = entry.path
        loadRemoteDirectory(entry.path)
    }

    func openRemoteDirectoryParent() {
        guard let remoteDirectoryParent else { return }
        newSessionWorkingDirectory = remoteDirectoryParent
        loadRemoteDirectory(remoteDirectoryParent)
    }

    func openRemoteHomeDirectory() {
        newSessionWorkingDirectory = "~"
        loadRemoteDirectory("~")
    }

    private func prepareRemoteDirectoryBrowserIfNeeded() {
        guard host.usesRemoteDaemonTransport || host.mode == .remoteSSH else { return }
        let initialPath = newSessionWorkingDirectory.nilIfBlank ?? remoteDirectoryPath.nilIfBlank ?? "~"
        newSessionWorkingDirectory = initialPath
        loadRemoteDirectory(initialPath)
    }

    private func loadRemoteDirectory(_ path: String) {
        isLoadingRemoteDirectory = true
        remoteDirectoryStatus = "Loading remote folders..."
        let refreshID = UUID()
        remoteDirectoryRefreshID = refreshID
        let currentHost = host
        let remoteDirectoryService = remoteDirectoryService
        Task.detached {
            do {
                let listing = try await remoteDirectoryService.listDirectories(host: currentHost, path: path)
                await MainActor.run {
                    guard self.remoteDirectoryRefreshID == refreshID else { return }
                    self.remoteDirectoryPath = listing.path
                    self.remoteDirectoryParent = listing.parent
                    self.remoteDirectoryEntries = listing.directories
                    self.newSessionWorkingDirectory = listing.path
                    self.isLoadingRemoteDirectory = false
                    self.remoteDirectoryStatus = listing.directories.isEmpty ? "No folders in this directory." : "\(listing.directories.count) folders"
                }
            } catch {
                await MainActor.run {
                    guard self.remoteDirectoryRefreshID == refreshID else { return }
                    self.remoteDirectoryEntries = []
                    self.isLoadingRemoteDirectory = false
                    self.remoteDirectoryStatus = error.localizedDescription
                }
            }
        }
    }

    private func openNewSession(workingDirectory: String?, sessionName: String?, isTemporary: Bool) {
        let effectiveName = sessionName?.nilIfBlank ?? (isTemporary ? "Temporary" : "New Pi")
        let request = PiLaunchRequest(
            workingDirectory: workingDirectory,
            sessionPath: nil,
            forkPath: nil,
            sessionName: sessionName?.nilIfBlank,
            isEphemeral: isTemporary,
            initialPrompt: nil
        )
        let key = "new:\(UUID().uuidString)"
        let tab = chatWorkspace.openTab(
            key: key,
            title: effectiveName,
            sessionPath: nil,
            launchRequest: request
        )
        _ = applyBestKnownSessionDefaults(to: tab)
        hydratePendingSessionDefaults(for: tab)
        statusMessage = isTemporary ? "Started temporary Pi session" : "Started new Pi session"
    }

    private func resetNewSessionSheet() {
        newSessionName = ""
        newSessionIsTemporary = false
        showsNewSessionSheet = false
    }

    func openEphemeralSession() {
        openTemporarySessionInCurrentFolder()
    }

    func resume(_ session: PiSessionSummary) {
        let tab = chatWorkspace.openOrSelectTab(
            key: session.filePath,
            title: session.title,
            sessionID: session.id,
            sessionPath: session.filePath,
            eventLoader: eventLoader(for: session),
            historyPageLoader: historyPageLoader(for: session)
        )
        refreshSessionRuntime(for: tab)
        applyCachedAvailableModels(to: tab)
        statusMessage = "Resumed \(session.title)"
    }

    func fork(_ session: PiSessionSummary) {
        let request = PiLaunchRequest.fork(session)
        chatWorkspace.openTab(
            key: "fork:\(session.filePath):\(UUID().uuidString)",
            title: "Fork: \(session.title)",
            sessionPath: nil,
            launchRequest: request
        )
        statusMessage = "Fork ready from \(session.title)"
    }

    private func eventLoader(for session: PiSessionSummary) -> (@Sendable () async throws -> SessionEventsPage)? {
        remoteEventLoader(sessionID: session.id)
    }

    private func historyPageLoader(for session: PiSessionSummary) -> (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)? {
        remoteHistoryPageLoader(sessionID: session.id)
    }

    private func remoteEventLoader(sessionID: String) -> (@Sendable () async throws -> SessionEventsPage)? {
        guard host.usesRemoteDaemonTransport || host.mode == .remoteSSH else { return nil }
        let remoteHost = host
        return {
            try await RemoteDaemonClient().loadSessionEventPage(host: remoteHost, sessionID: sessionID)
        }
    }

    private func remoteHistoryPageLoader(sessionID: String) -> (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)? {
        guard host.usesRemoteDaemonTransport || host.mode == .remoteSSH else { return nil }
        let remoteHost = host
        return { before, limit in
            try await RemoteDaemonClient().loadSessionEventPage(
                host: remoteHost,
                sessionID: sessionID,
                limit: limit,
                before: before
            )
        }
    }

    func cancelSend(in session: ChatSession) {
        guard session.hasActiveSend else { return }
        statusMessage = "Stopping Pi..."
        session.cancelSend()
    }

    @discardableResult
    func sendMessage(_ prompt: String, attachments: [ChatAttachment] = [], in session: ChatSession) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        let effectivePrompt = trimmed.isEmpty ? "Please inspect the attached item(s)." : trimmed
        let taggedPrompt = sourceTaggedAppPrompt(effectivePrompt)
        guard !session.isSending else {
            statusMessage = "Pi is already working on this session."
            return false
        }
        guard !session.isLoading else {
            statusMessage = "Session is still refreshing."
            return false
        }

        if let request = session.launchRequest, request.isEphemeral {
            session.finishSendingWithError("Temporary chat sessions are not supported yet in pi-app.")
            return false
        }

        session.beginSending(prompt: taggedPrompt, attachments: attachments)
        let sendGeneration = session.currentSendGeneration
        let initialAliases = sessionAliases(for: session)
        markSessionActive(initialAliases)
        setSessionSending(true, aliases: initialAliases)
        clearUnread(aliases: initialAliases)
        insertOptimisticSidebarSession(for: session, fallbackAliases: initialAliases)
        statusMessage = "Sending to Pi..."

        if host.usesRemoteDaemonTransport || host.mode == .remoteSSH {
            let task = Task { [weak self, weak session] in
                let outcome: SendOutcome
                if let self {
                    outcome = await self.runRemoteTurn(
                        session: session,
                        prompt: taggedPrompt,
                        attachments: attachments
                    )
                } else {
                    outcome = .cancelled
                }
                await MainActor.run {
                    Self.applySendOutcome(
                        outcome,
                        session: session,
                        sendGeneration: sendGeneration,
                        initialAliases: initialAliases,
                        appState: self
                    )
                }
            }
            session.sendTask = task
            return true
        }

        let launchRequest = session.launchRequest ?? PiLaunchRequest(
            workingDirectory: selectedWorkingDirectory,
            sessionPath: session.sessionPath,
            forkPath: nil,
            sessionName: nil,
            isEphemeral: false,
            initialPrompt: nil
        )
        let sessionRootCandidates = configurationService
            .resolveSessionRoots(host: host, projectDirectory: launchRequest.workingDirectory)
            .roots
            .map { $0.expandingTilde }

        let task = Task { [weak self, weak session] in
            // If the app state was deallocated there is nothing left to
            // coordinate with; bail out as a cancellation. In practice
            // this never happens because `PiAppState` is owned by the
            // SwiftUI environment, but the weak capture keeps the
            // closure Sendable-safe.
            guard let self else {
                await MainActor.run {
                    Self.applySendOutcome(
                        .cancelled,
                        session: session,
                        sendGeneration: sendGeneration,
                        initialAliases: initialAliases,
                        appState: nil
                    )
                }
                return
            }
            let outcome: SendOutcome
            do {
                try await LocalPiTurnRunner().run(
                    host: self.host,
                    request: launchRequest,
                    prompt: taggedPrompt,
                    attachments: attachments,
                    sessionRootCandidates: sessionRootCandidates,
                    onEvent: { [weak self, weak session] event in
                        guard let self else { return }
                        await MainActor.run {
                            guard let session else { return }
                            self.applyTurnStreamEvent(event, to: session)
                        }
                    }
                )
                outcome = .success
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            await MainActor.run {
                Self.applySendOutcome(
                    outcome,
                    session: session,
                    sendGeneration: sendGeneration,
                    initialAliases: initialAliases,
                    appState: self
                )
            }
        }
        session.sendTask = task

        return true
    }

    /// Outcome of a single send. The task body always funnels through
    /// `applySendOutcome` so success, failure, and cancellation take
    /// the same path: the session is mutated on the main actor only
    /// when it is still alive, and the send task reference is always
    /// cleared at the end.
    fileprivate enum SendOutcome: Sendable {
        case success
        case cancelled
        case failure(String)
    }

    /// Apply the outcome of a send. Runs on the main actor; silently
    /// no-ops if the session has been deallocated (e.g. the tab was
    /// closed mid-send). Always clears `session.sendTask` so the store
    /// stops reporting the session as busy.
    fileprivate static func applySendOutcome(
        _ outcome: SendOutcome,
        session: ChatSession?,
        sendGeneration: Int,
        initialAliases: [String],
        appState: PiAppState?
    ) {
        defer {
            if session?.currentSendGeneration == sendGeneration {
                session?.sendTask = nil
            }
        }
        guard let session,
              session.currentSendGeneration == sendGeneration else { return }
        switch outcome {
        case .success:
            session.finishSendingAndReload()
            appState?.completeSend(for: session, fallbackAliases: initialAliases)
            appState?.statusMessage = "Pi replied"
            appState?.scheduleCatalogRefresh(after: .seconds(0.2))
        case .cancelled:
            // Cancellation is an expected user action (closing the
            // tab, switching hosts, hitting a future "stop" button).
            // Reset the composer without surfacing an error.
            session.finishSendingCancelled()
            appState?.setSessionSending(false, aliases: initialAliases)
            appState?.removeOptimisticSidebarSessionIfNeeded(matching: initialAliases)
        case .failure(let message):
            session.finishSendingWithError(message)
            let aliases = appState?.sessionAliases(for: session, fallback: initialAliases) ?? initialAliases
            appState?.setSessionSending(false, aliases: aliases)
            appState?.removeOptimisticSidebarSessionIfNeeded(matching: initialAliases)
            appState?.statusMessage = message
        }
    }

    /// Runs the remote (pi-appd HTTP) send path. The session is
    /// captured weakly so closing the tab mid-send stops further
    /// mutations. Returns a `SendOutcome` for the caller to apply.
    ///
    /// The current release only reaches the daemon transport; the old
    /// SSH path is no longer wired up. This helper is therefore the
    /// "remote turn" entry point in practice, but it is named
    /// `runRemoteTurn` to leave room for an SSH-fallback runtime if
    /// one is reintroduced.
    private func runRemoteTurn(
        session: ChatSession?,
        prompt: String,
        attachments: [ChatAttachment]
    ) async -> SendOutcome {
        do {
            let daemonAttachments = try await self.uploadAttachmentsIfNeeded(attachments)
            if let sessionID = session?.sessionID?.nilIfBlank {
                try await RemoteDaemonClient().streamSend(
                    host: self.host,
                    sessionID: sessionID,
                    prompt: prompt,
                    attachments: daemonAttachments,
                    onEvent: { [weak self, weak session] event in
                        guard let self else { return }
                        await MainActor.run {
                            guard let session else { return }
                            self.applyTurnStreamEvent(event, to: session)
                        }
                    }
                )
            } else if let launchRequest = session?.launchRequest {
                try await RemoteDaemonClient().streamNewSession(
                    host: self.host,
                    request: launchRequest,
                    prompt: prompt,
                    attachments: daemonAttachments,
                    onEvent: { [weak self, weak session] event in
                        guard let self else { return }
                        await MainActor.run {
                            guard let session else { return }
                            self.applyTurnStreamEvent(event, to: session)
                        }
                    }
                )
            } else {
                throw RemoteDaemonError.requestFailed(status: 400, body: "Session is missing an ID.")
            }
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func applyTurnStreamEvent(_ event: PiTurnStreamEvent, to session: ChatSession) {
        switch event {
        case .sessionBound(let binding):
            let previousAliases = sessionAliases(for: session)
            let title = binding.title == "Pi" ? session.title : binding.title
            let eventLoader = binding.sessionID.flatMap { remoteEventLoader(sessionID: $0) }
            let historyPageLoader = binding.sessionID.flatMap { remoteHistoryPageLoader(sessionID: $0) }
            session.bindToSession(
                key: binding.key,
                title: title,
                sessionID: binding.sessionID,
                sessionPath: binding.sessionPath,
                eventLoader: eventLoader,
                historyPageLoader: historyPageLoader
            )
            migrateSessionState(from: previousAliases, to: sessionAliases(for: session))
            upsertSidebarSession(for: session, previousAliases: previousAliases, fallbackWorkingDirectory: binding.workingDirectory)
            // The key changed from `new:<UUID>` to the real file path,
            // so the persisted tabs snapshot is now stale. Save again.
            schedulePersistedChatTabsSave()
            restartSelectedSessionEventStream()
            scheduleCatalogRefresh(after: .milliseconds(50))
            refreshSessionRuntime(for: session, updatesStatus: false)
            applyCachedAvailableModels(to: session)
        case .sessionHeader(let meta):
            if session.sessionID == nil {
                let previousAliases = sessionAliases(for: session)
                session.bindToSession(
                    sessionID: meta.id,
                    sessionPath: session.sessionPath,
                    eventLoader: session.sessionPath == nil ? remoteEventLoader(sessionID: meta.id) : nil,
                    historyPageLoader: remoteHistoryPageLoader(sessionID: meta.id)
                )
                migrateSessionState(from: previousAliases, to: sessionAliases(for: session))
                upsertSidebarSession(for: session, previousAliases: previousAliases, fallbackWorkingDirectory: meta.workingDirectory)
                schedulePersistedChatTabsSave()
                restartSelectedSessionEventStream()
                scheduleCatalogRefresh(after: .milliseconds(50))
                refreshSessionRuntime(for: session, updatesStatus: false)
                applyCachedAvailableModels(to: session)
            }
        case .sessionEvents(let events, let isFinal):
            session.applyStreamingEvents(events, isFinal: isFinal)
        case .turnEnd:
            session.markTurnOutputComplete()
        case .agentEnd:
            session.applyStreamingEvents([], isFinal: true)
        case .outputComplete:
            session.finishSendingAndReload()
        case .streamError(let message):
            statusMessage = message
        }
    }

    func hydratePendingSessionDefaults(for session: ChatSession) {
        guard host.usesRemoteDaemonTransport,
              session.sessionID == nil,
              let launchRequest = session.launchRequest else { return }

        _ = applyBestKnownSessionDefaults(to: session)

        let remoteHost = host
        Task { [weak self, weak session] in
            do {
                let snapshot = try await RemoteDaemonClient().loadSessionDefaults(
                    host: remoteHost,
                    workingDirectory: launchRequest.workingDirectory
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteHost, session.sessionID == nil else { return }
                    self.cacheSessionDefaults(snapshot, for: launchRequest.workingDirectory)
                    var request = session.launchRequest ?? launchRequest
                    if request.initialModelProvider == nil { request.initialModelProvider = snapshot.runtimeState.provider }
                    if request.initialModelID == nil { request.initialModelID = snapshot.runtimeState.modelID }
                    if request.initialThinkingLevel == nil { request.initialThinkingLevel = snapshot.runtimeState.thinkingLevel }
                    session.updateLaunchRequest(request)
                    session.updateRuntimeState(snapshot.runtimeState)
                    session.updateAvailableModels(snapshot.availableModels)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshSessionRuntime(for session: ChatSession, updatesStatus: Bool = false) {
        guard host.usesRemoteDaemonTransport else {
            session.updateRuntimeState(nil)
            return
        }
        guard let sessionID = session.sessionID?.nilIfBlank else {
            hydratePendingSessionDefaults(for: session)
            return
        }

        let remoteHost = host
        let sessionKey = runtimeSessionKey(for: session)
        let observedThinkingMutationVersion = thinkingLevelMutationVersionBySessionKey[sessionKey] ?? 0
        Task { [weak self, weak session] in
            do {
                let runtime = try await RemoteDaemonClient().loadSessionRuntime(
                    host: remoteHost,
                    sessionID: sessionID
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteHost else { return }
                    guard (self.thinkingLevelMutationVersionBySessionKey[sessionKey] ?? 0) == observedThinkingMutationVersion else { return }
                    let effectiveRuntime = self.runtimeApplyingPendingThinkingLevel(runtime, sessionKey: sessionKey)
                    session.updateRuntimeState(effectiveRuntime)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if updatesStatus {
                        self.statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func refreshAvailableModels(for session: ChatSession, force: Bool = false) {
        guard host.usesRemoteDaemonTransport else {
            session.updateAvailableModels([])
            return
        }
        if !force, !session.availableModels.isEmpty { return }
        if applyCachedAvailableModels(to: session) { return }
        if isLoadingAvailableModels { return }

        isLoadingAvailableModels = true
        let remoteHost = host
        Task { [weak self, weak session] in
            do {
                let models = try await RemoteDaemonClient().loadAvailableModels(host: remoteHost)
                await MainActor.run {
                    guard let self, self.host == remoteHost else { return }
                    self.availableModelsCache = models
                    self.availableModelsCacheLoadedAt = Date()
                    self.isLoadingAvailableModels = false
                    for tab in self.chatWorkspace.tabs where tab.availableModels.isEmpty {
                        tab.updateAvailableModels(models)
                    }
                    if let session {
                        session.updateAvailableModels(models)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isLoadingAvailableModels = false
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    private func applyCachedAvailableModels(to session: ChatSession) -> Bool {
        guard !availableModelsCache.isEmpty else { return false }
        if let loadedAt = availableModelsCacheLoadedAt,
           Date().timeIntervalSince(loadedAt) > 6 * 60 * 60 {
            return false
        }
        if session.availableModels.isEmpty {
            session.updateAvailableModels(availableModelsCache)
        }
        return true
    }

    func selectModel(_ model: PiModelOption, in session: ChatSession) {
        guard host.usesRemoteDaemonTransport else {
            statusMessage = "Model selection is unavailable for this host."
            return
        }

        if session.sessionID == nil {
            if var request = session.launchRequest {
                request.initialModelProvider = model.provider
                request.initialModelID = model.modelID
                session.updateLaunchRequest(request)
            }
            if let current = session.runtimeState {
                session.updateRuntimeState(
                    SessionRuntimeState(
                        sessionID: current.sessionID,
                        sessionPath: current.sessionPath,
                        provider: model.provider,
                        modelID: model.modelID,
                        modelName: model.name,
                        thinkingLevel: current.thinkingLevel,
                        tokens: current.tokens,
                        contextUsage: current.contextUsage
                    )
                )
            }
            statusMessage = "Model: \(model.shortLabel)"
            return
        }

        guard let sessionID = session.sessionID?.nilIfBlank else {
            statusMessage = "Model selection is available after the session starts."
            return
        }

        if let current = session.runtimeState {
            session.updateRuntimeState(
                SessionRuntimeState(
                    sessionID: current.sessionID,
                    sessionPath: current.sessionPath,
                    provider: model.provider,
                    modelID: model.modelID,
                    modelName: model.name,
                    thinkingLevel: current.thinkingLevel,
                    tokens: current.tokens,
                    contextUsage: current.contextUsage
                )
            )
        }

        let remoteHost = host
        statusMessage = "Switching model..."
        Task { [weak self, weak session] in
            do {
                let runtime = try await RemoteDaemonClient().setSessionModel(
                    host: remoteHost,
                    sessionID: sessionID,
                    provider: model.provider,
                    modelID: model.modelID
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteHost else { return }
                    session.updateRuntimeState(runtime)
                    self.statusMessage = "Model: \(runtime.modelDisplayName)"
                }
            } catch {
                await MainActor.run {
                    guard let self, let session else { return }
                    self.statusMessage = error.localizedDescription
                    self.refreshSessionRuntime(for: session, updatesStatus: false)
                }
            }
        }
    }

    func cycleThinkingLevel(in session: ChatSession) {
        guard host.usesRemoteDaemonTransport else {
            statusMessage = "Thinking level is unavailable for this host."
            return
        }

        if session.sessionID == nil {
            let nextLevel = nextThinkingLevel(after: session.runtimeState?.thinkingLevel ?? "off")
            if var request = session.launchRequest {
                request.initialThinkingLevel = nextLevel
                session.updateLaunchRequest(request)
            }
            if let current = session.runtimeState {
                session.updateRuntimeState(
                    SessionRuntimeState(
                        sessionID: current.sessionID,
                        sessionPath: current.sessionPath,
                        provider: current.provider,
                        modelID: current.modelID,
                        modelName: current.modelName,
                        thinkingLevel: nextLevel,
                        tokens: current.tokens,
                        contextUsage: current.contextUsage
                    )
                )
            }
            statusMessage = "Thinking: \(nextLevel)"
            return
        }

        guard let sessionID = session.sessionID?.nilIfBlank else {
            statusMessage = "Thinking level is available after the session starts."
            return
        }

        let currentLevel = effectiveThinkingLevel(for: session)
        let nextLevel = nextThinkingLevel(after: currentLevel)
        let sessionKey = runtimeSessionKey(for: session)
        let mutationVersion = nextThinkingLevelMutationVersion(for: sessionKey)
        pendingThinkingLevelBySessionKey[sessionKey] = nextLevel

        if let current = session.runtimeState {
            session.updateRuntimeState(
                SessionRuntimeState(
                    sessionID: current.sessionID,
                    sessionPath: current.sessionPath,
                    provider: current.provider,
                    modelID: current.modelID,
                    modelName: current.modelName,
                    thinkingLevel: nextLevel,
                    tokens: current.tokens,
                    contextUsage: current.contextUsage
                )
            )
        }
        statusMessage = "Thinking: \(nextLevel)"

        let remoteHost = host
        Task { [weak self, weak session] in
            do {
                let runtime = try await RemoteDaemonClient().setSessionThinkingLevel(
                    host: remoteHost,
                    sessionID: sessionID,
                    level: nextLevel
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteHost else { return }
                    guard self.thinkingLevelMutationVersionBySessionKey[sessionKey] == mutationVersion else { return }
                    self.pendingThinkingLevelBySessionKey.removeValue(forKey: sessionKey)
                    session.updateRuntimeState(runtime)
                    self.statusMessage = "Thinking: \(runtime.thinkingLevel)"
                }
            } catch {
                await MainActor.run {
                    guard let self, let session else { return }
                    guard self.thinkingLevelMutationVersionBySessionKey[sessionKey] == mutationVersion else { return }
                    self.pendingThinkingLevelBySessionKey.removeValue(forKey: sessionKey)
                    self.statusMessage = error.localizedDescription
                    self.refreshSessionRuntime(for: session, updatesStatus: false)
                }
            }
        }
    }

    private func nextThinkingLevel(after currentLevel: String) -> String {
        let levels = ["off", "minimal", "low", "medium", "high", "xhigh"]
        let normalized = currentLevel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let index = levels.firstIndex(of: normalized) else {
            return "off"
        }
        return levels[(index + 1) % levels.count]
    }

    private func effectiveThinkingLevel(for session: ChatSession) -> String {
        let sessionKey = runtimeSessionKey(for: session)
        if let pending = pendingThinkingLevelBySessionKey[sessionKey]?.nilIfBlank {
            return pending
        }
        return session.runtimeState?.thinkingLevel ?? "off"
    }

    private func runtimeSessionKey(for session: ChatSession) -> String {
        if let sessionID = session.sessionID?.nilIfBlank {
            return "id:\(sessionID)"
        }
        if let sessionPath = session.sessionPath?.nilIfBlank {
            return "path:\(sessionPath)"
        }
        return "key:\(session.key)"
    }

    private func nextThinkingLevelMutationVersion(for sessionKey: String) -> Int {
        let next = (thinkingLevelMutationVersionBySessionKey[sessionKey] ?? 0) + 1
        thinkingLevelMutationVersionBySessionKey[sessionKey] = next
        return next
    }

    private func runtimeApplyingPendingThinkingLevel(_ runtime: SessionRuntimeState, sessionKey: String) -> SessionRuntimeState {
        guard let pendingLevel = pendingThinkingLevelBySessionKey[sessionKey]?.nilIfBlank,
              pendingLevel != runtime.thinkingLevel else {
            return runtime
        }
        return SessionRuntimeState(
            sessionID: runtime.sessionID,
            sessionPath: runtime.sessionPath,
            provider: runtime.provider,
            modelID: runtime.modelID,
            modelName: runtime.modelName,
            thinkingLevel: pendingLevel,
            tokens: runtime.tokens,
            contextUsage: runtime.contextUsage
        )
    }

    func delete(_ session: PiSessionSummary) {
        guard !host.usesRemoteDaemonTransport && host.mode == .local else {
            statusMessage = "Remote session deletion is not supported from pi-app."
            return
        }

        if let openTab = chatWorkspace.tabs.first(where: { $0.key == session.filePath }) {
            chatWorkspace.close(openTab)
        }

        do {
            try Foundation.FileManager().removeItem(atPath: session.filePath)
            sessions.removeAll { $0.filePath == session.filePath }
            clearSessionState(for: session)
            if selectedSession?.filePath == session.filePath {
                selection = projects.first(where: { $0.id == session.projectID }).map { .project($0.id) }
            }
            statusMessage = "Deleted \(session.title)"
            refreshCatalog()
        } catch {
            statusMessage = "Could not delete \(session.title): \(error.localizedDescription)"
        }
    }

    // MARK: - SSH host helpers

    /// Parses the user's `~/.ssh/config` and returns the selectable host
    /// aliases. Cheap to call repeatedly — the file is small.
    func loadSSHConfigEntries() -> [SSHConfigEntry] {
        SSHConfigParser.parseUserConfig()
    }

    /// Lists the keys Apple Pi can offer in the identity-file picker.
    func loadSSHKeys() -> [SSHKeyStore.Key] {
        SSHKeyStore.discoverKeys()
    }

    /// Applies a parsed `~/.ssh/config` entry to the current host settings.
    /// Fields the user has customised manually are not overwritten.
    ///
    /// We mutate a local copy and assign once at the end. Each per-field
    /// write to `host` fires `host.didSet` which in turn schedules a
    /// catalog refresh; assigning the whole struct keeps the refresh to a
    /// single round trip.
    func applySSHConfigEntry(_ entry: SSHConfigEntry) {
        var next = host
        next.remoteSSHConfigAlias = entry.hostPatterns.joined(separator: ",")
        if let hostName = entry.hostName?.nilIfBlank {
            next.remoteHost = hostName
        } else if next.remoteHost.isEmpty, let first = entry.hostPatterns.first(where: { !$0.hasSuffix("*") && !$0.hasPrefix("*") }) {
            next.remoteHost = first
        }
        if let user = entry.user?.nilIfBlank {
            next.remoteUser = user
        }
        if let port = entry.port {
            next.remotePort = port
        }
        if let identityFile = entry.identityFile?.nilIfBlank {
            next.remoteIdentityFile = identityFile
            next.remoteAuthMethod = .publicKey
        }
        host = next
    }

    /// Clears the alias selection so the host fields can be edited freely.
    func clearSSHConfigAlias() {
        host.remoteSSHConfigAlias = ""
    }

    /// Persists the supplied password for the current host. Returns an error
    /// message on failure, nil on success.
    @discardableResult
    func saveRemotePassword(_ password: String, for targetHost: PiHostConfiguration? = nil) -> String? {
        do {
            try RemoteCredentialStore.savePassword(password, for: targetHost ?? host)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func clearRemotePassword(for targetHost: PiHostConfiguration? = nil) -> String? {
        do {
            try RemoteCredentialStore.deletePassword(for: targetHost ?? host)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func hasRemotePasswordStored(for targetHost: PiHostConfiguration? = nil) -> Bool {
        RemoteCredentialStore.hasPassword(for: targetHost ?? host)
    }

    @discardableResult
    func saveRemoteDaemonToken(_ token: String, for targetHost: PiHostConfiguration? = nil) -> String? {
        do {
            try RemoteDaemonTokenStore.saveToken(token, for: targetHost ?? host)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func clearRemoteDaemonToken(for targetHost: PiHostConfiguration? = nil) -> String? {
        do {
            try RemoteDaemonTokenStore.deleteToken(for: targetHost ?? host)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func hasRemoteDaemonTokenStored(for targetHost: PiHostConfiguration? = nil) -> Bool {
        RemoteDaemonTokenStore.hasToken(for: targetHost ?? host)
    }

    @discardableResult
    func saveGroqAPIKey(_ token: String) -> String? {
        do {
            try GroqAPIKeyStore.saveKey(token)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func clearGroqAPIKey() -> String? {
        do {
            try GroqAPIKeyStore.deleteKey()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func hasGroqAPIKeyStored() -> Bool {
        GroqAPIKeyStore.hasKey()
    }

    func groqAPIKey() -> String? {
        GroqAPIKeyStore.readKey()
    }

    private func scheduleCatalogRefresh(after delay: Duration = .seconds(1)) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await MainActor.run {
                self?.refreshCatalog()
            }
        }
    }

    func refreshConfigurationSummary() {
        if host.usesRemoteDaemonTransport || host.mode == .remoteSSH {
            configurationSummary = PiConfigurationSummary.remote(
                host: host,
                projectDirectory: activeProject?.workingDirectory
            )
            return
        }

        configurationSummary = configurationService.loadSummary(
            host: host,
            projectDirectory: activeProject?.workingDirectory
        )
    }

    func openGlobalSettings() {
        openPath(configurationSummary.globalSettingsPath)
    }

    func revealAgentDirectory() {
        revealPath(configurationSummary.agentDirectoryPath)
    }

    func openConfigurationMetric(_ metric: PiConfigurationMetric) {
        switch metric {
        case .config:
            openFirstOrReveal(paths: configurationSummary.settingsPaths, fallback: configurationSummary.agentDirectoryPath)
        case .instructions:
            openFirstOrReveal(paths: configurationSummary.contextFilePaths, fallback: configurationSummary.projectDirectory ?? configurationSummary.agentDirectoryPath)
        case .resources:
            revealPath(configurationSummary.resourceRootPaths.first ?? configurationSummary.agentDirectoryPath)
        }
    }

    func openProjectSettings(for project: PiProject? = nil) {
        let path = project?.workingDirectory.map { "\($0)/.pi/settings.json" } ?? configurationSummary.projectSettingsPath
        openPath(path)
    }

    func openAgentsFile(for project: PiProject? = nil) {
        guard let directory = project?.workingDirectory ?? configurationSummary.projectDirectory else { return }
        let candidates = ["\(directory)/AGENTS.md", "\(directory)/.pi/AGENTS.md"]
        openPath(candidates.first(where: { Foundation.FileManager().fileExists(atPath: $0) }))
    }

    func revealProjectDirectory(for project: PiProject) {
        revealPath(project.workingDirectory)
    }

    func revealProjectPiDirectory(for project: PiProject? = nil) {
        guard let directory = project?.workingDirectory ?? configurationSummary.projectDirectory else { return }
        revealPath("\(directory)/.pi")
    }

    func pathExists(_ path: String?) -> Bool {
        guard let path else { return false }
        return Foundation.FileManager().fileExists(atPath: path)
    }

    private func repairSelectionIfNeeded() {
        guard let selection else {
            self.selection = projects.first.map { .project($0.id) }
            return
        }
        switch selection {
        case .project(let id):
            if !projects.contains(where: { $0.id == id }) {
                self.selection = projects.first.map { .project($0.id) }
            }
        case .session(let id):
            if !sessions.contains(where: { $0.id == id || $0.filePath == id }) {
                self.selection = projects.first.map { .project($0.id) }
            }
        }
        refreshConfigurationSummary()
    }

    private func clearCatalog() {
        projects = []
        sessions = []
        selection = nil
        sendingSessionKeys = []
        unreadSessionKeys = []
        sessionActivityOverrides = [:]
        sessionDefaultsCache = [:]
        availableModelsCache = []
        availableModelsCacheLoadedAt = nil
        isLoadingAvailableModels = false
        // Open chat tabs reference `sessionPath` values from the previous
        // host, so close them. Without this the user sees stale
        // conversations after a host change.
        chatWorkspace.closeAll(notify: false)
        // Also wipe the SSH directory browser state — it is per-host and
        // would otherwise flash stale entries when the user reopens the
        // "New Session in Folder" sheet.
        remoteDirectoryEntries = []
        remoteDirectoryPath = ""
        remoteDirectoryParent = nil
        remoteDirectoryStatus = ""
        newSessionWorkingDirectory = ""
        // Stop live SSE subscriptions — they are tied to the old host.
        stopSelectedSessionEventStream()
        stopCatalogLiveUpdates()
    }

    // MARK: - Live catalog subscription

    /// Starts (or restarts) the long-lived SSE subscription for the
    /// current host. No-op when the host does not use the daemon
    /// transport, or when the task is already running for that host.
    private func startCatalogLiveUpdates() {
        stopCatalogLiveUpdates()
        guard host.usesRemoteDaemonTransport else { return }
        let streamHost = host
        catalogStreamTask = Task { [weak self] in
            await self?.runCatalogLiveUpdates(host: streamHost)
        }
    }

    /// Cancels the SSE subscription, if any. Safe to call from any
    /// state — including when no task is running.
    private func stopCatalogLiveUpdates() {
        catalogStreamTask?.cancel()
        catalogStreamTask = nil
        isCatalogStreamConnected = false
    }

    private func startCatalogAdaptivePolling() {
        catalogPollingTask?.cancel()
        catalogPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval: Duration = self.isApplicationActive ? .seconds(3) : .seconds(30)
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard self.host.usesRemoteDaemonTransport,
                      !self.isLoadingCatalog,
                      !self.isCatalogStreamConnected else { continue }
                self.refreshCatalog(quietly: true)
            }
        }
    }

    private func stopCatalogAdaptivePolling() {
        catalogPollingTask?.cancel()
        catalogPollingTask = nil
    }

    private func startApplicationActivityObservers() {
        guard activityObservers.isEmpty else { return }
        isApplicationActive = NSApp?.isActive ?? true
        let center = NotificationCenter.default
        activityObservers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isApplicationActive = true
                    if self.host.usesRemoteDaemonTransport,
                       !self.isLoadingCatalog,
                       !self.isCatalogStreamConnected {
                        self.refreshCatalog(quietly: true)
                    }
                    await self.syncSelectedRemoteSessionDelta()
                }
            }
        )
        activityObservers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isApplicationActive = false
                }
            }
        )
    }

    private func restartSelectedSessionEventStream() {
        stopSelectedSessionEventStream()
        guard startsBackgroundWork,
              host.usesRemoteDaemonTransport,
              let session = chatWorkspace.selectedTab,
              let sessionID = session.sessionID?.nilIfBlank else { return }

        // Skeleton: show the runtime immediately from the cached JSONL
        // parse (handled inside the fast runtime endpoint) so the
        // model/thinking chip is never blank while the stream warms up.
        refreshSessionRuntime(for: session)

        let streamHost = host
        let selectedTabID = session.id
        selectedSessionStreamTask = Task { [weak self] in
            await self?.runSelectedSessionEventStream(
                host: streamHost,
                sessionID: sessionID,
                selectedTabID: selectedTabID
            )
        }
    }

    private func stopSelectedSessionEventStream() {
        selectedSessionStreamTask?.cancel()
        selectedSessionStreamTask = nil
    }

    private func runSelectedSessionEventStream(
        host streamHost: PiHostConfiguration,
        sessionID: String,
        selectedTabID: ChatSession.ID
    ) async {
        let client = RemoteDaemonClient()
        var backoff = Duration.seconds(1)
        let maxBackoff = Duration.seconds(30)

        while !Task.isCancelled {
            guard host == streamHost,
                  let session = chatWorkspace.selectedTab,
                  session.id == selectedTabID,
                  session.sessionID?.nilIfBlank == sessionID else {
                return
            }

            let after = session.lastPersistedLineIndex
            let stream = client.streamSessionEventPages(
                host: streamHost,
                sessionID: sessionID,
                after: after
            )
            var receivedEvent = false
            do {
                for try await page in stream {
                    receivedEvent = true
                    backoff = .seconds(1)
                    guard host == streamHost,
                          let currentSession = chatWorkspace.selectedTab,
                          currentSession.id == selectedTabID,
                          currentSession.sessionID?.nilIfBlank == sessionID else {
                        return
                    }
                    applySessionStreamPage(page, to: currentSession)
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: backoff)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    return
                }
                if !receivedEvent {
                    statusMessage = "Live session stream lost: \(error.localizedDescription). Retrying…"
                }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, maxBackoff)
            }
        }
    }

    private func applySessionStreamPage(_ page: SessionEventsPage, to session: ChatSession) {
        guard !session.isLoading else { return }
        // While the user is actively sending, the POST NDJSON stream owns the
        // optimistic timeline. The final output_complete reload reconciles the
        // persisted log; the session SSE stream is the production live path for
        // non-local writes and reconnect catch-up.
        guard !session.isSending else { return }
        let after = session.lastPersistedLineIndex
        if let firstLine = page.firstLine,
           !page.events.isEmpty,
           firstLine <= after {
            return
        }
        session.appendPersistedPage(page)
    }

    private func startSelectedSessionEventPolling() {
        selectedSessionPollingTask?.cancel()
        selectedSessionPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // When the per-session SSE stream is healthy, polling is
                // pure overhead (and risks racing with the optimistic
                // in-flight state). Keep this loop only as a slow safety
                // net for the rare case where the stream is down.
                let interval: Duration = self.selectedSessionStreamTask == nil && self.isApplicationActive
                    ? .seconds(2)
                    : .seconds(30)
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self.syncSelectedRemoteSessionDelta()
            }
        }
    }

    private func syncSelectedRemoteSessionDelta() async {
        guard host.usesRemoteDaemonTransport else { return }
        // The per-session SSE stream is the primary live path. Polling is
        // only useful when the stream is down, so skip the round-trip
        // entirely while it is healthy.
        guard selectedSessionStreamTask == nil else { return }
        guard let session = chatWorkspace.selectedTab,
              let sessionID = session.sessionID?.nilIfBlank,
              !session.isLoading,
              !session.isSending else {
            return
        }

        let after = session.lastPersistedLineIndex
        guard after >= 0 else {
            session.loadFromDisk(force: true)
            return
        }

        let remoteHost = host
        let selectedTabID = session.id
        do {
            async let deltaTask = RemoteDaemonClient().loadSessionEventPage(
                host: remoteHost,
                sessionID: sessionID,
                limit: 200,
                after: after
            )
            async let runtimeTask = RemoteDaemonClient().loadSessionRuntime(
                host: remoteHost,
                sessionID: sessionID
            )
            let (delta, runtime) = try await (deltaTask, runtimeTask)
            guard self.host == remoteHost,
                  self.chatWorkspace.selectedTab?.id == selectedTabID else {
                return
            }
            if let firstLine = delta.firstLine,
               !delta.events.isEmpty,
               firstLine <= after {
                session.loadFromDisk(force: true)
                return
            }
            session.appendPersistedPage(delta)
            let sessionKey = runtimeSessionKey(for: session)
            session.updateRuntimeState(runtimeApplyingPendingThinkingLevel(runtime, sessionKey: sessionKey))
            applyCachedAvailableModels(to: session)
        } catch {
            // Best-effort background sync: keep the current transcript and
            // let catalog polling / manual reload recover.
        }
    }

    /// Outer reconnect loop. On every successful event the backoff
    /// resets, so a stable connection pays only the per-event cost. On
    /// any failure (network, auth, malformed event) we sleep with an
    /// exponentially growing delay, capped at 30s. Cancellation is
    /// observed after each iteration so a host change can tear us down
    /// promptly.
    private func runCatalogLiveUpdates(host: PiHostConfiguration) async {
        let client = RemoteDaemonClient()
        var backoff = Duration.seconds(1)
        let maxBackoff = Duration.seconds(30)

        while !Task.isCancelled {
            let stream = client.streamCatalogSnapshots(host: host)
            var receivedEvent = false
            do {
                for try await event in stream {
                    receivedEvent = true
                    isCatalogStreamConnected = true
                    backoff = .seconds(1)
                    applyCatalogStreamEvent(event)
                }
                isCatalogStreamConnected = false
                if Task.isCancelled { return }
                try? await Task.sleep(for: backoff)
            } catch is CancellationError {
                isCatalogStreamConnected = false
                return
            } catch {
                isCatalogStreamConnected = false
                if Task.isCancelled { return }
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    return
                }
                if !receivedEvent {
                    statusMessage = "Live catalog lost: \(error.localizedDescription). Retrying…"
                }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, maxBackoff)
            }
        }
    }

    /// Applies a typed event from the global SSE channel. The first event
    /// is always a full snapshot; subsequent events are small deltas.
    private func applyCatalogStreamEvent(_ event: CatalogStreamEvent) {
        switch event {
        case .snapshot(let snapshot):
            projects = snapshot.projects
            sessions = snapshot.sessions
            if !snapshot.warnings.isEmpty {
                statusMessage = PiAppState.catalogStatusMessage(
                    sessionCount: snapshot.sessions.count,
                    warnings: snapshot.warnings
                )
            }
            repairSelectionIfNeeded()
            refreshConfigurationSummary()
        case .sessionUpdated(let summary):
            if let index = sessions.firstIndex(where: { $0.id == summary.id || $0.filePath == summary.filePath }) {
                sessions[index] = summary
            } else {
                sessions.append(summary)
                sessions.sort { $0.modifiedAt > $1.modifiedAt }
            }
            repairSelectionIfNeeded()
        case .sessionRemoved(let sessionId):
            sessions.removeAll { $0.id == sessionId || $0.filePath == sessionId }
            repairSelectionIfNeeded()
        case .runtimeChanged(let sessionId, let runtime):
            if sessionId.isEmpty { return }
            for tab in chatWorkspace.tabs where tab.sessionID?.nilIfBlank == sessionId {
                tab.updateRuntimeState(runtime)
            }
        case .unknown:
            break
        }
    }

    /// Builds a short status-bar message that lists the session count
    /// and any non-fatal catalog warnings, so the user actually sees
    /// "skipped 2 unreadable files" instead of getting a silently
    /// truncated catalog.
    static func catalogStatusMessage(sessionCount: Int, warnings: [String]) -> String {
        let prefix = "Loaded \(sessionCount) Pi session\(sessionCount == 1 ? "" : "s")"
        guard !warnings.isEmpty else { return prefix }
        let firstFew = warnings.prefix(3).joined(separator: " ")
        let suffix = warnings.count > 3 ? " (+ \(warnings.count - 3) more)" : ""
        return "\(prefix). \(firstFew)\(suffix)"
    }

    private func loadHost() {
        guard let data = defaults.data(forKey: hostDefaultsKey),
              let decoded = try? JSONDecoder().decode(PiHostConfiguration.self, from: data) else {
            return
        }
        host = decoded
    }

    private func saveHost() {
        guard let data = try? JSONEncoder().encode(host) else { return }
        defaults.set(data, forKey: hostDefaultsKey)
    }

    private func loadAppearance() {
        guard let data = defaults.data(forKey: appearanceDefaultsKey),
              let decoded = try? JSONDecoder().decode(AppAppearance.self, from: data) else {
            return
        }
        appearance = decoded
    }

    private func saveAppearance() {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: appearanceDefaultsKey)
    }

    private func loadShortcutPreferences() {
        guard let data = defaults.data(forKey: shortcutDefaultsKey),
              let decoded = try? JSONDecoder().decode(AppShortcutPreferences.self, from: data) else {
            return
        }
        shortcutPreferences = decoded
    }

    private func saveShortcutPreferences() {
        guard let data = try? JSONEncoder().encode(shortcutPreferences) else { return }
        defaults.set(data, forKey: shortcutDefaultsKey)
    }

    // MARK: - Chat tab persistence

    /// Builds a snapshot of the current open tabs (filtered to only
    /// file-backed or remote sessions) and writes it to `UserDefaults`.
    /// Safe to call on every mutation; the actual write is debounced via
    /// `schedulePersistedChatTabsSave` for the hot path.
    func savePersistedChatTabs() {
        let tabs = chatWorkspace.tabs.compactMap { session -> PersistedChatTab? in
            guard Self.isPersistedTabKey(session.key) else { return nil }
            return PersistedChatTab(
                key: session.key,
                title: session.title,
                sessionID: session.sessionID
            )
        }
        // Only persist the selected key if the selected tab is also
        // persisted-worthy. A `new:<UUID>` selection would never be
        // resolvable on the next launch, so it is intentionally dropped.
        let selectedKey: String? = {
            guard let key = chatWorkspace.selectedTab?.key,
                  Self.isPersistedTabKey(key) else { return nil }
            return key
        }()
        let snapshot = PersistedChatTabsSnapshot(
            hostFingerprint: host.persistenceFingerprint,
            tabs: tabs,
            selectedTabKey: selectedKey
        )
        chatTabPersistence.save(snapshot)
    }

    /// Debounces `savePersistedChatTabs` so a burst of mutations during
    /// streaming (e.g. successive `bindToSession` calls) collapses into
    /// a single write.
    func schedulePersistedChatTabsSave() {
        chatTabsSaveTask?.cancel()
        chatTabsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            await MainActor.run {
                self?.savePersistedChatTabs()
            }
        }
    }

    /// Reopens tabs and restores the selected tab from the persisted
    /// snapshot. Skips tabs whose underlying local file no longer
    /// exists and tolerates remote session IDs that the daemon has
    /// forgotten (the loader surfaces a `loadError`, the tab is not
    /// created in a way that could crash).
    func restorePersistedChatTabs() {
        guard let snapshot = chatTabPersistence.load() else { return }
        // Different host: keep the snapshot on disk (it will be
        // overwritten on the next save) but do not reopen any tabs.
        guard snapshot.hostFingerprint == host.persistenceFingerprint else { return }

        let isRemote = host.usesRemoteDaemonTransport || host.mode == .remoteSSH
        let fileManager = Foundation.FileManager()
        let selectedKey = snapshot.selectedTabKey

        for tab in snapshot.tabs {
            let shouldLoadImmediately = tab.key == selectedKey
            guard Self.isPersistedTabKey(tab.key) else { continue }
            if isRemote {
                let loader = tab.sessionID.flatMap { remoteEventLoader(sessionID: $0) }
                let historyLoader = tab.sessionID.flatMap { remoteHistoryPageLoader(sessionID: $0) }
                chatWorkspace.openOrSelectTab(
                    key: tab.key,
                    title: tab.title,
                    sessionID: tab.sessionID,
                    sessionPath: nil,
                    eventLoader: loader,
                    historyPageLoader: historyLoader,
                    autoLoad: shouldLoadImmediately
                )
            } else {
                // Local: only reopen if the file is still on disk. A
                // missing file is the most common reason a saved tab
                // becomes stale (session was deleted or the agent
                // directory moved).
                guard fileManager.fileExists(atPath: tab.key) else { continue }
                chatWorkspace.openOrSelectTab(
                    key: tab.key,
                    title: tab.title,
                    sessionID: nil,
                    sessionPath: tab.key,
                    eventLoader: nil,
                    autoLoad: shouldLoadImmediately
                )
            }
        }

        if let selectedKey,
           let tab = chatWorkspace.tabs.first(where: { $0.key == selectedKey }) {
            chatWorkspace.select(tab)
        }
    }

    /// `true` for keys that refer to a file-backed or remote session
    /// and are therefore safe to round-trip through persistence. The
    /// `new:<UUID>` and `fork:<path>:<UUID>` prefixes identify
    /// ephemeral tabs that have no on-disk file and no remote ID yet,
    /// so persisting them would produce a tab that the next launch
    /// cannot reopen.
    private static func isPersistedTabKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        if key.hasPrefix("new:") || key.hasPrefix("fork:") { return false }
        return true
    }

    private func openPath(_ path: String?) {
        guard let path, pathExists(path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openFirstOrReveal(paths: [String], fallback: String) {
        if paths.count == 1 {
            openPath(paths.first)
        } else {
            revealPath(paths.first ?? fallback)
        }
    }

    private func revealPath(_ path: String?) {
        guard let path, pathExists(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func sourceTaggedAppPrompt(_ text: String) -> String {
        let tag = "[source:pi-app type=text]"
        if text.hasPrefix(tag) {
            return text
        }
        return "\(tag)\n\(text)"
    }

    private func insertOptimisticSidebarSession(for session: ChatSession, fallbackAliases: [String]) {
        guard !Self.isPersistedTabKey(session.key) else { return }
        upsertSidebarSession(for: session, previousAliases: fallbackAliases)
    }

    private func removeOptimisticSidebarSessionIfNeeded(matching aliases: [String]) {
        let optimisticAliases = aliases.filter { !Self.isPersistedTabKey($0) }
        guard !optimisticAliases.isEmpty else { return }

        var affectedProjectIDs = Set<String>()
        sessions.removeAll { summary in
            let matches = !Set(sessionAliases(for: summary)).isDisjoint(with: Set(optimisticAliases))
            if matches {
                affectedProjectIDs.insert(summary.projectID)
            }
            return matches
        }
        for projectID in affectedProjectIDs {
            reconcileSidebarProject(projectID)
        }
    }

    private func upsertSidebarSession(
        for session: ChatSession,
        previousAliases: [String] = [],
        fallbackWorkingDirectory: String? = nil
    ) {
        guard let summary = sidebarSessionSummary(
            for: session,
            previousAliases: previousAliases,
            fallbackWorkingDirectory: fallbackWorkingDirectory
        ) else {
            return
        }

        let matchingAliases = Set(previousAliases + sessionAliases(for: session))
        let previousProjectID = sessions.first(where: {
            !matchingAliases.isDisjoint(with: Set(sessionAliases(for: $0)))
        })?.projectID

        if let index = sessions.firstIndex(where: { !matchingAliases.isDisjoint(with: Set(sessionAliases(for: $0))) }) {
            sessions[index] = summary
        } else {
            sessions.append(summary)
        }

        reconcileSidebarProject(summary.projectID)
        if let previousProjectID, previousProjectID != summary.projectID {
            reconcileSidebarProject(previousProjectID)
        }
    }

    private func sidebarSessionSummary(
        for session: ChatSession,
        previousAliases: [String] = [],
        fallbackWorkingDirectory: String? = nil
    ) -> PiSessionSummary? {
        let workingDirectory = fallbackWorkingDirectory?.nilIfBlank
            ?? session.launchRequest?.workingDirectory?.nilIfBlank
            ?? selectedWorkingDirectory?.nilIfBlank
        let filePath = session.sessionPath?.nilIfBlank
            ?? session.sessionID?.nilIfBlank
            ?? previousAliases.first(where: { !$0.isEmpty })
            ?? session.key.nilIfBlank
        guard let filePath else { return nil }

        let id = session.sessionID?.nilIfBlank ?? filePath
        let aliases = uniqueAliases([session.sessionID, session.sessionPath, session.key] + previousAliases.map(Optional.some))
        let modifiedAt = aliases.compactMap { sessionActivityOverrides[$0] }.max() ?? Date()
        let projectID = sidebarProjectID(for: workingDirectory)

        return PiSessionSummary(
            id: id,
            filePath: filePath,
            projectID: projectID,
            title: session.title,
            workingDirectory: workingDirectory,
            messageCount: 0,
            modifiedAt: modifiedAt,
            displayName: nil,
            parentSession: nil,
            branchCount: 0,
            labelCount: 0,
            branchSummaryCount: 0,
            latestModel: session.runtimeState?.modelDisplayName.nilIfBlank
        )
    }

    private func sidebarProjectID(for workingDirectory: String?) -> String {
        guard let workingDirectory = workingDirectory?.nilIfBlank else {
            return activeProject?.id ?? "sessions"
        }
        let standardizedPath = (workingDirectory as NSString).standardizingPath
        let components = URL(fileURLWithPath: standardizedPath)
            .pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        guard !components.isEmpty else { return "--root--" }
        return "--\(components.joined(separator: "-"))--"
    }

    private func reconcileSidebarProject(_ projectID: String) {
        let projectSessions = sessions.filter { $0.projectID == projectID }
        guard !projectSessions.isEmpty else {
            projects.removeAll { $0.id == projectID }
            return
        }

        let workingDirectory = projectSessions.compactMap(\.workingDirectory).first
        let title = projects.first(where: { $0.id == projectID })?.title
            ?? workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Sessions"
        let lastActivity = projectSessions
            .map { effectiveLastActivity(for: $0) }
            .max()

        let updated = PiProject(
            id: projectID,
            title: title,
            workingDirectory: workingDirectory,
            sessionDirectory: projectID,
            sessionCount: projectSessions.count,
            lastActivity: lastActivity
        )

        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index] = updated
        } else {
            projects.append(updated)
        }
        projects.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    private func sessionAliases(for session: PiSessionSummary) -> [String] {
        uniqueAliases([session.id, session.filePath])
    }

    private func sessionAliases(for session: ChatSession, fallback: [String] = []) -> [String] {
        uniqueAliases([session.sessionID, session.sessionPath, session.key] + fallback.map(Optional.some))
    }

    private func uniqueAliases(_ aliases: [String?]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rawAlias in aliases {
            guard let rawAlias, let alias = rawAlias.nilIfBlank else { continue }
            if seen.insert(alias).inserted {
                result.append(alias)
            }
        }
        return result
    }

    private func markSessionActive(_ aliases: [String], at date: Date = Date()) {
        for alias in aliases {
            sessionActivityOverrides[alias] = date
        }
    }

    private func setSessionSending(_ isSending: Bool, aliases: [String]) {
        guard !aliases.isEmpty else { return }
        if isSending {
            sendingSessionKeys.formUnion(aliases)
        } else {
            sendingSessionKeys.subtract(aliases)
        }
    }

    private func clearUnread(aliases: [String]) {
        unreadSessionKeys.subtract(aliases)
    }

    private func markUnread(aliases: [String]) {
        unreadSessionKeys.formUnion(aliases)
    }

    private func markSessionRead(_ session: PiSessionSummary) {
        clearUnread(aliases: sessionAliases(for: session))
    }

    private func clearSessionState(for session: PiSessionSummary) {
        let aliases = sessionAliases(for: session)
        sendingSessionKeys.subtract(aliases)
        unreadSessionKeys.subtract(aliases)
        for alias in aliases {
            sessionActivityOverrides.removeValue(forKey: alias)
        }
    }

    private func migrateSessionState(from oldAliases: [String], to newAliases: [String]) {
        guard !oldAliases.isEmpty, !newAliases.isEmpty else { return }
        let lastActivity = oldAliases.compactMap { sessionActivityOverrides[$0] }.max()
        let wasSending = !sendingSessionKeys.isDisjoint(with: Set(oldAliases))
        let wasUnread = !unreadSessionKeys.isDisjoint(with: Set(oldAliases))

        if let lastActivity {
            markSessionActive(newAliases, at: lastActivity)
        }
        if wasSending {
            sendingSessionKeys.formUnion(newAliases)
        }
        if wasUnread {
            unreadSessionKeys.formUnion(newAliases)
        }
    }

    private func completeSend(for session: ChatSession, fallbackAliases: [String]) {
        let aliases = sessionAliases(for: session, fallback: fallbackAliases)
        setSessionSending(false, aliases: aliases)
        markSessionActive(aliases)
        if !isCurrentlyViewingSession(aliases: aliases) {
            markUnread(aliases: aliases)
        } else {
            clearUnread(aliases: aliases)
        }
    }

    private func isCurrentlyViewingSession(aliases: [String]) -> Bool {
        let targetAliases = Set(aliases)
        if let selectedSession,
           !targetAliases.isDisjoint(with: Set(sessionAliases(for: selectedSession))) {
            return true
        }
        if let selectedTab = chatWorkspace.selectedTab,
           !targetAliases.isDisjoint(with: Set(sessionAliases(for: selectedTab))) {
            return true
        }
        return false
    }

    private func uploadAttachmentsIfNeeded(_ attachments: [ChatAttachment]) async throws -> [UploadedAttachmentReference] {
        guard !attachments.isEmpty else { return [] }
        var uploaded: [UploadedAttachmentReference] = []
        let client = RemoteDaemonClient()
        for attachment in attachments {
            uploaded.append(try await client.uploadAttachment(host: host, attachment: attachment))
        }
        return uploaded
    }
}
