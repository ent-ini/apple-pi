import Foundation
import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

// MARK: - ChatTabPersistence

@Test func chatTabPersistenceRoundTripsSnapshot() {
    let defaults = isolatedDefaults()
    let persistence = ChatTabPersistence(defaults: defaults)
    let snapshot = PersistedChatTabsSnapshot(
        hostFingerprint: "local|/tmp/agent",
        tabs: [
            PersistedChatTab(key: "/tmp/a.jsonl", title: "Alpha", sessionID: nil),
            PersistedChatTab(key: "/tmp/b.jsonl", title: "Beta", sessionID: "remote-2")
        ],
        selectedTabKey: "/tmp/a.jsonl"
    )

    persistence.save(snapshot)
    let loaded = persistence.load()

    #expect(loaded == snapshot)
}

@Test func chatTabPersistenceLoadReturnsNilWhenAbsent() {
    let defaults = isolatedDefaults()
    let persistence = ChatTabPersistence(defaults: defaults)

    #expect(persistence.load() == nil)
}

@Test func chatTabPersistenceLoadReturnsNilForCorruptData() {
    let defaults = isolatedDefaults()
    defaults.set(Data([0x00, 0x01, 0x02]), forKey: "ApplePi.chatTabs")
    let persistence = ChatTabPersistence(defaults: defaults)

    #expect(persistence.load() == nil)
}

@Test func chatTabPersistenceClearRemovesSnapshot() {
    let defaults = isolatedDefaults()
    let persistence = ChatTabPersistence(defaults: defaults)
    persistence.save(
        PersistedChatTabsSnapshot(
            hostFingerprint: "x",
            tabs: [],
            selectedTabKey: nil
        )
    )
    #expect(persistence.load() != nil)

    persistence.clear()

    #expect(persistence.load() == nil)
}

// MARK: - PiHostConfiguration.persistenceFingerprint

@Test func hostFingerprintIsStableForEqualHosts() {
    let a = PiHostConfiguration(agentDirectory: "/tmp/agent")
    let b = PiHostConfiguration(agentDirectory: "/tmp/agent")
    #expect(a.persistenceFingerprint == b.persistenceFingerprint)
}

@Test func hostFingerprintChangesWithAgentDirectory() {
    let a = PiHostConfiguration(agentDirectory: "/tmp/a")
    let b = PiHostConfiguration(agentDirectory: "/tmp/b")
    #expect(a.persistenceFingerprint != b.persistenceFingerprint)
}

@Test func hostFingerprintDecodesLegacyLocalAsRemoteAPI() throws {
    let data = #"{"mode":"local","agentDirectory":"/tmp/agent"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(PiHostConfiguration.self, from: data)
    #expect(decoded.mode == .remoteAPI)
}

@Test func hostFingerprintChangesWithDaemonURL() {
    let a = PiHostConfiguration(agentDirectory: "/tmp/agent", remoteDaemonURL: "http://a:1")
    let b = PiHostConfiguration(agentDirectory: "/tmp/agent", remoteDaemonURL: "http://b:1")
    #expect(a.persistenceFingerprint != b.persistenceFingerprint)
}

// MARK: - PiAppState save

@MainActor
@Test func appStateSavePersistsRemoteTabsAndFiltersLocalOrEphemeralKeys() throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    let realFile = try makeSessionFile(contents: "")
    state.chatWorkspace.openOrSelectTab(
        key: realFile.path,
        title: "Local legacy",
        sessionID: nil,
        sessionPath: realFile.path
    )
    state.chatWorkspace.openOrSelectTab(
        key: "remote-1",
        title: "Remote",
        sessionID: "remote-1",
        sessionPath: nil
    )
    state.chatWorkspace.openOrSelectTab(
        key: "fork:\(realFile.path):00000000-0000-0000-0000-000000000002",
        title: "Fork",
        sessionID: nil,
        sessionPath: nil
    )

    state.savePersistedChatTabs()

    let loaded = ChatTabPersistence(defaults: defaults).load()
    let snapshot = try #require(loaded)
    #expect(snapshot.tabs.count == 1)
    #expect(snapshot.tabs.first?.key == "remote-1")
    // The selected tab is the fork one, which is filtered out, so the
    // persisted selected key must be nil.
    #expect(snapshot.selectedTabKey == nil)
    #expect(snapshot.hostFingerprint == state.host.persistenceFingerprint)
}

@MainActor
@Test func appStateSavePersistsSelectedKeyForRemoteTab() throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    state.chatWorkspace.openOrSelectTab(
        key: "remote-1",
        title: "Remote",
        sessionID: "remote-1",
        sessionPath: nil
    )

    state.savePersistedChatTabs()

    let snapshot = try #require(ChatTabPersistence(defaults: defaults).load())
    #expect(snapshot.selectedTabKey == "remote-1")
}

// MARK: - PiAppState restore

@MainActor
@Test func appStateRestoreIsNoOpForMismatchedHost() throws {
    let defaults = isolatedDefaults()
    let realFile = try makeSessionFile(contents: "")
    let snapshot = PersistedChatTabsSnapshot(
        hostFingerprint: "definitely-not-our-host",
        tabs: [PersistedChatTab(key: realFile.path, title: "Real", sessionID: nil)],
        selectedTabKey: realFile.path
    )
    ChatTabPersistence(defaults: defaults).save(snapshot)
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    // A fingerprint mismatch must not reopen any tab.
    #expect(state.chatWorkspace.tabs.isEmpty)
    #expect(state.chatWorkspace.selectedTab == nil)
}

