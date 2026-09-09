// AssistStyle.swift
//
// One visual language for "this control can call a model".
//
// A single accent — violet through orchid — applied through one modifier, so
// the next AI feature adopts the look instead of inventing one.  It is used
// sparingly and never on a control that merely *relates* to AI: the treatment
// means "pressing this sends something", which is exactly the thing a writer
// should be able to spot without reading a tooltip.
//
// Motion is limited to a slow shimmer while a request is in flight, where it
// is a progress signal rather than decoration.
//
// See MasterContext/11-ai-integration.md §5.

import SwiftUI

enum AssistStyle {

    /// Violet → orchid.  Light and dark pairs, like every colour in the
    /// design system: the dark variants are lifted, since a saturated violet
    /// on a dark ground reads muddy.
    static func start(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.60, green: 0.49, blue: 1.00)
                        : Color(red: 0.48, green: 0.36, blue: 1.00)
    }

    static func end(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.79, green: 0.51, blue: 0.86)
                        : Color(red: 0.69, green: 0.42, blue: 0.70)
    }

    static func gradient(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(colors: [start(scheme), end(scheme)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The icon every assist control carries.
    static let symbol = "sparkles"

    static let strokeOpacity = 0.85
    static let fillOpacity   = 0.12
}

// MARK: - The modifier

private struct AssistAffordance: ViewModifier {
    let active: Bool
    let busy: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var shimmer = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(active ? AnyShapeStyle(AssistStyle.gradient(scheme))
                                    : AnyShapeStyle(Color.primary))
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AssistStyle.start(scheme).opacity(AssistStyle.fillOpacity))
                }
            }
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(AssistStyle.gradient(scheme)
                                        .opacity(busy && shimmer ? 0.35 : AssistStyle.strokeOpacity),
                                      lineWidth: 1)
                }
            }
            .animation(busy ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                       value: shimmer)
            .onChange(of: busy) { _, isBusy in shimmer = isBusy }
    }
}

extension View {
    /// Marks a control as AI-capable.  `active` is the manuscript's Assist
    /// toggle; `busy` shimmers the stroke while a request is in flight.
    func assistAffordance(active: Bool, busy: Bool = false) -> some View {
        modifier(AssistAffordance(active: active, busy: busy))
    }
}
