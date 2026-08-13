// RichTextEditor.swift
//
// A native, dependency-free rich-text editor for prose fields.
//
// WHY NSTextView
// ─────────────────────────────────────────────────────────────────────────────
// AppKit's NSTextView supports every requested style natively — bold, italic,
// underline, strikethrough, super/subscript, paragraph alignment, and bullet
// lists — and round-trips losslessly to RTF.  We wrap it in an
// `NSViewRepresentable` and expose formatting through a small `RichTextController`
// that the inline toolbar drives.
//
// CHROME
// ─────────────────────────────────────────────────────────────────────────────
//   • An always-visible formatting toolbar across the top.
//   • A line-number gutter on the left (custom NSRulerView).
//   • A draggable width ruler that sets the wrap column — how far text runs
//     before carrying to the next line.
//
// PUBLIC API
// ─────────────────────────────────────────────────────────────────────────────
// `RichEditor(value:placeholder:)` is the SwiftUI entry point.  Content is bound
// to a `RichText` (plain mirror + RTF archive).

import SwiftUI
import AppKit

// MARK: - Layout constants

enum EditorLayout {
    /// Width of the line-number gutter (the vertical ruler).
    static let gutterWidth: CGFloat = 40
    /// Horizontal inset between the gutter and the text.
    static let textInset: CGFloat = 8
    /// Distance from the editor's left edge to the first text glyph.
    static var leftInset: CGFloat { gutterWidth + textInset }
}

// MARK: - Undo tuning

enum UndoTuning {
    /// Typing pause after which the editors break AppKit's undo coalescing,
    /// so each burst is its own ⌘Z step.  There is no platform standard —
    /// AppKit's default is to coalesce an unbroken run forever; word
    /// processors pick ~0.5–2 s.  Smaller = finer-grained undo.
    static let typingChunkPause: Duration = .seconds(1)

    /// Same idea one tier up: per-keystroke draft commits (TextFields and
    /// PlainTextEditors committing on every change) register at most one
    /// document snapshot per burst; a pause this long starts a new one.
    static let snapshotCoalescePause: TimeInterval = 1.5
}

// MARK: - RichEditor (SwiftUI entry point)

struct RichEditor: View {
    @Environment(ManuscriptStore.self) private var store

    @Binding var value: RichText
    var placeholder: String = ""
    /// Which version's bibliography/figures/tables feed the "/" reference
    /// autocomplete and token numbering.
    var versionRef: VersionRef = .source
    /// Letter-to-editor context: "/" additionally offers Date and Signature
    /// snippets (inserted as plain text).
    var letterMode: Bool = false

    @AppStorage(EditorPrefs.fontKey)        private var family = EditorPrefs.defaultFont
    @AppStorage(EditorPrefs.fontSizeKey)    private var size = EditorPrefs.defaultFontSize
    @AppStorage(EditorPrefs.lineSpacingKey) private var lineSpacing = EditorPrefs.defaultLineSpacing
    @AppStorage("editorWrapWidth")          private var wrapWidth = 650.0

    @State private var controller = RichTextController()

    private var baseFont: NSFont {
        EditorTypography(family: family, size: size, lineSpacingMultiplier: lineSpacing).nsFont
    }

    var body: some View {
        VStack(spacing: 0) {
            FormatBar(controller: controller)
            Divider()
            WidthRuler(width: $wrapWidth, leftInset: EditorLayout.leftInset)
            Divider()
            ZStack(alignment: .topLeading) {
                RichTextRepresentable(
                    value: $value,
                    controller: controller,
                    baseFont: baseFont,
                    lineHeightMultiple: lineSpacing,
                    wrapWidth: CGFloat(wrapWidth),
                    candidates: refCandidates,
                    zoteroKeys: existingZoteroKeys,
                    addZoteroEntry: addZoteroEntry,
                    refContext: store.refContext(for: versionRef) ?? RefEngine.Context()
                )
                if value.isEmpty {
                    Text(placeholder)
                        .font(.system(size: size))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, EditorLayout.leftInset + 5)
                        .padding(.top, 18)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Reference lookup

    /// Everything "/" can reference, filtered by `query` and grouped by
    /// category: bibliography entries (key/title/authors/journal), then
    /// figures, then tables (number/title/caption).  Typing a category word
    /// ("ref", "figure", "table") narrows to that group.
    private func refCandidates(_ query: String) -> [RefCandidate] {
        guard let m = store.manuscript(for: versionRef) else { return [] }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        func matches(_ fields: [String]) -> Bool {
            q.isEmpty || fields.contains { $0.lowercased().contains(q) }
        }

        var out: [RefCandidate] = []
        // Letter references first — live tokens that resolve in preview and
        // export (⟦Date⟧ → today at render time, ⟦Signature⟧ → the drawing).
        if letterMode {
            let dateText = Date().formatted(date: .long, time: .omitted)
            if matches(["date", "today", dateText]) {
                out.append(RefCandidate(kind: .bib, id: Self.dateSnippetID,
                                        display: "Date • renders today's date (\(dateText))",
                                        snippetText: LetterToken.date.marker,
                                        tokenURL: LetterToken.date.url))
            }
            if matches(["signature", "sign"]) {
                let hasDrawn = m.letterToEditor.signatureImageData != nil
                out.append(RefCandidate(kind: .bib, id: Self.signatureSnippetID,
                                        display: hasDrawn
                                            ? "Signature • the drawn signature"
                                            : "Signature • draw one in the Signature section first",
                                        snippetText: LetterToken.signature.marker,
                                        tokenURL: LetterToken.signature.url))
            }
        }
        // Every entry is referencable — a missing citation key must not hide
        // it from the menu (DOI-imported entries start keyless; issue #12).
        for e in m.bibliography {
            guard matches(["reference", e.key, e.title, e.authorsFormatted, e.journal ?? ""]) else { continue }
            let label = e.key.isEmpty
                ? (e.title.isEmpty ? "(untitled reference)" : e.title)
                : "\(e.key) — \(e.title.isEmpty ? "(no title)" : e.title)"
            out.append(RefCandidate(kind: .bib, id: e.id, display: "Ref • \(label)"))
        }
        // Figures/tables get ONE row each; accepting opens a small menu at the
        // caret to choose Reference vs Placement (with a figure thumbnail).
        let figureNumbers = RefEngine.effectiveFigureNumbers(in: m)
        for f in m.figures.sorted(by: { (figureNumbers[$0.id] ?? 0) < (figureNumbers[$1.id] ?? 0) }) {
            let n = figureNumbers[f.id] ?? f.number
            guard matches(["figure \(n)", f.title, f.caption]) else { continue }
            out.append(RefCandidate(kind: .figure, id: f.id,
                                    display: "Figure \(n) — \(f.title)",
                                    thumbnail: thumbnail(for: f)))
        }
        let tableNumbers = RefEngine.effectiveTableNumbers(in: m)
        for t in m.tables.sorted(by: { (tableNumbers[$0.id] ?? 0) < (tableNumbers[$1.id] ?? 0) }) {
            let n = tableNumbers[t.id] ?? t.number
            guard matches(["table \(n)", t.title, t.caption]) else { continue }
            out.append(RefCandidate(kind: .table, id: t.id, display: "Table \(n) — \(t.title)"))
        }
        return out
    }

    /// Stable ids for the letter snippet rows (never resolved as references).
    private static let dateSnippetID      = UUID(uuidString: "51674E00-0000-4000-8000-00000000000D")!
    private static let signatureSnippetID = UUID(uuidString: "51674E00-0000-4000-8000-00000000000E")!

    // MARK: - Zotero quick-cite ("/" menu)

    /// Zotero keys already in this version's bibliography — those items appear
    /// as normal "Ref •" rows, so the Zotero section only offers new ones.
    private func existingZoteroKeys() -> Set<String> {
        Set((store.manuscript(for: versionRef)?.bibliography ?? []).compactMap(\.zoteroKey))
    }

    /// Accepting a Zotero row: add the entry to the bibliography (no-op when
    /// its zoteroKey is already there) and return the entry id for the token.
    private func addZoteroEntry(_ item: ZoteroItem) -> UUID? {
        store.addBibEntry(ZoteroService().bibEntry(from: item), ref: versionRef)
        return store.manuscript(for: versionRef)?.bibliography.first { $0.zoteroKey == item.key }?.id
    }

    /// A small sample image of the figure for the insert menu.
    private static let thumbnailCache = NSCache<NSUUID, NSImage>()
    private func thumbnail(for figure: Figure) -> NSImage? {
        if let cached = Self.thumbnailCache.object(forKey: figure.id as NSUUID) { return cached }
        guard let url = store.figureURL(for: figure),
              let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(72 / size.width, 48 / size.height, 1)
        let thumb = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale))
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumb.size))
        thumb.unlockFocus()
        Self.thumbnailCache.setObject(thumb, forKey: figure.id as NSUUID)
        return thumb
    }
}

