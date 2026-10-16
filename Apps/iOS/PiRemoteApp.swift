import SwiftUI

@main
struct PiRemoteApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            PhoneRoot(model: model)
                .onChange(of: scenePhase, initial: true) { _, phase in model.scene(phase) }
        }
    }
}
