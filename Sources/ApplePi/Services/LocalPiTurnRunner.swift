import Foundation

struct LocalPiTurnRunner {
    func run(
        host: PiHostConfiguration,
        request: PiLaunchRequest,
        prompt: String,
        sessionRootCandidates: [String],
        onEvent: @escaping @Sendable (PiTurnStreamEvent) async -> Void
    ) async throws {
        guard !request.isEphemeral else {
            throw LocalPiTurnError.ephemeralUnsupported
        }

        let workingDirectory = request.workingDirectory?.expandingTilde ?? NSHomeDirectory()
        let isCreatingSession = request.sessionPath == nil
        let beforeFiles = isCreatingSession
            ? Set(Self.collectSessionFiles(roots: sessionRootCandidates))
            : []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [host.piExecutable] + makePiArguments(request: request, prompt: prompt)
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var environment = RemoteSSHSupport.processEnvironment()
        environment["PI_CODING_AGENT_DIR"] = host.agentDirectory.expandingTilde
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        try process.run()

        let stdoutHandle = outputPipe.fileHandleForReading
        let stderrHandle = errorPipe.fileHandleForReading

        let terminationWaitTask = Task.detached(priority: .utility) {
            termination.wait()
        }

        let stderrTask = Task.detached(priority: .utility) {
            stderrHandle.readDataToEndOfFile()
        }

        let lineTask = Task.detached(priority: .userInitiated) {
            var discoveredBinding: PiSessionBinding?
            var didEmitBinding = false
            var lineBuffer = Data()
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

                    if isCreatingSession && !didEmitBinding,
                       let streamEvent = PiTurnStreamParser.parseLine(rawLine),
                       case .sessionHeader(let meta) = streamEvent {
                        let discoveredPath = Self.discoverCreatedSessionPath(
                            sessionID: meta.id,
                            roots: sessionRootCandidates,
                            excluding: beforeFiles
                        )
                        let binding = PiSessionBinding(
                            sessionID: meta.id,
                            sessionPath: discoveredPath,
                            title: request.sessionName ?? request.workingDirectory?.nilIfBlank.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Pi",
                            workingDirectory: meta.workingDirectory ?? request.workingDirectory
                        )
                        discoveredBinding = binding
                        didEmitBinding = true
                        await onEvent(.sessionBound(binding))
                    }

                    if let streamEvent = PiTurnStreamParser.parseLine(rawLine) {
                        await onEvent(streamEvent)
                    }
                }
            }

            if !lineBuffer.isEmpty,
               let rawLine = String(data: lineBuffer, encoding: .utf8),
               let streamEvent = PiTurnStreamParser.parseLine(rawLine) {
                await onEvent(streamEvent)
            }

            return (discoveredBinding, didEmitBinding)
        }

        _ = await terminationWaitTask.value
        let terminationStatus = process.terminationStatus
        let stderrData = await stderrTask.value
        let (discoveredBinding, didEmitBinding) = await lineTask.value

        if isCreatingSession && !didEmitBinding,
           let sessionID = discoveredBinding?.sessionID ?? Self.findLatestSessionID(roots: sessionRootCandidates, excluding: beforeFiles) {
            let binding = PiSessionBinding(
                sessionID: sessionID,
                sessionPath: discoveredBinding?.sessionPath ?? Self.discoverCreatedSessionPath(
                    sessionID: sessionID,
                    roots: sessionRootCandidates,
                    excluding: beforeFiles
                ),
                title: request.sessionName ?? request.workingDirectory?.nilIfBlank.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Pi",
                workingDirectory: request.workingDirectory
            )
            await onEvent(.sessionBound(binding))
        }

        guard terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalPiTurnError.commandFailed(status: terminationStatus, message: message)
        }
    }

    private func makePiArguments(request: PiLaunchRequest, prompt: String) -> [String] {
        var arguments = ["--mode", "json"]
        if let sessionPath = request.sessionPath?.nilIfBlank {
            arguments.append(contentsOf: ["--session", sessionPath])
        } else if let forkPath = request.forkPath?.nilIfBlank {
            arguments.append(contentsOf: ["--fork", forkPath])
        } else if let sessionName = request.sessionName?.nilIfBlank {
            arguments.append(contentsOf: ["--name", sessionName])
        }
        arguments.append(prompt)
        return arguments
    }

    private static func collectSessionFiles(roots: [String]) -> [String] {
        let fileManager = FileManager.default
        return roots.flatMap { root -> [String] in
            let expanded = root.expandingTilde
            guard fileManager.fileExists(atPath: expanded) else { return [] }
            return fileManager.enumerator(atPath: expanded)?
                .compactMap { $0 as? String }
                .filter { $0.hasSuffix(".jsonl") }
                .map { URL(fileURLWithPath: expanded).appendingPathComponent($0).path } ?? []
        }
    }

    private static func discoverCreatedSessionPath(
        sessionID: String,
        roots: [String],
        excluding beforeFiles: Set<String>
    ) -> String? {
        let matchingFiles = collectSessionFiles(roots: roots)
            .filter { !beforeFiles.contains($0) }
            .filter { $0.contains(sessionID) }

        if let exact = matchingFiles.first {
            return exact
        }

        let fileManager = FileManager.default
        let newest = collectSessionFiles(roots: roots)
            .filter { !beforeFiles.contains($0) }
            .compactMap { path -> (String, Date)? in
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let modifiedAt = attributes[.modificationDate] as? Date else {
                    return nil
                }
                return (path, modifiedAt)
            }
            .sorted { $0.1 > $1.1 }
            .first?
            .0
        return newest
    }

    private static func findLatestSessionID(roots: [String], excluding beforeFiles: Set<String>) -> String? {
        let fileManager = FileManager.default
        let newestPath = collectSessionFiles(roots: roots)
            .filter { !beforeFiles.contains($0) }
            .compactMap { path -> (String, Date)? in
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let modifiedAt = attributes[.modificationDate] as? Date else {
                    return nil
                }
                return (path, modifiedAt)
            }
            .sorted { $0.1 > $1.1 }
            .first?
            .0
        guard let newestPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: newestPath)),
              let text = String(data: data, encoding: .utf8)?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              let event = SessionEventParser.decode(line: String(text), at: 0),
              case .meta(let meta, _) = event else {
            return nil
        }
        return meta.id
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
