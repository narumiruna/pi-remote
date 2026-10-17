import Foundation

public enum BashStatus: String, Codable, Sendable {
    case running, cancelling, completed, cancelled, failed, unknownOutcome
}

/// One bounded shell display. The ID is the admitted app request ID.
public struct BashExecution: Codable, Sendable, Equatable, Identifiable {
    public static let outputLimit = 64 * 1_024
    public static let commandLimit = 16 * 1_024
    public var id: UUID
    public var command: String
    public var excludeFromContext: Bool
    public var status: BashStatus = .running
    public var output = ""
    public var exitCode: Int?
    public var truncated = false
    public var fault: RemoteFault?

    public init(id: UUID, command: String, excludeFromContext: Bool) {
        self.id = id; self.command = command; self.excludeFromContext = excludeFromContext
    }

    public var working: Bool { status == .running || status == .cancelling }

    public mutating func append(_ delta: String) {
        guard status == .running || status == .cancelling else { return }
        let remaining = max(0, Self.outputLimit - output.utf8.count)
        if delta.utf8.count > remaining { truncated = true }
        output += DisplayLimit.text(delta, bytes: remaining)
    }

    /// Replace streamed output with the authoritative final result.
    public mutating func finish(_ result: JSONValue) throws {
        guard let output = result["output"]?.string,
              let cancelled = result["cancelled"]?.bool,
              let truncated = result["truncated"]?.bool else { throw RemoteFault.incompatiblePi }
        let exitCode: Int?
        if result["exitCode"] == nil || result["exitCode"] == .null { exitCode = nil }
        else if case .number(let code) = result["exitCode"], code.isFinite,
                code.rounded() == code, code >= -2_147_483_648, code <= 2_147_483_647 { exitCode = Int(code) }
        else { throw RemoteFault.incompatiblePi }
        self.output = DisplayLimit.text(output, bytes: Self.outputLimit)
        self.truncated = truncated || output.utf8.count > Self.outputLimit
        self.exitCode = exitCode
        status = cancelled ? .cancelled : .completed
        fault = nil
    }
}
