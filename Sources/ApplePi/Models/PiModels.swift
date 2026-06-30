import Foundation

enum PiHostMode: String, CaseIterable, Identifiable, Sendable {
    /// Legacy value kept only so old preferences/tests can still decode. New UI
    /// exposes Remote API exclusively; local Pi execution is no longer a product
    /// mode and must not be selected by default.
    case local
    case remoteAPI

    static var allCases: [PiHostMode] { [.remoteAPI] }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local Mac (legacy)"
        case .remoteAPI: "Remote API"
        }
    }
}

extension PiHostMode: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Self.remoteAPI.rawValue
        switch rawValue {
        case "remote\u{53}\u{53}\u{48}", Self.remoteAPI.rawValue:
            self = .remoteAPI
        default:
            // pi-app is remote-daemon-only. Treat old/unknown modes (including
            // legacy `local`) as Remote API so the app never falls back to
            // spawning a local `pi` process.
            self = .remoteAPI
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct PiHostConfiguration: Codable, Equatable, Sendable {
    var mode: PiHostMode = .remoteAPI
    var piExecutable: String = "pi"
    var agentDirectory: String = "~/.pi/agent"
    /// Base URL or IP:port of the `pi-appd` daemon that Apple Pi talks
    /// to in Remote API mode. The Mac client only ever reaches Pi
    /// through this daemon.
    ///
    /// Example: `http://100.100.20.10:8787`.
    var remoteDaemonURL: String = ""
    var defaultWorkingDirectory: String = "~/ai-agent/workspace"

    init(
        mode: PiHostMode = .remoteAPI,
        piExecutable: String = "pi",
        agentDirectory: String = "~/.pi/agent",
        remoteDaemonURL: String = "",
        defaultWorkingDirectory: String = "~/ai-agent/workspace"
    ) {
        self.mode = mode
        self.piExecutable = piExecutable
        self.agentDirectory = agentDirectory
        self.remoteDaemonURL = remoteDaemonURL
        self.defaultWorkingDirectory = defaultWorkingDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case piExecutable
        case agentDirectory
        case remoteDaemonURL
        case defaultWorkingDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(PiHostMode.self, forKey: .mode) ?? .remoteAPI
        piExecutable = try container.decodeIfPresent(String.self, forKey: .piExecutable) ?? "pi"
        agentDirectory = try container.decodeIfPresent(String.self, forKey: .agentDirectory) ?? "~/.pi/agent"
        remoteDaemonURL = try container.decodeIfPresent(String.self, forKey: .remoteDaemonURL) ?? ""
        defaultWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .defaultWorkingDirectory) ?? "~/ai-agent/workspace"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(piExecutable, forKey: .piExecutable)
        try container.encode(agentDirectory, forKey: .agentDirectory)
        try container.encode(remoteDaemonURL, forKey: .remoteDaemonURL)
        try container.encode(defaultWorkingDirectory, forKey: .defaultWorkingDirectory)
    }

    var sessionRoot: String {
        "\(agentDirectory.expandingTilde)/sessions"
    }

    var remoteDaemonDisplayAddress: String {
        remoteDaemonURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasRemoteDaemonConfigured: Bool {
        remoteDaemonDisplayAddress.nilIfBlank != nil
    }

    /// pi-app is remote-daemon-only. Returning true even before the URL is
    /// configured keeps callers on the RemoteDaemonClient path, where they get
    /// a clear "Remote API URL is not configured" error instead of silently
    /// falling back to local process/filesystem behavior.
    var usesRemoteDaemonTransport: Bool {
        true
    }

    var remoteDaemonBaseURL: URL? {
        let raw = remoteDaemonDisplayAddress
        guard let value = raw.nilIfBlank else { return nil }
        if let direct = URL(string: value), direct.scheme != nil {
            return direct
        }
        return URL(string: "http://\(value)")
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
    var initialModelProvider: String?
    var initialModelID: String?
    var initialThinkingLevel: String?
    var hasExplicitInitialModel: Bool
    var hasExplicitInitialThinkingLevel: Bool

    init(
        workingDirectory: String? = nil,
        sessionPath: String? = nil,
        forkPath: String? = nil,
        sessionName: String? = nil,
        isEphemeral: Bool = false,
        initialPrompt: String? = nil,
        initialModelProvider: String? = nil,
        initialModelID: String? = nil,
        initialThinkingLevel: String? = nil,
        hasExplicitInitialModel: Bool = false,
        hasExplicitInitialThinkingLevel: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.sessionPath = sessionPath
        self.forkPath = forkPath
        self.sessionName = sessionName
        self.isEphemeral = isEphemeral
        self.initialPrompt = initialPrompt
        self.initialModelProvider = initialModelProvider
        self.initialModelID = initialModelID
        self.initialThinkingLevel = initialThinkingLevel
        self.hasExplicitInitialModel = hasExplicitInitialModel
        self.hasExplicitInitialThinkingLevel = hasExplicitInitialThinkingLevel
    }

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
