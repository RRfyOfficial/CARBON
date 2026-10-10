import Testing
@testable import Carbon

struct AsIsFormatterTests {
    private let formatter = AsIsFormatter()

    @Test func lineBreaksOnKeepsRowsAndSeparatesBlocks() {
        let text = ReadText(blocks: [["Week 6: Usability Testing"], ["Recruit 5 participants", "Record screen  "]])
        #expect(formatter.format(text, lineBreaks: true) == "Week 6: Usability Testing\n\nRecruit 5 participants\nRecord screen")
    }

    @Test func leadingBulletGlyphsBecomeADot() {
        let text = ReadText(blocks: [["- first", "* second", "● third", "-no space"]])
        #expect(formatter.format(text, lineBreaks: true) == "• first\n• second\n• third\n-no space")
    }

    @Test func lineBreaksOffJoinsParagraphRows() {
        let text = ReadText(blocks: [["In a think-aloud session the", "participant narrates."]])
        #expect(formatter.format(text, lineBreaks: false) == "In a think-aloud session the participant narrates.")
    }

    @Test func lineBreaksOffKeepsListItemsOnTheirOwnLines() {
        let text = ReadText(blocks: [["1. Welcome the participant", "and get consent", "2. Explain the method", "a) Read aloud"]])
        #expect(formatter.format(text, lineBreaks: false) == "1. Welcome the participant and get consent\n2. Explain the method\na) Read aloud")
    }

    @Test func lineBreaksOffRejoinsHyphenatedWords() {
        let text = ReadText(blocks: [["Retrospective think-aloud relies on mem-", "ory, which fades."]])
        #expect(formatter.format(text, lineBreaks: false) == "Retrospective think-aloud relies on memory, which fades.")
    }

    @Test func outputIsNFC() {
        let decomposed = "Cafe\u{0301}"
        #expect(formatter.format(ReadText(blocks: [[decomposed]]), lineBreaks: true) == "Café")
    }
}
