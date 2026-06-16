import File13Core
import SwiftUI
import AppKit

/// AppKit-backed sender table. SwiftUI's `Table` doesn't expose a way to make
/// columns auto-fill leftover horizontal space after the user manually drags
/// column dividers — `NSTableView` does, via `columnAutoresizingStyle`. The
/// trailing column ("Most recent") absorbs any space the other columns leave
/// behind, so the table is always flush with the detail pane edge regardless
/// of how the user resizes columns or panels.
///
/// Rows are passed in as `[Row]`, a flattened mix of `.header` (group-row
/// banner) and `.sender` (data row) entries. The Newsletters view feeds
/// section headers in via this enum so the most-actionable senders
/// (one-click unsubscribe) cluster visually at the top of the list; flat
/// mode (any view other than newsletters-only) passes only `.sender` rows
/// and the result reads identically to the pre-grouping table.
struct SenderTable: NSViewRepresentable {
    @Bindable var store: InboxStore
    var rows: [Row]
    var onAnalyzeSender: (Sender) -> Void
    /// When non-nil, the table scrolls to bring the matching group header
    /// into view and then resets the binding back to nil. Driven by the
    /// jump-to-section bar above the table in Newsletters mode.
    @Binding var scrollToGroup: UnsubscribeGroup?
    @Environment(\.accentPalette) private var accentPalette

    /// One entry in the flat table data model. The Coordinator interleaves
    /// headers with their senders so NSTableView sees a single linear list.
    enum Row: Hashable {
        case header(SenderGroupSection)
        case sender(Sender)

