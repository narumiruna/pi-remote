import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class InteractionSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor final class MacDebugInteractionTests: XCTestCase {
    private func fixture(_ body: (CompanionModel, NSWindow, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        let root = URL(fileURLWithPath: "/private/tmp/prdi-" + UUID().uuidString.prefix(10))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "PiRemote.DebugInteraction." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = CompanionModel(support: root.appendingPathComponent("support"), secrets: InteractionSecrets(), defaults: defaults,
                                   debugDirectory: root.appendingPathComponent("debug"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(MacDebugWindowMarker.Marker(frame: NSRect(x: 0, y: 0, width: 1, height: 1)))
        window.makeKeyAndOrderFront(nil)
        model.debug.enable(model: model)
        do { try await body(model, window, root) }
        catch { window.close(); await model.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root); throw error }
        window.close()
        await model.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult private func apply(_ action: String, _ value: String, _ model: CompanionModel, _ window: NSWindow) throws -> Data {
        try model.debug.interact(MacDebugInteraction(action: action, value: value), model: model, windows: [window], appHidden: false)
    }

    func testStrictActionValuesAndTextBounds() throws {
        for (action, values) in ["navigate": ["conversation", "overview", "settings", "devices"], "interface_mode": ["pi", "desktop"],
                                 "sidebar": ["show", "hide"], "inspector": ["Files", "Session", "Activity", "hide"],
                                 "panel": ["commands", "resume", "palette", "hotkeys", "directory", "workspace", "close"],
                                 "focus_editor": ["editor"], "scroll": ["history_up", "history_down", "history_top", "history_bottom", "dock_up", "dock_down", "page_up", "page_down"]] {
            for value in values { XCTAssertNoThrow(try MacDebugInteraction(action: action, value: value).validate()) }
        }
        XCTAssertNoThrow(try MacDebugInteraction(action: "type_text", value: String(repeating: "a", count: 2048)).validate())
        for (action, value) in [("send", "prompt"), ("navigate", "/private"), ("panel", "pairingQR"), ("panel", "dialog"), ("interface_mode", "other"),
                                ("type_text", ""), ("type_text", "\0"), ("type_text", String(repeating: "你", count: 683))] {
            XCTAssertThrowsError(try MacDebugInteraction(action: action, value: value).validate())
        }
    }

    func testNavigationAppearanceAndSidebarDoNotMutateRuntimeDraftOrNetwork() async throws {
        try await fixture { model, window, _ in
            let before = model.state
            model.text = "Keep private draft"
            for destination in ["settings", "devices", "overview", "conversation"] { try apply("navigate", destination, model, window) }
            try apply("interface_mode", "desktop", model, window)
            XCTAssertEqual(model.interfaceMode, .desktop)
            try apply("interface_mode", "pi", model, window)
            try apply("sidebar", "show", model, window)
            XCTAssertTrue(model.sidebarVisible)
            try apply("sidebar", "hide", model, window)
            XCTAssertFalse(model.sidebarVisible)
            XCTAssertEqual(model.state, before)
            XCTAssertEqual(model.text, "Keep private draft")
            XCTAssertFalse(model.listening)
        }
    }

    func testDisabledAndProtectedStatesCannotMutateUI() async throws {
        try await fixture { model, window, _ in
            model.destination = .overview
            model.debug.disable()
            XCTAssertThrowsError(try apply("navigate", "settings", model, window))
            model.debug.enable(model: model)
            model.code = "PRIVATE-PAIRING"
            XCTAssertThrowsError(try apply("navigate", "settings", model, window))
            model.code = ""
            model.state.dialogs = [ExtensionDialog(id: "pending", method: "input", title: "Secret", message: "", options: [], text: "", expires: nil)]
            XCTAssertThrowsError(try apply("navigate", "settings", model, window))
            model.state.dialogs = []
            model.editorOffer = EditorOffer(id: UUID(), session: nil, text: "private")
            XCTAssertThrowsError(try apply("navigate", "settings", model, window))
            model.editorOffer = nil
            let secure = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
            window.contentView!.addSubview(secure)
            XCTAssertThrowsError(try apply("navigate", "settings", model, window))
            secure.removeFromSuperview()
            model.openingSession = true
            XCTAssertThrowsError(try apply("navigate", "settings", model, window))
            model.openingSession = false
            XCTAssertEqual(model.destination, .overview)
        }
    }

    func testOrdinaryPanelsCanCloseButProtectedPanelsCannot() async throws {
        try await fixture { model, window, _ in
            try apply("panel", "commands", model, window)
            XCTAssertEqual(model.panel, "commands")
            XCTAssertThrowsError(try apply("navigate", "settings", model, window))
            try apply("panel", "close", model, window)
            XCTAssertNil(model.panel)
            for panel in ["dialog", "pairingQR", "compact", "export"] {
                model.panel = panel
                XCTAssertThrowsError(try apply("panel", "close", model, window))
                XCTAssertEqual(model.panel, panel)
            }
            model.panel = nil
        }
    }

    func testInspectorUsesWindowOwnedPresentationHook() async throws {
        try await fixture { model, window, _ in
            let marker = try XCTUnwrap(window.contentView?.subviews.first as? MacDebugWindowMarker.Marker)
            var section = ""
            marker.selectInspector = { section = $0; model.inspectorVisible = true }
            try apply("inspector", "Activity", model, window)
            XCTAssertEqual(section, "Activity")
            XCTAssertTrue(model.inspectorVisible)
            try apply("inspector", "hide", model, window)
            XCTAssertFalse(model.inspectorVisible)
        }
    }

    func testNativeTextAppendsWithoutSubmittingOrEchoingAndSupportsUndo() async throws {
        try await fixture { model, window, _ in
            let session = SessionInfo(id: UUID(), title: "fixture", directory: "/tmp")
            model.state.sessions = [session]; model.state.selected = session.id; model.state.phase = "idle"
            model.destination = .conversation
            model.text = "existing "
            var submits = 0
            let host = NSHostingView(rootView: PiEditor(text: Binding(get: { model.text }, set: { model.text = $0 }),
                                                       contextID: model.state.epoch.uuidString + session.id.uuidString,
                                                       onSubmit: { _ in submits += 1 }, onStop: {}))
            window.contentView = host
            host.addSubview(MacDebugWindowMarker.Marker(frame: NSRect(x: 0, y: 0, width: 1, height: 1)))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let result = try apply("type_text", "private debug text\n", model, window)
            XCTAssertEqual(model.text, "existing private debug text\n")
            XCTAssertEqual(submits, 0)
            XCTAssertFalse(String(decoding: result, as: UTF8.self).contains("private debug text"))
            let native = try XCTUnwrap(find(PiEditorNativeView.self, in: host))
            native.editor.undoManager?.undo()
            XCTAssertEqual(model.text, "existing ")
            model.text = "newer draft before native update"
            XCTAssertThrowsError(try apply("type_text", "must not overwrite", model, window))
            XCTAssertEqual(model.text, "newer draft before native update")
            model.text = native.editor.string
            model.state.selected = UUID()
            XCTAssertThrowsError(try apply("type_text", "stale session", model, window))
            model.state.selected = session.id
            model.state.phase = "unavailable"
            XCTAssertThrowsError(try apply("type_text", "cannot append", model, window))
        }
    }

    func testScrollOnlyIdentifiedNativeContentAndBounds() async throws {
        try await fixture { model, window, _ in
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            scroll.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 500, height: 2000))
            window.contentView!.addSubview(scroll)
            XCTAssertThrowsError(try apply("scroll", "history_down", model, window))
            scroll.identifier = NSUserInterfaceItemIdentifier("pi-debug-history")
            try apply("scroll", "history_down", model, window)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
            try apply("scroll", "history_bottom", model, window)
            XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView!.bounds.maxY, accuracy: 1)
            try apply("scroll", "history_top", model, window)
            XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        }
    }

    func testHostedProductNavigationInspectorPanelsAndPageScroll() async throws {
        try await fixture { model, window, _ in
            window.contentView = NSHostingView(rootView: CompanionWindow(model: model))
            window.contentView!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            try apply("navigate", "settings", model, window)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(model.destination, .settings)
            try apply("scroll", "page_down", model, window)
            try apply("scroll", "page_up", model, window)
            try apply("inspector", "Activity", model, window)
            XCTAssertTrue(model.inspectorVisible)
            try apply("inspector", "hide", model, window)
            try apply("panel", "hotkeys", model, window)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertNotNil(window.attachedSheet)
            try apply("panel", "close", model, window)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertNil(window.attachedSheet)
            try apply("navigate", "devices", model, window)
            try await Task.sleep(for: .milliseconds(200))
            try apply("scroll", "page_down", model, window)
            XCTAssertEqual(model.destination, .devices)
            XCTAssertFalse(model.listening)
            XCTAssertNil(model.state.selected)
        }
    }

    func testForeignConfirmationSheetCannotBeClosedThroughOrdinaryPanelState() async throws {
        try await fixture { model, window, _ in
            model.panel = "hotkeys"
            let confirmation = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
            confirmation.isReleasedWhenClosed = false
            window.beginSheet(confirmation)
            defer { window.endSheet(confirmation); confirmation.close(); model.panel = nil }
            XCTAssertThrowsError(try apply("panel", "close", model, window))
            XCTAssertEqual(model.panel, "hotkeys")
            XCTAssertTrue(window.attachedSheet === confirmation)
        }
    }

    func testQueuedSocketInteractionCannotSurviveDisableAndReenable() async throws {
        try await fixture { model, _, root in
            model.destination = .overview
            let directory = root.appendingPathComponent("debug")
            let sent = DispatchSemaphore(value: 0)
            let pending = Task.detached {
                try await MacDebugTestClient.request(directory: directory, operation: "interact",
                                                     interaction: MacDebugInteraction(action: "navigate", value: "settings"),
                                                     onSent: { sent.signal() })
            }
            // Keep MainActor occupied until bytes have reached the socket, then revoke
            // before the queued UI handler can run. No sleeps or UI-loop pumping.
            XCTAssertEqual(sent.wait(timeout: .now() + 2), .success)
            model.debug.disable()
            model.debug.enable(model: model)
            _ = try? await pending.value
            XCTAssertEqual(model.destination, .overview)
            XCTAssertTrue(model.debug.enabled)
        }
    }

    func testActualSocketInteractionAndRevocation() async throws {
        try await fixture { model, _, root in
            let directory = root.appendingPathComponent("debug")
            let bytes = try await MacDebugTestClient.request(directory: directory, operation: "interact",
                                                            interaction: MacDebugInteraction(action: "navigate", value: "settings"))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual(model.destination, .settings)
            XCTAssertEqual(response["result"] as? [String: String], ["action": "navigate", "outcome": "applied"])
            model.debug.disable()
            XCTAssertThrowsError(try model.debug.interact(MacDebugInteraction(action: "navigate", value: "devices"), model: model))
            XCTAssertEqual(model.destination, .settings)
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
}

@MainActor private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
