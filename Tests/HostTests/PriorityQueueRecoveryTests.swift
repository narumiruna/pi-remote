import Foundation
import Testing
import PiRemoteCore
import PiRemoteHost

private struct PriorityRecoveryFixture {
    let root: URL
    let host: HostCoordinator
    let device = UUID()
    let directory: UUID

    init(mode: String = "normal") async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("priority-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try fakePi(at: root)
        var script = try String(contentsOf: executable, encoding: .utf8)
        func replaceCase(_ name: String, _ replacement: String) throws {
            let line = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("        " + name + ")") })
            script = script.replacingOccurrences(of: line, with: replacement)
        }
        try replaceCase("compact", #"""
                compact)
                    if [ "MODE" = complete ]; then reply '{}'; continue; fi
                    pending=$id; pendingCommand=compact
                    printf '{"type":"compaction_start","reason":"manual"}\n'
                    if [ "MODE" = compact-dialog ]; then
                        printf '{"type":"extension_ui_request","id":"compact-confirm","method":"confirm","title":"Compaction fixture"}\n'
                    fi
                    /usr/bin/touch "$PWD/pending" ;;
        """#)
        script = script.replacingOccurrences(of: "        get_messages)\n", with: #"""
                get_messages)
                    if [ -f "$PWD/hold-history" ]; then
                        /usr/bin/touch "$PWD/history-pending"
                        while [ -f "$PWD/hold-history" ]; do /bin/sleep 0.01; done
                        reply '{"messages":[{"role":"assistant","content":[{"type":"text","text":"Stale compact history"}]}]}'
                        continue
                    fi
        """# + "\n")
        script = script.replacingOccurrences(of: "        prompt)\n", with: #"""
                prompt)
                    case "$line" in
                        *'/metadata pending'*)
                            pending=$id; pendingCommand=prompt
                            if [ -f "$PWD/dialog" ]; then
                                printf '{"type":"extension_ui_request","id":"question-1","method":"confirm","title":"Fixture"}\n'
                            fi
                            /usr/bin/touch "$PWD/pending"; continue ;;
                    esac
        """# + "\n")
        script = script.replacingOccurrences(of: "        extension_ui_response)\n", with: #"""
                extension_ui_response)
                    if [ "$pendingCommand" = compact ]; then
                        printf '{"id":"%s","type":"response","command":"compact","success":true,"data":{}}\n' "$pending"
                        pending=''
                        continue
                    fi
                    if [ "$pendingCommand" = new_session ]; then continue; fi
        """# + "\n")
        script = script.replacingOccurrences(of: "        new_session)\n", with: #"""
                new_session)
                    if [ -f "$PWD/lifecycle" ]; then
                        pending=$id; pendingCommand=new_session
                        printf '{"type":"extension_ui_request","id":"question-1","method":"confirm","title":"Lifecycle fixture"}\n'
                        /usr/bin/touch "$PWD/pending"; continue
                    fi
        """# + "\n")
        try replaceCase("clear_queue", #"""
                clear_queue)
                    printf Q >> "$PWD/clears"
                    case "MODE" in
                        reject) printf '{"id":"%s","type":"response","command":"clear_queue","success":false,"error":"fixture"}\n' "$id"; continue ;;
                        unknown) exit 1 ;;
                    esac
                    if [ -f "$PWD/hold-queue" ]; then
                        /usr/bin/touch "$PWD/queue-pending"
                        while [ -f "$PWD/hold-queue" ]; do /bin/sleep 0.01; done
                    fi
                    queueCount=0
                    reply '{"steering":["first","second\nline"],"followUp":["last"]}' ;;
        """#)
        try replaceCase("abort", #"""
                abort)
                    if [ -n "$pending" ]; then
                        printf '{"id":"%s","type":"response","command":"%s","success":true,"data":{}}\n' "$pending" "$pendingCommand"
                        pending=''
                    fi
                    if [ -f "$PWD/hold-abort" ]; then
                        /usr/bin/touch "$PWD/abort-pending"
                        while [ -f "$PWD/hold-abort" ]; do /bin/sleep 0.01; done
                    fi
                    streaming=false; printf '{"type":"agent_settled"}\n'; reply '{}' ;;
        """#)
        script = script.replacingOccurrences(of: "get_state) reply", with: #"""
        get_state)
                    if [ -f "$PWD/hold-state" ]; then
                        /usr/bin/touch "$PWD/state-pending"
                        while [ -f "$PWD/hold-state" ]; do /bin/sleep 0.01; done
                    fi
                    reply
        """#)
        script = script.replacingOccurrences(of: "MODE", with: mode)
        script = script.replacingOccurrences(of: "    case \"$command\" in\n", with: "    printf '%s\\n' \"$command\" >> \"$PWD/requests\"\n    case \"$command\" in\n        bash) reply '{\"output\":false}' ;;\n")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
        directory = try await host.directories.register(root)
    }

    func send(_ action: SessionAction, id: UUID = UUID()) async -> AppResult {
        await host.handle(AppRequest(id: id, epoch: host.epoch, session: await host.state().selected, action: action), device: device)
    }

    func flag(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }

    func waitForFile(_ name: String) async throws {
        for _ in 0..<400 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RemoteFault.unavailable
    }

    func cleanup() async {
        for name in ["hold-queue", "hold-state", "hold-abort", "hold-history"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["compact", "command", "dialog", "lifecycle"])
func priorityQueueRecoveryInterruptsPendingRPC(kind: String) async throws {
    let f = try await PriorityRecoveryFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let selected = try #require(await f.host.state().selected)
        if kind == "dialog" || kind == "lifecycle" { try f.flag(kind) }
        let action: SessionAction = kind == "compact" ? .compact(instructions: "fixture") : kind == "lifecycle" ? .newSession(parent: false) : .command(name: "metadata", arguments: "pending")
        let pending = Task { await f.send(action) }
        try await f.waitForFile("pending")
        #expect(await f.send(.recoverQueue(stop: false)) == .failure(.busy))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("clears").path))
        #expect(await f.host.handle(AppRequest(epoch: f.host.epoch, session: UUID(), action: .recoverQueue(stop: true)), device: f.device) == .failure(.conflict))
        #expect(await f.host.handle(AppRequest(epoch: UUID(), session: selected, action: .recoverQueue(stop: true)), device: f.device) == .failure(.unknownOutcome))
        let recoveryID = UUID()
        let recovered = await f.send(.recoverQueue(stop: true), id: recoveryID)
        try #require(recovered == .recoveredQueue(text: "first\n\nsecond\nline\n\nlast"))
        // Explicit interruption must release the reserved mutation, even if the
        // extension never answers its original RPC or ignores dialog cancellation.
        let result = await pending.value
        #expect([AppResult.failure(.unknownOutcome), .failure(.conflict)].contains(result))
        let state = await f.host.state()
        #expect(state.phase == "interrupted")
        #expect(state.selected == selected)
        #expect(state.dialogs.isEmpty)
        #expect(state.draft == nil && state.draftID == nil)
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("second\\nline"))
        #expect(await f.send(.recoverQueue(stop: true), id: recoveryID) == .ok)
        let requests = try String(contentsOf: f.root.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n")
        #expect(requests.filter { $0 == (kind == "compact" ? "compact" : kind == "lifecycle" ? "new_session" : "prompt") }.count == 1)
        #expect(await f.send(.resumeSession(id: selected)) == .ok)
        #expect(await f.host.state().phase == "idle")
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["reject", "unknown"])
func priorityQueueRecoveryStillStopsWhenQueueReadFails(mode: String) async throws {
    let f = try await PriorityRecoveryFixture(mode: mode)
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let pending = Task { await f.send(.compact(instructions: "fixture")) }
        try await f.waitForFile("pending")
        let recovery = await f.send(.recoverQueue(stop: true))
        #expect(recovery == .failure(mode == "reject" ? .invalidRequest : .unknownOutcome))
        #expect(await pending.value == .failure(.unknownOutcome))
        let state = await f.host.state()
        #expect(state.phase == "interrupted")
        #expect(state.draft == nil && state.draftID == nil)
        // On child exit, the event observer can own shutdown and retain its
        // unknown-outcome warning instead of the queue-read warning.
        #expect(!state.notices.isEmpty)
        if mode == "reject" { #expect(state.notices.contains { $0.contains("could not be recovered") }) }
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("second\\nline"))
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func priorityStopInterruptsPendingQueueRecovery() async throws {
    let f = try await PriorityRecoveryFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        try f.flag("hold-queue")
        let recovery = Task { await f.send(.recoverQueue(stop: true)) }
        try await f.waitForFile("queue-pending")
        #expect(await f.send(.recoverQueue(stop: false)) == .failure(.busy))
        #expect(await f.send(.stop) == .ok)
        #expect(await recovery.value == .failure(.unknownOutcome))
        #expect(await f.host.state().phase == "interrupted")
        #expect(await f.host.state().draft == nil)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func priorityStopFencesLateCompactAndExtensionResponses(compact: Bool) async throws {
    let f = try await PriorityRecoveryFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let action: SessionAction = compact ? .compact(instructions: "fixture") : .command(name: "metadata", arguments: "pending")
        let pending = Task { await f.send(action) }
        try await f.waitForFile("pending")
        try f.flag("hold-abort")
        let stop = Task { await f.send(.stop) }
        try await f.waitForFile("abort-pending")
        // The fake replies to old work while abort remains pending. A late
        // compaction reply must not replace stopping with an invented idle phase.
        #expect(await pending.value == (compact ? .failure(.conflict) : .ok))
        #expect(await f.host.state().phase == "stopping")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("hold-abort"))
        #expect(await stop.value == .ok)
        #expect(await f.host.state().phase == "idle")
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func priorityRecoveryFencesCompactAndCommandAdmission(compact: Bool) async throws {
    let f = try await PriorityRecoveryFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        try f.flag("hold-state")
        let action: SessionAction = compact ? .compact(instructions: "fixture") : .command(name: "metadata", arguments: "pending")
        let pending = Task { await f.send(action) }
        try await f.waitForFile("state-pending")
        let recovery = Task { await f.send(.recoverQueue(stop: true)) }
        for _ in 0..<400 {
            if await f.host.state().phase == "stopping" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await f.host.state().phase == "stopping")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("hold-state"))
        #expect(await pending.value == .failure(.conflict))
        #expect(await recovery.value == .recoveredQueue(text: "first\n\nsecond\nline\n\nlast"))
        let requests = try String(contentsOf: f.root.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n")
        #expect(!requests.contains(compact ? "compact" : "prompt"))
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func priorityQueueRecoveryStopsAnUncertainChild() async throws {
    let f = try await PriorityRecoveryFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(await f.send(.bash(command: "fixture", excludeFromContext: true, confirmed: true)) == .ok)
        for _ in 0..<400 {
            if await f.host.state().phase == "recovering" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await f.host.state().phase == "recovering")
        #expect(await f.send(.recoverQueue(stop: false)) == .failure(.busy))
        #expect(await f.send(.recoverQueue(stop: true)) == .recoveredQueue(text: "first\n\nsecond\nline\n\nlast"))
        #expect(await f.host.state().phase == "interrupted")
        #expect(await f.host.state().bash?.status == .unknownOutcome)
        #expect(await f.host.state().draft == nil)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func priorityRecoveryFenceAllowsCompactionDialogAnswer() async throws {
    let f = try await PriorityRecoveryFixture(mode: "compact-dialog")
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let compact = Task { await f.send(.compact(instructions: "fixture")) }
        try await f.waitForFile("pending")
        for _ in 0..<400 {
            if await f.host.state().dialogs.contains(where: { $0.id == "compact-confirm" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await f.host.state().dialogs.contains { $0.id == "compact-confirm" })
        #expect(await f.send(.answer(dialog: "compact-confirm", value: nil, confirmed: true, cancelled: false)) == .ok)
        #expect(await compact.value == .ok)
        #expect(await f.host.state().phase == "idle")
        #expect(await f.host.state().dialogs.isEmpty)
        let requests = try String(contentsOf: f.root.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n")
        #expect(requests.contains("get_messages"))
        #expect(!requests.contains("abort") && !requests.contains("clear_queue"))
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func priorityRecoveryDiscardsLateCompactHistory() async throws {
    let f = try await PriorityRecoveryFixture(mode: "complete")
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        try f.flag("hold-history")
        let compact = Task { await f.send(.compact(instructions: "fixture")) }
        try await f.waitForFile("history-pending")
        let recovery = Task { await f.send(.recoverQueue(stop: true)) }
        for _ in 0..<400 {
            if await f.host.state().phase == "stopping" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await f.host.state().phase == "stopping")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("hold-history"))
        #expect(await compact.value == .failure(.conflict))
        #expect(await recovery.value == .recoveredQueue(text: "first\n\nsecond\nline\n\nlast"))
        let state = await f.host.state()
        #expect(state.phase == "interrupted")
        #expect(!state.messages.contains { $0.text == "Stale compact history" })
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}
