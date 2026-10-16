import Darwin
import Foundation
import PiRemoteCore

private final class CommandLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false
    var stopped: Bool { lock.withLock { cancelled } }
    func attach(_ process: Process) {
        let stop = lock.withLock { child = process; return cancelled }
        if stop { terminate(process) }
    }
    func cancel() {
        let process = lock.withLock { cancelled = true; return child }
        if let process { terminate(process) }
    }
    private func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

enum LocalCommand {
    static func run(_ executable: String, _ arguments: [String], directory: URL, limit: Int = 1_048_576, environment: [String: String]? = nil) async throws -> (Data, Bool) {
        let lifetime = CommandLifetime()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    guard !lifetime.stopped else { continuation.resume(throwing: RemoteFault.cancelled); return }
                    let child = Process()
                    let output = Pipe(), error = Pipe()
                    child.executableURL = URL(fileURLWithPath: executable)
                    child.arguments = arguments; child.currentDirectoryURL = directory; child.environment = environment
                    child.standardOutput = output; child.standardError = error
                    child.standardInput = FileHandle.nullDevice
                    do { try child.run() } catch { continuation.resume(throwing: RemoteFault.unavailable); return }
                    lifetime.attach(child)
                    let handles = [output.fileHandleForReading, error.fileHandleForReading]
                    defer { for handle in handles { try? handle.close() } }
                    var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
                    for descriptor in descriptors {
                        _ = fcntl(descriptor.fd, F_SETFL, O_NONBLOCK)
                    }
                    let deadline = ProcessInfo.processInfo.systemUptime + 15
                    var stoppedAt: TimeInterval?
                    var data = Data(), truncated = false
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    // Nonblocking reads also bound shutdown when a descendant keeps a pipe open.
                    while descriptors.contains(where: { $0.fd >= 0 }) || child.isRunning {
                        let now = ProcessInfo.processInfo.systemUptime
                        if now >= deadline, !lifetime.stopped { lifetime.cancel() }
                        if lifetime.stopped {
                            if stoppedAt == nil { stoppedAt = now }
                            if now - stoppedAt! >= 1.1 { break }
                        }
                        _ = poll(&descriptors, nfds_t(descriptors.count), 50)
                        for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                            let count = read(descriptors[index].fd, &buffer, buffer.count)
                            if count > 0, index == 0 {
                                let available = max(0, limit - data.count)
                                data.append(contentsOf: buffer.prefix(min(count, available)))
                                truncated = truncated || count > available
                            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                                descriptors[index].fd = -1
                            }
                        }
                    }
                    if lifetime.stopped, child.isRunning { kill(child.processIdentifier, SIGKILL) }
                    child.waitUntilExit()
                    if lifetime.stopped { continuation.resume(throwing: RemoteFault.cancelled) }
                    else if child.terminationStatus == 0 { continuation.resume(returning: (data, truncated)) }
                    else { continuation.resume(throwing: RemoteFault.unavailable) }
                }
            }
        } onCancel: { lifetime.cancel() }
    }
}
