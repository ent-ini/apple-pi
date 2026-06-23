import Foundation
import Testing
@testable import ApplePi

@Test func shellQuotingProtectsSpacesAndQuotes() {
    #expect("hello".shellQuoted == "hello")
    #expect("two words".shellQuoted == "'two words'")
    #expect("it's".shellQuoted == "'it'\\''s'")
}

@Test func appearanceDecodingKeepsNotificationsEnabledByDefault() throws {
    let data = #"{"emptyTerminalMessage":"Ready"}"#.data(using: .utf8)!

    let appearance = try JSONDecoder().decode(AppAppearance.self, from: data)

    #expect(appearance.emptyChatMessage == "Ready")
    #expect(appearance.notifications.isEnabled)
    #expect(appearance.notifications.presentation == .bannerAndSound)
    #expect(appearance.notifications.allowsForegroundNotifications)
}

@Test func updateCheckReportsNewerLatestRelease() async throws {
    let service = UpdateCheckService(
        latestReleaseURL: URL(string: "https://example.test/releases/latest")!,
        currentVersionProvider: { "1.2.3" },
        fetch: { request in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "ApplePi")
            let data = """
            {"tag_name":"v1.3.0","html_url":"https://example.test/releases/v1.3.0"}
            """.data(using: .utf8)!
            return HTTPResult(statusCode: 200, data: data)
        }
    )

    let update = try await service.checkForUpdate()

    #expect(update?.latestVersion == "1.3.0")
    #expect(update?.releaseURL == URL(string: "https://example.test/releases/v1.3.0"))
}

@Test func updateCheckIgnoresCurrentOrOlderRelease() async throws {
    let service = UpdateCheckService(
        currentVersionProvider: { "1.3.0" },
        fetch: { _ in
            let data = """
            {"tag_name":"v1.3.0","html_url":"https://example.test/releases/v1.3.0"}
            """.data(using: .utf8)!
            return HTTPResult(statusCode: 200, data: data)
        }
    )

    let update = try await service.checkForUpdate()

    #expect(update == nil)
}

@Test func updateCheckIgnoresNonSuccessResponse() async throws {
    let service = UpdateCheckService(
        currentVersionProvider: { "1.0.0" },
        fetch: { _ in HTTPResult(statusCode: 503, data: Data()) }
    )

    let update = try await service.checkForUpdate()

    #expect(update == nil)
}


@Test func catalogUsesSessionHeaderCwdForProjectDirectory() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-my-project--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let sessionFile = encodedProject.appendingPathComponent("session.jsonl")
    let cwd = "/Users/ada/Code/my-project"
    try """
    {"type":"session","id":"session-1","cwd":"\(cwd)"}
    {"type":"message","role":"user","content":"hello"}
    """.write(to: sessionFile, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.sessions.first?.workingDirectory == cwd)
    #expect(snapshot.projects.first?.workingDirectory == cwd)
    #expect(snapshot.projects.first?.title == "my-project")
}

@Test func catalogPreservesHyphenatedProjectFolderNameFromSessionHeader() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-apple-pi--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let sessionFile = encodedProject.appendingPathComponent("session.jsonl")
    let cwd = "/Users/ada/Code/apple-pi"
    try """
    {"type":"session","id":"session-1","cwd":"\(cwd)"}
    {"type":"message","role":"user","content":"hello"}
    """.write(to: sessionFile, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.projects.first?.title == "apple-pi")
}

@Test func catalogGroupsRootLevelSessionsByHeaderCwd() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--home-edoardo--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)

    let rootSession = sessionsRoot.appendingPathComponent("root-session.jsonl")
    let groupedSession = encodedProject.appendingPathComponent("grouped-session.jsonl")
    let cwd = "/home/edoardo"
    try """
    {"type":"session","id":"root-session","cwd":"\(cwd)"}
    {"type":"message","role":"user","content":"root level"}
    """.write(to: rootSession, atomically: true, encoding: .utf8)
    try """
    {"type":"session","id":"grouped-session","cwd":"\(cwd)"}
    {"type":"message","role":"user","content":"grouped"}
    """.write(to: groupedSession, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.projects.count == 1)
    #expect(snapshot.projects.first?.id == "--home-edoardo--")
    #expect(snapshot.projects.first?.sessionCount == 2)
    #expect(Set(snapshot.sessions.map(\.projectID)) == ["--home-edoardo--"])
}

