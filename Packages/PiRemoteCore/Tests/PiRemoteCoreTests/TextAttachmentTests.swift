import Testing
@testable import PiRemoteCore

@Test func textAttachmentsAppendWithoutOverwritingAndEscapeCodeFences() throws {
    let preview = FilePreview(name: "source.swift", text: "let value = \"```\"", truncated: false)
    let text = try TextAttachment.append(preview, to: "Keep this draft")
    #expect(text == "Keep this draft\n\nFile: source.swift\n````\nlet value = \"```\"\n````")
    #expect(try TextAttachment.append(FilePreview(name: "a\nb", text: "text", truncated: true), to: "")
        == "File: a b\n[Partial file: only the displayed preview is attached.]\n```\ntext\n```")
}

@Test func textAttachmentsRejectOversizedCombinedDraftsRatherThanTruncating() throws {
    let preview = FilePreview(name: "fixture", text: String(repeating: "é", count: 70_000), truncated: false)
    #expect(throws: RemoteFault.tooLarge) { try TextAttachment.append(preview, to: String(repeating: "x", count: 130_000)) }
    #expect(throws: RemoteFault.tooLarge) { try TextAttachment.append(FilePreview(name: String(repeating: "x", count: 513), text: "", truncated: false), to: "") }
}
