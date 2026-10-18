import AppKit
import Observation
import PiRemoteCore
import SwiftUI
import XCTest

@MainActor private struct ToolAccessibility {
    let object: NSObject

    func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    func press() -> Bool {
        if let button = object as? NSButton {
            guard button.isEnabled else { return false }
            button.performClick(nil)
            return true
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
    }
}

@Observable @MainActor private final class ToolRowFixtureState {
    var message: TranscriptMessage
    var expandTools = false
    init(_ message: TranscriptMessage) { self.message = message }
}

@MainActor private struct ToolRowFixture: View {
    let state: ToolRowFixtureState
    let disclosure: (UUID, CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 23)
            PiToolRow(message: state.message, expandTools: state.expandTools, onDisclosure: disclosure)
            Spacer(minLength: 0)
        }.frame(width: 640, height: 450).coordinateSpace(name: "pi-surface-viewport")
    }
}

@MainActor final class PiToolRowTests: XCTestCase {
    func testAuthoritativeStatesAndLegacyOutcomeDoNotInventSuccess() {
        for (status, label) in [(TranscriptToolStatus.running, "Running"), (.completed, "Completed"), (.failed, "Failed"), (.interrupted, "Interrupted")] {
            let value = PiToolRowValue(message("bash\nresult", name: "bash", status: status))
            XCTAssertEqual(value.statusLabel, label)
            XCTAssertEqual(value.hasError, status == .failed)
            XCTAssertEqual(value.action, "Run")
            XCTAssertEqual(value.systemImage, "terminal")
        }
        XCTAssertEqual(PiToolRowValue(TranscriptMessage(role: "tool", text: "bash\nresult")).statusLabel, "Output")
        XCTAssertEqual(PiToolRowValue(TranscriptMessage(role: "tool", text: "bash — Running", streaming: true)).statusLabel, "Running")
        XCTAssertEqual(PiToolRowValue(TranscriptMessage(role: "tool", text: "legacy failure", isError: true)).statusLabel, "Failed")
        let interruptedError = PiToolRowValue(message("read\nfailure", name: "read", status: .interrupted, isError: true))
        XCTAssertEqual(interruptedError.statusLabel, "Interrupted")
        XCTAssertEqual(interruptedError.preview, "failure")
    }

    func testRuntimeInterruptionOverridesUnfinishedHeadingsButNotKnownResults() {
        let running = message("read\nPartial output", name: "read", status: .running)
        for phase in ["interrupted", "unavailable"] {
            let value = PiToolRowValue(running, runtimePhase: phase)
            XCTAssertEqual(value.statusLabel, "Interrupted")
            XCTAssertEqual(value.preview, "Partial output")
            XCTAssertTrue(value.requiresAttention)
        }
        XCTAssertEqual(PiToolRowValue(running, runtimePhase: "recovering").statusLabel, "Unconfirmed")
        XCTAssertEqual(PiToolRowValue(running, runtimePhase: "working").statusLabel, "Running")
        let partialError = message("read\nRetrying after an error", name: "read", status: .running, isError: true)
        XCTAssertEqual(PiToolRowValue(partialError, runtimePhase: "working").statusLabel, "Running")
        XCTAssertEqual(PiToolRowValue(partialError, runtimePhase: "working").preview, "Retrying after an error")
        XCTAssertEqual(PiToolRowValue(message("read\nSaved output", name: "read", status: .completed), runtimePhase: "interrupted").statusLabel, "Completed")
        XCTAssertEqual(PiToolRowValue(message("read\nFailure", name: "read", status: .completed, isError: true)).statusLabel, "Failed")
        XCTAssertEqual(PiToolRowValue(TranscriptMessage(role: "tool", text: "read\nPartial output", streaming: true), runtimePhase: "interrupted").statusLabel, "Interrupted")
    }

    func testReadPreviewHidesKnownNonerrorButKeepsFailedInterruptedAndLegacyOutput() {
        for status in [TranscriptToolStatus.running, .completed] {
            let value = PiToolRowValue(message("read\nfile contents", name: "read", status: status))
            XCTAssertEqual(value.preview, "")
            XCTAssertFalse(value.previewHidden)
            XCTAssertEqual(value.expandedOutput, "read\nfile contents")
        }
        for status in [TranscriptToolStatus.failed, .interrupted] {
            XCTAssertEqual(PiToolRowValue(message("read\nRead did not finish", name: "read", status: status)).preview, "Read did not finish")
        }
        let legacy = PiToolRowValue(TranscriptMessage(role: "tool", text: "read\nUnconfirmed output"))
        XCTAssertEqual(legacy.preview, "Unconfirmed output")
        XCTAssertEqual(legacy.statusLabel, "Output")
        XCTAssertEqual(PiToolRowValue(message("read\nPermission denied", name: "read", isError: true)).preview, "Permission denied")
    }

