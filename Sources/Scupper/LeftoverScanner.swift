import Foundation

/* Where macOS apps leave things: mostly the user's own ~/Library, and a
   few places in the system-wide /Library that installers use (daemons,
   privileged helpers, shared support files), which need an administrator
   to move. Every location is matched by the app's bundle identifiers; a
   few, where apps traditionally use their plain name (Application
   Support, Caches, Logs), by name too. */
enum LeftoverCategory: Int, CaseIterable, Sendable {
    case applicationSupport, caches, preferences, containers, groupContainers
    case savedState, httpStorages, webKit, logs, crashReports, launchAgents
    case applicationScripts, backgroundDownloads, analytics, recentDocuments
    // In /Library.
    case systemApplicationSupport, systemCaches, systemPreferences
    case systemLaunchAgents, launchDaemons, privilegedHelpers

    /// Folders under the Library whose entries are checked: ~/Library, or
    /// /Library for the system-wide categories.
    var directories: [String] {
        switch self {
        case .applicationSupport, .systemApplicationSupport: ["Application Support"]
        case .caches, .systemCaches: ["Caches"]
        case .preferences: ["Preferences", "Preferences/ByHost"]
        case .systemPreferences: ["Preferences"]
        case .containers: ["Containers"]
        case .groupContainers: ["Group Containers"]
        case .savedState: ["Saved Application State"]
        case .httpStorages: ["HTTPStorages"]
        case .webKit: ["WebKit"]
        case .logs: ["Logs"]
        case .crashReports: ["Logs/DiagnosticReports", "Application Support/CrashReporter"]
        case .launchAgents, .systemLaunchAgents: ["LaunchAgents"]
        case .launchDaemons: ["LaunchDaemons"]
        case .privilegedHelpers: ["PrivilegedHelperTools"]
        case .applicationScripts: ["Application Scripts"]
        case .backgroundDownloads: ["Caches/com.apple.nsurlsessiond/Downloads"]
        case .analytics: ["Logs/AppAnalytics"]
        case .recentDocuments:
            ["Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"]
        }
    }

    /// In /Library, for every user: moving these asks for an administrator.
    var isSystemWide: Bool { rawValue >= LeftoverCategory.systemApplicationSupport.rawValue }

    /// A launchd job's plist: matched by what it runs as well as by name,
    /// and unloaded when it goes.
    var isLaunchJob: Bool { self == .launchAgents || self == .systemLaunchAgents || self == .launchDaemons }

    /* Folders that hold dozens of small per-app files (one analytics
       record or crash report per launch) are shown as one row per folder
       rather than one per file. */
    var groupsFiles: Bool {
        self == .analytics || self == .crashReports
    }

    /* Some vendors file every product under one folder — Application
       Support/Google/Chrome, Caches/Mozilla/Firefox, JetBrains/… — so the
       folder named after the app's vendor is looked into, one level down,
       in these two places. Only that folder: listing every stranger's
       folder here would walk into TCC-protected ones (AddressBook,
       CallHistoryDB, …) and macOS answers with a "Data Access Blocked"
       notification. */
    var looksInsideVendorFolder: Bool {
        self == .applicationSupport || self == .caches
    }

    var title: String {
        switch self {
        case .applicationSupport, .systemApplicationSupport: L("Application Support")
        case .caches, .systemCaches: L("Caches")
        case .preferences, .systemPreferences: L("Preferences")
        case .containers: L("Container")
        case .groupContainers: L("Group Container")
        case .savedState: L("Saved State")
        case .httpStorages: L("Cookies & Web Storage")
        case .webKit: L("WebKit Data")
        case .logs: L("Logs")
        case .crashReports: L("Crash Reports")
        case .launchAgents, .systemLaunchAgents: L("Launch Agent")
        case .launchDaemons: L("Launch Daemon")
        case .privilegedHelpers: L("Privileged Helper")
        case .applicationScripts: L("Application Scripts")
        case .backgroundDownloads: L("Background Downloads")
        case .analytics: L("Analytics Logs")
        case .recentDocuments: L("Recent Documents List")
        }
    }
}

