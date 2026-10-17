import AppKit
import PiRemoteCore
import SwiftUI

@main
struct PiRemoteMacApp: App {
    @NSApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate
    @State private var model = CompanionModel.shared
    var body: some Scene {
        WindowGroup("Pi Remote for Mac", id: "session") {
            CompanionWindow(model: model).frame(minWidth: 900, minHeight: 600).task { model.observe() }
        }
        .defaultSize(width: 1200, height: 760)
        MenuBarExtra("Pi Remote", systemImage: "sparkle") {
            CompanionMenu(model: model)
        }
    }
}

struct CompanionMenu: View {
    @Bindable var model: CompanionModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.serverStatus)
        if model.listening { Text(model.serverEndpoint) }
        Text(model.sessionStatus)
        Button("Open session") { openWindow(id: "session") }
        Button("Stop work") { model.stopWork() }.disabled(!model.state.working)
        Divider()
        Button("Pair iPhone") { openWindow(id: "session"); model.openPairing() }.disabled(!model.listening)
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