    func testBashShowsLastFiveLinesDuringLiveAndFinalUpdates() {
        let text = "bash\n" + (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        for status in [TranscriptToolStatus.running, .completed, .interrupted] {
            let value = PiToolRowValue(message(text, name: "bash", status: status))
            XCTAssertEqual(value.preview, (8...12).map { "line \($0)" }.joined(separator: "\n"))
            XCTAssertTrue(value.previewHidden)
            XCTAssertEqual(value.expandedOutput, text)
        }
        let short = PiToolRowValue(message("bash\none\ntwo\n", name: "bash"))
        XCTAssertEqual(short.preview, "one\ntwo")
        XCTAssertFalse(short.previewHidden)
    }

    func testCompactPreviewsAndErrorExcerptsHaveByteAndLineBounds() {
        let lines = (1...40).map { "line \($0)" }.joined(separator: "\n")
        for name in ["write", "edit", "custom"] {
            let value = PiToolRowValue(message(name + "\n" + lines, name: name))
            XCTAssertEqual(value.preview, (1...5).map { "line \($0)" }.joined(separator: "\n"))
            XCTAssertTrue(value.previewHidden)
            let long = PiToolRowValue(message(name + "\n" + String(repeating: "x", count: 10_000), name: name))
            XCTAssertEqual(long.preview.utf8.count, 1_024)
            XCTAssertTrue(long.previewHidden)
        }
        let failure = PiToolRowValue(message("bash\n" + lines, name: "bash", status: .failed))
        XCTAssertEqual(failure.preview, "line 1\nline 2\nline 3")
        XCTAssertTrue(failure.previewHidden)
        let longFailure = PiToolRowValue(message("read\n" + String(repeating: "x", count: 4_000), name: "read", status: .failed))
        XCTAssertEqual(longFailure.preview.utf8.count, 512)
        XCTAssertTrue(longFailure.previewHidden)
    }

    func testUnicodeBoundsKeepValidExactPrefixesAndTails() {
        let output = String(repeating: "文😀e\u{301}", count: 1_000)
        for name in ["bash", "edit"] {
            let value = PiToolRowValue(message(name + "\n" + output, name: name))
            XCTAssertLessThanOrEqual(value.preview.utf8.count, 1_024)
            XCTAssertFalse(value.preview.contains("\u{FFFD}"))
            XCTAssertEqual(String(data: Data(value.preview.utf8), encoding: .utf8), value.preview)
            if name == "bash" { XCTAssertTrue(output.hasSuffix(value.preview)) }
            else { XCTAssertTrue(output.hasPrefix(value.preview)) }
            XCTAssertEqual(value.expandedOutput, name + "\n" + output)
        }
        let failure = PiToolRowValue(message("read\n" + output, name: "read", status: .failed))
        XCTAssertLessThanOrEqual(failure.preview.utf8.count, 512)
        XCTAssertTrue(output.hasPrefix(failure.preview))
    }

    func testUnknownAndAmbiguousHeadersRemainOutputAndTargetsStayExact() {
        for text in ["Unknown output\nsecond line", "read /tmp/file\npossibly ordinary output", "\nleading empty line", "READ\ncase is not metadata"] {
            let value = PiToolRowValue(TranscriptMessage(role: "tool", text: text))
            XCTAssertEqual(value.preview, text)
            XCTAssertEqual(value.expandedOutput, text)
            XCTAssertEqual(value.action, "Tool")
            XCTAssertNil(value.target)
        }
        let target = "/tmp/文 folder/$(not-executed); [x](https://invalid.example)"
        let value = PiToolRowValue(message("custom\nOutput", name: "custom", target: target))
        XCTAssertEqual(value.target, target)
        XCTAssertEqual(value.accessibilityHeading, "custom, " + target + ", Completed")
        XCTAssertEqual(value.preview, "Output")
        // Metadata does not authorize dropping a different first output line.
        XCTAssertEqual(PiToolRowValue(message("important first line\nnext", name: "custom")).preview, "important first line\nnext")
    }

    func testEditDiffRemainsExactPlainTextWithoutGuessingLineRoles() {
        let diff = "edit\n--- a/文.swift\n+++ b/文.swift\n@@ -1 +1 @@\n-old\n+new\n context\n+not necessarily a diff outside a hunk\n"
        let value = PiToolRowValue(message(diff, name: "edit"))
        XCTAssertEqual(value.expandedOutput, diff)
        XCTAssertEqual(value.preview, "--- a/文.swift\n+++ b/文.swift\n@@ -1 +1 @@\n-old\n+new")
        XCTAssertTrue(value.previewHidden)
        let ordinary = "edit\n+++ this is not a file header\n-negative number\n+ordinary text"
        XCTAssertEqual(PiToolRowValue(message(ordinary, name: "edit")).expandedOutput, ordinary)
    }

    func testEmptyOutputDoesNotCreatePreviewOrOmissionNotice() {
        for name in ["read", "bash", "edit", "write", "custom"] {
            for text in [name, name + "\n"] {
                let value = PiToolRowValue(message(text, name: name))
                XCTAssertEqual(value.preview, "")
                XCTAssertFalse(value.previewHidden)
                XCTAssertEqual(value.expandedOutput, text)
            }
        }
    }

    func testNativeDisclosurePreservesExplicitChoiceAcrossStreamingAndGlobalChanges() async throws {
        let target = "/tmp/文 folder/file.swift"
        let state = ToolRowFixtureState(message("bash\nfirst", name: "bash", target: target, status: .running))
        let id = state.message.id
        var calls: [(UUID, CGFloat)] = []
        var valuesBeforeToggle: [String] = []
        var root: NSView?
        let fixture = ToolRowFixture(state: state) { messageID, y in
            calls.append((messageID, y))
            if let root, let heading = self.heading(in: root, id: id) {
                valuesBeforeToggle.append(heading.value("accessibilityValue") as? String ?? "")
            }
        }
        try await hosted(fixture) { host in
            root = host
            let initial = try XCTUnwrap(self.heading(in: host, id: id))
            XCTAssertEqual(initial.value("accessibilityLabel") as? String, "Run, " + target + ", Running")
            XCTAssertEqual(initial.value("accessibilityValue") as? String, "Collapsed")
            XCTAssertTrue(initial.press())
            try await self.settle(host)
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].0, id)
            XCTAssertEqual(calls[0].1, 28, accuracy: 1)
            XCTAssertEqual(valuesBeforeToggle, ["Collapsed"], "The parent must receive geometry before row expansion changes.")
            try self.assertExpanded(true, in: host, id: id)

            state.message.text = "bash\nfirst\nsecond"
            try await self.settle(host)
            try self.assertExpanded(true, in: host, id: id)
            state.message.streaming = false
            state.message.tool?.status = .completed
            try await self.settle(host)
            try self.assertExpanded(true, in: host, id: id)
            XCTAssertEqual(self.heading(in: host, id: id)?.value("accessibilityLabel") as? String, "Run, " + target + ", Completed")

            state.expandTools = true
            try await self.settle(host)
            try self.assertExpanded(true, in: host, id: id)
            XCTAssertTrue(try XCTUnwrap(self.heading(in: host, id: id)).press())
            try await self.settle(host)
            try self.assertExpanded(false, in: host, id: id)
            state.message.text += "\nlate update"
            try await self.settle(host)
            try self.assertExpanded(false, in: host, id: id)
            XCTAssertEqual(calls.count, 2, "Streaming and global settings must not dispatch row disclosure.")
            XCTAssertEqual(valuesBeforeToggle, ["Collapsed", "Expanded"])

            state.expandTools = false
            try await self.settle(host)
            try self.assertExpanded(false, in: host, id: id)
            state.expandTools = true
            try await self.settle(host)
            try self.assertExpanded(true, in: host, id: id)
        }
    }

    func testFailedNativeHeadingAndCollapsedExcerptRemainAccessible() async throws {
        let state = ToolRowFixtureState(message("read\nPermission denied", name: "read", target: "/tmp/denied", status: .failed))
        try await hosted(ToolRowFixture(state: state, disclosure: { _, _ in })) { host in
            let heading = try XCTUnwrap(self.heading(in: host, id: state.message.id))
            XCTAssertEqual(heading.value("accessibilityLabel") as? String, "Read, /tmp/denied, Failed")
            XCTAssertEqual(heading.value("accessibilityValue") as? String, "Collapsed")
            XCTAssertTrue(self.elements(in: host).contains {
                ($0.value("accessibilityValue") as? String) == "Permission denied" ||
                ($0.value("accessibilityLabel") as? String) == "Permission denied"
            })
        }
    }

    private func message(_ text: String, name: String, target: String? = nil, status: TranscriptToolStatus = .completed, isError: Bool = false) -> TranscriptMessage {
        TranscriptMessage(role: "tool", text: text, isError: isError, streaming: status == .running,
                          tool: TranscriptTool(name: name, target: target, status: status))
    }

    private func elements(in root: NSView) -> [ToolAccessibility] {
        var visited = Set<ObjectIdentifier>()
        var result: [ToolAccessibility] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let element = ToolAccessibility(object: object)
            result.append(element)
            for child in element.value("accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return result
    }

    private func heading(in root: NSView, id: UUID) -> ToolAccessibility? {
        elements(in: root).first { $0.value("accessibilityIdentifier") as? String == "pi-tool-toggle-" + id.uuidString }
    }

    private func assertExpanded(_ expanded: Bool, in root: NSView, id: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
        let heading = try XCTUnwrap(heading(in: root, id: id), file: file, line: line)
        XCTAssertEqual(heading.value("accessibilityValue") as? String, expanded ? "Expanded" : "Collapsed", file: file, line: line)
    }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
    }

    private func hosted<V: View>(_ view: V, exercise: (NSView) async throws -> Void) async throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        try await exercise(host)
    }
}
