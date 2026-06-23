import Foundation

struct RemoteDaemonClient {
    func testConnection(host: PiHostConfiguration, tokenOverride: String? = nil) async throws -> String {
        let _: HealthResponse = try await send(
            host: host,
            path: "/healthz",
            tokenOverride: tokenOverride
        )
        let catalog: CatalogResponse = try await send(
            host: host,
            path: "/sessions",
            tokenOverride: tokenOverride
        )
        return "Connected. \(catalog.projects.count) projects, \(catalog.sessions.count) sessions."
    }

    /// Live subscription to the daemon's `/sessions/stream` SSE endpoint.
    /// Yields a full `PiCatalogSnapshot` every time the daemon emits a
    /// `snapshot` event. Non-snapshot events, heartbeats, and malformed
    /// frames are silently skipped — the stream only finishes (with an
    /// error) when the underlying HTTP request itself fails. The caller
    /// owns the reconnect cadence.
    func streamCatalogSnapshots(
        host: PiHostConfiguration,
        tokenOverride: String? = nil
    ) -> AsyncThrowingStream<PiCatalogSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    let request = try self.makeLiveRequest(
                        host: host,
                        path: "/sessions/stream",
                        tokenOverride: tokenOverride,
                        accept: "text/event-stream"
                    )
                    let (bytes, response) = try await Self.liveSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteDaemonError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyData = Data()
                        for try await byte in bytes {
                            bodyData.append(byte)
                        }
                        let message = String(data: bodyData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw RemoteDaemonError.requestFailed(status: http.statusCode, body: message)
                    }

