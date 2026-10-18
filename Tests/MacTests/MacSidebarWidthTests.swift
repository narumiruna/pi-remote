import AppKit
import Observation
import SwiftUI
import XCTest

@Observable @MainActor private final class SidebarFixtureState {
    var preferredWidth: Double {
        didSet {
            writes += 1
            preferences?.set(preferredWidth, forKey: "macWorkspaceSidebarWidth")
        }
    }
    var sidebarVisible = true
    var inspectorVisible = false
    var destination = 0
    var writes = 0
    private let preferences: UserDefaults?

    init(width: Double = 240, preferences: UserDefaults? = nil) {
        self.preferences = preferences
        preferredWidth = preferences?.object(forKey: "macWorkspaceSidebarWidth") as? Double ?? width
    }
}

/// Matches the existing split frames and priority without a model, Pi child or app preferences.
private struct SidebarFixtureRoot: View {
    @Bindable var state: SidebarFixtureState
    var legacyGeometrySaving = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Text("Toolbar").frame(height: 44)
                Divider()
                HSplitView {
                    if state.sidebarVisible {
                        if legacyGeometrySaving {
                            sidebar.frame(minWidth: 210, idealWidth: state.preferredWidth, maxWidth: 320)
                                .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
                                    if width >= 210, width <= 320, abs(state.preferredWidth - width) > 1 {
                                        state.preferredWidth = width
                                    }
                                }
                        } else {
                            sidebar.background(MacSidebarWidthKeeper(preferredWidth: $state.preferredWidth))
                                .frame(minWidth: 210, idealWidth: state.preferredWidth, maxWidth: 320)
                        }
                    }
                    VStack(spacing: 0) {
                        switch state.destination {
                        case 1: List { Text("Overview"); Text("Saved session") }
                        case 2: Form { Text("Settings"); Toggle("Fixture setting", isOn: .constant(false)) }
                        case 3: List { Text("Devices") }
                        default: Text("Conversation"); Spacer()
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity,
                           minHeight: max(0, geometry.size.height - 45), maxHeight: .infinity)
                    .layoutPriority(1)
                    if state.inspectorVisible {
                        Text("Inspector").frame(minWidth: 260, idealWidth: 320, maxWidth: 320)
                    }
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List { Text("Pi"); Text("Overview"); Text("Workspace") }.listStyle(.sidebar)
            Divider()
            List { Text("Devices"); Text("Settings") }.listStyle(.sidebar).frame(height: 116)
        }
    }
}

@MainActor final class MacSidebarWidthTests: XCTestCase {
    /// Before-fix evidence: a newly attached HSplitView sidebar starts at 210, not its ideal width.
    func testLegacyGeometrySavingReproduces235To210DriftAtFixedSize() throws {
        let state = SidebarFixtureState()
        try hosted(state, legacy: true) { host, window in
            let split = try self.split(in: host)
            try self.dragDivider(0, to: 235, in: split, window: window)
            self.settle(host)
            XCTAssertEqual(state.preferredWidth, 235, accuracy: 2)
            XCTAssertEqual(split.arrangedSubviews[0].frame.width, 235, accuracy: 2)
            let size = window.contentLayoutRect.size
            state.sidebarVisible = false
            self.settle(host)
            state.destination = 2
            state.sidebarVisible = true
            self.settle(host)
            XCTAssertEqual(window.contentLayoutRect.size, size)
            XCTAssertEqual(try self.split(in: host).arrangedSubviews[0].frame.width, 210, accuracy: 2)
            XCTAssertEqual(state.preferredWidth, 210, accuracy: 2)
        }
    }

    func testDefaultPreferredWidthRestoresWithoutWritingGeometry() throws {
        for size in [NSSize(width: 900, height: 600), NSSize(width: 1104, height: 829)] {
            let state = SidebarFixtureState()
            try hosted(state, size: size) { host, _ in
                XCTAssertEqual(try self.split(in: host).arrangedSubviews[0].frame.width, 240, accuracy: 2)
                XCTAssertEqual(state.preferredWidth, 240)
                XCTAssertEqual(state.writes, 0)
            }
        }
    }

