import AppKit
import Foundation
import SwiftUI

/// Semantic app-only controls. This is not desktop input or arbitrary RPC access.
struct MacDebugInteraction: Codable, Sendable {
    let action: String
    let value: String

    func validate() throws {
        let values: [String: Set<String>] = [
            "navigate": ["conversation", "overview", "settings", "devices"],
            "interface_mode": ["pi", "desktop"],
            "sidebar": ["show", "hide"],
            "inspector": ["Files", "Session", "Activity", "hide"],
            "panel": ["commands", "resume", "palette", "hotkeys", "directory", "workspace", "close"],
            "focus_editor": ["editor"],
            "scroll": ["history_up", "history_down", "history_top", "history_bottom", "dock_up", "dock_down", "page_up", "page_down"]
        ]
        if action == "click" {
            guard MacDebugClickTarget(rawValue: value) != nil else { throw MacDebugServer.OperationError.invalidInteraction }
        } else if action == "type_text" {
            guard !value.isEmpty, value.utf8.count <= 2_048,
                  !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw MacDebugServer.OperationError.invalidInteraction
            }
        } else if values[action]?.contains(value) != true {
            throw MacDebugServer.OperationError.invalidInteraction
        }
    }
}

/// Attach inside a page row so only that page's enclosing scroll view is selected.
@MainActor struct MacDebugPageScrollMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.setAccessibilityElement(false)
        return probe
    }
    func updateNSView(_ view: Probe, context: Context) { view.register() }

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        override func layout() { super.layout(); register() }
        func register() { enclosingScrollView?.identifier = NSUserInterfaceItemIdentifier("pi-debug-page") }
    }
}

