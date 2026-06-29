import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: PiAppState
    @AppStorage("ApplePi.showsSessionList") private var wantsSessionList = true
    @AppStorage("ApplePi.sessionListWidth") private var storedSessionListWidth = PaneLayout.sessionListDefault
    @AppStorage("ApplePi.showsUtilitySidebar") private var wantsUtilitySidebar = false
    @AppStorage("ApplePi.utilitySidebarWidth") private var storedUtilitySidebarWidth = PaneLayout.utilitySidebarDefault
    @State private var liveSessionListWidth: Double?
    @State private var liveUtilitySidebarWidth: Double?
    @State private var activeResize: ActivePaneResize?

    var body: some View {
        GeometryReader { proxy in
            let sessionListWidth = liveSessionListWidth ?? storedSessionListWidth
            let utilitySidebarWidth = liveUtilitySidebarWidth ?? storedUtilitySidebarWidth
            let paneVisibility = AdaptivePaneVisibility(
                windowWidth: proxy.size.width,
                wantsSessionList: wantsSessionList,
                wantsUtilitySidebar: wantsUtilitySidebar
            )

            HStack(spacing: 0) {
                if paneVisibility.showsSessionList {
                    SessionListView()
                        .frame(width: PaneLayout.clampedSessionListWidth(sessionListWidth))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    PaneResizeHandle(
                        topInset: proxy.safeAreaInsets.top,
                        onDragStart: {
                            activeResize = ActivePaneResize(kind: .sessionList, startingWidth: sessionListWidth)
                        },
                        onDrag: { translation in
                            let startWidth = activeResize?.startingWidth ?? sessionListWidth
                            let nextWidth = PaneLayout.clampedSessionListWidth(startWidth + translation)
                            withTransaction(Transaction(animation: nil)) {
                                liveSessionListWidth = Double(nextWidth)
                            }
                        },
                        onDragEnd: {
                            let finalWidth = liveSessionListWidth ?? sessionListWidth
                            storedSessionListWidth = finalWidth
                            activeResize = nil
                            if finalWidth <= PaneLayout.sessionListCollapseThreshold {
                                withAnimation(.snappy(duration: 0.18)) {
                                    wantsSessionList = false
                                }
                            }
                        }
                    )
                }

                DetailView()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                if paneVisibility.showsUtilitySidebar {
                    PaneResizeHandle(
                        topInset: proxy.safeAreaInsets.top,
                        onDragStart: {
                            activeResize = ActivePaneResize(kind: .utilitySidebar, startingWidth: utilitySidebarWidth)
                        },
                        onDrag: { translation in
                            let startWidth = activeResize?.startingWidth ?? utilitySidebarWidth
                            let nextWidth = PaneLayout.clampedUtilitySidebarWidth(startWidth - translation)
                            withTransaction(Transaction(animation: nil)) {
                                liveUtilitySidebarWidth = Double(nextWidth)
                            }
                        },
                        onDragEnd: {
                            let finalWidth = liveUtilitySidebarWidth ?? utilitySidebarWidth
                            storedUtilitySidebarWidth = finalWidth
                            activeResize = nil
                            if finalWidth <= PaneLayout.utilitySidebarCollapseThreshold {
                                withAnimation(.snappy(duration: 0.18)) {
                                    wantsUtilitySidebar = false
                                }
                            }
                        }
                    )
                    UtilitySidebarView()
                        .frame(width: PaneLayout.clampedUtilitySidebarWidth(utilitySidebarWidth))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.18), value: paneVisibility)
        }
        .background(AppBackdrop(appearance: appState.appearance))
        .onAppear {
            liveSessionListWidth = storedSessionListWidth
            liveUtilitySidebarWidth = storedUtilitySidebarWidth
        }
        .onChange(of: storedSessionListWidth) { _, newValue in
            guard activeResize?.kind != .sessionList else { return }
            liveSessionListWidth = newValue
        }
        .onChange(of: storedUtilitySidebarWidth) { _, newValue in
            guard activeResize?.kind != .utilitySidebar else { return }
            liveUtilitySidebarWidth = newValue
        }
        .onChange(of: appState.sessionSearchFocusRequestID) { _, _ in
            revealSessionListForSearch()
        }
        .overlay(alignment: .topLeading) {
            WindowAppearanceConfigurator(appearance: appState.appearance)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            if let update = appState.availableUpdate {
                UpdatePillView(update: update) {
                    appState.dismissAvailableUpdate()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: appState.availableUpdate)
        .preferredColorScheme(appState.appearance.colorScheme.colorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    toggleSessionList()
                } label: {
                    Label("Sessions", systemImage: "sidebar.right")
                }
                .help(wantsSessionList ? "Hide sessions" : "Show sessions")

                Button {
                    toggleUtilitySidebar()
                } label: {
                    Label("Utility Panel", systemImage: "sidebar.trailing")
                }
                .help(wantsUtilitySidebar ? "Hide utility panel" : "Show utility panel")

                if appState.isLoadingCatalog {
                    ProgressView()
                        .controlSize(.small)
                        .tint(appState.appearance.accentColor)
                        .help("Loading sessions")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.openNewSessionInCurrentFolder()
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(appState.appearance.accentColor)
                }
                .help("New session")

                Menu {
                    Button("Refresh Sessions") {
                        appState.refreshCatalog()
                    }
                    Divider()
                    SettingsLink {
                        Label("App Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button("Open Agent Settings JSON") {
                        appState.openGlobalSettings()
                    }
                    .disabled(!appState.pathExists(appState.configurationSummary.globalSettingsPath))
                    Button("Reveal Agent Folder") {
                        appState.revealAgentDirectory()
                    }
                    .disabled(!appState.pathExists(appState.configurationSummary.agentDirectoryPath))
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More actions")
            }
        }
        .tint(appState.appearance.accentColor)
        .sheet(isPresented: $appState.showsNewSessionSheet) {
            NewSessionSheet()
                .environmentObject(appState)
        }
    }

    private func toggleSessionList() {
        if !wantsSessionList && storedSessionListWidth <= PaneLayout.sessionListCollapseThreshold {
            storedSessionListWidth = PaneLayout.sessionListReopenWidth
            liveSessionListWidth = PaneLayout.sessionListReopenWidth
        }
        withAnimation(.snappy(duration: 0.18)) {
            wantsSessionList.toggle()
        }
    }

    private func toggleUtilitySidebar() {
        if !wantsUtilitySidebar && storedUtilitySidebarWidth <= PaneLayout.utilitySidebarCollapseThreshold {
            storedUtilitySidebarWidth = PaneLayout.utilitySidebarReopenWidth
            liveUtilitySidebarWidth = PaneLayout.utilitySidebarReopenWidth
        }
        withAnimation(.snappy(duration: 0.18)) {
            wantsUtilitySidebar.toggle()
        }
    }

    private func revealSessionListForSearch() {
        if storedSessionListWidth <= PaneLayout.sessionListCollapseThreshold {
            storedSessionListWidth = PaneLayout.sessionListReopenWidth
            liveSessionListWidth = PaneLayout.sessionListReopenWidth
        }
        guard !wantsSessionList else { return }
        withAnimation(.snappy(duration: 0.18)) {
            wantsSessionList = true
        }
    }
}

private enum PaneLayout {
    static let resizeHandleWidth: CGFloat = 1
    static let resizeHandleHitWidth: CGFloat = 14
    static let sessionListMinimum: Double = 88
    static let sessionListDefault: Double = 330
    static let sessionListMaximum: Double = 480
    static let sessionListCollapseThreshold: Double = 104
    static let sessionListReopenWidth: Double = 176
    static let utilitySidebarMinimum: Double = 220
    static let utilitySidebarDefault: Double = 320
    static let utilitySidebarMaximum: Double = 520
    static let utilitySidebarCollapseThreshold: Double = 232
    static let utilitySidebarReopenWidth: Double = 300

    static func clampedSessionListWidth(_ width: Double) -> CGFloat {
        CGFloat(min(max(width, sessionListMinimum), sessionListMaximum))
    }

    static func clampedUtilitySidebarWidth(_ width: Double) -> CGFloat {
        CGFloat(min(max(width, utilitySidebarMinimum), utilitySidebarMaximum))
    }
}

private struct ActivePaneResize {
    enum Kind {
        case sessionList
        case utilitySidebar
    }

    let kind: Kind
    let startingWidth: Double
}

private struct PaneResizeHandle: View {
    @Environment(\.colorScheme) private var colorScheme
    let topInset: CGFloat
    let onDragStart: () -> Void
    let onDrag: (Double) -> Void
    let onDragEnd: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        let hitOutset = max(0, (PaneLayout.resizeHandleHitWidth - PaneLayout.resizeHandleWidth) / 2)

        Rectangle()
            .fill(controlTint(for: colorScheme, opacity: isDragging ? 0.24 : (isHovering ? 0.16 : 0.06)))
            .frame(
                minWidth: PaneLayout.resizeHandleWidth,
                idealWidth: PaneLayout.resizeHandleWidth,
                maxWidth: PaneLayout.resizeHandleWidth,
                maxHeight: .infinity
            )
            .padding(.top, topInset)
            .padding(.horizontal, hitOutset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onDragStart()
                        }
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnd()
                    }
            )
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
            }
        }
        .padding(.horizontal, -hitOutset)
        .accessibilityLabel("Resize pane")
        .accessibilityHint("Drag horizontally to resize this column")
    }
}

