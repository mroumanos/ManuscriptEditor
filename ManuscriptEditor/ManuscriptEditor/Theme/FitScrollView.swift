// FitScrollView.swift
//
// A ScrollView that sizes itself to its content's measured height, capped
// at a fraction of the screen — the app default for popup and dropdown
// lists.  A bare ScrollView obeys whatever height it is proposed, which
// inside popovers and overlays is often far too small (a fixed maxHeight
// only caps it further; it never grows it) — so lists rendered a couple of
// rows tall no matter how much content they held.

import SwiftUI

struct FitScrollView<Content: View>: View {
    /// Cap as a fraction of the screen's visible height.
    var maxScreenFraction: CGFloat = 0.6
    @ViewBuilder var content: () -> Content

    @State private var contentHeight: CGFloat = 44

    var body: some View {
        ScrollView {
            content()
                .onGeometryChange(for: CGFloat.self,
                                  of: { $0.size.height },
                                  action: { contentHeight = $0 })
        }
        .frame(height: min(contentHeight,
                           (NSScreen.main?.visibleFrame.height ?? 800) * maxScreenFraction))
    }
}