@Test func catalogReadsModernSessionMetadata() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-my-project--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let sessionFile = encodedProject.appendingPathComponent("session.jsonl")
    let cwd = "/Users/ada/Code/my-project"
    try """
    {"type":"session","version":3,"id":"session-1","cwd":"\(cwd)","parentSession":"/tmp/parent.jsonl"}
    {"type":"message","id":"a","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"Build a tiny dashboard"}]}}
    {"type":"message","id":"b","parentId":"a","message":{"role":"assistant","provider":"openai","model":"gpt-5","content":[{"type":"text","text":"Sure"}]}}
    {"type":"message","id":"c","parentId":"a","message":{"role":"user","content":"Try another path"}}
    {"type":"label","id":"l","parentId":"c","targetId":"a","label":"checkpoint"}
    {"type":"branch_summary","id":"s","parentId":"a","fromId":"b","summary":"Explored first path"}
    {"type":"session_info","id":"n","parentId":"c","name":"Dashboard pass"}
    """.write(to: sessionFile, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)
    let session = try #require(snapshot.sessions.first)

    #expect(session.title == "Dashboard pass")
    #expect(session.parentSession == "/tmp/parent.jsonl")
    #expect(session.branchCount == 1)
    #expect(session.labelCount == 1)
    #expect(session.branchSummaryCount == 1)
    #expect(session.latestModel == "openai/gpt-5")
}

@MainActor
@Test func deleteSessionRemovesFileAndRefreshesList() async throws {
    let temp = try TemporaryPiFixture()
    let sessionFile = temp.root.appendingPathComponent("session.jsonl")
    try "{}".write(to: sessionFile, atomically: true, encoding: .utf8)
    let session = PiSessionSummary(
        id: "session-1",
        filePath: sessionFile.path,
        projectID: "project",
        title: "Delete me",
        workingDirectory: temp.project.path,
        messageCount: 1,
        modifiedAt: Date(),
        displayName: nil,
        parentSession: nil,
        branchCount: 0,
        labelCount: 0,
        branchSummaryCount: 0,
        latestModel: nil
    )
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    state.delete(session)

    #expect(!Foundation.FileManager().fileExists(atPath: sessionFile.path))
}

@MainActor
@Test func appStateStartupLoadsPersistedHostWithoutDuplicateCatalogRefresh() async throws {
    let defaults = isolatedDefaults()
    let host = PiHostConfiguration(agentDirectory: "/tmp/custom-agent")
    let hostData = try JSONEncoder().encode(host)
    defaults.set(hostData, forKey: "ApplePi.host")
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let probe = CatalogLoaderProbe()

    _ = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { host, _ in
            await probe.load(host: host)
        }
    )
    try await Task.sleep(for: .milliseconds(100))

    #expect(await probe.callCount == 1)
    #expect(await probe.loadedHosts == [host])
}

@MainActor
@Test func appStateHostModeChangeRefreshesWithoutStaleProjectContext() async throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let probe = CatalogLoaderProbe()
    let localSnapshot = PiCatalogSnapshot(
        projects: [
            PiProject(
                id: "local-project",
                title: "Local Project",
                workingDirectory: "/Users/example/project",
                sessionDirectory: "local-project",
                sessionCount: 0,
                lastActivity: nil
            )
        ],
        sessions: []
    )
    let emptySnapshot = PiCatalogSnapshot(projects: [], sessions: [])
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { host, activeProjectDirectory in
            await probe.load(
                host: host,
                activeProjectDirectory: activeProjectDirectory,
                snapshot: host.mode == .local ? localSnapshot : emptySnapshot
            )
        }
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.activeProject?.workingDirectory == "/Users/example/project")

    state.host.mode = .remoteSSH
    try await Task.sleep(for: .milliseconds(100))

    #expect(await probe.loadedProjectDirectories == [nil, nil])
    #expect(state.projects.isEmpty)
    #expect(state.selection == nil)
}

