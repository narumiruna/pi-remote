import Foundation
import Testing
import PiRemoteCore
import PiRemoteHost

private struct BashFixture {
    let root: URL
    let host: HostCoordinator
    let device = UUID()
    let directory: UUID

    init(installed: String? = nil) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-shell-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("pi")
        let script: String
        if let installed {
            func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            script = """
            #!/bin/sh
            exec /usr/bin/env -i HOME=\(quote(root.path)) PATH="${PATH:-/usr/bin:/bin}" TMPDIR=\(quote(root.path)) PI_CODING_AGENT_DIR=\(quote(root.appendingPathComponent("agent").path)) PI_TELEMETRY=0 \(quote(installed)) --offline --no-extensions --no-mcp --no-skills --no-prompt-templates --no-context-files --no-tools --provider openai --model gpt-4o "$@"
            """
        } else {
            script = #"""
            #!/bin/sh
            if [ "${1:-}" = --version ]; then printf '1.3.0\n'; exit 0; fi
            root='ROOT'; bashid=''; file=''
            while [ "$#" -gt 0 ]; do
              case "$1" in --session-dir) folder=$2; shift 2 ;; --session-id) session=$2; shift 2 ;; --session) file=$2; shift 2 ;; *) shift ;; esac
            done
            if [ -n "$file" ]; then session=$(/usr/bin/head -n 1 "$file" | /usr/bin/plutil -extract id raw -o - -)
            else file="$folder/$session.jsonl"; fi
            reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
            finish() { printf '{"id":"%s","type":"response","command":"bash","success":true,"data":{"output":"final","exitCode":%s,"cancelled":%s,"truncated":false}}\n' "$bashid" "$1" "$2"; bashid=''; }
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | /usr/bin/plutil -extract id raw -o - -)
              command=$(printf '%s' "$line" | /usr/bin/plutil -extract type raw -o - -)
              printf '%s\n' "$line" >> "$root/requests"
              case "$command" in
                get_state)
                  if [ -f "$root/hold-state" ]; then
                    /usr/bin/touch "$root/state-pending"
                    while [ -f "$root/hold-state" ]; do /bin/sleep 0.01; done
                  fi
                  reply "{\"sessionId\":\"$session\",\"sessionFile\":\"$file\",\"isStreaming\":false,\"isCompacting\":false,\"pendingMessageCount\":0,\"thinkingLevel\":\"off\",\"steeringMode\":\"one-at-a-time\",\"followUpMode\":\"one-at-a-time\",\"autoCompactionEnabled\":false}" ;;
                get_available_models) reply '{"models":[]}' ;;
                get_available_thinking_levels) reply '{"levels":["off"]}' ;;
                get_commands) reply '{"commands":[]}' ;;
                get_messages) reply '{"messages":[]}' ;;
                get_session_stats)
                  if [ -f "$root/hold-statistics" ]; then
                    (
                      /usr/bin/touch "$root/statistics-pending"
                      while [ -f "$root/hold-statistics" ]; do /bin/sleep 0.01; done
                      printf '{"id":"%s","type":"response","command":"get_session_stats","success":true,"data":{}}\n' "$id"
                    ) &
                  else reply '{}'; fi ;;
                bash)
                  value=$(printf '%s' "$line" | /usr/bin/plutil -extract command raw -o - -)
                  bashid=$id
                  case "$value" in
                    reject) /usr/bin/touch "$root/side-effect"; printf '{"id":"%s","type":"response","command":"bash","success":false,"error":"fixture"}\n' "$id"; bashid='' ;;
                    delayed)
                      printf '%s' "$id" > "$root/delayed-id"; bashid=''
                      (
                        /bin/sleep 0.3; /usr/bin/touch "$root/admitted"
                        while [ ! -f "$root/cancelled" ]; do /bin/sleep 0.01; done
                        printf '{"id":"%s","type":"response","command":"bash","success":true,"data":{"output":"","cancelled":true,"truncated":false}}\n' "$id"
                      ) & ;;
                    reject-on-stop)
                      bashid=''
                      (
                        while [ ! -f "$root/queue-pending" ]; do /bin/sleep 0.01; done
                        printf '{"id":"%s","type":"response","command":"bash","success":false,"error":"after side effects"}\n' "$id"
                      ) & ;;
                    ignore) bashid='' ;;
                    crash) exit 1 ;;
                    malformed) reply '{"output":false}' ;;
                    final) finish 7 false ;;
                    *)
                      printf '{"type":"bash_execution_update","id":"wrong","delta":"WRONG"}\n'
                      printf '{"type":"bash_execution_update","id":"%s","delta":"partial"}\n' "$id"
                      /usr/bin/awk -v id="$id" 'BEGIN { printf "{\"type\":\"bash_execution_update\",\"id\":\"%s\",\"delta\":\"", id; for(i=0;i<70000;i++) printf "x"; print "\"}" }'
                      printf '{"type":"agent_settled"}\n' ;;
                  esac ;;
                prompt) printf '{"type":"agent_start"}\n'; reply '{}' ;;
                abort)
                  if [ -f "$root/exit-on-abort" ]; then exit 1; fi
                  if [ -f "$root/reject-abort" ]; then printf '{"id":"%s","type":"response","command":"abort","success":false,"error":"fixture abort failed"}\n' "$id"
                  else reply '{}'; printf '{"type":"agent_settled"}\n'; fi ;;
                clear_queue)
                  if [ -f "$root/hold-queue" ]; then
                    /usr/bin/touch "$root/queue-pending"
                    while [ -f "$root/hold-queue" ]; do /bin/sleep 0.01; done
                  fi
                  if [ -f "$root/queue" ]; then
                    value=$(/bin/cat "$root/queue"); /bin/rm "$root/queue"; reply "$value"
                  else reply '{"steering":[],"followUp":[]}'; fi ;;
                abort_bash)
                  reply '{}'
                  /bin/sleep 0.1
                  if [ -f "$root/delayed-id" ]; then
                    [ ! -f "$root/admitted" ] || /usr/bin/touch "$root/cancelled"
                  else [ -z "$bashid" ] || finish null true; fi ;;
                *) reply '{}' ;;
              esac
            done
            """#.replacingOccurrences(of: "ROOT", with: root.path)
        }
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
        directory = try await host.directories.register(root)
    }

    func send(_ action: SessionAction, id: UUID = UUID()) async -> AppResult {
        let state = await host.state()
        return await host.handle(AppRequest(id: id, epoch: host.epoch, session: state.selected, action: action), device: device)
    }
    func wait(_ condition: @Sendable (HostSnapshot) -> Bool) async throws -> HostSnapshot {
        for _ in 0..<800 {
            let state = await host.state()
            if condition(state) { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RemoteFault.unavailable
    }
    func cleanup() async { await host.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test func bashAdmissionStaleBindingAndDeduplication() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(await f.send(.bash(command: "final", excludeFromContext: false, confirmed: false)) == .failure(.permissionDenied))
        #expect(await f.send(.bash(command: String(repeating: "x", count: 16_385), excludeFromContext: false, confirmed: true)) == .failure(.invalidRequest))
        #expect(await f.host.handle(AppRequest(epoch: f.host.epoch, session: UUID(), action: .bash(command: "final", excludeFromContext: true, confirmed: true)), device: f.device) == .failure(.conflict))
        let id = UUID()
        let action = SessionAction.bash(command: "final", excludeFromContext: true, confirmed: true)
        #expect(await f.send(action, id: id) == .ok)
        let state = try await f.wait { $0.bash?.status == .completed }
        #expect(state.bash?.exitCode == 7)
        #expect(state.bash?.output == "final")
        #expect(!state.working)
        #expect(await f.send(action, id: id) == .ok)
        let requests = try String(contentsOf: f.root.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n")
        let bash = try requests.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }.filter { $0["type"]?.string == "bash" }
        #expect(bash.count == 1)
        #expect(bash.first?["excludeFromContext"] == .bool(true))
        #expect(bash.first?["id"]?.string == id.uuidString)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test func bashStreamingBoundsCorrelationBusyAndCancellation() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        // Leave this subscriber unread while output arrives. It must not block Stop.
        let updates = await f.host.updates()
        let id = UUID()
        #expect(await f.send(.bash(command: "hold", excludeFromContext: false, confirmed: true), id: id) == .ok)
        let live = try await f.wait { $0.bash?.truncated == true }
        #expect(live.working)
        #expect(live.bash?.output.hasPrefix("partial") == true)
        #expect(live.bash?.output.contains("WRONG") == false)
        #expect(live.bash?.output.utf8.count == BashExecution.outputLimit)
        #expect(await f.send(.closeSession) == .failure(.busy))
        #expect(await f.send(.prompt(text: "No", delivery: .followUp, image: nil)) == .failure(.busy))
        #expect(await f.send(.abortBash(id: UUID())) == .failure(.conflict))
        #expect(await f.send(.abortBash(id: id)) == .ok)
        #expect(await f.host.state().bash?.status == .cancelling)
        #expect(await f.host.state().working)
        let done = try await f.wait { $0.bash?.status == .cancelled && !$0.working }
        #expect(done.bash?.output == "final")
        #expect(done.bash?.exitCode == nil)
        #expect(!done.working)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?.bash?.status == .cancelled)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test func bashStopAndCloseConfirmation() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(await f.send(.bash(command: "hold", excludeFromContext: false, confirmed: true)) == .ok)
        _ = try await f.wait { $0.bash?.truncated == true }
        let state = await f.host.state()
        let confirmation = try await f.host.closeConfirmation(for: state.context)
        #expect(try await f.host.quitConfirmation().requiresConfirmation)
        #expect(await f.host.handle(AppRequest(epoch: f.host.epoch, session: state.selected, action: .stop), device: f.device, closeConfirmation: confirmation) == .ok)
        #expect(await f.host.state().bash?.status == .cancelled)
        #expect(await f.send(.closeSession) == .ok)
        #expect(await f.host.state().bash == nil)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(arguments: ["reject", "crash", "malformed"])
func bashFailureAndUnknownOutcomesDoNotReplay(command: String) async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let id = UUID(), action = SessionAction.bash(command: command, excludeFromContext: false, confirmed: true)
        #expect(await f.send(action, id: id) == .ok)
        let final = try await f.wait { [.failed, .unknownOutcome].contains($0.bash?.status) }
        #expect(final.bash?.status == .unknownOutcome)
        if command == "reject" { #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("side-effect").path)) }
        #expect(await f.send(action, id: id) == .ok)
        #expect(try await f.host.quitConfirmation().requiresConfirmation)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test func bashProtocolCompatibilityAndUTF8Bounds() throws {
    var state = HostSnapshot(host: UUID(), epoch: UUID())
    #expect(state.capabilities.contains("bash"))
    let old = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(HostSnapshot.self, from: old).bash == nil)
    var execution = BashExecution(id: UUID(), command: "printf fixture", excludeFromContext: true)
    execution.append(String(repeating: "😀", count: 20_000))
    #expect(execution.output.utf8.count <= BashExecution.outputLimit)
    #expect(execution.truncated)
    execution.status = .completed
    let output = execution.output
    execution.append("late")
    #expect(execution.output == output)
    state.bash = execution
    #expect(try JSONDecoder().decode(HostSnapshot.self, from: JSONEncoder().encode(state)) == state)
    let action = SessionAction.bash(command: "fixture", excludeFromContext: false, confirmed: true)
    #expect(try JSONDecoder().decode(SessionAction.self, from: JSONEncoder().encode(action)) == action)
}

@Test func bashImmediateCancellationCannotOvertakeDispatch() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let id = UUID()
        #expect(await f.send(.bash(command: "hold", excludeFromContext: false, confirmed: true), id: id) == .ok)
        #expect(await f.send(.abortBash(id: id)) == .ok)
        _ = try await f.wait { $0.bash?.status == .cancelled && !$0.working }
        let requests = try String(contentsOf: f.root.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n")
        let commands = try requests.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["type"]?.string ?? "" }
        #expect(try #require(commands.firstIndex(of: "bash")) < #require(commands.firstIndex(of: "abort_bash")))
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test func bashStopDuringAdmissionPreventsLaterDispatch() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let hold = f.root.appendingPathComponent("hold-state")
        try Data().write(to: hold)
        let pending = Task { await f.send(.bash(command: "hold", excludeFromContext: false, confirmed: true)) }
        for _ in 0..<400 {
            if FileManager.default.fileExists(atPath: f.root.appendingPathComponent("state-pending").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("state-pending").path))
        let stop = Task { await f.send(.stop) }
        _ = try await f.wait { $0.phase == "stopping" }
        try FileManager.default.removeItem(at: hold)
        #expect(await pending.value == .failure(.conflict))
        #expect(await stop.value == .ok)
        #expect(await f.host.state().bash == nil)
        await f.cleanup()
    } catch {
        try? FileManager.default.removeItem(at: f.root.appendingPathComponent("hold-state"))
        await f.cleanup(); throw error
    }
}

@Test func bashCancellationRepeatsAcrossDelayedUpstreamAdmission() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let id = UUID()
        #expect(await f.send(.bash(command: "delayed", excludeFromContext: false, confirmed: true), id: id) == .ok)
        #expect(await f.send(.abortBash(id: id)) == .ok)
        _ = try await f.wait { $0.bash?.status == .cancelled && !$0.working }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("admitted").path))
        let requests = try String(contentsOf: f.root.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n")
        let aborts = try requests.filter { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["type"]?.string == "abort_bash" }
        #expect(aborts.count >= 2)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test func bashUnconfirmedCancellationStaysUncertainUntilExplicitStop() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let id = UUID()
        #expect(await f.send(.bash(command: "ignore", excludeFromContext: false, confirmed: true), id: id) == .ok)
        #expect(await f.send(.abortBash(id: id)) == .ok)
        let uncertain = try await f.wait { $0.bash?.status == .unknownOutcome }
        #expect(uncertain.working)
        #expect(uncertain.error == .unknownOutcome)
        #expect(await f.send(.closeSession) == .failure(.busy))
        #expect(await f.send(.stop) == .ok)
        #expect(await f.host.state().phase == "interrupted")
        #expect(await f.host.state().bash?.status == .unknownOutcome)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test func bashUncertaintyDuringStopQueueReadForcesChildShutdown() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(await f.send(.bash(command: "reject-on-stop", excludeFromContext: false, confirmed: true)) == .ok)
        let hold = f.root.appendingPathComponent("hold-queue")
        try Data().write(to: hold)
        let stopping = Task { await f.send(.stop) }
        _ = try await f.wait { $0.bash?.status == .unknownOutcome }
        try FileManager.default.removeItem(at: hold)
        #expect(await stopping.value == .ok)
        let state = await f.host.state()
        #expect(state.phase == "interrupted")
        #expect(state.bash?.status == .unknownOutcome)
        #expect(state.error == .unknownOutcome)
        await f.cleanup()
    } catch {
        try? FileManager.default.removeItem(at: f.root.appendingPathComponent("hold-queue"))
        await f.cleanup(); throw error
    }
}

@Test(arguments: [false, true])
func recoverQueueReturnsExactOrderedTextWithoutBroadcastOrReplay(stop: Bool) async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(await f.send(.prompt(text: "fixture", delivery: .prompt, image: nil)) == .ok)
        _ = try await f.wait { $0.working }
        let queue = #"{"steering":["first","second\nline"],"followUp":["last 😀"]}"#
        try queue.write(to: f.root.appendingPathComponent("queue"), atomically: true, encoding: .utf8)
        let id = UUID()
        let peerUpdates = await f.host.updates()
        #expect(await f.send(.recoverQueue(stop: stop), id: id) == .recoveredQueue(text: "first\n\nsecond\nline\n\nlast 😀"))
        let state = await f.host.state()
        #expect(state.draft == nil)
        #expect(state.draftID == nil)
        var peer = peerUpdates.makeAsyncIterator()
        let peerState = try #require(await peer.next())
        #expect(peerState.draft == nil)
        #expect(peerState.draftID == nil)
        #expect(String(data: try JSONEncoder().encode(peerState), encoding: .utf8)?.contains("last 😀") == false)
        #expect(state.pendingMessages == 0)
        #expect(state.working == !stop)
        #expect(await f.send(.recoverQueue(stop: stop), id: id) == .ok)
        #expect(await f.host.state().draft == nil)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(arguments: [false, true])
func recoverQueueRejectsOverflowAndMalformedTextExplicitly(oversized: Bool) async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let queue: JSONValue = oversized ? .object(["steering": .array([.string(String(repeating: "x", count: 256 * 1_024 + 1))]), "followUp": .array([])]) : .object(["steering": .array([.bool(false)]), "followUp": .array([])])
        try JSONEncoder().encode(queue).write(to: f.root.appendingPathComponent("queue"))
        #expect(await f.send(.recoverQueue(stop: true)) == .failure(oversized ? .tooLarge : .incompatiblePi))
        let state = await f.host.state()
        #expect(state.draft == nil)
        #expect(state.notices.contains { $0.contains("could not be recovered") })
        #expect(!state.working)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(arguments: [false, true]) func recoverQueuePreservesTextWhenSubsequentStopFails(childExits: Bool) async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: f.root.appendingPathComponent("support/sessions.json")))
        let entry = try #require(catalog.array?.first)
        let file = try #require(entry["file"]?.string.flatMap(URL.init(string:)))
        let piID = try #require(entry["piID"]?.string)
        let header: JSONValue = .object(["type": .string("session"), "id": .string(piID), "cwd": .string(f.root.path), "version": .number(3)])
        var bytes = try JSONEncoder().encode(header); bytes.append(10)
        try bytes.write(to: file)
        #expect(await f.send(.prompt(text: "fixture", delivery: .prompt, image: nil)) == .ok)
        _ = try await f.wait { $0.working }
        let queue: JSONValue = .object(["steering": .array([.string("recover this text")]), "followUp": .array([])])
        try JSONEncoder().encode(queue).write(to: f.root.appendingPathComponent("queue"))
        let selected = try #require(await f.host.state().selected)
        try Data().write(to: f.root.appendingPathComponent(childExits ? "exit-on-abort" : "reject-abort"))
        #expect(await f.send(.recoverQueue(stop: true)) == .recoveredQueue(text: "recover this text"))
        let state = await f.host.state()
        #expect(state.phase == "interrupted")
        #expect(state.error == .unknownOutcome || state.error == .unavailable)
        #expect(state.draft == nil)
        #expect(state.notices.contains { $0.contains("did not confirm Stop") })
        let resumed = await f.send(.resumeSession(id: selected))
        #expect(resumed == .ok)
        #expect(await f.host.state().phase == "idle")
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test func footerReadCannotReserveForegroundAdmissionOrPublishStaleFaults() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let state = await f.host.state()
        let hold = f.root.appendingPathComponent("hold-statistics")
        try Data().write(to: hold)
        let read = Task { try await f.host.displayStatistics(context: state.context) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: f.root.appendingPathComponent("statistics-pending").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("statistics-pending").path))
        #expect(await f.send(.prompt(text: "foreground", delivery: .prompt, image: nil)) == .ok)
        try FileManager.default.removeItem(at: hold)
        do { _ = try await read.value; Issue.record("Crossed footer read must be discarded") }
        catch { #expect(error as? RemoteFault == .conflict) }
        #expect(await f.host.state().error == nil)
        await f.cleanup()
    } catch {
        try? FileManager.default.removeItem(at: f.root.appendingPathComponent("hold-statistics"))
        await f.cleanup(); throw error
    }
}

@Test func agentSettlementCannotClearRunningShellInterruptionMarker() async throws {
    let f = try await BashFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let id = UUID()
        #expect(await f.send(.bash(command: "hold", excludeFromContext: false, confirmed: true), id: id) == .ok)
        _ = try await f.wait { $0.bash?.output.utf8.count == 64 * 1_024 }
        try await Task.sleep(for: .milliseconds(100))
        let data = try Data(contentsOf: f.root.appendingPathComponent("support/sessions.json"))
        let entries = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(entries.array?.first?["info"]?["interrupted"]?.bool == true)
        #expect(await f.send(.abortBash(id: id)) == .ok)
        _ = try await f.wait { $0.bash?.status == .cancelled }
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

/// Opt-in installed-runtime check. The wrapper has an empty home and no provider access.
@Test func bashInstalledPiIsolated() async throws {
    guard let pi = ProcessInfo.processInfo.environment["PI_REMOTE_SHELL_CHECK_EXECUTABLE"] else { return }
    let f = try await BashFixture(installed: pi)
    do {
        // Pi does not persist a shell-only empty session. Import an explicit,
        // synthetic user message so persistence/resume can be checked offline.
        let seed: [JSONValue] = [
            .object(["type": .string("session"), "version": .number(3), "id": .string(UUID().uuidString),
                     "cwd": .string(f.root.path), "timestamp": .string("2026-10-18T00:00:00.000Z")]),
            .object(["type": .string("message"), "id": .string("11111111"), "parentId": .null,
                     "timestamp": .string("2026-10-18T00:00:00.000Z"),
                     "message": .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("Offline shell persistence fixture. Do not send to a provider.")])]), "timestamp": .number(1_792_281_600_000)])])
        ]
        var data = Data()
        for record in seed { data.append(try JSONEncoder().encode(record)); data.append(10) }
        #expect(await f.send(.importSession(data: data)) == .ok)
        #expect(await f.send(.bash(command: "printf shell-fixture; exit 7", excludeFromContext: true, confirmed: true)) == .ok)
        let final = try await f.wait { $0.bash?.status == .completed }
        #expect(final.bash?.output == "shell-fixture")
        #expect(final.bash?.exitCode == 7)
        _ = try await f.wait { $0.messages.contains { $0.role == "bash" && $0.text.contains("shell-fixture") } }
        let id = UUID()
        #expect(await f.send(.bash(command: "printf streaming-fixture; sleep 30", excludeFromContext: false, confirmed: true), id: id) == .ok)
        _ = try await f.wait { $0.bash?.output.contains("streaming-fixture") == true }
        #expect(await f.send(.abortBash(id: id)) == .ok)
        _ = try await f.wait { $0.bash?.status == .cancelled && !$0.working && $0.messages.filter { $0.role == "bash" }.count == 2 }
        let selected = try #require(await f.host.state().selected)
        #expect(await f.send(.closeSession) == .ok)
        #expect(await f.send(.resumeSession(id: selected)) == .ok)
        #expect(await f.host.state().messages.filter { $0.role == "bash" }.count == 2)
        guard case .exportSession(let exported) = await f.send(.exportJSONL) else { throw RemoteFault.incompatiblePi }
        let entries = try exported.data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        let shells = entries.compactMap { $0["message"] }.filter { $0["role"]?.string == "bashExecution" }
        #expect(shells.count == 2)
        #expect(shells.first?["excludeFromContext"] == .bool(true))
        #expect(shells.last?["excludeFromContext"] == .bool(false))
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}
