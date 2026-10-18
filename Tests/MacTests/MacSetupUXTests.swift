import Foundation
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity
import XCTest

private final class SetupSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws { XCTFail("Setup presentation must not write credentials") }
    func remove(_ account: String) throws { XCTFail("Setup presentation must not revoke credentials") }
}

@MainActor final class MacSetupUXTests: XCTestCase {
    private func withModel(_ body: @MainActor (CompanionModel, UserDefaults) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.SetupUX." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: SetupSecrets(), defaults: defaults)
        XCTAssertNil(model.startupError)
        do { try await body(model, defaults) }
        catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    private func address(_ ip: String, name: String) throws -> ListenAddress {
        var value = try XCTUnwrap(ListenAddress.all().first, "A native interface is needed to construct the public value fixture")
        value.address = ip; value.name = name
        return value
    }

    func testRefreshRetainsSelectionPairingsDraftAndRuntime() async throws {
        let lan = try address("10.0.0.2", name: "fixture-lan")
        let tailscale = try address("100.64.0.2", name: "fixture-tailscale")
        try await withModel { model, _ in
            model.addresses = [lan]; model.address = lan.address
            model.devices = [PairedDevice(id: UUID(), name: "Saved fixture phone")]
            model.text = "Keep the current draft"
            let state = model.state
            let devices = model.devices
            let runtime = await model.coordinator?.state()
            model.refreshListenAddresses([lan, tailscale])
            XCTAssertEqual(model.addresses, [lan, tailscale])
            XCTAssertEqual(model.address, lan.address)
            XCTAssertEqual(model.devices, devices)
            XCTAssertEqual(model.text, "Keep the current draft")
            XCTAssertEqual(model.state, state)
            XCTAssertFalse(model.listening)
            XCTAssertFalse(model.starting)
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testRefreshDropsRemovedAddressAndHandlesNoAvailableAddresses() async throws {
        let lan = try address("10.0.0.2", name: "fixture-lan")
        let tailscale = try address("100.64.0.2", name: "fixture-tailscale")
        let loopback = try address("127.0.0.1", name: "fixture-loopback")
        try await withModel { model, _ in
            model.addresses = [lan]; model.address = lan.address
            model.refreshListenAddresses([loopback, tailscale])
            XCTAssertEqual(model.address, tailscale.address)
            model.refreshListenAddresses([loopback])
            XCTAssertEqual(model.address, loopback.address)
            model.refreshListenAddresses([])
            XCTAssertEqual(model.addresses, [])
            XCTAssertEqual(model.address, "")
            model.startNetwork()
            XCTAssertFalse(model.starting, "No address must not begin identity or listener setup")
        }
    }

    func testRefreshCannotChangeAListeningStartingOrShuttingDownHost() async throws {
        let lan = try address("10.0.0.2", name: "fixture-lan")
        try await withModel { model, _ in
            model.addresses = [lan]; model.address = lan.address
            model.listening = true
            model.refreshListenAddresses([])
            XCTAssertEqual(model.addresses, [lan]); XCTAssertEqual(model.address, lan.address)
            model.listening = false; model.starting = true
            model.refreshListenAddresses([])
            XCTAssertEqual(model.addresses, [lan]); XCTAssertEqual(model.address, lan.address)
            model.starting = false
            await model.shutdown()
            model.refreshListenAddresses([])
            XCTAssertEqual(model.addresses, [lan]); XCTAssertEqual(model.address, lan.address)
        }
    }

    func testInspectorContextDoesNotClearSavedVisibilityOnGlobalNavigation() async throws {
        try await withModel { model, defaults in
            model.inspectorVisible = true
            for destination in [MacDestination.overview, .settings, .devices, .conversation] {
                model.destination = destination
                XCTAssertFalse(model.hasInspectorContext)
                XCTAssertTrue(model.inspectorVisible)
            }
            let session = SessionInfo(id: UUID(), title: "Saved fixture", directory: "/tmp/setup-fixture")
            model.state.sessions = [session]
            model.destination = .workspace(session.directory)
            XCTAssertTrue(model.hasInspectorContext)
            model.destination = .session(session.id)
            XCTAssertTrue(model.hasInspectorContext)
            model.destination = .settings
            XCTAssertFalse(model.hasInspectorContext)
            model.state.selected = session.id
            XCTAssertTrue(model.hasInspectorContext, "Explicit session controls can identify the loaded session on another page")
            let saved = try XCTUnwrap(defaults.data(forKey: "workspacePreferences"))
            let preferences = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            XCTAssertEqual(preferences["inspectorVisible"] as? Bool, true)
        }
    }
}
