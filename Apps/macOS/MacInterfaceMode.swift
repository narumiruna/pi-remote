import AppKit
import SwiftUI

enum MacInterfaceMode: String, CaseIterable, Identifiable, Sendable {
    case pi, desktop

    var id: String { rawValue }
    var label: String { self == .pi ? "Pi" : "Desktop" }
}

private struct MacInterfaceModeKey: EnvironmentKey {
    static let defaultValue = MacInterfaceMode.pi
}

extension EnvironmentValues {
    var macInterfaceMode: MacInterfaceMode {
        get { self[MacInterfaceModeKey.self] }
        set { self[MacInterfaceModeKey.self] = newValue }
    }
}

/// The two Mac presentations share actions, not a fixed color scheme.
struct MacInterfaceTheme {
    let mode: MacInterfaceMode

    var background: Color { mode == .pi ? PiPalette.background : Color(nsColor: .windowBackgroundColor) }
    var panel: Color { mode == .pi ? PiPalette.panel : Color(nsColor: .controlBackgroundColor) }
    var text: Color { Color(nsColor: nativeText) }
    var muted: Color { Color(nsColor: nativeMuted) }
    var accent: Color { Color(nsColor: nativeAccent) }
    var warning: Color { Color(nsColor: nativeWarning) }

    var nativeText: NSColor { mode == .pi ? NSColor(PiPalette.text) : .labelColor }
    var nativeMuted: NSColor {
        mode == .pi ? NSColor(PiPalette.muted) : NSColor(name: "PiRemoteDesktopMuted") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgbRed: dark ? 0.68 : 0.36, green: dark ? 0.68 : 0.36, blue: dark ? 0.72 : 0.39, alpha: 1)
        }
    }
    var nativeAccent: NSColor {
        mode == .pi ? NSColor(PiPalette.accent) : NSColor(name: "PiRemoteDesktopAccent") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgbRed: dark ? 0.42 : 0, green: dark ? 0.67 : 0.29, blue: dark ? 1 : 0.63, alpha: 1)
        }
    }
    var nativeWarning: NSColor {
        mode == .pi ? NSColor(PiPalette.warning) : NSColor(name: "PiRemoteDesktopWarning") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgbRed: dark ? 1 : 0.72, green: dark ? 0.42 : 0.10, blue: dark ? 0.40 : 0.13, alpha: 1)
        }
    }
}
