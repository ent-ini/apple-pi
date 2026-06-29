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

/// Browser for folders on a remote host.
///
/// The current release only reaches the daemon transport: every public
/// method delegates to `RemoteDaemonClient`, which speaks bearer-token
/// HTTP to `pi-appd`. The macOS client never shells out to helper tools
/// on the remote host for directory listing.
struct RemoteDirectoryService: Sendable {
    func listDirectories(host: PiHostConfiguration, path: String?) async throws -> RemoteDirectoryListing {
        try await RemoteDaemonClient().listDirectories(host: host, path: path)
    }
}
