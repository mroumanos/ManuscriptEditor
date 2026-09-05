// ComparisonHighlight.swift
//
// Wiring for the compare-mode sentence highlighting: which pane a pane is
// measured against, and the two colours it paints with.
//
// The comparison reads RIGHT TO LEFT — each pane is measured against the pane
// to its left, so the rightmost cut is the one being examined and the leftmost
// is the reference. (The leftmost pane has nothing to its left, so it borrows
// its right-hand neighbour; otherwise it would be the one pane that never told
// you anything.)
//
// The panes hand each other nothing but plain text, so this stays a pure
// function of what is on screen: no stored diff, no invalidation to get wrong.

import SwiftUI

private struct ComparisonPeersKey: EnvironmentKey {
    static let defaultValue: [VersionRef] = []
}

extension EnvironmentValues {
    /// The refs currently displayed, left to right.  Empty in single-pane
    /// mode, where there is nothing to compare.
    var comparisonPeers: [VersionRef] {
        get { self[ComparisonPeersKey.self] }
        set { self[ComparisonPeersKey.self] = newValue }
    }
}

extension Array where Element == VersionRef {
    /// The ref `mine` is compared against: the one to its left, or — for the
    /// leftmost pane — the one to its right.
    func comparisonPartner(of mine: VersionRef) -> VersionRef? {
        guard count > 1, let index = firstIndex(of: mine) else { return nil }
        return index > 0 ? self[index - 1] : self[index + 1]
    }
}

/// The two highlight washes.  Deliberately near-invisible: this runs while
/// someone is writing, and a diff that shouts is a diff you turn off.
enum ComparisonHighlight {
    static func color(for kind: SentenceMatchKind, dark: Bool) -> NSColor {
        switch kind {
        case .exact:
            return dark ? NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.36, alpha: 0.16)
                        : NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.42, alpha: 0.13)
        case .partial:
            return dark ? NSColor(calibratedRed: 0.78, green: 0.66, blue: 0.20, alpha: 0.16)
                        : NSColor(calibratedRed: 0.92, green: 0.80, blue: 0.26, alpha: 0.16)
        }
    }
}
