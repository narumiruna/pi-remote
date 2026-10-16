import CoreImage
import CoreGraphics
import Foundation

/// Encodes the existing pairing text without changing the pairing protocol.
enum PairingQRCode {
    static func image(for text: String) -> CGImage? {
        // A QR code can hold at most 2,953 bytes at correction level L.
        guard !text.isEmpty, text.utf8.count <= 2_953,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
