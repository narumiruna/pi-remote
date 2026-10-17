import AppKit
import PiRemoteCore
import SwiftUI

/// All ranges use AppKit's UTF-16 coordinates. Pass this snapshot back with async results.
struct PiEditorInput: Equatable, Sendable {
    var text: String
    var selection: NSRange
    var contextID: String
    var revision: UInt64 = 0
}

struct PiEditorCompletions: Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        var id: String
        var label: String
        var detail: String = ""
        /// Include required quotes, spaces and directory separators in the replacement.
        var replacement: String
    }

    var input: PiEditorInput
    var replacementRange: NSRange
    var options: [Option]

    func matches(_ current: PiEditorInput) -> Bool {
        guard input == current, current.selection.length == 0, !options.isEmpty,
              let range = Range(replacementRange, in: current.text) else { return false }
        return range.lowerBound.samePosition(in: current.text.unicodeScalars) != nil
            && range.upperBound.samePosition(in: current.text.unicodeScalars) != nil
    }
}

struct PiEditorKey: Equatable {
    enum Code: Equatable { case enter, tab, up, down, escape, letter(String), other }
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let shift = Self(rawValue: 1)
        static let control = Self(rawValue: 2)
        static let option = Self(rawValue: 4)
        static let command = Self(rawValue: 8)
    }
    var code: Code
    var modifiers: Modifiers = []

    init(_ code: Code, modifiers: Modifiers = []) {
        self.code = code
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        switch event.keyCode {
        case 36, 76: code = .enter
        case 48: code = .tab
        case 126: code = .up
        case 125: code = .down
        case 53: code = .escape
        default: code = .letter(event.charactersIgnoringModifiers?.lowercased() ?? "")
        }
        modifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
    }
}

/// Pure routing. Application shortcuts apply only while this editor owns keyboard focus.
enum PiEditorRouting {
    struct State {
        var isComposing = false
        var isBusy = false
        var canSubmit = true
        var hasText = true
        var hasCompletions = false
        var hasSelection = false
        var firstVisualLine = true
        var lastVisualLine = true
        var atStart = true
        var browsingHistory = false
    }
    enum Action: Equatable {
        case native, consume, newline, submit(Delivery), stop, recoverQueue
        case complete, requestCompletion, dismissCompletion, suggestion(Int), history(Int)
        case lineStart, lineEnd, selectModel, cycleModel(Int), toggleTools, toggleThinking, cycleThinking
    }

    static func action(for key: PiEditorKey, state: State) -> Action {
        guard !state.isComposing, !key.modifiers.contains(.command) else { return .native }
        let modifiers = key.modifiers
        // Pi 1.3.0: coding-agent/dist/modes/interactive/components/custom-editor.js dispatches
        // application actions before pi-tui/dist/components/editor.js. interactive-mode.js
        // handleFollowUp queues while busy and submits while idle. This overrides Alt-Enter newline.
        if key.code == .enter, modifiers == .option {
            return state.canSubmit && state.hasText ? .submit(state.isBusy ? .followUp : .prompt) : .consume
        }
        if key.code == .up, modifiers == .option { return .recoverQueue }
        if modifiers == .control {
            switch key.code {
            case .letter("l"): return .selectModel
            case .letter("p"): return .cycleModel(1)
            case .letter("o"): return .toggleTools
            case .letter("t"): return .toggleThinking
            case .letter("j"): return .newline
            default: break
            }
        }
        if modifiers == [.control, .shift], key.code == .letter("p") { return .cycleModel(-1) }
        if modifiers == .shift, key.code == .tab { return .cycleThinking }
        if modifiers.isEmpty, state.hasCompletions {
            switch key.code {
            case .enter, .tab: return .complete
            case .up: return .suggestion(-1)
            case .down: return .suggestion(1)
            case .escape: return .dismissCompletion
            default: break
            }
        }
        switch key.code {
        case .enter:
            if !modifiers.isEmpty { return .newline }
            return state.canSubmit && state.hasText ? .submit(state.isBusy ? .steer : .prompt) : .consume
        case .tab where modifiers.isEmpty: return .requestCompletion
        case .escape where modifiers.isEmpty: return .stop
        case .up where modifiers.isEmpty && !state.hasSelection && state.firstVisualLine:
            return state.atStart || state.browsingHistory ? .history(-1) : .lineStart
        case .down where modifiers.isEmpty && !state.hasSelection && state.lastVisualLine:
            return state.browsingHistory ? .history(1) : .lineEnd
        default: return .native
        }
    }
}

