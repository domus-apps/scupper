import Foundation
import Testing

@testable import Scupper

private let sill = AppIdentity(bundleID: "com.jhaemin.sill", names: ["Sill"])
private let code = AppIdentity(bundleID: "com.microsoft.VSCode", names: ["Visual Studio Code", "Code", "Electron"])

@Test func identifierMatchesItselfAndWhatIsUnderIt() {
    #expect(LeftoverMatcher.identifierMatches("com.jhaemin.sill", "com.jhaemin.sill"))
    #expect(LeftoverMatcher.identifierMatches("com.jhaemin.sill.dev", "com.jhaemin.sill"))
    #expect(LeftoverMatcher.identifierMatches("com.jhaemin.sill.helper", "com.jhaemin.sill"))
    // A different app that merely shares the prefix.
    #expect(!LeftoverMatcher.identifierMatches("com.jhaemin.sillage", "com.jhaemin.sill"))
    #expect(!LeftoverMatcher.identifierMatches("com.jhaemin", "com.jhaemin.sill"))
    // Mac Catalyst files everything under a "maccatalyst." prefix.
    #expect(LeftoverMatcher.identifierMatches("maccatalyst.com.jhaemin.sill", "com.jhaemin.sill"))
    #expect(LeftoverMatcher.matches("maccatalyst.com.jhaemin.sill", in: .containers, identity: sill))
    #expect(LeftoverMatcher.matches("maccatalyst.com.jhaemin.sill.savedState", in: .savedState, identity: sill))
    #expect(!LeftoverMatcher.matches("maccatalyst.com.jhaemin.sillage", in: .containers, identity: sill))
}

@Test func preferenceDomainsComeFromThePlistName() {
    let library = URL(fileURLWithPath: "/Users/x/Library")
    let plain = library.appendingPathComponent("Preferences/com.jhaemin.sill.plist")
    #expect(Remover.preferenceDomain(of: plain) == .init(name: "com.jhaemin.sill", currentHostOnly: false))
    let dev = library.appendingPathComponent("Preferences/com.jhaemin.sill.dev.plist")
    #expect(Remover.preferenceDomain(of: dev)?.name == "com.jhaemin.sill.dev")
    let byHost = library.appendingPathComponent(
        "Preferences/ByHost/com.jhaemin.sill.0C8B3E6A-1D2F-4E5A-9B7C-123456789ABC.plist")
    #expect(Remover.preferenceDomain(of: byHost) == .init(name: "com.jhaemin.sill", currentHostOnly: true))
    // Not a preferences plist: a launch agent, a folder, a cache.
    #expect(Remover.preferenceDomain(of: library.appendingPathComponent("LaunchAgents/com.jhaemin.sill.plist")) == nil)
    #expect(Remover.preferenceDomain(of: library.appendingPathComponent("Preferences/com.jhaemin.sill")) == nil)
}

@Test func preferencesAndAgentsAreMatchedOnTheirPlistStem() {
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.plist", in: .preferences, identity: sill))
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.dev.plist", in: .preferences, identity: sill))
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.A1B2C3.plist", in: .preferences, identity: sill))  // ByHost
    #expect(!LeftoverMatcher.matches("com.jhaemin.sill", in: .preferences, identity: sill))  // no .plist
    #expect(!LeftoverMatcher.matches("com.jhaemin.sillage.plist", in: .preferences, identity: sill))
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.agent.plist", in: .launchAgents, identity: sill))
}

@Test func savedStateCookiesAndGroupContainersUseTheirOwnShapes() {
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.savedState", in: .savedState, identity: sill))
    #expect(!LeftoverMatcher.matches("com.jhaemin.sill", in: .savedState, identity: sill))
    #expect(LeftoverMatcher.matches("com.jhaemin.sill", in: .httpStorages, identity: sill))
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.binarycookies", in: .httpStorages, identity: sill))
    #expect(LeftoverMatcher.matches("TA74GWSAB2.com.jhaemin.sill", in: .groupContainers, identity: sill))
    #expect(LeftoverMatcher.matches("group.com.jhaemin.sill", in: .groupContainers, identity: sill))
    #expect(LeftoverMatcher.matches("group.com.jhaemin.sill.shared", in: .groupContainers, identity: sill))
    #expect(!LeftoverMatcher.matches("TA74GWSAB2.com.jhaemin.coffer", in: .groupContainers, identity: sill))
}

