import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import Vision
import XCTest

private final class MinimalConversationSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor final class MacMinimalConversationTests: XCTestCase {
    private var captureIndex = 0

    func testDiagnosticCountsUseTypedSeverityNotProviderText() {
        for severity in [ExtensionNoticeSeverity.error, .warning, .info] {
            var state = HostSnapshot(host: UUID(), epoch: UUID())
            state.extensionDisplay = ExtensionDisplayState(notices: [
                ExtensionNotice(id: "one", text: "Warning: provider unavailable", severity: severity),
                ExtensionNotice(id: "two", text: "Success", severity: severity)
            ])
            let counts = MacDesktopDiagnosticCounts(state: state)
            XCTAssertEqual(counts.total, 2)
            XCTAssertEqual(counts.errors, severity == .error ? 2 : 0)
            XCTAssertEqual(counts.warnings, severity == .warning ? 2 : 0)
            XCTAssertEqual(counts.information, severity == .info ? 2 : 0)
            XCTAssertEqual(counts.legacy, 0)
            XCTAssertEqual(counts.needsAttention, severity != .info)
            XCTAssertFalse(counts.text.contains("provider"))
        }
    }

    func testDiagnosticCountsRetainUnknownLegacyNoticesWithoutCountingMirrorsTwice() {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        XCTAssertEqual(MacDesktopDiagnosticCounts(state: state).total, 0)
        state.notices = ["Warning: legacy", "Unclassified legacy"]
        var counts = MacDesktopDiagnosticCounts(state: state)
        XCTAssertEqual(counts.legacy, 2)
        XCTAssertEqual(counts.warnings, 0, "Legacy text must not determine severity.")
        XCTAssertEqual(counts.text, "2 notices (severity unavailable)")
        state.extensionDisplay = ExtensionDisplayState(notices: [
            ExtensionNotice(id: "error", text: "Typed error", severity: .error),
            ExtensionNotice(id: "warning", text: "Typed warning", severity: .warning),
            ExtensionNotice(id: "info", text: "Typed info", severity: .info)
        ])
        state.notices += ["Typed error", "Typed warning", "Typed info"]
        counts = MacDesktopDiagnosticCounts(state: state)
        XCTAssertEqual(counts.total, 5)
        XCTAssertEqual(counts.texts, ["Typed error", "Typed warning", "Typed info", "Warning: legacy", "Unclassified legacy"])
        XCTAssertEqual(counts.text, "1 error · 1 warning · 1 info · 2 notices (severity unavailable)")
        state.notices += ["Typed warning", "typed warning", "Typed warning "]
        counts = MacDesktopDiagnosticCounts(state: state)
        XCTAssertEqual(counts.texts, ["Typed error", "Typed warning", "Typed info", "Warning: legacy", "Unclassified legacy", "typed warning", "Typed warning "])
        XCTAssertEqual(counts.errors, 1)
        XCTAssertEqual(counts.warnings, 1)
        XCTAssertEqual(counts.information, 1)
        XCTAssertEqual(counts.legacy, 4)
        XCTAssertEqual(counts.total, counts.texts.count)
    }

    func testDiagnosticCountsExcludeExactWidgetAndStatusMirrorsOnly() {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.extensionDisplay = ExtensionDisplayState(
            statuses: [ExtensionStatus(id: "status", text: "Status text")],
            widgets: [ExtensionWidget(id: "widget", text: "Widget text", placement: .aboveEditor)],
            notices: [ExtensionNotice(id: "warning", text: "Typed warning", severity: .warning)])
        state.notices = ["Status text", "Widget text", "Typed warning", "Status text", "status text", "Widget text ", "Unknown legacy"]
        let counts = MacDesktopDiagnosticCounts(state: state)
        XCTAssertEqual(counts.errors, 0)
        XCTAssertEqual(counts.warnings, 1)
        XCTAssertEqual(counts.information, 0)
        XCTAssertEqual(counts.legacy, 3)
        XCTAssertEqual(counts.total, 4)
        XCTAssertEqual(counts.texts, ["Typed warning", "status text", "Widget text ", "Unknown legacy"])
    }

