// TemplateStyle.swift
//
// One visual language for "this is a venue's rules, not your paper".
//
// A template opens in a tab in the same window as the manuscript, which is
// convenient and, without a visible difference, dangerous: the two look alike,
// and typing into the wrong one changes what every manuscript using that
// template starts from.  So a template tab is a different colour from top to
// bottom — tab chip, sidebar header, pane headers — and the colour means
// exactly one thing.
//
// Teal, because the palette already spends blue on the app's own accent,
// violet on AI (`AssistStyle`) and orange on "edited since".  A fourth hue
// that collides with none of them is the whole requirement.
//
// See MasterContext/features/journal-templates.md §3.2.

import SwiftUI

enum TemplateStyle {

    /// The template accent, light and dark.  The dark variant is lifted: a
    /// deep teal on a dark ground reads as grey.
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.35, green: 0.78, blue: 0.76)
                        : Color(red: 0.06, green: 0.48, blue: 0.50)
    }

    /// The tint behind a template tab and its pane headers.
    static func wash(_ scheme: ColorScheme) -> Color {
        accent(scheme).opacity(scheme == .dark ? 0.16 : 0.10)
    }

    /// The icon a template carries everywhere it appears.
    static let symbol = "building.columns.circle"
}

// MARK: - Layout

/// The one measurement every template pane shares.
///
/// It is not decoration.  A pane in a `NavigationSplitView` detail hands its
/// IDEAL width up to the split view, and a long unwrapped line of explanatory
/// text has an ideal width of well over a thousand points — enough to push the
/// split past the window, which squeezes the sidebar to nothing and leaves the
/// window looking empty.  Capping the content width caps the ideal, and a
/// pane can then be as narrow as the window needs.  See gotcha 24.
enum TemplateLayout {
    static let contentWidth: CGFloat = 760
    /// The Export pane is wider: its cards carry a row of typography controls
    /// per component, and squeezing those into a reading measure helps nobody.
    static let exportWidth: CGFloat = 900
}

// MARK: - The modifier

private struct TemplateSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(TemplateStyle.wash(scheme))
            // An OPAQUE base under the wash.  The wash is deliberately
            // translucent — a solid teal band would shout — and a translucent
            // band let the editor's gutter rule show straight through the
            // header, so the rule appeared to run from the tab bar to the
            // bottom of the window.  The rule belongs to the editor; it starts
            // where the editor starts.
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TemplateStyle.accent(scheme).opacity(0.45))
                    .frame(height: 1)
            }
    }
}

extension View {
    /// Marks a surface as belonging to a template rather than a manuscript.
    func templateSurface() -> some View { modifier(TemplateSurface()) }
}