@Test func plainNamesCountOnlyWhereAppsTraditionallyUseThem() {
    #expect(LeftoverMatcher.matches("Sill", in: .applicationSupport, identity: sill))
    #expect(LeftoverMatcher.matches("sill", in: .caches, identity: sill))
    #expect(LeftoverMatcher.matches("Sill", in: .logs, identity: sill))
    #expect(!LeftoverMatcher.matches("Sill", in: .containers, identity: sill))
    #expect(!LeftoverMatcher.matches("Sill", in: .webKit, identity: sill))
    // Every name the app goes by, but nothing under three characters.
    #expect(LeftoverMatcher.matches("Code", in: .applicationSupport, identity: code))
    let go = AppIdentity(bundleID: "org.example.go", names: ["Go"])
    #expect(!LeftoverMatcher.matches("Go", in: .applicationSupport, identity: go))
    #expect(LeftoverMatcher.matches("org.example.go", in: .applicationSupport, identity: go))
}

@Test func crashReportsAreMatchedByNamePrefix() {
    #expect(LeftoverMatcher.matches("Sill-2026-09-07-120000.ips", in: .crashReports, identity: sill))
    #expect(LeftoverMatcher.matches("Code_2026-09-07-120000_mac.crash", in: .crashReports, identity: code))
    #expect(!LeftoverMatcher.matches("Sillage-2026-09-07-120000.ips", in: .crashReports, identity: sill))
    #expect(!LeftoverMatcher.matches("Sill.ips", in: .crashReports, identity: sill))
}

@Test func scannerFindsMatchingEntriesAcrossTheLibraryWithSizes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scupper-test-\(UUID().uuidString)")
    let library = root.appendingPathComponent("Library")
    defer { try? FileManager.default.removeItem(at: root) }

    func write(_ relative: String, bytes: Int) throws {
        let url = library.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }
    try write("Application Support/Sill/specs/index.json", bytes: 100)
    try write("Application Support/Sill/derived/gh.json", bytes: 50)
    try write("Caches/com.jhaemin.sill/spec.zip", bytes: 300)
    try write("Preferences/com.jhaemin.sill.plist", bytes: 20)
    try write("Preferences/com.jhaemin.coffer.plist", bytes: 20)
    try write("Saved Application State/com.jhaemin.sill.savedState/window.plist", bytes: 10)
    try write("Application Support/Coffer/items.db", bytes: 999)
    // The vendor's folder holding the app's own folder, one level down —
    // and a stranger's folder that must not even be listed.
    try write("Application Support/Jhaemin/Sill/state.json", bytes: 30)
    try write("Application Support/Jhaemin/Coffer/state.json", bytes: 30)
    try write("Application Support/AddressBook/Sill/oops.db", bytes: 30)
    try write("Caches/com.apple.nsurlsessiond/Downloads/com.jhaemin.sill/part", bytes: 40)
    try write("Application Support/CrashReporter/Sill_ABC.plist", bytes: 5)
    // Per-launch analytics records: many small files, one row.
    try write("Logs/AppAnalytics/com.jhaemin.sill.0C8B3E6A-1D2F-4E5A-9B7C-123456789ABC.json", bytes: 7)
    try write("Logs/AppAnalytics/com.jhaemin.sill.1C8B3E6A-1D2F-4E5A-9B7C-123456789ABC.json", bytes: 7)
    try write("Logs/AppAnalytics/com.jhaemin.coffer.2C8B3E6A-1D2F-4E5A-9B7C-123456789ABC.json", bytes: 7)

    let found = LeftoverScanner.scan(identity: sill, library: library)
    // The temp folder is a symlink (/var → /private/var); compare resolved paths.
    let base = library.resolvingSymlinksInPath().path
    let paths = found.map { String($0.url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)) }
    #expect(paths == [
        "Application Support/Jhaemin/Sill",
        "Application Support/Sill",
        "Caches/com.jhaemin.sill",
        "Preferences/com.jhaemin.sill.plist",
        "Saved Application State/com.jhaemin.sill.savedState",
        "Application Support/CrashReporter",
        "Caches/com.apple.nsurlsessiond/Downloads/com.jhaemin.sill",
        "Logs/AppAnalytics",
    ])
    let analytics = try #require(found.first { $0.category == .analytics })
    #expect(analytics.isGroup)
    #expect(analytics.files.map(\.lastPathComponent) == [
        "com.jhaemin.sill.0C8B3E6A-1D2F-4E5A-9B7C-123456789ABC.json",
        "com.jhaemin.sill.1C8B3E6A-1D2F-4E5A-9B7C-123456789ABC.json",
    ])
    let crash = try #require(found.first { $0.category == .crashReports })
    #expect(crash.files.map(\.lastPathComponent) == ["Sill_ABC.plist"])
    #expect(!found.first { $0.category == .preferences }!.isGroup)
    // Folder sizes are summed over their contents (allocated size, so at
    // least the bytes written).
    let support = try #require(found.first { $0.category == .applicationSupport })
    #expect((support.size ?? 0) >= 150)
    #expect(found.first { $0.category == .preferences }?.size ?? 0 >= 20)
}

