import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class ModeFixtureSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor final class MacConversationModeTests: XCTestCase {
    func testModeChangesKeepTheMountedEditorDraftSelectionUndoAndMarkedText() async throws {
        try await withModel { model in
            model.text = "Unsent 文 draft"
            try await hosted(CompanionWindow(model: model)) { host, window in
                let original = try self.editor(in: host)
                XCTAssertTrue(window.makeFirstResponder(original))
                let undo = try XCTUnwrap(original.undoManager)
                let nativeParent = try XCTUnwrap(original.superview)
                let inputScroll = try XCTUnwrap(original.enclosingScrollView)
                let initial = original.string
                original.insertText(" added", replacementRange: NSRange(location: original.string.utf16.count, length: 0))
                try await self.settle(host)
                let draft = original.string
                let selected = NSRange(location: 7, length: 1)
                original.setSelectedRange(selected)
                for mode in [MacInterfaceMode.desktop, .pi, .desktop] {
                    model.interfaceMode = mode
                    try await self.settle(host)
                    XCTAssertTrue(try self.editor(in: host) === original)
                    XCTAssertTrue(original.undoManager === undo)
                    XCTAssertTrue(original.superview === nativeParent)
                    XCTAssertTrue(original.enclosingScrollView === inputScroll)
                    XCTAssertEqual(original.string, draft)
                    XCTAssertEqual(model.text, draft)
                    XCTAssertEqual(original.selectedRange(), selected)
                }
                undo.undo()
                try await self.settle(host)
                XCTAssertEqual(original.string, initial)
                XCTAssertEqual(model.text, initial)
                original.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: original.string.utf16.count, length: 0))
                let marked = original.markedRange()
                let markedString = original.string
                let markedSelection = original.selectedRange()
                XCTAssertTrue(original.hasMarkedText())
                for mode in [MacInterfaceMode.pi, .desktop] {
                    model.interfaceMode = mode
                    try await self.settle(host)
                    XCTAssertTrue(try self.editor(in: host) === original)
                    XCTAssertTrue(original.hasMarkedText())
                    XCTAssertTrue(original.superview === nativeParent)
                    XCTAssertTrue(original.enclosingScrollView === inputScroll)
                    XCTAssertEqual(original.markedRange(), marked)
                    XCTAssertEqual(original.string, markedString)
                    XCTAssertEqual(original.selectedRange(), markedSelection)
                }
                XCTAssertNil(model.fault)
            }
        }
    }

    func testModeChangesKeepPendingDialogAndWorkingStateWithoutDispatch() async throws {
        try await withModel { model in
            model.text = "Keep this draft"
            model.delivery = .followUp
            model.state.phase = "working"
            model.state.messages = [TranscriptMessage(role: "assistant", text: "Synthetic active output", streaming: true)]
            model.state.dialogs = [ExtensionDialog(id: "mode-confirm", method: "confirm", title: "Fixture confirmation", message: "Do not answer automatically", options: [], text: "", expires: nil)]
            model.panel = "dialog"
            let snapshot = model.state
            try await hosted(CompanionWindow(model: model)) { host, window in
                let sheet = try XCTUnwrap(window.sheets.first)
                for mode in [MacInterfaceMode.desktop, .pi, .desktop] {
                    model.interfaceMode = mode
                    try await self.settle(host)
                    XCTAssertEqual(model.state, snapshot)
                    XCTAssertEqual(model.text, "Keep this draft")
                    XCTAssertEqual(model.delivery, .followUp)
                    XCTAssertEqual(model.panel, "dialog")
                    XCTAssertTrue(window.sheets.first === sheet)
                    XCTAssertNil(model.fault)
                }
            }
        }
    }

    func testBothModesKeepVisibleCompletionWithoutChangingDraft() async throws {
        try await withModel { model in
            model.text = "/mo"
            try await hosted(CompanionWindow(model: model)) { host, _ in
                let original = try self.editor(in: host)
                let suggestions = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first { $0.accessibilityIdentifier() == "pi-editor-suggestions" })
                XCTAssertFalse(suggestions.isHidden)
                let buttons = self.descendants(suggestions).compactMap { $0 as? NSButton }.map(\.title)
                XCTAssertFalse(buttons.isEmpty)
                for mode in [MacInterfaceMode.desktop, .pi] {
                    model.interfaceMode = mode
                    try await self.settle(host)
                    XCTAssertTrue(try self.editor(in: host) === original)
                    XCTAssertFalse(suggestions.isHidden)
                    XCTAssertTrue(self.descendants(host).contains { $0 === suggestions })
                    XCTAssertTrue(host.visibleRect.contains(suggestions.convert(suggestions.bounds, to: host)))
                    XCTAssertEqual(self.descendants(suggestions).compactMap { $0 as? NSButton }.map(\.title), buttons)
                    XCTAssertEqual(model.text, "/mo")
                    XCTAssertNil(model.fault)
                }
            }
        }
    }

    func testPairedModeCapturesAtNarrowAndWideSizes() async throws {
        try await withModel { model in
            let fixture = [
                TranscriptMessage(role: "user", text: "Review the parser change and add a focused test."),
                TranscriptMessage(role: "assistant", text: "## Parser review\nThe change preserves Unicode paths and keeps each edit explicit.\n\n```swift\nlet path = \"Sources/文 Parser.swift\"\nif path.isEmpty { return }\n```"),
                TranscriptMessage(role: "tool", text: "read\nSynthetic file content", tool: TranscriptTool(name: "read", target: "Sources/Parser.swift", status: .completed)),
                TranscriptMessage(role: "tool", text: "bash\nParserTests passed", tool: TranscriptTool(name: "bash", target: "swift test --filter ParserTests", status: .completed)),
                TranscriptMessage(role: "assistant", text: "The focused test passed. Review the change before applying it elsewhere.")
            ]
            model.state.model = "fixture/model"; model.state.thinking = "medium"
            model.state.commands = [CommandOption(name: "skill:fixture", detail: "", source: "skill"), CommandOption(name: "review", detail: "", source: "prompt")]
            for mode in MacInterfaceMode.allCases {
                for dark in mode == .pi ? [true] : [false, true] {
                    for populated in [false, true] {
                        model.interfaceMode = mode
                        model.state.messages = populated ? fixture : []
                        for width in [900, 1300] {
                            try await hosted(CompanionWindow(model: model), width: CGFloat(width), dark: dark) { host, _ in
                                try self.capture(host, name: "\(mode.rawValue)-\(dark ? "dark" : "light")-\(populated ? "conversation" : "empty")-\(width)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func editor(in root: NSView) throws -> PiEditorTextView {
        try XCTUnwrap(descendants(root).compactMap { $0 as? PiEditorTextView }.first)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
    }
    private func withModel(_ body: (CompanionModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.InterfaceModes." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: ModeFixtureSecrets(), defaults: defaults)
        let id = UUID()
        model.state.sessions = [SessionInfo(id: id, title: "Parser review", directory: "/tmp/fixture-project")]
        model.state.selected = id; model.state.phase = "idle"
        do { try await body(model) } catch { await model.shutdown(); throw error }
        await model.shutdown()
    }
    private func hosted<V: View>(_ view: V, width: CGFloat = 1000, dark: Bool = false,
                                exercise: (NSView, NSWindow) async throws -> Void) async throws {
        let content = view.environment(\.colorScheme, dark ? .dark : .light).environment(\.accessibilityEnabled, true)
            .frame(width: width, height: 740)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 740))
        defer {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.contentViewController = nil; window.close()
        }
        window.makeKeyAndOrderFront(nil)
        try await settle(controller.view)
        try await exercise(controller.view, window)
    }
    private func capture(_ host: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: "/tmp/pi-mac-interface-structure/captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