@MainActor
@Test func sessionSearchCanMatchAcrossProjects() async throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let now = Date()
    let snapshot = PiCatalogSnapshot(
        projects: [
            PiProject(id: "a", title: "Alpha", workingDirectory: "/tmp/a", sessionDirectory: "a", sessionCount: 1, lastActivity: now),
            PiProject(id: "b", title: "Beta", workingDirectory: "/tmp/b", sessionDirectory: "b", sessionCount: 1, lastActivity: now)
        ],
        sessions: [
            PiSessionSummary(id: "1", filePath: "/tmp/a/one.jsonl", projectID: "a", title: "Design Notes", workingDirectory: "/tmp/a", messageCount: 1, modifiedAt: now, displayName: nil, parentSession: nil, branchCount: 0, labelCount: 0, branchSummaryCount: 0, latestModel: nil),
            PiSessionSummary(id: "2", filePath: "/tmp/b/two.jsonl", projectID: "b", title: "Design Review", workingDirectory: "/tmp/b", messageCount: 1, modifiedAt: now.addingTimeInterval(-60), displayName: nil, parentSession: nil, branchCount: 0, labelCount: 0, branchSummaryCount: 0, latestModel: nil)
        ]
    )
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in snapshot }
    )
    try await Task.sleep(for: .milliseconds(100))

    state.sessionSearchText = "design"

    let matched = state.filteredSessions(for: state.activeProject)

    #expect(matched.map(\.id) == ["1", "2"])
}

@Test func sessionRootDefaultsToAgentSessions() throws {
    let temp = try TemporaryPiFixture()
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: nil)

    #expect(resolution.displayRoot == temp.agent.appendingPathComponent("sessions").path)
    #expect(resolution.roots == [temp.agent.appendingPathComponent("sessions").path])
}

@Test func globalSessionDirOverridesDefault() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: nil)

    #expect(resolution.displayRoot == temp.agent.appendingPathComponent("global-sessions").path)
    #expect(resolution.roots.first == temp.agent.appendingPathComponent("global-sessions").path)
    #expect(resolution.roots.contains(temp.agent.appendingPathComponent("sessions").path))
}

