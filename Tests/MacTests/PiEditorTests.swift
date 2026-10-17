import AppKit
import PiRemoteCore
import SwiftUI
import XCTest

final class PiEditorRoutingTests: XCTestCase {
    private func route(_ code: PiEditorKey.Code, _ modifiers: PiEditorKey.Modifiers = [],
                       _ state: PiEditorRouting.State = .init()) -> PiEditorRouting.Action {
        PiEditorRouting.action(for: PiEditorKey(code, modifiers: modifiers), state: state)
    }

    func testReturnDeliveryAndModifiedNewlines() {
        XCTAssertEqual(route(.enter), .submit(.prompt))
        var busy = PiEditorRouting.State()
        busy.isBusy = true
        XCTAssertEqual(route(.enter, [], busy), .submit(.steer))
        XCTAssertEqual(route(.enter, .option, busy), .submit(.followUp))
        XCTAssertEqual(route(.enter, .option), .submit(.prompt))
        for modifiers: PiEditorKey.Modifiers in [.shift, .control, [.shift, .option], [.control, .shift]] {
            XCTAssertEqual(route(.enter, modifiers), .newline)
        }
        XCTAssertEqual(route(.enter, .shift, busy), .newline)
        XCTAssertEqual(route(.enter, .control, busy), .newline)
        XCTAssertEqual(route(.letter("j"), .control), .newline)
        XCTAssertEqual(route(.enter, .command), .native)
    }

    func testCompletionPrecedesSubmissionHistoryAndStop() {
        var state = PiEditorRouting.State()
        state.hasCompletions = true
        state.browsingHistory = true
        XCTAssertEqual(route(.enter, [], state), .complete)
        XCTAssertEqual(route(.tab, [], state), .complete)
        XCTAssertEqual(route(.up, [], state), .suggestion(-1))
        XCTAssertEqual(route(.down, [], state), .suggestion(1))
        XCTAssertEqual(route(.escape, [], state), .dismissCompletion)
        XCTAssertEqual(route(.enter, .shift, state), .newline)
        XCTAssertEqual(route(.tab, .shift, state), .cycleThinking)
        XCTAssertEqual(route(.enter, .option, state), .submit(.prompt))
        state.isBusy = true
        XCTAssertEqual(route(.enter, .option, state), .submit(.followUp))
        state.hasCompletions = false
        XCTAssertEqual(route(.escape, [], state), .stop)
        XCTAssertEqual(route(.tab, [], state), .requestCompletion)
    }

    func testCompositionOwnsEveryActionKey() {
        var state = PiEditorRouting.State()
        state.isComposing = true
        state.isBusy = true
        state.hasCompletions = true
        for code: PiEditorKey.Code in [.enter, .tab, .up, .down, .escape, .letter("l"), .letter("o"), .letter("t")] {
            for modifiers: PiEditorKey.Modifiers in [[], .shift, .control, .option] {
                XCTAssertEqual(route(code, modifiers, state), .native)
            }
        }
    }

    func testDisabledAndEmptySubmissionsAreConsumedNotNewlines() {
        for empty in [false, true] {
            var state = PiEditorRouting.State()
            state.canSubmit = empty
            state.hasText = !empty
            XCTAssertEqual(route(.enter, [], state), .consume)
            state.isBusy = true
            XCTAssertEqual(route(.enter, .option, state), .consume)
            XCTAssertEqual(route(.enter, .shift, state), .newline)
            state.hasCompletions = true
            XCTAssertEqual(route(.enter, [], state), .complete)
        }
    }

    func testHistoryOnlyAtVisualBoundariesWithoutSelection() {
        var state = PiEditorRouting.State()
        state.firstVisualLine = false
        state.lastVisualLine = false
        XCTAssertEqual(route(.up, [], state), .native)
        XCTAssertEqual(route(.down, [], state), .native)
        state.firstVisualLine = true
        state.atStart = false
        XCTAssertEqual(route(.up, [], state), .lineStart)
        state.atStart = true
        XCTAssertEqual(route(.up, [], state), .history(-1))
        state.lastVisualLine = true
        XCTAssertEqual(route(.down, [], state), .lineEnd)
        state.browsingHistory = true
        state.atStart = false
        XCTAssertEqual(route(.up, [], state), .history(-1))
        XCTAssertEqual(route(.down, [], state), .history(1))
        state.hasSelection = true
        XCTAssertEqual(route(.up, [], state), .native)
        XCTAssertEqual(route(.down, [], state), .native)
        XCTAssertEqual(route(.up, .option, state), .recoverQueue)
    }

