// PromptLogView.swift
//
// **AI Requests** — the third section of the Log pane, under Changelog and
// Events.  It belongs there rather than behind an icon of its own: the log
// pane is already where someone goes to ask "what happened to this
// manuscript", and a request to a model is one of the things that happened.
//
// Newest first, one row per request: what was asked, which tool and model
// answered, and what it changed — measured with the same sentence comparison
// compare mode uses, so "41% rewritten" means on this screen what it means in
// the editors.  Expanding a row shows the context that was sent, what was
// withheld, and the prompt and response verbatim.
//
// It is a transcript, not a control panel: nothing here edits or deletes an
// entry.  See MasterContext/11-ai-integration.md §6.

import SwiftUI

struct PromptLogView: View {
    @Environment(ManuscriptStore.self) private var store

    @State private var expanded: UUID?
    @State private var payload: (prompt: String, response: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("AI Requests")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("ships with the manuscript — every prompt, kept")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            if store.promptLog.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    ForEach(store.promptLog) { entry in
                        row(entry)
                        if entry.id != store.promptLog.last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
            }
        }
    }

    private var empty: some View {
        HStack(spacing: 8) {
            Image(systemName: AssistStyle.symbol).foregroundStyle(.tertiary)
            Text("Nothing sent yet — every AI request from this manuscript is recorded here, with what it changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
    }

    @ViewBuilder
    private func row(_ entry: AIPromptLogEntry) -> some View {
        let isOpen = expanded == entry.id
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isOpen {
                    expanded = nil
                    payload = nil
                } else {
                    expanded = entry.id
                    payload = load(entry)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.outcome.systemImage)
                        .foregroundStyle(color(entry.outcome))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary).fontWeight(.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(entry.model) · \(entry.connectorLabel) · \(entry.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.0fs", entry.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(entry.outcome == .failed ? .red : .secondary)
                    .padding(.leading, 22)
            }

            // The diff summary: what actually moved, per section.
            if !entry.changes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.changes) { change in
                        HStack(spacing: 6) {
                            changeBar(change)
                            Text(change.title).font(.caption).lineLimit(1)
                            Spacer()
                            Text(change.summary)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 22)
            }

            if isOpen { detailBlock(entry) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Green for what survived, yellow for what was reworked — the same
    /// vocabulary the compare-mode editors use.
    private func changeBar(_ change: AIPromptLogChange) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(Color.green.opacity(0.45))
                    .frame(width: geo.size.width * change.unchangedFraction)
                Rectangle().fill(Color.yellow.opacity(0.55))
                    .frame(width: geo.size.width * max(0, 1 - change.unchangedFraction - change.rewrittenFraction))
                Rectangle().fill(Color.purple.opacity(0.40))
            }
            .clipShape(Capsule())
        }
        .frame(width: 46, height: 5)
        .help("green: unchanged · yellow: edited · purple: rewritten")
    }

    @ViewBuilder
    private func detailBlock(_ entry: AIPromptLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.contextTitles.isEmpty {
                labelled("Sent", entry.contextTitles.joined(separator: ", "))
            }
            if !entry.excludedContextTitles.isEmpty {
                labelled("Withheld", entry.excludedContextTitles.joined(separator: ", "))
            }
            labelled("Size", "\(entry.promptCharacters) characters out, \(entry.responseCharacters) back")
            labelled("Intent", entry.intentID)

            // The tool keeps its own transcript of the run.  The app hands it
            // the session id, so that file can be pointed at directly rather
            // than hunted for under ~/.claude/projects.
            if let session = entry.sessionID {
                HStack(alignment: .top, spacing: 6) {
                    Text("Tool log")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    if let url = AIConnectorRunner.transcriptURL(for: session) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("Show the tool's own transcript", systemImage: "doc.text.magnifyingglass")
                                .font(.caption2)
                        }
                        .buttonStyle(.link)
                        .help(url.path)
                    } else {
                        Text("session \(session.prefix(8)) — no transcript on disk")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            if let payload {
                DisclosureGroup("Prompt") {
                    ScrollView {
                        Text(payload.prompt)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                }
                .font(.caption)
                DisclosureGroup("Response") {
                    ScrollView {
                        Text(payload.response.isEmpty ? "(nothing came back)" : payload.response)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                }
                .font(.caption)
            }
        }
        .padding(.leading, 22)
        .padding(.top, 2)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ outcome: AIPromptLogEntry.Outcome) -> Color {
        switch outcome {
        case .applied:  return .green
        case .noChange: return .secondary
        case .failed:   return .red
        }
    }

    /// Prompts and responses live beside the log rather than inside it, so
    /// they're read only when a row is opened.
    private func load(_ entry: AIPromptLogEntry) -> (String, String)? {
        guard let id = store.manuscript?.id else { return nil }
        let service = AIPromptLogService(persistence: store.persistence)
        return (service.promptText(entry.id, in: id) ?? "(not stored)",
                service.responseText(entry.id, in: id) ?? "")
    }
}
