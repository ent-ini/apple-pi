import Foundation
import ApplePiCore

package enum RemoteSessionEventLoader {
    package static func load(host: PiHostConfiguration, session: PiSessionSummary) async throws -> [SessionEvent] {
        try await RemoteDaemonClient().loadSessionEvents(host: host, sessionID: session.id)
    }
}
