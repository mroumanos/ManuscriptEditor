// AssistRunIndicator.swift
//
// What a journal shows while a model is working on it.
//
// A fast-forward is not a spinner-sized wait: a whole manuscript can take
// minutes, and an indeterminate spinner with no elapsed time is
// indistinguishable from a hung process — which is exactly the question
// someone asks at minute three.
//
// The answer to that question turned out to be "it is thinking": a real
// seven-section adaptation spent minutes on extended thinking before writing a
// single character.  So the row shows the phase the tool reports as well as the
// clock — thinking with its token count, then writing with its character count.
// Nothing to report is itself information, and it is what a stall looks like.
//
// It appears on the row whose button was pressed, and only there.
//
// See MasterContext/11-ai-integration.md §5.

import SwiftUI

struct AssistRunIndicator: View {
    let run: ManuscriptStore.AssistRun
    /// Seconds after which the request is abandoned.
    let timeout: Int

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
                    .frame(width: 64)
                Text(clock(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(elapsed > Double(timeout) - 60 ? .orange : .secondary)
                if let progress = run.progress {
                    Text(progress.summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
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
