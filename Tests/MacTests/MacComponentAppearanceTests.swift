import AppKit
import Observation
import PiRemoteCore
import SwiftUI
import XCTest

@Observable @MainActor private final class ComponentAppearanceState {
    var mode = MacInterfaceMode.pi
}

@MainActor private struct ComponentAppearanceFixture: View {
    let state: ComponentAppearanceState
    let message: TranscriptMessage
    let copy: (String) throws -> Void
    let disclosure: (UUID, CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 23)
            PiToolRow(message: message, expandTools: false, onDisclosure: disclosure)
            PiCodeBlock(code: "let café = \"😀\"\n", language: "swift", copy: copy)
            Spacer(minLength: 0)
        }
        .coordinateSpace(name: "pi-surface-viewport")
        .environment(\.macInterfaceMode, state.mode)
    }
}

@MainActor private struct PickerAppearanceFixture: View {
    let appearance: ComponentAppearanceState
    let snapshot: HostSnapshot
    let thinking: Bool
    let request: (SessionAction) async throws -> AppResult
    let done: () -> Void

    var body: some View {
        PiConfigurationPicker(state: snapshot, thinking: thinking, request: request, done: done)
            .environment(\.macInterfaceMode, appearance.mode)
    }
}

@MainActor private struct DialogAppearanceFixture: View {
    @Environment(\.colorScheme) private var systemColorScheme
    let appearance: ComponentAppearanceState
    let dialog: ExtensionDialog
    let request: (SessionAction) async throws -> AppResult

    var body: some View {
        PiExtensionDialog(dialog: dialog, request: request)
            .environment(\.macInterfaceMode, appearance.mode)
            .environment(\.colorScheme, appearance.mode == .pi ? .dark : systemColorScheme)
    }
}

