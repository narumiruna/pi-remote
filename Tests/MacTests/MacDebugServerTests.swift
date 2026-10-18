import Darwin
import Foundation
import XCTest

@MainActor final class MacDebugServerTests: XCTestCase {
    func testValidOperationsPrivateModesAndCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.server.start { operation in try JSONSerialization.data(withJSONObject: ["operation": operation]) }
        XCTAssertTrue(fixture.server.isRunning)
        let endpoint = try fixture.endpoint()
        XCTAssertEqual(endpoint.version, 1)
        XCTAssertEqual(endpoint.token.count, 64)
        XCTAssertNotNil(endpoint.token.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        for (name, mode): (String, mode_t) in [("", 0o700), ("endpoint.json", 0o600), ("control.sock", 0o600), ("server.lock", 0o600)] {
            var info = stat()
            XCTAssertEqual(lstat(fixture.directory.appendingPathComponent(name).path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, mode)
            XCTAssertEqual(info.st_uid, geteuid())
        }
        for operation in ["status", "capture"] {
            let id = UUID().uuidString
            let response = try await fixture.request(operation: operation, id: id)
            XCTAssertEqual(response["id"] as? String, id)
            XCTAssertEqual(response["version"] as? Int, 1)
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual((response["result"] as? [String: String])?["operation"], operation)
        }
        let unrelated = fixture.directory.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: unrelated)
        fixture.server.stop()
        fixture.server.stop()
        XCTAssertFalse(fixture.server.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("endpoint.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("server.lock").path))
    }

    func testInteractionEnvelopeValidationDoesNotForwardInvalidActions() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var calls = 0
        try fixture.server.start(handlingRequest: { _, interaction in
            calls += 1
            XCTAssertEqual(interaction?.action, "navigate")
            return Data("{\"action\":\"navigate\",\"outcome\":\"applied\"}".utf8)
        })
        var base = try fixture.requestObject(operation: "interact")
        base["interaction"] = ["action": "navigate", "value": "settings"]
        let valid = try await fixture.exchange(JSONSerialization.data(withJSONObject: base) + [10])
        XCTAssertEqual(valid["ok"] as? Bool, true)
        for fields in [["action": "send", "value": "prompt"], ["action": "navigate", "value": "settings", "extra": "private"],
                       ["action": "type_text", "value": String(repeating: "a", count: 2049)]] {
            var invalid = base
            invalid["interaction"] = fields
            let response = try await fixture.exchange(JSONSerialization.data(withJSONObject: invalid) + [10])
            XCTAssertEqual(response["error"] as? String, "invalid_interaction")
        }
        base["unexpected"] = "private"
        let extra = try await fixture.exchange(JSONSerialization.data(withJSONObject: base) + [10])
        XCTAssertEqual(extra["error"] as? String, "invalid_interaction")
        XCTAssertEqual(calls, 1)
    }

    func testAuthenticationVersionAndOperationRejections() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var calls = 0
        try fixture.server.start { _ in calls += 1; return Data("{}".utf8) }
        let endpoint = try fixture.endpoint()
        let base: [String: Any] = ["version": 1, "id": UUID().uuidString, "token": endpoint.token, "operation": "status"]
        for (key, value, expected) in [
            ("token", "" as Any, "unauthorized"),
            ("token", String(repeating: "0", count: 64) as Any, "unauthorized"),
            ("token", NSNull() as Any, "unauthorized"),
            ("version", 2 as Any, "unsupported_version"),
            ("operation", "send_prompt" as Any, "unsupported_operation")
        ] {
            var object = base
            object[key] = value
            let response = try await fixture.exchange(try JSONSerialization.data(withJSONObject: object) + [10])
            XCTAssertEqual(response["error"] as? String, expected)
            XCTAssertEqual(response["ok"] as? Bool, false)
        }
        var missing = base
        missing.removeValue(forKey: "token")
        let response = try await fixture.exchange(try JSONSerialization.data(withJSONObject: missing) + [10])
        XCTAssertEqual(response["error"] as? String, "unauthorized")
        XCTAssertEqual(calls, 0)
    }

