import Foundation

struct PiCatalogSnapshot: Sendable {
    var projects: [PiProject]
    var sessions: [PiSessionSummary]
    /// Human-readable notes about non-fatal problems encountered while
    /// building the snapshot, e.g. a session file that could not be
    /// read or a session file that exceeded the bounded line cap. The
    /// list is intentionally surfaced to the user via the status bar
    /// rather than swallowed — silent loss of sessions is worse than a
    /// short warning.
    var warnings: [String] = []
}

final class PiSessionCatalogService {
    private let configurationService: PiConfigurationService

    init(configurationService: PiConfigurationService = PiConfigurationService()) {
        self.configurationService = configurationService
    }

    func loadCatalog(host: PiHostConfiguration, activeProjectDirectory: String? = nil) async throws -> PiCatalogSnapshot {
        if host.usesRemoteDaemonTransport {
            return try await RemoteDaemonClient().loadCatalog(
                host: host,
                activeProjectDirectory: activeProjectDirectory
            )
        }

        switch host.mode {
        case .local:
            return try loadLocalCatalog(host: host, activeProjectDirectory: activeProjectDirectory)
        case .remoteSSH:
            return try await loadRemoteCatalog(host: host, activeProjectDirectory: activeProjectDirectory)
        }
    }

    private func loadLocalCatalog(host: PiHostConfiguration, activeProjectDirectory: String?) throws -> PiCatalogSnapshot {
        let roots = configurationService.resolveSessionRoots(host: host, projectDirectory: activeProjectDirectory).roots
        let fileManager = Foundation.FileManager()
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var warnings: [String] = []
        var collectedURLs: [URL] = []
        var seenPaths = Set<String>()

        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard fileManager.fileExists(atPath: rootURL.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { failedURL, error in
                    // Capture and continue. The catalog should still
                    // surface every session we can read even if a
                    // sibling directory returns an error (permissions,
                    // vanished, etc).
                    let path = failedURL.path
                    if !path.isEmpty {
                        warnings.append("Could not enumerate \(path): \(error.localizedDescription)")
                    }
                    return true
                }
            ) else {
                warnings.append("Could not enumerate session root \(rootURL.path).")
                continue
            }

            for case let url as URL in enumerator {
                // Skip symlinks. The enumerator follows them by default,
                // which means a link can re-surface the same file under
                // a different path (and the count, preview, and JSONL
                // validation logic would all run twice). For a session
                // catalog we only want the canonical filesystem entry.
                let resourceValues = try? url.resourceValues(forKeys: Set([URLResourceKey.isSymbolicLinkKey]))
                if resourceValues?.isSymbolicLink == true { continue }

                if seenPaths.insert(url.path).inserted {
                    collectedURLs.append(url)
                }
            }
        }

        var sessions: [PiSessionSummary] = []
        for url in collectedURLs {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            let load = readSessionFile(
                filePath: url.path,
                projectID: url.deletingLastPathComponent().lastPathComponent,
                modifiedAt: values?.contentModificationDate ?? Date.distantPast
            )
            if let warning = load.warning {
                warnings.append(warning)
            }
            if let summary = load.summary {
                sessions.append(summary)
            }
        }
        sessions.sort { $0.modifiedAt > $1.modifiedAt }

