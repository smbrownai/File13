import File13Core
import SwiftUI
import AppKit

/// AppKit-backed subject-cluster table. Mirrors `SenderTable` so the Subjects
/// view gets the same "user-resizable columns + Subject column absorbs
/// leftover width" behavior that SwiftUI's `LazyVStack` and `Table` can't
/// deliver. The original SwiftUI implementation kept hitting the
/// LazyVStack-center trap on narrow windows; dropping
/// to AppKit removes the whole class of problems.
struct SubjectTable: NSViewRepresentable {
    @Bindable var store: InboxStore
    var clusters: [SubjectCluster]
    @Environment(\.accentPalette) private var accentPalette

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        // Same auto-resize policy as `SenderTable`: only the Subject column
        // (the flex one) carries `.autoresizingMask`, so it absorbs leftover
        // width when the window grows / shrinks / the inspector slides in.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()

        for descriptor in Self.columnDescriptors {
            let column = NSTableColumn(identifier: .init(descriptor.id))
            column.title = descriptor.title
            column.width = descriptor.idealWidth
            column.minWidth = descriptor.minWidth
            column.maxWidth = 10_000
            column.headerCell.alignment = descriptor.alignment
            column.resizingMask = descriptor.id == "subject"
                ? [.userResizingMask, .autoresizingMask]
                : .userResizingMask
            table.addTableColumn(column)
        }

        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        coordinator.tableView = table
        coordinator.clusters = clusters

        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.clusters = clusters

        // Same diff strategy as `SenderTable.updateNSView`: skip
        // `reloadData()` when the clusters list is structurally unchanged,
        // and only refresh the visible check column to pick up selection
        // changes. See that file's comment for the full rationale.
        let fp = Self.clustersFingerprint(clusters)
        if coordinator.lastClustersFingerprint != fp {
            coordinator.lastClustersFingerprint = fp
            table.reloadData()
        } else {
            reloadVisibleCheckColumn(in: table)
        }

        // Sync selection from store. Cluster ids are normalized subjects.
        if let selectedId = store.inspectedSubjectClusterId,
           let row = clusters.firstIndex(where: { $0.id == selectedId }) {
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if !table.selectedRowIndexes.isEmpty {
            table.deselectAll(nil)
        }
    }

