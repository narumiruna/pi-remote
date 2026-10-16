import SwiftUI
import UIKit
import XCTest
@testable import PiRemote

@MainActor
final class ContrastTests: XCTestCase {
    private func components(_ color: UIColor) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        return [Double(r), Double(g), Double(b)]
    }
    private func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    private func ratio(_ first: [Double], _ second: [Double]) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    func testTextActionsAndProminentLabelsMeetNormalTextContrastInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let label = components(UIColor.label.resolvedColor(with: traits))
            let tint = components(UIColor(InterfaceColors.tint(dark: style == .dark)))
            for background in [UIColor.systemBackground, .secondarySystemBackground, .secondarySystemGroupedBackground] {
                let back = components(background.resolvedColor(with: traits))
                let secondary = zip(label, back).map { $0 * 0.75 + $1 * 0.25 }
                XCTAssertGreaterThanOrEqual(ratio(label, back), 4.5)
                XCTAssertGreaterThanOrEqual(ratio(secondary, back), 4.5)
                XCTAssertGreaterThanOrEqual(ratio(tint, back), 4.5)
                XCTAssertGreaterThanOrEqual(ratio(back, tint), 4.5)
            }
        }
    }
}
