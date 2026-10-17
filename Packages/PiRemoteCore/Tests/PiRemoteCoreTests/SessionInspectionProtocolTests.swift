import Foundation
import PiRemoteCore
import Testing

@Test func inspectionProtocolUsesSessionBoundReadOnlyActionsAndBoundedTypedPages() throws {
    let cursor = UUID()
    let action = SessionAction.sessionTree(cursor: cursor)
    #expect(!action.mutates && action.needsSession && !action.changesSession)
    #expect(try AppPacket<SessionAction>.decode(AppPacket(action).encode()).payload == action)
    let node = SessionTreeNode(id: "abandoned", parentID: "root", kind: "message", label: "Bookmark",
                               labelTimestamp: "2024-12-03T14:30:00.125Z", text: "Preview", truncated: true, canFork: true)
    let page = SessionTreePage(items: [SessionTreeItem(node: node, preview: UUID())], leafID: "other-branch", next: cursor)
    let result = AppResult.sessionTree(page)
    #expect(try AppPacket<AppResult>.decode(AppPacket(result).encode()).payload == result)
    #expect(HostSnapshot(host: UUID(), epoch: UUID()).capabilities.contains("session-tree"))
}
