import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class InterfaceModeSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor final class MacInterfaceModeTests: XCTestCase {
    func testPrivatePreferenceDefaultsFallbackAndRoundTrip() async throws {
        try await withDefaults { defaults, root in
            XCTAssertEqual(MacInterfaceMode.allCases.map(\.label), ["Pi", "Desktop"])
            XCTAssertEqual(EnvironmentValues().macInterfaceMode, .pi)
            for saved in [nil, "unknown", "Desktop", ""] as [String?] {
                if let saved { defaults.set(saved, forKey: "macInterfaceMode") }
                else { defaults.removeObject(forKey: "macInterfaceMode") }
                let model = self.makeModel(defaults, root: root)
                XCTAssertEqual(model.interfaceMode, .pi)
                XCTAssertEqual(defaults.string(forKey: "macInterfaceMode"), saved, "Loading must not rewrite an invalid preference.")
                await model.shutdown()
            }
            defaults.set(42, forKey: "macInterfaceMode")
            let invalid = self.makeModel(defaults, root: root)
            XCTAssertEqual(invalid.interfaceMode, .pi)
            await invalid.shutdown()
            for mode in MacInterfaceMode.allCases {
                let model = self.makeModel(defaults, root: root)
                model.interfaceMode = mode
                XCTAssertEqual(defaults.string(forKey: "macInterfaceMode"), mode.rawValue)
                await model.shutdown()
                let restored = self.makeModel(defaults, root: root)
                XCTAssertEqual(restored.interfaceMode, mode)
                await restored.shutdown()
            }
        }
    }

    func testPreferenceChangesOnlyItsKeyAndPreservesBusyDialogAndModelState() async throws {
        try await withDefaults { defaults, root in
            let model = self.makeModel(defaults, root: root)
            do {
                let session = SessionInfo(id: UUID(), title: "Interface fixture", directory: root.path)
                model.state.sessions = [session]
                model.state.selected = session.id
                model.destination = .session(session.id)
                model.text = String(repeating: "Unsent fixture draft\n", count: 300)
                model.delivery = .followUp
                model.state.extensionDisplay = ExtensionDisplayState(
                    statuses: [ExtensionStatus(id: "fixture", text: "Fixture status")],
                    widgets: [ExtensionWidget(id: "above", text: "Above input", placement: .aboveEditor),
                              ExtensionWidget(id: "below", text: "Below input", placement: .belowEditor)],
                    notices: [ExtensionNotice(id: "warning", text: "Fixture warning", severity: .warning)])
                model.sidebarVisible = true
                model.inspectorVisible = true
                model.confirmResend = true
                model.fault = .unknownOutcome
                model.editorOffer = EditorOffer(id: UUID(), session: session.id, text: "Keep this offer")
                let coordinator = try XCTUnwrap(model.coordinator)
                let hostBefore = await coordinator.state()
                for phase in ["idle", "working", "streaming", "waiting", "recovering", "unavailable"] {
                    model.state.phase = phase
                    model.state.model = "fixture-model-" + phase
                    model.state.dialogs = [ExtensionDialog(id: "pending", method: "confirm", title: "Keep request", message: "Synthetic request", options: [], text: "", expires: nil)]
                    model.panel = phase == "waiting" ? "dialog" : "model"
                    let state = model.state
                    let draft = model.text
                    let offer = model.editorOffer
                    let preferences = defaults.dictionaryRepresentation().filter { $0.key != "macInterfaceMode" } as NSDictionary
                    for mode in MacInterfaceMode.allCases.reversed() {
                        model.interfaceMode = mode
                        XCTAssertEqual(model.state, state)
                        XCTAssertEqual(model.text, draft)
                        XCTAssertEqual(model.destination, .session(session.id))
                        XCTAssertEqual(model.delivery, .followUp)
                        XCTAssertEqual(model.panel, phase == "waiting" ? "dialog" : "model")
                        XCTAssertTrue(model.sidebarVisible)
                        XCTAssertTrue(model.inspectorVisible)
                        XCTAssertTrue(model.confirmResend)
                        XCTAssertEqual(model.fault, .unknownOutcome)
                        XCTAssertEqual(model.editorOffer?.id, offer?.id)
                        XCTAssertEqual(model.editorOffer?.session, offer?.session)
                        XCTAssertEqual(model.editorOffer?.text, offer?.text)
                        XCTAssertFalse(model.sending)
                        XCTAssertFalse(model.openingSession)
                        XCTAssertNil(model.closingSession)
                        XCTAssertFalse(model.listening)
                        XCTAssertEqual(defaults.dictionaryRepresentation().filter { $0.key != "macInterfaceMode" } as NSDictionary, preferences)
                    }
                }
                let hostAfter = await coordinator.state()
                XCTAssertEqual(hostAfter, hostBefore, "Appearance must not dispatch a runtime action.")
            } catch { await model.shutdown(); throw error }
            await model.shutdown()
        }
    }

    func testVisibleNativeSwitchSupportsPointerKeyboardAndRetainsWorkflowAtBothWidths() async throws {
        try await withDefaults { defaults, root in
            let model = self.makeModel(defaults, root: root)
            do {
                let session = SessionInfo(id: UUID(), title: "Native switch fixture", directory: root.path)
                model.state.sessions = [session]
                model.state.selected = session.id
                model.destination = .conversation
                model.state.phase = "working"
                model.text = "Keep this unsent draft"
                for width: CGFloat in [900, 1300] {
                    model.interfaceMode = .pi
                    try await self.hosted(CompanionWindow(model: model), width: width) { host, window in
                        let control = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSSegmentedControl }.first {
                            $0.accessibilityIdentifier() == "mac-interface-mode"
                        })
                        XCTAssertEqual(control.segmentCount, 2)
                        XCTAssertEqual(control.label(forSegment: 0), "Pi")
                        XCTAssertEqual(control.label(forSegment: 1), "Desktop")
                        XCTAssertEqual(control.accessibilityLabel(), "Interface appearance")
                        XCTAssertTrue(control.isEnabled)
                        XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
                        XCTAssertTrue(host.visibleRect.contains(control.convert(control.bounds, to: host)))
                        for id in ["mac-files", "mac-commands", "mac-session-switcher-toggle", "mac-command-palette-toggle", "mac-close-focused-session", "mac-inspector-toggle", "mac-remote-access"] {
                            let element = try self.accessibilityElement(id, in: host)
                            let frame = try self.accessibilityFrame(element)
                            XCTAssertTrue(window.convertToScreen(host.visibleRect).contains(frame), "Hidden toolbar control at width \(width): \(id) \(frame)")
                        }
                        let editor = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                        editor.setSelectedRange(NSRange(location: 5, length: 4))
                        let original = model.state
                        try await self.click(control, fraction: 0.75, window: window)
                        XCTAssertEqual(model.interfaceMode, .desktop)
                        XCTAssertEqual(control.selectedSegment, 1)
                        XCTAssertEqual(defaults.string(forKey: "macInterfaceMode"), "desktop")
                        XCTAssertTrue(window.makeFirstResponder(control))
                        try await self.key("\u{f702}", code: 123, window: window)
                        XCTAssertEqual(model.interfaceMode, .pi)
                        XCTAssertEqual(control.selectedSegment, 0)
                        model.state.model = "changed-fixture-model"
                        let changed = model.state
                        try await self.key("\u{f703}", code: 124, window: window)
                        XCTAssertEqual(model.interfaceMode, .desktop)
                        XCTAssertEqual(model.state, changed)
                        XCTAssertEqual(model.state.context, original.context)
                        XCTAssertEqual(model.text, "Keep this unsent draft")
                        XCTAssertNil(model.panel)
                        XCTAssertFalse(model.sending)
                        let retained = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                        XCTAssertTrue(retained === editor)
                        XCTAssertEqual(retained.selectedRange(), NSRange(location: 5, length: 4))
                        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                            window.appearance = NSAppearance(named: appearance)
                            model.interfaceMode = .pi
                            try await Task.sleep(for: .milliseconds(100))
                            XCTAssertEqual(retained.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
                            model.interfaceMode = .desktop
                            try await Task.sleep(for: .milliseconds(100))
                            XCTAssertEqual(retained.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), appearance)
                            XCTAssertEqual(retained.string, "Keep this unsent draft")
                        }
                    }
                }
            } catch { await model.shutdown(); throw error }
            await model.shutdown()
        }
    }

    func testDesktopColorsResolveForSystemLightAndDarkAppearance() throws {
        let theme = MacInterfaceTheme(mode: .desktop)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertEqual(theme.nativeText, NSColor.labelColor)
                let foreground = theme.nativeText.usingColorSpace(.deviceRGB)!
                let background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!
                XCTAssertGreaterThan(abs(foreground.brightnessComponent - background.brightnessComponent), 0.4)
            }
        }
    }

    private func makeModel(_ defaults: UserDefaults, root: URL) -> CompanionModel {
        let model = CompanionModel(support: root.appendingPathComponent(UUID().uuidString), secrets: InterfaceModeSecrets(), defaults: defaults)
        XCTAssertNil(model.startupError)
        return model
    }

    private func withDefaults(_ body: @MainActor (UserDefaults, URL) async throws -> Void) async throws {
        let suite = "PiRemote.InterfaceModeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try await body(defaults, root)
    }

    private func hosted<V: View>(_ view: V, width: CGFloat, exercise: (NSView, NSWindow) async throws -> Void) async throws {
        let controller = NSHostingController(rootView: view.environment(\.accessibilityEnabled, true).frame(width: width, height: 650))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 650))
        defer {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.contentViewController = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutSubtreeIfNeeded()
        try await exercise(controller.view, window)
    }

    private func click(_ control: NSSegmentedControl, fraction: CGFloat, window: NSWindow) async throws {
        let point = control.convert(NSPoint(x: control.bounds.width * fraction, y: control.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        window.sendEvent(up)
        try await Task.sleep(for: .milliseconds(180))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func key(_ characters: String, code: UInt16, window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(120))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func accessibilityElement(_ identifier: String, in host: NSView) throws -> NSObject {
        var visited = Set<ObjectIdentifier>()
        let id = NSSelectorFromString("accessibilityIdentifier")
        let children = NSSelectorFromString("accessibilityChildren")
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: id), object.perform(id)?.takeUnretainedValue() as? String == identifier { return object }
            if object.responds(to: children) {
                for child in object.perform(children)?.takeUnretainedValue() as? [NSObject] ?? [] {
                    if let found = find(child) { return found }
                }
            }
            return nil
        }
        for view in descendants(host) { if let found = find(view) { return found } }
        if let window = host.window {
            for y in stride(from: CGFloat(6), to: host.bounds.height, by: 12) {
                for x in stride(from: CGFloat(12), to: host.bounds.width, by: 30) {
                    let point = window.convertPoint(toScreen: host.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = host.accessibilityHitTest(point) as? NSObject, let found = find(hit) { return found }
                }
            }
        }
        return try XCTUnwrap(nil as NSObject?, "Missing accessibility element: " + identifier)
    }

    private func accessibilityFrame(_ object: NSObject) throws -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { throw RemoteFault.unavailable }
        typealias Method = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }
}