        var sender: Sender? {
            if case .sender(let s) = self { return s }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        // Uniform style + per-column resizingMask lets us pick a single column
        // (Email) to absorb auto-resize. Columns without `.autoresizingMask`
        // stay at their user-set widths when the table grows or shrinks.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        // Inline group headers, not sticky. Sticky group headers feel right
        // in a source list (one selection at a time, fixed sections) but
        // distract here, where the user scrolls big lists and we don't want
        // a banner permanently obscuring the top rows.
        table.floatsGroupRows = false

        // Columns. Order matters — the LAST one is what auto-fills leftover
        // width. We put "Most recent" last because dates are right-aligned, so
        // any growth shows as whitespace to the left of the date and the date
        // stays anchored at the visible right edge.
        for descriptor in Self.columnDescriptors {
            let column = NSTableColumn(identifier: .init(descriptor.id))
            column.title = descriptor.title
            column.width = descriptor.idealWidth
            column.minWidth = descriptor.minWidth
            column.maxWidth = 10_000
            column.headerCell.alignment = descriptor.alignment
            // Email is the only column that auto-grows with the table; the
            // others stay at user-set widths. All columns remain user-
            // resizable via the divider drag handles.
            column.resizingMask = descriptor.id == "address"
                ? [.userResizingMask, .autoresizingMask]
                : .userResizingMask
            if let key = descriptor.sortKey {
                column.sortDescriptorPrototype = NSSortDescriptor(
                    key: key,
                    ascending: descriptor.defaultAscending
                )
            }
            table.addTableColumn(column)
        }

        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        // Trailing context-menu plumbing. The menu's items are built lazily
        // in `menuNeedsUpdate` so they reflect the row that was right-clicked.
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        // Sort: seed from store's existing sort state.
        if let initialDescriptor = Self.sortDescriptor(field: store.sortField, direction: store.sortDirection) {
            table.sortDescriptors = [initialDescriptor]
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        coordinator.tableView = table
        coordinator.rows = rows

        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.rows = rows

        // SwiftUI re-runs `updateNSView` on every observable mutation —
        // including pure selection changes that don't touch the rows list
        // at all. A blanket `reloadData()` here used to recycle every cell
        // (and re-apply font/alignment/color) on every checkbox click, which
        // dominated frame time on large mailboxes. Diff against a cheap
        // fingerprint instead: full reload only when the data actually moved;
        // otherwise refresh just the visible check column to pick up new
        // selection state.
        let fp = Self.rowsFingerprint(rows)
        if coordinator.lastRowsFingerprint != fp {
            coordinator.lastRowsFingerprint = fp
            table.reloadData()
        } else {
            reloadVisibleCheckColumn(in: table, rows: rows)
        }

        // Sync selection from store.
        if let selectedId = store.inspectedSenderId,
           let row = rows.firstIndex(where: { $0.sender?.id == selectedId }) {
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if !table.selectedRowIndexes.isEmpty {
            table.deselectAll(nil)
        }

        // Sync sort indicator from store.
        if let descriptor = Self.sortDescriptor(field: store.sortField, direction: store.sortDirection) {
            if table.sortDescriptors.first?.key != descriptor.key
                || table.sortDescriptors.first?.ascending != descriptor.ascending {
                table.sortDescriptors = [descriptor]
            }
        }

        // Honor any pending scroll-to-section request from the jump bar.
        // We reset the binding back to nil so the next updateNSView pass
        // doesn't keep re-scrolling on every observable mutation. The
        // reset is dispatched off the current run-loop turn because
        // mutating @Binding state during view evaluation isn't safe.
        if let target = scrollToGroup,
           let row = rows.firstIndex(where: { row in
               if case .header(let section) = row, section.group == target { return true }
               return false
           }) {
            table.scrollRowToVisible(row)
            DispatchQueue.main.async { self.scrollToGroup = nil }
        }
    }

    /// Reload just the check column for sender rows currently on screen. Skips
    /// header rows because they span the full row width and don't render the
    /// check column.
    private func reloadVisibleCheckColumn(in table: NSTableView, rows: [Row]) {
        let checkColIndex = table.column(withIdentifier: .init("check"))
        guard checkColIndex >= 0 else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        let upper = min(visible.location + visible.length, table.numberOfRows)
        guard visible.location >= 0, upper > visible.location else { return }
        var senderRows = IndexSet()
        for i in visible.location..<upper where i < rows.count {
            if case .sender = rows[i] { senderRows.insert(i) }
        }
        guard !senderRows.isEmpty else { return }
        table.reloadData(forRowIndexes: senderRows, columnIndexes: IndexSet(integer: checkColIndex))
    }

    /// Cheap structural fingerprint over the rows array. Captures
    /// add/remove/reorder and per-row counters that drive cell text. For
    /// headers we hash the group identity + count; for senders we hash the
    /// same fields the cells render (`id`, `messageCount`, `unreadCount`,
    /// `mostRecent`). Hashing 5–10k entries costs single-digit microseconds,
    /// vastly less than the avoided `reloadData()`.
    static func rowsFingerprint(_ rows: [Row]) -> Int {
        var hasher = Hasher()
        hasher.combine(rows.count)
        for row in rows {
            switch row {
            case .header(let section):
                hasher.combine("h")
                hasher.combine(section.group.rawValue)
                hasher.combine(section.count)
            case .sender(let sender):
                hasher.combine("s")
                hasher.combine(sender.id)
                hasher.combine(sender.messageCount)
                hasher.combine(sender.unreadCount)
                hasher.combine(sender.mostRecent)
            }
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
        let sortKey: String?
        let defaultAscending: Bool
    }

    static let columnDescriptors: [ColumnDescriptor] = [
        .init(id: "check",   title: "",            idealWidth: 28,  minWidth: 28,  alignment: .center,  sortKey: nil,           defaultAscending: true),
        .init(id: "name",    title: "Sender",      idealWidth: 180, minWidth: 80,  alignment: .left,    sortKey: "name",        defaultAscending: true),
        .init(id: "address", title: "Email",       idealWidth: 240, minWidth: 80,  alignment: .left,    sortKey: "address",     defaultAscending: true),
        .init(id: "count",   title: "Messages",    idealWidth: 80,  minWidth: 60,  alignment: .right,   sortKey: "messageCount", defaultAscending: false),
        .init(id: "unread",  title: "Unread",      idealWidth: 64,  minWidth: 50,  alignment: .right,   sortKey: "unreadCount", defaultAscending: false),
        .init(id: "date",    title: "Most recent", idealWidth: 110, minWidth: 90,  alignment: .right,   sortKey: "mostRecent",  defaultAscending: false),
    ]

    static func sortDescriptor(field: SortField, direction: SortDirection) -> NSSortDescriptor? {
        let key: String
        switch field {
        case .name:       key = "name"
        case .address:    key = "address"
        case .count:      key = "messageCount"
        case .unread:     key = "unreadCount"
        case .mostRecent: key = "mostRecent"
        }
        return NSSortDescriptor(key: key, ascending: direction == .ascending)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: SenderTable
        var rows: [Row] = []
        weak var tableView: NSTableView?
        /// Hash of the last rows list reloaded into the table — see
        /// `SenderTable.rowsFingerprint`. Used to skip redundant
        /// `reloadData()` calls when the only thing that changed is
        /// selection.
        var lastRowsFingerprint: Int?

        /// Shared formatter for the "date" column. NSTableView recycles
        /// cells but `Date.formatted(date:time:)` instantiates a fresh
        /// `Date.FormatStyle` per call, threading the user locale each
        /// time — on a 5k-row reload that's measurable. One configured
        /// `DateFormatter` reused across cells plus a tiny string cache
        /// keyed by date (most senders share their `mostRecent` value
        /// with neighbors when sorted) collapses the work to one
        /// formatter invocation per unique date per render.
        var dateFormatter: DateFormatter
        var dateStringCache: [Date: String] = [:]

        private static func makeDateFormatter() -> DateFormatter {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }

        /// Observer token for the system locale-changed broadcast. When
        /// the user switches their preferred language / region, the
        /// already-instantiated `DateFormatter` keeps the old locale —
        /// we have to drop the formatter and the per-date cache.
        private var localeObserver: NSObjectProtocol?

        init(parent: SenderTable) {
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
            // Bound the cache so a many-thousand-distinct-dates inbox
            // doesn't accumulate entries indefinitely. 4096 is enough to
            // cover one render of any realistic inbox without bookkeeping
            // overhead from a strict LRU.
            if dateStringCache.count >= 4096 {
                dateStringCache.removeAll(keepingCapacity: true)
            }
            dateStringCache[date] = s
            return s
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key else { return }
            let field: SortField
            switch key {
            case "name":         field = .name
            case "address":      field = .address
            case "messageCount": field = .count
            case "unreadCount":  field = .unread
            case "mostRecent":   field = .mostRecent
            default: return
            }
            parent.store.sortField = field
            parent.store.sortDirection = descriptor.ascending ? .ascending : .descending
        }

        // MARK: NSTableViewDelegate

        /// Marks header rows as group rows. NSTableView styles these with a
        /// distinct background, suppresses selection, and merges all columns
        /// into the single cell returned from `viewFor`.
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            guard row >= 0, row < rows.count else { return false }
            if case .header = rows[row] { return true }
            return false
        }

        /// Header rows can't be the inspected sender; refusing selection on
        /// them also prevents up/down arrow keys from parking on a header.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row >= 0, row < rows.count else { return false }
            if case .header = rows[row] { return false }
            return true
        }

        /// Group-row headers stack a title and caption, so they need more
        /// height than the standard 22-pt sender row.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < rows.count else { return tableView.rowHeight }
            if case .header = rows[row] { return 40 }
            return tableView.rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < rows.count else { return nil }

            // Group rows have to be handled before the column guard.
            // NSTableView calls `viewFor` once per group row with
            // `tableColumn: nil` — that's the documented signal that the
            // returned view should span the full row width. An earlier
            // version of this guard rejected `nil` outright, which left
            // header rows rendering as empty group bands with no title.
            if case .header(let section) = rows[row] {
                return makeHeaderCell(for: section, in: tableView)
            }

            guard let column = tableColumn, case .sender(let sender) = rows[row] else { return nil }
            return makeSenderCell(for: sender, column: column, in: tableView)
        }

        private func makeSenderCell(for sender: Sender, column: NSTableColumn, in tableView: NSTableView) -> NSView? {
            switch column.identifier.rawValue {
            case "check":
                let id = NSUserInterfaceItemIdentifier("checkCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: self) as? CheckboxCell) ?? CheckboxCell()
                cell.identifier = id
                cell.configure(
                    isFullySelected: parent.store.isSenderFullySelected(sender),
                    isPartiallySelected: parent.store.isSenderPartiallySelected(sender)
                ) { [weak self] newValue in
                    self?.parent.store.setSenderSelected(sender, selected: newValue)
                }
                return cell

            case "name":
                return makeTextCell(
                    identifier: "nameCell",
                    text: sender.name.isEmpty ? sender.address : sender.name,
                    alignment: .left,
                    secondary: false,
                    in: tableView
                )

            case "address":
                return makeTextCell(
                    identifier: "addressCell",
                    text: sender.address,
                    alignment: .left,
                    secondary: true,
                    in: tableView
                )

            case "count":
                return makeTextCell(
                    identifier: "countCell",
                    text: sender.messageCount.formatted(),
                    alignment: .right,
                    secondary: false,
                    in: tableView,
                    monospacedDigits: true
                )

            case "unread":
                let unread = sender.unreadCount
                let cell = makeTextCell(
                    identifier: "unreadCell",
                    text: unread == 0 ? "—" : unread.formatted(),
                    alignment: .right,
                    secondary: unread == 0,
                    in: tableView,
                    monospacedDigits: true
                )
                if let label = cell.textField, unread > 0 {
                    label.textColor = NSColor(parent.accentPalette.primary)
                }
                // The default VoiceOver reading is just the number ("3") or
                // an em-dash. Spell it out so the unread state isn't a
                // color-only signal — color-blind / VoiceOver users get
                // the same information sighted users do.
                cell.setAccessibilityLabel(unread == 0 ? "no unread messages" : "\(unread) unread")
                return cell

            case "date":
                return makeTextCell(
                    identifier: "dateCell",
                    text: formattedDate(sender.mostRecent),
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
            if row >= 0 && row < rows.count, case .sender(let sender) = rows[row] {
                if parent.store.inspectedSenderId != sender.id {
                    parent.store.inspectedSenderId = sender.id
                    parent.store.inspectedSubjectClusterId = nil
                }
            } else {
                parent.store.inspectedSenderId = nil
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }
            let clickedRow = table.clickedRow
            guard clickedRow >= 0 && clickedRow < rows.count,
                  case .sender(let sender) = rows[clickedRow] else { return }

            let openItem = NSMenuItem(
                title: "Open in Inspector",
                action: #selector(openInInspector(_:)),
                keyEquivalent: ""
            )
            openItem.target = self
            openItem.representedObject = sender.id
            menu.addItem(openItem)

            let analyzeItem = NSMenuItem(
                title: "Analyze with AI",
                action: #selector(analyze(_:)),
                keyEquivalent: ""
            )
            analyzeItem.target = self
            analyzeItem.representedObject = sender.id
            menu.addItem(analyzeItem)
        }

        private func sender(forId id: String) -> Sender? {
            for row in rows {
                if case .sender(let s) = row, s.id == id { return s }
            }
            return nil
        }

        @objc func openInInspector(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String,
                  let sender = sender(forId: id) else { return }
            parent.store.inspectedSenderId = sender.id
            parent.store.inspectedSubjectClusterId = nil
        }

        @objc func analyze(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String,
                  let sender = sender(forId: id) else { return }
            parent.onAnalyzeSender(sender)
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let table = tableView else { return }
            let row = table.clickedRow
            guard row >= 0 && row < rows.count, case .sender(let s) = rows[row] else { return }
            parent.store.inspectedSenderId = s.id
            parent.store.inspectedSubjectClusterId = nil
        }

        // MARK: - Cell builders

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

        private func makeHeaderCell(for section: SenderGroupSection, in tableView: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("groupHeaderCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? GroupHeaderCell)
                ?? GroupHeaderCell()
            cell.identifier = id
            cell.configure(title: section.group.title, count: section.count, caption: section.group.caption)
            return cell
        }
    }
}

// MARK: - Checkbox cell

final class CheckboxCell: NSTableCellView {
    private let checkbox = NSButton()
    private var onChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.allowsMixedState = true
        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
        addSubview(checkbox)

        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(isFullySelected: Bool, isPartiallySelected: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        if isFullySelected { checkbox.state = .on }
        else if isPartiallySelected { checkbox.state = .mixed }
        else { checkbox.state = .off }
        // VoiceOver: the NSButton in switch style announces as "button" by
        // default with no state hint. Spell out what the checkbox controls
        // and report its tri-state so a non-sighted user can tell whether
        // a sender is fully selected, partially selected (some messages),
        // or unselected without having to inspect every row.
        checkbox.setAccessibilityLabel("Select sender")
        switch checkbox.state {
        case .on:    checkbox.setAccessibilityValue("selected")
        case .mixed: checkbox.setAccessibilityValue("partially selected")
        default:     checkbox.setAccessibilityValue("not selected")
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        // NSButton with allowsMixedState cycles off → on → mixed by default.
        // We collapse to a binary: any non-off click goes to on, on goes to off.
        let newValue = (sender.state != .off)
        if sender.state == .mixed { sender.state = .on }
        onChange?(newValue)
    }
}

// MARK: - Group header cell

/// Banner cell for an `UnsubscribeGroup` section header. Lives in a single
/// row that spans all columns (NSTableView's group-row behavior). Two
/// lines stacked: a bold title with the sender count, and a one-line
/// caption describing what tapping Unsubscribe will do for senders in
/// this bucket. Non-interactive — navigation between sections happens via
/// the jump-to-section bar above the table, not by clicking headers.
private final class GroupHeaderCell: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let captionField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let stack = NSStackView(views: [titleField, captionField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        titleField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleField.textColor = NSColor.secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        captionField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        captionField.textColor = NSColor.tertiaryLabelColor
        captionField.lineBreakMode = .byTruncatingTail

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(title: String, count: Int, caption: String) {
        let plural = count == 1 ? "" : "s"
        titleField.stringValue = "\(title) · \(count) sender\(plural)"
        captionField.stringValue = caption
        // Mark as a section header so VoiceOver knows this row groups the
        // rows beneath it, instead of treating it as another data row.
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Section: \(title), \(count) sender\(plural). \(caption)")
    }
}
