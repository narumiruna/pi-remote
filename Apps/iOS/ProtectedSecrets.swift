import Foundation
import LocalAuthentication
import PiRemoteCore
import PiRemoteSecurity
import Security

/// The authenticated context is cleared on background entry; there is no unauthenticated fallback.
final class ProtectedSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var context: LAContext?
    func authorize(_ context: LAContext) { lock.withLock { self.context = context } }
    func invalidate() {
        let old = lock.withLock { let old = context; context = nil; return old }
        old?.invalidate()
    }
    private func query(_ account: String) throws -> [String: Any] {
        guard let context = lock.withLock({ context }) else { throw RemoteFault.unauthorized }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.narumi.PiRemote.Client",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context
        ]
    }
    func get(_ account: String) throws -> Data? {
        var query = try query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let value = item as? Data else { throw RemoteFault.storageFailure }
        return value
    }
    func put(_ data: Data, account: String) throws {
        let query = try query(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound,
              let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) else {
            throw RemoteFault.storageFailure
        }
        var attributes = query
        attributes[kSecAttrAccessControl as String] = control
        attributes[kSecValueData as String] = data
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw RemoteFault.storageFailure }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(try query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteFault.storageFailure }
    }
}
