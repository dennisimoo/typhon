import Foundation

/// The smallest, word-aligned change that turns an original span into the model's fix.
///
/// Accepting a suggestion should touch only the words that changed: it keeps the rest of the
/// field (formatting, undo history, anything typed meanwhile) intact. All ranges are UTF-16.
public struct SmartEdit: Equatable, Sendable {
    /// Range in the *field* text to replace.
    public var range: NSRange
    /// What must currently be in `range` for the edit to apply.
    public var old: String
    /// The replacement.
    public var new: String

    public var delta: Int { (new as NSString).length - (old as NSString).length }

    /// Builds the edit for `original` (found at `spanStart` in the field) → `fixed`.
    /// Returns nil when nothing changes.
    public static func make(original: String, fixed rawFixed: String, spanStart: Int) -> SmartEdit? {
        let fixed = tidy(original: original, fixed: rawFixed)
        guard fixed != original else { return nil }
        let a = Array(original), b = Array(fixed)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        // Widen to whole words so we never splice into the middle of one.
        var start = prefix
        while start > 0, !a[start - 1].isWhitespace { start -= 1 }
        var endA = a.count - suffix
        while endA < a.count, !a[endA].isWhitespace { endA += 1 }
        let tail = a.count - endA            // characters kept after the edit
        let startB = start                   // the shared prefix is identical in both
        let endB = b.count - tail

        guard endB >= startB else { return nil }
        let old = String(a[start..<endA])
        let new = String(b[startB..<endB])
        let location = spanStart + (String(a[..<start]) as NSString).length
        return SmartEdit(range: NSRange(location: location, length: (old as NSString).length), old: old, new: new)
    }

    /// Finds where this edit applies in `text` now, tolerating text added or removed elsewhere.
    /// Returns nil if the words to replace aren't there any more.
    public func rebased(onto text: String) -> SmartEdit? {
        let ns = text as NSString
        if NSMaxRange(range) <= ns.length, ns.substring(with: range) == old { return self }
        guard !old.isEmpty else { return nil }
        // Search near the old position and pick the closest exact match.
        let window = 400
        let lower = max(0, range.location - window)
        let upper = min(ns.length, NSMaxRange(range) + window)
        var best: NSRange?
        var searchRange = NSRange(location: lower, length: upper - lower)
        while searchRange.length > 0 {
            let found = ns.range(of: old, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - range.location) < abs(best!.location - range.location) {
                best = found
            }
            let next = found.location + 1
            searchRange = NSRange(location: next, length: upper - next)
        }
        guard let best else { return nil }
        var copy = self
        copy.range = best
        return copy
    }

    /// Where the caret should go after the edit, keeping it where the user left it.
    public func caret(after caret: Int) -> Int {
        if caret >= NSMaxRange(range) { return caret + delta }
        if caret > range.location { return range.location + (new as NSString).length }
        return caret
    }

    /// Light post-processing of the model's output for in-place edits.
    /// - Keeps the user's choice not to end with a full stop (people rarely end chat
    ///   messages with one, and it's wrong mid-sentence). "?" and "!" are kept: they carry meaning.
    public static func tidy(original: String, fixed: String) -> String {
        let originalEnd = original.last
        if fixed.hasSuffix("."), !fixed.hasSuffix(".."),
           let end = originalEnd, !".!?…".contains(end) {
            return String(fixed.dropLast())
        }
        return fixed
    }
}
