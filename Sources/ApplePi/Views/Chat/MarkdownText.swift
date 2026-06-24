import SwiftUI

/// Lightweight Markdown renderer for chat messages. It intentionally avoids
/// adding a heavy dependency while covering the shapes Pi responses commonly
/// use: paragraphs with inline emphasis/code/links, headings, lists, block
/// quotes, horizontal rules, and fenced code blocks.
struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.parseBlocks(text)) { block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph(let text):
            inlineMarkdownText(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inlineMarkdownText(text)
                .font(headingFont(for: level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedItem(let text):
            listRow(marker: "•", text: text)
        case .orderedItem(let marker, let text):
            listRow(marker: marker, text: text)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                inlineMarkdownText(text)
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code.isEmpty ? " " : code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
        case .rule:
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            inlineMarkdownText(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineMarkdownText(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title3
        case 2: return .headline
        default: return .subheadline
        }
    }

    static func parseBlocks(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        var lineIndex = 0

        func append(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(id: index, kind: kind))
            index += 1
        }

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !text.isEmpty {
                append(.paragraph(text))
            }
        }

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                lineIndex += 1
                continue
            }

            if let fence = fenceInfo(from: trimmed) {
                flushParagraph()
                lineIndex += 1
                var codeLines: [String] = []
                while lineIndex < lines.count {
                    let codeLine = lines[lineIndex]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        break
                    }
                    codeLines.append(codeLine)
                    lineIndex += 1
                }
                if lineIndex < lines.count {
                    lineIndex += 1
                }
                append(.code(language: fence.language, code: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = headingInfo(from: trimmed) {
                flushParagraph()
                append(.heading(level: heading.level, text: heading.text))
                lineIndex += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                append(.rule)
                lineIndex += 1
                continue
            }

            if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                append(.unorderedItem(item))
                lineIndex += 1
                continue
            }

            if let item = orderedItem(from: trimmed) {
                flushParagraph()
                append(.orderedItem(marker: item.marker, text: item.text))
                lineIndex += 1
                continue
            }

            if let quote = quoteText(from: trimmed) {
                flushParagraph()
                var quoteLines = [quote]
                lineIndex += 1
                while lineIndex < lines.count, let continuation = quoteText(from: lines[lineIndex].trimmingCharacters(in: .whitespaces)) {
                    quoteLines.append(continuation)
                    lineIndex += 1
                }
                append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            lineIndex += 1
        }

        flushParagraph()
        return blocks
    }

    private static func fenceInfo(from trimmedLine: String) -> (language: String?)? {
        guard trimmedLine.hasPrefix("```") else { return nil }
        let language = String(trimmedLine.dropFirst(3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (language.nilIfBlank)
    }

    private static func headingInfo(from trimmedLine: String) -> (level: Int, text: String)? {
        var level = 0
        for char in trimmedLine {
            if char == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let afterHashes = trimmedLine.dropFirst(level)
        guard afterHashes.first == " " else { return nil }
        let text = String(afterHashes.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func unorderedItem(from trimmedLine: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if trimmedLine.hasPrefix(marker) {
                let item = String(trimmedLine.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                return item.isEmpty ? nil : item
            }
        }
        return nil
    }

    private static func orderedItem(from trimmedLine: String) -> (marker: String, text: String)? {
        var digitCount = 0
        for char in trimmedLine {
            if char.isNumber { digitCount += 1 } else { break }
        }
        guard digitCount > 0 else { return nil }
        let afterDigits = trimmedLine.dropFirst(digitCount)
        guard afterDigits.hasPrefix(". ") else { return nil }
        let marker = String(trimmedLine.prefix(digitCount)) + "."
        let text = String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (marker, text)
    }

    private static func quoteText(from trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix(">") else { return nil }
        return String(trimmedLine.dropFirst())
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        guard trimmedLine.count >= 3 else { return false }
        let withoutSpaces = trimmedLine.replacingOccurrences(of: " ", with: "")
        guard withoutSpaces.count >= 3 else { return false }
        return withoutSpaces.allSatisfy { $0 == "-" }
            || withoutSpaces.allSatisfy { $0 == "*" }
            || withoutSpaces.allSatisfy { $0 == "_" }
    }
}

struct MarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedItem(String)
        case orderedItem(marker: String, text: String)
        case quote(String)
        case code(language: String?, code: String)
        case rule
    }

    let id: Int
    let kind: Kind
}