@Test func trustedProjectSessionDirOverridesGlobalDisplayRoot() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    try temp.writeJSON([temp.project.path: true], to: temp.agent.appendingPathComponent("trust.json"))
    try Foundation.FileManager().createDirectory(at: temp.project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    try temp.writeJSON(["sessionDir": "project-sessions"], to: temp.project.appendingPathComponent(".pi/settings.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: temp.project.path)

    #expect(resolution.displayRoot == temp.project.appendingPathComponent(".pi/project-sessions").path)
    #expect(resolution.roots.first == temp.project.appendingPathComponent(".pi/project-sessions").path)
}

@Test func untrustedProjectSessionDirIsIgnored() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    try temp.writeJSON([temp.project.path: false], to: temp.agent.appendingPathComponent("trust.json"))
    try Foundation.FileManager().createDirectory(at: temp.project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    try temp.writeJSON(["sessionDir": "project-sessions"], to: temp.project.appendingPathComponent(".pi/settings.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: temp.project.path)

    #expect(resolution.displayRoot == temp.agent.appendingPathComponent("global-sessions").path)
    #expect(!resolution.roots.contains(temp.project.appendingPathComponent(".pi/project-sessions").path))
}

@Test func unrelatedBooleanTrustValuesDoNotTrustProject() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    try Foundation.FileManager().createDirectory(at: temp.project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    try temp.writeJSON(["sessionDir": "project-sessions"], to: temp.project.appendingPathComponent(".pi/settings.json"))
    try temp.writeJSON(["metadata": ["enabled": true]], to: temp.agent.appendingPathComponent("trust.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: temp.project.path)

    #expect(resolution.displayRoot == temp.agent.appendingPathComponent("global-sessions").path)
    #expect(!resolution.roots.contains(temp.project.appendingPathComponent(".pi/project-sessions").path))
}

@Test func environmentSessionDirOverridesSettings() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    let override = temp.root.appendingPathComponent("env-sessions").path
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: ["PI_CODING_AGENT_SESSION_DIR": override])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: nil)

    #expect(resolution.displayRoot == override)
    #expect(resolution.roots == [override])
}

@Test func invalidSettingsAreIgnored() throws {
    let temp = try TemporaryPiFixture()
    try "not json".write(to: temp.agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let service = PiConfigurationService(environment: [:])

    let settings = service.readSettings(at: temp.agent.appendingPathComponent("settings.json").path)

    #expect(settings == nil)
}

@Test func configurationSummaryCountsContextAndResources() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON([temp.project.path: true], to: temp.agent.appendingPathComponent("trust.json"))
    try Foundation.FileManager().createDirectory(at: temp.project.appendingPathComponent(".pi/extensions"), withIntermediateDirectories: true)
    try Foundation.FileManager().createDirectory(at: temp.agent.appendingPathComponent("skills"), withIntermediateDirectories: true)
    try "".write(to: temp.project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "".write(to: temp.agent.appendingPathComponent("SYSTEM.md"), atomically: true, encoding: .utf8)
    try "".write(to: temp.project.appendingPathComponent(".pi/extensions/local.ts"), atomically: true, encoding: .utf8)
    try "".write(to: temp.agent.appendingPathComponent("skills/review.md"), atomically: true, encoding: .utf8)
    try temp.writeJSON(["prompts": ["review.md"]], to: temp.agent.appendingPathComponent("settings.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let summary = service.loadSummary(host: host, projectDirectory: temp.project.path)

    #expect(summary.trustStatus == .trusted)
    #expect(summary.settingsCount == 1)
    #expect(summary.contextFileCount == 2)
    #expect(summary.resourceCount == 3)
    #expect(summary.settingsPaths == [temp.agent.appendingPathComponent("settings.json").path])
    #expect(summary.contextFilePaths.contains(temp.project.appendingPathComponent("AGENTS.md").path))
    #expect(summary.resourceRootPaths.contains(temp.agent.appendingPathComponent("skills").path))
}

@MainActor
@Test func remoteDeleteDoesNotRemoveLocalPathCollision() throws {
    let temp = try TemporaryPiFixture()
    let sessionFile = temp.root.appendingPathComponent("session.jsonl")
    try "{}".write(to: sessionFile, atomically: true, encoding: .utf8)
    let session = PiSessionSummary(
        id: "session-1",
        filePath: sessionFile.path,
        projectID: "project",
        title: "Remote",
        workingDirectory: temp.project.path,
        messageCount: 1,
        modifiedAt: Date(),
        displayName: nil,
        parentSession: nil,
        branchCount: 0,
        labelCount: 0,
        branchSummaryCount: 0,
        latestModel: nil
    )
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )
    state.host.mode = .remoteSSH

    state.delete(session)

    #expect(Foundation.FileManager().fileExists(atPath: sessionFile.path))
    #expect(state.statusMessage == "Remote session deletion is not supported from pi-app.")
}

@MainActor
@Test func remoteConfigurationSummaryDoesNotExposeLocalConfiguration() {
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in PiCatalogSnapshot(projects: [], sessions: []) },
        startsBackgroundWork: false
    )
    state.host = PiHostConfiguration(
        mode: .remoteSSH,
        agentDirectory: "~/.pi/agent",
        remoteHost: "pi.example.com",
        remotePort: 22,
        remoteUser: "ada",
        remotePiExecutable: "pi"
    )

    #expect(state.configurationSummary.isRemote)
    #expect(state.configurationSummary.trustDisplayTitle == "Remote SSH")
    #expect(state.configurationSummary.globalSettingsPath.isEmpty)
    #expect(state.configurationSummary.settingsCount == 0)
    #expect(state.configurationSummary.contextFileCount == 0)
    #expect(state.configurationSummary.resourceCount == 0)
}

private final class TemporaryPiFixture {
    let root: URL
    let agent: URL
    let project: URL

    init() throws {
        root = Foundation.FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString)
        agent = root.appendingPathComponent("agent")
        project = root.appendingPathComponent("project")
        try Foundation.FileManager().createDirectory(at: agent, withIntermediateDirectories: true)
        try Foundation.FileManager().createDirectory(at: project, withIntermediateDirectories: true)
    }

    deinit {
        try? Foundation.FileManager().removeItem(at: root)
    }

    func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }
}

private actor CatalogLoaderProbe {
    private(set) var callCount = 0
    private(set) var loadedHosts: [PiHostConfiguration] = []
    private(set) var loadedProjectDirectories: [String?] = []

    func load(
        host: PiHostConfiguration,
        activeProjectDirectory: String? = nil,
        snapshot: PiCatalogSnapshot = PiCatalogSnapshot(projects: [], sessions: [])
    ) -> PiCatalogSnapshot {
        callCount += 1
        loadedHosts.append(host)
        loadedProjectDirectories.append(activeProjectDirectory)
        return snapshot
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "ApplePiTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test func sshConfigParserExtractsBasicHostBlock() throws {
    let home = makeTemporaryHomeDirectory()
    try writeSSHConfig(
        in: home,
        contents: """
        Host pi
            HostName 10.0.0.5
            User artemiy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """
    )

    let entries = SSHConfigParser.parseUserConfig(homeDirectory: home)
    let entry = try #require(entries.first)

    #expect(entry.hostPatterns == ["pi"])
    #expect(entry.hostName == "10.0.0.5")
    #expect(entry.user == "artemiy")
    #expect(entry.port == 2222)
    #expect(entry.identityFile?.hasSuffix("/.ssh/id_ed25519") == true)
}

@Test func sshConfigParserSkipsWildcardDefaultAndCollapsesMultiplePatterns() throws {
    let home = makeTemporaryHomeDirectory()
    try writeSSHConfig(
        in: home,
        contents: """
        Host *
            User root

        Host prod prod.example.com
            HostName 10.0.0.7
            User admin
        """
    )

    let entries = SSHConfigParser.parseUserConfig(homeDirectory: home)
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    #expect(entry.hostPatterns == ["prod", "prod.example.com"])
    #expect(entry.hostName == "10.0.0.7")
    #expect(entry.user == "admin")
}

@Test func sshConfigParserRespectsQuotedValues() throws {
    let home = makeTemporaryHomeDirectory()
    try writeSSHConfig(
        in: home,
        contents: """
        Host "weird name"
            HostName "10.0.0.9"
            IdentityFile "/Users/test/keys/with space"
        """
    )

    let entry = try #require(SSHConfigParser.parseUserConfig(homeDirectory: home).first)
    #expect(entry.hostPatterns == ["weird name"])
    #expect(entry.hostName == "10.0.0.9")
    #expect(entry.identityFile == "/Users/test/keys/with space")
}

@Test func sshConfigParserParsesIdentitiesOnlyBoolean() throws {
    let home = makeTemporaryHomeDirectory()
    try writeSSHConfig(
        in: home,
        contents: """
        Host pi
            HostName 10.0.0.5
            IdentitiesOnly yes
        """
    )

    let entry = try #require(SSHConfigParser.parseUserConfig(homeDirectory: home).first)
    #expect(entry.identitiesOnly == true)
}

@Test func sshKeyStoreSurfacesDefaultKeysAndFiltersArtifacts() throws {
    let home = makeTemporaryHomeDirectory()
    let ssh = "\(home)/.ssh"
    try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true)

    let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n"
    let files: [(name: String, contents: String?)] = [
        ("id_ed25519", privateKey),
        ("id_ed25519.pub", "ssh-ed25519 AAAA fake@host\n"),
        ("id_rsa", privateKey),
        ("config", "Host *\n"),
        ("known_hosts", "example.com ssh-ed25519 AAAA\n"),
        ("custom_key", privateKey),
        ("custom_key.pub", "ssh-ed25519 AAAA fake\n")
    ]
    for file in files {
        try file.contents?.write(toFile: "\(ssh)/\(file.name)", atomically: true, encoding: .utf8)
    }

    let keys = SSHKeyStore.discoverKeys(homeDirectory: home)
    let names = keys.map(\.label)

    #expect(names == ["id_ed25519", "id_rsa", "custom_key"])
    #expect(keys.first?.isDefault == true)
    #expect(keys.first(where: { $0.label == "id_ed25519" })?.publicKeyPath?.hasSuffix(".pub") == true)
}

@Suite(.serialized) struct CredentialStoreTests {
    @Test func remoteCredentialStoreRoundTripsPasswordPerHost() throws {
        let override = isolatedApplicationSupportOverride()
        defer { override.restore() }
        let host = makeHost(host: "example.com", user: "artemiy", port: 22)

        #expect(RemoteCredentialStore.hasPassword(for: host) == false)
        try RemoteCredentialStore.savePassword("hunter2", for: host)
        #expect(RemoteCredentialStore.hasPassword(for: host))

        let path = try RemoteCredentialStore.credentialPath(for: host)
        #expect(RemoteCredentialStore.readPassword(at: path) == "hunter2")

        // File mode is 0600 so other users on the box cannot read the secret.
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(permissions == 0o600)

        try RemoteCredentialStore.deletePassword(for: host)
        #expect(RemoteCredentialStore.hasPassword(for: host) == false)
    }

    @Test func remoteCredentialStoreIsolatesHostsByConnection() throws {
        let override = isolatedApplicationSupportOverride()
        defer { override.restore() }
        let a = makeHost(host: "a.example.com", user: "artemiy", port: 22)
        let b = makeHost(host: "b.example.com", user: "artemiy", port: 22)

        try RemoteCredentialStore.savePassword("password-a", for: a)
        try RemoteCredentialStore.savePassword("password-b", for: b)

        #expect(RemoteCredentialStore.readPassword(at: try RemoteCredentialStore.credentialPath(for: a)) == "password-a")
        #expect(RemoteCredentialStore.readPassword(at: try RemoteCredentialStore.credentialPath(for: b)) == "password-b")

        try RemoteCredentialStore.deletePassword(for: a)
        try RemoteCredentialStore.deletePassword(for: b)
    }
}

@Test func remoteAuthMethodFlagsAreStable() {
    #expect(RemoteAuthMethod.publicKey.title == "Public Key")
    #expect(RemoteAuthMethod.password.title == "Password")
    #expect(RemoteAuthMethod.password.requiresKeychainEntry)
    #expect(RemoteAuthMethod.publicKey.requiresKeychainEntry == false)
}

@Test func sessionEventParserReadsUserAndAssistantMessages() {
    let lines = [
        #"{"type":"session","id":"s1","cwd":"/tmp/proj"}"#,
        #"{"type":"message","message":{"role":"user","content":"hello"}}"#,
        #"{"type":"message","message":{"role":"assistant","content":"hi there","model":"anthropic/claude-3.5"}}"#
    ]

    let events = SessionEventParser.parse(lines: lines)

    #expect(events.count == 3)
    if case .message(let user, _) = events[1] {
        #expect(user.role == .user)
        #expect(user.content == [.text("hello")])
    } else {
        Issue.record("Expected user message at index 1")
    }
    if case .message(let assistant, _) = events[2] {
        #expect(assistant.role == .assistant)
        #expect(assistant.model == "anthropic/claude-3.5")
        #expect(assistant.content == [.text("hi there")])
    } else {
        Issue.record("Expected assistant message at index 2")
    }
}

@Test func sessionEventParserHandlesContentBlocksAndImages() {
    let lines = [
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"see "},{"type":"image","source":{"path":"/tmp/cat.png","media_type":"image/png"}}]}}"#
    ]

    let events = SessionEventParser.parse(lines: lines)

    guard events.count == 1, case .message(let message, _) = events[0] else {
        Issue.record("Expected one message event")
        return
    }
    #expect(message.content.count == 2)
    if case .text(let text) = message.content[0] {
        #expect(text == "see ")
    } else {
        Issue.record("Expected first block to be text")
    }
    if case .image(let path, let mime) = message.content[1] {
        #expect(path == "/tmp/cat.png")
        #expect(mime == "image/png")
    } else {
        Issue.record("Expected second block to be image")
    }
}

