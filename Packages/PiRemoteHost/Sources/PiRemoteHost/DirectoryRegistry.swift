import Darwin
import Foundation
import PiRemoteCore

public struct RegisteredPath: Sendable, Codable, Equatable {
    public var url: URL
    public var identity: String
    public var directory: Bool

    public static func == (lhs: RegisteredPath, rhs: RegisteredPath) -> Bool {
        // URL's directory hint can add a trailing slash without changing the filesystem object.
        lhs.url.path == rhs.url.path && lhs.identity == rhs.identity && lhs.directory == rhs.directory
    }
}

public actor DirectoryRegistry {
    private final class EnumerationFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func record() { lock.withLock { failed = true } }
        var occurred: Bool { lock.withLock { failed } }
    }
    private struct Node { var path: RegisteredPath; var touched: Date }
    private struct Cursor {
        var directory: UUID
        var iterator: FileManager.DirectoryEnumerator
        var failure: EnumerationFailure
        var created: Date
    }
    private var nodes: [UUID: Node] = [:]
    private var cursors: [UUID: Cursor] = [:]

    public init() {}

    public static func identify(_ url: URL) throws -> RegisteredPath {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard stat(canonical.path, &info) == 0 else {
            throw errno == EACCES || errno == EPERM ? RemoteFault.permissionDenied : RemoteFault.staleDirectory
        }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        guard directory || info.st_mode & S_IFMT == S_IFREG else { throw RemoteFault.unsupportedFeature }
        let fingerprint = "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
        return RegisteredPath(url: canonical, identity: fingerprint, directory: directory)
    }

    public func register(_ url: URL) throws -> UUID {
        let path = try Self.identify(url)
        if let existing = nodes.first(where: { $0.value.path == path })?.key {
            nodes[existing]?.touched = Date()
            return existing
        }
        if nodes.count >= 4_096, let oldest = nodes.min(by: { $0.value.touched < $1.value.touched })?.key {
            nodes.removeValue(forKey: oldest)
        }
        let id = UUID()
        nodes[id] = Node(path: path, touched: Date())
        return id
    }

    public func resolve(_ id: UUID, directory: Bool = true) throws -> RegisteredPath {
        guard let node = nodes[id], node.path.directory == directory,
              try Self.identify(node.path.url) == node.path else { throw RemoteFault.staleDirectory }
        nodes[id]?.touched = Date()
        return node.path
    }

    public func list(id supplied: UUID?, cursor cursorID: UUID?) throws -> DirectoryPage {
        cursors = cursors.filter { Date().timeIntervalSince($0.value.created) < 60 }
        let id = try supplied ?? register(FileManager.default.homeDirectoryForCurrentUser)
        let path = try resolve(id)
        let iterator: FileManager.DirectoryEnumerator
        let failure: EnumerationFailure
        let token: UUID
        if let cursorID {
            guard let cursor = cursors[cursorID], cursor.directory == id else { throw RemoteFault.staleDirectory }
            iterator = cursor.iterator; failure = cursor.failure; token = cursorID
        } else {
            failure = EnumerationFailure()
            guard FileManager.default.isReadableFile(atPath: path.url.path),
                  let value = FileManager.default.enumerator(
                    at: path.url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                    errorHandler: { [failure] _, _ in failure.record(); return false }
                  ) else { throw RemoteFault.permissionDenied }
            iterator = value; token = UUID()
            if cursors.count >= 8, let oldest = cursors.min(by: { $0.value.created < $1.value.created })?.key {
                cursors.removeValue(forKey: oldest)
            }
            cursors[token] = Cursor(directory: id, iterator: iterator, failure: failure, created: Date())
        }
        var items: [DirectoryItem] = []
        var examined = 0
        var ended = false
        while examined < 100 {
            guard let url = iterator.nextObject() as? URL else { ended = true; break }
            examined += 1
            do {
                let itemID = try register(url)
                if let node = nodes[itemID] {
                    items.append(DirectoryItem(id: itemID, name: url.lastPathComponent, isDirectory: node.path.directory))
                }
            } catch {
                // An error row has no registered capability and cannot authorize access.
                items.append(DirectoryItem(id: UUID(), name: url.lastPathComponent, isDirectory: false,
                                           fault: error as? RemoteFault ?? .permissionDenied))
            }
        }
        if failure.occurred { cursors.removeValue(forKey: token); throw RemoteFault.permissionDenied }
        if ended { cursors.removeValue(forKey: token) }
        let parentURL = path.url.deletingLastPathComponent()
        let parent = parentURL == path.url ? nil : try register(parentURL)
        // Touch the selected directory last so pagination does not evict it first.
        nodes[id]?.touched = Date()
        return DirectoryPage(
            id: id, path: path.url.path, parent: parent,
            items: items.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            next: ended ? nil : token
        )
    }

    public func preview(_ id: UUID) throws -> FilePreview {
        let path = try resolve(id, directory: false)
        do {
            let descriptor = open(path.url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw RemoteFault.permissionDenied }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(file.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)" == path.identity else {
                throw RemoteFault.staleDirectory
            }
            let data = try file.read(upToCount: 256 * 1_024 + 1) ?? Data()
            guard !data.prefix(4_096).contains(0) else { throw RemoteFault.unsupportedFeature }
            var bytes = Data(data.prefix(256 * 1_024))
            for _ in 0..<4 {
                if let text = String(data: bytes, encoding: .utf8) {
                    return FilePreview(name: path.url.lastPathComponent, text: text, truncated: data.count > bytes.count)
                }
                if data.count <= 256 * 1_024 { break }
                bytes.removeLast()
            }
            throw RemoteFault.unsupportedFeature
        } catch let fault as RemoteFault { throw fault }
        catch { throw RemoteFault.permissionDenied }
    }
}
