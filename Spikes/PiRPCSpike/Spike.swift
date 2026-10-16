import Foundation
import PiRemoteCore
import PiRPC

private enum SpikeFailure: Error {
    case usage
    case deadline
    case assertion(String)
}

private actor RunMonitor {
    private(set) var settledCount = 0
    private(set) var deltaCount = 0
    private(set) var providerFailed = false

    func receive(_ event: JSONValue) {
        if event["type"]?.string == "agent_settled" { settledCount += 1 }
        if event["type"]?.string == "message_update",
           event["assistantMessageEvent"]?["type"]?.string == "text_delta" { deltaCount += 1 }
        if event["type"]?.string == "message_end",
           event["message"]?["stopReason"]?.string == "error" { providerFailed = true }
    }

    func waitForSettlement(after count: Int) async throws {
        for _ in 0..<6_000 {
            if settledCount > count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SpikeFailure.deadline
    }
}

@main
struct Spike {
    static func main() async {
        do { try await run() }
        catch {
            // Do not print raw Pi errors, paths, prompts, or provider diagnostics.
            fputs("RPC spike failed: \(type(of: error)). No prompt will be retried automatically.\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 || (args.count == 3 && args[2] == "--exercise-model") else {
            fputs("Usage: PiRPCSpike <absolute-pi-executable> <working-directory> [--exercise-model]\n", stderr)
            throw SpikeFailure.usage
        }
        guard args[0].hasPrefix("/"), args[1].hasPrefix("/") else { throw SpikeFailure.usage }
        let executable = URL(fileURLWithPath: args[0])
        let workingDirectory = URL(fileURLWithPath: args[1], isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw SpikeFailure.usage }
        let sessions = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: sessions) }
        // Isolate the spike from project trust, tools, installed extensions, and MCP side effects.
        let common = [
            "--mode", "rpc", "--no-extensions", "--no-mcp", "--no-context-files",
            "--no-skills", "--no-prompt-templates", "--no-approve", "--no-tools", "--offline",
            "--session-dir", sessions.path
        ]
        let child = try RPCProcess(
            executable: executable,
            arguments: common + ["--session-id", UUID().uuidString],
            workingDirectory: workingDirectory
        )
        let monitor = RunMonitor()
        let observer = Task {
            for try await event in child.events { await monitor.receive(event) }
        }
        do {
            let state = try await child.request("get_state")
            guard state["isStreaming"]?.bool == false else { throw SpikeFailure.assertion("initial state") }
            let models = try await child.request("get_available_models")
            let levels = try await child.request("get_available_thinking_levels")
            let commands = try await child.request("get_commands")
            print("RPC metadata passed: models=\(models["models"]?.array?.count ?? 0), thinking-levels=\(levels["levels"]?.array?.count ?? 0), isolated-commands=\(commands["commands"]?.array?.count ?? 0).")
            guard args.count == 3 else {
                guard await child.shutdown() else { throw SpikeFailure.assertion("shutdown") }
                _ = await observer.result
                print("No model request was sent. Model streaming and persistence were not tested.")
                return
            }

            let before = await monitor.settledCount
            let response = try await child.request("prompt", fields: [
                "message": .string("Reply with exactly the word READY. Do not use tools.")
            ])
            guard response["disposition"]?.string == "started" else {
                throw SpikeFailure.assertion("prompt disposition")
            }
            try await monitor.waitForSettlement(after: before)
            guard await !monitor.providerFailed, await monitor.deltaCount > 0 else {
                throw SpikeFailure.assertion("model output")
            }
            let completed = try await child.request("get_state")
            guard let sessionFile = completed["sessionFile"]?.string,
                  URL(fileURLWithPath: sessionFile).deletingLastPathComponent().standardizedFileURL == sessions.standardizedFileURL,
                  FileManager.default.fileExists(atPath: sessionFile) else {
                throw SpikeFailure.assertion("persistent session")
            }
            let sessionData = try Data(contentsOf: URL(fileURLWithPath: sessionFile))
            guard let headerData = sessionData.split(separator: 0x0A).first,
                  let header = try? JSONDecoder().decode(JSONValue.self, from: Data(headerData)),
                  let cwd = header["cwd"]?.string,
                  URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == workingDirectory.resolvingSymlinksInPath() else {
                throw SpikeFailure.assertion("working directory")
            }
            // Start a second run, then explicitly clear the queue and stop it.
            _ = try await child.request("prompt", fields: [
                "message": .string("Count slowly from one to one hundred, with one number per line.")
            ])
            let active = try await child.request("get_state")
            guard active["isStreaming"]?.bool == true else { throw SpikeFailure.assertion("active run") }
            try await child.stopWork()
            guard await child.shutdown() else { throw SpikeFailure.assertion("shutdown") }
            _ = await observer.result

            let resumed = try RPCProcess(
                executable: executable,
                arguments: common + ["--session", sessionFile],
                workingDirectory: workingDirectory
            )
            do {
                let state = try await resumed.request("get_state")
                let history = try await resumed.request("get_messages")
                guard state["sessionId"] == completed["sessionId"],
                      let messages = history["messages"]?.array, !messages.isEmpty else {
                    throw SpikeFailure.assertion("restored history")
                }
                guard await resumed.shutdown() else { throw SpikeFailure.assertion("resumed shutdown") }
            } catch { await resumed.shutdown(); throw error }
            print("Model streaming, agent_settled, clear_queue → abort → idle, and persisted-session resumption passed.")
        } catch {
            await child.shutdown()
            _ = await observer.result
            throw error
        }
    }
}
