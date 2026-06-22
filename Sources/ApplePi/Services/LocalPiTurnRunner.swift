import Foundation

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

        var environment = RemoteSSHSupport.processEnvironment()
        environment["PI_CODING_AGENT_DIR"] = host.agentDirectory.expandingTilde
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminationObserver = ProcessTerminationObserver()
        process.terminationHandler = { process in
            terminationObserver.finish(status: process.terminationStatus)
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

        let stderrTask = Task.detached(priority: .utility) {
            stderrHandle.readDataToEndOfFile()
        }

        try Self.sendRPCCommand(GetStateCommand(id: "apple-pi-state"), to: stdinHandle)
        try Self.sendRPCCommand(
            PromptCommand(
                id: "apple-pi-prompt",
                type: "prompt",
                message: rpcPayload.message,
                images: rpcPayload.images
            ),
            to: stdinHandle
        )

        let lineTask = Task.detached(priority: .userInitiated) {
            var lineBuffer = Data()
            var didEmitBinding = false
            let handle = stdoutHandle

            while true {
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

        _ = await lineTask.value
        try? stdinHandle.close()

        let terminationStatus = await terminationStatusTask.value
        let stderrData = await stderrTask.value

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
