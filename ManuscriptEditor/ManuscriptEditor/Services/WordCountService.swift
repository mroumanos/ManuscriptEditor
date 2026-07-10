// WordCountService.swift
//
// Utility for counting words in a string.
// Used by ManuscriptSection, Manuscript, and the editor toolbars to show live word counts.

import Foundation

/// A stateless utility for counting words in text strings.
///
/// Declared as a `caseless enum` (no cases) because it only provides static methods
/// and should never be instantiated — this is a common Swift pattern for namespacing
/// a group of related functions.
enum WordCountService {

    /// Counts words in `text` by splitting on whitespace and newlines.
    ///
    /// This is a fast, naive count suitable for body sections and abstracts.
    /// It does NOT strip Markdown syntax, so heading markers (`#`) and bold markers (`**`)
    /// count as words.  Use `countStripped` when you need a count closer to what a journal
    /// would measure.
    ///
    /// - Parameter text: The raw string to count.
    /// - Returns: Number of non-empty whitespace-separated tokens.
    static func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    /// Counts words after stripping common Markdown formatting syntax.
    ///
    /// Removes:
    /// - Heading markers (`#`, `##`, etc.)
    /// - Bold and italic markers (`**`, `*`, `__`, `_`)
    /// - Inline code backticks and their content
    /// - Link syntax `[label](url)` — keeps the label, drops the URL
    ///
    /// The result is closer to what a journal's submission system would count.
    /// Used by `SectionEditorView`'s word-count toolbar.
    ///
    /// - Parameter text: Markdown-formatted string.
    /// - Returns: Approximate word count after stripping markup.
    static func countStripped(_ text: String) -> Int {
        var s = text
        s = s.replacingOccurrences(of: #"^#{1,6}\s+"#,            with: "",   options: [.regularExpression, .anchored])
        s = s.replacingOccurrences(of: #"\*{1,3}([^*]+)\*{1,3}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"_{1,2}([^_]+)_{1,2}"#,   with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`[^`]+`"#,                with: "",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        return count(s)
    }
}
