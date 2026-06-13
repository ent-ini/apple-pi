import Foundation

final class PiConfigurationService {
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        fileManager: FileManager = Foundation.FileManager(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func loadSummary(host: PiHostConfiguration, projectDirectory: String?) -> PiConfigurationSummary {
        let agentDirectory = host.agentDirectory.expandingTilde
        let globalSettingsPath = "\(agentDirectory)/settings.json"
        let globalSettings = readSettings(at: globalSettingsPath)
        let projectDirectory = projectDirectory?.expandingTilde.nilIfBlank
        let projectPiDirectory = projectDirectory.map { "\($0)/.pi" }
        let projectSettingsPath = projectPiDirectory.map { "\($0)/settings.json" }
        let trustStatus = trustStatus(for: projectDirectory, agentDirectory: agentDirectory)
        let projectSettings = trustStatus == .trusted ? readSettings(at: projectSettingsPath) : nil
        let settingsPaths = [globalSettings?.path, projectSettings?.path].compactMap(\.self)
        let contextPaths = contextFilePaths(agentDirectory: agentDirectory, projectDirectory: projectDirectory)
        let resourceRootPaths = resourceRootPaths(agentDirectory: agentDirectory, projectDirectory: projectDirectory)
        let rootResolution = resolveSessionRoots(
            host: host,
            projectDirectory: projectDirectory,
            globalSettings: globalSettings,
            projectSettings: projectSettings
        )

        return PiConfigurationSummary(
            projectDirectory: projectDirectory,
            trustStatus: trustStatus,
            globalSettingsPath: globalSettingsPath,
            projectSettingsPath: projectSettingsPath,
            piDirectoryPath: projectPiDirectory,
            agentDirectoryPath: agentDirectory,
            sessionRoot: rootResolution.displayRoot,
            settingsCount: settingsPaths.count,
            contextFileCount: contextPaths.count,
            resourceCount: resourceCount(
                agentDirectory: agentDirectory,
                projectDirectory: projectDirectory,
                globalSettings: globalSettings,
                projectSettings: projectSettings
            ),
            settingsPaths: settingsPaths,
            contextFilePaths: contextPaths,
            resourceRootPaths: resourceRootPaths
        )
    }

    func resolveSessionRoots(host: PiHostConfiguration, projectDirectory: String?) -> PiSessionRootResolution {
        let globalSettings = readSettings(at: "\(host.agentDirectory.expandingTilde)/settings.json")
        let trustStatus = trustStatus(for: projectDirectory?.expandingTilde.nilIfBlank, agentDirectory: host.agentDirectory.expandingTilde)
        let projectSettingsPath = projectDirectory?.expandingTilde.nilIfBlank.map { "\($0)/.pi/settings.json" }
        let projectSettings = trustStatus == .trusted ? readSettings(at: projectSettingsPath) : nil
        return resolveSessionRoots(
            host: host,
            projectDirectory: projectDirectory?.expandingTilde.nilIfBlank,
            globalSettings: globalSettings,
            projectSettings: projectSettings
        )
    }

    func readSettings(at path: String?) -> PiSettingsDocument? {
        guard let path, fileManager.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return PiSettingsDocument(path: path, values: object)
    }

    private func resolveSessionRoots(
        host: PiHostConfiguration,
        projectDirectory: String?,
        globalSettings: PiSettingsDocument?,
        projectSettings: PiSettingsDocument?
    ) -> PiSessionRootResolution {
        let defaultRoot = "\(host.agentDirectory.expandingTilde)/sessions"
        let envRoot = environment["PI_CODING_AGENT_SESSION_DIR"]?.nilIfBlank?.expandingTilde
        let globalRoot = globalSettings?.sessionDir.map { resolve(path: $0, relativeTo: host.agentDirectory.expandingTilde) }
        let projectRoot = projectSettings?.sessionDir.flatMap { sessionDir in
            projectDirectory.map { resolve(path: sessionDir, relativeTo: "\($0)/.pi") }
        }

        if let envRoot {
            return PiSessionRootResolution(roots: [envRoot], displayRoot: envRoot)
        }

        var roots: [String] = []
        if let projectRoot {
            roots.append(projectRoot)
        }
        if let globalRoot {
            roots.append(globalRoot)
        }
        roots.append(defaultRoot)
        roots = uniqueExistingOrCandidate(roots)

        return PiSessionRootResolution(roots: roots, displayRoot: projectRoot ?? globalRoot ?? defaultRoot)
    }

    private func trustStatus(for projectDirectory: String?, agentDirectory: String) -> PiTrustStatus {
        guard let projectDirectory else { return .unknown }
        let trustPath = "\(agentDirectory)/trust.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: trustPath)),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return .unknown
        }
        return containsTrustEntry(json, projectDirectory: projectDirectory.standardizedPath) ? .trusted : .untrusted
    }