    func testNativeDragSurvivesRepeatedToggleAndNavigationAtBothSizes() throws {
        for size in [NSSize(width: 900, height: 600), NSSize(width: 1104, height: 829)] {
            for inspector in [false, true] {
                let state = SidebarFixtureState()
                state.inspectorVisible = inspector
                try hosted(state, size: size) { host, window in
                    try self.dragDivider(0, to: 235, in: self.split(in: host), window: window)
                    self.settle(host)
                    XCTAssertEqual(state.preferredWidth, 235, accuracy: 2)
                    XCTAssertGreaterThan(state.writes, 0, "Native divider tracking must save the user's width.")
                    let writes = state.writes
                    let initialSize = window.contentLayoutRect.size
                    for destination in [1, 0, 2, 3, 0, 1] {
                        state.destination = destination
                        self.settle(host)
                        try self.checkPanes(host, width: 235, inspector: inspector)
                        state.sidebarVisible = false
                        self.settle(host)
                        state.destination = (destination + 1) % 4
                        state.sidebarVisible = true
                        self.settle(host)
                        try self.checkPanes(host, width: 235, inspector: inspector)
                        XCTAssertEqual(window.contentLayoutRect.size, initialSize)
                        XCTAssertEqual(state.preferredWidth, 235, accuracy: 2)
                        XCTAssertEqual(state.writes, writes, "Navigation must not save a layout allocation.")
                    }
                }
            }
        }
    }

    func testConstraintsAndProgrammaticResizeDoNotReplacePreferredWidth() throws {
        let state = SidebarFixtureState(width: 320)
        state.inspectorVisible = true
        try hosted(state) { host, window in
            try self.checkPanes(host, width: 320, inspector: true)
            let split = try self.split(in: host)
            split.setPosition(210, ofDividerAt: 0)
            self.settle(host)
            XCTAssertEqual(state.preferredWidth, 320)
            XCTAssertEqual(state.writes, 0)
            // Restore at the minimum size. 320 cannot fit with the other pane minimums.
            window.setContentSize(NSSize(width: 900, height: 600))
            self.settle(host)
            try self.checkPanes(host, width: 238, inspector: true)
            state.sidebarVisible = false
            self.settle(host)
            state.sidebarVisible = true
            self.settle(host)
            try self.checkPanes(host, width: 238, inspector: true)
            XCTAssertEqual(state.preferredWidth, 320)
            XCTAssertEqual(state.writes, 0)
            window.setContentSize(NSSize(width: 1104, height: 829))
            self.settle(host)
            try self.checkPanes(host, width: 320, inspector: true)
            state.sidebarVisible = false
            self.settle(host)
            state.sidebarVisible = true
            self.settle(host)
            try self.checkPanes(host, width: 320, inspector: true)
            XCTAssertEqual(state.preferredWidth, 320)
            XCTAssertEqual(state.writes, 0)
        }
    }

    func testInspectorConstraintsRestorePreferenceWhenInspectorLeaves() throws {
        let state = SidebarFixtureState(width: 320)
        try hosted(state, size: NSSize(width: 900, height: 600)) { host, _ in
            try self.checkPanes(host, width: 320, inspector: false)
            state.inspectorVisible = true
            self.settle(host)
            try self.checkPanes(host, width: 238, inspector: true)
            state.destination = 2
            self.settle(host)
            try self.checkPanes(host, width: 238, inspector: true)
            state.inspectorVisible = false
            self.settle(host)
            try self.checkPanes(host, width: 320, inspector: false)
            XCTAssertEqual(state.preferredWidth, 320)
            XCTAssertEqual(state.writes, 0)
        }
    }

    func testNativeDragKeepsBoundsAndIgnoresInspectorDivider() throws {
        let state = SidebarFixtureState()
        state.inspectorVisible = true
        try hosted(state) { host, window in
            let split = try self.split(in: host)
            for target: CGFloat in [180, 360, 275] {
                try self.dragDivider(0, to: target, in: split, window: window)
                self.settle(host)
                let width = split.arrangedSubviews[0].frame.width
                XCTAssertGreaterThanOrEqual(width, 210)
                XCTAssertLessThanOrEqual(width, 320)
                XCTAssertEqual(state.preferredWidth, width, accuracy: 2)
                try self.checkPanes(host, width: width, inspector: true)
            }
            let preferred = state.preferredWidth
            let writes = state.writes
            try self.dragDivider(1, to: 790, in: split, window: window)
            self.settle(host)
            XCTAssertEqual(state.preferredWidth, preferred)
            XCTAssertEqual(state.writes, writes)
        }
    }

    func testNewWindowRestoresNativeDragFromIsolatedPreferences() throws {
        let suite = "PiRemote.SidebarWidthTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = SidebarFixtureState(preferences: preferences)
        try hosted(first) { host, window in
            try self.dragDivider(0, to: 286, in: self.split(in: host), window: window)
            self.settle(host)
            XCTAssertEqual(first.preferredWidth, 286, accuracy: 2)
            XCTAssertEqual(preferences.double(forKey: "macWorkspaceSidebarWidth"), 286, accuracy: 2)
        }
        // New state and hosting tree; no static cache or production preference domain.
        let restarted = SidebarFixtureState(preferences: try XCTUnwrap(UserDefaults(suiteName: suite)))
        try hosted(restarted) { host, _ in
            XCTAssertEqual(restarted.preferredWidth, 286, accuracy: 2)
            XCTAssertEqual(try self.split(in: host).arrangedSubviews[0].frame.width, 286, accuracy: 2)
            XCTAssertEqual(restarted.writes, 0)
        }
    }

