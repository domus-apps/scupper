import Foundation

/// One app in the start screen's list.
struct ListedApp: Identifiable, Equatable, Sendable {
    var url: URL
    var name: String
    var id: URL { url }
}

/// How the start screen orders its apps: by a column, either way.
struct AppSort: Equatable, Sendable {
    enum Key: String, Sendable {
        case name, size
    }

    var key: Key = .name
    var ascending = true

    private static let keyDefault = "AppListSortKey"
    private static let ascendingDefault = "AppListSortAscending"

    /// The order last chosen, or by name.
    static var saved: AppSort {
        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: keyDefault).flatMap(Key.init(rawValue:)) else { return AppSort() }
        return AppSort(key: key, ascending: defaults.bool(forKey: ascendingDefault))
    }

    func save() {
        UserDefaults.standard.set(key.rawValue, forKey: Self.keyDefault)
        UserDefaults.standard.set(ascending, forKey: Self.ascendingDefault)
    }
}

/* The apps the start screen offers: the ones in /Applications and
   ~/Applications, and one level into their folders (Utilities, a vendor's
   folder, Chrome Apps.localized). macOS's own apps are left out, Safari's
   link into /System included: they can't be removed, and dropping one still
   shows what it left behind. */
enum AppList {
    static let folders = [
        URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    static func installed(in folders: [URL] = folders) -> [ListedApp] {
        bundles(in: folders).compactMap { url in
            guard !url.path.hasPrefix("/System/"),
                let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty
            else { return nil }
            return ListedApp(url: url, name: AppInspector.names(of: bundle, at: url).display)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /* Every app bundle in the folders and one folder level into them, each
       once, by its resolved path. The list and the check for what other
       apps share (InstalledApps) both look here, so an app the list shows
       is never one the sharing check misses. */
    static func bundles(in folders: [URL]) -> [URL] {
        var seen: Set<String> = []
        var found: [URL] = []
        func add(_ url: URL) {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            if seen.insert(resolved.path).inserted { found.append(resolved) }
        }
        for folder in folders {
            for child in contents(of: folder) {
                if child.pathExtension.lowercased() == "app" {
                    add(child)
                } else if isFolder(child) {
                    for inner in contents(of: child) where inner.pathExtension.lowercased() == "app" {
                        add(inner)
                    }
                }
            }
        }
        return found
    }

    /// Apps whose name contains the query, the whole list for an empty one.
    static func filter(_ apps: [ListedApp], by query: String) -> [ListedApp] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedStandardContains(query)
                || $0.url.deletingPathExtension().lastPathComponent.localizedStandardContains(query)
        }
    }

    /* Apps not measured yet go last either way, so a size sort fills in
       from the top as the sizes arrive. Equal ones keep name order. */
    static func sorted(_ apps: [ListedApp], by sort: AppSort, sizes: [URL: Int64]) -> [ListedApp] {
        apps.sorted { a, b in
            let byName = a.name.localizedStandardCompare(b.name)
            switch sort.key {
            case .name:
                return sort.ascending ? byName == .orderedAscending : byName == .orderedDescending
            case .size:
                switch (sizes[a.url], sizes[b.url]) {
                case let (x?, y?) where x != y:
                    return sort.ascending ? x < y : x > y
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return byName == .orderedAscending
                }
            }
        }
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
