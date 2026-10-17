import Foundation
import PiRemoteCore
import Testing
@testable import PiRemoteHost

@Suite struct PiLaunchEnvironmentTests {
    private func executable(_ path: URL, text: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

    @Test func guiLaunchFindsTheStableFnmDefaultWithoutReadingShellConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pi = root.appendingPathComponent("pi/bin/pi")
        try executable(pi, text: "#!/usr/bin/env node\nconsole.log('1.3.0');\n")
        let installation = root.appendingPathComponent("node installation")
        try executable(installation.appendingPathComponent("bin/node"), text: "#!/bin/sh\nprintf '1.3.0\\n'\n")
        let alias = root.appendingPathComponent("home/.local/share/fnm/aliases/default")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: installation)
        var environment = PiLaunchEnvironment.make(executable: pi, inherited: ["PATH": "/usr/bin:/bin"], home: root.appendingPathComponent("home"))
        let bin = alias.appendingPathComponent("bin").path
        #expect(environment["PATH"]?.components(separatedBy: ":").contains(bin) == true)
        // Restrict the process check to the discovered default and system tools;
        // another Node installation on a developer's machine must not mask it.
        environment["PATH"] = bin + ":/usr/bin:/bin"
        try PiLaunchEnvironment.validate(executable: pi, environment: environment)
        let result = try await LocalCommand.run(pi.path, ["--version"], directory: root, limit: 256, environment: environment)
        #expect(String(decoding: result.0, as: UTF8.self) == "1.3.0\n")
        #expect(!result.1)
    }

    @Test func inheritedNodeSelectionPrecedesFnmFallbackAndPathsStayAbsolute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("custom fnm/aliases/default/bin")
        try executable(bin.appendingPathComponent("node"), text: "#!/bin/sh\nexit 0\n")
        let selected = root.appendingPathComponent("selected/bin").path
        let environment = PiLaunchEnvironment.make(executable: root.appendingPathComponent("pi"),
            inherited: ["PATH": selected + ":/usr/bin::relative/path:" + selected,
                        "FNM_DIR": root.appendingPathComponent("custom fnm").path, "FIXTURE_VALUE": "preserved"], home: root)
        let paths = try #require(environment["PATH"]).components(separatedBy: ":")
        #expect(try #require(paths.firstIndex(of: selected)) < #require(paths.firstIndex(of: bin.path)))
        #expect(paths.filter { $0 == selected }.count == 1)
        #expect(paths.allSatisfy { $0.hasPrefix("/") })
        #expect(environment["FIXTURE_VALUE"] == "preserved")
    }

    @Test func missingNodeHasASpecificErrorButNativeLaunchersDoNotRequireNode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pi = root.appendingPathComponent("pi")
        try executable(pi, text: "#!/usr/bin/env node\n")
        #expect(throws: RemoteFault.nodeUnavailable) {
            try PiLaunchEnvironment.validate(executable: pi, environment: ["PATH": root.appendingPathComponent("empty").path])
        }
        try executable(pi, text: "#!/bin/sh\nexit 0\n")
        try PiLaunchEnvironment.validate(executable: pi, environment: ["PATH": ""])
        #expect(throws: RemoteFault.piLaunchFailed) {
            try PiLaunchEnvironment.validate(executable: root.appendingPathComponent("missing"), environment: [:])
        }
    }

    @Test func failedPiVersionCheckReportsLaunchFailureInsteadOfConnectionFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pi = root.appendingPathComponent("pi")
        try executable(pi, text: "#!/bin/sh\nexit 1\n")
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: pi)
        await host.inspectPi()
        #expect(await host.state().error == .piLaunchFailed)
        let directory = try await host.directories.register(root)
        let result = await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: UUID())
        #expect(result == .failure(.piLaunchFailed))
        #expect(await host.state().sessions.isEmpty)
        #expect(await host.state().selected == nil)
        await host.shutdown()
    }
}
