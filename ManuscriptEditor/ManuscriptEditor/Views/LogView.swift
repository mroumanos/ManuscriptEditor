// LogView.swift
//
// The Log pane (Manuscript section — took over Sync's sidebar slot,
// Aug 2026): the manuscript's activity history, newest first.  Full
// messages, never truncated — the fix for banner text that clipped with no
// way to expand (issue #2).  Every banner (success/error), manual save,
// stamp, rollback, sync, and journal add/delete lands here; automatic
// keystroke saves deliberately don't.

import SwiftUI

struct LogView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Rows whose full text is expanded (rows are single-line until clicked).
    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Log").font(.title2.weight(.semibold))
                    Spacer()
                    if !store.activityLog.isEmpty {
                        Button("Clear Log") { store.clearLog() }
                            .controlSize(.small)
                    }
                }

                if store.activityLog.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.activityLog.enumerated()), id: \.element.id) { index, entry in
                            row(entry)
                            if index < store.activityLog.count - 1 {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        let expanded = expandedIDs.contains(entry.id)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(color(for: entry.kind))
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                // One line until clicked; the click expands the full text.
                Text(entry.message)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 1)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: expanded)
                if expanded, let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(entry.date.formatted(date: .abbreviated, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded { expandedIDs.remove(entry.id) } else { expandedIDs.insert(entry.id) }
        }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    [entry.message, entry.detail].compactMap { $0 }.joined(separator: "\n"),
                    forType: .string)
            }
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        case .info:    return .secondary
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Nothing logged yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Saves, syncs, stamps, rollbacks, and every success or error\nmessage will appear here.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