@Test func abbreviatedPathsStartAtTheHome() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(abbreviatedPath(home.appendingPathComponent("Library/Caches/x")) == "~/Library/Caches/x")
    #expect(abbreviatedPath(URL(fileURLWithPath: "/Applications/Sill.app")) == "/Applications/Sill.app")
}

@Test func additionsAfterQuitRespectUncheckedCategories() {
    func item(_ path: String, _ category: LeftoverCategory) -> Leftover {
        Leftover(url: URL(fileURLWithPath: "/L/" + path), category: category, size: 1)
    }
    let shownPrefs = item("Preferences/com.x.app.plist", .preferences)
    let shownCache = item("Caches/com.x.app", .caches)
    let shown = [shownPrefs, shownCache]
    // The user unchecked the cache; the quit wrote a saved state and another cache.
    let rescan = shown + [
        item("Saved Application State/com.x.app.savedState", .savedState),
        item("Caches/com.x.app.helper", .caches),
    ]
    let added = LeftoverScanner.additions(after: rescan, shown: shown, selection: [shownPrefs.url])
    #expect(added.map(\.url.lastPathComponent) == ["com.x.app.savedState"])
    // Everything checked: every new file comes along, nothing shown is repeated.
    let all = LeftoverScanner.additions(after: rescan, shown: shown, selection: Set(shown.map(\.url)))
    #expect(all.map(\.url.lastPathComponent) == ["com.x.app.savedState", "com.x.app.helper"])
}

@Test func vendorIsTheSecondSegmentOfTheIdentifier() {
    #expect(AppIdentity(bundleID: "com.google.Chrome", names: []).vendor == "google")
    #expect(AppIdentity(bundleID: "org.mozilla.firefox", names: []).vendor == "mozilla")
    #expect(AppIdentity(bundleID: "Electron", names: []).vendor == "")
    #expect(AppIdentity(bundleID: "com.app", names: []).vendor == "")
}

@Test func analyticsAndRecentDocumentsAreMatchedOnTheirStems() {
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.0C8B3E6A-1D2F-4E5A-9B7C-123456789ABC.json", in: .analytics, identity: sill))
    #expect(!LeftoverMatcher.matches("com.jhaemin.sillage.0C8B3E6A-1D2F-4E5A-9B7C-123456789ABC.json", in: .analytics, identity: sill))
    #expect(!LeftoverMatcher.matches("com.jhaemin.sill.0C8B3E6A.log", in: .analytics, identity: sill))
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.sfl3", in: .recentDocuments, identity: sill))
    #expect(LeftoverMatcher.matches("com.jhaemin.sill.sfl2", in: .recentDocuments, identity: sill))
    #expect(!LeftoverMatcher.matches("com.jhaemin.sill", in: .recentDocuments, identity: sill))
}
