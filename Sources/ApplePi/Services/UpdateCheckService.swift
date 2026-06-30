import Foundation
import ApplePiCore
import ApplePiRemote

struct AvailableUpdate: Equatable, Sendable {
    let latestVersion: String
    let releaseURL: URL
}

struct UpdateCheckService: Sendable {
    /// The hardcoded GitHub releases endpoint. The URL falls back to a
    /// local file URL if the literal ever fails to parse, so the app never
    /// crashes on static URL initialisation. The fallback branch is
    /// unreachable for a well-formed HTTPS literal.
    static let latestReleaseURL: URL = URL(string: "https://api.github.com/repos/ent-ini/apple-pi/releases/latest")
        ?? URL(fileURLWithPath: "/")

    private let latestReleaseURL: URL
    private let currentVersionProvider: @Sendable () -> String
    private let fetch: @Sendable (URLRequest) async throws -> HTTPResult

    init(
        latestReleaseURL: URL = Self.latestReleaseURL,
        currentVersionProvider: @escaping @Sendable () -> String = { Self.bundleShortVersion() },
        fetch: @escaping @Sendable (URLRequest) async throws -> HTTPResult = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            return HTTPResult(statusCode: statusCode, data: data)
        }
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.currentVersionProvider = currentVersionProvider
        self.fetch = fetch
    }

    func checkForUpdate() async throws -> AvailableUpdate? {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("pi-app", forHTTPHeaderField: "User-Agent")

        let result = try await fetch(request)
        guard result.statusCode == 200 else { return nil }

        let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: result.data)
        let normalizedRemote = Self.normalizedVersion(release.tagName)
        let current = currentVersionProvider()
        guard Self.isNewer(remote: normalizedRemote, than: current) else { return nil }

        return AvailableUpdate(latestVersion: normalizedRemote, releaseURL: release.htmlURL)
    }

    static func bundleShortVersion(bundle: Bundle = .main) -> String {
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return normalizedVersion(raw ?? "0.0.0")
    }

    static func isNewer(remote: String, than current: String) -> Bool {
        let r = components(from: remote)
        let c = components(from: current)
        let count = max(r.count, c.count)
        for index in 0..<count {
            let rPart = index < r.count ? r[index] : 0
            let cPart = index < c.count ? c[index] : 0
            if rPart > cPart { return true }
            if rPart < cPart { return false }
        }
        return false
    }

    static func normalizedVersion(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else { return trimmed }
        return String(trimmed.dropFirst())
    }

    private static func components(from value: String) -> [Int] {
        normalizedVersion(value)
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }
}

struct HTTPResult: Sendable {
    let statusCode: Int
    let data: Data
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
