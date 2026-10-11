import Foundation

/* Where macOS apps leave things: mostly the user's own ~/Library, and a
   few places in the system-wide /Library: what installers put there
   (daemons, privileged helpers, shared support files, plug-ins), which
   mostly needs an administrator to move, and macOS's diagnostic reports.
   And one outside any Library: the per-user cache folder macOS keeps
   under /var/folders.
   Every location is matched by the app's bundle identifiers; a few, where
   apps traditionally use their plain name (Application Support, Caches,
   Logs), by name too. */
enum LeftoverCategory: Int, CaseIterable, Sendable {
    case applicationSupport, caches, darwinUserCache, preferences, containers, groupContainers
    case savedState, httpStorages, webKit, logs, crashReports, launchAgents
    case applicationScripts, backgroundDownloads, analytics, recentDocuments
    case syncedPreferences, fileProvider, plugIns
    // In /Library.
    case systemApplicationSupport, systemCaches, systemPreferences, systemCrashReports, systemPlugIns
    case systemLaunchAgents, launchDaemons, privilegedHelpers

    /// Folders under the Library whose entries are checked: ~/Library, or
    /// /Library for the system-wide categories.
    var directories: [String] {
        switch self {
        case .applicationSupport, .systemApplicationSupport: ["Application Support"]
        case .caches, .systemCaches: ["Caches"]
        case .darwinUserCache: [""]
        case .preferences: ["Preferences", "Preferences/ByHost"]
        case .systemPreferences: ["Preferences"]
        case .containers: ["Containers"]
        case .groupContainers: ["Group Containers"]
        case .savedState: ["Saved Application State"]
        case .httpStorages: ["HTTPStorages"]
        case .webKit: ["WebKit"]
        case .logs: ["Logs"]
        case .crashReports: ["Logs/DiagnosticReports", "Application Support/CrashReporter"]
        case .systemCrashReports: ["Logs/DiagnosticReports"]
        case .launchAgents, .systemLaunchAgents: ["LaunchAgents"]
        case .launchDaemons: ["LaunchDaemons"]
        case .privilegedHelpers: ["PrivilegedHelperTools"]
        case .applicationScripts: ["Application Scripts"]
        case .backgroundDownloads: ["Caches/com.apple.nsurlsessiond/Downloads"]
        case .analytics: ["Logs/AppAnalytics"]
        case .recentDocuments:
            ["Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"]
        case .syncedPreferences: ["SyncedPreferences"]
        case .fileProvider: ["Application Support/FileProvider"]
        case .plugIns, .systemPlugIns: Self.plugInFolders
        }
    }

    /* Where plug-ins for other software go: Quick Look, Spotlight, input
       methods, audio units and drivers, screen savers, Services. */
    static let plugInFolders = [
        "QuickLook", "Spotlight", "Screen Savers", "Input Methods", "PreferencePanes", "Internet Plug-Ins",
        "Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Audio/Plug-Ins/HAL",
        "ColorPickers", "Contextual Menu Items", "Services",
    ]

    /* Folders that are never listed: macOS refuses some (and answers
       with a "Data Access Blocked" notification), though an item in them
       can still be looked up by name. */
    var isLookedUpByName: Bool {
        self == .recentDocuments || self == .syncedPreferences || self == .fileProvider
    }

    /// The names an identifier's item would have in a looked-up folder.
    func lookupNames(for id: String) -> [String] {
        switch self {
        case .recentDocuments: LeftoverMatcher.recentDocumentsExtensions.map { id + "." + $0 }
        case .syncedPreferences: [id + ".plist"]
        default: [id]
        }
    }

    /// Folders that, when they can't be listed, can't be written either:
    /// moving out of them needs Full Disk Access.
    var isGuarded: Bool { self == .recentDocuments || self == .fileProvider }

    /// Matched by the identifier inside each plug-in, not by its file name.
    var isPlugIns: Bool { self == .plugIns || self == .systemPlugIns }

    /// In /Library, for every user: moving these asks for an administrator.
    var isSystemWide: Bool { rawValue >= LeftoverCategory.systemApplicationSupport.rawValue }

    /// A launchd job's plist: matched by what it runs as well as by name,
    /// and unloaded when it goes.
    var isLaunchJob: Bool { self == .launchAgents || self == .systemLaunchAgents || self == .launchDaemons }

