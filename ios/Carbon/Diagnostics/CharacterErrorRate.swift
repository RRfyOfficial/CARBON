// Character error rate (SPEC 8.3), identical to tools/ocr.swift so on-device and Mac numbers compare.

import Foundation

nonisolated enum CharacterErrorRate {
    /// (S + D + I) / N over Characters, case-sensitive, after folding typographic variants and
    /// collapsing whitespace on both sides. nil when the truth is empty.
    static func of(_ output: String, truth: String) -> Double? {
        let reference = Array(collapseWhitespace(canonical(truth)))
        guard !reference.isEmpty else { return nil }
        let hypothesis = Array(collapseWhitespace(canonical(output)))
        return Double(levenshtein(hypothesis, reference)) / Double(reference.count)
    }

    /// Curly quotes, dashes and non-breaking spaces fold to plain ones; bullet glyphs are dropped
    /// (Vision never returns them, M0), so CER measures recognition rather than glyph choice.
    static func canonical(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": out.append("\"")
            case "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}": out.append("-")
            case "\u{2026}": out.append("...")
            case "\u{00A0}", "\u{202F}": out.append(" ")
            case "\u{2022}", "\u{25CF}", "\u{25AA}", "\u{25E6}", "\u{2023}", "\u{2219}", "\u{00B7}": continue
            default: out.append(ch)
            }
        }
        return out
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Two-row Levenshtein distance, O(min(m, n)) memory.
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        var previous = Array(0...short.count)
        var current = Array(repeating: 0, count: short.count + 1)
        for i in 0..<long.count {
            current[0] = i + 1
            for j in 0..<short.count {
                let substitution = previous[j] + (long[i] == short[j] ? 0 : 1)
                current[j + 1] = min(substitution, previous[j + 1] + 1, current[j] + 1)
            }
            swap(&previous, &current)
        }
        return previous[short.count]
    }
}
