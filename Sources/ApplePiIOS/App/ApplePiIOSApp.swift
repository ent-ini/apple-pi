import SwiftUI
import ApplePiCore
import ApplePiRemote

@main
struct ApplePiIOSApp: App {
    @StateObject private var appState = MobilePiAppState()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(appState)
                .task {
                    await appState.loadInitialCatalogIfConfigured()
                }
        }
    }
}

@MainActor
final class MobilePiAppState: ObservableObject {
    @Published var daemonURL: String {
        didSet { saveHost() }
    }
    @Published var daemonToken: String {
        didSet { saveToken() }
    }
    @Published private(set) var projects: [PiProject] = []
    @Published private(set) var sessions: [PiSessionSummary] = []
    @Published private(set) var selectedSession: PiSessionSummary?
    @Published private(set) var selectedEvents: [SessionEvent] = []
    @Published private(set) var statusMessage = "Configure pi-appd to begin."
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var isLoadingSession = false
    @Published private(set) var isSending = false
    @Published var draft = ""

    private let defaults: UserDefaults
    private let client = RemoteDaemonClient()
    private let hostDefaultsKey = "ApplePiIOS.host"
    private var catalogStreamTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: hostDefaultsKey),
           let host = try? JSONDecoder().decode(PiHostConfiguration.self, from: data) {
            daemonURL = host.remoteDaemonURL
            daemonToken = RemoteDaemonTokenStore.readToken(for: host) ?? ""
        } else {
            daemonURL = ""
            daemonToken = ""
        }
    }

    deinit {
        catalogStreamTask?.cancel()
    }

    var host: PiHostConfiguration {
        PiHostConfiguration(remoteDaemonURL: daemonURL)
    }

    var isConfigured: Bool {
        host.hasRemoteDaemonConfigured
    }

    var filteredVisibleEvents: [SessionEvent] {
        selectedEvents.filter(\.isVisibleInTranscript)
    }

    func loadInitialCatalogIfConfigured() async {
        guard isConfigured else { return }
        await reloadCatalog()
        startCatalogStream()
    }

    func testConnection() async {
        guard isConfigured else {
            statusMessage = "Remote API URL is not configured."
            return
        }
        do {
            statusMessage = try await client.testConnection(host: host, tokenOverride: daemonToken.nilIfBlank)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reloadCatalog() async {
        guard isConfigured else {
            statusMessage = "Remote API URL is not configured."
            return
        }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let snapshot = try await client.loadCatalog(
                host: host,
                activeProjectDirectory: nil,
                tokenOverride: daemonToken.nilIfBlank
            )
            applyCatalog(snapshot)
            statusMessage = "Loaded \(snapshot.projects.count) projects, \(snapshot.sessions.count) sessions."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startCatalogStream() {
        catalogStreamTask?.cancel()
        guard isConfigured else { return }
        let host = host
        let token = daemonToken.nilIfBlank
        catalogStreamTask = Task { [client] in
            do {
                for try await event in client.streamCatalogSnapshots(host: host, tokenOverride: token) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        switch event {
                        case .snapshot(let snapshot):
                            self.applyCatalog(snapshot)
                        case .sessionUpdated(let session):
                            self.upsertSession(session)
                        case .sessionRemoved(let sessionId):
                            self.removeSession(id: sessionId)
                        case .runtimeChanged, .unknown:
                            break
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Catalog stream disconnected: \(error.localizedDescription)"
                }
            }
        }
    }

    func selectSession(_ session: PiSessionSummary) async {
        selectedSession = session
        selectedEvents = []
        await reloadSelectedSession()
    }

    func reloadSelectedSession() async {
        guard let selectedSession else { return }
        isLoadingSession = true
        defer { isLoadingSession = false }
        do {
            let page = try await client.loadSessionEventPage(
                host: host,
                sessionID: selectedSession.id,
                limit: 120,
                tokenOverride: daemonToken.nilIfBlank
            )
            selectedEvents = page.events
            statusMessage = "Loaded session \(selectedSession.title)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func sendDraft() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        isSending = true
        defer { isSending = false }
        do {
            if let selectedSession {
                try await client.streamSend(host: host, sessionID: selectedSession.id, prompt: prompt) { event in
                    await self.handleTurnStreamEvent(event)
                }
            } else {
                let request = PiLaunchRequest(workingDirectory: host.defaultWorkingDirectory)
                try await client.streamNewSession(host: host, request: request, prompt: prompt) { event in
                    await self.handleTurnStreamEvent(event)
                }
            }
            await reloadCatalog()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func handleTurnStreamEvent(_ event: PiTurnStreamEvent) async {
        await MainActor.run {
            switch event {
            case .sessionBound(let binding):
                statusMessage = "Session: \(binding.title)"
            case .sessionEvents(let events, _):
                selectedEvents.append(contentsOf: events)
            case .turnEnd:
                statusMessage = "Turn finished."
            case .agentEnd, .outputComplete:
                statusMessage = "Done."
            case .abort:
                statusMessage = "Aborted."
            case .streamError(let message):
                statusMessage = message
            case .sessionHeader:
                break
            }
        }
    }

    private func applyCatalog(_ snapshot: PiCatalogSnapshot) {
        projects = snapshot.projects.sorted { lhs, rhs in
            (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
        }
        sessions = snapshot.sessions.sorted { $0.modifiedAt > $1.modifiedAt }
        if let selectedSession,
           let updated = sessions.first(where: { $0.id == selectedSession.id }) {
            self.selectedSession = updated
        }
    }

    private func upsertSession(_ session: PiSessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.modifiedAt > $1.modifiedAt }
        if selectedSession?.id == session.id {
            selectedSession = session
        }
    }

    private func removeSession(id: String) {
        sessions.removeAll { $0.id == id }
        if selectedSession?.id == id {
            selectedSession = nil
            selectedEvents = []
        }
    }

    private func saveHost() {
        let host = host
        if let data = try? JSONEncoder().encode(host) {
            defaults.set(data, forKey: hostDefaultsKey)
        }
    }

    private func saveToken() {
        let token = daemonToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if token.isEmpty {
                try RemoteDaemonTokenStore.deleteToken(for: host)
            } else {
                try RemoteDaemonTokenStore.saveToken(token, for: host)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
