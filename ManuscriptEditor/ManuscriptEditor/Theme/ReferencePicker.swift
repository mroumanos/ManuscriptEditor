// ReferencePicker.swift
//
// The "/" reference dropdown: a floating panel under the caret with a search
// box (focused automatically — typing lands there, not in the prose) and an
// icon-tagged list of everything referencable: bibliography entries, figures,
// tables, and Zotero library items.
//
// Interaction contract (Jul 2026 feedback):
//   • "/" opens the panel and focuses the search box; typing (spaces
//     included) filters across every source's text fields.
//   • ↑/↓ move the selection without leaving the search box; Tab, Return,
//     or a click accepts the selected row.
//   • ONLY Escape leaves the "/" as ordinary text.  The panel's owner
//     (CitationTextView) opens it on the "/" keystroke alone, so a dismissed
//     slash can never re-arm — not even by backspacing to it.

import AppKit

/// Borderless panels refuse key status by default; the search field needs it
/// to receive typing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ReferencePicker: NSObject {

    private let provideCandidates: (String) -> [RefCandidate]
    private let onAccept: (RefCandidate) -> Void
    /// `refocus`: return the caret to the editor (Escape) or leave focus
    /// where the user clicked (the panel merely lost key status).
    private let onDismiss: (_ refocus: Bool) -> Void

    private var panel: NSPanel!
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matches")

    private var candidates: [RefCandidate] = []
    private var isClosing = false
    /// The screen point the panel hangs from (top-left growing down, or
    /// bottom-left growing up when the caret sits near the screen bottom).
    private var anchor: NSPoint = .zero
    private var opensUpward = false

    private static let width: CGFloat = 420
    private static let rowHeight: CGFloat = 24
    private static let searchHeight: CGFloat = 28
    private static let maxRows = 10

    init(provideCandidates: @escaping (String) -> [RefCandidate],
         onAccept: @escaping (RefCandidate) -> Void,
         onDismiss: @escaping (_ refocus: Bool) -> Void) {
        self.provideCandidates = provideCandidates
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        super.init()
        buildPanel()
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true

        searchField.delegate = self
        searchField.placeholderString = "Search references, figures, tables, Zotero…"
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 12)
        (searchField.cell as? NSSearchFieldCell)?.maximumRecents = 0
        searchField.sendsWholeSearchString = false

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.addTableColumn(NSTableColumn(identifier: .init("main")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        effect.addSubview(searchField)
        effect.addSubview(scrollView)
        effect.addSubview(emptyLabel)
        panel.contentView = effect
        self.panel = panel
    }

    // MARK: - Show / dismiss

    func show(nearCaret caretScreenRect: NSRect, parent: NSWindow) {
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let maxHeight = Self.searchHeight + CGFloat(Self.maxRows) * Self.rowHeight + 20
        opensUpward = caretScreenRect.minY - visible.minY < maxHeight + 12
        anchor = opensUpward
            ? NSPoint(x: caretScreenRect.minX, y: caretScreenRect.maxY + 6)
            : NSPoint(x: caretScreenRect.minX, y: caretScreenRect.minY - 6)
        anchor.x = max(visible.minX + 8, min(anchor.x, visible.maxX - Self.width - 8))

        parent.addChildWindow(panel, ordered: .above)
        refresh()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    /// Owner-initiated teardown (editor dismantled, a new "/" typed) — no
    /// callbacks fire.
    func close() {
        dismissPanel(refocusParent: false)
    }

    private func dismissPanel(refocusParent: Bool) {
        guard !isClosing else { return }
        isClosing = true
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if refocusParent { parent?.makeKeyAndOrderFront(nil) }
    }

    // MARK: - Candidates

    /// Reload after an async (Zotero) fetch, if the search box still holds
    /// the query the fetch was for.
    func refreshIfCurrent(query: String) {
        guard !isClosing,
              searchField.stringValue.lowercased()
                  .trimmingCharacters(in: .whitespaces) == query else { return }
        refresh()
    }

    private func refresh() {
        candidates = provideCandidates(searchField.stringValue)
        tableView.reloadData()
        if !candidates.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        emptyLabel.isHidden = !candidates.isEmpty
        relayout()
    }

    private func relayout() {
        let rows = min(candidates.count, Self.maxRows)
        let listHeight = candidates.isEmpty ? 32 : CGFloat(rows) * Self.rowHeight + 6
        let height = Self.searchHeight + 12 + listHeight + 6
        let originY = opensUpward ? anchor.y : anchor.y - height
        panel.setFrame(NSRect(x: anchor.x, y: originY, width: Self.width, height: height),
                       display: true)
        guard let content = panel.contentView else { return }
        let b = content.bounds
        searchField.frame = NSRect(x: 8, y: b.maxY - Self.searchHeight - 6,
                                   width: b.width - 16, height: Self.searchHeight)
        scrollView.frame = NSRect(x: 4, y: 6, width: b.width - 8, height: listHeight)
        emptyLabel.frame = scrollView.frame
    }

    // MARK: - Selection

    private func moveSelection(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        let row = max(0, min(candidates.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func accept(row: Int) {
        guard candidates.indices.contains(row) else { return }
        let candidate = candidates[row]
        dismissPanel(refocusParent: true)
        onAccept(candidate)
    }

    @objc private func rowClicked() {
        accept(row: tableView.clickedRow)
    }
}

// MARK: - Search field: filtering + key routing

extension ReferencePicker: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
            accept(row: max(tableView.selectedRow, candidates.isEmpty ? -1 : 0)); return true
        case #selector(NSResponder.cancelOperation(_:)):
            // The one and only "make the slash plain text" gesture.
            dismissPanel(refocusParent: true)
            onDismiss(true)
            return true
        default:
            return false
        }
    }
}

// MARK: - Table

extension ReferencePicker: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let candidate = candidates[row]
        let cell = NSTableCellView()

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: candidate.icon, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: candidate.display)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle

        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Window: click-away dismissal

extension ReferencePicker: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing else { return }
        dismissPanel(refocusParent: false)
        onDismiss(false)
    }
}
