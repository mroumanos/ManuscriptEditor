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
// entry.  See MasterContext/features/ai-assist.md §6.

import SwiftUI

struct PromptLogView: View {
    @Environment(ManuscriptStore.self) private var store

    @State private var expanded: UUID?
    @State private var payload: (prompt: String, response: String)?
    /// Which log popover is open, if any.
    @State private var openLog: OpenLog?

    /// One case per log a row can show, carrying the entry so two expanded
    /// rows can't fight over one flag.
    enum OpenLog: Hashable {
        case prompt(UUID), response(UUID), session(UUID)
    }

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

            // Everything this run left behind, each in its own window rather
            // than crammed into the row: what was asked, what came back, and
            // what the tool itself recorded while producing it.
            HStack(alignment: .top, spacing: 10) {
                Text("Logs")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .leading)

                logButton("Prompt", systemImage: "text.alignleft", tag: .prompt(entry.id)) {
                    LogTextPopover(title: "Prompt",
                                   subtitle: "Exactly what was sent, context first",
                                   text: payload?.prompt ?? "")
                }

                logButton("Output", systemImage: "text.quote", tag: .response(entry.id)) {
                    LogTextPopover(title: "Output",
                                   subtitle: entry.outcome == .failed
                                       ? "What came back before it failed"
                                       : "The model's raw reply, before it was parsed",
                                   text: payload?.response ?? "")
                }

                if let session = entry.sessionID,
                   let url = AIConnectorRunner.transcriptURL(for: session) {
                    logButton("Session log", systemImage: "list.bullet.rectangle",
                              tag: .session(entry.id)) {
                        SessionTranscriptView(url: url)
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal", systemImage: "folder").font(.caption2)
                    }
                    .buttonStyle(.link)
                    .help(url.path)
                } else if let session = entry.sessionID {
                    Text("session \(session.prefix(8)) — the tool kept no transcript")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.leading, 22)
        .padding(.top, 2)
    }

    /// A link that opens one log in a popover.
    private func logButton<Content: View>(_ title: String, systemImage: String,
                                          tag: OpenLog,
                                          @ViewBuilder content: @escaping () -> Content) -> some View {
        Button {
            openLog = (openLog == tag) ? nil : tag
        } label: {
            Label(title, systemImage: systemImage).font(.caption2)
        }
        .buttonStyle(.link)
        .popover(isPresented: Binding(get: { openLog == tag },
                                      set: { if !$0 { openLog = nil } }),
                 arrowEdge: .bottom) {
            content()
        }
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

// MARK: - The tool's own transcript

/// Claude Code's `.jsonl` record of one run, read from disk on demand.
///
/// Rendered as one row per event rather than raw JSON: the file is a stream of
/// bookkeeping (queue operations, attachments, thinking-token ticks) with the
/// interesting parts — the prompt, the answer, and any API error — buried in
/// it.  The raw line is one click away for when the summary isn't enough.
struct SessionTranscriptView: View {
    let url: URL

    @State private var events: [Event] = []
    @State private var showingRaw = false
    @State private var raw = ""

    struct Event: Identifiable {
        let id = UUID()
        let kind: String
        let time: String
        let detail: String
        let raw: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                Text("Session log").font(.callout.weight(.medium))
                Spacer()
                Toggle("Raw", isOn: $showingRaw)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the whole file")
            }

            if showingRaw {
                ScrollView {
                    Text(raw)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 300)
            } else if events.isEmpty {
                Text("The tool wrote no events for this run.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(height: 300, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Text(event.kind)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(color(event.kind))
                                    .frame(width: 78, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.detail)
                                        .font(.caption2)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Text(event.time)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            Divider()
                        }
                    }
                }
                .frame(height: 300)
            }

            Text(url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "user":      return .accentColor
        case "assistant": return .green
        case "error":     return .red
        default:          return .secondary
        }
    }

    private func load() {
        raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        events = raw.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let kind = json["type"] as? String ?? "?"
            let time = (json["timestamp"] as? String)
                .map { String($0.dropFirst(11).prefix(8)) } ?? ""
            return Event(kind: kind, time: time,
                         detail: describe(kind: kind, json: json),
                         raw: String(line))
        }
    }

    /// One readable line per event — the size of a prompt, the text of an
    /// answer, the message of an error.
    private func describe(kind: String, json: [String: Any]) -> String {
        let message = json["message"] as? [String: Any]
        switch kind {
        case "user":
            if let content = message?["content"] as? String {
                return "prompt · \(content.count) characters"
            }
            return "prompt"
        case "assistant":
            let model = message?["model"] as? String ?? ""
            var text = ""
            if let blocks = message?["content"] as? [[String: Any]] {
                text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
            }
            let head = text.replacingOccurrences(of: "\n", with: " ").prefix(200)
            return head.isEmpty ? "reply (\(model))" : "\(model): \(head)"
        case "attachment":
            return (json["attachment"] as? [String: Any])?["type"] as? String ?? "attachment"
        case "system":
            return [json["subtype"] as? String,
                    (json["estimated_tokens"] as? Int).map { "\($0) thinking tokens" }]
                .compactMap { $0 }.joined(separator: " · ")
        case "result":
            let error = (json["is_error"] as? Bool) == true ? "FAILED · " : ""
            let seconds = ((json["duration_ms"] as? Int) ?? 0) / 1000
            let cost = (json["total_cost_usd"] as? Double).map { String(format: "$%.2f", $0) } ?? ""
            return "\(error)\(seconds)s · \(cost)"
        default:
            return ""
        }
    }
}

// MARK: - One log, in a window of its own

/// A plain text log — a prompt, a reply — shown the way the session log is:
/// monospaced, scrollable, selectable, copyable.
struct LogTextPopover: View {
    let title: String
    let subtitle: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }

            if text.isEmpty {
                Text("Nothing was recorded — the request failed before this existed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 300, alignment: .top)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 300)
                Text("\(text.count.formatted()) characters")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 520)
    }
}
