import Foundation
import Darwin
import ApplePiCore
import ApplePiRemote

struct LocalPiTurnRunner {
    func run(
        host: PiHostConfiguration,
        request: PiLaunchRequest,
        prompt: String,
        attachments: [ChatAttachment],
        sessionRootCandidates: [String],
        onEvent: @escaping @Sendable (PiTurnStreamEvent) async -> Void
    ) async throws {
        guard !request.isEphemeral else {
            throw LocalPiTurnError.ephemeralUnsupported
        }

        let workingDirectory = request.workingDirectory?.expandingTilde ?? NSHomeDirectory()
        let rpcPayload = PiRpcPayloadBuilder.build(prompt: prompt, attachments: attachments)

        let process = Process()
        let fallbackTitle = Self.fallbackTitle(for: request, cwd: workingDirectory)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [host.piExecutable] + makePiArguments(request: request)
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var environment = PiProcessEnvironment.processEnvironment()
        environment["PI_CODING_AGENT_DIR"] = host.agentDirectory.expandingTilde
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminationObserver = ProcessTerminationObserver()
        process.terminationHandler = { proc in
            terminationObserver.finish(status: proc.terminationStatus)
        }
        let terminationStatusTask = Task<Int32, Never> {
            await terminationObserver.wait()
        }

        do {
            try process.run()
        } catch {
            terminationObserver.finish(status: -1)
            throw error
        }

        let stdoutHandle = outputPipe.fileHandleForReading
        let stderrHandle = errorPipe.fileHandleForReading
        let stdinHandle = inputPipe.fileHandleForWriting

        // Process is now running. The controller is the cancellation
        // hook: when the calling task is cancelled it sends SIGTERM
        // (with a SIGKILL fallback) so the child process does not leak
        // even if the line/stderr tasks are still draining.
        let controller = LocalPiRunController(process: process)

        // Detached tasks drive the pipe readers. They normally exit when
        // the process dies and the pipes close, but we cancel them
        // explicitly in the deferred cleanup to make sure nothing
        // outlives `run()`.
        let stderrTask = Task.detached(priority: .utility) {
            stderrHandle.readDataToEndOfFile()
        }

        let lineTask = Task.detached(priority: .userInitiated) {
            var lineBuffer = Data()
            var didEmitBinding = false
            let handle = stdoutHandle

            // Honour cooperative cancellation: if the calling task is
            // cancelled the line reader breaks out of the poll loop
            // promptly. The pipe close from the terminated process
            // would also break us out, but checking here avoids an
            // extra `availableData` round trip in the common case.
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    break
                }
                lineBuffer.append(chunk)

                while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                    let lineData = lineBuffer[..<newlineIndex]
                    lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
                    guard let rawLine = String(data: lineData, encoding: .utf8) else { continue }

                    if !didEmitBinding,
                       let binding = Self.decodeSessionBinding(from: rawLine, fallbackTitle: fallbackTitle, fallbackWorkingDirectory: workingDirectory) {
                        didEmitBinding = true
                        await onEvent(.sessionBound(binding))
                        continue
                    }

                    if Self.isRPCResponseLine(rawLine) {
                        continue
                    }

                    if let streamEvent = PiTurnStreamParser.parseLine(rawLine) {
                        await onEvent(streamEvent)
                    }

                    if Self.isAgentEndLine(rawLine) {
                        return
                    }
                }
            }
        }

        // Track explicit stdin close so the defer does not double-close
        // the writing end of the pipe (which would be a no-op on macOS
        // but is still cleaner to avoid).
        var didCloseStdin = false
        defer {
            stderrTask.cancel()
            lineTask.cancel()
            if !didCloseStdin {
                try? stdinHandle.close()
            }
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try Self.sendRPCCommand(GetStateCommand(id: "apple-pi-state"), to: stdinHandle)
                try Task.checkCancellation()
                try Self.sendRPCCommand(
                    PromptCommand(
                        id: "apple-pi-prompt",
                        type: "prompt",
                        message: rpcPayload.message,
                        images: rpcPayload.images
                    ),
                    to: stdinHandle
                )
                // Wait for the line task. If the calling task is
                // cancelled the `onCancel` handler terminates the
                // process, the pipes close, the line task completes,
                // and we fall through to the cancellation check below.
                _ = await lineTask.value
            } onCancel: {
                controller.cancel()
            }
        } catch {
            // The interactive phase failed (RPC write error, cancelled,
            // or process died early). Make sure the child is reaped
            // and the stderr pipe is drained before propagating, so
            // the caller's `await` returns with all file descriptors
            // released.
            controller.cancel()
            _ = await terminationStatusTask.value
            _ = await stderrTask.value
            throw error
        }

        // Graceful shutdown: close stdin so the child sees EOF.
        try? stdinHandle.close()
        didCloseStdin = true

        let terminationStatus = await terminationStatusTask.value
        let stderrData = await stderrTask.value

        // If the calling task was cancelled during shutdown, surface
        // that as `CancellationError` rather than a generic command
        // failure. The runner cannot distinguish "the process exited
        // because we killed it" from "the process exited with a
        // non-zero status on its own", so we let the cancellation
        // flag take precedence.
        if Task.isCancelled {
            throw CancellationError()
        }

        guard terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalPiTurnError.commandFailed(status: terminationStatus, message: message)
        }
    }

    private func makePiArguments(request: PiLaunchRequest) -> [String] {
        var arguments = ["--mode", "rpc"]
        if let sessionPath = request.sessionPath?.nilIfBlank {
            arguments.append(contentsOf: ["--session", sessionPath])
        } else if let forkPath = request.forkPath?.nilIfBlank {
            arguments.append(contentsOf: ["--fork", forkPath])
        } else if let sessionName = request.sessionName?.nilIfBlank {
            arguments.append(contentsOf: ["--name", sessionName])
        }
        return arguments
    }

    private static func fallbackTitle(for request: PiLaunchRequest, cwd: String) -> String {
        request.sessionName?.nilIfBlank ?? request.workingDirectory?.nilIfBlank.map { URL(fileURLWithPath: $0).lastPathComponent } ?? URL(fileURLWithPath: cwd).lastPathComponent
    }

    private static func sendRPCCommand<Command: Encodable>(_ command: Command, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(command)
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private static func decodeSessionBinding(from rawLine: String, fallbackTitle: String, fallbackWorkingDirectory: String) -> PiSessionBinding? {
        guard let data = rawLine.data(using: .utf8),
              let response = try? JSONDecoder().decode(GetStateResponse.self, from: data),
              response.type == "response",
              response.command == "get_state",
              response.success,
              let state = response.data else {
            return nil
        }

        return PiSessionBinding(
            sessionID: state.sessionId,
            sessionPath: state.sessionFile,
            title: state.sessionName?.nilIfBlank ?? fallbackTitle,
            workingDirectory: fallbackWorkingDirectory.nilIfBlank
        )
    }

    private static func isRPCResponseLine(_ rawLine: String) -> Bool {
        guard let data = rawLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        return type == "response"
    }

    private static func isAgentEndLine(_ rawLine: String) -> Bool {
        guard let data = rawLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        return type == "agent_end"
    }
}

