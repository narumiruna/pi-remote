import Foundation
import Testing
import PiRemoteCore
@testable import PiRemoteHost

private func displayEvent(_ method: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    .object(fields.merging(["type": .string("extension_ui_request"), "method": .string(method)]) { _, new in new })
}

@Test func extensionDisplayPlacementReplacementClearingAndNamespaces() throws {
    var metadata = ExtensionDisplayMetadata()
    try metadata.consume(displayEvent("setStatus", ["statusKey": .string("shared"), "statusText": .string("Status fixture")]))
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("shared"), "widgetLines": .array([.string("Widget fixture")])]))
    #expect(metadata.display(recovery: nil).widgets == [ExtensionWidget(id: "shared", text: "Widget fixture")])
    #expect(metadata.legacyNotices(recovery: nil) == ["Status fixture", "Widget fixture"])
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("shared"), "widgetLines": .array([.string("First"), .string("Second")]), "widgetPlacement": .string("belowEditor")]))
    #expect(metadata.display(recovery: nil).widgets == [ExtensionWidget(id: "shared", text: "First\nSecond", placement: .belowEditor)])
    #expect(metadata.display(recovery: nil).statuses == [ExtensionStatus(id: "shared", text: "Status fixture")])
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("shared"), "widgetLines": .array([.string("Back above")])]))
    #expect(metadata.display(recovery: nil).widgets.first?.placement == .aboveEditor)
    try metadata.consume(displayEvent("setStatus", ["statusKey": .string("shared")]))
    #expect(metadata.display(recovery: nil).statuses.isEmpty)
    #expect(metadata.display(recovery: nil).widgets.count == 1)
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("shared")]))
    #expect(metadata.legacyNotices(recovery: nil).isEmpty)

    for key in ["z", "a", "m"] {
        try metadata.consume(displayEvent("setStatus", ["statusKey": .string(key), "statusText": .string(key)]))
        try metadata.consume(displayEvent("setWidget", ["widgetKey": .string(key), "widgetLines": .array([.string(key)])]))
    }
    #expect(metadata.display(recovery: nil).statuses.map(\.id) == ["a", "m", "z"])
    #expect(metadata.display(recovery: nil).widgets.map(\.id) == ["a", "m", "z"])
    try metadata.consume(displayEvent("setStatus", ["statusKey": .string("a"), "statusText": .string("")]))
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("a"), "widgetLines": .array([])]))
    #expect(metadata.display(recovery: nil).statuses.map(\.id) == ["m", "z"])
    #expect(metadata.display(recovery: nil).widgets.map(\.id) == ["m", "z"])
}

@Test func extensionDisplayNoticeSeverityANSIAndLegacyStrings() throws {
    var metadata = ExtensionDisplayMetadata()
    let ansi = "\u{1B}[31mVisible\u{1B}[0m\u{1B}]52;c;private clipboard\u{07}\u{1B}]8;;https://example.invalid\u{1B}\\ link\u{1B}]8;;\u{1B}\\\u{00}\u{0D}\u{7F}\u{9B}2J\nNext\tline\u{1B}Pprivate payload\u{1B}\\\u{1B}(B\u{1B}["
    let visible = "Visible link\nNext\tline"
    try metadata.consume(displayEvent("setStatus", ["statusKey": .string("s"), "statusText": .string(ansi)]))
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("w"), "widgetLines": .array([.string(ansi)])]))
    try metadata.consume(displayEvent("notify", ["message": .string(ansi), "notifyType": .string("error")]))
    try metadata.consume(displayEvent("notify", ["message": .string("Warning"), "notifyType": .string("warning")]))
    try metadata.consume(displayEvent("notify", ["message": .string("Default")]))
    try metadata.consume(displayEvent("setTitle", ["title": .string("Window title")]))
    let state = metadata.display(recovery: "Recovery warning")
    #expect(state.statuses.first?.text == visible)
    #expect(state.widgets.first?.text == visible)
    #expect(state.notices.map(\.text) == ["Recovery warning", visible, "Warning", "Default", "Window title"])
    #expect(state.notices.map(\.severity) == [.warning, .error, .warning, .info, .info])
    #expect(Set(state.notices.map(\.id)).count == state.notices.count)
    #expect(metadata.legacyNotices(recovery: "Recovery warning") == ["Recovery warning", ansi, ansi, ansi, "Warning", "Default", "Window title"])
}