    private func reloadVisibleCheckColumn(in table: NSTableView) {
        let checkColIndex = table.column(withIdentifier: .init("check"))
        guard checkColIndex >= 0 else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        let upper = min(visible.location + visible.length, table.numberOfRows)
        guard visible.location >= 0, upper > visible.location else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<upper),
            columnIndexes: IndexSet(integer: checkColIndex)
        )
    }

    static func clustersFingerprint(_ clusters: [SubjectCluster]) -> Int {
        var hasher = Hasher()
        hasher.combine(clusters.count)
        for cluster in clusters {
            hasher.combine(cluster.id)
            hasher.combine(cluster.messageCount)
            hasher.combine(cluster.unreadCount)
            hasher.combine(cluster.uniqueSenderCount)
            hasher.combine(cluster.mostRecent)
        }
        return hasher.finalize()
    }

    // MARK: - Column metadata

    struct ColumnDescriptor {
        let id: String
        let title: String
        let idealWidth: CGFloat
        let minWidth: CGFloat
        let alignment: NSTextAlignment
    }

    static let columnDescriptors: [ColumnDescriptor] = [
        .init(id: "check",   title: "",            idealWidth: 28,  minWidth: 28,  alignment: .center),
        .init(id: "subject", title: "Subject",     idealWidth: 240, minWidth: 120, alignment: .left),
        .init(id: "senders", title: "Senders",     idealWidth: 80,  minWidth: 60,  alignment: .right),
        .init(id: "count",   title: "Messages",    idealWidth: 80,  minWidth: 60,  alignment: .right),
        .init(id: "unread",  title: "Unread",      idealWidth: 64,  minWidth: 50,  alignment: .right),
        .init(id: "date",    title: "Most recent", idealWidth: 110, minWidth: 90,  alignment: .right),
    ]

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: SubjectTable
        var clusters: [SubjectCluster] = []
        weak var tableView: NSTableView?
        /// Hash of the last clusters list reloaded into the table. See
        /// `SubjectTable.clustersFingerprint`.
        var lastClustersFingerprint: Int?

        /// Shared date-column formatter + per-date cache. Same reasoning
        /// as `SenderTable.Coordinator.formattedDate` — see that file
        /// for the full rationale.
        var dateFormatter: DateFormatter
        var dateStringCache: [Date: String] = [:]

        private static func makeDateFormatter() -> DateFormatter {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }

        private var localeObserver: NSObjectProtocol?

        init(parent: SubjectTable) {
            self.parent = parent
            self.dateFormatter = Coordinator.makeDateFormatter()
            super.init()
            localeObserver = NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.dateFormatter = Coordinator.makeDateFormatter()
                self.dateStringCache.removeAll(keepingCapacity: true)
                self.tableView?.reloadData()
            }
        }

        deinit {
            if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
        }

        func formattedDate(_ date: Date) -> String {
            if let cached = dateStringCache[date] { return cached }
            let s = dateFormatter.string(from: date)
            if dateStringCache.count >= 4096 {
                dateStringCache.removeAll(keepingCapacity: true)
            }
            dateStringCache[date] = s
            return s
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            clusters.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, row < clusters.count else { return nil }
            let cluster = clusters[row]

            switch column.identifier.rawValue {
            case "check":
                let id = NSUserInterfaceItemIdentifier("clusterCheckCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: self) as? CheckboxCell) ?? CheckboxCell()
                cell.identifier = id
                cell.configure(
                    isFullySelected: parent.store.isClusterFullySelected(cluster),
                    isPartiallySelected: parent.store.isClusterPartiallySelected(cluster)
                ) { [weak self] newValue in
                    self?.parent.store.setClusterSelected(cluster, selected: newValue)
                }
                return cell

            case "subject":
                return makeTextCell(
                    identifier: "clusterSubjectCell",
                    text: cluster.representative.isEmpty ? "(no subject)" : cluster.representative,
                    alignment: .left,
                    secondary: false,
                    in: tableView
                )

            case "senders":
                return makeTextCell(
                    identifier: "clusterSendersCell",
                    text: cluster.uniqueSenderCount.formatted(),
                    alignment: .right,
                    secondary: true,
                    in: tableView,
                    monospacedDigits: true
                )

            case "count":
                return makeTextCell(
                    identifier: "clusterCountCell",
                    text: cluster.messageCount.formatted(),
                    alignment: .right,
                    secondary: false,
                    in: tableView,
                    monospacedDigits: true
                )

            case "unread":
                let unread = cluster.unreadCount
                let cell = makeTextCell(
                    identifier: "clusterUnreadCell",
                    text: unread == 0 ? "—" : unread.formatted(),
                    alignment: .right,
                    secondary: unread == 0,
                    in: tableView,
                    monospacedDigits: true
                )
                if let label = cell.textField, unread > 0 {
                    label.textColor = NSColor(parent.accentPalette.primary)
                }
                return cell

            case "date":
                return makeTextCell(
                    identifier: "clusterDateCell",
                    text: formattedDate(cluster.mostRecent),
                    alignment: .right,
                    secondary: true,
                    in: tableView
                )

            default:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            if row >= 0 && row < clusters.count {
                let cluster = clusters[row]
                if parent.store.inspectedSubjectClusterId != cluster.id {
                    parent.store.inspectedSubjectClusterId = cluster.id
                    parent.store.inspectedSenderId = nil
                }
            } else {
                parent.store.inspectedSubjectClusterId = nil
            }
        }

        // MARK: Context menu — mirrors the SwiftUI `ClusterContextMenu`

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }
            let clickedRow = table.clickedRow
            guard clickedRow >= 0 && clickedRow < clusters.count else { return }
            let cluster = clusters[clickedRow]

            let fullySelected = parent.store.isClusterFullySelected(cluster)
            let count = cluster.messageCount

            let selectItem = NSMenuItem(
                title: fullySelected ? "Deselect all in this group" : "Select all in this group",
                action: #selector(toggleSelect(_:)),
                keyEquivalent: ""
            )
            selectItem.target = self
            selectItem.representedObject = cluster.id
            selectItem.isEnabled = count > 0
            menu.addItem(selectItem)

            menu.addItem(.separator())

            let deleteItem = NSMenuItem(
                title: "Delete this group (\(count))…",
                action: #selector(deleteGroup(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = cluster.id
            deleteItem.isEnabled = count > 0
            menu.addItem(deleteItem)

            let archiveItem = NSMenuItem(
                title: "Archive this group (\(count))",
                action: #selector(archiveGroup(_:)),
                keyEquivalent: ""
            )
            archiveItem.target = self
            archiveItem.representedObject = cluster.id
            archiveItem.isEnabled = count > 0
            menu.addItem(archiveItem)
        }

        @objc func toggleSelect(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String,
                  let cluster = clusters.first(where: { $0.id == id }) else { return }
            let fullySelected = parent.store.isClusterFullySelected(cluster)
            parent.store.setClusterSelected(cluster, selected: !fullySelected)
        }

        @objc func deleteGroup(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String,
                  let cluster = clusters.first(where: { $0.id == id }) else { return }
            parent.store.replaceSelection(withCluster: cluster)
            parent.store.startDelete()
        }

        @objc func archiveGroup(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String,
                  let cluster = clusters.first(where: { $0.id == id }) else { return }
            parent.store.replaceSelection(withCluster: cluster)
            parent.store.archiveSelection()
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let table = tableView else { return }
            let row = table.clickedRow
            guard row >= 0 && row < clusters.count else { return }
            let cluster = clusters[row]
            parent.store.inspectedSubjectClusterId = cluster.id
            parent.store.inspectedSenderId = nil
        }

        // MARK: - Cell builders (identical to SenderTable's; kept here to
        // avoid coupling the two tables' cell layouts).

        private func makeTextCell(
            identifier: String,
            text: String,
            alignment: NSTextAlignment,
            secondary: Bool,
            in tableView: NSTableView,
            monospacedDigits: Bool = false
        ) -> NSTableCellView {
            let id = NSUserInterfaceItemIdentifier(identifier)
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
                ?? makeReusableTextCell(identifier: id)
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor
            cell.textField?.lineBreakMode = .byTruncatingTail
            if monospacedDigits {
                let baseSize = NSFont.systemFontSize
                cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .regular)
            } else {
                cell.textField?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            }
            return cell
        }

        private func makeReusableTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            textField.cell?.usesSingleLineMode = true
            textField.cell?.wraps = false
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            return cell
        }
    }
}
