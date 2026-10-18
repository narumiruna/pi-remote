import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import Vision
import XCTest

private final class MinimalNavigationSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws { XCTFail("Navigation must not write credentials") }
    func remove(_ account: String) throws { XCTFail("Navigation must not revoke credentials") }
}

private struct MinimalNavigationVisibility: Encodable {
    let version = 1
    let closed: Set<UUID>
}

@MainActor private struct MinimalNavigationElement {
    let object: NSObject

    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                          "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue",
                          "accessibilityRole": "AXRole", "accessibilityParent": "AXParent",
                          "accessibilitySelectedText": "AXSelectedText", "accessibilityTitle": "AXTitle"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    var identifier: String? { value("accessibilityIdentifier") as? String }
    var role: String? { value("accessibilityRole") as? String }
    var label: String { value("accessibilityLabel") as? String ?? "" }
    func hasText(_ text: String) -> Bool {
        label == text || value("accessibilityValue") as? String == text || value("accessibilityTitle") as? String == text
    }
    var frame: NSRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return nil }
        typealias Read = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Read.self)(object, selector)
    }
    func press() -> Bool {
        if let button = object as? NSButton ?? (object as? NSButtonCell)?.controlView as? NSButton {
            guard button.isEnabled else { return false }
            button.performClick(nil)
            return true
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
}

/// Track the actual SwiftUI row context menu. No private menu actions are called.
@MainActor private final class MinimalNavigationContextMenu: NSObject {
    private var menu: NSMenu?
    private var inspect: ((NSMenu) -> Void)?
    private let window: NSWindow
    private let selection: String?
    private let deadline = Date().addingTimeInterval(2)

    private init(window: NSWindow, selection: String?) { self.window = window; self.selection = selection }

    static func open<Value>(at frame: NSRect, in window: NSWindow, selecting title: String? = nil,
                            inspect: @escaping (NSMenu) throws -> Value) throws -> Value {
        let tracker = MinimalNavigationContextMenu(window: window, selection: title)
        var result: Result<Value, Error>?
        tracker.inspect = { menu in result = Result { try inspect(menu) } }
        NotificationCenter.default.addObserver(tracker, selector: #selector(began(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        let timer = Timer(timeInterval: 0.04, target: tracker, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate(); NotificationCenter.default.removeObserver(tracker) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for (type, pressure) in [(NSEvent.EventType.rightMouseDown, Float(1)), (.rightMouseUp, Float(0))] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: pressure))
            window.sendEvent(event)
        }
        return try XCTUnwrap(result, "The native row context menu did not open").get()
    }

    @objc private func began(_ notification: Notification) { menu = notification.object as? NSMenu }

    private func post(_ text: String, code: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    @objc private func tick(_ timer: Timer) {
        guard let menu else { return }
        if let inspect, menu.numberOfItems > 0 {
            self.inspect = nil
            inspect(menu)
            guard let selection else { menu.cancelTrackingWithoutAnimation(); return }
            let enabled = menu.items.filter { $0.isEnabled && !$0.isSeparatorItem && !$0.isHidden && $0.action != nil }
            guard let target = enabled.firstIndex(where: { $0.title == selection }) else {
                menu.cancelTrackingWithoutAnimation(); return
            }
            let current = enabled.firstIndex { $0 === menu.highlightedItem }
            let steps = current.map { (target - $0 + enabled.count) % enabled.count } ?? target + 1
            for _ in 0..<steps { post("\u{f701}", code: 125) }
            post("\r", code: 36)
        } else if Date() >= deadline { menu.cancelTrackingWithoutAnimation() }
    }
}

/// Private native fixtures only. Captures contain synthetic data, not provider or user data.
@MainActor final class MacMinimalNavigationTests: XCTestCase {
    private let retiredIDs = ["desktop-session-controls", "desktop-welcome-files", "desktop-welcome-commands",
                              "desktop-welcome-new-session", "desktop-commands"]

    private func fixture(closed: Set<UUID> = [], corruptVisibility: Bool = false,
                         _ body: (CompanionModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.MinimalNavigation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        if corruptVisibility { defaults.set("unreadable-private-fixture", forKey: "closedSessionIDs") }
        else if !closed.isEmpty {
            defaults.set(try JSONEncoder().encode(MinimalNavigationVisibility(closed: closed)), forKey: "closedSessionIDs")
        }
        let model = CompanionModel(support: root, secrets: MinimalNavigationSecrets(), defaults: defaults,
                                   debugDirectory: root.appendingPathComponent("debug"))
        XCTAssertNil(model.startupError)
        XCTAssertFalse(model.debug.enabled)
        model.interfaceMode = .desktop
        do { try await body(model) } catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    private func sessions(_ count: Int = 2) -> [SessionInfo] {
        (0..<count).map { index in
            SessionInfo(id: UUID(), title: "Private saved session \(index)",
                        directory: index.isMultiple(of: 2) ? "/tmp/minimal-fixture/alpha" : "/tmp/minimal-fixture/beta")
        }
    }

    private func install(_ rows: [SessionInfo], in model: CompanionModel, selected: UUID? = nil) {
        model.state.sessions = rows
        model.state.selected = selected
        model.state.phase = "idle"
        model.sidebarVisible = true
        model.inspectorVisible = false
        model.expandedWorkspaces = Set(rows.map(\.directory))
        model.text = "Unsent private draft 文"
    }

    private func settle(_ root: NSView) async throws {
        root.layoutSubtreeIfNeeded()
        _ = elements(root)
        try await Task.sleep(for: .milliseconds(220))
        root.layoutSubtreeIfNeeded()
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

    private func elements(_ root: NSView) -> [MinimalNavigationElement] {
        var pending: [NSObject] = descendants(root)
        if let window = root.window {
            let scopes = [root] + descendants(root).filter { $0 is NSScrollView }
            for scope in scopes {
                for y in stride(from: CGFloat(6), to: scope.bounds.height, by: 12) {
                    for x in stride(from: CGFloat(6), to: scope.bounds.width, by: 24) {
                        let point = window.convertPoint(toScreen: scope.convert(NSPoint(x: x, y: y), to: nil))
                        if let hit = scope.accessibilityHitTest(point) as? NSObject { pending.append(hit) }
                    }
                }
            }
        }
        var seen = Set<ObjectIdentifier>(), result: [MinimalNavigationElement] = [], index = 0
        while index < pending.count, seen.count < 8192 {
            let object = pending[index]; index += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let element = MinimalNavigationElement(object: object)
            result.append(element)
            pending.append(contentsOf: element.value("accessibilityChildren") as? [NSObject] ?? [])
        }
        return result
    }

    private func element(_ id: String, in root: NSView) throws -> MinimalNavigationElement {
        try XCTUnwrap(elements(root).first { $0.identifier == id }, "Missing native element: " + id)
    }

    private func hasText(_ text: String, in root: NSView) -> Bool { elements(root).contains { $0.hasText(text) } }

    private func menu(_ id: String, in root: NSView) throws -> NSPopUpButton {
        let title = id == "mac-session-menu" ? "Session" : "Actions"
        return try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityIdentifier() == id || $0.title == title || $0.cell?.accessibilityIdentifier() == id
        }, "Missing native menu: " + id)
    }

    private func select(_ title: String, menu id: String, in root: NSView) async throws {
        try await MacNativeMenuTracking.select(title, from: menu(id, in: root))
        try await settle(root)
    }

    private func click(_ frame: NSRect, in window: NSWindow) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Native buttons can run a tracking loop in mouseDown. Other SwiftUI
        // controls return immediately. Deliver release in both cases.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            XCTAssertEqual(release.windowNumber, window.windowNumber)
            window.sendEvent(release)
        }
    }

    private func expand(_ id: String, in root: NSView, window: NSWindow) async throws {
        if let node = elements(root).first(where: { $0.identifier == id }) {
            if !node.press() { try click(try XCTUnwrap(node.frame), in: window) }
        } else if id == "mac-session-details" {
            try clickRendered("Details", window: window)
        } else { _ = try element(id, in: root) }
        try await settle(root)
    }

    private func sidebarRow(_ id: UUID, in root: NSView, window: NSWindow) throws -> (NSTableView, Int) {
        let frame = try XCTUnwrap(try element("mac-session-" + id.uuidString, in: root).frame)
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for table in descendants(root).compactMap({ $0 as? NSTableView }) {
            let local = table.convert(point, from: nil)
            let row = table.row(at: local)
            if table.bounds.contains(local), row >= 0 { return (table, row) }
        }
        XCTFail("Saved sidebar row must belong to a native selectable table")
        throw RemoteFault.unavailable
    }

    private func selectRow(_ row: Int, in table: NSTableView, window: NSWindow) async throws {
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        XCTAssertTrue(window.makeFirstResponder(table))
        let current = table.selectedRow
        let distance = current < 0 ? row + 1 : abs(row - current)
        let up = current >= 0 && row < current
        for _ in 0..<distance {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: up ? "\u{f700}" : "\u{f701}", charactersIgnoringModifiers: up ? "\u{f700}" : "\u{f701}",
                isARepeat: false, keyCode: up ? 126 : 125))
            table.keyDown(with: event)
        }
        if let root = window.contentView { try await settle(root) }
    }

    private func key(_ text: String, code: UInt16, window: NSWindow) async throws {
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.unhide()
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        for _ in 0..<5 {
            if !NSApp.isHidden { break }
            try await Task.sleep(for: .milliseconds(80))
            NSRunningApplication.current.unhide()
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "Missing global keyboard action: " + text)
        if let root = window.contentView { try await settle(root) }
    }

    private func scrollBottom(_ root: NSView) async throws {
        for _ in 0..<3 {
            for scroll in descendants(root).compactMap({ $0 as? NSScrollView }) {
                guard let document = scroll.documentView else { continue }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            try await settle(root)
        }
    }

    private func renderedText(_ window: NSWindow) throws -> String {
        let image = try MacDebugController.snapshot(window: window).value
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func clickRendered(_ title: String, window: NSWindow) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let image = try MacDebugController.snapshot(window: window).value
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observation = try XCTUnwrap(request.results?.first {
            let value = $0.topCandidates(1).first?.string.trimmingCharacters(in: CharacterSet(charactersIn: ">› "))
            return value == title
        }, "Missing rendered native control: " + title)
        let bounds = observation.boundingBox
        let content = try XCTUnwrap(window.contentView)
        let rect = NSRect(x: bounds.minX * content.bounds.width, y: bounds.minY * content.bounds.height,
                          width: bounds.width * content.bounds.width, height: bounds.height * content.bounds.height)
        let hit = title == "Details" ? NSRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height) : rect
        try click(window.convertToScreen(hit), in: window)
    }

    private func dump(_ root: NSView, name: String) throws {
        try FileManager.default.createDirectory(atPath: "/tmp/pi-minimal-desktop", withIntermediateDirectories: true)
        let text = elements(root).map {
            "\(type(of: $0.object)) id=\($0.identifier ?? "") label=\($0.label) value=\($0.value("accessibilityValue") ?? "") role=\($0.role ?? "") frame=\(String(describing: $0.frame))"
        }.joined(separator: "\n")
        try text.write(toFile: "/tmp/pi-minimal-desktop/navigation-\(name)-ax.txt", atomically: true, encoding: .utf8)
        if let window = root.window {
            try renderedText(window).write(toFile: "/tmp/pi-minimal-desktop/navigation-\(name)-ocr.txt", atomically: true, encoding: .utf8)
        }
    }

    private func assertSummary(_ text: String, in root: NSView, window: NSWindow) throws {
        if hasText(text, in: root) { return }
        // SwiftUI can render static Text without publishing an AX child.
        let visible = try renderedText(window).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "•", with: "·")
        XCTAssertTrue(visible.contains(text), "Missing visible diagnostic counts: \(text); OCR: \(visible)")
    }

    func testConversationAndLoadedSessionAliasesSelectTheSameNativeSidebarRowWithoutRuntimeMutation() async throws {
        try await fixture { model in
            let rows = self.sessions()
            self.install(rows, in: model, selected: rows[0].id)
            model.state.phase = "working"
            let before = model.state
            let runtime = await model.coordinator?.state()
            try await withMacNativeRootWindow(model) { root, window in
                for destination in [MacDestination.conversation, .session(rows[0].id), .conversation] {
                    model.destination = destination
                    try await self.settle(root)
                    let (table, row) = try self.sidebarRow(rows[0].id, in: root, window: window)
                    XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: row), "Both live aliases must select the loaded row")
                    XCTAssertEqual(model.destination, destination, "Canonical selection must not rewrite the route")
                    XCTAssertEqual(model.state, before)
                    XCTAssertEqual(model.text, "Unsent private draft 文")
                    XCTAssertFalse(model.openingSession)
                    XCTAssertNil(model.fault)
                }
            }
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testNativeSavedRowSelectionPreviewsWithoutActivatingOrStoppingLoadedWork() async throws {
        try await fixture { model in
            let rows = self.sessions()
            self.install(rows, in: model, selected: rows[0].id)
            model.destination = .conversation
            model.state.phase = "working"
            let before = model.state
            let runtime = await model.coordinator?.state()
            try await withMacNativeRootWindow(model) { root, window in
                let (table, row) = try self.sidebarRow(rows[1].id, in: root, window: window)
                try await self.selectRow(row, in: table, window: window)
                XCTAssertEqual(model.destination, .session(rows[1].id))
                XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: row))
                XCTAssertTrue(self.hasText("Open the saved session", in: root))
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Unsent private draft 文")
                XCTAssertFalse(model.openingSession)
                XCTAssertNil(model.fault, "A preview must not dispatch a busy activation")
            }
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testSidebarHasOnlySettingsFooterAndActionsRetainOverviewWithDevicesUnderSettings() async throws {
        try await fixture { model in
            let rows = self.sessions()
            self.install(rows, in: model, selected: rows[0].id)
            model.destination = .conversation
            let before = model.state
            let runtime = await model.coordinator?.state()
            try await withMacNativeRootWindow(model, width: 1104, height: 829) { root, window in
                let (workspaceTable, _) = try self.sidebarRow(rows[0].id, in: root, window: window)
                let sidebarFrame = window.convertToScreen(workspaceTable.convert(workspaceTable.bounds, to: nil))
                for title in ["Pi", "Overview", "Devices"] {
                    XCTAssertFalse(self.elements(root).contains {
                        guard $0.hasText(title), let frame = $0.frame else { return false }
                        return sidebarFrame.contains(frame)
                    }, "Retired sidebar destination: " + title)
                }
                let tables = self.descendants(root).compactMap { $0 as? NSTableView }
                let footer = try XCTUnwrap(tables.first { table in
                    table.numberOfRows == 1 && self.hasText("Settings", in: table)
                }, "The pinned footer must contain only Settings")
                XCTAssertEqual(footer.numberOfRows, 1)
                try MacNativeMenuTracking.open(self.menu("mac-global-actions", in: root)) { menu in
                    let titles = menu.items.map(\.title)
                    XCTAssertTrue(titles.contains("Overview"))
                    XCTAssertTrue(titles.contains("Settings"))
                    XCTAssertFalse(titles.contains("Devices"))
                    XCTAssertFalse(titles.contains("Files"))
                    XCTAssertFalse(titles.contains("Pi commands"))
                }
                try await self.select("Overview", menu: "mac-global-actions", in: root)
                XCTAssertEqual(model.destination, .overview)
                try await self.selectRow(0, in: footer, window: window)
                XCTAssertEqual(model.destination, .settings)
                XCTAssertEqual(footer.selectedRowIndexes, IndexSet(integer: 0))
                try await self.scrollBottom(root)
                try self.dump(root, name: "settings-devices")
                if let devices = self.elements(root).first(where: { $0.identifier == "mac-settings-devices" }) {
                    XCTAssertTrue(devices.press())
                } else { try self.clickRendered("Devices", window: window) }
                try await self.settle(root)
                XCTAssertEqual(model.destination, .devices)
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Unsent private draft 文")
                XCTAssertFalse(model.listening)
                XCTAssertNil(model.panel)
            }
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testSevenRowOverviewStartsWithTwoOpenRowsAndOneGlobalFiveClosedDisclosure() async throws {
        let rows = sessions(7)
        let closed = Set(rows.dropFirst(2).map(\.id))
        try await fixture(closed: closed) { model in
            self.install(rows, in: model, selected: rows[0].id)
            model.sidebarVisible = false
            model.destination = .overview
            let before = model.state
            try await withMacNativeRootWindow(model, width: 1104, height: 829) { root, window in
                for row in rows.prefix(2) { _ = try self.element("mac-overview-row-" + row.id.uuidString, in: root) }
                for row in rows.dropFirst(2) {
                    XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-overview-row-" + row.id.uuidString })
                }
                _ = try self.element("mac-overview-closed-sessions", in: root)
                XCTAssertTrue(self.hasText("Closed sessions (5)", in: root))
                try self.saveCapture(window, name: "overview-seven-collapsed", width: 1104, height: 829)
                try await self.expand("mac-overview-closed-sessions", in: root, window: window)
                try await self.settle(root)
                for row in rows {
                    _ = try self.element("mac-overview-row-" + row.id.uuidString, in: root)
                    XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-overview-close-" + row.id.uuidString },
                                   "Close must be a context-menu action, not an ordinary row button")
                }
                for row in rows.dropFirst(2) {
                    XCTAssertTrue(try self.element("mac-overview-open-" + row.id.uuidString, in: root).hasText("Reopen"))
                }
                try self.saveCapture(window, name: "overview-seven-expanded", width: 1104, height: 829)
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.closedSessionIDs, closed)
                XCTAssertEqual(model.text, "Unsent private draft 文")
                XCTAssertNil(model.fault)
            }
        }
    }

    func testOverviewAllClosedEmptyAndLoadedWithStaleClosedPreferenceRemainTruthful() async throws {
        let rows = sessions(2)
        let closed = Set(rows.map(\.id))
        for state in ["all-closed", "empty", "loaded-stale"] {
            try await fixture(closed: closed) { model in
                self.install(state == "empty" ? [] : rows, in: model, selected: state == "loaded-stale" ? rows[0].id : nil)
                model.destination = .overview
                model.sidebarVisible = false
                if state == "loaded-stale" {
                    // Preserve a delayed pre-close selection, as the model does for an old host snapshot.
                    let context = model.state.context
                    var receipt = model.state
                    receipt.selected = nil
                    receipt.sequence += 1
                    try model.finishSessionClose(rows[0].id, context: context, receipt: receipt)
                }
                let before = model.state
                try await withMacNativeRootWindow(model) { root, _ in
                    switch state {
                    case "all-closed":
                        XCTAssertTrue(self.hasText("No open sessions. Expand Closed sessions to reopen saved work.", in: root))
                        XCTAssertTrue(self.hasText("Closed sessions (2)", in: root))
                        for row in rows { XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-overview-row-" + row.id.uuidString }) }
                    case "empty":
                        XCTAssertTrue(self.hasText("No saved sessions. Add a workspace, then use New session.", in: root))
                        XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-overview-closed-sessions" })
                    default:
                        XCTAssertTrue(model.closedSessionIDs.contains(rows[0].id), "This fixture must retain stale local metadata")
                        _ = try self.element("mac-overview-row-" + rows[0].id.uuidString, in: root)
                        XCTAssertTrue(try self.element("mac-overview-open-" + rows[0].id.uuidString, in: root).hasText("View conversation"))
                        XCTAssertTrue(self.hasText("Closed sessions (1)", in: root))
                        XCTAssertFalse(self.hasText("No open sessions. Expand Closed sessions to reopen saved work.", in: root))
                    }
                    XCTAssertEqual(model.state, before)
                    XCTAssertEqual(model.closedSessionIDs, closed)
                    XCTAssertNil(model.fault)
                }
            }
        }
    }

    private func withResumeFixture(_ body: (CompanionModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("private-pi")
        let script = #"""
#!/bin/sh
if [ "${1:-}" = --version ]; then printf '1.3.0\n'; exit 0; fi
folder=''; session=''; file=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session-dir) folder=$2; shift 2 ;;
        --session-id) session=$2; shift 2 ;;
        --session) file=$2; session=$(/usr/bin/head -1 "$file" | /usr/bin/plutil -extract id raw -o - -); shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$file" ] || file="$folder/$session.jsonl"
