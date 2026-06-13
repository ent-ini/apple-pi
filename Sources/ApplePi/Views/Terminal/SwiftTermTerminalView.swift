import SwiftUI

struct SwiftTermTerminalView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    let preferences: TerminalPreferences
    let notificationPreferences: TerminalNotificationPreferences
    let isActive: Bool

    func makeNSView(context: Context) -> TerminalMountContainerView {
        let container = TerminalMountContainerView()
        session.mount(
            in: container,
            preferences: preferences,
            notificationPreferences: notificationPreferences,
            isActive: isActive
        )
        return container
    }

    func updateNSView(_ nsView: TerminalMountContainerView, context: Context) {
        session.mount(
            in: nsView,
            preferences: preferences,
            notificationPreferences: notificationPreferences,
            isActive: isActive
        )
    }

    static func dismantleNSView(_ nsView: TerminalMountContainerView, coordinator: Void) {
        nsView.unmountHostedView()
    }
}
