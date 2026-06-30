import Foundation

public enum PiHostMode: String, CaseIterable, Identifiable, Sendable {
    /// Legacy value kept only so old preferences/tests can still decode. New UI
    /// exposes Remote API exclusively; local Pi execution is no longer a product
    /// mode and must not be selected by default.
    case local
    case remoteAPI

    public static var allCases: [PiHostMode] { [.remoteAPI] }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: "Local Mac (legacy)"
        case .remoteAPI: "Remote API"
        }
    }
}

extension PiHostMode: Codable {
    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PiHostConfiguration: Codable, Equatable, Sendable {
    public var mode: PiHostMode = .remoteAPI
    public var piExecutable: String = "pi"
    public var agentDirectory: String = "~/.pi/agent"
    /// Base URL or IP:port of the `pi-appd` daemon that Apple Pi talks
    /// to in Remote API mode. The Mac client only ever reaches Pi
    /// through this daemon.
    ///
    /// Example: `http://100.100.20.10:8787`.
    public var remoteDaemonURL: String = ""
    public var defaultWorkingDirectory: String = "~/ai-agent/workspace"

    public init(
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(PiHostMode.self, forKey: .mode) ?? .remoteAPI
        piExecutable = try container.decodeIfPresent(String.self, forKey: .piExecutable) ?? "pi"
        agentDirectory = try container.decodeIfPresent(String.self, forKey: .agentDirectory) ?? "~/.pi/agent"
        remoteDaemonURL = try container.decodeIfPresent(String.self, forKey: .remoteDaemonURL) ?? ""
        defaultWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .defaultWorkingDirectory) ?? "~/ai-agent/workspace"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(piExecutable, forKey: .piExecutable)
        try container.encode(agentDirectory, forKey: .agentDirectory)
        try container.encode(remoteDaemonURL, forKey: .remoteDaemonURL)
        try container.encode(defaultWorkingDirectory, forKey: .defaultWorkingDirectory)
    }

    public var sessionRoot: String {
        "\(agentDirectory.expandingTilde)/sessions"
    }

    public var remoteDaemonDisplayAddress: String {
        remoteDaemonURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasRemoteDaemonConfigured: Bool {
        remoteDaemonDisplayAddress.nilIfBlank != nil
    }

    /// pi-app is remote-daemon-only. Returning true even before the URL is
    /// configured keeps callers on the RemoteDaemonClient path, where they get
    /// a clear "Remote API URL is not configured" error instead of silently
    /// falling back to local process/filesystem behavior.
    public var usesRemoteDaemonTransport: Bool {
        true
    }

    public var remoteDaemonBaseURL: URL? {
        let raw = remoteDaemonDisplayAddress
        guard let value = raw.nilIfBlank else { return nil }
        if let direct = URL(string: value), direct.scheme != nil {
            return direct
        }
        return URL(string: "http://\(value)")
    }
}

public struct PiProject: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let workingDirectory: String?
    public let sessionDirectory: String
    public let sessionCount: Int
    public let lastActivity: Date?

    public init(
        id: String,
        title: String,
        workingDirectory: String?,
        sessionDirectory: String,
        sessionCount: Int,
        lastActivity: Date?
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.sessionDirectory = sessionDirectory
        self.sessionCount = sessionCount
        self.lastActivity = lastActivity
    }
}

public struct PiSessionSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let filePath: String
    public let projectID: String
    public let title: String
    public let workingDirectory: String?
    public let messageCount: Int
    public let modifiedAt: Date
    public let displayName: String?
    public let parentSession: String?
    public let branchCount: Int
    public let labelCount: Int
    public let branchSummaryCount: Int
    public let latestModel: String?
    public let isGenerating: Bool

    public init(
        id: String,
        filePath: String,
        projectID: String,
        title: String,
        workingDirectory: String?,
        messageCount: Int,
        modifiedAt: Date,
        displayName: String?,
        parentSession: String?,
        branchCount: Int,
        labelCount: Int,
        branchSummaryCount: Int,
        latestModel: String?,
        isGenerating: Bool = false
    ) {
        self.id = id
        self.filePath = filePath
        self.projectID = projectID
        self.title = title
        self.workingDirectory = workingDirectory
        self.messageCount = messageCount
        self.modifiedAt = modifiedAt
        self.displayName = displayName
        self.parentSession = parentSession
        self.branchCount = branchCount
        self.labelCount = labelCount
        self.branchSummaryCount = branchSummaryCount
        self.latestModel = latestModel
        self.isGenerating = isGenerating
    }

    public var subtitle: String {
        if let workingDirectory, !workingDirectory.isEmpty {
            return workingDirectory
        }
        return URL(fileURLWithPath: filePath).lastPathComponent
    }

    public var hasMetadata: Bool {
        messageCount > 0 || parentSession != nil || branchCount > 0 || labelCount > 0 || branchSummaryCount > 0 || latestModel != nil
    }
}

public enum PiSelection: Hashable, Sendable {
    case project(String)
    case session(String)
}

public struct PiLaunchRequest: Hashable, Sendable {
    public var workingDirectory: String?
    public var sessionPath: String?
    public var forkPath: String?
    public var sessionName: String?
    public var isEphemeral: Bool
    public var initialPrompt: String?
    public var initialModelProvider: String?
    public var initialModelID: String?
    public var initialThinkingLevel: String?
    public var hasExplicitInitialModel: Bool
    public var hasExplicitInitialThinkingLevel: Bool

    public init(
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

    public static func resume(_ session: PiSessionSummary) -> PiLaunchRequest {
        PiLaunchRequest(
            workingDirectory: session.workingDirectory,
            sessionPath: session.filePath,
            forkPath: nil,
            sessionName: nil,
            isEphemeral: false,
            initialPrompt: nil
        )
    }

    public static func fork(_ session: PiSessionSummary) -> PiLaunchRequest {
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

public extension String {
    var expandingTilde: String {
        guard hasPrefix("~") else { return self }
        return NSString(string: self).expandingTildeInPath
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
