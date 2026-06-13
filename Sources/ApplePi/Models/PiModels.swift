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

    var sessionRoot: String {
        "\(agentDirectory.expandingTilde)/sessions"
    }

    var remoteAddress: String {
        let trimmedHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = remoteUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { return trimmedHost }
        return "\(trimmedUser)@\(trimmedHost)"
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
