import AppKit
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity
import SwiftUI
import Vision
import XCTest

private final class MinimalSessionSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws { XCTFail("Session presentation must not write credentials") }
    func remove(_ account: String) throws { XCTFail("Session presentation must not revoke credentials") }
}

@MainActor private struct MinimalSessionElement {
    let object: NSObject

    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                          "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue",
                          "accessibilityTitle": "AXTitle", "accessibilityRole": "AXRole"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    var identifier: String? { value("accessibilityIdentifier") as? String }
    func hasText(_ text: String) -> Bool {
        value("accessibilityLabel") as? String == text || value("accessibilityValue") as? String == text
            || value("accessibilityTitle") as? String == text
    }
    var frame: NSRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return nil }
        typealias Read = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Read.self)(object, selector)
    }
    var enabled: Bool {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return false }
        typealias Read = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Read.self)(object, selector)
    }
    func press() -> Bool {
        if let button = object as? NSButton ?? (object as? NSButtonCell)?.controlView as? NSButton {
            guard button.isEnabled else { return false }
            button.performClick(nil)
            return true
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), enabled else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
}

/// Hosted native fixtures only. No provider, listener, user preferences or saved sessions are used.
@MainActor final class MacMinimalSessionTests: XCTestCase {
    private func snapshot() -> HostSnapshot {
        let id = UUID()
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = id
        state.sessions = [SessionInfo(id: id, title: "Session fixture", directory: "/private/minimal-session-fixture/project")]
        state.piVersion = "fixture-1.0"
        state.models = [ModelOption(provider: "fixture", model: "model", name: "A long model name for a narrow Session inspector")]
        state.model = state.models[0].id
        state.thinkingLevels = ["off", "low", "high"]
        state.thinking = "high"
        state.runtime = RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .all, autoCompactionEnabled: true)
        state.commands = [CommandOption(name: "fixture-skill", detail: "Skill fixture", source: "skill"),
                          CommandOption(name: "fixture-template", detail: "Template fixture", source: "prompt"),
                          CommandOption(name: "fixture-extension", detail: "Extension fixture", source: "extension")]
        return state
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

    private func elements(_ root: NSView) -> [MinimalSessionElement] {
        var objects: [NSObject] = descendants(root)
        if let window = root.window {
            for y in stride(from: CGFloat(8), to: root.bounds.height, by: 16) {
                for x in stride(from: CGFloat(8), to: root.bounds.width, by: 16) {
                    let point = window.convertPoint(toScreen: root.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = root.accessibilityHitTest(point) as? NSObject { objects.append(hit) }
                }
            }
        }
        var seen = Set<ObjectIdentifier>(), result: [MinimalSessionElement] = [], index = 0
        while index < objects.count, seen.count < 8192 {
            let object = objects[index]
            index += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let element = MinimalSessionElement(object: object)
            result.append(element)
            objects.append(contentsOf: element.value("accessibilityChildren") as? [NSObject] ?? [])
        }
        return result
    }

    private func capture(_ root: NSView, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/pi-minimal-desktop")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pixels = try MacDebugController.snapshot(window: XCTUnwrap(root.window))
        let bitmap = NSBitmapImageRep(cgImage: pixels.value)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: pixels.value).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        try text.write(to: directory.appendingPathComponent(name + "-ocr.txt"), atomically: true, encoding: .utf8)
        let dump = elements(root).map {
            "\(type(of: $0.object)) id=\($0.identifier ?? "") title=\($0.value("accessibilityTitle") ?? "") label=\($0.value("accessibilityLabel") ?? "") value=\($0.value("accessibilityValue") ?? "") role=\($0.value("accessibilityRole") ?? "") enabled=\($0.enabled) frame=\(String(describing: $0.frame))"
        }.joined(separator: "\n")
        try dump.write(to: directory.appendingPathComponent(name + "-ax.txt"), atomically: true, encoding: .utf8)
    }