@Test func extensionDisplayBoundsKeepReplacementsAndLastEightNotices() throws {
    var metadata = ExtensionDisplayMetadata()
    let long = String(repeating: "界", count: 1_000)
    for index in 0..<8 {
        try metadata.consume(displayEvent("setStatus", ["statusKey": .string("s\(index)"), "statusText": .string(long)]))
        try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("w\(index)"), "widgetLines": .array([.string(long)])]))
    }
    #expect(throws: RemoteFault.capacity) { try metadata.consume(displayEvent("setStatus", ["statusKey": .string("extra"), "statusText": .string("overflow")])) }
    #expect(throws: RemoteFault.capacity) { try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("extra"), "widgetLines": .array([.string("overflow")])])) }
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("w0"), "widgetLines": .array([.string("Moved")]), "widgetPlacement": .string("belowEditor")]))
    #expect(metadata.display(recovery: nil).widgets.first?.placement == .belowEditor)
    for index in 0..<10 { try metadata.consume(displayEvent("notify", ["message": .string("\(index):" + long)])) }
    let state = metadata.display(recovery: nil)
    #expect(state.statuses.count + state.widgets.count == 16)
    #expect(state.notices.count == 8)
    #expect(state.notices.first?.text.hasPrefix("2:") == true)
    #expect(metadata.display(recovery: "Recovery").notices.count == 8)
    #expect(metadata.display(recovery: "Recovery").notices.first?.severity == .warning)
    #expect(state.statuses.allSatisfy { $0.text.utf8.count <= 2_048 })
    #expect(state.widgets.allSatisfy { $0.text.utf8.count <= 2_048 })
    #expect(state.notices.allSatisfy { $0.text.utf8.count <= 2_048 })
    try metadata.consume(displayEvent("setStatus", ["statusKey": .string("s0")]))
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("extra"), "widgetLines": .array([.string("Fits")])]))
    #expect(throws: RemoteFault.tooLarge) { try metadata.consume(displayEvent("setStatus", ["statusKey": .string(String(repeating: "k", count: 257))])) }
}

@Test func extensionDisplayMalformedValuesFailWithoutChangingDisplay() throws {
    var metadata = ExtensionDisplayMetadata()
    try metadata.consume(displayEvent("setWidget", ["widgetKey": .string("key"), "widgetLines": .array([.string("Retained")])]))
    let original = metadata.display(recovery: nil)
    let malformed: [JSONValue] = [
        displayEvent("setStatus", ["statusText": .string("Missing key")]),
        displayEvent("setStatus", ["statusKey": .number(1)]),
        displayEvent("setStatus", ["statusKey": .string("key"), "statusText": .bool(true)]),
        displayEvent("setStatus", ["statusKey": .string("key"), "statusText": .null]),
        displayEvent("setWidget", ["widgetKey": .string("key"), "widgetLines": .string("not lines")]),
        displayEvent("setWidget", ["widgetKey": .string("key"), "widgetLines": .array([.string("valid"), .number(1)])]),
        displayEvent("setWidget", ["widgetKey": .string("key"), "widgetLines": .null]),
        displayEvent("setWidget", ["widgetKey": .string("key"), "widgetPlacement": .string("sideways")]),
        displayEvent("setWidget", ["widgetKey": .string("key"), "widgetPlacement": .number(1)]),
        displayEvent("notify", ["message": .string("Bad severity"), "notifyType": .string("critical")]),
        displayEvent("notify", ["message": .number(1)]),
        displayEvent("setTitle", ["title": .bool(false)])
    ]
    for event in malformed {
        #expect(throws: RemoteFault.incompatiblePi) { try metadata.consume(event) }
        #expect(metadata.display(recovery: nil) == original)
    }
    #expect(throws: RemoteFault.unsupportedFeature) { try metadata.consume(displayEvent("future-interactive-method", ["message": .string("Do not approve")])) }
    #expect(metadata.display(recovery: nil) == original)
}

