import Foundation
import Testing

@testable import Scupper

private let finalCut = AppIdentity(
    bundleID: "com.apple.FinalCut", names: ["Final Cut Pro"],
    relatedBundleIDs: ["com.apple.ProAppsCompatibility"],
    appGroups: ["PTN9T2S29T.com.apple.videoProApps"])

private func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("scupper-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func write(_ url: URL, bytes: Int = 10) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
}

private func writePlist(_ url: URL, _ plist: [String: Any]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
}

@Test func helperIdentifiersAndSignedGroupsAreTheAppsToo() {
    #expect(LeftoverMatcher.matches("com.apple.ProAppsCompatibility", in: .containers, identity: finalCut))
    #expect(LeftoverMatcher.matches("com.apple.ProAppsCompatibility.plist", in: .preferences, identity: finalCut))
    // A group container named only by the signature, case aside.
    #expect(LeftoverMatcher.matches("PTN9T2S29T.com.apple.videoproapps", in: .groupContainers, identity: finalCut))
    #expect(!LeftoverMatcher.matches("PTN9T2S29T.com.apple.logic", in: .groupContainers, identity: finalCut))
    // Groups count only as group containers.
    #expect(!LeftoverMatcher.matches("PTN9T2S29T.com.apple.videoProApps", in: .containers, identity: finalCut))
}

@Test func sharedItemsBelongToWhoeverNamesThemMostSpecifically() {
    let others = OtherApps(
        identifiers: ["com.apple.finalcut.fxanalyzer": ["Motion"], "com.apple.motionapp": ["Motion"]],
        groups: ["ptn9t2s29t.com.apple.videoproapps": ["Motion", "Compressor"]])
    // Motion carries the analyzer, so its container is Motion's too.
    #expect(LeftoverMatcher.sharedWith("com.apple.FinalCut.FxAnalyzer", in: .containers,
                                       identity: finalCut, others: others) == ["Motion"])
    #expect(LeftoverMatcher.sharedWith("com.apple.FinalCut", in: .containers,
                                       identity: finalCut, others: others) == [])
    #expect(LeftoverMatcher.sharedWith("PTN9T2S29T.com.apple.videoProApps", in: .groupContainers,
                                       identity: finalCut, others: others) == ["Compressor", "Motion"])
    // A dev build's files aren't shared with the release build just
    // because its identifier is shorter.
    let dev = AppIdentity(bundleID: "com.x.app.dev", names: ["App Dev"])
    let release = OtherApps(identifiers: ["com.x.app": ["App"]])
    #expect(LeftoverMatcher.sharedWith("com.x.app.dev", in: .caches, identity: dev, others: release) == [])
    // Plain-name matches aren't looked up.
    #expect(LeftoverMatcher.sharedWith("Final Cut Pro", in: .applicationSupport,
                                       identity: finalCut, others: others) == [])
}

@Test func launchJobsAreMatchedByWhatTheyRun() {
    let steam = AppIdentity(bundleID: "com.valvesoftware.steam", names: ["Steam"], appPath: "/Applications/Steam.app")
    let support = "/Users/x/Library/Application Support/Steam"
    func job(_ program: String?, _ associated: [String] = []) -> LaunchJob {
        LaunchJob(label: "x", program: program, associatedBundleIDs: associated)
    }
    #expect(LeftoverMatcher.jobMatches(job(support + "/steamclean"), identity: steam, folders: [support]))
    #expect(LeftoverMatcher.jobMatches(job("/Applications/Steam.app/Contents/MacOS/helper"), identity: steam, folders: []))
    #expect(LeftoverMatcher.jobMatches(job("/usr/bin/true", ["com.valvesoftware.Steam"]), identity: steam, folders: []))
    // Not inside, just alongside.
    #expect(!LeftoverMatcher.jobMatches(job("/Applications/Steam.app.old/x"), identity: steam, folders: []))
    #expect(!LeftoverMatcher.jobMatches(job(support + "-beta/x"), identity: steam, folders: [support]))
    #expect(!LeftoverMatcher.jobMatches(job(nil, ["com.other.app"]), identity: steam, folders: [support]))
}

