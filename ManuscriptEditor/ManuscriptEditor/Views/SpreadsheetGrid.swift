// SpreadsheetGrid.swift
//
// The table grid, rebuilt on AppKit.
//
// WHY NOT SWIFTUI
// ─────────────────────────────────────────────────────────────────────────────
// The SwiftUI grid had one bug that survived five rewrites: after any
// STRUCTURAL change inside a horizontally scrollable table — resizing a
// column, deleting a column, deleting a row — clicks landed a constant two
// rows below the cursor, healing only on a scroll or when the view was
// recreated.  Every variant of the pointer math drifted the same way
// (container-local, named space, global minus a captured origin, finally
// per-cell reporting), because the thing going stale was SwiftUI's own
// mapping between where the content DRAWS and where it HIT-TESTS once the
// scroll view's content size changed mid-interaction.
//
// AppKit computes `convert(_:from: nil)` from the live view hierarchy at
// event time, so it cannot be stale by construction.  That, plus real
// floating header support and draw-only-what's-visible rendering, is why
// the grid lives here now.
//
// LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
//   SpreadsheetContainerView
//     ├── SpreadsheetHeaderView   (model row 0, pinned above the scroll view)
//     └── NSScrollView → SpreadsheetBodyView  (model rows 1…)
// The header is a SIBLING of the scroll view, not a floating subview:
// `addFloatingSubview(_:for:)` installs a full-size
// `_NSScrollViewFloatingSubviewsContainerView` over the clip view, and that
// container hid the document view entirely (verified — the body rendered
// correctly on its own and vanished in the composite).  The header mirrors
// the clip view's horizontal offset through its own `bounds.origin.x`, so
// it scrolls with the columns and stays put vertically.  Model row 0 is the
// header everywhere; the body maps y → row + 1.

import SwiftUI
import AppKit

// MARK: - CellRef

struct CellRef: Hashable {
    var row: Int
    var col: Int
}

// MARK: - GridSelection

/// The grid's selection, shared with SwiftUI so the formatting toolbar can
/// act on it.  A rectangle from `anchor` to `extent`.
@MainActor
@Observable
final class GridSelection {
    var anchor: CellRef?
    var extent: CellRef?

    /// Clamped to the live grid — a shrinking query result must never leave
    /// an out-of-bounds range behind (that crashed the SwiftUI version).
    func range(rows: Int, cols: Int) -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        guard let a = anchor, rows > 0, cols > 0 else { return nil }
        let e = extent ?? a
        let r1 = min(max(min(a.row, e.row), 0), rows - 1)
        let r2 = min(max(max(a.row, e.row), 0), rows - 1)
        let c1 = min(max(min(a.col, e.col), 0), cols - 1)
        let c2 = min(max(max(a.col, e.col), 0), cols - 1)
        return (r1...r2, c1...c2)
    }

    func clear() {
        anchor = nil
        extent = nil
    }
}

// MARK: - Geometry

/// Column layout shared by the body and header views.
struct GridMetrics {
    var widths: [CGFloat] = []
    var rowHeight: CGFloat = 26

    /// Leading edge of every column; `offsets[count]` is the total width.
    var offsets: [CGFloat] {
        var out: [CGFloat] = [0]
        for w in widths { out.append(out[out.count - 1] + w) }
        return out
    }

    var totalWidth: CGFloat { offsets.last ?? 0 }

    func columnAt(_ x: CGFloat) -> Int? {
        let xs = offsets
        guard xs.count > 1, x >= 0, x < xs[xs.count - 1] else { return nil }
        for c in 0..<widths.count where x < xs[c + 1] { return c }
        return widths.count - 1
    }

    /// Column boundary within `tolerance` of `x` (1...count — never 0, the
    /// left edge isn't draggable), for the header's resize handles.
    func boundary(near x: CGFloat, tolerance: CGFloat = 4) -> Int? {
        let xs = offsets
        for b in 1..<max(xs.count, 1) where abs(x - xs[b]) <= tolerance { return b }
        return nil
    }

