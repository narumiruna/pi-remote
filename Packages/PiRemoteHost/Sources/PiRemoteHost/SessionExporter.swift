import Darwin
import Foundation
import PiRPC
import PiRemoteCore

/// Creates bounded exports from the managed Pi child, never a phone-supplied path.
enum SessionExporter {
    static func export(using rpc: RPCProcess, support: URL) async throws -> SessionExport {
        let folder = support.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.html")
        let result = try await rpc.request("export_html", fields: ["outputPath": .string(file.path)])
        guard result["path"]?.string == file.path else { throw RemoteFault.incompatiblePi }
        return try read(file)
    }

    /// Match Pi's serializeSessionBranch: fresh header, active ancestors, normalized parents.
    static func branch(_ response: JSONValue, piID: String, directory: String) throws -> SessionExport {
        guard let entries = response["entries"]?.array, let leaf = response["leafId"],
              leaf == .null || leaf.string != nil else { throw RemoteFault.incompatiblePi }
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(piID),
            "timestamp": .string(date.string(from: Date())), "cwd": .string(directory)])
        func encode(_ records: [JSONValue]) throws -> Data {
            var bytes = Data()
            for record in records {
                bytes.append(try JSONEncoder().encode(record)); bytes.append(10)
                guard bytes.count <= SessionExport.maximumBytes else { throw RemoteFault.tooLarge }
            }
            return bytes
        }
        do { _ = try SessionImport(data: encode([header] + entries)) }
        catch let fault as RemoteFault { throw fault == .tooLarge ? fault : RemoteFault.incompatiblePi }
        var byID: [String: JSONValue] = [:]
        for entry in entries {
            guard let id = entry["id"]?.string else { throw RemoteFault.incompatiblePi }
            byID[id] = entry
        }
        var selected: [JSONValue] = []
        var current = leaf.string
        var visited: Set<String> = []
        while let id = current {
            guard visited.insert(id).inserted, let entry = byID[id] else { throw RemoteFault.incompatiblePi }
            selected.append(entry)
            current = entry["parentId"]?.string
        }
        var records = [header]
        var parent: JSONValue = .null
        for entry in selected.reversed() {
            guard case .object(var value) = entry, let id = value["id"]?.string else { throw RemoteFault.incompatiblePi }
            value["parentId"] = parent; records.append(.object(value)); parent = .string(id)
        }
        let result = SessionExport(data: try encode(records), format: .jsonl)
        try result.validate()
        return result
    }

    static func read(_ file: URL) throws -> SessionExport {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RemoteFault.permissionDenied }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RemoteFault.incompatiblePi }
        guard info.st_size <= SessionExport.maximumBytes else { throw RemoteFault.tooLarge }
        let value = SessionExport(data: try handle.read(upToCount: SessionExport.maximumBytes + 1) ?? Data())
        try value.validate()
        return value
    }
}
