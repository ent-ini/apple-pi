import AppKit
import SwiftUI
import ApplePiCore
import ApplePiRemote

struct ChatFileReference: Identifiable, Hashable, Sendable {
    let path: String

    var id: String { path }

    var displayName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    var fileExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    var iconName: String {
        switch fileExtension {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "markdown", "txt", "log", "json", "yaml", "yml", "csv": return "doc.text"
        case "zip", "tar", "gz", "tgz": return "archivebox"
        default: return "doc"
        }
    }

    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"].contains(fileExtension)
    }
}

struct FileReferenceExtraction: Sendable {
    let text: String
    let references: [ChatFileReference]
}

enum ChatFileReferenceExtractor {
    static func extract(from rawText: String) -> FileReferenceExtraction {
        let pattern = #"@([^\s<>()\[\]{}\"'`]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return FileReferenceExtraction(text: rawText, references: [])
        }

        let matches = regex.matches(in: rawText, range: NSRange(rawText.startIndex..., in: rawText))
        guard !matches.isEmpty else {
            return FileReferenceExtraction(text: rawText, references: [])
        }

        var cleaned = rawText
        var references: [ChatFileReference] = []

        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: cleaned),
                  let pathRange = Range(match.range(at: 1), in: cleaned) else { continue }
            let rawPath = String(cleaned[pathRange])
            let trimmedPath = trimTrailingPunctuation(rawPath)
            guard isLikelyFileReference(trimmedPath) else { continue }

            let reference = ChatFileReference(path: trimmedPath)
            references.append(reference)
            let consumedEnd = cleaned.index(fullRange.lowerBound, offsetBy: 1 + trimmedPath.count)
            cleaned.replaceSubrange(fullRange.lowerBound..<consumedEnd, with: reference.displayName)
        }

        references.reverse()
        return FileReferenceExtraction(
            text: normalize(cleaned),
            references: deduplicate(references)
        )
    }

    private static func trimTrailingPunctuation(_ value: String) -> String {
        var trimmed = value
        while let last = trimmed.last, ".,;:!?»”’`*_~".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func isLikelyFileReference(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value.contains("/") || value.hasPrefix("~/") || value.hasPrefix("/") else { return false }
        let ext = URL(fileURLWithPath: value).pathExtension
        return !ext.isEmpty || value.hasPrefix("~/") || value.hasPrefix("/")
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicate(_ references: [ChatFileReference]) -> [ChatFileReference] {
        var seen: Set<String> = []
        var unique: [ChatFileReference] = []
        for reference in references where seen.insert(reference.path).inserted {
            unique.append(reference)
        }
        return unique
    }
}

struct ChatFileReferenceCard: View {
    @EnvironmentObject private var appState: PiAppState

    let reference: ChatFileReference
    let baseDirectory: String?

    @State private var previewImage: NSImage?
    @State private var status: String?
    @State private var isLoadingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: reference.iconName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(appState.appearance.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(reference.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button("Preview") { preview() }
                    .buttonStyle(.borderless)
                Button("Download") { download() }
                    .buttonStyle(.borderless)
            }

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if isLoadingPreview {
                ProgressView()
                    .controlSize(.small)
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("Error") ? .red : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear(perform: loadInlinePreviewIfNeeded)
    }

    private func loadInlinePreviewIfNeeded() {
        guard reference.isImage, previewImage == nil, !isLoadingPreview else { return }
        isLoadingPreview = true
        Task {
            do {
                let file = try await fetchFile()
                let image = NSImage(data: file.data)
                await MainActor.run {
                    previewImage = image
                    isLoadingPreview = false
                }
            } catch {
                await MainActor.run {
                    isLoadingPreview = false
                    status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func preview() {
        Task {
            do {
                let localURL = try await materializeFileForPreview()
                await MainActor.run {
                    NSWorkspace.shared.open(localURL)
                    status = "Opened preview."
                }
            } catch {
                await MainActor.run { status = "Error: \(error.localizedDescription)" }
            }
        }
    }

    private func download() {
        Task {
            do {
                let file = try await fetchFile()
                await MainActor.run {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = file.fileName.nilIfBlank ?? reference.displayName
                    panel.canCreateDirectories = true
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        do {
                            try file.data.write(to: url, options: .atomic)
                            status = "Saved to \(url.path)."
                        } catch {
                            status = "Error: \(error.localizedDescription)"
                        }
                    }
                }
            } catch {
                await MainActor.run { status = "Error: \(error.localizedDescription)" }
            }
        }
    }

    private func materializeFileForPreview() async throws -> URL {
        let file = try await fetchFile()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-app-file-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = sanitizeFileName(file.fileName.nilIfBlank ?? reference.displayName)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        try file.data.write(to: url, options: .atomic)
        return url
    }

    private func fetchFile() async throws -> RemoteFileDownload {
        if appState.host.usesRemoteDaemonTransport {
            return try await RemoteDaemonClient().downloadFile(
                host: appState.host,
                path: reference.path,
                baseDirectory: baseDirectory
            )
        }

        let url = URL(fileURLWithPath: resolvedLocalPath())
        return RemoteFileDownload(
            data: try Data(contentsOf: url),
            fileName: url.lastPathComponent,
            mimeType: nil
        )
    }

    private func resolvedLocalPath() -> String {
        let expanded = (reference.path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        if let baseDirectory = baseDirectory?.nilIfBlank {
            return URL(fileURLWithPath: (baseDirectory as NSString).expandingTildeInPath)
                .appendingPathComponent(reference.path)
                .path
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(reference.path)
            .path
    }

    private func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.joined(separator: "-").nilIfBlank ?? "file"
    }
}
