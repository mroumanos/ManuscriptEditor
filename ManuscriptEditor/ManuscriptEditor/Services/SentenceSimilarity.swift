// SentenceSimilarity.swift
//
// Sentence-level comparison between two versions of the same component, for
// the side-by-side editors.
//
// The question a writer asks in compare mode is "what did this cut actually
// change?", and the honest unit for that is the SENTENCE: word-level diffs
// light up every rephrasing equally, and paragraph-level ones hide a rewritten
// clause inside a paragraph that looks untouched.
//
// Everything here is computed live from the two strings — nothing is stored,
// nothing is cached. A section is tens of sentences, so the O(n·m) sweep costs
// microseconds; if a component ever grows big enough for that to show, this is
// the file where an index would go, and the callers would not change.

import Foundation

/// One sentence and where it sits in its source string.
struct SentenceSpan: Equatable {
    let range: NSRange
    let text: String
    /// Lowercased, punctuation-free words — what matching actually compares.
    let words: [String]
}

/// How closely a sentence matches its counterpart.
enum SentenceMatchKind: Equatable {
    /// The same sentence, ignoring case, punctuation and spacing.
    case exact
    /// Recognisably the same sentence, edited.
    case partial(Double)
}

/// A sentence in one pane and the sentence it matched in the other.
struct SentenceMatch: Equatable {
    let range: NSRange
    let kind: SentenceMatchKind
    /// The counterpart's text, shown on hover.
    let counterpart: String
}

enum SentenceSimilarity {

    /// Below this share of shared words two sentences are simply different.
    /// Chosen so a sentence with a clause added or a few words swapped still
    /// reads as "the same sentence, edited", while two sentences that merely
    /// share a subject do not.
    static let partialThreshold = 0.45

    // MARK: - Splitting

    /// Splits into sentences, keeping each one's range in the original string.
    /// Uses the platform's sentence enumerator, so abbreviations and quotes
    /// behave the way they do everywhere else on the system.
    static func sentences(in text: String) -> [SentenceSpan] {
        guard !text.isEmpty else { return [] }
        var out: [SentenceSpan] = []
        let ns = text as NSString
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .localized]) { piece, range, _, _ in
            guard let piece else { return }
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let words = normalizedWords(trimmed)
            // A bare "3." or a lone bullet is not a sentence to compare.
            guard words.count >= 2 else { return }
            let nsRange = NSRange(range, in: text)
            // Trim the stored range to the visible sentence, so highlighting
            // doesn't wash over the whitespace between sentences.
            let leading = piece.prefix { $0.isWhitespace || $0.isNewline }.utf16.count
            let trailing = String(piece.reversed().prefix { $0.isWhitespace || $0.isNewline }).utf16.count
            let tight = NSRange(location: nsRange.location + leading,
                                length: max(0, nsRange.length - leading - trailing))
            guard tight.length > 0, NSMaxRange(tight) <= ns.length else { return }
            out.append(SentenceSpan(range: tight, text: trimmed, words: words))
        }
        return out
    }

    /// Lowercased words with punctuation stripped — "The dog, barking!" and
    /// "the dog barking" compare equal.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Matching

    /// For every sentence in `text`, its best counterpart in `other`.
    ///
    /// Each sentence takes its best available match rather than the first
    /// acceptable one, so a paragraph that repeats a phrase doesn't attach
    /// every copy to the same counterpart.
    static func matches(in text: String, against other: String) -> [SentenceMatch] {
        let mine = sentences(in: text)
        let theirs = sentences(in: other)
        guard !mine.isEmpty, !theirs.isEmpty else { return [] }

        // Exact matching is by normalized text, which is cheap and unambiguous.
        var exactIndex: [String: Int] = [:]
        for (i, s) in theirs.enumerated() where exactIndex[s.words.joined(separator: " ")] == nil {
            exactIndex[s.words.joined(separator: " ")] = i
        }

        var out: [SentenceMatch] = []
        for span in mine {
            let key = span.words.joined(separator: " ")
            if let hit = exactIndex[key] {
                out.append(SentenceMatch(range: span.range, kind: .exact,
                                         counterpart: theirs[hit].text))
                continue
            }
            var bestScore = 0.0
            var best: SentenceSpan?
            let mineSet = Set(span.words)
            for candidate in theirs {
                let score = similarity(mineSet, Set(candidate.words))
                if score > bestScore { bestScore = score; best = candidate }
            }
            if let best, bestScore >= partialThreshold {
                out.append(SentenceMatch(range: span.range, kind: .partial(bestScore),
                                         counterpart: best.text))
            }
        }
        return out
    }

    /// How alike two sentences are, on two readings:
    ///
    /// **Overlap** (shared / total distinct) is symmetric and forgiving of
    /// reordering, which is what a reworded sentence usually is.
    ///
    /// **Containment** (shared / the shorter one) catches the other common
    /// edit — a sentence kept whole and EXPANDED, where a clause or two of new
    /// material sinks the overlap score even though nothing was taken away.
    /// It is discounted, and gated behind a near-total match plus a floor of
    /// three shared words, so a short sentence swallowed by a long unrelated
    /// one doesn't score on coincidence.
    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = a.intersection(b).count
        guard shared > 0 else { return 0 }
        let overlap = Double(shared) / Double(a.union(b).count)
        let containment = Double(shared) / Double(min(a.count, b.count))
        guard shared >= 3, containment >= 0.8 else { return overlap }
        return max(overlap, containment * 0.75)
    }
}
