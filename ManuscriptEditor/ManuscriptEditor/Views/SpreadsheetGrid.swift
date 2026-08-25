// SpreadsheetGrid.swift
//
// The table grid: ONE AppKit view inside an NSScrollView.
//
// WHY NOT SWIFTUI
// ─────────────────────────────────────────────────────────────────────────────
// The SwiftUI grid had one bug that survived five rewrites: after any
// STRUCTURAL change inside a horizontally scrollable table — resizing a
// column, deleting a column, deleting a row — clicks landed a constant two
// rows below the cursor, healing only on a scroll or when the view was
// recreated.  Every variant of the pointer math drifted the same way,
// because what went stale was SwiftUI's own mapping between where scrolling
// content DRAWS and where it HIT-TESTS.  AppKit computes
// `convert(_:from: nil)` from the live view hierarchy at event time, so it
// cannot be stale by construction.
//
// WHY ONE VIEW
// ─────────────────────────────────────────────────────────────────────────────
// The frozen header and the row-number rail are DRAWN by this view at the
// current scroll offset instead of being separate pinned views.  Two
// arrangements failed to composite at all: `addFloatingSubview` installs a
// full-size container over the clip view and the document view vanished
// entirely, and a sibling header stacked above the scroll view rendered
// blank inside its container.  Drawing them here means one coordinate
// space, one hit test, and nothing to composite.
//
// LAYOUT (document coordinates, flipped)
//   x: 0…gutterWidth      row numbers (sticky to the viewport's left edge)
//      gutterWidth…       columns
//   y: 0…headerHeight     header = model row 0 (sticky to the viewport's top)
//      headerHeight…      model rows 1…

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

// MARK: - Style

enum GridStyle {
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
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            rect.fill()
        }
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25))
        border.lineWidth = 0.5
        border.stroke()

        let box = rect.insetBy(dx: 6, dy: 0)
        let attrs = attributes(cell, isHeader: isHeader)
        let size = (cell.text as NSString).size(withAttributes: attrs)
        (cell.text as NSString).draw(in: CGRect(x: box.minX, y: box.midY - size.height / 2,
                                                width: box.width, height: size.height),
                                     withAttributes: attrs)
    }
}

// MARK: - SpreadsheetGridView

/// The whole grid: sticky header, sticky row rail, cells, and every
/// interaction.
final class SpreadsheetGridView: NSView {

    var cells: [[TableCell]] = [] { didSet { needsDisplay = true } }
    var widths: [CGFloat] = [] { didSet { needsDisplay = true } }
    var selection: GridSelection?
    /// false = data-linked styling mode: the query owns the shape and text.
    var structureEditable = true { didSet { needsDisplay = true } }

    var onSelectionChanged: (() -> Void)?
    var onCommit: ((Int, Int, String) -> Void)?
    var onAddRow: (() -> Void)?
    var onAddColumn: (() -> Void)?
    var onDeleteRow: ((Int) -> Void)?
    var onDeleteColumn: ((Int) -> Void)?
    var onMoveRow: ((Int, Int) -> Void)?
    var onMoveColumn: ((Int, Int) -> Void)?
    var onWidthChanged: ((Int, CGFloat) -> Void)?
    var onClearCells: (() -> Void)?
    var onPaste: ((String, CellRef) -> Void)?

    static let headerHeight: CGFloat = 26
    static let gutterWidth: CGFloat = 36
    static let rowHeight: CGFloat = 26

    private var editor: NSTextField?
    private var editing: CellRef?
    private var resizingColumn: Int?
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0
    private var reorderRow: Int?
    private var reorderColumn: Int?
    private var reorderStart: CGPoint = .zero
    private var hoverAddRow = false
    private var hoverAddColumn = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: geometry

    private var rowCount: Int { cells.count }
    private var colCount: Int { widths.count }
    private var dataRows: Int { max(cells.count - 1, 0) }

    /// Leading edge of each column, measured from the rail.
    private var offsets: [CGFloat] {
        var out: [CGFloat] = [Self.gutterWidth]
        for w in widths { out.append(out[out.count - 1] + w) }
        return out
    }

