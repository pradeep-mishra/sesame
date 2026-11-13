import Foundation
import Testing
import SesameEngine

// plan-6-t7, tester step. Written from the entry plan-6-t7 of plan-6-tasks.md (Tests, `CodePreviewTests`), Decision D12, design section 5
// (Preview: "code, the stretch's stored line range, and inside it the line holding the most query words as whole words, a definition line
// first") and the DefinitionRule contract t5 pinned (DefinitionRuleTests.swift); no product source is read.
//
// SHAPES THIS FILE PINS (the entry names the call, not these; one place to edit, the helper `cpMatch`):
//   1. `CodePreview.matchLine(lines: [String], words: [String], ext: String)` is `public static` and returns the ZERO-BASED index into `lines`
//      of the match line (an `Int`, or an `Int?`: every check below compares with `==` against an integer literal).
//   2. `words` are the query words as the reader gets them from the typed text (letters, digits and the underscore, each once); a line
//      "holds" a word when the word stands in the line as a whole word, in any case: a letter, a digit or an underscore on either side
//      of it ends no word (the same rule the document and PDF marks use).
//   3. `ext` is the extension in lower case without a dot, the `ext` of `DefinitionRule.isDefinition(line:word:ext:)`; the definition
//      test is the rule of t5, so it is case-sensitive: the line declares the word exactly as it is spelled in `words`.
//   4. The order of the rules, as the design sentence reads: a definition line first; else the line holding the most distinct query words;
//      among equal lines the first; when no line holds a word, the first line (index 0). A line counts the distinct words it holds.
//   5. [PICK, not in the entry, one test: `aDefinitionLineOutranksALineThatHoldsMoreQueryWords`] "a definition line first" is read as a
//      priority over the count, as t5's search puts definition rows before the other tier-1 rows. If the controller reads it as a tie-break
//      among equal counts, that one test changes and nothing else.

private func cpMatch(_ lines: [String], _ words: [String], _ ext: String = "swift") -> Int? {
    CodePreview.matchLine(lines: lines, words: words, ext: ext)
}

@Suite("CodePreviewTests")
struct CodePreviewTests {

    // MARK: the most words

    @Test func theLineHoldingTheMostQueryWordsWins() {
        let lines = ["let a = 1", "let alpha = beta", "let gamma = 3", "let alpha = 2"]
        #expect(cpMatch(lines, ["alpha", "beta"]) == 1)
        #expect(cpMatch(lines, ["alpha", "beta", "gamma"]) == 1, "three words typed: the line with two still beats the lines with one")
        #expect(cpMatch(["x alpha", "y alpha beta", "z alpha beta gamma", "w beta"], ["alpha", "beta", "gamma"]) == 2)
    }

    @Test func aLineCountsEachQueryWordOnceHoweverOftenItStands() {
        // Three `alpha` on line 0 are one word; line 1 holds two different words.
        #expect(cpMatch(["alpha alpha alpha", "alpha beta"], ["alpha", "beta"]) == 1)
    }

    @Test func theFirstOfEqualLinesWins() {
        #expect(cpMatch(["alpha one", "alpha two", "alpha three"], ["alpha"]) == 0)
        #expect(cpMatch(["nothing here", "alpha two", "alpha three"], ["alpha"]) == 1)
        #expect(cpMatch(["x alpha", "alpha one two", "alpha two"], ["alpha", "two"]) == 1, "lines 1 and 2 hold both words: the first of them")
        #expect(cpMatch(["alpha two", "alpha two", "alpha two"], ["alpha", "two"]) == 0)
    }

    @Test func theFirstLineWhenNoLineHoldsAWord() {
        #expect(cpMatch(["import Foundation", "let x = 1", "let y = 2"], ["zzz"]) == 0)
        #expect(cpMatch(["import Foundation", "let x = 1"], []) == 0, "no words typed")
        #expect(cpMatch(["only line"], ["zzz"]) == 0)
        #expect(cpMatch(["only line"], ["line"]) == 0)
        #expect(cpMatch(["", "", "alpha"], ["alpha"]) == 2, "blank lines are lines")
        #expect(cpMatch(["", "", ""], ["alpha"]) == 0)
    }

    // MARK: whole words, any case

