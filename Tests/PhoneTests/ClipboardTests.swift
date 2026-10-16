import PiRemoteCore
import UIKit
import XCTest
@testable import PiRemote

@MainActor final class ClipboardTests: XCTestCase {
    func testCopyUsesAnIsolatedBoardRejectsInvalidTextAndExpires() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        try LocalClipboard.copy("Private synthetic copy fixture", to: board)
        XCTAssertEqual(board.string, "Private synthetic copy fixture")
        XCTAssertThrowsError(try LocalClipboard.copy("", to: board)) { XCTAssertEqual($0 as? RemoteFault, .invalidRequest) }
        XCTAssertEqual(board.string, "Private synthetic copy fixture")
        XCTAssertThrowsError(try LocalClipboard.copy(String(repeating: "x", count: 256 * 1_024 + 1), to: board))
        XCTAssertEqual(board.string, "Private synthetic copy fixture")
        try LocalClipboard.copy("Expiring synthetic copy fixture", to: board, expiresAt: Date().addingTimeInterval(1))
        XCTAssertEqual(board.string, "Expiring synthetic copy fixture")
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(board.string)
    }
}
