import AppKit
import PiRemoteCore
import SwiftUI

/// Native equivalents of the built-in dark terminal theme, not an ANSI renderer.
enum PiPalette {
    static let background = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let panel = Color(red: 0.13, green: 0.23, blue: 0.29)
    static let accent = Color(red: 0.65, green: 0.60, blue: 0.84)
    static let muted = Color(red: 0.62, green: 0.65, blue: 0.66)
    static let text = Color(red: 0.87, green: 0.88, blue: 0.88)
    static let warning = Color(red: 0.92, green: 0.50, blue: 0.51)
    static let heading = Color(red: 0.80, green: 0.60, blue: 0.13)
    static let toolPending = Color(red: 0.20, green: 0.22, blue: 0.23)
    static let toolSuccess = Color(red: 0.15, green: 0.25, blue: 0.19)
    static let toolError = Color(red: 0.36, green: 0.16, blue: 0.16)
    static let bash = Color(red: 0.37, green: 0.70, blue: 0.53)

    static func thinking(_ level: String) -> Color {
        switch level {
        case "minimal": Color(red: 0.41, green: 0.50, blue: 0.55)
        case "low": Color(red: 0.33, green: 0.54, blue: 0.64)
        case "medium": Color(red: 0.38, green: 0.52, blue: 0.80)
        case "high": Color(red: 0.59, green: 0.46, blue: 0.90)
        case "xhigh": Color(red: 0.87, green: 0.33, blue: 0.76)
        case "max": Color(red: 1, green: 0.33, blue: 0.38)
        default: Color(red: 0.42, green: 0.46, blue: 0.48)
        }
    }
}

struct PiBuiltinCommand: Identifiable, Equatable {
    let name: String
    let detail: String
    var id: String { name }

    static let all: [Self] = [
        .init(name: "model", detail: "Select a model"),
        .init(name: "thinking", detail: "Select a thinking level"),
        .init(name: "settings", detail: "Queue, retry and compaction settings"),
        .init(name: "session", detail: "Inspect this session and usage"),
        .init(name: "new", detail: "Start a session in the current directory"),
        .init(name: "name", detail: "Rename the current session"),
        .init(name: "compact", detail: "Review context compaction"),
        .init(name: "fork", detail: "Select an eligible message to fork"),
        .init(name: "clone", detail: "Review session clone controls"),
        .init(name: "copy", detail: "Review and copy the last response"),
        .init(name: "export", detail: "Review session export"),
        .init(name: "import", detail: "Review a JSONL session import"),
        .init(name: "changelog", detail: "Read the installed Pi changelog"),
        .init(name: "hotkeys", detail: "Show native Pi keyboard shortcuts")
    ]

    static func parse(_ text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let token = trimmed.prefix { !$0.isWhitespace }
        guard !token.dropFirst().contains("/") else { return nil }
        return (String(token.dropFirst()), String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct PiShellOffer: Identifiable, Equatable {
    let id = UUID()
    let context: SessionContext
    let draft: String
    let command: String
    let excludeFromContext: Bool

    static func parse(_ text: String, context: SessionContext) -> Self? {
        guard text.hasPrefix("!") else { return nil }
        let excluded = text.hasPrefix("!!")
        let command = String(text.dropFirst(excluded ? 2 : 1))
        return Self(context: context, draft: text, command: command, excludeFromContext: excluded)
    }
}

/// Path suggestions change the draft only. File contents require a separate preview/attach action.
struct PiPathQuery: Equatable {
    let range: NSRange
    let directory: String
    let prefix: String
    let typedParent: String
    let attachment: Bool
    let quoted: Bool

    static func parse(text: String, selection: NSRange, directory: String) -> Self? {
        let string = text as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= string.length,
              Range(selection, in: text) != nil else { return nil }
        // A partial replacement must not leave an unmodified path suffix after the completion.
        if selection.location < string.length {
            let suffix = string.substring(from: selection.location)
            guard suffix.first?.isWhitespace == true else { return nil }
        }
        let before = string.substring(to: selection.location)
        // Track whitespace only outside quotes so completed paths with spaces remain completable.
        var start = before.startIndex
        var insideQuote = false
        for index in before.indices {
            if before[index] == "\"" { insideQuote.toggle() }
            else if before[index].isWhitespace, !insideQuote { start = before.index(after: index) }
        }
        var token = String(before[start...])
        let attachment = token.hasPrefix("@")
        if attachment { token.removeFirst() }
        let quoted = token.hasPrefix("\"")
        if quoted { token.removeFirst(); if token.hasSuffix("\"") { token.removeLast() } }
        guard !token.contains("\"") else { return nil }
        guard attachment || token.contains("/") else { return nil }
        let parent = token.lastIndex(of: "/").map { String(token[...$0]) } ?? ""
        let prefix = token.lastIndex(of: "/").map { String(token[token.index(after: $0)...]) } ?? token
        let folder: String
        if parent.hasPrefix("/") || parent.hasPrefix("~/") { folder = parent }
        else { folder = URL(fileURLWithPath: directory).appendingPathComponent(parent).path }
        let location = before[..<start].utf16.count
        return Self(range: NSRange(location: location, length: before[start...].utf16.count), directory: folder,
                    prefix: prefix, typedParent: (attachment ? "@" : "") + parent, attachment: attachment, quoted: quoted)
    }

    func replacement(_ item: DirectoryItem) -> String {
        let value = typedParent + item.name + (item.isDirectory ? "/" : "")
        // Completion only edits text. Never interpret file names as shell syntax.
        if quoted || value.contains(where: { $0.isWhitespace }) {
            let path = attachment ? String(value.dropFirst()) : value
            return (attachment ? "@" : "") + "\"" + path + "\""
        }
        return value
    }
}

struct PiFooterValue: Equatable {
    let directory: String
    let model: String
    let usage: String
    let phase: String

    init(state: HostSnapshot, statistics: SessionStatistics?) {
        let path = state.sessions.first { $0.id == state.selected }?.directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        directory = path.map { $0 == home ? "~" : ($0.hasPrefix(home + "/") ? "~" + String($0.dropFirst(home.count)) : $0) } ?? "No working directory"
        model = state.model.isEmpty ? "Model unavailable" : state.model
        phase = state.selected == nil ? "No session" : state.phase
        if let statistics {
            var parts: [String] = []
            for (prefix, count) in [("↑", statistics.tokens.input), ("↓", statistics.tokens.output),
                                    ("R", statistics.tokens.cacheRead), ("W", statistics.tokens.cacheWrite)] where count > 0 {
                parts.append(prefix + Self.count(count))
            }
            parts.append(String(format: "$%.3f", statistics.cost))
            if let context = statistics.contextUsage {
                let percent = context.percent.map { String(format: "%.1f%%", $0) } ?? "?"
                parts.append(percent + "/" + Self.count(context.contextWindow))
            } else { parts.append("context unavailable") }
            if state.runtime?.autoCompactionEnabled == true { parts.append("(auto)") }
            usage = parts.joined(separator: " ")
        } else { usage = "Usage unavailable" }
    }

    private static func count(_ value: Int) -> String {
        value >= 1_000 && value % 1_000 == 0 ? "\(value / 1_000)k" : String(value)
    }
}
