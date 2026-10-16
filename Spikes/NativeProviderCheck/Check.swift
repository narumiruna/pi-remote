import AppKit
import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost

private enum CheckFailure: Error { case usage, assertion(Int), rejected(RemoteFault, Int), deadline }
private func require(_ value: Bool, line: Int = #line) throws { if !value { throw CheckFailure.assertion(line) } }
private func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Explicit provider exercise. All sessions and working files are temporary; tools and resources are disabled.
@main struct NativeProviderCheck {
    private static let device = UUID()

    static func main() async {
        do {
            try await run()
            print("PASS: native host provider image input, streaming, branching, compaction, queues, Stop and restart restoration.")
        } catch {
            if let failure = error as? CheckFailure { print("FAIL: \(failure). No instruction will be resent.") }
            else { print("FAIL: native provider check could not complete. No instruction will be resent.") }
            exit(1)
        }
    }

    private static func send(_ action: SessionAction, to host: HostCoordinator, line: Int = #line) async throws -> AppResult {
        let state = await host.state()
        let result = await host.handle(AppRequest(epoch: host.epoch, session: state.selected, action: action), device: device)
        if case .failure(let fault) = result { throw CheckFailure.rejected(fault, line) }
        return result
    }

    private static func wait(_ host: HostCoordinator, until predicate: (HostSnapshot) -> Bool) async throws -> HostSnapshot {
        for _ in 0..<6_000 {
            let state = await host.state()
            if let fault = state.error { throw CheckFailure.rejected(fault, #line) }
            try require(!state.messages.contains { $0.isError })
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure.deadline
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[2] == "--exercise-model",
              CommandLine.arguments[1].hasPrefix("/") else { throw CheckFailure.usage }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        try require(FileManager.default.isExecutableFile(atPath: pi.path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-remote-provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project/nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = folder.appendingPathComponent(".pi", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        // Keep a small recent span so a short synthetic run can exercise real
        // manual summarization without changing the user's global settings.
        try Data(#"{"compaction":{"enabled":false,"keepRecentTokens":128}}"#.utf8)
            .write(to: configuration.appendingPathComponent("settings.json"), options: .atomic)
        let wrapper = root.appendingPathComponent("isolated-pi")
        let script = """
        #!/bin/sh
        exec \(quoted(pi.path)) --offline --no-extensions --no-mcp --no-context-files --no-skills --no-prompt-templates --approve --no-tools "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let agent = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        let settings = agent.appendingPathComponent("settings.json")
        let settingsBefore = try settingsData(settings)
        let support = root.appendingPathComponent("support")
        let saved = try await exercise(support: support, wrapper: wrapper, folder: folder)
        // The first coordinator is out of scope, so its catalog lock is released before restart.
        try await restore(saved, support: support, wrapper: wrapper)
        try require(try settingsData(settings) == settingsBefore)
    }

    private static func settingsData(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private struct SavedSession {
        var session: UUID
        var directory: String
        var messages: [TranscriptMessage]
    }

    private static func exercise(support: URL, wrapper: URL, folder: URL) async throws -> SavedSession {
        let host = try HostCoordinator(support: support, executable: wrapper)
        do {
            let directory = try await host.directories.register(folder)
            _ = try await send(.createSession(directory: directory), to: host)
            let original = try await selected(host)
            _ = try await send(.prompt(text: "Reply with exactly READY. Do not use tools.", delivery: .prompt, image: fixtureImage()), to: host)
            let completed = try await wait(host) { state in
                state.phase == "idle" && state.messages.contains { $0.role == "assistant" && !$0.text.isEmpty && !$0.streaming }
            }
            guard case .preview(let lastText) = try await send(.lastAssistant, to: host) else { throw CheckFailure.assertion(#line) }
            try require(!lastText.text.isEmpty && !lastText.truncated && lastText.text.contains("READY"))
            let firstMessages = completed.messages
            try require(firstMessages.contains { $0.role == "user" })
            guard case .historyPage(let page) = try await send(.historyPage(cursor: nil), to: host),
                  let entry = page.items.first(where: { $0.canFork }) else { throw CheckFailure.assertion(#line) }
            _ = try await send(.clone, to: host)
            try require(try await selected(host) != original)
            try require(sameMessages(await host.state().messages, firstMessages))
            _ = try await send(.fork(entry: entry.id), to: host)
            try require(await host.state().draft?.contains("READY") == true)
            _ = try await send(.resumeSession(id: original), to: host)
            try require(sameMessages(await host.state().messages, firstMessages))

            let task = "List the integers 1 through 256, one per line. Do not use tools."
            let steer = "After the current response, reply with exactly STEERED."
            let followUp = "Reply with exactly FOLLOWED."
            _ = try await send(.prompt(text: task, delivery: .prompt, image: nil), to: host)
            _ = try await wait(host) { $0.working }
            _ = try await send(.prompt(text: steer, delivery: .steer, image: nil), to: host)
            _ = try await send(.prompt(text: followUp, delivery: .followUp, image: nil), to: host)
            var observedLiveText = false
            _ = try await wait(host) { state in
                if state.messages.contains(where: { $0.role == "assistant" && $0.streaming && !$0.text.isEmpty }) {
                    observedLiveText = true
                }
                return state.phase == "idle" && state.messages.contains { $0.role == "user" && $0.text == steer } &&
                    state.messages.contains { $0.role == "user" && $0.text == followUp } &&
                    state.messages.last.map { $0.role == "assistant" && !$0.streaming } == true
            }
            try require(observedLiveText)
            _ = try await send(.prompt(text: "List the integers 1 through 10000, one per line. Do not use tools.", delivery: .prompt, image: nil), to: host)
            _ = try await wait(host) { $0.working }
            _ = try await send(.prompt(text: "Reply QUEUED-STEER.", delivery: .steer, image: nil), to: host)
            _ = try await send(.prompt(text: "Reply QUEUED-FOLLOWUP.", delivery: .followUp, image: nil), to: host)
            _ = try await send(.stop, to: host)
            let stopped = await host.state()
            try require(stopped.phase == "idle")
            try await Task.sleep(for: .seconds(1))
            try require(await host.state().phase == "idle")
            let afterStop = await host.state()
            try require(afterStop.messages.filter { $0.role == "user" }.map(\.text) == stopped.messages.filter { $0.role == "user" }.map(\.text))
            let updates = await host.updates()
            let compacting = Task {
                for await update in updates {
                    if update.phase == "compacting" { return true }
                    if Task.isCancelled { return false }
                }
                return false
            }
            defer { compacting.cancel() }
            _ = try await send(.compact(instructions: "Summarize this synthetic verification conversation. Preserve the READY, STEERED and FOLLOWED checks."), to: host)
            try require(await compacting.value)
            let state = await host.state()
            try require(state.phase == "idle")
            guard case .statistics(let usage) = try await send(.statistics, to: host) else { throw CheckFailure.assertion(#line) }
            try usage.validate()
            try require(usage.tokens.total > 0 && usage.userMessages > 0)
            try require(usage.contextUsage?.tokens == nil && usage.contextUsage?.percent == nil)
            guard case .historyPage(let compactedHistory) = try await send(.historyPage(cursor: nil), to: host) else { throw CheckFailure.assertion(#line) }
            try require(compactedHistory.items.contains { $0.kind == "compaction" && !$0.text.isEmpty })
            guard let info = state.sessions.first(where: { $0.id == original }) else { throw CheckFailure.assertion(#line) }
            try require(info.directory == folder.resolvingSymlinksInPath().path && !info.interrupted)
            let saved = SavedSession(session: original, directory: info.directory, messages: state.messages)
            await host.shutdown()
            return saved
        } catch { await host.shutdown(); throw error }
    }

    private static func fixtureImage() throws -> ImageAttachment {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bytes = bitmap.bitmapData else { throw CheckFailure.assertion(#line) }
        bytes.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure.assertion(#line) }
        return ImageAttachment(data: data, mimeType: "image/png")
    }

    private static func selected(_ host: HostCoordinator) async throws -> UUID {
        guard let id = await host.state().selected else { throw CheckFailure.assertion(#line) }
        return id
    }

    private static func sameMessages(_ lhs: [TranscriptMessage], _ rhs: [TranscriptMessage]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.role == $1.role && $0.text == $1.text && $0.thinking == $1.thinking && $0.isError == $1.isError &&
                $0.streaming == $1.streaming && $0.truncated == $1.truncated
        }
    }

    private static func restore(_ saved: SavedSession, support: URL, wrapper: URL) async throws {
        let host = try HostCoordinator(support: support, executable: wrapper)
        do {
            try require(await host.state().selected == nil)
            _ = try await send(.resumeSession(id: saved.session), to: host)
            let state = await host.state()
            try require(state.selected == saved.session && state.phase == "idle")
            try require(state.sessions.first { $0.id == saved.session }?.directory == saved.directory)
            try require(!state.messages.isEmpty && sameMessages(state.messages, saved.messages))
            try require(state.sessions.first { $0.id == saved.session }?.interrupted == false)
            _ = try await send(.closeSession, to: host)
            let closed = await host.state()
            try require(closed.selected == nil && closed.sessions == state.sessions && closed.messages.isEmpty)
            _ = try await send(.resumeSession(id: saved.session), to: host)
            try require(sameMessages(await host.state().messages, saved.messages))
            await host.shutdown()
        } catch { await host.shutdown(); throw error }
    }
}