    private func element(_ id: String, in root: NSView) throws -> MinimalSessionElement {
        let all = elements(root)
        if let identified = all.first(where: { $0.identifier == id }) { return identified }
        // Native AppKit cells can omit SwiftUI identifiers on their first AX
        // exposure. Require the native role and exact value or labeled row.
        switch id {
        case "mac-session-model", "mac-session-thinking":
            let label = id == "mac-session-model" ? "Model" : "Thinking level"
            let value = id == "mac-session-model" ? "A long model name for a narrow Session inspector" : "high"
            let popup = try XCTUnwrap(all.first {
                $0.value("accessibilityRole") as? String == "AXPopUpButton"
                    && $0.value("accessibilityValue") as? String == value
            }, "Missing native popup: " + label)
            let heading = try XCTUnwrap(all.first { $0.hasText(label) }?.frame)
            let frame = try XCTUnwrap(popup.frame)
            XCTAssertGreaterThanOrEqual(heading.minY, frame.maxY)
            XCTAssertLessThan(heading.minY - frame.maxY, 12)
            XCTAssertEqual(heading.minX, frame.minX, accuracy: 2)
            return popup
        case "command-arguments":
            let label = try XCTUnwrap(all.first { $0.hasText("Command arguments") }?.frame)
            return try XCTUnwrap(all.first {
                guard $0.value("accessibilityRole") as? String == "AXTextField", let frame = $0.frame else { return false }
                return frame.minX >= label.maxX && frame.minY < label.maxY && frame.maxY > label.minY
            }, "Missing labeled Command arguments text field")
        default:
            return try XCTUnwrap(nil as MinimalSessionElement?, "Missing control: " + id)
        }
    }

    private func expand(_ id: String, in root: NSView) async throws {
        let control = try element(id, in: root)
        XCTAssertEqual(control.value("accessibilityRole") as? String, "AXDisclosureTriangle")
        XCTAssertTrue(control.enabled)
        let frame = try XCTUnwrap(control.frame)
        let window = try XCTUnwrap(root.window)
        // These SwiftUI disclosure nodes expose no AXPress action. Send a native
        // pointer click to the triangle, then verify the expanded AX value.
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.minX + 26, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        try await settle(root)
        XCTAssertEqual(try element(id, in: root).value("accessibilityValue") as? Int, 1)
    }
    private func text(_ text: String, in root: NSView) throws -> MinimalSessionElement {
        try XCTUnwrap(elements(root).first { $0.hasText(text) }, "Missing text: " + text)
    }
    private func contains(_ text: String, in root: NSView) -> Bool { elements(root).contains { $0.hasText(text) } }

    private func settle(_ root: NSView) async throws {
        root.layoutSubtreeIfNeeded()
        // Traverse once to create native popup/text cells, then allow SwiftUI
        // another layout turn before inspecting their accessibility traits.
        _ = elements(root)
        try await Task.sleep(for: .milliseconds(200))
        root.layoutSubtreeIfNeeded()
    }

    private func bottom(_ root: NSView) async throws {
        // Disclosure expansion can resize a grouped Form after its first layout.
        for _ in 0..<3 {
            for scroll in descendants(root).compactMap({ $0 as? NSScrollView }) {
                guard let document = scroll.documentView else { continue }
                let y = document.isFlipped ? max(0, document.bounds.height - scroll.bounds.height) : 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            try await settle(root)
        }
    }

    private func hosted<Content: View>(_ content: Content, width: CGFloat = 320, height: CGFloat = 650,
                                      _ body: (NSView, NSWindow) async throws -> Void) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: content.environment(\.accessibilityEnabled, true).frame(width: width, height: height))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        defer { window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(controller.view)
        try await body(controller.view, window)
    }

