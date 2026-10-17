import Foundation

/// A complete HTML export. Never render this active document inside the app.
public struct SessionExport: Codable, Sendable, Equatable {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public var data: Data
    public init(data: Data) { self.data = data }

    public func validate() throws {
        guard !data.isEmpty else { throw RemoteFault.incompatiblePi }
        guard data.count <= Self.maximumBytes else { throw RemoteFault.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw RemoteFault.incompatiblePi }
    }
}
