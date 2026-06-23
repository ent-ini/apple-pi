import Foundation

enum GroqAPIKeyStore {
    nonisolated(unsafe) static var applicationSupportOverride: String?

    enum KeyError: LocalizedError {
        case homeDirectoryUnavailable
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .homeDirectoryUnavailable:
                return "Could not resolve the Application Support directory."
            case .ioFailure(let detail):
                return detail
            }
        }
    }

    static func saveKey(_ token: String) throws {
        try write(data: Data(token.utf8))
    }

    static func deleteKey() throws {
        let fileManager = Foundation.FileManager()
        let path = try keyPath()
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    static func hasKey() -> Bool {
        guard let path = try? keyPath() else { return false }
        return Foundation.FileManager().fileExists(atPath: path)
    }

    static func readKey() -> String? {
        guard let path = try? keyPath(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func keyPath() throws -> String {
        let support = try supportDirectory()
        return "\(support)/groq.token"
    }

    private static func write(data: Data) throws {
        let path = try keyPath()
        do {
            try SecureSecretFileWriter.writeAtomically(data: data, to: path)
        } catch {
            throw KeyError.ioFailure("Could not write Groq token file: \(error.localizedDescription)")
        }
    }

    private static func supportDirectory() throws -> String {
        if let override = applicationSupportOverride {
            return "\(override)/ApplePi/groq"
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw KeyError.homeDirectoryUnavailable
        }
        return support.appendingPathComponent("ApplePi/groq", isDirectory: true).path
    }
}
