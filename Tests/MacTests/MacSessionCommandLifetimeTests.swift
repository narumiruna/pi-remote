import AppKit
import Observation
import PiRemoteCore
import SwiftUI
import Vision
import XCTest

private enum CommandLifetimeSurface: CaseIterable {
    case inspector, commands
}

@MainActor @Observable private final class CommandLifetimeState {
    var snapshot: HostSnapshot
    init(_ snapshot: HostSnapshot) { self.snapshot = snapshot }
}

private struct CommandLifetimeEvent: Equatable {
    let context: SessionContext
    let action: SessionAction
}

@MainActor private final class CommandLifetimeRequests {
    private(set) var events: [CommandLifetimeEvent] = []
    private(set) var completed: [Int] = []
    private var pending: [Int: CheckedContinuation<AppResult, Never>] = [:]
    var pendingIndices: [Int] { pending.keys.sorted() }

    func send(_ action: SessionAction, context: SessionContext) async -> AppResult {
        let index = events.count
        events.append(CommandLifetimeEvent(context: context, action: action))
        let result = await withCheckedContinuation { pending[index] = $0 }
        completed.append(index)
        return result
    }

    func finish(_ index: Int, with result: AppResult) throws {
        let continuation = try XCTUnwrap(pending.removeValue(forKey: index), "Missing pending request \(index)")
        continuation.resume(returning: result)
    }

    func finishAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(returning: .failure(.cancelled)) }
    }
}

@MainActor private struct CommandLifetimeRoot: View {
    let fixture: CommandLifetimeState
    let requests: CommandLifetimeRequests
    let surface: CommandLifetimeSurface

    var body: some View {
        // Capture the displayed context for each closure. Update the snapshot
        // without replacing the controls or changing their SwiftUI identity.
        let state = fixture.snapshot
        NavigationStack {
            switch surface {
            case .inspector:
                SessionControls(state: state, request: { action in
                    await requests.send(action, context: state.context)
                }) { _ in XCTFail("Commands must not open a file preview") }
            case .commands:
                SessionCommandsView(state: state, request: { action in
                    await requests.send(action, context: state.context)
                })
            }
        }
        .formStyle(.grouped)
        .environment(\.macInterfaceMode, .desktop)
        .environment(\.accessibilityEnabled, true)
    }
}

@MainActor private struct CommandLifetimeElement {
    let object: NSObject

    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                          "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue",
                          "accessibilityTitle": "AXTitle", "accessibilityRole": "AXRole", "accessibilityParent": "AXParent"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    var identifier: String? { value("accessibilityIdentifier") as? String }
    var role: String? { value("accessibilityRole") as? String }
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
        guard enabled, object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
}

/// Private native fixtures only. No companion, provider, listener or network is used.
@MainActor final class MacSessionCommandLifetimeTests: XCTestCase {
    private let commandID = "session-command-fixture-command"
    private let failure = RemoteFault.permissionDenied

