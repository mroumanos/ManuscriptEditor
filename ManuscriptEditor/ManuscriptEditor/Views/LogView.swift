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
    @State private var expandedChanges: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Log").font(.title2.weight(.semibold))
                    Spacer()
                }

                Text("Changelog")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                let changes = store.changelog()
                if changes.isEmpty {
                    Text("No changes since the last stamped versions.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(changes) { change in
                            let expanded = expandedChanges.contains(change.id)
                            VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Text(change.context)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 110, alignment: .leading)
                                Text(change.item).font(.callout)
                                Spacer()
                                Text(change.change)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(change.change == "Removed" ? .red : .secondary)
                                Text(SigningService.userName)
                                    .font(.caption2).foregroundStyle(.tertiary)
                                if change.detail != nil {
                                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            if expanded, let detail = change.detail {
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 120)
                            }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard change.detail != nil else { return }
                                if expanded { expandedChanges.remove(change.id) }
                                else { expandedChanges.insert(change.id) }
                            }
                            if change.id != changes.last?.id { Divider().padding(.leading, 12) }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
                }

                HStack {
                    Text("Events")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("local only — never pushed to the remote")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if !store.activityLog.isEmpty {
                        Button("Clear Events") { store.clearLog() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 8)
                Group {
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
            if let context = entry.context {
                Text(context)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)
            }
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
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let author = entry.author, !author.isEmpty {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
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
