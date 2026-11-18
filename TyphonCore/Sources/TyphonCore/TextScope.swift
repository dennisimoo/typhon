import Foundation

/// Decides which part of a text field Typhon should polish.
///
/// Typhon is trained on single messages, so in a long document we only send the sentences
/// around the caret, inside the caret's paragraph. All ranges are UTF-16, like AX ranges.
public enum TextScope {
    public static let maxCharacters = 320

    /// The range to polish, or `nil` when there's nothing worth sending.
    public static func span(in text: String, caret: Int) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let caret = min(max(0, caret), ns.length)

        // The caret's paragraph.
        var start = 0, end = 0, contentsEnd = 0
        ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: caret == ns.length ? max(0, caret - 1) : caret, length: 0))
        if caret == ns.length, caret > 0, ns.character(at: caret - 1) == 10 { return nil } // fresh empty line
        var range = NSRange(location: start, length: contentsEnd - start)

        if range.length > maxCharacters {
            range = sentences(in: ns, paragraph: range, around: caret)
        }
        range = trimmed(range, in: ns)
        guard range.length >= 6, range.length <= maxCharacters * 2 else { return nil }

        let candidate = ns.substring(with: range)
        let words = candidate.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, candidate.contains(where: \.isLetter) else { return nil }
        return range
    }

    /// Whether the model's answer is a plausible edit of the input (guards against rambling).
    public static func isPlausibleEdit(original: String, fixed: String) -> Bool {
        guard !fixed.isEmpty, fixed != original else { return false }
        let ratio = Double(fixed.count) / Double(max(1, original.count))
        let addsLineBreaks = fixed.contains("\n") && !original.contains("\n")
        return ratio > 0.5 && ratio < 1.8 && !addsLineBreaks
    }

    /// Whole sentences around the caret that fit in the budget, preferring the ones before it.
    private static func sentences(in ns: NSString, paragraph: NSRange, around caret: Int) -> NSRange {
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: paragraph, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        guard let index = ranges.firstIndex(where: { NSLocationInRange(caret, $0) || NSMaxRange($0) == caret })
            ?? (ranges.isEmpty ? nil : ranges.count - 1)
        else { return paragraph }

        var lower = index, upper = index
        func length() -> Int { NSMaxRange(ranges[upper]) - ranges[lower].location }
        while lower > 0, NSMaxRange(ranges[upper]) - ranges[lower - 1].location <= maxCharacters { lower -= 1 }
        while upper + 1 < ranges.count, NSMaxRange(ranges[upper + 1]) - ranges[lower].location <= maxCharacters { upper += 1 }
        if length() > maxCharacters * 2 { return ranges[index] }
        return NSRange(location: ranges[lower].location, length: length())
    }

    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        var lower = range.location, upper = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines
        while lower < upper, let scalar = Unicode.Scalar(ns.character(at: lower)), whitespace.contains(scalar) { lower += 1 }
        while upper > lower, let scalar = Unicode.Scalar(ns.character(at: upper - 1)), whitespace.contains(scalar) { upper -= 1 }
        return NSRange(location: lower, length: upper - lower)
    }
}