        return snapshot(from: sessions, warnings: warnings)
    }

    private func loadRemoteCatalog(host: PiHostConfiguration, activeProjectDirectory: String?) async throws -> PiCatalogSnapshot {
        try await RemoteDaemonClient().loadCatalog(
            host: host,
            activeProjectDirectory: activeProjectDirectory
        )
    }

    private func snapshot(from sessions: [PiSessionSummary], warnings: [String] = []) -> PiCatalogSnapshot {
        let grouped = Dictionary(grouping: sessions, by: \.projectID)
        let projects = grouped.map { projectID, sessions in
            PiProject(
                id: projectID,
                title: projectTitle(for: projectID, sessions: sessions),
                workingDirectory: sessions.first?.workingDirectory,
                sessionDirectory: projectID,
                sessionCount: sessions.count,
                lastActivity: sessions.map(\.modifiedAt).max()
            )
        }
        .sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }

        return PiCatalogSnapshot(projects: projects, sessions: sessions, warnings: warnings)
    }

    /// Result of trying to read a single Pi session `.jsonl` file.
    /// `summary` is `nil` when the file is unreadable or the JSON
    /// metadata needed to build a `PiSessionSummary` is missing. In
    /// those cases `warning` describes the problem so the catalog can
    /// surface it to the user instead of dropping the file silently.
    private struct SessionFileLoad {
        var summary: PiSessionSummary?
        var warning: String?
    }

    private func readSessionFile(
        filePath: String,
        projectID: String,
        modifiedAt: Date,
        previewLimit: Int = 240,
        maxLineLimit: Int = 200_000
    ) -> SessionFileLoad {
        let url = URL(fileURLWithPath: filePath)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return SessionFileLoad(
                summary: nil,
                warning: "Could not open session file \(filePath): \(error.localizedDescription)"
            )
        }
        defer { try? handle.close() }

        // Read the file in a single pass so the preview and the full
        // message count share the same buffer. We do not need to keep
        // the entire file in memory: we keep at most `previewLimit`
        // non-empty lines for parsing, and an integer counter for the
        // message total. `maxLineLimit` caps the work even if a session
        // file is accidentally huge.
        var previewLines: [String] = []
        var messageCount = 0
        var totalLines = 0
        var buffer = Data()
        let newline = Character("\n").asciiValue!
        var readError: String?
        var encounteredInvalidUTF8 = false

        outer: while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 64 * 1024), !next.isEmpty else { break }
                chunk = next
            } catch {
                readError = error.localizedDescription
                break
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                guard !lineData.isEmpty else { continue }

                totalLines += 1

                if totalLines <= maxLineLimit,
                   let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   object["type"] as? String == "message" {
                    messageCount += 1
                }

                if previewLines.count < previewLimit {
                    if let line = String(data: lineData, encoding: .utf8) {
                        previewLines.append(line)
                    } else {
                        encounteredInvalidUTF8 = true
                    }
                }

                if totalLines >= maxLineLimit && previewLines.count >= previewLimit {
                    break outer
                }
            }
        }

        if !buffer.isEmpty {
            totalLines += 1
            if totalLines <= maxLineLimit,
               let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
               object["type"] as? String == "message" {
                messageCount += 1
            }
            if previewLines.count < previewLimit {
                if let line = String(data: buffer, encoding: .utf8) {
                    previewLines.append(line)
                } else {
                    encounteredInvalidUTF8 = true
                }
            }
        }

        let truncated = totalLines >= maxLineLimit
        let summary = parseSessionRecord(
            filePath: filePath,
            projectID: projectID,
            modifiedAt: modifiedAt,
            lines: Array(previewLines.prefix(previewLimit)),
            fullMessageCount: messageCount
        )
        var warningParts: [String] = []
        if let readError {
            warningParts.append("Read error in \(filePath): \(readError)")
        }
        if encounteredInvalidUTF8 {
            warningParts.append("Skipped non-UTF-8 line(s) in \(filePath).")
        }
        if truncated {
            warningParts.append("Truncated \(filePath) at \(maxLineLimit) lines for the message count.")
        }
        return SessionFileLoad(
            summary: summary,
            warning: warningParts.isEmpty ? nil : warningParts.joined(separator: " ")
        )
    }

    private func parseSessionRecord(filePath: String, projectID: String, modifiedAt: Date, lines: [String], fullMessageCount: Int?) -> PiSessionSummary? {
        let url = URL(fileURLWithPath: filePath)
        let parsed = parseSessionLines(lines)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let effectiveProjectID = catalogProjectID(rawProjectID: projectID, parsed: parsed)

        return PiSessionSummary(
            id: parsed.id ?? url.deletingPathExtension().lastPathComponent,
            filePath: filePath,
            projectID: effectiveProjectID,
            title: parsed.displayName ?? parsed.firstUserMessage ?? fallbackTitle,
            workingDirectory: parsed.workingDirectory,
            messageCount: fullMessageCount ?? parsed.messageCount,
            modifiedAt: modifiedAt,
            displayName: parsed.displayName,
            parentSession: parsed.parentSession,
            branchCount: parsed.branchCount,
            labelCount: parsed.labelCount,
            branchSummaryCount: parsed.branchSummaryCount,
            latestModel: parsed.latestModel
        )
    }

    private func catalogProjectID(rawProjectID: String, parsed: ParsedSession) -> String {
        guard rawProjectID == "sessions",
              let workingDirectory = parsed.workingDirectory?.nilIfBlank else {
            return rawProjectID
        }
        return encodedProjectID(for: workingDirectory)
    }

    private func encodedProjectID(for workingDirectory: String) -> String {
        let standardizedPath = (workingDirectory as NSString).standardizingPath
        let components = URL(fileURLWithPath: standardizedPath)
            .pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        guard !components.isEmpty else { return "--root--" }
        return "--\(components.joined(separator: "-"))--"
    }

    private func parseSessionLines(_ lines: [String]) -> ParsedSession {
        var id: String?
        var workingDirectory: String?
        var displayName: String?
        var firstUserMessage: String?
        var messageCount = 0
        var parentSession: String?
        var childCounts: [String: Int] = [:]
        var labelTargets = Set<String>()
        var branchSummaryCount = 0
        var latestModel: String?

        for line in lines.prefix(240) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let type = object["type"] as? String
            if type == "session" {
                workingDirectory = workingDirectory ?? stringValue(from: object, keys: ["cwd", "workingDirectory"])
                parentSession = parentSession ?? stringValue(from: object, keys: ["parentSession"])
            }

            if type == "session" {
                id = id ?? stringValue(from: object, keys: ["sessionId", "sessionID", "id"])
            }
            if type == "session_info" || displayName == nil {
                displayName = displayName ?? stringValue(from: object, keys: ["name", "displayName", "title"])
            }

            if type == "message", let parentID = object["parentId"] as? String {
                childCounts[parentID, default: 0] += 1
            }

            if type == "message" {
                messageCount += 1
                if let message = object["message"] as? [String: Any] {
                    latestModel = modelDescription(from: message) ?? latestModel
                    if firstUserMessage == nil,
                       message["role"] as? String == "user" {
                        firstUserMessage = contentPreview(from: message["content"])
                    }
                } else {
                    latestModel = modelDescription(from: object) ?? latestModel
                    if firstUserMessage == nil,
                       object["role"] as? String == "user" {
                        firstUserMessage = contentPreview(from: object["content"])
                    }
                }
            }

            if type == "label", let targetID = object["targetId"] as? String {
                labelTargets.insert(targetID)
            }
            if type == "branch_summary" {
                branchSummaryCount += 1
            }
        }

        let branchCount = childCounts.values.filter { $0 > 1 }.count

        return ParsedSession(
            id: id,
            workingDirectory: workingDirectory?.nilIfBlank,
            displayName: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            firstUserMessage: firstUserMessage?.singleLinePreview,
            messageCount: messageCount,
            parentSession: parentSession?.nilIfBlank,
            branchCount: branchCount,
            labelCount: labelTargets.count,
            branchSummaryCount: branchSummaryCount,
            latestModel: latestModel?.nilIfBlank
        )
    }

    private func stringValue(from object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
            if let nested = object[key] as? [String: Any],
               let nestedValue = stringValue(from: nested, keys: keys) {
                return nestedValue
            }
        }
        if let message = object["message"] as? [String: Any] {
            return stringValue(from: message, keys: keys)
        }
        return nil
    }

    private func contentPreview(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                if let text = block["text"] as? String {
                    return text
                }
                if block["type"] as? String == "image" {
                    return "[image]"
                }
                return nil
            }
            .joined(separator: " ")
            .nilIfBlank
        }
        return nil
    }

    private func modelDescription(from object: [String: Any]) -> String? {
        let model = (object["model"] as? String) ?? (object["modelId"] as? String)
        guard let model = model?.nilIfBlank else { return nil }
        if let provider = (object["provider"] as? String)?.nilIfBlank {
            return "\(provider)/\(model)"
        }
        return model
    }

    private func projectTitle(for projectID: String, sessions: [PiSessionSummary]) -> String {
        if let workingDirectory = sessions.first?.workingDirectory {
            return URL(fileURLWithPath: workingDirectory).lastPathComponent
        }
        return fallbackProjectTitle(projectID)
    }

    private func fallbackProjectTitle(_ projectID: String) -> String {
        return normalizedProjectID(projectID)
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedProjectID(_ projectID: String) -> String {
        guard projectID.hasPrefix("--"), projectID.hasSuffix("--") else { return projectID }
        return String(projectID.dropFirst(2).dropLast(2))
    }
}

private struct ParsedSession {
    let id: String?
    let workingDirectory: String?
    let displayName: String?
    let firstUserMessage: String?
    let messageCount: Int
    let parentSession: String?
    let branchCount: Int
    let labelCount: Int
    let branchSummaryCount: Int
    let latestModel: String?
}

private extension String {
    var singleLinePreview: String {
        let collapsed = replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(77)) + "..."
    }
}
