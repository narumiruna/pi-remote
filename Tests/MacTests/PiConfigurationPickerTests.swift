import AppKit
import PiRemoteCore
import SwiftUI
import XCTest

@MainActor final class PiConfigurationPickerTests: XCTestCase {
    private func snapshot() -> HostSnapshot {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = UUID()
        state.models = [
            ModelOption(provider: "second", model: "one", name: "Shared name"),
            ModelOption(provider: "first", model: "two", name: "Shared name"),
            ModelOption(provider: "second", model: "three", name: "Other name")
        ]
        state.model = "first/two"
        state.thinkingLevels = ["off", "medium", "high"]
        state.thinking = "medium"
        return state
    }

    func testProviderGroupsKeepFirstSeenOrderAndDuplicateNamesKeepTheirIdentity() {
        let state = snapshot()
        let choices = PiConfigurationChoices(state: state, thinking: false)
        XCTAssertEqual(choices.groups.map(\.id), ["second", "first"])
        XCTAssertEqual(choices.groups[0].choices.map(\.id), ["second/one", "second/three"])
        XCTAssertEqual(choices.choices.map(\.name), ["Shared name", "Other name", "Shared name"])
        XCTAssertEqual(choices.choices.filter(\.current).map(\.id), ["first/two"])
        XCTAssertEqual(choices.initialSelection, "first/two")
        XCTAssertEqual(choices.choices.last?.action, .model(provider: "first", id: "two"))
        XCTAssertEqual(choices.choices.last?.model, "two")
        var filteredState = state
        filteredState.models[0].name = "Excluded"
        let filtered = PiConfigurationChoices(state: filteredState, thinking: false, query: "name")
        XCTAssertEqual(filtered.groups.map(\.id), ["second", "first"], "Search must not reorder providers when their first model is hidden.")
        XCTAssertEqual(filtered.choices.map(\.id), ["second/three", "first/two"])
    }

    func testThinkingUsesCurrentLevelWithoutProviderHeadings() {
        let state = snapshot()
        let choices = PiConfigurationChoices(state: state, thinking: true)
        XCTAssertEqual(choices.choices.map(\.id), state.thinkingLevels)
        XCTAssertNil(choices.groups.first?.provider)
        XCTAssertEqual(choices.initialSelection, "medium")
        XCTAssertEqual(choices.choices.filter(\.current).map(\.action), [.thinking(level: "medium")])
        XCTAssertEqual(PiConfigurationChoices(state: state, thinking: true, query: "HIGH").initialSelection, "high")
    }

    func testSearchMatchesNameModelAndProviderAndHandlesEmptyResults() {
        let state = snapshot()
        func matching(_ query: String) -> PiConfigurationChoices { .init(state: state, thinking: false, query: query) }
        XCTAssertEqual(matching("SHARED").choices.map(\.id), ["second/one", "first/two"])
        XCTAssertEqual(matching("THREE").choices.map(\.id), ["second/three"])
        XCTAssertEqual(matching("FIRST").choices.map(\.id), ["first/two"])
        XCTAssertEqual(matching("FIRST/TWO").choices.map(\.id), ["first/two"])
        XCTAssertEqual(matching("second").initialSelection, "second/one")
        XCTAssertEqual(matching("  ").choices.count, 3)
        XCTAssertTrue(matching("no match").hasChoices)
        XCTAssertTrue(matching("no match").groups.isEmpty)
        XCTAssertNil(matching("no match").initialSelection)
        var empty = state
        empty.models = []; empty.thinkingLevels = []
        for thinking in [false, true] {
            let choices = PiConfigurationChoices(state: empty, thinking: thinking)
            XCTAssertFalse(choices.hasChoices)
            XCTAssertNil(choices.initialSelection)
        }
    }

    func testKeyboardNavigationFollowsGroupedRowsAndClampsAtBoundaries() {
        let choices = PiConfigurationChoices(state: snapshot(), thinking: false)
        XCTAssertEqual(choices.moved(from: "second/one", direction: .up), "second/one")
        XCTAssertEqual(choices.moved(from: "second/one", direction: .down), "second/three")
        XCTAssertEqual(choices.moved(from: "second/three", direction: .down), "first/two")
        XCTAssertEqual(choices.moved(from: "first/two", direction: .down), "first/two")
        XCTAssertEqual(choices.moved(from: "first/two", direction: .up), "second/three")
        XCTAssertEqual(choices.moved(from: "first/two", direction: .left), "first/two")
        let empty = PiConfigurationChoices(state: snapshot(), thinking: false, query: "missing")
        XCTAssertNil(empty.moved(from: nil, direction: .down))
    }

