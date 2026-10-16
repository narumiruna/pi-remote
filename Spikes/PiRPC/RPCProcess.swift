import Foundation
import PiRemoteCore

public enum RPCFailure: Error, Sendable, Equatable {
    case closed
    case invalidCommand
    case invalidResponse
    case rejected(String)
    case unknownOutcome
    case eventOverflow
    case tooManyRequests
}

/// Local discovery transport only; never expose this interface to a remote client.
public final class RPCProcess: @unchecked Sendable {
    public let events: AsyncThrowingStream<JSONValue, any Error>
    private let eventContinuation: AsyncThrowingStream<JSONValue, any Error>.Continuation
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "PiRemote.rpc.stdin")
    private var closed = false
    private var stopping = false
    private var pending: [String: Pending] = [:]

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
        maximumRecordBytes: Int = 8 * 1_024 * 1_024
    ) throws {
        precondition(eventCapacity > 0)
        let stream = AsyncThrowingStream<JSONValue, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(eventCapacity)
        )
        events = stream.stream
        eventContinuation = stream.continuation
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        input = stdin.fileHandleForWriting
        process = child
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = workingDirectory
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

    public func request(
        _ command: String,
        fields: [String: JSONValue] = [:],
        timeout: TimeInterval = 30
    ) async throws -> JSONValue {
        guard !command.isEmpty, fields["type"] == nil, fields["id"] == nil,
              timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw RPCFailure.invalidCommand
        }
        let id = UUID().uuidString
        var record = fields
        record["type"] = .string(command)
        record["id"] = .string(id)
        var data = try JSONEncoder().encode(JSONValue.object(record))
        guard data.count <= 65_536 else { throw RPCFailure.invalidCommand }
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
                    guard pending.count < 64 else { return .tooManyRequests }
                    pending[id] = Pending(command: command, continuation: continuation, deadline: deadline)
                    return nil
                }
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                writer.async { [weak self] in
                    guard let self, self.lock.withLock({ self.pending[id] != nil && !self.stopping }) else { return }
                    do { try self.input.write(contentsOf: bytes) }
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
            else { entry.continuation.resume(throwing: RPCFailure.rejected(entry.command)) }
        } else {
            if case .dropped = eventContinuation.yield(record) {
                // Keep reading stdout and resolving commands after a slow consumer fails.
                eventContinuation.finish(throwing: RPCFailure.eventOverflow)
            }
        }
    }

    private func failRequest(_ id: String, error: any Error) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        entry.deadline.cancel()
        entry.continuation.resume(throwing: error)
    }

    private func finish(error: any Error) {
        let result = lock.withLock { () -> ([Pending], Bool) in
            closed = true
            let entries = Array(pending.values)
            pending.removeAll()
            return (entries, stopping)
        }
        for entry in result.0 {
            entry.deadline.cancel()
            // The child can exit after performing a command but before replying.
            entry.continuation.resume(throwing: RPCFailure.unknownOutcome)
        }
        if result.1 { eventContinuation.finish() }
        else { eventContinuation.finish(throwing: error) }
    }
}