    /* Folders that hold dozens of small per-app files (one analytics
       record or crash report per launch) are shown as one row per folder
       rather than one per file. */
    var groupsFiles: Bool {
        self == .analytics || isCrashReports
    }

    var isCrashReports: Bool { self == .crashReports || self == .systemCrashReports }

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
        case .darwinUserCache: L("macOS Cache")
        case .preferences, .systemPreferences: L("Preferences")
        case .containers: L("Container")
        case .groupContainers: L("Group Container")
        case .savedState: L("Saved State")
        case .httpStorages: L("Cookies & Web Storage")
        case .webKit: L("WebKit Data")
        case .logs: L("Logs")
        case .crashReports, .systemCrashReports: L("Crash Reports")
        case .launchAgents, .systemLaunchAgents: L("Launch Agent")
        case .launchDaemons: L("Launch Daemon")
        case .privilegedHelpers: L("Privileged Helper")
        case .applicationScripts: L("Application Scripts")
        case .backgroundDownloads: L("Background Downloads")
        case .analytics: L("Analytics Logs")
        case .recentDocuments: L("Recent Documents List")
        case .syncedPreferences: L("Synced Preferences")
        case .fileProvider: L("File Provider Data")
        case .plugIns, .systemPlugIns: L("Plug-In")
        }
    }
}

/// Why an item was taken to be the app's. Kept with every item so a
/// change to the rules can be reviewed item by item (Scripts/audit.sh).
enum Evidence: String, Sendable {
    /// Named for the app's bundle identifier.
    case identifier
    /// Named for a helper or extension inside the app.
    case helper
    /// An app group in the app's code signature.
    case appGroup
    /// The app's plain name, where apps traditionally use it.
    case name
    /// A launch job that runs something inside the app or its folders.
    case program
    /// A launch job that names the app among its associated bundles.
    case associated
    /// The helper tool a matched daemon runs.
    case daemonTool
    /// A launch job or helper tool signed by the app's developer.
    case developer
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
    var evidence: Evidence

    init(url: URL, category: LeftoverCategory, size: Int64?, files: [URL]? = nil,
         sharedWith: [String] = [], isProtected: Bool = false, evidence: Evidence = .identifier) {
        self.url = url
        self.category = category
        self.size = size
        self.files = files ?? [url]
        self.sharedWith = sharedWith
        self.isProtected = isProtected
        self.evidence = evidence
    }

    var isGroup: Bool { files.count != 1 || files.first != url }

    /* Left for the user to check: a plug-in tied to the app only by its
       developer's signature, which may have been installed on its own. */
    var needsReview: Bool {
        category.isPlugIns && evidence == .developer
    }
    var id: URL { url }
}

/* The matching rules, as pure functions over names so the tests can pin
   them down without a file system. */
enum LeftoverMatcher {
    /// Whether an entry named `entry` inside one of `category`'s folders
    /// belongs to the app.
    static func matches(_ entry: String, in category: LeftoverCategory, identity: AppIdentity) -> Bool {
        evidence(for: entry, in: category, identity: identity) != nil
    }

    /// Why the entry is the app's, strongest reason first; nil when it isn't.
    static func evidence(for entry: String, in category: LeftoverCategory, identity: AppIdentity) -> Evidence? {
        let name = entry.lowercased()
        if category == .groupContainers, identity.appGroups.contains(where: { $0.lowercased() == name }) {
            return .appGroup
        }
        if matches(name, in: category, bundleID: identity.bundleID.lowercased()) { return .identifier }
        if identity.relatedBundleIDs.contains(where: { matches(name, in: category, bundleID: $0.lowercased()) }) {
            return .helper
        }
        switch category {
        case .crashReports, .systemCrashReports:
            return identity.names.contains { crashReportMatches(name, $0.lowercased()) } ? .name : nil
        case .logs:
            // A folder, or a single "Name.log".
            return nameMatches(stripping(".log", from: name) ?? name, identity) ? .name : nil
        case .applicationSupport, .caches, .systemApplicationSupport, .systemCaches:
            return nameMatches(name, identity) ? .name : nil
        default:
            return nil
        }
    }

