import AppKit
import Darwin

struct RemovalFailure: Equatable, Identifiable, Sendable {
    var url: URL
    var reason: String
    /// What the item adds to the summary if a retry moves it.
    var size: Int64 = 0
    /// Refused by macOS's protection of other apps' containers, which only
    /// Full Disk Access lifts.
    var needsFullDiskAccess = false
    /// Refused for want of permission somewhere an administrator may
    /// write (a root-owned app or cache): worth one more try with a password.
    var needsAdministrator = false
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

    /* Asks the app to quit and waits a few seconds. Its helpers go too:
       login items, menu bar agents and background processes running from
       inside the bundle (or under its helpers' identifiers), which would
       otherwise keep running from the Trash. Those are asked, then made to
       quit; only the app itself is left to the user, since it may have
       unsaved work. */
    @MainActor
    static func quit(_ app: InspectedApp) async -> QuitResult {
        let me = NSRunningApplication.current
        let main = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .filter { $0 != me }
        let related = Set(app.relatedBundleIDs)
        let helpers = NSWorkspace.shared.runningApplications.filter { running in
            running != me && !main.contains(running)
                && (isInside(running.bundleURL, app.url) || isInside(running.executableURL, app.url)
                    || running.bundleIdentifier.map(related.contains) == true)
        }
        for running in main + helpers { running.terminate() }
        for _ in 0..<30 {
            if (main + helpers).allSatisfy(\.isTerminated) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for helper in helpers where !helper.isTerminated { helper.forceTerminate() }
        // Plain executables (no app bundle) running from inside it.
        for pid in processes(runningFrom: app.url) { kill(pid, SIGTERM) }
        if main.isEmpty { return .wasNotRunning }
        return main.allSatisfy(\.isTerminated) ? .quit : .stillRunning
    }

    private static func isInside(_ url: URL?, _ bundle: URL) -> Bool {
        guard let url else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(bundle.path + "/")
    }

    /// Our user's processes whose executable is inside `bundle`.
    static func processes(runningFrom bundle: URL) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let me = getpid()
        let uid = getuid()
        /* The kernel reports real paths, /private and all (which
           resolvingSymlinksInPath strips again). */
        guard let real = realpath(bundle.path, nil) else { return [] }
        let inside = String(cString: real) + "/"
        free(real)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 0, pid != me else { return false }
            var info = proc_bsdshortinfo()
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0,
                info.pbsi_uid == uid,
                proc_pidpath(pid, &path, UInt32(path.count)) > 0
            else { return false }
            return String(cString: path).hasPrefix(inside)
        }
    }

    /// Other installed copies of the same app: they share every leftover,
    /// so removing the files would break them.
    static func otherCopies(of app: InspectedApp) -> [URL] {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleID)
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter {
                $0.path != app.url.path && !$0.path.contains("/AppTranslocation/") && !isInTrash($0)
                    && !isInLibrary($0) && !isOnReadOnlyVolume($0)
                    && FileManager.default.fileExists(atPath: $0.path)
            }
    }

    /* Not installed copies: one in a Trash, one an updater staged inside
       a Library folder (Microsoft's keeps the next Edge under
       ~/Library/Application Support/Microsoft/EdgeUpdater), and one on a
       read-only volume — the disk image the app came on, still mounted. */
    static func isInLibrary(_ url: URL) -> Bool {
        url.path.hasPrefix(LeftoverScanner.userLibrary.path + "/")
            || url.path.hasPrefix(LeftoverScanner.systemLibrary.path + "/")
    }

    static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /* What one removal moves: every selected row's files (a grouped row is
       a shared folder such as Logs/DiagnosticReports, so only the matched
       files inside it, never the folder), then the app. Each path once:
       the same path moved twice fails the second time. */
    static func targets(for items: [Leftover], app: URL?) -> [URL] {
        var seen = Set<URL>()
        return (items.flatMap(\.files) + (app.map { [$0] } ?? [])).filter { seen.insert($0).inserted }
    }

    /// Moves the user's own items; `needsAdministrator` ones go through
    /// `trashAsAdministrator` instead.
    static func trash(_ urls: [URL], sizes: [URL: Int64] = [:]) -> (trashed: [URL], failures: [RemovalFailure]) {
        var trashed: [URL] = []
        var failures: [RemovalFailure] = []
        for url in urls {
            let job = launchJobLabel(of: url)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed.append(url)
                if let domain = preferenceDomain(of: url) {
                    forgetPreferences(domain)
                }
                if let job { bootOut("gui/\(getuid())/" + job) }
            } catch {
                let protected = isContainerProtection(error, at: url)
                failures.append(RemovalFailure(
                    url: url, reason: error.localizedDescription, size: sizes[url] ?? 0,
                    needsFullDiskAccess: protected,
                    needsAdministrator: !protected && isPermissionError(error)))
            }
        }
        return (trashed, failures)
    }

    // MARK: - Launch jobs

    /* launchd keeps a job loaded, and its process running, after the plist
       is gone — until the next login. So a trashed agent is also booted
       out by its label. */
    static func launchJobLabel(of url: URL) -> String? {
        guard url.pathExtension == "plist",
            ["LaunchAgents", "LaunchDaemons"].contains(url.deletingLastPathComponent().lastPathComponent)
        else { return nil }
        return LaunchJob(contentsOf: url)?.label
    }

    private static func bootOut(_ target: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Administrator

    /* Items only an administrator can move: everything in /Library, except
       where the folder lets us move it. Diagnostic reports are root's, but
       their folder is open to the analytics group, which administrators
       belong to; anyone else is asked for a password as before. In a
       sticky folder anyone may write to (/Library/Caches), only an item's
       owner may move it. */
    static func needsAdministrator(_ url: URL) -> Bool {
        guard url.path.hasPrefix(LeftoverScanner.systemLibrary.path + "/") else { return false }
        let folder = url.deletingLastPathComponent().path
        var folderInfo = stat()
        var itemInfo = stat()
        guard FileManager.default.isWritableFile(atPath: folder),
            stat(folder, &folderInfo) == 0, lstat(url.path, &itemInfo) == 0
        else { return true }
        return folderInfo.st_mode & S_ISVTX != 0 && itemInfo.st_uid != getuid()
    }

    /* /Library items move in one `do shell script … with administrator
       privileges`, so there is one password prompt for all of them. The
       script unloads each job first (a daemon from the system domain, an
       agent from ours), then moves every item into our Trash under a name
       not taken there — looked up by the script itself, at the moment of
       the move, and `mv -n` besides, so nothing already in the Trash is
       ever replaced — and reports each path so partial success is known.
       The items keep their owner (root), so the Finder asks for a password
       again when the Trash is emptied, as it does for anything it moved
       with one. */
    static func administratorScript(for urls: [URL], trash: URL, uid: uid_t) -> String {
        var lines = [
            "export LC_ALL=C",
            "T=\(quoted(trash.path))",
            #"m() { d="$T/$2$3"; n=2; while [ -e "$d" ] || [ -L "$d" ]; do d="$T/$2 $n$3"; n=$((n+1)); done; "#
                + #"if /bin/mv -n "$1" "$d" && [ ! -e "$1" ] && [ ! -L "$1" ]; then echo "ok $1"; else echo "fail $1"; fi; }"#,
        ]
        for url in urls {
            if let label = launchJobLabel(of: url) {
                let domain = url.deletingLastPathComponent().lastPathComponent == "LaunchDaemons"
                    ? "system" : "gui/\(uid)"
                lines.append("/bin/launchctl bootout \(quoted(domain + "/" + label)) 2>/dev/null")
            }
            let name = url.lastPathComponent as NSString
            let ext = name.pathExtension.isEmpty ? "" : "." + name.pathExtension
            lines.append("m \(quoted(url.path)) \(quoted(name.deletingPathExtension)) \(quoted(ext))")
        }
        return lines.joined(separator: "\n")
    }

    /// Single-quoted for sh: nothing inside is special except the quote.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Paths the script reported as moved, from its output.
    static func movedPaths(in output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("ok ") ? String(line.dropFirst(3)) : nil
        })
    }

    static func trashAsAdministrator(_ urls: [URL], sizes: [URL: Int64] = [:])
        -> (trashed: [URL], failures: [RemovalFailure])
    {
        guard !urls.isEmpty else { return ([], []) }
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let script = administratorScript(for: urls, trash: trash, uid: getuid())
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let result = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&error)
        guard let output = result?.stringValue else {
            let cancelled = (error?[NSAppleScript.errorNumber] as? Int) == -128
            let reason = cancelled
                ? L("Not moved. Moving it needs an administrator password.")
                : (error?[NSAppleScript.errorMessage] as? String ?? L("Not moved."))
            return ([], urls.map { RemovalFailure(url: $0, reason: reason, size: sizes[$0] ?? 0) })
        }
        let moved = movedPaths(in: output)
        let trashed = urls.filter { moved.contains($0.path) }
        let failures = urls.filter { !moved.contains($0.path) }.map {
            RemovalFailure(url: $0, reason: L("Not moved."), size: sizes[$0] ?? 0)
        }
        return (trashed, failures)
    }

    // MARK: - Full Disk Access

    /* ~/Library/Containers and ~/Library/Group Containers belong to the
       apps that made them, and macOS refuses to move them for anyone else
       (a write-permission error, even once the owner is gone) unless the
       mover has Full Disk Access. The recent documents lists and File
       Provider data are guarded the same way. */
    static func isContainerProtection(_ error: Error, at url: URL) -> Bool {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError else {
            return false
        }
        let library = LeftoverScanner.userLibrary.path
        let guarded = LeftoverCategory.allCases.filter(\.isGuarded).flatMap(\.directories)
        return (["Containers", "Group Containers"] + guarded).contains {
            url.path.hasPrefix(library + "/" + $0 + "/")
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError
    }

    static let fullDiskAccessSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

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
