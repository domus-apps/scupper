import Foundation

/* Where macOS apps leave things, all under ~/Library. Only the user's own
   Library: the system-wide /Library needs an administrator and almost
   nothing a dragged-to-the-Trash app leaves lives there. Every location is
   matched by the app's bundle identifier; a few, where apps traditionally
   use their plain name (Application Support, Caches, Logs), by name too. */
enum LeftoverCategory: Int, CaseIterable, Sendable {
    case applicationSupport, caches, preferences, containers, groupContainers
    case savedState, httpStorages, webKit, logs, crashReports, launchAgents
    case applicationScripts, backgroundDownloads, analytics, recentDocuments

    /// Folders under ~/Library whose entries are checked.
    var directories: [String] {
        switch self {
        case .applicationSupport: ["Application Support"]
        case .caches: ["Caches"]
        case .preferences: ["Preferences", "Preferences/ByHost"]
        case .containers: ["Containers"]
        case .groupContainers: ["Group Containers"]
        case .savedState: ["Saved Application State"]
        case .httpStorages: ["HTTPStorages"]
        case .webKit: ["WebKit"]
        case .logs: ["Logs"]
        case .crashReports: ["Logs/DiagnosticReports", "Application Support/CrashReporter"]
        case .launchAgents: ["LaunchAgents"]
        case .applicationScripts: ["Application Scripts"]
        case .backgroundDownloads: ["Caches/com.apple.nsurlsessiond/Downloads"]
        case .analytics: ["Logs/AppAnalytics"]
        case .recentDocuments:
            ["Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"]
        }
    }

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
        case .applicationSupport: L("Application Support")
        case .caches: L("Caches")
        case .preferences: L("Preferences")
        case .containers: L("Container")
        case .groupContainers: L("Group Container")
        case .savedState: L("Saved State")
        case .httpStorages: L("Cookies & Web Storage")
        case .webKit: L("WebKit Data")
        case .logs: L("Logs")
        case .crashReports: L("Crash Reports")
        case .launchAgents: L("Launch Agent")
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

    init(url: URL, category: LeftoverCategory, size: Int64?, files: [URL]? = nil) {
        self.url = url
        self.category = category
        self.size = size
        self.files = files ?? [url]
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
        let bundleID = identity.bundleID.lowercased()
        let name = entry.lowercased()
        switch category {
        case .preferences, .launchAgents:
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
            // "Name-2026-09-07-120000.ips", "Name_2026-09-07-120000_host.crash"
            return identity.names.contains { candidate in
                let lower = candidate.lowercased()
                return lower.count >= 3 && (name.hasPrefix(lower + "-") || name.hasPrefix(lower + "_"))
            }
        case .applicationSupport, .caches, .logs:
            return identifierMatches(name, bundleID) || nameMatches(name, identity)
        case .containers, .webKit, .applicationScripts, .backgroundDownloads:
            return identifierMatches(name, bundleID)
        }
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

    private static func stripping(_ suffix: String, from text: String) -> String? {
        text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : nil
    }
}

enum LeftoverScanner {
    static var userLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    }

    /// Everything under `library` that the matcher assigns to the app,
    /// sizes included. Slow on big caches — run off the main thread.
    static func scan(identity: AppIdentity, library: URL = userLibrary) -> [Leftover] {
        var found: [Leftover] = []
        for category in LeftoverCategory.allCases {
            for relative in category.directories {
                let directory = library.appendingPathComponent(relative)
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
                for entry in entries {
                    if LeftoverMatcher.matches(entry.lastPathComponent, in: category, identity: identity) {
                        found.append(Leftover(url: entry, category: category, size: size(of: entry)))
                        continue
                    }
                    guard category.looksInsideVendorFolder,
                        entry.lastPathComponent.lowercased() == identity.vendor, isDirectory(entry),
                        let children = try? FileManager.default.contentsOfDirectory(
                            at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    else { continue }
                    for child in children
                    where LeftoverMatcher.matches(child.lastPathComponent, in: category, identity: identity) {
                        found.append(Leftover(url: child, category: category, size: size(of: child)))
                    }
                }
            }
        }
        return found.sorted {
            ($0.category.rawValue, $0.url.path) < ($1.category.rawValue, $1.url.path)
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
        return rescan.filter { !known.contains($0.url) && !vetoed.contains($0.category) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Bytes allocated on disk for a file or a whole folder.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                childValues.isDirectory != true
            else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