// MARK: - RefCandidate

/// One referencable item (bibliography entry, figure, or table) offered by
/// the "/" autocomplete.
struct RefCandidate {
    let kind: RefOccurrence.Kind
    let id: UUID
    /// String shown in the completion list ("Ref • Key — Title", "Figure 2 — …").
    let display: String
    /// Sample image shown in the insert-kind menu (figures only).
    var thumbnail: NSImage? = nil
    /// When set, accepting inserts this text directly — no reference token,
    /// no insert-kind menu.  Used by the letter's Date/Signature references.
    var snippetText: String? = nil
    /// When also set, the snippet text is inserted as a live letter token
    /// (marker text carrying this letter:// link), resolved on export.
    var tokenURL: URL? = nil
    /// A Zotero library item not yet in the bibliography: accepting adds it
    /// (via the editor's `addZoteroEntry`) and cites the new entry.
    var zoteroItem: ZoteroItem? = nil
}

// MARK: - FormatBar (inline toolbar)

private struct FormatBar: View {
    let controller: RichTextController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                button("bold", "Bold") { controller.toggleBold() }
                button("italic", "Italic") { controller.toggleItalic() }
                button("underline", "Underline") { controller.toggleUnderline() }
                button("strikethrough", "Strikethrough") { controller.toggleStrikethrough() }
                button("textformat.superscript", "Superscript") { controller.toggleSuperscript() }
                button("textformat.subscript", "Subscript") { controller.toggleSubscript() }

                Divider().frame(height: 18).padding(.horizontal, 4)

                button("text.alignleft", "Align left") { controller.align(.left) }
                button("text.aligncenter", "Center") { controller.align(.center) }
                button("text.alignright", "Align right") { controller.align(.right) }
                button("text.justify", "Justify") { controller.align(.justified) }

                Divider().frame(height: 18).padding(.horizontal, 4)

                button("list.bullet", "Bulleted list") { controller.toggleBulletList() }
            }
            .padding(.leading, EditorLayout.leftInset)   // align with the text column
            .padding(.trailing, 10)
            .padding(.vertical, 5)
        }
        .frame(height: 36)                                // pin height; a horizontal
                                                          // ScrollView otherwise grows
                                                          // vertically and overlaps the editor
        .background(.bar)
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - WidthRuler

/// A horizontal ruler with a draggable handle that sets the wrap column.
/// Its origin aligns with the first text glyph (`leftInset`).
private struct WidthRuler: View {
    @Binding var width: Double
    let leftInset: CGFloat

    private let minWidth: CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            let maxWidth = max(minWidth, geo.size.width - leftInset - 16)
            let clamped = min(max(CGFloat(width), minWidth), maxWidth)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var x = leftInset
                    var i = 0
                    while x <= leftInset + maxWidth {
                        let tall = (i % 5 == 0)
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x, y: size.height - (tall ? 9 : 5)))
                        context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
                        x += 50
                        i += 1
                    }
                }

                // Active span up to the handle.
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: clamped, height: 3)
                    .position(x: leftInset + clamped / 2, y: 17)

                // Drag handle.
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .position(x: leftInset + clamped, y: 8)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let proposed = drag.location.x - leftInset
                                width = Double(min(max(proposed, minWidth), maxWidth))
                            }
                    )
                    .help("Drag to set line width (\(Int(width)) pt)")
            }
        }
        .frame(height: 20)
    }
}

// MARK: - RichTextController

/// Bridges the SwiftUI toolbar to the focused NSTextView.
@MainActor
final class RichTextController {
    weak var textView: NSTextView?

    private func notifyChange() { textView?.didChangeText() }

    // MARK: Character styles

    func toggleBold()   { toggleFontTrait(.bold) }
    func toggleItalic() { toggleFontTrait(.italic) }

    private func toggleFontTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let mask: NSFontTraitMask = (trait == .bold) ? .boldFontMask : .italicFontMask
        let range = tv.selectedRange()
        let fallback = tv.font ?? .systemFont(ofSize: NSFont.systemFontSize)

        func hasTrait(_ font: NSFont) -> Bool { font.fontDescriptor.symbolicTraits.contains(trait) }

