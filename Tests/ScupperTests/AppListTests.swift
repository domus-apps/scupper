import Foundation
import Testing

@testable import Scupper

private func makeApp(_ url: URL, id: String?, name: String? = nil, displayName: String? = nil) throws {
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = [:]
    if let id { info["CFBundleIdentifier"] = id }
    if let name { info["CFBundleName"] = name }
    if let displayName { info["CFBundleDisplayName"] = displayName }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
}

@Test func theListTakesAppsAndOneFolderLevelOnceEach() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scupper-list-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeApp(root.appendingPathComponent("Zeta.app"), id: "com.example.zeta")
    try makeApp(root.appendingPathComponent("Utilities/Alpha.app"), id: "com.example.alpha")
    // Two folders down is a bundle's business, not the list's.
    try makeApp(root.appendingPathComponent("Vendor/Deeper/Hidden.app"), id: "com.example.hidden")
    // Without an identifier there is nothing to look for.
    try makeApp(root.appendingPathComponent("Plain.app"), id: nil)
    // A link to a listed app is the same app.
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("Link.app"), withDestinationURL: root.appendingPathComponent("Zeta.app"))

    let apps = AppList.installed(in: [root])
    #expect(apps.map(\.name) == ["Alpha", "Zeta"])
    #expect(apps.allSatisfy { !$0.url.path.contains("Link.app") })
}

@Test func anEmptyDisplayNameFallsBackToTheBundleName() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scupper-name-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    // RapidAPI.app ships CFBundleDisplayName "".
    try makeApp(root.appendingPathComponent("Paw.app"), id: "com.luckymarmot.Paw", name: "RapidAPI", displayName: "")
    #expect(AppList.installed(in: [root]).map(\.name) == ["RapidAPI"])
}

@Test func searchMatchesTheNameOrTheFileName() {
    let apps = [
        ListedApp(url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"), name: "Code"),
        ListedApp(url: URL(fileURLWithPath: "/Applications/Keynote.app"), name: "Keynote"),
    ]
    #expect(AppList.filter(apps, by: "  ").count == 2)
    #expect(AppList.filter(apps, by: "visual").map(\.name) == ["Code"])
    #expect(AppList.filter(apps, by: "KEY").map(\.name) == ["Keynote"])
    #expect(AppList.filter(apps, by: "pages").isEmpty)
}

@Test func sortingBySizePutsUnmeasuredAppsLastEitherWay() {
    func app(_ name: String) -> ListedApp { ListedApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name) }
    let apps = [app("Beta"), app("alpha"), app("Gamma"), app("Delta")]
    let sizes = [apps[0].url: 300, apps[1].url: 100, apps[2].url: 300] as [URL: Int64]
    let names = { (sort: AppSort) in AppList.sorted(apps, by: sort, sizes: sizes).map(\.name) }
    #expect(names(AppSort(key: .name, ascending: true)) == ["alpha", "Beta", "Delta", "Gamma"])
    #expect(names(AppSort(key: .name, ascending: false)) == ["Gamma", "Delta", "Beta", "alpha"])
    // Equal sizes keep name order; Delta has no size yet.
    #expect(names(AppSort(key: .size, ascending: false)) == ["Beta", "Gamma", "alpha", "Delta"])
    #expect(names(AppSort(key: .size, ascending: true)) == ["alpha", "Beta", "Gamma", "Delta"])
}

@Test func theSharingCheckSeesEveryAppTheListShows() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scupper-catalog-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeApp(root.appendingPathComponent("Zeta.app"), id: "com.example.zeta")
    // An app in its vendor's folder (OpenVPN Connect/OpenVPN Connect.app).
    try makeApp(root.appendingPathComponent("Vendor/Alpha.app"), id: "com.example.alpha")

    let catalog = InstalledApps.catalog(in: [root])
    #expect(Set(catalog.map(\.url)) == Set(AppList.installed(in: [root]).map(\.url)))
    #expect(InstalledApps.claims(excluding: root.appendingPathComponent("Zeta.app"), in: catalog)
        .identifiers["com.example.alpha"] == ["Alpha"])
}
