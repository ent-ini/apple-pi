import Foundation

enum PiTrustStatus: Equatable, Sendable {
    case trusted
    case untrusted
    case unknown

    var title: String {
        switch self {
        case .trusted: "Trusted"
        case .untrusted: "Untrusted"
        case .unknown: "Trust Unknown"
        }
    }
}

struct PiConfigurationSummary: Equatable, Sendable {
    var projectDirectory: String?
    var isRemote: Bool = false
    var trustStatus: PiTrustStatus
    var globalSettingsPath: String
    var projectSettingsPath: String?
    var piDirectoryPath: String?
    var agentDirectoryPath: String
    var sessionRoot: String
    var settingsCount: Int
    var contextFileCount: Int
    var resourceCount: Int
    var settingsPaths: [String]
    var contextFilePaths: [String]
    var resourceRootPaths: [String]

    var hasProjectContext: Bool {
        projectDirectory != nil
    }

    var trustDisplayTitle: String {
        if isRemote { return "Remote SSH" }
        guard hasProjectContext else { return "Global" }
        if settingsCount <= 1 && contextFileCount <= 1 {
            return "Defaults"
        }
        return trustStatus.title
    }

    var trustDetail: String {
        if isRemote {
            return "This session group is on a remote SSH host. Apple Pi starts sessions there, but local file actions and trust checks are unavailable."
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

    static func empty(host: PiHostConfiguration) -> PiConfigurationSummary {
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

    static func remote(host: PiHostConfiguration, projectDirectory: String?) -> PiConfigurationSummary {
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

struct PiSessionRootResolution: Equatable, Sendable {
    let roots: [String]
    let displayRoot: String
}

enum PiConfigurationMetric: Sendable {
    case config
    case instructions
    case resources
}
