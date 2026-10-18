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
        NSApp.activate()
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

    func testClickAllowlistRejectsExecutionCredentialsAndArbitraryTargets() throws {
        for target in MacDebugClickTarget.allCases {
            XCTAssertNoThrow(try MacDebugInteraction(action: "click", value: target.rawValue).validate())
        }
        for target in ["desktop-send", "mac-stop", "mac-new-session", "mac-debug-banner-disable", "mac-settings-access-toggle", "extension-dialog-confirm", "arbitrary", ""] {
            XCTAssertThrowsError(try MacDebugInteraction(action: "click", value: target).validate())
        }
    }

    func testNativeClickPressesOneEnabledVisibleButtonWithoutEchoingItsTarget() async throws {
        try await fixture { model, window, _ in
            let receiver = ClickReceiver()
            let button = NSButton(title: "Fixture control", target: receiver, action: #selector(ClickReceiver.press))
            button.frame = NSRect(x: 20, y: 20, width: 160, height: 28)
            button.setAccessibilityIdentifier(MacDebugClickTarget.sidebar.rawValue)
            window.contentView!.addSubview(button)
            window.contentView!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let before = model.state
            let result: Data
            do { result = try apply("click", MacDebugClickTarget.sidebar.rawValue, model, window) }
            catch {
                XCTFail("Native fixture click rejected: enabled=\(button.isAccessibilityEnabled()), role=\(String(describing: button.accessibilityRole())), frame=\(button.accessibilityFrame()), visible=\(window.convertToScreen(window.contentView!.convert(window.contentView!.visibleRect, to: nil))), calls=\(receiver.count)")
                return
            }
            XCTAssertEqual(receiver.count, 1)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: result) as? [String: String], ["action": "click", "outcome": "applied"])
            XCTAssertFalse(String(decoding: result, as: UTF8.self).contains("mac-sidebar-toggle"))
            XCTAssertEqual(model.state, before)
            XCTAssertFalse(model.listening)
            button.isEnabled = false
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            button.isEnabled = true; button.isHidden = true
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            button.isHidden = false
            button.frame.origin.x = window.contentView!.bounds.maxX + 20
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            button.frame.origin.x = 20
            let duplicate = NSButton(title: "Duplicate", target: receiver, action: #selector(ClickReceiver.press))
            duplicate.frame = NSRect(x: 20, y: 70, width: 160, height: 28)
            duplicate.setAccessibilityIdentifier("mac-sidebar-toggle")
            window.contentView!.addSubview(duplicate)
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            XCTAssertEqual(receiver.count, 1, "Unavailable or ambiguous controls must not dispatch")
        }
    }

    func testVirtualClickChecksParentOwnershipHiddenAncestorsClippingAndNodeBudget() async throws {
        try await fixture { model, window, _ in
            let container = VirtualClickContainer(frame: NSRect(x: 10, y: 10, width: 250, height: 150))
            window.contentView!.addSubview(container)
            let element = VirtualClickElement()
            element.setAccessibilityIdentifier("mac-sidebar-toggle")
            element.setAccessibilityRole(.button)
            element.setAccessibilityEnabled(true)
            element.reportedParent = container
            element.setAccessibilityFrame(window.convertToScreen(NSRect(x: 30, y: 30, width: 100, height: 24)))
            container.elements = [element]
            try apply("click", "mac-sidebar-toggle", model, window)
            XCTAssertEqual(element.calls, 1)
            container.elements = [element, element]
            try apply("click", "mac-sidebar-toggle", model, window)
            XCTAssertEqual(element.calls, 2, "Repeated references to one AX element must press only once")
            let duplicate = VirtualClickElement()
            duplicate.setAccessibilityIdentifier("mac-sidebar-toggle")
            duplicate.setAccessibilityRole(.button)
            duplicate.setAccessibilityEnabled(true)
            duplicate.reportedParent = container
            duplicate.setAccessibilityFrame(element.accessibilityFrame())
            container.elements = [element, duplicate]
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window), "Different virtual controls are ambiguous even at the same frame")
            XCTAssertEqual(element.calls, 2)
            XCTAssertEqual(duplicate.calls, 0)
            container.elements = [element]
            element.setAccessibilityHidden(true)
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            element.setAccessibilityHidden(false)
            container.isHidden = true
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            container.isHidden = false
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            element.reportedParent = other.contentView
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window), "A stale in-window frame does not prove ownership")
            element.reportedParent = nil
            try apply("click", "mac-sidebar-toggle", model, window)
            XCTAssertEqual(element.calls, 3, "A parentless virtual control needs the content view's own hit-test proof")
            element.reportedParent = container
            container.clipsToBounds = true
            element.setAccessibilityFrame(window.convertToScreen(NSRect(x: 300, y: 30, width: 100, height: 24)))
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            element.setAccessibilityFrame(window.convertToScreen(NSRect(x: 30, y: 30, width: 100, height: 24)))
            container.elements = Array(repeating: element, count: 8_193)
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            XCTAssertEqual(element.calls, 3)
        }
    }

    func testCancellationDuringNativeResolutionCannotDispatchAfterward() async throws {
        try await fixture { model, window, _ in
            let container = DelayedClickContainer(frame: NSRect(x: 10, y: 10, width: 250, height: 150))
            window.contentView!.addSubview(container)
            let receiver = ClickReceiver()
            let button = NSButton(title: "Cancelled fixture", target: receiver, action: #selector(ClickReceiver.press))
            button.frame = NSRect(x: 20, y: 20, width: 160, height: 28)
            button.setAccessibilityIdentifier("mac-sidebar-toggle")
            container.addSubview(button)
            container.delay = 0.2
            let ready = container.ready
            let resolving = Task { @MainActor in
                try model.debug.interact(MacDebugInteraction(action: "click", value: "mac-sidebar-toggle"), model: model, windows: [window], appHidden: false)
            }
            let cancellation = Task.detached {
                guard waitForClickResolution(ready) else { return false }
                resolving.cancel()
                return true
            }
            let result = await resolving.result
            let cancelled = await cancellation.value
            XCTAssertTrue(cancelled)
            if case .success = result { XCTFail("Cancelled resolution must fail before native dispatch") }
            XCTAssertEqual(receiver.count, 0)
        }
    }

    func testNativeResolutionDeadlineCannotDispatchAfterASlowAccessor() async throws {
        try await fixture { model, window, _ in
            let container = DelayedClickContainer(frame: NSRect(x: 10, y: 10, width: 250, height: 150))
            window.contentView!.addSubview(container)
            let receiver = ClickReceiver()
            let button = NSButton(title: "Expired fixture", target: receiver, action: #selector(ClickReceiver.press))
            button.frame = NSRect(x: 20, y: 20, width: 160, height: 28)
            button.setAccessibilityIdentifier("mac-sidebar-toggle")
            container.addSubview(button)
            container.delay = 1.1
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            XCTAssertEqual(receiver.count, 0)
        }
    }

    func testClickCannotUseAnotherWindowOrBypassProtectedSurfacesAndDisable() async throws {
        try await fixture { model, window, _ in
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            let receiver = ClickReceiver()
            let button = NSButton(title: "Other control", target: receiver, action: #selector(ClickReceiver.press))
            button.frame = NSRect(x: 20, y: 20, width: 160, height: 28)
            button.setAccessibilityIdentifier("mac-sidebar-toggle")
            other.contentView!.addSubview(button)
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            button.removeFromSuperview()
            window.contentView!.addSubview(button)
            model.code = "PRIVATE PAIRING"
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            model.code = ""
            model.panel = "dialog"
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            model.panel = nil
            model.debug.disable()
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            XCTAssertEqual(receiver.count, 0)
        }
    }

    func testHostedProductNativeToolbarClicksAndSemanticPanelsDoNotStartPi() async throws {
        try await fixture { model, window, _ in
            model.interfaceMode = .desktop
            // Use the product environment, not a test-only AX override.
            window.contentView = NSHostingView(rootView: CompanionWindow(model: model))
            window.contentView!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            @MainActor func click(_ identifier: String) throws {
                try self.apply("click", identifier, model, window)
            }
            XCTAssertFalse(model.sidebarVisible)
            try click("mac-sidebar-toggle")
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertTrue(model.sidebarVisible)
            XCTAssertEqual(model.destination, .conversation)
            try click("mac-sidebar-toggle")
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertFalse(model.sidebarVisible)
            XCTAssertEqual(model.destination, .conversation)
            XCTAssertThrowsError(try apply("click", "mac-files", model, window), "Files needs an actual context")
            // Use the semantic picker route when SwiftUI does not expose body buttons to AX.
            try apply("panel", "resume", model, window)
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(model.panel, "resume")
            XCTAssertThrowsError(try apply("click", "mac-sidebar-toggle", model, window))
            try apply("panel", "close", model, window)
            try await Task.sleep(for: .milliseconds(180))
            try click("mac-commands")
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(model.panel, "commands")
            try apply("panel", "close", model, window)
            XCTAssertNil(model.state.selected)
            XCTAssertFalse(model.listening)
            XCTAssertEqual(model.state.messages.count, 0)
            let runtime = await model.coordinator?.state()
            XCTAssertNil(runtime?.selected)
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
            XCTAssertThrowsError(try apply("inspector", "Files", model, window))
            model.destination = .workspace("/tmp")
            try apply("inspector", "Activity", model, window)
            XCTAssertEqual(section, "Activity", "An empty Activity tab explains the missing loaded session")
            XCTAssertEqual(model.destination, .workspace("/tmp"))
            try apply("inspector", "Session", model, window)
            XCTAssertEqual(section, "Session")
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
        try await fixture { model, window, root in
            window.contentView = NSHostingView(rootView: CompanionWindow(model: model))
            window.contentView!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            try apply("navigate", "settings", model, window)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(model.destination, .settings)
            try apply("scroll", "page_down", model, window)
            try apply("scroll", "page_up", model, window)
            XCTAssertThrowsError(try apply("inspector", "Activity", model, window))
            model.destination = .workspace(root.path)
            try await Task.sleep(for: .milliseconds(180))
            try apply("inspector", "Session", model, window)
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

private final class VirtualClickElement: NSAccessibilityElement {
    weak var reportedParent: NSObject?
    override func accessibilityParent() -> Any? { reportedParent }
    var calls = 0
    override func accessibilityPerformPress() -> Bool { calls += 1; return true }
}

@MainActor private class VirtualClickContainer: NSView {
    var elements: [Any] = []
    override func accessibilityChildren() -> [Any]? { elements }
}

@MainActor private final class DelayedClickContainer: NSView {
    let ready = DispatchSemaphore(value: 0)
    var delay: TimeInterval = 0
    override func accessibilityChildren() -> [Any]? {
        if delay > 0 { ready.signal(); Thread.sleep(forTimeInterval: delay) }
        return super.accessibilityChildren()
    }
}

@MainActor private final class ClickReceiver: NSObject {
    var count = 0
    @objc func press(_ sender: Any?) { count += 1 }
}

private func waitForClickResolution(_ ready: DispatchSemaphore) -> Bool {
    ready.wait(timeout: .now() + 2) == .success
}

@MainActor private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
