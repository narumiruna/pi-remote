import AppKit
import Foundation
import PiRemoteCore
@testable import PiRemoteHost
import Testing

func outputImagePNG(seed: UInt32, width: Int = 2, height: Int = 2) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let bytes = try #require(bitmap.bitmapData)
    var value = seed
    for index in 0..<(bitmap.bytesPerRow * height) {
        value = value &* 1_664_525 &+ 1_013_904_223
        bytes[index] = UInt8(truncatingIfNeeded: value >> 24)
    }
    return try #require(bitmap.representation(using: .png, properties: [:]))
}
private func message(_ data: Data, mime: String = "image/png") -> JSONValue {
    .object(["role": .string("toolResult"), "content": .array([
        .object(["type": .string("image"), "mimeType": .string(mime), "data": .string(data.base64EncodedString()),
                 "remoteImageID": .string(UUID().uuidString), "remoteImageFault": .string("unavailable")])
    ])])
}
private func reference(_ value: JSONValue) throws -> OutputImageReference {
    try #require(TranscriptReducer.imageReferences(value["content"])?.first)
}

@Test func outputImagesAreOpaqueDeduplicatedAndNeverEmbeddedInSnapshots() throws {
    var cache = OutputImages()
    let data = try outputImagePNG(seed: 1)
    let display = cache.message(message(data))
    let first = try reference(display)
    #expect(first.fault == nil)
    let second = try reference(cache.message(message(data)))
    #expect(first.id == second.id)
    #expect(try cache.image(first.id).data == data)
    #expect(display["content"]?.array?.first?["data"] == nil)
    let rendered = try #require(TranscriptReducer.message(display))
    #expect(rendered.images == [first] && rendered.text == "[Image]")
    let encoded = try JSONEncoder().encode(rendered)
    #expect(!String(decoding: encoded, as: UTF8.self).contains(data.base64EncodedString()))
    #expect(try AppPacket<AppResult>.decode(AppPacket(AppResult.image(cache.image(first.id))).encode()).payload == .image(ImageAttachment(data: data, mimeType: "image/png")))
    var replaced = OutputImages()
    #expect(throws: RemoteFault.expired) { try replaced.image(first.id) }
}

@Test func outputImagesAcceptJpegAndGifRasterData() throws {
    let bitmap = try #require(NSBitmapImageRep(data: outputImagePNG(seed: 4)))
    var cache = OutputImages()
    for (format, mime) in [(NSBitmapImageRep.FileType.jpeg, "image/jpeg"), (.gif, "image/gif")] {
        let data = try #require(bitmap.representation(using: format, properties: [:]))
        let image = try reference(cache.message(message(data, mime: mime)))
        #expect(image.fault == nil)
        #expect(try cache.image(image.id) == ImageAttachment(data: data, mimeType: mime))
    }
}

@Test func outputImagesRejectInvalidFormatsSizesAndDimensions() throws {
    var cache = OutputImages()
    let data = try outputImagePNG(seed: 2)
    #expect(try reference(cache.message(message(data, mime: "image/svg+xml"))).fault == .unsupportedFeature)
    #expect(try reference(cache.message(message(data, mime: "image/jpeg"))).fault == .invalidRequest)
    #expect(try reference(cache.message(message(Data("not an image".utf8)))).fault == .invalidRequest)
    #expect(try reference(cache.message(message(Data(count: OutputImages.maximumImageBytes + 1)))).fault == .tooLarge)
    #expect(try reference(cache.message(message(outputImagePNG(seed: 3, width: 20_001, height: 1)))).fault == .tooLarge)
    let malformed: JSONValue = .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("%%%")])])])
    #expect(try reference(cache.message(malformed)).fault == .invalidRequest)
}

@Test func outputImageCacheEvictsByCountAndRetainsRecentlyReadImages() throws {
    var cache = OutputImages()
    var references: [OutputImageReference] = []
    for seed in 0..<32 { references.append(try reference(cache.message(message(outputImagePNG(seed: UInt32(seed)))))) }
    _ = try cache.image(references[0].id)
    _ = cache.message(message(try outputImagePNG(seed: 32)))
    #expect(throws: RemoteFault.expired) { try cache.image(references[1].id) }
    #expect(try cache.image(references[0].id).mimeType == "image/png")
}

@Test func outputImageCacheEvictsByBytesBeforeItsCountLimit() throws {
    var cache = OutputImages()
    var references: [OutputImageReference] = []
    var total = 0
    for seed in 0..<8 {
        let data = try outputImagePNG(seed: UInt32(seed), width: 500, height: 700)
        #expect(data.count < OutputImages.maximumImageBytes)
        total += data.count
        references.append(try reference(cache.message(message(data))))
    }
    #expect(total > OutputImages.maximumBytes)
    #expect(references.allSatisfy { $0.fault == nil })
    #expect(throws: RemoteFault.expired) { try cache.image(references[0].id) }
    #expect(try cache.image(references.last!.id).data.count > 0)
}

@Test func outputImagesReachLiveToolRowsAndBoundReferenceCounts() throws {
    var cache = OutputImages(), reducer = TranscriptReducer()
    let data = try outputImagePNG(seed: 10)
    reducer.consume(.object(["type": .string("tool_execution_start"), "toolCallId": .string("tool"), "toolName": .string("read")]))
    let event: JSONValue = .object(["type": .string("tool_execution_end"), "toolCallId": .string("tool"), "toolName": .string("read"), "result": message(data)])
    reducer.consume(cache.event(event))
    #expect(reducer.messages.count == 1 && reducer.messages[0].images?.count == 1)
    let many: JSONValue = .object(["role": .string("user"), "content": .array(Array(repeating: message(data)["content"]!.array![0], count: 20))])
    let rendered = try #require(TranscriptReducer.message(cache.message(many)))
    #expect(rendered.images?.count == 16 && rendered.truncated)
}
