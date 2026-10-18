import Foundation
import Testing
import PiRemoteCore
import PiRemoteHost

private struct ExecutableReadinessFixture {
    let root: URL
    let executable: URL
    let host: HostCoordinator
    let directory: UUID
    let device = UUID()

    init() async throws {
        root = URL(fileURLWithPath: "/private/tmp/pi-executable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        executable = root.appendingPathComponent("fake-pi")
        let script = #"""
        #!/bin/sh
        root='ROOT'
        hold() {
          if [ -f "$root/hold-$1" ]; then
            /usr/bin/touch "$root/pending-$1"
            while [ -f "$root/hold-$1" ]; do /bin/sleep 0.01; done
          fi
        }
        if [ "${1:-}" = --version ]; then
          hold version
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
            get_state)
              hold state
              reply "{\"sessionId\":\"$session\",\"sessionFile\":\"$file\",\"isStreaming\":$streaming,\"isCompacting\":false,\"pendingMessageCount\":0}" ;;
            get_available_models) reply '{"models":[]}' ;;
            get_available_thinking_levels) reply '{"levels":["off"]}' ;;
            get_commands) reply '{"commands":[]}' ;;
            get_messages) reply '{"messages":[]}' ;;
            prompt) streaming=true; printf '{"type":"agent_start"}\n'; reply '{}' ;;
            abort) hold stop; streaming=false; reply '{}'; printf '{"type":"agent_settled"}\n' ;;
            get_last_assistant_text) exit 0 ;;
            *) reply '{}' ;;
          esac
        done
        hold exit
        """#.replacingOccurrences(of: "ROOT", with: root.path)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
        directory = try await host.directories.register(root)
    }

    func send(_ action: SessionAction) async -> AppResult {
        await host.handle(AppRequest(epoch: host.epoch, session: host.state().selected, action: action), device: device)
    }

    func mark(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }
    func release(_ name: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent("hold-" + name)) }

    func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RemoteFault.unavailable
    }

    func pending(_ name: String) async throws {
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("pending-" + name).path) }
    }

    func cleanup() async {
        for name in ["version", "state", "stop", "exit"] { try? release(name) }
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

struct ExecutableReadinessTests {
    @Test(.timeLimit(.minutes(1))) func cancelledSetterCannotCommitAReplacement() async throws {
        let f = try await ExecutableReadinessFixture()
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await f.host.setExecutable(f.root.appendingPathComponent("missing-pi"))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await attempt.value)
        #expect(await f.host.executableChangeReadiness() == .ready)
        #expect(await f.send(.createSession(directory: f.directory)) == .ok,
                "A cancelled setter must retain the original executable")
        await f.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func idleWorkingAndStoppingRequireExplicitClose() async throws {
        let f = try await ExecutableReadinessFixture()
        do {
            #expect(await f.host.executableChangeReadiness() == .ready)
            #expect(await f.send(.createSession(directory: f.directory)) == .ok)
            let selected = await f.host.state().selected
            #expect(selected != nil)
            #expect(await f.host.executableChangeReadiness() == .sessionLoaded)
            await #expect(throws: RemoteFault.busy) { try await f.host.setExecutable(f.executable) }
            #expect(await f.send(.prompt(text: "Private fixture", delivery: .prompt, image: nil)) == .ok)
            #expect(await f.host.executableChangeReadiness() == .sessionLoaded)
            try f.mark("hold-stop")
            let stop = Task { await f.send(.stop) }
            try await f.pending("stop")
            #expect(await f.host.state().phase == "stopping")
            #expect(await f.host.executableChangeReadiness() == .busy)
            await #expect(throws: RemoteFault.busy) { try await f.host.setExecutable(f.executable) }
            try f.release("stop")
            #expect(await stop.value == .ok)
            #expect(await f.host.state().selected == selected)
            #expect(await f.host.executableChangeReadiness() == .sessionLoaded, "Stop does not close an idle child")
            #expect(await f.send(.closeSession) == .ok)
            #expect(await f.host.executableChangeReadiness() == .ready)
            try await f.host.setExecutable(f.executable)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func startupAndPickerOpenRacesRetainHostAdmission() async throws {
        let f = try await ExecutableReadinessFixture()
        do {
            #expect(await f.host.executableChangeReadiness() == .ready, "Picker preflight can succeed")
            try f.mark("hold-version"); try f.mark("hold-state")
            let start = Task { await f.send(.createSession(directory: f.directory)) }
            try await f.pending("version")
            #expect(await f.host.state().phase == "starting")
            #expect(await f.host.executableChangeReadiness() == .busy, "No child yet, but startup owns admission")
            await #expect(throws: RemoteFault.busy) { try await f.host.setExecutable(f.executable) }
            try f.release("version")
            try await f.pending("state")
            #expect(await f.host.state().phase == "starting")
            #expect(await f.host.executableChangeReadiness() == .busy, "Starting RPC child must not permit replacement")
            await #expect(throws: RemoteFault.busy) { try await f.host.setExecutable(f.executable) }
            #expect(await f.send(.stop) == .failure(.busy))
            try f.release("state")
            #expect(await start.value == .ok)
            #expect(await f.host.executableChangeReadiness() == .sessionLoaded)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func utilityCleanupAndShutdownPublishWithoutSnapshotInference() async throws {
        let f = try await ExecutableReadinessFixture()
        do {
            var updates = await f.host.executableChangeUpdates().makeAsyncIterator()
            #expect(await updates.next() == .ready)
            try f.mark("hold-version")
            let inspect = Task { await f.host.inspectPi() }
            try await f.pending("version")
            #expect(await updates.next() == .busy)
            await #expect(throws: RemoteFault.busy) { try await f.host.setExecutable(f.executable) }
            try f.release("version")
            await inspect.value
            #expect(await updates.next() == .ready, "Utility defer must restore admission even without another snapshot")
            let confirmation = try await f.host.quitConfirmation()
            try await f.host.reserveShutdown(confirmation: confirmation, confirmed: false)
            #expect(await updates.next() == .closing)
            #expect(await updates.next() == nil, "Shutdown must finish local readiness observation")
            var afterClosing = await f.host.executableChangeUpdates().makeAsyncIterator()
            #expect(await afterClosing.next() == .closing)
            #expect(await afterClosing.next() == nil)
            await #expect(throws: RemoteFault.busy) { try await f.host.setExecutable(f.executable) }
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func mutationBeforeUtilityOrChildStillBlocksReplacement() async throws {
        let f = try await ExecutableReadinessFixture()
        do {
            #expect(await f.send(.createSession(directory: f.directory)) == .ok)
            let next = f.root.appendingPathComponent("next")
            try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
            let directory = try await f.host.directories.register(next)
            try f.mark("hold-exit")
            let start = Task { await f.send(.createSession(directory: directory)) }
            try await f.pending("exit")
            #expect(await f.host.state().phase == "starting")
            #expect(await f.host.executableChangeReadiness() == .busy, "Previous child shutdown has no RPC reference or utility but still owns admission")
            await #expect(throws: RemoteFault.busy) { try await f.host.setExecutable(f.executable) }
            try f.release("exit")
            #expect(await start.value == .ok)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func cancelledObservationDoesNotRetainHost() async throws {
        var fixture: ExecutableReadinessFixture? = try await ExecutableReadinessFixture()
        weak var releasedHost = fixture?.host
        let stream = await fixture!.host.executableChangeUpdates()
        let observation = Task { for await _ in stream {} }
        observation.cancel()
        await observation.value
        await fixture!.cleanup()
        fixture = nil
        for _ in 0..<200 {
            if releasedHost == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(releasedHost == nil, "Cancelled readiness observation must not retain the host")
    }

    @Test(.timeLimit(.minutes(1))) func interruptedSelectedMetadataDoesNotBlockRecovery() async throws {
        let f = try await ExecutableReadinessFixture()
        do {
            #expect(await f.send(.createSession(directory: f.directory)) == .ok)
            let selected = await f.host.state().selected
            _ = await f.send(.lastAssistant)
            try await f.wait { await f.host.state().phase == "interrupted" }
            #expect(await f.host.state().selected == selected)
            #expect(await f.host.executableChangeReadiness() == .ready)
            try await f.host.setExecutable(f.executable)
            #expect(await f.host.state().selected == selected, "Recovery must not activate or close saved metadata")
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func unavailableSelectedMetadataDoesNotBlockRecovery() async throws {
        let f = try await ExecutableReadinessFixture()
        do {
            #expect(await f.send(.createSession(directory: f.directory)) == .ok)
            let selected = try #require(await f.host.state().selected)
            #expect(await f.send(.closeSession) == .ok)
            try f.mark("fail-version")
            #expect(await f.send(.resumeSession(id: selected)) == .failure(.piLaunchFailed))
            #expect(await f.host.state().phase == "unavailable")
            #expect(await f.host.state().selected == selected)
            #expect(await f.host.executableChangeReadiness() == .ready)
            try await f.host.setExecutable(f.executable)
            #expect(await f.host.state().selected == selected)
            #expect(await f.host.state().phase == "unavailable")
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }
}
