import Foundation
import PiRemoteCore
import PiRemoteHost
import Testing

private let inspectionTimestamp = "2024-12-03T14:00:00.000Z"

private func inspectionNode(_ id: String, parent: String? = nil, kind: String = "message",
                            role: String = "user", content: JSONValue = .string("text"),
                            children: [JSONValue] = [], label: String? = nil,
                            labelTimestamp: String? = nil) -> JSONValue {
    var result: [String: JSONValue] = [
        "entry": .object(["id": .string(id), "parentId": parent.map(JSONValue.string) ?? .null,
                          "timestamp": .string(inspectionTimestamp), "type": .string(kind),
                          "message": .object(["role": .string(role), "content": content]),
                          "sessionFile": .string("/private/not-for-inspection.jsonl"),
                          "cwd": .string("/private/not-for-inspection")]),
        "children": .array(children)
    ]
    if let label { result["label"] = .string(label) }
    if let labelTimestamp { result["labelTimestamp"] = .string(labelTimestamp) }
    return .object(result)
}

private func inspectionTree(_ roots: [JSONValue], leaf: String? = nil) -> JSONValue {
    .object(["tree": .array(roots), "leafId": leaf.map(JSONValue.string) ?? .null])
}

private func inspectionForks(_ values: [(String, String)]) -> JSONValue {
    .object(["messages": .array(values.map { .object(["entryId": .string($0.0), "text": .string($0.1)]) })])
}

private func inspectionReplacing(_ object: JSONValue, key: String, value: JSONValue?) -> JSONValue {
    guard case .object(var fields) = object else { return object }
    fields[key] = value
    return .object(fields)
}

@Test func inspectionMapsResolvedLabelsExactLinkageAndAllBranchForkOptions() throws {
    let abandoned = inspectionNode("Abandoned", parent: "Root", content: .string("old"))
    let active = inspectionNode("Active", parent: "Root", content: .string("current"))
    let root = inspectionNode("Root", content: .string("start"), children: [abandoned, active],
                              label: "Resolved bookmark", labelTimestamp: "2024-12-03T14:30:00.125Z")
    let forks = try SessionInspectionMapper.forks(inspectionForks([("Root", "start"), ("Abandoned", "old"), ("Active", "current")]))
    let result = try SessionInspectionMapper.tree(inspectionTree([root], leaf: "Active"), forks: forks)
    #expect(result.leafID == "Active")
    #expect(result.nodes.map(\.id) == ["Root", "Abandoned", "Active"])
    #expect(result.nodes.map(\.parentID) == [nil, "Root", "Root"])
    #expect(result.nodes.allSatisfy { $0.kind == "message" && $0.canFork })
    #expect(result.nodes[0].label == "Resolved bookmark")
    #expect(result.nodes[0].labelTimestamp == "2024-12-03T14:30:00.125Z")
    #expect(result.nodes[0].labelTimestamp != inspectionTimestamp)
    #expect(result.nodes[1].labelTimestamp == nil)
    #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("/private/"))
}

@Test func inspectionForkTextMatchesPiFilteringWithoutActiveBranchOrWhitespaceAssumptions() throws {
    let image: JSONValue = .object(["type": .string("image"), "data": .string("not-exported"), "mimeType": .string("image/png")])
    let text: (String) -> JSONValue = { .object(["type": .string("text"), "text": .string($0)]) }
    let roots = [inspectionNode("image", content: .array([image])),
                 inspectionNode("empty", content: .array([text("")])),
                 inspectionNode("mixed", content: .array([text("one"), image, text("two")])),
                 inspectionNode("spaces", content: .string(" \n")),
                 inspectionNode("assistant", role: "assistant"),
                 inspectionNode("not-listed", content: .string("Not inferred as eligible"))]
    let options = try SessionInspectionMapper.forks(inspectionForks([("mixed", "onetwo"), ("spaces", " \n")]))
    let result = try SessionInspectionMapper.tree(inspectionTree(roots, leaf: "spaces"), forks: options)
    #expect(result.nodes.filter(\.canFork).map(\.id) == ["mixed", "spaces"])
    #expect(result.nodes[0].text == "[Image]")
    #expect(result.nodes[2].text == "one[Image]two")
    #expect(throws: RemoteFault.incompatiblePi) { try SessionInspectionMapper.forks(inspectionForks([("empty", "")])) }
    for id in ["image", "empty", "assistant", "absent"] {
        let invalid = [SessionForkOption(entryID: id, text: "text", truncated: false)]
        #expect(throws: RemoteFault.incompatiblePi) { try SessionInspectionMapper.tree(inspectionTree(roots), forks: invalid) }
    }
    let mismatch = [SessionForkOption(entryID: "mixed", text: "one\ntwo", truncated: false)]
    #expect(throws: RemoteFault.incompatiblePi) { try SessionInspectionMapper.tree(inspectionTree(roots), forks: mismatch) }
}