    func testRecoveryInstructionsStayVisibleWhenActivityIsBlockedByPendingDialog() async throws {
        try await withModel { model in
            model.interfaceMode = .desktop
            model.state.phase = "recovering"
            let recovery = "Session history was refreshed after lost events. Work status is uncertain. Use Stop, then reopen the saved session; do not resend uncertain actions."
            model.state.dialogs = [ExtensionDialog(id: "pending", method: "confirm", title: "Pending confirmation", message: "Keep pending", options: [], text: "", expires: nil)]
            model.state.extensionDisplay = ExtensionDisplayState(notices: [
                ExtensionNotice(id: "recovery", text: recovery, severity: .warning),
                ExtensionNotice(id: "generic", text: "Generic private warning detail", severity: .warning)
            ])
            model.state.notices = [recovery, "Generic private warning detail", "Unclassified legacy"]
            let counts = MacDesktopDiagnosticCounts(state: model.state)
            XCTAssertEqual(counts.warnings, 1, "Required recovery is not a generic diagnostic.")
            XCTAssertEqual(counts.legacy, 1)
            XCTAssertEqual(counts.total, 2)
            XCTAssertEqual(counts.recovery.map(\.text), [recovery])
            XCTAssertEqual(counts.texts, [recovery, "Generic private warning detail", "Unclassified legacy"], "Activity must retain the complete details.")
            let before = model.state
            var routes: [String] = []
            let controls: (String) -> Bool = { route in
                routes.append(route)
                return model.state.dialogs.isEmpty
            }
            // At this width the complete recovery text requires more than three lines.
            try await hosted(MacDesktopDiagnostics(state: model.state, openControls: controls), width: 260) { host in
                XCTAssertTrue(self.semanticText(host).contains("Warning: " + recovery))
                let rendered = try self.renderedText(host)
                XCTAssertTrue(rendered.contains("Session history was refreshed"))
                XCTAssertTrue(rendered.contains("uncertain actions."), "The final recovery instruction must be painted, not clipped.")
                XCTAssertFalse(rendered.contains("Generic private warning detail"))
                XCTAssertTrue(self.press(try XCTUnwrap(self.find("desktop-diagnostics-details", in: host))))
                XCTAssertEqual(routes, ["activity"])
                XCTAssertEqual(model.state, before)
                XCTAssertNil(model.panel)
            }
            routes = []
            try await hosted(PiConversationView(model: model, openControls: controls)) { host in
                XCTAssertTrue(self.semanticText(host).contains("Warning: " + recovery))
                XCTAssertTrue(try self.renderedText(host).contains("do not resend uncertain actions."))
                XCTAssertNotNil(self.action("Stop", in: host))
                XCTAssertTrue(routes.isEmpty)
                XCTAssertEqual(model.state, before)
                XCTAssertNil(model.panel)
            }
            model.state.extensionDisplay = ExtensionDisplayState(notices: [ExtensionNotice(id: "recovery", text: recovery, severity: .warning)])
            model.state.notices = [recovery]
            try await hosted(MacDesktopDiagnostics(state: model.state, openControls: controls)) { host in
                XCTAssertTrue(self.semanticText(host).contains("Warning: " + recovery))
                XCTAssertNil(self.find("desktop-diagnostics-summary", in: host))
                XCTAssertNil(self.find("desktop-diagnostics-details", in: host))
            }
        }
    }

    func testDiagnosticRowShowsSeverityCountsAndDetailsRouteWithoutRuntimeDispatch() async throws {
        try await withModel { model in
            model.destination = .settings
            model.text = "Unsent draft 文"
            model.state.extensionDisplay = ExtensionDisplayState(notices: [
                ExtensionNotice(id: "error", text: "Private error detail", severity: .error),
                ExtensionNotice(id: "warning", text: "Private warning detail", severity: .warning),
                ExtensionNotice(id: "info", text: "Private info detail", severity: .info)
            ])
            model.state.notices = ["Private legacy detail", "Private warning detail"]
            let before = model.state
            var routes: [String] = []
            try await hosted(MacDesktopDiagnostics(state: model.state, openControls: { routes.append($0); return true })) { host in
                XCTAssertTrue(routes.isEmpty)
                let summary = try XCTUnwrap(self.find("desktop-diagnostics-summary", in: host))
                XCTAssertTrue(self.semanticText(summary).contains("1 error · 1 warning · 1 info · 1 notice (severity unavailable)"))
                XCTAssertFalse(self.semanticText(host).contains { $0.contains("Private") })
                let details = try XCTUnwrap(self.find("desktop-diagnostics-details", in: host))
                XCTAssertTrue(self.press(details))
                XCTAssertEqual(routes, ["activity"])
                XCTAssertEqual(model.destination, .settings)
                XCTAssertEqual(model.state, before)
                XCTAssertEqual(model.text, "Unsent draft 文")
                XCTAssertNil(model.panel)
                XCTAssertNil(model.fault)
                XCTAssertFalse(model.sending)
            }
        }
    }

