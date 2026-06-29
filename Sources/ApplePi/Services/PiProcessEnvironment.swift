import Foundation

/// Process-environment helpers shared by local Pi child processes.
///
/// The parent process environment is filtered through a small allowlist
/// instead of being passed through wholesale, so secrets such as model
/// provider API keys, GitHub tokens, cloud credentials, etc. do not leak
/// into the agent just because they were present in the launching shell.
enum PiProcessEnvironment {
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

    static func processEnvironment(
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in allowlistedEnvironmentKeys {
            if let value = parentEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        if environment["HOME"] == nil {
            environment["HOME"] = NSHomeDirectory()
        }
        if environment["USER"] == nil {
            environment["USER"] = NSUserName()
        }
        environment["PATH"] = "\(localDefaultPath):\(environment["PATH"] ?? "")"
        return environment
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