    private func containsTrustEntry(_ value: Any, projectDirectory: String) -> Bool {
        if let string = value as? String {
            return string.standardizedPath == projectDirectory
        }
        if let array = value as? [Any] {
            return array.contains { containsTrustEntry($0, projectDirectory: projectDirectory) }
        }
        if let dictionary = value as? [String: Any] {
            for (key, value) in dictionary {
                if key.standardizedPath == projectDirectory {
                    if let bool = value as? Bool { return bool }
                    if let string = value as? String { return string.lowercased() == "trusted" }
                    return true
                }
                if containsTrustEntry(value, projectDirectory: projectDirectory) {
                    return true
                }
            }
        }
        return false
    }

    private func contextFilePaths(agentDirectory: String, projectDirectory: String?) -> [String] {
        let names = ["AGENTS.md", "CLAUDE.md", "SYSTEM.md", "APPEND_SYSTEM.md"]
        let globalPaths = names
            .map { "\(agentDirectory)/\($0)" }
            .filter { fileManager.fileExists(atPath: $0) }
        let projectPaths = projectDirectory.map { directory in
            names.flatMap { name in
                ["\(directory)/\(name)", "\(directory)/.pi/\(name)"]
            }
            .filter { fileManager.fileExists(atPath: $0) }
        } ?? []
        return uniqueExistingOrCandidate(globalPaths + projectPaths)
    }

    private func resourceRootPaths(agentDirectory: String, projectDirectory: String?) -> [String] {
        let resourceFolders = ["packages", "extensions", "skills", "prompts", "themes"]
        let globalPaths = resourceFolders.map { "\(agentDirectory)/\($0)" }.filter { fileManager.fileExists(atPath: $0) }
        let projectPaths = projectDirectory.map { directory in
            resourceFolders.map { "\(directory)/.pi/\($0)" }.filter { fileManager.fileExists(atPath: $0) }
        } ?? []
        return uniqueExistingOrCandidate(globalPaths + projectPaths)
    }

    private func resourceCount(
        agentDirectory: String,
        projectDirectory: String?,
        globalSettings: PiSettingsDocument?,
        projectSettings: PiSettingsDocument?
    ) -> Int {
        let resourceFolders = ["packages", "extensions", "skills", "prompts", "themes"]
        let globalFolderCount = resourceFolders.reduce(0) { count, folder in
            count + directoryEntryCount("\(agentDirectory)/\(folder)")
        }
        let projectFolderCount = projectDirectory.map { directory in
            resourceFolders.reduce(0) { count, folder in
                count + directoryEntryCount("\(directory)/.pi/\(folder)")
            }
        } ?? 0
        return globalFolderCount + projectFolderCount + (globalSettings?.resourceReferenceCount ?? 0) + (projectSettings?.resourceReferenceCount ?? 0)
    }

    private func directoryEntryCount(_ path: String) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return 0 }
        return entries.filter { !$0.hasPrefix(".") }.count
    }

    private func resolve(path: String, relativeTo base: String) -> String {
        let expanded = path.expandingTilde
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: base).appendingPathComponent(expanded).path
    }

    private func uniqueExistingOrCandidate(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedPath).inserted }
    }
}

struct PiSettingsDocument: Equatable {
    let path: String
    let values: [String: Any]

    static func == (lhs: PiSettingsDocument, rhs: PiSettingsDocument) -> Bool {
        lhs.path == rhs.path
    }

    var sessionDir: String? {
        stringValue(for: "sessionDir")
    }

    var resourceReferenceCount: Int {
        ["packages", "extensions", "skills", "prompts", "promptTemplates", "themes"].reduce(0) { count, key in
            count + countReferences(values[key])
        }
    }

    private func stringValue(for key: String) -> String? {
        values[key] as? String
    }

    private func countReferences(_ value: Any?) -> Int {
        if value == nil { return 0 }
        if value is String { return 1 }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + countReferences($1) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.reduce(0) { $0 + countReferences($1) }
        }
        return 0
    }
}

private extension String {
    var standardizedPath: String {
        (self as NSString).standardizingPath
    }
}