struct Leftover: Identifiable, Equatable, Sendable {
    /// The item shown: a file, a folder, or — for a grouped row — the
    /// folder the files sit in.
    var url: URL
    var category: LeftoverCategory
    /// Bytes on disk, summed over a folder or a group; nil while unknown.
    var size: Int64?
    /// What actually moves to the Trash: the item itself, or the group's files.
    var files: [URL]
    /// Other installed apps that use the same item. It stays unchecked
    /// unless the user checks it.
    var sharedWith: [String] = []
    /// Another app's container that macOS won't let Scupper look into (so
    /// the size counts only what's outside Data) or move without Full
    /// Disk Access.
    var isProtected = false

    init(url: URL, category: LeftoverCategory, size: Int64?, files: [URL]? = nil,
         sharedWith: [String] = [], isProtected: Bool = false) {
        self.url = url
        self.category = category
        self.size = size
        self.files = files ?? [url]
        self.sharedWith = sharedWith
        self.isProtected = isProtected
    }

    var isGroup: Bool { files.count != 1 || files.first != url }
    var id: URL { url }
}

/* The matching rules, as pure functions over names so the tests can pin
   them down without a file system. */
enum LeftoverMatcher {
    /// Whether an entry named `entry` inside one of `category`'s folders
    /// belongs to the app.
    static func matches(_ entry: String, in category: LeftoverCategory, identity: AppIdentity) -> Bool {
        let name = entry.lowercased()
        if category == .groupContainers, identity.appGroups.contains(where: { $0.lowercased() == name }) {
            return true
        }
        if identity.bundleIDs.contains(where: { matches(name, in: category, bundleID: $0.lowercased()) }) {
            return true
        }
        switch category {
        case .crashReports:
            // "Name-2026-09-07-120000.ips", "Name_2026-09-07-120000_host.crash"
            return identity.names.contains { candidate in
                let lower = candidate.lowercased()
                return lower.count >= 3 && (name.hasPrefix(lower + "-") || name.hasPrefix(lower + "_"))
            }
        case .applicationSupport, .caches, .logs, .systemApplicationSupport, .systemCaches:
            return nameMatches(name, identity)
        default:
            return false
        }
    }

    /// Whether a lowercased entry name is filed under one lowercased
    /// bundle identifier, in the shape `category` uses.
    static func matches(_ name: String, in category: LeftoverCategory, bundleID: String) -> Bool {
        switch category {
        case .preferences, .launchAgents, .systemPreferences, .systemLaunchAgents, .launchDaemons:
            guard let stem = stripping(".plist", from: name) else { return false }
            return identifierMatches(stem, bundleID)
        case .savedState:
            guard let stem = stripping(".savedstate", from: name) else { return false }
            return identifierMatches(stem, bundleID)
        case .httpStorages:
            return identifierMatches(stripping(".binarycookies", from: name) ?? name, bundleID)
        case .analytics:
            // "com.x.app.<UUID>.json", one per launch
            guard let stem = stripping(".json", from: name) else { return false }
            return identifierMatches(stem, bundleID)
        case .recentDocuments:
            // "com.x.app.sfl3" (sfl2 on older systems)
            let stem = stripping(".sfl3", from: name) ?? stripping(".sfl2", from: name) ?? stripping(".sfl", from: name)
            guard let stem else { return false }
            return identifierMatches(stem, bundleID)
        case .groupContainers:
            /* "TEAMID.com.vendor.app", "group.com.vendor.app": the identifier
               sits inside, on dot boundaries. */
            return identifierMatches(name, bundleID) || name.hasSuffix("." + bundleID)
                || name.contains("." + bundleID + ".")
        case .crashReports:
            return false
        case .applicationSupport, .caches, .logs, .containers, .webKit, .applicationScripts,
             .backgroundDownloads, .systemApplicationSupport, .systemCaches, .privilegedHelpers:
            return identifierMatches(name, bundleID)
        }
    }

