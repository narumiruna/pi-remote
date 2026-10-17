import Foundation
import PiRemoteCore
import PiRemoteHost
import Testing

@Test func explicitDirectoryPathsResolveCanonicallyWithoutStartingPi() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("project with spaces; $HOME")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    let registry = DirectoryRegistry()
    let page = try await registry.list(path: alias.path)
    #expect(page.path == target.resolvingSymlinksInPath().path)
    #expect(try await registry.resolve(page.id).url.path == page.path)
    #expect(try await registry.list(id: page.id, cursor: nil).path == page.path)
    #expect(try await registry.list(path: "~").path == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)
    #expect(try await registry.list(path: "~/").path == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)

    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: URL(fileURLWithPath: "/missing-pi"))
    let result = await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .directoryAtPath(path: target.path)), device: UUID())
    guard case .directories(let listed) = result else { Issue.record("Expected a directory listing without Pi"); await host.shutdown(); return }
    #expect(listed.path == page.path)
    let snapshot = await host.state()
    #expect(snapshot.selected == nil)
    #expect(snapshot.sessions.isEmpty)
    await host.shutdown()
}

@Test func explicitDirectoryPathsRejectMalformedMissingAndNonDirectoryTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = DirectoryRegistry()
    for path in ["", "relative/path", "~other/project", "file:///tmp", "$HOME/project", "/tmp/\0bad", "/" + String(repeating: "é", count: 2_048)] {
        await #expect(throws: RemoteFault.invalidRequest) { try await registry.list(path: path) }
    }
    await #expect(throws: RemoteFault.staleDirectory) { try await registry.list(path: root.appendingPathComponent("missing").path) }
    let file = root.appendingPathComponent("file")
    try Data("fixture".utf8).write(to: file)
    await #expect(throws: RemoteFault.staleDirectory) { try await registry.list(path: file.path) }
    let loop = root.appendingPathComponent("loop")
    try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
    await #expect(throws: RemoteFault.staleDirectory) { try await registry.list(path: loop.path) }
}

@Test func directoryPathActionIsReadOnlySessionIndependentAndCodable() throws {
    let action = SessionAction.directoryAtPath(path: "/Users/fixture/project with spaces")
    #expect(!action.mutates)
    #expect(!action.needsSession)
    #expect(!action.changesSession)
    #expect(try JSONDecoder().decode(SessionAction.self, from: JSONEncoder().encode(action)) == action)
}
