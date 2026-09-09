// AssistRunIndicator.swift
//
// What a journal shows while a model is working on it.
//
// A fast-forward is not a spinner-sized wait: a whole manuscript can take
// minutes — one real seven-section run took 14 — and an indeterminate spinner
// with no elapsed time is indistinguishable from a hung process, which is
// exactly the question someone asks at minute three.
//
// The answer to that question turned out to be "it is thinking": that run spent
// 15,850 tokens of extended thinking before writing a single character.  So the
// row shows three things — the clock, the phase the tool reports, and an eye
// that opens the output as it arrives.  Watching the text appear is the
// difference between trusting the wait and killing it.
//
// It appears on the row whose button was pressed, and only there.
//
// See MasterContext/11-ai-integration.md §5.

import SwiftUI

struct AssistRunIndicator: View {
    let run: ManuscriptStore.AssistRun
    /// Seconds after which the request is abandoned.
    let timeout: Int

    @State private var showingOutput = false

    /// Past this, the wait is worth explaining rather than just showing.
    private let longRun: TimeInterval = 45

    var body: some View {
        // Redrawn once a second by the timeline, so the clock moves without a
        // Timer of its own.
        TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(run.startedAt))
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 56)
                Text(clock(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(elapsed > Double(timeout) - 60 ? .orange : .secondary)
                if let progress = run.progress {
                    Text(progress.summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Button {
                    showingOutput = true
                } label: {
                    Image(systemName: "eye")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Watch the output as it arrives")
                .popover(isPresented: $showingOutput, arrowEdge: .bottom) {
                    AssistLiveOutputView(run: run, elapsed: elapsed)
                }
            }
            .help(helpText(elapsed))
        }
    }

    private func helpText(_ elapsed: TimeInterval) -> String {
        var lines = [run.progress.map { "\($0.summary)." } ?? "Starting the tool."]
        if elapsed >= longRun {
            lines.append("A whole manuscript can take several minutes — most of it is the model thinking before it writes anything.")
        }
        lines.append("Given up on after \(clock(Double(timeout))), or after 3 minutes of silence. Nothing is written until it returns.")
        return lines.joined(separator: " ")
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - The live view

/// The end of the answer as it is being written.
///
/// A tail, not a transcript: the run's full output is kept once it lands, and
/// the point of this window is to see that something is happening — and to
/// read what kind of thing it is.
struct AssistLiveOutputView: View {
    let run: ManuscriptStore.AssistRun
    let elapsed: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: AssistStyle.symbol).foregroundStyle(.secondary)
                Text(run.progress?.summary ?? "Starting…")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            let tail = run.progress?.tail ?? ""
            if tail.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.progress?.phase == .thinking
                         ? "Nothing written yet — the model is still thinking."
                         : "Waiting for the tool to start.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("On a whole manuscript this is normal, and usually most of the wait: the thinking happens before any of the answer exists.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    Text(tail)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                Text("The last \(tail.count) characters, as they arrive. Nothing is written to the manuscript until the run finishes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 460)
    }
}
