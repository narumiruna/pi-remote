import Darwin
import Foundation
import PiRemoteCore

final class InstanceLease: @unchecked Sendable {
    private var descriptor: Int32 = -1
    init(support: URL) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(support.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RemoteFault.storageFailure }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw RemoteFault.conflict }
        self.descriptor = descriptor
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}
