import AppKit
import SwiftUI

/// Display-only lexical colors. These runs never interpret or execute source text.
enum PiCodeSyntax {
    static let maximumBytes = 32 * 1_024
    static let maximumRuns = 2_048

    enum Kind: Equatable { case plain, keyword, string, comment, number }
    struct Run: Equatable {
        let text: String
        let kind: Kind
    }

    private enum Language: String {
        case swift, javascript, typescript, python, json

        init?(_ label: String?) {
            guard let label, label.utf8.prefix(33).count <= 32 else { return nil }
            switch label.lowercased() {
            case "swift": self = .swift
            case "js", "javascript", "jsx": self = .javascript
            case "ts", "typescript", "tsx": self = .typescript
            case "py", "python", "python3": self = .python
            case "json": self = .json
            default: return nil
            }
        }

        var keywords: Set<String> {
            switch self {
            case .swift:
                return Set("actor as async await break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is let nil nonisolated open operator private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var where while".split(separator: " ").map(String.init))
            case .javascript, .typescript:
                return Set("as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null of private protected public readonly return static super switch this throw true try type typeof undefined var void while yield".split(separator: " ").map(String.init))
            case .python:
                return Set("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield".split(separator: " ").map(String.init))
            case .json: return ["true", "false", "null"]
            }
        }
    }

    /// Both limits fail closed to one plain run. Joining runs preserves the original UTF-8.
    static func runs(code: String, language: String?) -> [Run] {
        let plain = [Run(text: code, kind: .plain)]
        guard let language = Language(language),
              code.utf8.prefix(maximumBytes + 1).count <= maximumBytes else { return plain }
        let source = Array(code.unicodeScalars)
        let keywords = language.keywords
        var result: [Run] = []
        var index = 0
        var plainStart = 0

        func matches(_ marker: [Unicode.Scalar], at offset: Int) -> Bool {
            guard offset + marker.count <= source.count else { return false }
            return source[offset..<(offset + marker.count)].elementsEqual(marker)
        }
        func text(_ start: Int, _ end: Int) -> String {
            String(String.UnicodeScalarView(source[start..<end]))
        }
        func identifierStart(_ value: Unicode.Scalar) -> Bool {
            value == "_" || (65...90).contains(value.value) || (97...122).contains(value.value) || value.value >= 128
        }
        func digit(_ value: Unicode.Scalar) -> Bool { (48...57).contains(value.value) }

        while index < source.count {
            let start = index
            let value = source[index]
            var kind = Kind.plain
            if language == .swift && value == "#" {
                var end = index + 1
                while end < source.count && source[end] == "#" { end += 1 }
                // Raw string delimiters need a different escape grammar. Do not guess it.
                if end < source.count && source[end] == "\"" { return plain }
            }
            if (language == .python && value == "#") ||
                (language != .python && language != .json && matches(["/", "/"], at: index)) {
                kind = .comment
                while index < source.count && source[index] != "\n" && source[index] != "\r" { index += 1 }
            } else if language != .python && language != .json && matches(["/", "*"], at: index) {
                kind = .comment
                index += 2
                var depth = 1
                while index < source.count && depth > 0 {
                    if language == .swift && matches(["/", "*"], at: index) { depth += 1; index += 2 }
                    else if matches(["*", "/"], at: index) { depth -= 1; index += 2 }
                    else { index += 1 }
                }
            } else if value == "\"" || (language != .json && value == "'") ||
                        ((language == .javascript || language == .typescript) && value == "`") {
                kind = .string
                let triple = (language == .python || language == .swift) && matches([value, value, value], at: index)
                let delimiter = triple ? [value, value, value] : [value]
                index += delimiter.count
                while index < source.count {
                    if source[index] == "\\" { index = min(index + 2, source.count) }
                    else if matches(delimiter, at: index) { index += delimiter.count; break }
                    else if !triple && value != "`" && (source[index] == "\n" || source[index] == "\r") { break }
                    else { index += 1 }
                }
            } else if identifierStart(value) {
                index += 1
                while index < source.count && (identifierStart(source[index]) || digit(source[index])) { index += 1 }
                if keywords.contains(text(start, index)) { kind = .keyword }
            } else if digit(value) {
                kind = .number
                while index < source.count && digit(source[index]) { index += 1 }
                if index + 1 < source.count && source[index] == "." && digit(source[index + 1]) {
                    index += 1
                    while index < source.count && digit(source[index]) { index += 1 }
                }
                if index < source.count && (source[index] == "e" || source[index] == "E") {
                    var end = index + 1
                    if end < source.count && (source[end] == "+" || source[end] == "-") { end += 1 }
                    let digits = end
                    while end < source.count && digit(source[end]) { end += 1 }
                    if end > digits { index = end }
                }
            } else { index += 1 }

            if kind != .plain {
                if plainStart < start { result.append(Run(text: text(plainStart, start), kind: .plain)) }
                result.append(Run(text: text(start, index), kind: kind))
                plainStart = index
                if result.count >= maximumRuns { return plain }
            }
        }
        if plainStart < source.count { result.append(Run(text: text(plainStart, source.count), kind: .plain)) }
        return result.isEmpty ? plain : result
    }
}

