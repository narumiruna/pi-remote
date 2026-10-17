import Darwin
import Foundation
import PiRPC
import PiRemoteCore

/// Only reads the exact private output path, never a path supplied by Pi or the phone.
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
