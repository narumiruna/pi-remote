#if os(macOS)
import Foundation
import PiRemoteCore
import Security

public enum SpikeIdentity {
    /// The private key is imported to memory only and is never added to a login keychain.
    public static func load(pkcs12: Data, password: String) throws -> SecIdentity {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true
        ]
        var items: CFArray?
        guard SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw TransportSpikeFailure.invalidIdentity
        }
        return value as! SecIdentity
    }
}
#endif
