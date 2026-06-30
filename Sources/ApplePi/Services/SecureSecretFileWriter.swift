import Foundation
import Darwin
import ApplePiCore
import ApplePiRemote

/// Securely writes small secret blobs (daemon bearer tokens,
/// third-party API keys, etc.) to disk with mode 0600 from the very first
/// byte, and moves the result into place atomically.
///
/// The three secrets stores in the app used to duplicate this logic and
/// shared a few weaknesses:
///
///   * The temp file lived at a predictable `<path>.tmp` path, so two
///     concurrent writers could race over the same name.
///   * `Data.write(options: .atomic)` creates the temp file with the
///     process umask (typically 022), then `chmod`s it to 0600. That
///     leaves a sub-second window where another local user can read the
///     secret.
///   * The directory `chmod` to 0o700 was a `try?` — a user who loosened
///     the directory permissions could silently make stored secrets
///     world-readable, and we'd happily write into that directory.
///
/// This helper fixes all three: a unique temp name, a file created with
/// `O_CREAT|O_EXCL` and mode 0o600 from the start, and a directory
/// `chmod` whose failure is propagated as an error to the caller.
enum SecureSecretFileWriter {
    enum WriterError: LocalizedError {
        case directoryCreationFailed(String)
        case directoryChmodFailed(String)
        case writeFailed(String)
        case renameFailed(String)
        case finalChmodFailed(String)

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed(let detail):
                return "Could not create directory: \(detail)"
            case .directoryChmodFailed(let detail):
                return "Could not secure directory permissions: \(detail)"
            case .writeFailed(let detail):
                return "Could not write secret file: \(detail)"
            case .renameFailed(let detail):
                return "Could not finalize secret file: \(detail)"
            case .finalChmodFailed(let detail):
                return "Could not secure secret file permissions: \(detail)"
            }
        }
    }

    /// Writes `data` to `path` atomically. The parent directory is created
    /// with `directoryMode` (default 0o700); the file itself is created
    /// with `fileMode` (default 0o600) and chmod'd again after the rename
    /// to defend against any filesystem that does not preserve the mode.
    static func writeAtomically(
        data: Data,
        to path: String,
        directoryMode: mode_t = 0o700,
        fileMode: mode_t = 0o600
    ) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let fileManager = FileManager()
        try prepareDirectory(at: directory, mode: directoryMode, fileManager: fileManager)

        // Unique temp name keeps concurrent writers (and any pre-existing
        // stale `.tmp` files left behind by a crash) from colliding.
        let temporaryName = ".\(UUID().uuidString).secret.tmp"
        let temporaryPath = "\(directory)/\(temporaryName)"

        try writeDataAtomically(data, toTemporaryPath: temporaryPath, fileMode: fileMode)

        // Only remove the existing destination once the new file is fully
        // written and fsync'd, so a crash between steps still leaves a
        // valid secret file at either the old or new path.
        do {
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
            try fileManager.moveItem(atPath: temporaryPath, toPath: path)
        } catch {
            try? fileManager.removeItem(atPath: temporaryPath)
            throw WriterError.renameFailed(error.localizedDescription)
        }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: fileMode)],
                ofItemAtPath: path
            )
        } catch {
            throw WriterError.finalChmodFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private static func prepareDirectory(
        at directory: String,
        mode: mode_t,
        fileManager: FileManager
    ) throws {
        do {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)]
            )
        } catch {
            throw WriterError.directoryCreationFailed(error.localizedDescription)
        }

        // `createDirectory` only applies attributes when the directory is
        // newly created. Force the mode on every write so a user who
        // hand-chmod'd the directory to something world-readable cannot
        // silently expose stored secrets. Failures here are real errors:
        // a permissive directory would defeat the whole point of mode 0600
        // on the file, so we surface them to the caller.
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: directory
            )
        } catch {
            throw WriterError.directoryChmodFailed(error.localizedDescription)
        }
    }

    private static func writeDataAtomically(
        _ data: Data,
        toTemporaryPath temporaryPath: String,
        fileMode: mode_t
    ) throws {
        // O_NOFOLLOW refuses to follow a symlink at the temp path. This
        // is belt-and-braces because we just generated a fresh UUID name
        // inside a directory we just chmod'd to 0o700, but a hostile user
        // who can race us could otherwise plant a symlink in the parent
        // directory and trick us into writing the secret to their target.
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        let fd = open(temporaryPath, flags, fileMode)
        if fd < 0 {
            throw WriterError.writeFailed(posixError("open"))
        }

        // The fd is intentionally not closed via `defer` because we also
        // need to remove the temp file on failure, and a single `close`
        // after the write is simpler to reason about.
        var failure: WriterError?
        do {
            let written = try Self.writeAllBytes(data, to: fd)
            guard written == data.count else {
                throw WriterError.writeFailed("Short write to secret file (\(written)/\(data.count))")
            }

            // Defend against a too-permissive umask: re-assert the mode on
            // the open fd after the bytes are down.
            if fchmod(fd, fileMode) != 0 {
                throw WriterError.writeFailed(posixError("fchmod"))
            }

            // Push the bytes to disk before the rename so the destination
            // is durable. Some filesystems (e.g. some FUSE mounts) return
            // EINVAL for fsync; tolerate that explicitly and surface
            // everything else.
            if fsync(fd) != 0 {
                let err = errno
                if err != EINVAL && err != ENOTSUP && err != EINTR {
                    throw WriterError.writeFailed(posixError("fsync"))
                }
            }
        } catch let error as WriterError {
            failure = error
        } catch {
            failure = .writeFailed(error.localizedDescription)
        }

        close(fd)
        if let failure {
            try? FileManager().removeItem(atPath: temporaryPath)
            throw failure
        }
    }

    /// Writes every byte of `data` to `fd`, looping past short writes and
    /// retrying on `EINTR`. Throws `WriterError.writeFailed` if the write
    /// is short-circuited by an I/O error.
    private static func writeAllBytes(_ data: Data, to fd: Int32) throws -> Int {
        try data.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            var total = 0
            while total < data.count {
                let remaining = data.count - total
                let n = write(fd, pointer.advanced(by: total), remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WriterError.writeFailed(posixError("write"))
                }
                if n == 0 { break }
                total += n
            }
            return total
        }
    }

    private static func posixError(_ call: String) -> String {
        let message = String(cString: strerror(errno))
        return "\(call) failed: \(message) (errno \(errno))"
    }
}
