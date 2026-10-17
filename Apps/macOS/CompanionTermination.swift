import AppKit

@MainActor final class CompanionDelegate: NSObject, NSApplicationDelegate {
    private let model: CompanionModel
    private let confirm: @MainActor (NSApplication, Bool) async -> Bool
    private let reply: @MainActor (NSApplication, Bool) -> Void

    override convenience init() {
        self.init(model: .shared, confirm: { application, changed in
            await CompanionQuitAlert().present(application: application,
                parent: application.keyWindow ?? application.mainWindow, workChanged: changed)
        }, reply: { $0.reply(toApplicationShouldTerminate: $1) })
    }

    init(model: CompanionModel,
         confirm: @escaping @MainActor (NSApplication, Bool) async -> Bool,
         reply: @escaping @MainActor (NSApplication, Bool) -> Void) {
        self.model = model; self.confirm = confirm; self.reply = reply
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.requestTermination(confirm: { [confirm] changed in
            await confirm(sender, changed)
        }, reply: { [reply] allowed in reply(sender, allowed) })
    }
}

/// Nonblocking confirmation, including when an extension already owns a sheet.
@MainActor final class CompanionQuitAlert: NSObject, NSWindowDelegate {
    private(set) var alert: NSAlert?
    private var continuation: CheckedContinuation<Bool, Never>?
    private weak var previousWindow: NSWindow?
    private weak var previousResponder: NSResponder?

    func present(application: NSApplication, parent: NSWindow?, workChanged: Bool) async -> Bool {
        let alert = CompanionModel.terminationAlert(workChanged: workChanged)
        self.alert = alert
        defer { self.alert = nil }
        application.activate(ignoringOtherApps: true)
        if let parent, parent.sheetParent == nil, parent.attachedSheet == nil {
            return await alert.beginSheetModal(for: parent) == .alertSecondButtonReturn
        }
        // Do not queue Quit behind a pending extension sheet or block MainActor.
        previousWindow = application.keyWindow
        previousResponder = previousWindow?.firstResponder
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for button in alert.buttons {
                button.target = self
                button.action = #selector(respond(_:))
            }
            alert.window.delegate = self
            alert.window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func respond(_ sender: NSButton) {
        finish(sender === alert?.buttons[1])
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(false)
        return false
    }

    private func finish(_ allowed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        alert?.window.delegate = nil
        alert?.window.orderOut(nil)
        if let previousWindow, previousWindow.isVisible {
            previousWindow.makeKey()
            previousWindow.makeFirstResponder(previousResponder)
        }
        continuation.resume(returning: allowed)
    }
}