@Test func launchJobPlistsYieldTheirProgram() throws {
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let one = root.appendingPathComponent("one.plist")
    try writePlist(one, ["Label": "com.x.one", "ProgramArguments": ["/opt/x/run", "--flag"],
                         "AssociatedBundleIdentifiers": "com.x.app"])
    #expect(LaunchJob(contentsOf: one) == LaunchJob(label: "com.x.one", program: "/opt/x/run",
                                                   associatedBundleIDs: ["com.x.app"]))
    let two = root.appendingPathComponent("two.plist")
    try writePlist(two, ["Label": "com.x.two", "Program": "/opt/x/two", "ProgramArguments": ["ignored"]])
    #expect(LaunchJob(contentsOf: two)?.program == "/opt/x/two")
    #expect(LaunchJob(contentsOf: root.appendingPathComponent("missing.plist")) == nil)
}

@Test func scannerFindsJobsHelpersAndSystemWideItems() throws {
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library")
    let system = root.appendingPathComponent("System Library")
    let steam = AppIdentity(bundleID: "com.valvesoftware.steam", names: ["Steam"],
                            appPath: root.appendingPathComponent("Steam.app").path)
    let support = library.appendingPathComponent("Application Support/Steam")
    try write(support.appendingPathComponent("steamclean"))
    // Named for another identifier, but runs from the app's folder.
    try writePlist(library.appendingPathComponent("LaunchAgents/com.valvesoftware.steamclean.plist"),
                   ["Label": "com.valvesoftware.steamclean", "Program": support.appendingPathComponent("steamclean").path])
    try writePlist(library.appendingPathComponent("LaunchAgents/com.other.agent.plist"),
                   ["Label": "com.other.agent", "Program": "/usr/bin/true"])
    // A daemon that says whose it is, and its helper tool (named anything).
    let tool = system.appendingPathComponent("PrivilegedHelperTools/steam-updater")
    try write(tool)
    try writePlist(system.appendingPathComponent("LaunchDaemons/com.valve.updater.plist"),
                   ["Label": "com.valve.updater", "Program": tool.path,
                    "AssociatedBundleIdentifiers": ["com.valvesoftware.steam"]])
    try write(system.appendingPathComponent("Application Support/Steam/shared.bin"))
    try write(system.appendingPathComponent("Preferences/com.valvesoftware.steam.plist"))
    try write(system.appendingPathComponent("Preferences/com.valvesoftware.steamy.plist"))

    let found = LeftoverScanner.scan(identity: steam, library: library, systemLibrary: system)
    let names = found.map {
        ($0.category, $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: ""))
    }
    #expect(names.map(\.1) == [
        "Library/Application Support/Steam",
        "Library/LaunchAgents/com.valvesoftware.steamclean.plist",
        "System Library/Application Support/Steam",
        "System Library/Preferences/com.valvesoftware.steam.plist",
        "System Library/LaunchDaemons/com.valve.updater.plist",
        "System Library/PrivilegedHelperTools/steam-updater",
    ])
    #expect(names.map(\.0) == [.applicationSupport, .launchAgents, .systemApplicationSupport,
                                .systemPreferences, .launchDaemons, .privilegedHelpers])
    #expect(found.filter(\.category.isSystemWide).count == 4)
}

@Test func sharedItemsAreMarkedAndNeverAddedBehindTheUsersBack() throws {
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library")
    try write(library.appendingPathComponent("Group Containers/PTN9T2S29T.com.apple.videoProApps/x"))
    try write(library.appendingPathComponent("Containers/com.apple.FinalCut/x"))
    let others = OtherApps(groups: ["ptn9t2s29t.com.apple.videoproapps": ["Motion"]])
    let found = LeftoverScanner.scan(identity: finalCut, others: others, library: library, systemLibrary: nil)
    #expect(found.map(\.sharedWith) == [[], ["Motion"]])
    // Even with everything checked, a shared item that appears after the
    // quit isn't taken.
    let added = LeftoverScanner.additions(after: found, shown: [], selection: [])
    #expect(added.map(\.url.lastPathComponent) == ["com.apple.FinalCut"])
}

