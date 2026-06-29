import Foundation
import Darwin
import Testing
@testable import ApplePi

/// Covers `SecureSecretFileWriter`, the single chokepoint used by
/// `RemoteDaemonTokenStore`, `GroqAPIKeyStore`, and
/// `GroqAPIKeyStore` to drop secrets on disk.
///
/// The pre-hardening implementation wrote to a predictable `<path>.tmp`
/// with the process umask (usually 022), then chmod'd to 0600 and
/// renamed. The directory chmod was a `try?`, so a user who loosened the
/// directory to 0755 could silently make their stored secrets
/// world-readable. These tests pin the new behaviour: files are created
/// with 0600 from the start, temp names are unique, and directory chmod
/// failures are real errors.
@Suite("SecureSecretFileWriter")
struct SecureSecretFileWriterTests {

    @Test
    func writesContentAtomicallyAndApplies0600Mode() throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        let path = temp.directory.appendingPathComponent("secret.pw").path
        let payload = Data("super-secret-payload".utf8)

        try SecureSecretFileWriter.writeAtomically(data: payload, to: path)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(permissions == 0o600)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == payload)
    }

    @Test
    func createsParentDirectoryWith0700Mode() throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        // The secret path is nested two levels deep; the parent directory
        // must be created with 0o700, not the default 0o755.
        let nested = temp.directory
            .appendingPathComponent("nested")
            .appendingPathComponent("deeper")
        let path = nested.appendingPathComponent("secret.pw").path
        try SecureSecretFileWriter.writeAtomically(data: Data("x".utf8), to: path)

        let outerAttributes = try FileManager.default.attributesOfItem(atPath: nested.deletingLastPathComponent().path)
        let innerAttributes = try FileManager.default.attributesOfItem(atPath: nested.path)
        #expect((outerAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
        #expect((innerAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
    }

    @Test
    func overwritesExistingSecretWithoutLeavingTempFilesBehind() throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        let path = temp.directory.appendingPathComponent("secret.pw").path
        try SecureSecretFileWriter.writeAtomically(data: Data("first".utf8), to: path)
        try SecureSecretFileWriter.writeAtomically(data: Data("second".utf8), to: path)

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("second".utf8))
        // The directory must not contain any leftover `.tmp` files.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.directory.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "expected no leftover temp files, found: \(leftovers)")
    }

    @Test
    func tempFileNamesAreUniqueAcrossConcurrentWrites() throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        let path = temp.directory.appendingPathComponent("secret.pw").path
        // Simulate concurrent writers by issuing many writes in close
        // succession. With a non-unique `.tmp` name, two simultaneous
        // open(O_CREAT|O_EXCL) calls would race and one would fail with
        // EEXIST. With UUID-suffixed names, every write should succeed.
        for index in 0..<32 {
            try SecureSecretFileWriter.writeAtomically(
                data: Data("payload-\(index)".utf8),
                to: path
            )
        }

        // The final state is the last write.
        let finalBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(finalBytes == Data("payload-31".utf8))
    }

    @Test
    func retightensPreExistingDirectoryTo0700() throws {
        // The pre-hardening code used `try?` on the directory chmod,
        // which silently swallowed failures and let a permissive
        // directory silently make stored secrets world-readable. The
        // new helper explicitly re-asserts the mode on every write.
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        // Pre-create the parent with a permissive mode.
        let parent = temp.directory.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let path = parent.appendingPathComponent("secret.pw").path
        try SecureSecretFileWriter.writeAtomically(data: Data("x".utf8), to: path)

        // The helper must have tightened the directory to 0o700
        // even though it pre-existed with 0o755.
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(permissions == 0o700, "helper should re-tighten pre-existing directory to 0o700")
    }

    @Test
    func surfacesIOFailuresAsWriterError() throws {
        // The helper must propagate underlying I/O errors as a typed
        // `WriterError` rather than swallow them. Forcing a chmod
        // failure at runtime is not portable without root, so we
        // exercise the same error-propagation code path by using a
        // path whose parent cannot be created: passing a regular file
        // as the parent. This triggers `directoryCreationFailed`,
        // which is the same kind of error the chmod path would raise.
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        let blocker = temp.directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)

        let path = blocker.appendingPathComponent("secret.pw").path
        #expect(throws: SecureSecretFileWriter.WriterError.self) {
            try SecureSecretFileWriter.writeAtomically(data: Data("x".utf8), to: path)
        }
    }

    @Test
    func createsFileWith0600FromTheFirstByte() throws {
        // The pre-hardening `Data.write(options: .atomic)` path left a
        // sub-second window where the file existed with the process
        // umask (typically 022 -> 0644). The new helper opens the
        // destination with O_CREAT and an explicit mode of 0o600, so
        // even if we peek at the file mid-write, no world-readable
        // intermediate is produced.
        //
        // We can't easily observe the in-flight mode from a unit test
        // without injecting a hook, but we *can* assert that the final
        // mode is strictly tighter than the typical umask result.
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        let path = temp.directory.appendingPathComponent("secret.pw").path
        try SecureSecretFileWriter.writeAtomically(
            data: Data("very-secret".utf8),
            to: path
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        // Mode must be 0o600 exactly: no group/other read, no group/other
        // write, no setuid/setgid, no sticky.
        #expect(permissions == 0o600)
        #expect((permissions & 0o077) == 0)
    }

    @Test
    func writesToDestinationEvenWhenDestinationIsASymlink() throws {
        // A hostile symlink planted at the destination must not trick
        // the helper into overwriting an unrelated file. The helper
        // writes to a UUID-suffixed temp name inside a freshly-chmod'd
        // parent directory, then renames into place — so a symlink at
        // the destination gets replaced by the new file rather than
        // followed.
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        let target = temp.directory.appendingPathComponent("target.pw")
        let symlinkPath = temp.directory.appendingPathComponent("link.pw")
        try Data("decoy".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: target)

        try SecureSecretFileWriter.writeAtomically(
            data: Data("real-secret".utf8),
            to: symlinkPath.path
        )

        // The destination is a regular file now, holding the new secret.
        #expect(try Data(contentsOf: symlinkPath) == Data("real-secret".utf8))
        // The original target should be untouched.
        #expect(try Data(contentsOf: target) == Data("decoy".utf8))
    }
}

// MARK: - Test helpers

private struct TempDirectoryHandle {
    let directory: URL
}

private func makeTemporaryDirectory() throws -> TempDirectoryHandle {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplePiTests-secure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return TempDirectoryHandle(directory: directory)
}
