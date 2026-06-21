import Foundation

struct RemoteDirectoryListing: Sendable {
    let path: String
    let parent: String?
    let directories: [RemoteDirectoryEntry]
}

struct RemoteDirectoryEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String

    var id: String { path }
}

struct RemoteDirectoryService: Sendable {
    func listDirectories(host: PiHostConfiguration, path: String?) async throws -> RemoteDirectoryListing {
        if host.usesRemoteDaemonTransport {
            return try await RemoteDaemonClient().listDirectories(host: host, path: path)
        }

        guard !host.remoteAddress.isEmpty else {
            throw RemoteDirectoryError.missingHost
        }

        var arguments = ["-o", "ConnectTimeout=8"]
        arguments.append(contentsOf: RemoteSSHSupport.commonArguments(for: host))
        if host.hasExplicitIdentityFile {
            arguments.append(contentsOf: ["-i", host.remoteIdentityFile.expandingTilde])
        }
        arguments.append(host.remoteAddress)
        arguments.append(remoteDirectoryScript(path: path?.nilIfBlank ?? "~"))

        let environment = RemoteSSHSupport.remoteEnvironment(
            for: host,
            askpassExecutable: RemoteSSHSupport.bundledAskpassPath()
        )

        let result = try ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: environment,
            timeout: 12
        )
        if result.timedOut {
            throw RemoteDirectoryError.scanFailed("Remote folder scan timed out.")
        }
        guard result.terminationStatus == 0 else {
            let message = String(data: result.standardError, encoding: .utf8) ?? "Remote folder scan failed."
            throw RemoteDirectoryError.scanFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let record = try JSONDecoder().decode(RemoteDirectoryListingRecord.self, from: result.standardOutput)
        return RemoteDirectoryListing(
            path: record.path,
            parent: record.parent,
            directories: record.directories.map { RemoteDirectoryEntry(name: $0.name, path: $0.path) }
        )
    }

    private func remoteDirectoryScript(path: String) -> String {
        """
        python3 -c \(remotePythonSource.shellQuoted) \(path.shellQuoted)
        """
    }

    private var remotePythonSource: String {
        """
        import json, os, sys
        requested = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else '~'
        path = os.path.abspath(os.path.expanduser(requested))
        parent = os.path.dirname(path) if os.path.dirname(path) != path else None
        entries = []
        try:
            names = sorted(os.listdir(path), key=lambda value: value.lower())
            for name in names:
                full = os.path.join(path, name)
                if os.path.isdir(full):
                    entries.append({'name': name, 'path': full})
        except Exception as error:
            print(str(error), file=sys.stderr)
            sys.exit(1)
        print(json.dumps({'path': path, 'parent': parent, 'directories': entries}))
        """
    }

    enum RemoteDirectoryError: LocalizedError {
        case missingHost
        case scanFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingHost:
                return "Remote host is not configured."
            case .scanFailed(let message):
                return message.isEmpty ? "Remote folder scan failed." : message
            }
        }
    }
}

private struct RemoteDirectoryListingRecord: Decodable {
    let path: String
    let parent: String?
    let directories: [RemoteDirectoryEntryRecord]
}

private struct RemoteDirectoryEntryRecord: Decodable {
    let name: String
    let path: String
}
