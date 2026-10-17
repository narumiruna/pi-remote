import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost

private enum CheckFailure: Error { case arguments, mismatch }

/// Read every installed changelog byte through the typed native host, without starting Pi.
@main struct NativeReleaseNotesCheck {
    static func main() async {
        do { try await run() }
        catch { print("FAIL: installed release-note verification failed."); exit(1) }
    }
    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.arguments }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let resource = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")
        let expected = try Data(contentsOf: resource)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("pi-remote-notes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let host = try HostCoordinator(support: support, executable: executable)
        do {
            var actual = Data(), offset = 0, pages = 0
            var revision: String?
            repeat {
                let request = AppRequest(epoch: host.epoch, session: nil, action: .releaseNotes(offset: offset, revision: revision))
                guard case .releaseNotes(let page) = await host.handle(request, device: UUID()) else { throw CheckFailure.mismatch }
                try page.validate()
                guard page.offset == offset else { throw CheckFailure.mismatch }
                actual.append(contentsOf: page.text.utf8); revision = page.revision; pages += 1
                guard let next = page.next else { break }
                offset = next
            } while true
            guard actual == expected else { throw CheckFailure.mismatch }
            await host.shutdown()
            print("PASS: installed release notes match all \(actual.count) bytes across \(pages) native pages; no Pi child or provider request.")
        } catch { await host.shutdown(); throw error }
    }
}
