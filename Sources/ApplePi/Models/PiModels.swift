import Foundation

enum PiHostMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case remoteSSH

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local Mac"
        case .remoteSSH: "Remote SSH"
        }
    }
}

struct PiHostConfiguration: Codable, Equatable, Sendable {
    var mode: PiHostMode = .local
    var piExecutable: String = "pi"
    var agentDirectory: String = "~/.pi/agent"
    var remoteHost: String = ""
    var remotePort: Int = 22
    var remoteUser: String = ""
    var remotePiExecutable: String = "pi"
    var remoteAuthMethod: RemoteAuthMethod = .publicKey
    var remoteIdentityFile: String = ""
    var remoteSSHConfigAlias: String = ""
    /// Base URL or IP:port of the future lightweight `pi-appd` daemon.
    /// Example: `http://100.100.20.10:8787`.
    var remoteDaemonURL: String = ""

    init(
        mode: PiHostMode = .local,
        piExecutable: String = "pi",
        agentDirectory: String = "~/.pi/agent",
        remoteHost: String = "",
        remotePort: Int = 22,
        remoteUser: String = "",
        remotePiExecutable: String = "pi",
        remoteAuthMethod: RemoteAuthMethod = .publicKey,
        remoteIdentityFile: String = "",
        remoteSSHConfigAlias: String = "",
        remoteDaemonURL: String = ""
    ) {
        self.mode = mode
        self.piExecutable = piExecutable
        self.agentDirectory = agentDirectory
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.remoteUser = remoteUser
        self.remotePiExecutable = remotePiExecutable
        self.remoteAuthMethod = remoteAuthMethod
        self.remoteIdentityFile = remoteIdentityFile
        self.remoteSSHConfigAlias = remoteSSHConfigAlias
        self.remoteDaemonURL = remoteDaemonURL
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case piExecutable
        case agentDirectory
        case remoteHost
        case remotePort
        case remoteUser
        case remotePiExecutable
        case remoteAuthMethod
        case remoteIdentityFile
        case remoteSSHConfigAlias
        case remoteDaemonURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(PiHostMode.self, forKey: .mode) ?? .local
        piExecutable = try container.decodeIfPresent(String.self, forKey: .piExecutable) ?? "pi"
        agentDirectory = try container.decodeIfPresent(String.self, forKey: .agentDirectory) ?? "~/.pi/agent"
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost) ?? ""
        remotePort = try container.decodeIfPresent(Int.self, forKey: .remotePort) ?? 22
        remoteUser = try container.decodeIfPresent(String.self, forKey: .remoteUser) ?? ""
        remotePiExecutable = try container.decodeIfPresent(String.self, forKey: .remotePiExecutable) ?? "pi"
        remoteAuthMethod = try container.decodeIfPresent(RemoteAuthMethod.self, forKey: .remoteAuthMethod) ?? .publicKey
        remoteIdentityFile = try container.decodeIfPresent(String.self, forKey: .remoteIdentityFile) ?? ""
        remoteSSHConfigAlias = try container.decodeIfPresent(String.self, forKey: .remoteSSHConfigAlias) ?? ""
        remoteDaemonURL = try container.decodeIfPresent(String.self, forKey: .remoteDaemonURL) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(piExecutable, forKey: .piExecutable)
        try container.encode(agentDirectory, forKey: .agentDirectory)
        try container.encode(remoteHost, forKey: .remoteHost)
        try container.encode(remotePort, forKey: .remotePort)
        try container.encode(remoteUser, forKey: .remoteUser)
        try container.encode(remotePiExecutable, forKey: .remotePiExecutable)
        try container.encode(remoteAuthMethod, forKey: .remoteAuthMethod)
        try container.encode(remoteIdentityFile, forKey: .remoteIdentityFile)
        try container.encode(remoteSSHConfigAlias, forKey: .remoteSSHConfigAlias)
        try container.encode(remoteDaemonURL, forKey: .remoteDaemonURL)
    }

    var sessionRoot: String {
        "\(agentDirectory.expandingTilde)/sessions"
    }

    var remoteAddress: String {
        let trimmedHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = remoteUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { return trimmedHost }
        return "\(trimmedUser)@\(trimmedHost)"
    }

    var remoteDaemonDisplayAddress: String {
        remoteDaemonURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the user selected an `IdentityFile` (or a config alias that
    /// resolves to one) and we should pass it to ssh with `-i`.
    var hasExplicitIdentityFile: Bool {
        !remoteIdentityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// How Apple Pi authenticates the SSH connection to the remote host.
///
/// The raw `ssh` binary handles public-key auth automatically through the
/// system agent and the user's `~/.ssh/config`. Apple Pi adds:
///   * an explicit `-i` flag plus `IdentitiesOnly=yes` when the user picks a
///     key from the picker, so we don't fall through to other keys in the
///     agent; and
///   * `PreferredAuthentications=password` plus an `SSH_ASKPASS` helper when
///     the user opts into password auth.
enum RemoteAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case publicKey
    case password

    var id: String { rawValue }

    var title: String {
        switch self {
        case .publicKey: "Public Key"
        case .password: "Password"
        }
    }

    var requiresKeychainEntry: Bool {
        self == .password
    }
}

struct PiProject: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let workingDirectory: String?
    let sessionDirectory: String
    let sessionCount: Int
    let lastActivity: Date?
}

struct PiSessionSummary: Identifiable, Hashable, Sendable {
    let id: String
    let filePath: String
    let projectID: String
    let title: String
    let workingDirectory: String?
    let messageCount: Int
    let modifiedAt: Date
    let displayName: String?
    let parentSession: String?
    let branchCount: Int
    let labelCount: Int
    let branchSummaryCount: Int
    let latestModel: String?

    var subtitle: String {
        if let workingDirectory, !workingDirectory.isEmpty {
            return workingDirectory
        }
        return URL(fileURLWithPath: filePath).lastPathComponent
    }

    var hasMetadata: Bool {
        messageCount > 0 || parentSession != nil || branchCount > 0 || labelCount > 0 || branchSummaryCount > 0 || latestModel != nil
    }
}

enum PiSelection: Hashable, Sendable {
    case project(String)
    case session(String)
}

struct PiLaunchRequest: Hashable, Sendable {
    var workingDirectory: String?
    var sessionPath: String?
    var forkPath: String?
    var sessionName: String?
    var isEphemeral: Bool
    var initialPrompt: String?

    static func resume(_ session: PiSessionSummary) -> PiLaunchRequest {
        PiLaunchRequest(
            workingDirectory: session.workingDirectory,
            sessionPath: session.filePath,
            forkPath: nil,
            sessionName: nil,
            isEphemeral: false,
            initialPrompt: nil
        )
    }

    static func fork(_ session: PiSessionSummary) -> PiLaunchRequest {
        PiLaunchRequest(
            workingDirectory: session.workingDirectory,
            sessionPath: nil,
            forkPath: session.filePath,
            sessionName: nil,
            isEphemeral: false,
            initialPrompt: nil
        )
    }
}

extension String {
    var expandingTilde: String {
        guard hasPrefix("~") else { return self }
        return NSString(string: self).expandingTildeInPath
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
