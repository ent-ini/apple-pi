import AppKit
import SwiftUI

private let messageBubbleMaxWidth: CGFloat = 420

private struct BubbleWidthModifier: ViewModifier {
    let prefersCompactWidth: Bool
    let alignment: Alignment

    func body(content: Content) -> some View {
        if prefersCompactWidth {
            content
                .fixedSize(horizontal: true, vertical: false)
        } else {
            content
                .frame(maxWidth: messageBubbleMaxWidth, alignment: alignment)
        }
    }
}

private struct UserVisibleAttachment: Identifiable, Hashable {
    enum Kind: Hashable {
        case image(path: String, mime: String?)
        case file(path: String, displayName: String, isAudio: Bool)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .image(let path, _):
            return "image:\(path)"
        case .file(let path, let displayName, let isAudio):
            return "file:\(path):\(displayName):\(isAudio)"
        }
    }
}

private struct UserMessagePresentation {
    let attachments: [UserVisibleAttachment]
    let text: String

    var hasAttachments: Bool {
        !attachments.isEmpty
    }

    var isAttachmentOnly: Bool {
        hasAttachments && text.isEmpty
    }

    var prefersCompactWidth: Bool {
        isAttachmentOnly && attachments.count == 1
    }

    static func build(from blocks: [ContentBlock]) -> UserMessagePresentation {
        let hasRenderedImageBlock = blocks.contains {
            if case .image = $0 { return true }
            return false
        }

        var explicitImages: [UserVisibleAttachment] = []
        var extractedAttachments: [UserVisibleAttachment] = []
        var textFragments: [String] = []

        for block in blocks {
            switch block {
            case .text(let rawText):
                let extraction = extractAttachmentsAndText(
                    from: rawText,
                    includeImageTags: !hasRenderedImageBlock
                )
                extractedAttachments.append(contentsOf: extraction.attachments)
                if !extraction.text.isEmpty {
                    textFragments.append(extraction.text)
                }
            case .image(let path, let mime):
                explicitImages.append(.init(kind: .image(path: path, mime: mime)))
            case .thinking:
                continue
            }
        }

        return UserMessagePresentation(
            attachments: deduplicate(explicitImages + extractedAttachments),
            text: normalizeVisibleText(textFragments.joined(separator: "\n\n"))
        )
    }

    static func sanitizeTextOnly(_ rawText: String) -> String {
        normalizeVisibleText(removeSourceTags(from: rawText))
    }

    private struct Extraction {
        let attachments: [UserVisibleAttachment]
        let text: String
    }

    private static func extractAttachmentsAndText(from rawText: String, includeImageTags: Bool) -> Extraction {
        let pattern = #"<file\s+name=\"([^\"]+)\">([\s\S]*?)</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return Extraction(attachments: [], text: sanitizeTextOnly(rawText))
        }

        let nsRange = NSRange(rawText.startIndex..., in: rawText)
        let matches = regex.matches(in: rawText, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return Extraction(attachments: [], text: sanitizeTextOnly(rawText))
        }

