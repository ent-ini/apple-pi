import Foundation

@MainActor
final class TerminalWorkspaceStore: ObservableObject {
    @Published private(set) var tabs: [TerminalSession] = []
    @Published var selectedTabID: UUID?
    var onSessionExit: (() -> Void)?

    private let commandBuilder = PiCommandBuilder()

    var selectedTab: TerminalSession? {
        guard let selectedTabID else { return nil }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    @discardableResult
    func openOrSelectTab(
        key: String,
        title: String,
        request: PiLaunchRequest,
        host: PiHostConfiguration,
        notificationsEnabled: Bool = true
    ) -> TerminalSession {
        if let tab = tabs.first(where: { $0.key == key }) {
            selectedTabID = tab.id
            return tab
        }
        return openTab(
            key: key,
            title: title,
            request: request,
            host: host,
            notificationsEnabled: notificationsEnabled
        )
    }

    @discardableResult
    func openTab(
        title: String,
        request: PiLaunchRequest,
        host: PiHostConfiguration,
        notificationsEnabled: Bool = true
    ) -> TerminalSession {
        openTab(
            key: UUID().uuidString,
            title: title,
            request: request,
            host: host,
            notificationsEnabled: notificationsEnabled
        )
    }

    func close(_ tab: TerminalSession) {
        if selectedTabID == tab.id {
            selectedTabID = tabs.last(where: { $0.id != tab.id })?.id
        }
        tabs.removeAll { $0.id == tab.id }
        tab.stop()
    }

    func select(_ tab: TerminalSession) {
        selectedTabID = tab.id
    }

    func closeAll() {
        tabs.forEach { $0.stop() }
        tabs = []
        selectedTabID = nil
    }

    private func openTab(
        key: String,
        title: String,
        request: PiLaunchRequest,
        host: PiHostConfiguration,
        notificationsEnabled: Bool
    ) -> TerminalSession {
        let processRequest = commandBuilder.terminalLaunch(
            for: request,
            host: host,
            notificationsEnabled: notificationsEnabled
        )
        let tab = TerminalSession(key: key, title: title, launchRequest: processRequest)
        tab.onExit = { [weak self] in
            self?.onSessionExit?()
        }
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }
}
