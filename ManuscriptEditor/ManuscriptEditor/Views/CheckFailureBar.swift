// CheckFailureBar.swift
//
// The red bar across the top of a content pane naming what is wrong there.
//
// The sidebar's red dot says a pane has a problem; this says WHICH problem,
// in the same words the Checks pane uses, without making the writer leave the
// section they're editing.  Only the FIRST failure is shown — a bar that
// grows with the failure count would push the editor around — with a circled
// count when there are more, and the full list one click away.
//
// It is derived, never stored: the bar and the sidebar dot both disappear the
// moment the content satisfies the check.

import SwiftUI

struct CheckFailureBar: View {

    /// The failing checks covering this pane, in checklist order.
    let failures: [ChecklistResult]
    /// Applies a repairable failure (the typography Fix), when there is one.
    var fix: ((ChecklistResult) -> Void)? = nil

    @State private var showingAll = false

    var body: some View {
        if let first = failures.first {
            Button {
                showingAll = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(first.rule)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(first.details)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if failures.count > 1 {
                        Text("\(failures.count)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                            .help("\(failures.count) checks are failing here")
                    }
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
                .overlay(alignment: .bottom) { Divider() }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(failures.count > 1
                  ? "\(failures.count) failing checks — click to see them all"
                  : "\(first.rule) — click for detail")
            .popover(isPresented: $showingAll, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(failures.count == 1
                         ? "1 failing check"
                         : "\(failures.count) failing checks")
                        .font(.headline)
                    ForEach(failures) { result in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.rule)
                                    .fontWeight(.medium)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(result.details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let fix, result.fixID != nil {
                                Spacer()
                                Button("Fix") {
                                    fix(result)
                                    showingAll = false
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(width: 380)
            }
        }
    }
}