    func rect(row: Int, col: Int) -> CGRect {
        let xs = offsets
        guard col < widths.count else { return .zero }
        return CGRect(x: xs[col], y: CGFloat(row) * rowHeight,
                      width: widths[col], height: rowHeight)
    }
}

// MARK: - Cell drawing

enum GridStyle {
    static let border = NSColor.separatorColor
    static let headerFill = NSColor.controlBackgroundColor
    static let rowFill = NSColor.textBackgroundColor
    static let addStrip: CGFloat = 18

    static func highlight(_ name: String?) -> NSColor {
        switch name {
        case "green":  return NSColor.systemGreen.withAlphaComponent(0.28)
        case "blue":   return NSColor.systemBlue.withAlphaComponent(0.24)
        case "pink":   return NSColor.systemPink.withAlphaComponent(0.24)
        case "orange": return NSColor.systemOrange.withAlphaComponent(0.28)
        default:       return NSColor.systemYellow.withAlphaComponent(0.35)
        }
    }

    static func attributes(_ cell: TableCell, isHeader: Bool) -> [NSAttributedString.Key: Any] {
        var font = NSFont.systemFont(ofSize: 12,
                                     weight: (cell.bold ?? isHeader) ? .semibold : .regular)
        if cell.italic == true {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        switch cell.align {
        case "center": para.alignment = .center
        case "right":  para.alignment = .right
        default:       para.alignment = .left
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        if cell.underline == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    /// Paints one cell's background, border, and text into `rect`.
    static func draw(_ cell: TableCell, in rect: CGRect, isHeader: Bool, selected: Bool) {
        if cell.highlight == true {
            highlight(cell.highlightColor).setFill()
        } else if isHeader {
            headerFill.setFill()
        } else {
            rowFill.setFill()
        }
        rect.fill()
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            rect.fill()
        }
        border.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25))
        path.lineWidth = 0.5
        path.stroke()

        let text = rect.insetBy(dx: 6, dy: 0)
        let attrs = attributes(cell, isHeader: isHeader)
        let size = (cell.text as NSString).size(withAttributes: attrs)
        let y = text.midY - size.height / 2
        (cell.text as NSString).draw(in: CGRect(x: text.minX, y: y,
                                                width: text.width, height: size.height),
                                     withAttributes: attrs)
    }
}

// MARK: - SpreadsheetBodyView

/// Draws every row and owns all pointer/keyboard input.
final class SpreadsheetBodyView: NSView, NSTextFieldDelegate {

    var cells: [[TableCell]] = [] { didSet { needsDisplay = true } }
    var metrics = GridMetrics() { didSet { needsDisplay = true } }
    var selection: GridSelection?
    var structureEditable = true

    /// Callbacks into SwiftUI.
    var onSelectionChanged: (() -> Void)?
    var onCommit: ((Int, Int, String) -> Void)?
    var onAddRow: (() -> Void)?
    var onAddColumn: (() -> Void)?
    var onDeleteRow: ((Int) -> Void)?
    var onDeleteColumn: ((Int) -> Void)?
    var onClearCells: (() -> Void)?
    var onPaste: ((String, CellRef) -> Void)?

    private var editor: NSTextField?
    private var editing: CellRef?
    private var hoveringAddRow = false
    private var hoveringAddColumn = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Model row 0 is the header and lives in the pinned header view, so
    /// the body draws rows 1… at y = (row - 1) * rowHeight.
    private var dataRows: Int { max(cells.count - 1, 0) }

    func rect(modelRow row: Int, col: Int) -> CGRect {
        var r = metrics.rect(row: max(row - 1, 0), col: col)
        if row == 0 { r.origin.y = 0 }
        return r
    }

    var contentSize: CGSize {
        CGSize(width: metrics.totalWidth + (structureEditable ? GridStyle.addStrip : 0),
               height: CGFloat(dataRows) * metrics.rowHeight
                   + (structureEditable ? GridStyle.addStrip : 0))
    }

