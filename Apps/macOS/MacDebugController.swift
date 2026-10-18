import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Explicit debug consent persists; transport access is fresh for each app launch.
@MainActor @Observable final class MacDebugController {
    nonisolated static let maxImageBytes = 2 * 1024 * 1024
    static let maxEdge = 1920
    static let maxPixels = 2_304_000
    static let disclosure = "Debug mode gives processes running as your Mac user access to app state, window captures and app-only UI controls. These controls can navigate, change appearance, open ordinary panels, scroll and append draft text. They cannot send prompts, run commands, control Pi or networking, or approve devices. UI preferences and draft edits can persist. Debug access is independent of iPhone access. Captures can contain private conversation text, paths and secrets shown in the window. Pi can save them in session history and send them to its model provider. This is not a security sandbox. Captures are requested individually; they are not recorded automatically. Debug mode stays enabled after you reopen the app until you select Disable debug mode. Quitting closes access; reopening creates a new local capability."

    private(set) var enabled = false
    private(set) var restoreOnLaunch: Bool
    private static let preferenceKey = "macDebugEnabled"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var error: String?
    @ObservationIgnored private let server: MacDebugServer
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var captureID: UUID?

    init(directory: URL = MacDebugServer.defaultDirectory, defaults: UserDefaults = .standard) {
        server = MacDebugServer(directory: directory)
        self.defaults = defaults
        restoreOnLaunch = defaults.bool(forKey: Self.preferenceKey)
    }

    func restore(model: CompanionModel) {
        if restoreOnLaunch { enable(model: model) }
    }

    func enable(model: CompanionModel) {
        guard !enabled, !model.shuttingDown else { return }
        error = nil
        let generation = UUID()
        self.generation = generation
        do {
            try server.start(handlingRequest: { [weak self, weak model] operation, interaction in
                guard let self, let model, !model.shuttingDown, self.enabled, self.generation == generation else {
                    throw MacDebugServer.OperationError.disabled
                }
                if operation == "status" { return try self.status(model: model) }
                if operation == "interact" {
                    guard let interaction else { throw MacDebugServer.OperationError.invalidInteraction }
                    return try self.interact(interaction, model: model)
                }
                return try await self.capture(model: model, generation: generation)
            })
            enabled = true
            restoreOnLaunch = true
            defaults.set(true, forKey: Self.preferenceKey)
        } catch {
            // Do not expose system errors, paths, request data or capability tokens.
            let code = (error as? MacDebugServer.Failure)?.rawValue ?? "startup_failed"
            self.error = "Debug mode could not start (\(code)). Another instance or an unsafe local endpoint may be present."
        }
    }

    func disable() {
        restoreOnLaunch = false
        defaults.removeObject(forKey: Self.preferenceKey)
        stop()
    }

    /// Close the current capability without withdrawing the user's saved consent.
    func stop() {
        enabled = false
        generation = UUID()
        captureID = nil
        server.stop()
        error = nil
    }

    func status(model: CompanionModel, windows: [NSWindow]? = nil) throws -> Data {
        let candidates = (windows ?? NSApp.windows).filter { MacDebugWindowMarker.isAttached(to: $0) }
        let window = candidates.count == 1 ? candidates.first : nil
        let size = window?.contentView?.bounds.size ?? .zero
        let phases = ["starting", "idle", "working", "queued", "bash", "waiting", "stopping", "retrying", "compacting", "recovering", "unavailable", "interrupted"]
        let destination: String
        switch model.destination {
        case .conversation: destination = "conversation"
        case .overview: destination = "overview"
        case .workspace: destination = "workspace"
        case .session: destination = "session"
        case .settings: destination = "settings"
        case .devices: destination = "devices"
        case nil: destination = "none"
        }
        let value = DebugStatus(interfaceMode: model.interfaceMode.rawValue, destination: destination,
                                windowWidth: Self.dimension(size.width), windowHeight: Self.dimension(size.height),
                                sessionPresent: model.state.selected != nil,
                                phase: phases.contains(model.state.phase) ? model.state.phase : "unknown",
                                listenerOn: model.listening,
                                sessionCount: min(model.state.sessions.count, 10_000),
                                messageCount: min(model.state.messages.count, 10_000),
                                dialogCount: min(model.state.dialogs.count, 10_000))
        return try JSONEncoder().encode(value)
    }

    private static func dimension(_ value: CGFloat) -> Int {
        value.isFinite ? Int(min(max(value, 0), 16_384)) : 0
    }

    /// All app sheets and secondary key windows are excluded, not only known pairing UI.
    static func captureWindow(model: CompanionModel, windows: [NSWindow], appHidden: Bool,
                              modalWindow: NSWindow?) throws -> NSWindow {
        guard model.code.isEmpty, model.pending == nil, model.panel == nil,
              model.state.dialogs.isEmpty, modalWindow == nil else {
            throw MacDebugServer.OperationError.captureProtected
        }
        let candidates = windows.filter { MacDebugWindowMarker.isAttached(to: $0) }
        guard candidates.count <= 1 else { throw MacDebugServer.OperationError.windowAmbiguous }
        guard let window = candidates.first, !appHidden, window.isVisible, !window.isMiniaturized,
              window.contentView != nil else { throw MacDebugServer.OperationError.windowUnavailable }
        guard window.attachedSheet == nil,
              !windows.contains(where: { $0 !== window && $0.isVisible && ($0.canBecomeKey || $0 is NSPanel) }),
              !containsSecureField(window.contentView!) else {
            throw MacDebugServer.OperationError.captureProtected
        }
        return window
    }

