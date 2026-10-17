import Darwin
import Foundation
import Testing
import PiRemoteCore
@testable import PiRemoteHost

private struct LifecycleFixture {
    let root: URL
    let host: HostCoordinator
    let directory: UUID
    let device = UUID()

    init(catalogCount: Int = 0) async throws {
        root = URL(fileURLWithPath: "/tmp/pi-remote-lifecycle-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-pi")
        let script = #"""
        #!/bin/sh
        if [ "${1:-}" = --version ]; then printf '1.3.0\n'; exit 0; fi
        root='ROOT'
        printf '%s\n' "$$" >> "$root/pids"
        file=''; folder=''; session=''; parent=''; streaming=false; messages='[]'; name='Original'; model=fixture; thinking=off; branch=false
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --session-dir) folder=$2; shift 2 ;;
            --session-id) session=$2; shift 2 ;;
            --session) file=$2; session=$(/usr/bin/head -1 "$file" | /usr/bin/plutil -extract id raw -o - -); shift 2 ;;
            *) shift ;;
          esac
        done
        [ -n "$file" ] || file="$folder/$session.jsonl"
        if [ -f "$file" ] && /usr/bin/grep -q '"type":"message"' "$file"; then messages='[{"role":"user","content":"Saved lifecycle"}]'; fi
        reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
        header() {
          if [ -n "$parent" ]; then ancestry=",\"parentSession\":\"$parent\""; else ancestry=''; fi
          printf '{"type":"session","version":3,"id":"%s","cwd":"%s"%s}\n' "$session" "$PWD" "$ancestry" > "$file"
        }
        persist() {
          header
          printf '{"type":"message","id":"11111111","parentId":null,"message":{"role":"user","content":"Saved lifecycle"}}\n' >> "$file"
          messages='[{"role":"user","content":"Saved lifecycle"}]'
        }
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | /usr/bin/plutil -extract id raw -o - -)
          command=$(printf '%s' "$line" | /usr/bin/plutil -extract type raw -o - -)
          printf '%s\n' "$command" >> "$root/commands"
          case "$command" in
            get_state)
              if [ -f "$root/replace-on-state" ]; then
                target=$(/bin/cat "$root/replace-on-state"); /bin/rm "$root/replace-on-state"
                /bin/cp "$target" "$target.replace"; /bin/mv "$target.replace" "$target"
              fi
              reply "{\"sessionId\":\"$session\",\"sessionFile\":\"$file\",\"sessionName\":\"$name\",\"isStreaming\":$streaming,\"isCompacting\":false,\"pendingMessageCount\":0,\"model\":{\"provider\":\"test\",\"id\":\"$model\"},\"thinkingLevel\":\"$thinking\",\"steeringMode\":\"one-at-a-time\",\"followUpMode\":\"one-at-a-time\",\"autoCompactionEnabled\":false}" ;;
            get_available_models) reply '{"models":[{"provider":"test","id":"fixture","name":"Fixture"},{"provider":"test","id":"branch","name":"Branch"}]}' ;;
            get_available_thinking_levels) reply '{"levels":["off","low"]}' ;;
            get_commands)
              if [ "$branch" = true ]; then reply '{"commands":[{"name":"fixture","source":"extension","description":"Lifecycle fixture"},{"name":"branch-only","source":"extension","description":"New runtime"}]}'
              else reply '{"commands":[{"name":"fixture","source":"extension","description":"Lifecycle fixture"}]}'; fi ;;
            get_messages) reply "{\"messages\":$messages}" ;;
            set_auto_retry) reply '{}' ;;
            get_fork_messages) reply "$(/bin/cat "$root/forks.json")" ;;
            get_tree) reply "$(/bin/cat "$root/tree.json")" ;;
            clone|fork)
              if [ -f "$root/cancel-$command" ]; then /bin/rm "$root/cancel-$command"; reply '{"cancelled":true}'; continue; fi
              parent=$file; session=$(/usr/bin/uuidgen); file="$folder/$session.jsonl"; name='Incoming branch'; model=branch; thinking=low; branch=true
              persist
              printf '{"type":"session_info_changed","name":"Incoming branch"}\n'
              if [ "$command" = clone ]; then
                printf '{"type":"extension_ui_request","method":"set_editor_text","text":"Branch startup draft"}\n{"type":"extension_ui_request","method":"setStatus","statusKey":"shared","statusText":"Branch status"}\n{"type":"extension_ui_request","method":"setWidget","widgetKey":"shared","widgetLines":["Branch widget"]}\n'
                reply '{"cancelled":false}'
              else reply "$(/bin/cat "$root/fork-response.json")"; fi ;;
            new_session|switch_session)
              if [ -f "$root/pending-hook" ]; then
                /bin/rm "$root/pending-hook"; pendingID=$id; pendingCommand=$command; pendingLine=$line
                printf '{"type":"extension_ui_request","id":"lifecycle-hook","method":"input","title":"Lifecycle hook","timeout":15000}\n'
                continue
              fi
              if [ -f "$root/cancel-$command" ]; then /bin/rm "$root/cancel-$command"; reply '{"cancelled":true}'; continue; fi
              if [ -f "$root/exit-$command" ]; then exit 0; fi
              if [ "$command" = new_session ]; then
                parent=$(printf '%s' "$line" | /usr/bin/plutil -extract parentSession raw -o - - 2>/dev/null) || parent=''
                session=$(/usr/bin/uuidgen); file="$folder/$session.jsonl"; messages='[]'; name='New session'
              else
                file=$(printf '%s' "$line" | /usr/bin/plutil -extract sessionPath raw -o - -)
                session=$(/usr/bin/head -1 "$file" | /usr/bin/plutil -extract id raw -o - -)
                folder=$(/usr/bin/dirname "$file"); messages='[]'; name='Resumed session'
                if /usr/bin/grep -q '"type":"message"' "$file"; then messages='[{"role":"user","content":"Saved lifecycle"}]'; fi
              fi
              printf '{"type":"session_info_changed","name":"Transition name"}\n'
              reply '{"cancelled":false}' ;;
            extension_ui_response)
              id=$pendingID; command=$pendingCommand
              if [ ! -f "$root/ignore-hook-cancel" ] && printf '%s' "$line" | /usr/bin/grep -q '"cancelled":true'; then
                reply '{"cancelled":true}'
              else
                if [ "$command" = new_session ]; then
                  session=$(/usr/bin/uuidgen); file="$folder/$session.jsonl"; messages='[]'; name='Hook session'
                else
                  file=$(printf '%s' "$pendingLine" | /usr/bin/plutil -extract sessionPath raw -o - -)
                  session=$(/usr/bin/head -1 "$file" | /usr/bin/plutil -extract id raw -o - -)
                fi
                reply '{"cancelled":false}'
              fi ;;
            prompt)
              message=$(printf '%s' "$line" | /usr/bin/plutil -extract message raw -o - -)
              case "$message" in
                '/fixture persist') persist ;;
                '/fixture crash') exit 0 ;;
                '/fixture custom') header; printf '{"type":"custom_message","id":"custom","parentId":null,"customType":"fixture","display":true,"content":"Custom persisted history"}\n' >> "$file"; messages='[{"role":"custom","display":true,"content":"Custom persisted history"}]'; printf '{"type":"message_start","message":{"role":"custom","display":true,"content":"Custom persisted history"}}\n{"type":"message_end","message":{"role":"custom","display":true,"content":"Custom persisted history"}}\n' ;;
                '/fixture metadata') printf '{"type":"extension_ui_request","method":"set_editor_text","text":"Retained draft"}\n{"type":"extension_ui_request","method":"setStatus","statusKey":"status","statusText":"Retained notice"}\n' ;;
                '/fixture active') streaming=true; printf '{"type":"agent_start"}\n' ;;
              esac
              reply '{"disposition":"handled"}' ;;
            clear_queue) reply '{}' ;;
            abort) streaming=false; reply '{}'; printf '{"type":"agent_settled"}\n' ;;
            *) printf '{"id":"%s","type":"response","command":"%s","success":false,"error":"Unsupported fixture request"}\n' "$id" "$command" ;;
          esac
        done
        """#.replacingOccurrences(of: "ROOT", with: root.path)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        if catalogCount > 0 {
            let support = root.appendingPathComponent("support")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let directory = try DirectoryRegistry.identify(project)
            let values: [JSONValue] = try (0..<catalogCount).map { _ in
                let id = UUID()
                return .object(["info": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(SessionInfo(id: id, title: "Saved", directory: project.path))),
                                "directory": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(directory)),
                                "piID": .string(id.uuidString), "folder": .string(support.appendingPathComponent("pi-sessions/" + id.uuidString).absoluteString),
                                "hasHistory": .bool(false)])
            }
            try JSONEncoder().encode(JSONValue.array(values)).write(to: support.appendingPathComponent("sessions.json"))
        }
        host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
        directory = try await host.directories.register(project)
    }

    func send(_ action: SessionAction) async -> AppResult {
        let state = await host.state()
        return await host.handle(AppRequest(epoch: host.epoch, session: state.selected, action: action), device: device)
    }
    func calls(_ name: String) throws -> Int {
        guard let text = try? String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { $0 == name }.count
    }
    func pids() throws -> [pid_t] {
        try String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
    }
    func file(for id: UUID) throws -> URL {
        let data = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("support/sessions.json")))
        guard let path = data.array?.first(where: { $0["info"]?["id"]?.string?.lowercased() == id.uuidString.lowercased() })?["file"]?.string else {
            throw RemoteFault.storageFailure
        }
        return URL(string: path)!
    }
    func cleanup() async throws {
        await host.shutdown()
        for pid in (try? pids()) ?? [] { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        try FileManager.default.removeItem(at: root)
    }
}

@Test(arguments: [256, 257]) func importedForkDraftBudgetAlwaysAdoptsExactlyOneBranchWithoutReplay(kib: Int) async throws {
    let f = try await LifecycleFixture()
    do {
        let text = String(repeating: "x", count: kib * 1_024)
        let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(UUID().uuidString),
                                         "cwd": .string(f.root.appendingPathComponent("project").path), "timestamp": .string("2026-10-17T00:00:00.000Z")])
        let entry: JSONValue = .object(["type": .string("message"), "id": .string("11111111"), "parentId": .null,
                                        "timestamp": .string("2026-10-17T00:00:00.000Z"),
                                        "message": .object(["role": .string("user"), "content": .string(text), "timestamp": .number(1)])])
        var imported = try JSONEncoder().encode(header); imported.append(10); imported.append(try JSONEncoder().encode(entry)); imported.append(10)
        try JSONEncoder().encode(JSONValue.object(["messages": .array([.object(["entryId": .string("11111111"), "text": .string(text)])])])).write(to: f.root.appendingPathComponent("forks.json"))
        try JSONEncoder().encode(JSONValue.object(["tree": .array([.object(["entry": entry, "children": .array([])])]), "leafId": .string("11111111")])).write(to: f.root.appendingPathComponent("tree.json"))
        try JSONEncoder().encode(JSONValue.object(["cancelled": .bool(false), "text": .string(text)])).write(to: f.root.appendingPathComponent("fork-response.json"))
        #expect(await f.send(.importSession(data: imported)) == .ok)
        let prior = await f.host.state()
        let request = AppRequest(epoch: f.host.epoch, session: prior.selected, action: .fork(entry: "11111111"))
        #expect(await f.host.handle(request, device: f.device) == .ok)
        #expect(await f.host.handle(request, device: f.device) == .ok)
        let state = await f.host.state()
        #expect(state.selected != prior.selected && state.sessions.count == prior.sessions.count + 1)
        #expect(state.error == nil && state.phase == "idle")
        if kib > 256 {
            #expect(state.draft == nil && state.draftID == nil)
            #expect(state.notices.contains { $0.contains("Fork succeeded") && $0.contains("256 KiB") })
        } else {
            #expect(state.draft == text && state.draftID != nil)
            #expect(!state.notices.contains { $0.contains("256 KiB") })
        }
        #expect(try AppPacket(AppResult.snapshot(state)).encode().count < 4 * 1_024 * 1_024)
        #expect(try f.calls("fork") == 1 && f.calls("prompt") == 0)
        #expect(try f.pids().count == 1)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}

@Test func cloneUsesTransitionFencingAndRefreshesTheNewRuntime() async throws {
    let f = try await LifecycleFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(await f.send(.command(name: "fixture", arguments: "persist")) == .ok)
        #expect(await f.send(.command(name: "fixture", arguments: "metadata")) == .ok)
        for _ in 0..<100 { if await f.host.state().draft != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let prior = await f.host.state()
        try Data().write(to: f.root.appendingPathComponent("cancel-clone"))
        #expect(await f.send(.clone) == .failure(.cancelled))
        #expect(await f.host.state().sessions == prior.sessions)
        #expect(await f.host.state().draft == prior.draft)
        #expect(await f.send(.clone) == .ok)
        for _ in 0..<100 { if await f.host.state().draft == "Branch startup draft" { break }; try await Task.sleep(for: .milliseconds(10)) }
        let state = await f.host.state()
        #expect(state.selected != prior.selected && state.sessions.count == 2)
        #expect(state.sessions.first(where: { $0.id == prior.selected })?.title == prior.sessions.first?.title)
        #expect(state.model == "test/branch" && state.thinking == "low")
        #expect(state.commands.contains { $0.name == "branch-only" })
        #expect(state.draft == "Branch startup draft")
        #expect(state.notices.contains("Branch status") && state.notices.contains("Branch widget"))
        #expect(try f.pids().count == 1)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}

@Test func nativeNewSessionActionUsesOnlyAnOpaqueCurrentContextAndParentFlag() throws {
    for parent in [false, true] {
        let action = SessionAction.newSession(parent: parent)
        #expect(action.mutates && action.changesSession && action.needsSession)
        let packet = AppPacket(AppRequest(epoch: UUID(), session: UUID(), action: action))
        #expect(try AppPacket<AppRequest>.decode(packet.encode()).payload.action == action)
        #expect(!String(decoding: try packet.encode(), as: UTF8.self).contains("sessionPath"))
    }
}

@Test func managedLifecycleUsesCoreNewSwitchAndKeepsRetryAcknowledgement() async throws {
    let f = try await LifecycleFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let first = try #require(await f.host.state().selected)
        #expect(await f.send(.command(name: "fixture", arguments: "persist")) == .ok)
        #expect(await f.send(.autoRetry(enabled: false)) == .ok)
        let before = await f.host.state()
        let request = AppRequest(epoch: f.host.epoch, session: first, action: .newSession(parent: true))
        #expect(await f.host.handle(request, device: f.device) == .ok)
        let new = await f.host.state()
        #expect(new.selected != first && new.messages.isEmpty && new.sessions.count == 2)
        #expect(new.runtime?.acknowledgedAutoRetry == false)
        #expect(new.sessions.first(where: { $0.id == first })?.title == before.sessions.first(where: { $0.id == first })?.title)
        #expect(await f.host.handle(request, device: f.device) == .ok)
        #expect(try f.calls("new_session") == 1)
        #expect(await f.host.handle(AppRequest(epoch: f.host.epoch, session: first, action: .newSession(parent: false)), device: f.device) == .failure(.conflict))
        #expect(await f.send(.resumeSession(id: first)) == .ok)
        #expect(try f.calls("switch_session") == 1)
        #expect(try f.pids().count == 1)
        #expect(await f.host.state().messages.first?.text == "Saved lifecycle")
        #expect(await f.host.state().runtime?.acknowledgedAutoRetry == false)
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(try f.calls("new_session") == 2)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}

@Test func cancelledCoreLifecyclePreservesCatalogSelectionDraftAndHistory() async throws {
    let f = try await LifecycleFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let first = try #require(await f.host.state().selected)
        #expect(await f.send(.command(name: "fixture", arguments: "persist")) == .ok)
        #expect(await f.send(.newSession(parent: false)) == .ok)
        #expect(await f.send(.command(name: "fixture", arguments: "metadata")) == .ok)
        for _ in 0..<100 {
            if await f.host.state().draft != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for (core, action) in [("new_session", SessionAction.newSession(parent: false)), ("switch_session", .resumeSession(id: first))] {
            let prior = await f.host.state()
            let catalog = try Data(contentsOf: f.root.appendingPathComponent("support/sessions.json"))
            try Data().write(to: f.root.appendingPathComponent("cancel-" + core))
            #expect(await f.send(action) == .failure(.cancelled))
            let after = await f.host.state()
            #expect(after.selected == prior.selected && after.sessions == prior.sessions)
            #expect(after.messages == prior.messages && after.draft == prior.draft && after.notices == prior.notices)
            #expect(after.phase == prior.phase && after.runtime == prior.runtime)
            #expect(try Data(contentsOf: f.root.appendingPathComponent("support/sessions.json")) == catalog)
        }
        #expect(try f.pids().count == 1)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}

@Test func emptyReopenAndCrossDirectoryUseExplicitProcessActivation() async throws {
    let f = try await LifecycleFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let first = try #require(await f.host.state().selected)
        #expect(await f.send(.newSession(parent: false)) == .ok)
        let empty = try #require(await f.host.state().selected)
        #expect(await f.send(.resumeSession(id: first)) == .ok)
        #expect(await f.send(.resumeSession(id: empty)) == .ok)
        #expect(try f.pids().count == 3 && f.calls("switch_session") == 0)
        #expect(await f.host.state().runtime?.acknowledgedAutoRetry == nil)
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let directory = try await f.host.directories.register(other)
        #expect(await f.send(.createSession(directory: directory)) == .ok)
        #expect(try f.pids().count == 4)
        #expect(await f.host.state().sessions.first(where: { $0.id == empty })?.directory != other.path)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}

@Test func lifecycleRejectsActiveWorkInvalidParentsAndReplacedFilesBeforeDispatch() async throws {
    let f = try await LifecycleFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(await f.send(.newSession(parent: true)) == .failure(.invalidRequest))
        #expect(try f.calls("new_session") == 0)
        #expect(await f.send(.command(name: "fixture", arguments: "persist")) == .ok)
        let saved = try #require(await f.host.state().selected)
        let file = try f.file(for: saved)
        #expect(await f.send(.newSession(parent: false)) == .ok)
        try Data(file.path.utf8).write(to: f.root.appendingPathComponent("replace-on-state"))
        #expect(await f.send(.resumeSession(id: saved)) == .failure(.staleDirectory))
        #expect(try f.calls("switch_session") == 0)
        #expect(await f.send(.command(name: "fixture", arguments: "active")) == .ok)
        for _ in 0..<100 {
            if await f.host.state().working { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.send(.newSession(parent: false)) == .failure(.busy))
        #expect(await f.send(.resumeSession(id: saved)) == .failure(.busy))
        #expect(try f.calls("new_session") == 1)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}

@Test func lifecycleUnknownOutcomeStopsChildWithoutInventingIdleOrCatalogEntry() async throws {
    let f = try await LifecycleFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let prior = await f.host.state()
        try Data().write(to: f.root.appendingPathComponent("exit-new_session"))
        #expect(await f.send(.newSession(parent: false)) == .failure(.unknownOutcome))
        let state = await f.host.state()
        #expect(state.selected == prior.selected && state.sessions.count == prior.sessions.count)
        #expect(state.phase == "interrupted" && state.error == .unknownOutcome)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}

@Test func pendingLifecycleHookAllowsAnswerAndStopFencesALateSuccess() async throws {
    for stop in [false, true] {
        let f = try await LifecycleFixture()
        do {
            #expect(await f.send(.createSession(directory: f.directory)) == .ok)
            let prior = await f.host.state()
            try Data().write(to: f.root.appendingPathComponent("pending-hook"))
            if stop { try Data().write(to: f.root.appendingPathComponent("ignore-hook-cancel")) }
            let request = AppRequest(epoch: f.host.epoch, session: prior.selected, action: .newSession(parent: false))
            let pending = Task { await f.host.handle(request, device: f.device) }
            for _ in 0..<200 {
                if await !f.host.state().dialogs.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let waiting = await f.host.state()
            #expect(waiting.dialogs.count == 1 && waiting.phase == "waiting")
            #expect(await f.send(.closeSession) == .failure(.busy))
            if stop {
                #expect(await f.send(.stop) == .ok)
                let result = await pending.value
                #expect(result == .failure(.conflict) || result == .failure(.unknownOutcome))
                let final = await f.host.state()
                #expect(final.selected == prior.selected && final.sessions.count == 1)
                #expect(final.phase == "interrupted" && final.dialogs.isEmpty)
                for pid in try f.pids() { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
            } else {
                #expect(await f.send(.answer(dialog: "lifecycle-hook", value: "continue", confirmed: nil, cancelled: false)) == .ok)
                #expect(await pending.value == .ok)
                #expect(await f.host.state().sessions.count == 2)
                #expect(await f.host.state().phase == "idle")
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

@Test func shutdownWhileLifecycleHookWaitsCannotCommitALateSelection() async throws {
    let f = try await LifecycleFixture()
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        let prior = await f.host.state()
        try Data().write(to: f.root.appendingPathComponent("pending-hook"))
        let request = AppRequest(epoch: f.host.epoch, session: prior.selected, action: .newSession(parent: false))
        let pending = Task { await f.host.handle(request, device: f.device) }
        for _ in 0..<200 {
            if await !f.host.state().dialogs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.state().dialogs.count == 1)
        await f.host.shutdown()
        let result = await pending.value
        #expect(result == .failure(.unknownOutcome) || result == .failure(.conflict))
        let final = await f.host.state()
        #expect(final.phase == "unavailable" && final.selected == prior.selected && final.sessions.count == 1)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}

@Test func handledMetadataPromptDoesNotInventPersistedConversationHistory() async throws {
    let fixture = try await LifecycleFixture()
    do {
        #expect(await fixture.send(.createSession(directory: fixture.directory)) == .ok)
        let selected = try #require(await fixture.host.state().selected)
        let file = try fixture.file(for: selected)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await fixture.send(.prompt(text: "/fixture metadata", delivery: .prompt, image: nil)) == .ok)
        #expect(await fixture.host.state().phase == "idle")
        #expect(await fixture.host.state().messages.isEmpty)
        #expect(await fixture.send(.closeSession) == .ok)
        #expect(await fixture.send(.resumeSession(id: selected)) == .ok)
        #expect(await fixture.host.state().selected == selected)
        #expect(await fixture.host.state().messages.isEmpty)
        #expect(try fixture.calls("prompt") == 1)
        #expect(try fixture.pids().count == 2)
        try await fixture.cleanup()
    } catch { try? await fixture.cleanup(); throw error }
}

@Test func unexpectedEmptyChildExitPreservesExplicitReopenWithoutPromptReplay() async throws {
    let fixture = try await LifecycleFixture()
    do {
        #expect(await fixture.send(.createSession(directory: fixture.directory)) == .ok)
        let selected = try #require(await fixture.host.state().selected)
        let file = try fixture.file(for: selected)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await fixture.send(.command(name: "fixture", arguments: "crash")) == .failure(.unknownOutcome))
        for _ in 0..<200 {
            if await fixture.host.state().phase == "interrupted" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.host.state().phase == "interrupted")
        #expect(await fixture.host.state().sessions.first(where: { $0.id == selected })?.interrupted == true)
        #expect(await fixture.send(.resumeSession(id: selected)) == .ok)
        #expect(await fixture.host.state().selected == selected)
        #expect(await fixture.host.state().messages.isEmpty)
        #expect(try fixture.calls("prompt") == 1)
        #expect(try fixture.pids().count == 2)
        try await fixture.cleanup()
    } catch { try? await fixture.cleanup(); throw error }
}

@Test func customMessageWithoutAnAgentRunCannotBeReopenedAsAnEmptySessionAfterHistoryLoss() async throws {
    let fixture = try await LifecycleFixture()
    do {
        #expect(await fixture.send(.createSession(directory: fixture.directory)) == .ok)
        let selected = try #require(await fixture.host.state().selected)
        #expect(await fixture.send(.command(name: "fixture", arguments: "custom")) == .ok)
        for _ in 0..<200 {
            if await fixture.host.state().messages.contains(where: { $0.text == "Custom persisted history" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.host.state().messages.contains { $0.text == "Custom persisted history" })
        #expect(await fixture.send(.closeSession) == .ok)
        let file = try fixture.file(for: selected)
        try FileManager.default.removeItem(at: file)
        #expect(await fixture.send(.resumeSession(id: selected)) == .failure(.staleDirectory))
        #expect(try fixture.pids().count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await fixture.cleanup()
    } catch { try? await fixture.cleanup(); throw error }
}

@Test func emptyChildAncestrySurvivesAHostRestartWithoutReplacingHistory() async throws {
    var fixture: LifecycleFixture? = try await LifecycleFixture()
    let root = fixture!.root
    defer { try? FileManager.default.removeItem(at: root) }
    var reopened: HostCoordinator?
    do {
        #expect(await fixture!.send(.createSession(directory: fixture!.directory)) == .ok)
        let source = try #require(await fixture!.host.state().selected)
        #expect(await fixture!.send(.command(name: "fixture", arguments: "persist")) == .ok)
        let parent = try fixture!.file(for: source), original = try Data(contentsOf: parent)
        #expect(await fixture!.send(.newSession(parent: true)) == .ok)
        let child = try #require(await fixture!.host.state().selected)
        let childFile = try fixture!.file(for: child)
        #expect(!FileManager.default.fileExists(atPath: childFile.path))
        let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("support/sessions.json")))
        let saved = try #require(catalog.array?.first { $0["info"]?["id"]?.string?.lowercased() == child.uuidString.lowercased() })
        #expect(saved["parentFile"]?.string == parent.absoluteString)
        weak var previous = fixture?.host
        await fixture!.host.shutdown()
        fixture = nil
        for _ in 0..<200 {
            if previous == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(previous == nil)
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: root.appendingPathComponent("fake-pi"))
        reopened = host
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .resumeSession(id: child)), device: UUID()) == .ok)
        #expect(await host.state().selected == child)
        let data = try Data(contentsOf: childFile)
        let records = try data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        #expect(records.count == 1 && records[0]["type"]?.string == "session")
        #expect(records[0]["id"] == saved["piID"])
        #expect(records[0]["parentSession"]?.string == parent.path)
        let mode = try FileManager.default.attributesOfItem(atPath: childFile.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try Data(contentsOf: parent) == original)
        await host.shutdown()
    } catch {
        if let fixture { await fixture.host.shutdown() }
        if let reopened { await reopened.shutdown() }
        throw error
    }
}

@Test func forkAndCloneRejectFullCatalogBeforeCoreDispatch() async throws {
    let f = try await LifecycleFixture(catalogCount: 255)
    do {
        #expect(await f.send(.createSession(directory: f.directory)) == .ok)
        #expect(await f.host.state().sessions.count == 256)
        #expect(await f.send(.fork(entry: "11111111")) == .failure(.capacity))
        #expect(await f.send(.clone) == .failure(.capacity))
        #expect(try f.calls("fork") == 0 && f.calls("clone") == 0)
        #expect(await f.host.state().sessions.count == 256)
        try await f.cleanup()
    } catch { try await f.cleanup(); throw error }
}
