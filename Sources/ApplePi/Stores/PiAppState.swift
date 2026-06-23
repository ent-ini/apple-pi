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
        }
    }
    @Published private(set) var projects: [PiProject] = []
    @Published private(set) var sessions: [PiSessionSummary] = []
    @Published var selection: PiSelection?
    @Published var searchText = ""
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
    private let lastUpdateCheckKey = "ApplePi.updateCheck.lastCheckedAt"
    private let updateCheckInterval: TimeInterval = 24 * 60 * 60
    private var isLoadingPersistedState = false
    private var catalogRefreshID = UUID()
    private var remoteDirectoryRefreshID = UUID()

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

        isLoadingPersistedState = true
        loadHost()
        loadAppearance()
        isLoadingPersistedState = false

        chatWorkspace.onSessionExit = { [weak self] in
            self?.scheduleCatalogRefresh()
        }
        refreshConfigurationSummary()
        if startsBackgroundWork {
            refreshCatalog()
            runUpdateCheckIfNeeded()
        }
    }

    func dismissAvailableUpdate() {
        availableUpdate = nil
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
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return projects
        }
        return projects.filter { project in
            project.title.localizedCaseInsensitiveContains(searchText) ||
            (project.workingDirectory ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    func sessions(for project: PiProject) -> [PiSessionSummary] {
        sessions
            .filter { $0.projectID == project.id }
            .sorted { effectiveLastActivity(for: $0) > effectiveLastActivity(for: $1) }
    }

    func filteredSessions(for project: PiProject?) -> [PiSessionSummary] {
        guard let project else { return [] }
        let projectSessions = sessions(for: project)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projectSessions }
        return projectSessions.filter { session in
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

    func refreshCatalog(usesActiveProjectContext: Bool = true) {
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
                    self.statusMessage = "Loaded \(snapshot.sessions.count) Pi sessions"
                    self.repairSelectionIfNeeded()
                    self.refreshConfigurationSummary()
                }
            } catch {
                await MainActor.run {
                    guard self.catalogRefreshID == refreshID else { return }
                    self.isLoadingCatalog = false
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

    func select(_ selection: PiSelection) {
        self.selection = selection
        if case .session = selection, let selectedSession {
            markSessionRead(selectedSession)
        }
        refreshConfigurationSummary()
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
        chatWorkspace.openTab(
            key: key,
            title: effectiveName,
            sessionPath: nil,
            launchRequest: request
        )
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
        chatWorkspace.openOrSelectTab(
            key: session.filePath,
            title: session.title,
            sessionID: session.id,
            sessionPath: session.filePath,
            eventLoader: eventLoader(for: session)
        )
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

    private func eventLoader(for session: PiSessionSummary) -> (@Sendable () async throws -> [SessionEvent])? {
        remoteEventLoader(sessionID: session.id)
    }

    private func remoteEventLoader(sessionID: String) -> (@Sendable () async throws -> [SessionEvent])? {
        guard host.usesRemoteDaemonTransport || host.mode == .remoteSSH else { return nil }
        let remoteHost = host
        return {
            try await RemoteDaemonClient().loadSessionEvents(host: remoteHost, sessionID: sessionID)
        }
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

        if let request = session.launchRequest, request.isEphemeral {
            session.finishSendingWithError("Temporary chat sessions are not supported yet in pi-app.")
            return false
        }

        session.beginSending(prompt: taggedPrompt, attachments: attachments)
        let initialAliases = sessionAliases(for: session)
        markSessionActive(initialAliases)
        setSessionSending(true, aliases: initialAliases)
        clearUnread(aliases: initialAliases)
        statusMessage = "Sending to Pi..."

        if host.usesRemoteDaemonTransport || host.mode == .remoteSSH {
            Task { [weak self, session] in
                guard let self else { return }
                do {
                    let daemonAttachments = try await self.uploadAttachmentsIfNeeded(attachments)
                    if let sessionID = session.sessionID?.nilIfBlank {
                        try await RemoteDaemonClient().streamSend(
                            host: self.host,
                            sessionID: sessionID,
                            prompt: taggedPrompt,
                            attachments: daemonAttachments,
                            onEvent: { [weak self, session] event in
                                guard let self else { return }
                                await MainActor.run {
                                    self.applyTurnStreamEvent(event, to: session)
                                }
                            }
                        )
                    } else if let launchRequest = session.launchRequest {
                        try await RemoteDaemonClient().streamNewSession(
                            host: self.host,
                            request: launchRequest,
                            prompt: taggedPrompt,
                            attachments: daemonAttachments,
                            onEvent: { [weak self, session] event in
                                guard let self else { return }
                                await MainActor.run {
                                    self.applyTurnStreamEvent(event, to: session)
                                }
                            }
                        )
                    } else {
                        throw RemoteDaemonError.requestFailed(status: 400, body: "Session is missing an ID.")
                    }

                    await MainActor.run {
                        session.finishSendingAndReload()
                        self.completeSend(for: session, fallbackAliases: initialAliases)
                        self.statusMessage = "Pi replied"
                        self.scheduleCatalogRefresh(after: .seconds(0.2))
                    }
                } catch {
                    await MainActor.run {
                        session.finishSendingWithError(error.localizedDescription)
                        self.setSessionSending(false, aliases: self.sessionAliases(for: session, fallback: initialAliases))
                        self.statusMessage = error.localizedDescription
                    }
                }
            }
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

        Task { [weak self, session] in
            guard let self else { return }
            do {
                try await LocalPiTurnRunner().run(
                    host: self.host,
                    request: launchRequest,
                    prompt: taggedPrompt,
                    attachments: attachments,
                    sessionRootCandidates: sessionRootCandidates,
                    onEvent: { [weak self, session] event in
                        guard let self else { return }
                        await MainActor.run {
                            self.applyTurnStreamEvent(event, to: session)
                        }
                    }
                )
                await MainActor.run {
                    session.finishSendingAndReload()
                    self.completeSend(for: session, fallbackAliases: initialAliases)
                    self.statusMessage = "Pi replied"
                    self.scheduleCatalogRefresh(after: .seconds(0.2))
                }
            } catch {
                await MainActor.run {
                    session.finishSendingWithError(error.localizedDescription)
                    self.setSessionSending(false, aliases: self.sessionAliases(for: session, fallback: initialAliases))
                    self.statusMessage = error.localizedDescription
                }
            }
        }

        return true
    }

    private func applyTurnStreamEvent(_ event: PiTurnStreamEvent, to session: ChatSession) {
        switch event {
        case .sessionBound(let binding):
            let previousAliases = sessionAliases(for: session)
            let title = binding.title == "Pi" ? session.title : binding.title
            let eventLoader = binding.sessionID.flatMap { remoteEventLoader(sessionID: $0) }
            session.bindToSession(
                key: binding.key,
                title: title,
                sessionID: binding.sessionID,
                sessionPath: binding.sessionPath,
                eventLoader: eventLoader
            )
            migrateSessionState(from: previousAliases, to: sessionAliases(for: session))
        case .sessionHeader(let meta):
            if session.sessionID == nil {
                let previousAliases = sessionAliases(for: session)
                session.bindToSession(
                    sessionID: meta.id,
                    sessionPath: session.sessionPath,
                    eventLoader: session.sessionPath == nil ? remoteEventLoader(sessionID: meta.id) : nil
                )
                migrateSessionState(from: previousAliases, to: sessionAliases(for: session))
            }
        case .message(let message, let isFinal):
            if message.role == .assistant {
                session.applyStreamingMessage(message, isFinal: isFinal)
            }
        case .streamError(let message):
            statusMessage = message
        }
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
        guard let selectedSession else { return false }
        return !Set(aliases).isDisjoint(with: Set(sessionAliases(for: selectedSession)))
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
