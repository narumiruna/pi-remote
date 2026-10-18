import AppKit
import PiRemoteCore
import SwiftUI
import Vision
import XCTest

@MainActor private final class FilesResponses {
    let directory = UUID(), parent = UUID(), folder = UUID(), file = UUID()
    let hiddenFile = UUID(), hiddenFolder = UUID(), firstCursor = UUID(), secondCursor = UUID()
    let path = "/private/files-inspector-fixture/deeply/nested/project"
    var actions: [SessionAction] = []
    var selections: [String] = []
    var copies: [String] = []
    var failNext = false

    var initial: DirectoryPage {
        DirectoryPage(id: directory, path: path, parent: parent, items: [
            DirectoryItem(id: folder, name: "Sources", isDirectory: true),
            DirectoryItem(id: file, name: "README.md", isDirectory: false),
            DirectoryItem(id: hiddenFile, name: ".config", isDirectory: false),
            DirectoryItem(id: hiddenFolder, name: ".git", isDirectory: true),
            DirectoryItem(id: UUID(), name: ".denied", isDirectory: false, fault: .permissionDenied)
        ], next: firstCursor)
    }

    func request(_ action: SessionAction) async throws -> AppResult {
        actions.append(action)
        switch action {
        case .directories(id: nil, cursor: nil), .directories(id: directory, cursor: nil):
            return .directories(initial)
        case .directories(id: directory, cursor: firstCursor):
            if failNext { failNext = false; throw RemoteFault.permissionDenied }
            return .directories(DirectoryPage(id: directory, path: path, parent: parent, items: [
                DirectoryItem(id: hiddenFile, name: ".config", isDirectory: false)
            ], next: secondCursor))
        case .directories(id: directory, cursor: secondCursor):
            return .directories(DirectoryPage(id: directory, path: path, parent: parent, items: [
                DirectoryItem(id: file, name: "README.md", isDirectory: false)
            ], next: nil))
        case .directories(id: folder, cursor: nil):
            return .directories(DirectoryPage(id: folder, path: path + "/Sources", parent: directory, items: [], next: nil))
        case .directories(id: parent, cursor: nil):
            return .directories(DirectoryPage(id: parent, path: "/private/files-inspector-fixture/deeply/nested", parent: nil, items: [], next: nil))
        case .preview(id: file):
            return .preview(FilePreview(name: "README.md", text: "Private preview fixture", truncated: false))
        default:
            XCTFail("Unexpected private Files request: \(action)")
            return .failure(.invalidRequest)
        }
    }
}

@MainActor private struct FilesElement {
    let object: NSObject
    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                          "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue",
                          "accessibilityParent": "AXParent"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }
    var identifier: String? { value("accessibilityIdentifier") as? String }
    var label: String { value("accessibilityLabel") as? String ?? "" }
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

// Inspect the real context menu, then leave its tracking loop without an action.
@MainActor private final class FilesContextMenu: NSObject {
    var titles: [String]?
    private var menu: NSMenu?
    @objc func began(_ notification: Notification) { menu = notification.object as? NSMenu }
    @objc func tick(_ timer: Timer) {
        guard let menu, menu.numberOfItems > 0 else { return }
        titles = menu.items.map(\.title)
        menu.cancelTrackingWithoutAnimation()
    }
}

/// Native windows use synthetic responses only. No host folders, provider or listener are opened.
@MainActor final class MacFilesInspectorTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func elements(_ root: NSView) -> [FilesElement] {
        var objects: [NSObject] = [root]
        if let window = root.window {
            for y in stride(from: CGFloat(6), to: root.bounds.height, by: 12) {
                for x in stride(from: CGFloat(6), to: root.bounds.width, by: 12) {
                    let point = window.convertPoint(toScreen: root.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = root.accessibilityHitTest(point) as? NSObject { objects.append(hit) }
                }
            }
        }
        // Seed native subviews and scroll-view hits before walking AX children.
        // NSTableView can create new mock row proxies on every parent query.
        // Do not follow those parents back into an unbounded proxy cycle.
        objects.append(contentsOf: descendants(root))
        for scroll in descendants(root).compactMap({ $0 as? NSScrollView }) {
            guard let window = scroll.window else { continue }
            for y in stride(from: CGFloat(6), to: scroll.bounds.height, by: 12) {
                let point = window.convertPoint(toScreen: scroll.convert(NSPoint(x: 40, y: y), to: nil))
                if let hit = scroll.accessibilityHitTest(point) as? NSObject { objects.append(hit) }
            }
        }
        var seen = Set<ObjectIdentifier>(), result: [FilesElement] = [], index = 0
        while index < objects.count, seen.count < 8192 {
            let object = objects[index]
            index += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let element = FilesElement(object: object)
            result.append(element)
            objects.append(contentsOf: element.value("accessibilityChildren") as? [NSObject] ?? [])
        }
        return result
    }

