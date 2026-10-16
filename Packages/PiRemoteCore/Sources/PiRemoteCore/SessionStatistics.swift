import Foundation

/// Provider-reported usage across this session, including branches and summaries.
/// Do not include the provider's session file path in the remote result.
public struct SessionStatistics: Codable, Sendable, Equatable {
    public struct Tokens: Codable, Sendable, Equatable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var total: Int
    }
    public struct ContextUsage: Codable, Sendable, Equatable {
        public var tokens: Int?
        public var contextWindow: Int
        public var percent: Double?
    }
    public var userMessages: Int
    public var assistantMessages: Int
    public var toolCalls: Int
    public var toolResults: Int
    public var totalMessages: Int
    public var tokens: Tokens
    public var cost: Double
    public var contextUsage: ContextUsage?

    public func validate() throws {
        let counts = [userMessages, assistantMessages, toolCalls, toolResults, totalMessages,
                      tokens.input, tokens.output, tokens.cacheRead, tokens.cacheWrite, tokens.total]
        guard counts.allSatisfy({ $0 >= 0 }), cost.isFinite, cost >= 0 else { throw RemoteFault.incompatiblePi }
        if let contextUsage {
            guard contextUsage.contextWindow > 0,
                  contextUsage.tokens.map({ $0 >= 0 }) ?? true,
                  contextUsage.percent.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw RemoteFault.incompatiblePi }
        }
    }
}
