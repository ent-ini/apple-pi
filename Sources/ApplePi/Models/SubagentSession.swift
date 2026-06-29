import Foundation

struct SubagentSession: Identifiable, Hashable, Sendable {
    let id: String
    let callId: String
    let name: String
    let model: String?
    let task: String
    let cwd: String?
    let status: String
    let output: String?
    let isError: Bool

    var displayModel: String {
        model?.nilIfBlank ?? "default model"
    }

    var displayStatus: String {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (output == nil ? "running" : "completed") : value
    }

    var taskPreview: String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No task text" }
        return trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func extract(from events: [SessionEvent]) -> [SubagentSession] {
        var calls: [(call: ToolCall, lineIndex: Int)] = []
        var resultsByCallId: [String: ToolResult] = [:]

        for event in events {
            switch event {
            case .toolCall(let call, let lineIndex) where call.name == "subagent":
                calls.append((call, lineIndex))
            case .toolResult(let result, _) where result.toolName == "subagent" || calls.contains(where: { $0.call.id == result.callId }):
                resultsByCallId[result.callId] = result
            default:
                continue
            }
        }

        return calls.flatMap { call, _ in
            let specs = SubagentToolArguments.decode(from: call.arguments).expandedSpecs
            let result = resultsByCallId[call.id]
            var sections = SubagentOutputSection.parse(result?.output ?? "")

            return specs.enumerated().map { index, spec in
                let matchedSectionIndex = sections.firstIndex { section in
                    section.name == spec.displayName && !section.isConsumed
                }
                let section = matchedSectionIndex.map { sections[$0] }
                if let matchedSectionIndex {
                    sections[matchedSectionIndex].isConsumed = true
                }

                let output = section?.body.nilIfBlank ?? fallbackOutput(for: result, index: index, total: specs.count)
                let status = result?.isError == true
                    ? "error"
                    : (section?.status.nilIfBlank ?? (result == nil ? "running" : "completed"))

                return SubagentSession(
                    id: "subagent:\(call.id):\(index)",
                    callId: call.id,
                    name: spec.displayName,
                    model: spec.displayModel,
                    task: spec.task ?? "",
                    cwd: spec.cwd,
                    status: status,
                    output: output,
                    isError: result?.isError ?? false
                )
            }
        }
    }

    private static func fallbackOutput(for result: ToolResult?, index: Int, total: Int) -> String? {
        guard let result else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // For a single subagent older sessions sometimes store just the raw
        // subagent reply without per-agent markdown sections. For parallel
        // runs, avoid duplicating the whole combined payload into every row.
        return total == 1 ? trimmed : nil
    }
}

private struct SubagentToolArguments: Decodable {
    var task: String?
    var cwd: String?
    var temporaryAgent: SubagentTemporaryAgent?
    var name: String?
    var model: String?
    var description: String?
    var systemPrompt: String?
    var tools: [String]?
    var tasks: [SubagentTaskSpec]?

    var expandedSpecs: [SubagentTaskSpec] {
        if let tasks, !tasks.isEmpty { return tasks }
        return [
            SubagentTaskSpec(
                task: task,
                cwd: cwd,
                temporaryAgent: temporaryAgent,
                name: name,
                model: model,
                description: description,
                systemPrompt: systemPrompt,
                tools: tools
            )
        ]
    }

    static func decode(from arguments: String) -> SubagentToolArguments {
        guard let data = arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SubagentToolArguments.self, from: data) else {
            return SubagentToolArguments(task: nil, cwd: nil, temporaryAgent: nil, name: nil, model: nil, description: nil, systemPrompt: nil, tools: nil, tasks: nil)
        }
        return decoded
    }
}

private struct SubagentTaskSpec: Decodable, Hashable, Sendable {
    var task: String?
    var cwd: String?
    var temporaryAgent: SubagentTemporaryAgent?
    var name: String?
    var model: String?
    var description: String?
    var systemPrompt: String?
    var tools: [String]?

    var displayName: String {
        temporaryAgent?.name?.nilIfBlank
            ?? name?.nilIfBlank
            ?? description?.nilIfBlank
            ?? "Subagent"
    }

    var displayModel: String? {
        temporaryAgent?.model?.nilIfBlank ?? model?.nilIfBlank
    }
}

private struct SubagentTemporaryAgent: Decodable, Hashable, Sendable {
    var name: String?
    var description: String?
    var systemPrompt: String?
    var model: String?
    var tools: [String]?
}

private struct SubagentOutputSection: Hashable {
    var name: String
    var status: String
    var body: String
    var isConsumed = false

    static func parse(_ output: String) -> [SubagentOutputSection] {
        let pattern = #"(?ms)^### \[(.*?)\] ([^\n]+)\n\n(.*?)(?=\n---\n\n### \[|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 4,
                  let nameRange = Range(match.range(at: 1), in: output),
                  let statusRange = Range(match.range(at: 2), in: output),
                  let bodyRange = Range(match.range(at: 3), in: output) else { return nil }
            return SubagentOutputSection(
                name: String(output[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                status: String(output[statusRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                body: cleanSectionBody(String(output[bodyRange]))
            )
        }
    }

    private static func cleanSectionBody(_ body: String) -> String {
        body
            .replacingOccurrences(of: #"\n---\s*\z"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