@MainActor
@Test func appStateRestoreIgnoresLegacyLocalFileBackedTab() throws {
    let defaults = isolatedDefaults()
    let realFile = try makeSessionFile(contents: "{\"type\":\"session\",\"id\":\"a\"}\n")
    let host = PiHostConfiguration()
    let snapshot = PersistedChatTabsSnapshot(
        hostFingerprint: host.persistenceFingerprint,
        tabs: [PersistedChatTab(key: realFile.path, title: "Local", sessionID: nil)],
        selectedTabKey: realFile.path
    )
    ChatTabPersistence(defaults: defaults).save(snapshot)
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    #expect(state.chatWorkspace.tabs.isEmpty)
    #expect(state.chatWorkspace.selectedTab == nil)
}

@MainActor
@Test(.disabled("Local file-backed tab restore is legacy-disabled in remote-only mode")) func appStateRestoreSkipsLocalTabWithMissingFile() throws {
    let defaults = isolatedDefaults()
    let missing = "/tmp/ApplePiMissingSession-\(UUID().uuidString).jsonl"
    let snapshot = PersistedChatTabsSnapshot(
        hostFingerprint: PiHostConfiguration().persistenceFingerprint,
        tabs: [PersistedChatTab(key: missing, title: "Gone", sessionID: nil)],
        selectedTabKey: missing
    )
    ChatTabPersistence(defaults: defaults).save(snapshot)
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    #expect(state.chatWorkspace.tabs.isEmpty)
    #expect(state.chatWorkspace.selectedTab == nil)
}

@MainActor
@Test func appStateRestoreReopensRemoteTabsWithoutCrashing() throws {
    let defaults = isolatedDefaults()
    let remoteAPIHost = PiHostConfiguration(
        mode: .remoteAPI,
        remoteDaemonURL: "http://127.0.0.1:1"
    )
    // Pre-seed the host so the in-app state loads it on init.
    let hostData = try JSONEncoder().encode(remoteAPIHost)
    defaults.set(hostData, forKey: "ApplePi.host")
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let snapshot = PersistedChatTabsSnapshot(
        hostFingerprint: remoteAPIHost.persistenceFingerprint,
        tabs: [
            PersistedChatTab(key: "remote-1", title: "R1", sessionID: "remote-1"),
            PersistedChatTab(key: "remote-2", title: "R2", sessionID: "remote-2")
        ],
        selectedTabKey: "remote-2"
    )
    ChatTabPersistence(defaults: defaults).save(snapshot)

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    // Restoration must create one tab per persisted entry, even though
    // the daemon URL is bogus. The bogus event loader is what surfaces
    // a `loadError` later — the test only asserts that we did not
    // crash and that the tab is present.
    #expect(state.chatWorkspace.tabs.count == 2)
    #expect(Set(state.chatWorkspace.tabs.map(\.key)) == ["remote-1", "remote-2"])
    #expect(state.chatWorkspace.selectedTab?.key == "remote-2")
}

@MainActor
@Test func appStateRestoreIgnoresEphemeralKeysInSnapshot() throws {
    let defaults = isolatedDefaults()
    let snapshot = PersistedChatTabsSnapshot(
        hostFingerprint: PiHostConfiguration().persistenceFingerprint,
        tabs: [
            PersistedChatTab(key: "new:abc", title: "X", sessionID: nil),
            PersistedChatTab(key: "fork:/tmp/a.jsonl:xyz", title: "Y", sessionID: nil),
            PersistedChatTab(key: "", title: "Z", sessionID: nil)
        ],
        selectedTabKey: nil
    )
    ChatTabPersistence(defaults: defaults).save(snapshot)
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    #expect(state.chatWorkspace.tabs.isEmpty)
}

@MainActor
@Test func appStateRestoreFallsBackGracefullyWhenSelectedRemoteKeyMissing() throws {
    let defaults = isolatedDefaults()
    let snapshot = PersistedChatTabsSnapshot(
        hostFingerprint: PiHostConfiguration().persistenceFingerprint,
        tabs: [
            PersistedChatTab(key: "remote-a", title: "A", sessionID: "remote-a"),
            PersistedChatTab(key: "remote-b", title: "B", sessionID: "remote-b")
        ],
        // Selected key is stale — we should not crash and we should leave the
        // natural selection alone.
        selectedTabKey: "missing-remote"
    )
    ChatTabPersistence(defaults: defaults).save(snapshot)
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    #expect(state.chatWorkspace.tabs.count == 2)
    // A selected key that does not resolve must not become the
    // selected tab; we just leave the store's default selection.
    #expect(state.chatWorkspace.selectedTab?.key != snapshot.selectedTabKey)
}

@MainActor
@Test func appStateRestoreIsNoOpForCorruptSnapshot() throws {
    let defaults = isolatedDefaults()
    defaults.set(Data([0xFF, 0xEE, 0xDD]), forKey: "ApplePi.chatTabs")
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    #expect(state.chatWorkspace.tabs.isEmpty)
}

// MARK: - Helpers

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "ApplePiChatTabTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func makeSessionFile(contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplePiChatTabSession-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("session.jsonl")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file
}
