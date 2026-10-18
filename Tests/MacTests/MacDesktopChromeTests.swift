import AppKit
import SwiftUI
import XCTest

@MainActor private struct DesktopChromeAccessibility {
    let object: NSObject

    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    func semanticText() -> Set<String> {
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) -> Set<String> {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = DesktopChromeAccessibility(object: object)
            var text = Set([element.value("accessibilityValue"), element.value("accessibilityLabel")].compactMap { $0 as? String })
            for child in element.value("accessibilityChildren") as? [NSObject] ?? [] {
                text.formUnion(collect(child))
            }
            if let view = object as? NSView {
                for child in view.subviews { text.formUnion(collect(child)) }
            }
            return text
        }
        return collect(object)
    }

    func boolean(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }

    func press() -> Bool {
        if let button = object as? NSButton {
            guard button.isEnabled else { return false }
            button.performClick(nil)
            return true
        }
        return boolean("accessibilityPerformPress")
    }

    func frame() throws -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        XCTAssertTrue(object.responds(to: selector))
        guard object.responds(to: selector) else { throw CocoaError(.featureUnsupported) }
        typealias Method = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }
}

@MainActor final class MacDesktopChromeTests: XCTestCase {
    func testHeaderShowsIdentityAndPhaseWithoutDuplicateSessionControl() async throws {
        let header = MacDesktopHeader(title: "Review changes", directory: "/tmp/project", phase: "Working", hasSession: true)
        try await hosted(header) { host, _ in
            _ = try self.element("desktop-session-header", in: host)
            XCTAssertTrue(try self.element("desktop-session-title", in: host).semanticText().contains("Review changes"))
            XCTAssertTrue(try self.element("desktop-session-directory", in: host).semanticText().contains("/tmp/project"))
            XCTAssertFalse(try self.element("desktop-session-phase", in: host).semanticText().isDisjoint(with: ["Working", "Session phase: Working"]))
            XCTAssertNil(self.find("desktop-session-controls", in: host))
        }
    }

    func testHeaderWithoutSessionOmitsDuplicateControlsAndMissingDirectory() async throws {
        for directory: String? in [nil, ""] {
            let header = MacDesktopHeader(title: "Pi Remote", directory: directory, phase: "idle", hasSession: false)
            try await hosted(header) { host, _ in
                XCTAssertNil(self.find("desktop-session-directory", in: host))
                let phase = try self.element("desktop-session-phase", in: host)
                // SwiftUI can put the identifier on a wrapper and the status on its text child.
                XCTAssertFalse(phase.semanticText().isDisjoint(with: ["Session phase: No session loaded", "No session loaded"]),
                               "The session phase must report that no session is loaded.")
                XCTAssertNil(self.find("desktop-session-controls", in: host))
            }
        }
    }

    func testWelcomeUsesToolbarNewSessionGuidanceAndExplicitResumeOnly() async throws {
        var calls = 0
        let welcome = MacDesktopWelcome(hasSession: false, canStart: true, resume: { calls += 1 })
        try await hosted(welcome) { host, _ in
            XCTAssertEqual(calls, 0, "Rendering must not dispatch an action.")
            _ = try self.element("desktop-welcome", in: host)
            XCTAssertTrue(try self.element("desktop-welcome-subtitle", in: host).semanticText().contains("Use New session in the toolbar to choose a folder, or resume saved work."))
            for identifier in ["desktop-welcome-files", "desktop-welcome-commands", "desktop-welcome-new-session"] {
                XCTAssertNil(self.find(identifier, in: host))
            }
            let button = try self.element("desktop-welcome-resume", in: host)
            XCTAssertTrue(button.boolean("isAccessibilityEnabled"))
            XCTAssertTrue(button.press())
            XCTAssertEqual(calls, 1)
        }
    }

    func testUnavailableWelcomeDisablesResume() async throws {
        var calls = 0
        let welcome = MacDesktopWelcome(hasSession: false, canStart: false, resume: { calls += 1 })
        try await hosted(welcome) { host, _ in
            XCTAssertNil(self.find("desktop-welcome-new-session", in: host))
            let button = try self.element("desktop-welcome-resume", in: host)
            XCTAssertFalse(button.boolean("isAccessibilityEnabled"))
            _ = button.press()
            XCTAssertEqual(calls, 0)
        }
    }

