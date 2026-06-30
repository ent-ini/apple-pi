import Foundation
import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

// MARK: - ChatSession cancellation

@MainActor
@Test func chatSessionStartsWithoutActiveSend() {
    let session = ChatSession(key: "test", title: "Test")

    #expect(session.sendTask == nil)
    #expect(session.hasActiveSend == false)
}

@MainActor
@Test func chatSessionCancelSendIsSafeWhenNoTask() {
    let session = ChatSession(key: "test", title: "Test")

    // Should be a no-op rather than crashing.
    session.cancelSend()

    #expect(session.sendTask == nil)
    #expect(session.hasActiveSend == false)
}

@MainActor
@Test func chatSessionCancelSendCancelsActiveTask() async throws {
    let session = ChatSession(key: "test", title: "Test")
    let task = Task<Void, Never> {
        // Long-running dummy work that the test will cancel.
        try? await Task.sleep(for: .seconds(30))
    }
    session.sendTask = task

    #expect(session.hasActiveSend)
    #expect(task.isCancelled == false)

    session.cancelSend()

    // The reference is cleared synchronously so the store / view can
    // observe the new state immediately.
    #expect(session.sendTask == nil)
    #expect(session.hasActiveSend == false)
    // The underlying task received the cancellation signal.
    #expect(task.isCancelled)
}

@MainActor
@Test func chatSessionCancelSendTwiceIsIdempotent() async throws {
    let session = ChatSession(key: "test", title: "Test")
    let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    session.sendTask = task

    session.cancelSend()
    session.cancelSend()

    #expect(session.sendTask == nil)
    #expect(task.isCancelled)
}

@MainActor
@Test func chatSessionFinishSendingCancelledClearsTransientState() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "hello")

    #expect(session.isSending)

    session.finishSendingCancelled()

    #expect(session.isSending == false)
    #expect(session.statusMessage.isEmpty)
}

@MainActor
@Test func chatSessionAbortPreservesTransientTranscriptAndAddsAbortEvent() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "hello")
    session.applyStreamingEvents(
        [
            .message(
                Message(id: "assistant-1", role: .assistant, content: [.text("partial")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            )
        ],
        isFinal: false
    )

    session.recordAbortAcknowledged()

    #expect(session.isSending)
    #expect(session.events.contains { event in
        if case .message(let message, _) = event { return message.role == .user }
        return false
    })
    #expect(session.events.contains { event in
        if case .message(let message, _) = event { return message.role == .assistant && message.content == [.text("partial")] }
        return false
    })
    #expect(session.events.contains { event in
        if case .other(let type, _) = event { return type == "abort" }
        return false
    })
}

@MainActor
@Test func chatSessionShowsPlaceholderOnlyBeforeStreamEventsArrive() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "hello")

    #expect(session.pendingAssistantMessageForDisplay != nil)
    #expect(session.shouldShowPendingAssistantPlaceholder)

    session.applyStreamingEvents(
        [
            .message(
                Message(
                    id: "assistant-1",
                    role: .assistant,
                    content: [.text("Hi there")],
                    model: nil,
                    timestamp: nil,
                    parentId: nil
                ),
                lineIndex: 0
            )
        ],
        isFinal: false
    )

    #expect(session.pendingAssistantMessageForDisplay == nil)
    #expect(session.shouldShowPendingAssistantPlaceholder == false)
}

