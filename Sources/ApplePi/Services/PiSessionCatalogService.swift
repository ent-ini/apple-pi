import Foundation

struct PiCatalogSnapshot: Sendable {
    var projects: [PiProject]
    var sessions: [PiSessionSummary]
}

final class PiSessionCatalogService {
    private let configurationService: PiConfigurationService

    init(configurationService: PiConfigurationService = PiConfigurationService()) {
        self.configurationService = configurationService
    }

    func loadCatalog(host: PiHostConfiguration, activeProjectDirectory: String? = nil) async throws -> PiCatalogSnapshot {
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
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = roots.flatMap { root -> [URL] in
            let rootURL = URL(fileURLWithPath: root)
            guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
            return fileManager.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys))?
                .compactMap { $0 as? URL } ?? []
        }

        let sessions = Dictionary(grouping: urls, by: { (url: URL) in url.path }).values.compactMap { duplicates -> PiSessionSummary? in
            guard let url = duplicates.first else { return nil }
            guard url.pathExtension == "jsonl" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { return nil }
            return parseSessionFile(
                filePath: url.path,
                projectID: url.deletingLastPathComponent().lastPathComponent,
                modifiedAt: values?.contentModificationDate ?? Date.distantPast
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }

        return snapshot(from: sessions)
    }

    private func loadRemoteCatalog(host: PiHostConfiguration, activeProjectDirectory: String?) async throws -> PiCatalogSnapshot {
        guard !host.remoteAddress.isEmpty else {
            return PiCatalogSnapshot(projects: [], sessions: [])
        }

        var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        if host.remotePort > 0, host.remotePort != 22 {
            arguments.append(contentsOf: ["-p", String(host.remotePort)])
        }
        arguments.append(host.remoteAddress)
        arguments.append(remoteCatalogScript(agentDirectory: host.agentDirectory, projectDirectory: activeProjectDirectory))

        let result = try ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: RemoteSSHSupport.processEnvironment(),
            timeout: 20
        )
        if result.timedOut {
            throw CatalogError.remoteScanFailed("Remote session scan timed out.")
        }
        guard result.terminationStatus == 0 else {
            let message = String(data: result.standardError, encoding: .utf8) ?? "Remote session scan failed."
            throw CatalogError.remoteScanFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let remoteRecords = try JSONDecoder().decode([RemoteSessionRecord].self, from: result.standardOutput)
        let sessions = remoteRecords.compactMap { record in
            parseSessionRecord(
                filePath: record.filePath,
                projectID: record.projectID,
                modifiedAt: Date(timeIntervalSince1970: record.modifiedAt),
                lines: record.lines
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }

        return snapshot(from: sessions)
    }

    private func snapshot(from sessions: [PiSessionSummary]) -> PiCatalogSnapshot {
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

        return PiCatalogSnapshot(projects: projects, sessions: sessions)
    }

    private func parseSessionFile(filePath: String, projectID: String, modifiedAt: Date) -> PiSessionSummary? {
        let url = URL(fileURLWithPath: filePath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let lines = readSessionPreviewLines(from: handle) else { return nil }

        return parseSessionRecord(
            filePath: filePath,
            projectID: projectID,
            modifiedAt: modifiedAt,
            lines: Array(lines.prefix(240))
        )
    }

    private func readSessionPreviewLines(from handle: FileHandle, limit: Int = 240) -> [String]? {
        var lines: [String] = []
        var buffer = Data()
        let newline = Character("\n").asciiValue!

        while lines.count < limit {
            guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { break }
            buffer.append(data)

            while lines.count < limit, let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[..<newlineIndex]
                if !lineData.isEmpty {
                    guard let line = String(data: lineData, encoding: .utf8) else { return nil }
                    lines.append(line)
                }
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
            }
        }

        if lines.count < limit, !buffer.isEmpty {
            guard let line = String(data: buffer, encoding: .utf8) else { return nil }
            lines.append(line)
        }

        return lines
    }

    private func parseSessionRecord(filePath: String, projectID: String, modifiedAt: Date, lines: [String]) -> PiSessionSummary? {
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
            messageCount: parsed.messageCount,
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

            if type == "message", let message = object["message"] as? [String: Any] {
                messageCount += 1
                latestModel = modelDescription(from: message) ?? latestModel
                if firstUserMessage == nil,
                   message["role"] as? String == "user" {
                    firstUserMessage = contentPreview(from: message["content"])
                }
            } else if object["message"] != nil || object["content"] != nil || object["role"] != nil {
                messageCount += 1
                latestModel = modelDescription(from: object) ?? latestModel
                if firstUserMessage == nil,
                   object["role"] as? String == "user" {
                    firstUserMessage = contentPreview(from: object["content"])
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

    private func remoteCatalogScript(agentDirectory: String, projectDirectory: String?) -> String {
        let projectArgument = projectDirectory?.nilIfBlank ?? ""
        return """
        python3 -c \(remotePythonSource.shellQuoted) \(agentDirectory.shellQuoted) \(projectArgument.shellQuoted)
        """
    }

    private var remotePythonSource: String {
        """
        import json, os, sys
        agent = os.path.expanduser(sys.argv[1])
        project = os.path.expanduser(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None

        def read_json(path):
            try:
                with open(path, 'r', encoding='utf-8') as fh:
                    data = json.load(fh)
                return data if isinstance(data, dict) else None
            except Exception:
                return None

        def resolve(path, base):
            path = os.path.expanduser(path)
            return path if os.path.isabs(path) else os.path.join(base, path)

        def trusted(project_path):
            if not project_path:
                return False
            trust = read_json(os.path.join(agent, 'trust.json'))
            if trust is None:
                return False
            project_path = os.path.normpath(project_path)
            def contains(value):
                if isinstance(value, str):
                    return os.path.normpath(os.path.expanduser(value)) == project_path
                if isinstance(value, list):
                    return any(contains(item) for item in value)
                if isinstance(value, dict):
                    for key, item in value.items():
                        if os.path.normpath(os.path.expanduser(key)) == project_path:
                            if isinstance(item, bool):
                                return item
                            if isinstance(item, str):
                                return item.lower() == 'trusted'
                            return True
                        if contains(item):
                            return True
                return False
            return contains(trust)

        default_root = os.path.join(agent, 'sessions')
        env_root = os.environ.get('PI_CODING_AGENT_SESSION_DIR')
        global_settings = read_json(os.path.join(agent, 'settings.json'))
        project_settings = read_json(os.path.join(project, '.pi', 'settings.json')) if trusted(project) else None
        roots = []
        if env_root:
            roots = [os.path.expanduser(env_root)]
        else:
            if project_settings and isinstance(project_settings.get('sessionDir'), str):
                roots.append(resolve(project_settings.get('sessionDir'), os.path.join(project, '.pi')))
            if global_settings and isinstance(global_settings.get('sessionDir'), str):
                roots.append(resolve(global_settings.get('sessionDir'), agent))
            roots.append(default_root)

        seen = set()
        roots = [root for root in roots if not (os.path.normpath(root) in seen or seen.add(os.path.normpath(root)))]
        out = []
        emitted = set()
        for root in roots:
            if not os.path.exists(root):
                continue
            for dirpath, _, files in os.walk(root):
                project_id = os.path.basename(dirpath)
                for name in files:
                    if not name.endswith('.jsonl'):
                        continue
                    path = os.path.join(dirpath, name)
                    if path in emitted:
                        continue
                    emitted.add(path)
                    try:
                        stat = os.stat(path)
                        lines = []
                        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                            for _, line in zip(range(240), fh):
                                lines.append(line)
                        out.append({'filePath': path, 'projectID': project_id, 'modifiedAt': stat.st_mtime, 'lines': lines})
                    except Exception:
                        pass
        print(json.dumps(out))
        """
    }

    enum CatalogError: LocalizedError {
        case remoteScanFailed(String)

        var errorDescription: String? {
            switch self {
            case .remoteScanFailed(let message):
                return message.isEmpty ? "Remote session scan failed." : message
            }
        }
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

private struct RemoteSessionRecord: Decodable {
    let filePath: String
    let projectID: String
    let modifiedAt: TimeInterval
    let lines: [String]
}

private extension String {
    var singleLinePreview: String {
        let collapsed = replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(77)) + "..."
    }
}