    func testEmptySessionShowsOnlyCompactHintWithoutActionsOrHero() async throws {
        var calls = 0
        let welcome = MacDesktopWelcome(hasSession: true, canStart: false, resume: { calls += 1 })
        try await hosted(welcome) { host, _ in
            XCTAssertEqual(calls, 0)
            let hint = try self.element("desktop-empty-hint", in: host)
            XCTAssertTrue(hint.semanticText().contains("Write an instruction below."))
            XCTAssertLessThan(try self.element("desktop-welcome", in: host).frame().height, 80)
            for identifier in ["desktop-welcome-new-session", "desktop-welcome-resume", "desktop-welcome-files", "desktop-welcome-commands", "desktop-welcome-title"] {
                XCTAssertNil(self.find(identifier, in: host))
            }
        }
    }

    func testLightAndDarkBoundsWithLongUnicodeTitleAndDirectory() async throws {
        let title = String(repeating: "調査 🧑🏽‍💻 café — Δοκιμή ", count: 16)
        let directory = "/tmp/" + String(repeating: "長いフォルダー/", count: 18)
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [360, 880] {
                for hasSession in [false, true] {
                    var calls = 0
                    let fixture = VStack(spacing: 12) {
                        MacDesktopHeader(title: title, directory: directory, phase: "Waiting for confirmation", hasSession: hasSession)
                        MacDesktopWelcome(hasSession: hasSession, canStart: false, resume: { calls += 1 })
                    }
                    try await hosted(fixture, width: width, scheme: scheme) { host, window in
                        XCTAssertEqual(host.bounds.width, width, accuracy: 1)
                        let titleElement = try self.element("desktop-session-title", in: host)
                        XCTAssertTrue([titleElement.value("accessibilityValue"), titleElement.value("accessibilityLabel")].contains { $0 as? String == title })
                        let directoryElement = try self.element("desktop-session-directory", in: host)
                        XCTAssertTrue([directoryElement.value("accessibilityValue"), directoryElement.value("accessibilityLabel")].contains { $0 as? String == directory })
                        let identifiers = ["desktop-session-title", "desktop-session-directory", "desktop-session-phase"]
                            + (hasSession ? ["desktop-empty-hint"] : ["desktop-welcome-title", "desktop-welcome-subtitle", "desktop-welcome-resume"])
                        let bounds = window.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -1, dy: -1)
                        for identifier in identifiers {
                            let frame = try self.element(identifier, in: host).frame()
                            XCTAssertGreaterThan(frame.width, identifier == "desktop-session-phase" ? 80 : 0, identifier)
                            XCTAssertGreaterThan(frame.height, 0, identifier)
                            XCTAssertTrue(bounds.contains(frame), "Out of bounds: \(identifier), \(scheme), \(width): \(frame) outside \(bounds)")
                        }
                        XCTAssertEqual(calls, 0, "Layout and appearance must not dispatch actions.")
                    }
                }
            }
        }
    }

    private func find(_ identifier: String, in root: NSView) -> DesktopChromeAccessibility? {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) -> DesktopChromeAccessibility? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let element = DesktopChromeAccessibility(object: object)
            if element.value("accessibilityIdentifier") as? String == identifier { return element }
            for child in element.value("accessibilityChildren") as? [NSObject] ?? [] {
                if let result = visit(child) { return result }
            }
            if let view = object as? NSView {
                for child in view.subviews {
                    if let result = visit(child) { return result }
                }
            }
            return nil
        }
        return visit(root)
    }

    private func element(_ identifier: String, in root: NSView) throws -> DesktopChromeAccessibility {
        try XCTUnwrap(find(identifier, in: root), "Missing accessibility element: " + identifier)
    }

    private func hosted<V: View>(_ view: V, width: CGFloat = 520, scheme: ColorScheme = .light,
                                exercise: (NSView, NSWindow) throws -> Void) async throws {
        let controller = NSHostingController(rootView: view
            .environment(\.accessibilityEnabled, true)
            .preferredColorScheme(scheme)
            .frame(width: width, height: 600, alignment: .top))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 600))
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        controller.view.layoutSubtreeIfNeeded()
        try exercise(controller.view, window)
    }
}