    /* Which other installed apps use the same entry. An entry belongs to
       whoever's identifier names it most specifically: when uninstalling
       Final Cut Pro (com.apple.FinalCut), com.apple.FinalCut.FxAnalyzer is
       also Motion's, since Motion carries that helper; but uninstalling a
       com.x.app.dev build doesn't make com.x.app's app a co-owner of
       com.x.app.dev. A group container is shared with every app whose
       signature names the group. Entries matched only by plain name are
       not looked up. */
    static func sharedWith(_ entry: String, in category: LeftoverCategory, identity: AppIdentity,
                           others: OtherApps) -> [String] {
        let name = entry.lowercased()
        var claimants: [String] = []
        if category == .groupContainers, identity.appGroups.contains(where: { $0.lowercased() == name }) {
            claimants += others.groups[name] ?? []
        }
        let own = identity.bundleIDs.map { $0.lowercased() }.filter { matches(name, in: category, bundleID: $0) }
        if let specific = own.map(\.count).max() {
            for (id, apps) in others.identifiers
            where id.count >= specific && matches(name, in: category, bundleID: id) {
                claimants += apps
            }
        }
        var seen = Set<String>()
        return claimants.sorted().filter { seen.insert($0).inserted }
    }

    /* The identifier itself, or something under it ("com.x.app.helper",
       "com.x.app.dev"). A dot boundary keeps "com.x.app" away from
       "com.x.application" — a different app that happens to share the
       prefix. Mac Catalyst apps are filed as "maccatalyst.com.x.app"
       everywhere (containers, storages, saved state), so that prefix is
       looked through. */
    static func identifierMatches(_ text: String, _ bundleID: String) -> Bool {
        let bare = text.hasPrefix("maccatalyst.") ? String(text.dropFirst("maccatalyst.".count)) : text
        return bare == bundleID || bare.hasPrefix(bundleID + ".")
    }

    /// The plain app name as a folder name, case-insensitively. Names
    /// shorter than three characters are too easy to collide with.
    static func nameMatches(_ text: String, _ identity: AppIdentity) -> Bool {
        identity.names.contains { $0.count >= 3 && $0.lowercased() == text }
    }

    /* A launchd job belongs to the app when it runs something inside the
       app or inside a folder already found to be the app's — Steam's
       com.valvesoftware.steamclean runs from ~/Library/Application
       Support/Steam — or names the app among its associated bundles (what
       System Settings' Login Items reads). */
    static func jobMatches(_ job: LaunchJob, identity: AppIdentity, folders: [String]) -> Bool {
        if let program = job.program {
            let inside = (identity.appPath.map { [$0] } ?? []) + folders
            if inside.contains(where: { program.hasPrefix($0 + "/") }) { return true }
        }
        let ids = Set(identity.bundleIDs.map { $0.lowercased() })
        return job.associatedBundleIDs.contains { ids.contains($0.lowercased()) }
    }

    private static func stripping(_ suffix: String, from text: String) -> String? {
        text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : nil
    }
}

/// The parts of a launchd plist that say what the job is.
struct LaunchJob: Equatable, Sendable {
    var label: String?
    /// Program, or else the first of ProgramArguments.
    var program: String?
    var associatedBundleIDs: [String] = []

    init(label: String? = nil, program: String? = nil, associatedBundleIDs: [String] = []) {
        self.label = label
        self.program = program
        self.associatedBundleIDs = associatedBundleIDs
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        label = plist["Label"] as? String
        program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        switch plist["AssociatedBundleIdentifiers"] {
        case let one as String: associatedBundleIDs = [one]
        case let many as [String]: associatedBundleIDs = many
        default: break
        }
    }
}

