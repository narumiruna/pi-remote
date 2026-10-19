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
        let phase = ["spaces", "spaces-working", "spaces-empty", "working", "retrying", "streaming", "large", "error", "disconnected", "images", "import", "legacy-import", "import-missing-directory", "dialog-recovery", "extension-notices", "extension-notices-empty", "extension-notices-long", "extension-notices-recovery", "tool-details", "tool-details-error", "tool-edit", "compact-working", "crashed"].first(where: arguments.contains) ?? "idle"
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
                .transformEnvironment(\.dynamicTypeSize) { size in
                    if ProcessInfo.processInfo.arguments.contains("large-text") { size = .accessibility3 }
                }
                .onChange(of: phase, initial: true) { _, phase in model.scene(phase) }
                .onChange(of: model.state?.context) { _, context in
                    if context != nil, ProcessInfo.processInfo.arguments.contains("image-draft") {
                        // A fixture-only one-pixel PNG exercises attachment-only Send.
                        model.image = ImageAttachment(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!, mimeType: "image/png")
                    }
                }
        }
    }
}
