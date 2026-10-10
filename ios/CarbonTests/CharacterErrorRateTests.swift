import Testing
@testable import Carbon

struct CharacterErrorRateTests {
    @Test func identicalTextIsZero() {
        #expect(CharacterErrorRate.of("Next steps", truth: "Next steps") == 0)
    }

    @Test func oneTypoInTenCharacters() {
        #expect(CharacterErrorRate.of("Next stejs", truth: "Next steps") == 0.1)
    }

    @Test func whitespaceAndLineBreaksDontCount() {
        #expect(CharacterErrorRate.of("Task  Round 1\nRound 2", truth: "Task Round 1 Round 2") == 0)
    }

    @Test func typographicVariantsAndBulletsDontCount() {
        #expect(CharacterErrorRate.of("\u{201C}Now?\u{201D} \u{2014} it\u{2019}s", truth: "\"Now?\" - it's") == 0)
        #expect(CharacterErrorRate.of("Fix the issues", truth: "• Fix the issues") == 0)
    }

    @Test func emptyTruthHasNoRate() {
        #expect(CharacterErrorRate.of("anything", truth: "  \n") == nil)
    }
}