    func testBusyMissingSessionAndPendingApplyCannotDispatch() throws {
        var state = snapshot()
        var selection = PiConfigurationSelection()
        let choices = PiConfigurationChoices(state: state, thinking: false)
        selection.update(choices)
        state.phase = "working"
        XCTAssertNil(selection.begin(choices, state: state))
        state.phase = "idle"; state.selected = nil
        XCTAssertNil(selection.begin(choices, state: state))
        state.selected = choices.context.session
        let apply = try XCTUnwrap(selection.begin(choices, state: state))
        XCTAssertEqual(apply.choice.id, "first/two")
        XCTAssertTrue(selection.applying)
        XCTAssertNil(selection.begin(choices, state: state))
        XCTAssertTrue(selection.finish(apply, fault: nil))
        XCTAssertFalse(selection.applying)
    }

    func testSearchAndCatalogChangesRepairSelectionWithoutApplying() {
        var state = snapshot()
        var selection = PiConfigurationSelection()
        selection.update(.init(state: state, thinking: false))
        XCTAssertEqual(selection.selected, state.model)
        selection.update(.init(state: state, thinking: false, query: "second"))
        XCTAssertEqual(selection.selected, "second/one")
        selection.update(.init(state: state, thinking: false, query: "missing"))
        XCTAssertNil(selection.selected)
        selection.update(.init(state: state, thinking: false))
        state.models.removeAll { $0.id == state.model }
        let changed = PiConfigurationChoices(state: state, thinking: false)
        XCTAssertNil(selection.begin(changed, state: state), "An unreconciled catalog cannot apply an old selection.")
        selection.update(changed)
        XCTAssertEqual(selection.selected, "second/one")
        state.models = []
        selection.update(.init(state: state, thinking: false))
        XCTAssertNil(selection.selected)
        XCTAssertNil(selection.pending)
    }

    func testFailedApplyKeepsChoiceAndErrorAndAllowsExplicitRetry() throws {
        let state = snapshot()
        let choices = PiConfigurationChoices(state: state, thinking: true)
        var selection = PiConfigurationSelection()
        selection.update(choices)
        let apply = try XCTUnwrap(selection.begin(choices, state: state))
        XCTAssertFalse(selection.finish(apply, fault: .unavailable))
        XCTAssertEqual(selection.error, RemoteFault.unavailable.explanation)
        XCTAssertEqual(selection.selected, "medium")
        selection.update(.init(state: state, thinking: true, query: "high"))
        XCTAssertNotNil(selection.error, "Search must not hide an apply failure.")
        let retryChoices = PiConfigurationChoices(state: state, thinking: true, query: "high")
        XCTAssertNotNil(selection.begin(retryChoices, state: state))
        XCTAssertNil(selection.error)
    }

    func testOldCompletionCannotAffectNewContextModeOrPresentation() throws {
        for change in ["host", "epoch", "session", "mode", "disappear"] {
            var state = snapshot()
            var selection = PiConfigurationSelection()
            let choices = PiConfigurationChoices(state: state, thinking: false)
            selection.update(choices)
            let old = try XCTUnwrap(selection.begin(choices, state: state))
            if change == "disappear" { selection.invalidate() }
            else {
                if change == "host" { state.host = UUID() }
                if change == "epoch" { state.epoch = UUID() }
                if change == "session" { state.selected = UUID() }
                selection.update(.init(state: state, thinking: change == "mode"))
            }
            XCTAssertFalse(selection.finish(old, fault: .unavailable), change)
            XCTAssertFalse(selection.finish(old, fault: nil), change)
            XCTAssertNil(selection.error, change)
            XCTAssertFalse(selection.applying, change)
        }
    }

    func testOldCompletionDoesNotClearNewPendingApplyAndRemovedChoiceCannotClose() throws {
        var state = snapshot()
        var selection = PiConfigurationSelection()
        var choices = PiConfigurationChoices(state: state, thinking: false)
        selection.update(choices)
        let old = try XCTUnwrap(selection.begin(choices, state: state))
        state.selected = UUID()
        choices = .init(state: state, thinking: false)
        selection.update(choices)
        let new = try XCTUnwrap(selection.begin(choices, state: state))
        XCTAssertFalse(selection.finish(old, fault: .unavailable))
        XCTAssertEqual(selection.pending, new)
        state.models = []
        selection.update(.init(state: state, thinking: false))
        XCTAssertFalse(selection.finish(new, fault: nil))
        XCTAssertNil(selection.selected)
    }

