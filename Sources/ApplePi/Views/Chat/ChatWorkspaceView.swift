import SwiftUI
import ApplePiCore
import ApplePiRemote

/// Root view for the chat area. The app now operates in a single-session
/// mode: the sidebar selection controls which chat is open, and the old
/// top tab strip is intentionally removed.
struct ChatWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    @ObservedObject var workspace: ChatSessionStore
    let appearance: AppAppearance

    var body: some View {
        ZStack {
            if workspace.tabs.isEmpty {
                Text(appearance.resolvedEmptyChatMessage)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.62)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let activeTab = workspace.selectedTab ?? workspace.tabs.first {
                ChatSessionView(session: activeTab)
                    .id(activeTab.id)
            }
        }
        .foregroundStyle(appearance.textColor(for: appearance.resolvedColorScheme(current: colorScheme)))
        .background(appearance.mainBackgroundColor(for: appearance.resolvedColorScheme(current: colorScheme)))
        .onChange(of: workspace.selectedTabID) { _, _ in
            guard let tab = workspace.selectedTab else { return }
            if tab.sessionID != nil {
                appState.refreshSessionRuntime(for: tab)
            } else {
                appState.hydratePendingSessionDefaults(for: tab)
            }
        }
    }

}