        if range.length == 0 {
            let current = (tv.typingAttributes[.font] as? NSFont) ?? fallback
            tv.typingAttributes[.font] = hasTrait(current)
                ? fm.convert(current, toNotHaveTrait: mask)
                : fm.convert(current, toHaveTrait: mask)
            return
        }

        var allHave = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            if !hasTrait((value as? NSFont) ?? fallback) { allHave = false }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = (value as? NSFont) ?? fallback
            let next = allHave ? fm.convert(font, toNotHaveTrait: mask)
                               : fm.convert(font, toHaveTrait: mask)
            storage.addAttribute(.font, value: next, range: sub)
        }
        storage.endEditing()
        notifyChange()
    }

    func toggleUnderline()     { toggleLineAttribute(.underlineStyle) }
    func toggleStrikethrough() { toggleLineAttribute(.strikethroughStyle) }

    private func toggleLineAttribute(_ key: NSAttributedString.Key) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let on = NSUnderlineStyle.single.rawValue

        if range.length == 0 {
            let current = (tv.typingAttributes[key] as? Int) ?? 0
            tv.typingAttributes[key] = current == 0 ? on : 0
            return
        }
        var allOn = true
        storage.enumerateAttribute(key, in: range) { value, _, _ in
            if ((value as? Int) ?? 0) == 0 { allOn = false }
        }
        storage.beginEditing()
        storage.addAttribute(key, value: allOn ? 0 : on, range: range)
        storage.endEditing()
        notifyChange()
    }

    func toggleSuperscript() { toggleSuperscript(1) }
    func toggleSubscript()   { toggleSuperscript(-1) }

    private func toggleSuperscript(_ value: Int) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            let current = (tv.typingAttributes[.superscript] as? Int) ?? 0
            tv.typingAttributes[.superscript] = (current == value) ? 0 : value
            return
        }
        var allMatch = true
        storage.enumerateAttribute(.superscript, in: range) { v, _, _ in
            if ((v as? Int) ?? 0) != value { allMatch = false }
        }
        storage.beginEditing()
        storage.addAttribute(.superscript, value: allMatch ? 0 : value, range: range)
        storage.endEditing()
        notifyChange()
    }

    // MARK: Paragraph styles

    func align(_ alignment: NSTextAlignment) {
        guard let tv = textView else { return }
        switch alignment {
        case .center:    tv.alignCenter(nil)
        case .right:     tv.alignRight(nil)
        case .justified: tv.alignJustified(nil)
        default:         tv.alignLeft(nil)
        }
        notifyChange()
    }

    /// Toggles a "•\t" bullet prefix on each selected paragraph.
    func toggleBulletList() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let nsString = storage.string as NSString
        let paragraphRange = nsString.paragraphRange(for: tv.selectedRange())
        let marker = "•\t"

        let lines = nsString.substring(with: paragraphRange).components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.isEmpty }
        let allBulleted = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(marker) }

        let rebuilt = lines.map { line -> String in
            guard !line.isEmpty else { return line }
            if allBulleted { return String(line.dropFirst(marker.count)) }
            return line.hasPrefix(marker) ? line : marker + line
        }.joined(separator: "\n")

        guard tv.shouldChangeText(in: paragraphRange, replacementString: rebuilt) else { return }
        storage.replaceCharacters(in: paragraphRange, with: rebuilt)
        tv.didChangeText()
    }
}

// MARK: - RichTextRepresentable

/// Hosts the AppKit text view (TextKit 1) inside SwiftUI.  Line numbers are
/// rendered by `LineNumberRulerView`, attached as the scroll view's vertical
/// ruler; the text wraps at a fixed column for a page-like layout.
private struct RichTextRepresentable: NSViewRepresentable {
    @Binding var value: RichText
    let controller: RichTextController
    let baseFont: NSFont
    let lineHeightMultiple: Double
    let wrapWidth: CGFloat
    /// Returns referencable items for a "/" query.
    let candidates: (String) -> [RefCandidate]
    /// Zotero keys already in the bibliography (their items are hidden from
    /// the menu's Zotero section — they show as "Ref •" rows instead).
    let zoteroKeys: () -> Set<String>
    /// Adds a Zotero item to the bibliography and returns the entry id.
    let addZoteroEntry: (ZoteroItem) -> UUID?
    /// Snapshot of numbering + entry details that token rendering depends on.
    let refContext: RefEngine.Context

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Explicit TextKit 1 stack.  On macOS 26 a default NSTextView uses
        // TextKit 2 (where `layoutManager` is nil); the line-number ruler needs
        // TextKit 1, which providing our own NSLayoutManager guarantees.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false        // fixed wrap column
        container.lineFragmentPadding = 5
        layoutManager.addTextContainer(container)

