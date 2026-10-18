import AppKit
import PiRemoteCore
import SwiftUI
import XCTest

@MainActor private struct DialogAccessibility {
    let object: NSObject

    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let result = object.perform(selector)?.takeUnretainedValue() { return result }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    func boolean(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }

    func frame() throws -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { throw RemoteFault.unavailable }
        typealias Method = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }

    func press() {
        if let button = object as? NSButton { button.performClick(nil) }
        else { _ = boolean("accessibilityPerformPress") }
    }
}

@MainActor final class PiExtensionDialogTests: XCTestCase {
    func testLongValidRequestsScrollWithoutMovingAnswerControlsAndRetainNativeInput() async throws {
        for mode in MacInterfaceMode.allCases {
            for method in ["confirm", "select", "input", "editor"] {
                let dialog = fixture(method)
                var requests: [SessionAction] = []
                try await hosted(dialog, mode: mode, request: { requests.append($0); return .ok }) { host, sheet in
                    XCTAssertTrue(requests.isEmpty, "Presentation must not answer a request.")
                    let action = method == "confirm" ? "confirm" : method == "select" ? "select" : "submit"
                    let button = try self.element("extension-dialog-" + action, in: host)
                    let cancel = try self.element("extension-dialog-cancel", in: host)
                    let visible = sheet.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -1, dy: -1)
                    let original = try button.frame()
                    XCTAssertTrue(button.boolean("isAccessibilityEnabled"))
                    XCTAssertTrue(cancel.boolean("isAccessibilityEnabled"))
                    XCTAssertTrue(visible.contains(original))
                    XCTAssertTrue(visible.contains(try cancel.frame()))
                    if method == "confirm" {
                        XCTAssertTrue(visible.contains(try self.element("extension-dialog-no", in: host).frame()))
                    }
                    let scroll = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first {
                        ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 1_000
                    })
                    XCTAssertGreaterThan(scroll.contentSize.height, 50)
                    XCTAssertLessThanOrEqual(scroll.frame.height, 221)
                    let requestFrame = sheet.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                    XCTAssertFalse(requestFrame.intersects(original), "Answer buttons must stay outside request scrolling.")
                    let before = scroll.contentView.bounds.origin
                    self.scrollToEnd(scroll)
                    try await self.settle(host)
                    XCTAssertNotEqual(scroll.contentView.bounds.origin, before)
                    XCTAssertEqual(try button.frame(), original)
                    XCTAssertTrue(visible.contains(try cancel.frame()))

                    var response = dialog.text
                    if method != "confirm" {
                        let input = try XCTUnwrap(sheet.firstResponder as? NSTextView, "Native input must have initial focus.")
                        XCTAssertTrue(input.isEditable)
                        let replacement = method == "select" ? "Second" : "Edited response"
                        input.insertText(replacement, replacementRange: NSRange(location: 0, length: input.string.utf16.count))
                        // Apply the native edit to SwiftUI's binding before starting composition.
                        try await self.settle(host)
                        if method == "editor" {
                            let document = try XCTUnwrap(scroll.documentView)
                            let startY = document.isFlipped ? 0 : max(0, document.bounds.height - scroll.contentSize.height)
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: startY))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try await self.settle(host)
                            let origin = scroll.contentView.bounds.origin
                            let undo = input.undoManager
                            input.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: input.selectedRange())
                            XCTAssertTrue(input.hasMarkedText())
                            let markedRange = input.markedRange()
                            let composingText = input.string
                            self.scrollToEnd(scroll)
                            try await self.settle(host)
                            XCTAssertNotEqual(scroll.contentView.bounds.origin, origin)
                            XCTAssertTrue(sheet.firstResponder === input)
                            XCTAssertTrue(input.hasMarkedText(), "Request scrolling must not reset IME composition.")
                            XCTAssertEqual(input.markedRange(), markedRange)
                            XCTAssertEqual(input.string, composingText)
                            XCTAssertTrue(input.undoManager === undo)
                            input.unmarkText()
                        }
                        response = method == "select" ? "Second choice" : input.string
                        try await self.settle(host)
                    }
                    let active = try self.element("extension-dialog-" + action, in: host)
                    XCTAssertTrue(active.boolean("isAccessibilityEnabled"))
                    active.press()
                    try await self.settle(host)
                    let expected: SessionAction = method == "confirm"
                        ? .answer(dialog: dialog.id, value: nil, confirmed: true, cancelled: false)
                        : .answer(dialog: dialog.id, value: response, confirmed: nil, cancelled: false)
                    XCTAssertEqual(requests, [expected])
                    XCTAssertFalse(try self.element("extension-dialog-cancel", in: host).boolean("isAccessibilityEnabled"))
                    active.press()
                    try await self.settle(host)
                    XCTAssertEqual(requests, [expected], "A successful answer must not be sent again while the sheet closes.")
                }
            }
        }
    }

    func testInlineFailureRemainsScrollableAndCancelCanRetryTheSameRequest() async throws {
        let dialog = fixture("confirm")
        var requests: [SessionAction] = []
        try await hosted(dialog, request: { action in
            requests.append(action)
            return requests.count == 1 ? .failure(.unknownOutcome) : .ok
        }) { host, sheet in
            try self.element("extension-dialog-confirm", in: host).press()
            try await self.settle(host)
            let scroll = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 1_000
            })
            let error = try self.element("extension-dialog-error", in: host)
            XCTAssertTrue([error.value("accessibilityValue"), error.value("accessibilityLabel")].contains {
                $0 as? String == RemoteFault.unknownOutcome.explanation
            })
            let visible = sheet.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -1, dy: -1)
            let errorFrame = try error.frame()
            let viewport = sheet.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            XCTAssertTrue(visible.contains(errorFrame), "Answer failure must be visible without scrolling the request.")
            XCTAssertFalse(viewport.intersects(errorFrame), "Answer failure must stay outside request scrolling.")
            var buttonFrames: [String: NSRect] = [:]
            for action in ["cancel", "no", "confirm"] {
                let button = try self.element("extension-dialog-" + action, in: host)
                XCTAssertTrue(button.boolean("isAccessibilityEnabled"))
                let frame = try button.frame()
                XCTAssertTrue(visible.contains(frame))
                buttonFrames[action] = frame
            }
            let origin = scroll.contentView.bounds.origin
            self.scrollToEnd(scroll)
            try await self.settle(host)
            XCTAssertNotEqual(scroll.contentView.bounds.origin, origin, "The request must remain scrollable after an answer failure.")
            XCTAssertEqual(try self.element("extension-dialog-error", in: host).frame(), errorFrame)
            for action in ["cancel", "no", "confirm"] {
                let button = try self.element("extension-dialog-" + action, in: host)
                XCTAssertTrue(button.boolean("isAccessibilityEnabled"))
                XCTAssertEqual(try button.frame(), try XCTUnwrap(buttonFrames[action]))
            }
            try self.element("extension-dialog-cancel", in: host).press()
            try await self.settle(host)
            XCTAssertEqual(requests, [
                .answer(dialog: dialog.id, value: nil, confirmed: true, cancelled: false),
                .answer(dialog: dialog.id, value: nil, confirmed: nil, cancelled: true)
            ])
        }
    }

    func testPendingAnswerBlocksConcurrentAnswersAndStaysDisabledAfterSuccess() async throws {
        let dialog = fixture("confirm")
        var requests: [SessionAction] = []
        var pending: CheckedContinuation<AppResult, Never>?
        defer { pending?.resume(returning: .failure(.cancelled)) }
        try await hosted(dialog, request: { action in
            requests.append(action)
            return await withCheckedContinuation { pending = $0 }
        }) { host, _ in
            let yes = try self.element("extension-dialog-confirm", in: host)
            yes.press()
            yes.press()
            try await self.settle(host)
            try self.element("extension-dialog-cancel", in: host).press()
            XCTAssertEqual(requests.count, 1)
            XCTAssertFalse(try self.element("extension-dialog-confirm", in: host).boolean("isAccessibilityEnabled"))
            pending?.resume(returning: .ok)
            pending = nil
            try await self.settle(host)
            XCTAssertFalse(try self.element("extension-dialog-confirm", in: host).boolean("isAccessibilityEnabled"))
            XCTAssertEqual(requests, [.answer(dialog: dialog.id, value: nil, confirmed: true, cancelled: false)])
        }
    }

    private func fixture(_ method: String) -> ExtensionDialog {
        // These multiline strings remain within the host's 512/4,096-byte request limits.
        let title = String(repeating: "Title\n", count: 60)
        let message = String(repeating: "Request line\n", count: 250)
        XCTAssertLessThanOrEqual(title.utf8.count, 512)
        XCTAssertLessThanOrEqual(message.utf8.count, 4_096)
        return ExtensionDialog(id: "long-" + method, method: method, title: title, message: message,
                               options: ["First choice", "Second choice"], text: "Prefilled response", expires: nil)
    }

    private func scrollToEnd(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

    private func element(_ identifier: String? = nil, text: String? = nil, in host: NSView) throws -> DialogAccessibility {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) -> DialogAccessibility? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let candidate = DialogAccessibility(object: object)
            if let identifier, candidate.value("accessibilityIdentifier") as? String == identifier { return candidate }
            if let text, [candidate.value("accessibilityValue"), candidate.value("accessibilityLabel")].contains(where: { $0 as? String == text }) { return candidate }
            for child in candidate.value("accessibilityChildren") as? [NSObject] ?? [] {
                if let result = visit(child) { return result }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let result = visit(child) { return result } }
            }
            return nil
        }
        return try XCTUnwrap(visit(host), "Missing dialog element: " + (identifier ?? text ?? "unknown"))
    }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
    }

    private func hosted(_ dialog: ExtensionDialog, mode: MacInterfaceMode = .pi,
                        request: @escaping (SessionAction) async throws -> AppResult,
                        exercise: (NSView, NSWindow) async throws -> Void) async throws {
        // Match the product sheet bounds in its 900 × 600 parent window.
        let content = Color.clear.frame(width: 900, height: 600)
            .sheet(isPresented: .constant(true)) {
                NavigationStack { PiExtensionDialog(dialog: dialog, request: request) }
                    .environment(\.macInterfaceMode, mode)
                    .environment(\.accessibilityEnabled, true)
                    .frame(width: 600, height: 560)
            }
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        defer {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil); window.contentViewController = nil; window.close()
        }
        window.makeKeyAndOrderFront(nil)
        try await settle(controller.view)
        let sheet = try XCTUnwrap(window.sheets.first)
        let host = try XCTUnwrap(sheet.contentView)
        try await settle(host)
        XCTAssertLessThanOrEqual(sheet.frame.width, window.frame.width)
        XCTAssertLessThanOrEqual(sheet.frame.height, window.frame.height)
        try await exercise(host, sheet)
    }
}
