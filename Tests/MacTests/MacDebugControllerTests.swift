import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class DebugSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor final class MacDebugControllerTests: XCTestCase {
    private func withModel(_ body: (CompanionModel, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        let root = URL(fileURLWithPath: "/private/tmp/prdc-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "PiRemote.DebugTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "debugEnabled") // An old or injected preference cannot enable access.
        let model = CompanionModel(support: root.appendingPathComponent("support"), secrets: DebugSecrets(), defaults: defaults,
                                   debugDirectory: root.appendingPathComponent("debug"))
        do { try await body(model, root); await model.shutdown() }
        catch { await model.shutdown(); throw error }
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func window(size: CGSize = CGSize(width: 900, height: 600)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.contentView?.addSubview(MacDebugWindowMarker.Marker(frame: NSRect(x: 0, y: 0, width: 1, height: 1)))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func testOffByDefaultEnableRotateDisableAndShutdownPreserveSessionAndDraft() async throws {
        try await withModel { model, root in
            XCTAssertFalse(model.debug.enabled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("debug/endpoint.json").path))
            model.text = "Do not send this draft"
            let before = model.state
            model.debug.enable(model: model)
            XCTAssertTrue(model.debug.enabled)
            let endpoint = root.appendingPathComponent("debug/endpoint.json")
            let first = try Data(contentsOf: endpoint)
            model.debug.enable(model: model)
            XCTAssertEqual(try Data(contentsOf: endpoint), first)
            model.debug.disable()
            XCTAssertFalse(model.debug.enabled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path))
            model.debug.enable(model: model)
            XCTAssertNotEqual(try Data(contentsOf: endpoint), first)
            XCTAssertEqual(model.state, before)
            XCTAssertEqual(model.text, "Do not send this draft")
            XCTAssertFalse(model.listening)
            await model.shutdown()
            model.debug.enable(model: model)
            XCTAssertFalse(model.debug.enabled, "A late enable confirmation cannot reopen access during shutdown")
            XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path))
        }
    }

    func testStartupFailureDoesNotEnableOrExposeSystemError() async throws {
        try await withModel { model, root in
            try "private fixture path".write(to: root.appendingPathComponent("debug"), atomically: true, encoding: .utf8)
            model.debug.enable(model: model)
            XCTAssertFalse(model.debug.enabled)
            XCTAssertNotNil(model.debug.error)
            XCTAssertFalse(model.debug.error!.contains(root.path))
            model.debug.disable()
            XCTAssertNil(model.debug.error)
        }
    }

    func testStatusIsAnAllowlistWithoutPrivateFixtureStrings() async throws {
        try await withModel { model, _ in
            let secret = "PRIVATE-CREDENTIAL-PROMPT-TOOL-OUTPUT"
            model.text = secret
            model.code = secret
            model.piPath = secret
            model.state.phase = secret
            model.destination = .workspace("/" + secret)
            let session = SessionInfo(id: UUID(), title: secret, directory: "/" + secret)
            model.state.sessions = [session]
            model.state.selected = session.id
            let data = try model.debug.status(model: model, windows: [])
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(text.contains(secret))
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(value.keys), Set(["interfaceMode", "destination", "windowWidth", "windowHeight", "sessionPresent", "phase", "listenerOn", "sessionCount", "messageCount", "dialogCount"]))
            XCTAssertEqual(value["phase"] as? String, "unknown")
            XCTAssertEqual(value["destination"] as? String, "workspace")
            XCTAssertEqual(value["sessionCount"] as? Int, 1)
            XCTAssertEqual(value["windowWidth"] as? Int, 0)
            for phase in ["bash", "queued"] {
                model.state.phase = phase
                let state = try JSONSerialization.jsonObject(with: model.debug.status(model: model, windows: [])) as? [String: Any]
                XCTAssertEqual(state?["phase"] as? String, phase)
            }
        }
    }

    func testSelectionRejectsMissingAmbiguousHiddenAndMinimizedWindows() async throws {
        try await withModel { model, _ in
            @MainActor func select(_ windows: [NSWindow], hidden: Bool = false) throws -> NSWindow {
                try MacDebugController.captureWindow(model: model, windows: windows, appHidden: hidden, modalWindow: nil)
            }
            XCTAssertThrowsError(try select([]))
            let first = window(); let second = window()
            defer { first.close(); second.close() }
            XCTAssertThrowsError(try select([first, second]))
            XCTAssertThrowsError(try select([first], hidden: true))
            first.orderOut(nil)
            XCTAssertThrowsError(try select([first]))
            first.makeKeyAndOrderFront(nil)
            XCTAssertTrue(try select([first]) === first)
            first.miniaturize(nil)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(first.isMiniaturized)
            XCTAssertThrowsError(try select([first]))
            first.deminiaturize(nil)
            let unrelated = window()
            unrelated.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            unrelated.identifier = NSUserInterfaceItemIdentifier("pi-remote-session-window")
            defer { unrelated.close() }
            XCTAssertThrowsError(try select([unrelated]), "Never select an arbitrary app window")
        }
    }

    func testProtectedModelSurfacesModalSheetsSecondaryWindowsAndSecureFieldsRejectCapture() async throws {
        try await withModel { model, _ in
            let main = window()
            defer { main.close() }
            @MainActor func select(_ windows: [NSWindow]? = nil, modal: NSWindow? = nil) throws -> NSWindow {
                try MacDebugController.captureWindow(model: model, windows: windows ?? [main], appHidden: false, modalWindow: modal)
            }
            model.code = "PAIRING-SECRET"
            XCTAssertThrowsError(try select())
            model.code = ""
            for panel in ["pairingQR", "dialog", "editor", "anything"] {
                model.panel = panel
                XCTAssertThrowsError(try select())
            }
            model.panel = nil
            model.state.dialogs = [ExtensionDialog(id: "pending", method: "input", title: "Credential", message: "", options: [], text: "", expires: nil)]
            XCTAssertThrowsError(try select())
            model.state.dialogs = []
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            XCTAssertThrowsError(try select(modal: panel))
            main.beginSheet(panel)
            XCTAssertThrowsError(try select())
            main.endSheet(panel); panel.orderOut(nil)
            panel.makeKeyAndOrderFront(nil)
            XCTAssertThrowsError(try select([main, panel]))
            panel.orderOut(nil)
            let secure = NSSecureTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
            secure.stringValue = "CREDENTIAL"
            main.contentView!.addSubview(secure)
            XCTAssertThrowsError(try select())
            secure.removeFromSuperview()
            XCTAssertTrue(try select() === main)
        }
    }

    func testBoundedSnapshotDecodesToExpectedPixelsAndDimensions() async throws {
        try await withModel { _, _ in
            for size in [CGSize(width: 900, height: 600), CGSize(width: 3840, height: 2400)] {
                let main = window(size: size)
                defer { main.close() }
                main.contentView = DebugColorView(frame: NSRect(origin: .zero, size: size))
                let started = Date()
                let pixels = try MacDebugController.snapshot(window: main)
                XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "Bounded rendering must leave the UI responsive")
                let data = try await Task.detached { try MacDebugController.encode(pixels) }.value
                let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertLessThanOrEqual(decoded.pixelsWide, MacDebugController.maxEdge)
                XCTAssertLessThanOrEqual(decoded.pixelsHigh, MacDebugController.maxEdge)
                XCTAssertLessThanOrEqual(decoded.pixelsWide * decoded.pixelsHigh, MacDebugController.maxPixels)
                XCTAssertLessThanOrEqual(data.count, MacDebugController.maxImageBytes)
                XCTAssertEqual(decoded.pixelsWide, size.width == 900 ? 900 : 1920)
                XCTAssertEqual(decoded.pixelsHigh, size.height == 600 ? 600 : 1200)
                let red = try XCTUnwrap(decoded.colorAt(x: decoded.pixelsWide / 4, y: decoded.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                let blue = try XCTUnwrap(decoded.colorAt(x: decoded.pixelsWide * 3 / 4, y: decoded.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(red.redComponent, 0.9)
                XCTAssertGreaterThan(blue.blueComponent, 0.9)
            }
            for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 10), CGSize(width: -1, height: 10)] {
                XCTAssertThrowsError(try MacDebugController.imageSize(size))
            }
        }
    }

    func testActualSocketStatusAndCaptureReturnOnlyBoundedAppEvidence() async throws {
        try await withModel { model, root in
            let main = window()
            main.contentView = DebugColorView(frame: main.contentView!.bounds)
            main.contentView!.addSubview(MacDebugWindowMarker.Marker(frame: NSRect(x: 0, y: 0, width: 1, height: 1)))
            defer { main.close() }
            model.debug.enable(model: model)
            XCTAssertTrue(model.debug.enabled)
            let directory = root.appendingPathComponent("debug")
            let before = model.state
            let status = try await MacDebugTestClient.request(directory: directory)
            let statusObject = try XCTUnwrap(JSONSerialization.jsonObject(with: status) as? [String: Any])
            XCTAssertEqual(statusObject["ok"] as? Bool, true)
            let response = try await MacDebugTestClient.request(directory: directory, operation: "capture")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            XCTAssertEqual(object["ok"] as? Bool, true)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            XCTAssertEqual(Set(result.keys), Set(["png", "width", "height", "capturedAt", "method"]))
            XCTAssertEqual(result["method"] as? String, "appkit-view")
            let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result["png"] as? String)))
            XCTAssertNotNil(NSBitmapImageRep(data: png))
            XCTAssertEqual(result["width"] as? Int, 900)
            model.code = "PAIRING-SECRET"
            let rejected = try await MacDebugTestClient.request(directory: directory, operation: "capture")
            let error = try XCTUnwrap(JSONSerialization.jsonObject(with: rejected) as? [String: Any])
            XCTAssertEqual(error["error"] as? String, "capture_protected")
            XCTAssertEqual(model.state, before)
            XCTAssertFalse(model.listening)
        }
    }

    func testOversizedPNGEncodingFailsWithoutAnUnboundedResponse() async throws {
        let width = 1920, height = 1200
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt64 = 12345
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                random = random &* 6364136223846793005 &+ 1
                bytes[pixel + channel] = UInt8(truncatingIfNeeded: random >> 32)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let pixels = MacDebugController.Pixels(value: image)
        do {
            _ = try await Task.detached { try MacDebugController.encode(pixels) }.value
            XCTFail("High-entropy PNG must exceed the response image limit")
        } catch {
            XCTAssertEqual(error as? MacDebugServer.OperationError, .captureTooLarge)
        }
    }

    func testProductSwiftUIContentCapturesPiAndDesktopLightDarkWithoutChangingSession() async throws {
        try await withModel { model, root in
            let main = window()
            let host = NSHostingController(rootView: CompanionWindow(model: model).frame(width: 900, height: 650))
            host.sizingOptions = []
            main.contentViewController = host
            main.setContentSize(NSSize(width: 900, height: 650))
            defer { main.contentViewController = nil; main.close() }
            model.text = "Keep unsent draft"
            model.debug.enable(model: model)
            let state = model.state
            var images: [Data] = []
            var luminances: [Double] = []
            for (mode, appearance) in [(MacInterfaceMode.pi, NSAppearance.Name.darkAqua), (.desktop, .aqua), (.desktop, .darkAqua)] {
                model.interfaceMode = mode
                main.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(180))
                let response = try await MacDebugTestClient.request(directory: root.appendingPathComponent("debug"), operation: "capture")
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
                let value = try XCTUnwrap(object["result"] as? [String: Any], "Capture failed: \(object["error"] ?? "unknown")")
                let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(value["png"] as? String)))
                let image = try XCTUnwrap(NSBitmapImageRep(data: png))
                images.append(png)
                var sum = 0.0, count = 0.0
                for y in stride(from: 5, to: image.pixelsHigh, by: 20) {
                    for x in stride(from: 5, to: image.pixelsWide, by: 20) {
                        let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        sum += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                        count += 1
                    }
                }
                luminances.append(sum / count)
                XCTAssertEqual(model.state, state)
                XCTAssertEqual(model.text, "Keep unsent draft")
            }
            XCTAssertNotEqual(images[0], images[1])
            XCTAssertNotEqual(images[1], images[2])
            XCTAssertGreaterThan(luminances[1], luminances[2] + 0.2, "Rendered Desktop light content must differ from dark content")
        }
    }

    func testProductWindowSelectionSurvivesSwiftUISceneIdentifierChanges() async throws {
        try await withModel { model, root in
            let main = window()
            let initialIdentifier = NSUserInterfaceItemIdentifier("SwiftUI-window-scene-initial")
            main.identifier = initialIdentifier
            let host = NSHostingController(rootView: CompanionWindow(model: model).frame(width: 900, height: 650))
            host.sizingOptions = []
            main.contentViewController = host
            main.setContentSize(NSSize(width: 900, height: 650))
            defer { main.contentViewController = nil; main.close() }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(main.identifier, initialIdentifier, "Mounting the marker must preserve SwiftUI window identity")
            // SwiftUI owns this property and can replace it after the marker attaches.
            let sceneIdentifier = NSUserInterfaceItemIdentifier("SwiftUI-window-scene-session")
            main.identifier = sceneIdentifier
            let status = try XCTUnwrap(JSONSerialization.jsonObject(with: model.debug.status(model: model, windows: [main])) as? [String: Any])
            XCTAssertEqual(status["windowWidth"] as? Int, 900)
            XCTAssertEqual(status["windowHeight"] as? Int, 650)
            XCTAssertTrue(try MacDebugController.captureWindow(model: model, windows: [main], appHidden: false, modalWindow: nil) === main)
            model.debug.enable(model: model)
            let response = try await MacDebugTestClient.request(directory: root.appendingPathComponent("debug"), operation: "capture")
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            XCTAssertEqual(value["ok"] as? Bool, true)
            XCTAssertEqual(main.identifier, sceneIdentifier, "Debug capture must not change SwiftUI window identity")
        }
    }

    func testMarkerRemovalReparentingAndContentReplacementDoNotLeaveStaleWindows() async throws {
        try await withModel { model, _ in
            let first = window(), second = window()
            first.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            second.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            let marker = MacDebugWindowMarker.Marker(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            defer { first.close(); second.close() }
            first.contentView!.addSubview(marker)
            XCTAssertTrue(MacDebugWindowMarker.isAttached(to: first))
            XCTAssertFalse(MacDebugWindowMarker.isAttached(to: second))
            XCTAssertNil(marker.hitTest(.zero))
            marker.removeFromSuperview()
            XCTAssertFalse(MacDebugWindowMarker.isAttached(to: first))
            XCTAssertThrowsError(try MacDebugController.captureWindow(model: model, windows: [first, second], appHidden: false, modalWindow: nil))
            second.contentView!.addSubview(marker)
            XCTAssertFalse(MacDebugWindowMarker.isAttached(to: first))
            XCTAssertTrue(MacDebugWindowMarker.isAttached(to: second))
            second.contentView = NSView()
            XCTAssertFalse(MacDebugWindowMarker.isAttached(to: second))
            let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            panel.contentView!.addSubview(marker)
            XCTAssertFalse(MacDebugWindowMarker.isAttached(to: panel), "A panel must never become a capture candidate")
            let sheet = window()
            sheet.orderOut(nil)
            defer { sheet.close() }
            first.beginSheet(sheet)
            XCTAssertNotNil(sheet.sheetParent)
            XCTAssertFalse(MacDebugWindowMarker.isAttached(to: sheet), "A marked regular window used as a sheet must be excluded")
            first.endSheet(sheet)
            sheet.orderOut(nil)
        }
    }

    func testSettingsRequiresConfirmationAndCancelKeepsAccessOff() async throws {
        try await withModel { model, _ in
            let main = window()
            let host = NSHostingController(rootView: Form { MacDebugSettings(model: model) }.formStyle(.grouped)
                .environment(\.accessibilityEnabled, true).frame(width: 700, height: 650))
            main.contentViewController = host
            defer {
                for sheet in main.sheets { main.endSheet(sheet); sheet.orderOut(nil) }
                main.contentViewController = nil; main.close()
            }
            try await Task.sleep(for: .milliseconds(150))
            for confirm in [false, true] {
                let button = try XCTUnwrap(find("mac-debug-enable", in: host.view))
                let selector = NSSelectorFromString("accessibilityPerformPress")
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                XCTAssertTrue(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertFalse(model.debug.enabled, "Opening consent must not grant access")
                let sheet = try XCTUnwrap(main.attachedSheet)
                @MainActor func buttons(_ view: NSView) -> [NSButton] {
                    if let button = view as? NSButton { return [button] }
                    return view.subviews.flatMap { buttons($0) }
                }
                let action = try XCTUnwrap(buttons(try XCTUnwrap(sheet.contentView)).first { $0.title == (confirm ? "Enable debug mode" : "Cancel") })
                action.performClick(nil)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(model.debug.enabled, confirm)
            }
        }
    }

    func testProductWindowMarkerAndDisableBannerArePresentOnlyWhileEnabled() async throws {
        try await withModel { model, _ in
            let main = window()
            let host = NSHostingController(rootView: CompanionWindow(model: model).environment(\.accessibilityEnabled, true).frame(width: 900, height: 650))
            host.sizingOptions = []
            main.contentViewController = host
            main.setContentSize(NSSize(width: 900, height: 650))
            defer { main.contentViewController = nil; main.close() }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(MacDebugWindowMarker.isAttached(to: main))
            XCTAssertNil(find("mac-debug-banner-disable", in: host.view))
            model.debug.enable(model: model)
            try await Task.sleep(for: .milliseconds(150))
            let button = try XCTUnwrap(find("mac-debug-banner-disable", in: host.view))
            let action = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(button.method(for: action), to: Press.self)(button, action))
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(model.debug.enabled)
            XCTAssertNil(find("mac-debug-banner-disable", in: host.view))
        }
    }

    private func find(_ id: String, in object: NSObject) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(value)).inserted else { return nil }
            func attribute(_ name: String, legacy: String) -> Any? {
                let selector = NSSelectorFromString(name)
                if value.responds(to: selector), let result = value.perform(selector)?.takeUnretainedValue() { return result }
                let old = NSSelectorFromString("accessibilityAttributeValue:")
                return value.responds(to: old) ? value.perform(old, with: legacy)?.takeUnretainedValue() : nil
            }
            if attribute("accessibilityIdentifier", legacy: "AXIdentifier") as? String == id { return value }
            for child in attribute("accessibilityChildren", legacy: "AXChildren") as? [NSObject] ?? [] {
                if let match = visit(child) { return match }
            }
            if let view = value as? NSView {
                for child in view.subviews { if let match = visit(child) { return match } }
            }
            return nil
        }
        if let match = visit(object) { return match }
        if let view = object as? NSView, let window = view.window {
            for y in stride(from: CGFloat(6), to: view.bounds.height, by: 12) {
                for x in stride(from: CGFloat(10), to: view.bounds.width, by: 30) {
                    let point = window.convertPoint(toScreen: view.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = view.accessibilityHitTest(point) as? NSObject, let match = visit(hit) { return match }
                }
            }
        }
        return nil
    }
}

@MainActor private final class DebugColorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height).fill()
        NSColor.blue.setFill(); NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height).fill()
    }
}