@Test func inspectionSupportsOrphanAndMultipleRootsAndNullOrInteriorLeaf() throws {
    let orphan = inspectionNode("orphan", parent: "missing")
    let root = inspectionNode("root", children: [inspectionNode("child", parent: "root")], label: "Legacy label")
    let result = try SessionInspectionMapper.tree(inspectionTree([root, orphan], leaf: "root"), forks: [])
    #expect(result.nodes.map(\.id) == ["root", "child", "orphan"])
    #expect(result.nodes.last?.parentID == "missing")
    #expect(result.nodes[0].labelTimestamp == nil)
    #expect(result.leafID == "root")
    #expect(try SessionInspectionMapper.tree(inspectionTree([root]), forks: []).leafID == nil)
    #expect(try SessionInspectionMapper.tree(inspectionTree([]), forks: []) == SessionTreeInspection(nodes: [], leafID: nil))
}

@Test func inspectionBoundsUTF8PreviewsAndDoesNotLeakHiddenOrRawContent() throws {
    let long = String(repeating: "界", count: 300)
    let options = try SessionInspectionMapper.forks(inspectionForks([("long", long)]))
    #expect(options[0].text.utf8.count == 510)
    #expect(options[0].truncated)
    let blocks: JSONValue = .array([.object(["type": .string("text"), "text": .string(long)]),
                                     .object(["type": .string("text"), "text": .string("x")])])
    let result = try SessionInspectionMapper.tree(inspectionTree([inspectionNode("long", content: .string(long)),
                                                                  inspectionNode("blocks", content: blocks)]), forks: options)
    #expect(result.nodes[0].text == options[0].text && result.nodes[0].truncated)
    #expect(result.nodes[1].text == options[0].text && result.nodes[1].truncated)
    let hidden = inspectionReplacing(inspectionNode("hidden", role: "custom"), key: "entry", value: .object([
        "id": .string("hidden"), "parentId": .null, "timestamp": .string(inspectionTimestamp), "type": .string("message"),
        "message": .object(["role": .string("custom"), "display": .bool(false), "content": .string("secret")])]))
    let summary = inspectionReplacing(inspectionNode("summary", kind: "compaction"), key: "entry", value: .object([
        "id": .string("summary"), "parentId": .null, "timestamp": .string(inspectionTimestamp), "type": .string("compaction"), "summary": .string("Summary preview")]))
    let display = try SessionInspectionMapper.tree(inspectionTree([hidden, summary, inspectionNode("opaque", kind: "custom")]), forks: [])
    #expect(display.nodes.map(\.text) == ["", "Summary preview", "custom"])
}

@Test func inspectionRejectsMalformedDuplicateCyclicAndAmbiguousTrees() throws {
    let root = inspectionNode("root")
    let invalid: [JSONValue] = [
        .null, .object(["tree": .array([])]), .object(["tree": .null, "leafId": .null]),
        inspectionTree([], leaf: "absent"), inspectionTree([root, root]),
        inspectionTree([inspectionNode("self", parent: "self")]),
        inspectionTree([inspectionNode("a", parent: "b"), inspectionNode("b", parent: "a")]),
        inspectionTree([root, inspectionNode("child", parent: "root")]),
        inspectionTree([inspectionNode("root", children: [inspectionNode("child", parent: "wrong")])]),
        inspectionTree([inspectionNode("root", children: [root])]),
        inspectionTree([inspectionReplacing(root, key: "children", value: nil)]),
        inspectionTree([inspectionReplacing(root, key: "label", value: .null)]),
        inspectionTree([inspectionReplacing(root, key: "labelTimestamp", value: .string(inspectionTimestamp))]),
        inspectionTree([inspectionNode("root", label: "mark", labelTimestamp: "invalid")]),
        inspectionTree([inspectionReplacing(root, key: "labelTimestamp", value: .number(42))]),
        inspectionTree([inspectionNode("root", label: "")]),
        inspectionTree([inspectionReplacing(root, key: "entry", value: .object(["id": .string("root")]))]),
        inspectionTree([inspectionNode("root", content: .array([.object(["type": .string("text"), "text": .bool(true)])]))])
    ]
    for value in invalid {
        #expect(throws: RemoteFault.incompatiblePi) { try SessionInspectionMapper.tree(value, forks: []) }
    }
    for value in [JSONValue.null, .object(["messages": .null]), inspectionForks([("a", "text"), ("a", "text")]),
                  inspectionForks([("", "text")]), .object(["messages": .array([.object(["entryId": .string("a"), "text": .bool(true)])])])] {
        #expect(throws: RemoteFault.incompatiblePi) { try SessionInspectionMapper.forks(value) }
    }
    let duplicate = [SessionForkOption(entryID: "root", text: "text", truncated: false), SessionForkOption(entryID: "root", text: "text", truncated: false)]
    #expect(throws: RemoteFault.incompatiblePi) { try SessionInspectionMapper.tree(inspectionTree([root]), forks: duplicate) }
    let wrongFlag = [SessionForkOption(entryID: "root", text: "text", truncated: true)]
    #expect(throws: RemoteFault.incompatiblePi) { try SessionInspectionMapper.tree(inspectionTree([root]), forks: wrongFlag) }
}