    func testDesktopEmptyAndPopulatedConversationHaveNoDuplicateActionsResourcesOrRawDiagnostics() async throws {
        try await withModel { model in
            model.interfaceMode = .desktop
            model.text = "Keep draft"
            model.state.extensionDisplay = ExtensionDisplayState(notices: [
                ExtensionNotice(id: "warning", text: "Raw diagnostic must stay in Activity", severity: .warning)
            ])
            model.state.commands = [CommandOption(name: "skill:resource", detail: "", source: "skill")]
            for populated in [false, true] {
                model.state.messages = populated ? [TranscriptMessage(role: "assistant", text: "Conversation result")] : []
                let before = model.state
                var routes: [String] = []
                try await hosted(PiConversationView(model: model, openControls: { routes.append($0); return true })) { host in
                    XCTAssertTrue(routes.isEmpty)
                    let rendered = try self.renderedText(host)
                    XCTAssertEqual(rendered.contains("Write an instruction below."), !populated)
                    if populated { XCTAssertTrue(rendered.contains("Conversation result")) }
                    for identifier in ["desktop-session-controls", "desktop-welcome-files", "desktop-welcome-commands", "desktop-welcome-new-session", "desktop-welcome-resume", "desktop-commands", "desktop-session-resources", "pi-activity"] {
                        XCTAssertNil(self.find(identifier, in: host), identifier)
                    }
                    XCTAssertFalse(self.semanticText(host).contains { $0.contains("Raw diagnostic must stay in Activity") })
                    XCTAssertFalse(rendered.contains("Raw diagnostic must stay in Activity"))
                    XCTAssertNotNil(self.find("desktop-diagnostics-details", in: host))
                    XCTAssertNotNil(self.find("pi-editor", in: host))
                    XCTAssertTrue(rendered.contains("Usage unavailable"))
                    XCTAssertNotNil(self.find("pi-model-selector", in: host))
                    XCTAssertNotNil(self.find("pi-thinking-selector", in: host))
                    XCTAssertEqual(model.state, before)
                    XCTAssertEqual(model.text, "Keep draft")
                    XCTAssertNil(model.fault)
                }
            }
        }
    }

    func testResourcesShowFullDiscoveredDataWithoutRuntimeActions() async throws {
        try await withModel { model in
            let skills = (0..<24).map { "skill-\($0)-文" }
            let prompts = (0..<24).map { "prompt-\($0)-文" }
            model.state.commands = skills.map { CommandOption(name: "skill:" + $0, detail: "", source: "skill") }
                + prompts.map { CommandOption(name: $0, detail: "", source: "prompt") }
                + [CommandOption(name: "not-a-resource", detail: "", source: "extension")]
            let before = model.state
            for width: CGFloat in [260, 320] {
                try await hosted(ScrollView { MacDesktopSessionResources(state: model.state) }, width: width) { host in
                    // Selectable SwiftUI Text uses native text cells that can omit its identifier.
                    let text = self.semanticText(host)
                    XCTAssertTrue(text.contains("Loaded context paths are not reported by Pi RPC."))
                    XCTAssertTrue(text.contains(skills.joined(separator: ", ")))
                    XCTAssertTrue(text.contains(prompts.map { "/" + $0 }.joined(separator: ", ")))
                    let rendered = try self.renderedText(host)
                    XCTAssertTrue(rendered.contains("Context"))
                    XCTAssertTrue(rendered.contains("Skills"))
                    XCTAssertFalse(self.semanticText(host).contains { $0.contains("not-a-resource") })
                    XCTAssertEqual(model.state, before)
                    XCTAssertNil(model.panel)
                    XCTAssertNil(model.fault)
                    XCTAssertFalse(model.sending)
                }
            }
        }
    }

