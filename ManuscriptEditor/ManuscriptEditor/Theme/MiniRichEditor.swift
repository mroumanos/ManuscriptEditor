// MiniRichEditor.swift
//
// A compact rich-text box for captions: character-level bold / italic /
// underline and paragraph alignment via the STANDARD AppKit key equivalents
// (⌘B, ⌘I, ⌘U, and ⌘{ / ⌘| / ⌘} for alignment) — NSTextView provides them
// natively when rich text is on, so there is no toolbar to carry.  Persists
// as `RichText` (RTF + plain mirror), like the prose editors.

import SwiftUI
import AppKit

struct MiniRichEditor: NSViewRepresentable {
    @Binding var value: RichText
    var fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let text = NSTextView()
        text.isRichText = true
        text.usesFontPanel = true
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.font = .systemFont(ofSize: fontSize)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 2, height: 4)
        text.autoresizingMask = [.width]
        text.delegate = context.coordinator
        scroll.documentView = text

        context.coordinator.load(value, into: text, fontSize: fontSize)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.binding = $value
        // External change only (our own edits arrive back equal).
        if value.plain != text.string, !context.coordinator.editing {
            context.coordinator.load(value, into: text, fontSize: fontSize)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $value) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<RichText>
        var editing = false

        init(binding: Binding<RichText>) { self.binding = binding }

        func load(_ value: RichText, into text: NSTextView, fontSize: CGFloat) {
            if let rtf = value.rtf,
               let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                text.textStorage?.setAttributedString(attributed)
            } else {
                text.textStorage?.setAttributedString(NSAttributedString(
                    string: value.plain,
                    attributes: [.font: NSFont.systemFont(ofSize: fontSize),
                                 .foregroundColor: NSColor.labelColor]))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView,
                  let storage = text.textStorage else { return }
            editing = true
            defer { editing = false }
            let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length),
                                  documentAttributes: [:])
            binding.wrappedValue = RichText(plain: storage.string, rtf: rtf,
                                            refs: binding.wrappedValue.refs)
        }
    }
}