@Test func sessionEventParserSkipsBlankAndMalformedLines() {
    let lines = [
        "",
        "not json at all",
        #"{"unrelated":"value"}"#,
        #"{"type":"message","message":{"role":"user","content":"valid"}}"#,
        ""
    ]

    let events = SessionEventParser.parse(lines: lines)

    #expect(events.count == 1)
    if case .message(let message, let lineIndex) = events[0] {
        #expect(message.content == [.text("valid")])
        #expect(lineIndex == 3)
    } else {
        Issue.record("Expected a single valid message")
    }
}

@Test func sessionEventParserCapturesToolCallsAndResults() {
    let lines = [
        #"{"type":"tool_use","id":"call-1","name":"read_file","input":{"path":"/tmp/a.txt"}}"#,
        #"{"type":"tool_result","toolCallId":"call-1","content":"file contents","isError":false}"#
    ]

    let events = SessionEventParser.parse(lines: lines)

    #expect(events.count == 2)
    if case .toolCall(let call, _) = events[0] {
        #expect(call.id == "call-1")
        if case .function(_, let name, let arguments) = call {
            #expect(name == "read_file")
            #expect(arguments.contains("\"path\":\"/tmp/a.txt\""))
        } else {
            Issue.record("Expected function-style tool call")
        }
    } else {
        Issue.record("Expected tool call at index 0")
    }
    if case .toolResult(let result, _) = events[1] {
        #expect(result.callId == "call-1")
        if case .result(_, _, let output, let isError) = result {
            #expect(output == "file contents")
            #expect(isError == false)
        } else {
            Issue.record("Expected plain tool result")
        }
    } else {
        Issue.record("Expected tool result at index 1")
    }
}

