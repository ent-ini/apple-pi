import Foundation

struct PiCommandBuilder {
    private let notificationExtensionResourceURL: URL?

    init(notificationExtensionResourceURL: URL? = Bundle.main.resourceURL) {
        self.notificationExtensionResourceURL = notificationExtensionResourceURL
    }

    func terminalLaunch(
        for request: PiLaunchRequest,
        host: PiHostConfiguration,
        notificationsEnabled: Bool = true
    ) -> TerminalProcessRequest {
        switch host.mode {
        case .local:
            return localLaunch(for: request, host: host, notificationsEnabled: notificationsEnabled)
        case .remoteSSH:
            return remoteLaunch(for: request, host: host)
        }
    }

    private func localLaunch(
        for request: PiLaunchRequest,
        host: PiHostConfiguration,
        notificationsEnabled: Bool
    ) -> TerminalProcessRequest {
        var arguments = notificationsEnabled ? notificationExtensionArguments() : []
        if request.isEphemeral {
            arguments.append("--no-session")
        }
        if let sessionPath = request.sessionPath {
            arguments.append(contentsOf: ["--session", sessionPath])
        }
        if let forkPath = request.forkPath {
            arguments.append(contentsOf: ["--fork", forkPath])
        }
        if let sessionName = request.sessionName?.nilIfBlank {
            arguments.append(contentsOf: ["--name", sessionName])
        }
        if let initialPrompt = request.initialPrompt?.nilIfBlank {
            arguments.append(initialPrompt)
        }

        let executable = localExecutable(for: host.piExecutable)
        return TerminalProcessRequest(
            executable: executable.path,
            arguments: executable.arguments + arguments,
            environment: terminalEnvironment(),
            workingDirectory: request.workingDirectory?.expandingTilde,
            execName: executable.execName
        )
    }

    private func remoteLaunch(for request: PiLaunchRequest, host: PiHostConfiguration) -> TerminalProcessRequest {
        let remoteCommand = remoteShellCommand(for: request, host: host)
        var arguments = ["-tt"]
        arguments.append(contentsOf: RemoteSSHSupport.commonArguments(for: host))
        if host.hasExplicitIdentityFile {
            arguments.append(contentsOf: ["-i", host.remoteIdentityFile.expandingTilde])
        }
        arguments.append(host.remoteAddress)
        arguments.append(remoteCommand)

        return TerminalProcessRequest(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: terminalEnvironment(remoteHost: host),
            workingDirectory: nil,
            execName: "ssh"
        )
    }

    private func remoteShellCommand(for request: PiLaunchRequest, host: PiHostConfiguration) -> String {
        var words = [remoteShellPathWord(host.remotePiExecutable.nilIfBlank ?? "pi")]
        if request.isEphemeral {
            words.append("--no-session")
        }
        if let sessionPath = request.sessionPath {
            words.append("--session")
            words.append(remoteShellPathWord(sessionPath))
        }
        if let forkPath = request.forkPath {
            words.append("--fork")
            words.append(remoteShellPathWord(forkPath))
        }
        if let sessionName = request.sessionName?.nilIfBlank {
            words.append("--name")
            words.append(sessionName.shellQuoted)
        }
        if let initialPrompt = request.initialPrompt?.nilIfBlank {
            words.append(initialPrompt.shellQuoted)
        }

        let piCommand = words.joined(separator: " ")
        let pathPrefix = remotePathPrefix
        guard let workingDirectory = request.workingDirectory?.nilIfBlank else {
            return "\(pathPrefix) && \(piCommand)"
        }
        return "\(pathPrefix) && cd \(remoteShellPathWord(workingDirectory)) && \(piCommand)"
    }

    private func terminalEnvironment(remoteHost: PiHostConfiguration? = nil) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PI_DESKTOP"] = "1"
        environment["PATH"] = mergedPath(environment["PATH"])
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["SHELL"] = environment["SHELL"] ?? "/bin/zsh"
        if let remoteHost,
           remoteHost.mode == .remoteSSH,
           remoteHost.remoteAuthMethod == .password,
           let askpass = RemoteSSHSupport.bundledAskpassPath() {
            environment["SSH_ASKPASS"] = askpass
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            if let path = try? RemoteCredentialStore.credentialPath(for: remoteHost) {
                environment["APPLE_PI_ASKPASS_FILE"] = path
            }
        }
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    private func notificationExtensionArguments() -> [String] {
        guard let extensionPath = bundledNotificationExtensionPath() else { return [] }
        return ["--extension", extensionPath]
    }

    private func bundledNotificationExtensionPath() -> String? {
        guard let notificationExtensionResourceURL else { return nil }
        let candidates = [
            notificationExtensionResourceURL.appendingPathComponent("ApplePiNotifyExtension.mjs"),
            notificationExtensionResourceURL.appendingPathComponent("Resources/ApplePiNotifyExtension.mjs")
        ]

        return candidates.first { Foundation.FileManager().fileExists(atPath: $0.path) }?.path
    }

    private func mergedPath(_ inheritedPath: String?) -> String {
        let inheritedParts = inheritedPath?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        var seen = Set<String>()
        return (defaultPathParts + inheritedParts)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private func localExecutable(for configuredExecutable: String) -> ResolvedExecutable {
        let expanded = configuredExecutable.expandingTilde.nilIfBlank ?? "pi"
        if expanded.contains("/") {
            return ResolvedExecutable(path: expanded, arguments: [], execName: URL(fileURLWithPath: expanded).lastPathComponent)
        }
        return ResolvedExecutable(path: "/usr/bin/env", arguments: [expanded], execName: nil)
    }

    private var remotePathPrefix: String {
        let path = (remoteDefaultPathParts + ["$PATH"]).joined(separator: ":")
        return "export PATH=\"\(path)\""
    }

    private func remoteShellPathWord(_ path: String) -> String {
        if path == "~" {
            return "$HOME"
        }
        if path.hasPrefix("~/") {
            let relativePath = String(path.dropFirst(2))
            return "$HOME/" + relativePath.shellQuoted
        }
        return path.shellQuoted
    }

    private var defaultPathParts: [String] {
        [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    private var remoteDefaultPathParts: [String] {
        [
            "$HOME/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }
}

private struct ResolvedExecutable {
    let path: String
    let arguments: [String]
    let execName: String?
}
