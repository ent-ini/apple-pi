import Foundation
import Darwin

struct ProcessRunResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
    let timedOut: Bool
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 20
    ) throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = LockedDataBuffer()
        let errorBuffer = LockedDataBuffer()
        let termination = DispatchSemaphore(value: 0)

        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputBuffer.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorBuffer.append(data)
            }
        }
        process.terminationHandler = { _ in
            termination.signal()
        }

        try process.run()
        let waitResult = termination.wait(timeout: .now() + timeout)
        let timedOut = waitResult == .timedOut
        if timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        return ProcessRunResult(
            standardOutput: outputBuffer.data,
            standardError: errorBuffer.data,
            terminationStatus: timedOut ? -1 : process.terminationStatus,
            timedOut: timedOut
        )
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
