import Foundation
import PiRemoteCore

public enum RPCFailure: Error, Sendable, Equatable {
    case closed
    case invalidCommand
    case invalidResponse
    case rejected(String)
    case providerAuthenticationRequired
    case unknownOutcome
    case eventOverflow
    case tooManyRequests

    public static func isProviderAuthenticationError(_ diagnostic: String) -> Bool {
        let reason = diagnostic.lowercased()
        return ["api key", "credential", "authentication", "not logged in"].contains(where: reason.contains)
    }
}

/// Local subprocess transport only; never expose this interface to a remote client.
public final class RPCProcess: @unchecked Sendable {
    public let events: AsyncThrowingStream<JSONValue, any Error>
    private var eventContinuation: AsyncThrowingStream<JSONValue, any Error>.Continuation
    private let eventCapacity: Int
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "PiRemote.rpc.stdin")
    private var closed = false
    private var stopping = false
    private var pending: [String: Pending] = [:]
    // Admission includes both queued blocks and the write currently blocked on stdin.
    // Timeout/cancellation ends response tracking, not ownership of queued bytes.
    private static let maximumQueuedWrites = 64
    private static let maximumQueuedWriteBytes = 8 * 1_024 * 1_024
    private var queuedWrites = 0
    private var queuedWriteBytes = 0
    private var writing = false

    /// Internal accounting for deterministic backpressure tests; contains no request data.
    var queuedWriteUsage: (count: Int, bytes: Int, active: Bool) { lock.withLock { (queuedWrites, queuedWriteBytes, writing) } }

    private struct Pending {
        let command: String
        let continuation: CheckedContinuation<JSONValue, any Error>
        let deadline: DispatchWorkItem
    }

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        eventCapacity: Int = 256,
        maximumRecordBytes: Int = 8 * 1_024 * 1_024,
        environment: [String: String]? = nil
    ) throws {
        precondition(eventCapacity > 0)
        let stream = AsyncThrowingStream<JSONValue, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(eventCapacity)
        )
        events = stream.stream
        eventContinuation = stream.continuation
        self.eventCapacity = eventCapacity
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        input = stdin.fileHandleForWriting
        process = child
        // A child can close stdin while a large write is blocked. Report EPIPE as
        // an unknown outcome instead of terminating the companion with SIGPIPE.
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = workingDirectory
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        try child.run()

        // Dedicated I/O queues avoid blocking Swift's cooperative executor.
        DispatchQueue(label: "PiRemote.rpc.stdout").async { [weak self] in
            var framer = JSONLFramer(maximumRecordBytes: maximumRecordBytes)
            do {
                while true {
                    let data = stdout.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    try framer.append(data) { record in try self?.receive(record) }
                }
                try framer.finish()
                self?.finish(error: RPCFailure.closed)
            } catch {
                self?.finish(error: error)
                // A broken protocol cannot be recovered within this process.
                if child.isRunning { child.terminate() }
            }
            try? stdout.fileHandleForReading.close()
        }
        DispatchQueue(label: "PiRemote.rpc.stderr").async {
            // Drain diagnostics without retaining or logging possible secrets.
            while !stderr.fileHandleForReading.availableData.isEmpty {}
            try? stderr.fileHandleForReading.close()
        }
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input.close()
    }

    /// Replace the event subscription with a fresh bounded buffer.
    /// Only events received after replacement enter the new stream. Lost events are
    /// not replayed; the caller must resynchronize authoritative session state.
    /// A superseded subscription finishes with eventOverflow, even if still active.
    /// The events property always refers to the initial subscription.
    public func resumeEvents() throws -> AsyncThrowingStream<JSONValue, any Error> {
        try lock.withLock {
            guard !closed, !stopping else { throw RPCFailure.closed }
            let stream = AsyncThrowingStream<JSONValue, any Error>.makeStream(
                bufferingPolicy: .bufferingOldest(eventCapacity)
            )
            eventContinuation.finish(throwing: RPCFailure.eventOverflow)
            eventContinuation = stream.continuation
            return stream.stream
        }
    }

    public func request(
        _ command: String,
        fields: [String: JSONValue] = [:],
        timeout: TimeInterval = 30
    ) async throws -> JSONValue {
        try await enqueue(command, fields: fields, wireID: nil, expectsResponse: true, timeout: timeout)
    }

    public func answerDialog(id: String, value: String?, confirmed: Bool?, cancelled: Bool) async throws {
        var fields: [String: JSONValue] = ["cancelled": .bool(cancelled)]
        if let value { fields["value"] = .string(value) }
        if let confirmed { fields["confirmed"] = .bool(confirmed) }
        _ = try await enqueue("extension_ui_response", fields: fields, wireID: id, expectsResponse: false, timeout: 10)
    }

    private func enqueue(
        _ command: String, fields: [String: JSONValue], wireID: String?, expectsResponse: Bool, timeout: TimeInterval
    ) async throws -> JSONValue {
        guard !command.isEmpty, fields["type"] == nil, fields["id"] == nil,
              timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw RPCFailure.invalidCommand
        }
        let id = UUID().uuidString
        var record = fields
        record["type"] = .string(command)
        record["id"] = .string(wireID ?? id)
        var data = try JSONEncoder().encode(JSONValue.object(record))
        guard data.count <= 4 * 1_024 * 1_024 else { throw RPCFailure.invalidCommand }
        data.append(0x0A)
        let bytes = data
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = DispatchWorkItem { [weak self] in
                    self?.failRequest(id, error: RPCFailure.unknownOutcome)
                }
                let failure: RPCFailure? = lock.withLock {
                    if closed || stopping { return .closed }
                    if Task.isCancelled { return .unknownOutcome }
                    guard pending.count < 64, queuedWrites < Self.maximumQueuedWrites,
                          bytes.count <= Self.maximumQueuedWriteBytes - queuedWriteBytes else { return .tooManyRequests }
                    queuedWrites += 1; queuedWriteBytes += bytes.count
                    pending[id] = Pending(command: command, continuation: continuation, deadline: deadline)
                    return nil
                }
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                writer.async { [weak self] in
                    guard let self else { return }
                    defer {
                        self.lock.withLock {
                            self.writing = false
                            self.queuedWrites -= 1; self.queuedWriteBytes -= bytes.count
                        }
                    }
                    guard self.lock.withLock({
                        guard self.pending[id] != nil, !self.stopping, !self.closed else { return false }
                        self.writing = true
                        return true
                    }) else { return }
                    do {
                        try self.input.write(contentsOf: bytes)
                        if !expectsResponse, let entry = self.lock.withLock({ self.pending.removeValue(forKey: id) }) {
                            entry.deadline.cancel()
                            entry.continuation.resume(returning: .null)
                        }
                    }
                    catch { self.failRequest(id, error: RPCFailure.unknownOutcome) }
                }
            }
        } onCancel: { [weak self] in
            // Dispatch may already have happened; never promise that cancellation unsent it.
            self?.failRequest(id, error: RPCFailure.unknownOutcome)
        }
    }

    /// Clear queues first because abort alone can allow queued work to continue.
    public func stopWork() async throws {
        _ = try await request("clear_queue")
        _ = try await request("abort")
        let state = try await request("get_state")
        guard state["isStreaming"]?.bool == false,
              state["isCompacting"]?.bool == false,
              state["pendingMessageCount"] == .number(0) else {
            throw RPCFailure.invalidResponse
        }
    }

    @discardableResult
    public func shutdown() async -> Bool {
        lock.withLock { stopping = true }
        // Cleanup must finish even when the request or observer task was cancelled.
        return await Task.detached { [self] in await finishShutdown() }.value
    }

    private func finishShutdown() async -> Bool {
        // Queue the close so a blocked write cannot block the shutdown deadline.
        writer.async { [input] in try? input.close() }
        for _ in 0..<50 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<50 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<50 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        finish(error: RPCFailure.closed)
        return !process.isRunning
    }

    private func receive(_ record: JSONValue) throws {
        guard let type = record["type"]?.string else { throw RPCFailure.invalidResponse }
        if type == "response" {
            guard let id = record["id"]?.string else { throw RPCFailure.invalidResponse }
            let entry = lock.withLock { pending.removeValue(forKey: id) }
            // Late responses are valid after a request timeout or cancellation.
            guard let entry else { return }
            entry.deadline.cancel()
            guard record["command"]?.string == entry.command,
                  let success = record["success"]?.bool else {
                entry.continuation.resume(throwing: RPCFailure.invalidResponse)
                throw RPCFailure.invalidResponse
            }
            if success { entry.continuation.resume(returning: record["data"] ?? .null) }
            else {
                let authentication = RPCFailure.isProviderAuthenticationError(record["error"]?.string ?? "")
                entry.continuation.resume(throwing: authentication ? RPCFailure.providerAuthenticationRequired : RPCFailure.rejected(entry.command))
            }
        } else {
            lock.withLock {
                guard !closed else { return }
                if case .dropped = eventContinuation.yield(record) {
                    // Keep draining stdout. Replacement and termination use this same
                    // lock so an old overflow cannot finish a new subscription.
                    eventContinuation.finish(throwing: RPCFailure.eventOverflow)
                }
            }
        }
    }

    private func failRequest(_ id: String, error: any Error) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        entry.deadline.cancel()
        entry.continuation.resume(throwing: error)
    }

    private func finish(error: any Error) {
        let entries = lock.withLock {
            closed = true
            let entries = Array(pending.values)
            pending.removeAll()
            if stopping { eventContinuation.finish() }
            else { eventContinuation.finish(throwing: error) }
            return entries
        }
        for entry in entries {
            entry.deadline.cancel()
            // The child can exit after performing a command but before replying.
            entry.continuation.resume(throwing: RPCFailure.unknownOutcome)
        }
    }
}
