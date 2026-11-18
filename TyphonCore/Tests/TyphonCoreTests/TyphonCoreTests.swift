import Foundation
import Testing

@testable import TyphonCore

@Suite struct WordDiffTests {
    @Test func marksChangedWords() {
        let segments = WordDiff.diff("cna u pikc up milk", "Can you pick up milk?")
        #expect(segments.map(\.kind) == [.removed, .added, .same, .removed, .added])
        #expect(segments.filter { $0.kind != .removed }.map(\.text).joined() == "Can you pick up milk?")
        #expect(segments.filter { $0.kind != .added }.map(\.text).joined() == "cna u pikc up milk")
    }

    @Test func identicalTextHasNoChanges() {
        #expect(WordDiff.diff("all good here", "all good here").map(\.kind) == [.same])
        #expect(WordDiff.changedWordCount("all good here", "all good here") == 0)
    }

    @Test func countsChangedWords() {
        #expect(WordDiff.changedWordCount("teh cat sat", "The cat sat.") == 2)
    }
}

@Suite struct TextScopeTests {
    @Test func wholeShortMessage() {
        let text = "cna u pikc up some milk"
        #expect(TextScope.span(in: text, caret: (text as NSString).length) == NSRange(location: 0, length: 23))
    }

    @Test func onlyTheCaretParagraph() throws {
        let text = "First paragraph is fine.\nteh second one needs work\nThird."
        let caret = (text as NSString).range(of: "needs").location
        let range = try #require(TextScope.span(in: text, caret: caret))
        #expect((text as NSString).substring(with: range) == "teh second one needs work")
    }

    @Test func trimsWhitespace() throws {
        let text = "   hello tehre   "
        let range = try #require(TextScope.span(in: text, caret: 10))
        #expect((text as NSString).substring(with: range) == "hello tehre")
    }

    @Test func skipsTooShortOrEmptyLines() {
        #expect(TextScope.span(in: "hi", caret: 2) == nil)
        #expect(TextScope.span(in: "first line ok\n", caret: 14) == nil)
        #expect(TextScope.span(in: "", caret: 0) == nil)
    }

    @Test func longParagraphUsesSentencesNearCaret() throws {
        let sentence = "This sentence is perfectly fine and has quite a few words in it. "
        let text = String(repeating: sentence, count: 10) + "But teh last one has a typo"
        let range = try #require(TextScope.span(in: text, caret: (text as NSString).length))
        let picked = (text as NSString).substring(with: range)
        #expect(picked.hasSuffix("But teh last one has a typo"))
        #expect(picked.count <= TextScope.maxCharacters)
    }

    @Test func emojiUsesUTF16Offsets() throws {
        let text = "👋 hey hwo are u"
        let range = try #require(TextScope.span(in: text, caret: (text as NSString).length))
        #expect((text as NSString).substring(with: range) == text)
    }

    @Test func plausibility() {
        #expect(TextScope.isPlausibleEdit(original: "teh cat", fixed: "The cat."))
        #expect(!TextScope.isPlausibleEdit(original: "same", fixed: "same"))
        #expect(!TextScope.isPlausibleEdit(original: "hi there", fixed: String(repeating: "word ", count: 20)))
    }
}

@Suite struct ModelStoreTests {
    @Test func manifestIsPinned() {
        #expect(ModelManifest.revision.count == 40)
        #expect(ModelManifest.core.contains { $0.path == "model.safetensors" && $0.sha256 != nil })
        #expect(ModelManifest.url(for: ModelManifest.core[0]).absoluteString.contains(ModelManifest.revision))
    }

    @Test func installDetectionUsesSizes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root)
        #expect(!store.hasCore)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let file = ModelManifest.core[1]
        try Data(count: Int(file.size)).write(to: store.directory.appending(path: file.path))
        #expect(store.isInstalled([file]))
        #expect(store.bytesOnDisk([file]) == file.size)
    }
}

@Suite struct SmartEditTests {
    private func apply(_ edit: SmartEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.new)
    }

    @Test func onlyTouchesChangedWords() throws {
        let text = "Hey, are we stil on for tonight"
        let edit = try #require(SmartEdit.make(original: text, fixed: "Hey, are we still on for tonight?", spanStart: 0))
        #expect(edit.old == "stil on for tonight")
        #expect(apply(edit, to: text) == "Hey, are we still on for tonight?")
    }

    @Test func singleWordInTheMiddle() throws {
        let text = "I think teh plan works"
        let edit = try #require(SmartEdit.make(original: text, fixed: "I think the plan works", spanStart: 0))
        #expect(edit.old == "teh")
        #expect(edit.new == "the")
        #expect(edit.range == NSRange(location: 8, length: 3))
    }

    @Test func dropsAddedFullStop() throws {
        let edit = try #require(SmartEdit.make(original: "pls send teh report", fixed: "Please send the report.", spanStart: 0))
        #expect(apply(edit, to: "pls send teh report") == "Please send the report")
    }

    @Test func keepsQuestionMark() throws {
        let edit = try #require(SmartEdit.make(original: "cna u come", fixed: "Can you come?", spanStart: 0))
        #expect(apply(edit, to: "cna u come") == "Can you come?")
    }

    @Test func noOpWhenOnlyAFullStopWasAdded() {
        #expect(SmartEdit.make(original: "All good here", fixed: "All good here.", spanStart: 0) == nil)
    }

    @Test func offsetBySpanStartInUTF16() throws {
        let field = "👋 First line\nteh second"
        let start = (field as NSString).range(of: "teh second").location
        let edit = try #require(SmartEdit.make(original: "teh second", fixed: "The second", spanStart: start))
        #expect(apply(edit, to: field) == "👋 First line\nThe second")
    }

    @Test func rebasesWhenUserKeptTyping() throws {
        let edit = try #require(SmartEdit.make(original: "teh cat sat", fixed: "The cat sat", spanStart: 0))
        let typedMore = "teh cat sat on teh mat"
        let rebased = try #require(edit.rebased(onto: typedMore))
        #expect(apply(rebased, to: typedMore) == "The cat sat on teh mat")
    }

    @Test func rebasesWhenTextWasInsertedBefore() throws {
        let edit = try #require(SmartEdit.make(original: "teh cat", fixed: "The cat", spanStart: 6))
        let shifted = "Hello there, teh cat"
        let rebased = try #require(edit.rebased(onto: shifted))
        #expect(apply(rebased, to: shifted) == "Hello there, The cat")
    }

    @Test func refusesWhenWordsAreGone() throws {
        let edit = try #require(SmartEdit.make(original: "teh cat", fixed: "The cat", spanStart: 0))
        #expect(edit.rebased(onto: "a dog") == nil)
    }

    @Test func caretStaysWithUser() throws {
        let edit = try #require(SmartEdit.make(original: "I think teh plan works", fixed: "I think the plan works", spanStart: 0))
        #expect(edit.caret(after: 22) == 22)
        let longer = try #require(SmartEdit.make(original: "u ok", fixed: "you ok", spanStart: 0))
        #expect(longer.caret(after: 4) == 6)
    }
}
