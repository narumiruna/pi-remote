import Foundation
import Security

enum DeviceCredential {
    enum Failure: Error { case keychain(OSStatus) }

    private static func query(_ device: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.narumiruna.PiRemote.TransportSpike",
            kSecAttrAccount as String: device.uuidString,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func save(_ credential: Data, device: UUID) throws {
        var attributes = query(device)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = credential
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func load(device: UUID) throws -> Data {
        var attributes = query(device)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.keychain(status) }
        return data
    }

    static func delete(device: UUID) throws {
        let status = SecItemDelete(query(device) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
