import Foundation

/// Stores SSH passwords on disk under Application Support, one file per host,
/// mode 0600. The `ApplePiAskpass` helper reads the file path passed through
/// `SSH_ASKPASS_REQUIRE`-style env vars and prints the contents to stdout so
/// OpenSSH can consume it as a password prompt answer.
///
/// We deliberately do not use the macOS Keychain here: the keychain prompts
/// the user the first time the helper binary (which is a different code
/// signature from the app) reads a generic password item, which interrupts
/// SSH sessions with a modal dialog. A user-owned file with `0600` perms is
/// simple, transparent, and not visible to other users.
enum RemoteCredentialStore {
    /// Override hook for tests. The default is the user's real Application
    /// Support directory, which is what the running app wants.
    nonisolated(unsafe) static var applicationSupportOverride: String?

    enum CredentialError: LocalizedError {
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

    /// Persists a password for `host`. Existing files are overwritten.
    static func savePassword(_ password: String, for host: PiHostConfiguration) throws {
        let data = Data(password.utf8)
        try write(data: data, for: host)
    }

    /// Removes the stored password for `host` if present. Missing files are
    /// not treated as errors — clearing should always succeed.
    static func deletePassword(for host: PiHostConfiguration) throws {
        let fileManager = Foundation.FileManager()
        let path = try credentialPath(for: host)
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    /// Returns true when a password file is present for `host`.
    static func hasPassword(for host: PiHostConfiguration) -> Bool {
        guard let path = try? credentialPath(for: host) else { return false }
        return Foundation.FileManager().fileExists(atPath: path)
    }

    /// Reads the password for `host`. Intended for the askpass helper, which
    /// receives the path through an env var. The app itself should not need
    /// to read the password back.
    static func readPassword(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the on-disk path for `host`. Used by the SSH command builder
    /// to wire `APPLE_PI_ASKPASS_FILE` to the askpass helper.
    static func credentialPath(for host: PiHostConfiguration) throws -> String {
        let support = try supportDirectory()
        let hostHash = sanitizedHostIdentifier(for: host)
        return "\(support)/\(hostHash).pw"
    }

    // MARK: - Private

    private static func write(data: Data, for host: PiHostConfiguration) throws {
        let path = try credentialPath(for: host)
        do {
            try SecureSecretFileWriter.writeAtomically(data: data, to: path)
        } catch {
            throw CredentialError.ioFailure("Could not write credentials file: \(error.localizedDescription)")
        }
    }

    private static func supportDirectory() throws -> String {
        if let override = applicationSupportOverride {
            return "\(override)/ApplePi/credentials"
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CredentialError.homeDirectoryUnavailable
        }
        return support.appendingPathComponent("ApplePi/credentials", isDirectory: true).path
    }

    /// Produces a stable, filesystem-safe identifier for the host. Falls
    /// back to a SHA-like digest for the unlikely case where the sanitized
    /// string is empty.
    private static func sanitizedHostIdentifier(for host: PiHostConfiguration) -> String {
        let raw = host.remoteAddress.isEmpty
            ? "default"
            : "\(host.remoteUser)_\(host.remoteHost)_\(host.remotePort)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let joined = String(scalars)
        if joined.count > 96 {
            return String(joined.prefix(96))
        }
        return joined.isEmpty ? "default" : joined
    }
}