    // MARK: tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard structureEditable else { return }
        let p = convert(event.locationInWindow, from: nil)
        let inRow = addRowRect.contains(p)
        let inCol = addColumnRect.contains(p)
        if inRow != hoveringAddRow || inCol != hoveringAddColumn {
            hoveringAddRow = inRow
            hoveringAddColumn = inCol
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveringAddRow || hoveringAddColumn else { return }
        hoveringAddRow = false
        hoveringAddColumn = false
        needsDisplay = true
    }

    private var addRowRect: CGRect {
        CGRect(x: 0, y: CGFloat(dataRows) * metrics.rowHeight,
               width: max(metrics.totalWidth, 1), height: GridStyle.addStrip)
    }

    private var addColumnRect: CGRect {
        CGRect(x: metrics.totalWidth, y: 0, width: GridStyle.addStrip,
               height: max(CGFloat(dataRows) * metrics.rowHeight, 1))
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard !cells.isEmpty, !metrics.widths.isEmpty else { return }

        let range = selection?.range(rows: cells.count, cols: metrics.widths.count)
        // Only the rows that intersect the dirty rect are drawn — a 2,000-row
        // result costs the same as a screenful.
        let first = max(Int(dirtyRect.minY / metrics.rowHeight) + 1, 1)
        let last = min(Int(dirtyRect.maxY / metrics.rowHeight) + 1, cells.count - 1)
        guard first <= last else { return }

        for r in first...last {
            for c in cells[r].indices where c < metrics.widths.count {
                let selected = range.map { $0.rows.contains(r) && $0.cols.contains(c) } ?? false
                GridStyle.draw(cells[r][c], in: rect(modelRow: r, col: c),
                               isHeader: false, selected: selected)
            }
        }

        // The selection outline covers only the part below the header.
        if let range, range.rows.upperBound >= 1 {
            let xs = metrics.offsets
            let top = max(range.rows.lowerBound, 1)
            let rect = CGRect(x: xs[range.cols.lowerBound],
                              y: CGFloat(top - 1) * metrics.rowHeight,
                              width: xs[range.cols.upperBound + 1] - xs[range.cols.lowerBound],
                              height: CGFloat(range.rows.upperBound - top + 1) * metrics.rowHeight)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
            path.lineWidth = 1.5
            path.stroke()
        }

        if structureEditable {
            drawAddStrip(addRowRect, hovering: hoveringAddRow)
            drawAddStrip(addColumnRect, hovering: hoveringAddColumn)
        }
    }

