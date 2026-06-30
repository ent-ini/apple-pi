import Foundation

package struct ChatAttachment: Identifiable, Hashable, Sendable {
    package enum Kind: String, Hashable, Sendable {
        case image
        case file
        case audio
    }

    package let id: UUID
    package let kind: Kind
    package let fileURL: URL
    package let displayName: String
    package let mimeType: String?
    package let size: Int64?

    package init(
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

    package var filePath: String {
        fileURL.path
    }

    package var isImage: Bool {
        kind == .image
    }
}
