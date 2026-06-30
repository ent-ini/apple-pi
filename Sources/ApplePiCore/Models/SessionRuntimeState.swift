import Foundation

package struct PiModelOption: Identifiable, Hashable, Codable, Sendable {
    package let provider: String
    package let modelID: String
    package let name: String?
    package let reasoning: Bool
    package let contextWindow: Int?

    package init(provider: String, modelID: String, name: String?, reasoning: Bool, contextWindow: Int?) {
        self.provider = provider
        self.modelID = modelID
        self.name = name
        self.reasoning = reasoning
        self.contextWindow = contextWindow
    }

    package var id: String { "\(provider)/\(modelID)" }
    package var displayName: String { id }
    package var shortLabel: String { modelID }
}

package struct DefaultModelPreference: Hashable, Codable, Sendable {
    package let provider: String
    package let modelID: String
    package var thinkingLevel: String?

    package init(provider: String, modelID: String, thinkingLevel: String? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
    }

    package var id: String { "\(provider)/\(modelID)" }
}

package struct SessionTokenTotals: Hashable, Sendable {
    package let input: Int
    package let output: Int
    package let cacheRead: Int
    package let cacheWrite: Int
    package let total: Int

    package init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, total: Int) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }

    package static let zero = SessionTokenTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
}

package struct SessionContextUsage: Hashable, Sendable {
    package let tokens: Int?
    package let contextWindow: Int?
    package let percent: Double?

    package init(tokens: Int?, contextWindow: Int?, percent: Double?) {
        self.tokens = tokens
        self.contextWindow = contextWindow
        self.percent = percent
    }
}

package struct SessionRuntimeState: Hashable, Sendable {
    package let sessionID: String?
    package let sessionPath: String?
    package let provider: String?
    package let modelID: String?
    package let modelName: String?
    package let thinkingLevel: String
    package let tokens: SessionTokenTotals
    package let contextUsage: SessionContextUsage?

    package init(
        sessionID: String?,
        sessionPath: String?,
        provider: String?,
        modelID: String?,
        modelName: String?,
        thinkingLevel: String,
        tokens: SessionTokenTotals,
        contextUsage: SessionContextUsage?
    ) {
        self.sessionID = sessionID
        self.sessionPath = sessionPath
        self.provider = provider
        self.modelID = modelID
        self.modelName = modelName
        self.thinkingLevel = thinkingLevel
        self.tokens = tokens
        self.contextUsage = contextUsage
    }

    package var modelDisplayName: String {
        modelID?.nilIfBlank ?? modelName?.nilIfBlank ?? "no-model"
    }
}
