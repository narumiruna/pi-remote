import Foundation
import PiRemoteCore
import PiRemoteSecurity

public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

public actor DeviceRegistry {
    private var devices: [PairedDevice]
    private let secrets: any SecretStore
    private let metadata: URL
    private var grant: Data?
    private var expires: TimeInterval = 0
    private var attempts = 0
    private var pending: (connection: UUID, device: PairedDevice)?

    public init(secrets: any SecretStore, metadata: URL) throws {
        self.secrets = secrets; self.metadata = metadata
        devices = try PrivateFiles.read([PairedDevice].self, from: metadata) ?? []
    }

    public func list() -> [PairedDevice] { devices }

    public func openWindow() throws -> Data {
        let value = try PairingProof.randomSecret()
        grant = value; expires = ProcessInfo.processInfo.systemUptime + 120; attempts = 0; pending = nil
        return value
    }

    public func closeWindow() { grant = nil; pending = nil; expires = 0 }

    public func request(connection: UUID, device: UUID, name: String, grant supplied: Data) throws -> PairedDevice {
        attempts += 1
        guard attempts <= 5, let grant, pending == nil, ProcessInfo.processInfo.systemUptime < expires,
              DeviceProof.equal(grant, supplied), !devices.contains(where: { $0.id == device }),
              devices.count < 16, !name.isEmpty, name.utf8.count <= 128 else { throw RemoteFault.unauthorized }
        self.grant = nil
        let item = PairedDevice(id: device, name: name)
        pending = (connection, item)
        return item
    }

    public func approve(connection: UUID) throws -> Data {
        guard let pending, pending.connection == connection, ProcessInfo.processInfo.systemUptime < expires else {
            throw RemoteFault.expired
        }
        let secret = try PairingProof.randomSecret()
        try secrets.put(secret, account: pending.device.id.uuidString)
        var updated = devices
        updated.append(pending.device)
        do { try PrivateFiles.write(updated, to: metadata) }
        catch { try? secrets.remove(pending.device.id.uuidString); throw error }
        devices = updated; self.pending = nil; expires = 0
        return secret
    }

    public func verify(device: UUID, nonce: Data, proof: Data) throws -> Bool {
        guard devices.contains(where: { $0.id == device }), let secret = try secrets.get(device.uuidString) else { return false }
        return DeviceProof.verify(secret: secret, device: device, nonce: nonce, proof: proof)
    }

    public func contains(_ id: UUID) -> Bool { devices.contains { $0.id == id } }

    public func revoke(_ id: UUID) throws {
        // Remove authorization metadata first; failure deleting the secret must not restore access.
        let updated = devices.filter { $0.id != id }
        devices = updated
        var failed = false
        do { try PrivateFiles.write(updated, to: metadata) } catch { failed = true }
        do { try secrets.remove(id.uuidString) } catch { failed = true }
        if failed { throw RemoteFault.storageFailure }
    }
}
