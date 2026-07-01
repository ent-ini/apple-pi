import Foundation
import ApplePiCore
import ApplePiRemote

final class PiSessionCatalogService {
    init(configurationService: PiConfigurationService = PiConfigurationService()) {}

    func loadCatalog(host: PiHostConfiguration, activeProjectDirectory: String? = nil) async throws -> PiCatalogSnapshot {
        try await RemoteDaemonClient().loadCatalog(
            host: host,
            activeProjectDirectory: activeProjectDirectory
        )
    }
}