    private func controls(_ state: HostSnapshot, mode: MacInterfaceMode = .desktop,
                          close: (() -> Void)? = nil, closeReason: String? = nil,
                          request: @escaping (SessionAction) async throws -> AppResult) -> some View {
        NavigationStack {
            SessionControls(state: state, request: request, closeSession: close, closeSessionDisabledReason: closeReason) { _ in }
                .formStyle(.grouped)
        }.environment(\.macInterfaceMode, mode)
    }

    private func withModel(_ body: (CompanionModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.MinimalSession." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = CompanionModel(support: root, secrets: MinimalSessionSecrets(), defaults: defaults,
                                   debugDirectory: root.appendingPathComponent("debug"))
        XCTAssertNil(model.startupError)
        // Let initial empty-catalog observation finish before installing presentation-only state.
        try await Task.sleep(for: .milliseconds(100))
        do { try await body(model) }
        catch {
            await model.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.shutdown(); defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    func testDesktopPrimaryPicksFit260And320WithoutScrolling() async throws {
        for width: CGFloat in [260, 320] {
            var actions: [SessionAction] = []
            try await hosted(controls(snapshot(), request: { actions.append($0); return .ok }), width: width, height: 600) { root, window in
                try self.capture(root, name: "session-initial-\(Int(width))")
                let model = try XCTUnwrap(try self.element("mac-session-model", in: root).frame)
                let thinking = try XCTUnwrap(try self.element("mac-session-thinking", in: root).frame)
                // Both labels must remain separate, readable AX text even when
                // AppKit has not yet attached the popup cell's SwiftUI traits.
                _ = try self.text("Model", in: root)
                _ = try self.text("Thinking level", in: root)
                let ocr = try String(contentsOfFile: "/tmp/pi-minimal-desktop/session-initial-\(Int(width))-ocr.txt", encoding: .utf8)
                XCTAssertTrue(ocr.contains("Model"))
                XCTAssertTrue(ocr.contains("Thinking level"))
                let content = window.convertToScreen(root.convert(root.bounds, to: nil))
                for frame in [model, thinking] {
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThanOrEqual(frame.minX, content.minX)
                    XCTAssertLessThanOrEqual(frame.maxX, content.maxX)
                    XCTAssertGreaterThan(frame.minY, content.maxY - 220)
                    XCTAssertLessThanOrEqual(frame.maxY, content.maxY)
                }
                XCTAssertGreaterThan(model.minY, thinking.minY)
                XCTAssertFalse(self.contains("Cycle model", in: root))
                XCTAssertFalse(self.contains("Cycle thinking level", in: root))
                XCTAssertFalse(self.contains("Pi changelog", in: root))
                XCTAssertFalse(self.contains("Version: fixture-1.0", in: root))
                XCTAssertFalse(self.contains("Clone session", in: root))
                XCTAssertTrue(actions.isEmpty)
            }
        }
    }

    func testDetailsExposeResourcesWithoutRequests() async throws {
        var actions: [SessionAction] = []
        try await hosted(controls(snapshot(), request: { actions.append($0); return .ok })) { root, _ in
            XCTAssertFalse(self.elements(root).contains { $0.identifier == "desktop-session-resources" })
            try await self.expand("mac-session-details", in: root)
            try await self.settle(root)
            try await self.bottom(root)
            try self.capture(root, name: "session-details-after")
            for id in ["desktop-session-resources", "desktop-resource-context", "desktop-resource-skills", "desktop-resource-prompts"] {
                _ = try self.element(id, in: root)
            }
            XCTAssertTrue(self.contains("fixture-skill", in: root))
            XCTAssertTrue(self.contains("/fixture-template", in: root))
            XCTAssertTrue(actions.isEmpty, "Expanding metadata must not send a request")
        }
    }

    func testAdvancedRetainsExplicitLifecycleRuntimeExportAndCommands() async throws {
        var actions: [SessionAction] = []
        // Keep all relocated rows instantiated for identity and action checks.
        // The separate 600-point fixtures verify the compact inspector geometry.
        try await hosted(controls(snapshot(), request: { actions.append($0); return .ok }), height: 2400) { root, _ in
            try self.capture(root, name: "session-advanced-before")
            try await self.expand("mac-session-advanced", in: root)
            try await self.settle(root)
            try await self.bottom(root)
            try self.capture(root, name: "session-advanced-after")
            for title in ["Review and export session", "Pi runtime settings", "Automatic retry controls", "New in current directory",
                          "Rename", "Compact context", "Clone session", "Working tree diff"] {
                _ = try self.text(title, in: root)
            }
            _ = try self.text("Session name", in: root)
            XCTAssertTrue(self.elements(root).contains { $0.value("accessibilityRole") as? String == "AXTextField" })
            _ = try self.element("command-arguments", in: root)
            _ = try self.element("session-command-fixture-extension", in: root)
            XCTAssertTrue(actions.isEmpty, "Expanding Advanced must not read settings, export or execute commands")
            XCTAssertTrue(try self.text("Clone session", in: root).press())
            try await self.settle(root)
            XCTAssertEqual(actions, [.clone])
        }
    }

    func testCapabilityGuardsHideUnavailableRelocatedActions() async throws {
        var state = snapshot()
        state.capabilities = []
        try await hosted(controls(state, request: { _ in XCTFail("Presentation must not request work"); return .ok })) { root, _ in
            XCTAssertFalse(self.contains("Session tokens and cost", in: root))
            XCTAssertFalse(self.contains("Copy last assistant message", in: root))
            XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-inspector-close-session" })
            try await self.expand("mac-session-advanced", in: root)
            try await self.settle(root)
            try await self.bottom(root)
            for title in ["Review and export session", "Pi runtime settings", "Automatic retry controls", "New in current directory"] {
                XCTAssertFalse(self.contains(title, in: root), title)
            }
            _ = try self.text("Compact context", in: root)
            _ = try self.element("session-command-fixture-extension", in: root)
        }
    }

    func testBusyGuardsKeepRetryRecoveryAndCloseConsentRoute() async throws {
        var state = snapshot()
        state.phase = "retrying"
        var actions: [SessionAction] = [], closes = 0
        try await hosted(controls(state, close: { closes += 1 }, request: { actions.append($0); return .ok }), height: 2400) { root, _ in
            XCTAssertFalse(try self.element("mac-session-model", in: root).enabled)
            XCTAssertFalse(try self.element("mac-session-thinking", in: root).enabled)
            XCTAssertTrue(try self.text("Cancel retry wait", in: root).enabled)
            XCTAssertTrue(try self.element("mac-inspector-close-session", in: root).enabled)
            try await self.bottom(root)
            try self.capture(root, name: "session-busy-before")
            try await self.expand("mac-session-advanced", in: root)
            try await self.settle(root)
            try await self.bottom(root)
            for title in ["Review and export session", "Pi runtime settings", "New in current directory", "Clone session", "Working tree diff"] {
                XCTAssertFalse(try self.text(title, in: root).enabled, title)
            }
            XCTAssertFalse(try self.element("session-command-fixture-skill", in: root).enabled)
            XCTAssertTrue(try self.element("session-command-fixture-extension", in: root).enabled)
            XCTAssertTrue(actions.isEmpty)
            XCTAssertTrue(try self.element("mac-inspector-close-session", in: root).press())
            XCTAssertEqual(closes, 1, "Close must use the parent's consent route, not direct close RPC")
            XCTAssertTrue(actions.isEmpty)
        }
    }

    func testUnloadedPicksAndUnavailableCloseRemainDisabled() async throws {
        var state = snapshot()
        state.selected = nil
        try await hosted(controls(state, close: {}, closeReason: "Session unavailable", request: { _ in
            XCTFail("Unavailable controls must not dispatch"); return .ok
        })) { root, _ in
            XCTAssertFalse(try self.element("mac-session-model", in: root).enabled)
            XCTAssertFalse(try self.element("mac-session-thinking", in: root).enabled)
            XCTAssertFalse(try self.element("mac-inspector-close-session", in: root).enabled)
        }
    }

    func testPiFormKeepsVersionChangelogAndCycleActions() async throws {
        var actions: [SessionAction] = []
        try await hosted(controls(snapshot(), mode: .pi, request: { actions.append($0); return .ok }), width: 560, height: 800) { root, _ in
            _ = try self.text("Version: fixture-1.0", in: root)
            _ = try self.text("Pi changelog", in: root)
            _ = try self.text("Cycle thinking level", in: root)
            XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-session-advanced" })
            XCTAssertTrue(try self.text("Cycle model", in: root).press())
            try await self.settle(root)
            XCTAssertEqual(actions, [.cycleModel])
        }
    }

    func testSettingsChangelogUsesExistingProtectedPanelWithoutStartingPi() async throws {
        try await withModel { model in
            model.state = self.snapshot()
            model.destination = .settings
            model.text = "Keep the draft"
            let before = model.state
            let runtime = await model.coordinator?.state()
            try await self.hosted(NavigationStack { CompanionConnectionSettings(model: model, openSessionControls: {}) }, width: 650, height: 800) { root, _ in
                XCTAssertTrue(try self.element("mac-settings-pi-changelog", in: root).press())
                XCTAssertEqual(model.panel, "changelog", "Use the existing root panel and its debug protection")
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Keep the draft")
                XCTAssertFalse(model.starting)
                XCTAssertFalse(model.listening)
                let after = await model.coordinator?.state()
                XCTAssertEqual(after, runtime)
            }
        }
    }

    func testSettingsChangelogCapabilityAndScopedRequestGuards() async throws {
        try await withModel { model in
            model.state.capabilities.removeAll { $0 == "pi-release-notes" }
            try await self.hosted(NavigationStack { CompanionConnectionSettings(model: model, openSessionControls: {}) }, width: 650, height: 800) { root, _ in
                XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-settings-pi-changelog" })
                XCTAssertNil(model.panel)
            }
            let request = model.scopedRequest(for: model.state)
            model.state.epoch = UUID()
            do {
                _ = try await request(.releaseNotes(offset: 0, revision: nil))
                XCTFail("Stale changelog context must be rejected")
            } catch { XCTAssertEqual(error as? RemoteFault, .conflict) }
        }
    }

    func testChangelogReaderUsesReleaseNotesRequestOnly() async throws {
        var actions: [SessionAction] = []
        let page = ReleaseNotesPage(version: "fixture-1.0", revision: String(repeating: "a", count: 64), offset: 0,
                                    totalBytes: 13, text: "Fixture notes", next: nil)
        try await hosted(NavigationStack {
            ReleaseNotesView(request: { action in actions.append(action); return .releaseNotes(page) })
        }, width: 560) { root, _ in
            XCTAssertEqual(actions, [.releaseNotes(offset: 0, revision: nil)])
            _ = try self.text("Fixture notes", in: root)
        }
    }

    func testSettingsDevicesRoutePreservesSessionDraftAndRuntime() async throws {
        try await withModel { model in
            model.state = self.snapshot()
            model.destination = .settings
            model.text = "Keep the draft"
            model.devices = [PairedDevice(id: UUID(), name: "Private fixture phone")]
            let state = model.state, devices = model.devices
            let runtime = await model.coordinator?.state()
            try await self.hosted(NavigationStack { CompanionConnectionSettings(model: model, openSessionControls: {}) }, width: 650, height: 850) { root, _ in
                XCTAssertTrue(try self.element("mac-settings-devices", in: root).press())
                XCTAssertEqual(model.destination, .devices)
                XCTAssertEqual(model.state, state)
                XCTAssertEqual(model.devices, devices)
                XCTAssertEqual(model.text, "Keep the draft")
                XCTAssertFalse(model.listening)
                XCTAssertFalse(model.starting)
                let after = await model.coordinator?.state()
                XCTAssertEqual(after, runtime)
            }
        }
    }
}