    func testMalformedRecordsNeverReflectUnvalidatedInput() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.server.start { _ in XCTFail("Malformed request reached handler"); return Data("{}".utf8) }
        let records = [Data("not-json\n".utf8), Data("[]\n".utf8), Data([0xff, 10]),
                       Data("{\"id\":\"sensitive-fixture\"}\n".utf8), Data("{}\n{}\n".utf8)]
        for record in records {
            let response = try await fixture.exchange(record)
            XCTAssertEqual(response["error"] as? String, "invalid_request")
            XCTAssertTrue(response["id"] is NSNull)
            XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!.contains("sensitive-fixture"))
        }
        var object = try fixture.requestObject()
        object["version"] = true
        let response = try await fixture.exchange(try JSONSerialization.data(withJSONObject: object) + [10])
        XCTAssertEqual(response["error"] as? String, "invalid_request")
    }

    func testRequestBoundaryAndFragmentedIO() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.server.start { _ in Data("{}".utf8) }
        let record = try JSONSerialization.data(withJSONObject: fixture.requestObject())
        let exactly = record + Data(repeating: 32, count: 4095 - record.count) + [10]
        let endpoint = try fixture.endpoint()
        let bytes = try await Task.detached {
            let client = try DebugTestClient(endpoint.socketPath)
            for offset in stride(from: 0, to: exactly.count, by: 17) {
                try client.send(exactly.subdata(in: offset..<min(offset + 17, exactly.count)))
            }
            return try client.receive()
        }.value
        XCTAssertEqual(try decode(bytes)["ok"] as? Bool, true)
        let over = record + Data(repeating: 32, count: 4096 - record.count) + [10]
        let response = try await fixture.exchange(over)
        XCTAssertEqual(response["error"] as? String, "request_too_large")
    }

    func testPartialRecordAndHandlerDeadlinesCancelWork() async throws {
        let fixture = try Fixture(deadline: 0.15)
        defer { fixture.clean() }
        var cancelled = false
        try fixture.server.start { _ in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled = true; throw error }
            return Data("{}".utf8)
        }
        let partial = try await fixture.exchange(Data("{".utf8))
        XCTAssertEqual(partial["error"] as? String, "timeout")
        let response = try await fixture.request()
        XCTAssertEqual(response["error"] as? String, "timeout")
        try await waitUntil { cancelled }
    }

    func testDisconnectCancelsHandlerAndReleasesClient() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var started = false
        var cancelled = false
        try fixture.server.start { _ in
            started = true
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled = true; throw error }
            return Data("{}".utf8)
        }
        let endpoint = try fixture.endpoint()
        let request = try JSONSerialization.data(withJSONObject: fixture.requestObject()) + [10]
        let client = try await Task.detached {
            let client = try DebugTestClient(endpoint.socketPath)
            try client.send(request)
            return client
        }.value
        try await waitUntil { started }
        client.close()
        try await waitUntil { cancelled }
    }

    func testClientLimitAndRecovery() async throws {
        let fixture = try Fixture(deadline: 1)
        defer { fixture.clean() }
        try fixture.server.start { _ in Data("{}".utf8) }
        let endpoint = try fixture.endpoint()
        let clients = try await Task.detached {
            try (0..<4).map { _ in try DebugTestClient(endpoint.socketPath) }
        }.value
        defer { clients.forEach { $0.close() } }
        // The serial listener admits these connections before the fifth connection.
        let response = try await fixture.request()
        XCTAssertEqual(response["error"] as? String, "busy")
        clients[0].close()
        try await Task.sleep(for: .milliseconds(40))
        let recovered = try await fixture.request()
        XCTAssertEqual(recovered["ok"] as? Bool, true)
    }

    func testResultsAreObjectsBoundedAndErrorsAreSafe() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        enum SecretError: Error { case sensitiveFixture }
        for (result, expected) in [(Data("[]".utf8), "invalid_result"),
                                   (Data("not-json".utf8), "invalid_result"),
                                   (Data(repeating: 32, count: 3 * 1024 * 1024 + 1), "response_too_large")] {
            try fixture.server.start { _ in result }
            let response = try await fixture.request()
            XCTAssertEqual(response["error"] as? String, expected)
            fixture.server.stop()
        }
        try fixture.server.start { _ in throw SecretError.sensitiveFixture }
        let unknown = try await fixture.request()
        XCTAssertEqual(unknown["error"] as? String, "operation_failed")
        fixture.server.stop()
        try fixture.server.start { _ in throw MacDebugServer.OperationError.captureProtected }
        let safe = try await fixture.request()
        XCTAssertEqual(safe["error"] as? String, "capture_protected")
    }

    func testLargeResponsePartialWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let large = try JSONSerialization.data(withJSONObject: ["image": String(repeating: "x", count: 2 * 1024 * 1024)])
        try fixture.server.start { _ in large }
        let response = try await fixture.request(operation: "capture")
        XCTAssertEqual((response["result"] as? [String: String])?["image"]?.count, 2 * 1024 * 1024)
    }

    func testSlowReaderDeadline() async throws {
        let fixture = try Fixture(deadline: 0.3)
        defer { fixture.clean() }
        let large = try JSONSerialization.data(withJSONObject: ["image": String(repeating: "x", count: 2 * 1024 * 1024)])
        try fixture.server.start { operation in operation == "capture" ? large : Data("{}".utf8) }
        let endpoint = try fixture.endpoint()
        let request = try JSONSerialization.data(withJSONObject: fixture.requestObject(operation: "capture")) + [10]
        let clients = try await Task.detached {
            try (0..<4).map { _ in
                let client = try DebugTestClient(endpoint.socketPath)
                try client.send(request)
                return client
            }
        }.value
        defer { clients.forEach { $0.close() } }
        try await Task.sleep(for: .milliseconds(500))
        let recovered = try await fixture.request()
        XCTAssertEqual(recovered["ok"] as? Bool, true)
    }

    func testStopRevokesInFlightWorkAndReenableRotatesToken() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var continuation: CheckedContinuation<Data, Never>?
        try fixture.server.start { _ in await withCheckedContinuation { continuation = $0 } }
        let first = try fixture.endpoint()
        let request = try JSONSerialization.data(withJSONObject: fixture.requestObject()) + [10]
        let pending = Task.detached {
            let client = try DebugTestClient(first.socketPath)
            try client.send(request)
            return try client.receive()
        }
        try await waitUntil { continuation != nil }
        fixture.server.stop()
        try fixture.server.start { _ in Data("{\"new\":true}".utf8) }
        let second = try fixture.endpoint()
        XCTAssertNotEqual(first.token, second.token)
        continuation?.resume(returning: Data("{\"stale\":true}".utf8))
        let revoked = try await pending.value
        XCTAssertTrue(revoked.isEmpty)
        var old = try fixture.requestObject()
        old["token"] = first.token
        let denied = try await fixture.exchange(try JSONSerialization.data(withJSONObject: old) + [10])
        XCTAssertEqual(denied["error"] as? String, "unauthorized")
        let current = try await fixture.request()
        XCTAssertEqual((current["result"] as? [String: Bool])?["new"], true)
    }

    func testLiveCollisionAndStaleOwnedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let socketPath = fixture.directory.appendingPathComponent("control.sock").path
        let stale = try DebugTestClient.makeSocket(at: socketPath)
        Darwin.close(stale)
        XCTAssertEqual(chmod(socketPath, 0o600), 0)
        let endpointPath = fixture.directory.appendingPathComponent("endpoint.json").path
        try Data("stale".utf8).write(to: URL(fileURLWithPath: endpointPath))
        XCTAssertEqual(chmod(endpointPath, 0o600), 0)
        try fixture.server.start { _ in Data("{}".utf8) }
        let token = try fixture.endpoint().token
        let second = MacDebugServer(directory: fixture.directory)
        XCTAssertThrowsError(try second.start { _ in Data("{}".utf8) }) { error in
            XCTAssertEqual(error as? MacDebugServer.Failure, .alreadyRunning)
        }
        second.stop()
        XCTAssertEqual(try fixture.endpoint().token, token)
        let response = try await fixture.request()
        XCTAssertEqual(response["ok"] as? Bool, true)
    }

    func testRejectsSymlinksForDirectoryAncestorsAndArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let alias = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
        for path in [alias, alias.appendingPathComponent("nested")] {
            let server = MacDebugServer(directory: path)
            XCTAssertThrowsError(try server.start { _ in Data("{}".utf8) })
        }
        let target = fixture.directory.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        for name in ["endpoint.json", "control.sock", "server.lock"] {
            let link = fixture.directory.appendingPathComponent(name)
            if name == "server.lock" { try FileManager.default.removeItem(at: link) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try fixture.server.start { _ in Data("{}".utf8) })
            XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
            var info = stat()
            XCTAssertEqual(lstat(link.path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
            try FileManager.default.removeItem(at: link)
        }
    }

    func testRejectsUnsafeModesHardlinksAndUnexpectedTypes() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        XCTAssertEqual(chmod(fixture.directory.path, 0o755), 0)
        XCTAssertThrowsError(try fixture.server.start { _ in Data("{}".utf8) })
        XCTAssertEqual(chmod(fixture.directory.path, 0o700), 0)
        let target = fixture.directory.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        for name in ["endpoint.json", "server.lock"] {
            let link = fixture.directory.appendingPathComponent(name)
            if name == "server.lock" { try FileManager.default.removeItem(at: link) }
            XCTAssertEqual(Darwin.link(target.path, link.path), 0)
            XCTAssertThrowsError(try fixture.server.start { _ in Data("{}".utf8) })
            XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
            try FileManager.default.removeItem(at: link)
        }
        for name in ["endpoint.json", "server.lock"] {
            let unsafe = fixture.directory.appendingPathComponent(name)
            try Data("keep".utf8).write(to: unsafe)
            XCTAssertEqual(chmod(unsafe.path, 0o644), 0)
            XCTAssertThrowsError(try fixture.server.start { _ in Data("{}".utf8) })
            XCTAssertEqual(try Data(contentsOf: unsafe), Data("keep".utf8))
            try FileManager.default.removeItem(at: unsafe)
        }
        let regularSocket = fixture.directory.appendingPathComponent("control.sock")
        try Data("keep".utf8).write(to: regularSocket)
        XCTAssertEqual(chmod(regularSocket.path, 0o600), 0)
        XCTAssertThrowsError(try fixture.server.start { _ in Data("{}".utf8) })
        XCTAssertEqual(try Data(contentsOf: regularSocket), Data("keep".utf8))
        try FileManager.default.removeItem(at: regularSocket)
        let endpoint = fixture.directory.appendingPathComponent("endpoint.json")
        try FileManager.default.createDirectory(at: endpoint, withIntermediateDirectories: false)
        XCTAssertThrowsError(try fixture.server.start { _ in Data("{}".utf8) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpoint.path))
    }

    func testForeignOwnershipRejectedWhenPrivilegeAllows() throws {
        guard geteuid() == 0 else { throw XCTSkip("Changing a fixture to another owner requires root.") }
        let fixture = try Fixture()
        defer { fixture.clean() }
        let endpoint = fixture.directory.appendingPathComponent("endpoint.json")
        try Data("foreign".utf8).write(to: endpoint)
        XCTAssertEqual(chmod(endpoint.path, 0o600), 0)
        XCTAssertEqual(chown(endpoint.path, 65534, 65534), 0)
        XCTAssertThrowsError(try fixture.server.start { _ in Data("{}".utf8) })
        XCTAssertEqual(try Data(contentsOf: endpoint), Data("foreign".utf8))
    }

    func testRejectsWritableAncestorAndLongPath() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let child = fixture.directory.appendingPathComponent("child")
        XCTAssertEqual(chmod(fixture.directory.path, 0o777), 0)
        let server = MacDebugServer(directory: child)
        XCTAssertThrowsError(try server.start { _ in Data("{}".utf8) })
        XCTAssertEqual(chmod(fixture.directory.path, 0o700), 0)
        let long = MacDebugServer(directory: fixture.directory.appendingPathComponent(String(repeating: "x", count: 100)))
        XCTAssertThrowsError(try long.start { _ in Data("{}".utf8) }) { error in
            XCTAssertEqual(error as? MacDebugServer.Failure, .pathTooLong)
        }
    }

    func testCleanupPreservesReplacedArtifact() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.server.start { _ in Data("{}".utf8) }
        let endpoint = fixture.directory.appendingPathComponent("endpoint.json")
        let saved = fixture.directory.appendingPathComponent("saved")
        try FileManager.default.moveItem(at: endpoint, to: saved)
        try Data("replacement".utf8).write(to: endpoint)
        fixture.server.stop()
        XCTAssertEqual(try Data(contentsOf: endpoint), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct DebugTestEndpoint: Decodable, Sendable {
    let version: Int
    let socketPath: String
    let token: String
}

@MainActor private final class Fixture {
    let directory: URL
    let server: MacDebugServer
    init(deadline: TimeInterval = 5) throws {
        // Resolve Darwin's /var and /tmp aliases before server path validation.
        directory = URL(fileURLWithPath: "/private/tmp/prd-\(UUID().uuidString.prefix(12))", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(.EIO) }
        server = MacDebugServer(directory: directory, testDeadline: deadline)
    }
    func clean() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    func endpoint() throws -> DebugTestEndpoint {
        try JSONDecoder().decode(DebugTestEndpoint.self, from: Data(contentsOf: directory.appendingPathComponent("endpoint.json")))
    }
    func requestObject(operation: String = "status", id: String = UUID().uuidString) throws -> [String: Any] {
        ["version": 1, "id": id, "token": try endpoint().token, "operation": operation]
    }
    func request(operation: String = "status", id: String = UUID().uuidString) async throws -> [String: Any] {
        try await exchange(JSONSerialization.data(withJSONObject: requestObject(operation: operation, id: id)) + [10])
    }
    func exchange(_ record: Data) async throws -> [String: Any] {
        let endpoint = try endpoint()
        let data = try await Task.detached {
            let client = try DebugTestClient(endpoint.socketPath)
            try client.send(record)
            return try client.receive()
        }.value
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private typealias DebugTestClient = MacDebugTestClient

/// Blocking test IO is used only in detached tasks. The lock makes close idempotent.
final class MacDebugTestClient: @unchecked Sendable {
    static func request(directory: URL, operation: String = "status", token: String? = nil,
                        interaction: MacDebugInteraction? = nil, onSent: (@Sendable () -> Void)? = nil) async throws -> Data {
        try await Task.detached {
            let endpoint = try JSONDecoder().decode(DebugTestEndpoint.self, from: Data(contentsOf: directory.appendingPathComponent("endpoint.json")))
            let client = try MacDebugTestClient(endpoint.socketPath)
            var request: [String: Any] = ["version": 1, "id": UUID().uuidString, "token": token ?? endpoint.token, "operation": operation]
            if let interaction { request["interaction"] = ["action": interaction.action, "value": interaction.value] }
            try client.send(JSONSerialization.data(withJSONObject: request) + [10])
            onSent?()
            return try client.receive()
        }.value
    }
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = Self.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
    }
    deinit { close() }
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed { closed = true; Darwin.close(fd) }
    }
    func send(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }
    func receive() throws -> Data {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(.EIO) }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
            if bytes.prefix(count).contains(10) { return data }
            guard data.count <= 3 * 1024 * 1024 else { throw POSIXError(.EIO) }
        }
    }
    static func makeSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        return fd
    }
    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        return address
    }
}
