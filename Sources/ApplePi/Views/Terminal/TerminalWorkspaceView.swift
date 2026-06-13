import SwiftUI

struct TerminalWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var workspace: TerminalWorkspaceStore
    let appearanceSettings: AppAppearance

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().opacity(0.35)
            ZStack {
                if workspace.tabs.isEmpty {
                    Text(appearanceSettings.resolvedEmptyTerminalMessage)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.62)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(workspace.tabs) { tab in
                        SwiftTermTerminalView(
                            session: tab,
                            preferences: appearanceSettings.terminal,
                            notificationPreferences: appearanceSettings.notifications,
                            isActive: workspace.selectedTabID == tab.id
                        )
                        .opacity(workspace.selectedTabID == tab.id ? 1 : 0)
                    }
                }
            }
            .background(terminalBackground)
        }
    }

    @ViewBuilder
    private var terminalBackground: some View {
        if workspace.tabs.isEmpty {
            Color.clear
        } else {
            workspaceSurfaceTint(opacity: appearanceSettings.effectiveTerminalOpacity * 0.78)
        }
    }

    private var tabStrip: some View {
        Group {
            if workspace.tabs.isEmpty {
                Color.clear.frame(height: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspace.tabs) { tab in
                            TerminalTabButton(
                                tab: tab,
                                isSelected: workspace.selectedTabID == tab.id,
                                onSelect: { workspace.select(tab) },
                                onClose: { workspace.close(tab) },
                                onReconnect: { tab.reconnect() }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .frame(height: 40)
                .background(workspaceSurfaceTint(opacity: appearanceSettings.effectiveChromeOpacity * 0.44))
            }
        }
    }

    private func workspaceSurfaceTint(opacity: Double) -> Color {
        colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }
}

private struct TerminalTabButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var tab: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tab.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tabBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reconnect", action: onReconnect)
                .disabled(!tab.canReconnect)
            Button("Close", action: onClose)
        }
    }

    private var tabBackground: Color {
        let opacity = isSelected ? 0.15 : 0.06
        return colorScheme == .dark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }
}
