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

    @MainActor private final class FixtureState: ObservableObject {
        @Published var state: HostSnapshot
        init(_ state: HostSnapshot) { self.state = state }
    }

    private struct FixtureView: View {
        @ObservedObject var fixture: FixtureState
        let spy: RequestSpy

        var body: some View {
            NavigationStack {
                SessionControls(state: fixture.state, request: spy.request, preview: { _ in
                    XCTFail("Session controls must not open a preview without an explicit action")
                })
            }
        }
    }

    private func snapshot() -> HostSnapshot {
        let session = UUID()
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = session
        state.sessions = [SessionInfo(id: session, title: "Phone fixture", directory: "/fixture/phone-session")]
        state.piVersion = "9.9.9"
        state.capabilities = ["pi-release-notes", "models", "thinking", "model-cycling", "close-session", "clone", "git-diff"]
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

    private func hosted(_ fixture: FixtureState, spy: RequestSpy,
                        _ body: (UIView) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let view = FixtureView(fixture: fixture, spy: spy)
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
        // This diagnostic includes inactive recycled cells; it is not visibility evidence.
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

    private func assertDetails(_ root: UIView, expanded: Bool, changelog: Bool, name: String) async throws {
        var foundDetails = false, foundVersion = false, foundChangelog = false, pageNumber = 0
        try await pages(root) { page in
            // Check rendered pixels, not labels retained in UIKit's cell cache.
            let text = try self.captureText(page, name: name + "-page-\(pageNumber)")
            pageNumber += 1
            foundDetails = foundDetails || text.contains { $0.text == "details" }
            foundVersion = foundVersion || text.contains { $0.text.contains("version: 9.9.9") }
            foundChangelog = foundChangelog || text.contains { $0.text.contains("pi changelog") }
            XCTAssertFalse(text.contains { $0.text == "advanced" }, "Retain the phone form's primary sections")
        }
        XCTAssertTrue(foundDetails, "The scan must reach Details at the end of the phone form")
        XCTAssertEqual(foundVersion, expanded, "Version must be visible only while Details is expanded")
        XCTAssertEqual(foundChangelog, expanded && changelog, "Pi changelog needs expanded Details and its capability")
    }

    private func toggleDetails(_ root: UIView) async throws {
        // Details is the last section. Resolve its active node after scrolling;
        // do not retain an accessibility object across cell recycling.
        try await pages(root) { _ in }
        let button = try control("Details", in: root)
        XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled), "Details must remain readable")
        XCTAssertTrue(button.accessibilityActivate(), "Cannot activate Details")
        try await settle(root)
    }

    func testModelAndThinkingPrecedeDirectoryWithExplicitCyclesAndCollapsedDetails() async throws {
        let spy = RequestSpy()
        try await hosted(FixtureState(snapshot()), spy: spy) { root in
            let text = try self.captureText(root, name: "Phone-session-model-first")
            var previousY: CGFloat = 1
            for label in ["Model", "Thinking level", "Cycle model", "Cycle thinking level", "Working directory"] {
                let expected = label.lowercased()
                let row = try XCTUnwrap(text.first { $0.text == expected || $0.text.hasPrefix(expected + " ") },
                                       "Missing visible phone row: " + label)
                // Vision's origin is at the bottom of the image.
                XCTAssertLessThan(row.y, previousY, "Wrong phone order: " + label)
                previousY = row.y
            }
            XCTAssertTrue(spy.actions.isEmpty, "Rendering must not read the changelog or dispatch work")
            for (label, action) in [("Cycle model", SessionAction.cycleModel), ("Cycle thinking level", .cycleThinking)] {
                let button = try self.control(label, in: root)
                XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
                XCTAssertTrue(button.accessibilityActivate(), "Cannot activate " + label)
                try await self.settle(root)
                XCTAssertEqual(spy.actions.last, action)
            }
            XCTAssertEqual(spy.actions, [.cycleModel, .cycleThinking])
            try await self.assertDetails(root, expanded: false, changelog: true, name: "Phone-details-collapsed")
            try await self.toggleDetails(root)
            try await self.assertDetails(root, expanded: true, changelog: true, name: "Phone-details-expanded")
            XCTAssertFalse(try self.control("Pi changelog", in: root).accessibilityTraits.contains(.notEnabled))
            try await self.toggleDetails(root)
            try await self.assertDetails(root, expanded: false, changelog: true, name: "Phone-details-recollapsed")
            XCTAssertEqual(spy.actions, [.cycleModel, .cycleThinking], "Scrolling and Details must not dispatch requests")
        }
    }

    func testMissingCapabilitiesRemoveChangelogCycleAndCloseControls() async throws {
        var state = snapshot()
        state.capabilities = []
        let spy = RequestSpy()
        try await hosted(FixtureState(state), spy: spy) { root in
            let text = try self.captureText(root, name: "Phone-session-no-capabilities")
            for label in ["Model", "Thinking level", "Fixture model", "high"] {
                XCTAssertTrue(text.contains { $0.text.contains(label.lowercased()) }, "Retain the visible picker row: " + label)
            }
            // UIKit does not expose the menu picker's actionable node in this
            // in-process tree. Explicit action/disabled checks below use native buttons.
            let unavailable = ["Pi changelog", "Cycle model", "Cycle thinking level", "Close Pi session", "Rename", "Compact context", "Clone session", "Working tree diff"]
            var pageNumber = 0
            try await self.pages(root) { page in
                let text = try self.captureText(page, name: "Phone-no-capabilities-actions-page-\(pageNumber)")
                pageNumber += 1
                for label in unavailable {
                    XCTAssertFalse(text.contains { $0.text.contains(label.lowercased()) }, "Unavailable control: " + label)
                }
            }
            try await self.assertDetails(root, expanded: false, changelog: false, name: "Phone-no-capabilities-collapsed")
            try await self.toggleDetails(root)
            try await self.assertDetails(root, expanded: true, changelog: false, name: "Phone-no-capabilities-expanded")
            try await self.pages(root) { page in
                let text = try self.captureText(page, name: "Phone-no-capabilities-expanded-actions-page-\(pageNumber)")
                pageNumber += 1
                for label in unavailable {
                    XCTAssertFalse(text.contains { $0.text.contains(label.lowercased()) }, "Details must not restore unavailable controls: " + label)
                }
            }
            XCTAssertTrue(spy.actions.isEmpty, "Missing capabilities must not trigger fallback requests")
        }
    }

    func testBusyAndUnloadedActionsStayDisabledWithoutRequests() async throws {
        for unloaded in [false, true] {
            var state = snapshot()
            state.phase = unloaded ? "idle" : "working"
            if unloaded { state.selected = nil }
            let spy = RequestSpy()
            try await hosted(FixtureState(state), spy: spy) { root in
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
                let name = unloaded ? "Phone-unloaded-details" : "Phone-busy-details"
                try await self.assertDetails(root, expanded: false, changelog: true, name: name + "-collapsed")
                try await self.toggleDetails(root)
                try await self.assertDetails(root, expanded: true, changelog: true, name: name + "-expanded")
                XCTAssertFalse(try self.control("Pi changelog", in: root).accessibilityTraits.contains(.notEnabled),
                               "Installed Pi details must remain readable without an idle session")
                try await self.settle(root)
                XCTAssertTrue(spy.actions.isEmpty, "Disabled controls, scrolling and Details must not dispatch requests")
            }
        }
    }

    func testExpandedDetailsPersistsWhenSessionStartsWorking() async throws {
        let fixture = FixtureState(snapshot())
        let spy = RequestSpy()
        try await hosted(fixture, spy: spy) { root in
            try await self.assertDetails(root, expanded: false, changelog: true, name: "Phone-transition-initial")
            try await self.toggleDetails(root)
            try await self.assertDetails(root, expanded: true, changelog: true, name: "Phone-transition-idle")
            fixture.state.phase = "working"
            try await self.settle(root)
            try await self.assertDetails(root, expanded: true, changelog: true, name: "Phone-transition-working")
            var foundCycles = Set<String>()
            try await self.pages(root) { page in
                for label in ["Cycle model", "Cycle thinking level"] {
                    if let button = self.elements(page).first(where: {
                        self.matches($0, label) && $0.accessibilityTraits.contains(.button)
                    }) {
                        foundCycles.insert(label)
                        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled), label)
                    }
                }
            }
            XCTAssertEqual(foundCycles, Set(["Cycle model", "Cycle thinking level"]),
                           "The state update must retain both disabled Cycle controls")
            try await self.toggleDetails(root)
            try await self.assertDetails(root, expanded: false, changelog: true, name: "Phone-transition-recollapsed")
            XCTAssertTrue(spy.actions.isEmpty, "State updates, scrolling and disclosure changes must not dispatch requests")
        }
    }
}
