import PiRemoteCore
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import PiRemote

/// Native hosted fixtures only. These tests do not connect to a Mac or start Pi.
@MainActor
final class SessionControlsTests: XCTestCase {
    @MainActor private final class RequestSpy {
        var actions: [SessionAction] = []
        func request(_ action: SessionAction) async throws -> AppResult {
            actions.append(action)
            return .ok
        }
    }

    private func snapshot() -> HostSnapshot {
        let session = UUID()
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = session
        state.sessions = [SessionInfo(id: session, title: "Phone fixture", directory: "/fixture/phone-session")]
        state.piVersion = "9.9.9"
        state.capabilities = ["pi-release-notes", "model-cycling", "close-session"]
        state.models = [ModelOption(provider: "fixture", model: "synthetic", name: "Fixture model")]
        state.model = state.models[0].id
        state.thinkingLevels = ["off", "high"]
        state.thinking = "high"
        return state
    }

    private func descendants(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func elements(_ root: UIView) -> [NSObject] {
        var pending: [NSObject] = descendants(root)
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = [], index = 0
        while index < pending.count, seen.count < 4096 {
            let object = pending[index]
            index += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            pending.append(contentsOf: object.accessibilityElements?.compactMap { $0 as? NSObject } ?? [])
            pending.append(contentsOf: object.automationElements?.compactMap { $0 as? NSObject } ?? [])
            let count = object.accessibilityElementCount()
            if count > 0, count < 256 {
                for child in 0..<count {
                    if let element = object.accessibilityElement(at: child) as? NSObject { pending.append(element) }
                }
            }
        }
        return result
    }

    private func matches(_ object: NSObject, _ label: String) -> Bool {
        let text = object.accessibilityLabel ?? ""
        return text.caseInsensitiveCompare(label) == .orderedSame
            || text.lowercased().hasPrefix(label.lowercased() + ", ")
    }

    private func control(_ label: String, in root: UIView) throws -> NSObject {
        try XCTUnwrap(elements(root).first {
            matches($0, label) && $0.accessibilityTraits.contains(.button)
        }, "Missing native control: " + label)
    }

    private func settle(_ root: UIView) async throws {
        root.setNeedsLayout()
        root.layoutIfNeeded()
        _ = elements(root)
        try await Task.sleep(for: .milliseconds(150))
        root.layoutIfNeeded()
    }

    private func hosted(_ state: HostSnapshot, spy: RequestSpy,
                        _ body: (UIView) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let view = NavigationStack {
            SessionControls(state: state, request: spy.request, preview: { _ in
                XCTFail("Session controls must not open a preview without an explicit action")
            })
        }
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.accessibilityEnabled, true)
        let controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        try await settle(controller.view)
        try await body(controller.view)
    }

