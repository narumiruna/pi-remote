import CryptoKit
import Foundation
import ImageIO
import PiRemoteCore
import UniformTypeIdentifiers

/// Bounded, session-local storage. Never include image bytes in state replay.
struct OutputImages {
    private struct Entry {
        var id: UUID
        var digest: String
        var image: ImageAttachment
    }
    private var entries: [Entry] = []
    private var bytes = 0
    static let maximumImageBytes = 2 * 1_024 * 1_024
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumCount = 32

    mutating func image(_ id: UUID) throws -> ImageAttachment {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw RemoteFault.expired }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.image
    }

    mutating func event(_ event: JSONValue) -> JSONValue {
        guard case .object(var fields) = event else { return event }
        for key in ["message", "result", "partialResult"] {
            if let value = fields[key] { fields[key] = message(value) }
        }
        return .object(fields)
    }

    mutating func message(_ message: JSONValue) -> JSONValue {
        guard case .object(var fields) = message, let content = fields["content"]?.array else { return message }
        if fields["role"]?.string == "system" || (fields["role"]?.string == "custom" && fields["display"]?.bool == false) {
            fields["content"] = .array([])
            return .object(fields)
        }
        var count = 0
        fields["content"] = .array(content.map { block in
            guard block["type"]?.string == "image" else { return block }
            count += 1
            // Strip any provider-supplied capability fields and all binary data.
            // The reducer displays at most sixteen references per message.
            guard count <= 16 else { return .object(["type": .string("image")]) }
            let reference = store(block)
            var display: [String: JSONValue] = ["type": .string("image"), "remoteImageID": .string(reference.id.uuidString)]
            if let fault = reference.fault { display["remoteImageFault"] = .string(fault.rawValue) }
            return .object(display)
        })
        return .object(fields)
    }

    private mutating func store(_ block: JSONValue) -> OutputImageReference {
        do {
            guard let mime = block["mimeType"]?.string,
                  let type = ["image/png": UTType.png, "image/jpeg": .jpeg, "image/webp": .webP, "image/gif": .gif][mime] else {
                throw RemoteFault.unsupportedFeature
            }
            guard let encoded = block["data"]?.string else { throw RemoteFault.invalidRequest }
            guard encoded.utf8.count <= (Self.maximumImageBytes + 2) / 3 * 4 else { throw RemoteFault.tooLarge }
            guard let data = Data(base64Encoded: encoded), !data.isEmpty else { throw RemoteFault.invalidRequest }
            guard data.count <= Self.maximumImageBytes else { throw RemoteFault.tooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == type.identifier,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw RemoteFault.invalidRequest }
            let w = width.doubleValue, h = height.doubleValue
            guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 20_000, h <= 20_000, w * h <= 40_000_000 else { throw RemoteFault.tooLarge }
            let digest = mime + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let index = entries.firstIndex(where: { $0.digest == digest }) {
                let existing = entries.remove(at: index); entries.append(existing)
                return OutputImageReference(id: existing.id)
            }
            while entries.count >= Self.maximumCount || bytes + data.count > Self.maximumBytes {
                let oldest = entries.removeFirst(); bytes -= oldest.image.data.count
            }
            let entry = Entry(id: UUID(), digest: digest, image: ImageAttachment(data: data, mimeType: mime))
            entries.append(entry); bytes += data.count
            return OutputImageReference(id: entry.id)
        } catch { return OutputImageReference(id: UUID(), fault: error as? RemoteFault ?? .invalidRequest) }
    }
}
