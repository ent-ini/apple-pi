import Foundation

struct ChatAttachment: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case image
        case file
        case audio
    }

    let id: UUID
    let kind: Kind
    let fileURL: URL
    let displayName: String
    let mimeType: String?
    let size: Int64?

    init(
        id: UUID = UUID(),
        kind: Kind,
        fileURL: URL,
        displayName: String,
        mimeType: String? = nil,
        size: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.displayName = displayName
        self.mimeType = mimeType
        self.size = size
    }

    var filePath: String {
        fileURL.path
    }

    var isImage: Bool {
        kind == .image
    }
}
