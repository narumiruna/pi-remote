import SwiftUI

/// Test host only; this is not the Pi Remote product interface.
@main
struct TransportDeviceSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text("Pi Remote").font(.title)
                Text("Secure transport verification").font(.headline)
                Text("Run the device tests from Xcode. This test app cannot start Pi or access Mac files.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }
}
