import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updater = UpdaterController()
    private let model = ScupperModel()
    private var windowController: MainWindowController?
    /* A Dock drop that starts the app delivers its URLs before the launch
       finishes; keep them until the window exists. */
    private var pendingURLs: [URL] = []
    private var hasLaunched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        /* A translocated launch relaunches itself from the real bundle —
           nothing else must start in this doomed instance. */
        if TranslocationHealer.healIfNeeded() { return }

        setUpMainMenu()
        hasLaunched = true
        // `swift run Scupper --app /Applications/Foo.app` opens straight into the review.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--app"), arguments.indices.contains(index + 1) {
            pendingURLs.append(URL(fileURLWithPath: arguments[index + 1]))
        }
        showWindow()
        let urls = pendingURLs
        pendingURLs = []
        open(urls)
    }

    /* Finder hands over an app dropped on the Dock tile (the Info.plist
       declares application bundles as an accepted document type). */
    func application(_ application: NSApplication, open urls: [URL]) {
        guard hasLaunched else {
            pendingURLs += urls
            return
        }
        showWindow()
        open(urls)
    }

    private func open(_ urls: [URL]) {
        guard let app = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else { return }
        model.open(app)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        showWindow()
        return false
    }

    /* One window, one job: closing it is quitting. */
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showWindow() {
        if windowController == nil {
            windowController = MainWindowController(model: model)
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu

    private func setUpMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: L("About Scupper"),
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""))
        appMenu.addItem(updater.makeMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: L("Quit Scupper"),
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileMenu = NSMenu(title: L("File"))
        let openItem = NSMenuItem(
            title: L("Open…"), action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            NSMenuItem(
                title: L("Close Window"),
                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(
            NSMenuItem(
                title: L("Minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))

        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openDocument(_ sender: Any?) {
        model.chooseApp()
    }
}
