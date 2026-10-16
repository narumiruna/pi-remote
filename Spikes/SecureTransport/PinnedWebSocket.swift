import Foundation
import PiRemoteCore
import Security

/// Explicit out-of-band certificate pinning for the diagnostic spike.
public final class PinnedWebSocket: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let certificate: Data
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask!
    private let lock = NSLock()
    private var rejectedIdentity = false

    public init(url: URL, certificate: Data) throws {
        guard url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil,
              SecCertificateCreateWithData(nil, certificate as CFData) != nil else {
            throw TransportSpikeFailure.invalidIdentity
        }
        self.certificate = certificate
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16_384
        socket.resume()
    }

    public var didRejectIdentity: Bool { lock.withLock { rejectedIdentity } }

    public func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    public func send(_ payload: TransportSpikePayload) async throws {
        let data = try TransportSpikeMessage(payload).encode()
        try await bounded { [socket] in try await socket!.send(.data(data)) }
    }

    public func receive() async throws -> TransportSpikePayload {
        let message = try await bounded { [socket] in try await socket!.receive() }
        do {
            let bytes: Data
            switch message {
            case .data(let data): bytes = data
            case .string(let string): bytes = Data(string.utf8)
            @unknown default: throw TransportSpikeFailure.invalidMessage
            }
            return try TransportSpikeMessage.decode(bytes).payload
        } catch { close(); throw error }
    }

    private func bounded<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try await operation() }
                    group.addTask { [self] in
                        try await Task.sleep(for: .seconds(10))
                        close()
                        throw TransportSpikeFailure.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch { close(); throw error }
        } onCancel: { close() }
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              (SecCertificateCopyData(leaf) as Data) == certificate,
              let anchor = SecCertificateCreateWithData(nil, certificate as CFData),
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            lock.withLock { rejectedIdentity = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
