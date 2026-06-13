import Foundation

enum RemoteSSHSupport {
    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
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