@Test func inspectionRejectsOversizedCountsIdentifiersLabelsAndContentBlocks() throws {
    let limit = SessionInspectionMapper.maximumItems
    let longID = String(repeating: "i", count: SessionInspectionMapper.maximumIdentifierBytes + 1)
    let root = inspectionNode("root")
    #expect(throws: RemoteFault.tooLarge) { try SessionInspectionMapper.forks(inspectionForks(Array(repeating: ("id", "text"), count: limit + 1))) }
    #expect(throws: RemoteFault.tooLarge) { try SessionInspectionMapper.forks(inspectionForks([(longID, "text")])) }
    for response in [inspectionTree(Array(repeating: root, count: limit + 1)),
                     inspectionTree([inspectionNode(longID)]), inspectionTree([inspectionNode("root", parent: longID)]),
                     inspectionTree([], leaf: longID),
                     inspectionTree([inspectionNode("root", kind: longID)]),
                     inspectionTree([inspectionNode("root", label: String(repeating: "l", count: 513))]),
                     inspectionTree([inspectionNode("root", label: "mark", labelTimestamp: String(repeating: "t", count: 129))]),
                     inspectionTree([inspectionNode("root", content: .array(Array(repeating: .object(["type": .string("text"), "text": .string("x")]), count: limit + 1)))]) ] {
        #expect(throws: RemoteFault.tooLarge) { try SessionInspectionMapper.tree(response, forks: []) }
    }
    let tooManyForks = Array(repeating: SessionForkOption(entryID: "root", text: "text", truncated: false), count: limit + 1)
    #expect(throws: RemoteFault.tooLarge) { try SessionInspectionMapper.tree(inspectionTree([root]), forks: tooManyForks) }
}

@Test(.timeLimit(.minutes(1))) func inspectionAcceptsExactWideAndForkCountBounds() throws {
    let count = SessionInspectionMapper.maximumItems
    let options = try SessionInspectionMapper.forks(inspectionForks((0..<count).map { (String($0), "text") }))
    let roots = (0..<count).map { inspectionNode(String($0)) }
    let result = try SessionInspectionMapper.tree(inspectionTree(roots, leaf: String(count - 1)), forks: options)
    #expect(options.count == count)
    #expect(result.nodes.count == count && result.nodes.allSatisfy(\.canFork))
    let label = String(repeating: "l", count: SessionInspectionMapper.maximumLabelBytes)
    #expect(try SessionInspectionMapper.tree(inspectionTree([inspectionNode("root", label: label)]), forks: []).nodes[0].label == label)
    // The work bound includes pending descendants, not just the root array.
    let tooWide = inspectionNode("parent", children: roots)
    #expect(throws: RemoteFault.tooLarge) { try SessionInspectionMapper.tree(inspectionTree([tooWide]), forks: []) }
    let oversizedOption = [SessionForkOption(entryID: "root", text: String(repeating: "x", count: 513), truncated: true)]
    #expect(throws: RemoteFault.tooLarge) { try SessionInspectionMapper.tree(inspectionTree([]), forks: oversizedOption) }
}

@Test(.timeLimit(.minutes(1))) func inspectionTraversesTenThousandDeepNodesWithoutRecursion() throws {
    let count = SessionInspectionMapper.maximumItems
    var chain = inspectionNode(String(count - 1), parent: String(count - 2))
    for index in stride(from: count - 2, through: 0, by: -1) {
        chain = inspectionNode(String(index), parent: index == 0 ? nil : String(index - 1), children: [chain])
    }
    // Release the fixture iteratively too; JSONValue's nested storage is not the mapper.
    defer {
        while let child = chain["children"]?.array?.first { chain = child }
    }
    let result = try SessionInspectionMapper.tree(inspectionTree([chain], leaf: String(count - 1)), forks: [])
    #expect(result.nodes.count == count)
    #expect(result.nodes.first?.id == "0")
    #expect(result.nodes.last?.parentID == String(count - 2))
    #expect(result.leafID == String(count - 1))
}
