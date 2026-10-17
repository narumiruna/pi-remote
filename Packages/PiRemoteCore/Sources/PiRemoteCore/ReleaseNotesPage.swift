import Foundation

public struct ReleaseNotesPage: Codable, Sendable, Equatable {
    public static let maximumDocumentBytes = 1_024 * 1_024
    public static let maximumPageBytes = 32 * 1_024
    public var version: String
    public var revision: String
    public var offset: Int
    public var totalBytes: Int
    public var text: String
    public var next: Int?

    public init(version: String, revision: String, offset: Int, totalBytes: Int, text: String, next: Int?) {
        self.version = version; self.revision = revision; self.offset = offset
        self.totalBytes = totalBytes; self.text = text; self.next = next
    }

    public func validate() throws {
        let count = text.utf8.count
        guard !version.isEmpty, version.utf8.count <= 128, revision.utf8.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              totalBytes >= 0, totalBytes <= Self.maximumDocumentBytes,
              offset >= 0, offset <= totalBytes, count <= Self.maximumPageBytes,
              count <= totalBytes - offset else { throw RemoteFault.incompatiblePi }
        if offset + count == totalBytes {
            guard next == nil else { throw RemoteFault.incompatiblePi }
        } else {
            guard count > 0, next == offset + count else { throw RemoteFault.incompatiblePi }
        }
    }
}
