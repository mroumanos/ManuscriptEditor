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

    /// User-adjusted height (the grabber under the box drags it taller).
    @State private var height: CGFloat?
    @State private var dragBase: CGFloat?

    /// Amber-on-black terminal palette.
    private let ink = NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1)

    var body: some View {
        VStack(spacing: 0) {
            PlainTextEditor(text: $text,
                            font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                                                        weight: .regular),
                            textColor: ink,
                            insertionColor: ink,
                            smartSubstitutions: false)
                .padding(8)
                .frame(minHeight: minHeight)
                .frame(height: height)
            // Grabber: drag to grow the box downwards.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .frame(height: 10)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragBase == nil { dragBase = height ?? minHeight }
                            height = min(max((dragBase ?? minHeight) + value.translation.height, minHeight), 600)
                        }
                        .onEnded { _ in dragBase = nil }
                )
                .help("Drag to resize the SQL box")
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