@Test func unreadableContainersAreMarkedProtected() throws {
    let root = temporaryFolder()
    let library = root.appendingPathComponent("Library")
    let data = library.appendingPathComponent("Containers/com.apple.FinalCut/Data")
    try write(data.appendingPathComponent("inside"), bytes: 4096)
    try write(library.appendingPathComponent("Caches/com.apple.FinalCut/Data/inside"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: data.path)
    let cacheData = library.appendingPathComponent("Caches/com.apple.FinalCut/Data")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cacheData.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheData.path)
        try? FileManager.default.removeItem(at: root)
    }
    let found = LeftoverScanner.scan(identity: finalCut, library: library, systemLibrary: nil)
    #expect(found.map(\.category) == [.caches, .containers])
    // Only containers: elsewhere an unreadable folder is just unreadable.
    #expect(found.map(\.isProtected) == [false, true])
}

@Test func nestedHelpersOfTheSameVendorBecomeRelatedIdentifiers() throws {
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Cut.app")
    func bundle(_ relative: String, _ id: String) throws {
        try writePlist(app.appendingPathComponent(relative + "/Contents/Info.plist"), ["CFBundleIdentifier": id])
    }
    try writePlist(app.appendingPathComponent("Contents/Info.plist"),
                   ["CFBundleIdentifier": "com.apple.FinalCut", "CFBundleName": "Cut"])
    try bundle("Contents/PlugIns/Share.appex", "com.apple.FinalCut.Share")  // under the app's own
    try bundle("Contents/Library/LoginItems/Analyzer.app", "com.apple.FxAnalyzer")
    try bundle("Contents/Library/LoginItems/Analyzer.app/Contents/XPCServices/Render.xpc", "com.apple.FxRender")
    try bundle("Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app", "org.sparkle-project.Sparkle.Updater")
    try bundle("Contents/Helpers/Crash.app", "io.sentry.crashpad")  // another vendor's SDK
    let inspected = try #require(AppInspector.inspect(app))
    #expect(inspected.relatedBundleIDs.sorted() == ["com.apple.FxAnalyzer", "com.apple.FxRender"])
    #expect(inspected.identity.bundleIDs.first == "com.apple.FinalCut")
}

@Test func theAdministratorScriptMovesEverythingWithoutReplacingAnything() throws {
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent("Trash")
    let daemons = root.appendingPathComponent("LaunchDaemons")
    let plist = daemons.appendingPathComponent("com.scupper.test.nonexistent.plist")
    try writePlist(plist, ["Label": "com.scupper.test.nonexistent", "Program": "/usr/bin/true"])
    let quoteName = root.appendingPathComponent("Support/it's \"odd\" $HOME")
    try write(quoteName.appendingPathComponent("x"))
    let missing = root.appendingPathComponent("gone.txt")
    // Already in the Trash under the same name, twice over.
    try write(trash.appendingPathComponent("com.scupper.test.nonexistent.plist"), bytes: 1)
    try write(trash.appendingPathComponent("com.scupper.test.nonexistent 2.plist"), bytes: 2)

    let script = Remover.administratorScript(for: [plist, quoteName, missing], trash: trash, uid: getuid())
    #expect(script.contains("/bin/launchctl bootout 'system/com.scupper.test.nonexistent'"))
    // Run it as ourselves: the same script, minus the password.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(Remover.movedPaths(in: output) == [plist.path, quoteName.path])
    #expect(output.contains("fail " + missing.path))
    let inTrash = try FileManager.default.contentsOfDirectory(atPath: trash.path).sorted()
    #expect(inTrash == ["com.scupper.test.nonexistent 2.plist", "com.scupper.test.nonexistent 3.plist",
                        "com.scupper.test.nonexistent.plist", "it's \"odd\" $HOME"])
    // What was there is untouched.
    let first = try Data(contentsOf: trash.appendingPathComponent("com.scupper.test.nonexistent.plist"))
    #expect(first.count == 1)
    #expect(!FileManager.default.fileExists(atPath: plist.path))
}

@Test func onlyLibraryItemsNeedAnAdministrator() {
    #expect(Remover.needsAdministrator(URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist")))
    #expect(!Remover.needsAdministrator(LeftoverScanner.userLibrary.appendingPathComponent("Caches/x")))
    #expect(!Remover.needsAdministrator(URL(fileURLWithPath: "/Library")))
    #expect(!Remover.needsAdministrator(URL(fileURLWithPath: "/Applications/X.app")))
}

