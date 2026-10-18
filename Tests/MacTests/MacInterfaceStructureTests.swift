import AppKit
import PiRemoteCore
import PiRemoteHost
import Vision
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class StructureSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor private struct StructureElement {
    let object: NSObject
    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                          "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue",
                          "accessibilityRole": "AXRole", "accessibilityParent": "AXParent"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }
    var identifier: String? { value("accessibilityIdentifier") as? String }
    var label: String { value("accessibilityLabel") as? String ?? "" }
    var frame: NSRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return nil }
        typealias Method = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }
    func press() -> Bool {
        if let button = object as? NSButton ?? (object as? NSButtonCell)?.controlView as? NSButton {
            guard button.isEnabled else { return false }
            button.performClick(nil)
            return true
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }
}

/// Open the rendered AppKit menu and run checks while its tracking loop is active.
@MainActor final class MacNativeMenuTracking: NSObject {
    private let button: NSPopUpButton
    private let deadline = Date().addingTimeInterval(2)
    private var inspect: ((NSMenu) -> Void)?
    private var trackingMenu: NSMenu?
    private var selectionTitle: String?

    private init(button: NSPopUpButton) { self.button = button }

    static func open<Value>(_ button: NSPopUpButton, selecting title: String? = nil, inspect: @escaping (NSMenu) throws -> Value) throws -> Value {
        NSApp.unhide(nil)
        button.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let tracking = MacNativeMenuTracking(button: button)
        tracking.selectionTitle = title
        var result: Result<Value, Error>?
        tracking.inspect = { menu in result = Result { try inspect(menu) } }
        let timer = Timer(timeInterval: 0.04, target: tracking, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        NotificationCenter.default.addObserver(tracking, selector: #selector(menuBeganTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        defer {
            timer.invalidate(); tracking.inspect = nil
            NotificationCenter.default.removeObserver(tracking)
        }
        let window = try XCTUnwrap(button.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        button.mouseDown(with: event)
        let release = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        button.mouseUp(with: release)
        return try XCTUnwrap(result, "The native menu did not open before the tracking timeout").get()
    }

    static func select(_ title: String, from button: NSPopUpButton) async throws {
        try open(button, selecting: title) { menu in
            let item = try XCTUnwrap(menu.item(withTitle: title), "Missing native menu item: " + title)
            XCTAssertTrue(item.isEnabled, "Disabled native menu item: " + title)
        }
        try await Task.sleep(for: .milliseconds(80))
    }

    private func postKey(_ characters: String, code: UInt16, window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
        if let release = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
            NSApp.postEvent(release, atStart: false)
        }
    }

    @objc private func menuBeganTracking(_ notification: Notification) {
        trackingMenu = notification.object as? NSMenu
    }

    @objc private func tick(_ timer: Timer) {
        guard let menu = trackingMenu ?? button.menu else { return }
        if menu.numberOfItems > 0, let inspect {
            self.inspect = nil
            inspect(menu)
            if let selectionTitle, let window = button.window {
                let enabled = menu.items.filter { $0.isEnabled && !$0.isSeparatorItem && !$0.isHidden && $0.action != nil }
                guard let target = enabled.firstIndex(where: { $0.title == selectionTitle }) else {
                    menu.cancelTrackingWithoutAnimation()
                    return
                }
                let current = enabled.firstIndex { $0 === menu.highlightedItem }
                let steps = current.map { (target - $0 + enabled.count) % enabled.count } ?? target + 1
                for _ in 0..<steps { postKey("\u{f701}", code: 125, window: window) }
                postKey("\r", code: 36, window: window)
            } else { menu.cancelTrackingWithoutAnimation() }
        } else if Date() >= deadline {
            inspect = nil
            menu.cancelTrackingWithoutAnimation()
        }
    }
}

/// A native root fixture for menus, sheets and popovers, separate from raster captures.
@MainActor func withMacNativeRootWindow(_ model: CompanionModel, width: CGFloat = 900, height: CGFloat = 600,
                                       restoreApplication: Bool = true, exercise: @MainActor (NSView, NSWindow) async throws -> Void) async throws {
    let app = NSApplication.shared
    let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let previous = NSWorkspace.shared.frontmostApplication
    let policy = app.activationPolicy()
    app.setActivationPolicy(.regular)
    app.unhide(nil)
    let controller = NSHostingController(rootView: CompanionWindow(model: model)
        .environment(\.accessibilityEnabled, true).frame(width: width, height: height))
    controller.sizingOptions = []
    window.contentViewController = controller
    window.setContentSize(NSSize(width: width, height: height))
    defer {
        model.panel = nil
        for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
        window.contentViewController = nil
        window.close()
        for owned in app.windows where !existingWindows.contains(ObjectIdentifier(owned)) && owned !== window && owned.isVisible {
            if let parent = owned.sheetParent { parent.endSheet(owned) }
            owned.orderOut(nil)
            owned.close()
        }
        if restoreApplication {
            app.setActivationPolicy(policy)
            previous?.activate()
        }
    }
    window.makeKeyAndOrderFront(nil)
    app.activate()
    try await Task.sleep(for: .milliseconds(400))
    controller.view.layoutSubtreeIfNeeded()
    try await exercise(controller.view, window)
}

/// Private hosted fixtures. These checks do not use a provider, listener or shared preferences.
@MainActor final class MacInterfaceStructureTests: XCTestCase {
    private func withModel(_ body: (CompanionModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.Structure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: StructureSecrets(), defaults: defaults)
        XCTAssertNil(model.startupError)
        do { try await body(model) }
        catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    private func settle(_ root: NSView) async throws {
        try await Task.sleep(for: .milliseconds(220))
        root.layoutSubtreeIfNeeded()
    }

    private func hosted(_ model: CompanionModel, width: CGFloat = 900, height: CGFloat = 600,
                        _ body: @MainActor (NSView, NSWindow) async throws -> Void) async throws {
        try await withMacNativeRootWindow(model, width: width, height: height, exercise: body)
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

    private func elements(_ root: NSView) -> [StructureElement] {
        var visited = Set<ObjectIdentifier>(), result: [StructureElement] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let element = StructureElement(object: object)
            result.append(element)
            for child in element.value("accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        if let window = root.window {
            for y in stride(from: CGFloat(8), to: root.bounds.height, by: 12) {
                for x in stride(from: CGFloat(12), to: root.bounds.width, by: 90) {
                    let point = window.convertPoint(toScreen: root.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = root.accessibilityHitTest(point) as? NSObject {
                        visit(hit)
                        var parent = StructureElement(object: hit).value("accessibilityParent") as? NSObject
                        var ancestors = Set<ObjectIdentifier>()
                        while let object = parent, ancestors.insert(ObjectIdentifier(object)).inserted {
                            visit(object)
                            parent = StructureElement(object: object).value("accessibilityParent") as? NSObject
                        }
                    }
                }
            }
        }
        return result
    }

    private func hasInspectorControls(_ root: NSView) -> Bool {
        descendants(root).contains {
            guard let control = $0 as? NSSegmentedControl else { return false }
            return control.label(forSegment: 0) == "Files" && !control.isHiddenOrHasHiddenAncestor && !control.visibleRect.isEmpty
        }
    }

    private func element(_ id: String, in root: NSView) throws -> StructureElement {
        let nodes = elements(root)
        let title = id == "mac-session-menu" ? "Session" : (id == "mac-global-actions" ? "Actions" : nil)
        let match = nodes.first { $0.identifier == id } ?? nodes.first {
            if id == "mac-inspector-view-active-session" {
                return ($0.label == "View active session" || $0.value("accessibilityValue") as? String == "View active session"
                    || ($0.object as? NSButton)?.title == "View active session")
                    && $0.object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            }
            guard let title, $0.object is NSPopUpButtonCell || $0.object is NSPopUpButton else { return false }
            return $0.label == title || $0.identifier == title || ($0.object as? NSPopUpButtonCell)?.title == title
                || ($0.object as? NSPopUpButton)?.title == title
        }
        if match == nil {
            let dump = nodes.map {
                "\(type(of: $0.object)) id=\($0.identifier ?? "") label=\($0.label) value=\($0.value("accessibilityValue") ?? "") role=\($0.value("accessibilityRole") ?? "")"
            }.joined(separator: "\n")
            try dump.write(to: URL(fileURLWithPath: "/tmp/pi-remote-structure-missing-" + id + ".txt"), atomically: true, encoding: .utf8)
        }
        return try XCTUnwrap(match, "Missing native element: " + id)
    }

    private func hasText(_ text: String, in root: NSView) -> Bool {
        elements(root).contains { $0.label == text || $0.label.hasPrefix(text + ", ") || $0.value("accessibilityValue") as? String == text }
    }

    private func menuButton(_ id: String, in root: NSView) throws -> NSPopUpButton {
        let node = try element(id, in: root).object
        let title = id == "mac-session-menu" ? "Session" : "Actions"
        return try XCTUnwrap(node as? NSPopUpButton ?? (node as? NSPopUpButtonCell)?.controlView as? NSPopUpButton
            ?? descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == id || $0.title == title },
            "Missing native menu button: " + id)
    }

    private func menuItems(_ id: String, in root: NSView) throws -> [NSMenuItem] {
        try MacNativeMenuTracking.open(menuButton(id, in: root)) { $0.items }
    }

    private func choose(_ title: String, from id: String, in root: NSView) async throws {
        try await MacNativeMenuTracking.select(title, from: menuButton(id, in: root))
        try await settle(root)
    }

    private func editor(in root: NSView) throws -> NSTextView {
        try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isFieldEditor })
    }

