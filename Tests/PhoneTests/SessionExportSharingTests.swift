import CoreTransferable
import PiRemoteCore
import UniformTypeIdentifiers
import XCTest
@testable import PiRemote

@MainActor
final class SessionExportSharingTests: XCTestCase {
    func testTransferPreservesTheReviewedBytesTypeAndFilename() async throws {
        guard #available(iOS 18.2, *) else { throw XCTSkip("Transfer export inspection requires iOS 18.2.") }
        let jsonl = Data(#"{"type":"session","version":3,"id":"share-fixture","cwd":"/tmp"}"#.utf8)
        let values = [SessionExport(data: Data("<!doctype html><html>Private 🦉 fixture</html>".utf8)),
                      SessionExport(data: jsonl, format: .jsonl)]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        for value in values {
            let document = SessionExportDocument(value)
            XCTAssertEqual(document.exportedContentTypes(), [document.contentType])
            XCTAssertEqual(document.suggestedFilename, document.filename)
            let data = try await document.exported(as: document.contentType)
            XCTAssertEqual(data, value.data)
            let file = try await document.export(to: folder, contentType: document.contentType)
            XCTAssertEqual(file.lastPathComponent, document.filename)
            XCTAssertEqual(try Data(contentsOf: file), value.data)
            XCTAssertEqual(file.pathExtension, value.format == .html ? "html" : "jsonl")
        }
    }

    func testTransferRejectsInvalidOrOversizedExports() async throws {
        guard #available(iOS 18.2, *) else { throw XCTSkip("Transfer export inspection requires iOS 18.2.") }
        for value in [SessionExport(data: Data()), SessionExport(data: Data([0xff])),
                      SessionExport(data: Data("not JSONL".utf8), format: .jsonl),
                      SessionExport(data: Data(repeating: 65, count: SessionExport.maximumBytes + 1))] {
            let document = SessionExportDocument(value)
            do {
                _ = try await document.exported(as: document.contentType)
                XCTFail("Invalid exports must not enter the service transfer.")
            } catch { continue }
        }
    }
}
