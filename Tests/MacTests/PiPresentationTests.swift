import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class PiFixtureSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor final class PiPresentationTests: XCTestCase {
    func testShellPrefixesPreserveExactCommandAndContext() {
        let context = SessionContext(host: UUID(), epoch: UUID(), session: UUID())
        let single = PiShellOffer.parse("!printf 'hello'\n", context: context)
        XCTAssertEqual(single?.command, "printf 'hello'\n")
        XCTAssertEqual(single?.excludeFromContext, false)
        XCTAssertEqual(single?.context, context)
        XCTAssertEqual(PiShellOffer.parse("!!git status", context: context)?.excludeFromContext, true)
        XCTAssertNil(PiShellOffer.parse("Explain !git status", context: context))
    }

    func testPathCompletionSupportsUnicodeSpacesAndQuotedContinuation() throws {
        func query(_ text: String) throws -> PiPathQuery {
            try XCTUnwrap(PiPathQuery.parse(text: text, selection: NSRange(location: text.utf16.count, length: 0), directory: "/tmp/project"))
        }
        let relative = try query("Read @文")
        XCTAssertEqual(relative.directory, "/tmp/project")
        XCTAssertEqual(relative.prefix, "文")
        let item = DirectoryItem(id: UUID(), name: "文 file.swift", isDirectory: false)
        XCTAssertEqual(relative.replacement(item), "@\"文 file.swift\"")
        let quoted = try query("Read @\"folder name/fi\"")
        XCTAssertEqual(quoted.directory, "/tmp/project/folder name")
        XCTAssertEqual(quoted.prefix, "fi")
        XCTAssertEqual(quoted.replacement(item), "@\"folder name/文 file.swift\"")
        let absolute = try query("/tmp/fi")
        XCTAssertEqual(absolute.directory, "/tmp/")
        XCTAssertEqual(absolute.replacement(.init(id: UUID(), name: "files", isDirectory: true)), "/tmp/files/")
        XCTAssertNil(PiPathQuery.parse(text: "ordinary", selection: NSRange(location: 8, length: 0), directory: "/tmp"))
        XCTAssertNil(PiPathQuery.parse(text: "@file", selection: NSRange(location: 1, length: 2), directory: "/tmp"))
        XCTAssertNil(PiPathQuery.parse(text: "@😀", selection: NSRange(location: 2, length: 0), directory: "/tmp"))
        XCTAssertNil(PiPathQuery.parse(text: "Read @Sources/PiEditor.swift", selection: NSRange(location: 17, length: 0), directory: "/tmp"))
        XCTAssertNil(PiPathQuery.parse(text: "Read @\"folder name/file.swift\"", selection: NSRange(location: 24, length: 0), directory: "/tmp"))
    }

    func testStartupResourcesUseDiscoveredKindsWithoutGuessingContext() {
        let commands = [CommandOption(name: "skill:fixture-skill", detail: "", source: "skill"),
                        CommandOption(name: "review", detail: "", source: "prompt"),
                        CommandOption(name: "fixture-extension", detail: "", source: "extension"),
                        CommandOption(name: "skill:fixture-skill", detail: "duplicate", source: "skill"),
                        CommandOption(name: "", detail: "", source: "prompt")]
        XCTAssertEqual(PiStartupResources.names(source: "skill", commands: commands), ["fixture-skill"])
        XCTAssertEqual(PiStartupResources.names(source: "prompt", commands: commands), ["/review"])
    }

    func testFooterUsesRealContextWindowAndAutoCompactionWithoutInventingSubscription() throws {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.runtime = RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .oneAtATime, autoCompactionEnabled: true)
        let json = #"{"userMessages":0,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0,"contextUsage":{"tokens":0,"contextWindow":500000,"percent":0}}"#
        let stats = try JSONDecoder().decode(SessionStatistics.self, from: Data(json.utf8))
        XCTAssertEqual(PiFooterValue(state: state, statistics: stats).usage, "$0.000 0.0%/500k (auto)")
        XCTAssertFalse(PiFooterValue(state: state, statistics: stats).usage.contains("sub"))
    }

    func testBuiltinCommandParserDoesNotTreatAbsolutePathsAsCommands() {
        XCTAssertEqual(PiBuiltinCommand.parse(" /model ")?.name, "model")
        XCTAssertEqual(PiBuiltinCommand.parse("/name Saved name")?.arguments, "Saved name")
        XCTAssertNil(PiBuiltinCommand.parse("/tmp/project"))
        XCTAssertNil(PiBuiltinCommand.parse("Explain /model"))
        XCTAssertEqual(Set(PiBuiltinCommand.all.map(\.name)).count, PiBuiltinCommand.all.count)
    }

    func testFooterDoesNotInventUnavailableModelOrUsage() {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        let value = PiFooterValue(state: state, statistics: nil)
        XCTAssertEqual(value.model, "Model unavailable")
        XCTAssertEqual(value.usage, "Usage unavailable")
        XCTAssertEqual(value.phase, "No session")
        let id = UUID()
        state.sessions = [SessionInfo(id: id, title: "Fixture", directory: "/tmp/project")]
        state.selected = id; state.phase = "retrying"; state.model = "fixture/model"
        let active = PiFooterValue(state: state, statistics: nil)
        XCTAssertEqual(active.directory, "/tmp/project")
        XCTAssertEqual(active.model, "fixture/model")
        XCTAssertEqual(active.phase, "retrying")
    }

    func testNativePiSurfaceFixturesAndInputFailurePreserveDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.PiPresentation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: PiFixtureSecrets(), defaults: defaults)
        do {
            XCTAssertEqual(model.destination, .conversation)
            try await capture(PiConversationView(model: model, openControls: { _ in }), name: "startup", size: NSSize(width: 900, height: 600))
            let id = UUID()
            model.state.sessions = [SessionInfo(id: id, title: "Synthetic fixture", directory: "/tmp/pi-native-fixture")]
            model.state.selected = id
            for (name, phase) in [("retry", "retrying"), ("compaction", "compacting"), ("interrupted", "interrupted"), ("unavailable", "unavailable"), ("uncertain", "recovering")] {
                model.state.phase = phase
                try await capture(PiConversationView(model: model, openControls: { _ in }), name: name, size: NSSize(width: 900, height: 600))
            }
            model.state.phase = "working"; model.state.model = "fixture/model"; model.state.thinking = "medium"
            model.state.messages = [
                TranscriptMessage(role: "user", text: "Explain the fixture parser and add a focused test."),
                TranscriptMessage(role: "assistant", text: "## Parser review\nThe parser keeps Unicode paths intact.\n```swift\nlet path = \"/tmp/example\"\n```", thinking: "Inspect the bounded parser first."),
                TranscriptMessage(role: "tool", text: "read Tests/ParserTests.swift\n" + String(repeating: "fixture output\n", count: 100), streaming: true),
                TranscriptMessage(role: "assistant", text: "The focused check is running…", streaming: true)
            ]
            for width in [900, 1300] {
                try await capture(PiConversationView(model: model, openControls: { _ in }), name: "active-\(width)", size: NSSize(width: width, height: 700))
            }
            model.state.phase = "idle"
            try await capture(CompanionWindow(model: model), name: "root-idle", size: NSSize(width: 1100, height: 720))
            model.text = "/login"
            try await capture(PiConversationView(model: model, openControls: { _ in }), name: "unsupported-command", size: NSSize(width: 900, height: 600)) { host, window in
                let editor = try XCTUnwrap(self.subviews(host).compactMap { $0 as? PiEditorTextView }.first)
                window.makeFirstResponder(editor)
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                editor.keyDown(with: event)
                XCTAssertEqual(model.text, "/login")
                XCTAssertNotNil(model.composerError)
            }
        } catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    func testNativeSelectorsAndStandardDialogsNeverDispatchOnPresentation() async throws {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = UUID()
        state.models = [ModelOption(provider: "fixture", model: "model", name: "Fixture model")]
        state.thinkingLevels = ["off", "medium", "high"]
        var requests: [SessionAction] = []
        let request: (SessionAction) async throws -> AppResult = { action in requests.append(action); return .ok }
        for thinking in [false, true] {
            try await capture(PiConfigurationPicker(state: state, thinking: thinking, request: request, done: {}),
                              name: thinking ? "thinking-picker" : "model-picker", size: NSSize(width: 560, height: 440))
        }
        for method in ["select", "confirm", "input", "editor", "unknown"] {
            let dialog = ExtensionDialog(id: method, method: method, title: "Synthetic " + method, message: "Review this fixture request.", options: ["First choice", "Second choice"], text: "Fixture text", expires: nil)
            try await capture(PiExtensionDialog(dialog: dialog, request: request), name: "dialog-" + method, size: NSSize(width: 560, height: 440))
        }
        XCTAssertTrue(requests.isEmpty, "Rendering must never answer, approve or change a setting.")
    }

    func testShellWorkOffersCloseConsentAndSidebarPreferenceUsesPrivateDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.PiClose." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: PiFixtureSecrets(), defaults: defaults)
        let id = UUID()
        model.state.sessions = [SessionInfo(id: id, title: "Fixture", directory: "/tmp")]
        model.state.selected = id; model.state.phase = "bash"
        model.text = "Unsent draft"
        XCTAssertTrue(model.closeSessionRequiresConfirmation(id))
        XCTAssertNil(model.closeSessionDisabledReason(id))
        XCTAssertEqual(model.text, "Unsent draft")
        XCTAssertFalse(model.sidebarVisible)
        model.sidebarVisible = true
        XCTAssertTrue(defaults.bool(forKey: "piSidebarVisible"))
        await model.shutdown()
    }

    private func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }

    private func capture<V: View>(_ view: V, name: String, size: NSSize, inspect: ((NSView, NSWindow) throws -> Void)? = nil) async throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try inspect?(host, window)
        XCTAssertEqual(host.bounds.size.width, size.width, accuracy: 1)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let path = URL(fileURLWithPath: "/tmp/pi-like-mac-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try data.write(to: path.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