@MainActor struct PiCodeBlock: View {
    let code: String
    let language: String?
    private let copy: (String) throws -> Void
    @Environment(\.macInterfaceMode) private var interfaceMode
    @State private var rendered = AttributedString()
    @State private var height: CGFloat = 40
    @State private var feedback: String?
    @State private var copyFailed = false

    init(code: String, language: String?, copy: @escaping (String) throws -> Void = { try LocalClipboard.copy($0) }) {
        self.code = code
        self.language = language
        self.copy = copy
    }

    private struct Input: Equatable {
        let code: String
        let language: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(languageLabel).foregroundStyle(PiPalette.muted).lineLimit(1)
                Spacer(minLength: 0)
                if let feedback {
                    PiCodeCopyFeedback(message: feedback, failed: copyFailed)
                }
                PiCodeCopyButton(action: copyCode)
            }
            .font(.system(size: interfaceMode == .desktop ? 12 : 11, design: interfaceMode == .desktop ? .default : .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView([.horizontal, .vertical]) {
                Text(rendered).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("pi-code-source")
            }
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .frame(height: height)
        }
        .background(PiPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: interfaceMode == .desktop ? 8 : 0))
        // The lexical palette and native header controls share this local dark surface.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .onChange(of: Input(code: code, language: language), initial: true) { _, _ in
            // Cache styling across unrelated view updates, including copy feedback changes.
            var attributed = AttributedString()
            for run in PiCodeSyntax.runs(code: code, language: language) {
                var part = AttributedString(run.text)
                switch run.kind {
                case .plain: part.foregroundColor = PiPalette.text
                case .keyword: part.foregroundColor = PiPalette.accent
                case .string: part.foregroundColor = PiPalette.bash
                case .comment: part.foregroundColor = PiPalette.muted
                case .number: part.foregroundColor = PiPalette.heading
                }
                attributed.append(part)
            }
            rendered = attributed
            var lines = 1
            for byte in code.utf8 {
                if byte == 10 { lines += 1 }
                if lines >= 18 { break }
            }
            height = CGFloat(lines * 16 + 20)
            feedback = nil
            copyFailed = false
        }
    }

    private var languageLabel: String {
        guard let language, !language.isEmpty else { return "Code" }
        // A fence label is untrusted display text, not a URL or a format string.
        let label = language.unicodeScalars.prefix(32).filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        return label.isEmpty ? "Code" : label
    }

    private func copyCode() {
        do {
            try copy(code)
            copyFailed = false
            feedback = "Copied to this Mac"
        } catch {
            copyFailed = true
            feedback = "Cannot copy code. Try again."
        }
    }
}

/// Keep the compact action a native button with a stable accessibility identifier.
private struct PiCodeCopyButton: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Copy code", target: context.coordinator, action: #selector(Coordinator.activate))
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        let font = context.environment.macInterfaceMode == .desktop
            ? NSFont.systemFont(ofSize: 12, weight: .regular)
            : NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        button.appearance = NSAppearance(named: .darkAqua)
        button.font = font
        button.attributedTitle = NSAttributedString(string: "Copy code", attributes: [.font: font, .foregroundColor: NSColor(PiPalette.accent)])
        button.contentTintColor = NSColor(PiPalette.accent)
        button.setAccessibilityLabel("Copy code")
        button.setAccessibilityIdentifier("pi-code-copy")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}

private struct PiCodeCopyFeedback: NSViewRepresentable {
    let message: String
    let failed: Bool

    func makeNSView(context: Context) -> NSTextField { NSTextField(labelWithString: message) }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = message
        field.appearance = NSAppearance(named: .darkAqua)
        field.font = context.environment.macInterfaceMode == .desktop
            ? .systemFont(ofSize: 12, weight: .regular)
            : .monospacedSystemFont(ofSize: 11, weight: .regular)
        let warning = context.environment.macInterfaceMode == .desktop
            ? Color(red: 0.96, green: 0.53, blue: 0.54) : PiPalette.warning
        field.textColor = NSColor(failed ? warning : PiPalette.muted)
        field.setAccessibilityIdentifier("pi-code-copy-feedback")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