[ -f "$file" ] || printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
printf '%s\n' "$file" > "$PWD/session-path"
reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
while IFS= read -r line; do
    id=$(printf '%s' "$line" | /usr/bin/plutil -extract id raw -o - -)
    command=$(printf '%s' "$line" | /usr/bin/plutil -extract type raw -o - -)
    printf '%s\n' "$command" >> "$PWD/commands"
    case "$command" in
        get_state) reply "{\"isStreaming\":false,\"isCompacting\":false,\"pendingMessageCount\":0,\"sessionId\":\"$session\",\"sessionFile\":\"$file\"}" ;;
        get_available_models) reply '{"models":[]}' ;;
        get_available_thinking_levels) reply '{"levels":["off"]}' ;;
        get_commands) reply '{"commands":[]}' ;;
        get_messages)
            if /usr/bin/grep -q '"type":"message"' "$file"; then reply '{"messages":[{"role":"user","content":"Private saved history"}]}'
            else reply '{"messages":[]}'; fi ;;
        prompt)
            printf '{"type":"message","id":"saved-message","parentId":null,"message":{"role":"user","content":"Private saved history"}}\n' >> "$file"
            reply '{"disposition":"handled"}'
            printf '{"type":"message_end","message":{"role":"user","content":"Private saved history"}}\n' ;;
        switch_session)
            file=$(printf '%s' "$line" | /usr/bin/plutil -extract sessionPath raw -o - -)
            session=$(/usr/bin/head -1 "$file" | /usr/bin/plutil -extract id raw -o - -)
            reply '{"cancelled":false}' ;;
        *) reply '{}' ;;
    esac
