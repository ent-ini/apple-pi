import Foundation

/// Shared SSH plumbing for the catalog scanner, the remote-directory
/// service, and the terminal launcher. Centralising this keeps the
/// password-auth path (SSH_ASKPASS wiring, environment variables) in one
/// place so the three call sites cannot drift.
enum RemoteSSHSupport {
    /// Process environment used when invoking `ssh` for one-shot operations
    /// (catalog scan, directory listing). The terminal launcher applies its
    /// own env because it needs the merged PATH plus the askpass env vars.
    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(localDefaultPath):\(environment["PATH"] ?? "")"
        return environment
    }

    /// Builds the full environment for a remote SSH call: PATH, askpass
    /// helper, password file pointer, and the dummy `DISPLAY` ssh insists on.
    static func remoteEnvironment(
        for host: PiHostConfiguration,
        askpassExecutable: String?
    ) -> [String: String] {
        var environment = processEnvironment()
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

    /// Returns the absolute path of the bundled `ApplePiAskpass` helper, or
    /// nil when the binary cannot be located (development builds, tests).
    static func bundledAskpassPath() -> String? {
        let bundleResources = Bundle.main.bundlePath + "/Contents/Resources/ApplePiAskpass"
        let bundleMacOS = Bundle.main.bundlePath + "/Contents/MacOS/ApplePiAskpass"
        // `swift run` puts the helper next to the main executable, in the
        // same directory as `Bundle.main.executableURL`.
        let swiftRunCandidate = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("ApplePiAskpass")
            .path
        let candidates: [String] = [bundleResources, bundleMacOS, swiftRunCandidate].compactMap { $0 }
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
