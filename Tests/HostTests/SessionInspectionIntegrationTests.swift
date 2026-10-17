import Foundation
import PiRemoteCore
import PiRemoteHost
import Testing

private struct InspectionIntegrationFixture {
    let root: URL
    let host: HostCoordinator
    let device = UUID()
    let session: UUID
    let image: Data

    static func start(mode: String = "normal", count: Int = 205) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-inspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let image = try outputImagePNG(seed: 21)
        let timestamp = "2024-12-03T14:00:00.000Z"
        var entries: [JSONValue] = [], children: [JSONValue] = [], options: [JSONValue] = []
        for index in 0..<count {
            let id = "e\(index)"
            let text = index == 2 ? String(repeating: "Abandoned 日本語 ", count: 100) : "Message \(index)"
            let content: JSONValue = index == 3 ? .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(image.base64EncodedString())])]) : .string(text)
            let entry: JSONValue = .object(["id": .string(id), "parentId": index == 0 ? .null : .string("e0"),
                                            "type": .string("message"), "timestamp": .string(timestamp),
                                            "message": .object(["role": .string(index == 1 ? "assistant" : "user"), "content": content])])
            entries.append(entry)
            if index != 1 && index != 3 { options.append(.object(["entryId": .string(id), "text": .string(text)])) }
            if index > 0 { children.append(.object(["entry": entry, "children": .array([])])) }
        }
        let rootNode: JSONValue = .object(["entry": entries[0], "children": .array(children), "label": .string("Actual bookmark"),
                                            "labelTimestamp": .string("2024-12-03T14:30:00.125Z")])
        let tree: JSONValue = .object(["tree": .array([rootNode]), "leafId": .string("e1")])
        var changedRoot = rootNode
        if case .object(var object) = rootNode { object["label"] = .string("Changed bookmark"); changedRoot = .object(object) }
        let changed: JSONValue = .object(["tree": .array([changedRoot]), "leafId": .string("e1")])
        try JSONEncoder().encode(tree).write(to: root.appendingPathComponent("tree.json"))
        try JSONEncoder().encode(changed).write(to: root.appendingPathComponent("changed.json"))
        try JSONEncoder().encode(JSONValue.object(["messages": .array(options)])).write(to: root.appendingPathComponent("forks.json"))
        try JSONEncoder().encode(JSONValue.object(["entries": .array(entries), "leafId": .string("e1")])).write(to: root.appendingPathComponent("all.json"))
        var lines = Data()
        for entry in entries { lines.append(try JSONEncoder().encode(entry)); lines.append(10) }
        try lines.write(to: root.appendingPathComponent("entries.jsonl"))
        try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("fake-pi")
        let script = #"""
        #!/bin/bash
        if [ "$1" = --version ]; then printf 'inspection-fixture\n'; exit 0; fi
        base=$(/usr/bin/dirname "$0")
        mode=$(/bin/cat "$base/mode")
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --session-dir) folder=$2; shift 2 ;;
                --session-id) session=$2; shift 2 ;;
                --session) file=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        if [ -z "$file" ]; then
            file="$folder/fixture.jsonl"
            printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
            /bin/cat "$base/entries.jsonl" >> "$file"
        fi
        streaming=false
        tree_count=0
        reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
        while IFS= read -r line; do
            id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
            command=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
            printf '%s\n' "$command" >> "$base/commands"
            case "$command" in
                get_state) reply "{\"model\":{\"id\":\"fixture\",\"provider\":\"test\"},\"thinkingLevel\":\"off\",\"steeringMode\":\"all\",\"followUpMode\":\"all\",\"autoCompactionEnabled\":true,\"pendingMessageCount\":0,\"isStreaming\":$streaming,\"isCompacting\":false,\"sessionId\":\"$session\",\"sessionFile\":\"$file\"}" ;;
                get_available_models) reply '{"models":[]}' ;;
                get_available_thinking_levels) reply '{"levels":["off"]}' ;;
                get_commands) reply '{"commands":[]}' ;;
                get_messages) reply '{"messages":[]}' ;;
                get_entries) reply "$(/bin/cat "$base/all.json")" ;;
                get_fork_messages) reply "$(/bin/cat "$base/forks.json")" ;;
                get_tree)
                    tree_count=$((tree_count + 1))
                    if [ "$mode" = hold ]; then
                        : > "$base/tree-read"
                        deadline=$((SECONDS + 5))
                        while [ ! -f "$base/release-tree" ] && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.01; done
                    fi
                    if [ "$mode" = working ]; then streaming=true; printf '{"type":"agent_start"}\n'; /bin/sleep 0.05; fi
                    if [ "$mode" = changed ] && [ "$tree_count" -gt 1 ]; then reply "$(/bin/cat "$base/changed.json")"; else reply "$(/bin/cat "$base/tree.json")"; fi ;;
                fork)
                    session=forked
                    file="$folder/forked.jsonl"
                    printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
                    /bin/cat "$base/entries.jsonl" >> "$file"
                    reply '{"cancelled":false,"text":"Abandoned fork draft"}' ;;
                clear_queue) reply '{}' ;;
                abort) streaming=false; printf '{"type":"agent_settled","aborted":true}\n'; reply '{}' ;;
                *) reply '{}' ;;
            esac
        done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
        do {
            let directory = try await host.directories.register(root)
            let state = await host.state()
            #expect(await host.handle(AppRequest(epoch: state.epoch, session: nil, action: .createSession(directory: directory)), device: UUID()) == .ok)
            let session = try #require(await host.state().selected)
            return Self(root: root, host: host, session: session, image: image)
        } catch { await host.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }

    func request(_ action: SessionAction, session override: UUID? = nil) async -> AppResult {
        await host.handle(AppRequest(epoch: host.epoch, session: override ?? session, action: action), device: device)
    }
    func close() async { await host.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1))) func inspectionIntegrationPagesAuthoritativeTreeAndPreservesFullPreviewsAndImages() async throws {
    let fixture = try await InspectionIntegrationFixture.start()
    do {
        guard case .sessionTree(let first) = await fixture.request(.sessionTree(cursor: nil)) else { throw RemoteFault.invalidRequest }
        #expect(first.items.count == 100 && first.leafID == "e1")
        #expect(first.items[0].node.label == "Actual bookmark")
        #expect(first.items[0].node.labelTimestamp == "2024-12-03T14:30:00.125Z")
        #expect(first.items[2].node.canFork && first.items[2].node.truncated)
        #expect(!first.items[1].node.canFork && !first.items[3].node.canFork)
        #expect(first.items[2].node.parentID == "e0")
        let preview = try #require(first.items[2].preview)
        guard case .preview(let text) = await fixture.request(.historyEntry(id: preview)) else { throw RemoteFault.invalidRequest }
        #expect(text.text.utf8.count > 512 && !text.truncated)
        let imageToken = try #require(first.items[3].preview)
        guard case .preview(let imagePreview) = await fixture.request(.historyEntry(id: imageToken)) else { throw RemoteFault.invalidRequest }
        let imageID = try #require(imagePreview.images?.first?.id)
        #expect(await fixture.request(.outputImage(id: imageID)) == .image(ImageAttachment(data: fixture.image, mimeType: "image/png")))
        guard case .sessionTree(let second) = await fixture.request(.sessionTree(cursor: first.next)),
              case .sessionTree(let third) = await fixture.request(.sessionTree(cursor: second.next)) else { throw RemoteFault.invalidRequest }
        #expect(second.items.count == 100 && third.items.count == 5 && third.next == nil)
        #expect(Set((first.items + second.items + third.items).map(\.id)).count == 205)
        guard case .sessionTree(let repeated) = await fixture.request(.sessionTree(cursor: first.next)) else { throw RemoteFault.invalidRequest }
        #expect(repeated.items.map(\.node) == second.items.map(\.node))
        let encoded = try AppPacket(AppResult.sessionTree(first)).encode()
        #expect(encoded.count < 1_024 * 1_024)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(fixture.root.path))
        guard case .historyPage(let history) = await fixture.request(.historyPage(cursor: nil)),
              case .history(let entries) = await fixture.request(.history) else { throw RemoteFault.invalidRequest }
        #expect(history.items.count == 100 && history.next != nil)
        #expect(history.items.allSatisfy { !$0.canFork })
        #expect(entries.count == 205 && entries.allSatisfy { !$0.canFork })
        #expect(await fixture.request(.sessionTree(cursor: UUID())) == .failure(.expired))
        let commands = try String(contentsOf: fixture.root.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").map(String.init)
        let start = try #require(commands.firstIndex(of: "get_tree"))
        #expect(Array(commands[start..<(start + 3)]) == ["get_tree", "get_fork_messages", "get_tree"])
        #expect(commands.filter { $0 == "get_tree" }.count == 2)
        #expect(commands.contains("get_entries"))
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func inspectionIntegrationRevalidatesForkAndAcceptsAbandonedBranch() async throws {
    let fixture = try await InspectionIntegrationFixture.start()
    do {
        #expect(await fixture.request(.fork(entry: "e3")) == .failure(.invalidRequest))
        #expect(await fixture.request(.fork(entry: "absent")) == .failure(.invalidRequest))
        guard case .sessionTree(let first) = await fixture.request(.sessionTree(cursor: nil)) else { throw RemoteFault.invalidRequest }
        // A previously displayed option is no longer authoritative after Pi removes it.
        try Data(#"{"messages":[]}"#.utf8).write(to: fixture.root.appendingPathComponent("forks.json"))
        #expect(await fixture.request(.fork(entry: "e2")) == .failure(.invalidRequest))
        try Data(#"{"messages":[{"entryId":"e2","text":"Current fork text"}]}"#.utf8).write(to: fixture.root.appendingPathComponent("forks.json"))
        #expect(await fixture.request(.fork(entry: "e2")) == .ok)
        let state = await fixture.host.state()
        #expect(state.selected != fixture.session && state.draft == "Abandoned fork draft")
        #expect(await fixture.request(.sessionTree(cursor: first.next), session: state.selected) == .failure(.expired))
        let stalePreview = try #require(first.items.first?.preview)
        #expect(await fixture.request(.historyEntry(id: stalePreview), session: state.selected) == .failure(.expired))
        let commands = try String(contentsOf: fixture.root.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n")
        #expect(commands.filter { $0 == "fork" }.count == 1)
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func inspectionIntegrationRejectsChangedSnapshotsAndWorkingRaces() async throws {
    for mode in ["changed", "working"] {
        let fixture = try await InspectionIntegrationFixture.start(mode: mode)
        let result = await fixture.request(.sessionTree(cursor: nil))
        if mode == "changed" { #expect(result == .failure(.conflict)) }
        else { #expect(result == .failure(.busy) || result == .failure(.conflict)) }
        await fixture.close()
    }
}

@Test(.timeLimit(.minutes(1))) func inspectionIntegrationSerializesReadsAndScopesCursorsToFileAndSession() async throws {
    let fixture = try await InspectionIntegrationFixture.start(mode: "hold")
    do {
        let pending = Task { await fixture.request(.sessionTree(cursor: nil)) }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("tree-read").path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("tree-read").path))
        #expect(await fixture.request(.rename(name: "Concurrent rename")) == .failure(.busy))
        #expect(await fixture.request(.sessionTree(cursor: nil)) == .failure(.busy))
        try Data().write(to: fixture.root.appendingPathComponent("release-tree"))
        guard case .sessionTree(let page) = await pending.value else { throw RemoteFault.invalidRequest }
        #expect(await fixture.request(.sessionTree(cursor: page.next), session: UUID()) == .failure(.conflict))
        let folder = fixture.root.appendingPathComponent("support/pi-sessions/" + fixture.session.uuidString)
        let file = folder.appendingPathComponent("fixture.jsonl")
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd(); try writer.write(contentsOf: Data("\n".utf8)); try writer.close()
        #expect(await fixture.request(.sessionTree(cursor: page.next)) == .failure(.expired))
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func inspectionIntegrationBoundsRetainedSnapshots() async throws {
    let fixture = try await InspectionIntegrationFixture.start()
    do {
        guard case .sessionTree(let first) = await fixture.request(.sessionTree(cursor: nil)) else { throw RemoteFault.invalidRequest }
        _ = await fixture.request(.sessionTree(cursor: nil))
        _ = await fixture.request(.sessionTree(cursor: nil))
        #expect(await fixture.request(.sessionTree(cursor: first.next)) == .failure(.expired))
    } catch { await fixture.close(); throw error }
    await fixture.close()
}
