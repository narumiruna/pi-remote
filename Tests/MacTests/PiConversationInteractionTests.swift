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
    func testEmptyConversationBlocksNativeEditingAndEnablesItAfterSessionSelection() async throws {
        for mode in MacInterfaceMode.allCases {
            try await withModel { model in
                model.interfaceMode = mode
                let session = try XCTUnwrap(model.state.selected)
                model.state.selected = nil
                let snapshot = model.state
                var opened = 0
                try await hosted(PiConversationView(model: model, openControls: { _ in opened += 1; return true }), width: 900, height: 600) { host, window in
                    let editor = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                    XCTAssertFalse(editor.isEditable)
                    let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
                    XCTAssertFalse(editor.validateUserInterfaceItem(paste))
                    editor.insertText("Must not become a lost draft", replacementRange: NSRange(location: 0, length: 0))
                    for (text, code, flags) in [("a", UInt16(0), NSEvent.ModifierFlags()), ("\r", UInt16(36), []), ("\r", UInt16(36), .option)] {
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                        editor.keyDown(with: event)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    XCTAssertEqual(editor.string, "")
                    XCTAssertEqual(model.text, "")
                    XCTAssertEqual(model.state, snapshot, "Typing or Return without a session must not send a prompt.")
                    XCTAssertEqual(opened, 0)
                    XCTAssertNil(model.fault)
                    _ = try self.accessibilityElement("pi-editor-hint", in: host, text: "Choose or resume a session")
                    if mode == .desktop {
                        _ = try self.accessibilityElement("desktop-session-phase", in: host, text: "No session loaded")
                    }
                    model.state.selected = session
                    try await Task.sleep(for: .milliseconds(150))
                    XCTAssertTrue(self.descendants(host).contains { $0 === editor })
                    XCTAssertTrue(editor.isEditable)
                    XCTAssertTrue(window.makeFirstResponder(editor))
                    editor.insertText("Loaded draft", replacementRange: NSRange(location: 0, length: 0))
                    XCTAssertEqual(model.text, "Loaded draft")
                    XCTAssertNil(model.fault)
                }
            }
        }
    }

    func testLoadedUnavailableConversationRetainsNativeUndoSelectionAndIMEWithoutSubmission() async throws {
        for mode in MacInterfaceMode.allCases {
            try await withModel { model in
                model.interfaceMode = mode
                model.text = "Keep 文 draft"
                try await hosted(PiConversationView(model: model, openControls: { _ in false })) { host, window in
                    let editor = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                    XCTAssertTrue(window.makeFirstResponder(editor))
                    let undo = try XCTUnwrap(editor.undoManager)
                    let original = editor.string
                    editor.insertText(" added", replacementRange: NSRange(location: original.utf16.count, length: 0))
                    editor.breakUndoCoalescing()
                    try await Task.sleep(for: .milliseconds(50))
                    editor.setSelectedRange(NSRange(location: 5, length: 1))
                    model.state.phase = "unavailable"
                    try await Task.sleep(for: .milliseconds(150))
                    XCTAssertTrue(editor.isEditable, "A loaded session must retain its native draft during temporary unavailability.")
                    XCTAssertTrue(editor.undoManager === undo)
                    XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 1))
                    undo.undo()
                    try await Task.sleep(for: .milliseconds(50))
                    XCTAssertEqual(model.text, original)
                    editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
                    try await self.returnKey(in: host, window: window)
                    XCTAssertEqual(model.text, original)
                    XCTAssertNil(model.fault, "Unavailable Return must not dispatch a prompt.")
                    editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
                    let marked = editor.markedRange()
                    let selection = editor.selectedRange()
                    model.state.phase = "idle"
                    try await Task.sleep(for: .milliseconds(150))
                    XCTAssertTrue(editor.hasMarkedText())
                    XCTAssertEqual(editor.markedRange(), marked)
                    XCTAssertEqual(editor.selectedRange(), selection)
                    XCTAssertTrue(editor.undoManager === undo)
                    XCTAssertNil(model.fault)
                }
            }
        }
    }

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
        try await checkDisclosureReadingPosition(mode: .pi)
    }

    func testDesktopDisclosureKeepsReadingPositionDuringStreaming() async throws {
        try await checkDisclosureReadingPosition(mode: .desktop)
    }

    private func checkDisclosureReadingPosition(mode: MacInterfaceMode) async throws {
        try await withModel { model in
            model.interfaceMode = mode
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

    func testDesktopHistoryScrollKeepsInputVisibleAndInputScrollIndependent() async throws {
        try await withModel { model in
            model.interfaceMode = .desktop
            model.state.messages = (0..<60).map { TranscriptMessage(role: "user", text: "History fixture \($0)\nSecond line\nThird line") }
            model.text = String(repeating: "Long unsent draft\n", count: 80)
            try await hosted(PiConversationView(model: model, openControls: { _ in true }), width: 400, height: 600) { host, window in
                let editor = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                let inputScroll = try XCTUnwrap(editor.enclosingScrollView)
                let history = try self.historyScroll(in: host, editor: editor)
                let initial = inputScroll.convert(inputScroll.bounds, to: host)
                XCTAssertTrue(host.visibleRect.contains(initial), "Input viewport \(initial) must fit inside \(host.visibleRect).")
                let last = try XCTUnwrap(model.state.messages.last)
                // Text selection can replace the card identifier with an exact-text accessibility node.
                let lastFrame = try self.accessibilityFrame(self.accessibilityElement("pi-message-" + last.id.uuidString, in: host, text: last.text)).insetBy(dx: -16, dy: -16)
                let dock = try self.dockScroll(in: host, editor: editor)
                let dockFrame = window.convertToScreen(dock.convert(dock.bounds, to: nil))
                XCTAssertGreaterThanOrEqual(lastFrame.minY, dockFrame.maxY - 2, "The last transcript row must be above the dock.")
                let historyFrame = window.convertToScreen(history.convert(history.bounds, to: nil))
                XCTAssertGreaterThanOrEqual(historyFrame.minY, dockFrame.maxY - 2, "The history viewport and its scrollbar must stop above the dock.")
                XCTAssertTrue(historyFrame.contains(lastFrame), "The complete last row must be visible at latest.")
                let historyBefore = history.contentView.bounds.origin
                self.scroll(history, fraction: 0)
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                XCTAssertNotEqual(history.contentView.bounds.origin, historyBefore, "Exercise the actual native history viewport.")
                XCTAssertEqual(inputScroll.convert(inputScroll.bounds, to: host).minY, initial.minY, accuracy: 1)
                XCTAssertTrue(host.visibleRect.contains(inputScroll.convert(inputScroll.bounds, to: host)))
                let first = try XCTUnwrap(model.state.messages.first)
                let olderFrame = try self.accessibilityFrame(self.accessibilityElement("pi-message-" + first.id.uuidString, in: host, text: first.text))
                XCTAssertTrue(historyFrame.contains(olderFrame), "The older transcript must be visible while input stays docked.")
                try self.capture(host, name: "desktop-history-400x600-input-visible")
                let reading = history.contentView.bounds.origin
                let inputBefore = inputScroll.contentView.bounds.origin
                self.scroll(inputScroll, fraction: 1)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertNotEqual(inputScroll.contentView.bounds.origin, inputBefore)
                XCTAssertEqual(history.contentView.bounds.origin, reading, "Scrolling the draft must not scroll history.")
                XCTAssertTrue(window.makeFirstResponder(editor))
                XCTAssertEqual(model.text, String(repeating: "Long unsent draft\n", count: 80))
            }
        }
    }

    func testPiDockMovesWithHistoryAndDoesNotInterceptWhenOutsideViewport() async throws {
        try await withModel { model in
            model.state.messages = (0..<60).map { TranscriptMessage(role: "user", text: "Flow fixture \($0)\nSecond line\nThird line") }
            try await hosted(PiConversationView(model: model, openControls: { _ in true })) { host, _ in
                let editor = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                let inputScroll = try XCTUnwrap(editor.enclosingScrollView)
                let parent = editor.superview
                let history = try self.historyScroll(in: host, editor: editor)
                let initial = inputScroll.convert(inputScroll.bounds, to: host)
                XCTAssertTrue(host.visibleRect.contains(initial))
                let oldOrigin = history.contentView.bounds.origin
                self.scroll(history, fraction: 0)
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let moved = inputScroll.convert(inputScroll.bounds, to: host)
                XCTAssertGreaterThan(abs(moved.minY - initial.minY), 200)
                XCTAssertEqual(abs(moved.minY - initial.minY), abs(history.contentView.bounds.origin.y - oldOrigin.y), accuracy: 3)
                XCTAssertFalse(host.visibleRect.intersects(moved))
                XCTAssertTrue(editor.superview === parent)
                let hit = host.hitTest(NSPoint(x: initial.midX, y: initial.midY))
                XCTAssertFalse(hit.map { $0 === editor || $0.isDescendant(of: inputScroll) } ?? false)
                self.scroll(history, fraction: 1)
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(host.visibleRect.contains(inputScroll.convert(inputScroll.bounds, to: host)))
            }
        }
    }

    func testWidgetsKeepPlacementAndOversizedDockHasIndependentScrollAccess() async throws {
        for mode in MacInterfaceMode.allCases {
            for height: CGFloat in [600, 900] {
                for width: CGFloat in [400, 900] {
                    try await withModel { model in
                        model.interfaceMode = mode
                        model.state.messages = (0..<30).map { TranscriptMessage(role: "user", text: "History \($0)\nSecond line") }
                        model.state.extensionDisplay = ExtensionDisplayState(widgets: [
                            ExtensionWidget(id: "above", text: String(repeating: "Above editor extension\n", count: 80), placement: .aboveEditor),
                            ExtensionWidget(id: "below", text: String(repeating: "Below editor extension\n", count: 80), placement: .belowEditor)
                        ])
                        try await hosted(PiConversationView(model: model, openControls: { _ in true }), width: width, height: height) { host, _ in
                            let editor = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                            let inputScroll = try XCTUnwrap(editor.enclosingScrollView)
                            let dock = try self.dockScroll(in: host, editor: editor)
                            let history = try self.historyScroll(in: host, editor: editor)
                            let reading = history.contentView.bounds.origin
                            XCTAssertGreaterThan(try XCTUnwrap(dock.documentView).bounds.height, dock.contentSize.height * 2)
                            XCTAssertLessThan(dock.frame.height, height)
                            let above = try self.accessibilityFrame(self.accessibilityElement("pi-widget-above", in: host, text: model.state.extensionDisplay?.widgets.first?.text))
                            let below = try self.accessibilityFrame(self.accessibilityElement("pi-widget-below", in: host, text: model.state.extensionDisplay?.widgets.last?.text))
                            let editorFrame = try self.accessibilityFrame(editor)
                            XCTAssertGreaterThanOrEqual(above.minY, editorFrame.maxY - 2)
                            XCTAssertLessThanOrEqual(below.maxY, editorFrame.minY + 2)
                            let target = inputScroll.convert(inputScroll.bounds, to: dock.documentView)
                            let document = try XCTUnwrap(dock.documentView)
                            let y = document.isFlipped ? target.minY : target.maxY - dock.contentSize.height
                            dock.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                            dock.reflectScrolledClipView(dock.contentView)
                            try await Task.sleep(for: .milliseconds(100))
                            host.layoutSubtreeIfNeeded()
                            XCTAssertTrue(host.visibleRect.intersects(inputScroll.convert(inputScroll.bounds, to: host)), "Oversized widgets must leave scroll access to input.")
                            self.scroll(dock, fraction: 1)
                            try await Task.sleep(for: .milliseconds(100))
                            let footer = try self.accessibilityFrame(self.accessibilityElement("pi-model-selector", in: host))
                            let visible = try XCTUnwrap(host.window).convertToScreen(host.convert(host.visibleRect, to: nil))
                            XCTAssertTrue(visible.contains(footer), "The footer must remain reachable.")
                            XCTAssertEqual(history.contentView.bounds.origin, reading, "Dock scrolling must not move history.")
                            XCTAssertTrue(self.descendants(host).contains { $0 === editor })
                        }
                    }
                }
            }
        }
    }

    func testPiNativeWheelRouteIsScopedAndRemovedWithItsView() async throws {
        var detached: PiConversationWheelView?
        try await withModel { model in
            model.state.messages = (0..<60).map { TranscriptMessage(role: "user", text: "Wheel history \($0)\nSecond line") }
            try await hosted(PiConversationView(model: model, openControls: { _ in true })) { host, window in
                let bridge = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiConversationWheelView }.first)
                detached = bridge
                XCTAssertTrue(bridge.isMonitoring)
                let editor = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                let input = try XCTUnwrap(editor.enclosingScrollView)
                let history = try XCTUnwrap(bridge.targets.history)
                XCTAssertTrue(try self.dockScroll(in: host, editor: editor) === bridge.targets.dock)
                let event = try self.wheel(deltaY: 100)
                let point = input.convert(NSPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
                let original = history.contentView.bounds.origin
                let contentHit = window.contentView?.hitTest(window.contentView?.convert(point, from: nil) ?? .zero)
                let dock = try XCTUnwrap(bridge.targets.dock)
                let diagnostics = "root=\(bridge.bounds)/\(bridge.visibleRect), point=\(bridge.convert(point, from: nil)), dock=\(dock.bounds)/\(dock.visibleRect), dockPoint=\(dock.convert(point, from: nil)), hit=\(String(describing: contentHit.map { String(describing: type(of: $0)) })), inputCanScroll=\(PiConversationWheelView.canScroll(input, deltaY: event.scrollingDeltaY)), dockCanScroll=\(PiConversationWheelView.canScroll(dock, deltaY: event.scrollingDeltaY)), delta=\(event.scrollingDeltaY)"
                XCTAssertTrue(bridge.forwardWheel(event, from: window, at: point), "An unconsumed Pi wheel over input must reach history. " + diagnostics)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertNotEqual(history.contentView.bounds.origin, original)
                self.scroll(history, fraction: 1)
                try await Task.sleep(for: .milliseconds(100))
                let currentPoint = input.convert(NSPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
                let reading = history.contentView.bounds.origin
                XCTAssertFalse(bridge.forwardWheel(try self.wheel(deltaY: 0, deltaX: 100), from: window, at: currentPoint))
                for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
                    XCTAssertFalse(bridge.forwardWheel(try self.wheel(deltaY: 100, modifiers: flags), from: window, at: currentPoint))
                }
                XCTAssertFalse(bridge.forwardWheel(event, from: window, at: NSPoint(x: -100, y: -100)))
                bridge.isEnabled = false
                XCTAssertFalse(bridge.forwardWheel(event, from: window, at: currentPoint))
                bridge.isEnabled = true
                bridge.isHidden = true
                XCTAssertFalse(bridge.forwardWheel(event, from: window, at: currentPoint))
                bridge.isHidden = false
                let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
                other.isReleasedWhenClosed = false
                XCTAssertFalse(bridge.forwardWheel(event, from: other, at: currentPoint))
                other.close()
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false
                window.beginSheet(sheet, completionHandler: { _ in })
                XCTAssertFalse(bridge.forwardWheel(event, from: window, at: currentPoint))
                window.endSheet(sheet); sheet.orderOut(nil); sheet.close()
                XCTAssertEqual(history.contentView.bounds.origin, reading)
                model.interfaceMode = .desktop
                try await Task.sleep(for: .milliseconds(150))
                let desktopReading = history.contentView.bounds.origin
                let desktopPoint = input.convert(NSPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
                XCTAssertFalse(bridge.forwardWheel(event, from: window, at: desktopPoint))
                XCTAssertEqual(history.contentView.bounds.origin, desktopReading)
            }
        }
        XCTAssertFalse(try XCTUnwrap(detached).isMonitoring)
        XCTAssertNil(detached?.window)
        weak var released: PiConversationWheelView?
        released = detached
        detached = nil
        XCTAssertNil(released, "The local monitor must not retain its owner.")
    }

    func testPiNativeWheelKeepsEditorCompletionAndOversizedDockScrollingFirst() async throws {
        try await withModel { model in
            model.state.messages = (0..<60).map { TranscriptMessage(role: "user", text: "Inner scroll \($0)\nSecond line") }
            model.text = String(repeating: "Long draft\n", count: 80)
            try await hosted(PiConversationView(model: model, openControls: { _ in true })) { host, window in
                let bridge = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiConversationWheelView }.first)
                let editor = try XCTUnwrap(self.descendants(host).compactMap { $0 as? PiEditorTextView }.first)
                let input = try XCTUnwrap(editor.enclosingScrollView)
                let history = try XCTUnwrap(bridge.targets.history)
                let event = try self.wheel(deltaY: 40)
                self.scroll(input, fraction: 0.5)
                let reading = history.contentView.bounds.origin
                let inputPoint = input.convert(NSPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
                XCTAssertTrue(PiConversationWheelView.canScroll(input, deltaY: event.scrollingDeltaY))
                XCTAssertFalse(bridge.forwardWheel(event, from: window, at: inputPoint))
                let inputBefore = input.contentView.bounds.origin
                input.scrollWheel(with: event)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertNotEqual(input.contentView.bounds.origin, inputBefore)
                XCTAssertEqual(history.contentView.bounds.origin, reading)
                model.text = "/"
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let suggestions = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first { $0.accessibilityIdentifier() == "pi-editor-suggestions" })
                self.scroll(suggestions, fraction: 0.5)
                XCTAssertTrue(PiConversationWheelView.canScroll(suggestions, deltaY: event.scrollingDeltaY))
                let suggestionPoint = suggestions.convert(NSPoint(x: suggestions.bounds.midX, y: suggestions.bounds.midY), to: nil)
                XCTAssertFalse(bridge.forwardWheel(event, from: window, at: suggestionPoint))
                model.state.extensionDisplay = ExtensionDisplayState(widgets: [ExtensionWidget(id: "oversized", text: String(repeating: "Oversized extension\n", count: 100))])
                try await Task.sleep(for: .milliseconds(150))
                let dock = try XCTUnwrap(bridge.targets.dock)
                self.scroll(dock, fraction: 0.5)
                XCTAssertTrue(PiConversationWheelView.canScroll(dock, deltaY: event.scrollingDeltaY))
                let dockPoint = dock.convert(NSPoint(x: dock.bounds.midX, y: dock.bounds.midY), to: nil)
                XCTAssertFalse(bridge.forwardWheel(event, from: window, at: dockPoint))
            }
        }
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

    private func wheel(deltaY: Int32, deltaX: Int32 = 0, modifiers: CGEventFlags = []) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: deltaY, wheel2: deltaX, wheel3: 0))
        event.flags = modifiers
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func dockScroll(in host: NSView, editor: PiEditorTextView) throws -> NSScrollView {
        try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first {
            $0 !== editor.enclosingScrollView && ($0.documentView.map { editor.isDescendant(of: $0) } ?? false)
        })
    }

    private func historyScroll(in host: NSView, editor: PiEditorTextView) throws -> NSScrollView {
        try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first {
            guard let document = $0.documentView else { return false }
            return !editor.isDescendant(of: document) && document.bounds.height > $0.contentSize.height + 100
        })
    }

    private func scroll(_ scroll: NSScrollView, fraction: CGFloat) {
        guard let document = scroll.documentView else { return }
        let range = max(0, document.bounds.height - scroll.contentSize.height)
        let y = document.bounds.minY + range * (document.isFlipped ? fraction : 1 - fraction)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
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

    private func accessibilityElement(_ identifier: String, in host: NSView, text: String? = nil) throws -> NSObject {
        var visited = Set<ObjectIdentifier>()
        let idSelector = NSSelectorFromString("accessibilityIdentifier")
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: idSelector), object.perform(idSelector)?.takeUnretainedValue() as? String == identifier { return object }
            if let text {
                for name in ["accessibilityValue", "accessibilityLabel"] {
                    let selector = NSSelectorFromString(name)
                    guard object.responds(to: selector) else { continue }
                    let value = object.perform(selector)?.takeUnretainedValue()
                    if (value as? String ?? (value as? NSAttributedString)?.string) == text { return object }
                }
            }
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

    private func hosted<V: View>(_ view: V, width: CGFloat = 1000, height: CGFloat = 650,
                                exercise: (NSView, NSWindow) async throws -> Void) async throws {
        let controller = NSHostingController(rootView: view.preferredColorScheme(.dark).environment(\.accessibilityEnabled, true).frame(width: width, height: height))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
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
