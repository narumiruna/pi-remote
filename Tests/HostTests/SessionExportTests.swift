import Foundation
import PiRemoteCore
@testable import PiRemoteHost
import Testing

@Test func jsonlExportUsesTheLiveLeafAndExcludesAbandonedBranches() throws {
    func entry(_ id: String, parent: JSONValue, text: String) -> JSONValue {
        .object(["type": .string("message"), "id": .string(id), "parentId": parent,
                 "message": .object(["role": .string("user"), "content": .string(text)])])
    }
    let root = entry("root", parent: .null, text: "Shared root")
    let left = entry("left", parent: .string("root"), text: "Abandoned fixture")
    let right = entry("right", parent: .string("root"), text: "Selected fixture")
    let last = entry("last", parent: .string("left"), text: "Later abandoned fixture")
    let entries: JSONValue = .array([root, left, right, last])
    let result = try SessionExporter.branch(.object(["entries": entries, "leafId": .string("right")]), piID: "branch-fixture", directory: "/tmp")
    let records = try result.data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    #expect(result.format == .jsonl && records.count == 3)
    #expect(records[0]["id"]?.string == "branch-fixture" && records[0]["cwd"]?.string == "/tmp")
    #expect(records[0]["timestamp"]?.string != nil)
    #expect(records[1] == root && records[2] == right)
    #expect(!String(decoding: result.data, as: UTF8.self).contains("Abandoned fixture"))
    let empty = try SessionExporter.branch(.object(["entries": entries, "leafId": .null]), piID: "branch-fixture", directory: "/tmp")
    #expect(try SessionImport(data: empty.data).entryCount == 0)
    #expect(throws: RemoteFault.incompatiblePi) {
        try SessionExporter.branch(.object(["entries": entries, "leafId": .string("missing")]), piID: "branch-fixture", directory: "/tmp")
    }
    #expect(throws: RemoteFault.incompatiblePi) {
        try SessionExporter.branch(.object(["entries": .array([root, root]), "leafId": .string("root")]), piID: "branch-fixture", directory: "/tmp")
    }
}
