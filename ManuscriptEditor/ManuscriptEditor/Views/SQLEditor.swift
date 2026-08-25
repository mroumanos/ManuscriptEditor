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
    @State private var dragged = false

    /// Tall enough for every line of the query, within reason.
    private var fittedHeight: CGFloat {
        let lines = max(text.components(separatedBy: "\n").count, 1)
        let lineHeight = NSFont.preferredFont(forTextStyle: .callout).pointSize * 1.45
        return min(max(CGFloat(lines) * lineHeight + 18, minHeight), 600)
    }

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
            // Grabber: click fits the box to the query, drag resizes it.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragBase == nil { dragBase = height ?? minHeight }
                            dragged = dragged || abs(value.translation.height) > 2
                            guard dragged else { return }
                            height = min(max((dragBase ?? minHeight) + value.translation.height,
                                             minHeight), 600)
                        }
                        .onEnded { _ in
                            // A click (no movement) snaps to the query's
                            // own height; a second click collapses again.
                            if !dragged {
                                height = (height ?? minHeight) > minHeight + 1 ? minHeight : fittedHeight
                            }
                            dragBase = nil
                            dragged = false
                        }
                )
                .help("Click to fit the box to the query · drag to resize")
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