    /// Whether a lowercased entry name is filed under one lowercased
    /// bundle identifier, in the shape `category` uses.
    static func matches(_ name: String, in category: LeftoverCategory, bundleID: String) -> Bool {
        switch category {
        case .preferences, .systemPreferences:
            // "com.x.app.plist", or a folder of them named for the app
            return identifierMatches(stripping(".plist", from: name) ?? name, bundleID)
        case .launchAgents, .systemLaunchAgents, .launchDaemons, .syncedPreferences:
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
            // "com.x.app.sfl4" (sfl3, sfl2 on older systems)
            let stem = recentDocumentsExtensions.lazy.compactMap { stripping("." + $0, from: name) }.first
            guard let stem else { return false }
            return identifierMatches(stem, bundleID)
        case .groupContainers:
            /* "TEAMID.com.vendor.app", "group.com.vendor.app": the identifier
               sits inside, on dot boundaries. */
            return identifierMatches(name, bundleID) || name.hasSuffix("." + bundleID)
                || name.contains("." + bundleID + ".")
        case .crashReports, .systemCrashReports:
            return false
        case .darwinUserCache:
            /* What macOS caches for the app itself (Metal shaders, mostly),
               filed under its identifier; some under "TEAMID.com.x.app". */
            return identifierMatches(name, bundleID)
                || identifierMatches(strippingTeamID(from: name) ?? name, bundleID)
        case .applicationSupport, .caches, .logs, .containers, .webKit, .applicationScripts,
             .backgroundDownloads, .systemApplicationSupport, .systemCaches, .privilegedHelpers,
             .fileProvider:
            return identifierMatches(name, bundleID)
        case .plugIns, .systemPlugIns:
            // Here the name is the plug-in's bundle identifier.
            return identifierMatches(name, bundleID)
        }
    }