    private var totalWidth: CGFloat { offsets.last ?? Self.gutterWidth }

    var contentSize: CGSize {
        CGSize(width: totalWidth + (structureEditable ? GridStyle.addStrip : 0),
               height: Self.headerHeight + CGFloat(dataRows) * Self.rowHeight
                   + (structureEditable ? GridStyle.addStrip : 0))
    }

    /// What the scroll view is showing; the sticky header and rail pin
    /// themselves to its edges.
    private var viewport: CGRect {
        enclosingScrollView?.contentView.bounds ?? bounds
    }

    private func columnX(_ c: Int) -> CGFloat { offsets[min(max(c, 0), colCount)] }

    private func cellRect(row: Int, col: Int) -> CGRect {
        CGRect(x: columnX(col), y: Self.headerHeight + CGFloat(row - 1) * Self.rowHeight,
               width: col < colCount ? widths[col] : 0, height: Self.rowHeight)
    }

    private func headerRect(col: Int) -> CGRect {
        CGRect(x: columnX(col), y: viewport.minY,
               width: col < colCount ? widths[col] : 0, height: Self.headerHeight)
    }

    private func railRect(row: Int) -> CGRect {
        CGRect(x: viewport.minX, y: Self.headerHeight + CGFloat(row - 1) * Self.rowHeight,
               width: Self.gutterWidth, height: Self.rowHeight)
    }

    private var addRowRect: CGRect {
        CGRect(x: Self.gutterWidth, y: Self.headerHeight + CGFloat(dataRows) * Self.rowHeight,
               width: max(totalWidth - Self.gutterWidth, 1), height: GridStyle.addStrip)
    }

    private var addColumnRect: CGRect {
        CGRect(x: totalWidth, y: Self.headerHeight, width: GridStyle.addStrip,
               height: max(CGFloat(dataRows) * Self.rowHeight, 1))
    }

    // MARK: hit testing — one space, one set of rules

    private enum Region {
        case corner
        case header(Int)
        case rail(Int)
        case cell(CellRef)
        case addRow
        case addColumn
        case none
    }

    private func region(at p: CGPoint) -> Region {
        let vp = viewport
        let inHeader = p.y < vp.minY + Self.headerHeight
        let inRail = p.x < vp.minX + Self.gutterWidth
        if inHeader && inRail { return .corner }
        if inHeader {
            guard let c = column(at: p.x) else { return .none }
            return .header(c)
        }
        if inRail {
            guard let r = dataRow(at: p.y) else { return .none }
            return .rail(r)
        }
        if structureEditable, addRowRect.contains(p) { return .addRow }
        if structureEditable, addColumnRect.contains(p) { return .addColumn }
        guard let c = column(at: p.x), let r = dataRow(at: p.y) else { return .none }
        return .cell(CellRef(row: r, col: c))
    }

    private func column(at x: CGFloat) -> Int? {
        let xs = offsets
        guard colCount > 0, x >= xs[0], x < xs[colCount] else { return nil }
        for c in 0..<colCount where x < xs[c + 1] { return c }
        return colCount - 1
    }

    private func dataRow(at y: CGFloat) -> Int? {
        let row = Int((y - Self.headerHeight) / Self.rowHeight) + 1
        guard row >= 1, row < rowCount else { return nil }
        return row
    }

    /// Nearest valid cell for a drag; dragging up into the header reaches
    /// model row 0.
    private func clampedCell(at p: CGPoint) -> CellRef {
        let vp = viewport
        let col = column(at: min(max(p.x, offsets[0]), max(totalWidth - 1, offsets[0]))) ?? 0
        if p.y < vp.minY + Self.headerHeight { return CellRef(row: 0, col: col) }
        let row = min(max(Int((p.y - Self.headerHeight) / Self.rowHeight) + 1, 1),
                      max(rowCount - 1, 1))
        return CellRef(row: row, col: col)
    }

