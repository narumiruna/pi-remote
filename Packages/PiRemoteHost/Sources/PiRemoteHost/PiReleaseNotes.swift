import CryptoKit
import Darwin
import Foundation
import PiRemoteCore

/// Read only the selected npm-style Pi installation's declared changelog.
enum PiReleaseNotes {
    private struct Manifest: Decodable { var name: String; var version: String; var bin: [String: String] }

    static func page(executable: URL, offset: Int, revision: String?) throws -> ReleaseNotesPage {
        guard offset >= 0, offset <= ReleaseNotesPage.maximumDocumentBytes,
              offset == 0 || revision != nil else { throw RemoteFault.invalidRequest }
        let (root, version) = try installation(executable)
        let bytes = try read(root.appendingPathComponent("CHANGELOG.md"), limit: ReleaseNotesPage.maximumDocumentBytes)
        guard String(data: bytes, encoding: .utf8) != nil else { throw RemoteFault.incompatiblePi }
        var hash = SHA256()
        hash.update(data: Data(version.utf8)); hash.update(data: Data([0])); hash.update(data: bytes)
        let current = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard revision == nil || revision == current else { throw RemoteFault.expired }
        guard offset <= bytes.count, offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else { throw RemoteFault.invalidRequest }
        let end = min(offset + ReleaseNotesPage.maximumPageBytes, bytes.count)
        for adjustment in 0...3 where end - adjustment >= offset {
            let stop = end - adjustment
            if let text = String(data: bytes[offset..<stop], encoding: .utf8) {
                let page = ReleaseNotesPage(version: version, revision: current, offset: offset, totalBytes: bytes.count,
                                            text: text, next: stop == bytes.count ? nil : stop)
                try page.validate()
                return page
            }
        }
        throw RemoteFault.incompatiblePi
    }

    private static func installation(_ executable: URL) throws -> (URL, String) {
        let actual = executable.resolvingSymlinksInPath().standardizedFileURL
        var root = actual.deletingLastPathComponent()
        for _ in 0..<4 {
            let file = root.appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let manifest: Manifest
                do { manifest = try JSONDecoder().decode(Manifest.self, from: read(file, limit: 65_536)) }
                catch let fault as RemoteFault { throw fault }
                catch { throw RemoteFault.unsupportedFeature }
                if manifest.name == "@earendil-works/pi-coding-agent" {
                    guard let bin = manifest.bin["pi"], !bin.hasPrefix("/"), !bin.contains("\0"),
                          !manifest.version.isEmpty, manifest.version.utf8.count <= 128 else { throw RemoteFault.unsupportedFeature }
                    let declared = root.appendingPathComponent(bin).resolvingSymlinksInPath().standardizedFileURL
                    guard declared.path.hasPrefix(root.path + "/"), declared.path == actual.path else { throw RemoteFault.unsupportedFeature }
                    return (root, manifest.version)
                }
            }
            root.deleteLastPathComponent()
        }
        throw RemoteFault.unsupportedFeature
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == EACCES || errno == EPERM || errno == ELOOP ? RemoteFault.permissionDenied : RemoteFault.unsupportedFeature
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RemoteFault.unsupportedFeature }
        guard info.st_size <= limit else { throw RemoteFault.tooLarge }
        var data = Data()
        while data.count <= limit {
            let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw RemoteFault.tooLarge
    }
}
