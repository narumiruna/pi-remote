import SwiftUI

/// Keep action text readable on system backgrounds in both appearances.
enum InterfaceColors {
    static func tint(dark: Bool) -> Color {
        dark ? Color(red: 0.42, green: 0.67, blue: 1) : Color(red: 0, green: 0.29, blue: 0.63)
    }
}

struct InterfaceAppearance: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.tint(InterfaceColors.tint(dark: scheme == .dark)) }
}
