import Foundation

public struct ChatAttachment: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case image
        case file
        case audio
    }

    public let id: UUID
    public let kind: Kind
    public let fileURL: URL
    public let displayName: String
    public let mimeType: String?
    public let size: Int64?

    public init(
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

    public var filePath: String {
        fileURL.path
    }

    public var isImage: Bool {
        kind == .image
    }
}
