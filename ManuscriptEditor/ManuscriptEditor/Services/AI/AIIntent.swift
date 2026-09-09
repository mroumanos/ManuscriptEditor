// AIIntent.swift
//
// The seam every AI feature goes through, and the convention that makes them
// all findable.
//
// FINDING EVERY WAY THIS APP CAN TALK TO A MODEL
// ─────────────────────────────────────────────────────────────────────────────
//     grep -rn "AI INTENT" ManuscriptEditor/
//
// Every intent lives in `Services/AI/Intents/`, carries an `// AI INTENT`
// banner declaring what it sends and what it writes back, and is listed in
// `AIIntentRegistry.all`.  The registry is what Settings renders, so the list
// the user sees is the list the code has — not a second list that drifts.
//
// An intent describes itself; it does not decide whether it may run.  That
// decision belongs to `AIRequestService`, which enforces the context
// checkboxes and writes the prompt log.
//
// See MasterContext/11-ai-integration.md §7.

import Foundation

/// What an intent tells the user (and the reviewer) about itself.
struct AIIntentDescriptor: Identifiable, Sendable, Hashable {
    /// Stable, dotted, and the same string that lands in the prompt log.
    let id: String
    let title: String
    /// One line: what it does.
    let summary: String
    /// What leaves the machine, beyond the enabled context rows.
    let sends: [String]
    /// What it writes back into the manuscript.
    let writes: String
    /// Whether a change it makes can be undone with ⌘Z, or is recorded as a
    /// version instead.  Stated because it is the first thing anyone asks.
    let reversal: String
}

protocol AIIntent {
    static var descriptor: AIIntentDescriptor { get }
}

/// Every intent in the app.  Adding one without adding it here is the mistake
/// this file exists to make obvious.
enum AIIntentRegistry {
    static var all: [AIIntentDescriptor] {
        [FastForwardIntent.descriptor]
    }
}