/// History is supplied oldest first. Browsing snapshots the entries and preserves the unsent draft.
struct PiEditorHistory {
    private var entries: [String] = []
    private var index: Int?
    private var draft: PiEditorInput?
    var isBrowsing: Bool { index != nil }

    mutating func reset() { entries = []; index = nil; draft = nil }

    mutating func move(_ direction: Int, current: PiEditorInput, history: [String]) -> PiEditorInput? {
        if index == nil {
            guard direction < 0 else { return nil }
            entries = history.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !entries.isEmpty else { return nil }
            draft = current
            index = entries.count
        }
        guard let index else { return nil }
        let next = max(0, min(entries.count, index + (direction < 0 ? -1 : 1)))
        guard next != index else { return nil }
        if next == entries.count {
            let restored = draft
            reset()
            return restored
        }
        self.index = next
        var result = current
        result.text = entries[next]
        result.selection = NSRange(location: direction < 0 ? 0 : result.text.utf16.count, length: 0)
        return result
    }
}

struct PiEditorSuggestionSelection {
    private(set) var id: String?
    mutating func update(options: [PiEditorCompletions.Option]) {
        if !options.contains(where: { $0.id == id }) { id = options.first?.id }
    }
    mutating func move(_ direction: Int, options: [PiEditorCompletions.Option]) {
        update(options: options)
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.id == id } ?? 0
        id = options[(index + (direction < 0 ? options.count - 1 : 1)) % options.count].id
    }
}