    private static func containsSecureField(_ view: NSView) -> Bool {
        if view is NSSecureTextField, !view.isHiddenOrHasHiddenAncestor { return true }
        return view.subviews.contains(where: containsSecureField)
    }

    private func capture(model: CompanionModel, generation: UUID) async throws -> Data {
        guard captureID == nil else { throw MacDebugServer.OperationError.captureBusy }
        let id = UUID()
        captureID = id
        defer { if captureID == id { captureID = nil } }
        let window = try Self.captureWindow(model: model, windows: NSApp.windows,
                                           appHidden: NSApp.isHidden, modalWindow: NSApp.modalWindow)
        let image = try Self.snapshot(window: window)
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        let data = try await Task.detached(priority: .utility) { try Self.encode(image) }.value
        try Task.checkCancellation()
        guard enabled, self.generation == generation else { throw MacDebugServer.OperationError.disabled }
        // A protected surface can appear while the PNG is encoded off the main thread.
        let current = try Self.captureWindow(model: model, windows: NSApp.windows,
                                            appHidden: NSApp.isHidden, modalWindow: NSApp.modalWindow)
        guard current === window else { throw MacDebugServer.OperationError.windowUnavailable }
        return try JSONEncoder().encode(DebugCapture(png: data.base64EncodedString(), width: image.value.width,
                                                     height: image.value.height, capturedAt: capturedAt,
                                                     method: "appkit-view"))
    }

    static func imageSize(_ size: CGSize) throws -> (Int, Int) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw MacDebugServer.OperationError.captureFailed
        }
        let scale = min(1, CGFloat(maxEdge) / max(size.width, size.height),
                        sqrt(CGFloat(maxPixels) / size.width / size.height))
        return (max(1, Int((size.width * scale).rounded(.down))), max(1, Int((size.height * scale).rounded(.down))))
    }

    /// Immutable CGImage owns the captured pixels; only PNG encoding leaves MainActor.
    struct Pixels: @unchecked Sendable { let value: CGImage }

    static func snapshot(window: NSWindow) throws -> Pixels {
        guard let view = window.contentView else { throw MacDebugServer.OperationError.windowUnavailable }
        let (width, height) = try imageSize(view.bounds.size)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32) else {
            throw MacDebugServer.OperationError.captureFailed
        }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw MacDebugServer.OperationError.captureFailed }
        return Pixels(value: image)
    }

    nonisolated static func encode(_ image: Pixels) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw MacDebugServer.OperationError.captureFailed
        }
        CGImageDestinationAddImage(destination, image.value, nil)
        guard CGImageDestinationFinalize(destination) else { throw MacDebugServer.OperationError.captureFailed }
        guard output.length <= maxImageBytes else { throw MacDebugServer.OperationError.captureTooLarge }
        return output as Data
    }
}

private struct DebugStatus: Encodable {
    let interfaceMode: String
    let destination: String
    let windowWidth: Int
    let windowHeight: Int
    let sessionPresent: Bool
    let phase: String
    let listenerOn: Bool
    let sessionCount: Int
    let messageCount: Int
    let dialogCount: Int
}

private struct DebugCapture: Encodable {
    let png: String
    let width: Int
    let height: Int
    let capturedAt: String
    let method: String
}

/// Identify the product content by an attached view, not SwiftUI-owned window identity.
@MainActor struct MacDebugWindowMarker: NSViewRepresentable {
    var selectInspector: ((String) -> Void)? = nil
    func makeNSView(context: Context) -> NSView {
        let marker = Marker()
        marker.setAccessibilityElement(false)
        marker.selectInspector = selectInspector
        return marker
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Marker)?.selectInspector = selectInspector
    }

    static func isAttached(to window: NSWindow) -> Bool {
        guard window.sheetParent == nil, !(window is NSPanel), let content = window.contentView else { return false }
        return containsMarker(content)
    }

    private static func containsMarker(_ view: NSView) -> Bool {
        view is Marker || view.subviews.contains { containsMarker($0) }
    }

    final class Marker: NSView {
        var selectInspector: ((String) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct MacDebugSettings: View {
    let model: CompanionModel
    @State private var confirming = false
    var body: some View {
        Section("Local debug mode") {
            Text(model.debug.enabled ? "Debug mode is on" : "Debug mode is off")
                .accessibilityIdentifier("mac-debug-status")
            Text(MacDebugController.disclosure).font(.caption).foregroundStyle(.secondary)
            Text("Captures contain rendered window content only, without native window chrome or sheets. Close sheets, dialogs and pairing before capture.")
                .font(.caption).foregroundStyle(.secondary)
            if model.debug.enabled || model.debug.restoreOnLaunch {
                Button("Disable debug mode") { model.debug.disable() }.accessibilityIdentifier("mac-debug-disable")
            } else {
                Button("Enable debug mode…") { confirming = true }.accessibilityIdentifier("mac-debug-enable")
            }
            if let error = model.debug.error { Text(error).foregroundStyle(.red) }
            if model.debug.restoreOnLaunch && !model.debug.enabled {
                Text("Debug mode is saved, but access could not start. Disable it to cancel automatic startup, or retry.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry debug mode") { model.debug.restore(model: model) }
            }
        }
        .confirmationDialog("Enable local debug access?", isPresented: $confirming) {
            Button("Enable debug mode") { model.debug.enable(model: model) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(MacDebugController.disclosure) }
    }
}
