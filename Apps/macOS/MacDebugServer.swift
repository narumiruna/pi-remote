import Darwin
import Foundation
import Security

/// An opt-in, same-user debug capability. Socket IO runs on a private serial queue.
@MainActor final class MacDebugServer {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/PiRemoteDebug", isDirectory: true)

    enum Failure: String, Error, LocalizedError, Sendable {
        case unsafePath = "unsafe_path"
        case alreadyRunning = "already_running"
        case startupFailed = "startup_failed"
        case pathTooLong = "path_too_long"
        var errorDescription: String? { "Debug service: \(rawValue)." }
    }

    enum OperationError: String, Error, Sendable {
        case windowUnavailable = "window_unavailable"
        case windowAmbiguous = "window_ambiguous"
        case captureProtected = "capture_protected"
        case captureFailed = "capture_failed"
        case captureTooLarge = "capture_too_large"
        case captureBusy = "capture_busy"
        case disabled
    }

    private let directory: URL
    private let deadline: TimeInterval
    private var transport: DebugTransport?
    private(set) var isRunning = false

    init(directory: URL = MacDebugServer.defaultDirectory) {
        self.directory = directory
        deadline = 5
    }

    // Short deadlines are available to tests only, not as a runtime setting.
    init(directory: URL, testDeadline: TimeInterval) {
        self.directory = directory
        deadline = testDeadline
    }

    /// The handler returns an encoded JSON object, not a complete protocol response.
    func start(handler: @escaping @MainActor @Sendable (String) async throws -> Data) throws {
        guard !isRunning else { throw Failure.alreadyRunning }
        let next = DebugTransport(directory: directory, deadline: deadline, handler: handler)
        try next.start()
        transport = next
        isRunning = true
    }

    func stop() {
        transport?.stop()
        transport = nil
        isRunning = false
    }

    deinit { transport?.stop() }
}