        let textView = CitationTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.refContext = refContext
        textView.addZoteroEntry = addZoteroEntry
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.font = baseFont
        textView.typingAttributes = context.coordinator.defaultAttributes(baseFont, lineHeightMultiple)
        textView.defaultTypingAttributes = context.coordinator.defaultAttributes(baseFont, lineHeightMultiple)
        textView.defaultParagraphStyle = context.coordinator.paragraphStyle(lineHeightMultiple)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: EditorLayout.textInset, height: 16)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // Line-number gutter.
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView, layoutManager: layoutManager)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.hasHorizontalRuler = false
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        controller.textView = textView
        context.coordinator.observeScrolling(in: scrollView, textView: textView)
        context.coordinator.load(value, into: textView, baseFont: baseFont, lineHeightMultiple: lineHeightMultiple)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        controller.textView = textView
        (textView as? CitationTextView)?.refContext = refContext
        (textView as? CitationTextView)?.addZoteroEntry = addZoteroEntry

        // Apply wrap-width changes.
        if let container = textView.textContainer, container.size.width != wrapWidth {
            container.size = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
            context.coordinator.ruler?.needsDisplay = true
        }

        // Reload only when the bound content differs from the on-screen text
        // (avoids clobbering the field while the user is typing).  A token
        // rewrite makes them differ until its async commit lands — never
        // reload over that.
        if value.plain != textView.string {
            guard !context.coordinator.hasPendingCommit else { return }
            context.coordinator.load(value, into: textView, baseFont: baseFont, lineHeightMultiple: lineHeightMultiple)
        } else if context.coordinator.lastRefSignature != refContext.signature {
            // Numbering or entry details changed elsewhere (another pane, the
            // bibliography, a paragraph swap…) — re-render this view's tokens.
            context.coordinator.refreshTokens(in: textView)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // The undo manager dies with the coordinator, but clear it eagerly so
        // nothing can pop an entry mid-teardown.
        coordinator.editorUndoManager.removeAllActions()
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextRepresentable
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        private var observers: [NSObjectProtocol] = []

        /// Signature of the `RefEngine.Context` the tokens were last rendered
        /// against — lets `updateNSView` skip the rewrite pass on the vast
        /// majority of renders (plain typing never changes it).
        var lastRefSignature: Int?
        /// True between a programmatic token rewrite and its async binding
        /// commit; guards the reload-from-binding path against clobbering.
        var hasPendingCommit = false

        /// Undo history scoped to this editor instance.  The text view
        /// registers its typing operations here (via `undoManager(for:)`)
        /// instead of the window's long-lived manager, so entries can never
        /// outlive the text view they target — the window manager's stale
        /// entries were crashing ⌘Z (issue #8).
        let editorUndoManager = UndoManager()

        init(_ parent: RichTextRepresentable) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }

        // MARK: Zotero quick-cite

        /// Fetched Zotero results per lowercased query.  Failures aren't
        /// cached (Zotero may launch mid-session); a backoff stops hammering
        /// a closed port on every keystroke.
        private var zoteroCache: [String: [ZoteroItem]] = [:]
        private var zoteroFetch: Task<Void, Never>?
        private var zoteroLastFailure: Date?

        /// Rows shown for a "/" query: local candidates (bibliography,
        /// figures, tables, letter snippets) plus a Zotero section of library
        /// items not yet in the bibliography.  Cold cache kicks a debounced
        /// fetch that refreshes the open list when results land.
        func combinedCandidates(_ query: String, for tv: CitationTextView) -> [RefCandidate] {
            var out = parent.candidates(query)
            let key = query.lowercased().trimmingCharacters(in: .whitespaces)
            if let items = zoteroCache[key] {
                let existing = parent.zoteroKeys()
                out += items.lazy.filter { !existing.contains($0.key) }.prefix(8).map { item in
                    let authors = item.creators.first.map { $0.formatted } ?? ""
                    let bits = [authors, item.date.isEmpty ? "" : "(\(item.date.prefix(4)))",
                                item.title.isEmpty ? "(no title)" : item.title]
                        .filter { !$0.isEmpty }
                    return RefCandidate(kind: .bib, id: UUID(),
                                        display: "Zotero • " + bits.joined(separator: " "),
                                        zoteroItem: item)
                }
            } else {
                scheduleZoteroFetch(key, for: tv)
            }
            return out
        }

        private func scheduleZoteroFetch(_ query: String, for tv: CitationTextView) {
            if let last = zoteroLastFailure, Date().timeIntervalSince(last) < 30 { return }
            zoteroFetch?.cancel()
            zoteroFetch = Task { @MainActor [weak self, weak tv] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                do {
                    let items = try await ZoteroService().fetchItems(matching: query, limit: 20)
                    guard let self, !Task.isCancelled else { return }
                    self.zoteroCache[query] = items
                    tv?.refreshCompletionIfActive(query: query)
                } catch {
                    self?.zoteroLastFailure = Date()
                }
            }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func paragraphStyle(_ multiple: Double) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = CGFloat(multiple)
            return style
        }

        func defaultAttributes(_ font: NSFont, _ multiple: Double) -> [NSAttributedString.Key: Any] {
            [.font: font,
             .foregroundColor: NSColor.labelColor,
             .paragraphStyle: paragraphStyle(multiple)]
        }

        /// Redraw the gutter (and drop any hover card) when the text view
        /// scrolls (its content view bounds change).
        func observeScrolling(in scrollView: NSScrollView, textView: NSTextView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main
            ) { [weak self, weak textView] _ in
                self?.ruler?.needsDisplay = true
                (textView as? CitationTextView)?.dismissHover()
            }
            observers.append(token)
        }

        /// Loads `value`: RTF when present, else plain text with default attributes.
        func load(_ value: RichText, into textView: NSTextView, baseFont: NSFont, lineHeightMultiple: Double) {
            guard let storage = textView.textStorage else { return }
            // A programmatic reload replaces the content wholesale (section
            // switch, external restore); undoing across it would replay old
            // operations against the new text's ranges.
            editorUndoManager.removeAllActions()
            if let rtf = value.rtf,
               let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                storage.setAttributedString(attributed)
            } else {
                storage.setAttributedString(
                    NSAttributedString(string: value.plain,
                                       attributes: defaultAttributes(baseFont, lineHeightMultiple))
                )
            }
            textView.typingAttributes = defaultAttributes(baseFont, lineHeightMultiple)
            (textView as? CitationTextView)?.defaultTypingAttributes = defaultAttributes(baseFont, lineHeightMultiple)
            // Re-render tokens against current numbering (RTF stores only the
            // text they displayed when last edited) and rebuild tooltips,
            // which RTF doesn't preserve at all.
            refreshTokens(in: textView)
            ruler?.needsDisplay = true
        }

        /// Rewrites every reference token whose visible text or tooltip is out
        /// of date (numbering shifted, entry edited, style upgraded from the
        /// legacy `{Key}` form), then commits the result to the binding.
        func refreshTokens(in textView: NSTextView) {
            lastRefSignature = parent.refContext.signature
            guard let storage = textView.textStorage else { return }
            let updates = RefEngine.plannedUpdates(in: storage, context: parent.refContext)
            guard !updates.isEmpty else { return }

            var selection = textView.selectedRange()
            storage.beginEditing()
            // Back-to-front so earlier ranges stay valid.
            for u in updates.sorted(by: { $0.range.location > $1.range.location }) {
                if u.textChanged {
                    var attrs = storage.attributes(at: u.range.location, effectiveRange: nil)
                    attrs[.link] = u.url
                    attrs[.toolTip] = u.tooltip
                    storage.replaceCharacters(in: u.range,
                                              with: NSAttributedString(string: u.text, attributes: attrs))
                    // Keep the caret logically in place across the length change.
                    let newLength = (u.text as NSString).length
                    if selection.location >= NSMaxRange(u.range) {
                        selection.location += newLength - u.range.length
                    } else if selection.location > u.range.location {
                        selection.location = u.range.location + newLength
                    }
                } else if let tip = u.tooltip {
                    storage.addAttribute(.toolTip, value: tip, range: u.range)
                } else {
                    storage.removeAttribute(.toolTip, range: u.range)
                }
            }
            storage.endEditing()
            textView.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
            scheduleCommit(textView)
        }

        /// Pushes the text view's content into the binding on the next runloop
        /// tick (a rewrite can happen inside a SwiftUI update, where mutating
        /// the binding synchronously is illegal).
        private func scheduleCommit(_ textView: NSTextView) {
            hasPendingCommit = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.hasPendingCommit = false
                guard let tv = textView else { return }
                self.pushValue(from: tv)
            }
        }

        /// Pending pause-detection for undo chunking.
        private var coalescingBreakTask: Task<Void, Never>?

        /// AppKit merges an unbroken typing run into ONE "Undo Typing" entry;
        /// without an explicit break, ⌘Z after a long burst reverts all of it.
        /// Breaking on a pause turns each burst into its own undo step.
        private func scheduleCoalescingBreak(_ textView: NSTextView) {
            coalescingBreakTask?.cancel()
            coalescingBreakTask = Task { @MainActor [weak textView] in
                try? await Task.sleep(for: UndoTuning.typingChunkPause)
                guard !Task.isCancelled else { return }
                textView?.breakUndoCoalescing()
            }
        }

        /// The single place the binding learns about text-view content: plain
        /// mirror, RTF archive, and the extracted reference-token list.
        func pushValue(from textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let rtf = storage.rtf(from: full, documentAttributes: [:])
            parent.value = RichText(plain: storage.string, rtf: rtf,
                                    refs: RefEngine.scanRefs(in: storage))
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            hasPendingCommit = false     // superseded by this direct edit
            pushValue(from: textView)
            ruler?.needsDisplay = true
            scheduleCoalescingBreak(textView)

            // Reference autocomplete: while the caret sits in a "/query",
            // (re)open the native completion list so it live-filters as you
            // type — but only when something actually matches, so a stray "/"
            // in prose doesn't pop an empty menu.  An Escape-dismissed query
            // stays closed (the "/" is just text) until Tab re-opens it.
            if let tv = textView as? CitationTextView,
               !tv.isHandlingCompletion,
               let range = tv.refQueryRange(),
               tv.allowsAutoComplete(at: range.location) {
                let ns = textView.string as NSString
                let query = ns.substring(with: NSRange(location: range.location + 1,
                                                       length: range.length - 1))
                if !combinedCandidates(query, for: tv).isEmpty {
                    tv.complete(nil)
                }
            }
        }

        /// Keep tokens closed: when the caret lands right after one, NSTextView
        /// adopts its attributes for typing — strip them so new text is normal.
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? CitationTextView)?.sanitizeTypingAttributes()
        }

        // MARK: Reference completion (NSTextViewDelegate)

        /// Supplies the completion list for a "/" session: bibliography
        /// entries, figures, and tables matching the typed query.
        func textView(_ textView: NSTextView,
                      completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let tv = textView as? CitationTextView else { return words }
            let ns = textView.string as NSString
            guard charRange.length >= 1,
                  charRange.location < ns.length,
                  ns.substring(with: NSRange(location: charRange.location, length: 1)) == "/"
            else { return words }
            let query = ns.substring(with: NSRange(location: charRange.location + 1,
                                                   length: charRange.length - 1))
            let candidates = combinedCandidates(query, for: tv)
            tv.currentCandidates = candidates
            index?.pointee = candidates.isEmpty ? -1 : 0   // top match ready for Tab/Return
            return candidates.map(\.display)
        }

        /// Clicking a token opens its menu (citation style, remove) instead of
        /// following the link.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            // Letter tokens (⟦Date⟧/⟦Signature⟧) are markers, not links —
            // consume the click so AppKit doesn't try to open letter://.
            if url.scheme == "letter" { return true }
            guard let token = RefEngine.Token.parse(url) else { return false }
            (textView as? CitationTextView)?.showTokenMenu(for: token, at: charIndex)
            return true
        }
    }
}

