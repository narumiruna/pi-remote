import AppKit
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class PresentationSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@MainActor final class CompanionPresentationTests: XCTestCase {
    private func withModel(_ body: (CompanionModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.PresentationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: PresentationSecrets(), defaults: defaults)
        XCTAssertNil(model.startupError)
        model.address = "127.0.0.1"
        // Use private synthetic session state. The folder sheet can read the Mac
        // home listing, but never starts Pi, a listener, Keychain or shared storage.
        do { try await body(model) }
        catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    func testServerAndSessionStatusAreIndependent() async throws {
        try await withModel { model in
            XCTAssertEqual(model.serverStatus, "Server: Stopped")
            XCTAssertEqual(model.sessionStatus, "Session: None")
            XCTAssertEqual(model.serverEndpoint, "wss://127.0.0.1:7443")
            model.starting = true
            XCTAssertEqual(model.serverStatus, "Server: Updating")
            model.starting = false; model.listening = true
            XCTAssertEqual(model.serverStatus, "Server: Listening")
            XCTAssertEqual(model.sessionStatus, "Session: None")
            model.state.selected = UUID(); model.state.phase = "working"
            XCTAssertEqual(model.sessionStatus, "Session: working")
            model.listening = false
            XCTAssertEqual(model.serverStatus, "Server: Stopped")
            XCTAssertEqual(model.sessionStatus, "Session: working")
        }
    }

    private func capture<V: View>(_ view: V, name: String, width: CGFloat = 1000, height: CGFloat = 700, sheet: Bool = false, scrollToBottom: Bool = false,
                                  exercise: ((NSView, NSWindow) async throws -> Void)? = nil) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Pi Remote workspace verification"
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer {
            window.close()
            NSApp.setActivationPolicy(previousPolicy)
            previousApplication?.activate()
        }
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).frame(width: width, height: height))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        if let exercise { try await exercise(host, window) }
        XCTAssertEqual(host.bounds.width, width, accuracy: 1)
        XCTAssertEqual(host.bounds.height, height, accuracy: 1)
        let directory = URL(fileURLWithPath: "/tmp/pi-remote-mac-ux-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        @MainActor func nativeTree(_ view: NSView, depth: Int = 0) -> [String] {
            let rows = (view as? NSTableView).map { " rows=\($0.numberOfRows)" } ?? ""
            let title = (view as? NSButton).map { " title=\($0.title) help=\($0.toolTip ?? "")" } ?? ""
            return [String(repeating: " ", count: depth) + String(describing: type(of: view)) + " \(view.frame)" + rows + title] + view.subviews.flatMap { nativeTree($0, depth: depth + 1) }
        }
        try nativeTree(host).joined(separator: "\n").write(to: directory.appendingPathComponent(name + "-native-tree.txt"), atomically: true, encoding: .utf8)
        let target: NSView
        if sheet {
            let presented = try XCTUnwrap(window.sheets.first, "Expected the actual Mac sheet to open")
            XCTAssertLessThanOrEqual(presented.frame.width, window.frame.width)
            XCTAssertLessThanOrEqual(presented.frame.height, window.frame.height)
            target = try XCTUnwrap(presented.contentView)
        } else { target = host }
        if scrollToBottom {
            @MainActor func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            let scroll = try XCTUnwrap(scrollViews(in: target).first { ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 1 },
                                       "Long Mac forms must have a scrollable viewport")
            let document = try XCTUnwrap(scroll.documentView)
            let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentSize.height : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(150))
            target.layoutSubtreeIfNeeded()
        }
        let bitmap = try XCTUnwrap(target.bitmapImageRepForCachingDisplay(in: target.bounds))
        target.cacheDisplay(in: target.bounds, to: bitmap)
        // AppKit's cache can contain a transparent foreground mask. Composite it
        // over an opaque background for layout review; this is not a color audit.
        let context = try XCTUnwrap(CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.draw(try XCTUnwrap(bitmap.cgImage), in: rect)
        let opaque = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let data = try XCTUnwrap(opaque.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000)
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 13) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 13) {
                if let color = opaque.colorAt(x: min(x, opaque.pixelsWide - 1), y: min(y, opaque.pixelsHigh - 1)) { colors.insert(color.description) }
            }
        }
        XCTAssertGreaterThan(colors.count, 8, "Capture must contain rendered controls, not a blank window")
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func testStoppedServerAndEmptySessionAtMinimumWindowSize() async throws {
        try await withModel { model in
            try await capture(CompanionWindow(model: model), name: "stopped-empty-minimum", width: 900, height: 600)
        }
    }

    func testListeningServerKeepsPairingAndSessionStartVisible() async throws {
        try await withModel { model in
            model.listening = true
            try await capture(CompanionWindow(model: model), name: "listening-empty-minimum")
        }
    }

    func testActiveSessionKeepsConversationAndServerStatus() async throws {
        try await withModel { model in
            let id = UUID()
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("pi-workspace-render-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: path) }
            try Data("let answer = 42".utf8).write(to: path.appendingPathComponent("Example.swift"))
            model.state.sessions = [SessionInfo(id: id, title: "Synthetic session", directory: path.path)]
            model.state.selected = id; model.state.piVersion = "1.3.0"; model.destination = .session(id)
            model.expandedWorkspaces = [path.path]
            model.inspectorVisible = true
            model.state.messages = [TranscriptMessage(role: "user", text: "Inspect the build error."),
                                    TranscriptMessage(role: "tool", text: "Read file\nSources/Example.swift\nlet answer = 42"),
                                    TranscriptMessage(role: "assistant", text: "The source is ready.\n\n```swift\nlet answer = 42\n```")]
            try await capture(CompanionWindow(model: model), name: "active-workspace-session", width: 1300, height: 800) { host, window in
                @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
                let outline = try XCTUnwrap(descendants(host).compactMap { $0 as? NSOutlineView }.first { $0.numberOfRows > 5 })
                let selected = outline.selectedRow
                XCTAssertGreaterThanOrEqual(selected, 0)
                let item = try XCTUnwrap(outline.item(atRow: selected))
                let parent = try XCTUnwrap(outline.parent(forItem: item), "Sessions must be nested under a workspace")
                let workspaceRow = outline.row(forItem: parent)
                outline.selectRowIndexes(IndexSet(integer: workspaceRow), byExtendingSelection: false)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(model.destination, .workspace(path.path))
                outline.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(model.destination, .session(id))
                XCTAssertFalse(model.openingSession, "Selecting an already loaded session must not start another process")
                let click = host.convert(NSPoint(x: host.bounds.width - 32, y: 24), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: click, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertFalse(model.inspectorVisible, "The visible Inspector button must collapse its panel")
                model.inspectorVisible = true
                try await Task.sleep(for: .milliseconds(150))
            }
            try await capture(CompanionWindow(model: model), name: "active-workspace-minimum", width: 900, height: 600)
            model.state.phase = "working"; model.destination = .workspace(path.path)
            try await capture(CompanionWindow(model: model), name: "busy-workspace-minimum", width: 900, height: 600)
        }
    }

    func testConnectionSettingsSeparatePairedAccessFromLiveStatus() async throws {
        try await withModel { model in
            model.devices = [PairedDevice(id: UUID(), name: "Synthetic iPhone")]
            try await capture(NavigationStack { CompanionDevicesView(model: model) },
                              name: "connection-settings", width: 560, height: 680)
        }
    }

    func testSessionToolsRemainScrollableInANarrowInspector() async throws {
        try await withModel { model in
            let id = UUID()
            model.state.sessions = [SessionInfo(id: id, title: "Synthetic session", directory: "/tmp/synthetic-project")]
            model.state.selected = id; model.state.phase = "unavailable"
            let controls = NavigationStack {
                SessionControls(state: model.state, request: model.scopedRequest(for: model.state)) { _ in }.formStyle(.grouped)
            }
            try await capture(controls, name: "session-tools-inspector", width: 320, height: 650)
            try await capture(controls, name: "session-tools-bottom", width: 320, height: 650, scrollToBottom: true)
        }
    }

    func testFolderPickerSheetFitsTheMinimumWindow() async throws {
        try await withModel { model in
            model.panel = "directory"
            try await capture(CompanionWindow(model: model), name: "folder-picker-sheet", sheet: true)
        }
    }

    func testEmptySessionActionsRemainVisibleWithLargeText() async throws {
        try await withModel { model in
            try await capture(CompanionWindow(model: model).environment(\.dynamicTypeSize, .accessibility3),
                              name: "stopped-empty-large-text", width: 1000, height: 700)
        }
    }
}
