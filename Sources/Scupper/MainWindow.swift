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
            let found = await Task.detached(priority: .userInitiated) {
                LeftoverScanner.scan(identity: identity)
            }.value
            let size = await Task.detached(priority: .userInitiated) {
                LeftoverScanner.size(of: inspected.url)
            }.value
            guard let self, !Task.isCancelled, self.app == inspected else { return }
            self.leftovers = found
            // Shared with another copy: nothing checked until the user says so.
            self.selection = self.otherCopies.isEmpty ? Set(found.map(\.url)) : []
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
                switch await Remover.quit(bundleID: app.bundleID) {
                case .quit:
                    // The quit itself may have written files; take those too.
                    let identity = app.identity
                    let rescan = await Task.detached(priority: .userInitiated) {
                        LeftoverScanner.scan(identity: identity)
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
            targets = items.map(\.url) + targets
            // A grouped row moves its files; every other row moves itself.
            let files = items.flatMap(\.files) + targets
            let outcome = await Task.detached(priority: .userInitiated) {
                Remover.trash(files)
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
                    if model.leftovers.isEmpty {
                        Text(L("Nothing. This app kept its files to itself."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.leftovers) { item in
                        Toggle(isOn: binding(for: item)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(abbreviatedPath(item.url) + (item.isGroup ? " · " + L("%d files", item.files.count) : ""))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(item.category.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formattedBytes(item.size ?? 0))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
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
                .frame(maxHeight: 200)
            }
        }
    }
}
