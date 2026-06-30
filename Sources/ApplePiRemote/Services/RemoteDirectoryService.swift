import Foundation
import ApplePiCore

package struct RemoteDirectoryListing: Sendable {
    package let path: String
    package let parent: String?
    package let directories: [RemoteDirectoryEntry]
}

package struct RemoteDirectoryEntry: Identifiable, Hashable, Sendable {
    package let name: String
    package let path: String

    package var id: String { path }
}

/// Browser for folders on a remote host.
///
/// The current release only reaches the daemon transport: every public
/// method delegates to `RemoteDaemonClient`, which speaks bearer-token
/// HTTP to `pi-appd`. The macOS client never shells out to helper tools
/// on the remote host for directory listing.
package struct RemoteDirectoryService: Sendable {
    package func listDirectories(host: PiHostConfiguration, path: String?) async throws -> RemoteDirectoryListing {
        try await RemoteDaemonClient().listDirectories(host: host, path: path)
    }
}