/// Native prompt input. The parent supplies slash/path results and owns submission acknowledgement.
/// Submission never clears text or adds history. Clear the binding only after acceptance.
/// Use a new contextID when changing sessions; this also clears native undo and history browsing.
@MainActor
struct PiEditor: NSViewRepresentable {
    @Binding var text: String
    var contextID: String = ""
    var isBusy = false
    var canSubmit = true
    var completions: PiEditorCompletions?
    var history: [String] = []
    var onSubmit: (Delivery) -> Void
    var onStop: () -> Void
    /// Option-Up requests queued-input recovery. Escape uses onStop; the parent owns abort policy.
    var onRecoverQueue: ((Bool) -> Void)? = nil
    var onCompletion: (PiEditorCompletions.Option) -> Void = { _ in }
    /// Called on input/caret changes and Tab. The Bool is true for an explicit Tab request.
    /// Cancel older work in the parent; return the exact input snapshot with each result batch.
    var onCompletionRequest: (PiEditorInput, Bool) -> Void = { _, _ in }
    var onDismissCompletion: () -> Void = {}
    var onSelectModel: () -> Void = {}
    /// +1 selects the next model; -1 selects the previous model.
    var onCycleModel: (Int) -> Void = { _ in }
    var onToggleTools: () -> Void = {}
    var onToggleThinking: () -> Void = {}
    var onCycleThinking: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> PiEditorNativeView {
        let view = PiEditorNativeView()
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: PiEditorNativeView, context: Context) {
        context.coordinator.update(self)
    }
    static func dismantleNSView(_ view: PiEditorNativeView, coordinator: Coordinator) {
        view.editor.delegate = nil
        view.editor.routeKey = nil
        coordinator.view = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PiEditor
        weak var view: PiEditorNativeView?
        var input: PiEditorInput
        private var history = PiEditorHistory()
        private var selection = PiEditorSuggestionSelection()
        private var dismissed: PiEditorInput?
        private var changingText = false
        private var requestTask: Task<Void, Never>?

        init(_ parent: PiEditor) {
            self.parent = parent
            input = PiEditorInput(text: parent.text, selection: NSRange(location: parent.text.utf16.count, length: 0), contextID: parent.contextID)
        }

        func attach(_ view: PiEditorNativeView) {
            self.view = view
            view.editor.string = parent.text
            view.editor.setSelectedRange(input.selection)
            view.editor.delegate = self
            view.editor.routeKey = { [weak self] event in self?.handle(PiEditorKey(event: event)) ?? false }
            refreshCompletions()
            requestCompletion()
        }

        func update(_ parent: PiEditor) {
            let contextChanged = self.parent.contextID != parent.contextID
            self.parent = parent
            guard let editor = view?.editor else { return }
            let desiredText = parent.text
            if contextChanged {
                changingText = true
                editor.unmarkText()
                changingText = false
                history.reset()
                dismissed = nil
                input.contextID = parent.contextID
            }
            if contextChanged || (editor.string != desiredText && !editor.hasMarkedText()) {
                history.reset()
                replace(NSRange(location: 0, length: editor.string.utf16.count), with: desiredText,
                        selection: NSRange(location: min(editor.selectedRange().location, desiredText.utf16.count), length: 0))
                if contextChanged { editor.undoManager?.removeAllActions() }
                captureInput()
                requestCompletion()
            }
            refreshCompletions()
        }

        private var activeCompletions: PiEditorCompletions? {
            guard let batch = parent.completions, batch.matches(input), dismissed != input,
                  view?.editor.hasMarkedText() == false else { return nil }
            return batch
        }

        func handle(_ key: PiEditorKey) -> Bool {
            guard let editor = view?.editor, !editor.hasMarkedText() else { return false }
            let lines = editor.visualLineBoundaries()
            var state = PiEditorRouting.State()
            state.isComposing = editor.hasMarkedText()
            state.isBusy = parent.isBusy
            state.canSubmit = parent.canSubmit
            state.hasText = !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            state.hasCompletions = activeCompletions != nil
            state.hasSelection = editor.selectedRange().length != 0
            state.firstVisualLine = lines.first
            state.lastVisualLine = lines.last
            state.atStart = editor.selectedRange().location == 0
            state.browsingHistory = history.isBrowsing
            switch PiEditorRouting.action(for: key, state: state) {
            case .native: return false
            case .consume: break
            case .newline: editor.insertText("\n", replacementRange: editor.selectedRange())
            case .submit(let delivery): parent.onSubmit(delivery)
            case .stop: parent.onStop()
            case .recoverQueue:
                guard let recover = parent.onRecoverQueue else { return false }
                recover(false)
            case .complete:
                if let batch = activeCompletions {
                    selection.update(options: batch.options)
                    if let option = batch.options.first(where: { $0.id == selection.id }) { complete(option) }
                }
            case .requestCompletion:
                dismissed = nil
                refreshCompletions()
                requestCompletion(explicit: true)
            case .dismissCompletion:
                dismissed = input
                refreshCompletions()
                parent.onDismissCompletion()
            case .suggestion(let direction):
                selection.move(direction, options: activeCompletions?.options ?? [])
                refreshCompletions()
            case .history(let direction):
                if let replacement = history.move(direction, current: input, history: parent.history) {
                    replace(NSRange(location: 0, length: editor.string.utf16.count), with: replacement.text, selection: replacement.selection)
                    parent.text = editor.string
                    captureInput()
                    requestCompletion()
                    refreshCompletions()
                }
            case .lineStart: editor.moveToBeginningOfLine(nil)
            case .lineEnd: editor.moveToEndOfLine(nil)
            case .selectModel: parent.onSelectModel()
            case .cycleModel(let direction): parent.onCycleModel(direction)
            case .toggleTools: parent.onToggleTools()
            case .toggleThinking: parent.onToggleThinking()
            case .cycleThinking: parent.onCycleThinking()
            }
            return true
        }

        private func complete(_ option: PiEditorCompletions.Option) {
            guard let batch = activeCompletions, batch.options.contains(option), let editor = view?.editor else { return }
            dismissed = input
            history.reset()
            replace(batch.replacementRange, with: option.replacement,
                    selection: NSRange(location: batch.replacementRange.location + option.replacement.utf16.count, length: 0))
            parent.text = editor.string
            captureInput()
            refreshCompletions()
            parent.onCompletion(option)
            requestCompletion()
        }

        /// Use NSTextView's edit path for undo, input delegates and native selection notifications.
        private func replace(_ range: NSRange, with text: String, selection: NSRange) {
            guard let editor = view?.editor else { return }
            changingText = true
            editor.breakUndoCoalescing()
            editor.insertText(text, replacementRange: range)
            editor.setSelectedRange(selection)
            editor.breakUndoCoalescing()
            changingText = false
        }

        private func captureInput() {
            guard let editor = view?.editor else { return }
            input.text = editor.string
            input.selection = editor.selectedRange()
            input.contextID = parent.contextID
            input.revision &+= 1
        }

        private func requestCompletion(explicit: Bool = false) {
            requestTask?.cancel()
            let requested = input
            // SwiftUI updates must not synchronously change parent state.
            requestTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, self.input == requested,
                      self.view?.editor.hasMarkedText() == false else { return }
                self.parent.onCompletionRequest(requested, explicit)
            }
        }