    func testApplicationShortcutsAndNativeEditing() {
        XCTAssertEqual(route(.letter("l"), .control), .selectModel)
        XCTAssertEqual(route(.letter("p"), .control), .cycleModel(1))
        XCTAssertEqual(route(.letter("p"), [.control, .shift]), .cycleModel(-1))
        XCTAssertEqual(route(.letter("o"), .control), .toggleTools)
        XCTAssertEqual(route(.letter("t"), .control), .toggleThinking)
        XCTAssertEqual(route(.tab, .shift), .cycleThinking)
        for code: PiEditorKey.Code in [.letter("a"), .letter("c"), .letter("v"), .letter("x"), .letter("z")] {
            XCTAssertEqual(route(code, .command), .native)
        }
        XCTAssertEqual(route(.letter("a"), .control), .native)
        XCTAssertEqual(route(.letter("l"), [.control, .option]), .native)
    }
}

final class PiEditorHistoryTests: XCTestCase {
    func testBrowseRestoresExactMultilineDraftAndSelection() throws {
        var history = PiEditorHistory()
        let draft = PiEditorInput(text: "draft\n日本語 🐈", selection: NSRange(location: 2, length: 0), contextID: "session")
        let entries = ["old", "", "  ", "new\nline"]
        var current = try XCTUnwrap(history.move(-1, current: draft, history: entries))
        XCTAssertEqual(current.text, "new\nline")
        XCTAssertEqual(current.selection.location, 0)
        current = try XCTUnwrap(history.move(-1, current: current, history: entries))
        XCTAssertEqual(current.text, "old")
        XCTAssertNil(history.move(-1, current: current, history: entries))
        current = try XCTUnwrap(history.move(1, current: current, history: entries))
        XCTAssertEqual(current.text, "new\nline")
        XCTAssertEqual(current.selection.location, current.text.utf16.count)
        XCTAssertEqual(history.move(1, current: current, history: entries), draft)
        XCTAssertFalse(history.isBrowsing)
        XCTAssertNil(history.move(1, current: draft, history: entries))
    }

    func testNoHistoryResetAndChangingParentEntries() {
        var history = PiEditorHistory()
        let draft = PiEditorInput(text: "draft", selection: NSRange(location: 0, length: 0), contextID: "a")
        XCTAssertNil(history.move(-1, current: draft, history: []))
        XCTAssertFalse(history.isBrowsing)
        XCTAssertEqual(history.move(-1, current: draft, history: ["a", "b"])?.text, "b")
        XCTAssertEqual(history.move(-1, current: draft, history: ["different"])?.text, "a")
        history.reset()
        XCTAssertFalse(history.isBrowsing)
        XCTAssertNil(history.move(1, current: draft, history: ["a"]))
        XCTAssertEqual(history.move(-1, current: draft, history: ["different"])?.text, "different")
    }
}

final class PiEditorCompletionTests: XCTestCase {
    func testResultsRequireExactContextRevisionTextAndCaret() {
        let input = PiEditorInput(text: "/mo", selection: NSRange(location: 3, length: 0), contextID: "a", revision: 7)
        let batch = PiEditorCompletions(input: input, replacementRange: NSRange(location: 0, length: 3),
                                       options: [.init(id: "model", label: "/model", replacement: "/model ")])
        XCTAssertTrue(batch.matches(input))
        var changed = input
        changed.contextID = "b"
        XCTAssertFalse(batch.matches(changed))
        changed = input; changed.revision += 1
        XCTAssertFalse(batch.matches(changed))
        changed = input; changed.text = "/my"
        XCTAssertFalse(batch.matches(changed))
        changed = input; changed.selection.location = 2
        XCTAssertFalse(batch.matches(changed))
        changed = input; changed.selection.length = 1
        XCTAssertFalse(batch.matches(changed))
    }

    func testUTF16RangesNoMatchesAndInvalidRanges() {
        let input = PiEditorInput(text: "🐈 ./日本語", selection: NSRange(location: 8, length: 0), contextID: "a")
        let option = PiEditorCompletions.Option(id: "path", label: "日本語 file", detail: "directory", replacement: "\"日本語 file\"/")
        var batch = PiEditorCompletions(input: input, replacementRange: NSRange(location: 3, length: 5), options: [option])
        XCTAssertTrue(batch.matches(input))
        batch.replacementRange = NSRange(location: 1, length: 1) // Inside the surrogate pair.
        XCTAssertFalse(batch.matches(input))
        batch.replacementRange = NSRange(location: NSNotFound, length: 0)
        XCTAssertFalse(batch.matches(input))
        batch.replacementRange = NSRange(location: 0, length: 100)
        XCTAssertFalse(batch.matches(input))
        batch.options = []
        XCTAssertFalse(batch.matches(input))
    }