    private func snapshot() -> HostSnapshot {
        let id = UUID()
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = id
        state.sessions = [SessionInfo(id: id, title: "Command lifetime fixture", directory: "/private/command-lifetime-fixture")]
        state.capabilities = ["sessions", "models", "thinking", "runtime-settings", "retry-controls", "session-export",
                              "session-lifecycle", "session-statistics", "last-assistant", "close-session"]
        state.models = [ModelOption(provider: "fixture", model: "model", name: "Fixture model")]
        state.model = state.models[0].id
        state.thinkingLevels = ["off", "high"]
        state.thinking = "off"
        state.runtime = RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .all, autoCompactionEnabled: true)
        state.commands = [CommandOption(name: "fixture-command", detail: "Fixture extension command", source: "extension")]
        return state
    }

    func testAdvancedCollapseRetainsPendingArgumentsFailureAndExplicitRetry() async throws {
        let fixture = CommandLifetimeState(snapshot())
        let requests = CommandLifetimeRequests()
        defer { requests.finishAll() }
        let arguments = "retained --value native-input"
        let expected = CommandLifetimeEvent(context: fixture.snapshot.context,
                                           action: .command(name: "fixture-command", arguments: arguments))

        try await hosted(fixture, requests: requests, surface: .inspector) { root, window in
            XCTAssertTrue(requests.events.isEmpty)
            try await self.setAdvanced(true, in: root, window: window)
            try await self.enterArguments(arguments, in: root, window: window)
            XCTAssertTrue(requests.events.isEmpty, "Rendering, expanding and editing must not dispatch")
            XCTAssertTrue(try self.command(in: root).press())
            try await self.settle(root)
            XCTAssertEqual(requests.events, [expected])
            XCTAssertEqual(requests.pendingIndices, [0])
            try self.assertArguments(arguments, enabled: false, in: root)
            XCTAssertFalse(try self.command(in: root).press(), "A pending command must reject a second native press")

            try await self.setAdvanced(false, in: root, window: window)
            try self.assertAdvancedContentsHidden(in: root)
            try self.assertCollapsedPending(in: root)
            self.assertNoError(in: root)
            fixture.snapshot.sequence += 1
            try await self.settle(root)
            try self.assertCollapsedPending(in: root)
            XCTAssertEqual(requests.events, [expected], "Collapse and an unrelated render must not replay the command")

            try await self.setAdvanced(true, in: root, window: window)
            try self.assertArguments(arguments, enabled: false, in: root)
            XCTAssertFalse(try self.command(in: root).press())
            XCTAssertEqual(requests.events, [expected], "Reopening must preserve the pending guard")
            try await self.setAdvanced(false, in: root, window: window)
            try requests.finish(0, with: .failure(self.failure))
            try await self.settle(root)
            XCTAssertEqual(requests.completed, [0])
            XCTAssertTrue(requests.pendingIndices.isEmpty)
            XCTAssertFalse(self.hasPending(in: root))
            try self.assertError(in: root)
            try self.assertAdvancedContentsHidden(in: root)
            XCTAssertEqual(requests.events, [expected])

            try await self.setAdvanced(true, in: root, window: window)
            try self.assertError(in: root)
            try self.assertArguments(arguments, enabled: true, in: root)
            XCTAssertTrue(try self.command(in: root).enabled)
            fixture.snapshot.sequence += 1
            try await self.settle(root)
            XCTAssertEqual(requests.events, [expected], "Failure and re-expansion must not retry automatically")

            XCTAssertTrue(try self.command(in: root).press(), "Only an explicit retry may dispatch again")
            try await self.settle(root)
            XCTAssertEqual(requests.events, [expected, expected])
            XCTAssertEqual(requests.pendingIndices, [1])
            self.assertNoError(in: root)
            try self.assertArguments(arguments, enabled: false, in: root)
            try await self.setAdvanced(false, in: root, window: window)
            try self.assertCollapsedPending(in: root)
            try requests.finish(1, with: .ok)
            try await self.settle(root)
            XCTAssertFalse(self.hasPending(in: root))
            self.assertNoError(in: root)
            try await self.setAdvanced(true, in: root, window: window)
            try self.assertArguments(arguments, enabled: true, in: root)
            XCTAssertTrue(try self.command(in: root).enabled)
            XCTAssertEqual(requests.events, [expected, expected])
            XCTAssertEqual(requests.completed, [0, 1])
            XCTAssertTrue(requests.pendingIndices.isEmpty)
        }
    }

    private func assertAdvancedContentsHidden(in root: NSView) throws {
        // AppKit keeps offscreen Form cells in its native subtree after collapse.
        // Check the painted surface, not the cached accessibility identifiers.
        let pixels = try MacDebugController.snapshot(window: XCTUnwrap(root.window))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: pixels.value).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        for label in ["/fixture-command", "fixture extension command", "command arguments"] {
            XCTAssertFalse(text.contains(label), "Collapsed Advanced must not display: " + label)
        }
    }

    func testChangedContextIgnoresOldCompletionWhileNewCommandIsPending() async throws {
        for surface in CommandLifetimeSurface.allCases {
            let fixture = CommandLifetimeState(snapshot())
            let requests = CommandLifetimeRequests()
            defer { requests.finishAll() }
            let oldContext = fixture.snapshot.context
            let old = CommandLifetimeEvent(context: oldContext, action: .command(name: "fixture-command", arguments: "old arguments"))

            try await hosted(fixture, requests: requests, surface: surface) { root, window in
                if surface == .inspector { try await self.setAdvanced(true, in: root, window: window) }
                try await self.enterArguments("old arguments", in: root, window: window)
                XCTAssertTrue(requests.events.isEmpty)
                XCTAssertTrue(try self.command(in: root).press())
                try await self.settle(root)
                try self.assertArguments("old arguments", enabled: false, in: root)
                XCTAssertFalse(try self.command(in: root).enabled)
                XCTAssertEqual(requests.events, [old])
                XCTAssertEqual(requests.pendingIndices, [0])

                var next = fixture.snapshot
                if surface == .inspector {
                    let id = UUID()
                    next.selected = id
                    next.sessions = [SessionInfo(id: id, title: "New context", directory: "/private/new-command-lifetime-fixture")]
                } else {
                    next.epoch = UUID()
                }
                XCTAssertNotEqual(next.context, oldContext)
                fixture.snapshot = next
                try await self.settle(root)
                if surface == .inspector {
                    XCTAssertEqual(try self.advanced(in: root).value("accessibilityValue") as? Int, 1,
                                   "A context update must not remount the controls or close Advanced")
                }
                try self.assertArguments("", enabled: true, in: root)
                XCTAssertTrue(try self.command(in: root).enabled)
                self.assertNoError(in: root)
                XCTAssertEqual(requests.events, [old], "Changing context must not send or replay a command")
                XCTAssertEqual(requests.pendingIndices, [0], "The old request must still be suspended")

                try await self.enterArguments("new arguments", in: root, window: window)
                let new = CommandLifetimeEvent(context: next.context,
                                               action: .command(name: "fixture-command", arguments: "new arguments"))
                XCTAssertEqual(requests.events, [old])
                XCTAssertTrue(try self.command(in: root).press())
                try await self.settle(root)
                XCTAssertEqual(requests.events, [old, new])
                XCTAssertEqual(requests.pendingIndices, [0, 1])
                try self.assertArguments("new arguments", enabled: false, in: root)

                try requests.finish(0, with: .failure(self.failure))
                try await self.settle(root)
                XCTAssertEqual(requests.completed, [0])
                XCTAssertEqual(requests.pendingIndices, [1])
                self.assertNoError(in: root)
                try self.assertArguments("new arguments", enabled: false, in: root)
                XCTAssertFalse(try self.command(in: root).enabled, "The old defer must not clear the new pending guard")
                XCTAssertFalse(try self.command(in: root).press())
                if surface == .inspector {
                    try await self.setAdvanced(false, in: root, window: window)
                    try self.assertCollapsedPending(in: root)
                    self.assertNoError(in: root)
                    try await self.setAdvanced(true, in: root, window: window)
                    try self.assertArguments("new arguments", enabled: false, in: root)
                    XCTAssertFalse(try self.command(in: root).press())
                }
                XCTAssertEqual(requests.events, [old, new], "Old completion and re-rendering must not dispatch")

                try requests.finish(1, with: .ok)
                try await self.settle(root)
                try self.assertArguments("new arguments", enabled: true, in: root)
                XCTAssertTrue(try self.command(in: root).enabled)
                self.assertNoError(in: root)
                XCTAssertFalse(self.hasPending(in: root))
                fixture.snapshot.sequence += 1
                try await self.settle(root)
                XCTAssertEqual(requests.events, [old, new])
                XCTAssertEqual(requests.completed, [0, 1])
                XCTAssertTrue(requests.pendingIndices.isEmpty)
            }
        }
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

    private func elements(_ root: NSView) -> [CommandLifetimeElement] {
        var objects: [NSObject] = descendants(root)
        if let window = root.window {
            // SwiftUI creates some native labels and cells only after AX hit tests.
            for y in stride(from: CGFloat(8), to: root.bounds.height, by: 16) {
                for x in stride(from: CGFloat(8), to: root.bounds.width, by: 16) {
                    let point = window.convertPoint(toScreen: root.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = root.accessibilityHitTest(point) as? NSObject { objects.append(hit) }
                }
            }
        }
        var seen = Set<ObjectIdentifier>(), result: [CommandLifetimeElement] = [], index = 0
        while index < objects.count, seen.count < 8192 {
            let object = objects[index]
            index += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let element = CommandLifetimeElement(object: object)
            result.append(element)
            objects.append(contentsOf: element.value("accessibilityChildren") as? [NSObject] ?? [])
            if let parent = element.value("accessibilityParent") as? NSObject,
               !(parent is NSWindow), !(parent is NSApplication) { objects.append(parent) }
        }
        return result
    }

    private func command(in root: NSView) throws -> CommandLifetimeElement {
        let all = elements(root)
        // The Commands Form can replace child identifiers. AppKit combines the
        // two command label lines in its native button description.
        let labels = ["/fixture-command", "/fixture-command, Fixture extension command", "/fixture-command\nFixture extension command"]
        return try XCTUnwrap(all.first { $0.identifier == commandID && $0.role == "AXButton" }
            ?? all.first { node in node.role == "AXButton" && labels.contains(where: node.hasText) }, "Missing native fixture command")
    }

    private func advanced(in root: NSView) throws -> CommandLifetimeElement {
        let all = elements(root)
        return try XCTUnwrap(all.first { $0.identifier == "mac-session-advanced" }
            ?? all.first { $0.role == "AXDisclosureTriangle" && $0.hasText("Advanced") }, "Missing Advanced disclosure")
    }

    private func argumentField(in root: NSView) throws -> NSTextField {
        let fields = descendants(root).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        if let field = fields.first(where: {
            $0.accessibilityIdentifier() == "command-arguments" || $0.cell?.accessibilityIdentifier() == "command-arguments"
                || $0.placeholderString == "Command arguments"
        }) { return field }
        let all = elements(root)
        let identified = all.first { $0.identifier == "command-arguments" && $0.role == "AXTextField" }
        let label = all.first { $0.hasText("Command arguments") }?.frame
        let element = try XCTUnwrap(identified ?? all.first {
            guard $0.role == "AXTextField", let frame = $0.frame, let label else { return false }
            return frame.minX >= label.maxX && frame.minY < label.maxY && frame.maxY > label.minY
        }, "Missing Command arguments AX text field")
        if let field = element.object as? NSTextField ?? (element.object as? NSCell)?.controlView as? NSTextField { return field }
        let frame = try XCTUnwrap(element.frame)
        let window = try XCTUnwrap(root.window)
        return try XCTUnwrap(fields.first {
            let native = window.convertToScreen($0.convert($0.bounds, to: nil))
            return native.intersects(frame) && abs(native.midY - frame.midY) < 4
        }, "Missing native NSTextField for Command arguments")
    }

    private func enterArguments(_ text: String, in root: NSView, window: NSWindow) async throws {
        let field = try argumentField(in: root)
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "Command arguments must use a native field editor")
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(root)
        XCTAssertEqual(try argumentField(in: root).stringValue, text)
    }

    private func assertArguments(_ text: String, enabled: Bool, in root: NSView,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let field = try argumentField(in: root)
        XCTAssertEqual(field.stringValue, text, file: file, line: line)
        XCTAssertEqual(field.isEnabled, enabled, file: file, line: line)
    }

    private func hasPending(in root: NSView) -> Bool {
        elements(root).contains { $0.identifier == "session-command-pending" || $0.hasText("Command in progress") }
    }

    private func assertCollapsedPending(in root: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try advanced(in: root).value("accessibilityValue") as? Int, 0, file: file, line: line)
        XCTAssertTrue(hasPending(in: root), "Pending status must remain visible outside Advanced", file: file, line: line)
    }

    private func assertError(in root: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let all = elements(root)
        _ = try XCTUnwrap(all.first { $0.hasText(failure.explanation) }, "The same failure must remain visible", file: file, line: line)
    }

    private func assertNoError(in root: NSView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(elements(root).contains { $0.identifier == "session-command-error" || $0.hasText(failure.explanation) },
                       "An old or cleared error must not be visible", file: file, line: line)
    }

    private func setAdvanced(_ expanded: Bool, in root: NSView, window: NSWindow) async throws {
        let control = try advanced(in: root)
        XCTAssertEqual(control.role, "AXDisclosureTriangle")
        XCTAssertTrue(control.enabled)
        XCTAssertEqual(control.value("accessibilityValue") as? Int, expanded ? 0 : 1)
        let frame = try XCTUnwrap(control.frame)
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.minX + 26, y: frame.midY))
        let now = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: now, windowNumber: window.windowNumber, context: nil, eventNumber: 7301, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: now + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 7302, clickCount: 1, pressure: 0))
        window.makeKeyAndOrderFront(nil)
        // Form-level disclosure headers have no working AXPress. Queue release
        // before mouseDown because AppKit can enter a native tracking loop.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            if release.windowNumber == window.windowNumber && release.eventNumber == up.eventNumber {
                window.sendEvent(release)
            } else {
                NSApp.postEvent(release, atStart: false)
            }
        }
        try await settle(root)
        XCTAssertEqual(try advanced(in: root).value("accessibilityValue") as? Int, expanded ? 1 : 0)
    }

    private func settle(_ root: NSView) async throws {
        root.layoutSubtreeIfNeeded()
        _ = elements(root) // Warm AX before the next layout turn.
        try await Task.sleep(for: .milliseconds(200))
        root.layoutSubtreeIfNeeded()
    }

    private func hosted(_ fixture: CommandLifetimeState, requests: CommandLifetimeRequests, surface: CommandLifetimeSurface,
                        exercise: (NSView, NSWindow) async throws -> Void) async throws {
        _ = NSApplication.shared
        let size = NSSize(width: 320, height: surface == .inspector ? 2400 : 1400)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: CommandLifetimeRoot(fixture: fixture, requests: requests, surface: surface)
            .frame(width: size.width, height: size.height))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(size)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(controller.view)
        try await exercise(controller.view, window)
    }
}
