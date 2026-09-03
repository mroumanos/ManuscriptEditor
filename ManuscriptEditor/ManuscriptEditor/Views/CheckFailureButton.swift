// CheckFailureButton.swift
//
// The failing-check control in a content pane's header, beside the gear.
//
// The sidebar's badge says a pane has problems and how many; this names the
// first one.  It sits in the header's control cluster rather than as a band
// across the pane, so it can never overlap the editor's gutter rule or push
// the text down — and so the writer's eye finds it in the same place every
// time.
//
// The label is just the check's TITLE.  Its measurement ("Abstract: 312
// words") and any others covering this pane are one click away, because a
// header has room for a name but not for an explanation.
//
// Entirely derived: the button and the sidebar badge both disappear the
// moment the content satisfies the check.

import SwiftUI

struct CheckFailureButton: View {

    /// The failing checks covering this pane, in checklist order.
    let failures: [ChecklistResult]
    /// Applies a repairable failure (the typography Fix), when there is one.
    var fix: ((ChecklistResult) -> Void)? = nil

    @State private var showingDetail = false

    var body: some View {
        if let first = failures.first {
            Button {
                showingDetail = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(first.rule)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if failures.count > 1 {
                        Text("\(failures.count)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 280, alignment: .trailing)
            .help(failures.count > 1
                  ? "\(failures.count) failing checks — click to see them all"
                  : "\(first.rule): \(first.details)")
            .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
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
                                    showingDetail = false
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
