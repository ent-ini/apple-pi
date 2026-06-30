import Foundation

package enum PiHostMode: String, CaseIterable, Identifiable, Sendable {
    /// Legacy value kept only so old preferences/tests can still decode. New UI
    /// exposes Remote API exclusively; local Pi execution is no longer a product
    /// mode and must not be selected by default.
    case local
    case remoteAPI

    package static var allCases: [PiHostMode] { [.remoteAPI] }

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .local: "Local Mac (legacy)"
        case .remoteAPI: "Remote API"
        }
    }
}

package extension PiHostMode: Codable {
    package init(from decoder: Decoder) throws {
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

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

package struct PiHostConfiguration: Codable, Equatable, Sendable {
    package var mode: PiHostMode = .remoteAPI
    package var piExecutable: String = "pi"
    package var agentDirectory: String = "~/.pi/agent"
    /// Base URL or IP:port of the `pi-appd` daemon that Apple Pi talks
    /// to in Remote API mode. The Mac client only ever reaches Pi
    /// through this daemon.
    ///
    /// Example: `http://100.100.20.10:8787`.
    package var remoteDaemonURL: String = ""
    package var defaultWorkingDirectory: String = "~/ai-agent/workspace"

    package init(
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

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(PiHostMode.self, forKey: .mode) ?? .remoteAPI
        piExecutable = try container.decodeIfPresent(String.self, forKey: .piExecutable) ?? "pi"
        agentDirectory = try container.decodeIfPresent(String.self, forKey: .agentDirectory) ?? "~/.pi/agent"
        remoteDaemonURL = try container.decodeIfPresent(String.self, forKey: .remoteDaemonURL) ?? ""
        defaultWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .defaultWorkingDirectory) ?? "~/ai-agent/workspace"
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(piExecutable, forKey: .piExecutable)
        try container.encode(agentDirectory, forKey: .agentDirectory)
        try container.encode(remoteDaemonURL, forKey: .remoteDaemonURL)
        try container.encode(defaultWorkingDirectory, forKey: .defaultWorkingDirectory)
    }

    package var sessionRoot: String {
        "\(agentDirectory.expandingTilde)/sessions"
    }

    package var remoteDaemonDisplayAddress: String {
        remoteDaemonURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package var hasRemoteDaemonConfigured: Bool {
        remoteDaemonDisplayAddress.nilIfBlank != nil
    }

    /// pi-app is remote-daemon-only. Returning true even before the URL is
    /// configured keeps callers on the RemoteDaemonClient path, where they get
    /// a clear "Remote API URL is not configured" error instead of silently
    /// falling back to local process/filesystem behavior.
    package var usesRemoteDaemonTransport: Bool {
        true
    }

    package var remoteDaemonBaseURL: URL? {
        let raw = remoteDaemonDisplayAddress
        guard let value = raw.nilIfBlank else { return nil }
        if let direct = URL(string: value), direct.scheme != nil {
            return direct
        }
        return URL(string: "http://\(value)")
    }
}

package struct PiProject: Identifiable, Hashable, Sendable {
    package let id: String
    package let title: String
    package let workingDirectory: String?
    package let sessionDirectory: String
    package let sessionCount: Int
    package let lastActivity: Date?

    package init(
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

package struct PiSessionSummary: Identifiable, Hashable, Sendable {
    package let id: String
    package let filePath: String
    package let projectID: String
    package let title: String
    package let workingDirectory: String?
    package let messageCount: Int
    package let modifiedAt: Date
    package let displayName: String?
    package let parentSession: String?
    package let branchCount: Int
    package let labelCount: Int
    package let branchSummaryCount: Int
    package let latestModel: String?

    package init(
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
        latestModel: String?
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
    }

    package var subtitle: String {
        if let workingDirectory, !workingDirectory.isEmpty {
            return workingDirectory
        }
        return URL(fileURLWithPath: filePath).lastPathComponent
    }

    package var hasMetadata: Bool {
        messageCount > 0 || parentSession != nil || branchCount > 0 || labelCount > 0 || branchSummaryCount > 0 || latestModel != nil
    }
}

package enum PiSelection: Hashable, Sendable {
    case project(String)
    case session(String)
}

package struct PiLaunchRequest: Hashable, Sendable {
    package var workingDirectory: String?
    package var sessionPath: String?
    package var forkPath: String?
    package var sessionName: String?
    package var isEphemeral: Bool
    package var initialPrompt: String?
    package var initialModelProvider: String?
    package var initialModelID: String?
    package var initialThinkingLevel: String?
    package var hasExplicitInitialModel: Bool
    package var hasExplicitInitialThinkingLevel: Bool

    package init(
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

    package static func resume(_ session: PiSessionSummary) -> PiLaunchRequest {
        PiLaunchRequest(
            workingDirectory: session.workingDirectory,
            sessionPath: session.filePath,
            forkPath: nil,
            sessionName: nil,
            isEphemeral: false,
            initialPrompt: nil
        )
    }

    package static func fork(_ session: PiSessionSummary) -> PiLaunchRequest {
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

package extension String {
    package var expandingTilde: String {
        guard hasPrefix("~") else { return self }
        return NSString(string: self).expandingTildeInPath
    }

    package var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
