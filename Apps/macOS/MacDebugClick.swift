import AppKit

/// Only ordinary controls reviewed for local presentation effects are callable.
enum MacDebugClickTarget: String, CaseIterable, Sendable {
    case sidebar = "mac-sidebar-toggle"
    case inspector = "mac-inspector-toggle"
    case files = "mac-files"
    case commands = "mac-commands"
    // Retired Desktop controls keep their input names for compatibility. Missing
    // visible targets remain unavailable; they are never redirected to another action.
    case composerCommands = "desktop-commands"
    case sessionControls = "desktop-session-controls"
    case welcomeFiles = "desktop-welcome-files"
    case welcomeCommands = "desktop-welcome-commands"
    case welcomeNewSession = "desktop-welcome-new-session"
    case welcomeResume = "desktop-welcome-resume"
    case latest = "pi-follow-latest"
    case refreshAddresses = "mac-refresh-addresses"
}

/// Resolve native buttons or accessibility elements inside one app-owned tree only.
/// No system Accessibility permission, desktop coordinates or arbitrary selectors.
@MainActor enum MacDebugClick {
    static func press(_ target: MacDebugClickTarget, in window: NSWindow) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        guard let content = window.contentView else { throw MacDebugServer.OperationError.targetUnavailable }
        let visible = window.convertToScreen(content.convert(content.visibleRect, to: nil))
        var stack: [(NSObject, Int, NSView)] = [(content, 0, content)]
        var visited = Set<ObjectIdentifier>()
        var candidates: [(element: NSObject, owner: NSView)] = []
        while let (object, depth, source) = stack.popLast() {
            let owner = object as? NSView ?? source
            try check(deadline)
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard visited.count <= 8_192, depth <= 128 else { throw MacDebugServer.OperationError.targetUnavailable }
            if object is NSWindow || boolean(object, "isAccessibilityHidden") { continue }
            if let view = object as? NSView {
                guard view.window === window, !view.isHiddenOrHasHiddenAncestor,
                      view === content || view.isDescendant(of: content) else { continue }
            }
            if string(object, "accessibilityIdentifier", legacy: "AXIdentifier") == target.rawValue {
                // AppKit can expose a button through its cell while its view reports AXUnknown.
                let button = object as? NSButton ?? (object as? NSCell)?.controlView as? NSButton
                let accessible = string(object, "accessibilityRole", legacy: "AXRole") == "AXButton"
                    && object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
                if button?.action != nil || accessible {
                    let candidate: NSObject = button ?? object
                    if !candidates.contains(where: { $0.element === candidate }) { candidates.append((candidate, owner)) }
                }
            }
            let views = (object as? NSView)?.subviews ?? []
            let children = value(object, "accessibilityChildren", legacy: "AXChildren") as? [NSObject] ?? []
            // Native accessors cannot be preempted. Check time/cancellation again after
            // each accessor returns and bound our own stack before expanding its result.
            try check(deadline)
            guard views.count + children.count <= 8_192 - stack.count else { throw MacDebugServer.OperationError.targetUnavailable }
            for child in views { stack.append((child, depth + 1, owner)) }
            for child in children { stack.append((child, depth + 1, owner)) }
        }
        guard candidates.count == 1, let candidate = candidates.first,
              boolean(candidate.element, "isAccessibilityEnabled"),
              let frame = frame(candidate.element), frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite), visible.contains(frame),
              try ownership(candidate.owner, frame: frame, content: content, window: window, deadline: deadline, requireVisibleElement: false) == .owned else {
            throw MacDebugServer.OperationError.targetUnavailable
        }
        let element: NSObject
        switch try ownership(candidate.element, frame: frame, content: content, window: window, deadline: deadline) {
        case .foreign: throw MacDebugServer.OperationError.targetUnavailable
        case .owned: element = candidate.element
        case .unknown:
            // SwiftUI can omit in-process AX parents. Require the content view's own
            // hit-test to resolve the same visible button instead of trusting its frame.
            guard let hit = content.accessibilityHitTest(NSPoint(x: frame.midX, y: frame.midY)) as? NSObject,
                  string(hit, "accessibilityIdentifier", legacy: "AXIdentifier") == target.rawValue,
                  string(hit, "accessibilityRole", legacy: "AXRole") == "AXButton",
                  boolean(hit, "isAccessibilityEnabled"), !boolean(hit, "isAccessibilityHidden"),
                  let hitFrame = self.frame(hit), visible.contains(hitFrame),
                  abs(hitFrame.minX - frame.minX) < 1, abs(hitFrame.minY - frame.minY) < 1,
                  abs(hitFrame.width - frame.width) < 1, abs(hitFrame.height - frame.height) < 1,
                  try ownership(hit, frame: hitFrame, content: content, window: window, deadline: deadline) != .foreign else {
                throw MacDebugServer.OperationError.targetUnavailable
            }
            element = hit
        }
        try check(deadline)
        if let button = element as? NSButton {
            guard button.isEnabled, button.action != nil else { throw MacDebugServer.OperationError.targetUnavailable }
            try check(deadline)
            button.performClick(nil)
        } else {
            guard boolean(element, "accessibilityPerformPress") else { throw MacDebugServer.OperationError.targetUnavailable }
        }
    }

    private enum Ownership { case owned, unknown, foreign }

    private static func ownership(_ element: NSObject, frame: NSRect, content: NSView,
                                  window: NSWindow, deadline: ContinuousClock.Instant, requireVisibleElement: Bool = true) throws -> Ownership {
        var current: NSObject? = element
        var visited = Set<ObjectIdentifier>()
        while let object = current {
            try check(deadline)
            guard visited.insert(ObjectIdentifier(object)).inserted, visited.count <= 128,
                  !boolean(object, "isAccessibilityHidden") else { return .foreign }
            if let owner = value(object, "accessibilityWindow", legacy: "AXWindow") as? NSWindow, owner !== window { return .foreign }
            if let ancestor = object as? NSWindow { return ancestor === window ? .owned : .foreign }
            if let cell = object as? NSCell, let control = cell.controlView { current = control; continue }
            if let view = object as? NSView {
                guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return .foreign }
                if requireVisibleElement, object === element, view.visibleRect.isEmpty { return .foreign }
                if view.clipsToBounds || view is NSClipView {
                    let clip = window.convertToScreen(view.convert(view.visibleRect, to: nil))
                    guard clip.contains(frame) else { return .foreign }
                }
                if view === content { return .owned }
                guard let parent = view.superview else { return .foreign }
                current = parent
            } else {
                // Inspect declared ancestry. Missing AX parents require the caller's
                // content-local hit-test proof, not merely an in-window frame.
                current = value(object, "accessibilityParent", legacy: "AXParent") as? NSObject
            }
        }
        return .unknown
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw MacDebugServer.OperationError.disabled }
        guard ContinuousClock.now < deadline else { throw MacDebugServer.OperationError.targetUnavailable }
    }

    private static func value(_ object: NSObject, _ name: String, legacy: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let fallback = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: fallback) else { return nil }
        return object.perform(fallback, with: legacy)?.takeUnretainedValue()
    }

    private static func string(_ object: NSObject, _ name: String, legacy: String) -> String? {
        value(object, name, legacy: legacy) as? String
    }

    private static func boolean(_ object: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }

    private static func frame(_ object: NSObject) -> NSRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return nil }
        typealias Method = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }
}
