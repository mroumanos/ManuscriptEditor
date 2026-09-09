// AssistRunIndicator.swift
//
// What a journal shows while a model is working on it.
//
// A fast-forward is not a spinner-sized wait: a whole manuscript can take
// minutes, and an indeterminate spinner with no elapsed time is
// indistinguishable from a hung process — which is exactly the question
// someone asks at minute three.  So this shows a bar, a running clock, and,
// once the wait stops being ordinary, what the cutoff is.
//
// It appears on the row whose button was pressed, and only there.
//
// See MasterContext/11-ai-integration.md §5.

import SwiftUI

struct AssistRunIndicator: View {
    let startedAt: Date
    /// Seconds after which the request is abandoned.
    let timeout: Int

    /// Past this, the wait is worth explaining rather than just showing.
    private let longRun: TimeInterval = 45

    var body: some View {
        // Redrawn once a second by the timeline, so the clock moves without a
        // Timer of its own.
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 64)
                Text(clock(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(elapsed > Double(timeout) - 60 ? .orange : .secondary)
            }
            .help(elapsed < longRun
                  ? "Working — the model is adapting this journal's sections."
                  : "Still working after \(clock(elapsed)). A whole manuscript can take several minutes; the request is given up on at \(clock(Double(timeout))) and logged as a failure, and nothing is written until it returns.")
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