    private func boundary(near x: CGFloat) -> Int? {
        let xs = offsets
        guard colCount > 0 else { return nil }
        for b in 1...colCount where b < xs.count && abs(x - xs[b]) <= 4 { return b - 1 }
        return nil
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard rowCount > 0, colCount > 0 else { return }
        let range = selection?.range(rows: rowCount, cols: colCount)

        // Data cells: only the band that intersects the dirty rect.
        let first = max(Int((dirtyRect.minY - Self.headerHeight) / Self.rowHeight) + 1, 1)
        let last = min(Int((dirtyRect.maxY - Self.headerHeight) / Self.rowHeight) + 1, rowCount - 1)
        if first <= last {
            for r in first...last {
                for c in 0..<min(cells[r].count, colCount) {
                    let selected = range.map { $0.rows.contains(r) && $0.cols.contains(c) } ?? false
                    GridStyle.draw(cells[r][c], in: cellRect(row: r, col: c),
                                   isHeader: false, selected: selected)
                }
            }
        }

        if structureEditable {
            drawAddStrip(addRowRect, hovering: hoverAddRow)
            drawAddStrip(addColumnRect, hovering: hoverAddColumn)
        }

        drawRail(range: range)
        drawHeader(range: range)

        // The corner sits over both.
        let vp = viewport
        let corner = CGRect(x: vp.minX, y: vp.minY,
                            width: Self.gutterWidth, height: Self.headerHeight)
        GridStyle.headerFill.setFill()
        corner.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: corner.insetBy(dx: 0.25, dy: 0.25)).stroke()