    /* Which other installed apps use the same entry. An entry belongs to
       whoever's identifier names it most specifically: when uninstalling
       Final Cut Pro (com.apple.FinalCut), com.apple.FinalCut.FxAnalyzer is
       also Motion's, since Motion carries that helper; but uninstalling a
       com.x.app.dev build doesn't make com.x.app's app a co-owner of
       com.x.app.dev. A group container is shared with every app whose
       signature names the group. An entry matched only by the app's plain
       name is shared with every other app known by that name: uninstalling
       the Claude Code URL Handler (whose executable is "claude") leaves
       Application Support/Claude to the Claude app. */
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
        } else if evidence(for: entry, in: category, identity: identity) == .name, !category.isCrashReports {
            let stem = category == .logs ? stripping(".log", from: name) ?? name : name
            claimants += others.names[squeezed(stem)] ?? []
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

    /* The plain app name as a folder name, case-insensitively, and also
       with spaces and punctuation dropped: Porting Kit keeps
       ~/Library/Application Support/portingkit. Names shorter than three
       characters are too easy to collide with. */
    static func nameMatches(_ text: String, _ identity: AppIdentity) -> Bool {
        let squeezed = squeezed(text)
        return identity.names.contains {
            $0.count >= 3 && ($0.lowercased() == text || (squeezed.count >= 3 && Self.squeezed($0) == squeezed))
        }
    }

    /* A report is named for the process that crashed, then a date:
       "Name-2026-09-07-120000.ips", "Name_2026-09-07-120000_host.diag".
       Electron and Chromium apps crash as often in their helper processes
       ("Notion Helper (Renderer)", "Google Chrome Helper"), which are
       named for the app too. */
    static func crashReportMatches(_ report: String, _ name: String) -> Bool {
        guard name.count >= 3, report.hasPrefix(name) else { return false }
        var rest = report.dropFirst(name.count)
        if rest.hasPrefix(" helper") {
            rest = rest.dropFirst(" helper".count)
            if rest.hasPrefix(" (") { return true }
        }
        return rest.hasPrefix("-") || rest.hasPrefix("_")
    }

    /// Letters and digits only, lowercased.
    static func squeezed(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Newest first: sfl4 on macOS 26 and later.
    static let recentDocumentsExtensions = ["sfl4", "sfl3", "sfl2", "sfl"]

    /* A launchd job belongs to the app when it runs something inside the
       app or inside a folder already found to be the app's — Steam's
       com.valvesoftware.steamclean runs from ~/Library/Application
       Support/Steam — or names the app among its associated bundles (what
       System Settings' Login Items reads). */
    static func jobMatches(_ job: LaunchJob, identity: AppIdentity, folders: [String]) -> Bool {
        jobEvidence(job, identity: identity, folders: folders) != nil
    }

    static func jobEvidence(_ job: LaunchJob, identity: AppIdentity, folders: [String]) -> Evidence? {
        if let program = job.program {
            let inside = (identity.appPath.map { [$0] } ?? []) + folders
            if inside.contains(where: { program.hasPrefix($0 + "/") }) { return .program }
        }
        let ids = Set(identity.bundleIDs.map { $0.lowercased() })
        return job.associatedBundleIDs.contains { ids.contains($0.lowercased()) } ? .associated : nil
    }

    /// "com.x.app" from "2bua8c4s2c.com.x.app": a ten-character team
    /// identifier, then a dot.
    static func strippingTeamID(from text: String) -> String? {
        let parts = text.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return String(parts[1])
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

    /* /var/folders/…/C: where macOS keeps caches on an app's behalf, per
       user, outside the Library. It outlives the app like any other
       cache: Parallels, long gone, still had 131 MB of shaders here. */
    static var darwinUserCache: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Everything under `library` (and `systemLibrary` and `darwinUserCache`,
    /// unless nil) that the matcher assigns to the app, sizes included,
    /// marked with the other apps that share it. Slow on big caches — run
    /// off the main thread.
    static func scan(identity: AppIdentity, others: OtherApps = .none, library: URL = userLibrary,
                     systemLibrary: URL? = systemLibrary, darwinUserCache: URL? = darwinUserCache) -> [Leftover] {
        var found: [Leftover] = []
        func add(_ url: URL, _ category: LeftoverCategory, _ evidence: Evidence, sharedWith: [String]? = nil,
                 isProtected: Bool = false) {
            guard !found.contains(where: { $0.url == url }) else { return }
            let measured = measure(url)
            found.append(Leftover(
                url: url, category: category, size: measured.bytes,
                sharedWith: sharedWith ?? LeftoverMatcher.sharedWith(
                    url.lastPathComponent, in: category, identity: identity, others: others),
                isProtected: isProtected
                    || measured.blocked && (category == .containers || category == .groupContainers),
                evidence: evidence))
        }
        let vendor = AppInspector.vendorDomain(identity.bundleID)
        func root(of category: LeftoverCategory) -> URL? {
            if category == .darwinUserCache { return darwinUserCache }
            return category.isSystemWide ? systemLibrary : library
        }
        // Launch jobs last: they are also matched by what they run, which
        // may be inside a folder found before them.
        let order = LeftoverCategory.allCases.filter { !$0.isLaunchJob }
            + LeftoverCategory.allCases.filter(\.isLaunchJob)
        for category in order {
            guard let root = root(of: category) else { continue }
            for relative in category.directories {
                let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
                /* Looked up by name, never listed. Where the folder can't be
                   listed it can't be written either (the recent documents
                   lists, File Provider data), so what's found is protected. */
                if category.isLookedUpByName {
                    let listable = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil
                    for id in identity.bundleIDs {
                        for name in category.lookupNames(for: id) {
                            let url = directory.appendingPathComponent(name)
                            guard FileManager.default.fileExists(atPath: url.path) else { continue }
                            add(url, category, id == identity.bundleID ? .identifier : .helper,
                                isProtected: category.isGuarded && !listable)
                        }
                    }
                    continue
                }
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                else { continue }
                if category.groupsFiles {
                    let matched = entries.compactMap { entry in
                        LeftoverMatcher.evidence(for: entry.lastPathComponent, in: category, identity: identity)
                            .map { (entry, $0) }
                    }.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
                    if !matched.isEmpty {
                        found.append(Leftover(
                            url: directory, category: category,
                            size: matched.reduce(0) { $0 + size(of: $1.0) }, files: matched.map(\.0),
                            evidence: matched.map(\.1).contains(.identifier) ? .identifier : matched[0].1))
                    }
                    continue
                }
                let folders = found.filter { !$0.isGroup && !$0.category.isLaunchJob }
                    .map { $0.url.resolvingSymlinksInPath().path }
                for entry in entries {
                    /* A plug-in is the app's when its identifier is, or when
                       the app's developer signed it. Not by its file name:
                       Services also holds the user's own workflows. The
                       signature is read only for the vendor's own
                       identifiers: a music Mac can hold hundreds of audio
                       plug-ins, at a couple of milliseconds each. */
                    if category.isPlugIns {
                        guard let id = Bundle(url: entry)?.bundleIdentifier, !id.isEmpty else { continue }
                        if let evidence = LeftoverMatcher.evidence(for: id, in: category, identity: identity) {
                            add(entry, category, evidence, sharedWith: LeftoverMatcher.sharedWith(
                                id, in: category, identity: identity, others: others))
                        } else if !vendor.isEmpty, AppInspector.vendorDomain(id) == vendor,
                            let claimants = developerClaim(entry.path, identity, others)
                        {
                            add(entry, category, .developer, sharedWith: claimants)
                        }
                        continue
                    }
                    if let evidence = LeftoverMatcher.evidence(
                        for: entry.lastPathComponent, in: category, identity: identity)
                    {
                        add(entry, category, evidence)
                    } else if category.isLaunchJob, entry.pathExtension == "plist",
                        var job = LaunchJob(contentsOf: entry)
                    {
                        job.program = job.program.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                        if let evidence = LeftoverMatcher.jobEvidence(job, identity: identity, folders: folders) {
                            add(entry, category, evidence)
                        } else if let program = job.program, let claimants = developerClaim(program, identity, others) {
                            add(entry, category, .developer, sharedWith: claimants)
                        } else {
                            continue
                        }
                    } else if category == .privilegedHelpers,
                        let claimants = developerClaim(entry.path, identity, others)
                    {
                        add(entry, category, .developer, sharedWith: claimants)
                    } else {
                        guard category.looksInsideVendorFolder,
                            entry.lastPathComponent.lowercased() == identity.vendor, isDirectory(entry),
                            let children = try? FileManager.default.contentsOfDirectory(
                                at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        else { continue }
                        for child in children {
                            if let evidence = LeftoverMatcher.evidence(
                                for: child.lastPathComponent, in: category, identity: identity)
                            {
                                add(child, category, evidence)
                            }
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
                        // Shared exactly as its daemon is.
                        add(URL(fileURLWithPath: program), .privilegedHelpers, .daemonTool,
                            sharedWith: found.first { $0.url == entry }?.sharedWith)
                    }
                }
            }
        }
        return found.sorted {
            ($0.category.rawValue, $0.url.path) < ($1.category.rawValue, $1.url.path)
        }
    }

    /* A launch job's program, or a helper tool, that the app's developer
       signed belongs to the app even when nothing names it — OpenVPN's
       daemons say org.openvpn.client, not the app's org.openvpn.client.app.
       Not when the program sits inside some other app, though: then it is
       that app's (Google's updater runs from its own GoogleUpdater.app).
       Other installed apps from the same developer share it. Returns those
       apps (empty when none), or nil when the developer rule doesn't
       apply. */
    static func developerClaim(_ program: String, _ identity: AppIdentity, _ others: OtherApps) -> [String]? {
        guard let team = identity.teamID else { return nil }
        let insideApp = identity.appPath.map { program.hasPrefix($0 + "/") } ?? false
        guard insideApp || !program.contains(".app/"),
            FileManager.default.fileExists(atPath: program),
            CodeSignature.teamID(of: URL(fileURLWithPath: program)) == team
        else { return nil }
        return (others.teams[team.lowercased()] ?? []).sorted()
    }

    /* What starts checked: everything the app alone uses, except what
       needs the user's say (`needsReview`); nothing at all when another
       copy is installed (it shares every file) or the app is part of macOS
       (whose files stay in use as long as the system does). */
    static func initialSelection(_ found: [Leftover], isSystemApp: Bool, hasOtherCopies: Bool) -> Set<URL> {
        guard !isSystemApp, !hasOtherCopies else { return [] }
        return Set(found.filter { $0.sharedWith.isEmpty && !$0.needsReview }.map(\.url))
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
            !known.contains($0.url) && !vetoed.contains($0.category) && $0.sharedWith.isEmpty && !$0.needsReview
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
