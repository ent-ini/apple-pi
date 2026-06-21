import Foundation

struct RemoteDaemonClient {
    func loadCatalog(host: PiHostConfiguration, activeProjectDirectory: String?) async throws -> PiCatalogSnapshot {
        let response: CatalogResponse = try await send(
            host: host,
            path: "/sessions",
            queryItems: activeProjectDirectory?.nilIfBlank.map { [URLQueryItem(name: "projectDirectory", value: $0)] } ?? []
        )
        return PiCatalogSnapshot(
            projects: response.projects.map { record in
                PiProject(
                    id: record.id,
                    title: record.title,
                    workingDirectory: record.workingDirectory,
                    sessionDirectory: record.sessionDirectory,
                    sessionCount: record.sessionCount,
                    lastActivity: record.lastActivity
                )
            },
            sessions: response.sessions.map { record in
                PiSessionSummary(
                    id: record.id,
                    filePath: record.filePath,
                    projectID: record.projectID,
                    title: record.title,
                    workingDirectory: record.workingDirectory,
                    messageCount: record.messageCount,
                    modifiedAt: record.modifiedAt,
                    displayName: record.displayName,
                    parentSession: record.parentSession,
                    branchCount: record.branchCount,
                    labelCount: record.labelCount,
                    branchSummaryCount: record.branchSummaryCount,
                    latestModel: record.latestModel
                )
            }
        )
    }

    func loadSessionEvents(host: PiHostConfiguration, sessionID: String) async throws -> [SessionEvent] {
        let encodedID = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        let response: EventPageResponse = try await send(
            host: host,
            path: "/sessions/\(encodedID)/events"
        )
        return response.events.compactMap { SessionEventParser.decode(line: $0.raw, at: $0.line) }
    }

    func listDirectories(host: PiHostConfiguration, path: String?) async throws -> RemoteDirectoryListing {
        let response: FileListResponse = try await send(
            host: host,
            path: "/files",
            queryItems: path?.nilIfBlank.map { [URLQueryItem(name: "path", value: $0)] } ?? []
        )
        return RemoteDirectoryListing(
            path: response.path,
            parent: response.parent,
            directories: response.items.filter(\.isDirectory).map {
                RemoteDirectoryEntry(name: $0.name, path: $0.path)
            }
        )
    }

    private func send<Response: Decodable>(
        host: PiHostConfiguration,
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        guard let baseURL = host.remoteDaemonBaseURL else {
            throw RemoteDaemonError.missingBaseURL
        }
        guard let token = RemoteDaemonTokenStore.readToken(for: host) else {
            throw RemoteDaemonError.missingToken
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RemoteDaemonError.invalidBaseURL
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw RemoteDaemonError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteDaemonError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = RemoteDaemonDateParsers.shared.parse(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid daemon date: \(raw)"
            )
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw RemoteDaemonError.decodingFailed(error.localizedDescription)
        }
    }
}

private final class RemoteDaemonDateParsers: @unchecked Sendable {
    static let shared = RemoteDaemonDateParsers()

    private let lock = NSLock()
    private let withFractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    private init() {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.withFractional = withFractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        self.plain = plain
    }

    func parse(_ raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = withFractional.date(from: raw) { return date }
        return plain.date(from: raw)
    }
}

enum RemoteDaemonError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL
    case missingToken
    case invalidResponse
    case requestFailed(status: Int, body: String?)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Remote API URL is not configured."
        case .invalidBaseURL:
            return "Remote API URL is invalid."
        case .missingToken:
            return "Remote API token is not configured."
        case .invalidResponse:
            return "Remote API returned an invalid response."
        case .requestFailed(let status, let body):
            if let body = body?.nilIfBlank {
                return "Remote API error \(status): \(body)"
            }
            return "Remote API error \(status)."
        case .decodingFailed(let detail):
            return "Could not decode remote API response: \(detail)"
        }
    }
}

private struct CatalogResponse: Decodable {
    let projects: [ProjectRecord]
    let sessions: [SessionRecord]
}

private struct ProjectRecord: Decodable {
    let id: String
    let title: String
    let workingDirectory: String?
    let sessionDirectory: String
    let sessionCount: Int
    let lastActivity: Date?
}

private struct SessionRecord: Decodable {
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
}

private struct EventPageResponse: Decodable {
    let events: [RawEventRecord]
}

private struct RawEventRecord: Decodable {
    let line: Int
    let raw: String
}

private struct FileListResponse: Decodable {
    let path: String
    let parent: String?
    let items: [FileItemRecord]
}

private struct FileItemRecord: Decodable {
    let name: String
    let path: String
    let isDirectory: Bool
}
