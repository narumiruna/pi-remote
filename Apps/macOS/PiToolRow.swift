import AppKit
import PiRemoteCore
import SwiftUI

/// Compact tool presentation. Output and targets are display text, not commands or links.
struct PiToolRow: View {
    let message: TranscriptMessage
    let expandTools: Bool
    let onDisclosure: (UUID, CGFloat) -> Void
    var runtimePhase: String? = nil
    @State private var expandedChoice: Bool?
    @State private var headerY: CGFloat = 0

    private var isExpanded: Bool { expandedChoice ?? expandTools }

    var body: some View {
        let value = PiToolRowValue(message, runtimePhase: runtimePhase)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).id("pi-tool-anchor-" + message.id.uuidString)
            PiToolHeading(value: value, expanded: isExpanded, identifier: "pi-tool-toggle-" + message.id.uuidString) {
                onDisclosure(message.id, headerY)
                expandedChoice = !isExpanded
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .named("pi-surface-viewport")).minY
            } action: { headerY = $0 }

            if isExpanded {
                ScrollView(.horizontal) {
                    Text(verbatim: value.expandedOutput)
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 6)
                    .accessibilityIdentifier("pi-tool-expanded-" + message.id.uuidString)
            } else if !value.preview.isEmpty {
                Text(verbatim: value.preview)
                    .foregroundStyle(value.hasError ? PiPalette.warning : PiPalette.muted)
                    .textSelection(.enabled).lineLimit(value.hasError ? 3 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    .accessibilityIdentifier("pi-tool-preview-" + message.id.uuidString)
            }
            if !isExpanded, value.previewHidden {
                Text("More output hidden · expand to read")
                    .foregroundStyle(PiPalette.muted).font(.system(size: 11, design: .monospaced))
                    .padding(.top, 2)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(PiPalette.text)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PiPalette.toolPending.opacity(0.25))
        .onChange(of: expandTools) { _, _ in expandedChoice = nil }
    }
}

/// A native button retains its identifier and disclosure state inside SwiftUI scroll containers.
@MainActor private struct PiToolHeading: NSViewRepresentable {
    let value: PiToolRowValue
    let expanded: Bool
    let identifier: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.press))
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.alignment = .left
        button.controlSize = .small
        button.cell?.wraps = false
        button.cell?.usesSingleLineMode = true
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let title = NSMutableAttributedString(string: (expanded ? "▾ " : "▸ ") + value.action,
                                             attributes: [.font: font, .foregroundColor: NSColor(PiPalette.accent)])
        if let target = value.target {
            title.append(NSAttributedString(string: "  " + target, attributes: [.font: font, .foregroundColor: NSColor(PiPalette.muted)]))
        }
        title.append(NSAttributedString(string: "   " + value.statusLabel,
                                        attributes: [.font: font, .foregroundColor: NSColor(value.requiresAttention ? PiPalette.warning : PiPalette.muted)]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        button.attributedTitle = title
        button.image = NSImage(systemSymbolName: value.systemImage, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.contentTintColor = NSColor(PiPalette.accent)
        button.toolTip = value.target ?? value.name
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(value.accessibilityHeading)
        button.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
        button.setAccessibilityHelp(expanded ? "Collapse tool output" : "Expand tool output")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 22)
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }
}

/// Pure, bounded heading and preview values. Expanded output always retains the exact text.
struct PiToolRowValue {
    let name: String
    let action: String
    let systemImage: String
    let target: String?
    let statusLabel: String
    let hasError: Bool
    var requiresAttention: Bool { hasError || statusLabel == "Interrupted" || statusLabel == "Unconfirmed" }
    let preview: String
    let previewHidden: Bool
    let expandedOutput: String

    var accessibilityHeading: String {
        ([action] + (target.map { [$0] } ?? []) + [statusLabel]).joined(separator: ", ")
    }

    init(_ message: TranscriptMessage, runtimePhase: String? = nil) {
        expandedOutput = message.text
        let first = message.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let legacyName = Self.legacyName(first)
        name = message.tool?.name ?? legacyName ?? "Tool"
        target = message.tool?.target
        hasError = message.isError || message.tool?.status == .failed
        let unfinished = message.tool?.status == .running || (message.tool == nil && message.streaming)
        if message.tool?.status == .interrupted || (unfinished && (runtimePhase == "interrupted" || runtimePhase == "unavailable")) {
            statusLabel = "Interrupted"
        } else if unfinished, runtimePhase == "recovering" { statusLabel = "Unconfirmed" }
        else if let status = message.tool?.status {
            switch status {
            case .running: statusLabel = "Running"
            case .completed: statusLabel = hasError ? "Failed" : "Completed"
            case .failed: statusLabel = "Failed"
            case .interrupted: statusLabel = "Interrupted"
            }
        } else { statusLabel = message.isError ? "Failed" : (message.streaming ? "Running" : "Output") }

        switch name {
        case "read": action = "Read"; systemImage = "doc.text"
        case "bash": action = "Run"; systemImage = "terminal"
        case "write": action = "Write"; systemImage = "square.and.pencil"
        case "edit": action = "Edit"; systemImage = "pencil.line"
        default:
            action = name.isEmpty ? "Tool" : DisplayLimit.text(name, bytes: 128)
            systemImage = "wrench.and.screwdriver"
        }

        // Strip only a recognized transport heading. An unknown first line is output.
        let recognized = message.tool.map { first == $0.name || first == $0.name + " — Running" } ?? (legacyName != nil)
        let output: String
        if recognized {
            output = message.text.firstIndex(of: "\n").map { String(message.text[message.text.index(after: $0)...]) } ?? ""
        } else { output = message.text }

        if name == "read", !hasError, message.tool != nil,
           statusLabel == "Running" || statusLabel == "Completed" {
            preview = ""
            previewHidden = false
        } else {
            var lines = output.components(separatedBy: "\n")
            // A terminal LF ends the last line; it is not another output line.
            if lines.last == "", !output.isEmpty { lines.removeLast() }
            let count = hasError ? 3 : 5
            let selected = (name == "bash" && !hasError ? Array(lines.suffix(count)) : Array(lines.prefix(count))).joined(separator: "\n")
            let limit = hasError ? 512 : 1_024
            preview = name == "bash" && !hasError ? Self.tail(selected, bytes: limit) : DisplayLimit.text(selected, bytes: limit)
            previewHidden = lines.count > count || selected.utf8.count > limit
        }
    }

    private static func legacyName(_ header: String) -> String? {
        for name in ["read", "bash", "write", "edit", "Tool"] {
            if header == name || header == name + " — Running" { return name }
        }
        return nil
    }

    private static func tail(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.suffix(bytes))
        // At most three leading bytes can belong to an incomplete UTF-8 scalar.
        for _ in 0..<4 {
            if let text = String(data: data, encoding: .utf8) { return text }
            if !data.isEmpty { data.removeFirst() }
        }
        return ""
    }
}