enum LeftoverScanner {
    static var userLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    }

    static let systemLibrary = URL(fileURLWithPath: "/Library")

    /// Everything under `library` (and `systemLibrary`, unless nil) that
    /// the matcher assigns to the app, sizes included, marked with the
    /// other apps that share it. Slow on big caches — run off the main
    /// thread.
    static func scan(identity: AppIdentity, others: OtherApps = .none, library: URL = userLibrary,
                     systemLibrary: URL? = systemLibrary) -> [Leftover] {
        var found: [Leftover] = []
        func add(_ url: URL, _ category: LeftoverCategory) {
            guard !found.contains(where: { $0.url == url }) else { return }
            let measured = measure(url)
            found.append(Leftover(
                url: url, category: category, size: measured.bytes,
                sharedWith: LeftoverMatcher.sharedWith(
                    url.lastPathComponent, in: category, identity: identity, others: others),
                isProtected: measured.blocked && (category == .containers || category == .groupContainers)))
        }
        func root(of category: LeftoverCategory) -> URL? {
            category.isSystemWide ? systemLibrary : library
        }
        // Launch jobs last: they are also matched by what they run, which
        // may be inside a folder found before them.
        let order = LeftoverCategory.allCases.filter { !$0.isLaunchJob }
            + LeftoverCategory.allCases.filter(\.isLaunchJob)
        for category in order {
            guard let root = root(of: category) else { continue }
            for relative in category.directories {
                let directory = root.appendingPathComponent(relative)
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                else { continue }
                if category.groupsFiles {
                    let matched = entries.filter {
                        LeftoverMatcher.matches($0.lastPathComponent, in: category, identity: identity)
                    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    if !matched.isEmpty {
                        found.append(Leftover(
                            url: directory, category: category,
                            size: matched.reduce(0) { $0 + size(of: $1) }, files: matched))
                    }
                    continue
                }
                let folders = found.filter { !$0.isGroup && !$0.category.isLaunchJob }
                    .map { $0.url.resolvingSymlinksInPath().path }
                for entry in entries {
                    if LeftoverMatcher.matches(entry.lastPathComponent, in: category, identity: identity) {
                        add(entry, category)
                    } else if category.isLaunchJob, entry.pathExtension == "plist",
                        var job = LaunchJob(contentsOf: entry)
                    {
                        job.program = job.program.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                        guard LeftoverMatcher.jobMatches(job, identity: identity, folders: folders) else { continue }
                        add(entry, category)
                    } else {
                        guard category.looksInsideVendorFolder,
                            entry.lastPathComponent.lowercased() == identity.vendor, isDirectory(entry),
                            let children = try? FileManager.default.contentsOfDirectory(
                                at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        else { continue }
                        for child in children
                        where LeftoverMatcher.matches(child.lastPathComponent, in: category, identity: identity) {
                            add(child, category)
                        }
                        continue
                    }
                    /* A daemon's program is usually its helper tool, named
                       anything: that tool goes with the daemon. */
                    if category == .launchDaemons, let systemLibrary,
                        let program = LaunchJob(contentsOf: entry)?.program,
                        program.hasPrefix(systemLibrary.appendingPathComponent("PrivilegedHelperTools").path + "/"),
                        FileManager.default.fileExists(atPath: program)
                    {
                        add(URL(fileURLWithPath: program), .privilegedHelpers)
                    }
                }
            }
        }
        return found.sorted {
            ($0.category.rawValue, $0.url.path) < ($1.category.rawValue, $1.url.path)
        }
    }

    /// The scan's findings marked with who else uses them, for a scan
    /// that ran before the other apps were known.
    static func markingShared(_ found: [Leftover], identity: AppIdentity, others: OtherApps) -> [Leftover] {
        found.map { item in
            var item = item
            if !item.isGroup {
                item.sharedWith = LeftoverMatcher.sharedWith(
                    item.url.lastPathComponent, in: item.category, identity: identity, others: others)
            }
            return item
        }
    }

    /* Quitting is when apps write: saved state, window positions, a last
       preferences flush. So after the app has been asked to quit the
       Library is looked at again, and what appeared since the review is
       taken along — but only in categories the user left fully checked.
       An unchecked item is a decision about that category, and nothing new
       there is trashed behind their back. */
    static func additions(after rescan: [Leftover], shown: [Leftover], selection: Set<URL>) -> [Leftover] {
        let known = Set(shown.map(\.url))
        let vetoed = Set(shown.filter { !selection.contains($0.url) }.map(\.category))
        return rescan.filter {
            !known.contains($0.url) && !vetoed.contains($0.category) && $0.sharedWith.isEmpty
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Bytes allocated on disk for a file or a whole folder.
    static func size(of url: URL) -> Int64 { measure(url).bytes }

    /// The size, and whether some of the folder couldn't be read (another
    /// app's container, where macOS keeps Data to its owner).
    static func measure(_ url: URL) -> (bytes: Int64, blocked: Bool) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, false) }
        if values.isDirectory != true {
            return (Int64(values.totalFileAllocatedSize ?? 0), false)
        }
        var blocked = false
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in
                if (error as NSError).code == NSFileReadNoPermissionError { blocked = true }
                return true
            })
        else { return (0, false) }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                childValues.isDirectory != true
            else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? 0)
        }
        return (total, blocked)
    }
}
