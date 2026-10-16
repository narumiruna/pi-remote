import Foundation
import Network
import PiRemoteCore
import Security

/// The locally approved leaf, URL hostname and certificate validity must all match.
/// Network.framework permits this explicit private-PKI policy on LAN and Tailscale without ATS exceptions.
public final class PinnedChannel: @unchecked Sendable {
    private var connection: NWConnection!
    private let queue = DispatchQueue(label: "PiRemote.pinned-connection")
    private let lock = NSLock()
    private var rejected = false
    private let maximumBytes: Int

    public init(url: URL, certificate: Data, maximumBytes: Int = 4 * 1_024 * 1_024) throws {
        guard url.scheme == "wss", let hostname = url.host, url.user == nil, url.password == nil, url.query == nil,
              maximumBytes > 0, maximumBytes <= 4 * 1_024 * 1_024,
              SecCertificateCreateWithData(nil, certificate as CFData) != nil else { throw RemoteFault.invalidRequest }
        self.maximumBytes = maximumBytes
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, hostname)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, object, complete in
            let trust = sec_trust_copy_ref(object).takeRetainedValue()
            let valid: Bool
            if let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let leaf = certificates.first, SecCertificateCopyData(leaf) as Data == certificate,
               let starts = SecCertificateCopyNotValidBeforeDate(leaf) as Date?,
               let ends = SecCertificateCopyNotValidAfterDate(leaf) as Date?, starts <= Date(), Date() <= ends,
               let anchor = SecCertificateCreateWithData(nil, certificate as CFData),
               SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, hostname as CFString)) == errSecSuccess,
               SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
               SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
               SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess {
                valid = SecTrustEvaluateWithError(trust, nil)
            } else { valid = false }
            if !valid, let self { self.lock.withLock { self.rejected = true } }
            complete(valid)
        }, queue)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.maximumMessageSize = maximumBytes
        webSocket.autoReplyPing = true
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        connection.start(queue: queue)
    }

    deinit { connection?.cancel() }
    public var didRejectIdentity: Bool { lock.withLock { rejected } }
    public func close() { connection.cancel() }

    public func send(_ data: Data) async throws {
        guard data.count <= maximumBytes else { throw RemoteFault.tooLarge }
        try await bounded(seconds: 15) { [connection] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let context = NWConnection.ContentContext(identifier: "pi-remote", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
                connection!.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
    }

    public func receive(timeout: TimeInterval = 45) async throws -> Data {
        guard timeout > 0, timeout <= 150 else { throw RemoteFault.invalidRequest }
        return try await bounded(seconds: timeout) { [self] in
            while true {
                let result: (Data?, NWProtocolWebSocket.Opcode?) = try await withCheckedThrowingContinuation { continuation in
                    connection.receiveMessage { data, context, complete, error in
                        if let error { continuation.resume(throwing: error); return }
                        guard complete else { continuation.resume(throwing: RemoteFault.invalidRequest); return }
                        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                        continuation.resume(returning: (data, metadata?.opcode))
                    }
                }
                if result.1 == .ping || result.1 == .pong { continue }
                guard result.1 == .binary || result.1 == .text, let data = result.0 else { throw RemoteFault.unavailable }
                guard data.count <= maximumBytes else { throw RemoteFault.tooLarge }
                return data
            }
        }
    }

    private func bounded<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
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
}