@MainActor final class MacComponentAppearanceTests: XCTestCase {
    func testExtensionEditorKeepsInputAndNativeContrastAcrossModes() async throws {
        let appearance = ComponentAppearanceState()
        let text = "Unsent extension response 文\nSecond line"
        let dialog = ExtensionDialog(id: "appearance-editor", method: "editor", title: "Edit response", message: "Fixture only", options: [], text: text, expires: nil)
        var calls = 0
        let fixture = DialogAppearanceFixture(appearance: appearance, dialog: dialog, request: { _ in
            calls += 1
            return .ok
        })
        try await hosted(fixture) { root, window in
            let editor = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSTextView }.first)
            editor.setSelectedRange(NSRange(location: 7, length: 3))
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: name)
                for mode in [MacInterfaceMode.desktop, .pi, .desktop] {
                    appearance.mode = mode
                    try await self.settle(root)
                    XCTAssertTrue(self.descendants(root).compactMap { $0 as? NSTextView }.first === editor)
                    XCTAssertEqual(editor.string, text)
                    XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 3))
                    if mode == .desktop {
                        self.assertContrast(try XCTUnwrap(editor.textColor), editor.backgroundColor,
                                            appearance: editor.effectiveAppearance)
                        XCTAssertEqual(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
                    }
                    XCTAssertEqual(calls, 0)
                }
            }
        }
    }

    func testExtensionSelectionRemainsReadableAndDoesNotAnswerOnModeChange() async throws {
        let appearance = ComponentAppearanceState()
        let options = ["First fixture option", "Second fixture option"]
        let dialog = ExtensionDialog(id: "appearance-select", method: "select", title: "Choose a response", message: "Fixture only", options: options, text: "", expires: nil)
        var calls = 0
        let fixture = DialogAppearanceFixture(appearance: appearance, dialog: dialog, request: { _ in
            calls += 1
            return .ok
        })
        try await hosted(fixture) { root, window in
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: name)
                for mode in [MacInterfaceMode.desktop, .pi, .desktop] {
                    appearance.mode = mode
                    try await self.settle(root)
                    let nodes = self.accessibleNodes(root)
                    for option in options {
                        XCTAssertTrue(nodes.contains {
                            self.value("accessibilityValue", of: $0) as? String == option ||
                            self.value("accessibilityLabel", of: $0) as? String == option
                        })
                    }
                    let theme = MacInterfaceTheme(mode: mode)
                    self.assertContrast(theme.nativeText, NSColor(theme.background),
                                        appearance: try XCTUnwrap(NSAppearance(named: mode == .pi ? .darkAqua : name)))
                    XCTAssertEqual(calls, 0)
                }
            }
        }
    }

    func testNativeToolColorsAndDisclosureSurviveRepeatedModeAndAppearanceChanges() async throws {
        let state = ComponentAppearanceState()
        let message = TranscriptMessage(role: "tool", text: "read\nPermission denied", isError: true,
                                        tool: TranscriptTool(name: "read", target: "/tmp/example.swift", status: .failed))
        var disclosures: [(UUID, CGFloat)] = []
        let fixture = ComponentAppearanceFixture(state: state, message: message, copy: { _ in XCTFail("Render must not copy") },
                                                  disclosure: { disclosures.append(($0, $1)) })
        try await hosted(fixture) { root, window in
            let heading = try self.button("pi-tool-toggle-" + message.id.uuidString, in: root)
            let identity = ObjectIdentifier(heading)
            XCTAssertEqual(heading.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                           NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
            heading.performClick(nil)
            try await self.settle(root)
            XCTAssertEqual(disclosures.count, 1)
            XCTAssertEqual(disclosures.first?.0, message.id)
            XCTAssertEqual(try XCTUnwrap(disclosures.first?.1), 28, accuracy: 1)

            for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                window.appearance = NSAppearance(named: name)
                for mode in [MacInterfaceMode.desktop, .pi, .desktop] {
                    state.mode = mode
                    try await self.settle(root)
                    let updated = try self.button("pi-tool-toggle-" + message.id.uuidString, in: root)
                    XCTAssertEqual(ObjectIdentifier(updated), identity)
                    XCTAssertEqual(updated.accessibilityValue() as? String, "Expanded")
                    let nodes = self.accessibleNodes(root)
                    // SwiftUI selection overlays expose the text, not the scroll wrapper identifier.
                    XCTAssertTrue(nodes.contains {
                        self.value("accessibilityValue", of: $0) as? String == message.text ||
                        self.value("accessibilityLabel", of: $0) as? String == message.text
                    }, "Expanded output must keep the exact text.")
                    XCTAssertEqual(updated.accessibilityLabel(), "Read, /tmp/example.swift, Failed")
                    XCTAssertEqual(disclosures.count, 1, "Appearance updates must not invoke disclosure.")
                    let title = updated.attributedTitle
                    let source = title.string as NSString
                    let target = source.range(of: "/tmp/example.swift").location
                    XCTAssertEqual(title.attribute(.font, at: target, effectiveRange: nil) as? NSFont,
                                   NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
                    if mode == .desktop {
                        XCTAssertEqual(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                                       NSFont.systemFont(ofSize: 13, weight: .medium))
                        let appearance = try XCTUnwrap(NSAppearance(named: name))
                        let panel = NSColor(MacInterfaceTheme(mode: mode).panel)
                        for location in [0, target, source.range(of: "Failed").location] {
                            let color = try XCTUnwrap(title.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)
                            self.assertContrast(color, panel, appearance: appearance)
                        }
                    }
                }
            }
            heading.performClick(nil)
            try await self.settle(root)
            XCTAssertEqual(heading.accessibilityValue() as? String, "Collapsed")
            XCTAssertEqual(disclosures.count, 2, "The original native callback must still work.")
        }
    }

    func testDarkCodeControlsAndCopyFeedbackSurviveModesInBothNativeAppearances() async throws {
        struct CopyFailure: Error {}
        let state = ComponentAppearanceState()
        let message = TranscriptMessage(role: "tool", text: "bash\noutput")
        var copies: [String] = []
        var fail = false
        let fixture = ComponentAppearanceFixture(state: state, message: message, copy: {
            copies.append($0)
            if fail { throw CopyFailure() }
        }, disclosure: { _, _ in XCTFail("Appearance must not disclose") })
        try await hosted(fixture) { root, window in
            let copy = try self.button("pi-code-copy", in: root)
            let identity = ObjectIdentifier(copy)
            XCTAssertTrue(copies.isEmpty)
            for failure in [false, true] {
                fail = failure
                copy.performClick(nil)
                try await self.settle(root)
                let expected = failure ? "Cannot copy code. Try again." : "Copied to this Mac"
                let attempts = copies.count
                for name in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: name)
                    for mode in [MacInterfaceMode.desktop, .pi, .desktop] {
                        state.mode = mode
                        try await self.settle(root)
                        let updated = try self.button("pi-code-copy", in: root)
                        XCTAssertEqual(ObjectIdentifier(updated), identity)
                        XCTAssertEqual(updated.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
                        let feedback = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSTextField }
                            .first { $0.accessibilityIdentifier() == "pi-code-copy-feedback" })
                        XCTAssertEqual(feedback.stringValue, expected)
                        XCTAssertEqual(feedback.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
                        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
                        let foreground = try XCTUnwrap(updated.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                        self.assertContrast(foreground, NSColor(PiPalette.panel), appearance: dark)
                        // Pi retains its existing 4.43:1 failure color; Desktop uses at least 4.5:1.
                        self.assertContrast(try XCTUnwrap(feedback.textColor), NSColor(PiPalette.panel), appearance: dark,
                                            minimum: failure && mode == .pi ? 4.4 : 4.5)
                        XCTAssertEqual(copies.count, attempts, "Mode changes must not copy or clear feedback.")
                    }
                }
            }
            XCTAssertEqual(copies, ["let café = \"😀\"\n", "let café = \"😀\"\n"])
        }
    }

    func testModelPickerPreservesSearchAndArrowSelectionWithoutThemeDispatch() async throws {
        try await checkPicker(thinking: false)
    }

    func testThinkingPickerPreservesSelectionWithoutThemeDispatch() async throws {
        try await checkPicker(thinking: true)
    }

    private func checkPicker(thinking: Bool) async throws {
        let appearance = ComponentAppearanceState()
        var snapshot = HostSnapshot(host: UUID(), epoch: UUID())
        snapshot.selected = UUID()
        snapshot.models = [ModelOption(provider: "second", model: "one", name: "One"),
                           ModelOption(provider: "first", model: "two", name: "Two"),
                           ModelOption(provider: "second", model: "three", name: "Three")]
        snapshot.model = "first/two"
        snapshot.thinkingLevels = ["off", "medium", "high"]
        snapshot.thinking = "medium"
        var requests: [SessionAction] = []
        var closes = 0
        let fixture = PickerAppearanceFixture(appearance: appearance, snapshot: snapshot, thinking: thinking,
                                              request: { requests.append($0); return .ok }, done: { closes += 1 })
        try await hosted(fixture) { root, window in
            let field = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(thinking ? "" : "second", replacementRange: editor.selectedRange())
            try await self.settle(root)
            try await self.key("\u{f701}", code: 125, window: window, root: root)
            XCTAssertTrue(requests.isEmpty)
            for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                window.appearance = NSAppearance(named: name)
                for mode in [MacInterfaceMode.desktop, .pi, .desktop] {
                    appearance.mode = mode
                    try await self.settle(root)
                    XCTAssertTrue(requests.isEmpty)
                    XCTAssertEqual(closes, 0)
                    XCTAssertEqual(field.stringValue, thinking ? "" : "second")
                    XCTAssertTrue(self.descendants(root).contains { $0 === field }, "Do not replace the native search field.")
                    if mode == .desktop {
                        let native = try XCTUnwrap(NSAppearance(named: name))
                        let theme = MacInterfaceTheme(mode: mode)
                        for foreground in [theme.nativeText, theme.nativeMuted, theme.nativeAccent, theme.nativeWarning] {
                            self.assertContrast(foreground, NSColor(theme.background), appearance: native)
                        }
                    }
                }
            }
            XCTAssertTrue(window.makeFirstResponder(field))
            try await self.key("\r", code: 36, window: window, root: root)
            XCTAssertEqual(requests, thinking ? [.thinking(level: "high")] : [.model(provider: "second", id: "three")])
            XCTAssertEqual(closes, 1)
        }
    }

    private func assertContrast(_ foreground: NSColor, _ background: NSColor, appearance: NSAppearance, minimum: Double = 4.5,
                                file: StaticString = #filePath, line: UInt = #line) {
        appearance.performAsCurrentDrawingAppearance {
            guard let front = foreground.usingColorSpace(.sRGB), let back = background.usingColorSpace(.sRGB) else {
                XCTFail("Cannot resolve color", file: file, line: line)
                return
            }
            func luminance(_ components: [CGFloat]) -> Double {
                let linear = components.map { component -> Double in
                    let value = Double(component)
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
            }
            let backgroundComponents = [back.redComponent, back.greenComponent, back.blueComponent]
            let foregroundComponents = zip([front.redComponent, front.greenComponent, front.blueComponent], backgroundComponents)
                .map { $0 * front.alphaComponent + $1 * (1 - front.alphaComponent) }
            let first = luminance(foregroundComponents), second = luminance(backgroundComponents)
            XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), minimum, file: file, line: line)
        }
    }

    private func value(_ name: String, of object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector) { return object.perform(selector)?.takeUnretainedValue() }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                          "accessibilityValue": "AXValue", "accessibilityLabel": "AXDescription", "accessibilityParent": "AXParent"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    private func accessibleNodes(_ root: NSView) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var nodes: [NSObject] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            nodes.append(object)
            for child in value("accessibilityChildren", of: object) as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        if let window = root.window {
            for y in stride(from: CGFloat(6), to: root.bounds.height, by: 12) {
                for x in stride(from: CGFloat(6), to: root.bounds.width, by: 40) {
                    let point = window.convertPoint(toScreen: root.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = root.accessibilityHitTest(point) as? NSObject {
                        visit(hit)
                        var parent = value("accessibilityParent", of: hit) as? NSObject
                        var ancestors = Set<ObjectIdentifier>()
                        while let object = parent, ancestors.insert(ObjectIdentifier(object)).inserted {
                            visit(object)
                            parent = value("accessibilityParent", of: object) as? NSObject
                        }
                    }
                }
            }
        }
        return nodes
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func button(_ identifier: String, in root: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == identifier })
    }

    private func key(_ text: String, code: UInt16, window: NSWindow, root: NSView) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        window.sendEvent(event)
        try await settle(root)
    }

    private func settle(_ root: NSView) async throws {
        try await Task.sleep(for: .milliseconds(150))
        root.layoutSubtreeIfNeeded()
    }

    private func hosted<V: View>(_ view: V, exercise: (NSView, NSWindow) async throws -> Void) async throws {
        let controller = NSHostingController(rootView: view.environment(\.accessibilityEnabled, true))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 640, height: 460))
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(controller.view)
        try await exercise(controller.view, window)
    }
}