// MARK: - CitationTextView

/// NSTextView subclass that turns "/" into a live reference autocomplete.
///
/// Typing "/" (at a word boundary) opens the native completion list of
/// bibliography entries, figures, and tables (see the Coordinator's
/// `textView(_:completions:...)`); accepting with Return/Tab (or double-click)
/// replaces the partial "/query" with a formatted token — "[1]",
/// "(Smith et al., 2024)", "Figure 2", … — carrying an identity link
/// (cite:// / figref:// / tabref://) and a hover tooltip.  Dismissing restores
/// exactly what the user had typed.  Clicking a token opens a menu to switch
/// its citation style or remove it.
final class CitationTextView: NSTextView {

    /// Candidates backing the currently displayed completion list.
    var currentCandidates: [RefCandidate] = []

    /// Current numbering + entry details, refreshed by `updateNSView`.
    var refContext = RefEngine.Context()

    /// The editor's normal typing attributes — restored after inserting a
    /// token so continued typing isn't linked to it.
    var defaultTypingAttributes: [NSAttributedString.Key: Any] = [:]

    /// True while a completion session is being processed; used to stop
    /// `textDidChange` from re-triggering `complete(nil)` recursively.
    private(set) var isHandlingCompletion = false

    /// Adds a Zotero item to the bibliography and returns the entry id —
    /// wired by the representable (the store lives up in SwiftUI).
    var addZoteroEntry: ((ZoteroItem) -> UUID?)?

    /// "/" location the user dismissed with Escape.  While set, typing in
    /// that query doesn't re-open the list — the "/" reads as normal text
    /// (issue #14).  Cleared when the caret leaves the query or Tab re-opens.
    var suppressedSlashLocation: Int?

    /// Whether the auto-complete may (re)open for the query at `location`.
    /// A different location is a new "/" session, which also clears an old
    /// suppression.
    func allowsAutoComplete(at location: Int) -> Bool {
        if suppressedSlashLocation == location { return false }
        suppressedSlashLocation = nil
        return true
    }

    /// Re-opens the list after an async (Zotero) result lands, but only if
    /// the caret still sits in the same query and it wasn't Escape-dismissed.
    func refreshCompletionIfActive(query: String) {
        guard let range = refQueryRange(), allowsAutoComplete(at: range.location) else { return }
        let ns = string as NSString
        let current = ns.substring(with: NSRange(location: range.location + 1,
                                                 length: range.length - 1))
        guard current.lowercased().trimmingCharacters(in: .whitespaces) == query else { return }
        complete(nil)
    }

    /// Tab inside a "/query" opens (or re-opens after Escape) the reference
    /// list — arrows then navigate it.  Elsewhere Tab stays a tab.
    override func insertTab(_ sender: Any?) {
        if refQueryRange() != nil {
            suppressedSlashLocation = nil
            complete(nil)
            return
        }
        super.insertTab(sender)
    }

    /// Token the context menu is currently acting on.
    private var menuToken: (token: RefEngine.Token, range: NSRange)?

