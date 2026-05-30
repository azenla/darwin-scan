import SwiftUI
import AppKit
import DarwinScanCore

/// `NSTableView`-backed item list. The SwiftUI `List(...)` initialiser
/// allocates an AttributeGraph node per row identifier — at 470k items
/// the graph runs out of data space and the app crashes with
/// "AttributeGraph precondition failure: exhausted data space."
/// `NSTableView` realises only the rows currently on-screen (typically
/// ~30) regardless of how large `numberOfRows(in:)` returns, so this view
/// scales to millions of items without bloating the SwiftUI graph.
///
/// Selection is two-way bound to a `UUID?`. Header data is fetched from
/// `ScanStore.itemHeader(id:)` per visible row, which itself is backed by
/// the small LRU cache in `ScanStore` — so a scroll over the same window
/// repeatedly is effectively free.
struct ItemTableView: NSViewRepresentable {
    let ids: [UUID]
    @Binding var selection: UUID?
    let store: ScanStore

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 40
        table.style = .inset
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 100
        table.addTableColumn(column)

        let coord = context.coordinator
        coord.tableView = table
        coord.ids = ids
        table.dataSource = coord
        table.delegate = coord

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let table = nsView.documentView as? NSTableView else { return }
        let coord = context.coordinator
        let oldIDs = coord.ids
        // Replace the binding's parent reference + the data array on the
        // coordinator. We compare counts first (cheap) and only fall back
        // to a full equality check when the count matches but content may
        // have rotated.
        coord.parent = self
        coord.store = store
        if oldIDs.count != ids.count || oldIDs != ids {
            coord.ids = ids
            table.reloadData()
        }
        let desiredRow: Int? = selection.flatMap { sel in
            coord.ids.firstIndex(of: sel)
        }
        if let row = desiredRow {
            if table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        } else if selection == nil, table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate var parent: ItemTableView
        fileprivate var store: ScanStore
        fileprivate var ids: [UUID] = []
        fileprivate weak var tableView: NSTableView?

        init(parent: ItemTableView) {
            self.parent = parent
            self.store = parent.store
            self.ids = parent.ids
        }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < ids.count else { return nil }
            let id = ids[row]
            let header = store.itemHeader(id: id)
            let identifier = NSUserInterfaceItemIdentifier("ItemRowCell")
            if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ItemHostingCell {
                cell.update(with: header)
                return cell
            }
            let cell = ItemHostingCell(identifier: identifier)
            cell.update(with: header)
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            40
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = tableView else { return }
            let row = table.selectedRow
            let newSelection: UUID? = (row >= 0 && row < ids.count) ? ids[row] : nil
            if parent.selection != newSelection {
                parent.selection = newSelection
            }
        }
    }
}

/// `NSTableCellView` subclass that hosts the SwiftUI `ItemRow` for a
/// single row. Cells are recycled by NSTableView — `update(with:)` swaps
/// the hosted view's `rootView` instead of allocating a new hosting view
/// per visible row.
@MainActor
private final class ItemHostingCell: NSTableCellView {
    private let hosting: NSHostingView<AnyView>

    init(identifier: NSUserInterfaceItemIdentifier) {
        self.hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        self.identifier = identifier
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func update(with header: ItemHeader?) {
        if let header {
            hosting.rootView = AnyView(ItemRow(header: header))
        } else {
            hosting.rootView = AnyView(
                HStack {
                    ProgressView().controlSize(.small)
                    Text("…").foregroundStyle(.tertiary).font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 4)
            )
        }
    }
}
