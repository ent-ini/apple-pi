import Foundation
import Testing
@testable import ApplePi

@Test func shellQuotingProtectsSpacesAndQuotes() {
    #expect("hello".shellQuoted == "hello")
    #expect("two words".shellQuoted == "'two words'")
    #expect("it's".shellQuoted == "'it'\\''s'")
}

@Test func osc777NotificationPayloadParsesNotifySequenceBodyWithSemicolons() throws {
    let bytes = ArraySlice("notify;Pi;Ready; for input".utf8)
    let payload = try #require(OSC777NotificationPayload(bytes: bytes))

    #expect(payload.title == "Pi")
    #expect(payload.body == "Ready; for input")
}

@Test func osc777NotificationPayloadRejectsUnknownCommand() {
    let bytes = ArraySlice("open;Pi;Ready for input".utf8)

    #expect(OSC777NotificationPayload(bytes: bytes) == nil)
}

@Test func osc777NotificationPayloadRejectsBlankNotificationText() {
    #expect(OSC777NotificationPayload(bytes: ArraySlice("notify;;Ready for input".utf8)) == nil)
    #expect(OSC777NotificationPayload(bytes: ArraySlice("notify;Pi;   ".utf8)) == nil)
}

@Test func osc777NotificationPayloadStripsControlCharacters() throws {
    let bytes = ArraySlice("notify;Pi\u{001b};Ready\u{0007}".utf8)
    let payload = try #require(OSC777NotificationPayload(bytes: bytes))

    #expect(payload.title == "Pi")
    #expect(payload.body == "Ready")
}

