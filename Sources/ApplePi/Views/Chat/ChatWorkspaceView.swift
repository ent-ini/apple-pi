import SwiftUI

/// Root view for the chat area. Holds the tab strip on top and the active
/// `ChatSessionView` underneath. The empty state mirrors the old terminal
/// view's "welcome" message so the layout does not collapse when there are
/// no tabs.
struct ChatWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var workspace: ChatSessionStore
    let appearance: AppAppearance

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().opacity(0.35)
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
                } else if let activeTab = workspace.tabs.first(where: { $0.id == workspace.selectedTabID }) {
                    ChatSessionView(session: activeTab)
                        .id(activeTab.id)
                }
            }
            .background(workspaceSurfaceTint(opacity: appearance.effectiveChatOpacity * 0.78))
        }
    }

    @ViewBuilder
    private var tabStrip: some View {
        if workspace.tabs.isEmpty {
            Color.clear.frame(height: 0)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabs) { tab in
                        ChatTabButton(
                            tab: tab,
                            isSelected: workspace.selectedTabID == tab.id,
                            onSelect: { workspace.select(tab) },
                            onClose: { workspace.close(tab) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .frame(height: 40)
            .background(workspaceSurfaceTint(opacity: appearance.effectiveChromeOpacity * 0.44))
        }
    }

    private func workspaceSurfaceTint(opacity: Double) -> Color {
        colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }
}

private struct ChatTabButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var tab: ChatSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        // The select and close affordances live on disjoint HStack children
        // for the same reason as the old terminal tab button: nested Button
        // hit-testing on macOS is fiddly and the close button needs its own
        // hit area.
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .contextMenu {
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

    private var statusColor: Color {
        if tab.loadError != nil { return .red }
        if tab.isLoading { return .orange }
        if tab.events.isEmpty { return Color.secondary.opacity(0.5) }
        return .green
    }

    private var tabBackground: Color {
        let opacity = isSelected ? 0.15 : 0.06
        return colorScheme == .dark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }
}
