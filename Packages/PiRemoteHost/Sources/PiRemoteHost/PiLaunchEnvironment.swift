import Foundation
import PiRemoteCore

/// GUI apps do not inherit the shell initialization used by Node version managers.
enum PiLaunchEnvironment {
    static func make(executable: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        var environment = inherited
        var paths = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        paths += (inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").components(separatedBy: ":")
        var roots = [home.appendingPathComponent(".local/share/fnm"),
                     home.appendingPathComponent("Library/Application Support/fnm")]
        if let root = inherited["FNM_DIR"], root.hasPrefix("/") { roots.insert(URL(fileURLWithPath: root), at: 0) }
        // Use the user's stable default alias, not an arbitrary installed version
        // or an expiring fnm_multishells directory. Existing PATH order wins.
        for root in roots {
            let bin = root.appendingPathComponent("aliases/default/bin")
            if FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("node").path) { paths.append(bin.path) }
        }
        var seen = Set<String>()
        environment["PATH"] = paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    static func validate(executable: URL, environment: [String: String]) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw RemoteFault.piLaunchFailed }
        let prefix: Data
        do {
            let file = try FileHandle(forReadingFrom: executable)
            defer { try? file.close() }
            prefix = try file.read(upToCount: 256) ?? Data()
        } catch { throw RemoteFault.piLaunchFailed }
        let firstLine = String(decoding: prefix.prefix(while: { $0 != 10 }), as: UTF8.self)
        let words = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
        let needsNode = words.starts(with: ["#!/usr/bin/env", "node"]) || words.starts(with: ["#!/usr/bin/env", "-S", "node"])
        if needsNode {
            let paths = (environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
            guard paths.contains(where: { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent("node").path) }) else {
                throw RemoteFault.nodeUnavailable
            }
        }
    }
}