    func testEmptyResourcesReportMissingEntriesWithoutInventingContextPaths() async throws {
        let state = HostSnapshot(host: UUID(), epoch: UUID())
        try await hosted(MacDesktopSessionResources(state: state).padding(12), width: 260) { host in
            let missing = self.objects(in: host).filter { self.value($0, "accessibilityValue") as? String == "No entries reported by Pi." }
            XCTAssertGreaterThanOrEqual(missing.count, 2, "Both resource sections must report missing entries.")
            XCTAssertTrue(self.semanticText(host).contains("Loaded context paths are not reported by Pi RPC."))
            let rendered = try self.renderedText(host)
            for label in ["Context", "Skills", "Prompts", "No entries reported by Pi."] {
                XCTAssertTrue(rendered.contains(label), label)
            }
        }
    }

    func testPiKeepsStartupResourcesAndVisibleWarningText() async throws {
        try await withModel { model in
            model.interfaceMode = .pi
            model.state.extensionDisplay = ExtensionDisplayState(notices: [
                ExtensionNotice(id: "warning", text: "Visible Pi warning", severity: .warning)
            ])
            model.state.commands = [CommandOption(name: "skill:fixture-review", detail: "", source: "skill"),
                                    CommandOption(name: "fixture-prompt", detail: "", source: "prompt")]
            try await hosted(PiConversationView(model: model, openControls: { _ in XCTFail("Rendering must not navigate."); return false })) { host in
                let text = self.semanticText(host)
                for resource in ["Loaded context paths are not reported by Pi RPC.", "fixture-review", "/fixture-prompt"] {
                    XCTAssertTrue(text.contains(resource), resource)
                }
                let rendered = try self.renderedText(host)
                for label in ["Pi can explain its own features", "Context", "Skills", "Prompts", "Visible Pi warning"] {
                    XCTAssertTrue(rendered.contains(label), label)
                }
                XCTAssertTrue(text.contains("Activity · 1 notices"))
                XCTAssertNotNil(self.action("Activity · 1 notices", in: host))
                XCTAssertTrue(text.contains { $0.contains("Warning: Visible Pi warning") })
                XCTAssertNil(self.find("desktop-diagnostics", in: host))
            }
        }
    }

    func testDesktopKeepsQueueToolFailureWidgetsStatusesAndStopVisible() async throws {
        try await withModel { model in
            model.interfaceMode = .desktop
            model.state.phase = "working"
            model.state.pendingMessages = 2
            let failure = TranscriptMessage(role: "tool", text: "read\nRequired tool failure", isError: true,
                                            tool: TranscriptTool(name: "read", target: "missing.swift", status: .failed))
            model.state.messages = [failure]
            model.state.extensionDisplay = ExtensionDisplayState(statuses: [ExtensionStatus(id: "status", text: "Required status")], widgets: [
                ExtensionWidget(id: "above", text: "Required above widget", placement: .aboveEditor),
                ExtensionWidget(id: "below", text: "Required below widget", placement: .belowEditor)
            ])
            let before = model.state
            try await hosted(PiConversationView(model: model, openControls: { _ in XCTFail("Rendering must not navigate."); return false })) { host in
                let text = self.semanticText(host)
                XCTAssertTrue(text.contains { $0.contains("Required tool failure") })
                for content in ["Required above widget", "Required below widget", "Required status"] {
                    XCTAssertTrue(text.contains(content), content)
                }
                let rendered = try self.renderedText(host)
                for content in ["2 queued", "Required tool failure", "Required above widget", "Required below widget", "Required status", "Stop"] {
                    XCTAssertTrue(rendered.contains(content), content)
                }
                XCTAssertNotNil(self.find("pi-tool-toggle-" + failure.id.uuidString, in: host))
                XCTAssertNotNil(self.action("Stop", in: host))
                XCTAssertEqual(model.state, before)
                XCTAssertNil(model.fault)
            }
        }
    }

