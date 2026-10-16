import CoreImage
import PiRemoteCore
import XCTest
@testable import PiRemote

@MainActor
final class PairingQRTests: XCTestCase {
    private func code(expires: Date = Date().addingTimeInterval(120), certificateSize: Int = 1_100) -> PairingCode {
        PairingCode(host: UUID(), name: "Fixture Mac", url: URL(string: "wss://192.168.1.2:7443/")!,
                    certificate: Data((0..<certificateSize).map { UInt8($0 % 256) }),
                    grant: Data(repeating: 42, count: 32), expires: expires)
    }

    private func withModel(_ body: (PhoneModel) throws -> Void) rethrows {
        let name = "PairingQRTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = PhoneModel(defaults: defaults)
        model.locked = false; model.covered = false; model.panel = "pair"
        try body(model)
    }

    func testQRCodePreservesPairingCertificateGrantAndIdentity() throws {
        let original = code(), text = try original.encoded()
        let image = try XCTUnwrap(PairingQRCode.image(for: text))
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let scanned = try XCTUnwrap((detector.features(in: scaled).first as? CIQRCodeFeature)?.messageString)
        XCTAssertEqual(scanned, text)
        let decoded = try PairingCode.decode(scanned)
        XCTAssertEqual(decoded.host, original.host)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.certificate, original.certificate)
        XCTAssertEqual(decoded.grant, original.grant)
    }

    func testQRCodeRejectsEmptyAndOversizedTextWithoutTruncation() throws {
        XCTAssertNil(PairingQRCode.image(for: ""))
        XCTAssertNil(PairingQRCode.image(for: String(repeating: "x", count: 2_954)))
        let oversized = try code(certificateSize: 3_000).encoded()
        XCTAssertNil(PairingQRCode.image(for: oversized))
        // Oversized codes remain valid for the copy-and-paste fallback.
        XCTAssertEqual(try PairingCode.decode(oversized).certificate.count, 3_000)
    }

    func testValidScanOnlyFillsPairingFormWithoutStartingPairing() throws {
        try withModel { model in
            let text = try code().encoded()
            model.fault = .invalidRequest
            XCTAssertTrue(model.acceptPairingScan(text, scope: model.contentScope))
            XCTAssertEqual(model.pairingText, text)
            XCTAssertNil(model.fault)
            XCTAssertFalse(model.pairing || model.connected)
            XCTAssertTrue(model.saved.isEmpty)
            XCTAssertEqual(model.panel, "pair")
        }
    }

    func testInvalidExpiredAndUnsupportedScansDoNotReplaceInput() throws {
        try withModel { model in
            model.pairingText = "Existing input"
            let scope = model.contentScope
            XCTAssertFalse(model.acceptPairingScan("https://example.com", scope: scope))
            XCTAssertEqual(model.fault, .invalidRequest)
            XCTAssertFalse(model.acceptPairingScan(try code(expires: Date().addingTimeInterval(-1)).encoded(), scope: scope))
            XCTAssertEqual(model.fault, .expired)
            var unsupported = code(); unsupported.version = 2
            XCTAssertFalse(model.acceptPairingScan(try unsupported.encoded(), scope: scope))
            XCTAssertEqual(model.fault, .invalidRequest)
            XCTAssertFalse(model.acceptPairingScan(String(repeating: "x", count: 32_769), scope: scope))
            XCTAssertEqual(model.fault, .invalidRequest)
            XCTAssertEqual(model.pairingText, "Existing input")
            XCTAssertFalse(model.pairing)
        }
    }

    func testScanCannotCrossLockMacPanelOrActivePairingBoundaries() throws {
        try withModel { model in
            let text = try code().encoded(), scope = model.contentScope
            model.covered = true
            XCTAssertFalse(model.acceptPairingScan(text, scope: scope))
            model.covered = false; model.panel = "connections"
            XCTAssertFalse(model.acceptPairingScan(text, scope: scope))
            model.panel = "pair"; model.pairing = true
            XCTAssertFalse(model.acceptPairingScan(text, scope: scope))
            model.pairing = false; model.chooseMac(UUID())
            XCTAssertFalse(model.acceptPairingScan(text, scope: scope))
            let current = model.contentScope
            model.lock()
            XCTAssertFalse(model.acceptPairingScan(text, scope: current))
            XCTAssertTrue(model.pairingText.isEmpty)
            XCTAssertTrue(model.saved.isEmpty)
        }
    }
}