// All mutable transport and client state is confined to queue. A new transport is
// created on each enablement, so a cancelled handler cannot reply to a new client.
private final class DebugTransport: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (String) async throws -> Data
    private let queue = DispatchQueue(label: "PiRemote.debug-transport")
    private let directory: URL
    private let deadline: TimeInterval
    private let handler: Handler
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var listener: DispatchSourceRead?
    private var clients: [UUID: Client] = [:]
    private var artifacts: [String: stat] = [:]
    private var active = false
    private var token = ""
    private static let requestLimit = 4_096
    private static let responseLimit = 3 * 1_024 * 1_024

    private final class Descriptor: @unchecked Sendable {
        let value: Int32
        init(_ value: Int32) { self.value = value }
        deinit { Darwin.close(value) }
    }

    private final class Client: @unchecked Sendable {
        let key = UUID()
        let descriptor: Descriptor
        var reader: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var timer: DispatchSourceTimer?
        var task: Task<Void, Never>?
        var input = Data()
        var output = Data()
        var offset = 0
        var requestID: String?
        init(_ descriptor: Descriptor) { self.descriptor = descriptor }
    }

    private struct Request: Decodable {
        let version: Int
        let id: String
        let token: String?
        let operation: String
    }

    init(directory: URL, deadline: TimeInterval, handler: @escaping Handler) {
        self.directory = directory
        self.deadline = deadline
        self.handler = handler
    }

    func start() throws {
        try queue.sync {
            do { try prepare() }
            catch {
                cleanup()
                throw error
            }
        }
    }

    func stop() { queue.sync { cleanup() } }

    private func prepare() throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.path.utf8.contains(0) else { throw MacDebugServer.Failure.unsafePath }
        let path = directory.appendingPathComponent("control.sock").path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw MacDebugServer.Failure.pathTooLong
        }
        directoryFD = try openPrivateDirectory()
        lockFD = openat(directoryFD, "server.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw MacDebugServer.Failure.unsafePath }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, safe(lockInfo, kind: S_IFREG),
              lockInfo.st_nlink == 1 else { throw MacDebugServer.Failure.unsafePath }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw MacDebugServer.Failure.alreadyRunning }

        // Keep the lock inode across disablement. Unlinking a flock file can let
        // two instances lock different inodes and both claim the endpoint.
        for (name, kind) in [("endpoint.json", S_IFREG), ("control.sock", S_IFSOCK)] {
            var info = stat()
            if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard safe(info, kind: kind), info.st_nlink == 1 else { throw MacDebugServer.Failure.unsafePath }
                guard unlinkat(directoryFD, name, 0) == 0 else { throw MacDebugServer.Failure.startupFailed }
            } else if errno != ENOENT { throw MacDebugServer.Failure.unsafePath }
        }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw MacDebugServer.Failure.startupFailed
        }
        token = random.map { String(format: "%02x", $0) }.joined()
        let raw = socket(AF_UNIX, SOCK_STREAM, 0)
        guard raw >= 0 else { throw MacDebugServer.Failure.startupFailed }
        let descriptor = Descriptor(raw)
        try configure(raw)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw MacDebugServer.Failure.startupFailed }
        try remember("control.sock", kind: S_IFSOCK, setPermissions: true)
        guard listen(raw, 4) == 0 else { throw MacDebugServer.Failure.startupFailed }
        let endpoint = try JSONSerialization.data(withJSONObject: ["version": 1, "socketPath": path, "token": token])
        let file = openat(directoryFD, "endpoint.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw MacDebugServer.Failure.startupFailed }
        defer { Darwin.close(file) }
        guard fchmod(file, 0o600) == 0 else { throw MacDebugServer.Failure.startupFailed }
        try remember("endpoint.json", kind: S_IFREG)
        var written = 0
        try endpoint.withUnsafeBytes { bytes in
            while written < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MacDebugServer.Failure.startupFailed }
                written += count
            }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: raw, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(raw) }
        source.setCancelHandler { withExtendedLifetime(descriptor) {} }
        listener = source
        active = true
        source.resume()
    }

    private func openPrivateDirectory() throws -> Int32 {
        // Walk with openat, never following a symlink, including in ancestors.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MacDebugServer.Failure.unsafePath }
        do {
            let components = directory.path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { throw MacDebugServer.Failure.unsafePath }
            for (index, component) in components.enumerated() {
                guard component != ".", component != ".." else { throw MacDebugServer.Failure.unsafePath }
                let name = String(component)
                let last = index == components.count - 1
                if last && mkdirat(fd, name, 0o700) != 0 && errno != EEXIST {
                    throw MacDebugServer.Failure.unsafePath
                }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw MacDebugServer.Failure.unsafePath }
                Darwin.close(fd)
                fd = next
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw MacDebugServer.Failure.unsafePath }
                if last {
                    guard info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
                        throw MacDebugServer.Failure.unsafePath
                    }
                } else {
                    let trustedOwner = info.st_uid == 0 || info.st_uid == geteuid()
                    let stickySystemDirectory = info.st_uid == 0 && info.st_mode & S_ISVTX != 0
                    guard trustedOwner, info.st_mode & 0o022 == 0 || stickySystemDirectory else {
                        throw MacDebugServer.Failure.unsafePath
                    }
                }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func safe(_ info: stat, kind: mode_t) -> Bool {
        info.st_uid == geteuid() && info.st_mode & S_IFMT == kind && info.st_mode & 0o7777 == 0o600
    }

    private func remember(_ name: String, kind: mode_t, setPermissions: Bool = false) throws {
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_uid == geteuid(), info.st_mode & S_IFMT == kind else {
            throw MacDebugServer.Failure.unsafePath
        }
        artifacts[name] = info
        if setPermissions && fchmodat(directoryFD, name, 0o600, AT_SYMLINK_NOFOLLOW) != 0 {
            throw MacDebugServer.Failure.startupFailed
        }
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0, safe(info, kind: kind) else {
            throw MacDebugServer.Failure.unsafePath
        }
    }

    private func configure(_ fd: Int32) throws {
        var one: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
            throw MacDebugServer.Failure.startupFailed
        }
    }

    private func acceptClients(_ fd: Int32) {
        guard active else { return }
        // Bound work per event, including a stream of rejected connections.
        for _ in 0..<16 {
            let accepted = accept(fd, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                return
            }
            let descriptor = Descriptor(accepted)
            do { try configure(accepted) } catch { continue }
            guard clients.count < 4 else {
                let data = response(id: nil, error: "busy")
                data.withUnsafeBytes { _ = Darwin.write(accepted, $0.baseAddress, $0.count) }
                continue
            }
            let client = Client(descriptor)
            clients[client.key] = client
            let reader = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: queue)
            reader.setEventHandler { [weak self, weak client] in
                guard let client else { return }
                self?.read(client)
            }
            reader.setCancelHandler { withExtendedLifetime(descriptor) {} }
            client.reader = reader
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + deadline)
            timer.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                if client.offset == 0 {
                    let data = self.response(id: client.requestID, error: "timeout")
                    data.withUnsafeBytes { _ = Darwin.write(accepted, $0.baseAddress, $0.count) }
                }
                self.finish(client)
            }
            client.timer = timer
            reader.resume()
            timer.resume()
        }
    }

    private func read(_ client: Client) {
        guard clients[client.key] != nil, client.task == nil, client.writer == nil else { return }
        var buffer = [UInt8](repeating: 0, count: Self.requestLimit + 1)
        while true {
            let count = Darwin.read(client.descriptor.value, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish(client) }
                return
            }
            if count == 0 { finish(client); return }
            client.input.append(contentsOf: buffer.prefix(count))
            if client.input.count > Self.requestLimit {
                reply(client, error: "request_too_large")
                return
            }
            if let newline = client.input.firstIndex(of: 10) {
                guard newline == client.input.endIndex - 1 else { reply(client, error: "invalid_request"); return }
                process(client, data: client.input.prefix(upTo: newline))
                return
            }
        }
    }

    private func process(_ client: Client, data: Data) {
        // Parse the ID independently so only validated UUIDs can be reflected.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? String, UUID(uuidString: id) != nil, id.utf8.count == 36 {
            client.requestID = id
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: data), client.requestID != nil else {
            reply(client, error: "invalid_request"); return
        }
        guard let suppliedToken = request.token, suppliedToken.utf8.count == 64,
              constantTimeEqual(suppliedToken, token) else {
            reply(client, error: "unauthorized"); return
        }
        guard request.version == 1 else { reply(client, error: "unsupported_version"); return }
        guard request.operation == "status" || request.operation == "capture" else {
            reply(client, error: "unsupported_operation"); return
        }
        // Retain read readiness while the handler runs to detect disconnection.
        client.reader?.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            var byte: UInt8 = 0
            let count = recv(client.descriptor.value, &byte, 1, MSG_PEEK)
            if count == 0 || count > 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                self.finish(client)
            }
        }
        let handler = handler
        client.task = Task { @MainActor [weak self, weak client] in
            guard !Task.isCancelled else { return }
            let result: Data
            do { result = try await handler(request.operation) }
            catch {
                let code = (error as? MacDebugServer.OperationError)?.rawValue ?? "operation_failed"
                self?.queue.async { [weak self, weak client] in
                    guard let self, let client, self.active, self.clients[client.key] != nil else { return }
                    self.reply(client, error: code)
                }
                return
            }
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self, weak client] in
                guard let self, let client, self.active, self.clients[client.key] != nil else { return }
                self.complete(client, result: result)
            }
        }
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func complete(_ client: Client, result: Data) {
        guard result.count <= Self.responseLimit else { reply(client, error: "response_too_large"); return }
        guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: [
                "version": 1, "id": client.requestID as Any, "ok": true, "result": object
              ]) else { reply(client, error: "invalid_result"); return }
        guard data.count + 1 <= Self.responseLimit else { reply(client, error: "response_too_large"); return }
        write(client, data: data + [10])
    }

    private func response(id: String?, error: String) -> Data {
        // All errors are fixed codes; arbitrary handler errors and input are never returned.
        let object: [String: Any] = ["version": 1, "id": id.map { $0 as Any } ?? NSNull(), "ok": false, "error": error]
        return (try! JSONSerialization.data(withJSONObject: object)) + [10]
    }

    private func reply(_ client: Client, error: String) { write(client, data: response(id: client.requestID, error: error)) }

    private func write(_ client: Client, data: Data) {
        client.reader?.cancel()
        client.reader = nil
        client.output = data
        let descriptor = client.descriptor
        let writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor.value, queue: queue)
        writer.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.flush(client)
        }
        writer.setCancelHandler { withExtendedLifetime(descriptor) {} }
        client.writer = writer
        writer.resume()
    }

    private func flush(_ client: Client) {
        while client.offset < client.output.count {
            let count = client.output.withUnsafeBytes {
                Darwin.write(client.descriptor.value, $0.baseAddress!.advanced(by: client.offset), $0.count - client.offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish(client) }
                return
            }
            guard count > 0 else { finish(client); return }
            client.offset += count
        }
        finish(client)
    }

    private func finish(_ client: Client) {
        guard clients.removeValue(forKey: client.key) != nil else { return }
        client.task?.cancel()
        client.task = nil
        shutdown(client.descriptor.value, SHUT_RDWR)
        client.reader?.cancel()
        client.writer?.cancel()
        client.timer?.cancel()
    }

    private func cleanup() {
        active = false
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) { finish(client) }
        for (name, owned) in artifacts {
            var current = stat()
            if fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_uid == geteuid(), current.st_dev == owned.st_dev, current.st_ino == owned.st_ino {
                _ = unlinkat(directoryFD, name, 0)
            }
        }
        artifacts.removeAll()
        if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
        if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
        token = ""
    }
}
