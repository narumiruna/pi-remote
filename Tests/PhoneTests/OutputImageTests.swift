import PiRemoteCore
import UIKit
import XCTest
@testable import PiRemote

@MainActor final class OutputImageTests: XCTestCase {
    private func image(width: Int, height: Int) throws -> ImageAttachment {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let data = renderer.pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return ImageAttachment(data: data, mimeType: "image/png")
    }

    func testOutputDecoderDownsamplesPreviewAndRetainsOriginalResolutionOnRequest() throws {
        let attachment = try image(width: 3_000, height: 8)
        let preview = try OutputImageDecoder.decode(attachment, fullResolution: false)
        XCTAssertEqual(preview.width, 2_048)
        let original = try OutputImageDecoder.decode(attachment, fullResolution: true)
        XCTAssertEqual(original.width, 3_000)
        XCTAssertEqual(original.height, 8)
    }

    func testOutputDecoderRejectsInvalidMimeDataDimensionsAndSize() throws {
        var attachment = try image(width: 16, height: 16)
        attachment.mimeType = "image/jpeg"
        XCTAssertThrowsError(try OutputImageDecoder.decode(attachment, fullResolution: true)) { XCTAssertEqual($0 as? RemoteFault, .invalidRequest) }
        attachment.mimeType = "image/svg+xml"
        XCTAssertThrowsError(try OutputImageDecoder.decode(attachment, fullResolution: true)) { XCTAssertEqual($0 as? RemoteFault, .unsupportedFeature) }
        attachment = ImageAttachment(data: Data("invalid".utf8), mimeType: "image/png")
        XCTAssertThrowsError(try OutputImageDecoder.decode(attachment, fullResolution: true)) { XCTAssertEqual($0 as? RemoteFault, .invalidRequest) }
        attachment = ImageAttachment(data: Data(count: 2 * 1_024 * 1_024 + 1), mimeType: "image/png")
        XCTAssertThrowsError(try OutputImageDecoder.decode(attachment, fullResolution: false)) { XCTAssertEqual($0 as? RemoteFault, .tooLarge) }
        attachment = try image(width: 20_001, height: 1)
        XCTAssertThrowsError(try OutputImageDecoder.decode(attachment, fullResolution: false)) { XCTAssertEqual($0 as? RemoteFault, .tooLarge) }
    }
}
