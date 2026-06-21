import Foundation

enum RemoteSessionEventLoader {
    static func load(host: PiHostConfiguration, session: PiSessionSummary) async throws -> [SessionEvent] {
        if host.usesRemoteDaemonTransport {
            return try await RemoteDaemonClient().loadSessionEvents(host: host, sessionID: session.id)
        }
        return try loadOverSSH(host: host, remotePath: session.filePath)
    }

    private static func loadOverSSH(host: PiHostConfiguration, remotePath: String) throws -> [SessionEvent] {
        guard !host.remoteAddress.isEmpty else {
            throw RemoteSessionLoadError.missingRemoteHost
        }

        var arguments = ["-o", "ConnectTimeout=8"]
        arguments.append(contentsOf: RemoteSSHSupport.commonArguments(for: host))
        if host.hasExplicitIdentityFile {
            arguments.append(contentsOf: ["-i", host.remoteIdentityFile.expandingTilde])
        }
        arguments.append(host.remoteAddress)
        arguments.append(remoteReadCommand(for: remotePath))

        let environment = RemoteSSHSupport.remoteEnvironment(
            for: host,
            askpassExecutable: RemoteSSHSupport.bundledAskpassPath()
        )

        let result = try ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: environment,
            timeout: 20
        )

        if result.timedOut {
            throw RemoteSessionLoadError.timedOut
        }

        guard result.terminationStatus == 0 else {
            let message = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteSessionLoadError.remoteCommandFailed(message?.nilIfBlank)
        }

        guard let text = String(data: result.standardOutput, encoding: .utf8) else {
            return []
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return SessionEventParser.parse(lines: lines)
    }

    private static func remoteReadCommand(for remotePath: String) -> String {
        "LC_ALL=en_US.UTF-8 cat -- \(remotePath.shellQuoted)"
    }
}

enum RemoteSessionLoadError: LocalizedError {
    case missingRemoteHost
    case timedOut
    case remoteCommandFailed(String?)

    var errorDescription: String? {
        switch self {
        case .missingRemoteHost:
            return "Remote host is empty."
        case .timedOut:
            return "Remote session read timed out."
        case .remoteCommandFailed(let message):
            return message ?? "Remote session read failed."
        }
    }
}
