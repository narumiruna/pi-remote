import Foundation
import PiRemoteCore
import Testing

@Test func sessionInspectionPublicDTOsRoundTripWithoutRawEntries() throws {
    let fork = SessionForkOption(entryID: "Exact-ID", text: "User preview", truncated: true)
    let node = SessionTreeNode(id: "Exact-ID", parentID: "Missing-parent", kind: "message",
                               label: "Checkpoint", labelTimestamp: "2024-12-03T14:30:00.125Z",
                               text: "User preview", truncated: true, canFork: true)
    let tree = SessionTreeInspection(nodes: [node], leafID: "Exact-ID")
    #expect(try JSONDecoder().decode(SessionForkOption.self, from: JSONEncoder().encode(fork)) == fork)
    let encoded = try JSONEncoder().encode(tree)
    #expect(try JSONDecoder().decode(SessionTreeInspection.self, from: encoded) == tree)
    #expect(tree.nodes[0].labelTimestamp == "2024-12-03T14:30:00.125Z")
    let keys = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(keys.keys) == ["nodes", "leafID"])
    let nodes = try #require(keys["nodes"] as? [[String: Any]])
    #expect(Set(nodes[0].keys) == ["id", "parentID", "kind", "label", "labelTimestamp", "text", "truncated", "canFork"])
}

@Test func sessionInspectionDTOsPreserveEmptyAndUnlabelledState() throws {
    let tree = SessionTreeInspection(nodes: [], leafID: nil)
    #expect(try JSONDecoder().decode(SessionTreeInspection.self, from: JSONEncoder().encode(tree)) == tree)
    let node = SessionTreeNode(id: "root", parentID: nil, kind: "custom", label: nil,
                               labelTimestamp: nil, text: "custom", truncated: false, canFork: false)
    #expect(try JSONDecoder().decode(SessionTreeNode.self, from: JSONEncoder().encode(node)) == node)
    func sendable<T: Sendable>(_ value: T) -> T { value }
    #expect(sendable(tree) == tree)
    #expect(sendable(node) == node)
    #expect(sendable(SessionForkOption(entryID: "root", text: "text", truncated: false)).entryID == "root")
}