    private func drawAddStrip(_ rect: CGRect, hovering: Bool) {
        guard rect.width > 0, rect.height > 0 else { return }
        (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                  : NSColor.separatorColor.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
        let plus = "+" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: hovering ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor,
        ]
        let size = plus.size(withAttributes: attrs)
        plus.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                  withAttributes: attrs)
    }

    // MARK: hit testing — AppKit converts from the live hierarchy at event
    // time, so this cannot go stale the way the SwiftUI mapping did.

    private func cell(at point: CGPoint) -> CellRef? {
        guard let col = metrics.columnAt(point.x) else { return nil }
        let row = Int(point.y / metrics.rowHeight) + 1     // row 0 is the header view's
        guard row >= 1, row < cells.count else { return nil }
        return CellRef(row: row, col: col)
    }

    private func clampedCell(at point: CGPoint) -> CellRef {
        let col = metrics.columnAt(min(max(point.x, 0), max(metrics.totalWidth - 1, 0))) ?? 0
        let row = min(max(Int(point.y / metrics.rowHeight) + 1, 1), max(cells.count - 1, 1))
        return CellRef(row: row, col: col)
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        if structureEditable, addRowRect.contains(p) { commitEditing(); onAddRow?(); return }
        if structureEditable, addColumnRect.contains(p) { commitEditing(); onAddColumn?(); return }

        guard let ref = cell(at: p), let selection else { return }
        if event.clickCount >= 2, structureEditable {
            beginEditing(ref)
            return
        }
        commitEditing()
        if event.modifierFlags.contains(.shift), selection.anchor != nil {
            selection.extent = ref
        } else {
            selection.anchor = ref
            selection.extent = nil
        }
        needsDisplay = true
        onSelectionChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard editing == nil, let selection, selection.anchor != nil else { return }
        let ref = clampedCell(at: convert(event.locationInWindow, from: nil))
        guard selection.extent != ref else { return }
        selection.extent = ref
        needsDisplay = true
        onSelectionChanged?()
        autoscroll(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard structureEditable else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let ref = cell(at: p), let selection else { return }
        selection.anchor = ref
        selection.extent = nil
        needsDisplay = true
        onSelectionChanged?()

        let menu = NSMenu()
        if ref.row > 0 {
            let item = NSMenuItem(title: "Delete Row", action: #selector(deleteRowAction), keyEquivalent: "")
            item.target = self
            item.representedObject = ref.row
            menu.addItem(item)
        }
        let col = NSMenuItem(title: "Delete Column", action: #selector(deleteColumnAction), keyEquivalent: "")
        col.target = self
        col.representedObject = ref.col
        menu.addItem(col)
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Row", action: #selector(addRowAction), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let addCol = NSMenuItem(title: "Add Column", action: #selector(addColumnAction), keyEquivalent: "")
        addCol.target = self
        menu.addItem(addCol)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func deleteRowAction(_ sender: NSMenuItem) {
        commitEditing()
        if let row = sender.representedObject as? Int { onDeleteRow?(row) }
    }
    @objc private func deleteColumnAction(_ sender: NSMenuItem) {
        commitEditing()
        if let col = sender.representedObject as? Int { onDeleteColumn?(col) }
    }
    @objc private func addRowAction() { commitEditing(); onAddRow?() }
    @objc private func addColumnAction() { commitEditing(); onAddColumn?() }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        guard let selection, let anchor = selection.anchor else {
            super.keyDown(with: event)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let base = shift ? (selection.extent ?? anchor) : anchor

        func move(_ dr: Int, _ dc: Int) {
            let next = CellRef(row: min(max(base.row + dr, 1), cells.count - 1),
                               col: min(max(base.col + dc, 0), metrics.widths.count - 1))
            if shift { selection.extent = next } else { selection.anchor = next; selection.extent = nil }
            needsDisplay = true
            onSelectionChanged?()
            scrollToVisible(rect(modelRow: next.row, col: next.col).insetBy(dx: -8, dy: -8))
        }

        switch event.keyCode {
        case 126: move(-1, 0)
        case 125: move(1, 0)
        case 123: move(0, -1)
        case 124: move(0, 1)
        case 36:                                  // ⏎ — edit, or commit and step down
            if structureEditable { beginEditing(anchor) }
        case 48:                                  // ⇥ / ⇧⇥
            move(0, shift ? -1 : 1)
        case 51, 117:                             // ⌫ / ⌦ — clear the selection's text
            if structureEditable { onClearCells?() }
        default:
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v",
               structureEditable,
               let text = NSPasteboard.general.string(forType: .string) {
                onPaste?(text, anchor)
                return
            }
            // Typing over a cell starts editing with that character.
            if structureEditable, !event.modifierFlags.contains(.command),
               let chars = event.characters, chars.count == 1,
               let scalar = chars.unicodeScalars.first,
               CharacterSet.alphanumerics.union(.punctuationCharacters)
                   .union(.symbols).contains(scalar) {
                beginEditing(anchor, seed: chars)
                return
            }
            super.keyDown(with: event)
        }
    }

    // MARK: in-cell editing

    func beginEditing(_ ref: CellRef, seed: String? = nil) {
        commitEditing()
        guard ref.row < cells.count, ref.col < cells[ref.row].count,
              ref.col < metrics.widths.count else { return }
        let rect = rect(modelRow: ref.row, col: ref.col)
        let field = NSTextField(frame: rect.insetBy(dx: 1, dy: 1))
        field.stringValue = seed ?? cells[ref.row][ref.col].text
        field.font = NSFont.systemFont(ofSize: 12)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.delegate = self
        field.target = self
        field.action = #selector(editorCommitted)
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        editor = field
        editing = ref
        selection?.anchor = ref
        selection?.extent = nil
        needsDisplay = true
    }

    @objc private func editorCommitted() {
        commitEditing(thenMove: (1, 0))
    }

    /// Writes the field's text back and (optionally) steps to a neighbour.
    func commitEditing(thenMove step: (Int, Int)? = nil) {
        guard let field = editor, let ref = editing else { return }
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        editor = nil
        editing = nil
        onCommit?(ref.row, ref.col, text)
        if let step, let selection {
            let next = CellRef(row: min(max(ref.row + step.0, 1), cells.count - 1),
                               col: min(max(ref.col + step.1, 0), metrics.widths.count - 1))
            selection.anchor = next
            selection.extent = nil
            onSelectionChanged?()
            scrollToVisible(rect(modelRow: next.row, col: next.col).insetBy(dx: -8, dy: -8))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            commitEditing(thenMove: (0, 1))
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            commitEditing(thenMove: (0, -1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            commitEditing(thenMove: (-1, 0))
            return true
        case #selector(NSResponder.moveDown(_:)):
            commitEditing(thenMove: (1, 0))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            editor?.delegate = nil
            editor?.removeFromSuperview()
            editor = nil
            editing = nil
            window?.makeFirstResponder(self)
            return true
        default:
            return false
        }
    }
}

// MARK: - SpreadsheetHeaderView

/// The pinned copy of row 0.  Owns column resizing: dragging a boundary is
/// tracked in this view's own coordinates, which never move vertically.
final class SpreadsheetHeaderView: NSView {

    var cells: [TableCell] = [] { didSet { needsDisplay = true } }
    var metrics = GridMetrics() { didSet { needsDisplay = true } }
    var selection: GridSelection?
    var resizable = true

    var onWidthChanged: ((Int, CGFloat) -> Void)?
    var onSelectHeader: ((Int, Bool) -> Void)?

    /// Horizontal scroll offset, mirrored from the clip view so the header
    /// tracks the columns while staying pinned vertically.
    var scrollOffsetX: CGFloat = 0 {
        didSet { bounds.origin.x = scrollOffsetX; needsDisplay = true }
    }

    private var dragColumn: Int?
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        GridStyle.headerFill.setFill()
        dirtyRect.fill()
        // Bounds are shifted by the scroll offset, so drawing in "content"
        // coordinates lines the header up with the columns below it.
        let range = selection?.range(rows: max(cells.count, 1), cols: metrics.widths.count)
        for c in cells.indices where c < metrics.widths.count {
            var rect = metrics.rect(row: 0, col: c)
            rect.origin.y = bounds.origin.y
            rect.size.height = bounds.height
            let selected = range.map { $0.rows.contains(0) && $0.cols.contains(c) } ?? false
            GridStyle.draw(cells[c], in: rect, isHeader: true, selected: selected)
        }
        // A firmer rule under the header so it reads as pinned while the
        // rows scroll beneath it.
        NSColor.separatorColor.setStroke()
        let rule = NSBezierPath()
        rule.lineWidth = 1
        rule.move(to: CGPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        rule.line(to: CGPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        rule.stroke()
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard resizable else { return }
        for b in metrics.offsets.dropFirst() {
            addCursorRect(CGRect(x: b - 4, y: bounds.origin.y, width: 8, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if resizable, let boundary = metrics.boundary(near: p.x) {
            dragColumn = boundary - 1
            dragStartX = p.x
            dragStartWidth = metrics.widths[boundary - 1]
            return
        }
        if let col = metrics.columnAt(p.x) {
            onSelectHeader?(col, event.modifierFlags.contains(.shift))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let column = dragColumn else { return }
        // The delta is measured in this view's own space, and this view
        // never moves vertically or resizes horizontally under the cursor
        // mid-drag, so the value stays true for the whole gesture.
        let p = convert(event.locationInWindow, from: nil)
        let width = min(max(dragStartWidth + (p.x - dragStartX), 44), 520)
        onWidthChanged?(column, width)
    }

    override func mouseUp(with event: NSEvent) {
        dragColumn = nil
        window?.invalidateCursorRects(for: self)
    }
}

// MARK: - SpreadsheetGrid (SwiftUI bridge)

struct SpreadsheetGrid: NSViewRepresentable {
    @Binding var cells: [[TableCell]]
    @Binding var columnWidths: [Double]?
    var selection: GridSelection
    /// false = data-linked styling mode: the query owns the shape and the
    /// text, so rows/columns can't be added, removed, or typed into.
    var structureEditable: Bool = true

    static let headerHeight: CGFloat = 26

    func makeNSView(context: Context) -> SpreadsheetContainerView {
        let container = SpreadsheetContainerView(frame: .zero)
        context.coordinator.scroll = container.scroll
        context.coordinator.body = container.body
        context.coordinator.header = container.header
        container.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.sync()
        }
        context.coordinator.attach(self)
        context.coordinator.sync()
        return container
    }

    func updateNSView(_ container: SpreadsheetContainerView, context: Context) {
        context.coordinator.attach(self)
        context.coordinator.sync()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var scroll: NSScrollView?
        var body: SpreadsheetBodyView?
        var header: SpreadsheetHeaderView?
        private var parent: SpreadsheetGrid?

        func attach(_ parent: SpreadsheetGrid) {
            self.parent = parent
            guard let body, let header else { return }
            body.selection = parent.selection
            header.selection = parent.selection
            body.structureEditable = parent.structureEditable
            header.resizable = true

            body.onSelectionChanged = { [weak self] in self?.header?.needsDisplay = true }
            body.onCommit = { [weak self] r, c, text in
                self?.edit { cells in
                    guard cells.indices.contains(r), cells[r].indices.contains(c) else { return }
                    cells[r][c].text = text
                }
            }
            body.onAddRow = { [weak self] in
                self?.edit { cells in
                    cells.append(Array(repeating: TableCell(), count: cells.first?.count ?? 1))
                }
            }
            body.onAddColumn = { [weak self] in
                self?.edit { cells in
                    for r in cells.indices { cells[r].append(TableCell()) }
                }
                self?.appendWidth()
            }
            body.onDeleteRow = { [weak self] row in
                self?.edit { cells in
                    guard cells.count > 1, cells.indices.contains(row) else { return }
                    cells.remove(at: row)
                }
                self?.parent?.selection.clear()
            }
            body.onDeleteColumn = { [weak self] col in
                self?.edit { cells in
                    guard (cells.first?.count ?? 0) > 1 else { return }
                    for r in cells.indices where cells[r].indices.contains(col) {
                        cells[r].remove(at: col)
                    }
                }
                self?.removeWidth(col)
                self?.parent?.selection.clear()
            }
            body.onClearCells = { [weak self] in
                guard let self, let parent = self.parent,
                      let range = parent.selection.range(rows: parent.cells.count,
                                                         cols: parent.cells.first?.count ?? 0)
                else { return }
                self.edit { cells in
                    for r in range.rows where cells.indices.contains(r) {
                        for c in range.cols where cells[r].indices.contains(c) {
                            cells[r][c].text = ""
                        }
                    }
                }
            }
            body.onPaste = { [weak self] text, origin in
                self?.paste(text, at: origin)
            }

            header.onWidthChanged = { [weak self] col, width in
                self?.setWidth(col, width)
            }
            header.onSelectHeader = { [weak self] col, shift in
                guard let selection = self?.parent?.selection else { return }
                if shift, selection.anchor != nil {
                    selection.extent = CellRef(row: selection.extent?.row ?? 0, col: col)
                } else {
                    selection.anchor = CellRef(row: 0, col: col)
                    selection.extent = nil
                }
                self?.body?.needsDisplay = true
                self?.header?.needsDisplay = true
            }
        }

        // MARK: model edits

        private func edit(_ change: (inout [[TableCell]]) -> Void) {
            guard let parent else { return }
            var cells = parent.cells
            change(&cells)
            parent.cells = cells
        }

        private func widths(for count: Int, available: CGFloat) -> [CGFloat] {
            if let stored = parent?.columnWidths, stored.count == count, stored.allSatisfy({ $0 > 0 }) {
                return stored.map { CGFloat($0) }
            }
            // Default: share the visible width so the grid fills its pane.
            let width = max(available / CGFloat(max(count, 1)), 90)
            return Array(repeating: width, count: count)
        }

        private func setWidth(_ col: Int, _ width: CGFloat) {
            guard let parent, let body else { return }
            var stored = parent.columnWidths ?? body.metrics.widths.map { Double($0) }
            while stored.count < body.metrics.widths.count { stored.append(Double(body.metrics.widths.count)) }
            guard stored.indices.contains(col) else { return }
            stored[col] = Double(width)
            parent.columnWidths = stored
        }

        private func appendWidth() {
            guard let parent, var stored = parent.columnWidths else { return }
            stored.append(120)
            parent.columnWidths = stored
        }

        private func removeWidth(_ col: Int) {
            guard let parent, var stored = parent.columnWidths, stored.indices.contains(col) else { return }
            stored.remove(at: col)
            parent.columnWidths = stored
        }

        /// Spreadsheet paste: tab-separated columns, newline rows, growing
        /// the grid as needed.
        private func paste(_ text: String, at origin: CellRef) {
            let rows = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            var matrix = rows.map { $0.components(separatedBy: "\t") }
            while matrix.last?.allSatisfy(\.isEmpty) == true { matrix.removeLast() }
            guard !matrix.isEmpty else { return }
            let blockCols = matrix.map(\.count).max() ?? 1
            edit { cells in
                let neededRows = origin.row + matrix.count
                let neededCols = max(origin.col + blockCols, cells.first?.count ?? 1)
                while cells.count < neededRows {
                    cells.append(Array(repeating: TableCell(), count: cells.first?.count ?? 1))
                }
                for r in cells.indices {
                    while cells[r].count < neededCols { cells[r].append(TableCell()) }
                }
                for (i, row) in matrix.enumerated() {
                    for (j, value) in row.enumerated() {
                        cells[origin.row + i][origin.col + j].text = value
                    }
                }
            }
        }

        // MARK: sync

        func sync() {
            guard let parent, let scroll, let body, let header else { return }
            let count = parent.cells.first?.count ?? 0
            let available = scroll.contentSize.width - (parent.structureEditable ? GridStyle.addStrip : 0)
            var metrics = GridMetrics()
            metrics.widths = widths(for: count, available: max(available, 200))
            metrics.rowHeight = 26

            body.cells = parent.cells
            body.metrics = metrics
            header.cells = parent.cells.first ?? []
            header.metrics = metrics

            let size = body.contentSize
            body.frame = CGRect(origin: .zero,
                                size: CGSize(width: max(size.width, scroll.contentSize.width),
                                             height: max(size.height, scroll.contentSize.height)))
            body.needsDisplay = true
            header.needsDisplay = true
            scroll.window?.invalidateCursorRects(for: header)
        }
    }
}


// MARK: - SpreadsheetContainerView

/// Stacks the pinned header above the scrolling body and keeps the two
/// horizontally in step.
final class SpreadsheetContainerView: NSView {

    let header = SpreadsheetHeaderView(frame: .zero)
    let scroll = NSScrollView(frame: .zero)
    let body = SpreadsheetBodyView(frame: .zero)

    /// Called after every layout so the grid can recompute default column
    /// widths against the new visible width.
    var onLayout: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        scroll.documentView = body
        addSubview(header)
        addSubview(scroll)

        // Mirror the horizontal scroll offset into the header's own bounds.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func clipBoundsChanged() {
        header.scrollOffsetX = scroll.contentView.bounds.origin.x
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = SpreadsheetGrid.headerHeight
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        scroll.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(bounds.height - h, 0))
        header.scrollOffsetX = scroll.contentView.bounds.origin.x
        onLayout?()
    }
}