@Test func processesRunningFromInsideTheBundleAreFound() throws {
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Helper Host.app")
    let binary = app.appendingPathComponent("Contents/Library/Helpers/sleeper")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: binary.path)
    // A copied platform binary is killed at launch unless signed anew.
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["-s", "-", "-f", binary.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    let process = Process()
    process.executableURL = binary
    process.arguments = ["30"]
    try process.run()
    defer { process.terminate() }
    Thread.sleep(forTimeInterval: 0.2)
    #expect(Remover.processes(runningFrom: app) == [process.processIdentifier])
    #expect(Remover.processes(runningFrom: root.appendingPathComponent("Helper")) == [])
}

@Test func sharingCanBeMarkedAfterTheScan() {
    let group = Leftover(url: URL(fileURLWithPath: "/L/Group Containers/PTN9T2S29T.com.apple.videoProApps"),
                         category: .groupContainers, size: 1)
    let own = Leftover(url: URL(fileURLWithPath: "/L/Containers/com.apple.FinalCut"), category: .containers, size: 1)
    let others = OtherApps(groups: ["ptn9t2s29t.com.apple.videoproapps": ["Motion"]])
    let marked = LeftoverScanner.markingShared([group, own], identity: finalCut, others: others)
    #expect(marked.map(\.sharedWith) == [["Motion"], []])
}

@Test func namesMatchWithoutTheirSpacesAndPunctuation() {
    let portingKit = AppIdentity(bundleID: "com.paulthetall.portingkit", names: ["Porting Kit"])
    #expect(LeftoverMatcher.matches("portingkit", in: .applicationSupport, identity: portingKit))
    #expect(LeftoverMatcher.matches("Porting-Kit", in: .caches, identity: portingKit))
    #expect(LeftoverMatcher.matches("porting_kit", in: .systemApplicationSupport, identity: portingKit))
    #expect(!LeftoverMatcher.matches("Porting", in: .applicationSupport, identity: portingKit))
    #expect(!LeftoverMatcher.matches("portingkit2", in: .applicationSupport, identity: portingKit))
    // Still only where apps traditionally use their names.
    #expect(!LeftoverMatcher.matches("portingkit", in: .containers, identity: portingKit))
    // Squeezing can't make a short name long enough to count.
    let ab = AppIdentity(bundleID: "com.x.ab", names: ["A B"])
    #expect(!LeftoverMatcher.matches("ab", in: .applicationSupport, identity: ab))
}

@Test func recentDocumentListsAreFoundByNameInEveryFormat() throws {
    #expect(LeftoverMatcher.matches("com.paulthetall.portingkit.sfl4",
                                    in: .recentDocuments, identity: AppIdentity(bundleID: "com.paulthetall.portingkit", names: [])))
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library")
    let folder = library.appendingPathComponent(LeftoverCategory.recentDocuments.directories[0])
    try write(folder.appendingPathComponent("com.paulthetall.portingkit.sfl4"))
    try write(folder.appendingPathComponent("com.paulthetall.portingkit.helper.sfl4"))  // not the app's own list
    let found = LeftoverScanner.scan(identity: AppIdentity(bundleID: "com.paulthetall.portingkit", names: ["Porting Kit"]),
                                     library: library, systemLibrary: nil)
    #expect(found.map(\.url.lastPathComponent) == ["com.paulthetall.portingkit.sfl4"])
    // The folder could be listed here, so nothing needed Full Disk Access.
    #expect(found.map(\.isProtected) == [false])
    let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    #expect(Remover.isContainerProtection(
        denied, at: LeftoverScanner.userLibrary.appendingPathComponent(LeftoverCategory.recentDocuments.directories[0] + "/x.sfl4")))
}

@Test func copiesInATrashOrOnADiskImageDontCount() {
    #expect(Remover.isInTrash(URL(fileURLWithPath: "/Users/x/.Trash/Porting Kit.app")))
    #expect(Remover.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/Porting Kit.app")))
    #expect(!Remover.isInTrash(URL(fileURLWithPath: "/Applications/Porting Kit.app")))
    #expect(!Remover.isOnReadOnlyVolume(FileManager.default.temporaryDirectory))
}
