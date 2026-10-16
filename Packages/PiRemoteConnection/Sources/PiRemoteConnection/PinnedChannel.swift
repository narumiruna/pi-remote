import Foundation
import PiRemoteCore
import Security

/// TLS trust is evaluated for the URL hostname AND the exact locally approved leaf certificate.
public final class PinnedChannel: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let certificate: Data
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask!
    private let lock = NSLock()
    private var rejected = false
    private let maximumBytes: Int

    public init(url: URL, certificate: Data, maximumBytes: Int = 4 * 1_024 * 1_024) throws {
        guard url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil, url.query == nil,
              maximumBytes > 0, maximumBytes <= 4 * 1_024 * 1_024,
              SecCertificateCreateWithData(nil, certificate as CFData) != nil else { throw RemoteFault.invalidRequest }
        self.certificate = certificate; self.maximumBytes = maximumBytes
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = maximumBytes
        socket.resume()
    }

    public var didRejectIdentity: Bool { lock.withLock { rejected } }

    public func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    public func send(_ data: Data) async throws {
        guard data.count <= maximumBytes else { throw RemoteFault.tooLarge }
        try await bounded(seconds: 15) { [socket] in try await socket!.send(.data(data)) }
    }

    public func receive(timeout: TimeInterval = 45) async throws -> Data {
        guard timeout > 0, timeout <= 150 else { throw RemoteFault.invalidRequest }
        let message = try await bounded(seconds: timeout) { [socket] in try await socket!.receive() }
        switch message {
        case .data(let data):
            guard data.count <= maximumBytes else { close(); throw RemoteFault.tooLarge }
            return data
        case .string(let string):
            let data = Data(string.utf8)
            guard data.count <= maximumBytes else { close(); throw RemoteFault.tooLarge }
            return data
        @unknown default: close(); throw RemoteFault.invalidRequest
        }
    }

    private func bounded<T: Sendable>(
        seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try await operation() }
                    group.addTask { [self] in
                        try await Task.sleep(for: .milliseconds(Int64(seconds * 1_000)))
                        close()
                        throw RemoteFault.unavailable
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw RemoteFault.unavailable }
                    return result
                }
            } catch { close(); throw error }
        } onCancel: { close() }
    }

    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first, SecCertificateCopyData(leaf) as Data == certificate,
              let anchor = SecCertificateCreateWithData(nil, certificate as CFData),
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            lock.withLock { rejected = true }
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