        private func refreshCompletions() {
            let options = activeCompletions?.options ?? []
            selection.update(options: options)
            view?.showCompletions(options, selectedID: selection.id) { [weak self] option in
                self?.complete(option)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !changingText, let editor = view?.editor else { return }
            history.reset()
            parent.text = editor.string
            captureInput()
            refreshCompletions()
            requestCompletion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !changingText, let editor = view?.editor,
                  input.selection != editor.selectedRange() || input.text != editor.string else { return }
            // AppKit can report an undo through selection before its text-change notification.
            if input.text != editor.string {
                history.reset()
                parent.text = editor.string
            }
            captureInput()
            refreshCompletions()
            requestCompletion()
        }
    }
}

@MainActor final class PiEditorTextView: NSTextView {
    private let editorUndoManager = UndoManager()
    override var undoManager: UndoManager? { editorUndoManager }
    var routeKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        // Let the input context consume Return, arrows, Tab and Escape during composition.
        if hasMarkedText() || routeKey?(event) != true { super.keyDown(with: event) }
    }

    func visualLineBoundaries() -> (first: Bool, last: Bool) {
        guard !string.isEmpty, let layoutManager, let textContainer else { return (true, true) }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.numberOfGlyphs
        guard glyphs > 0 else { return (true, true) }
        let location = min(selectedRange().location, string.utf16.count)
        // An extra line fragment represents the empty line after a trailing newline.
        if location == string.utf16.count, layoutManager.extraLineFragmentTextContainer != nil {
            return (false, true)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, string.utf16.count - 1))
        var range = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        return (range.location == 0,
                NSMaxRange(range) == glyphs && layoutManager.extraLineFragmentTextContainer == nil)
    }
}

@MainActor final class PiEditorNativeView: NSView {
    let editor = PiEditorTextView(frame: .zero)
    private let suggestions = NSStackView()
    private let suggestionScroll = NSScrollView()
    private var suggestionHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier("pi-editor")
        editor.setAccessibilityLabel("Prompt")
        scroll.documentView = editor

        suggestions.orientation = .vertical
        suggestions.alignment = .leading
        suggestions.spacing = 0
        suggestionScroll.documentView = suggestions
        suggestionScroll.drawsBackground = false
        suggestionScroll.hasVerticalScroller = true
        let stack = NSStackView(views: [scroll, suggestionScroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        suggestionHeight = suggestionScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 180),
            suggestionScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), suggestionHeight,
            suggestions.widthAnchor.constraint(equalTo: suggestionScroll.contentView.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil,
                  window.firstResponder === window || window.firstResponder === window.contentView else { return }
            window.makeFirstResponder(self.editor)
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 100 + suggestionHeight.constant) }

    func showCompletions(_ options: [PiEditorCompletions.Option], selectedID: String?, choose: @escaping (PiEditorCompletions.Option) -> Void) {
        for child in suggestions.arrangedSubviews { suggestions.removeArrangedSubview(child); child.removeFromSuperview() }
        for option in options {
            let button = PiEditorCompletionButton()
            button.title = option.label + (option.detail.isEmpty ? "" : "  —  " + option.detail)
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.bezelStyle = .inline
            button.state = option.id == selectedID ? .on : .off
            button.setAccessibilityIdentifier("pi-completion-" + option.id)
            button.setAccessibilityLabel(button.title)
            button.choose = { choose(option) }
            suggestions.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: suggestions.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        suggestionHeight.constant = CGFloat(min(5, options.count)) * 28
        suggestionScroll.isHidden = options.isEmpty
        layoutSubtreeIfNeeded()
        if let index = options.firstIndex(where: { $0.id == selectedID }), suggestions.arrangedSubviews.indices.contains(index) {
            suggestions.scrollToVisible(suggestions.arrangedSubviews[index].frame)
        }
        invalidateIntrinsicContentSize()
    }
}

@MainActor private final class PiEditorCompletionButton: NSButton {
    var choose: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(selectCompletion)
        setButtonType(.toggle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func selectCompletion() { choose?() }
}