    /// Hover details card state (see "Hover details" below).
    private var hoverPopover: NSPopover?
    private var hoverTarget: UUID?
    private var hoverWork: DispatchWorkItem?
    private var hoverTrackingArea: NSTrackingArea?

    /// The "/…caret" range of an in-progress reference query, or nil when the
    /// caret isn't in one.  The "/" must sit at a word boundary (start of the
    /// text or after whitespace) so "and/or", dates, and URLs don't trigger;
    /// the query may contain spaces (titles) but stops at a newline and is
    /// capped so a stray "/" can't swallow a whole paragraph.
    func refQueryRange() -> NSRange? {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret <= ns.length, caret > 0 else { return nil }
        var i = caret - 1
        var scanned = 0
        while i >= 0 && scanned <= 60 {
            let ch = ns.character(at: i)
            if ch == 0x2F {                                            // "/"
                let atBoundary = i == 0 || isSpace(ns.character(at: i - 1))
                guard atBoundary else { return nil }
                // A query can't *start* with whitespace ("/ " is prose).
                if caret > i + 1, isSpace(ns.character(at: i + 1)) { return nil }
                return NSRange(location: i, length: caret - i)
            }
            if ch == 0x0A { return nil }                               // newline
            i -= 1
            scanned += 1
        }
        return nil
    }

    private func isSpace(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x0A || ch == 0x09 || ch == 0xA0
    }

    override var rangeForUserCompletion: NSRange {
        refQueryRange() ?? super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String,
                                   forPartialWordRange charRange: NSRange,
                                   movement: Int,
                                   isFinal flag: Bool) {
        let ns = string as NSString
        let isRefSession = charRange.length >= 1
            && charRange.location < ns.length
            && ns.substring(with: NSRange(location: charRange.location, length: 1)) == "/"
        guard isRefSession else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
            return
        }

        isHandlingCompletion = true
        defer { isHandlingCompletion = false }

        // While arrowing through the list (isFinal == false) do nothing: the
        // default behavior would paste the long display string into the text
        // as a preview — and once it has, the "/" test above can no longer
        // recognize the session on the accepting call.  The "/query" stays
        // visible until a definitive choice is made (Xcode-style).
        guard flag else { return }

        // Accept on Return, Tab, or a click on a list item (`.other`);
        // Escape / focus loss arrive as `.cancel` and leave the text as typed.
        let accepted: Bool
        switch NSTextMovement(rawValue: movement) {
        case .return, .tab, .other: accepted = true
        default:                    accepted = false
        }

        // Escape leaves the "/query" as typed AND remembers it, so continued
        // typing doesn't re-pop the list — the "/" is just prose now (#14).
        if NSTextMovement(rawValue: movement) == .cancel {
            suppressedSlashLocation = charRange.location
        }

