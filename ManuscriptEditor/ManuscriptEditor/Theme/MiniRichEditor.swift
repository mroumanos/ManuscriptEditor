// MiniRichEditor.swift
//
// A compact rich-text box for captions: character-level bold / italic /
// underline and paragraph alignment, with a visible mini toolbar AND the
// standard hotkeys (⌘B/⌘I/⌘U, ⌘E center) handled by the text view itself.
//
// The key equivalents are intercepted in `performKeyEquivalent` — the app
// has no Format menu to route them, and the responder chain runs BEFORE
// SwiftUI's scene-wide keyboard shortcuts, so a focused caption keeps ⌘B
// for itself instead of triggering a toolbar button elsewhere (the table
// grid's, for instance).  Persists as `RichText` (RTF + plain mirror).

import SwiftUI
import AppKit

// MARK: - CaptionRichBox (toolbar + editor)

/// The caption editing box both figures and tables embed: B/I/U + alignment
/// buttons over the rich text area.
struct CaptionRichBox: View {
    @Binding var value: RichText

    @State private var controller = MiniRichController()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                button("bold", "Bold (⌘B)") { controller.toggleTrait(.bold) }
                button("italic", "Italic (⌘I)") { controller.toggleTrait(.italic) }
                button("underline", "Underline (⌘U)") { controller.toggleUnderline() }
                Divider().frame(height: 14).padding(.horizontal, 2)
                button("text.alignleft", "Align left") { controller.align(.left) }
                button("text.aligncenter", "Center (⌘E)") { controller.align(.center) }
                button("text.alignright", "Align right") { controller.align(.right) }
                Spacer()
                Text("⌘B ⌘I ⌘U · ⌘E center")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            MiniRichEditor(value: $value, controller: controller)
                .frame(minHeight: 56)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25)))
        }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - MiniRichController

/// Bridges the toolbar to the focused caption text view.
@MainActor
final class MiniRichController {
    weak var textView: NSTextView?

    func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let mask: NSFontTraitMask = trait == .bold ? .boldFontMask : .italicFontMask
        let range = tv.selectedRange()
        let fallback = tv.font ?? .systemFont(ofSize: 12)
        func has(_ font: NSFont) -> Bool { font.fontDescriptor.symbolicTraits.contains(trait) }

        if range.length == 0 {
            let current = (tv.typingAttributes[.font] as? NSFont) ?? fallback
            tv.typingAttributes[.font] = has(current)
                ? fm.convert(current, toNotHaveTrait: mask)
                : fm.convert(current, toHaveTrait: mask)
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            if !has((value as? NSFont) ?? fallback) { allHave = false }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = (value as? NSFont) ?? fallback
            storage.addAttribute(.font, value: allHave
                ? fm.convert(font, toNotHaveTrait: mask)
                : fm.convert(font, toHaveTrait: mask), range: sub)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    func toggleUnderline() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let on = NSUnderlineStyle.single.rawValue
        if range.length == 0 {
            let current = (tv.typingAttributes[.underlineStyle] as? Int) ?? 0
            tv.typingAttributes[.underlineStyle] = current == 0 ? on : 0
            return
        }
        var allOn = true
        storage.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            if ((value as? Int) ?? 0) == 0 { allOn = false }
        }
        storage.beginEditing()
        storage.addAttribute(.underlineStyle, value: allOn ? 0 : on, range: range)
        storage.endEditing()
        tv.didChangeText()
    }

    func align(_ alignment: NSTextAlignment) {
        guard let tv = textView else { return }
        switch alignment {
        case .center: tv.alignCenter(nil)
        case .right:  tv.alignRight(nil)
        default:      tv.alignLeft(nil)
        }
        tv.didChangeText()
    }

    /// ⌘E: center on/off for the current paragraph.
    func toggleCenter() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let para = (tv.textStorage?.length ?? 0) > 0 && range.location < (tv.textStorage?.length ?? 0)
            ? tv.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            : tv.defaultParagraphStyle
        align(para?.alignment == .center ? .left : .center)
    }
}

// MARK: - MiniRichEditor

struct MiniRichEditor: NSViewRepresentable {
    @Binding var value: RichText
    let controller: MiniRichController
    var fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let text = CaptionTextView()
        text.isRichText = true
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.font = .systemFont(ofSize: fontSize)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.autoresizingMask = [.width]
        text.delegate = context.coordinator
        text.controller = controller
        scroll.documentView = text
        controller.textView = text

        context.coordinator.load(value, into: text, fontSize: fontSize)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? CaptionTextView else { return }
        context.coordinator.binding = $value
        text.controller = controller
        controller.textView = text
        // External change only (our own edits arrive back equal).
        if value.plain != text.string, !context.coordinator.editing {
            context.coordinator.load(value, into: text, fontSize: fontSize)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $value) }

    /// Handles the standard styling key equivalents itself — the app menu
    /// has no Format items to route them, and intercepting here keeps ⌘B
    /// away from any scene-wide SwiftUI shortcuts while a caption is
    /// focused.
    final class CaptionTextView: NSTextView {
        weak var controller: MiniRichController?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .option, .control]) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return super.performKeyEquivalent(with: event)
            }
            switch key {
            case "b": controller?.toggleTrait(.bold); return true
            case "i": controller?.toggleTrait(.italic); return true
            case "u": controller?.toggleUnderline(); return true
            case "e": controller?.toggleCenter(); return true
            default:  return super.performKeyEquivalent(with: event)
            }
        }
    }

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
