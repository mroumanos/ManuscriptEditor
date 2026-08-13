// PlainTextEditor.swift
//
// Drop-in replacement for SwiftUI's `TextEditor` in form fields (table
// content/captions, figure captions, bibliography authors/notes, letter
// header slots, SQL).
//
// Why not `TextEditor`: its backing NSTextView registers undo operations in
// the *window's* undo manager, which outlives the view. When SwiftUI destroys
// that text view (row deleted, selection switch, identity churn from the
// per-keystroke draft→store commits), the entries keep an unretained pointer
// to the dead view and ⌘Z crashes in -[_NSUndoStack popAndInvoke]
// (issue #8, Jim's crash report). Here the undo manager is owned by the
// coordinator, so typing history can never outlive the view it edits — and
// the window's manager stays clean for document-level (store) undo.

import SwiftUI
import AppKit

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .preferredFont(forTextStyle: .callout)
    var textColor: NSColor = .labelColor
    var insertionColor: NSColor?
    var alignment: NSTextAlignment = .natural
    /// Smart quotes/dashes and autocorrect — keep off for data-ish fields
    /// (Markdown pipe tables, SQL) where substitutions corrupt the syntax.
    var smartSubstitutions: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = textColor
        if let insertionColor { textView.insertionPointColor = insertionColor }
        textView.alignment = alignment
        textView.isAutomaticQuoteSubstitutionEnabled = smartSubstitutions
        textView.isAutomaticDashSubstitutionEnabled = smartSubstitutions
        textView.isAutomaticSpellingCorrectionEnabled = smartSubstitutions
        textView.isAutomaticTextReplacementEnabled = smartSubstitutions
        textView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            // External change (row switch, programmatic edit): replace the text
            // and drop the undo history — stale entries would otherwise replay
            // against the new value's ranges.
            textView.string = text
            textView.font = font
            textView.alignment = alignment
            context.coordinator.scopedUndoManager.removeAllActions()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.scopedUndoManager.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        /// Scoped to this editor: entries die with the view, so ⌘Z can never
        /// dispatch into a deallocated text view.
        let scopedUndoManager = UndoManager()

        init(_ parent: PlainTextEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { scopedUndoManager }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