                    let parser = SSECatalogEventParser()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let event = parser.feed(line),
                              event.event == "snapshot" else { continue }
                        guard let data = event.data.data(using: .utf8),
                              let snapshot = Self.decodeCatalogSnapshot(from: data) else {
                            continue
                        }
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }

    private static func decodeCatalogSnapshot(from data: Data) -> PiCatalogSnapshot? {
        guard let response = try? makeCatalogDecoder().decode(CatalogResponse.self, from: data) else {
            return nil
        }
        return catalogSnapshot(from: response)
    }

    func loadCatalog(host: PiHostConfiguration, activeProjectDirectory: String?, tokenOverride: String? = nil) async throws -> PiCatalogSnapshot {
        let response: CatalogResponse = try await send(
            host: host,
            path: "/sessions",
            queryItems: activeProjectDirectory?.nilIfBlank.map { [URLQueryItem(name: "projectDirectory", value: $0)] } ?? [],
            tokenOverride: tokenOverride
        )
        return Self.catalogSnapshot(from: response)
    }

    func loadSessionEvents(
        host: PiHostConfiguration,
        sessionID: String,
        limit: Int = 120,
        tokenOverride: String? = nil
    ) async throws -> [SessionEvent] {
        let response: EventPageResponse = try await send(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/events",
            queryItems: [URLQueryItem(name: "limit", value: String(limit))],
            tokenOverride: tokenOverride
        )
        return response.events.compactMap { SessionEventParser.decode(line: $0.raw, at: $0.line) }
    }

    func listDirectories(host: PiHostConfiguration, path: String?, tokenOverride: String? = nil) async throws -> RemoteDirectoryListing {
        let response: FileListResponse = try await send(
            host: host,
            path: "/files",
            queryItems: path?.nilIfBlank.map { [URLQueryItem(name: "path", value: $0)] } ?? [],
            tokenOverride: tokenOverride
        )
        return RemoteDirectoryListing(
            path: response.path,
            parent: response.parent,
            directories: response.items.filter(\.isDirectory).map {
                RemoteDirectoryEntry(name: $0.name, path: $0.path)
            }
        )
    }

    func streamNewSession(
        host: PiHostConfiguration,
        request: PiLaunchRequest,
        prompt: String,
        attachments: [UploadedAttachmentReference] = [],
        onEvent: @escaping @Sendable (PiTurnStreamEvent) async -> Void
    ) async throws {
        let body = CreateSessionRequestBody(
            workingDirectory: request.workingDirectory,
            sessionName: request.sessionName,
            isTemporary: request.isEphemeral,
            prompt: prompt,
            forkPath: request.forkPath,
            attachments: attachments
        )
        try await stream(
            host: host,
            path: "/sessions",
            method: "POST",
            body: body,
            onEvent: onEvent
        )
    }

    func streamSend(
        host: PiHostConfiguration,
        sessionID: String,
        prompt: String,
        attachments: [UploadedAttachmentReference] = [],
        onEvent: @escaping @Sendable (PiTurnStreamEvent) async -> Void
    ) async throws {
        let body = SendSessionRequestBody(prompt: prompt, attachments: attachments)
        try await stream(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/send",
            method: "POST",
            body: body,
            onEvent: onEvent
        )
    }

    func uploadAttachment(host: PiHostConfiguration, attachment: ChatAttachment) async throws -> UploadedAttachmentReference {
        let boundary = "ApplePiBoundary-\(UUID().uuidString)"
        var request = try makeRequest(
            host: host,
            path: "/uploads",
            method: "POST",
            accept: "application/json"
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let multipartFileName = attachment.displayName
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\"", with: "-")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(multipartFileName)\"\r\n".data(using: .utf8)!)
        if let mimeType = attachment.mimeType {
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        } else {
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append(try Data(contentsOf: attachment.fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteDaemonError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
        }
        do {
            return try JSONDecoder().decode(UploadedAttachmentReference.self, from: data)
        } catch {
            throw RemoteDaemonError.decodingFailed(error.localizedDescription)
        }
    }

    private func send<Response: Decodable>(
        host: PiHostConfiguration,
        path: String,
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil
    ) async throws -> Response {
        let request = try makeRequest(
            host: host,
            path: path,
            queryItems: queryItems,
            tokenOverride: tokenOverride,
            accept: "application/json"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteDaemonError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
        }

        let decoder = Self.makeCatalogDecoder()
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw RemoteDaemonError.decodingFailed(error.localizedDescription)
        }
    }

    private func stream<Body: Encodable>(
        host: PiHostConfiguration,
        path: String,
        method: String,
        body: Body,
        tokenOverride: String? = nil,
        onEvent: @escaping @Sendable (PiTurnStreamEvent) async -> Void
    ) async throws {
        let request = try makeRequest(
            host: host,
            path: path,
            method: method,
            tokenOverride: tokenOverride,
            body: body,
            accept: "application/x-ndjson"
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteDaemonError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
            }
            let message = String(data: bodyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
        }

        for try await line in bytes.lines {
            if let event = PiTurnStreamParser.parseLine(line) {
                await onEvent(event)
                if case .streamError(let message) = event {
                    throw RemoteDaemonError.requestFailed(status: 0, body: message)
                }
            }
        }
    }

    private func makeRequest(
        host: PiHostConfiguration,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil,
        accept: String
    ) throws -> URLRequest {
        guard let baseURL = host.remoteDaemonBaseURL else {
            throw RemoteDaemonError.missingBaseURL
        }
        guard let token = tokenOverride?.nilIfBlank ?? RemoteDaemonTokenStore.readToken(for: host) else {
            throw RemoteDaemonError.missingToken
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RemoteDaemonError.invalidBaseURL
        }
        let basePath = components.percentEncodedPath
        components.percentEncodedPath = joinedPath(basePath: basePath, requestPath: path)
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw RemoteDaemonError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300
        return request
    }

    private func makeLiveRequest(
        host: PiHostConfiguration,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil,
        accept: String
    ) throws -> URLRequest {
        var request = try makeRequest(
            host: host,
            path: path,
            method: method,
            queryItems: queryItems,
            tokenOverride: tokenOverride,
            accept: accept
        )
        request.timeoutInterval = TimeInterval.infinity
        return request
    }

    private func makeRequest<Body: Encodable>(
        host: PiHostConfiguration,
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil,
        body: Body,
        accept: String
    ) throws -> URLRequest {
        var request = try makeRequest(
            host: host,
            path: path,
            method: method,
            queryItems: queryItems,
            tokenOverride: tokenOverride,
            accept: accept
        )
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func makeCatalogDecoder() -> JSONDecoder {
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
        return decoder
    }

    private static func catalogSnapshot(from response: CatalogResponse) -> PiCatalogSnapshot {
        PiCatalogSnapshot(
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

    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = TimeInterval.infinity
        configuration.timeoutIntervalForResource = TimeInterval.infinity
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()
}

private func joinedPath(basePath: String, requestPath: String) -> String {
    let left = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let right = requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    switch (left.isEmpty, right.isEmpty) {
    case (true, true): return "/"
    case (true, false): return "/\(right)"
    case (false, true): return "/\(left)"
    case (false, false): return "/\(left)/\(right)"
    }
}

private func encodedPathComponent(_ value: String) -> String {
    value.addingPercentEncoding(
        withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    ) ?? value
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
            if status <= 0 {
                return body?.nilIfBlank ?? "Remote API stream failed."
            }
            if let body = body?.nilIfBlank {
                return "Remote API error \(status): \(body)"
            }
            return "Remote API error \(status)."
        case .decodingFailed(let detail):
            return "Could not decode remote API response: \(detail)"
        }
    }
}

private struct HealthResponse: Decodable {
    let ok: Bool
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

struct UploadedAttachmentReference: Codable, Hashable, Sendable {
    let path: String
    let fileName: String
    let mimeType: String?
    let size: Int64?
}

private struct CreateSessionRequestBody: Encodable {
    let workingDirectory: String?
    let sessionName: String?
    let isTemporary: Bool
    let prompt: String
    let forkPath: String?
    let attachments: [UploadedAttachmentReference]
}

private struct SendSessionRequestBody: Encodable {
    let prompt: String
    let attachments: [UploadedAttachmentReference]
}
