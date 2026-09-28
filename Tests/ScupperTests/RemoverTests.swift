import Foundation
import Testing

@testable import Scupper

@Test func removalTargetsNeverIncludeASharedFolderOrRepeatAPath() {
    let library = LeftoverScanner.userLibrary
    let reports = library.appendingPathComponent("Logs/DiagnosticReports")
    let crash = reports.appendingPathComponent("Example_2026-09-28.ips")
    let cache = library.appendingPathComponent("Caches/com.example.app")
    let app = URL(fileURLWithPath: "/Applications/Example.app")
    let items = [
        Leftover(url: cache, category: .caches, size: 10),
        // A grouped row: the folder is shared by every app's crash reports.
        Leftover(url: reports, category: .crashReports, size: 5, files: [crash]),
        // The same row again, as a rescan after the app quits can bring it.
        Leftover(url: cache, category: .caches, size: 10),
    ]
    let targets = Remover.targets(for: items, app: app)
    #expect(targets == [cache, crash, app])
    #expect(!targets.contains(reports))
    #expect(Remover.targets(for: items, app: nil) == [cache, crash])
}

@Test func onlyContainerPermissionErrorsAskForFullDiskAccess() {
    let library = LeftoverScanner.userLibrary
    let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    let container = library.appendingPathComponent("Containers/org.example.helper")
    let group = library.appendingPathComponent("Group Containers/group.org.example")
    let cache = library.appendingPathComponent("Caches/org.example")
    #expect(Remover.isContainerProtection(denied, at: container))
    #expect(Remover.isContainerProtection(denied, at: group))
    // Other folders and other errors are not what Full Disk Access fixes.
    #expect(!Remover.isContainerProtection(denied, at: cache))
    #expect(!Remover.isContainerProtection(denied, at: library.appendingPathComponent("Containers")))
    let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
    #expect(!Remover.isContainerProtection(missing, at: container))
}