done
"""#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await fixture { model in
            let host = try XCTUnwrap(model.coordinator)
            try await host.setExecutable(executable)
            let directory = try await host.directories.register(root)
            model.observe()
            _ = try await model.request(.createSession(directory: directory))
            _ = try await model.request(.prompt(text: "Private saved history", delivery: .prompt, image: nil))
            for _ in 0..<200 {
                if model.state.phase == "idle" && !model.state.messages.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.state.messages.map(\.text), ["Private saved history"])
            try await body(model, root)
        }
    }

    func testExpandedClosedOverviewRequiresExplicitReopenAndRestoresThePrivateSavedDraft() async throws {
        try await withResumeFixture { model, rootURL in
            XCTAssertEqual(model.state.phase, "idle")
            let id = try XCTUnwrap(model.state.selected)
            let saved = model.state.sessions
            let messages = model.state.messages
            let path = try String(contentsOf: rootURL.appendingPathComponent("session-path"), encoding: .utf8).trimmingCharacters(in: .newlines)
            let savedFile = URL(fileURLWithPath: path)
            let historyBytes = try Data(contentsOf: savedFile)
            let promptCalls = try String(contentsOf: rootURL.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").filter { $0 == "prompt" }.count
            XCTAssertEqual(promptCalls, 1)
            model.text = "Private draft retained through explicit reopen 文"
            let closed = await model.closeSession(id)
            XCTAssertTrue(closed)
            model.interfaceMode = .desktop
            model.sidebarVisible = false
            model.inspectorVisible = false
            model.destination = .overview
            try await withMacNativeRootWindow(model, width: 1104, height: 829) { root, window in
                XCTAssertTrue(model.closedSessionIDs.contains(id))
                XCTAssertNil(model.state.selected)
                XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-overview-row-" + id.uuidString })
                try await self.expand("mac-overview-closed-sessions", in: root, window: window)
                try await self.settle(root)
                XCTAssertNil(model.state.selected, "Disclosure must not activate saved work")
                XCTAssertEqual(try Data(contentsOf: savedFile), historyBytes)
                XCTAssertTrue(model.closedSessionIDs.contains(id))
                let reopen = try self.element("mac-overview-open-" + id.uuidString, in: root)
                XCTAssertTrue(reopen.hasText("Reopen"))
                XCTAssertTrue(reopen.press())
                for _ in 0..<200 {
                    if model.state.selected == id && !model.openingSession && model.state.phase == "idle" { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(model.state.selected, id)
                XCTAssertEqual(model.state.phase, "idle")
                XCTAssertFalse(model.openingSession)
                XCTAssertFalse(model.closedSessionIDs.contains(id))
                XCTAssertEqual(model.state.sessions.map(\.id), saved.map(\.id))
                XCTAssertEqual(model.state.messages.count, messages.count)
                for (actual, expected) in zip(model.state.messages, messages) {
                    // TranscriptReducer assigns new local display IDs when history reloads.
                    var restored = actual
                    restored.id = expected.id
                    XCTAssertEqual(restored, expected)
                }
                XCTAssertEqual(model.text, "Private draft retained through explicit reopen 文")
                XCTAssertEqual(try Data(contentsOf: savedFile), historyBytes, "Reopen must not rewrite saved history")
                XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").filter { $0 == "prompt" }.count, promptCalls, "Reopen must not replay a prompt")
                XCTAssertNil(model.fault)
            }
        }
    }

    func testVisibilityPreferenceErrorAndFailedLoadedCloseStayVisibleOutsideClosedGroup() async throws {
        try await fixture(corruptVisibility: true) { model in
            let rows = self.sessions(1)
            self.install(rows, in: model, selected: rows[0].id)
            model.destination = .overview
            model.sidebarVisible = false
            // This presentation-only session has no host runtime. Close must fail, not hide it.
            let result = await model.closeSession(rows[0].id)
            XCTAssertFalse(result)
            XCTAssertNotNil(model.fault)
            XCTAssertTrue(model.closedSessionIDs.isEmpty)
            let before = model.state
            try await withMacNativeRootWindow(model) { root, _ in
                let error = try XCTUnwrap(model.sessionVisibilityError)
                XCTAssertTrue(self.hasText(error, in: root))
                XCTAssertTrue(try self.renderedText(XCTUnwrap(root.window)).contains("Session visibility"), "The visibility error must remain rendered outside collapsed history")
                _ = try self.element("mac-overview-row-" + rows[0].id.uuidString, in: root)
                XCTAssertTrue(self.hasText(try XCTUnwrap(model.fault).explanation, in: root))
                XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-overview-closed-sessions" })
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.state.selected, rows[0].id)
                XCTAssertEqual(model.text, "Unsent private draft 文")
            }
        }
    }

    func testOverviewContextCloseTargetsSavedRowAndGlobalCloseShortcutStillTargetsFocusedSavedSession() async throws {
        try await fixture { model in
            let rows = self.sessions(3)
            self.install(rows, in: model, selected: rows[0].id)
            model.destination = .overview
            model.sidebarVisible = false
            let before = model.state
            let runtime = await model.coordinator?.state()
            try await withMacNativeRootWindow(model, width: 1104, height: 829) { root, window in
                let frame = try XCTUnwrap(try self.element("mac-overview-row-" + rows[1].id.uuidString, in: root).frame)
                try MinimalNavigationContextMenu.open(at: frame, in: window, selecting: "Close Session") { menu in
                    XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Close Session")).isEnabled)
                }
                try await self.settle(root)
                XCTAssertEqual(model.closedSessionIDs, [rows[1].id])
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Unsent private draft 文")
                model.destination = .session(rows[2].id)
                try await self.settle(root)
                try await self.key("w", code: 13, window: window)
                XCTAssertEqual(model.closedSessionIDs, Set(rows.dropFirst().map(\.id)))
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.destination, .workspace(rows[2].directory))
                XCTAssertTrue(window.isVisible, "Native close route must keep its parent window visible; appHidden=\(NSApp.isHidden)")
                XCTAssertNil(model.fault)
            }
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testWorkingOverviewContextCloseAndGlobalKeyboardCloseRequireConsentAndCancelPreservesWork() async throws {
        try await CompanionPresentationTests.withWorkingCloseFixture { model, _, _ in
            model.interfaceMode = .desktop
            model.sidebarVisible = false
            model.inspectorVisible = false
            model.destination = .overview
            model.text = "Keep working context-menu draft"
            let host = try XCTUnwrap(model.coordinator)
            let before = await host.state()
            let id = try XCTUnwrap(model.state.selected)
            try await withMacNativeRootWindow(model, width: 1104, height: 829) { root, window in
                for route in ["context", "keyboard"] {
                    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
                    if route == "context" {
                        let frame = try XCTUnwrap(try self.element("mac-overview-row-" + id.uuidString, in: root).frame)
                        try MinimalNavigationContextMenu.open(at: frame, in: window, selecting: "Close Session") { menu in
                            XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Close Session")).isEnabled)
                        }
                    } else {
                        model.destination = .conversation
                        try await self.settle(root)
                        try await self.key("w", code: 13, window: window)
                    }
                    @MainActor func consent() -> [MinimalNavigationElement] {
                        let owned = [window] + window.sheets + (window.childWindows ?? [])
                            + NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }
                        return owned.filter { $0.isVisible }.compactMap { $0.contentView }.flatMap { self.elements($0) }
                    }
                    for _ in 0..<100 {
                        if consent().contains(where: { $0.hasText("Stop and Close") }) { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertTrue(consent().contains { $0.hasText("Stop and Close") }, route)
                    XCTAssertTrue(try XCTUnwrap(consent().first { $0.hasText("Cancel") }).press())
                    try await self.settle(root)
                    XCTAssertFalse(consent().contains { $0.hasText("Stop and Close") })
                    let after = await host.state()
                    XCTAssertEqual(after, before, "Cancelling Close must not stop or mutate the active runtime")
                    XCTAssertTrue(model.state.working)
                    XCTAssertTrue(model.closedSessionIDs.isEmpty)
                    XCTAssertEqual(model.text, "Keep working context-menu draft")
                    XCTAssertNil(model.fault)
                }
            }
        }
    }

    func testRootDiagnosticDetailsOpenActivityWithFullSelectableTypedAndLegacyTextAndExactMirrorDeduplication() async throws {
        try await fixture { model in
            let rows = self.sessions(1)
            self.install(rows, in: model, selected: rows[0].id)
            model.destination = .conversation
            let typed = ["Private typed-only error\nFull error detail", "Private mirrored warning", "Private typed-only info"]
            let legacy = "Private legacy notice\nFull legacy detail"
            let nearMirror = typed[1] + " "
            model.state.extensionDisplay = ExtensionDisplayState(notices: [
                ExtensionNotice(id: "error", text: typed[0], severity: .error),
                ExtensionNotice(id: "warning", text: typed[1], severity: .warning),
                ExtensionNotice(id: "info", text: typed[2], severity: .info)
            ])
            model.state.notices = [typed[1], legacy, nearMirror]
            let before = model.state
            let runtime = await model.coordinator?.state()
            try await withMacNativeRootWindow(model, width: 1300, height: 800) { root, window in
                try await self.settle(root)
                try self.dump(root, name: "diagnostics-before")
                try self.assertSummary("1 error · 1 warning · 1 info · 2 notices (severity unavailable)", in: root, window: window)
                for text in typed + [legacy, nearMirror] { XCTAssertFalse(self.hasText(text, in: root)) }
                if let button = self.elements(root).first(where: { $0.identifier == "desktop-diagnostics-details" }) {
                    XCTAssertTrue(button.press())
                } else { try self.clickRendered("View details", window: window) }
                try await self.settle(root)
                XCTAssertTrue(model.inspectorVisible)
                XCTAssertEqual(model.destination, .conversation)
                let picker = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSSegmentedControl }.first {
                    $0.label(forSegment: 0) == "Files"
                })
                XCTAssertEqual(picker.label(forSegment: picker.selectedSegment), "Activity")
                try await self.scrollBottom(root)
                try self.dump(root, name: "diagnostics-after")
                for text in typed + [legacy, nearMirror] {
                    let matches = self.elements(root).filter { $0.hasText(text) && ($0.role == "AXStaticText" || $0.role == "AXTextArea") }
                    // AX can expose one backing text through multiple wrappers. Compare rendered frames.
                    let frames = Set(matches.compactMap(\.frame).map { NSStringFromRect($0) })
                    XCTAssertEqual(frames.count, 1, "Each full diagnostic must render once: " + text)
                    let node = try XCTUnwrap(matches.first)
                    try self.assertSelectable(node, text: text, window: window)
                }
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Unsent private draft 文")
                XCTAssertNil(model.panel)
                XCTAssertNil(model.fault)
            }
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    private func assertSelectable(_ node: MinimalNavigationElement, text: String, window: NSWindow) throws {
        let setter = NSSelectorFromString("setAccessibilitySelectedTextRange:")
        let getter = NSSelectorFromString("accessibilitySelectedTextRange")
        XCTAssertTrue(node.object.responds(to: setter), "Activity diagnostics must support native text selection")
        XCTAssertTrue(node.object.responds(to: getter))
        guard node.object.responds(to: setter), node.object.responds(to: getter) else { return }
        window.makeFirstResponder(nil)
        let range = NSRange(location: 0, length: text.utf16.count)
        typealias SetRange = @convention(c) (AnyObject, Selector, NSRange) -> Void
        typealias GetRange = @convention(c) (AnyObject, Selector) -> NSRange
        unsafeBitCast(node.object.method(for: setter), to: SetRange.self)(node.object, setter, range)
        XCTAssertEqual(unsafeBitCast(node.object.method(for: getter), to: GetRange.self)(node.object, getter), range)
        let field = try XCTUnwrap((node.object as? NSCell)?.controlView as? NSTextField,
                                  "Selectable diagnostic text must have a native text field")
        XCTAssertTrue(field.isSelectable)
        XCTAssertEqual(field.stringValue, text, "Keep full text, newlines and trailing whitespace")
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(range)
        XCTAssertEqual(editor.selectedRange(), range)
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), text)
        window.makeFirstResponder(nil)
    }

    func testRootSessionMenuDetailsRetainDiscoveredResourcesWithoutRuntimeRequests() async throws {
        try await fixture { model in
            let rows = self.sessions(1)
            self.install(rows, in: model, selected: rows[0].id)
            model.destination = .conversation
            model.sidebarVisible = false
            model.state.commands = [CommandOption(name: "skill:private-resource", detail: "", source: "skill"),
                                    CommandOption(name: "private-template", detail: "", source: "prompt")]
            let before = model.state
            let runtime = await model.coordinator?.state()
            try await withMacNativeRootWindow(model, width: 1104, height: 829) { root, window in
                try await self.select("Session controls", menu: "mac-session-menu", in: root)
                XCTAssertTrue(model.inspectorVisible)
                try await self.scrollBottom(root)
                try self.dump(root, name: "session-before")
                try await self.expand("mac-session-details", in: root, window: window)
                try await self.settle(root)
                try await self.scrollBottom(root)
                let visible = try self.renderedText(window).replacingOccurrences(of: "\n", with: " ")
                for text in ["Context", "Skills", "Prompts", "private-resource", "/private-template",
                             "Loaded context paths are not reported by Pi RPC."] {
                    XCTAssertTrue(self.hasText(text, in: root) || visible.contains(text), "Missing Session resource: " + text)
                }
                XCTAssertEqual(model.destination, .conversation)
                XCTAssertEqual(model.state, before)
                XCTAssertNil(model.fault)
            }
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testCommandsSheetRendersSyntheticLabelsButEveryModelPanelRemainsCaptureProtected() async throws {
        try await fixture { model in
            let rows = self.sessions(1)
            self.install(rows, in: model, selected: rows[0].id)
            model.destination = .conversation
            model.state.commands = [CommandOption(name: "private-command", detail: "Synthetic extension label", source: "extension"),
                                    CommandOption(name: "skill:private-skill", detail: "Synthetic skill label", source: "skill"),
                                    CommandOption(name: "private-template", detail: "Synthetic template label", source: "prompt")]
            let before = model.state
            let runtime = await model.coordinator?.state()
            try await withMacNativeRootWindow(model, width: 1104, height: 829) { root, window in
                XCTAssertTrue(try MacDebugController.captureWindow(model: model, windows: [window], appHidden: false, modalWindow: nil) === window)
                XCTAssertTrue(try self.element("mac-commands", in: root).press())
                try await self.settle(root)
                XCTAssertEqual(model.panel, "commands")
                let sheet = try XCTUnwrap(window.sheets.first?.contentView)
                try await self.settle(sheet)
                try self.dump(sheet, name: "commands")
                let label = try XCTUnwrap(self.elements(sheet).first { $0.hasText("Command arguments") }?.frame)
                let arguments = try XCTUnwrap(self.elements(sheet).first {
                    guard $0.role == "AXTextField", let frame = $0.frame else { return false }
                    return frame.minX >= label.maxX && frame.minY < label.maxY && frame.maxY > label.minY
                }, "Commands must retain its native arguments field")
                XCTAssertEqual(arguments.role, "AXTextField")
                for command in model.state.commands {
                    let row = try self.element("session-command-" + command.id, in: sheet)
                    XCTAssertTrue(row.label.contains("/" + command.name) || self.hasText("/" + command.name, in: sheet))
                    XCTAssertTrue(row.label.contains(command.detail) || self.hasText(command.detail, in: sheet))
                }
                XCTAssertThrowsError(try MacDebugController.captureWindow(model: model, windows: [window], appHidden: false, modalWindow: nil)) {
                    XCTAssertEqual($0 as? MacDebugServer.OperationError, .captureProtected)
                }
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Unsent private draft 文")
                XCTAssertNil(model.fault)
                model.panel = nil
                try await self.settle(root)
                XCTAssertTrue(window.sheets.isEmpty)
                // Even without an attached sheet, any non-nil panel fails the model guard.
                for panel in ["commands", "hotkeys", "unknown-private-panel"] {
                    model.panel = panel
                    XCTAssertThrowsError(try MacDebugController.captureWindow(model: model, windows: [window], appHidden: false, modalWindow: nil)) {
                        XCTAssertEqual($0 as? MacDebugServer.OperationError, .captureProtected)
                    }
                    model.panel = nil
                }
            }
            let after = await model.coordinator?.state()
            XCTAssertEqual(after, runtime)
        }
    }

    func testLoadedDesktopKeepsOnePrimaryFilesAndCommandsAndRetiredDebugClicksFailClosed() async throws {
        try await fixture { model in
            let rows = self.sessions(1)
            self.install(rows, in: model, selected: rows[0].id)
            model.destination = .conversation
            model.state.messages = [TranscriptMessage(role: "assistant", text: "Private populated transcript")]
            let before = model.state
            try await withMacNativeRootWindow(model, width: 1104, height: 829) { root, window in
                for id in ["mac-files", "mac-commands"] {
                    let nodes = self.elements(root).filter {
                        $0.identifier == id && ($0.role == "AXButton" || $0.object is NSButton || $0.object is NSButtonCell)
                    }
                    let frames = Set(nodes.compactMap(\.frame).map { NSStringFromRect($0) })
                    XCTAssertEqual(frames.count, 1, "Keep exactly one primary visible action: " + id)
                }
                for id in self.retiredIDs + ["desktop-welcome-resume"] {
                    XCTAssertFalse(self.elements(root).contains { $0.identifier == id }, id)
                    let target = try XCTUnwrap(MacDebugClickTarget(rawValue: id), "Retired allowlist targets must fail closed at native resolution")
                    XCTAssertThrowsError(try MacDebugClick.press(target, in: window)) {
                        XCTAssertEqual($0 as? MacDebugServer.OperationError, .targetUnavailable)
                    }
                }
                XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-session-close-" + rows[0].id.uuidString })
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Unsent private draft 文")
                XCTAssertNil(model.panel)
                XCTAssertNil(model.fault)
                XCTAssertTrue(try self.element("mac-files", in: root).press())
                try await self.settle(root)
                XCTAssertTrue(model.inspectorVisible)
                XCTAssertEqual(model.destination, .conversation)
                model.interfaceMode = .pi
                try await self.settle(root)
                let row = try self.element("mac-session-" + rows[0].id.uuidString, in: root)
                let frame = try XCTUnwrap(row.frame)
                let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
                let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0))
                window.acceptsMouseMovedEvents = true
                window.sendEvent(move)
                try await self.settle(root)
                try self.dump(root, name: "pi-close")
                XCTAssertTrue(self.elements(root).contains { ($0.role == "AXButton" || $0.object is NSButton) && $0.hasText("Close Session") },
                              "Pi retains its native sidebar Close button")
            }
        }
    }

    func testPrivateDesktopScreenshotMatrixLightDarkAtThreeSizes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for (width, height) in [(900, 600), (1104, 829), (1300, 800)] {
                for state in ["populated", "working-errors", "empty-loaded", "unloaded"] {
                    try await fixture { model in
                        let rows = self.sessions()
                        self.install(rows, in: model, selected: state == "unloaded" ? nil : rows[0].id)
                        model.destination = .conversation
                        model.inspectorVisible = false
                        model.state.sessions[0].title = "Private long session name — investigate native navigation and preserve the unsent multilingual draft 文 — fixture only"
                        model.text = state == "unloaded" ? "" : String(repeating: "Private long draft 文. ", count: 16)
                        if state == "populated" || state == "working-errors" {
                            model.state.messages = [
                                TranscriptMessage(role: "user", text: "Private fixture: explain this local change without running commands."),
                                TranscriptMessage(role: "assistant", text: "## Private fixture result\n\nThe conversation remains the primary surface.\n\n```swift\nlet message = \"Synthetic data only\"\n```"),
                                TranscriptMessage(role: "tool", text: "read\nPrivate tool failure: fixture.swift is unavailable", isError: true,
                                                  tool: TranscriptTool(name: "read", target: "fixture.swift", status: .failed))
                            ]
                        }
                        if state == "working-errors" {
                            model.state.phase = "working"
                            model.state.pendingMessages = 2
                            model.state.extensionDisplay = ExtensionDisplayState(notices: [
                                ExtensionNotice(id: "error", text: "Private raw error details remain in Activity", severity: .error),
                                ExtensionNotice(id: "warning", text: "Private raw warning details remain in Activity", severity: .warning)
                            ])
                            model.composerError = "Private fixture recovery: review this error before continuing."
                        }
                        let before = model.state
                        try await self.captureRoot(model, scheme: scheme, width: CGFloat(width), height: CGFloat(height)) { root, window in
                            _ = try self.element("pi-editor", in: root)
                            _ = try self.element("mac-files", in: root)
                            _ = try self.element("mac-commands", in: root)
                            if state == "working-errors" {
                                _ = try self.element("mac-stop", in: root)
                                try self.assertSummary("1 error · 1 warning", in: root, window: window)
                                _ = try self.element("mac-composer-error", in: root)
                            }
                            XCTAssertEqual(model.state, before)
                            let appearance = scheme == .light ? "light" : "dark"
                            try self.saveCapture(window, name: "desktop-\(appearance)-\(width)x\(height)-\(state)", width: width, height: height)
                        }
                    }
                }
            }
        }
    }

    /// The shared native-root helper intentionally follows system appearance. Fix both sources here.
    private func captureRoot(_ model: CompanionModel, scheme: ColorScheme, width: CGFloat, height: CGFloat,
                             _ body: (NSView, NSWindow) async throws -> Void) async throws {
        let app = NSApplication.shared
        let previous = NSWorkspace.shared.frontmostApplication
        let policy = app.activationPolicy()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let controller = NSHostingController(rootView: CompanionWindow(model: model)
            .environment(\.colorScheme, scheme).environment(\.accessibilityEnabled, true).frame(width: width, height: height))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        app.setActivationPolicy(.regular)
        app.unhide(nil)
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            app.setActivationPolicy(policy); previous?.activate()
        }
        window.makeKeyAndOrderFront(nil)
        app.activate()
        try await settle(controller.view)
        try await body(controller.view, window)
    }

    private func saveCapture(_ window: NSWindow, name: String, width: Int, height: Int) throws {
        let pixels = try MacDebugController.snapshot(window: window)
        XCTAssertEqual(pixels.value.width, width)
        XCTAssertEqual(pixels.value.height, height)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: pixels.value).representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/tmp/pi-minimal-desktop/captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