@MainActor
@Test func chatSessionKeepsStreamEventsInWireOrder() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "hello")

    session.applyStreamingEvents(
        [
            .message(
                Message(id: "assistant-1", role: .assistant, content: [.text("I'll check")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            ),
            .toolCall(.function(id: "call-1", name: "read", arguments: "{}"), lineIndex: 0),
            .toolResult(.result(id: "result-1", callId: "call-1", toolName: "read", output: "ok", isError: false), lineIndex: 0),
            .message(
                Message(id: "assistant-2", role: .assistant, content: [.text("Done")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            )
        ],
        isFinal: false
    )

    let roles = session.events.map { event -> String in
        switch event {
        case .message(let message, _): return "message:\(message.role.rawValue):\(message.id)"
        case .toolCall(let call, _): return "toolCall:\(call.id)"
        case .toolResult(let result, _): return "toolResult:\(result.callId)"
        case .meta, .other: return "other"
        }
    }

    #expect(roles.first?.hasPrefix("message:user:") == true)
    #expect(Array(roles.dropFirst()) == [
        "message:assistant:assistant-1",
        "toolCall:call-1",
        "toolResult:call-1",
        "message:assistant:assistant-2"
    ])
}

@MainActor
@Test func chatSessionInitialRemotePageTracksEarlierHistoryAvailability() async throws {
    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: {
            SessionEventsPage(
                events: [
                    .message(
                        Message(id: "m2", role: .assistant, content: [.text("new")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 2
                    )
                ],
                firstLine: 2,
                lastLine: 2,
                hasMoreBefore: true,
                hasMoreAfter: false
            )
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.firstPersistedLineIndex == 2 }

    #expect(session.hasEarlierHistory)
    #expect(session.firstPersistedLineIndex == 2)
}

@MainActor
@Test func chatSessionLoadEarlierHistoryPrependsEventsAndExposesAnchor() async throws {
    let initialPage = SessionEventsPage(
        events: [
            .message(
                Message(id: "m2", role: .assistant, content: [.text("two")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 2
            ),
            .message(
                Message(id: "m3", role: .assistant, content: [.text("three")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 3
            )
        ],
        firstLine: 2,
        lastLine: 3,
        hasMoreBefore: true,
        hasMoreAfter: false
    )
    let olderPage = SessionEventsPage(
        events: [
            .message(
                Message(id: "m0", role: .assistant, content: [.text("zero")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            ),
            .message(
                Message(id: "m1", role: .assistant, content: [.text("one")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 1
            )
        ],
        firstLine: 0,
        lastLine: 1,
        hasMoreBefore: false,
        hasMoreAfter: true
    )

    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: { initialPage },
        historyPageLoader: { before, _ in
            precondition(before == 2)
            return olderPage
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.firstPersistedLineIndex == 2 }
    session.loadEarlierHistory(limit: 120)
    try await waitUntil { session.firstPersistedLineIndex == 0 }

    #expect(session.firstPersistedLineIndex == 0)
    #expect(session.hasEarlierHistory == false)
    #expect(session.pendingHistoryAnchorID == "m2")
    #expect(session.consumePendingHistoryAnchorID() == "m2")
}

// MARK: - ChatSessionStore close/closeAll cancellation

@MainActor
@Test func chatSessionStoreCloseCancelsActiveSend() async throws {
    let store = ChatSessionStore()
    let session = store.openTab(key: "test", title: "Test")
    let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    session.sendTask = task

    store.close(session)

    #expect(store.tabs.isEmpty)
    #expect(session.sendTask == nil)
    #expect(task.isCancelled)
}

@MainActor
@Test func chatSessionStoreCloseAllCancelsActiveSends() async throws {
    let store = ChatSessionStore()
    let sessionA = store.openTab(key: "a", title: "A")
    let sessionB = store.openTab(key: "b", title: "B")
    let taskA = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    let taskB = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    sessionA.sendTask = taskA
    sessionB.sendTask = taskB

    store.closeAll()

    #expect(store.tabs.isEmpty)
    #expect(store.selectedTabID == nil)
    #expect(taskA.isCancelled)
    #expect(taskB.isCancelled)
}

@MainActor
@Test func chatSessionStoreCloseAllOnEmptyStoreIsNoop() {
    let store = ChatSessionStore()
    var onExitCalls = 0
    store.onSessionExit = { onExitCalls += 1 }

    store.closeAll()

    #expect(store.tabs.isEmpty)
    #expect(onExitCalls == 0)
}

@MainActor
@Test func chatSessionStoreCloseIsNoopForUnknownTab() async throws {
    let store = ChatSessionStore()
    let session = ChatSession(key: "test", title: "Test")
    // Note: session is not appended to `store.tabs`.
    let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    session.sendTask = task

    store.close(session)

    // The unknown tab is not removed and its task is untouched.
    #expect(store.tabs.isEmpty)
    #expect(task.isCancelled == false)
}

// MARK: - LocalPiTurnRunner cancellation

@Test func localPiTurnRunnerTerminatesProcessOnCancellation() async throws {
    // The runner uses `/usr/bin/env <piExecutable> --mode rpc ...`,
    // so a shell script that ignores its arguments is a perfect
    // stand-in for a long-running `pi` invocation.
    let fixture = try LongRunningScriptFixture()
    defer { fixture.cleanup() }

    let host = PiHostConfiguration(piExecutable: fixture.scriptPath, agentDirectory: fixture.directory)
    let request = PiLaunchRequest(
        workingDirectory: fixture.directory,
        sessionPath: nil,
        forkPath: nil,
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )
    let runner = LocalPiTurnRunner()

    let task = Task<TestSendOutcome, Never> {
        do {
            try await runner.run(
                host: host,
                request: request,
                prompt: "hello",
                attachments: [],
                sessionRootCandidates: [],
                onEvent: { _ in }
            )
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(String(describing: error))
        }
    }

    // Give the runner time to spawn the process and start the line
    // task. The runner is now suspended in `await lineTask.value`
    // waiting for the script to exit or the pipe to close.
    try await Task.sleep(for: .milliseconds(500))

    let started = Date()
    task.cancel()
    let outcome = await task.value
    let elapsed = Date().timeIntervalSince(started)

    switch outcome {
    case .cancelled:
        // Expected path.
        break
    case .success:
        Issue.record("Expected CancellationError, got success")
    case .failure(let message):
        Issue.record("Expected CancellationError, got failure: \(message)")
    }
    // The script sleeps for 30s by default. If the runner does not
    // honour cancellation it would block until the script exits
    // naturally, far exceeding this budget.
    #expect(elapsed < 5.0, "Cancellation should propagate within 5s, took \(elapsed)s")
}

@Test func localPiTurnRunnerCancellationBeforeRunIsCheap() async throws {
    // If the task is already cancelled when `run` is called, the
    // runner should reject it without spawning a process. We can't
    // observe "no process was spawned" directly, but we can assert
    // that the call returns promptly with `CancellationError`.
    let fixture = try LongRunningScriptFixture()
    defer { fixture.cleanup() }

    let host = PiHostConfiguration(piExecutable: fixture.scriptPath, agentDirectory: fixture.directory)
    let request = PiLaunchRequest(
        workingDirectory: fixture.directory,
        sessionPath: nil,
        forkPath: nil,
        sessionName: nil,
        isEphemeral: false,
        initialPrompt: nil
    )
    let runner = LocalPiTurnRunner()

    let task = Task<TestSendOutcome, Never> {
        do {
            try await runner.run(
                host: host,
                request: request,
                prompt: "hello",
                attachments: [],
                sessionRootCandidates: [],
                onEvent: { _ in }
            )
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(String(describing: error))
        }
    }
    task.cancel()

    let started = Date()
    let outcome = await task.value
    let elapsed = Date().timeIntervalSince(started)

    #expect(outcome == .cancelled, "Expected .cancelled, got \(outcome)")
    #expect(elapsed < 2.0, "Pre-cancelled run should be cheap, took \(elapsed)s")
}

// MARK: - PiAppState send lifecycle

@MainActor
@Test func piAppStateSendMessageStoresTaskOnSession() async throws {
    let fixture = try LongRunningScriptFixture()
    defer { fixture.cleanup() }

    let defaults = isolatedDefaults()
    let host = PiHostConfiguration(piExecutable: fixture.scriptPath, agentDirectory: fixture.directory)
    let hostData = try JSONEncoder().encode(host)
    defaults.set(hostData, forKey: "ApplePi.host")
    // Skip the update check so the test does not hit the network.
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )
    let session = state.chatWorkspace.openTab(
        key: "test",
        title: "Test",
        sessionPath: nil,
        launchRequest: nil
    )

    let didStart = state.sendMessage("hello", in: session)

    #expect(didStart)
    #expect(session.isSending)
    #expect(session.hasActiveSend)
    #expect(session.sendTask != nil)

    // Cancel via the public API and wait for the task body to finish.
    let task = session.sendTask
    session.cancelSend()
    _ = await task?.value

    #expect(session.sendTask == nil)
    #expect(session.isSending == false)
    #expect(session.hasActiveSend == false)
}

@MainActor
@Test func piAppStateSendMessageRefusesToMutateClosedSession() async throws {
    let fixture = try LongRunningScriptFixture()
    defer { fixture.cleanup() }

    let defaults = isolatedDefaults()
    let host = PiHostConfiguration(piExecutable: fixture.scriptPath, agentDirectory: fixture.directory)
    let hostData = try JSONEncoder().encode(host)
    defaults.set(hostData, forKey: "ApplePi.host")
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )
    var session: ChatSession? = state.chatWorkspace.openTab(
        key: "test",
        title: "Test",
        sessionPath: nil,
        launchRequest: nil
    )

    let didStart = state.sendMessage("hello", in: session!)
    #expect(didStart)

    // Close the tab *while* the send is running. `close(_:)` cancels
    // the task and removes the session from the store. The task body
    // must observe the weak reference and avoid touching the session
    // (it is fine for it to keep running in the background until the
    // process is reaped).
    let task = session?.sendTask
    state.chatWorkspace.close(session!)

    // Drop the only strong reference to the session. The task body
    // holds it weakly, so it must observe `nil` and exit cleanly
    // without trying to mutate deallocated state.
    session = nil

    // Wait for the task body to complete. It should not crash even
    // though the session is gone.
    _ = await task?.value
}

@MainActor
@Test func piAppStateCloseAllCancelsActiveSends() async throws {
    let fixture = try LongRunningScriptFixture()
    defer { fixture.cleanup() }

    let defaults = isolatedDefaults()
    let host = PiHostConfiguration(piExecutable: fixture.scriptPath, agentDirectory: fixture.directory)
    let hostData = try JSONEncoder().encode(host)
    defaults.set(hostData, forKey: "ApplePi.host")
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )
    let session = state.chatWorkspace.openTab(
        key: "test",
        title: "Test",
        sessionPath: nil,
        launchRequest: nil
    )

    let didStart = state.sendMessage("hello", in: session)
    #expect(didStart)
    let task = session.sendTask
    #expect(task != nil)

    state.chatWorkspace.closeAll()

    // The send task is cancelled and the session is removed.
    #expect(state.chatWorkspace.tabs.isEmpty)
    #expect(task?.isCancelled == true)
}

// MARK: - Helpers

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let start = ContinuousClock.now
    while !predicate() {
        if start.duration(to: ContinuousClock.now) > timeout {
            throw TestTimeoutError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct TestTimeoutError: Error {}

private enum TestSendOutcome: Equatable, Sendable {
    case success
    case cancelled
    case failure(String)
}

/// Creates a self-executing shell script that sleeps for a long time
/// and ignores its arguments. Used as a stand-in for the real `pi`
/// process so we can exercise the cancellation paths without
/// requiring a working `pi` installation in the test environment.
private final class LongRunningScriptFixture {
    let directory: String
    let scriptPath: String

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplePiSendLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        directory = root.path
        let script = root.appendingPathComponent("sleep-stand-in.sh")
        // 30s is far longer than any reasonable test timeout, so a
        // healthy cancellation path must terminate the process well
        // before it elapses.
        try """
        #!/bin/sh
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        scriptPath = script.path
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    deinit {
        cleanup()
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "ApplePiSendLifecycleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
