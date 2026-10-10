// The Formatter socket (SPEC 8.1) and its v1 implementation, As-is (SPEC 8.5).

import Foundation

protocol ScanFormatter: Sendable {
    func format(_ text: ReadText, lineBreaks: Bool) -> String
}

nonisolated struct AsIsFormatter: ScanFormatter {
    func format(_ text: ReadText, lineBreaks: Bool) -> String {
        let blocks = text.blocks.map { rows in rows.map(Self.normalizeBullet) }
        let rendered = blocks.map { rows in lineBreaks ? rows.joined(separator: "\n") : Self.joinRows(rows) }
        let joined = rendered.joined(separator: "\n\n")
        return joined
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.trimmingTrailingWhitespace(String($0)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    /// A leading bullet glyph (or `-` / `*`) followed by a space becomes "• ".
    /// Vision drops real bullet dots (M0), so in practice this catches typed `-` and `*`.
    static func normalizeBullet(_ row: String) -> String {
        let bulletGlyphs: Set<Character> = ["•", "●", "▪", "◦", "‣", "∙", "·", "-", "*"]
        guard let first = row.first, bulletGlyphs.contains(first) else { return row }
        let rest = row.dropFirst()
        guard let next = rest.first, next == " " else { return row }
        return "• " + rest.drop(while: { $0 == " " })
    }

    /// LINE BREAKS OFF: rows in a block become one paragraph, except list items, which keep their
    /// own line. A hyphen at a row's end followed by a lowercase start joins without the hyphen.
    static func joinRows(_ rows: [String]) -> String {
        var lines: [String] = []
        for row in rows {
            guard let last = lines.last, !isListItem(row) else {
                lines.append(row)
                continue
            }
            if last.hasSuffix("-"), let first = row.first, first.isLowercase {
                lines[lines.count - 1] = String(last.dropLast()) + row
            } else {
                lines[lines.count - 1] = last + " " + row
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "• item", "1. item", "12) item", "a) item".
    static func isListItem(_ row: String) -> Bool {
        if row.hasPrefix("• ") { return true }
        return row.range(of: #"^([0-9]{1,3}|[A-Za-z])[.)] "#, options: .regularExpression) != nil
    }

    private static func trimmingTrailingWhitespace(_ s: String) -> String {
        var result = Substring(s)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return String(result)
    }
}
