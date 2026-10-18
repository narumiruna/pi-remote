import Foundation
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity
import XCTest

private final class DeviceIdentitySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var removals: [String] = []

    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws {
        lock.withLock { values.removeValue(forKey: account); removals.append(account) }
    }
    var removedAccounts: [String] { lock.withLock { removals } }
}

@MainActor final class MacDeviceIdentityTests: XCTestCase {
    // These IDs share every character except the last. Full IDs remain distinct.
    private let first = PairedDevice(id: UUID(uuidString: "12345678-1234-1234-1234-123456789AB1")!, name: "iPhone")
    private let second = PairedDevice(id: UUID(uuidString: "12345678-1234-1234-1234-123456789AB2")!, name: "iPhone")

    func testDuplicateNamesIncludeIdentityWithoutDisclosure() {
        let unique = PairedDevice(id: UUID(), name: "Other phone")
        let devices = [first, second, unique]
        XCTAssertEqual(MacDeviceIdentity.label(for: first, in: devices), "iPhone · " + first.id.uuidString)
        XCTAssertEqual(MacDeviceIdentity.label(for: second, in: devices), "iPhone · " + second.id.uuidString)
        XCTAssertEqual(MacDeviceIdentity.label(for: unique, in: devices), unique.name)
    }

    func testFullDeviceIDsRemainDistinctWithCollidingPrefixesAndReorderedRows() {
        XCTAssertEqual(first.id.uuidString.prefix(35), second.id.uuidString.prefix(35))
        let firstLabel = MacDeviceIdentity.label(for: first, in: [first, second])
        let secondLabel = MacDeviceIdentity.label(for: second, in: [first, second])
        XCTAssertNotEqual(firstLabel, secondLabel)
        XCTAssertEqual(firstLabel, MacDeviceIdentity.label(for: first, in: [second, first]))
        XCTAssertEqual(secondLabel, MacDeviceIdentity.label(for: second, in: [second, first]))
        XCTAssertTrue(firstLabel.contains(first.id.uuidString))
        XCTAssertTrue(secondLabel.contains(second.id.uuidString))
    }

    func testConfirmationIdentifiesCapturedNameAndFullIdentity() {
        let captured = MacDeviceRevocationConsent(first)
        let message = MacDeviceRevocationConsent.message(for: first)
        XCTAssertEqual(captured.device, first)
        XCTAssertTrue(message.contains(first.name))
        XCTAssertTrue(message.contains(first.id.uuidString))
        XCTAssertFalse(message.contains(second.id.uuidString))
        XCTAssertTrue(message.contains("Pi work will continue"))
    }

    func testCancelPreservesDisposableCredentialsConnectionStateAndPiState() async throws {
        try await withFixture { model, secrets, _, _ in
            let state = model.state
            let runtime = await model.coordinator?.state()
            let connections = model.connectedDevices
            let firstSecret = try secrets.get(self.first.id.uuidString)
            let secondSecret = try secrets.get(self.second.id.uuidString)
            var consent = MacDeviceRevocationConsent(self.first)
            consent.cancel()
            consent.confirm(in: model)
            await Task.yield()
            XCTAssertNil(consent.device)
            XCTAssertTrue(secrets.removedAccounts.isEmpty)
            XCTAssertEqual(try secrets.get(self.first.id.uuidString), firstSecret)
            XCTAssertEqual(try secrets.get(self.second.id.uuidString), secondSecret)
            XCTAssertEqual(model.devices, [self.first, self.second])
            XCTAssertEqual(model.connectedDevices, connections)
            XCTAssertEqual(model.state, state)
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testConfirmRevokesOnlyCapturedDisposableDeviceAfterDismissalAndListReorder() async throws {
        try await withFixture { model, secrets, _, metadata in
            let state = model.state
            let runtime = await model.coordinator?.state()
            let survivorSecret = try secrets.get(self.second.id.uuidString)
            var pending = MacDeviceRevocationConsent(self.first)
            let displayed = try XCTUnwrap(pending.device)
            // SwiftUI can clear the presentation binding before it runs the button action.
            pending.cancel()
            var consent = MacDeviceRevocationConsent(displayed)
            model.devices.reverse()
            XCTAssertEqual(consent.device, self.first)
            consent.confirm(in: model)
            try await self.waitUntil { model.devices == [self.second] }
            XCTAssertNil(consent.device)
            XCTAssertNil(try secrets.get(self.first.id.uuidString))
            XCTAssertEqual(try secrets.get(self.second.id.uuidString), survivorSecret)
            XCTAssertEqual(secrets.removedAccounts, [self.first.id.uuidString])
            let persisted = try DeviceRegistry(secrets: secrets, metadata: metadata)
            let remaining = await persisted.list()
            XCTAssertEqual(remaining, [self.second])
            XCTAssertEqual(model.state, state, "Revocation must not change Pi execution state")
            XCTAssertEqual(model.text, "Keep the fixture draft")
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testRemovedTargetCannotRetargetSameNameDevice() async throws {
        try await withFixture { model, secrets, registry, _ in
            var consent = MacDeviceRevocationConsent(self.first)
            try await registry.revoke(self.first.id)
            model.devices = await registry.list()
            let removals = secrets.removedAccounts
            consent.confirm(in: model)
            await Task.yield()
            XCTAssertNil(consent.device)
            XCTAssertEqual(model.devices, [self.second])
            XCTAssertEqual(secrets.removedAccounts, removals)
            XCTAssertNotNil(try secrets.get(self.second.id.uuidString))
        }
    }

    func testChangedNameRequiresFreshConsent() async throws {
        try await withFixture { model, secrets, _, _ in
            var consent = MacDeviceRevocationConsent(self.first)
            model.devices[0].name = "Changed fixture name"
            XCTAssertEqual(consent.device?.name, "iPhone")
            consent.confirm(in: model)
            await Task.yield()
            XCTAssertTrue(secrets.removedAccounts.isEmpty)
            XCTAssertNotNil(try secrets.get(self.first.id.uuidString))
            XCTAssertNotNil(try secrets.get(self.second.id.uuidString))
        }
    }

    private func withFixture(
        _ body: @MainActor (CompanionModel, DeviceIdentitySecrets, DeviceRegistry, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let suite = "PiRemote.DeviceIdentityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let secrets = DeviceIdentitySecrets()
        let metadata = root.appendingPathComponent("devices.json")
        let registry = try DeviceRegistry(secrets: secrets, metadata: metadata)
        // Approve private credentials directly. Do not start a listener or a Pi process.
        for device in [first, second] {
            let connection = UUID()
            let grant = try await registry.openWindow()
            _ = try await registry.request(connection: connection, device: device.id, name: device.name, grant: grant)
            _ = try await registry.approve(connection: connection)
        }
        defaults.set(root.appendingPathComponent("unused-pi").path, forKey: "piExecutable")
        let model = CompanionModel(support: root, secrets: secrets, defaults: defaults, debugDirectory: root.appendingPathComponent("debug"))
        XCTAssertNil(model.startupError)
        model.devices = await registry.list()
        model.connectedDevices = [first.id, second.id]
        model.text = "Keep the fixture draft"
        // Synthetic work checks that consent never changes the displayed execution state.
        model.state.selected = UUID()
        model.state.phase = "streaming"
        do { try await body(model, secrets, registry, metadata) }
        catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for disposable device revocation")
        throw RemoteFault.unavailable
    }
}
