// SearchDropdownBar.swift
//
// Shared chrome for the categorized search bars in the Authors and
// Bibliography panes: a compact search field plus a floating dropdown card
// that overlays the content below it (never pushing layout around), sized
// to its measured content and capped at 40% of the screen.
//
// The overlay gotcha this encapsulates: an overlay proposes the FIELD's
// height to its children, and a ScrollView obeys the proposal — so the card
// must measure its own content and set an explicit height, or it renders a
// row and a half tall.  Call sites should raise the bar's zIndex so the
// card paints over the list beneath it.

import SwiftUI

struct SearchDropdownBar<Dropdown: View>: View {
    let placeholder: String
    @Binding var query: String
    var searching: Bool
    var dropdownVisible: Bool
    @ViewBuilder var dropdown: () -> Dropdown

    /// Measured field height, so the floating card lands just below it.
    @State private var fieldHeight: CGFloat = 28
    /// Measured height of the card's content, so it can size to fit.
    @State private var contentHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
            if searching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color(NSColor.textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .onGeometryChange(for: CGFloat.self,
                          of: { $0.size.height },
                          action: { fieldHeight = $0 })
        .overlay(alignment: .topLeading) {
            if dropdownVisible {
                card.offset(y: fieldHeight + 4)
            }
        }
    }

    private var card: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                dropdown()
            }
            .onGeometryChange(for: CGFloat.self,
                              of: { $0.size.height },
                              action: { contentHeight = $0 })
        }
        .frame(height: min(contentHeight,
                           (NSScreen.main?.visibleFrame.height ?? 800) * 0.4))
        // Wider than the narrow panes on purpose — it floats, so it may
        // overhang the editor to show full titles and institutions.
        .frame(width: 360, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// "Saved (3)" — one source-category header inside the dropdown.
struct SearchSectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        Text(count.map { "\(title) (\($0))" } ?? title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// One dropdown result row.  Rows that ADD something show a leading "+"
/// (`icon: "plus.circle"`); rows that just OPEN an existing item pass nil.
struct SearchResultRow: View {
    var icon: String? = nil
    let title: String
    var subtitle: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// A quiet caption row for dropdown status text ("No matches", errors).
struct SearchNoteRow: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)
    }
}