@Test(.timeLimit(.minutes(1))) func extensionDisplayHostLifecycleResetsAndTransitionPlacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-display-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    var script = try String(contentsOf: executable, encoding: .utf8)
    script = script.replacingOccurrences(of: "        prompt)\n", with: "        prompt)\n            case \"$line\" in *'/metadata display'*) /bin/cat \"$PWD/display-events\"; reply '{\"disposition\":\"handled\"}'; continue ;; *'/metadata crash-display'*) exit 0 ;; esac\n")
    // This hook runs during same-child context replacement and must retain placement and severity.
    script = script.replacingOccurrences(of: "            reply '{\"cancelled\":false}' ;;", with: "            /bin/cat \"$PWD/transition-events\"\n            reply '{\"cancelled\":false}' ;;")
    try script.write(to: executable, atomically: true, encoding: .utf8)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    let device = UUID(), directory = try await host.directories.register(root)
    func send(_ action: SessionAction) async -> AppResult {
        await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: action), device: device)
    }
    func writeEvents(_ events: [JSONValue], name: String) throws {
        let data = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n" }.joined()
        try data.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let metadata = [
        displayEvent("setStatus", ["statusKey": .string("shared"), "statusText": .string("Status fixture")]),
        displayEvent("setWidget", ["widgetKey": .string("shared"), "widgetLines": .array([.string("Widget fixture")])]),
        displayEvent("notify", ["message": .string("Error fixture"), "notifyType": .string("error")])
    ]
    try writeEvents(metadata, name: "display-events")
    try writeEvents([], name: "transition-events")
    do {
        #expect(await send(.createSession(directory: directory)) == .ok)
        let first = try #require(await host.state().selected)
        #expect(await send(.command(name: "metadata", arguments: "display")) == .ok)
        try await waitForDisplay(host) { $0.extensionDisplay?.notices.first?.severity == .error }
        #expect(await host.state().notices == ["Status fixture", "Widget fixture", "Error fixture"])
        let replacement = await send(.newSession(parent: false))
        #expect(replacement == .ok)
        #expect(await host.state().extensionDisplay == nil)
        #expect(await host.state().notices.isEmpty)
        #expect(await send(.command(name: "metadata", arguments: "display")) == .ok)
        try await waitForDisplay(host) { $0.extensionDisplay?.statuses.count == 1 }
        #expect(await send(.resumeSession(id: first)) == .ok)
        #expect(await host.state().extensionDisplay == nil)

        try writeEvents([
            displayEvent("setWidget", ["widgetKey": .string("transition"), "widgetLines": .array([.string("Below")]), "widgetPlacement": .string("belowEditor")]),
            displayEvent("notify", ["message": .string("Transition error"), "notifyType": .string("error")])
        ], name: "transition-events")
        #expect(await send(.newSession(parent: false)) == .ok)
        try await waitForDisplay(host) { $0.extensionDisplay?.widgets.first?.placement == .belowEditor && $0.extensionDisplay?.notices.first?.severity == .error }
        #expect(await send(.closeSession) == .ok)
        #expect(await host.state().extensionDisplay == nil)
        #expect(await host.state().notices.isEmpty)
        #expect(await send(.resumeSession(id: first)) == .ok)
        #expect(await host.state().extensionDisplay == nil)
        #expect(await send(.command(name: "metadata", arguments: "display")) == .ok)
        try await waitForDisplay(host) { $0.extensionDisplay?.statuses.count == 1 }
        try writeEvents([displayEvent("setWidget", ["widgetKey": .string("shared"), "widgetLines": .array([.string("Invalid")]), "widgetPlacement": .string("sideways")])], name: "display-events")
        #expect(await send(.command(name: "metadata", arguments: "display")) == .ok)
        try await waitForDisplay(host) { $0.error == .incompatiblePi }
        #expect(await host.state().extensionDisplay?.widgets.first?.text == "Widget fixture")
        try writeEvents([displayEvent("unknown-dialog", ["message": .string("Do not approve")])], name: "display-events")
        #expect(await send(.command(name: "metadata", arguments: "display")) == .ok)
        try await waitForDisplay(host) { $0.error == .unsupportedFeature }
        #expect(await host.state().dialogs.isEmpty)
        #expect(await !host.state().notices.contains("Do not approve"))
        #expect(await send(.command(name: "metadata", arguments: "crash-display")) == .failure(.unknownOutcome))
        try await waitForDisplay(host) { $0.extensionDisplay?.statuses.isEmpty != false && $0.extensionDisplay?.widgets.isEmpty != false }
        #expect(await !host.state().notices.contains("Widget fixture"))
        #expect(await send(.resumeSession(id: first)) == .ok)
        try writeEvents(metadata, name: "display-events")
        #expect(await send(.command(name: "metadata", arguments: "display")) == .ok)
        try await waitForDisplay(host) { $0.extensionDisplay?.statuses.count == 1 }
        await host.shutdown()
        #expect(await host.state().extensionDisplay == nil)
        #expect(await host.state().notices.isEmpty)
    } catch { await host.shutdown(); throw error }
}

private func waitForDisplay(_ host: HostCoordinator, _ predicate: (HostSnapshot) -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate(host.state()) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteFault.unavailable
}