    private func toolbarKey(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "Missing keyboard workflow: " + text)
        if let root = window.contentView { try await settle(root) }
    }

    func testFilesInspectorHidesOnGlobalPagesWithoutClearingSavedVisibility() async throws {
        try await withModel { model in
            model.inspectorVisible = true
            let directory = FileManager.default.temporaryDirectory.path
            model.destination = .workspace(directory)
            try await self.hosted(model, width: 1300, height: 800) { root, _ in
                XCTAssertTrue(self.hasInspectorControls(root))
                let state = model.state
                for destination in [MacDestination.overview, .settings, .devices, .conversation] {
                    model.destination = destination
                    try await self.settle(root)
                    XCTAssertFalse(self.hasInspectorControls(root))
                    XCTAssertTrue(model.inspectorVisible, "Automatic scoping must preserve the saved preference")
                    XCTAssertFalse(model.hasInspectorContext)
                    XCTAssertEqual(model.state, state)
                }
                model.destination = .workspace(directory)
                try await self.settle(root)
                XCTAssertTrue(self.hasInspectorControls(root))
            }
        }
    }

    func testExplicitFilesFromSettingsUsesLoadedConversationWithoutRuntimeMutation() async throws {
        try await withModel { model in
            let session = SessionInfo(id: UUID(), title: "Files fixture", directory: "/tmp")
            model.state.sessions = [session]; model.state.selected = session.id; model.state.phase = "idle"
            model.destination = .settings
            model.text = "Keep files navigation draft"
            try await self.hosted(model, width: 1300, height: 800) { root, _ in
                let before = model.state
                let runtime = await model.coordinator?.state()
                XCTAssertTrue(try self.element("mac-files", in: root).press())
                try await self.settle(root)
                XCTAssertEqual(model.destination, .session(session.id))
                XCTAssertTrue(self.hasInspectorControls(root))
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Keep files navigation draft")
                let after = await model.coordinator?.state()
                XCTAssertEqual(after?.context, runtime?.context)
                XCTAssertEqual(after?.selected, runtime?.selected)
                XCTAssertEqual(after?.phase, runtime?.phase)
                XCTAssertEqual(after?.messages, runtime?.messages)
                XCTAssertEqual(after?.sessions, runtime?.sessions)
            }
        }
    }

