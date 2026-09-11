import AppKit

struct RemovalFailure: Equatable, Identifiable, Sendable {
    var url: URL
    var reason: String
    var id: URL { url }
}

struct RemovalSummary: Equatable, Sendable {
    var trashedCount: Int
    var bytes: Int64
    var failures: [RemovalFailure]
}

/* Moves to the Trash, never deletes: the user can still get everything
   back until the Trash is emptied. */
enum Remover {
    enum QuitResult {
        case wasNotRunning
        case quit
        /// Still up after a few seconds (unsaved changes, say).
        case stillRunning
    }

    /// Asks running instances of the app to quit and waits a few seconds.
    @MainActor
    static func quit(bundleID: String) async -> QuitResult {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard !running.isEmpty else { return .wasNotRunning }
        for app in running { app.terminate() }
        for _ in 0..<30 {
            if running.allSatisfy(\.isTerminated) { return .quit }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return running.allSatisfy(\.isTerminated) ? .quit : .stillRunning
    }

    /// Other installed copies of the same app: they share every leftover,
    /// so removing the files would break them.
    static func otherCopies(of app: InspectedApp) -> [URL] {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleID)
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter {
                $0 != app.url && !$0.path.contains("/AppTranslocation/")
                    && FileManager.default.fileExists(atPath: $0.path)
            }
    }

    static func trash(_ urls: [URL]) -> (trashed: [URL], failures: [RemovalFailure]) {
        var trashed: [URL] = []
        var failures: [RemovalFailure] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed.append(url)
                if let domain = preferenceDomain(of: url) {
                    forgetPreferences(domain)
                }
            } catch {
                failures.append(RemovalFailure(url: url, reason: error.localizedDescription))
            }
        }
        return (trashed, failures)
    }

    // MARK: - Preferences

    struct PreferenceDomain: Equatable {
        var name: String
        /// A ByHost plist: the domain is scoped to this Mac.
        var currentHostOnly: Bool
    }

    /* cfprefsd keeps a domain in memory after its plist is gone, and the
       next write from any process that still touches the domain brings the
       file back (`defaults delete` goes through the daemon for exactly this
       reason). So a trashed plist under Preferences is also emptied in the
       daemon: "com.x.app.plist" is the domain com.x.app; ByHost files carry
       the hardware UUID after the domain. */
    static func preferenceDomain(of url: URL) -> PreferenceDomain? {
        guard url.pathExtension.lowercased() == "plist" else { return nil }
        let parent = url.deletingLastPathComponent()
        let byHost = parent.lastPathComponent == "ByHost"
        let preferences = byHost ? parent.deletingLastPathComponent() : parent
        guard preferences.lastPathComponent == "Preferences",
            preferences.deletingLastPathComponent().lastPathComponent == "Library"
        else { return nil }
        var name = url.deletingPathExtension().lastPathComponent
        if byHost, let dot = name.lastIndex(of: "."),
            looksLikeUUID(String(name[name.index(after: dot)...]))
        {
            name = String(name[..<dot])
        }
        return name.isEmpty ? nil : PreferenceDomain(name: name, currentHostOnly: byHost)
    }

    private static func looksLikeUUID(_ text: String) -> Bool {
        text.count == 36 && text.filter { $0 == "-" }.count == 4
    }

    static func forgetPreferences(_ domain: PreferenceDomain) {
        let host = domain.currentHostOnly ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        let name = domain.name as CFString
        if let keys = CFPreferencesCopyKeyList(name, kCFPreferencesCurrentUser, host),
            CFArrayGetCount(keys) > 0
        {
            CFPreferencesSetMultiple(nil, keys, name, kCFPreferencesCurrentUser, host)
        }
        CFPreferencesSynchronize(name, kCFPreferencesCurrentUser, host)
    }
}
