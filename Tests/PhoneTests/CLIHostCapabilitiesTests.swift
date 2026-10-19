import Foundation
import PiRemoteClient
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import UIKit
import XCTest
@testable import PiRemote

private final class CLIPhoneSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}

@MainActor final class CLIHostCapabilitiesTests: XCTestCase {
    private let capabilities = ["directories", "directory-path", "sessions", "prompt", "steering", "follow-up", "stop", "models", "thinking", "extension-dialogs", "thinking-display", "close-session"]

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func elements(_ root: UIView) -> [NSObject] {
        var pending: [NSObject] = descendants(root)
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = [], index = 0
        while index < pending.count, seen.count < 4096 {
            let item = pending[index]; index += 1
            guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
            result.append(item)
            pending += item.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
            pending += item.automationElements?.compactMap { $0 as? NSObject } ?? []
            let count = item.accessibilityElementCount()
            if count > 0, count < 256 {
                for child in 0..<count {
                    if let value = item.accessibilityElement(at: child) as? NSObject { pending.append(value) }
                }
            }
        }
        return result
    }
    private func labels(_ view: some View) async throws -> Set<String> {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: view.environment(\.accessibilityEnabled, true))
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.rootViewController = controller; window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.makeKeyAndVisible(); controller.view.frame = window.bounds
        var result = Set<String>()
        for _ in 0..<8 {
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            result.formUnion(elements(controller.view).compactMap(\.accessibilityLabel))
            guard let scroll = descendants(controller.view).compactMap({ $0 as? UIScrollView }).max(by: { $0.bounds.height < $1.bounds.height }) else { break }
            let end = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            if scroll.contentOffset.y >= end - 1 { break }
            scroll.setContentOffset(CGPoint(x: 0, y: min(end, scroll.contentOffset.y + scroll.bounds.height * 0.7)), animated: false)
        }
        return result
    }

    func testReducedCapabilitiesHideDeferredSessionActionsAndKeepNativeActions() async throws {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        let session = UUID(); state.selected = session
        state.sessions = [SessionInfo(id: session, title: "CLI fixture", directory: "/fixture/project")]
        state.models = [ModelOption(provider: "fixture", model: "model", name: "Fixture model")]
        state.thinkingLevels = ["off", "high"]
        state.capabilities = capabilities
        let cli = try await labels(NavigationStack {
            SessionControls(state: state, request: { _ in XCTFail("Rendering must not dispatch"); return .ok }, preview: { _ in XCTFail("Rendering must not preview") })
        })
        XCTAssertTrue(cli.contains("Close Pi session"))
        for label in ["Rename", "Compact context", "Clone session", "Working tree diff", "Pi changelog", "Cycle model", "Cycle thinking level", "Review and export session", "Session tokens and cost"] {
            XCTAssertFalse(cli.contains(where: { $0 == label || $0.hasPrefix(label + ", ") }), "Deferred CLI control: " + label)
        }
        state.capabilities = HostSnapshot(host: state.host, epoch: state.epoch).capabilities
        let native = try await labels(NavigationStack {
            SessionControls(state: state, request: { _ in XCTFail("Rendering must not dispatch"); return .ok }, preview: { _ in })
        })
        for label in ["Rename", "Compact context", "Clone session", "Working tree diff"] {
            XCTAssertTrue(native.contains(where: { $0 == label || $0.hasPrefix(label + ", ") }), "Native host control must remain: " + label)
        }
    }

    private struct Fixture: Decodable {
        var pairingCode: String
        var cwd: String
        var controlDirectory: String
        var verificationFile: String?
    }
    private struct Approval: Encodable { var device: UUID }
    private func state(_ client: RemoteClient) async throws -> HostSnapshot {
        guard case .snapshot(let value) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
        return value
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("CLI phone fixture timed out")
        throw RemoteFault.unavailable
    }

    /// Explicit fixture only. This does not make provider requests or bypass host approval.
    func testProductionPhonePairProjectCodingAndReconnect() async throws {
        let path = URL(fileURLWithPath: "/tmp/pi-remote-cli-simulator-fixture/config.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Start the explicit TypeScript CLI simulator fixture first.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        let secrets = CLIPhoneSecrets(), client = RemoteClient(secrets: secrets)
        let suite = "PiRemote.CLI.Phone." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PhoneModel(defaults: defaults, connection: client, authenticate: { _ in true })
        defer { model.lock() }
        let control = URL(fileURLWithPath: fixture.controlDirectory)
        try PrivateFiles.write(Approval(device: model.device), to: control.appendingPathComponent("approve.json"))
        model.scene(.active)
        try await wait { !model.locked }
        model.pairingText = fixture.pairingCode; model.pair()
        try await wait { !model.pairing && model.connected }
        XCTAssertNil(model.fault)
        let saved = try XCTUnwrap(model.saved.first)
        let initial = try await state(client)
        XCTAssertNil(initial.selected)
        XCTAssertFalse(initial.capabilities.contains("file-preview"))
        XCTAssertFalse(initial.capabilities.contains("clone"))
        guard case .directories(let root) = try await model.request(.directories(id: nil, cursor: nil)),
              let nested = root.items.first(where: { $0.isDirectory && $0.fault == nil }) else { throw RemoteFault.invalidRequest }
        XCTAssertEqual(root.path, fixture.cwd)
        guard case .directories(let project) = try await model.request(.directories(id: nested.id, cursor: nil)) else { throw RemoteFault.invalidRequest }
        _ = try await model.request(.createSession(directory: project.id))
        try await wait { model.state?.selected != nil }
        let selected = try XCTUnwrap(model.state?.selected)
        model.text = "CLI fixture: write acceptance.txt with CLI acceptance\n"
        model.send(context: try XCTUnwrap(model.state).context)
        try await wait { !model.sending && model.text.isEmpty }
        await client.disconnect()
        try await client.connect(saved)
        var completed = try await state(client)
        for _ in 0..<400 where completed.working || !completed.messages.contains(where: { $0.role == "assistant" && !$0.streaming }) {
            try await Task.sleep(for: .milliseconds(25)); completed = try await state(client)
        }
        XCTAssertFalse(completed.working)
        XCTAssertEqual(completed.selected, selected)
        XCTAssertEqual(completed.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertTrue(completed.messages.contains { $0.role == "assistant" && !$0.streaming })
        let file = URL(fileURLWithPath: fixture.verificationFile ?? project.path + "/acceptance.txt")
        try await wait { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "CLI acceptance\n")
        await client.disconnect()
    }
}
