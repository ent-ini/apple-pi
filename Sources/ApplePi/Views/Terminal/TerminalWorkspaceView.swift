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
                } else if let activeTab = workspace.tabs.first(where: { $0.id == workspace.selectedTabID }) {
                    // Only mount the active terminal as an NSView. Keeping all
                    // tabs alive via opacity hid their NSViews behind opacity 0
                    // but still paid the full update cost on every body re-eval
                    // (which happens on every tab switch), making switching
                    // noticeably slow with a handful of tabs open. Dismantling
                    // the inactive ones hands their `TerminalHostView` back so
                    // SwiftUI re-mounts it under a new container; the underlying
                    // SwiftTerm process is preserved because the host view
                    // itself is owned by the `TerminalSession` and outlives any
                    // single mount cycle.
                    SwiftTermTerminalView(
                        session: activeTab,
                        preferences: appearanceSettings.terminal,
                        notificationPreferences: appearanceSettings.notifications,
                        isActive: true
                    )
                    .id(activeTab.id)
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
        // The whole row is a tappable area for selection; the close button is
        // an explicit nested control so the right-click context menu lands on
        // the HStack instead of getting swallowed by a Button (a known
        // SwiftUI quirk on macOS where Button + .buttonStyle(.plain) +
        // .contextMenu is unreliable on right-click).
        HStack(spacing: 7) {
            Circle()
                .fill(tab.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tabBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { onSelect() }
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
