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
        try await RemoteDaemonClient().listDirectories(host: host, path: path)
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