    @Test func aWordMatchesOnlyAsAWholeWordSoRetryDoesNotMatchRetryWithBackoff() {
        #expect(cpMatch(["retryWithBackoff(x)", "retry(x)"], ["retry"]) == 1)
        #expect(cpMatch(["retryAll()", "retry_all()", "retry9()", "my_retry = 1", "éretry()", "a.retry.b()"], ["retry"]) == 5,
                "a letter, a digit or an underscore on either side ends no word; a dot does")
        #expect(cpMatch(["retryable", "retry-count", "x"], ["retry"]) == 1, "a hyphen ends a word")
        #expect(cpMatch(["x", "(retry)"], ["retry"]) == 1)
        #expect(cpMatch(["retries", "retry"], ["retry"]) == 1, "a longer word that starts with the word is not the word")
        #expect(cpMatch(["wasretry", "x retry"], ["retry"]) == 1, "a word that ends with the word is not the word")
    }

    @Test func aWordMatchesInAnyCase() {
        #expect(cpMatch(["x", "Retry later", "retry now"], ["retry"]) == 1)
        #expect(cpMatch(["x", "RETRY LATER"], ["retry"]) == 1)
        #expect(cpMatch(["x", "// retry the call", "y"], ["retry"]) == 1, "a comment line holds the word like any other line")
    }

    // MARK: a definition line first, case-sensitive

    @Test func aDefinitionLineIsTheMatchLineBeforeAnEarlierCallOfTheSameName() {
        let lines = ["let first = zqmaker()", "func zqmaker() -> Int {", "let again = zqmaker()"]
        #expect(cpMatch(lines, ["zqmaker"]) == 1)
        #expect(cpMatch(lines, ["zqmaker"], "py") == 1, "the same rule for the other keyword languages: `func` is read for py as for swift")
        #expect(cpMatch(["x = zqpy()", "def zqpy():", "y = zqpy()"], ["zqpy"], "py") == 1)
    }

    @Test func theDefinitionTestIsCaseSensitiveSoARefreshAccessTokenTypedInAnotherCaseIsNoDefinition() {
        let lines = ["try refreshAccessToken()", "func refreshAccessToken(a: Int) {"]
        #expect(cpMatch(lines, ["refreshAccessToken"]) == 1, "spelled as declared: the definition line")
        #expect(cpMatch(lines, ["RefreshAccessToken"]) == 0, "spelled in another case: no definition, both lines hold it, the first wins")
    }

    @Test func theExtensionDecidesWhatAnAnonymousLineDeclares() {
        // A C-like declaration: a type, then the name followed by `(`. Under swift the same line is no declaration.
        let lines = ["return zqsum(x);", "int zqsum(int a) {"]
        #expect(cpMatch(lines, ["zqsum"], "c") == 1)
        #expect(cpMatch(lines, ["zqsum"], "java") == 1)
        #expect(cpMatch(lines, ["zqsum"], "swift") == 0, "int zqsum( is no swift declaration: equal lines, the first")
        #expect(cpMatch(["zqrun", "function zqrun {"], ["zqrun"], "sh") == 1)
    }

    @Test func ofTwoDefinitionLinesTheFirstWins() {
        #expect(cpMatch(["let x = 1", "func zqa() {", "func zqa(x: Int) {"], ["zqa"]) == 1)
    }

    @Test func aDefinitionLineOutranksALineThatHoldsMoreQueryWords() {
        // [PICK] line 0 holds two words and declares nothing; line 1 holds one and declares `alpha`.
        #expect(cpMatch(["let both = alpha + beta", "func alpha() {"], ["alpha", "beta"]) == 1)
    }

    @Test func aTypedPhraseTakesAnyOfItsWordsAsTheDeclaredName() {
        #expect(cpMatch(["let x = beta()", "func alpha() {", "let y = alpha()"], ["beta", "alpha"]) == 1,
                "alpha is declared on line 1: it is the definition line though beta stands first")
    }

    @Test func aNameThatIsOnlyThePrefixOfADeclaredNameIsNoDefinition() {
        // t5's rule: a typed word is a definition match only for the whole name.
        #expect(cpMatch(["let x = retry()", "func retryWithBackoff(a: Int) {"], ["retry"]) == 0)
    }
}
