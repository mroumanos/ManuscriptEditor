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

// MARK: - The modifier

private struct TemplateSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(TemplateStyle.wash(scheme))
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
