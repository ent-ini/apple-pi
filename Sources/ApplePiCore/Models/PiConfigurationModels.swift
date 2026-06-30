import Foundation

public enum PiTrustStatus: Equatable, Sendable {
    case trusted
    case untrusted
    case unknown

    public var title: String {
        switch self {
        case .trusted: "Trusted"
        case .untrusted: "Untrusted"
        case .unknown: "Trust Unknown"
        }
    }
}

public struct PiConfigurationSummary: Equatable, Sendable {
    public var projectDirectory: String?
    public var isRemote: Bool = false
    public var trustStatus: PiTrustStatus
    public var globalSettingsPath: String
    public var projectSettingsPath: String?
    public var piDirectoryPath: String?
    public var agentDirectoryPath: String
    public var sessionRoot: String
    public var settingsCount: Int
    public var contextFileCount: Int
    public var resourceCount: Int
    public var settingsPaths: [String]
    public var contextFilePaths: [String]
    public var resourceRootPaths: [String]

    public init(
        projectDirectory: String?,
        isRemote: Bool = false,
        trustStatus: PiTrustStatus,
        globalSettingsPath: String,
        projectSettingsPath: String?,
        piDirectoryPath: String?,
        agentDirectoryPath: String,
        sessionRoot: String,
        settingsCount: Int,
        contextFileCount: Int,
        resourceCount: Int,
        settingsPaths: [String],
        contextFilePaths: [String],
        resourceRootPaths: [String]
    ) {
        self.projectDirectory = projectDirectory
        self.isRemote = isRemote
        self.trustStatus = trustStatus
        self.globalSettingsPath = globalSettingsPath
        self.projectSettingsPath = projectSettingsPath
        self.piDirectoryPath = piDirectoryPath
        self.agentDirectoryPath = agentDirectoryPath
        self.sessionRoot = sessionRoot
        self.settingsCount = settingsCount
        self.contextFileCount = contextFileCount
        self.resourceCount = resourceCount
        self.settingsPaths = settingsPaths
        self.contextFilePaths = contextFilePaths
        self.resourceRootPaths = resourceRootPaths
    }

    public var hasProjectContext: Bool {
        projectDirectory != nil
    }

    public var trustDisplayTitle: String {
        if isRemote { return "Remote API" }
        guard hasProjectContext else { return "Global" }
        if settingsCount <= 1 && contextFileCount <= 1 {
            return "Defaults"
        }
        return trustStatus.title
    }

    public var trustDetail: String {
        if isRemote {
            return "This session group is on a remote host reached through pi-appd. Local file actions and trust checks are unavailable from the Mac client."
        }
        guard hasProjectContext else {
            return "This session group is not tied to a folder. Pi will use global settings and built-in defaults."
        }
        if settingsCount <= 1 && contextFileCount <= 1 {
            return "This folder has no project-local Pi overrides. Pi will use global settings and built-in defaults."
        }
        switch trustStatus {
        case .trusted:
            return "Pi can load trusted project-local settings, instructions, and resources from this folder."
        case .untrusted:
            return "Project-local Pi files exist, but Pi will ignore them until the folder is trusted in the terminal."
        case .unknown:
            return "Project-local Pi files may exist, but the app could not confirm this folder's trust state."
        }
    }

    public static func empty(host: PiHostConfiguration) -> PiConfigurationSummary {
        let agentDirectory = host.agentDirectory.expandingTilde
        return PiConfigurationSummary(
            projectDirectory: nil,
            isRemote: false,
            trustStatus: .unknown,
            globalSettingsPath: "\(agentDirectory)/settings.json",
            projectSettingsPath: nil,
            piDirectoryPath: nil,
            agentDirectoryPath: agentDirectory,
            sessionRoot: "\(agentDirectory)/sessions",
            settingsCount: 0,
            contextFileCount: 0,
            resourceCount: 0,
            settingsPaths: [],
            contextFilePaths: [],
            resourceRootPaths: []
        )
    }

    public static func remote(host: PiHostConfiguration, projectDirectory: String?) -> PiConfigurationSummary {
        let agentDirectory = host.agentDirectory.nilIfBlank ?? "~/.pi/agent"
        let projectDirectory = projectDirectory?.nilIfBlank
        return PiConfigurationSummary(
            projectDirectory: projectDirectory,
            isRemote: true,
            trustStatus: .unknown,
            globalSettingsPath: "",
            projectSettingsPath: nil,
            piDirectoryPath: projectDirectory.map { "\($0)/.pi" },
            agentDirectoryPath: agentDirectory,
            sessionRoot: "\(agentDirectory)/sessions",
            settingsCount: 0,
            contextFileCount: 0,
            resourceCount: 0,
            settingsPaths: [],
            contextFilePaths: [],
            resourceRootPaths: []
        )
    }
}

public struct PiSessionRootResolution: Equatable, Sendable {
    public let roots: [String]
    public let displayRoot: String

    public init(roots: [String], displayRoot: String) {
        self.roots = roots
        self.displayRoot = displayRoot
    }
}

public enum PiConfigurationMetric: Sendable {
    case config
    case instructions
    case resources
}
