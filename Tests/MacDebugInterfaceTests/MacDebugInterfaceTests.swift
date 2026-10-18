import AppKit
import ApplicationServices
import XCTest

/// Separate-process product check. This is not a hosted SwiftUI fixture.
@MainActor final class MacDebugInterfaceTests: XCTestCase {
    func testNormalLaunchDebugConsentCaptureDisableAndRestart() throws {
        executionTimeAllowance = 60
        continueAfterFailure = false
        // The command must also preflight before starting the UI runner.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not authorized. An attended user must authorize the test runner before UI automation.")
        }
        let home = URL(fileURLWithPath: "/private/tmp/prdi-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches"),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let app = XCUIApplication(bundleIdentifier: "dev.narumi.PiRemote.MacDebugCheck")
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["HOME"] = home.path
        app.launchArguments = ["-AppleInterfaceStyle", "Light"]
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: home)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/PiRemote/host.json").path),
                      "Foundation Application Support must use the isolated home.")
        try assertOff(home)
        try enable(app, home: home)
        showConversation(app)
        let pi = try capture(home, mode: "pi")
        selectMode(app, label: "Desktop")
        let light = try capture(home, mode: "desktop")
        XCTAssertNotEqual(pi["sha256"] as? String, light["sha256"] as? String)
        XCTAssertGreaterThan(try luminance(light), try luminance(pi) + 20)
        try disable(app, home: home)

        app.terminate()
        app.launchArguments = ["-AppleInterfaceStyle", "Dark"]
        app.launch()
        try assertOff(home)
        openSettings(app)
        XCTAssertTrue(app.buttons["mac-debug-enable"].waitForExistence(timeout: 5))
        try enable(app, home: home)
        showConversation(app)
        let dark = try capture(home, mode: "desktop")
        XCTAssertNotEqual(light["sha256"] as? String, dark["sha256"] as? String)
        XCTAssertGreaterThan(try luminance(light), try luminance(dark) + 20)
        // Ordinary Quit while enabled must clean up and must not persist opt-in.
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        try assertOff(home)
        openSettings(app)
        XCTAssertTrue(app.buttons["mac-debug-enable"].waitForExistence(timeout: 5))
        let artifacts = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)
        while let artifact = artifacts?.nextObject() as? URL {
            XCTAssertFalse(["png", "jpg", "jpeg"].contains(artifact.pathExtension.lowercased()))
        }
    }

    private func openSettings(_ app: XCUIApplication) {
        app.descendants(matching: .any)["mac-global-actions"].firstMatch.click()
        app.menuItems["Settings"].click()
    }

    private func enable(_ app: XCUIApplication, home: URL) throws {
        if !app.buttons["mac-debug-enable"].exists { openSettings(app) }
        let enable = app.buttons["mac-debug-enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        enable.click()
        let confirm = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Enable debug mode")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.buttons["mac-debug-disable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mac-debug-banner"].exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpoint(home).path))
        let attributes = try FileManager.default.attributesOfItem(atPath: socket(home).path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
    }

    private func showConversation(_ app: XCUIApplication) {
        app.buttons["mac-sidebar-toggle"].click()
        let sidebar = app.descendants(matching: .any)["mac-workspace-sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        sidebar.staticTexts["Pi"].click()
        app.buttons["mac-sidebar-toggle"].click()
    }

    private func selectMode(_ app: XCUIApplication, label: String) {
        let picker = app.descendants(matching: .any)["mac-interface-mode"].firstMatch
        picker.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.click()
    }

    private func disable(_ app: XCUIApplication, home: URL) throws {
        app.buttons["mac-debug-banner-disable"].click()
        XCTAssertFalse(app.descendants(matching: .any)["mac-debug-banner"].exists)
        try assertOff(home)
    }

    private func assertOff(_ home: URL) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint(home).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket(home).path))
        for operation in ["status", "capture"] {
            let result = try probe(operation, home: home)
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["error"] as? String,
                           "Pi Remote debug is unavailable. Enable debug mode in the Mac app Settings.")
        }
    }

    private func capture(_ home: URL, mode: String) throws -> [String: Any] {
        let response = try probe("status", home: home)
        XCTAssertEqual(response["ok"] as? Bool, true)
        let status = try XCTUnwrap(response["status"] as? [String: Any])
        XCTAssertEqual(Set(status.keys), Set(["interfaceMode", "destination", "windowWidth", "windowHeight", "sessionPresent",
                                              "phase", "listenerOn", "sessionCount", "messageCount", "dialogCount"]))
        XCTAssertEqual(status["interfaceMode"] as? String, mode)
        XCTAssertEqual(status["destination"] as? String, "conversation")
        XCTAssertEqual(status["sessionPresent"] as? Bool, false)
        XCTAssertEqual(status["listenerOn"] as? Bool, false)
        for key in ["sessionCount", "messageCount", "dialogCount"] { XCTAssertEqual(status[key] as? Int, 0) }
        let image = try probe("capture", home: home)
        XCTAssertEqual(image["ok"] as? Bool, true)
        XCTAssertEqual(image["method"] as? String, "appkit-view")
        let width = try XCTUnwrap(image["width"] as? Int)
        let height = try XCTUnwrap(image["height"] as? Int)
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThanOrEqual(max(width, height), 1920)
        XCTAssertLessThanOrEqual(width * height, 2_304_000)
        XCTAssertGreaterThan(try XCTUnwrap(image["pngBytes"] as? Int), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(image["pngBytes"] as? Int), 2 * 1024 * 1024)
        XCTAssertEqual(try XCTUnwrap(image["sha256"] as? String).count, 64)
        return image
    }

    private func luminance(_ image: [String: Any]) throws -> Double {
        try XCTUnwrap(image["meanLuminance"] as? Double)
    }

    private func endpoint(_ home: URL) -> URL { home.appendingPathComponent("Library/Caches/PiRemoteDebug/endpoint.json") }
    private func socket(_ home: URL) -> URL { home.appendingPathComponent("Library/Caches/PiRemoteDebug/control.sock") }

    /// The probe executes the actual registered project tool. It returns no PNG or token.
    /// This does not establish live interactive or RPC Pi-session acceptance.
    private func probe(_ operation: String, home: URL) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent(".pi/tests/debug-probe.ts").path, operation]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment.removeValue(forKey: "CFFIXED_USER_HOME")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else {
            process.terminate()
            throw NSError(domain: "MacDebugInterfaceTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The project extension probe exceeded 8 seconds."])
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(process.terminationStatus, result["ok"] as? Bool == true ? 0 : 1)
        return result
    }
}
