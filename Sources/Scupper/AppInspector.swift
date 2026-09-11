import AppKit

/// The names an app's leftovers may be filed under.
struct AppIdentity: Equatable, Sendable {
    var bundleID: String
    /// Display name, file name, CFBundleName, executable — deduplicated.
    var names: [String]

    /// The vendor segment of a reverse-DNS identifier, lowercased:
    /// "google" for com.google.Chrome. Vendors file products under a folder
    /// of this name. Empty when the identifier has no such segment.
    var vendor: String {
        let parts = bundleID.split(separator: ".")
        return parts.count >= 3 ? parts[1].lowercased() : ""
    }
}

/// What Scupper knows about a dropped app, read from its bundle.
struct InspectedApp: Equatable, Sendable {
    var url: URL
    var name: String
    var bundleID: String
    var version: String?
    var names: [String]

    /// Apps under /System are protected by the OS and can't be moved.
    var isSystem: Bool { url.path.hasPrefix("/System/") }
    var identity: AppIdentity { AppIdentity(bundleID: bundleID, names: names) }
}

enum AppInspector {
    static func inspect(_ dropped: URL) -> InspectedApp? {
        let url = dropped.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app",
            let bundle = Bundle(url: url),
            let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty
        else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let localized = bundle.localizedInfoDictionary ?? [:]
        let fileName = url.deletingPathExtension().lastPathComponent
        let displayName =
            (localized["CFBundleDisplayName"] ?? info["CFBundleDisplayName"]
                ?? localized["CFBundleName"] ?? info["CFBundleName"]) as? String ?? fileName

        var names: [String] = []
        for candidate in [displayName, fileName, info["CFBundleName"] as? String,
                          info["CFBundleExecutable"] as? String] {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespaces),
                !candidate.isEmpty, !names.contains(candidate)
            else { continue }
            names.append(candidate)
        }
        return InspectedApp(
            url: url, name: displayName, bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String, names: names)
    }
}
