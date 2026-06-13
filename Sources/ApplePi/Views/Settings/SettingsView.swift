import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: PiAppState
    @State private var showsAdvancedTerminalSettings = false
    @State private var notificationTestStatus: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: Binding(
                    get: { appState.appearance.colorScheme },
                    set: { newValue in appState.updateAppearance { $0.colorScheme = newValue } }
                )) {
                    ForEach(AppColorSchemePreference.allCases) { scheme in
                        Text(scheme.title).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)

                opacitySlider(
                    "Window opacity",
                    value: appState.appearance.windowOpacity,
                    range: 0.58...1.0
                ) { value in
                    appState.updateAppearance { $0.windowOpacity = value }
                }

                opacitySlider(
                    "Project sidebar",
                    value: appState.appearance.sidebarOpacity,
                    range: 0.25...0.85
                ) { value in
                    appState.updateAppearance { $0.sidebarOpacity = value }
                }

                opacitySlider(
                    "Session list",
                    value: appState.appearance.listOpacity,
                    range: 0.30...0.90
                ) { value in
                    appState.updateAppearance { $0.listOpacity = value }
                }

                opacitySlider(
                    "Terminal surface",
                    value: appState.appearance.terminalOpacity,
                    range: 0.55...1.0
                ) { value in
                    appState.updateAppearance { $0.terminalOpacity = value }
                }

                Toggle("Reduce transparency", isOn: Binding(
                    get: { appState.appearance.reduceTransparency },
                    set: { newValue in appState.updateAppearance { $0.reduceTransparency = newValue } }
                ))

                Picker("Accent", selection: Binding(
                    get: { appState.appearance.accentColorName },
                    set: { newValue in appState.updateAppearance { $0.accentColorName = newValue } }
                )) {
                    ForEach(AccentColorName.allCases) { accent in
                        Text(accent.title).tag(accent)
                    }
                }

                Toggle("Transparent titlebar", isOn: Binding(
                    get: { appState.appearance.useTransparentTitlebar },
                    set: { newValue in appState.updateAppearance { $0.useTransparentTitlebar = newValue } }
                ))
            }

            Section("Pi Host") {
                Picker("Mode", selection: $appState.host.mode) {
                    ForEach(PiHostMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                TextField("Local Pi executable", text: $appState.host.piExecutable)
                TextField("Agent directory", text: $appState.host.agentDirectory)
            }

            Section("Remote SSH") {
                TextField("Host", text: $appState.host.remoteHost)
                TextField("User", text: $appState.host.remoteUser)
                Stepper(value: $appState.host.remotePort, in: 1...65535) {
                    Text("Port \(appState.host.remotePort)")
                }
                TextField("Remote Pi executable", text: $appState.host.remotePiExecutable)
            }

            Section("Terminal") {
                terminalPreview

                Picker("Theme", selection: terminalBinding(\.themeName)) {
                    ForEach(TerminalThemeName.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }

                Picker("Font", selection: terminalBinding(\.fontFamily)) {
                    ForEach(TerminalFontFamily.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }

                TextField("Empty terminal message", text: Binding(
                    get: { appState.appearance.emptyTerminalMessage },
                    set: { newValue in
                        appState.updateAppearance { $0.emptyTerminalMessage = newValue }
                    }
                ))

                Slider(
                    value: Binding(
                        get: { appState.appearance.terminal.fontSize },
                        set: { newValue in
                            appState.updateAppearance { $0.terminal.fontSize = TerminalFontPreference.clamped(newValue) }
                        }
                    ),
                    in: TerminalFontPreference.minimumSize...TerminalFontPreference.maximumSize,
                    step: 0.5
                ) {
                    Text("Font size")
                }
                Text("\(appState.appearance.terminal.fontSize, specifier: "%.1f") pt")
                    .foregroundStyle(.secondary)

                Picker("Scrollback", selection: terminalBinding(\.scrollbackLines)) {
                    ForEach(TerminalScrollbackPreference.allCases) { depth in
                        Text(depth.title).tag(depth)
                    }
                }

                Picker("Links", selection: terminalBinding(\.linkMode)) {
                    ForEach(TerminalLinkMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                DisclosureGroup("Advanced", isExpanded: $showsAdvancedTerminalSettings) {
                    Toggle("Option sends Meta", isOn: terminalBinding(\.optionAsMetaKey))
                    Toggle("Allow mouse reporting", isOn: terminalBinding(\.allowMouseReporting))
                    Toggle("Use bright colors for bold text", isOn: terminalBinding(\.useBrightColors))
                    Toggle("Backspace sends Control-H", isOn: terminalBinding(\.backspaceSendsControlH))
                }
            }

            Section("Notifications") {
                Toggle("OSC 777 notifications", isOn: notificationBinding(\.isEnabled))

                Text(notificationExtensionHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Presentation", selection: notificationBinding(\.presentation)) {
                    ForEach(TerminalNotificationPresentation.allCases) { presentation in
                        Text(presentation.title).tag(presentation)
                    }
                }
                .disabled(!appState.appearance.notifications.isEnabled)

                Toggle("Show while app is in foreground", isOn: notificationBinding(\.allowsForegroundNotifications))
                    .disabled(!appState.appearance.notifications.isEnabled)

                Button("Test Notification") {
                    Task {
                        let result = await appState.sendTestNotification()
                        notificationTestStatus = notificationStatusText(for: result)
                    }
                }
                .disabled(!appState.appearance.notifications.isEnabled)

                if let notificationTestStatus {
                    Text(notificationTestStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
    }

    private func opacitySlider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        update: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Slider(
                value: Binding(
                    get: { value },
                    set: { update($0) }
                ),
                in: range,
                step: 0.01
            ) {
                Text(title)
            }
            Text("\(Int(value * 100))%")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var terminalPreview: some View {
        let theme = appState.appearance.terminal.theme

        return VStack(alignment: .leading, spacing: 8) {
            Text("Pi session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(nsColor: theme.foregroundColor).opacity(0.72))
            HStack(spacing: 0) {
                Text("$ ")
                    .foregroundStyle(Color(nsColor: theme.ansiPalette[2]))
                Text("pi resume latest")
                    .foregroundStyle(Color(nsColor: theme.foregroundColor))
                Text("  ready")
                    .foregroundStyle(Color(nsColor: theme.ansiPalette[3]))
            }
            .font(.system(size: appState.appearance.terminal.fontSize, design: .monospaced))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: theme.backgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func terminalBinding<Value>(_ keyPath: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { appState.appearance.terminal[keyPath: keyPath] },
            set: { newValue in
                appState.updateAppearance { $0.terminal[keyPath: keyPath] = newValue }
            }
        )
    }

    private func notificationBinding<Value>(_ keyPath: WritableKeyPath<TerminalNotificationPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { appState.appearance.notifications[keyPath: keyPath] },
            set: { newValue in
                appState.updateNotificationPreferences { $0[keyPath: keyPath] = newValue }
                notificationTestStatus = nil
            }
        )
    }

    private var notificationExtensionHelpText: String {
        if appState.host.mode == .remoteSSH {
            return "Remote sessions need a Pi notification extension installed on the remote host. The bundled helper is only available to local sessions started from this app."
        }

        if appState.appearance.notifications.isEnabled {
            return "Local sessions started from Apple Pi load a bundled Pi notification helper. Your existing Pi agent settings are not changed."
        } else {
            return "The bundled Pi notification helper will not be loaded for new local sessions while notifications are off."
        }
    }

    private func notificationStatusText(for result: TerminalNotificationDeliveryResult) -> String {
        switch result {
        case .delivered:
            "Test notification sent."
        case .disabled:
            "Notifications are disabled in Apple Pi."
        case .suppressedInForeground:
            "Foreground notifications are disabled. Put the app in the background or enable foreground notifications."
        case .denied:
            "macOS notifications are disabled for this app. Enable them in System Settings > Notifications."
        case .failed:
            "macOS could not deliver the notification."
        }
    }
}
