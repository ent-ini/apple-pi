import Foundation

/// Discovers SSH keys in `~/.ssh/`. The picker surfaces both the default
/// `id_*` keys and any `*.pub` files that have a matching private key next
/// to them, so users can select custom keys without typing the full path.
struct SSHKeyStore {
    struct Key: Identifiable, Hashable, Sendable {
        let id: String          // absolute path to the private key
        let publicKeyPath: String?  // absolute path to the .pub sidecar, if present
        let label: String       // fileName or "fileName (no .pub)"
        let isDefault: Bool     // id_rsa / id_ed25519 / id_ecdsa / id_dsa
    }

    /// Lists keys found in `~/.ssh/`. The list is sorted with the conventional
    /// default keys first, then the rest alphabetically.
    static func discoverKeys(homeDirectory: String = NSHomeDirectory()) -> [Key] {
        let directory = URL(fileURLWithPath: "\(homeDirectory)/.ssh", isDirectory: true)
        let fileManager = Foundation.FileManager()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let defaultNames: Set<String> = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
        var keys: [Key] = []

        for url in contents {
            let name = url.lastPathComponent
            // Skip public key files; we always present keys by their private side.
            if name.hasSuffix(".pub") { continue }
            // Skip non-key files that commonly live in ~/.ssh/ (config, known_hosts, etc.).
            if isNonKeyArtifact(name) { continue }

            let publicCandidate = url.appendingPathExtension("pub").path
            let hasPublic = fileManager.fileExists(atPath: publicCandidate)
            keys.append(Key(
                id: url.path,
                publicKeyPath: hasPublic ? publicCandidate : nil,
                label: name,
                isDefault: defaultNames.contains(name)
            ))
        }

        return keys.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    /// Filenames that exist in `~/.ssh/` but are not keys. We don't want to
    /// offer `known_hosts`, `config`, or `authorized_keys` as auth methods.
    private static func isNonKeyArtifact(_ name: String) -> Bool {
        let excluded: Set<String> = [
            "config",
            "known_hosts",
            "known_hosts2",
            "authorized_keys",
            "rc",
            "environment",
            "ssh_config",
            "sshd_config"
        ]
        return excluded.contains(name) || name.hasSuffix("~") || name.hasSuffix(".bak")
    }
}