private struct AdaptivePaneVisibility: Equatable {
    let showsSessionList: Bool
    let showsUtilitySidebar: Bool

    init(windowWidth: CGFloat, wantsSessionList: Bool, wantsUtilitySidebar: Bool) {
        let minimumDetailWidth: CGFloat = 320
        let minimumSessionWidth: CGFloat = CGFloat(PaneLayout.sessionListMinimum)
        let minimumUtilityWidth: CGFloat = CGFloat(PaneLayout.utilitySidebarMinimum)
        let resizeHandleWidth = PaneLayout.resizeHandleWidth
        showsSessionList = wantsSessionList && windowWidth >= minimumDetailWidth + minimumSessionWidth + resizeHandleWidth
        let occupiedBySession = showsSessionList ? minimumSessionWidth + resizeHandleWidth : 0
        showsUtilitySidebar = wantsUtilitySidebar && windowWidth >= minimumDetailWidth + occupiedBySession + minimumUtilityWidth + resizeHandleWidth
    }
}

private struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    let appearance: AppAppearance

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    backdropShade(opacity: 0.16),
                    backdropShade(opacity: 0.34),
                    appearance.accentColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private func backdropShade(opacity: Double) -> Color {
        colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }
}

struct ProjectSidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.filteredProjects) { project in
                        ProjectRow(
                            project: project,
                            isSelected: appState.activeProject?.id == project.id && appState.selectedSession == nil,
                            onSelect: { appState.select(.project(project.id)) }
                        )
                    }
                }
                .padding(.vertical, 10)
            }
            .overlay {
                if appState.isLoadingCatalog {
                    ProgressView()
                        .controlSize(.small)
                } else if appState.projects.isEmpty {
                    EmptyCatalogView(
                        title: "No Sessions",
                        systemImage: "folder",
                        message: appState.statusMessage,
                        action: { appState.refreshCatalog() }
                    )
                    .padding()
                }
            }
            Divider().opacity(0.35)
            PiContextFooter(summary: appState.configurationSummary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(
            surfaceTint(for: colorScheme, opacity: appState.appearance.effectiveSidebarOpacity)
                .background(.ultraThinMaterial)
        )
    }
}

