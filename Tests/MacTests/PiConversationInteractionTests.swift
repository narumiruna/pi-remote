import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class PiInteractionSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor final class PiConversationInteractionTests: XCTestCase {
    func testAcceptedNativeCommandsClearOnlyConsumedDraft() async throws {
        try await withModel { model in
            var opened: [String] = []
            try await hosted(PiConversationView(model: model, openControls: { name in
                opened.append(name)
                return true
            })) { host, window in
                for command in PiBuiltinCommand.all {
                    model.text = "/" + command.name
                    try await self.submit(in: host, window: window)
                    XCTAssertEqual(model.text, "", command.name)
                    XCTAssertNil(model.composerError)
                    XCTAssertEqual(opened.last, command.name)
                    let count = opened.count
                    try await self.returnKey(in: host, window: window)
                    XCTAssertEqual(opened.count, count, "Empty Return must not reopen the workflow.")
                }
            }
        }
    }

    func testRejectedNativeCommandKeepsDraft() async throws {
        try await withModel { model in
            var attempts = 0
            model.text = "/settings"
            try await hosted(PiConversationView(model: model, openControls: { _ in
                attempts += 1
                model.composerError = "Wait for Pi to become idle."
                return false
            })) { host, window in
                try await self.submit(in: host, window: window)
                XCTAssertEqual(attempts, 1)
                XCTAssertEqual(model.text, "/settings")
                XCTAssertEqual(model.composerError, "Wait for Pi to become idle.")
            }
        }
    }

    func testInlineArgumentsAndDialogRetainCommandWithoutOpeningControls() async throws {
        try await withModel { model in
            var attempts = 0
            model.text = "/model extra"
            try await hosted(PiConversationView(model: model, openControls: { _ in attempts += 1; return true })) { host, window in
                try await self.submit(in: host, window: window)
                XCTAssertEqual(model.text, "/model extra")
                XCTAssertNotNil(model.composerError)
                model.text = "/model"
                model.state.dialogs = [ExtensionDialog(id: "fixture", method: "confirm", title: "Confirm", message: "Fixture", options: [], text: "", expires: nil)]
                try await self.submit(in: host, window: window)
                XCTAssertEqual(model.text, "/model")
                XCTAssertEqual(model.composerError, "Answer or cancel the open request first.")
                XCTAssertEqual(attempts, 0)
            }
        }
    }

    func testAcceptedControlDoesNotClearChangedDraftOrContext() async throws {
        for changeContext in [false, true] {
            try await withModel { model in
                model.text = "/model"
                var attempts = 0
                try await hosted(PiConversationView(model: model, openControls: { _ in
                    attempts += 1
                    if changeContext { model.state.epoch = UUID() }
                    else { model.text = "New draft" }
                    return true
                })) { host, window in
                    try await self.submit(in: host, window: window)
                    XCTAssertEqual(attempts, 1)
                    XCTAssertEqual(model.text, changeContext ? "/model" : "New draft")
                }
            }
        }
    }

    func testRootModelPickerConsumesCommandAndBusySettingsRetainIt() async throws {
        try await withModel { model in
            model.text = "/model"
            try await hosted(CompanionWindow(model: model)) { host, window in
                try await self.submit(in: host, window: window)
                XCTAssertEqual(model.panel, "model")
                XCTAssertEqual(model.text, "")
                model.panel = nil
                try await Task.sleep(for: .milliseconds(300))
                model.state.phase = "working"
                model.text = "/settings"
                try await self.submit(in: host, window: window)
                XCTAssertNil(model.panel)
                XCTAssertEqual(model.text, "/settings")
                XCTAssertEqual(model.composerError, "Wait for Pi to become idle.")
            }
        }
    }

    func testLoadedTranscriptStartsAtLatestAndReturnsFromOverviewAtLatest() async throws {
        try await withModel { model in
            model.state.messages = (0..<60).map {
                TranscriptMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Fixture message \($0)\nSecond line\nThird line")
            }
            let original = model.state.messages
            try await hosted(CompanionWindow(model: model)) { host, _ in
                try self.assertLatestVisible(in: host)
                XCTAssertEqual(model.state.messages, original, "Initial scrolling must not need a transcript mutation.")
                model.destination = .overview
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertTrue(self.descendants(host).compactMap { $0 as? PiEditorTextView }.isEmpty)
                model.destination = .conversation
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                try self.assertLatestVisible(in: host)
                XCTAssertEqual(model.state.messages, original)
            }
        }
    }

    func testToolDisclosureKeepsHeaderAndReadingPositionDuringStreaming() async throws {
        try await withModel { model in
            let tool = TranscriptMessage(role: "tool", text: "read\n" + String(repeating: "Fixture file output\n", count: 160),
                                         tool: TranscriptTool(name: "read", target: "Sources/Fixture.swift", status: .completed))
            let before = (0..<25).map { TranscriptMessage(role: "user", text: "Earlier fixture \($0)\nSecond line") }
            let after = (0..<30).map { TranscriptMessage(role: "assistant", text: "Later fixture \($0)\nSecond line") }
            model.state.messages = before + [tool] + after
            try await hosted(PiConversationView(model: model, openControls: { _ in true })) { host, window in
                let scroll = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first {
                    ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 100
                })
                let document = try XCTUnwrap(scroll.documentView)
                let identifier = "pi-tool-toggle-" + tool.id.uuidString
                let initial = try self.accessibilityElement(identifier, in: host)
                let frame = try self.accessibilityFrame(initial)
                let inDocument = document.convert(window.convertFromScreen(frame), from: nil)
                let targetY = document.isFlipped ? inDocument.minY - 140 : inDocument.maxY - scroll.contentSize.height + 140
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(targetY, document.bounds.height - scroll.contentSize.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let header = try self.accessibilityElement(identifier, in: host)
                let original = try self.accessibilityFrame(header)
                XCTAssertTrue(window.convertToScreen(host.visibleRect).intersects(original))
                try self.press(header)
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                let expanded = try self.accessibilityFrame(self.accessibilityElement(identifier, in: host))
                XCTAssertEqual(expanded.minY, original.minY, accuracy: 3, "Expansion must keep its header in place.")
                model.state.messages.append(TranscriptMessage(role: "assistant", text: "New streaming fixture\n" + String(repeating: "New output\n", count: 20), streaming: true))
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let reading = try self.accessibilityFrame(self.accessibilityElement(identifier, in: host))
                XCTAssertEqual(reading.minY, expanded.minY, accuracy: 3, "Output must not pull the reader away.")
                _ = try self.accessibilityElement("pi-follow-latest", in: host)
                try self.press(self.accessibilityElement(identifier, in: host))
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                let collapsed = try self.accessibilityFrame(self.accessibilityElement(identifier, in: host))
                XCTAssertEqual(collapsed.minY, original.minY, accuracy: 3, "Collapse must keep its header in place.")
                let index = try XCTUnwrap(model.state.messages.firstIndex { $0.id == tool.id })
                model.state.messages[index].tool?.status = .running
                model.state.messages[index].streaming = true
                model.state.phase = "interrupted"
                try await Task.sleep(for: .milliseconds(150))
                let stopped = try XCTUnwrap(self.accessibilityElement(identifier, in: host) as? NSButton)
                XCTAssertEqual(stopped.accessibilityLabel(), "Read, Sources/Fixture.swift, Interrupted")
            }
        }
    }

    private func assertLatestVisible(in host: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? PiEditorTextView }.first, file: file, line: line)
        let rect = editor.convert(editor.bounds, to: host)
        XCTAssertTrue(host.visibleRect.contains(rect), "The loaded editor must be visible: \(rect) in \(host.visibleRect)", file: file, line: line)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 100
        }, file: file, line: line)
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        let visible = document.visibleRect
        XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height * 2, file: file, line: line)
        if document.isFlipped {
            XCTAssertGreaterThanOrEqual(visible.maxY, document.bounds.maxY - 48, file: file, line: line)
            XCTAssertGreaterThan(visible.minY, document.bounds.minY + 100, file: file, line: line)
        } else {
            XCTAssertLessThanOrEqual(visible.minY, document.bounds.minY + 48, file: file, line: line)
        }
    }

    private func submit(in host: NSView, window: NSWindow) async throws {
        // Completion-only Return remains unchanged. Escape dismisses suggestions first.
        try await Task.sleep(for: .milliseconds(80))
        try key("\u{1b}", code: 53, in: host, window: window)
        try await Task.sleep(for: .milliseconds(50))
        try await returnKey(in: host, window: window)
    }

    private func returnKey(in host: NSView, window: NSWindow) async throws {
        try key("\r", code: 36, in: host, window: window)
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
    }

    private func key(_ text: String, code: UInt16, in host: NSView, window: NSWindow) throws {
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? PiEditorTextView }.first)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        editor.keyDown(with: event)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func accessibilityElement(_ identifier: String, in host: NSView) throws -> NSObject {
        var visited = Set<ObjectIdentifier>()
        let idSelector = NSSelectorFromString("accessibilityIdentifier")
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: idSelector), object.perform(idSelector)?.takeUnretainedValue() as? String == identifier { return object }
            if object.responds(to: childrenSelector) {
                for child in object.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] ?? [] {
                    if let found = find(child) { return found }
                }
            }
            return nil
        }
        for view in descendants(host) { if let found = find(view) { return found } }
        if let window = host.window {
            for y in stride(from: CGFloat(6), to: host.bounds.height, by: 12) {
                for x in stride(from: CGFloat(20), to: host.bounds.width, by: 100) {
                    let point = window.convertPoint(toScreen: host.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = host.accessibilityHitTest(point) as? NSObject, let found = find(hit) { return found }
                }
            }
        }
        return try XCTUnwrap(nil as NSObject?, "Missing accessibility element: " + identifier)
    }

    private func accessibilityFrame(_ object: NSObject) throws -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { XCTFail("Missing accessibility frame"); throw RemoteFault.unavailable }
        typealias Method = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }

    private func press(_ object: NSObject) throws {
        if let button = object as? NSButton {
            XCTAssertTrue(button.isEnabled)
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { XCTFail("Missing accessibility press action"); throw RemoteFault.unavailable }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector))
    }

    private func withModel(_ body: (CompanionModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.PiInteraction." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: PiInteractionSecrets(), defaults: defaults)
        let id = UUID()
        model.state.sessions = [SessionInfo(id: id, title: "Synthetic interaction", directory: "/tmp/pi-interaction-fixture")]
        model.state.selected = id; model.state.phase = "idle"
        do { try await body(model) } catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    private func hosted<V: View>(_ view: V, exercise: (NSView, NSWindow) async throws -> Void) async throws {
        let controller = NSHostingController(rootView: view.preferredColorScheme(.dark).environment(\.accessibilityEnabled, true).frame(width: 1000, height: 650))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 650))
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
}
