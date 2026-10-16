import Foundation
import PiRemoteClient
import PiRemoteCore
import PiRemoteSecurity
import XCTest
@testable import PiRemote

private final class IntegrationSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@MainActor final class LocalHostIntegrationTests: XCTestCase {
    private struct Fixture: Decodable { var code: PairingCode; var directory: String }
    private let root = URL(fileURLWithPath: "/tmp/pi-remote-simulator-fixture", isDirectory: true)

    private func mark(_ stage: String) throws {
        try stage.write(to: root.appendingPathComponent("progress"), atomically: true, encoding: .utf8)
    }

    private func state(_ client: RemoteClient) async throws -> HostSnapshot {
        guard case .snapshot(let value) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
        return value
    }
    private func page(_ client: RemoteClient, id: UUID?, cursor: UUID? = nil) async throws -> DirectoryPage {
        guard case .directories(let page) = try await client.request(.directories(id: id, cursor: cursor)) else { throw RemoteFault.invalidRequest }
        return page
    }
    private func child(_ name: String, in initial: DirectoryPage, client: RemoteClient) async throws -> DirectoryItem {
        var listing = initial
        while true {
            if let item = listing.items.first(where: { $0.name == name }) { return item }
            guard let cursor = listing.next else { throw RemoteFault.staleDirectory }
            listing = try await page(client, id: initial.id, cursor: cursor)
        }
    }

    private func restart(_ client: RemoteClient, mac: SavedMac, epoch: UUID) async throws -> HostSnapshot {
        await client.disconnect()
        try Data().write(to: root.appendingPathComponent("restart"))
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: root.appendingPathComponent("ready.json")),
               let current = try? JSONDecoder().decode(UUID.self, from: data), current != epoch {
                try await client.connect(mac)
                return try await state(client)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RemoteFault.unavailable
    }

