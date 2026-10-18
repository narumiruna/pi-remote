import Foundation
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity
import XCTest

private final class ExecutableReadinessSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@MainActor final class MacExecutableReadinessTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Executable readiness did not arrive")
        throw RemoteFault.unavailable
    }

    private func withModel(_ body: @MainActor (CompanionModel, HostCoordinator, UserDefaults, URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/pi-mac-executable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-pi")
        let script = #"""
        #!/bin/sh
        root='ROOT'
        if [ "${1:-}" = --version ]; then
          [ ! -f "$root/fail-version" ] || exit 1
          printf '1.3.0\n'; exit 0
        fi
        streaming=false
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --session-dir) folder=$2; shift 2 ;;
            --session-id) session=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        file="$folder/$session.jsonl"
        printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
        reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | /usr/bin/plutil -extract id raw -o - -)
          command=$(printf '%s' "$line" | /usr/bin/plutil -extract type raw -o - -)
          case "$command" in
            get_state) reply "{\"sessionId\":\"$session\",\"sessionFile\":\"$file\",\"isStreaming\":$streaming,\"isCompacting\":false,\"pendingMessageCount\":0}" ;;
            get_available_models) reply '{"models":[]}' ;;
            get_available_thinking_levels) reply '{"levels":["off"]}' ;;
            get_commands) reply '{"commands":[]}' ;;
            get_messages) reply '{"messages":[]}' ;;
            prompt) streaming=true; printf '{"type":"agent_start"}\n'; reply '{}' ;;
            abort) streaming=false; reply '{}'; printf '{"type":"agent_settled"}\n' ;;
            *) reply '{}' ;;
          esac
        done
        """#.replacingOccurrences(of: "ROOT", with: root.path)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "PiRemote.ExecutableTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(executable.path, forKey: "piExecutable")
        let model = CompanionModel(support: root.appendingPathComponent("support"), secrets: ExecutableReadinessSecrets(),
                                   defaults: defaults, debugDirectory: root.appendingPathComponent("debug"))
        let host = try XCTUnwrap(model.coordinator)
        model.observe()
        do {
            try await wait { model.canChooseExecutable }
            try await body(model, host, defaults, root)
        } catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    func testCancelPreservesExecutableSessionAndDraft() async throws {
        try await withModel { model, host, defaults, _ in
            model.text = "Private draft"
            let before = await host.state()
            let path = model.piPath
            await model.chooseExecutable { nil }
            XCTAssertEqual(model.piPath, path)
            XCTAssertEqual(defaults.string(forKey: "piExecutable"), path)
            XCTAssertEqual(model.text, "Private draft")
            let after = await host.state()
            XCTAssertEqual(after, before)
            XCTAssertTrue(model.canChooseExecutable)
            XCTAssertFalse(model.selectingExecutable)
        }
    }

    func testIdleAndWorkingChildRequireCloseInsteadOfOnlyStopOrWait() async throws {
        try await withModel { model, host, _, root in
            let directory = try await host.directories.register(root)
            _ = try await model.request(.createSession(directory: directory))
            try await wait { model.executableSessionLoaded && model.state.phase == "idle" }
            XCTAssertFalse(model.canChooseExecutable)
            XCTAssertTrue(model.executableChangeGuidance.hasPrefix("Close the loaded Pi session"))
            var opened = false
            await model.chooseExecutable { opened = true; return nil }
            XCTAssertFalse(opened, "An idle child must not open the picker")
            let selected = model.state.selected
            _ = try await model.request(.prompt(text: "Private work", delivery: .prompt, image: nil))
            try await wait { model.state.working && model.executableSessionLoaded }
            XCTAssertTrue(model.executableChangeGuidance.hasPrefix("Close the loaded Pi session"))
            _ = try await model.request(.stop)
            try await wait { model.state.phase == "idle" }
            XCTAssertFalse(model.canChooseExecutable, "Stop must not be presented as executable recovery")
            XCTAssertEqual(model.state.selected, selected)
            _ = try await model.request(.closeSession)
            try await wait { model.canChooseExecutable && model.state.selected == nil }
            XCTAssertNil(model.state.selected)
        }
    }

    func testPickerOpenStartRaceCannotChangeOrPersistExecutable() async throws {
        try await withModel { model, host, defaults, root in
            let directory = try await host.directories.register(root)
            let path = model.piPath
            var selected: UUID?
            await model.chooseExecutable {
                _ = try? await model.request(.createSession(directory: directory))
                selected = await host.state().selected
                model.text = "Draft after explicit session creation"
                return root.appendingPathComponent("replacement-pi")
            }
            XCTAssertNotNil(selected)
            XCTAssertEqual(model.piPath, path)
            XCTAssertEqual(defaults.string(forKey: "piExecutable"), path)
            XCTAssertEqual(model.text, "Draft after explicit session creation")
            XCTAssertEqual(model.state.selected, selected)
            XCTAssertTrue(model.executableSelectionError?.contains("Close the loaded Pi session") == true)
            XCTAssertFalse(model.canChooseExecutable)
            _ = try await model.request(.closeSession)
            try await wait { model.canChooseExecutable }
            XCTAssertNil(model.executableSelectionError, "Resolved admission must not retain stale Close guidance")
        }
    }

    func testUnavailableSelectedMetadataAllowsExplicitRecoveryWithoutActivation() async throws {
        try await withModel { model, host, defaults, root in
            let directory = try await host.directories.register(root)
            _ = try await model.request(.createSession(directory: directory))
            let loaded = await host.state()
            let selected = try XCTUnwrap(loaded.selected)
            _ = try await model.request(.closeSession)
            try await wait { model.state.selected == nil && model.canChooseExecutable }
            try Data().write(to: root.appendingPathComponent("fail-version"))
            do { _ = try await model.request(.resumeSession(id: selected)); XCTFail("Version fixture must fail") }
            catch { XCTAssertEqual(error as? RemoteFault, .piLaunchFailed) }
            try await wait { model.state.phase == "unavailable" && model.canChooseExecutable }
            XCTAssertEqual(model.state.selected, selected)
            XCTAssertFalse(model.executableSessionLoaded)
            model.text = "Recovery draft"
            let before = await host.state()
            let replacement = root.appendingPathComponent("replacement-pi")
            await model.chooseExecutable { replacement }
            XCTAssertEqual(model.piPath, replacement.path)
            XCTAssertEqual(defaults.string(forKey: "piExecutable"), replacement.path)
            XCTAssertEqual(model.text, "Recovery draft")
            let after = await host.state()
            XCTAssertEqual(after, before, "Executable recovery must not activate or close saved metadata")
        }
    }

    func testChildFreeSelectionChangesOnlyExecutable() async throws {
        try await withModel { model, host, defaults, root in
            model.text = "Child-free recovery draft"
            let before = await host.state()
            let replacement = root.appendingPathComponent("replacement-pi")
            await model.chooseExecutable { replacement }
            XCTAssertEqual(model.piPath, replacement.path)
            XCTAssertEqual(defaults.string(forKey: "piExecutable"), replacement.path)
            XCTAssertEqual(model.text, "Child-free recovery draft")
            let after = await host.state()
            XCTAssertEqual(after, before)
            XCTAssertNil(after.selected)
            XCTAssertTrue(model.canChooseExecutable)
        }
    }

    func testPickerOpenShutdownRaceDoesNotPersistExecutable() async throws {
        try await withModel { model, host, defaults, root in
            let path = model.piPath
            model.text = "Shutdown draft"
            await model.chooseExecutable {
                await model.shutdown()
                return root.appendingPathComponent("replacement-pi")
            }
            XCTAssertEqual(model.piPath, path)
            XCTAssertEqual(defaults.string(forKey: "piExecutable"), path)
            XCTAssertEqual(model.text, "Shutdown draft")
            XCTAssertFalse(model.canChooseExecutable)
            let readiness = await host.executableChangeReadiness()
            XCTAssertEqual(readiness, .closing)
        }
    }

    func testCancelledSelectionTaskDoesNotCommitReturnedURL() async throws {
        try await withModel { model, host, defaults, root in
            let path = model.piPath
            let before = await host.state()
            model.text = "Cancelled selection draft"
            let selection = Task {
                await model.chooseExecutable {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return root.appendingPathComponent("replacement-pi")
                }
            }
            await selection.value
            XCTAssertEqual(model.piPath, path)
            XCTAssertEqual(defaults.string(forKey: "piExecutable"), path)
            XCTAssertEqual(model.text, "Cancelled selection draft")
            let after = await host.state()
            XCTAssertEqual(after, before)
            XCTAssertNil(model.executableSelectionError)
        }
    }
}