enum LocalPiTurnError: LocalizedError {
    case ephemeralUnsupported
    case commandFailed(status: Int32, message: String?)

    var errorDescription: String? {
        switch self {
        case .ephemeralUnsupported:
            return "Temporary chat sessions are not supported yet in pi-app."
        case .commandFailed(let status, let message):
            let detail = message?.nilIfBlank
            if let detail {
                return "pi exited with status \(status): \(detail)"
            }
            return "pi exited with status \(status)."
        }
    }
}

private struct GetStateCommand: Encodable {
    let id: String
    let type = "get_state"
}

private struct PromptCommand: Encodable {
    let id: String
    let type: String
    let message: String
    let images: [PiRpcImageContent]
}

private final class ProcessTerminationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var status: Int32?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
            return
        }
        self.status = status
        lock.unlock()
    }
}

private struct GetStateResponse: Decodable {
    let type: String
    let command: String
    let success: Bool
    let data: StateData?

    struct StateData: Decodable {
        let sessionFile: String?
        let sessionId: String?
        let sessionName: String?
    }
}

/// Thread-safe cancellation hook for the running child `pi` process.
/// Used as the `onCancel` handler inside `withTaskCancellationHandler`,
/// so it must be safe to call from any thread and must not block.
///
/// Termination strategy:
///   1. Send `SIGTERM` via `Process.terminate()` so the agent can
///      flush and shut down cleanly.
///   2. If the process is still alive two seconds later, send
///      `SIGKILL` to guarantee the child is reaped.
///
/// `cancel()` is idempotent: the first call wins and subsequent calls
/// are silent no-ops, which matters because the `withTaskCancellationHandler`
/// `onCancel` closure may be invoked from multiple paths.
private final class LocalPiRunController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var didCancel = false

    init(process: Process) {
        self.process = process
    }

    func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        let process = self.process
        self.process = nil
        lock.unlock()

        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        // Hard-kill fallback. The detached task captures only the
        // pid (an `Int32`), so it is safe to run independently of the
        // caller's lifetime. If the process has already exited by the
        // time we wake up, `kill(pid, 0)` returns -1 and the
        // `SIGKILL` is skipped — no risk of killing a recycled pid
        // because the early-exit branch is the common path.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }
}
