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
        // The select affordance and the close button live in sibling
        // subviews rather than nested in a single Button. Two reasons:
        //   * Button(action:select) wrapping a Button(action:close) gives
        //     the outer Button the entire hit area and the inner one
        //     never sees clicks on macOS.
        //   * `.onTapGesture` on the outer HStack, paired with
        //     `.contentShape(RoundedRectangle(...))`, swallows taps before
        //     the nested close Button can react, so the X appeared dead.
        // Keeping the two interactions on disjoint HStack children means
        // the hit-testing is unambiguous: clicks on the title go to
        // `onSelect`, clicks on the X go to `onClose`.
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tab.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .contextMenu {
                Button("Reconnect", action: onReconnect)
                    .disabled(!tab.canReconnect)
                Button("Close", action: onClose)
            }

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tabBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var tabBackground: Color {
        let opacity = isSelected ? 0.15 : 0.06
        return colorScheme == .dark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }
}
