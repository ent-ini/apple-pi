import Foundation

/// Stores per-remote-daemon bearer tokens on disk under Application Support,
/// one file per daemon URL, mode 0600.
enum RemoteDaemonTokenStore {
    nonisolated(unsafe) static var applicationSupportOverride: String?

    enum TokenError: LocalizedError {
        case homeDirectoryUnavailable
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .homeDirectoryUnavailable:
                return "Could not resolve the Application Support directory."
            case .ioFailure(let detail):
                return detail
            }
        }
    }

    static func saveToken(_ token: String, for host: PiHostConfiguration) throws {
        let data = Data(token.utf8)
        try write(data: data, for: host)
    }

    static func deleteToken(for host: PiHostConfiguration) throws {
        let fileManager = Foundation.FileManager()
        let path = try tokenPath(for: host)
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    static func hasToken(for host: PiHostConfiguration) -> Bool {
        guard let path = try? tokenPath(for: host) else { return false }
        return Foundation.FileManager().fileExists(atPath: path)
    }

    static func readToken(for host: PiHostConfiguration) -> String? {
        guard let path = try? tokenPath(for: host),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    static func tokenPath(for host: PiHostConfiguration) throws -> String {
        let support = try supportDirectory()
        let hostHash = sanitizedHostIdentifier(for: host)
        return "\(support)/\(hostHash).token"
    }

    private static func write(data: Data, for host: PiHostConfiguration) throws {
        let path = try tokenPath(for: host)
        do {
            try SecureSecretFileWriter.writeAtomically(data: data, to: path)
        } catch {
            throw TokenError.ioFailure("Could not write daemon token file: \(error.localizedDescription)")
        }
    }

    private static func supportDirectory() throws -> String {
        if let override = applicationSupportOverride {
            return "\(override)/ApplePi/daemon-tokens"
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TokenError.homeDirectoryUnavailable
        }
        return support.appendingPathComponent("ApplePi/daemon-tokens", isDirectory: true).path
    }

    private static func sanitizedHostIdentifier(for host: PiHostConfiguration) -> String {
        let raw = host.remoteDaemonDisplayAddress.nilIfBlank ?? "default"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let joined = String(scalars)
        if joined.count > 96 {
            return String(joined.prefix(96))
        }
        return joined.isEmpty ? "default" : joined
    }
}
