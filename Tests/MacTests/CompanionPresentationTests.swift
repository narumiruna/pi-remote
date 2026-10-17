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

@MainActor private struct PresentationAccessibility {
    let object: NSObject
    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }
    func accessibilityIdentifier() -> String? { value("accessibilityIdentifier") as? String }
    func isAccessibilityEnabled() -> Bool { boolean("isAccessibilityEnabled") }
    func accessibilityPerformPress() -> Bool { boolean("accessibilityPerformPress") }
    private func boolean(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }
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

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func accessibilityElements(in root: NSView) -> [PresentationAccessibility] {
        _ = root.accessibilityHitTest(root.window?.convertPoint(toScreen: NSPoint(x: 20, y: 20)) ?? .zero)
        var visited = Set<ObjectIdentifier>()
        var result: [PresentationAccessibility] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let element = PresentationAccessibility(object: object)
            result.append(element)
            for child in element.value("accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return result
    }

    private func element(_ identifier: String, in root: NSView) throws -> PresentationAccessibility {
        let elements = accessibilityElements(in: root)
        let exact = elements.first { $0.accessibilityIdentifier() == identifier }
        // SwiftUI can propagate a Form identifier to its children. Match the
        // visible command label when the child identifier is replaced.
        let visible = elements.first { node in
            let label = node.value("accessibilityLabel") as? String ?? ""
            let value = node.value("accessibilityValue") as? String ?? ""
            if identifier.hasPrefix("session-command-"), identifier != "session-command-error" {
                return label.hasPrefix("/" + identifier.replacingOccurrences(of: "session-command-", with: "") + ",")
            }
            switch identifier {
            case "session-commands-form": return label == "Commands, skills, and templates"
            case "session-commands-empty": return value == "No commands are available for this session."
            case "session-command-error": return value == RemoteFault.unsupportedFeature.explanation
            case "mac-folder-breadcrumb": return label == "project"
            default: return false
            }
        }
        return try XCTUnwrap(exact ?? visible, "Missing rendered control: \(identifier)")
    }

    private func press(_ identifier: String, in root: NSView, title: String? = nil, help: String? = nil) async throws {
        let native = descendants(root).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == identifier || (title != nil && $0.title == title) || (help != nil && $0.toolTip == help)
        }
        if let native {
            XCTAssertTrue(native.isEnabled, "Disabled control: \(identifier)")
            native.performClick(nil)
        } else {
            let control = try element(identifier, in: root)
            XCTAssertTrue(control.isAccessibilityEnabled(), "Disabled control: \(identifier)")
            XCTAssertTrue(control.accessibilityPerformPress(), "Control must support native activation: \(identifier)")
        }
        try await Task.sleep(for: .milliseconds(150))
        root.layoutSubtreeIfNeeded()
    }

    private func enter(_ text: String, placeholder: String, in root: NSView) throws {
        let field = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == placeholder || ($0.isEditable && self.descendants(root).compactMap { $0 as? NSTextField }.filter(\.isEditable).count == 1)
        }, "Missing native text field: \(placeholder)")
        XCTAssertTrue(field.isEnabled)
        let window = try XCTUnwrap(field.window)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: text, charactersIgnoringModifiers: text,
                                                  isARepeat: false, keyCode: 0))
        window.sendEvent(event)
        window.makeFirstResponder(nil)
        XCTAssertEqual(field.stringValue, text)
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

    func testRemoteAccessSummaryDoesNotDependOnSessionRunState() async throws {
        try await withModel { model in
            for phase in ["idle", "working", "unavailable"] {
                model.state.phase = phase
                model.listening = false; model.starting = false; model.connectedDevices = []
                XCTAssertEqual(model.remoteAccessSummary, "Remote access off")
                model.starting = true
                XCTAssertEqual(model.remoteAccessSummary, "Remote access updating")
                model.starting = false; model.listening = true
                XCTAssertEqual(model.remoteAccessSummary, "Remote access on · no devices")
                model.connectedDevices = [UUID()]
                XCTAssertEqual(model.remoteAccessSummary, "1 device connected")
                model.connectedDevices.insert(UUID())
                XCTAssertEqual(model.remoteAccessSummary, "2 devices connected")
            }
            let id = UUID()
            model.state.selected = id; model.destination = .session(id)
            XCTAssertFalse(model.showingLoadedSession, "An unknown session is not displayed as loaded")
            model.state.sessions = [SessionInfo(id: id, title: "Fixture", directory: "/tmp/fixture")]
            XCTAssertTrue(model.showingLoadedSession)
            model.destination = .overview
            XCTAssertFalse(model.showingLoadedSession)
        }
    }

    func testCommandsButtonOpensDedicatedCommandsSheet() async throws {
        try await withModel { model in
            let id = UUID()
            model.state.selected = id
            model.state.sessions = [SessionInfo(id: id, title: "Command fixture", directory: "/tmp/fixture")]
            model.state.commands = [CommandOption(name: "fixture", detail: "Fixture command", source: "extension")]
            model.destination = .session(id)
            model.inspectorVisible = false
            try await capture(CompanionWindow(model: model), name: "uiux-commands-minimum", width: 900, height: 600, sheet: true) { host, window in
                try await self.press("mac-composer-commands", in: host, title: "Commands", help: "Open Pi commands")
                XCTAssertEqual(model.panel, "commands")
                XCTAssertFalse(model.inspectorVisible, "Commands must not route to the Tools inspector")
                let content = try XCTUnwrap(window.sheets.first?.contentView)
                XCTAssertTrue(self.accessibilityElements(in: content).contains { ($0.value("accessibilityValue") as? String) == "Commands" },
                              "The sheet must show the dedicated Commands title")
                let arguments = try XCTUnwrap(self.descendants(content).compactMap { $0 as? NSTextField }.first(where: \.isEditable),
                                              "The dedicated command sheet must expose its arguments field without navigation")
                XCTAssertTrue(arguments.isEnabled)
                XCTAssertTrue(content.bounds.contains(arguments.convert(arguments.bounds, to: content)))
            }
        }
    }

    func testRenderedCommandDispatchesArgumentsOnceAndShowsFailure() async throws {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = UUID()
        state.commands = [CommandOption(name: "fixture", detail: "Fixture command", source: "extension")]
        var actions: [SessionAction] = []
        let view = NavigationStack {
            SessionCommandsView(state: state) { action in
                actions.append(action)
                try await Task.sleep(for: .milliseconds(200))
                return .failure(.unsupportedFeature)
            }
        }
        try await capture(view, name: "uiux-command-dispatch-error", width: 560, height: 480) { host, _ in
            try self.enter("one two --flag", placeholder: "Command arguments", in: host)
            let command = try self.element("session-command-fixture", in: host)
            XCTAssertTrue(command.accessibilityPerformPress())
            _ = command.accessibilityPerformPress()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(actions, [.command(name: "fixture", arguments: "one two --flag")],
                           "An immediate second activation while pending must not dispatch twice")
            _ = try self.element("session-command-error", in: host)
        }
    }

    func testCommandsRespectBusyAndMissingSessionAndShowEmptyState() async throws {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = UUID(); state.phase = "working"
        state.commands = [CommandOption(name: "builtin", detail: "Core fixture", source: "prompt"),
                          CommandOption(name: "extension", detail: "Extension fixture", source: "extension")]
        var actions: [SessionAction] = []
        try await capture(SessionCommandsView(state: state, request: { actions.append($0); return .ok }),
                          name: "uiux-commands-busy", width: 560, height: 480) { host, _ in
            XCTAssertFalse(try self.element("session-command-builtin", in: host).isAccessibilityEnabled())
            XCTAssertTrue(try self.element("session-command-extension", in: host).isAccessibilityEnabled())
            try await self.press("session-command-extension", in: host)
            XCTAssertEqual(actions, [.command(name: "extension", arguments: "")])
        }
        state.selected = nil
        try await capture(SessionCommandsView(state: state, request: { _ in XCTFail("No session must not dispatch"); return .ok }),
                          name: "uiux-commands-no-session", width: 560, height: 480) { host, _ in
            XCTAssertFalse(try self.element("session-command-extension", in: host).isAccessibilityEnabled())
        }
        state.commands = []
        try await capture(SessionCommandsView(state: state, request: { _ in .ok }), name: "uiux-commands-empty", width: 560, height: 480) { host, _ in
            _ = try self.element("session-commands-empty", in: host)
        }
    }

    func testStaleCommandRequestIsRejectedBeforeDispatch() async throws {
        try await withModel { model in
            model.state.selected = UUID()
            let request = model.scopedRequest(for: model.state)
            model.state.selected = UUID()
            do {
                _ = try await request(.command(name: "fixture", arguments: "not delivered"))
                XCTFail("A command from the previous session must fail")
            } catch {
                XCTAssertEqual(error as? RemoteFault, .conflict)
            }
            XCTAssertEqual(model.fault, .conflict)
        }
    }

    func testFilesShortcutKeepsChatAndOpensSingleInspectorDestination() async throws {
        try await withModel { model in
            let id = UUID()
            model.state.selected = id
            model.state.sessions = [SessionInfo(id: id, title: "Files fixture", directory: "/tmp/fixture")]
            model.state.messages = [TranscriptMessage(role: "assistant", text: "Conversation remains visible.")]
            model.destination = .session(id); model.inspectorVisible = false
            try await capture(CompanionWindow(model: model), name: "uiux-files-routing-minimum", width: 900, height: 600) { host, _ in
                try await self.press("mac-composer-files", in: host, title: "Files", help: "Show files in the inspector")
                XCTAssertTrue(model.inspectorVisible)
                XCTAssertEqual(model.destination, .session(id))
                XCTAssertNil(model.panel)
                _ = try self.element("mac-composer-commands", in: host)
                let pickers = self.descendants(host).compactMap { $0 as? NSSegmentedControl }
                let inspectorPicker = try XCTUnwrap(pickers.first { control in
                    (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Files" }
                })
                XCTAssertEqual((0..<inspectorPicker.segmentCount).compactMap { inspectorPicker.label(forSegment: $0) }, ["Files", "Tools", "Activity"])
                XCTAssertEqual(inspectorPicker.selectedSegment, 0)
                let sessionPicker = try XCTUnwrap(pickers.first { control in
                    (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Chat" }
                })
                XCTAssertEqual((0..<sessionPicker.segmentCount).compactMap { sessionPicker.label(forSegment: $0) }, ["Chat", "History"])
                XCTAssertEqual(sessionPicker.selectedSegment, 0)
            }
        }
    }

    func testRemoteAccessDetailsOpenFromRenderedSummaryAtBothWindowSizes() async throws {
        try await withModel { model in
            let id = UUID()
            model.state.selected = id
            model.state.sessions = [SessionInfo(id: id, title: "Remote fixture", directory: "/tmp/fixture")]
            model.destination = .session(id); model.inspectorVisible = true
            for (width, height) in [(900, 600), (1300, 800)] {
                model.listening = width == 1300
                model.connectedDevices = model.listening ? [UUID()] : []
                try await capture(CompanionWindow(model: model), name: "uiux-remote-inspector-\(width)", width: CGFloat(width), height: CGFloat(height)) { host, window in
                    XCTAssertTrue(model.showingLoadedSession)
                    XCTAssertEqual(self.accessibilityElements(in: host).filter { $0.accessibilityIdentifier() == "mac-session-status" }.count, 1,
                                   "Only the session header must show the displayed session status")
                    try await self.press("mac-remote-access", in: host, help: "Show listener and authenticated device status")
                    let roots = [host] + (window.childWindows ?? []).compactMap(\.contentView)
                        + NSApp.windows.filter { $0 !== window }.compactMap(\.contentView)
                    XCTAssertTrue(roots.contains { root in self.accessibilityElements(in: root).contains { $0.accessibilityIdentifier() == "mac-remote-server-status" } })
                    XCTAssertTrue(roots.contains { root in self.accessibilityElements(in: root).contains { $0.accessibilityIdentifier() == "mac-remote-device-status" } })
                    window.makeFirstResponder(nil)
                }
            }
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
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).environment(\.accessibilityEnabled, true).frame(width: width, height: height))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        for _ in 0..<30 {
            _ = host.accessibilityHitTest(window.convertPoint(toScreen: NSPoint(x: 20, y: 20)))
            if accessibilityElements(in: host).contains(where: { $0.accessibilityIdentifier() != nil || $0.value("accessibilityLabel") != nil }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
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

    func testFolderPathEditorNavigatesOnlyAndBlocksSelectionAfterFailure() async throws {
        let initial = DirectoryPage(id: UUID(), path: "/fixture/deeply/nested/project", parent: UUID(), items: [], next: nil)
        let resolved = DirectoryPage(id: UUID(), path: "/fixture/resolved", parent: initial.id, items: [], next: nil)
        var actions: [SessionAction] = []
        var selections: [String] = []
        let view = DirectoryBrowser(selecting: true, request: { action in
            actions.append(action)
            switch action {
            case .directories: return .directories(initial)
            case .directoryAtPath(let path):
                return path == "/fixture/resolved" ? .directories(resolved) : .failure(.permissionDenied)
            default: XCTFail("Unexpected folder action: \(action)"); return .failure(.invalidRequest)
            }
        }, pathEntry: true) { _, path in selections.append(path) }
        try await capture(view, name: "uiux-folder-editor-recovery", width: 560, height: 500) { host, _ in
            XCTAssertFalse(self.descendants(host).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Mac folder path" })
            XCTAssertTrue(try self.element("mac-folder-select", in: host).isAccessibilityEnabled())
            try await self.press("mac-folder-edit-path", in: host, title: "Edit path")
            try self.enter("/fixture/denied", placeholder: "Mac folder path", in: host)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(try self.element("mac-folder-select", in: host).isAccessibilityEnabled(), "An unresolved edit cannot select the previous folder")
            try await self.press("mac-folder-go", in: host, title: "Go")
            _ = try self.element("folder-error", in: host)
            XCTAssertFalse(try self.element("mac-folder-select", in: host).isAccessibilityEnabled())
            XCTAssertTrue(selections.isEmpty)
            try self.enter("/fixture/resolved", placeholder: "Mac folder path", in: host)
            try await self.press("mac-folder-go", in: host, title: "Go")
            XCTAssertTrue(selections.isEmpty, "Go only navigates; it must not select or start Pi")
            XCTAssertEqual(actions, [.directories(id: nil, cursor: nil), .directoryAtPath(path: "/fixture/denied"), .directoryAtPath(path: "/fixture/resolved")])
            XCTAssertTrue(try self.element("mac-folder-select", in: host).isAccessibilityEnabled())
            try await self.press("mac-folder-select", in: host, title: "Start Pi Here")
            XCTAssertEqual(selections, [resolved.path])
        }
    }

    func testFolderParentAndCopyUseResolvedPaths() async throws {
        let parentID = UUID()
        let initial = DirectoryPage(id: UUID(), path: "/fixture/nested/project", parent: parentID, items: [], next: nil)
        let parent = DirectoryPage(id: parentID, path: "/fixture/nested", parent: UUID(), items: [], next: nil)
        var actions: [SessionAction] = []
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let view = DirectoryBrowser(selecting: false, request: { action in
            actions.append(action)
            switch action {
            case .directories(id: nil, cursor: nil): return .directories(initial)
            case .directories(id: parentID, cursor: nil): return .directories(parent)
            default: XCTFail("Unexpected navigation action"); return .failure(.invalidRequest)
            }
        }, pathEntry: true) { _, _ in XCTFail("Browsing must not select a session") }
            .environment(\.clipboardWriter, { try LocalClipboard.copy($0, to: board) })
        try await capture(view, name: "uiux-folder-navigation-copy", width: 320, height: 480) { host, _ in
            try await self.press("mac-folder-copy-path", in: host, title: "Copy full path")
            XCTAssertEqual(board.string(forType: .string), initial.path)
            try await self.press("mac-folder-parent", in: host)
            XCTAssertEqual(actions.last, .directories(id: parentID, cursor: nil))
            try await self.press("mac-folder-copy-path", in: host, title: "Copy full path")
            XCTAssertEqual(board.string(forType: .string), parent.path)
        }
    }

    func testCompactFolderNavigationAtInspectorWidths() async throws {
        let page = DirectoryPage(id: UUID(), path: "/fixture/a-long-workspace-name/deeply/nested/project", parent: UUID(), items: [], next: nil)
        for width in [260, 320] {
            let view = DirectoryBrowser(selecting: false, request: { _ in .directories(page) }, pathEntry: true) { _, _ in
                XCTFail("The inspector must not select a session")
            }
            try await capture(view, name: "uiux-folder-inspector-\(width)", width: CGFloat(width), height: 480) { host, _ in
                _ = try self.element("mac-folder-breadcrumb", in: host)
                _ = try self.element("mac-folder-parent", in: host)
                _ = try self.element("mac-folder-copy-path", in: host)
                try await self.press("mac-folder-edit-path", in: host, title: "Edit path")
                XCTAssertEqual(self.descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable).count, 1,
                               "Edit path must expose one native path field")
                _ = try self.element("mac-folder-go", in: host)
            }
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
