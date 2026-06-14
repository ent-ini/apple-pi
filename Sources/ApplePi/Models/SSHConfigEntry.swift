import Foundation

/// A single `Host` block parsed from an OpenSSH `~/.ssh/config` file.
///
/// Matches only the directives Apple Pi currently surfaces in the host picker.
/// `Match` blocks are intentionally ignored: Apple Pi already lets the user
/// override `Host`/`User`/`Port`/`IdentityFile` in its own settings, so the
/// complexity of conditional matching is not worth dragging into the UI.
struct SSHConfigEntry: Identifiable, Hashable, Sendable {
    let id: String
    let hostPatterns: [String]
    let hostName: String?
    let user: String?
    let port: Int?
    let identityFile: String?
    let preferredAuthentications: String?
    let identitiesOnly: Bool?
    let sourcePath: String

    /// The first pattern that is not a wildcard, or the first pattern overall.
    var displayName: String {
        hostPatterns.first(where: { !$0.hasSuffix("*") && !$0.hasPrefix("*") }) ?? hostPatterns.first ?? id
    }

    /// Subtitle shown beneath the alias in the picker.
    var subtitle: String {
        var parts: [String] = []
        if let user, !user.isEmpty { parts.append(user) }
        let host = hostName ?? hostPatterns.first ?? ""
        if !host.isEmpty { parts.append(host) }
        if let port, port != 22 { parts.append(":\(port)") }
        return parts.joined(separator: "@")
    }
}
