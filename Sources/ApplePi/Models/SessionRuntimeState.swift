import Foundation

struct PiModelOption: Identifiable, Hashable, Codable, Sendable {
    let provider: String
    let modelID: String
    let name: String?
    let reasoning: Bool
    let contextWindow: Int?

    var id: String { "\(provider)/\(modelID)" }
    var displayName: String { id }
    var shortLabel: String { modelID }
}

struct DefaultModelPreference: Hashable, Codable, Sendable {
    let provider: String
    let modelID: String

    var id: String { "\(provider)/\(modelID)" }
}

struct SessionTokenTotals: Hashable, Sendable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let total: Int

    static let zero = SessionTokenTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
}

struct SessionContextUsage: Hashable, Sendable {
    let tokens: Int?
    let contextWindow: Int?
    let percent: Double?
}

struct SessionRuntimeState: Hashable, Sendable {
    let sessionID: String?
    let sessionPath: String?
    let provider: String?
    let modelID: String?
    let modelName: String?
    let thinkingLevel: String
    let tokens: SessionTokenTotals
    let contextUsage: SessionContextUsage?

    var modelDisplayName: String {
        modelID?.nilIfBlank ?? modelName?.nilIfBlank ?? "no-model"
    }
}