@Test func appearanceDecodingDefaultsOSC777NotificationsForExistingSettings() throws {
    let data = #"{"emptyTerminalMessage":"Ready"}"#.data(using: .utf8)!

    let appearance = try JSONDecoder().decode(AppAppearance.self, from: data)

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

@Test func localPiLaunchEnvironmentContainsDeveloperPath() {
    let request = PiLaunchRequest(
        workingDirectory: nil,
        sessionPath: "/tmp/session.jsonl",
        forkPath: nil,
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )
    let launch = PiCommandBuilder().terminalLaunch(for: request, host: PiHostConfiguration())
    let path = launch.environment.first { $0.hasPrefix("PATH=") } ?? ""

    #expect(path.contains("\(NSHomeDirectory())/.local/bin"))
    #expect(path.contains("/opt/homebrew/bin"))
    #expect(path.contains("/usr/bin"))
}

@Test func defaultLocalPiLaunchUsesPathLookup() {
    let request = PiLaunchRequest(
        workingDirectory: nil,
        sessionPath: nil,
        forkPath: nil,
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )

    let launch = PiCommandBuilder().terminalLaunch(for: request, host: PiHostConfiguration())

    #expect(launch.executable == "/usr/bin/env")
    #expect(launch.arguments == ["pi"])
    #expect(launch.execName == nil)
}

@Test func localPiLaunchLoadsBundledNotificationExtensionWhenEnabled() throws {
    let resourceDirectory = Foundation.FileManager().temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try Foundation.FileManager().createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
    let extensionURL = resourceDirectory.appendingPathComponent("ApplePiNotifyExtension.mjs")
    try "export default function () {}\n".write(to: extensionURL, atomically: true, encoding: .utf8)
    defer { try? Foundation.FileManager().removeItem(at: resourceDirectory) }

    let request = PiLaunchRequest(
        workingDirectory: nil,
        sessionPath: nil,
        forkPath: nil,
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )
    let launch = PiCommandBuilder(notificationExtensionResourceURL: resourceDirectory)
        .terminalLaunch(for: request, host: PiHostConfiguration(), notificationsEnabled: true)

    #expect(launch.arguments == ["pi", "--extension", extensionURL.path])
}

@Test func localPiLaunchSkipsBundledNotificationExtensionWhenDisabled() throws {
    let resourceDirectory = Foundation.FileManager().temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try Foundation.FileManager().createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
    let extensionURL = resourceDirectory.appendingPathComponent("ApplePiNotifyExtension.mjs")
    try "export default function () {}\n".write(to: extensionURL, atomically: true, encoding: .utf8)
    defer { try? Foundation.FileManager().removeItem(at: resourceDirectory) }

    let request = PiLaunchRequest(
        workingDirectory: nil,
        sessionPath: nil,
        forkPath: nil,
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )
    let launch = PiCommandBuilder(notificationExtensionResourceURL: resourceDirectory)
        .terminalLaunch(for: request, host: PiHostConfiguration(), notificationsEnabled: false)

    #expect(launch.arguments == ["pi"])
}

@Test func explicitLocalPiExecutableLaunchesDirectly() {
    let request = PiLaunchRequest(
        workingDirectory: nil,
        sessionPath: nil,
        forkPath: nil,
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )
    let host = PiHostConfiguration(piExecutable: "/usr/local/bin/pi")

    let launch = PiCommandBuilder().terminalLaunch(for: request, host: host)

    #expect(launch.executable == "/usr/local/bin/pi")
    #expect(launch.arguments.isEmpty)
    #expect(launch.execName == "pi")
}

@Test func localPiLaunchPreservesWorkingDirectory() {
    let request = PiLaunchRequest(
        workingDirectory: "~/Code/My Project",
        sessionPath: nil,
        forkPath: nil,
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )

    let launch = PiCommandBuilder().terminalLaunch(for: request, host: PiHostConfiguration())

    #expect(launch.workingDirectory == "\(NSHomeDirectory())/Code/My Project")
}

@Test func localPiForkLaunchUsesForkFlag() {
    let request = PiLaunchRequest(
        workingDirectory: "~/Code/My Project",
        sessionPath: nil,
        forkPath: "/tmp/source.jsonl",
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )

    let launch = PiCommandBuilder().terminalLaunch(for: request, host: PiHostConfiguration())

    #expect(launch.arguments == ["pi", "--fork", "/tmp/source.jsonl"])
    #expect(launch.workingDirectory == "\(NSHomeDirectory())/Code/My Project")
}

@Test func remotePiLaunchDoesNotLeakLocalHomePath() {
    let request = PiLaunchRequest(
        workingDirectory: "~/code/My Project",
        sessionPath: "~/.pi/agent/sessions/--home-user-code--/session.jsonl",
        forkPath: nil,
        sessionName: "pairing check",
        isEphemeral: false,
        initialPrompt: "hello from Pi"
    )
    let host = PiHostConfiguration(
        mode: .remoteSSH,
        agentDirectory: "~/.pi/agent",
        remoteHost: "pi.example.com",
        remotePort: 2222,
        remoteUser: "ada",
        remotePiExecutable: "~/bin/pi"
    )

    let launch = PiCommandBuilder().terminalLaunch(for: request, host: host)
    let remoteCommand = launch.arguments.last ?? ""

    #expect(launch.executable == "/usr/bin/ssh")
    #expect(launch.arguments.prefix(4) == ["-tt", "-p", "2222", "ada@pi.example.com"])
    #expect(!remoteCommand.contains(NSHomeDirectory()))
    #expect(remoteCommand.contains("export PATH=\"$HOME/.local/bin:"))
    #expect(remoteCommand.contains("cd $HOME/'code/My Project'"))
    #expect(remoteCommand.contains("$HOME/bin/pi"))
    #expect(remoteCommand.contains("--session $HOME/.pi/agent/sessions/--home-user-code--/session.jsonl"))
    #expect(remoteCommand.contains("--name 'pairing check'"))
    #expect(remoteCommand.contains("'hello from Pi'"))
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
@Test func appStateStartsNewSessionInRequestedFolder() throws {
    let temp = try TemporaryPiFixture()
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    state.openNewSession(in: temp.project.path)

    let tab = try #require(state.terminalWorkspace.tabs.first)
    #expect(tab.title == "New Pi")
    #expect(tab.launchRequest.workingDirectory == temp.project.path)
    #expect(!tab.launchRequest.arguments.contains("--no-session"))
}

@MainActor
@Test func appStateStartsNewSessionInHomeWhenNoFolderIsSelected() throws {
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    state.openNewSessionInCurrentFolder()

    let tab = try #require(state.terminalWorkspace.tabs.first)
    #expect(tab.launchRequest.workingDirectory == NSHomeDirectory())
}

@MainActor
@Test func appStateStartsRemoteSessionInRemoteHomeWhenNoFolderIsSelected() throws {
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

    state.openNewSessionInCurrentFolder()

    let tab = try #require(state.terminalWorkspace.tabs.first)
    #expect(tab.launchRequest.workingDirectory == nil)
    #expect(tab.launchRequest.arguments.last?.contains("cd $HOME && pi") == true)
}

@MainActor
@Test func appStateStartsTemporarySessionWithNoSessionFlag() throws {
    let temp = try TemporaryPiFixture()
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    state.openNewSession(in: temp.project.path, isTemporary: true)

    let tab = try #require(state.terminalWorkspace.tabs.first)
    #expect(tab.title == "Temporary")
    #expect(tab.launchRequest.workingDirectory == temp.project.path)
    #expect(tab.launchRequest.arguments.contains("--no-session"))
}

@MainActor
@Test func appStateSheetLaunchUsesFolderNameAndTemporaryToggle() throws {
    let temp = try TemporaryPiFixture()
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )
    state.newSessionWorkingDirectory = temp.project.path
    state.newSessionName = "Pairing check"
    state.newSessionIsTemporary = true
    state.showsNewSessionSheet = true

    state.openNewSession()

    let tab = try #require(state.terminalWorkspace.tabs.first)
    #expect(tab.title == "Pairing check")
    #expect(tab.launchRequest.workingDirectory == temp.project.path)
    #expect(tab.launchRequest.arguments.contains("--no-session"))
    #expect(tab.launchRequest.arguments.contains("--name"))
    #expect(tab.launchRequest.arguments.contains("Pairing check"))
    #expect(!state.showsNewSessionSheet)
    #expect(state.newSessionName.isEmpty)
    #expect(!state.newSessionIsTemporary)
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
    #expect(state.statusMessage == "Remote session deletion is not supported from Apple Pi.")
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
