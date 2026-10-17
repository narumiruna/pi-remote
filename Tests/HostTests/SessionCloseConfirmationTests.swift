import Foundation
import Testing
import PiRemoteCore
import PiRemoteHost

private struct CloseConfirmationFixture {
    let root: URL
    let host: HostCoordinator
    let device = UUID()
    let directory: UUID

    init() async throws {
        root = URL(fileURLWithPath: "/tmp/pi-close-confirmation-" + UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-pi")
        let script = #"""
        #!/bin/sh
        if [ "${1:-}" = --version ]; then printf '1.3.0\n'; exit 0; fi
        root='ROOT'; streaming=false; file=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --session-dir) folder=$2; shift 2 ;;
            --session-id) session=$2; shift 2 ;;
            --session) file=$2; session=$(/usr/bin/head -1 "$file" | /usr/bin/plutil -extract id raw -o - -); shift 2 ;;
            *) shift ;;
          esac
        done
        [ -n "$file" ] || file="$folder/$session.jsonl"
        reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | /usr/bin/plutil -extract id raw -o - -)
          command=$(printf '%s' "$line" | /usr/bin/plutil -extract type raw -o - -)
          printf '%s\n' "$command" >> "$root/commands"
          case "$command" in
            get_state) reply "{\"sessionId\":\"$session\",\"sessionFile\":\"$file\",\"isStreaming\":$streaming,\"isCompacting\":false,\"pendingMessageCount\":0,\"model\":{\"provider\":\"test\",\"id\":\"fixture\"},\"thinkingLevel\":\"off\",\"steeringMode\":\"one-at-a-time\",\"followUpMode\":\"one-at-a-time\",\"autoCompactionEnabled\":false}" ;;
            get_available_models) reply '{"models":[{"provider":"test","id":"fixture","name":"Fixture"}]}' ;;
            get_available_thinking_levels) reply '{"levels":["off"]}' ;;
            get_commands) reply '{"commands":[{"name":"fixture","source":"extension","description":"Fixture"}]}' ;;
            get_messages) reply '{"messages":[]}' ;;
            get_last_assistant_text)
              if [ -f "$root/events" ]; then /bin/cat "$root/events"; /bin/rm "$root/events"; fi
              reply '{"text":""}' ;;
            prompt)
              printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
              streaming=true
              printf '{"type":"agent_start"}\n'
              reply '{}' ;;
            steer|follow_up)
              if [ -f "$root/hold-work" ]; then
                /usr/bin/touch "$root/work-pending"
                while [ -f "$root/hold-work" ]; do /bin/sleep 0.01; done
              fi
              reply '{}' ;;
            clear_queue) reply '{}' ;;
            abort)
              if [ -f "$root/hold-stop" ]; then
                /usr/bin/touch "$root/stop-pending"
                while [ -f "$root/hold-stop" ]; do /bin/sleep 0.01; done
              fi
              streaming=false; reply '{}'; printf '{"type":"agent_settled"}\n' ;;
            *) reply '{}' ;;
          esac
        done
        """#.replacingOccurrences(of: "ROOT", with: root.path)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
        directory = try await host.directories.register(project)
    }

    func send(_ action: SessionAction, confirmation: LocalCloseConfirmation? = nil, id: UUID = UUID()) async -> AppResult {
        let state = await host.state()
        return await host.handle(AppRequest(id: id, epoch: host.epoch, session: state.selected, action: action),
                                 device: device, closeConfirmation: confirmation)
    }

    func start() async throws -> LocalCloseConfirmation {
        #expect(await send(.createSession(directory: directory)) == .ok)
        #expect(await send(.prompt(text: "Start", delivery: .prompt, image: nil)) == .ok)
        for _ in 0..<200 {
            if let token = try? await host.closeConfirmation(for: host.state().context) { return token }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RemoteFault.unavailable
    }

    func events(_ text: String) async throws {
        try text.write(to: root.appendingPathComponent("events"), atomically: true, encoding: .utf8)
        #expect(await send(.lastAssistant) == .preview(FilePreview(name: "Last assistant text", text: "", truncated: false)))
    }

    func calls(_ command: String) throws -> Int {
        try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
            .split(separator: "\n").filter { $0 == command }.count
    }

    func cleanup() async throws {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("hold-work"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("hold-stop"))
        await host.shutdown()
        try FileManager.default.removeItem(at: root)
    }
}

@Test func closeConfirmationRejectsAcceptedWorkBeforeAnyRunEvent() async throws {
    let f = try await CloseConfirmationFixture()
    do {
        let token = try await f.start()
        #expect(await f.send(.prompt(text: "Queued next run", delivery: .followUp, image: nil)) == .ok)
        let requestID = UUID()
        #expect(await f.send(.stop, confirmation: token, id: requestID) == .failure(.conflict))
        #expect(try f.calls("clear_queue") == 0)
        #expect(try f.calls("abort") == 0)
        let fresh = try await f.host.closeConfirmation(for: token.context)
        // A stale attempt must not enter the journal or poison this request ID.
        #expect(await f.send(.stop, confirmation: fresh, id: requestID) == .ok)
        #expect(try f.calls("clear_queue") == 2)
        #expect(try f.calls("abort") == 1)
        try await f.cleanup()
    } catch { try? await f.cleanup(); throw error }
}

@Test func closeConfirmationRejectsWhileNewWorkDispatchIsPending() async throws {
    let f = try await CloseConfirmationFixture()
    do {
        let token = try await f.start()
        let hold = f.root.appendingPathComponent("hold-work")
        try Data().write(to: hold)
        let pending = Task { await f.send(.prompt(text: "Pending acceptance", delivery: .followUp, image: nil)) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: f.root.appendingPathComponent("work-pending").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("work-pending").path))
        #expect(await f.send(.stop, confirmation: token) == .failure(.conflict))
        do { _ = try await f.host.closeConfirmation(for: token.context); Issue.record("Captured pending mutation") }
        catch { #expect(error as? RemoteFault == .busy) }
        #expect(try f.calls("clear_queue") == 0)
        #expect(try f.calls("abort") == 0)
        try FileManager.default.removeItem(at: hold)
        #expect(await pending.value == .ok)
        let fresh = try await f.host.closeConfirmation(for: token.context)
        #expect(await f.send(.stop, confirmation: fresh) == .ok)
        try await f.cleanup()
    } catch { try? await f.cleanup(); throw error }
}

@Test func closeConfirmationRejectsSettledThenStartedRunWithoutObservedIdle() async throws {
    let f = try await CloseConfirmationFixture()
    do {
        let token = try await f.start()
        try await f.events("{\"type\":\"agent_settled\"}\n{\"type\":\"agent_start\"}\n")
        var fresh = token
        for _ in 0..<200 {
            if let next = try? await f.host.closeConfirmation(for: token.context), next != token { fresh = next; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fresh != token)
        #expect(await f.send(.stop, confirmation: token) == .failure(.conflict))
        #expect(try f.calls("clear_queue") == 0)
        #expect(try f.calls("abort") == 0)
        #expect(await f.send(.stop, confirmation: fresh) == .ok)
        try await f.cleanup()
    } catch { try? await f.cleanup(); throw error }
}

@Test func closeConfirmationSurvivesOrdinaryMessageCompletionAndStopsOriginalRun() async throws {
    let f = try await CloseConfirmationFixture()
    do {
        let token = try await f.start()
        try await f.events("{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Streaming reply\"}]}}\n{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Streaming reply\"}]}}\n")
        for _ in 0..<200 {
            if await f.host.state().messages.contains(where: { $0.text == "Streaming reply" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.state().messages.contains { $0.text == "Streaming reply" })
        #expect(try await f.host.closeConfirmation(for: token.context) == token)
        #expect(await f.send(.stop, confirmation: token) == .ok)
        #expect(try f.calls("clear_queue") == 2)
        #expect(try f.calls("abort") == 1)
        try await f.cleanup()
    } catch { try? await f.cleanup(); throw error }
}

@Test func closeConfirmationReplaysPendingAndCompletedStopWithoutDispatch() async throws {
    let f = try await CloseConfirmationFixture()
    do {
        let token = try await f.start()
        let hold = f.root.appendingPathComponent("hold-stop")
        try Data().write(to: hold)
        let id = UUID()
        let pending = Task { await f.send(.stop, confirmation: token, id: id) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: f.root.appendingPathComponent("stop-pending").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("stop-pending").path))
        #expect(await f.send(.stop, confirmation: token, id: id) == .failure(.unknownOutcome))
        #expect(try f.calls("clear_queue") == 2)
        #expect(try f.calls("abort") == 1)
        try FileManager.default.removeItem(at: hold)
        #expect(await pending.value == .ok)
        #expect(await f.send(.stop, confirmation: token, id: id) == .ok)
        #expect(try f.calls("clear_queue") == 2)
        #expect(try f.calls("abort") == 1)
        try await f.cleanup()
    } catch { try? await f.cleanup(); throw error }
}

@Test func closeConfirmationCannotCancelANewPendingDialog() async throws {
    let f = try await CloseConfirmationFixture()
    do {
        let token = try await f.start()
        try await f.events("{\"type\":\"extension_ui_request\",\"id\":\"new-dialog\",\"method\":\"confirm\",\"title\":\"New approval\"}\n")
        for _ in 0..<200 {
            if await f.host.state().dialogs.contains(where: { $0.id == "new-dialog" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.state().dialogs.contains { $0.id == "new-dialog" })
        #expect(await f.send(.stop, confirmation: token) == .failure(.busy))
        #expect(try f.calls("clear_queue") == 0)
        #expect(try f.calls("abort") == 0)
        #expect(await f.host.state().dialogs.contains { $0.id == "new-dialog" })
        // Existing explicit Stop still cancels dialogs. Only close consent is restricted.
        #expect(await f.send(.stop) == .ok)
        #expect(try f.calls("abort") == 1)
        try await f.cleanup()
    } catch { try? await f.cleanup(); throw error }
}

@Test func closeConfirmationRejectsWrongContextsAndOtherActions() async throws {
    let f = try await CloseConfirmationFixture()
    do {
        let token = try await f.start()
        let context = token.context
        let wrong = [SessionContext(host: UUID(), epoch: context.epoch, session: context.session),
                     SessionContext(host: context.host, epoch: UUID(), session: context.session),
                     SessionContext(host: context.host, epoch: context.epoch, session: UUID())]
        for context in wrong {
            do { _ = try await f.host.closeConfirmation(for: context); Issue.record("Accepted wrong context") }
            catch { #expect(error as? RemoteFault == .conflict) }
        }
        #expect(await f.send(.prompt(text: "Must not dispatch", delivery: .followUp, image: nil), confirmation: token) == .failure(.conflict))
        #expect(try f.calls("follow_up") == 0)
        #expect(await f.send(.stop, confirmation: token) == .ok)
        #expect(await f.send(.closeSession) == .ok)
        #expect(await f.send(.resumeSession(id: try #require(context.session))) == .ok)
        #expect(await f.send(.prompt(text: "New lifecycle", delivery: .prompt, image: nil)) == .ok)
        #expect(await f.send(.stop, confirmation: token) == .failure(.conflict))
        #expect(try f.calls("clear_queue") == 2)
        #expect(try f.calls("abort") == 1)
        try await f.cleanup()
    } catch { try? await f.cleanup(); throw error }
}
