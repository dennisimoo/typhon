import Foundation

/// A run of text in a word-level diff.
public struct DiffSegment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case same, removed, added }
    public let id: Int
    public let kind: Kind
    public let text: String
}

/// Word-level diff (LCS over whitespace-separated tokens, keeping the original spacing).
public enum WordDiff {
    public static func diff(_ old: String, _ new: String) -> [DiffSegment] {
        let a = tokens(old), b = tokens(new)
        let n = a.count, m = b.count
        // LCS table on word identity (whitespace is carried along with its word).
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i].word == b[j].word
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var raw: [(DiffSegment.Kind, String)] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i].word == b[j].word {
                raw.append((.same, b[j].text)); i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                raw.append((.added, b[j].text)); j += 1
            } else {
                raw.append((.removed, a[i].text)); i += 1
            }
        }

        // Group each run of changes into one "removed" segment followed by one "added" segment.
        var merged: [(DiffSegment.Kind, String)] = []
        var removed = "", added = ""
        func flush() {
            if !removed.isEmpty { merged.append((.removed, removed)) }
            if !added.isEmpty { merged.append((.added, added)) }
            removed = ""; added = ""
        }
        for (kind, text) in raw {
            switch kind {
            case .removed: removed += text
            case .added: added += text
            case .same:
                flush()
                if let last = merged.last, last.0 == .same { merged[merged.count - 1].1 += text }
                else { merged.append((.same, text)) }
            }
        }
        flush()
        return merged.enumerated().map { DiffSegment(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    /// Number of words that differ, used to skip no-op suggestions.
    public static func changedWordCount(_ old: String, _ new: String) -> Int {
        diff(old, new).filter { $0.kind == .added }.reduce(0) { $0 + tokens($1.text).count }
    }

    private struct Token { let word: String; let text: String }

    /// Splits into words, attaching trailing whitespace to each word so we can rebuild the text.
    private static func tokens(_ s: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var trailing = ""
        for ch in s {
            if ch.isWhitespace {
                trailing.append(ch)
            } else {
                if !trailing.isEmpty {
                    result.append(Token(word: current, text: current + trailing))
                    current = ""; trailing = ""
                }
                current.append(ch)
            }
        }
        if !current.isEmpty || !trailing.isEmpty { result.append(Token(word: current, text: current + trailing)) }
        return result
    }
}
