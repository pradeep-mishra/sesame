import AppKit
import Carbon.HIToolbox
import SesameEngine

@MainActor
final class ResultList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Content {
        case empty
        case searching
        case rows([SearchHit])
        case noMatches
    }

    private static let cellID = NSUserInterfaceItemIdentifier("ResultCell")

    let view = NSView()
    private let scroll = NSScrollView()
    private let table = ResultTable()
    private var stateView: StateView?
    private(set) var hits: [SearchHit] = []

    /// The selected row's file, for the pane.
    var onSelect: (@MainActor (SearchHit?) -> Void)?

    /// The list as a stop of the Tab key loop.
    var keyView: NSView { table }

    /// A click selects a row and then hands the focus back, so typing stays in the search box.
    var returnFocus: (@MainActor () -> Void)? {
        get { table.returnFocus }
        set { table.returnFocus = newValue }
    }

    var selectedHit: SearchHit? {
        let row = table.selectedRow
        return hits.indices.contains(row) ? hits[row] : nil
    }

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Space.s8
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        // A letter must never be eaten by the table's type-to-select, even when the person tabbed to the list.
        table.allowsTypeSelect = false
        // Tab reaches the list (and shows where the focus is); a click selects the row but does not keep the focus.
        table.setAccessibilityLabel(AccessibilityLabels.resultList)
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func show(_ content: Content) {
        switch content {
        case .empty:
            replace(with: [])
            say(nil)
        case .searching:
            replace(with: [])
            say(StateView(symbol: "magnifyingglass", title: "Searching", body: ""))
        case .noMatches:
            replace(with: [])
            say(StateView(
                symbol: "magnifyingglass",
                title: "No matches",
                body: "Describe what is in the file, or type part of its exact name or text."
            ))
        case let .rows(found):
            say(nil)
            replace(with: found)
        }
    }

    /// Up and Down: one row, and no wrap at either end.
    func move(by step: Int) {
        guard !hits.isEmpty else { return }
        let row = min(max(table.selectedRow + step, 0), hits.count - 1)
        select(row: row)
    }

    /// A file that has gone: its row leaves the list and the next row is selected (a path not listed changes nothing).
    func dropGone(_ path: String) {
        var rows = RowSelection(paths: hits.map(\.path))
        if let selectedHit { rows.select(path: selectedHit.path) }
        rows.dropGone(path)
        hits.removeAll { $0.path == path }
        table.reloadData()
        if let next = rows.selectedPath, let row = hits.firstIndex(where: { $0.path == next }) {
            select(row: row)
        } else {
            table.deselectAll(nil)
            onSelect?(nil)
        }
    }

    private func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// The list replaced in place; with rows, the first is selected.
    private func replace(with found: [SearchHit]) {
        hits = found
        table.reloadData()
        if found.isEmpty {
            // reloadData cleared the selection without a notification, so the owner is told here.
            table.deselectAll(nil)
            onSelect?(nil)
        } else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func say(_ state: StateView?) {
        stateView?.removeFromSuperview()
        stateView = state
        guard let state else { return }
        state.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(state)
        NSLayoutConstraint.activate([
            state.topAnchor.constraint(equalTo: view.topAnchor),
            state.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            state.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int {
        hits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ResultCell ?? ResultCell()
        cell.identifier = Self.cellID
        cell.configure(path: hits[row].path)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ResultRowView()
        if hits.indices.contains(row) { rowView.setAccessibilityLabel(AccessibilityLabels.resultRow(path: hits[row].path)) }
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedHit)
    }
}

/// The list's table: it takes the focus only from a click or from Tab, never from a reload or a selection change, so
/// typed keys stay in the search box. A click selects a row, then the focus goes back to where `returnFocus` puts it.
@MainActor
private final class ResultTable: NSTableView {
    var returnFocus: (@MainActor () -> Void)?
    private var isClicked = false

    override var acceptsFirstResponder: Bool {
        if isClicked { return true }
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return Int(event.keyCode) == kVK_Tab
    }

    override func mouseDown(with event: NSEvent) {
        isClicked = true
        super.mouseDown(with: event)
        isClicked = false
        returnFocus?()
    }
}

/// The rows as a value: which file is selected, and what a gone file does to the selection. The list wraps it.
struct RowSelection: Equatable {
    private(set) var paths: [String]
    private var index: Int?

    /// The first row starts selected; an empty list selects nothing.
    init(paths: [String]) {
        self.paths = paths
        index = paths.isEmpty ? nil : 0
    }

    var selectedPath: String? {
        index.map { paths[$0] }
    }

    /// A path that is not listed changes nothing.
    mutating func select(path: String) {
        if let row = paths.firstIndex(of: path) { index = row }
    }

    /// The selected row goes: the row below it is selected, or the new last row when it was the last. Another row
    /// goes: the selection stays on the same file.
    mutating func dropGone(_ path: String) {
        guard let removed = paths.firstIndex(of: path) else { return }
        paths.remove(at: removed)
        guard let selected = index else { return }
        if paths.isEmpty {
            index = nil
        } else if removed < selected {
            index = selected - 1
        } else if removed == selected {
            index = min(selected, paths.count - 1)
        }
    }
}

/// The selected row: the accent colour with rounded corners, drawn as active even while the search box has the focus.
private final class ResultRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Design.accent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: Radius.row, yRadius: Radius.row).fill()
    }
}

private final class ResultCell: NSTableCellView {
    private let symbol = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.contentTintColor = Design.secondaryLabel
        symbol.setAccessibilityElement(false)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbol)
        name.font = Typeface.rowName
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)
        folder.font = Typeface.secondary
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [name, folder] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.s5),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: Space.s5),
            symbol.heightAnchor.constraint(equalToConstant: Space.s5),
            name.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: Space.s3),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -(Space.s5 + Space.s3)),
            folder.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: Space.s3),
            folder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.s5),
        ])
        textField = name
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(path: String) {
        let url = URL(fileURLWithPath: path)
        name.stringValue = url.lastPathComponent
        folder.stringValue = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        folder.setAccessibilityLabel(path)
        symbol.image = Design.symbol(Self.symbolName(forExtension: url.pathExtension.lowercased()), pointSize: Space.s5)
    }

    private static func symbolName(forExtension ext: String) -> String {
        switch Rules.kind(forExtension: ext) {
        case "photo": "photo"
        case "pdf": "doc.richtext"
        case "doc": "doc.text"
        case "audio": "waveform"
        case "video": "film"
        case "code": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        name.textColor = selected ? Design.selectedText : Design.label
        folder.textColor = selected ? Design.selectedSecondaryText : Design.secondaryLabel
    }
}
