import Foundation
import Testing

@testable import Scupper

/* Not a test in the usual sense. With SCUPPER_AUDIT set to a file path it
   scans every installed app, read-only, and writes what Scupper would
   offer for each — one line per item, with why it matched and whether it
   starts checked — for Scripts/audit.sh to compare with the last accepted
   snapshot. Without the variable it does nothing. Sizes are left out:
   they change on their own and would bury the rule changes. */
@Test func auditSnapshot() throws {
    guard let output = ProcessInfo.processInfo.environment["SCUPPER_AUDIT"] else { return }
    let catalog = InstalledApps.catalog()
    var lines: [String] = []
    let apps = catalog.filter { !$0.url.path.hasPrefix("/System/") }
        .sorted { ($0.name.lowercased(), $0.url.path) < ($1.name.lowercased(), $1.url.path) }
    for entry in apps {
        // Opened the way a drop opens it: a directory URL, trailing slash and all.
        guard let app = AppInspector.inspect(URL(fileURLWithPath: entry.url.path, isDirectory: true))
        else { continue }
        let identity = app.identity
        let found = LeftoverScanner.scan(
            identity: identity, others: InstalledApps.claims(excluding: app.url, in: catalog))
        let copies = Remover.otherCopies(of: app)
        let selected = LeftoverScanner.initialSelection(
            found, isSystemApp: app.isSystem, hasOtherCopies: !copies.isEmpty)
        var header = "\(abbreviatedPath(app.url))  \(app.bundleID)"
        if !copies.isEmpty { header += "  other copies: " + copies.map(abbreviatedPath).joined(separator: ", ") }
        lines.append(header)
        for item in found {
            var line = "  [\(selected.contains(item.url) ? "x" : " ")] \(abbreviatedPath(item.url))"
            line += "  \(item.category)  \(item.evidence.rawValue)"
            if item.isGroup { line += "  group" }
            if !item.sharedWith.isEmpty { line += "  shared: " + item.sharedWith.joined(separator: ", ") }
            if item.isProtected { line += "  protected" }
            lines.append(line)
        }
    }
    try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
}