    func testInspectorTabChangesFromSettingsRetainVisibleContextWithoutActivatingPi() async throws {
        try await withModel { model in
            let session = SessionInfo(id: UUID(), title: "Inspector tabs fixture", directory: "/tmp")
            model.state.sessions = [session]; model.state.selected = session.id; model.state.phase = "working"
            model.text = "Keep inspector tab draft"
            model.destination = .settings
            try await self.hosted(model, width: 1300, height: 800) { root, window in
                let before = model.state
                for index in [0, 2] {
                    model.destination = .settings
                    try await self.settle(root)
                    try await self.choose("Session controls", from: "mac-session-menu", in: root)
                    let picker = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "Files" })
                    let point = picker.convert(NSPoint(x: picker.bounds.width * (CGFloat(index) + 0.5) / 3, y: picker.bounds.midY), to: nil)
                    let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                    NSApp.postEvent(up, atStart: true)
                    window.sendEvent(down)
                    window.sendEvent(up)
                    try await self.settle(root)
                    XCTAssertEqual(model.destination, .session(session.id))
                    XCTAssertTrue(self.hasInspectorControls(root))
                    XCTAssertEqual(model.state, before)
                    XCTAssertEqual(model.text, "Keep inspector tab draft")
                }
            }
        }
    }

    func testLocalSetupPrecedesOptionalPhoneAccessAndRefreshIsNonDestructive() async throws {
        try await withModel { model in
            model.destination = .settings
            try await self.hosted(model, width: 1300, height: 800) { root, window in
                // Grouped Form buttons are drawn by SwiftUI and are not exposed by
                // this in-process AX fixture. Read only this private window in memory.
                @MainActor func renderedText() throws -> [VNRecognizedTextObservation] {
                    let pixels = try MacDebugController.snapshot(window: window)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: pixels.value).perform([request])
                    return request.results ?? []
                }
                @MainActor func box(_ text: String, in observations: [VNRecognizedTextObservation]) throws -> CGRect {
                    try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == text }, "Missing rendered settings text: " + text).boundingBox
                }
                let observations = try renderedText()
                let local = try box("Pi and folder access", in: observations)
                let remote = try box("iPhone access (optional)", in: observations)
                XCTAssertGreaterThan(local.minY, remote.maxY, "Local Pi setup must appear before optional iPhone access")
                let before = model.state
                let devices = model.devices
                model.addresses = []; model.address = ""
                try await self.settle(root)
                let empty = try renderedText()
                XCTAssertTrue(empty.contains { $0.topCandidates(1).first?.string.contains("No local address") == true })
                let refresh = try box("Refresh addresses", in: empty)
                let point = root.convert(NSPoint(x: root.bounds.width * refresh.midX,
                    y: root.bounds.height * (root.isFlipped ? 1 - refresh.midY : refresh.midY)), to: nil)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                NSApp.postEvent(up, atStart: true)
                window.sendEvent(down); window.sendEvent(up)
                try await self.settle(root)
                XCTAssertEqual(model.addresses, ListenAddress.all())
                XCTAssertFalse(model.addresses.isEmpty)
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.devices, devices)
                XCTAssertFalse(model.listening)
                XCTAssertFalse(model.starting)
            }
        }
    }

    func testContextualActionsAreReachableInNativeSessionMenuForBothAliases() async throws {
        try await CompanionPresentationTests.withWorkingCloseFixture { model, _, _ in
            _ = try await model.request(.stop)
            for _ in 0..<200 {
                if model.state.phase == "idle" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.state.phase, "idle")
            let session = try XCTUnwrap(model.state.sessions.first { $0.id == model.state.selected })
            model.destination = .conversation
            try await self.hosted(model) { root, window in
                for destination in [MacDestination.conversation, .session(session.id)] {
                    model.destination = destination
                    try await self.settle(root)
                    let titles = try self.menuItems("mac-session-menu", in: root).map(\.title)
                    for title in ["Session controls", "Rename…", "Session tree", "History", "Extension diagnostics", "Copy working directory", "Close Session"] {
                        XCTAssertEqual(titles.filter { $0 == title }.count, 1, title)
                    }
                    XCTAssertTrue(titles.contains("Loaded session: " + model.displayName(for: session)))
                    XCTAssertFalse(titles.contains("Files")); XCTAssertFalse(titles.contains("Commands"))
                    let context = model.state.context
                    try await self.choose("Extension diagnostics", from: "mac-session-menu", in: root)
                    XCTAssertTrue(model.inspectorVisible)
                    let picker = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSSegmentedControl }.first {
                        $0.label(forSegment: 0) == "Files"
                    })
                    XCTAssertEqual(picker.selectedSegment, 2, "Extension diagnostics must open the native Activity tab")
                    XCTAssertTrue(self.hasText("No extension diagnostics", in: root), "The real loaded fixture has no extension diagnostics")
                    try await self.choose("Session controls", from: "mac-session-menu", in: root)
                    XCTAssertNotNil(try self.element("mac-inspector-close-session", in: root))
                    let windowsBeforeRename = Set(NSApp.windows.map(ObjectIdentifier.init))
                    try await self.choose("Rename…", from: "mac-session-menu", in: root)
                    XCTAssertEqual(model.panel, "rename")
                    @MainActor func renameField() -> NSTextField? {
                        let roots = window.sheets.compactMap(\.contentView) + (window.childWindows ?? []).compactMap(\.contentView)
                            + NSApp.windows.filter { !windowsBeforeRename.contains(ObjectIdentifier($0)) }.compactMap(\.contentView)
                        return roots.flatMap(self.descendants).compactMap { $0 as? NSTextField }.first {
                            $0.isEditable && $0.stringValue == session.title && $0.window?.isVisible == true
                        }
                    }
                    for _ in 0..<50 {
                        if renameField() != nil { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let renameWindow = renameField()?.window
                    XCTAssertNotNil(renameWindow, "Rename must show the actual loaded name in a native field")
                    defer {
                        if let renameWindow, !windowsBeforeRename.contains(ObjectIdentifier(renameWindow)), renameWindow.isVisible {
                            if let parent = renameWindow.sheetParent { parent.endSheet(renameWindow) }
                            renameWindow.orderOut(nil)
                            renameWindow.close()
                        }
                    }
                    XCTAssertEqual(model.state.context, context)
                    XCTAssertNil(model.fault)
                    model.panel = nil
                    for _ in 0..<100 {
                        if renameWindow?.isVisible != true { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
        }
    }

    func testInspectorNamesActualActiveSessionAndRequiresExplicitNavigation() async throws {
        try await withModel { model in
            let active = SessionInfo(id: UUID(), title: "Actual active session", directory: "/tmp/structure-active")
            let saved = SessionInfo(id: UUID(), title: "Focused saved session", directory: active.directory)
            model.state.sessions = [active, saved]; model.state.selected = active.id; model.state.phase = "working"
            model.text = "Keep active draft"
            model.destination = .overview
            try await self.hosted(model, width: 1300, height: 800) { root, _ in
                for destination in [MacDestination.overview, .settings, .session(saved.id)] {
                    model.destination = destination
                    try await self.settle(root)
                    let before = model.state
                    let runtime = await model.coordinator?.state()
                    try await self.choose("Session controls", from: "mac-session-menu", in: root)
                    XCTAssertEqual(model.destination, destination, "Opening controls must not change UI selection")
                    let inspectorTabs = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "Files" })
                    XCTAssertEqual(inspectorTabs.selectedSegment, 1, "Session action must select the Session inspector tab")
                    XCTAssertTrue(self.hasText("Actual active session", in: root))
                    XCTAssertFalse(self.hasText("No loaded session", in: root))
                    XCTAssertFalse(self.elements(root).contains { $0.identifier == "mac-inspector-close-session" })
                    let titles = try self.menuItems("mac-session-menu", in: root).map(\.title)
                    XCTAssertFalse(titles.contains("Rename…")); XCTAssertFalse(titles.contains("History"))
                    XCTAssertFalse(titles.contains("Session tree"), "Saved-row focus must not retarget actions to active work")
                    XCTAssertEqual(inspectorTabs.selectedSegment, 1, "Closing a menu without selection must preserve the inspector tab")
                    let route = try self.element("mac-inspector-view-active-session", in: root)
                    XCTAssertTrue(route.press())
                    try await self.settle(root)
                    XCTAssertEqual(model.destination, .session(active.id))
                    XCTAssertEqual(model.state, before)
                    XCTAssertEqual(model.text, "Keep active draft")
                    let after = await model.coordinator?.state()
                    XCTAssertEqual(after, runtime)
                    XCTAssertNotNil(try self.element("mac-inspector-close-session", in: root))
                }
            }
        }
    }

    func testNativeSessionMenuRejectsStaleFocusAndContextActions() async throws {
        try await CompanionPresentationTests.withWorkingCloseFixture { model, _, _ in
            _ = try await model.request(.stop)
            for _ in 0..<200 {
                if model.state.phase == "idle" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.state.phase, "idle")
            let active = try XCTUnwrap(model.state.sessions.first { $0.id == model.state.selected })
            let saved = SessionInfo(id: UUID(), title: "Unrelated saved menu target", directory: active.directory)
            model.state.sessions.append(saved); model.destination = .conversation
            model.text = "Keep stale-menu draft"
            try await self.hosted(model, width: 1300, height: 800) { root, _ in
                let runtime = await model.coordinator?.state()
                let context = model.state.context
                for title in ["Rename…", "Session tree", "History", "Close Session"] {
                    try MacNativeMenuTracking.open(self.menuButton("mac-session-menu", in: root)) { menu in
                        let index = menu.indexOfItem(withTitle: title)
                        XCTAssertGreaterThanOrEqual(index, 0, title)
                        guard index >= 0 else { return }
                        model.destination = .session(saved.id)
                        // Keep the old rendered target/action. Do not let SwiftUI rebuild the menu first.
                        menu.performActionForItem(at: index)
                        XCTAssertNil(model.panel, title)
                        XCTAssertNil(model.closingSession, title)
                        XCTAssertTrue(model.closedSessionIDs.isEmpty, title)
                        model.destination = .conversation
                    }
                    try await self.settle(root)
                }
                for title in ["Rename…", "Session tree", "History"] {
                    try MacNativeMenuTracking.open(self.menuButton("mac-session-menu", in: root)) { menu in
                        let index = menu.indexOfItem(withTitle: title)
                        XCTAssertGreaterThanOrEqual(index, 0, title)
                        guard index >= 0 else { return }
                        let epoch = model.state.epoch
                        model.state.epoch = UUID()
                        menu.performActionForItem(at: index)
                        XCTAssertNil(model.panel, title)
                        model.state.epoch = epoch
                    }
                    try await self.settle(root)
                }
                XCTAssertEqual(model.state.context, context)
                XCTAssertEqual(model.text, "Keep stale-menu draft")
                XCTAssertTrue(model.closedSessionIDs.isEmpty)
                let after = await model.coordinator?.state()
                XCTAssertEqual(after, runtime, "Stale menu actions must not change the host or dispatch a prompt")
            }
        }
    }

    func testSessionMenuCloseKeepsFocusedSavedTargetWhileAnotherSessionWorks() async throws {
        try await withModel { model in
            let active = SessionInfo(id: UUID(), title: "Working session", directory: "/tmp/structure-close")
            let saved = SessionInfo(id: UUID(), title: "Close saved target", directory: active.directory)
            model.state.sessions = [active, saved]; model.state.selected = active.id; model.state.phase = "working"
            model.destination = .session(saved.id); model.text = "Keep working draft"
            try await self.hosted(model) { root, _ in
                XCTAssertTrue(try self.menuItems("mac-session-menu", in: root).contains { $0.title == "Saved session: Close saved target" })
                let before = model.state
                try await self.choose("Close Session", from: "mac-session-menu", in: root)
                XCTAssertTrue(model.closedSessionIDs.contains(saved.id)); XCTAssertFalse(model.closedSessionIDs.contains(active.id))
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.destination, .workspace(saved.directory))
                XCTAssertEqual(model.text, "Keep working draft")
            }
        }
    }

    func testActivityUsesTypedActionTargetAndOutcomeWithoutInferredSuccess() async throws {
        try await withModel { model in
            let session = SessionInfo(id: UUID(), title: "Activity outcomes", directory: "/tmp/structure-activity")
            model.state.sessions = [session]; model.state.selected = session.id; model.destination = .conversation
            let messages: [(TranscriptMessage, String)] = [
                (.init(role: "tool", text: "read\nPartial output", tool: .init(name: "read", target: "interrupted.swift", status: .interrupted)), "Read, interrupted.swift, Interrupted"),
                (.init(role: "tool", text: "bash\nSaved legacy output"), "Run, Output"),
                (.init(role: "tool", text: "write\nPermission denied", tool: .init(name: "write", target: "failed.swift", status: .failed)), "Write, failed.swift, Failed"),
                (.init(role: "tool", text: "edit\nPending edit", streaming: true, tool: .init(name: "edit", target: "running.swift", status: .running)), "Edit, running.swift, Running"),
                (.init(role: "tool", text: "read\nFinal output", tool: .init(name: "read", target: "completed.swift", status: .completed)), "Read, completed.swift, Completed")
            ]
            model.state.messages = messages.map(\.0); model.state.phase = "working"
            try await self.hosted(model, width: 1300, height: 800) { root, _ in
                try await self.choose("Extension diagnostics", from: "mac-session-menu", in: root)
                for (_, heading) in messages { XCTAssertTrue(self.hasText(heading, in: root), heading) }
                model.state.phase = "recovering"
                try await self.settle(root)
                XCTAssertTrue(self.hasText("Edit, running.swift, Unconfirmed", in: root))
                XCTAssertTrue(self.hasText("Read, completed.swift, Completed", in: root))
                model.state.phase = "interrupted"
                try await self.settle(root)
                XCTAssertTrue(self.hasText("Edit, running.swift, Interrupted", in: root))
                XCTAssertTrue(self.hasText("Run, Output", in: root), "A finished legacy stream is output, not confirmed success")
            }
        }
    }

    func testLiveAliasesKeepNativeEditorUndoSelectionDraftDisclosureAndScroll() async throws {
        try await withModel { model in
            let session = SessionInfo(id: UUID(), title: "Stable live conversation", directory: "/tmp/structure-alias")
            let tool = TranscriptMessage(role: "tool", text: "bash\n" + (0..<18).map { "Output line \($0)" }.joined(separator: "\n"),
                                         tool: .init(name: "bash", target: "fixture command", status: .completed))
            model.state.sessions = [session]; model.state.selected = session.id
            model.state.messages = [tool]
            for mode in MacInterfaceMode.allCases {
                model.interfaceMode = mode; model.destination = .conversation; model.text = "Draft "
                model.inspectorVisible = false; model.sidebarVisible = false
                try await self.hosted(model, width: 1300, height: 800) { root, window in
                    let editor = try self.editor(in: root)
                    XCTAssertTrue(window.makeFirstResponder(editor))
                    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                    editor.insertText("change", replacementRange: editor.selectedRange())
                    try await self.settle(root)
                    XCTAssertTrue(editor.undoManager?.canUndo == true)
                    let draft = editor.string
                    editor.setSelectedRange(NSRange(location: 1, length: 3))
                    let heading = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSButton }.first {
                        $0.accessibilityIdentifier() == "pi-tool-toggle-" + tool.id.uuidString
                    })
                    heading.performClick(nil)
                    try await self.settle(root)
                    XCTAssertEqual(heading.accessibilityValue() as? String, "Expanded")
                    let history = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSScrollView }.filter {
                        $0 !== editor.enclosingScrollView && $0.documentView != nil
                    }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
                    history.contentView.scroll(to: NSPoint(x: 0, y: 20))
                    history.reflectScrolledClipView(history.contentView)
                    try await self.settle(root)
                    let origin = history.contentView.bounds.origin
                    let before = model.state
                    let runtime = await model.coordinator?.state()
                    for destination in [MacDestination.session(session.id), .conversation, .session(session.id), .conversation] {
                        model.destination = destination
                        try await self.settle(root)
                        XCTAssertTrue(try self.editor(in: root) === editor)
                        XCTAssertEqual(editor.string, draft); XCTAssertEqual(model.text, draft)
                        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 3))
                        XCTAssertTrue(editor.undoManager?.canUndo == true)
                        XCTAssertEqual(heading.accessibilityValue() as? String, "Expanded")
                        let retainedHeading = self.descendants(root).compactMap { $0 as? NSButton }.first {
                            $0.accessibilityIdentifier() == "pi-tool-toggle-" + tool.id.uuidString
                        }
                        XCTAssertTrue(retainedHeading === heading)
                        XCTAssertEqual(history.contentView.bounds.origin.y, origin.y, accuracy: 1)
                        XCTAssertEqual(model.state, before); XCTAssertFalse(model.openingSession); XCTAssertNil(model.fault)
                    }
                    editor.undoManager?.undo()
                    try await self.settle(root)
                    XCTAssertEqual(editor.string, "Draft ")
                    XCTAssertEqual(model.text, "Draft ")

                    XCTAssertTrue(window.makeFirstResponder(editor))
                    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                    editor.setMarkedText("未確定", selectedRange: NSRange(location: 3, length: 0),
                                         replacementRange: NSRange(location: NSNotFound, length: 0))
                    let marked = editor.markedRange()
                    for destination in [MacDestination.session(session.id), .conversation] {
                        model.destination = destination
                        try await self.settle(root)
                        XCTAssertTrue(try self.editor(in: root) === editor)
                        XCTAssertTrue(editor.hasMarkedText())
                        XCTAssertEqual(editor.markedRange(), marked)
                    }
                    editor.unmarkText(); editor.didChangeText()
                    editor.insertText("/mo", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    try await self.settle(root)
                    let suggestions = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSScrollView }.first {
                        $0.accessibilityIdentifier() == "pi-editor-suggestions"
                    })
                    XCTAssertFalse(suggestions.isHidden)
                    for destination in [MacDestination.session(session.id), .conversation] {
                        model.destination = destination
                        try await self.settle(root)
                        let retained = self.descendants(root).compactMap { $0 as? NSScrollView }.first {
                            $0.accessibilityIdentifier() == "pi-editor-suggestions"
                        }
                        XCTAssertTrue(retained === suggestions)
                        XCTAssertFalse(suggestions.isHidden)
                        XCTAssertEqual(editor.string, "/mo")
                        XCTAssertTrue(try self.editor(in: root) === editor)
                    }
                    XCTAssertEqual(model.state, before)
                    let after = await model.coordinator?.state()
                    XCTAssertEqual(after, runtime, "Alias changes must not start or stop a runtime")
                }
            }
        }
    }

    func testLiveAliasesRetainRecoveryAndLoadingPresentation() async throws {
        try await withModel { model in
            let session = SessionInfo(id: UUID(), title: "Interrupted session", directory: "/tmp/structure-recovery")
            model.state.sessions = [session]; model.state.selected = session.id; model.text = "Unsent recovery draft"
            for mode in MacInterfaceMode.allCases {
                model.interfaceMode = mode
                for phase in ["interrupted", "unavailable"] {
                    model.state.phase = phase
                    for destination in [MacDestination.conversation, .session(session.id)] {
                        model.destination = destination
                        try await self.hosted(model) { root, window in
                            XCTAssertNotNil(try self.element("mac-reopen-loaded-session", in: root))
                            let editor = try self.editor(in: root)
                            XCTAssertTrue(window.makeFirstResponder(editor))
                            let selection = editor.selectedRange()
                            model.openingSession = true
                            try await self.settle(root)
                            XCTAssertNotNil(try self.element("mac-session-loading", in: root))
                            XCTAssertFalse(editor.isEditable)
                            XCTAssertTrue(window.firstResponder === editor)
                            for (text, code) in [("z", UInt16(6)), ("\r", UInt16(36)), ("t", UInt16(17))] {
                                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                    modifierFlags: code == 17 ? .control : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                                window.sendEvent(event)
                            }
                            try await self.settle(root)
                            XCTAssertEqual(model.text, "Unsent recovery draft")
                            XCTAssertEqual(editor.string, model.text)
                            XCTAssertEqual(editor.selectedRange(), selection)
                            XCTAssertNil(model.panel)
                            model.openingSession = false
                            try await self.settle(root)
                            XCTAssertTrue(try self.editor(in: root) === editor)
                            XCTAssertTrue(editor.isEditable)
                            XCTAssertEqual(model.text, "Unsent recovery draft")
                        }
                    }
                }
            }
        }
    }

    func testGroupedToolbarPrimaryControlsFitWhileWorkingOnOtherDestinations() async throws {
        try await withModel { model in
            let session = SessionInfo(id: UUID(), title: "Active toolbar fixture", directory: "/tmp/structure-toolbar")
            model.state.sessions = [session]; model.state.selected = session.id; model.state.phase = "working"
            model.sidebarVisible = true; model.inspectorVisible = true
            for destination in [MacDestination.conversation, .overview, .settings] {
                model.destination = destination
                for (width, height) in [(900.0, 600.0), (1300.0, 800.0)] {
                    try await self.hosted(model, width: width, height: height) { root, window in
                        let viewport = window.convertToScreen(root.convert(root.bounds, to: nil))
                        for id in ["mac-sidebar-toggle", "mac-interface-mode", "mac-new-session", "mac-stop", "mac-files", "mac-commands", "mac-session-menu", "mac-global-actions", "mac-inspector-toggle"] {
                            let frame = try XCTUnwrap(self.element(id, in: root).frame, id)
                            XCTAssertGreaterThan(frame.width, 0, id)
                            XCTAssertTrue(viewport.contains(frame), "Primary toolbar control must fit: " + id + " \(frame)")
                        }
                        let actions = try self.menuItems("mac-global-actions", in: root).map(\.title)
                        XCTAssertFalse(actions.contains("Files")); XCTAssertFalse(actions.contains("Commands"))
                        for title in ["Command palette…", "Settings", "Devices", "iPhone access…", "Keyboard shortcuts"] {
                            XCTAssertTrue(actions.contains(title), title)
                        }
                    }
                }
            }
        }
    }

    func testNativeActionsMenuRoutesManagementWithoutChangingRuntimeOrDraft() async throws {
        try await withModel { model in
            let session = SessionInfo(id: UUID(), title: "Management menu fixture", directory: "/tmp/structure-management")
            model.state.sessions = [session]; model.state.selected = session.id; model.state.phase = "working"
            model.destination = .conversation; model.text = "Keep management draft"
            try await self.hosted(model) { root, _ in
                let state = model.state
                let runtime = await model.coordinator?.state()
                for (title, destination) in [("Overview", MacDestination.overview), ("Settings", .settings), ("Devices", .devices)] {
                    try await self.choose(title, from: "mac-global-actions", in: root)
                    XCTAssertEqual(model.destination, destination)
                    XCTAssertEqual(model.state, state)
                    XCTAssertEqual(model.text, "Keep management draft")
                }
                try await self.choose("Command palette…", from: "mac-global-actions", in: root)
                XCTAssertEqual(model.panel, "palette")
                XCTAssertEqual(model.text, "Keep management draft")
                let after = await model.coordinator?.state()
                XCTAssertEqual(after, runtime)
                model.panel = nil
            }
        }
    }

    func testSessionMenuWorkingClosePresentsConsentAndCancelKeepsWorkRunning() async throws {
        try await CompanionPresentationTests.withWorkingCloseFixture { model, _, _ in
            model.destination = .conversation
            model.text = "Keep working menu draft"
            try await self.hosted(model) { root, window in
                let host = try XCTUnwrap(model.coordinator)
                let before = await host.state()
                let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
                try await self.choose("Close Session", from: "mac-session-menu", in: root)
                @MainActor func dialogElements() -> [StructureElement] {
                    let windows = [window] + window.sheets + (window.childWindows ?? [])
                        + NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }
                    return windows.filter(\.isVisible).compactMap(\.contentView).flatMap { self.elements($0) }
                }
                for _ in 0..<100 {
                    if dialogElements().contains(where: { $0.label == "Stop and Close" }) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(dialogElements().contains { $0.label == "Stop and Close" }, "Working Close must present explicit consent")
                let cancel = try XCTUnwrap(dialogElements().first { $0.label == "Cancel" })
                XCTAssertTrue(cancel.press())
                for _ in 0..<100 {
                    if !dialogElements().contains(where: { $0.label == "Stop and Close" }) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(dialogElements().contains { $0.label == "Stop and Close" }, "Cancel must dismiss the consent UI")
                try await self.settle(root)
                let after = await host.state()
                XCTAssertEqual(after.selected, before.selected)
                XCTAssertEqual(after.context, before.context)
                XCTAssertEqual(after.phase, before.phase)
                XCTAssertEqual(after.messages, before.messages)
                XCTAssertTrue(after.working)
                XCTAssertEqual(model.text, "Keep working menu draft")
                XCTAssertTrue(model.closedSessionIDs.isEmpty)
            }
        }
    }

    func testActionsMenuRemoteAccessShowsTheNativePopoverWithoutStartingListener() async throws {
        try await withModel { model in
            try await self.hosted(model) { root, window in
                let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
                try await self.choose("iPhone access…", from: "mac-global-actions", in: root)
                @MainActor func statusPopover() -> NSWindow? {
                    let windows = window.childWindows ?? []
                    let created = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }
                    return (windows + created).first { candidate in
                        guard candidate.isVisible, let content = candidate.contentView else { return false }
                        return self.hasText(model.serverStatus, in: content) && self.hasText(model.connectionStatus, in: content)
                    }
                }
                for _ in 0..<50 {
                    if statusPopover() != nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let popover = try XCTUnwrap(statusPopover(), "The menu must open the actual native status popover")
                let content = try XCTUnwrap(popover.contentView)
                let settings = try XCTUnwrap(self.elements(content).first { $0.label == "iPhone access settings" })
                XCTAssertTrue(settings.press())
                for _ in 0..<100 {
                    if !popover.isVisible { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(popover.isVisible, "Navigation must dismiss the owned status popover")
                XCTAssertEqual(model.destination, .settings)
                XCTAssertFalse(model.listening)
                XCTAssertNil(model.panel)
            }
        }
    }

    func testGroupedMenuShortcutsKeepSessionSwitchingPaletteAndCloseAccessible() async throws {
        try await withModel { model in
            let saved = SessionInfo(id: UUID(), title: "Keyboard saved session", directory: "/tmp/structure-keys")
            model.state.sessions = [saved]; model.destination = .session(saved.id); model.text = "Keep keyboard draft"
            try await self.hosted(model) { root, window in
                try await self.toolbarKey("o", code: 31, modifiers: [.command, .shift], window: window)
                XCTAssertEqual(model.panel, "resume")
                model.panel = nil; try await self.settle(root)
                try await self.toolbarKey("p", code: 35, modifiers: [.command, .shift], window: window)
                XCTAssertEqual(model.panel, "palette")
                model.panel = nil; try await self.settle(root)
                try await self.toolbarKey("w", code: 13, modifiers: [.command, .shift], window: window)
                XCTAssertTrue(model.closedSessionIDs.contains(saved.id))
                XCTAssertEqual(model.text, "Keep keyboard draft")
            }
        }
    }
}
