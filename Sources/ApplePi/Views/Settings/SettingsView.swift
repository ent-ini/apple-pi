import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: PiAppState
    @State private var notificationTestStatus: String?
    @State private var sshConfigEntries: [SSHConfigEntry] = []
    @State private var sshKeys: [SSHKeyStore.Key] = []
    @State private var passwordInput: String = ""
    @State private var passwordStatus: String?

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
                    "Chat surface",
                    value: appState.appearance.chatSurfaceOpacity,
                    range: 0.55...1.0
                ) { value in
                    appState.updateAppearance { $0.chatSurfaceOpacity = value }
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

                TextField("Empty chat message", text: Binding(
                    get: { appState.appearance.emptyChatMessage },
                    set: { newValue in
                        appState.updateAppearance { $0.emptyChatMessage = newValue }
                    }
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
                sshConfigAliasPicker
                TextField("Host", text: $appState.host.remoteHost)
                TextField("User", text: $appState.host.remoteUser)
                Stepper(value: $appState.host.remotePort, in: 1...65535) {
                    Text("Port \(appState.host.remotePort)")
                }
                TextField("Remote Pi executable", text: $appState.host.remotePiExecutable)

                Picker("Authentication", selection: $appState.host.remoteAuthMethod) {
                    ForEach(RemoteAuthMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .onChange(of: appState.host.remoteAuthMethod) { _, newValue in
                    passwordInput = ""
                    if newValue == .password {
                        refreshPasswordStatus()
                    }
                }

                if appState.host.remoteAuthMethod == .publicKey {
                    sshIdentityFilePicker
                } else {
                    sshPasswordField
                }
            }

            Section("Notifications") {
                Toggle("Pi session notifications", isOn: notificationBinding(\.isEnabled))

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
            return "Remote sessions need a Pi notification helper installed on the remote host. The bundled helper is only available to local sessions started from this app."
        }

        if appState.appearance.notifications.isEnabled {
            return "Local sessions started from pi-app load a bundled Pi notification helper. Your existing Pi agent settings are not changed."
        } else {
            return "The bundled Pi notification helper will not be loaded for new local sessions while notifications are off."
        }
    }

    private func notificationStatusText(for result: TerminalNotificationDeliveryResult) -> String {
        switch result {
        case .delivered:
            "Test notification sent."
        case .disabled:
            "Notifications are disabled in pi-app."
        case .suppressedInForeground:
            "Foreground notifications are disabled. Put the app in the background or enable foreground notifications."
        case .denied:
            "macOS notifications are disabled for this app. Enable them in System Settings > Notifications."
        case .failed:
            "macOS could not deliver the notification."
        }
    }

    // MARK: - SSH host UI

    private var sshConfigAliasPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("SSH config alias", selection: sshConfigAliasBinding) {
                Text("Custom").tag(Optional<String>.none)
                ForEach(sshConfigEntries) { entry in
                    Text(entry.subtitle.isEmpty ? entry.displayName : "\(entry.displayName) — \(entry.subtitle)")
                        .tag(Optional(entry.id))
                }
            }
            .onAppear { reloadSSHCollections() }

            if let alias = appState.host.remoteSSHConfigAlias.nonEmpty {
                HStack(spacing: 6) {
                    Text("Editing alias: \(alias)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Detach") { appState.clearSSHConfigAlias() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else if sshConfigEntries.isEmpty {
                Text("No entries found in ~/.ssh/config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sshIdentityFilePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Identity file", selection: sshIdentityBinding) {
                Text("Default (ssh-agent)").tag(Optional<String>.none)
                ForEach(sshKeys) { key in
                    Text(key.label).tag(Optional(key.id))
                }
            }
            if appState.host.remoteIdentityFile.isEmpty {
                Text("Uses the system default — the agent or ~/.ssh/id_*")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sshPasswordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Password", text: $passwordInput)
                .textContentType(.password)
                .onSubmit { savePassword() }
            HStack {
                Button(appState.hasRemotePasswordStored() ? "Update password" : "Save password", action: savePassword)
                if appState.hasRemotePasswordStored() {
                    Button("Clear", role: .destructive) { clearPassword() }
                }
                Spacer()
            }
            if let passwordStatus {
                Text(passwordStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.hasRemotePasswordStored() {
                Text("Password is stored locally for this host only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Stored as a 0600 file in Application Support — never in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sshConfigAliasBinding: Binding<String?> {
        Binding(
            get: { appState.host.remoteSSHConfigAlias.nonEmpty },
            set: { newValue in
                if let newValue, let entry = sshConfigEntries.first(where: { $0.id == newValue }) {
                    appState.applySSHConfigEntry(entry)
                } else {
                    appState.clearSSHConfigAlias()
                }
            }
        )
    }

    private var sshIdentityBinding: Binding<String?> {
        Binding(
            get: { appState.host.remoteIdentityFile.nonEmpty },
            set: { newValue in
                appState.host.remoteIdentityFile = newValue ?? ""
            }
        )
    }

    private func reloadSSHCollections() {
        sshConfigEntries = appState.loadSSHConfigEntries()
        sshKeys = appState.loadSSHKeys()
        refreshPasswordStatus()
    }

    private func refreshPasswordStatus() {
        passwordStatus = appState.hasRemotePasswordStored()
            ? "A password is stored for this host."
            : nil
    }

    private func savePassword() {
        guard !passwordInput.isEmpty else {
            passwordStatus = "Password is empty."
            return
        }
        if let error = appState.saveRemotePassword(passwordInput) {
            passwordStatus = error
        } else {
            passwordInput = ""
            passwordStatus = "Saved."
        }
    }

    private func clearPassword() {
        if let error = appState.clearRemotePassword() {
            passwordStatus = error
        } else {
            passwordStatus = "Cleared."
        }
    }
}

private extension String {
    /// Returns nil when the string is empty, otherwise the string itself.
    /// Lets `Picker` selection bindings work with `Optional<String>` without
    /// scattering `.nilIfBlank` checks.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