    private func captureText(_ root: UIView, name: String) throws -> [(text: String, y: CGFloat)] {
        let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in
            root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let dump = elements(root).map {
            "label=\($0.accessibilityLabel ?? "") value=\($0.accessibilityValue ?? "") traits=\($0.accessibilityTraits.rawValue)"
        }.joined(separator: "\n")
        let accessibility = XCTAttachment(string: dump)
        accessibility.name = name + "-accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text.lowercased(), observation.boundingBox.midY)
        }
    }

    /// Visit each page of the native Form; do not infer absence from its first viewport.
    private func pages(_ root: UIView, inspect: (UIView) throws -> Void) async throws {
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? UIScrollView }
            .max { $0.bounds.height < $1.bounds.height })
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        for _ in 0..<6 {
            try await settle(root)
            try inspect(root)
            let end = max(-scroll.adjustedContentInset.top,
                          scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            if scroll.contentOffset.y >= end - 1 { return }
            scroll.setContentOffset(CGPoint(x: 0, y: min(end, scroll.contentOffset.y + scroll.bounds.height * 0.7)), animated: false)
        }
        XCTFail("The synthetic Session form exceeded the six-page scan limit")
    }

    func testLegacyOrderKeepsVersionChangelogAndExplicitCycleActions() async throws {
        let spy = RequestSpy()
        try await hosted(snapshot(), spy: spy) { root in
            let text = try self.captureText(root, name: "Phone-session-legacy")
            var previousY: CGFloat = 1
            for label in ["Working directory", "Installed Pi", "Pi", "Version: 9.9.9", "Model", "Thinking level"] {
                let expected = label.lowercased()
                let row = try XCTUnwrap(text.first { $0.text == expected || $0.text.hasPrefix(expected + " ") },
                                       "Missing visible legacy row: " + label)
                // Vision's origin is at the bottom of the image.
                XCTAssertLessThan(row.y, previousY, "Wrong legacy order: " + label)
                previousY = row.y
            }
            for label in ["Pi changelog", "Cycle model", "Cycle thinking level"] {
                XCTAssertTrue(text.contains { $0.text.contains(label.lowercased()) }, "Missing visible action: " + label)
            }
            let changelog = try self.control("Pi changelog", in: root)
            XCTAssertFalse(changelog.accessibilityTraits.contains(.notEnabled))
            XCTAssertTrue(spy.actions.isEmpty, "Rendering must not read the changelog or dispatch work")
            for (label, action) in [("Cycle model", SessionAction.cycleModel), ("Cycle thinking level", .cycleThinking)] {
                let button = try self.control(label, in: root)
                XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
                XCTAssertTrue(button.accessibilityActivate(), "Cannot activate " + label)
                try await self.settle(root)
                XCTAssertEqual(spy.actions.last, action)
            }
            XCTAssertEqual(spy.actions, [.cycleModel, .cycleThinking])
            try await self.pages(root) { page in
                for object in self.elements(page) {
                    XCTAssertFalse(self.matches(object, "Details"), "Desktop Details must not replace the iPhone form")
                    XCTAssertFalse(self.matches(object, "Advanced"), "Desktop Advanced must not replace the iPhone form")
                }
            }
            XCTAssertEqual(spy.actions, [.cycleModel, .cycleThinking], "Scrolling must not dispatch requests")
        }
    }

    func testMissingCapabilitiesRemoveChangelogCycleAndCloseControls() async throws {
        var state = snapshot()
        state.capabilities = []
        let spy = RequestSpy()
        try await hosted(state, spy: spy) { root in
            let text = try self.captureText(root, name: "Phone-session-no-capabilities")
            XCTAssertTrue(text.contains { $0.text.contains("version: 9.9.9") })
            for label in ["Model", "Thinking level", "Fixture model", "high"] {
                XCTAssertTrue(text.contains { $0.text.contains(label.lowercased()) }, "Retain the visible picker row: " + label)
            }
            // UIKit does not expose the menu picker's actionable node in this
            // in-process tree. Explicit action/disabled checks below use native buttons.
            var foundClone = false
            try await self.pages(root) { page in
                let all = self.elements(page)
                for label in ["Pi changelog", "Cycle model", "Cycle thinking level", "Close Pi session"] {
                    XCTAssertFalse(all.contains { self.matches($0, label) }, "Unavailable control: " + label)
                }
                foundClone = foundClone || all.contains { self.matches($0, "Clone session") }
            }
            XCTAssertTrue(foundClone, "The scan must reach the retained Session actions")
            XCTAssertTrue(spy.actions.isEmpty, "Missing capabilities must not trigger fallback requests")
        }
    }

    func testBusyAndUnloadedActionsStayDisabledWithoutRequests() async throws {
        for unloaded in [false, true] {
            var state = snapshot()
            state.phase = unloaded ? "idle" : "working"
            if unloaded { state.selected = nil }
            let spy = RequestSpy()
            try await hosted(state, spy: spy) { root in
                let text = try self.captureText(root, name: unloaded ? "Phone-session-unloaded" : "Phone-session-busy")
                for label in ["Model", "Thinking level"] {
                    XCTAssertTrue(text.contains { $0.text.contains(label.lowercased()) }, "Retain the visible picker label: " + label)
                }
                for label in ["Cycle model", "Cycle thinking level"] {
                    let button = try self.control(label, in: root)
                    XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled), label)
                    _ = button.accessibilityActivate()
                }
                var foundActions = Set<String>()
                try await self.pages(root) { page in
                    for label in ["Clone session", "Working tree diff", "Close Pi session"] {
                        if let button = self.elements(page).first(where: {
                            self.matches($0, label) && $0.accessibilityTraits.contains(.button)
                        }) {
                            foundActions.insert(label)
                            XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled), label)
                            _ = button.accessibilityActivate()
                        }
                    }
                }
                XCTAssertEqual(foundActions, Set(["Clone session", "Working tree diff", "Close Pi session"]),
                               "The scan must reach all checked Session actions")
                try await self.settle(root)
                XCTAssertTrue(spy.actions.isEmpty, "Disabled controls must not dispatch requests")
            }
        }
    }
}
