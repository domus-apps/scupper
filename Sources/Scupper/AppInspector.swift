import AppKit
import Security

/// The names an app's leftovers may be filed under.
struct AppIdentity: Equatable, Sendable {
    var bundleID: String
    /// Display name, file name, CFBundleName, executable — deduplicated.
    var names: [String]
    /// Identifiers of the extensions, helpers and login items inside the
    /// bundle whose identifier isn't under the app's own
    /// (com.apple.FinalCut.FxAnalyzer inside Final Cut Pro). Each files its
    /// own container and preferences.
    var relatedBundleIDs: [String] = []
    /// App groups from the code signatures (the app's and its
    /// extensions'): the exact names of its group containers, which rarely
    /// contain the bundle identifier ("BQR82RBBHL.slack").
    var appGroups: [String] = []
    /// Where the bundle is, so a launch agent that runs something inside
    /// it can be recognized whatever it is named.
    var appPath: String? = nil

    /// The app's identifier first, then its helpers'.
    var bundleIDs: [String] { [bundleID] + relatedBundleIDs }

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
    var relatedBundleIDs: [String] = []
    var appGroups: [String] = []

    /// Apps under /System are protected by the OS and can't be moved.
    var isSystem: Bool { url.path.hasPrefix("/System/") }
    var identity: AppIdentity {
        AppIdentity(bundleID: bundleID, names: names, relatedBundleIDs: relatedBundleIDs,
                    appGroups: appGroups, appPath: url.path)
    }
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
        let nested = nestedBundles(in: url)
        let vendor = vendorDomain(bundleID)
        var related: [String] = []
        for inner in nested {
            guard let id = Bundle(url: inner)?.bundleIdentifier, !id.isEmpty,
                !LeftoverMatcher.identifierMatches(id.lowercased(), bundleID.lowercased()),
                !related.contains(id),
                // Someone else's code shipped inside (Sparkle's installer,
                // a crash reporter SDK) files under its own vendor, shared by
                // every app that embeds it: only the app vendor's own count.
                !vendor.isEmpty, vendorDomain(id) == vendor
            else { continue }
            related.append(id)
        }
        var groups: [String] = []
        for code in [url] + nested {
            for group in CodeSignature.appGroups(of: code) where !groups.contains(group) {
                groups.append(group)
            }
        }
        return InspectedApp(
            url: url, name: displayName, bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String, names: names,
            relatedBundleIDs: related, appGroups: groups)
    }

    /* Where apps keep their extensions, helper apps, login items and XPC
       services, and the same inside each of those. Only these places:
       walking all of Contents takes seconds on the big apps (Logic, Xcode)
       and what hides elsewhere is mostly Electron's helpers, filed under
       the app's own identifier anyway. Bundles inside frameworks belong to
       the framework's vendor and are left alone. */
    static let nestedPlaces = [
        "Contents/PlugIns", "Contents/Extensions", "Contents/XPCServices", "Contents/Helpers",
        "Contents/MacOS", "Contents/Frameworks", "Contents/Applications", "Contents/SharedSupport",
        "Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/Library/Helpers",
        "Contents/Library/LaunchAgents", "Contents/Library/SystemExtensions",
    ]

    static func nestedBundles(in bundle: URL, depth: Int = 0) -> [URL] {
        guard depth < 3 else { return [] }
        var found: [URL] = []
        for place in nestedPlaces {
            let folder = bundle.appendingPathComponent(place)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let url = folder.appendingPathComponent(name)
                guard ["app", "appex", "xpc", "systemextension"].contains(url.pathExtension.lowercased())
                else { continue }
                found.append(url)
                found += nestedBundles(in: url, depth: depth + 1)
            }
        }
        return found
    }

    /// "com.apple" for com.apple.FinalCut: the reverse-DNS domain.
    static func vendorDomain(_ bundleID: String) -> String {
        let parts = bundleID.lowercased().split(separator: ".")
        return parts.count >= 3 ? parts.prefix(2).joined(separator: ".") : ""
    }
}

enum CodeSignature {
    /// The com.apple.security.application-groups entitlement of a bundle.
    static func appGroups(of bundle: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code
        else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let signing = info as? [String: Any],
            let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}

/// What the other installed apps lay claim to, lowercased: identifiers
/// (their own and their helpers') and app groups, each with the names of
/// the apps claiming it.
struct OtherApps: Equatable, Sendable {
    var identifiers: [String: [String]] = [:]
    var groups: [String: [String]] = [:]

    static let none = OtherApps()
}

/* Much of what an app leaves is shared: Pages, Numbers and Keynote all
   keep group.com.apple.iWork, and Final Cut Pro and Motion both carry
   com.apple.FinalCut.FxAnalyzer. So before anything is offered, the other
   installed apps are asked what they use (well under a second for 100
   apps, run alongside the scan). */
enum InstalledApps {
    // macOS's own apps too: Safari shares a group with Tips.
    static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                          "/System/Applications/Utilities"]
        + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]

    static func claims(excluding app: URL) -> OtherApps {
        let own = app.standardizedFileURL.resolvingSymlinksInPath()
        var claims = OtherApps()
        func add(_ key: String, _ name: String, to table: inout [String: [String]]) {
            let key = key.lowercased()
            if !(table[key]?.contains(name) ?? false) { table[key, default: []].append(name) }
        }
        for folder in folders {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(entry)
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard url != own else { continue }
                let name = String(entry.dropLast(4))
                for bundle in [url] + AppInspector.nestedBundles(in: url) {
                    if let id = Bundle(url: bundle)?.bundleIdentifier, !id.isEmpty {
                        add(id, name, to: &claims.identifiers)
                    }
                    for group in CodeSignature.appGroups(of: bundle) {
                        add(group, name, to: &claims.groups)
                    }
                }
            }
        }
        return claims
    }
}
