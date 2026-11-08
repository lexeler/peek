import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var notchController: NotchController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard InstanceGuard.claim() else {
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeHiddenMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        self.environment = environment
        let controller = NotchController(environment: environment)
        notchController = controller
        controller.start()

        environment.recycler.canRecycle = { [weak controller, weak environment] in
            guard let controller, let environment else { return false }
            let settingsOpen = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) }
            return controller.isIdle
                && !settingsOpen
                && !environment.translator.isDownloading
                && !environment.bluetooth.devices.contains(where: \.isBusy)
        }
        environment.recycler.willRecycle = { [weak environment] in environment?.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.shutdown()
    }

    /// Accessory apps have no visible menu bar, but text editing shortcuts (⌘V, ⌘C, ⌘A, ⌘Z)
    /// are resolved through the main menu. A hidden Edit menu makes them work in the panel.
    private static func makeHiddenMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти из Peek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
