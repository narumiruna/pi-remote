import Foundation
import Testing
@testable import PiRemoteCore

@Test func outputImageReferencesRoundTripWithoutBinaryPayloads() throws {
    let image = OutputImageReference(id: UUID())
    let message = TranscriptMessage(role: "tool", text: "[Image]", images: [image])
    let data = try JSONEncoder().encode(message)
    #expect(try JSONDecoder().decode(TranscriptMessage.self, from: data) == message)
    let preview = FilePreview(name: "History", text: "[Image]", truncated: false, images: [image])
    #expect(try AppPacket<AppResult>.decode(AppPacket(AppResult.preview(preview)).encode()).payload == .preview(preview))
    #expect(!SessionAction.outputImage(id: image.id).mutates)
    #expect(SessionAction.outputImage(id: image.id).needsSession)
}

@Test func hiddenAndUnannotatedImageMessagesDoNotInventCapabilities() {
    let raw: JSONValue = .object(["role": .string("toolResult"), "content": .array([.object(["type": .string("image"), "data": .string("untrusted"), "mimeType": .string("image/png")])])])
    #expect(TranscriptReducer.message(raw)?.images == nil)
    let hidden: JSONValue = .object(["role": .string("custom"), "display": .bool(false), "content": .array([.object(["type": .string("image"), "remoteImageID": .string(UUID().uuidString)])])])
    #expect(TranscriptReducer.message(hidden) == nil)
}