    // Run only with the explicit, short-lived provider fixture. Normal app tests make no provider requests.
    func testSimulatorCodingReconnectStopAndHostRestoration() async throws {
        let file = root.appendingPathComponent("pairing.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("Start SimulatorHostFixture explicitly to run the provider integration check.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        defer { try? Data().write(to: root.appendingPathComponent("stop")) }
        XCTAssertGreaterThan(fixture.code.expires.timeIntervalSinceNow, 0)
        try mark("pairing")
        let secrets = IntegrationSecrets()
        let client = RemoteClient(secrets: secrets)
        let suite = "PiRemote.Integration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PhoneModel(defaults: defaults, connection: client, authenticate: { _ in true })
        defer { model.lock() }
        try JSONEncoder().encode(model.device).write(to: root.appendingPathComponent("expected-device.json"), options: .atomic)
        model.scene(.active)
        for _ in 0..<200 where model.locked { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.locked)
        model.pairingText = try fixture.code.encoded()
        model.pair()
        for _ in 0..<300 where model.pairing || !model.connected { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.pairing)
        XCTAssertTrue(model.connected)
        XCTAssertNil(model.fault)
        let mac = try XCTUnwrap(model.saved.first)
        XCTAssertEqual(model.selectedMac, mac.id)
        let restoredModel = PhoneModel(defaults: defaults, connection: client, authenticate: { _ in true })
        XCTAssertEqual(restoredModel.saved, [mac])
        XCTAssertEqual(restoredModel.selectedMac, mac.id)
        XCTAssertEqual(restoredModel.device, model.device)
        XCTAssertTrue(restoredModel.locked)
        try mark("paired and saved through PhoneModel")
        do {
            try mark("connected")
            var listing = try await page(client, id: nil)
            try mark("home listed")
            for _ in 0..<32 {
                guard let parent = listing.parent else { break }
                listing = try await page(client, id: parent)
                try mark("parent listed")
            }
            XCTAssertNil(listing.parent)
            let expected = URL(fileURLWithPath: fixture.directory).resolvingSymlinksInPath().path
            for component in expected.split(separator: "/").map(String.init) {
                let item = try await child(component, in: listing, client: client)
                XCTAssertTrue(item.isDirectory)
                listing = try await page(client, id: item.id)
            }
            XCTAssertEqual(URL(fileURLWithPath: listing.path).resolvingSymlinksInPath().path, expected)
            try mark("nested directory selected")
            _ = try await model.request(.createSession(directory: listing.id))
            let created = try await state(client)
            for _ in 0..<200 where model.state?.selected != created.selected { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(model.state?.selected, created.selected)
            let session = try XCTUnwrap(created.selected)
            XCTAssertEqual(created.sessions.first(where: { $0.id == session })?.directory, expected)
            let prompt = "First read image.png in the current directory with the read tool. Then create a file named result.swift containing exactly: let simulatorResult = 42 followed by a newline. Use the write tool. Then reply DONE."
            model.text = prompt
            model.send(context: created.context)
            for _ in 0..<300 where model.sending { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.sending)
            XCTAssertEqual(model.text, "")
            XCTAssertNil(model.fault)
            try mark("coding task accepted through PhoneModel")
            let running = try await state(client)
            XCTAssertTrue(running.working)
            await client.disconnect()
            try await Task.sleep(for: .milliseconds(300))
            try await client.connect(mac)
            var completed = try await state(client)
            for _ in 0..<600 where completed.working {
                try await Task.sleep(for: .milliseconds(200))
                completed = try await state(client)
            }
            XCTAssertFalse(completed.working)
            XCTAssertEqual(completed.selected, session)
            XCTAssertEqual(completed.messages.filter { $0.role == "user" && $0.text == prompt }.count, 1)
            XCTAssertFalse(completed.messages.contains { $0.isError })
            XCTAssertTrue(completed.messages.contains { $0.role == "tool" })
            let output = try XCTUnwrap(completed.messages.compactMap(\.images).flatMap { $0 }.first)
            XCTAssertNil(output.fault)
            guard case .image(let image) = try await client.request(.outputImage(id: output.id)) else { throw RemoteFault.invalidRequest }
            XCTAssertEqual(image.data, try Data(contentsOf: URL(fileURLWithPath: expected).appendingPathComponent("image.png")))
            let decoded = try OutputImageDecoder.decode(image, fullResolution: true)
            XCTAssertEqual(decoded.width, 32); XCTAssertEqual(decoded.height, 32)
            XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: expected).appendingPathComponent("result.swift"), encoding: .utf8), "let simulatorResult = 42\n")
            try mark("coding task complete")
            let files = try await page(client, id: listing.id)
            let result = try await child("result.swift", in: files, client: client)
            guard case .preview(let preview) = try await client.request(.preview(id: result.id)) else { throw RemoteFault.invalidRequest }
            XCTAssertEqual(preview.text, "let simulatorResult = 42\n")
            for _ in 0..<100 where !model.connected { try await Task.sleep(for: .milliseconds(20)) }
            model.text = "Keep this draft"
            try model.attachText(preview, context: completed.context)
            XCTAssertTrue(model.text.hasPrefix("Keep this draft\n\nFile: result.swift"))
            XCTAssertTrue(model.text.contains("let simulatorResult = 42"))
            XCTAssertFalse(model.sending)
            let afterAttachment = try await state(client)
            XCTAssertEqual(afterAttachment.messages, completed.messages)
            model.text = ""
            _ = try await client.request(.prompt(text: "List integers 1 through 10000, one per line. Do not use tools.", delivery: .prompt, image: nil))
            _ = try await client.request(.prompt(text: "Reply STEERING.", delivery: .steer, image: nil))
            _ = try await client.request(.prompt(text: "Reply FOLLOWUP.", delivery: .followUp, image: nil))
            _ = try await client.request(.stop)
            let stopped = try await state(client)
            XCTAssertFalse(stopped.working)
            try mark("stopped; restarting host")
            let restarted = try await restart(client, mac: mac, epoch: stopped.epoch)
            XCTAssertNotEqual(restarted.epoch, stopped.epoch)
            XCTAssertEqual(restarted.host, stopped.host)
            _ = try await client.request(.resumeSession(id: session))
            let restored = try await state(client)
            XCTAssertEqual(restored.selected, session)
            XCTAssertEqual(restored.sessions.first(where: { $0.id == session })?.directory, expected)
            XCTAssertFalse(restored.working)
            let restoredImage = try XCTUnwrap(restored.messages.compactMap(\.images).flatMap { $0 }.first)
            guard case .image(let restoredAttachment) = try await client.request(.outputImage(id: restoredImage.id)) else { throw RemoteFault.invalidRequest }
            XCTAssertEqual(restoredAttachment, image)
            XCTAssertEqual(restored.messages.filter { $0.role == "user" && $0.text == prompt }.count, 1)
            let interruption = "List integers 10001 through 20000, one per line. Do not use tools."
            _ = try await client.request(.prompt(text: interruption, delivery: .prompt, image: nil))
            let active = try await state(client)
            XCTAssertTrue(active.working)
            let afterInterruption = try await restart(client, mac: mac, epoch: active.epoch)
            XCTAssertEqual(afterInterruption.sessions.first(where: { $0.id == session })?.interrupted, true)
            XCTAssertNil(afterInterruption.selected)
            _ = try await client.request(.resumeSession(id: session))
            let reviewed = try await state(client)
            XCTAssertFalse(reviewed.working)
            XCTAssertEqual(reviewed.sessions.first(where: { $0.id == session })?.interrupted, true)
            XCTAssertEqual(reviewed.messages.filter { $0.role == "user" && $0.text == interruption }.count, 1)
            try await Task.sleep(for: .seconds(1))
            let unchanged = try await state(client)
            XCTAssertFalse(unchanged.working)
            XCTAssertEqual(unchanged.messages, reviewed.messages)
            await client.disconnect()
            try Data().write(to: root.appendingPathComponent("stop"))
        } catch {
            await client.disconnect()
            try? Data().write(to: root.appendingPathComponent("stop"))
            throw error
        }
    }
}
