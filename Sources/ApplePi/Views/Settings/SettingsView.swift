import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: PiAppState
    @State private var notificationTestStatus: String?
    @State private var sshConfigEntries: [SSHConfigEntry] = []
    @State private var sshKeys: [SSHKeyStore.Key] = []
    @State private var passwordInput: String = ""
    @State private var passwordStatus: String?
    @State private var apiTokenInput: String = ""
    @State private var apiTokenStatus: String?
    @State private var isConfirmingClearPassword = false
    @State private var isConfirmingClearAPIToken = false
    @State private var isConfirmingHostCommit = false
    @State private var pendingHostCommit: PiHostConfiguration?
    @State private var editingHost: PiHostConfiguration?

    var body: some View {
        Form {
            appearanceSection
            hostSections
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
        .onAppear {
            if editingHost == nil { editingHost = appState.host }
            refreshAPITokenStatus()
        }
        .onChange(of: appState.host) { _, newValue in
            if editingHost != newValue {
                editingHost = newValue
            }
            refreshAPITokenStatus()
        }
        .onChange(of: editingHost) { _, _ in
            refreshAPITokenStatus()
        }
        .onDisappear { commitHostIfChanged(force: true) }
        .confirmationDialog(
            "Apply host changes?",
            isPresented: $isConfirmingHostCommit,
            titleVisibility: .visible
        ) {
            Button("Apply and reload catalog", role: .destructive) {
                performHostCommit()
            }
            Button("Cancel", role: .cancel) {
                pendingHostCommit = nil
            }
        } message: {
            Text(hostCommitMessage)
        }
        .confirmationDialog(
            "Clear stored API token?",
            isPresented: $isConfirmingClearAPIToken,
            titleVisibility: .visible
        ) {
            Button("Clear Token", role: .destructive) {
                clearAPIToken()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stored bearer token for this remote daemon will be deleted. You will need to paste it again before pi-app can authenticate to pi-appd.")
        }
    }

    // MARK: - Appearance section

    @ViewBuilder
    private var appearanceSection: some View {
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
    }

    // MARK: - Host sections (Pi Host + Remote API + Apply/Discard bar)

    @ViewBuilder
    private var hostSections: some View {
        Section {
            Picker("Mode", selection: editingHostBinding(\.mode)) {
                ForEach(PiHostMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            TextField("Local Pi executable", text: editingHostBinding(\.piExecutable))
            TextField("Agent directory", text: editingHostBinding(\.agentDirectory))
        } header: {
            Text("Pi Host")
        } footer: {
            Text("Changes are buffered. Click Apply to commit and reload the catalog; Discard to revert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            TextField("pi-appd URL or IP", text: editingHostBinding(\.remoteDaemonURL))
                .onChange(of: editingHost?.remoteDaemonURL) { _, _ in
                    apiTokenInput = ""
                    refreshAPITokenStatus()
                }
            remoteAPITokenField
            HStack {
                Button("Test Remote API") {
                    testRemoteAPI()
                }
                Button("Copy curl") {
                    copyCurlCommand()
                }
                Spacer()
            }
        } header: {
            Text("Remote API (pi-appd)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("pi-appd is now the only remote transport. Configure URL and token, then use Test Remote API before Apply.")
                if let curlCommand {
                    Text(curlCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if hasPendingHostChanges {
            Section {
                HStack {
                    Spacer()
                    Button("Discard changes") {
                        discardHostEdits()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Apply") {
                        requestHostCommit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Host binding helpers

    private func editingHostBinding<Value>(_ keyPath: WritableKeyPath<PiHostConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: {
                if let editingHost { return editingHost[keyPath: keyPath] }
                return appState.host[keyPath: keyPath]
            },
            set: { newValue in
                var current = editingHost ?? appState.host
                current[keyPath: keyPath] = newValue
                editingHost = current
            }
        )
    }

    private var hasPendingHostChanges: Bool {
        guard let editingHost else { return false }
        return editingHost != appState.host
    }

    private var hostCommitMessage: String {
        guard let pending = pendingHostCommit else { return "" }
        let modeChanged = pending.mode != appState.host.mode
        let hostChanged = pending.remoteHost != appState.host.remoteHost
        if pending.usesRemoteDaemonTransport {
            return "Switching to the remote API will close all open chat tabs and reload the session catalog from \(pending.remoteDaemonDisplayAddress.isEmpty ? "the configured daemon" : pending.remoteDaemonDisplayAddress)."
        } else if modeChanged && pending.mode == .remoteSSH {
            return "Switching to Remote API mode without a configured pi-appd URL will fail. Set the daemon URL and token first."
        } else if modeChanged {
            return "Switching to Local Mac will close all open chat tabs and reload the session catalog from your local Pi agent directory."
        } else if hostChanged {
            return "Updating the remote host to \(pending.remoteHost) will close all open chat tabs and reload the catalog."
        } else {
            return "Applying these host settings will close all open chat tabs and reload the session catalog."
        }
    }

    private func requestHostCommit() {
        guard let editingHost else { return }
        pendingHostCommit = editingHost
        isConfirmingHostCommit = true
    }

    private func performHostCommit() {
        guard let pending = pendingHostCommit else { return }

        if pending.hasRemoteDaemonConfigured {
            guard pending.remoteDaemonBaseURL != nil else {
                apiTokenStatus = "Remote API URL is invalid."
                return
            }

            if !apiTokenInput.isEmpty {
                if let error = appState.saveRemoteDaemonToken(apiTokenInput, for: pending) {
                    apiTokenStatus = error
                    return
                }
                apiTokenInput = ""
                apiTokenStatus = "Saved."
            } else if !appState.hasRemoteDaemonTokenStored(for: pending) {
                apiTokenStatus = "Save a bearer token before enabling the remote API URL."
                return
            }
        }

        appState.host = pending
        pendingHostCommit = nil
        refreshAPITokenStatus()
    }

    private func commitHostIfChanged(force: Bool) {
        guard let editingHost, editingHost != appState.host else { return }
        if force {
            appState.host = editingHost
            pendingHostCommit = nil
        }
    }

    private func discardHostEdits() {
        editingHost = appState.host
        pendingHostCommit = nil
    }

    // MARK: - SSH pickers (operate on editingHost)

    private var editingSshConfigAliasPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("SSH config alias", selection: editingSshConfigAliasBinding) {
                Text("Custom").tag(Optional<String>.none)
                ForEach(sshConfigEntries) { entry in
                    Text(entry.subtitle.isEmpty ? entry.displayName : "\(entry.displayName) — \(entry.subtitle)")
                        .tag(Optional(entry.id))
                }
            }
            .onChange(of: editingSshConfigAliasBinding.wrappedValue) { _, newValue in
                applyAliasToEditingBuffer(newValue)
            }

            if let alias = editingHost?.remoteSSHConfigAlias.nonEmpty ?? appState.host.remoteSSHConfigAlias.nonEmpty {
                HStack(spacing: 6) {
                    Text("Editing alias: \(alias)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Detach") {
                        detachAliasInEditingBuffer()
                    }
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

    private var editingSshIdentityFilePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Identity file", selection: editingSshIdentityBinding) {
                Text("Default (ssh-agent)").tag(Optional<String>.none)
                ForEach(sshKeys) { key in
                    Text(key.label).tag(Optional(key.id))
                }
            }
            if (editingHost?.remoteIdentityFile ?? appState.host.remoteIdentityFile).isEmpty {
                Text("Uses the system default — the agent or ~/.ssh/id_*")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editingSshConfigAliasBinding: Binding<String?> {
        Binding(
            get: { editingHost?.remoteSSHConfigAlias.nonEmpty ?? appState.host.remoteSSHConfigAlias.nonEmpty },
            set: { newValue in
                var current = editingHost ?? appState.host
                current.remoteSSHConfigAlias = newValue ?? ""
                editingHost = current
            }
        )
    }

    private var editingSshIdentityBinding: Binding<String?> {
        Binding(
            get: { editingHost?.remoteIdentityFile.nonEmpty ?? appState.host.remoteIdentityFile.nonEmpty },
            set: { newValue in
                var current = editingHost ?? appState.host
                current.remoteIdentityFile = newValue ?? ""
                // Picking a key does not change the auth method; if the user
                // wants password auth they will pick the Password picker.
                editingHost = current
            }
        )
    }

    private func applyAliasToEditingBuffer(_ aliasID: String?) {
        var current = editingHost ?? appState.host
        if let aliasID, let entry = sshConfigEntries.first(where: { $0.id == aliasID }) {
            // Mirror PiAppState.applySSHConfigEntry into the local buffer.
            current.remoteSSHConfigAlias = entry.hostPatterns.joined(separator: ",")
            if let hostName = entry.hostName?.nilIfBlank {
                current.remoteHost = hostName
            } else if current.remoteHost.isEmpty, let first = entry.hostPatterns.first(where: { !$0.hasSuffix("*") && !$0.hasPrefix("*") }) {
                current.remoteHost = first
            }
            if let user = entry.user?.nilIfBlank { current.remoteUser = user }
            if let port = entry.port { current.remotePort = port }
            if let identityFile = entry.identityFile?.nilIfBlank {
                current.remoteIdentityFile = identityFile
                current.remoteAuthMethod = .publicKey
            }
        } else {
            current.remoteSSHConfigAlias = ""
        }
        editingHost = current
    }

    private func detachAliasInEditingBuffer() {
        var current = editingHost ?? appState.host
        current.remoteSSHConfigAlias = ""
        editingHost = current
    }

    // MARK: - Other bindings (unchanged from before)

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

    private var currentEditingHost: PiHostConfiguration {
        editingHost ?? appState.host
    }

    private var curlCommand: String? {
        guard let baseURL = currentEditingHost.remoteDaemonBaseURL else { return nil }
        let token = apiTokenInput.nilIfBlank ?? RemoteDaemonTokenStore.readToken(for: currentEditingHost)
        guard let token else { return nil }
        return "curl -H \"Authorization: Bearer \(token)\" \(baseURL.appending(path: "healthz").absoluteString.shellQuoted)"
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
        if appState.host.usesRemoteDaemonTransport || appState.host.mode == .remoteSSH {
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

    // MARK: - SSH password field

    private var sshPasswordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Password", text: $passwordInput)
                .textContentType(.password)
                .onSubmit { savePassword() }
            HStack {
                Button(appState.hasRemotePasswordStored(for: currentEditingHost) ? "Update password" : "Save password", action: savePassword)
                if appState.hasRemotePasswordStored(for: currentEditingHost) {
                    Button("Clear", role: .destructive) {
                        isConfirmingClearPassword = true
                    }
                }
                Spacer()
            }
            if let passwordStatus {
                Text(passwordStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.hasRemotePasswordStored(for: currentEditingHost) {
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

    private var remoteAPITokenField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Bearer token", text: $apiTokenInput)
                .textContentType(.password)
                .onSubmit { saveAPIToken() }
            HStack {
                Button(appState.hasRemoteDaemonTokenStored(for: currentEditingHost) ? "Update token" : "Save token", action: saveAPIToken)
                if appState.hasRemoteDaemonTokenStored(for: currentEditingHost) {
                    Button("Clear", role: .destructive) {
                        isConfirmingClearAPIToken = true
                    }
                }
                Spacer()
            }
            if let apiTokenStatus {
                Text(apiTokenStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.hasRemoteDaemonTokenStored(for: currentEditingHost) {
                Text("A bearer token is stored locally for this daemon endpoint only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Stored as a 0600 file in Application Support — never in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reloadSSHCollections() {
        sshConfigEntries = appState.loadSSHConfigEntries()
        sshKeys = appState.loadSSHKeys()
        if editingHost == nil { editingHost = appState.host }
        refreshPasswordStatus()
        refreshAPITokenStatus()
    }

    private func refreshPasswordStatus() {
        passwordStatus = appState.hasRemotePasswordStored(for: currentEditingHost)
            ? "A password is stored for this host."
            : nil
    }

    private func refreshAPITokenStatus() {
        apiTokenStatus = appState.hasRemoteDaemonTokenStored(for: currentEditingHost)
            ? "A token is stored for this daemon endpoint."
            : nil
    }

    private func testRemoteAPI() {
        let host = currentEditingHost
        let tokenOverride = apiTokenInput.nilIfBlank
        Task {
            do {
                let message = try await RemoteDaemonClient().testConnection(host: host, tokenOverride: tokenOverride)
                await MainActor.run {
                    apiTokenStatus = message
                }
            } catch {
                await MainActor.run {
                    apiTokenStatus = error.localizedDescription
                }
            }
        }
    }

    private func copyCurlCommand() {
        guard let curlCommand else {
            apiTokenStatus = "Set URL and token first."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(curlCommand, forType: .string)
        apiTokenStatus = "curl command copied."
    }

    private func savePassword() {
        guard !passwordInput.isEmpty else {
            passwordStatus = "Password is empty."
            return
        }
        if let error = appState.saveRemotePassword(passwordInput, for: currentEditingHost) {
            passwordStatus = error
        } else {
            passwordInput = ""
            passwordStatus = "Saved."
        }
    }

    private func clearPassword() {
        if let error = appState.clearRemotePassword(for: currentEditingHost) {
            passwordStatus = error
        } else {
            passwordStatus = "Cleared."
        }
    }

    private func saveAPIToken() {
        guard !apiTokenInput.isEmpty else {
            apiTokenStatus = "Token is empty."
            return
        }
        if let error = appState.saveRemoteDaemonToken(apiTokenInput, for: currentEditingHost) {
            apiTokenStatus = error
        } else {
            apiTokenInput = ""
            apiTokenStatus = "Saved."
        }
    }

    private func clearAPIToken() {
        if let error = appState.clearRemoteDaemonToken(for: currentEditingHost) {
            apiTokenStatus = error
        } else {
            apiTokenStatus = "Cleared."
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