    func testMarkerRemovesTrackingOnHideAndWindowTeardown() throws {
        let state = SidebarFixtureState()
        var retainedMarker: MacSidebarWidthKeeper.Marker?
        try hosted(state) { host, window in
            let removed = try self.marker(in: host)
            XCTAssertNotNil(removed.eventMonitor)
            state.sidebarVisible = false
            self.settle(host)
            XCTAssertNil(removed.window)
            XCTAssertNil(removed.eventMonitor, "Removing a sidebar must remove its local event monitor.")
            state.sidebarVisible = true
            self.settle(host)
            let replacement = try self.marker(in: host)
            XCTAssertFalse(removed === replacement)
            XCTAssertNotNil(replacement.eventMonitor)
            try self.dragDivider(0, to: 275, in: self.split(in: host), window: window)
            self.settle(host)
            XCTAssertEqual(state.writes, 1, "Only the attached marker can write for one native drag event.")
            XCTAssertEqual(state.preferredWidth, 275, accuracy: 2)
            XCTAssertNil(removed.eventMonitor)
            retainedMarker = replacement
        }
        XCTAssertNil(retainedMarker?.window)
        XCTAssertNil(retainedMarker?.eventMonitor, "Closing the window must remove native event tracking.")
    }

    func testInvalidStoredWidthDoesNotEscapeBoundsOrWriteOnAttachment() throws {
        for width in [Double.nan, .infinity, 100, 500] {
            let state = SidebarFixtureState(width: width)
            try hosted(state) { host, window in
                let split = try self.split(in: host)
                let allocated = split.arrangedSubviews[0].frame.width
                XCTAssertGreaterThanOrEqual(allocated, 210)
                XCTAssertLessThanOrEqual(allocated, 320)
                XCTAssertEqual(state.writes, 0)
                try self.dragDivider(0, to: 275, in: split, window: window)
                self.settle(host)
                XCTAssertEqual(state.preferredWidth, 275, accuracy: 2)
                XCTAssertEqual(state.writes, 1)
            }
        }
    }

    private func checkPanes(_ host: NSView, width: CGFloat, inspector: Bool,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let split = try split(in: host)
        let panes = split.arrangedSubviews
        XCTAssertEqual(panes.count, inspector ? 3 : 2, file: file, line: line)
        XCTAssertEqual(panes[0].frame.width, width, accuracy: 2, file: file, line: line)
        XCTAssertGreaterThanOrEqual(panes[1].frame.width, 399.5, file: file, line: line)
        if inspector { XCTAssertGreaterThanOrEqual(panes[2].frame.width, 259.5, file: file, line: line) }
        for pane in panes {
            XCTAssertTrue(split.bounds.insetBy(dx: -0.5, dy: -0.5).contains(pane.frame), file: file, line: line)
        }
    }

    private func split(in root: NSView) throws -> NSSplitView {
        func find(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(root))
    }

    private func marker(in root: NSView) throws -> MacSidebarWidthKeeper.Marker {
        func find(_ view: NSView) -> MacSidebarWidthKeeper.Marker? {
            if let marker = view as? MacSidebarWidthKeeper.Marker { return marker }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(root))
    }

    /// Events stay in this process and name only the private fixture window. No desktop input API.
    private func dragDivider(_ index: Int, to position: CGFloat, in split: NSSplitView, window: NSWindow) throws {
        let start = split.convert(NSPoint(x: split.arrangedSubviews[index].frame.maxX + split.dividerThickness / 2,
                                         y: split.bounds.midY), to: nil)
        let end = split.convert(NSPoint(x: position + split.dividerThickness / 2, y: split.bounds.midY), to: nil)
        let entries: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)]
        for (index, entry) in entries.enumerated() {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: entry.0, location: entry.1, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: index + 1,
                clickCount: 1, pressure: entry.0 == .leftMouseUp ? 0 : 1))
            NSApp.postEvent(event, atStart: false)
        }
        // The native divider consumes drag/up in its tracking loop. Drain any unhandled fixture events.
        while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                                         until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }

    private func settle(_ host: NSView) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
    }

    private func hosted(_ state: SidebarFixtureState, size: NSSize = NSSize(width: 1104, height: 829),
                        legacy: Bool = false, exercise: (NSView, NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: SidebarFixtureRoot(state: state, legacyGeometrySaving: legacy))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        // AppKit does not route native divider tracking to an unordered window.
        window.orderFront(nil)
        settle(controller.view)
        try exercise(controller.view, window)
    }
}
