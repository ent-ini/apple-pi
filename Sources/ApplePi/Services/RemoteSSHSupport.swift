import Foundation

/// Process-environment helpers shared by the local Pi runner and the
/// `pi-appd` remote turn path. Centralising the allowlist here keeps
/// the secrets-stripping behaviour consistent between the two call
/// sites.
///
/// The file also still carries the SSH-flavored helpers
/// (`commonArguments`, `remoteEnvironment`, `bundledAskpassPath`) that
/// were wired up when the remote runtime was SSH-based. The current
/// release does not call them; remote mode is now a pure HTTP client
/// against `pi-appd`. They are kept so a future local-SSH passthrough
/// can reuse them without re-deriving the password/identity plumbing,
/// and the test suite (`RemoteSSHSupportTests`) pins their behaviour.
enum RemoteSSHSupport {
    /// Environment variable names we are willing to forward to the child
    /// `pi` and `ssh` processes. Everything else from the parent process is
    /// intentionally dropped so secrets such as `OPENAI_API_KEY`,
    /// `GITHUB_TOKEN`, `AWS_*`, etc. that might be set in the launching
    /// shell (Terminal, an IDE, a CI launcher) do not leak into the agent
    /// or onto the remote host.
    ///
    /// The list is small and explicit on purpose. Add a key here only
    /// after confirming it is both safe to forward and actually required
    /// by `pi` or `ssh`.
    static let allowlistedEnvironmentKeys: [String] = [
        "HOME",
        "USER",
        "LOGNAME",
        "PATH",
        "TMPDIR",
        "SHELL",
        "TERM",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "XDG_RUNTIME_DIR"
    ]

    /// Process environment used when invoking `ssh` for one-shot operations
    /// (catalog scan, directory listing) and when launching the local
    /// `pi` agent. The parent process's environment is filtered through
    /// `allowlistedEnvironmentKeys` rather than passed through wholesale.
    ///
    /// `parentEnvironment` defaults to the real process environment but is
    /// overridable for tests.
    static func processEnvironment(
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in allowlistedEnvironmentKeys {
            if let value = parentEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        // Always guarantee a HOME and USER, even if the launching shell
        // happened to leave them blank — tools that expand `~` or read
        // `$USER` would otherwise misbehave in a way that's hard to
        // diagnose from inside the agent.
        if environment["HOME"] == nil {
            environment["HOME"] = NSHomeDirectory()
        }
        if environment["USER"] == nil {
            environment["USER"] = NSUserName()
        }
        environment["PATH"] = "\(localDefaultPath):\(environment["PATH"] ?? "")"
        return environment
    }

    /// Builds the full environment for a remote SSH call: PATH, askpass
    /// helper, password file pointer, and the dummy `DISPLAY` ssh insists on.
    static func remoteEnvironment(
        for host: PiHostConfiguration,
        askpassExecutable: String?,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = processEnvironment(parentEnvironment: parentEnvironment)
        if let askpassExecutable, !askpassExecutable.isEmpty {
            environment["SSH_ASKPASS"] = askpassExecutable
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            // ssh refuses to invoke SSH_ASKPASS unless DISPLAY is set to a
            // non-empty value, even with SSH_ASKPASS_REQUIRE=force.
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            if let path = try? RemoteCredentialStore.credentialPath(for: host) {
                environment["APPLE_PI_ASKPASS_FILE"] = path
            }
        }
        return environment
    }

    /// Common ssh flags applied to every remote invocation. Order matters:
    /// `-p` only takes effect for the immediately following positional host,
    /// so it has to come right before `host.remoteAddress`.
    static func commonArguments(for host: PiHostConfiguration) -> [String] {
        var arguments: [String] = ["-o", "BatchMode=no"]
        if host.remotePort > 0, host.remotePort != 22 {
            arguments.append(contentsOf: ["-p", String(host.remotePort)])
        }

        switch host.remoteAuthMethod {
        case .password:
            arguments.append(contentsOf: [
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ])
        case .publicKey:
            if host.hasExplicitIdentityFile {
                arguments.append(contentsOf: [
                    "-o", "IdentitiesOnly=yes"
                ])
            }
        }

        return arguments
    }

    /// Returns the absolute path of the bundled `pi-app-askpass` helper, or
    /// nil when the binary cannot be located (development builds, tests).
    static func bundledAskpassPath() -> String? {
        let bundleResources = Bundle.main.bundlePath + "/Contents/Resources/pi-app-askpass"
        let legacyBundleResources = Bundle.main.bundlePath + "/Contents/Resources/ApplePiAskpass"
        let bundleMacOS = Bundle.main.bundlePath + "/Contents/MacOS/pi-app-askpass"
        // `swift run` puts the helper next to the main executable, in the
        // same directory as `Bundle.main.executableURL`.
        let swiftRunCandidate = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("ApplePiAskpass")
            .path
        let candidates: [String] = [bundleResources, legacyBundleResources, bundleMacOS, swiftRunCandidate].compactMap { $0 }
        let fileManager = Foundation.FileManager()
        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static var localDefaultPath: String {
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
        ].joined(separator: ":")
    }
}
