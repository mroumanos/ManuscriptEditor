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
/// bordered; the save is the floppy disk every save button has been, and
/// the discard a bin in the same tint — discarding an edit is not a
/// destructive act, so it is not red.
struct EditControls: View {
    let editing: Bool
    let onEdit: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                Button(action: onSave) {
                    FloppyIcon()
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.bordered)
                .help("Save")
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

/// The floppy disk — the save icon everyone knows — drawn here because SF
/// Symbols has none.  The body with its clipped corner, the metal shutter
/// with its slot at the top, the label at the bottom; stroked and filled in
/// the current foreground, sized like the symbols beside it.
struct FloppyIcon: View {
    var size: CGFloat = 16
    var lineWidth: CGFloat = 1.8

    var body: some View {
        Canvas { context, box in
            let w = box.width, h = box.height
            let inset = lineWidth / 2 + 0.5
            let r: CGFloat = 1.6
            let cut = w * 0.2

            var body = Path()
            body.move(to: CGPoint(x: inset + r, y: inset))
            body.addLine(to: CGPoint(x: w - inset - cut, y: inset))
            body.addLine(to: CGPoint(x: w - inset, y: inset + cut))
            body.addLine(to: CGPoint(x: w - inset, y: h - inset - r))
            body.addArc(center: CGPoint(x: w - inset - r, y: h - inset - r), radius: r,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            body.addLine(to: CGPoint(x: inset + r, y: h - inset))
            body.addArc(center: CGPoint(x: inset + r, y: h - inset - r), radius: r,
                        startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            body.addLine(to: CGPoint(x: inset, y: inset + r))
            body.addArc(center: CGPoint(x: inset + r, y: inset + r), radius: r,
                        startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            body.closeSubpath()
            context.stroke(body, with: .foreground,
                           style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))

            // The shutter, with its slot punched out.
            let shutter = CGRect(x: w * 0.30, y: inset, width: w * 0.36, height: h * 0.32)
            context.fill(Path(shutter), with: .foreground)
            var punch = context
            punch.blendMode = .destinationOut
            let slot = CGRect(x: w * 0.52, y: inset + h * 0.07, width: w * 0.07, height: h * 0.17)
            punch.fill(Path(roundedRect: slot, cornerRadius: 0.5), with: .color(.black))

            // The label.
            let label = CGRect(x: w * 0.26, y: h * 0.58, width: w * 0.48, height: h * 0.24)
            context.stroke(Path(roundedRect: label, cornerRadius: 1), with: .foreground, lineWidth: lineWidth * 0.8)
        }
        .frame(width: size, height: size)
    }
}