    private func element(_ id: String, in root: NSView) throws -> FilesElement {
        try XCTUnwrap(elements(root).first { $0.identifier == id }, "Missing Files control: " + id)
    }
    private func has(_ id: String, in root: NSView) -> Bool { elements(root).contains { $0.identifier == id } }
    private func hasText(_ text: String, in root: NSView) -> Bool {
        elements(root).contains { $0.label.contains(text) || ($0.value("accessibilityValue") as? String ?? "").contains(text) }
    }
    private func settle(_ root: NSView) async throws {
        try await Task.sleep(for: .milliseconds(200))
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
    }

    private func capture(_ root: NSView, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/pi-mac-inspector-review/captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = try XCTUnwrap(root.window)
        let pixels = try MacDebugController.snapshot(window: window)
        let bitmap = NSBitmapImageRep(cgImage: pixels.value)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        let dump = elements(root).map {
            "\(type(of: $0.object)) id=\($0.identifier ?? "") label=\($0.label) value=\($0.value("accessibilityValue") ?? "") frame=\(String(describing: $0.frame))"
        }.joined(separator: "\n")
        try dump.write(to: directory.appendingPathComponent(name + "-ax.txt"), atomically: true, encoding: .utf8)
    }
    private func waitFor(_ message: String, in root: NSView, condition: @MainActor () -> Bool) async throws {
        for _ in 0..<30 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
            root.layoutSubtreeIfNeeded()
        }
        XCTFail(message)
    }

    private func renderedText(_ root: NSView) throws -> String {
        let image = try MacDebugController.snapshot(window: XCTUnwrap(root.window))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image.value).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func reviewCanonicalPath(_ path: String, in root: NSView, width: Int) async throws {
        // Selectable SwiftUI Text becomes an AppKit text cell without the SwiftUI
        // identifier. Check its exact AX value and the pixels at both scroll ends.
        XCTAssertTrue(elements(root).contains { ($0.value("accessibilityValue") as? String) == path })
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first {
            $0.bounds.height < 30 && ($0.documentView?.bounds.width ?? 0) > $0.contentSize.width
        }, "Canonical review must keep horizontal scrolling")
        XCTAssertTrue(try renderedText(root).contains("/private/"), "Render the canonical path prefix")
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: document.bounds.maxX - scroll.contentSize.width, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(root)
        XCTAssertTrue(try renderedText(root).contains("/project"), "The full canonical path must remain readable by scrolling")
        try capture(root, name: "files-canonical-trailing-\(width)")
    }

    private func press(_ id: String, in root: NSView) async throws {
        XCTAssertTrue(try element(id, in: root).press(), "Files control must support native activation: " + id)
        try await settle(root)
    }
    private func more(_ root: NSView) throws -> NSPopUpButton {
        let node = try element("mac-folder-more-actions", in: root).object
        return try XCTUnwrap(node as? NSPopUpButton ?? (node as? NSPopUpButtonCell)?.controlView as? NSPopUpButton
            ?? descendants(root).compactMap { $0 as? NSPopUpButton }.first {
                $0.accessibilityIdentifier() == "mac-folder-more-actions" || $0.accessibilityLabel() == "More actions"
            })
    }
    private func choose(_ title: String, in root: NSView) async throws {
        try await MacNativeMenuTracking.select(title, from: more(root))
        try await settle(root)
    }

    private func hosted(_ fixture: FilesResponses, width: CGFloat, selecting: Bool = false,
                        exercise: (NSView, NSWindow) async throws -> Void) async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy(), previous = NSWorkspace.shared.frontmostApplication
        let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
        app.setActivationPolicy(.regular)
        app.unhide(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let browser = DirectoryBrowser(selecting: selecting, request: fixture.request, pathEntry: true,
                                       relativeTo: fixture.path, reveal: { _, _ in }) { _, path in
            fixture.selections.append(path)
        }.environment(\.clipboardWriter, { fixture.copies.append($0) })
        let controller = NSHostingController(rootView: browser.environment(\.accessibilityEnabled, true)
            .environment(\.colorScheme, .light).frame(width: width, height: 480).background(.background))
        controller.sizingOptions = []
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        let host = controller.view
        window.setContentSize(NSSize(width: width, height: 480))
        defer {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.contentViewController = nil
            window.close()
            for owned in app.windows where owned !== window && !existingWindows.contains(ObjectIdentifier(owned)) && owned.isVisible {
                if let parent = owned.sheetParent { parent.endSheet(owned) }
                owned.orderOut(nil)
                owned.close()
            }
            app.setActivationPolicy(policy)
            previous?.activate()
        }
        window.makeKeyAndOrderFront(nil)
        app.activate()
        try await settle(host)
        try await Task.sleep(for: .milliseconds(300))
        try capture(host, name: "files-\(selecting ? "selecting" : "default")-\(Int(width))")
        try await exercise(host, window)
    }

    func testCompactHeaderAndFullWidthRowsAtBothInspectorWidths() async throws {
        for width: CGFloat in [260, 320] {
            let fixture = FilesResponses()
            try await hosted(fixture, width: width) { root, _ in
                let controls = try ["mac-folder-parent", "mac-folder-breadcrumb", "mac-folder-edit-path", "mac-folder-more-actions"]
                    .map { try XCTUnwrap(self.element($0, in: root).frame) }
                for frame in controls {
                    XCTAssertEqual(frame.midY, controls[0].midY, accuracy: 4, "The default Files header must use one row")
                    XCTAssertGreaterThan(frame.width, 0)
                }
                XCTAssertFalse(self.hasText(fixture.path, in: root), "The default Files header must not show a second full-path row")
                XCTAssertTrue(try self.renderedText(root).contains("project"), "The short current-folder name must fit at both widths")
                XCTAssertFalse(self.has("mac-folder-copy-path", in: root), "Copy belongs in More actions, not a second header row")
                let row = try self.element("mac-file-row-" + fixture.file.uuidString, in: root)
                XCTAssertGreaterThan(try XCTUnwrap(row.frame).width, width * 0.65, "The file action must fill its native list row")
                XCTAssertTrue(self.hasText("README.md", in: root))
                try MacNativeMenuTracking.open(self.more(root)) { menu in
                    XCTAssertNotNil(menu.item(withTitle: "Copy full path"))
                    XCTAssertEqual(menu.item(withTitle: "Show hidden files")?.state, .off)
                    XCTAssertNotNil(menu.item(withTitle: "Full path"))
                    XCTAssertNil(menu.item(withTitle: "Full canonical path"))
                }
                try await self.choose("Copy full path", in: root)
                XCTAssertEqual(fixture.copies, [fixture.path])
                try await self.choose("Full path", in: root)
                try await self.reviewCanonicalPath(fixture.path, in: root, width: Int(width))
                try await self.press("mac-folder-edit-path", in: root)
                XCTAssertEqual(self.descendants(root).compactMap { $0 as? NSTextField }.filter(\.isEditable).count, 1)
                XCTAssertTrue(self.has("mac-folder-go", in: root))
                XCTAssertTrue(fixture.selections.isEmpty)
            }
        }
    }

    func testHiddenToggleKeepsFaultsAndPaginationIncludingFilteredEmptyPages() async throws {
        for width: CGFloat in [260, 320] {
            let fixture = FilesResponses()
            try await hosted(fixture, width: width) { root, _ in
                let hidden = "mac-file-row-" + fixture.hiddenFile.uuidString
                XCTAssertFalse(self.has(hidden, in: root))
                XCTAssertFalse(self.has("mac-folder-row-" + fixture.hiddenFolder.uuidString, in: root))
                XCTAssertTrue(self.hasText(".denied", in: root), "A dotfile access error must not be hidden")
                let initialActions = fixture.actions
                try await self.choose("Show hidden files", in: root)
                XCTAssertTrue(self.has(hidden, in: root))
                XCTAssertTrue(self.has("mac-folder-row-" + fixture.hiddenFolder.uuidString, in: root))
                XCTAssertEqual(fixture.actions, initialActions, "Filtering must not fetch or advance a host page")
                try self.capture(root, name: "files-hidden-shown-\(Int(width))")
                try MacNativeMenuTracking.open(self.more(root)) { menu in
                    XCTAssertEqual(menu.item(withTitle: "Show hidden files")?.state, .on)
                }
                try await self.choose("Show hidden files", in: root)
                fixture.failNext = true
                try await self.press("mac-folder-next-page", in: root)
                XCTAssertTrue(self.has("folder-error", in: root))
                XCTAssertTrue(self.has("mac-folder-retry", in: root))
                XCTAssertTrue(self.hasText(".denied", in: root))
                try await self.press("mac-folder-retry", in: root)
                XCTAssertEqual(fixture.actions.last, .directories(id: fixture.directory, cursor: nil))
                XCTAssertFalse(self.has("folder-error", in: root))
                XCTAssertTrue(self.hasText(".denied", in: root))
                try await self.press("mac-folder-next-page", in: root)
                XCTAssertTrue(self.has("mac-folder-filtered-empty", in: root))
                XCTAssertTrue(try self.renderedText(root).contains("No visible files"), "Paging must show the start of the filtered-page explanation")
                try self.capture(root, name: "files-filtered-empty-\(Int(width))")
                XCTAssertFalse(self.hasText("This folder is empty.", in: root))
                XCTAssertTrue(self.has("mac-folder-previous-page", in: root))
                XCTAssertTrue(self.has("mac-folder-next-page", in: root))
                try await self.choose("Show hidden files", in: root)
                XCTAssertTrue(self.has(hidden, in: root))
                XCTAssertFalse(self.has("mac-folder-filtered-empty", in: root))
                try await self.choose("Show hidden files", in: root)
                try await self.press("mac-folder-next-page", in: root)
                XCTAssertTrue(self.has("mac-file-row-" + fixture.file.uuidString, in: root))
                XCTAssertFalse(self.has("mac-folder-next-page", in: root))
                let requests = fixture.actions
                try await self.press("mac-folder-previous-page", in: root)
                XCTAssertTrue(self.has("mac-folder-filtered-empty", in: root))
                try await self.press("mac-folder-previous-page", in: root)
                XCTAssertTrue(self.hasText(".denied", in: root))
                XCTAssertEqual(fixture.actions, requests, "Previous pages must remain cached")
                XCTAssertTrue(fixture.selections.isEmpty)
            }
        }
    }

    func testNativeRowsKeepContextLabelsPreviewAndFolderNavigation() async throws {
        for width: CGFloat in [260, 320] {
            let fixture = FilesResponses()
            try await hosted(fixture, width: width) { root, window in
                // Verify repeated preview before context tracking. Presenting a sheet
                // after synthetic context-menu cancellation is order-dependent in this host.
                try await self.press("mac-file-row-" + fixture.file.uuidString, in: root)
                XCTAssertEqual(fixture.actions.last, .preview(id: fixture.file))
                try await self.waitFor("Ordinary file activation must open its native preview sheet", in: root) { !window.sheets.isEmpty }
                try self.capture(root, name: "files-before-context-preview-\(Int(width))")
                let windows = NSApp.windows.map {
                    "\(type(of: $0)) number=\($0.windowNumber) title=\($0.title) visible=\($0.isVisible) parent=\(String(describing: $0.sheetParent?.windowNumber)) sheets=\($0.sheets.count)"
                }.joined(separator: "\n")
                try windows.write(toFile: "/tmp/pi-mac-inspector-review/captures/files-preview-windows-\(Int(width)).txt", atomically: true, encoding: .utf8)
                let initialSheet = try XCTUnwrap(window.sheets.first?.contentView)
                XCTAssertTrue(self.hasText("Private preview fixture", in: initialSheet))
                try self.capture(initialSheet, name: "files-preview-\(Int(width))")
                try await self.press("file-preview-done", in: initialSheet)
                try await self.waitFor("The first preview must finish dismissal", in: root) { window.sheets.isEmpty }
                try await Task.sleep(for: .milliseconds(400))
                try await self.press("mac-file-row-" + fixture.file.uuidString, in: root)
                XCTAssertEqual(fixture.actions.last, .preview(id: fixture.file))
                try await self.waitFor("The repeated native file preview sheet must open", in: root) { !window.sheets.isEmpty }
                let sheet = try XCTUnwrap(window.sheets.first?.contentView)
                XCTAssertTrue(self.hasText("Private preview fixture", in: sheet))
                try await self.press("file-preview-done", in: sheet)
                try await self.waitFor("The second preview must finish dismissal", in: root) { window.sheets.isEmpty }
                try await Task.sleep(for: .milliseconds(400))
                let row = try self.element("mac-file-row-" + fixture.file.uuidString, in: root)
                let frame = try XCTUnwrap(row.frame)
                let tracker = FilesContextMenu()
                NotificationCenter.default.addObserver(tracker, selector: #selector(FilesContextMenu.began(_:)),
                                                       name: NSMenu.didBeginTrackingNotification, object: nil)
                let timer = Timer(timeInterval: 0.04, target: tracker, selector: #selector(FilesContextMenu.tick(_:)), userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .eventTracking)
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate(); NotificationCenter.default.removeObserver(tracker) }
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
                    location: window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
                let release = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseUp,
                    location: event.locationInWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                window.sendEvent(release)
                try await self.settle(root)
                XCTAssertTrue(tracker.titles?.contains("Copy relative path") == true)
                XCTAssertTrue(tracker.titles?.contains("Show in Finder") == true)
                try await self.press("mac-folder-row-" + fixture.folder.uuidString, in: root)
                XCTAssertEqual(fixture.actions.last, .directories(id: fixture.folder, cursor: nil))
                XCTAssertTrue(self.hasText("This folder is empty.", in: root))
                try await self.press("mac-folder-parent", in: root)
                XCTAssertEqual(fixture.actions.last, .directories(id: fixture.directory, cursor: nil))
                XCTAssertTrue(fixture.selections.isEmpty, "Navigation and preview must not select a working directory")
            }
        }
    }

    func testNativeListSelectionAndReturnOpenFolderWithoutSelectingSession() async throws {
        for width: CGFloat in [260, 320] {
            let fixture = FilesResponses()
            try await hosted(fixture, width: width) { root, window in
                let table = try XCTUnwrap(self.descendants(root).compactMap { $0 as? NSTableView }.first)
                XCTAssertTrue(window.makeFirstResponder(table))
                @MainActor func key(_ characters: String, code: UInt16) throws {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code))
                    window.sendEvent(event)
                }
                try key("\u{f701}", code: 125)
                try await self.settle(root)
                XCTAssertGreaterThanOrEqual(table.selectedRow, 0, "Arrow keys must select a native full row")
                XCTAssertEqual(fixture.actions.count, 1, "Row selection alone must not navigate")
                try key("\r", code: 36)
                try await self.settle(root)
                XCTAssertEqual(fixture.actions.last, .directories(id: fixture.folder, cursor: nil))
                XCTAssertTrue(fixture.selections.isEmpty)
            }
        }
    }

    func testSelectingFlowKeepsCanonicalReviewAndHiddenFoldersVisible() async throws {
        let fixture = FilesResponses()
        try await hosted(fixture, width: 320, selecting: true) { root, _ in
            XCTAssertTrue(self.hasText("Resolved Mac folder", in: root))
            XCTAssertTrue(self.hasText(fixture.path, in: root))
            try await self.reviewCanonicalPath(fixture.path, in: root, width: 320)
            XCTAssertTrue(self.has("mac-folder-copy-path", in: root))
            XCTAssertTrue(self.has("mac-folder-row-" + fixture.hiddenFolder.uuidString, in: root))
            XCTAssertFalse(self.has("mac-folder-more-actions", in: root))
            XCTAssertTrue(fixture.selections.isEmpty)
            try await self.press("mac-folder-select", in: root)
            XCTAssertEqual(fixture.selections, [fixture.path])
        }
    }
}