    private func withModel(_ body: (CompanionModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.MinimalConversation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: MinimalConversationSecrets(), defaults: defaults,
                                   debugDirectory: root.appendingPathComponent("debug"))
        let id = UUID()
        model.state.sessions = [SessionInfo(id: id, title: "Minimal fixture", directory: "/tmp/fixture-project")]
        model.state.selected = id
        do { try await body(model) } catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    private func value(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let result = object.perform(selector)?.takeUnretainedValue() { return result }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func objects(in root: NSObject) -> [NSObject] {
        var pending: [NSObject] = [root]
        if let view = root as? NSView {
            if let window = view.window {
                for y in stride(from: CGFloat(6), to: view.bounds.height, by: 12) {
                    for x in stride(from: CGFloat(6), to: view.bounds.width, by: 12) {
                        let point = window.convertPoint(toScreen: view.convert(NSPoint(x: x, y: y), to: nil))
                        if let hit = view.accessibilityHitTest(point) as? NSObject { pending.append(hit) }
                    }
                }
            }
            pending.append(contentsOf: descendants(view))
            for scroll in descendants(view).compactMap({ $0 as? NSScrollView }) {
                guard let window = scroll.window else { continue }
                for y in stride(from: CGFloat(6), to: scroll.bounds.height, by: 12) {
                    let point = window.convertPoint(toScreen: scroll.convert(NSPoint(x: 40, y: y), to: nil))
                    if let hit = scroll.accessibilityHitTest(point) as? NSObject { pending.append(hit) }
                }
            }
        }
        // Match the Files inspector helper: seed native views and visible AX hits,
        // then walk children only. Native proxy parents can form unbounded cycles.
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = [], index = 0
        while index < pending.count, seen.count < 8192 {
            let object = pending[index]
            index += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            pending.append(contentsOf: value(object, "accessibilityChildren") as? [NSObject] ?? [])
        }
        return result
    }

    private func capture(_ root: NSView) throws {
        captureIndex += 1
        let name = self.name.replacingOccurrences(of: "/", with: "-") + "-\(captureIndex)"
        let folder = URL(fileURLWithPath: "/tmp/pi-minimal-desktop/conversation-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = try MacDebugController.snapshot(window: XCTUnwrap(root.window))
        let bitmap = NSBitmapImageRep(cgImage: image.value)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
        let dump = objects(in: root).map {
            "\(type(of: $0)) id=\(value($0, "accessibilityIdentifier") ?? "") label=\(value($0, "accessibilityLabel") ?? "") value=\(value($0, "accessibilityValue") ?? "")"
        }.joined(separator: "\n")
        try dump.write(to: folder.appendingPathComponent(name + "-ax.txt"), atomically: true, encoding: .utf8)
    }

    private func renderedText(_ root: NSView) throws -> String {
        let image = try MacDebugController.snapshot(window: XCTUnwrap(root.window))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image.value).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func find(_ identifier: String, in root: NSView) -> NSObject? {
        objects(in: root).first { value($0, "accessibilityIdentifier") as? String == identifier }
    }

    private func semanticText(_ object: NSObject) -> Set<String> {
        Set(objects(in: object).flatMap { object in
            [value(object, "accessibilityValue"), value(object, "accessibilityLabel")].compactMap { $0 as? String }
        })
    }

    private func action(_ label: String, in root: NSView) -> NSObject? {
        objects(in: root).first {
            value($0, "accessibilityLabel") as? String == label && $0.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }
    }

    private func press(_ object: NSObject) -> Bool {
        if let button = object as? NSButton {
            guard button.isEnabled else { return false }
            button.performClick(nil)
            return true
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }

    private func hosted<V: View>(_ view: V, width: CGFloat = 880, exercise: (NSView) throws -> Void) async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy(), previous = NSWorkspace.shared.frontmostApplication
        app.setActivationPolicy(.regular)
        app.unhide(nil)
        let controller = NSHostingController(rootView: view.environment(\.accessibilityEnabled, true)
            .environment(\.colorScheme, .light).frame(width: width, height: 740, alignment: .top).background(.background))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 740))
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            app.setActivationPolicy(policy)
            previous?.activate()
        }
        window.makeKeyAndOrderFront(nil)
        app.activate()
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        try capture(controller.view)
        try exercise(controller.view)
    }
}