@Test func sessionEventDecodeAppendsLineIndexForLiveTail() {
    let raw = #"{"type":"message","message":{"role":"user","content":"queued"}}"#

    let event = SessionEventParser.decode(line: raw, at: 42)

    guard let event, case .message(_, let lineIndex) = event else {
        Issue.record("Expected a message with line index")
        return
    }
    #expect(lineIndex == 42)
}

@Test func shortcutPreferencesUseDefaultsAndSwapConflicts() {
    var preferences = AppShortcutPreferences()

    #expect(preferences.binding(for: .newSession).displayString == "⌘N")
    #expect(preferences.binding(for: .findSessions).displayString == "⌘F")

    preferences.set(AppShortcut(key: .character("f"), modifiers: .command), for: .newSession)

    #expect(preferences.binding(for: .newSession).displayString == "⌘F")
    #expect(preferences.binding(for: .findSessions).displayString == "⌘N")

    preferences.set(AppShortcutAction.newSession.defaultShortcut, for: .newSession)

    #expect(preferences.binding(for: .newSession).displayString == "⌘N")
}

@MainActor
@Test func appStateCanRequestSessionSearchFocus() {
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    #expect(state.pendingSessionSearchFocusRequest == false)
    let previousID = state.sessionSearchFocusRequestID

    state.requestSessionSearchFocus()

    #expect(state.pendingSessionSearchFocusRequest)
    #expect(state.sessionSearchFocusRequestID == previousID + 1)

    state.consumeSessionSearchFocusRequest()

    #expect(state.pendingSessionSearchFocusRequest == false)
}