        if let range { drawSelectionOutline(range) }
    }

    private func drawSelectionOutline(_ range: (rows: ClosedRange<Int>, cols: ClosedRange<Int>)) {
        let vp = viewport
        let top = range.rows.lowerBound == 0
            ? vp.minY
            : Self.headerHeight + CGFloat(range.rows.lowerBound - 1) * Self.rowHeight
        let bottom = Self.headerHeight + CGFloat(range.rows.upperBound) * Self.rowHeight
        let rect = CGRect(x: columnX(range.cols.lowerBound), y: top,
                          width: columnX(range.cols.upperBound + 1) - columnX(range.cols.lowerBound),
                          height: max(bottom - top, Self.rowHeight))
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawHeader(range: (rows: ClosedRange<Int>, cols: ClosedRange<Int>)?) {
        guard let header = cells.first else { return }
        for c in 0..<min(header.count, colCount) {
            let selected = range.map { $0.rows.contains(0) && $0.cols.contains(c) } ?? false
            GridStyle.draw(header[c], in: headerRect(col: c), isHeader: true, selected: selected)
        }
        let vp = viewport
        NSColor.separatorColor.setStroke()
        let rule = NSBezierPath()
        rule.lineWidth = 1
        rule.move(to: CGPoint(x: vp.minX, y: vp.minY + Self.headerHeight - 0.5))
        rule.line(to: CGPoint(x: vp.maxX, y: vp.minY + Self.headerHeight - 0.5))
        rule.stroke()
    }

    /// Row numbers: an editing aid only — never part of `cells`, never
    /// exported.
    private func drawRail(range: (rows: ClosedRange<Int>, cols: ClosedRange<Int>)?) {
        guard dataRows > 0 else { return }
        for r in 1..<rowCount {
            let rect = railRect(row: r)
            GridStyle.headerFill.setFill()
            rect.fill()
            if range?.rows.contains(r) == true {
                NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
                rect.fill()
            }
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25))
            path.lineWidth = 0.5
            path.stroke()
            let label = "\(r)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                       withAttributes: attrs)
        }
    }

    private func drawAddStrip(_ rect: CGRect, hovering: Bool) {
        guard rect.width > 0, rect.height > 0 else { return }
        (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                  : NSColor.separatorColor.withAlphaComponent(0.14)).setFill()
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
        let p = convert(event.locationInWindow, from: nil)
        if structureEditable {
            let row = addRowRect.contains(p), col = addColumnRect.contains(p)
            if row != hoverAddRow || col != hoverAddColumn {
                hoverAddRow = row
                hoverAddColumn = col
                needsDisplay = true
            }
        }
        if p.y < viewport.minY + Self.headerHeight, boundary(near: p.x) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        guard hoverAddRow || hoverAddColumn else { return }
        hoverAddRow = false
        hoverAddColumn = false
        needsDisplay = true
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitEditing()
        let p = convert(event.locationInWindow, from: nil)
        guard let selection else { return }
        let shift = event.modifierFlags.contains(.shift)

        switch region(at: p) {
        case .header(let col):
            if let b = boundary(near: p.x) {
                resizingColumn = b
                resizeStartX = p.x
                resizeStartWidth = widths[b]
                return
            }
            if event.clickCount >= 2, structureEditable {
                beginEditing(CellRef(row: 0, col: col))
                return
            }
            // A header press selects the WHOLE column and primes a reorder.
            if shift, selection.anchor != nil {
                selection.extent = CellRef(row: max(rowCount - 1, 0), col: col)
            } else {
                selection.anchor = CellRef(row: 0, col: col)
                selection.extent = CellRef(row: max(rowCount - 1, 0), col: col)
            }
            if structureEditable {
                reorderColumn = col
                reorderStart = p
            }
        case .rail(let row):
            if shift, selection.anchor != nil {
                selection.extent = CellRef(row: row, col: max(colCount - 1, 0))
            } else {
                selection.anchor = CellRef(row: row, col: 0)
                selection.extent = CellRef(row: row, col: max(colCount - 1, 0))
            }
            if structureEditable {
                reorderRow = row
                reorderStart = p
            }
        case .cell(let ref):
            if event.clickCount >= 2, structureEditable {
                beginEditing(ref)
                return
            }
            if shift, selection.anchor != nil {
                selection.extent = ref
            } else {
                selection.anchor = ref
                selection.extent = nil
            }
        case .addRow:    onAddRow?(); return
        case .addColumn: onAddColumn?(); return
        case .corner, .none: return
        }
        needsDisplay = true
        onSelectionChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let col = resizingColumn {
            onWidthChanged?(col, min(max(resizeStartWidth + (p.x - resizeStartX), 44), 520))
            return
        }
        if let from = reorderColumn, abs(p.x - reorderStart.x) > 5 {
            if let to = column(at: min(max(p.x, offsets[0]), max(totalWidth - 1, offsets[0]))),
               to != from {
                onMoveColumn?(from, to)
                reorderColumn = to
            }
            return
        }
        if let from = reorderRow, abs(p.y - reorderStart.y) > 5 {
            let to = min(max(Int((p.y - Self.headerHeight) / Self.rowHeight) + 1, 1),
                         max(rowCount - 1, 1))
            if to != from {
                onMoveRow?(from, to)
                reorderRow = to
            }
            return
        }
        guard editing == nil, let selection, selection.anchor != nil else { return }
        let ref = clampedCell(at: p)
        guard selection.extent != ref else { return }
        selection.extent = ref
        needsDisplay = true
        onSelectionChanged?()
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        resizingColumn = nil
        reorderColumn = nil
        reorderRow = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard structureEditable else { return }
        let p = convert(event.locationInWindow, from: nil)
        var row: Int?
        var col: Int?
        switch region(at: p) {
        case .header(let c): col = c
        case .rail(let r):   row = r
        case .cell(let ref): row = ref.row; col = ref.col
        default: break
        }
        let menu = NSMenu()
        if let row {
            let item = NSMenuItem(title: "Delete Row \(row)",
                                  action: #selector(deleteRowAction), keyEquivalent: "")
            item.target = self
            item.representedObject = row
            menu.addItem(item)
        }
        if let col {
            let item = NSMenuItem(title: "Delete Column",
                                  action: #selector(deleteColumnAction), keyEquivalent: "")
            item.target = self
            item.representedObject = col
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let addRow = NSMenuItem(title: "Add Row", action: #selector(addRowAction), keyEquivalent: "")
        addRow.target = self
        menu.addItem(addRow)
        let addCol = NSMenuItem(title: "Add Column", action: #selector(addColumnAction), keyEquivalent: "")
        addCol.target = self
        menu.addItem(addCol)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func deleteRowAction(_ s: NSMenuItem) {
        commitEditing()
        if let r = s.representedObject as? Int { onDeleteRow?(r) }
    }
    @objc private func deleteColumnAction(_ s: NSMenuItem) {
        commitEditing()
        if let c = s.representedObject as? Int { onDeleteColumn?(c) }
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
            let next = CellRef(row: min(max(base.row + dr, 0), max(rowCount - 1, 0)),
                               col: min(max(base.col + dc, 0), max(colCount - 1, 0)))
            if shift { selection.extent = next } else { selection.anchor = next; selection.extent = nil }
            needsDisplay = true
            onSelectionChanged?()
            if next.row > 0 {
                scrollToVisible(cellRect(row: next.row, col: next.col).insetBy(dx: -8, dy: -8))
            }
        }

        switch event.keyCode {
        case 126: move(-1, 0)
        case 125: move(1, 0)
        case 123: move(0, -1)
        case 124: move(0, 1)
        case 36:  if structureEditable { beginEditing(anchor) }
        case 48:  move(0, shift ? -1 : 1)
        case 51, 117: if structureEditable { onClearCells?() }
        default:
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v",
               structureEditable, let text = NSPasteboard.general.string(forType: .string) {
                onPaste?(text, anchor)
                return
            }
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

    // MARK: editing

    func beginEditing(_ ref: CellRef, seed: String? = nil) {
        commitEditing()
        guard ref.row < rowCount, ref.col < colCount, ref.col < cells[ref.row].count else { return }
        let rect = ref.row == 0 ? headerRect(col: ref.col) : cellRect(row: ref.row, col: ref.col)
        let field = NSTextField(frame: rect.insetBy(dx: 1, dy: 1))
        field.stringValue = seed ?? cells[ref.row][ref.col].text
        field.font = NSFont.systemFont(ofSize: 12, weight: ref.row == 0 ? .semibold : .regular)
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

    @objc private func editorCommitted() { commitEditing(thenMove: (1, 0)) }

    func commitEditing(thenMove step: (Int, Int)? = nil) {
        guard let field = editor, let ref = editing else { return }
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        editor = nil
        editing = nil
        onCommit?(ref.row, ref.col, text)
        if let step, let selection {
            let next = CellRef(row: min(max(ref.row + step.0, 0), max(rowCount - 1, 0)),
                               col: min(max(ref.col + step.1, 0), max(colCount - 1, 0)))
            selection.anchor = next
            selection.extent = nil
            onSelectionChanged?()
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

extension SpreadsheetGridView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):     commitEditing(thenMove: (0, 1)); return true
        case #selector(NSResponder.insertBacktab(_:)): commitEditing(thenMove: (0, -1)); return true
        case #selector(NSResponder.moveUp(_:)):        commitEditing(thenMove: (-1, 0)); return true
        case #selector(NSResponder.moveDown(_:)):      commitEditing(thenMove: (1, 0)); return true
        case #selector(NSResponder.cancelOperation(_:)):
            editor?.delegate = nil
            editor?.removeFromSuperview()
            editor = nil
            editing = nil
            window?.makeFirstResponder(self)
            return true
        default: return false
        }
    }
}

// MARK: - SpreadsheetGrid (SwiftUI bridge)

struct SpreadsheetGrid: NSViewRepresentable {
    @Binding var cells: [[TableCell]]
    @Binding var columnWidths: [Double]?
    var selection: GridSelection
    var structureEditable: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder

        let grid = SpreadsheetGridView(frame: .zero)
        scroll.documentView = grid
        // The header and rail draw at the scroll offset, so every scroll
        // needs a repaint.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll)
        context.coordinator.scroll = scroll
        context.coordinator.grid = grid
        context.coordinator.attach(self)
        context.coordinator.sync()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.attach(self)
        context.coordinator.sync()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var scroll: NSScrollView?
        var grid: SpreadsheetGridView?
        private var parent: SpreadsheetGrid?
        private var observer: NSObjectProtocol?

        func observe(_ scroll: NSScrollView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.grid?.needsDisplay = true }
                }
        }

        func attach(_ parent: SpreadsheetGrid) {
            self.parent = parent
            guard let grid else { return }
            grid.selection = parent.selection
            grid.structureEditable = parent.structureEditable

            grid.onCommit = { [weak self] r, c, text in
                self?.edit { cells in
                    guard cells.indices.contains(r), cells[r].indices.contains(c) else { return }
                    cells[r][c].text = text
                }
            }
            grid.onAddRow = { [weak self] in
                self?.edit { cells in
                    cells.append(Array(repeating: TableCell(), count: cells.first?.count ?? 1))
                }
            }
            grid.onAddColumn = { [weak self] in
                self?.edit { cells in for r in cells.indices { cells[r].append(TableCell()) } }
                if var stored = self?.parent?.columnWidths {
                    stored.append(120)
                    self?.parent?.columnWidths = stored
                }
            }
            grid.onDeleteRow = { [weak self] row in
                self?.edit { cells in
                    guard cells.count > 2, cells.indices.contains(row), row >= 1 else { return }
                    cells.remove(at: row)
                }
                self?.parent?.selection.clear()
            }
            grid.onDeleteColumn = { [weak self] col in
                self?.edit { cells in
                    guard (cells.first?.count ?? 0) > 1 else { return }
                    for r in cells.indices where cells[r].indices.contains(col) {
                        cells[r].remove(at: col)
                    }
                }
                if var stored = self?.parent?.columnWidths, stored.indices.contains(col) {
                    stored.remove(at: col)
                    self?.parent?.columnWidths = stored
                }
                self?.parent?.selection.clear()
            }
            grid.onMoveRow = { [weak self] from, to in
                self?.edit { cells in
                    guard cells.indices.contains(from), from >= 1, to >= 1, to < cells.count else { return }
                    let row = cells.remove(at: from)
                    cells.insert(row, at: to)
                }
                guard let parent = self?.parent else { return }
                parent.selection.anchor = CellRef(row: to, col: 0)
                parent.selection.extent = CellRef(row: to, col: max((parent.cells.first?.count ?? 1) - 1, 0))
            }
            grid.onMoveColumn = { [weak self] from, to in
                self?.edit { cells in
                    for r in cells.indices where cells[r].indices.contains(from) {
                        let cell = cells[r].remove(at: from)
                        cells[r].insert(cell, at: min(to, cells[r].count))
                    }
                }
                if var stored = self?.parent?.columnWidths, stored.indices.contains(from) {
                    let w = stored.remove(at: from)
                    stored.insert(w, at: min(to, stored.count))
                    self?.parent?.columnWidths = stored
                }
                guard let parent = self?.parent else { return }
                parent.selection.anchor = CellRef(row: 0, col: to)
                parent.selection.extent = CellRef(row: max(parent.cells.count - 1, 0), col: to)
            }
            grid.onWidthChanged = { [weak self] col, width in
                guard let self, let parent = self.parent, let grid = self.grid else { return }
                var stored = parent.columnWidths ?? grid.widths.map { Double($0) }
                while stored.count < grid.widths.count { stored.append(120) }
                guard stored.indices.contains(col) else { return }
                stored[col] = Double(width)
                parent.columnWidths = stored
            }
            grid.onClearCells = { [weak self] in
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
            grid.onPaste = { [weak self] text, origin in self?.paste(text, at: origin) }
        }

        private func edit(_ change: (inout [[TableCell]]) -> Void) {
            guard let parent else { return }
            var cells = parent.cells
            change(&cells)
            parent.cells = cells
        }

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

        func sync() {
            guard let parent, let scroll, let grid else { return }
            let count = parent.cells.first?.count ?? 0
            // Columns share the visible width until one is dragged, so the
            // grid fills its pane.
            let available = scroll.contentSize.width - SpreadsheetGridView.gutterWidth
                - (parent.structureEditable ? GridStyle.addStrip : 0)
            let widths: [CGFloat]
            if let stored = parent.columnWidths, stored.count == count, stored.allSatisfy({ $0 > 0 }) {
                widths = stored.map { CGFloat($0) }
            } else {
                widths = Array(repeating: max(available / CGFloat(max(count, 1)), 90), count: count)
            }
            grid.cells = parent.cells
            grid.widths = widths
            let size = grid.contentSize
            grid.frame = CGRect(origin: .zero,
                                size: CGSize(width: max(size.width, scroll.contentSize.width),
                                             height: max(size.height, scroll.contentSize.height)))
            grid.needsDisplay = true
        }
    }
}
