import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

final class MainWindowController: NSWindowController {
    init(model: ScupperModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: ScupperView(model: model)))
        window.title = "Scupper"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 580))
        window.minSize = NSSize(width: 440, height: 360)
        window.center()
        window.setFrameAutosaveName("Main")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

// MARK: - Model

@MainActor
final class ScupperModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case scanning
        case review
        case removing
        case done(RemovalSummary)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var app: InspectedApp?
    @Published private(set) var appSize: Int64?
    @Published private(set) var leftovers: [Leftover] = []
    /// Other installed copies of the same app, which share these files.
    @Published private(set) var otherCopies: [URL] = []
    /// Leftovers that will go to the Trash — all of them, until unchecked.
    @Published var selection: Set<URL> = []
    @Published var includeApp = true
    @Published var isTargeted = false

    private var scanTask: Task<Void, Never>?
    private var others = OtherApps.none

    func open(_ url: URL) {
        guard let inspected = AppInspector.inspect(url) else {
            phase = .failed(L("That isn't an app, or it has no bundle identifier."))
            return
        }
        scanTask?.cancel()
        app = inspected
        leftovers = []
        selection = []
        otherCopies = Remover.otherCopies(of: inspected)
        appSize = nil
        includeApp = !inspected.isSystem
        phase = .scanning
        let identity = inspected.identity
        scanTask = Task { [weak self] in
            /* The other apps first: the scan needs them to tell what they
               share, which for a developer's daemons depends on reading
               signatures as the scan goes (the same path Scripts/audit.sh
               checks). The app's own size is measured meanwhile. */
            async let measured = Task.detached(priority: .userInitiated) {
                LeftoverScanner.size(of: inspected.url)
            }.value
            let others = await Task.detached(priority: .userInitiated) {
                InstalledApps.claims(excluding: inspected.url)
            }.value
            let found = await Task.detached(priority: .userInitiated) {
                LeftoverScanner.scan(identity: identity, others: others)
            }.value
            let size = await measured
            guard let self, !Task.isCancelled, self.app == inspected else { return }
            self.others = others
            self.leftovers = found
            self.selection = LeftoverScanner.initialSelection(
                found, isSystemApp: inspected.isSystem, hasOtherCopies: !self.otherCopies.isEmpty)
            self.appSize = size
            self.phase = .review
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Choose")
        panel.message = L("Choose the app to remove along with its leftovers.")
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    var userLeftovers: [Leftover] { leftovers.filter { !$0.category.isSystemWide } }
    var systemLeftovers: [Leftover] { leftovers.filter(\.category.isSystemWide) }

    var selectedLeftovers: [Leftover] {
        leftovers.filter { selection.contains($0.url) }
    }

    var selectedCount: Int {
        selectedLeftovers.count + (includeApp ? 1 : 0)
    }

    var selectedBytes: Int64 {
        selectedLeftovers.reduce(0) { $0 + ($1.size ?? 0) } + (includeApp ? (appSize ?? 0) : 0)
    }

    func remove() {
        guard let app, phase == .review, selectedCount > 0 else { return }
        var items = selectedLeftovers
        let shown = leftovers
        let selection = selection
        let includeApp = includeApp
        let appSize = appSize ?? 0
        phase = .removing
        Task {
            var failures: [RemovalFailure] = []
            var targets: [URL] = []
            if includeApp {
                switch await Remover.quit(app) {
                case .quit:
                    // The quit itself may have written files; take those too.
                    let identity = app.identity
                    let others = self.others
                    let rescan = await Task.detached(priority: .userInitiated) {
                        LeftoverScanner.scan(identity: identity, others: others)
                    }.value
                    items += LeftoverScanner.additions(after: rescan, shown: shown, selection: selection)
                    targets.append(app.url)
                case .wasNotRunning:
                    targets.append(app.url)
                case .stillRunning:
                    failures.append(RemovalFailure(
                        url: app.url, reason: L("Still running. Quit it and try again.")))
                }
            }
            let sizes = Dictionary(items.map { ($0.url, $0.size ?? 0) }, uniquingKeysWith: { a, _ in a })
            // A grouped row moves its files; every other row moves itself.
            let files = Remover.targets(for: items, app: targets.first)
            let fileSizes = sizes.merging([app.url: appSize]) { a, _ in a }
            let outcome = await Task.detached(priority: .userInitiated) {
                /* The user's own items first, then — behind one password
                   prompt — /Library's and whatever of ours needed an
                   administrator after all (a root-owned app, say). */
                let own = Remover.trash(files.filter { !Remover.needsAdministrator($0) }, sizes: fileSizes)
                let elevated = files.filter(Remover.needsAdministrator)
                    + own.failures.filter(\.needsAdministrator).map(\.url)
                let admin = Remover.trashAsAdministrator(elevated, sizes: fileSizes)
                let retried = Set(elevated)
                return (trashed: own.trashed + admin.trashed,
                        failures: own.failures.filter { !retried.contains($0.url) } + admin.failures)
            }.value
            let trashed = Set(outcome.trashed)
            var bytes: Int64 = trashed.contains(app.url) ? appSize : 0
            var count = trashed.contains(app.url) ? 1 : 0
            for item in items where item.files.contains(where: trashed.contains) {
                bytes += sizes[item.url] ?? 0
                count += 1
            }
            self.phase = .done(RemovalSummary(
                trashedCount: count, bytes: bytes,
                failures: failures + outcome.failures))
        }
    }

    @Published private(set) var isRetrying = false

    /// Moves again what macOS's container protection refused — after the
    /// user has given Scupper Full Disk Access, it goes this time.
    func retryProtected() {
        guard case .done(let summary) = phase, !isRetrying else { return }
        let retry = summary.failures.filter(\.needsFullDiskAccess)
        guard !retry.isEmpty else { return }
        isRetrying = true
        let sizes = Dictionary(retry.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Remover.trash(retry.map(\.url), sizes: sizes)
            }.value
            let trashed = Set(outcome.trashed)
            let again = Dictionary(outcome.failures.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            self.isRetrying = false
            self.phase = .done(RemovalSummary(
                trashedCount: summary.trashedCount + trashed.count,
                bytes: summary.bytes + trashed.reduce(0) { $0 + (sizes[$1] ?? 0) },
                failures: summary.failures.compactMap { trashed.contains($0.url) ? nil : again[$0.url] ?? $0 }))
        }
    }

    func reset() {
        scanTask?.cancel()
        app = nil
        leftovers = []
        selection = []
        appSize = nil
        phase = .empty
    }
}

// MARK: - Views

func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// "~/Library/Caches/com.example.app" rather than the full home path.
func abbreviatedPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

struct ScupperView: View {
    @ObservedObject var model: ScupperModel

    var body: some View {
        Group {
            switch model.phase {
            case .empty, .failed:
                EmptyStateView(model: model)
            case .scanning:
                ProgressView(L("Looking for leftovers…"))
                    .controlSize(.large)
            case .review, .removing:
                ReviewView(model: model)
            case .done(let summary):
                DoneView(model: model, summary: summary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else {
                return false
            }
            model.open(app)
            return true
        } isTargeted: { targeted in
            model.isTargeted = targeted
        }
        .overlay {
            if model.isTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var model: ScupperModel

    var body: some View {
        ContentUnavailableView {
            Label(L("Drop an App Here"), systemImage: "arrow.down.app")
        } description: {
            if case .failed(let message) = model.phase {
                Text(message)
            } else {
                Text(L("Scupper finds everything the app left behind and moves it to the Trash along with the app."))
            }
        } actions: {
            Button(L("Choose App…")) {
                model.chooseApp()
            }
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: ScupperModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let app = model.app {
                    Section {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable()
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.title3.weight(.semibold))
                                if let version = app.version {
                                    Text(version)
                                        .foregroundStyle(.secondary)
                                }
                                Text(abbreviatedPath(app.url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 4)

                        if let other = model.otherCopies.first {
                            Label {
                                Text(L("Another copy is installed at %@. It shares these files, so none are checked.", abbreviatedPath(other)))
                                    .font(.callout)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }

                        Toggle(isOn: $model.includeApp) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Move the app itself to the Trash"))
                                    if app.isSystem {
                                        Text(L("Part of macOS. It can't be removed."))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let size = model.appSize {
                                    Text(formattedBytes(size))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(app.isSystem)
                    }
                }

                Section(L("Left behind in your Library")) {
                    if model.userLeftovers.isEmpty {
                        Text(L("Nothing. This app kept its files to itself."))
                            .foregroundStyle(.secondary)
                    }
                    if model.userLeftovers.contains(where: \.isProtected) {
                        HStack(alignment: .firstTextBaseline) {
                            Label {
                                Text(L("macOS protects some of these items. Moving them needs Full Disk Access for Scupper."))
                                    .font(.callout)
                            } icon: {
                                Image(systemName: "lock")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Open Privacy Settings…")) {
                                NSWorkspace.shared.open(Remover.fullDiskAccessSettings)
                            }
                        }
                    }
                    ForEach(model.userLeftovers) { item in
                        row(for: item)
                    }
                }

                if !model.systemLeftovers.isEmpty {
                    Section {
                        ForEach(model.systemLeftovers) { item in
                            row(for: item)
                        }
                    } header: {
                        Text(L("Left behind in the system Library"))
                    } footer: {
                        if model.systemLeftovers.contains(where: { $0.files.contains(where: Remover.needsAdministrator) }) {
                            Text(L("Moving these asks for an administrator password."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.phase == .removing)

            Divider()
            HStack {
                Text(summary)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.phase == .removing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(L("Choose Another…")) {
                        model.reset()
                    }
                    Button(L("Move to Trash")) {
                        model.remove()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedCount == 0)
                }
            }
            .padding()
        }
    }

    private var summary: String {
        let count = model.selectedCount
        let items = count == 1 ? L("1 item") : L("%d items", count)
        return "\(items) · \(formattedBytes(model.selectedBytes))"
    }

    private func row(for item: Leftover) -> some View {
        Toggle(isOn: binding(for: item)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(abbreviatedPath(item.url) + (item.isGroup ? " · " + (item.files.count == 1 ? L("1 file") : L("%d files", item.files.count)) : ""))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(caption(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if item.isProtected {
                    // Only what's outside Data could be counted.
                    Label(L("Protected"), systemImage: "lock")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                } else {
                    Text(formattedBytes(item.size ?? 0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func caption(for item: Leftover) -> String {
        var parts = [item.category.title]
        if !item.sharedWith.isEmpty {
            parts.append(L("Also used by %@", ListFormatter.localizedString(byJoining: item.sharedWith)))
        }
        if item.needsReview {
            parts.append(L("From the same developer"))
        }
        return parts.joined(separator: " · ")
    }

    private func binding(for item: Leftover) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(item.url) },
            set: { checked in
                if checked {
                    model.selection.insert(item.url)
                } else {
                    model.selection.remove(item.url)
                }
            })
    }
}

struct DoneView: View {
    @ObservedObject var model: ScupperModel
    var summary: RemovalSummary

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label(
                    summary.trashedCount > 0 ? L("Moved to the Trash") : L("Nothing Was Moved"),
                    systemImage: summary.trashedCount > 0 ? "checkmark.circle" : "exclamationmark.circle")
            } description: {
                if summary.trashedCount > 0 {
                    let items = summary.trashedCount == 1
                        ? L("1 item") : L("%d items", summary.trashedCount)
                    Text(L("%@, %@. Empty the Trash when you're ready.", items, formattedBytes(summary.bytes)))
                }
            } actions: {
                Button(L("Done")) {
                    model.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
            if !summary.failures.isEmpty {
                Form {
                    if summary.failures.contains(where: \.needsFullDiskAccess) {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("macOS protects some of these items. To move them, turn on Full Disk Access for Scupper, then try again."))
                                Text(L("If Scupper is already turned on there, quit and reopen it first."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(L("Open Privacy Settings…")) {
                                    NSWorkspace.shared.open(Remover.fullDiskAccessSettings)
                                }
                                Spacer()
                                if model.isRetrying {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Button(L("Try Again")) {
                                    model.retryProtected()
                                }
                                .disabled(model.isRetrying)
                            }
                        }
                    }
                    Section(L("Couldn't be moved")) {
                        ForEach(summary.failures) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(abbreviatedPath(failure.url))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(failure.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxHeight: summary.failures.contains(where: \.needsFullDiskAccess) ? 320 : 200)
            }
        }
    }
}