/// Mark only the app's ordinary panel content; native confirmation sheets have no marker.
@MainActor struct MacDebugPanelMarker: NSViewRepresentable {
    let panel: String
    func makeNSView(context: Context) -> Marker {
        let marker = Marker()
        marker.panel = panel
        marker.setAccessibilityElement(false)
        return marker
    }
    func updateNSView(_ view: Marker, context: Context) { view.panel = panel }
    final class Marker: NSView {
        var panel = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension MacDebugController {
    /// Checks and dispatch run together on MainActor. Cancellation after dispatch
    /// cannot undo an accepted native UI action.
    func interact(_ interaction: MacDebugInteraction, model: CompanionModel,
                  windows: [NSWindow]? = nil, appHidden: Bool? = nil,
                  modalWindow: NSWindow? = nil) throws -> Data {
        guard enabled, !model.shuttingDown, !Task.isCancelled else { throw MacDebugServer.OperationError.disabled }
        try interaction.validate()
        let windows = windows ?? NSApp.windows
        let closePanel = interaction.action == "panel" && interaction.value == "close"
        let safePanels: Set<String> = ["commands", "resume", "palette", "hotkeys", "directory", "workspace"]
        guard model.code.isEmpty, model.pending == nil, model.state.dialogs.isEmpty,
              model.editorOffer == nil, !model.confirmResend, !model.needsActionReview,
              !model.openingSession, model.closingSession == nil,
              (modalWindow ?? NSApp.modalWindow) == nil,
              model.panel == nil || (closePanel && safePanels.contains(model.panel!)) else {
            throw MacDebugServer.OperationError.interactionBlocked
        }
        let candidates = windows.filter { MacDebugWindowMarker.isAttached(to: $0) }
        guard candidates.count <= 1 else { throw MacDebugServer.OperationError.windowAmbiguous }
        guard let window = candidates.first, !(appHidden ?? NSApp.isHidden), window.isVisible,
              !window.isMiniaturized, let content = window.contentView else {
            throw MacDebugServer.OperationError.windowUnavailable
        }
        let ownsPanel = window.attachedSheet?.contentView.map { sheet in
            Self.descendants(sheet).contains {
                guard let marker = $0 as? MacDebugPanelMarker.Marker else { return false }
                return marker.panel == model.panel && safePanels.contains(marker.panel)
            }
        } ?? false
        guard (window.attachedSheet == nil || (closePanel && ownsPanel)),
              !windows.contains(where: { $0 !== window && $0 !== window.attachedSheet && $0.isVisible && ($0.canBecomeKey || $0 is NSPanel) }),
              window.attachedSheet?.attachedSheet == nil,
              !Self.hasSecureField(content),
              window.attachedSheet?.contentView.map({ !Self.hasSecureField($0) }) ?? true else {
            throw MacDebugServer.OperationError.interactionBlocked
        }
        switch interaction.action {
        case "navigate":
            switch interaction.value {
            case "conversation": model.destination = .conversation
            case "overview": model.destination = .overview
            case "settings": model.destination = .settings
            default: model.destination = .devices
            }
        case "interface_mode": model.interfaceMode = MacInterfaceMode(rawValue: interaction.value)!
        case "sidebar": model.sidebarVisible = interaction.value == "show"
        case "click":
            guard let target = MacDebugClickTarget(rawValue: interaction.value) else { throw MacDebugServer.OperationError.invalidInteraction }
            try MacDebugClick.press(target, in: window)
        case "inspector":
            if interaction.value == "hide" { model.inspectorVisible = false }
            else {
                guard model.hasInspectorContext,
                      let marker = Self.descendants(content).compactMap({ $0 as? MacDebugWindowMarker.Marker }).first,
                      let select = marker.selectInspector else { throw MacDebugServer.OperationError.targetUnavailable }
                select(interaction.value)
            }
        case "panel":
            if closePanel { model.panel = nil }
            else {
                guard !model.sending else { throw MacDebugServer.OperationError.interactionBlocked }
                if interaction.value == "resume" {
                    guard model.openNativeWorkflow(.resume) else { throw MacDebugServer.OperationError.interactionBlocked }
                } else {
                    guard !["directory", "workspace"].contains(interaction.value) || (!model.state.working && model.startupError == nil) else {
                        throw MacDebugServer.OperationError.interactionBlocked
                    }
                    model.panel = interaction.value
                }
            }
        case "type_text", "focus_editor":
            guard model.showingLoadedSession, model.state.selected != nil,
                  !["unavailable", "interrupted", "recovering", "starting", "stopping", "bash"].contains(model.state.phase),
                  let native = Self.descendants(content).compactMap({ $0 as? PiEditorNativeView }).first,
                  native.inputContextID == model.state.epoch.uuidString + (model.state.selected?.uuidString ?? "none"),
                  native.editor.string == model.text,
                  native.editor.isEditable, !native.editor.hasMarkedText(),
                  !native.isHiddenOrHasHiddenAncestor, !native.visibleRect.isEmpty,
                  window.makeFirstResponder(native.editor) else { throw MacDebugServer.OperationError.targetUnavailable }
            if interaction.action == "type_text" {
                // Append only. Never silently replace a selection or an existing draft.
                native.editor.insertText(interaction.value, replacementRange: NSRange(location: native.editor.string.utf16.count, length: 0))
            }
        case "scroll":
            let id: String
            if interaction.value.hasPrefix("history_") { id = "pi-debug-history" }
            else if interaction.value.hasPrefix("dock_") { id = "pi-debug-dock" }
            else { id = "pi-debug-page" }
            let matches = Self.descendants(content).compactMap { $0 as? NSScrollView }.filter {
                $0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }
            guard matches.count == 1, let scroll = matches.first, let document = scroll.documentView else {
                throw MacDebugServer.OperationError.targetUnavailable
            }
            let start = document.bounds.minY
            let end = max(start, document.bounds.maxY - scroll.contentView.bounds.height)
            let current = scroll.contentView.bounds.origin
            let down = interaction.value.hasSuffix("down")
            var y = current.y + (down ? 1 : -1) * max(1, scroll.contentView.bounds.height * 0.8)
            if interaction.value.hasSuffix("top") { y = start }
            if interaction.value.hasSuffix("bottom") { y = end }
            scroll.contentView.scroll(to: NSPoint(x: current.x, y: min(end, max(start, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        default: throw MacDebugServer.OperationError.invalidInteraction
        }
        return try JSONSerialization.data(withJSONObject: ["action": interaction.action, "outcome": "applied"])
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private static func hasSecureField(_ view: NSView) -> Bool {
        descendants(view).contains { $0 is NSSecureTextField && !$0.isHiddenOrHasHiddenAncestor }
    }
}
