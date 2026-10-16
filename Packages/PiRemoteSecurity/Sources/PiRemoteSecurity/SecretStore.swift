import Darwin
import Foundation
import PiRemoteCore
import Security

public protocol SecretStore: Sendable {
    func get(_ account: String) throws -> Data?
    func put(_ data: Data, account: String) throws
    func remove(_ account: String) throws
}

public struct KeychainSecrets: SecretStore {
    public let service: String
    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func get(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw RemoteFault.storageFailure }
        return data
    }

    public func put(_ data: Data, account: String) throws {
        let query = query(account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw RemoteFault.storageFailure }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw RemoteFault.storageFailure }
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteFault.storageFailure }
    }
}

public enum PrivateFiles {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw RemoteFault.storageFailure
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RemoteFault.storageFailure }
            let data = try file.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
            guard data.count <= 16 * 1_024 * 1_024 else { throw RemoteFault.storageFailure }
            return try JSONDecoder().decode(type, from: data)
        } catch { throw RemoteFault.storageFailure }
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw RemoteFault.storageFailure }
    }
}