        var attachments: [UserVisibleAttachment] = []
        var cleaned = rawText

        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: cleaned) else { continue }

            let path = substring(in: cleaned, nsRange: match.range(at: 1)).map(xmlUnescape) ?? ""
            let body = substring(in: cleaned, nsRange: match.range(at: 2)).map(xmlUnescape) ?? ""

            if let attachment = makeAttachment(path: path, body: body, includeImageTags: includeImageTags) {
                attachments.append(attachment)
            }

            cleaned.replaceSubrange(fullRange, with: "")
        }

        attachments.reverse()
        return Extraction(
            attachments: attachments,
            text: sanitizeTextOnly(cleaned)
        )
    }

    private static func makeAttachment(path: String, body: String, includeImageTags: Bool) -> UserVisibleAttachment? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let isImage = isImageAttachment(path: trimmedPath, body: body)
        if isImage {
            guard includeImageTags else { return nil }
            return UserVisibleAttachment(kind: .image(path: trimmedPath, mime: guessImageMimeType(from: trimmedPath)))
        }

        let displayName = URL(fileURLWithPath: trimmedPath).lastPathComponent
        return UserVisibleAttachment(
            kind: .file(
                path: trimmedPath,
                displayName: displayName.isEmpty ? trimmedPath : displayName,
                isAudio: isAudioPath(trimmedPath)
            )
        )
    }

    private static func isImageAttachment(path: String, body: String) -> Bool {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if isImagePath(path) {
            return true
        }
        return trimmedBody.isEmpty
            || trimmedBody.hasPrefix("[Image:")
            || trimmedBody.hasPrefix("[Image attachment:")
    }

    private static func isImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"].contains(ext)
    }

    private static func isAudioPath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["mp3", "wav", "m4a", "ogg", "oga", "aac", "flac"].contains(ext)
    }

    private static func guessImageMimeType(from path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        default: return nil
        }
    }

    private static func removeSourceTags(from text: String) -> String {
        let withoutSource = text.replacingOccurrences(
            of: #"(?:^|\n)\[source:[^\]]+\]\n?"#,
            with: "\n",
            options: .regularExpression
        )
        return withoutSource.replacingOccurrences(
            of: #"(?:^|\n)\[telegram_topic\][\s\S]*?\[/telegram_topic\]\n?"#,
            with: "\n",
            options: .regularExpression
        )
    }

    private static func normalizeVisibleText(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicate(_ attachments: [UserVisibleAttachment]) -> [UserVisibleAttachment] {
        var seen: Set<String> = []
        var unique: [UserVisibleAttachment] = []
        for attachment in attachments {
            if seen.insert(attachment.id).inserted {
                unique.append(attachment)
            }
        }
        return unique
    }

    private static func substring(in text: String, nsRange: NSRange) -> String? {
        guard let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }

    private static func xmlUnescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// One chat bubble. User messages are right-aligned with the accent
/// background; assistant messages span almost the full width with a
/// neutral surface so long responses are easy to read.
struct MessageBubble: View {
    @EnvironmentObject private var appState: PiAppState
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 90)
                bubbleColumn(alignment: .trailing)
            } else {
                bubbleColumn(alignment: .leading)
                Spacer(minLength: 90)
            }
        }
    }

    @ViewBuilder
    private func bubbleColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            if !thinkingText.isEmpty {
                ThinkingSummaryView(thinkingText: thinkingText)
            }
            if let presentation = userPresentation {
                bubbleSurface(
                    isLastVisibleBlock: true,
                    prefersCompactWidth: presentation.prefersCompactWidth,
                    timestampOverlaysContent: presentation.isAttachmentOnly
                ) {
                    userPresentationView(presentation)
                }
            } else {
                ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { index, block in
                    blockView(block, isLastVisibleBlock: index == visibleBlocks.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func userPresentationView(_ presentation: UserMessagePresentation) -> some View {
        VStack(alignment: .leading, spacing: presentation.text.isEmpty ? 0 : 10) {
            ForEach(presentation.attachments) { attachment in
                userAttachmentView(attachment)
            }
            if !presentation.text.isEmpty {
                MarkdownText(presentation.text)
                    .font(.body)
            }
        }
    }

    @ViewBuilder
    private func userAttachmentView(_ attachment: UserVisibleAttachment) -> some View {
        switch attachment.kind {
        case .image(let path, _):
            if let image = resolvedImage(for: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                attachmentCard(systemImage: "photo", title: "Image")
            }
        case .file(_, let displayName, let isAudio):
            attachmentCard(systemImage: isAudio ? "waveform" : "doc", title: displayName)
        }
    }

    private func attachmentCard(systemImage: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
            Text(title)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: 240, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.black.opacity(message.role == .user ? 0.12 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock, isLastVisibleBlock: Bool) -> some View {
        switch block {
        case .text(let rawText):
            let text = displayText(for: rawText)
            if !text.isEmpty {
                bubbleSurface(
                    isLastVisibleBlock: isLastVisibleBlock,
                    prefersCompactWidth: prefersCompactWidth(for: text)
                ) {
                    MarkdownText(text)
                        .font(.body)
                }
            }
        case .thinking:
            EmptyView()
        case .image(let path, _):
            bubbleSurface(isLastVisibleBlock: isLastVisibleBlock, prefersCompactWidth: true) {
                if let image = resolvedImage(for: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text("[image]")
                        .font(.body.monospaced())
                }
            }
        }
    }

    private func bubbleSurface<Content: View>(
        isLastVisibleBlock: Bool,
        prefersCompactWidth: Bool,
        timestampOverlaysContent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let showsTimestamp = isLastVisibleBlock && formattedTime != nil

        return VStack(alignment: .leading, spacing: 0) {
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, showsTimestamp && !timestampOverlaysContent ? 24 : 10)
        .background(bubbleBackground)
        .foregroundStyle(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if isLastVisibleBlock, let timestamp = formattedTime {
                timestampView(timestamp, compact: timestampOverlaysContent)
            }
        }
        .modifier(BubbleWidthModifier(prefersCompactWidth: prefersCompactWidth, alignment: bubbleFrameAlignment))
    }

    private func timestampView(_ timestamp: String, compact: Bool) -> some View {
        Text(timestamp)
            .font(.caption2)
            .foregroundStyle(timestampColor)
            .padding(.horizontal, compact ? 6 : 0)
            .padding(.vertical, compact ? 3 : 0)
            .background {
                if compact {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(message.role == .user ? 0.18 : 0.08))
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 8)
    }

    private var visibleBlocks: [ContentBlock] {
        message.content.filter {
            if case .thinking = $0 { return false }
            return true
        }
    }

    private var userPresentation: UserMessagePresentation? {
        guard message.role == .user else { return nil }
        let presentation = UserMessagePresentation.build(from: message.content)
        return presentation.hasAttachments ? presentation : nil
    }

    private var thinkingText: String {
        message.content.compactMap { block in
            if case .thinking(let text, _) = block {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n---\n\n")
    }

    private func displayText(for rawText: String) -> String {
        guard message.role == .user else { return rawText }
        return UserMessagePresentation.sanitizeTextOnly(rawText)
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return appState.appearance.accentColor
        case .assistant:
            return Color.gray.opacity(0.10)
        case .system:
            return Color.gray.opacity(0.06)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user:
            return appState.appearance.accentForegroundColor
        case .assistant, .system:
            return .primary
        }
    }

    private var formattedTime: String? {
        guard let timestamp = message.timestamp else { return nil }
        return Self.timeFormatter.string(from: timestamp)
    }

    private var timestampColor: Color {
        switch message.role {
        case .user:
            return appState.appearance.accentForegroundColor.opacity(0.82)
        case .assistant, .system:
            return .secondary
        }
    }

    private var bubbleFrameAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private func prefersCompactWidth(for text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count <= 42 && !normalized.contains("\n")
    }

    private func resolvedImage(for path: String) -> NSImage? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "inline-image" else { return nil }
        if trimmed.hasPrefix("data:"),
           let commaIndex = trimmed.firstIndex(of: ",") {
            let base64 = String(trimmed[trimmed.index(after: commaIndex)...])
            if let data = Data(base64Encoded: base64) {
                return NSImage(data: data)
            }
        }
        if let image = NSImage(contentsOfFile: trimmed) {
            return image
        }
        return nil
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
