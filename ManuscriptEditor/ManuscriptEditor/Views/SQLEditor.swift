// SQLEditor.swift
//
// The shared SQL input: a terminal-style black box with a monospaced font in
// amber — deliberately identical in light and dark mode — that formats
// naturally across multiple lines.  Used by the Data pane and by data-linked
// figures/tables.

import SwiftUI

struct SQLEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 64

    /// Amber-on-black terminal palette.
    private let ink = NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1)

    var body: some View {
        PlainTextEditor(text: $text,
                        font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                                                    weight: .regular),
                        textColor: ink,
                        insertionColor: ink,
                        smartSubstitutions: false)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}
