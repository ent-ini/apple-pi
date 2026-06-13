import Foundation

struct OSC777NotificationPayload: Equatable, Sendable {
    let title: String
    let body: String

    init?(bytes: ArraySlice<UInt8>) {
        guard let string = String(bytes: bytes, encoding: .utf8) else { return nil }
        let parts = string.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "notify" else { return nil }

        guard
            let title = Self.sanitizedText(parts[1]),
            let body = Self.sanitizedText(parts[2])
        else {
            return nil
        }

        self.title = title
        self.body = body
    }

    private static func sanitizedText(_ value: Substring) -> String? {
        let cleaned = String(value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0..<32, 127:
                return false
            default:
                return true
            }
        }).trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.nilIfBlank
    }
}
