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
    var separatorColor: NSColor? = nil
    var interfaceMode: MacInterfaceMode = .pi

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> PiEditorNativeView {
        let view = PiEditorNativeView()
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: PiEditorNativeView, context: Context) {
        context.coordinator.update(self)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PiEditorNativeView, context: Context) -> CGSize? {
        nsView.fittingSize(for: proposal.width ?? max(1, nsView.bounds.width))
    }

    static func dismantleNSView(_ view: PiEditorNativeView, coordinator: Coordinator) {
        coordinator.detach()
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

        deinit { NotificationCenter.default.removeObserver(self) }

        func attach(_ view: PiEditorNativeView) {
            NotificationCenter.default.removeObserver(self)
            self.view = view
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoDidFinish),
                                                       name: name, object: view.editor.undoManager)
            }
            view.editor.string = parent.text
            view.editor.setSelectedRange(input.selection)
            view.editor.delegate = self
            view.editor.routeKey = { [weak self] event in self?.handle(PiEditorKey(event: event)) ?? false }
            applyStyle()
            view.invalidateTextSize()
            refreshCompletions()
            requestCompletion()
        }

        func detach() {
            requestTask?.cancel()
            NotificationCenter.default.removeObserver(self)
            view?.editor.delegate = nil
            view?.editor.routeKey = nil
            view = nil
        }

        func update(_ parent: PiEditor) {
            let contextChanged = self.parent.contextID != parent.contextID
            self.parent = parent
            guard let editor = view?.editor else { return }
            applyStyle()
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

        private func applyStyle() {
            changingText = true
            view?.applyStyle(interfaceMode: parent.interfaceMode, separatorColor: parent.separatorColor)
            changingText = false
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
            view?.invalidateTextSize()
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
            view?.invalidateTextSize()
            history.reset()
            parent.text = editor.string
            captureInput()
            refreshCompletions()
            requestCompletion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            synchronizeNativeInput()
        }

        @objc private func undoOrRedoDidFinish(_ notification: Notification) {
            // A closed native undo group can restore storage without text or selection callbacks.
            // Read the final native state after undo/redo, but do not recapture an unchanged input.
            synchronizeNativeInput()
        }

        private func synchronizeNativeInput() {
            guard !changingText, let editor = view?.editor,
                  input.selection != editor.selectedRange() || input.text != editor.string else { return }
            // AppKit can report an undo through selection before its text-change notification.
            if input.text != editor.string {
                view?.invalidateTextSize()
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
    var onTextChange: (() -> Void)?
    override func didChangeText() {
        onTextChange?()
        super.didChangeText()
    }
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
    let bottomRule = NSView()
    private let scroll = NSScrollView()
    private let suggestions = PiEditorSuggestionList()
    private let suggestionScroll = NSScrollView()
    private let measurementStorage = NSTextStorage()
    private let measurementLayout = NSLayoutManager()
    private let measurementContainer = NSTextContainer(size: .zero)
    private var options: [PiEditorCompletions.Option] = []
    private var selectedID: String?
    private var hasInitialFocus = false
    private var interfaceMode: MacInterfaceMode = .pi
    var separatorColor: NSColor? {
        didSet {
            guard separatorColor != oldValue else { return }
            bottomRule.layer?.backgroundColor = (separatorColor ?? NSColor(
                calibratedRed: 0.42, green: 0.46, blue: 0.48, alpha: 1)).cgColor
        }
    }

    override var isFlipped: Bool { true }
    private var suggestionHeight: CGFloat { CGFloat(min(5, options.count)) * 28 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let foreground = NSColor(calibratedRed: 0.87, green: 0.88, blue: 0.88, alpha: 1)
        editor.font = font
        editor.textColor = foreground
        editor.insertionPointColor = foreground
        editor.typingAttributes = [.font: font, .foregroundColor: foreground]
        editor.selectedTextAttributes = [
            .foregroundColor: foreground,
            .backgroundColor: NSColor(calibratedRed: 0.29, green: 0.31, blue: 0.43, alpha: 1)
        ]
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier("pi-editor")
        editor.setAccessibilityLabel("Prompt")
        editor.onTextChange = { [weak self] in self?.invalidateTextSize() }
        scroll.documentView = editor

        measurementStorage.addLayoutManager(measurementLayout)
        measurementLayout.addTextContainer(measurementContainer)
        bottomRule.wantsLayer = true
        bottomRule.setAccessibilityIdentifier("pi-editor-bottom-rule")
        separatorColor = nil
        bottomRule.layer?.backgroundColor = NSColor(calibratedRed: 0.42, green: 0.46, blue: 0.48, alpha: 1).cgColor
        suggestionScroll.documentView = suggestions
        suggestionScroll.setAccessibilityIdentifier("pi-editor-suggestions")
        suggestionScroll.drawsBackground = false
        suggestionScroll.hasVerticalScroller = true
        suggestionScroll.autohidesScrollers = true
        suggestionScroll.scrollerStyle = .overlay
        suggestionScroll.isHidden = true
        addSubview(scroll)
        addSubview(bottomRule)
        addSubview(suggestionScroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Update presentation without replacing text, native input state or the undo manager.
    func applyStyle(interfaceMode: MacInterfaceMode, separatorColor: NSColor?) {
        self.separatorColor = separatorColor
        guard self.interfaceMode != interfaceMode else { return }
        self.interfaceMode = interfaceMode
        let isPi = interfaceMode == .pi
        let font = isPi ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
        let foreground = isPi ? NSColor(calibratedRed: 0.87, green: 0.88, blue: 0.88, alpha: 1) : .labelColor
        let fontChanged = editor.font != font
        let markedRange = editor.markedRange()
        let marked = editor.hasMarkedText() ? editor.textStorage?.attributedSubstring(from: markedRange) : nil

        appearance = isPi ? NSAppearance(named: .darkAqua) : nil
        // The native setters update existing text attributes. Restore marked runs by attributes
        // only, so AppKit retains the input context and its UTF-16 marked/selected ranges.
        editor.font = font
        editor.textColor = foreground
        editor.insertionPointColor = foreground
        var typing = editor.typingAttributes
        typing[.font] = font
        typing[.foregroundColor] = foreground
        editor.typingAttributes = typing
        editor.selectedTextAttributes = [
            .foregroundColor: isPi ? foreground : NSColor.selectedTextColor,
            .backgroundColor: isPi ? NSColor(calibratedRed: 0.29, green: 0.31, blue: 0.43, alpha: 1) : NSColor.selectedTextBackgroundColor
        ]
        if let marked {
            marked.enumerateAttributes(in: NSRange(location: 0, length: marked.length)) { attributes, range, _ in
                editor.textStorage?.setAttributes(attributes, range: NSRange(location: markedRange.location + range.location, length: range.length))
            }
        }
        bottomRule.isHidden = !isPi
        if fontChanged { invalidateTextSize() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                                  name: NSWindow.didBecomeKeyNotification, object: window)
        }
        scheduleInitialFocus()
    }

    @objc private func windowBecameKey(_ notification: Notification) { scheduleInitialFocus() }

    private func scheduleInitialFocus() {
        DispatchQueue.main.async { [weak self] in self?.focusInitiallyIfAvailable() }
    }

    /// Retry after window attachment/key activation, but never reclaim focus from another control.
    func focusInitiallyIfAvailable() {
        guard !hasInitialFocus, let window, window.attachedSheet == nil,
              window.sheetParent == nil, NSApplication.shared.modalWindow == nil else { return }
        if window.firstResponder === editor { hasInitialFocus = true; return }
        if let responder = window.firstResponder, responder !== window {
            guard let view = responder as? NSView, !(view is NSTextView), !(view is NSControl),
                  self.isDescendant(of: view) else { return }
        }
        hasInitialFocus = window.makeFirstResponder(editor)
    }

    /// Measure a separate TextKit layout. SwiftUI sizing must not move the live caret or scroll view.
    private var measuredHeights: [CGFloat: CGFloat] = [:]
    private var measuredText: String?

    private func textHeight(for width: CGFloat) -> CGFloat {
        if measuredText != editor.string {
            measuredHeights.removeAll(keepingCapacity: true)
            measuredText = editor.string
        }
        if let height = measuredHeights[width] { return height }
        measurementStorage.setAttributedString(editor.textStorage ?? NSAttributedString(string: editor.string))
        measurementContainer.lineFragmentPadding = editor.textContainer?.lineFragmentPadding ?? 5
        measurementContainer.containerSize = NSSize(width: max(1, width - editor.textContainerInset.width * 2),
                                                    height: .greatestFiniteMagnitude)
        measurementLayout.ensureLayout(for: measurementContainer)
        let lineHeight = measurementLayout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: NSFont.systemFontSize))
        let height = max(lineHeight, measurementLayout.usedRect(for: measurementContainer).maxY,
                         measurementLayout.extraLineFragmentRect.maxY)
        let measured = ceil(height + editor.textContainerInset.height * 2)
        measuredHeights[width] = measured
        return measured
    }

    func fittingSize(for width: CGFloat) -> NSSize {
        let width = width.isFinite ? max(1, width) : max(1, bounds.width)
        return NSSize(width: width, height: min(180, max(34, textHeight(for: width))) + 1 + suggestionHeight)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingSize(for: bounds.width).height)
    }

    func invalidateTextSize() {
        measuredHeights.removeAll(keepingCapacity: true)
        measuredText = nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateTextSize() }
    }

    override func layout() {
        super.layout()
        let inputHeight = fittingSize(for: bounds.width).height - 1 - suggestionHeight
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: inputHeight)
        editor.setFrameSize(NSSize(width: scroll.contentSize.width,
                                  height: max(inputHeight, textHeight(for: scroll.contentSize.width))))
        bottomRule.frame = NSRect(x: 0, y: inputHeight, width: bounds.width, height: 1)
        suggestionScroll.frame = NSRect(x: 0, y: inputHeight + 1, width: bounds.width, height: suggestionHeight)
        suggestions.setFrameSize(NSSize(width: suggestionScroll.contentSize.width, height: CGFloat(options.count) * 28))
        for (index, button) in suggestions.subviews.enumerated() {
            button.frame = NSRect(x: 0, y: CGFloat(index) * 28, width: suggestions.frame.width, height: 28)
        }
    }

    func showCompletions(_ options: [PiEditorCompletions.Option], selectedID: String?, choose: @escaping (PiEditorCompletions.Option) -> Void) {
        let changed = self.options != options || self.selectedID != selectedID
        self.options = options
        self.selectedID = selectedID
        // Refresh callbacks even when the visible results have not changed.
        if changed {
            for child in suggestions.subviews { child.removeFromSuperview() }
            for option in options {
                let button = PiEditorCompletionButton()
                button.title = option.label + (option.detail.isEmpty ? "" : "  —  " + option.detail)
                button.alignment = .left
                button.lineBreakMode = .byTruncatingTail
                button.bezelStyle = .inline
                button.state = option.id == selectedID ? .on : .off
                button.setAccessibilityIdentifier("pi-completion-" + option.id)
                button.setAccessibilityLabel(button.title)
                suggestions.addSubview(button)
            }
            suggestionScroll.isHidden = options.isEmpty
            invalidateTextSize()
        }
        for (option, button) in zip(options, suggestions.subviews) {
            (button as? PiEditorCompletionButton)?.choose = { choose(option) }
        }
        guard changed else { return }
        layoutSubtreeIfNeeded()
        suggestions.layoutSubtreeIfNeeded()
        if let index = options.firstIndex(where: { $0.id == selectedID }) {
            // Scroll only this clip view. NSView.scrollToVisible can move the outer conversation.
            let row = suggestions.subviews[index].frame
            let clip = suggestionScroll.contentView
            var origin = clip.bounds.origin
            if row.minY < clip.bounds.minY { origin.y = row.minY }
            else if row.maxY > clip.bounds.maxY { origin.y = row.maxY - clip.bounds.height }
            clip.scroll(to: origin)
            suggestionScroll.reflectScrolledClipView(clip)
        }
    }
}

@MainActor private final class PiEditorSuggestionList: NSView {
    override var isFlipped: Bool { true }
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