// MARK: - Test helpers

private func makeTemporaryHomeDirectory() -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplePiTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(atPath: directory.path, withIntermediateDirectories: true)
    return directory.path
}

private func writeSSHConfig(in home: String, contents: String) throws {
    let ssh = "\(home)/.ssh"
    try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true)
    try contents.write(toFile: "\(ssh)/config", atomically: true, encoding: .utf8)
}

private func makeHost(host: String, user: String, port: Int) -> PiHostConfiguration {
    PiHostConfiguration(
        mode: .remoteSSH,
        piExecutable: "pi",
        agentDirectory: "~/.pi/agent",
        remoteHost: host,
        remotePort: port,
        remoteUser: user,
        remotePiExecutable: "pi",
        remoteAuthMethod: .password,
        remoteIdentityFile: "",
        remoteSSHConfigAlias: ""
    )
}

/// Points `RemoteCredentialStore` at a temporary Application Support folder
/// so tests never touch the user's real data. The returned object restores
/// the previous override when `restore()` is called (or the test exits).
private func isolatedApplicationSupportOverride() -> OverrideHandle {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplePiTests-support-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(atPath: directory.path, withIntermediateDirectories: true)
    let previous = RemoteCredentialStore.applicationSupportOverride
    RemoteCredentialStore.applicationSupportOverride = directory.path
    return OverrideHandle(previous: previous, directory: directory)
}

private final class OverrideHandle {
    let previous: String?
    let directory: URL

    init(previous: String?, directory: URL) {
        self.previous = previous
        self.directory = directory
    }

    func restore() {
        RemoteCredentialStore.applicationSupportOverride = previous
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        RemoteCredentialStore.applicationSupportOverride = previous
        try? FileManager.default.removeItem(at: directory)
    }
}
