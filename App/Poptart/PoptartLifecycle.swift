import AppKit
import Observation

/// AppKit owns the menu-bar item and process lifetime; SwiftUI owns the product windows.
@MainActor
final class PoptartLifecycle: NSObject, NSApplicationDelegate {
    let menuBar = PoptartMenuBar()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.start()
        Task { await AppRoot.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await AppRoot.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class PoptartMenuBar: NSObject {
    var openWindow: (() -> Void)?
    private var item: NSStatusItem?
    private let status = NSMenuItem(title: "Starting Poptart…", action: nil, keyEquivalent: "")

    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        let menu = NSMenu()
        menu.addItem(status)
        menu.addItem(.separator())
        for (title, action) in [("Open Poptart…", #selector(open)), ("Quit Poptart", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        observeStatus()
    }

    private func observeStatus() {
        withObservationTracking {
            let root = AppRoot.shared
            status.title = root.statusMessage
            item?.button?.image = NSImage(systemSymbolName: root.menuBarSymbol, accessibilityDescription: "Poptart")
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }

    @objc private func open() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
