import Foundation
import ApplePiCore

public struct RemoteDirectoryListing: Sendable {
    public let path: String
    public let parent: String?
    public let directories: [RemoteDirectoryEntry]
}

public struct RemoteDirectoryEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String

    public var id: String { path }
}

/// Browser for folders on a remote host.
///
/// The current release only reaches the daemon transport: every public
/// method delegates to `RemoteDaemonClient`, which speaks bearer-token
/// HTTP to `pi-appd`. The macOS client never shells out to helper tools
/// on the remote host for directory listing.
public struct RemoteDirectoryService: Sendable {
    public init() {}

    public func listDirectories(host: PiHostConfiguration, path: String?) async throws -> RemoteDirectoryListing {
        try await RemoteDaemonClient().listDirectories(host: host, path: path)
    }
}