private struct ProjectRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let project: PiProject
    let isSelected: Bool
    let onSelect: () -> Void

    private var projectSettingsPath: String? {
        project.workingDirectory.map { "\($0)/.pi/settings.json" }
    }

    private var agentsPath: String? {
        project.workingDirectory.flatMap { directory in
            ["\(directory)/AGENTS.md", "\(directory)/.pi/AGENTS.md"]
                .first(where: { appState.pathExists($0) })
        }
    }

    private var piDirectoryPath: String? {
        project.workingDirectory.map { "\($0)/.pi" }
    }

    private var hasProjectDirectory: Bool {
        appState.pathExists(project.workingDirectory)
    }

    var body: some View {
        row
            .contextMenu {
                Button("New Session") {
                    appState.openNewSession(in: project.workingDirectory)
                }
                Divider()
                Button("Show in Finder") {
                    appState.revealProjectDirectory(for: project)
                }
                .disabled(!hasProjectDirectory)

                projectFileActions
            }
    }

    @ViewBuilder
    private var projectFileActions: some View {
        if appState.pathExists(projectSettingsPath) || appState.pathExists(agentsPath) || appState.pathExists(piDirectoryPath) {
            Divider()
        }

        if appState.pathExists(projectSettingsPath) {
            Button("Open Project Settings JSON") {
                appState.openProjectSettings(for: project)
            }
        }

        if appState.pathExists(agentsPath) {
            Button("Open AGENTS.md") {
                appState.openAgentsFile(for: project)
            }
        }

        if appState.pathExists(piDirectoryPath) {
            Button("Reveal .pi Folder") {
                appState.revealProjectPiDirectory(for: project)
            }
        }
    }

    private var row: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(appState.appearance.accentColor)
                    .frame(width: 22)
                Text(project.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(project.sessionCount)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? controlTint(for: colorScheme, opacity: 0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

private struct PiContextFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let summary: PiConfigurationSummary
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(summary.trustDisplayTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showsDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show Pi configuration")
            .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
                PiContextPopover(summary: summary)
                    .environmentObject(appState)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(controlTint(for: colorScheme, opacity: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusColor: Color {
        switch summary.trustStatus {
        case .trusted: .green
        case .untrusted: .orange
        case .unknown: summary.hasProjectContext ? .secondary : .secondary.opacity(0.55)
        }
    }
}

private struct PiContextPopover: View {
    @EnvironmentObject private var appState: PiAppState
    let summary: PiConfigurationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pi")
                        .font(.headline.weight(.semibold))
                    Text(summary.trustDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    appState.refreshConfigurationSummary()
                    appState.refreshCatalog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh Pi context")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { metrics }
                VStack(alignment: .leading, spacing: 5) { metrics }
            }

            VStack(alignment: .leading, spacing: 8) {
                PiContextPathRow(title: "Session storage", path: summary.sessionRoot)
                if let projectDirectory = summary.projectDirectory {
                    PiContextPathRow(title: "Project", path: projectDirectory)
                }
                PiContextPathRow(title: "Agent", path: summary.agentDirectoryPath)
            }

            Divider()

            HStack {
                Button("Open Settings JSON") {
                    appState.openGlobalSettings()
                }
                .disabled(!appState.pathExists(summary.globalSettingsPath))

                Button("Reveal Agent") {
                    appState.revealAgentDirectory()
                }
                .disabled(!appState.pathExists(summary.agentDirectoryPath))
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    private var metrics: some View {
        PiContextMetric(title: "Config", value: summary.settingsCount) {
            appState.openConfigurationMetric(.config)
        }
        .help("Open Pi settings JSON")

        PiContextMetric(title: "Instructions", value: summary.contextFileCount) {
            appState.openConfigurationMetric(.instructions)
        }
        .help("Open Pi instruction file")

        PiContextMetric(title: "Resources", value: summary.resourceCount) {
            appState.openConfigurationMetric(.resources)
        }
        .help("Reveal Pi resources")
    }
}

private struct PiContextPathRow: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
    }
}

private struct PiContextMetric: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(value)")
                    .monospacedDigit()
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(controlTint(for: colorScheme, opacity: 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(value == 0)
        .opacity(value == 0 ? 0.55 : 1)
    }
}

struct SessionListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions", text: $appState.sessionSearchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                if appState.hasActiveSessionSearch {
                    Button {
                        appState.sessionSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(controlTint(for: colorScheme, opacity: 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().opacity(0.24)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.filteredSessions()) { session in
                        SessionListRow(
                            session: session,
                            isSelected: appState.isSelectedSession(session),
                            onSelect: {
                                appState.select(.session(session.id))
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .overlay {
                if !appState.isLoadingCatalog,
                   appState.filteredSessions().isEmpty {
                    EmptyCatalogView(
                        title: appState.hasActiveSessionSearch ? "No Matches" : "No Sessions",
                        systemImage: appState.hasActiveSessionSearch ? "magnifyingglass" : "text.bubble",
                        message: appState.hasActiveSessionSearch ? appState.sessionSearchText : appState.statusMessage,
                        action: {
                            if appState.hasActiveSessionSearch {
                                appState.sessionSearchText = ""
                            } else {
                                appState.refreshCatalog()
                            }
                        }
                    )
                    .padding()
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(
            surfaceTint(for: colorScheme, opacity: appState.appearance.effectiveListOpacity)
                .background(.thinMaterial)
        )
        .onAppear {
            applyPendingSearchFocus()
        }
        .onChange(of: appState.sessionSearchFocusRequestID) { _, _ in
            applyPendingSearchFocus()
        }
    }

    private func applyPendingSearchFocus() {
        guard appState.pendingSessionSearchFocusRequest else { return }
        DispatchQueue.main.async {
            isSearchFieldFocused = true
            appState.consumeSessionSearchFocusRequest()
        }
    }
}

struct UtilitySidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.split.2x1")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Workspace")
                        .font(.callout.weight(.semibold))
                    Text("Subagents · Preview · Inspector")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(controlTint(for: colorScheme, opacity: 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().opacity(0.24)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    UtilitySidebarPlaceholderCard(
                        icon: "person.2.wave.2",
                        title: "Subagents",
                        message: "Future panel for spawned agents, progress, and handoffs."
                    )
                    UtilitySidebarPlaceholderCard(
                        icon: "doc.text.magnifyingglass",
                        title: "Preview",
                        message: "File previews and selected tool output will land here."
                    )
                    UtilitySidebarPlaceholderCard(
                        icon: "slider.horizontal.3",
                        title: "Inspector",
                        message: "Contextual controls for the active chat item."
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)
        }
        .background(
            surfaceTint(for: colorScheme, opacity: appState.appearance.effectiveListOpacity)
                .background(.thinMaterial)
        )
    }
}

private struct UtilitySidebarPlaceholderCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(appState.appearance.accentColor)
                    .frame(width: 22)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(controlTint(for: colorScheme, opacity: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(controlTint(for: colorScheme, opacity: 0.06), lineWidth: 1)
        )
    }
}

private struct EmptyCatalogView: View {
    let title: String
    let systemImage: String
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionListRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let session: PiSessionSummary
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isRenaming = false
    @State private var draftTitle = ""

    var body: some View {
        Button(action: onSelect) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button("Rename") {
                draftTitle = session.title
                isRenaming = true
            }
        }
        .alert("Rename Session", isPresented: $isRenaming) {
            TextField("Name", text: $draftTitle)
            Button("Rename") {
                appState.rename(session, to: draftTitle)
            }
            Button("Cancel", role: .cancel) {}
        }
        Divider()
            .padding(.leading, 12)
            .opacity(isSelected ? 0 : 0.28)
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(session.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(appState.effectiveLastActivity(for: session), style: .date)
                        .lineLimit(1)
                    if session.hasMetadata {
                        SessionMetadataStrip(session: session)
                    }
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            SessionActivityIndicator(
                isSending: appState.isSessionSending(session),
                showsUnread: appState.hasUnreadIndicator(session),
                accentColor: appState.appearance.accentColor
            )
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            controlTint(for: colorScheme, opacity: 0.14)
        } else {
            Color.clear
        }
    }
}

private struct SessionActivityIndicator: View {
    let isSending: Bool
    let showsUnread: Bool
    let accentColor: Color

    var body: some View {
        Group {
            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentColor)
            } else if showsUnread {
                Circle()
                    .fill(accentColor)
                    .frame(width: 9, height: 9)
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct SessionMetadataStrip: View {
    let session: PiSessionSummary

    var body: some View {
        HStack(spacing: 5) {
            if session.messageCount > 0 {
                SessionMetadataBadge(systemImage: "text.bubble", value: session.messageCount, help: "Messages")
            }
            if session.branchCount > 0 {
                SessionMetadataBadge(systemImage: "point.3.connected.trianglepath.dotted", value: session.branchCount, help: "Branch points")
            }
            if session.labelCount > 0 {
                SessionMetadataBadge(systemImage: "tag", value: session.labelCount, help: "Labels")
            }
            if session.branchSummaryCount > 0 {
                SessionMetadataBadge(systemImage: "text.badge.checkmark", value: session.branchSummaryCount, help: "Branch summaries")
            }
            if session.parentSession != nil {
                Label("Fork", systemImage: "tuningfork")
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.semibold))
                    .help("Forked session")
            }
            if let latestModel = session.latestModel {
                Text(latestModel)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 86)
                    .help(latestModel)
            }
        }
        .foregroundStyle(.tertiary)
    }
}

private struct SessionMetadataBadge: View {
    let systemImage: String
    let value: Int
    let help: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text("\(value)")
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .help(help)
    }
}

struct DetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState

    var body: some View {
        VStack(spacing: 0) {
            ChatWorkspaceView(
                workspace: appState.chatWorkspace,
                appearance: appState.appearance
            )
        }
        .background(
            surfaceTint(for: colorScheme, opacity: appState.appearance.effectiveChatOpacity)
                .background(.regularMaterial)
        )
    }
}

private func surfaceTint(for colorScheme: ColorScheme, opacity: Double) -> Color {
    colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
}

private func controlTint(for colorScheme: ColorScheme, opacity: Double) -> Color {
    colorScheme == .dark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
}
