import AppKit
import SwiftUI

/// Keeps the preferred width separate from SwiftUI's temporary split allocation.
struct MacSidebarWidthKeeper: NSViewRepresentable {
    @Binding var preferredWidth: Double

    func makeNSView(context: Context) -> Marker {
        Marker(preferredWidth: $preferredWidth)
    }

    func updateNSView(_ view: Marker, context: Context) {
        view.preferredWidth = $preferredWidth
        view.scheduleRestore()
    }

    static func dismantleNSView(_ view: Marker, coordinator: ()) {
        view.detach()
    }

    @MainActor final class Marker: NSView {
        var preferredWidth: Binding<Double>
        private weak var split: NSSplitView?
        private weak var pane: NSView?
        private(set) var eventMonitor: Any?
        private var restorePending = false
        private var needsRestore = true
        private var restoredMaximum: CGFloat?
        private var dividerDrag = false
        private var restoring = false

        init(preferredWidth: Binding<Double>) {
            self.preferredWidth = preferredWidth
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() }
            else { scheduleRestore() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleRestore()
        }

        override func layout() {
            super.layout()
            scheduleRestore()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            split = nil
            pane = nil
            dividerDrag = false
            needsRestore = true
            restoredMaximum = nil
        }

        func scheduleRestore() {
            guard !restorePending, window != nil else { return }
            restorePending = true
            // SwiftUI must finish adding the pane before a divider position is valid.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restorePending = false
                self.attachAndRestore()
            }
        }

        private func attachAndRestore() {
            guard window != nil else { return }
            var child: NSView = self
            var ancestor = superview
            while let view = ancestor {
                if let owner = view as? NSSplitView, owner.isVertical,
                   owner.arrangedSubviews.first === child {
                    if split !== owner || pane !== child {
                        detach()
                        split = owner
                        pane = child
                        NotificationCenter.default.addObserver(self, selector: #selector(resized),
                            name: NSSplitView.didResizeSubviewsNotification, object: owner)
                        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                            self?.observe(event)
                            return event
                        }
                    }
                    restoreIfNeeded()
                    return
                }
                child = view
                ancestor = view.superview
            }
        }

        private func restoreIfNeeded() {
            guard !dividerDrag, let split, let pane,
                  split.arrangedSubviews.first === pane, (2...3).contains(split.arrangedSubviews.count),
                  split.bounds.width > 0 else { return }
            // The existing layout has a 400-point main pane and an optional 260-point inspector.
            let otherMinimum: CGFloat = 400 + (split.arrangedSubviews.count > 2 ? 260 : 0)
            let maximum = min(320, split.bounds.width - otherMinimum
                - CGFloat(split.arrangedSubviews.count - 1) * split.dividerThickness)
            guard maximum >= 210, needsRestore || restoredMaximum != maximum else { return }
            let preferred = preferredWidth.wrappedValue
            let width = min(maximum, max(210, preferred.isFinite ? preferred : 240))
            restoring = true
            split.setPosition(width, ofDividerAt: 0)
            restoring = false
            needsRestore = false
            restoredMaximum = maximum
        }

        private func observe(_ event: NSEvent) {
            if event.type == .leftMouseUp {
                dividerDrag = false
                scheduleRestore()
                return
            }
            dividerDrag = false
            guard let split, event.window === window else { return }
            if event.type == .leftMouseDown {
                let point = split.convert(event.locationInWindow, from: nil)
                guard let pane, split.arrangedSubviews.first === pane else { return }
                let divider = NSRect(x: pane.frame.maxX - 2, y: split.bounds.minY,
                                     width: split.dividerThickness + 4, height: split.bounds.height)
                dividerDrag = divider.contains(point)
            }
        }

        @objc private func resized(_ notification: Notification) {
            guard !restoring else { return }
            scheduleRestore()
            guard dividerDrag, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
                  event.window === window, let pane else { return }
            let width = Double(pane.frame.width)
            let preferred = preferredWidth.wrappedValue
            guard width.isFinite, (210...320).contains(width),
                  !preferred.isFinite || abs(preferred - width) > 0.5 else { return }
            preferredWidth.wrappedValue = width
        }
    }
}