    func testNativePresentationSearchAndKeyboardNeverDispatchUntilReturn() async throws {
        var requests: [SessionAction] = []
        var closes = 0
        try await hosted(state: snapshot(), request: { requests.append($0); return .ok }, done: { closes += 1 }) { controller, window in
            XCTAssertTrue(requests.isEmpty)
            try await self.key("\u{f700}", code: 126, controller: controller, window: window)
            try await self.key("\u{f701}", code: 125, controller: controller, window: window)
            XCTAssertTrue(requests.isEmpty)
            try await self.search("second", controller: controller, window: window)
            XCTAssertTrue(requests.isEmpty)
            try await self.key("\u{f701}", code: 125, controller: controller, window: window)
            XCTAssertTrue(requests.isEmpty)
            try await self.key("\r", code: 36, controller: controller, window: window)
            XCTAssertEqual(requests, [.model(provider: "second", id: "three")])
            XCTAssertEqual(closes, 1)
        }
    }

    func testNativeThinkingReturnUsesCurrentChoiceAndFailureDoesNotClose() async throws {
        var requests: [SessionAction] = []
        var closes = 0
        try await hosted(state: snapshot(), thinking: true, request: { requests.append($0); return .failure(.unavailable) }, done: { closes += 1 }) { controller, window in
            try await self.key("\r", code: 36, controller: controller, window: window)
            XCTAssertEqual(requests, [.thinking(level: "medium")])
            XCTAssertEqual(closes, 0)
            try await self.key("\r", code: 36, controller: controller, window: window)
            XCTAssertEqual(requests.count, 2, "Failure must allow an explicit retry.")
            XCTAssertEqual(closes, 0)
        }
    }

    func testNativeBusyMissingSessionAndNoMatchReturnDoNotDispatch() async throws {
        var state = snapshot()
        var requests: [SessionAction] = []
        let request: (SessionAction) async throws -> AppResult = { requests.append($0); return .ok }
        state.phase = "working"
        try await hosted(state: state, request: request) { controller, window in
            try await self.key("\r", code: 36, controller: controller, window: window)
            XCTAssertTrue(requests.isEmpty)
        }
        state.phase = "idle"; state.selected = nil
        try await hosted(state: state, request: request) { controller, window in
            try await self.key("\r", code: 36, controller: controller, window: window)
            XCTAssertTrue(requests.isEmpty)
        }
        state.selected = UUID()
        try await hosted(state: state, request: request) { controller, window in
            try await self.search("no match", controller: controller, window: window)
            try await self.key("\r", code: 36, controller: controller, window: window)
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testNativeInFlightCompletionCannotCloseChangedContext() async throws {
        var state = snapshot()
        var continuation: CheckedContinuation<AppResult, Never>?
        var requests: [SessionAction] = []
        var closes = 0
        let request: (SessionAction) async throws -> AppResult = { action in
            requests.append(action)
            return await withCheckedContinuation { continuation = $0 }
        }
        try await hosted(state: state, request: request, done: { closes += 1 }) { controller, window in
            try await self.key("\r", code: 36, controller: controller, window: window)
            XCTAssertEqual(requests.count, 1)
            let pending = try XCTUnwrap(continuation)
            state.selected = UUID()
            state.model = "second/one"
            controller.rootView = PiConfigurationPicker(state: state, thinking: false, request: request, done: { closes += 1 })
            try await self.settle(controller)
            pending.resume(returning: .ok)
            continuation = nil
            try await self.settle(controller)
            XCTAssertEqual(closes, 0)
            XCTAssertEqual(requests.count, 1)
        }
    }

    private func hosted(state: HostSnapshot, thinking: Bool = false,
                        request: @escaping (SessionAction) async throws -> AppResult, done: @escaping () -> Void = {},
                        exercise: (NSHostingController<PiConfigurationPicker>, NSWindow) async throws -> Void) async throws {
        let controller = NSHostingController(rootView: PiConfigurationPicker(state: state, thinking: thinking, request: request, done: done))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 580, height: 440))
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(controller)
        try await exercise(controller, window)
    }

    private func settle(_ controller: NSHostingController<PiConfigurationPicker>) async throws {
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutSubtreeIfNeeded()
    }

    private func searchField(_ controller: NSHostingController<PiConfigurationPicker>, window: NSWindow) throws -> NSTextView {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let field = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(field))
        return try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
    }

    private func search(_ query: String, controller: NSHostingController<PiConfigurationPicker>, window: NSWindow) async throws {
        let editor = try searchField(controller, window: window)
        editor.selectAll(nil)
        editor.insertText(query, replacementRange: editor.selectedRange())
        try await settle(controller)
    }

    private func key(_ text: String, code: UInt16, controller: NSHostingController<PiConfigurationPicker>, window: NSWindow) async throws {
        _ = try searchField(controller, window: window)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                                                 isARepeat: false, keyCode: code))
        // Send through the window so SwiftUI receives native key routing before the field editor.
        window.sendEvent(event)
        try await settle(controller)
    }
}
