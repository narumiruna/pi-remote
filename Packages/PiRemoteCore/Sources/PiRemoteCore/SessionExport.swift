import Foundation

public enum SessionExportFormat: String, Codable, Sendable, CaseIterable {
    case html, jsonl
}

/// A complete export. Never render exported HTML inside the app.
public struct SessionExport: Codable, Sendable, Equatable {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public var data: Data
    public var format: SessionExportFormat
    public init(data: Data, format: SessionExportFormat = .html) { self.data = data; self.format = format }

    private enum CodingKeys: String, CodingKey { case data, format }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        data = try values.decode(Data.self, forKey: .data)
        // Hosts with HTML-only export did not send a format field.
        format = try values.decodeIfPresent(SessionExportFormat.self, forKey: .format) ?? .html
    }

    public func validate() throws {
        guard !data.isEmpty else { throw RemoteFault.incompatiblePi }
        guard data.count <= Self.maximumBytes else { throw RemoteFault.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw RemoteFault.incompatiblePi }
        if format == .jsonl { _ = try SessionImport(data: data) }
    }
}
