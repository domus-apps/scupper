import AppKit

/* A regular app with a Dock icon, unlike its menu-bar siblings: the window
   and the Dock tile are both drop targets, and dropping is the whole
   interface. */
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
