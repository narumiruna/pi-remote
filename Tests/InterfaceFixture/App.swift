import PiRemoteCore
import SwiftUI

/// Separate UI review app. Product targets do not include this source or these fixture inputs.
@main
struct InterfaceFixtureApp: App {
    @State private var model: PhoneModel
    @Environment(\.scenePhase) private var phase
    private let dark = ProcessInfo.processInfo.arguments.contains("dark")

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let phase = ["working", "streaming", "large", "error", "disconnected", "images", "import", "legacy-import"].first(where: arguments.contains) ?? "idle"
        let defaults = UserDefaults(suiteName: "PiRemote.InterfaceFixture")!
        defaults.removePersistentDomain(forName: "PiRemote.InterfaceFixture")
        let mac = SavedMac(id: FixtureConnection.host, name: "Fixture Mac", url: URL(string: "wss://127.0.0.1:7443/")!, certificate: Data(), device: UUID())
        defaults.set(try! JSONEncoder().encode([mac]), forKey: "savedMacs")
        _model = State(initialValue: PhoneModel(defaults: defaults, connection: FixtureConnection(phase: phase), authenticate: { _ in true }))
    }
    var body: some Scene {
        WindowGroup {
            PhoneRoot(model: model)
                .environment(\.clipboardWriter, { text in
                    // Verify the fixture payload without changing the system clipboard.
                    guard text == "Native copy fixture" else { throw RemoteFault.invalidRequest }
                })
                .preferredColorScheme(dark ? .dark : .light)
                .onChange(of: phase, initial: true) { _, phase in model.scene(phase) }
        }
    }
}
