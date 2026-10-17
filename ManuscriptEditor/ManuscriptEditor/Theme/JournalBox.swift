// JournalBox.swift
//
// The design standard for a journal's pages: content sits in grey rounded
// boxes, and a box that can be edited carries its controls top right — a
// prominent pencil, which turns into save and discard while editing.  The
// same three icons wherever a thing is edited in place, so there is one
// gesture to learn.

import SwiftUI

/// A grey rounded box with a caption and, optionally, the edit controls.
/// Without a caption (a test's box, where the content names itself) the
/// controls sit over the top-right corner instead.
struct JournalBox<Content: View>: View {
    var title: String? = nil
    var editing: Bool? = nil           // nil = not editable
    var onEdit: () -> Void = {}
    var onSave: () -> Void = {}
    var onDiscard: () -> Void = {}
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let editing {
                        EditControls(editing: editing, onEdit: onEdit, onSave: onSave, onDiscard: onDiscard)
                    }
                }
            }
            content()
                .padding(.trailing, title == nil && editing != nil ? (editing == true ? 64 : 32) : 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if title == nil, let editing {
                EditControls(editing: editing, onEdit: onEdit, onSave: onSave, onDiscard: onDiscard)
                    .padding(8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
    }
}

/// Pencil → (save | discard).  Prominent: a heavy pencil, accent-colored,
/// bordered; the save is a disc and the discard a bin in the same tint —
/// discarding an edit is not a destructive act, so it is not red.
struct EditControls: View {
    let editing: Bool
    let onEdit: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                iconButton("opticaldisc", "Save", tint: .accentColor, action: onSave)
                iconButton("trash", "Discard the changes", tint: .accentColor, action: onDiscard)
            } else {
                iconButton("pencil", "Edit", tint: .accentColor, action: onEdit)
            }
        }
        .controlSize(.small)
    }

    private func iconButton(_ symbol: String, _ help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}