        if accepted, let candidate = currentCandidates.first(where: { $0.display == word }) {
            // A Zotero row: add the entry to the bibliography (deduped by
            // zoteroKey in the store), then cite it like any bib entry.
            if let item = candidate.zoteroItem {
                if let id = addZoteroEntry?(item) {
                    insertToken(RefEngine.Token(kind: .bib, targetID: id, style: .numeric),
                                replacing: charRange)
                }
                return
            }
            // Letter references insert a live token; plain snippets paste text.
            if let snippet = candidate.snippetText {
                if let url = candidate.tokenURL {
                    insertLetterToken(snippet, url: url, replacing: charRange)
                } else {
                    insertPlainText(snippet, replacing: charRange)
                }
                return
            }
            switch candidate.kind {
            case .bib:
                let token = RefEngine.Token(kind: .bib, targetID: candidate.id, style: .numeric)
                insertToken(token, replacing: charRange)
            default:
                // Figures/tables: one dropdown row, then a caret menu chooses
                // Reference vs Placement.  Deferred a tick so the completion
                // window finishes tearing down first.
                DispatchQueue.main.async { [weak self] in
                    self?.showInsertKindMenu(for: candidate, replacing: charRange)
                }
            }
        }
        // Dismissed — nothing to restore; the text was never touched.
    }

    /// Replaces `range` (the "/query") with a letter token: marker text
    /// carrying a letter:// link that preview/export resolve (date, drawn
    /// signature).  Typing continues in normal attributes.
    private func insertLetterToken(_ marker: String, url: URL, replacing range: NSRange) {
        guard shouldChangeText(in: range, replacementString: marker) else { return }
        var attrs = defaultTypingAttributes
        attrs[.link] = url
        attrs[.toolTip] = "Resolved on export"
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: marker, attributes: attrs))
        setSelectedRange(NSRange(location: range.location + (marker as NSString).length, length: 0))
        typingAttributes = defaultTypingAttributes
        didChangeText()
    }

    /// Replaces `range` (the "/query") with plain text in the editor's
    /// default typing attributes — used by the letter's snippet candidates.
    private func insertPlainText(_ text: String, replacing range: NSRange) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(
            in: range,
            with: NSAttributedString(string: text, attributes: defaultTypingAttributes))
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        typingAttributes = defaultTypingAttributes
        didChangeText()
    }

    /// The candidate + range awaiting a Reference/Placement choice.
    private var pendingInsert: (candidate: RefCandidate, range: NSRange)?

    /// Pops a two-choice menu at the caret: insert a cross-reference token, or
    /// a placement marker (the figure/table renders there on export).  Figures
    /// show a sample image.  Esc/click-away cancels, leaving the typed text.
    private func showInsertKindMenu(for candidate: RefCandidate, replacing range: NSRange) {
        pendingInsert = (candidate, range)
        let isFigure = candidate.kind == .figure
        let noun = isFigure ? "Figure" : "Table"

        let menu = NSMenu()
        if let thumb = candidate.thumbnail {
            let preview = NSMenuItem(title: candidate.display, action: nil, keyEquivalent: "")
            preview.image = thumb
            preview.isEnabled = false
            menu.addItem(preview)
            menu.addItem(.separator())
        }
        let reference = NSMenuItem(title: "Insert Reference (\(candidate.display))",
                                   action: #selector(insertPendingReference), keyEquivalent: "")
        reference.target = self
        menu.addItem(reference)
        let placement = NSMenuItem(title: "Place \(noun) Here (renders on export)",
                                   action: #selector(insertPendingPlacement), keyEquivalent: "")
        placement.target = self
        menu.addItem(placement)

        // Anchor at the caret.
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        let windowPoint = window?.convertPoint(fromScreen: screenRect.origin) ?? .zero
        let local = convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: local.x, y: local.y), in: self)
    }

    @objc private func insertPendingReference() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        let kind: RefOccurrence.Kind = pending.candidate.kind == .figure ? .figure : .table
        insertToken(RefEngine.Token(kind: kind, targetID: pending.candidate.id, style: .numeric),
                    replacing: pending.range)
    }

    @objc private func insertPendingPlacement() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        let kind: RefOccurrence.Kind = pending.candidate.kind == .figure ? .figurePlacement : .tablePlacement
        insertToken(RefEngine.Token(kind: kind, targetID: pending.candidate.id, style: .numeric),
                    replacing: pending.range)
    }

    /// Replaces `range` with a rendered token: identity link + tooltip in the
    /// editor's **default** format — tokens read as normal prose, not bold;
    /// their identity lives in the link attribute, not in styling.
    /// A first-time citation shows the next free number; the store-driven
    /// rewrite pass corrects it if document order says otherwise.
    private func insertToken(_ token: RefEngine.Token, replacing range: NSRange) {
        let text = RefEngine.displayText(for: token, context: refContext)
        var attrs = defaultTypingAttributes
        // Inherit the surrounding line's paragraph style and font so the
        // insertion never changes the line's spacing (no gap above/below).
        if let storage = textStorage, storage.length > 0 {
            let anchor = min(max(range.location - 1, 0), storage.length - 1)
            let inherited = storage.attributes(at: anchor, effectiveRange: nil)
            if let style = inherited[.paragraphStyle] { attrs[.paragraphStyle] = style }
            if let font = inherited[.font] as? NSFont,
               RefEngine.Token.parse((inherited[.link] as? URL) ?? URL(fileURLWithPath: "/")) == nil {
                attrs[.font] = font
            }
        }
        if let url = token.url { attrs[.link] = url }
        if let tip = RefEngine.tooltip(for: token, context: refContext) { attrs[.toolTip] = tip }

        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
        // Restore normal typing style and park the caret after the token.
        typingAttributes = defaultTypingAttributes
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        didChangeText()
    }

    /// Typing next to a token must not extend it: strip our token attributes
    /// (link, tooltip, bold affordance) from the typing attributes whenever
    /// the caret moves.
    func sanitizeTypingAttributes() {
        guard let url = typingAttributes[.link] as? URL, RefEngine.Token.parse(url) != nil else { return }
        typingAttributes = defaultTypingAttributes
    }

    // MARK: Token details (shared by the hover card and the click menu)

    /// "Key · cited as [n]" (or "Figure 2 — Title") in bold, with the full
    /// reference / caption below in secondary color.
    private func tokenDetails(for token: RefEngine.Token) -> NSAttributedString {
        var title = ""
        var body = ""
        switch token.kind {
        case .bib:
            if let info = refContext.bib[token.targetID] {
                let number = refContext.numbers[token.targetID]
                title = ([info.key.isEmpty ? "Reference" : info.key]
                         + (number.map { ["cited as [\($0)]"] } ?? [])).joined(separator: "  ·  ")
                body = info.tooltip
            } else {
                title = "Reference not found"
                body = "This entry was removed from the bibliography."
            }
        case .figure, .table, .figurePlacement, .tablePlacement:
            let isFigure = token.kind == .figure || token.kind == .figurePlacement
            let noun = isFigure ? "Figure" : "Table"
            let tip = isFigure
                ? refContext.figures[token.targetID]?.tooltip
                : refContext.tables[token.targetID]?.tooltip
            if let tip {
                // Tooltip format is "Figure N — Title\nCaption".
                let parts = tip.split(separator: "\n", maxSplits: 1).map(String.init)
                title = parts.first ?? tip
                body = parts.count > 1 ? parts[1] : ""
            } else {
                title = "\(noun) not found"
                body = "This \(noun.lowercased()) was removed from the manuscript."
            }
        }
        let out = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.labelColor])
        if !body.isEmpty {
            out.append(NSAttributedString(
                string: "\n" + body,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }

    /// A padded, width-capped wrapping label for menu headers / hover cards.
    private func detailsView(for token: RefEngine.Token, width: CGFloat) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = tokenDetails(for: token)
        label.isSelectable = false
        let height = ceil(label.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 20)
        label.frame = NSRect(x: 14, y: 8, width: width, height: height)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + 28, height: height + 16))
        container.addSubview(label)
        return container
    }

    // MARK: Token menu (click a token)

    /// Menu for the token at `charIndex`: the reference's details on top, then
    /// citation styles (bib tokens) and removal.  Anchored to the click.
    func showTokenMenu(for token: RefEngine.Token, at charIndex: Int) {
        guard let storage = textStorage else { return }
        var effective = NSRange()
        guard storage.attribute(.link, at: charIndex, longestEffectiveRange: &effective,
                                in: NSRange(location: 0, length: storage.length)) != nil else { return }
        menuToken = (token, effective)
        dismissHover()

        let menu = NSMenu()

        // Details header: which reference this token points to.
        let header = NSMenuItem()
        header.view = detailsView(for: token, width: 300)
        menu.addItem(header)
        menu.addItem(.separator())

        if token.kind == .bib {
            menu.addItem(NSMenuItem.sectionHeader(title: "Citation Format"))
            let number = refContext.numbers[token.targetID] ?? refContext.nextNumber
            let info = refContext.bib[token.targetID]
            for (i, style) in RefEngine.CitationStyle.allCases.enumerated() {
                let item = NSMenuItem(title: style.menuLabel(number: number, info: info),
                                      action: #selector(applyCitationStyle(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.state = (style == token.style) ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let remove = NSMenuItem(title: token.kind == .bib ? "Remove Citation" : "Remove Reference",
                                action: #selector(removeToken(_:)), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    @objc private func applyCitationStyle(_ sender: NSMenuItem) {
        guard let (token, range) = menuToken,
              RefEngine.CitationStyle.allCases.indices.contains(sender.tag) else { return }
        menuToken = nil
        let restyled = RefEngine.Token(kind: token.kind, targetID: token.targetID,
                                       style: RefEngine.CitationStyle.allCases[sender.tag])
        insertToken(restyled, replacing: range)
    }

    @objc private func removeToken(_ sender: NSMenuItem) {
        guard let (_, range) = menuToken else { return }
        menuToken = nil
        guard shouldChangeText(in: range, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: range, with: "")
        typingAttributes = defaultTypingAttributes
        didChangeText()
    }

    // MARK: Pasting

    // The editor keeps ONE base format (final typography is chosen in Export),
    // so ⌘V must not import the source's fonts/sizes/colors.  Pasted text is
    // re-set in the editor's default style, keeping only inline emphasis
    // (bold/italic/underline/strikethrough/super- and subscript) — and our own
    // reference tokens when pasting text copied from another section.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let source: NSAttributedString?
        if let attributed = pb.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString {
            source = attributed
        } else if let plain = pb.string(forType: .string) {
            source = NSAttributedString(string: plain)
        } else {
            source = nil
        }
        guard let source, source.length > 0 else { return }

        let normalized = normalizedForPaste(source)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: normalized.string) else { return }
        textStorage?.replaceCharacters(in: range, with: normalized)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + normalized.length, length: 0))
        typingAttributes = defaultTypingAttributes
    }

    /// Re-sets `source` in the editor's default typing attributes, carrying
    /// over only emphasis attributes and reference-token links.
    private func normalizedForPaste(_ source: NSAttributedString) -> NSAttributedString {
        let base = defaultTypingAttributes
        let baseFont = (base[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 13)
        let out = NSMutableAttributedString(string: source.string, attributes: base)
        let fm = NSFontManager.shared

        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
            if let f = attrs[.font] as? NSFont {
                let traits = f.fontDescriptor.symbolicTraits
                var font = baseFont
                if traits.contains(.bold)   { font = fm.convert(font, toHaveTrait: .boldFontMask) }
                if traits.contains(.italic) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
                if font != baseFont { out.addAttribute(.font, value: font, range: range) }
            }
            if let underline = attrs[.underlineStyle] {
                out.addAttribute(.underlineStyle, value: underline, range: range)
            }
            if let strike = attrs[.strikethroughStyle] {
                out.addAttribute(.strikethroughStyle, value: strike, range: range)
            }
            if let script = attrs[.superscript] {
                out.addAttribute(.superscript, value: script, range: range)
            }
            // Keep our own reference tokens (cite:// / figref:// / tabref://).
            if let link = attrs[.link] as? URL, RefEngine.Token.parse(link) != nil {
                out.addAttribute(.link, value: link, range: range)
                if let tip = attrs[.toolTip] {
                    out.addAttribute(.toolTip, value: tip, range: range)
                }
            }
        }

        // Drop attachment placeholders (images/tables from the source).
        out.mutableString.replaceOccurrences(
            of: "\u{FFFC}", with: "",
            range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: Hover details

    // The `.toolTip` attribute works but takes seconds to appear and is easy
    // to miss; hovering a token shows a details card (key, citation number,
    // full reference — or figure/table title + caption) after a short delay.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)     // keep I-beam / link cursor behavior
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        dismissHover()
    }

    override func didChangeText() {
        super.didChangeText()
        dismissHover()
    }

    /// Shows/updates the details card when the pointer sits on a token; hides
    /// it otherwise.
    private func handleHover(at point: NSPoint) {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { dismissHover(); return }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        // glyphIndex(for:) returns the *nearest* glyph — require an actual hit.
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                                   in: textContainer)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { dismissHover(); return }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        var effective = NSRange()
        guard charIndex < storage.length,
              let url = storage.attribute(.link, at: charIndex, longestEffectiveRange: &effective,
                                          in: NSRange(location: 0, length: storage.length)) as? URL,
              let token = RefEngine.Token.parse(url)
        else { dismissHover(); return }

        guard hoverTarget != token.targetID else { return }   // shown or pending
        dismissHover()
        hoverTarget = token.targetID
        let work = DispatchWorkItem { [weak self] in
            self?.showHoverCard(for: token, tokenRange: effective)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func showHoverCard(for token: RefEngine.Token, tokenRange: NSRange) {
        guard let layoutManager, let textContainer, window?.isKeyWindow == true else { return }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        let controller = NSViewController()
        controller.view = detailsView(for: token, width: 340)
        popover.contentViewController = controller

        let glyphRange = layoutManager.glyphRange(forCharacterRange: tokenRange, actualCharacterRange: nil)
        var anchor = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        anchor.origin.x += textContainerInset.width
        anchor.origin.y += textContainerInset.height
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        hoverPopover = popover
    }

    /// Closes the card and cancels any pending show.
    func dismissHover() {
        hoverWork?.cancel()
        hoverWork = nil
        hoverTarget = nil
        hoverPopover?.close()
        hoverPopover = nil
    }
}

// MARK: - LineNumberRulerView

/// The line-number gutter, drawn as the scroll view's vertical ruler.
///
/// Numbers every *visual* line (wrapped lines included).  A 1-pt strip of the
/// editor background is painted over the ruler's right edge so AppKit's default
/// separator hairline doesn't read as a border beside the text.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private weak var layoutManager: NSLayoutManager?

    init(scrollView: NSScrollView, textView: NSTextView, layoutManager: NSLayoutManager) {
        self.textView = textView
        self.layoutManager = layoutManager
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = EditorLayout.gutterWidth
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
         .foregroundColor: NSColor.secondaryLabelColor]
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager,
              let container = textView.textContainer else { return }

        let insetHeight = textView.textContainerInset.height
        let relativeY = convert(NSPoint.zero, from: textView).y

        guard textView.string.isEmpty == false else {
            drawNumber(1, atY: insetHeight + relativeY, lineHeight: layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)))
            return
        }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)

        // Starting number: count visual lines before the visible region.
        var lineNumber = 1
        if visibleGlyphRange.location > 0 {
            layoutManager.enumerateLineFragments(
                forGlyphRange: NSRange(location: 0, length: visibleGlyphRange.location)
            ) { _, _, _, _, _ in lineNumber += 1 }
        }

        // Use the *used* rect (the actual glyph bounds) rather than the full
        // fragment, so the number lines up with the text and not the extra
        // line-spacing gap.
        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { _, usedRect, _, _, _ in
            self.drawNumber(lineNumber, atY: usedRect.minY + insetHeight + relativeY, lineHeight: usedRect.height)
            lineNumber += 1
        }
    }

    /// Draws the number right-aligned in the gutter, vertically centred within
    /// the line so it lines up with the text on that row.
    private func drawNumber(_ number: Int, atY y: CGFloat, lineHeight: CGFloat) {
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: labelAttributes)
        let centeredY = y + (lineHeight - size.height) / 2
        label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: centeredY), withAttributes: labelAttributes)
    }
}

// MARK: - EditorTypography → NSFont

extension EditorTypography {
    /// The AppKit font matching the user's editor font + size preference.
    var nsFont: NSFont {
        switch family {
        case "Mono":
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case "Serif":
            let base = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
            if let serif = base.withDesign(.serif) {
                return NSFont(descriptor: serif, size: size) ?? .systemFont(ofSize: size)
            }
            return .systemFont(ofSize: size)
        default:
            return .systemFont(ofSize: size)
        }
    }
}
