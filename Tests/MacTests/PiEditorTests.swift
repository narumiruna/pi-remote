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
        var bindingWrites = 0
        var completionRequests: [PiEditorInput] = []
        var dismissals = 0
        init(_ text: String) { self.text = text }
    }

    private func fixture(_ draft: Draft) -> (PiEditor, PiEditor.Coordinator, PiEditorNativeView, NSWindow) {
        _ = NSApplication.shared
        let parent = PiEditor(text: Binding(get: { draft.text }, set: { draft.text = $0; draft.bindingWrites += 1 }),
                              onSubmit: { draft.deliveries.append($0) }, onStop: { draft.stops += 1 },
                              onCompletion: { draft.completed.append($0.id) },
                              onCompletionRequest: { input, _ in draft.completionRequests.append(input) },
                              onDismissCompletion: { draft.dismissals += 1 },
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

    func testUndoAndRedoAfterRunLoopSynchronizeDraftAndInput() async throws {
        let draft = Draft("Unsent 文 draft")
        let (_, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        let original = draft.text
        let undo = try XCTUnwrap(view.editor.undoManager)
        view.editor.insertText(" added", replacementRange: view.editor.selectedRange())
        view.editor.breakUndoCoalescing()
        let edited = draft.text
        // Let AppKit close the event's undo group, as it does between real keystrokes.
        try await Task.sleep(for: .milliseconds(20))
        view.editor.setSelectedRange(NSRange(location: 7, length: 1))
        let beforeUndo = coordinator.input
        undo.undo()
        XCTAssertEqual(view.editor.string, original)
        XCTAssertEqual(draft.text, original)
        XCTAssertEqual(coordinator.input.text, original)
        XCTAssertEqual(coordinator.input.selection, view.editor.selectedRange())
        XCTAssertGreaterThan(coordinator.input.revision, beforeUndo.revision)
        let afterUndo = coordinator.input
        undo.redo()
        XCTAssertEqual(view.editor.string, edited)
        XCTAssertEqual(draft.text, edited)
        XCTAssertEqual(coordinator.input.text, edited)
        XCTAssertEqual(coordinator.input.selection, view.editor.selectedRange())
        XCTAssertGreaterThan(coordinator.input.revision, afterUndo.revision)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(draft.completionRequests.last, coordinator.input)
        XCTAssertTrue(draft.deliveries.isEmpty)
        XCTAssertEqual(draft.stops, 0)
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

    func testEmptyAndSingleLineUseCompactNativeHeight() throws {
        let draft = Draft("")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        let empty = view.fittingSize(for: 300)
        XCTAssertEqual(empty.height, 35) // 34-point input and its bottom rule.
        draft.text = "one line"
        coordinator.update(parent)
        XCTAssertEqual(view.fittingSize(for: 300), empty)
        window.setContentSize(view.fittingSize(for: 300))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(view.editor.enclosingScrollView).frame.height, 34)
        parent.isBusy = true
        coordinator.update(parent)
        XCTAssertEqual(view.intrinsicContentSize.height, empty.height)
    }

    func testMultilineWrappedAndTrailingNewlineGrowToNativeCap() throws {
        let draft = Draft("line")
        let (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        let oneLine = view.fittingSize(for: 300).height
        draft.text = "line\n"
        coordinator.update(parent)
        let twoLines = view.fittingSize(for: 300).height
        XCTAssertGreaterThan(twoLines, oneLine)
        draft.text = "line\nline\nline"
        coordinator.update(parent)
        XCTAssertGreaterThan(view.fittingSize(for: 300).height, twoLines)
        draft.text = String(repeating: "word ", count: 30)
        coordinator.update(parent)
        let wide = view.fittingSize(for: 600).height
        let narrow = view.fittingSize(for: 200).height
        XCTAssertGreaterThan(narrow, wide)
        draft.text = String(repeating: "line\n", count: 100)
        coordinator.update(parent)
        XCTAssertEqual(view.fittingSize(for: 300).height, 181)
        window.setContentSize(view.fittingSize(for: 300))
        view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(view.editor.enclosingScrollView)
        XCTAssertEqual(scroll.frame.height, 180)
        XCTAssertGreaterThan(view.editor.frame.height, scroll.contentSize.height)
        draft.text = ""
        coordinator.update(parent)
        XCTAssertEqual(view.fittingSize(for: 300).height, 35)
    }

    func testMeasurementPreservesSelectionCompositionUndoAndScrollPosition() throws {
        let draft = Draft(String(repeating: "line\n", count: 50))
        let (_, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        view.editor.setSelectedRange(NSRange(location: 2, length: 0))
        view.editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                                  replacementRange: view.editor.selectedRange())
        let input = coordinator.input
        let selection = view.editor.selectedRange()
        let clip = try XCTUnwrap(view.editor.enclosingScrollView?.contentView)
        let origin = clip.bounds.origin
        let canUndo = view.editor.undoManager?.canUndo
        for width: CGFloat in [100, 600, 300, 120] { _ = view.fittingSize(for: width) }
        XCTAssertEqual(coordinator.input, input)
        XCTAssertEqual(view.editor.selectedRange(), selection)
        XCTAssertTrue(view.editor.hasMarkedText())
        XCTAssertEqual(view.editor.undoManager?.canUndo, canUndo)
        XCTAssertEqual(clip.bounds.origin, origin)
    }

    func testTextCaretAndTypingColorsRemainVisibleOnDarkSurface() throws {
        let draft = Draft("prompt")
        let (_, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        XCTAssertEqual(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(view.editor.font, .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertFalse(view.bottomRule.isHidden)
        for color in [view.editor.textColor, view.editor.insertionPointColor,
                      view.editor.typingAttributes[.foregroundColor] as? NSColor] {
            let rgb = try XCTUnwrap(color?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(rgb.redComponent, 0.8)
            XCTAssertGreaterThan(rgb.greenComponent, 0.8)
            XCTAssertGreaterThan(rgb.blueComponent, 0.8)
            XCTAssertEqual(rgb.alphaComponent, 1)
        }
        withExtendedLifetime(coordinator) {}
    }

    func testModeChangesPreserveMarkedAttributesSelectionUndoFocusAndScroll() async throws {
        let draft = Draft(String(repeating: "line 🐈\n", count: 50))
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        let native = view
        let editor = view.editor
        let undo = try XCTUnwrap(editor.undoManager)
        editor.breakUndoCoalescing()
        editor.insertText("undoable", replacementRange: NSRange(location: 2, length: 0))
        editor.breakUndoCoalescing()
        let marked = NSAttributedString(string: "かな🐈", attributes: [
            .underlineStyle: NSUnderlineStyle.double.rawValue,
            .foregroundColor: NSColor.systemPink,
            NSAttributedString.Key("fixture-marked-attribute"): "preserve"
        ])
        editor.setMarkedText(marked, selectedRange: NSRange(location: 2, length: 2),
                             replacementRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let markedRange = editor.markedRange()
        let markedSnapshot = try XCTUnwrap(editor.textStorage?.attributedSubstring(from: markedRange))
        let text = editor.string
        let selected = editor.selectedRange()
        XCTAssertEqual(selected, NSRange(location: 4, length: 2))
        let input = coordinator.input
        let clip = try XCTUnwrap(editor.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 25))
        let origin = clip.bounds.origin
        let canUndo = undo.canUndo
        XCTAssertTrue(canUndo)
        for _ in 0..<10 { await Task.yield() }
        let writes = draft.bindingWrites
        let requests = draft.completionRequests
        var otherCallbacks = 0
        parent.onSelectModel = { otherCallbacks += 1 }
        parent.onRecoverQueue = { _ in otherCallbacks += 1 }

        for mode: MacInterfaceMode in [.desktop, .pi, .desktop, .pi] {
            parent.interfaceMode = mode
            coordinator.update(parent)
            XCTAssertTrue(coordinator.view === native)
            XCTAssertTrue(view.editor === editor)
            XCTAssertTrue(editor.delegate === coordinator)
            XCTAssertTrue(editor.undoManager === undo)
            XCTAssertEqual(undo.canUndo, canUndo)
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(editor.markedRange(), markedRange)
            XCTAssertEqual(editor.textStorage?.attributedSubstring(from: markedRange), markedSnapshot)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange(), selected)
            XCTAssertEqual(coordinator.input, input)
            XCTAssertEqual(clip.bounds.origin, origin)
            XCTAssertTrue(window.firstResponder === editor)
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(draft.bindingWrites, writes)
        XCTAssertEqual(draft.completionRequests, requests)
        XCTAssertTrue(draft.deliveries.isEmpty)
        XCTAssertEqual(draft.stops, 0)
        XCTAssertTrue(draft.completed.isEmpty)
        XCTAssertEqual(draft.dismissals, 0)
        XCTAssertTrue(draft.models.isEmpty)
        XCTAssertEqual(draft.tools + draft.thinking + draft.thinkingCycles + otherCallbacks, 0)
        editor.unmarkText()
        editor.breakUndoCoalescing()
        undo.undo()
        XCTAssertNotEqual(editor.string, text)
        undo.redo()
        XCTAssertEqual(editor.string, text)
    }

    func testModeChangesPreserveNativeUndoAndUTF16Selection() throws {
        let draft = Draft("draft 🐈 日本語")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        let original = draft.text
        view.editor.insertText("edit", replacementRange: NSRange(location: 0, length: 0))
        view.editor.breakUndoCoalescing()
        let edited = draft.text
        let selected = NSRange(location: 10, length: 2) // The cat's UTF-16 surrogate pair.
        view.editor.setSelectedRange(selected)
        let input = coordinator.input
        let undo = try XCTUnwrap(view.editor.undoManager)
        for mode: MacInterfaceMode in [.desktop, .pi, .desktop] {
            parent.interfaceMode = mode
            coordinator.update(parent)
            XCTAssertEqual(view.editor.string, edited)
            XCTAssertEqual(view.editor.selectedRange(), selected)
            XCTAssertEqual(coordinator.input, input)
            XCTAssertTrue(view.editor.undoManager === undo)
        }
        undo.undo()
        XCTAssertEqual(view.editor.string, original)
        XCTAssertEqual(draft.text, original)
        undo.redo()
        XCTAssertEqual(view.editor.string, edited)
    }

    func testDesktopInheritsAppearanceAndUsesDynamicNativeTextAndSelectionColors() throws {
        let draft = Draft("first\nsecond\nthird")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        let piHeight = view.fittingSize(for: 300).height
        parent.interfaceMode = .desktop
        parent.separatorColor = .systemPurple
        coordinator.update(parent)
        XCTAssertNil(view.appearance)
        XCTAssertEqual(view.editor.font, .systemFont(ofSize: 14))
        XCTAssertTrue(view.bottomRule.isHidden)
        XCTAssertNotEqual(view.fittingSize(for: 300).height, piHeight)
        var labels: [NSColor] = []
        var selections: [NSColor] = []
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            window.appearance = try XCTUnwrap(NSAppearance(named: name))
            coordinator.update(parent)
            XCTAssertNil(view.appearance)
            XCTAssertEqual(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
            XCTAssertEqual(view.editor.textColor, .labelColor)
            XCTAssertEqual(view.editor.insertionPointColor, .labelColor)
            XCTAssertEqual(view.editor.typingAttributes[.foregroundColor] as? NSColor, .labelColor)
            XCTAssertEqual(view.editor.selectedTextAttributes[.foregroundColor] as? NSColor, .selectedTextColor)
            XCTAssertEqual(view.editor.selectedTextAttributes[.backgroundColor] as? NSColor, .selectedTextBackgroundColor)
            var label: NSColor?
            var selection: NSColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                label = view.editor.textColor?.usingColorSpace(.deviceRGB)
                selection = (view.editor.selectedTextAttributes[.backgroundColor] as? NSColor)?.usingColorSpace(.deviceRGB)
            }
            labels.append(try XCTUnwrap(label))
            selections.append(try XCTUnwrap(selection))
        }
        XCTAssertNotEqual(labels[0], labels[1])
        XCTAssertNotEqual(selections[0], selections[1])
        parent.interfaceMode = .pi
        coordinator.update(parent)
        XCTAssertEqual(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(view.editor.font, .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertEqual(view.fittingSize(for: 300).height, piHeight)
        XCTAssertFalse(view.bottomRule.isHidden)
        XCTAssertEqual(view.bottomRule.layer?.backgroundColor, NSColor.systemPurple.cgColor)
    }

    func testModeChangesKeepExactCompletionSnapshotSelectionAndDismissal() throws {
        let draft = Draft("/m")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 2),
            options: [.init(id: "model", label: "/model", replacement: "/model "),
                      .init(id: "menu", label: "/menu", replacement: "/menu ")])
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.down)))
        let input = coordinator.input
        for mode: MacInterfaceMode in [.desktop, .pi, .desktop] {
            parent.interfaceMode = mode
            coordinator.update(parent)
            XCTAssertEqual(coordinator.input, input)
            XCTAssertEqual(view.editor.string, "/m")
        }
        XCTAssertTrue(coordinator.handle(PiEditorKey(.tab)))
        XCTAssertEqual(draft.text, "/menu ")
        XCTAssertEqual(draft.completed, ["menu"])
        try XCTUnwrap(view.editor.undoManager).undo()
        XCTAssertEqual(view.editor.string, "/m")
        XCTAssertEqual(draft.text, "/m")
        XCTAssertEqual(view.editor.selectedRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual(coordinator.input.selection, view.editor.selectedRange())
        XCTAssertFalse(try XCTUnwrap(parent.completions).matches(coordinator.input))
        // Native undo selects the restored text. Completion requires a caret and a fresh batch.
        view.editor.setSelectedRange(NSRange(location: 2, length: 0))
        parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 2),
                                                options: try XCTUnwrap(parent.completions).options)
        XCTAssertTrue(try XCTUnwrap(parent.completions).matches(coordinator.input))
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.escape)))
        XCTAssertEqual(draft.stops, 0)
        parent.interfaceMode = .pi
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.escape)))
        XCTAssertEqual(draft.stops, 1)
        XCTAssertTrue(draft.deliveries.isEmpty)
        XCTAssertEqual(draft.completed, ["menu"])
        XCTAssertEqual(draft.text, "/m")
    }

    func testModeChangesKeepHistoryBrowsingAndExactDraftRecovery() {
        let draft = Draft("draft\n🐈 日本語")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        parent.history = ["old", "new"]
        coordinator.update(parent)
        view.editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(coordinator.handle(PiEditorKey(.up)))
        parent.interfaceMode = .desktop
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.up)))
        XCTAssertEqual(draft.text, "old")
        parent.interfaceMode = .pi
        coordinator.update(parent)
        XCTAssertTrue(coordinator.handle(PiEditorKey(.down)))
        XCTAssertEqual(draft.text, "new")
        XCTAssertTrue(coordinator.handle(PiEditorKey(.down)))
        XCTAssertEqual(draft.text, "draft\n🐈 日本語")
        XCTAssertEqual(view.editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testCompletionsAreBelowBottomRuleAndAddOnlyTheirOwnHeight() throws {
        let draft = Draft("/m")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        let plainHeight = view.fittingSize(for: 300).height
        parent.separatorColor = .systemPurple
        parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 2),
                                                 options: (0..<8).map { .init(id: "\($0)", label: "/model \($0)", replacement: "/model ") })
        coordinator.update(parent)
        XCTAssertEqual(view.fittingSize(for: 300).height, plainHeight + 140)
        window.setContentSize(view.fittingSize(for: 300))
        view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(view.editor.enclosingScrollView)
        XCTAssertEqual(view.bottomRule.frame.minY, scroll.frame.maxY)
        XCTAssertEqual(view.bottomRule.frame.height, 1)
        XCTAssertEqual(view.bottomRule.layer?.backgroundColor, NSColor.systemPurple.cgColor)
        let suggestions = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first { $0 !== scroll })
        XCTAssertEqual(suggestions.frame.minY, view.bottomRule.frame.maxY)
        XCTAssertEqual(suggestions.frame.height, 140)
        let buttons = try XCTUnwrap(suggestions.documentView).subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 8)
        XCTAssertEqual(buttons.first?.frame.minY, 0)
        XCTAssertEqual(buttons.last?.frame.maxY, 224)
        let origin = suggestions.contentView.bounds.origin
        coordinator.update(parent)
        XCTAssertEqual(suggestions.contentView.bounds.origin, origin)
        XCTAssertEqual(scroll.frame.height, 34)
    }

    func testSwiftUIUsesMeasuredHeightWithoutFixedEditorFrame() {
        let draft = Draft("")
        func content(width: CGFloat) -> some View {
            PiEditor(text: .constant(draft.text), onSubmit: { _ in }, onStop: {}).frame(width: width)
        }
        let hosting = NSHostingView(rootView: content(width: 300))
        XCTAssertEqual(hosting.fittingSize.height, 35)
        draft.text = String(repeating: "line\n", count: 50)
        hosting.rootView = content(width: 300)
        XCTAssertEqual(hosting.fittingSize.height, 181)
        draft.text = String(repeating: "word ", count: 30)
        hosting.rootView = content(width: 600)
        let wide = hosting.fittingSize.height
        hosting.rootView = content(width: 200)
        XCTAssertGreaterThan(hosting.fittingSize.height, wide)
        draft.text = ""
        hosting.rootView = content(width: 300)
        XCTAssertEqual(hosting.fittingSize.height, 35)
    }

    private struct SizingFixture: View {
        @State private var text = ""
        var body: some View {
            PiEditor(text: $text, onSubmit: { _ in }, onStop: {})
        }
    }

    func testSwiftUIHeightUpdatesAfterNativeTypingAndUndo() async throws {
        let hosting = NSHostingView(rootView: SizingFixture().frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.height, 35)
        func nativeView(in view: NSView) -> PiEditorNativeView? {
            (view as? PiEditorNativeView) ?? view.subviews.lazy.compactMap { nativeView(in: $0) }.first
        }
        let native = try XCTUnwrap(nativeView(in: hosting))
        for _ in 0..<100 where window.firstResponder !== native.editor { await Task.yield() }
        XCTAssertTrue(window.firstResponder === native.editor)
        native.editor.insertText("first\nsecond\nthird", replacementRange: NSRange(location: 0, length: 0))
        for _ in 0..<100 where hosting.fittingSize.height == 35 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(hosting.fittingSize.height, 35)
        native.editor.undoManager?.undo()
        for _ in 0..<100 where hosting.fittingSize.height != 35 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(hosting.fittingSize.height, 35)
    }

    func testCompletionNavigationDoesNotScrollOuterConversation() throws {
        let draft = Draft("/m")
        var (parent, coordinator, view, window) = fixture(draft)
        defer { window.close() }
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        outer.documentView = document
        window.contentView = outer
        document.addSubview(view)
        view.frame = NSRect(x: 0, y: 600, width: 300, height: 175)
        outer.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let origin = outer.contentView.bounds.origin
        parent.completions = PiEditorCompletions(input: coordinator.input, replacementRange: NSRange(location: 0, length: 2),
                                                 options: (0..<8).map { .init(id: "\($0)", label: "/model \($0)", replacement: "/model ") })
        coordinator.update(parent)
        XCTAssertEqual(outer.contentView.bounds.origin, origin)
        for _ in 0..<7 { XCTAssertTrue(coordinator.handle(PiEditorKey(.down))) }
        XCTAssertEqual(outer.contentView.bounds.origin, origin)
        let inputScroll = try XCTUnwrap(view.editor.enclosingScrollView)
        let completionScroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first { $0 !== inputScroll })
        XCTAssertGreaterThan(completionScroll.contentView.bounds.origin.y, 0)
        let completionOrigin = completionScroll.contentView.bounds.origin
        coordinator.update(parent)
        XCTAssertEqual(completionScroll.contentView.bounds.origin, completionOrigin)
        XCTAssertEqual(outer.contentView.bounds.origin, origin)
    }

    private final class FocusWindow: NSWindow {
        var blockingSheet: NSWindow?
        override var attachedSheet: NSWindow? { blockingSheet ?? super.attachedSheet }
    }

    func testInitialFocusRetriesButDoesNotStealFromTextFieldOrSheet() async {
        _ = NSApplication.shared
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let window = FocusWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 0, y: 80, width: 200, height: 24))
        root.addSubview(field)
        window.makeFirstResponder(field)
        let editor = PiEditorNativeView(frame: NSRect(x: 0, y: 0, width: 300, height: 35))
        root.addSubview(editor)
        for _ in 0..<10 { await Task.yield() }
        editor.focusInitiallyIfAvailable()
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        window.makeFirstResponder(window)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.blockingSheet = sheet
        editor.focusInitiallyIfAvailable()
        XCTAssertFalse(window.firstResponder === editor.editor)
        window.blockingSheet = nil
        sheet.close()
        editor.focusInitiallyIfAvailable()
        XCTAssertTrue(window.firstResponder === editor.editor)
        window.makeFirstResponder(field)
        editor.focusInitiallyIfAvailable()
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        window.makeFirstResponder(window)
        editor.focusInitiallyIfAvailable()
        XCTAssertTrue(window.firstResponder === window)
    }

    func testInitialFocusAfterWindowAttachmentWithoutActiveControl() async {
        _ = NSApplication.shared
        let view = PiEditorNativeView(frame: NSRect(x: 0, y: 0, width: 300, height: 35))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        for _ in 0..<100 where window.firstResponder !== view.editor { await Task.yield() }
        XCTAssertTrue(window.firstResponder === view.editor)
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
