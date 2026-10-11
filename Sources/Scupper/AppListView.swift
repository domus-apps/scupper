import AppKit
import SwiftUI

/* The start screen: the installed apps, with dropping still open anywhere
   on the window. The search is in the toolbar (MainWindowController), which
   hands the arrow keys and Return to this list; a double click or Return
   here opens the review too. */
struct AppListView: View {
    @ObservedObject var model: ScupperModel

    var body: some View {
        let apps = model.visibleApps
        VStack(spacing: 0) {
            AppTable(
                apps: apps, sizes: model.installedSizes, selection: $model.listSelection, sort: $model.sort
            ) { url in
                model.open(url)
            }
            // Up under the toolbar, where the system blurs what scrolls by.
            .ignoresSafeArea(edges: .top)
            .overlay {
                if apps.isEmpty && model.hasListedApps {
                    ContentUnavailableView.search(text: model.query)
                }
            }

            Divider()
            HStack {
                if case .failed(let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Or drop an app here."))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(L("Other App…")) {
                    model.chooseApp()
                }
                Button(L("Find Leftovers")) {
                    model.openListSelection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.listSelection == nil)
            }
            // Lantern's push buttons: large, the default one in the accent color.
            .controlSize(.large)
            .padding()
        }
    }
}

/* An AppKit table rather than a SwiftUI List: macOS 26 blurs what scrolls
   under the toolbar only for AppKit scroll views. A List keeps the system's
   scroll pocket switched off and draws no edge effect of its own under an
   AppKit toolbar. Its column headers sort, as in Finder's list view: a
   click picks the column, another turns the order around. */
private struct AppTable: NSViewRepresentable {
    var apps: [ListedApp]
    var sizes: [URL: Int64]
    @Binding var selection: URL?
    @Binding var sort: AppSort
    var onOpen: (URL) -> Void

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("size")

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = AppTableView()
        // Edge to edge like Finder's list view: the sorted column's header
        // line falls on the window edge instead of floating in an inset margin.
        table.style = .fullWidth
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = L("Name")
        name.minWidth = 120
        name.resizingMask = .autoresizingMask
        name.sortDescriptorPrototype = NSSortDescriptor(key: AppSort.Key.name.rawValue, ascending: true)
        table.addTableColumn(name)

        let size = NSTableColumn(identifier: Self.sizeColumn)
        size.title = L("Size")
        size.width = 96
        size.resizingMask = []
        size.headerCell.alignment = .right
        // Largest first, the reason to sort by size.
        size.sortDescriptorPrototype = NSSortDescriptor(key: AppSort.Key.size.rawValue, ascending: false)
        table.addTableColumn(size)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked(_:))
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.table = table
        // The arrow keys move through the list from the start.
        DispatchQueue.main.async { table.window?.makeFirstResponder(table) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        coordinator.sort = $sort
        coordinator.onOpen = onOpen
        let table = coordinator.table!
        coordinator.isSyncing = true
        defer { coordinator.isSyncing = false }

        let descriptor = NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)
        if table.sortDescriptors != [descriptor] {
            table.sortDescriptors = [descriptor]
        }
        if coordinator.apps != apps {
            // A new search, a new order, or a size sort moving a measured app up.
            coordinator.apps = apps
            coordinator.sizes = sizes
            table.reloadData()
        } else if coordinator.sizes != sizes {
            // Only the sizes that just arrived.
            let changed = IndexSet(apps.indices.filter { coordinator.sizes[apps[$0].url] != sizes[apps[$0].url] })
            coordinator.sizes = sizes
            table.reloadData(forRowIndexes: changed, columnIndexes: [1])
        }

        let row = selection.flatMap { url in apps.firstIndex { $0.url == url } }
        if table.selectedRow != row ?? -1 {
            if let row {
                table.selectRowIndexes([row], byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }
        /* Scrolled to when it changes, or when a new order moves it; not as
           sizes arriving shuffle a size sort under someone reading it. */
        if let row, selection != coordinator.revealed.selection || sort != coordinator.revealed.sort {
            coordinator.reveal(row, in: scrollView)
        }
        coordinator.revealed = (selection, sort)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var apps: [ListedApp] = []
        var sizes: [URL: Int64] = [:]
        var selection: Binding<URL?>?
        var sort: Binding<AppSort>?
        var onOpen: ((URL) -> Void)?
        weak var table: NSTableView?
        var isSyncing = false
        var revealed: (selection: URL?, sort: AppSort?) = (nil, nil)

        func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let app = apps[row]
            if tableColumn?.identifier == AppTable.sizeColumn {
                let cell = tableView.makeView(withIdentifier: AppTable.sizeColumn, owner: nil) as? SizeCellView
                    ?? SizeCellView()
                cell.identifier = AppTable.sizeColumn
                cell.show(sizes[app.url])
                return cell
            }
            let cell = tableView.makeView(withIdentifier: AppTable.nameColumn, owner: nil) as? NameCellView
                ?? NameCellView()
            cell.identifier = AppTable.nameColumn
            cell.show(app)
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncing, let descriptor = tableView.sortDescriptors.first,
                let key = descriptor.key.flatMap(AppSort.Key.init(rawValue:))
            else { return }
            sort?.wrappedValue = AppSort(key: key, ascending: descriptor.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table else { return }
            let row = table.selectedRow
            selection?.wrappedValue = apps.indices.contains(row) ? apps[row].url : nil
        }

        @objc func openClicked(_ sender: NSTableView) {
            guard apps.indices.contains(sender.clickedRow) else { return }
            onOpen?(apps[sender.clickedRow].url)
        }

        func openSelected() {
            guard let table, apps.indices.contains(table.selectedRow) else { return }
            onOpen?(apps[table.selectedRow].url)
        }

        /* scrollRowToVisible counts the area under the toolbar and the
           column headers as visible, so a row moved to with the arrow keys
           could stop behind them. */
        func reveal(_ row: Int, in scrollView: NSScrollView) {
            guard let table else { return }
            let rect = table.rect(ofRow: row)
            let clip = scrollView.contentView
            let covered = scrollView.contentInsets.top + (table.headerView?.frame.height ?? 0)
            let top = clip.bounds.minY + covered
            var origin = clip.bounds.origin
            if rect.minY < top {
                origin.y = rect.minY - covered
            } else if rect.maxY > clip.bounds.maxY {
                origin.y = rect.maxY - clip.bounds.height
            } else {
                return
            }
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

/// Return opens the selected app, like a double click.
private final class AppTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class NameCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ app: ListedApp) {
        icon.image = NSWorkspace.shared.icon(forFile: app.url.path)
        name.stringValue = app.name
    }
}

private final class SizeCellView: NSTableCellView {
    private let size = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        size.textColor = .secondaryLabelColor
        size.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        size.alignment = .right
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [size, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            size.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            size.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            size.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ bytes: Int64?) {
        if let bytes {
            size.stringValue = formattedBytes(bytes)
            spinner.stopAnimation(nil)
        } else {
            // Still being measured.
            size.stringValue = ""
            spinner.startAnimation(nil)
        }
    }
}
