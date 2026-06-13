import Foundation

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let key: String
    let launchRequest: TerminalProcessRequest
    private let viewHost = TerminalViewHost()

    @Published var title: String
    @Published var terminalTitle: String
    @Published var currentDirectory: String?
    @Published var exitCode: Int32?
    @Published private(set) var didStart = false
    @Published private(set) var isRunning = false
    @Published private(set) var launchToken = UUID()
    var onExit: (() -> Void)?

    var canReconnect: Bool {
        didStart && !isRunning
    }

    init(key: String, title: String, launchRequest: TerminalProcessRequest) {
        self.key = key
        self.title = title
        self.terminalTitle = title
        self.launchRequest = launchRequest
        viewHost.setEventHandlers(
            onProcessStart: { [weak self] in self?.markStarted() },
            onTitleChange: { [weak self] title in self?.updateTitle(title) },
            onDirectoryChange: { [weak self] directory in self?.currentDirectory = directory },
            onProcessExit: { [weak self] exitCode in self?.markExited(exitCode) }
        )
    }

    deinit {
        viewHost.terminate()
    }

    func mount(
        in container: TerminalMountContainerView,
        preferences: TerminalPreferences,
        notificationPreferences: TerminalNotificationPreferences,
        isActive: Bool
    ) {
        viewHost.mount(
            in: container,
            request: launchRequest,
            launchToken: launchToken,
            preferences: preferences,
            notificationPreferences: notificationPreferences,
            isActive: isActive
        )
    }

    func reconnect() {
        guard canReconnect else { return }
        currentDirectory = nil
        exitCode = nil
        didStart = false
        isRunning = false
        launchToken = UUID()
    }

    func stop() {
        viewHost.terminate()
        isRunning = false
        currentDirectory = nil
    }

    private func markStarted() {
        didStart = true
        isRunning = true
        exitCode = nil
    }

    private func updateTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        terminalTitle = trimmed
    }

    private func markExited(_ code: Int32?) {
        isRunning = false
        exitCode = code
        onExit?()
    }
}