    func testSelectionUsesStableIDsAndWraps() {
        let a = PiEditorCompletions.Option(id: "a", label: "same", replacement: "a")
        let b = PiEditorCompletions.Option(id: "b", label: "same", replacement: "b")
        var selection = PiEditorSuggestionSelection()
        selection.update(options: [a, b])
        XCTAssertEqual(selection.id, "a")
        selection.move(-1, options: [a, b])
        XCTAssertEqual(selection.id, "b")
        selection.update(options: [b, a])
        XCTAssertEqual(selection.id, "b")
        selection.move(1, options: [b, a])
        XCTAssertEqual(selection.id, "a")
        selection.update(options: [b])
        XCTAssertEqual(selection.id, "b")
        selection.move(1, options: [])
        XCTAssertNil(selection.id)
    }
}

@MainActor final class PiEditorNativeTests: XCTestCase {
    private final class Draft {
        var text: String
        var deliveries: [Delivery] = []
        var stops = 0
        var completed: [String] = []
        var models: [Int] = []
        var tools = 0
        var thinking = 0
        var thinkingCycles = 0
        init(_ text: String) { self.text = text }
    }

    private func fixture(_ draft: Draft) -> (PiEditor, PiEditor.Coordinator, PiEditorNativeView, NSWindow) {
        _ = NSApplication.shared
        let parent = PiEditor(text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                              onSubmit: { draft.deliveries.append($0) }, onStop: { draft.stops += 1 },
                              onCompletion: { draft.completed.append($0.id) },
                              onCycleModel: { draft.models.append($0) },
                              onToggleTools: { draft.tools += 1 }, onToggleThinking: { draft.thinking += 1 },
                              onCycleThinking: { draft.thinkingCycles += 1 })
        let coordinator = PiEditor.Coordinator(parent)
        let view = PiEditorNativeView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        coordinator.attach(view)
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view.editor)
        return (parent, coordinator, view, window)
    }

    func testSubmitKeepsDraftUntilParentAcknowledgesAndNewlineIsUndoable() {
        let draft = Draft("keep this")
        let (_, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        XCTAssertTrue(coordinator.handle(PiEditorKey(.enter)))
        XCTAssertEqual(draft.deliveries, [.prompt])
        XCTAssertEqual(draft.text, "keep this")
        XCTAssertEqual(view.editor.string, "keep this")
        XCTAssertTrue(coordinator.handle(PiEditorKey(.enter, modifiers: .shift)))
        XCTAssertEqual(draft.text, "keep this\n")
        view.editor.undoManager?.undo()
        XCTAssertEqual(draft.text, "keep this")
    }

    func testCompletionOnlyReturnTabMouseAndUndo() throws {
        for trigger in [PiEditorKey.Code.enter, .tab] {
            let draft = Draft("/mo")
            var (parent, coordinator, view, window) = fixture(draft)
            defer { window.close() }
            parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 3),
                                                     options: [.init(id: "model", label: "/model", replacement: "/model ")])
            coordinator.update(parent)
            XCTAssertTrue(coordinator.handle(PiEditorKey(trigger)))
            XCTAssertEqual(draft.text, "/model ")
            XCTAssertEqual(draft.completed, ["model"])
            XCTAssertTrue(draft.deliveries.isEmpty)
            view.editor.undoManager?.undo()
            XCTAssertEqual(draft.text, "/mo")
        }
        let draft = Draft("./日本語")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 5),
                                                 options: [.init(id: "path", label: "日本語 file", detail: "directory", replacement: "\"日本語 file\"/")])
        coordinator.update(parent)
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
        }
        let button = try XCTUnwrap(buttons(view).first)
        button.performClick(nil)
        XCTAssertEqual(draft.text, "\"日本語 file\"/")
        XCTAssertTrue(draft.deliveries.isEmpty)
        XCTAssertTrue(window.firstResponder === view.editor)
    }

    func testEscapeDismissesBeforeStopAndLateResultsStayDismissed() {
        let draft = Draft("/m")
        var (parent, coordinator, _, window) = fixture(draft)
        defer { window.close() }
        parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 2),
                                                 options: [.init(id: "model", label: "/model", replacement: "/model ")])
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.escape)))
        XCTAssertEqual(draft.stops, 0)
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.escape)))
        XCTAssertEqual(draft.stops, 1)
        XCTAssertEqual(draft.text, "/m")
    }

    func testNativeIMEBlocksCompletionSubmitAndShortcuts() {
        let draft = Draft("")
        let (_, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        view.editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.editor.hasMarkedText())
        for key in [PiEditorKey(.enter), PiEditorKey(.escape), PiEditorKey(.tab), PiEditorKey(.letter("o"), modifiers: .control)] {
            XCTAssertFalse(coordinator.handle(key))
        }
        XCTAssertTrue(draft.deliveries.isEmpty)
        XCTAssertEqual(draft.stops, 0)
        XCTAssertEqual(draft.tools, 0)
        view.editor.unmarkText()
        view.editor.insertText("日本", replacementRange: NSRange(location: 0, length: view.editor.string.utf16.count))
        XCTAssertTrue(coordinator.handle(PiEditorKey(.enter)))
        XCTAssertEqual(draft.deliveries, [.prompt])
    }

    func testUnchangedUpdatePreservesSelectionUndoAndComposition() {
        let draft = Draft("hello")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        view.editor.setSelectedRange(NSRange(location: 1, length: 3))
        coordinator.update(parent)
        XCTAssertEqual(view.editor.selectedRange(), NSRange(location: 1, length: 3))
        view.editor.insertText("🐈\n日本語", replacementRange: view.editor.selectedRange())
        let inserted = draft.text
        coordinator.update(parent)
        XCTAssertEqual(view.editor.string, inserted)
        view.editor.undoManager?.undo()
        XCTAssertEqual(view.editor.string, "hello")
        XCTAssertEqual(draft.text, "hello")
        view.editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: view.editor.selectedRange())
        coordinator.update(parent)
        XCTAssertTrue(view.editor.hasMarkedText())
        parent.contextID = "other"
        draft.text = "new session"
        coordinator.update(parent)
        XCTAssertFalse(view.editor.hasMarkedText())
        XCTAssertEqual(view.editor.string, "new session")
        XCTAssertFalse(view.editor.undoManager?.canUndo ?? true)
    }

    func testNativeHistoryBoundariesDraftRecoveryAndEditReset() {
        let draft = Draft("draft")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        parent.history = ["old", "new"]
        coordinator.update(parent)
        view.editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(coordinator.handle(PiEditorKey(.up)))
        XCTAssertEqual(draft.text, "new")
        XCTAssertTrue(coordinator.handle(PiEditorKey(.up)))
        XCTAssertEqual(draft.text, "old")
        XCTAssertTrue(coordinator.handle(PiEditorKey(.down)))
        XCTAssertEqual(draft.text, "new")
        XCTAssertTrue(coordinator.handle(PiEditorKey(.down)))
        XCTAssertEqual(draft.text, "draft")
        XCTAssertEqual(view.editor.selectedRange().location, 0)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.up)))
        view.editor.insertText(" edited", replacementRange: NSRange(location: view.editor.string.utf16.count, length: 0))
        XCTAssertTrue(coordinator.handle(PiEditorKey(.down)))
        XCTAssertEqual(draft.text, "new edited")
    }

    func testNativeScrollHeightIsBounded() throws {
        let draft = Draft("prompt")
        let (_, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        window.setContentSize(NSSize(width: 300, height: 240))
        view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(view.editor.enclosingScrollView)
        XCTAssertLessThanOrEqual(scroll.frame.height, 180)
        XCTAssertGreaterThanOrEqual(scroll.frame.height, 48)
        withExtendedLifetime(coordinator) {}
    }

    func testVisualWrappingAndEmptyFinalLineAreNotHistoryBoundaries() {
        let draft = Draft(String(repeating: "word ", count: 100))
        let (_, _, view, window) = fixture(draft)
        defer { window.close() }
        view.editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(view.editor.visualLineBoundaries().first)
        XCTAssertFalse(view.editor.visualLineBoundaries().last)
        view.editor.setSelectedRange(NSRange(location: draft.text.utf16.count, length: 0))
        XCTAssertFalse(view.editor.visualLineBoundaries().first)
        XCTAssertTrue(view.editor.visualLineBoundaries().last)
        view.editor.insertText("\n", replacementRange: view.editor.selectedRange())
        XCTAssertFalse(view.editor.visualLineBoundaries().first)
        XCTAssertTrue(view.editor.visualLineBoundaries().last)
    }

    func testBusyAltReturnHasApplicationPriorityAndQueueRecoveryIsOptional() {
        let draft = Draft("/m")
        var (parent, coordinator, _, window) = fixture(draft)
        defer { window.close() }
        parent.isBusy = true
        parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 2),
                                                 options: [.init(id: "model", label: "/model", replacement: "/model ")])
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.enter, modifiers: .option)))
        XCTAssertEqual(draft.deliveries, [.followUp])
        XCTAssertTrue(draft.completed.isEmpty)
        XCTAssertEqual(draft.text, "/m")
        parent.isBusy = false
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.enter, modifiers: .option)))
        XCTAssertEqual(draft.deliveries, [.followUp, .prompt])
        XCTAssertFalse(coordinator.handle(PiEditorKey(.up, modifiers: .option)))
        var recoveries: [Bool] = []
        parent.onRecoverQueue = { recoveries.append($0) }
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.up, modifiers: .option)))
        XCTAssertEqual(recoveries, [false])
    }

    func testStaleCompletionAfterCaretRoundTripAndSessionChange() {
        let draft = Draft("/m")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 2),
                                                 options: [.init(id: "model", label: "/model", replacement: "/model ")])
        view.editor.setSelectedRange(NSRange(location: 0, length: 0))
        view.editor.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.enter)))
        XCTAssertTrue(draft.completed.isEmpty)
        XCTAssertEqual(draft.deliveries, [.prompt])
        parent.contextID = "other session"
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.enter)))
        XCTAssertTrue(draft.completed.isEmpty)
        XCTAssertEqual(draft.text, "/m")
    }

    func testCompletionRequestsUseLatestSnapshotAndExplicitTab() async {
        let draft = Draft("a")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        var requests: [(PiEditorInput, Bool)] = []
        parent.onCompletionRequest = { requests.append(($0, $1)) }
        coordinator.update(parent)
        for _ in 0..<100 where requests.isEmpty { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, coordinator.input)
        XCTAssertEqual(requests.first?.1, false)
        requests.removeAll()
        view.editor.insertText("b", replacementRange: view.editor.selectedRange())
        view.editor.insertText("c", replacementRange: view.editor.selectedRange())
        XCTAssertTrue(coordinator.handle(PiEditorKey(.tab)))
        for _ in 0..<100 where requests.isEmpty { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, coordinator.input)
        XCTAssertEqual(requests.first?.0.text, "abc")
        XCTAssertEqual(requests.first?.1, true)
    }

    func testNativeKeyEventsUseLocalRoutingAndUndo() throws {
        let draft = Draft("prompt")
        let (_, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        // The coordinator normally lives in SwiftUI. Keep it alive for the event callbacks.
        func enter(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        }
        view.editor.keyDown(with: try enter([]))
        XCTAssertEqual(draft.deliveries, [.prompt])
        view.editor.keyDown(with: try enter(.shift))
        XCTAssertEqual(draft.text, "prompt\n")
        view.editor.undoManager?.undo()
        XCTAssertEqual(draft.text, "prompt")
        withExtendedLifetime(coordinator) {}
    }

    func testNativeShortcutsCallClosuresAndCommandEditingIsNotIntercepted() {
        let draft = Draft("text")
        let (_, coordinator, _, window) = fixture(draft)
        defer { window.close() }
        XCTAssertTrue(coordinator.handle(PiEditorKey(.letter("p"), modifiers: .control)))
        XCTAssertTrue(coordinator.handle(PiEditorKey(.letter("p"), modifiers: [.control, .shift])))
        XCTAssertTrue(coordinator.handle(PiEditorKey(.letter("o"), modifiers: .control)))
        XCTAssertTrue(coordinator.handle(PiEditorKey(.letter("t"), modifiers: .control)))
        XCTAssertTrue(coordinator.handle(PiEditorKey(.tab, modifiers: .shift)))
        XCTAssertEqual(draft.models, [1, -1])
        XCTAssertEqual(draft.tools, 1)
        XCTAssertEqual(draft.thinking, 1)
        XCTAssertEqual(draft.thinkingCycles, 1)
        for letter in ["a", "c", "v", "x", "z"] {
            XCTAssertFalse(coordinator.handle(PiEditorKey(.letter(letter), modifiers: .command)))
        }
    }
}
