import Foundation
import Testing
import SesameEngine

// plan-6-t5, tester step, part 1: the definition rule. Written from the entry plan-6-t5 of plan-6-tasks.md (its Tests paragraph),
// design section 9 (the definition rule of S2(e), guess G19). No product source was read. The two tests that read the kit's language
// table and the files `kit-fixtures.sh build langs` wrote were retired in plan-7-t9, which deletes the table and that build; the
// pure rule tests below stay (dormant logic, design-job2.md D2).
//
// Shape the tests pin (the entry names `DefinitionRule.isDefinition(line:word:ext:)`; if a type or label is wrong, ask for a
// test change). All of it is `public` in SesameEngine, because this file uses `import SesameEngine`, not `@testable`:
//
//   DefinitionRule.isDefinition(line: String, word: String, ext: String) -> Bool      (static, pure, no file is opened)
//       line: one line of a code file, as stored in `fts`, leading blanks kept
//       word: one typed word, case-sensitive, whole word
//       ext:  the extension without a dot, lower case: swift go py rb js ts tsx jsx rs kt sh c h cpp java
//
// What each family pins, from the entry:
//   - swift go py rb js ts tsx jsx rs kt: true when the line declares `word` right after one of
//     `func def function fn fun class struct enum interface trait type` (a modifier before the keyword, as in `export function`
//     or `pub fn`, does not matter: the fixtures of ts, tsx, jsx hold `export function`).
//   - sh: the `function name` form.
//   - c h cpp java: a line that starts with a type and has the name followed by `(`.
//   - false for a comment, a call, a longer name (whole word), another case.
// Not pinned, on purpose: a keyword of one family used with another family's extension, an extension not listed, an empty word,
// a keyword inside a comment, a call inside a declaration (`int x = computeChecksum(y);`), a pointer or `::` return type,
// two spaces after the keyword, and anything about a line that holds more than one declaration.
//
// Every expected value is a hand table in this file.

// MARK: hand-written tables

private let keywordExts = ["swift", "go", "py", "rb", "js", "ts", "tsx", "jsx", "rs", "kt"]
private let keywords = ["func", "def", "function", "fn", "fun", "class", "struct", "enum", "interface", "trait", "type"]
private let cLikeExts = ["c", "h", "cpp", "java"]
private let name = "refreshAccessToken"

private func yes(_ line: String, _ word: String, _ ext: String) -> Bool {
    DefinitionRule.isDefinition(line: line, word: word, ext: ext)
}

private func def(_ line: String, _ ext: String) -> Bool { yes(line, name, ext) }

@Suite("DefinitionRuleTests")
struct DefinitionRuleTests {

    // MARK: the entry's own named lines

    @Test func theEntrysNamedLinesGiveTheEntrysAnswersForSwift() {
        #expect(yes("func refreshAccessToken(", "refreshAccessToken", "swift"))
        #expect(!yes("func RefreshAccessToken(", "refreshAccessToken", "swift"), "case")
        #expect(!yes("// refreshAccessToken is called", "refreshAccessToken", "swift"))
        #expect(!yes("try refreshAccessToken()", "refreshAccessToken", "swift"))
        #expect(!yes("class refreshAccessTokenFactory", "refreshAccessToken", "swift"), "whole word")
    }

    @Test func theEntrysNamedLinesGiveTheEntrysAnswersForTheCLikeFamily() {
        for ext in cLikeExts {
            #expect(yes("int computeChecksum(const char *p) {", "computeChecksum", ext), "\(ext)")
            #expect(yes("static int computeChecksum(", "computeChecksum", ext), "\(ext)")
            #expect(!yes("return computeChecksum(x);", "computeChecksum", ext), "\(ext)")
            #expect(!yes("computeChecksum(x);", "computeChecksum", ext), "\(ext)")
        }
    }

    @Test func theEntrysNamedLinesGiveTheEntrysAnswersForSh() {
        #expect(yes("function computeChecksum {", "computeChecksum", "sh"))
        #expect(yes("function computeChecksum()", "computeChecksum", "sh"))
    }

    // MARK: the keyword forms: swift go py rb js ts tsx jsx rs kt

    @Test func everyKeywordDeclaresTheWordInEveryKeywordLanguage() {
        var bad: [String] = []
        var rows = 0
        for ext in keywordExts {
            for kw in keywords {
                for line in ["\(kw) \(name)(", "\(kw) \(name) {", "\(kw) \(name)", "    \(kw) \(name)(token: String) -> Bool {"] {
                    rows += 1
                    if !def(line, ext) { bad.append("\(ext): \(line.debugDescription)") }
                }
            }
        }
        #expect(rows == 440)
        #expect(bad.isEmpty, "\(bad.count) of \(rows) not a definition, first: \(bad.prefix(4))")
    }

    @Test func aKeywordFormWithAnotherCaseOrALongerOrShorterNameIsNotADefinition() {
        var bad: [String] = []
        var rows = 0
        for ext in keywordExts {
            for kw in keywords {
                for line in [
                    "\(kw) RefreshAccessToken(", "\(kw) refreshaccesstoken(", "\(kw) refreshAccessTokenFactory",
                    "\(kw) refreshAccessTokenFactory(", "\(kw) xrefreshAccessToken(", "\(kw) refreshAccess(",
                    "\(kw) other(refreshAccessToken: Int)", "\(kw) other { refreshAccessToken() }",
                ] {
                    rows += 1
                    if def(line, ext) { bad.append("\(ext): \(line.debugDescription)") }
                }
            }
        }
        #expect(rows == 880)
        #expect(bad.isEmpty, "\(bad.count) of \(rows) taken for a definition, first: \(bad.prefix(4))")
    }

    @Test func aCommentACallOrAMentionIsNotADefinitionInAnyKeywordLanguage() {
        let lines = [
            "// refreshAccessToken is called", "# refreshAccessToken is called", "/// refreshAccessToken", "try refreshAccessToken()",
            "let t = refreshAccessToken()", "return refreshAccessToken(x)", "refreshAccessToken()", "await refreshAccessToken()",
            "    token = refreshAccessToken(old)", "class refreshAccessTokenFactory", "print(refreshAccessToken)", "",
            "   ", "func", "def ", "refreshAccessToken",
        ]
        var bad: [String] = []
        for ext in keywordExts {
            for line in lines where def(line, ext) { bad.append("\(ext): \(line.debugDescription)") }
        }
        #expect(bad.isEmpty, "\(bad.count) taken for a definition, first: \(bad.prefix(4))")
    }

    @Test func aModifierBeforeTheKeywordStillDeclaresTheWord() {
        let cases: [(ext: String, line: String)] = [
            ("js", "export function refreshAccessToken(bytes) {"), ("ts", "export function refreshAccessToken(bytes: number[]): number {"),
            ("tsx", "export function refreshAccessToken(props: Props) {"), ("jsx", "export default function refreshAccessToken() {"),
            ("ts", "export async function refreshAccessToken() {"), ("rs", "pub fn refreshAccessToken(data: &[u8]) -> u32 {"),
            ("rs", "pub(crate) fn refreshAccessToken() {"), ("swift", "public func refreshAccessToken() {"),
            ("swift", "    private static func refreshAccessToken(_ x: Int) {"), ("swift", "public final class refreshAccessToken {"),
            ("kt", "private fun refreshAccessToken(): Int {"), ("kt", "internal data class refreshAccessToken(val a: Int)"),
            ("py", "    async def refreshAccessToken(self):"), ("go", "func refreshAccessToken() error {"),
            ("ts", "export interface refreshAccessToken {"), ("ts", "export type refreshAccessToken = string"),
        ]
        var bad: [String] = []
        for c in cases where !def(c.line, c.ext) { bad.append("\(c.ext): \(c.line.debugDescription)") }
        #expect(bad.isEmpty, "\(bad.count) of \(cases.count) not a definition, first: \(bad.prefix(4))")
    }

    @Test func theWordMustBeTheWholeNameAndCaseSensitiveWhateverTheLine() {
        let line = "func refreshAccessToken(old: String) -> String {"
        #expect(yes(line, "refreshAccessToken", "swift"))
        for word in ["refresh", "Token", "AccessToken", "refreshAccessTokenX", "RefreshAccessToken", "refreshaccesstoken", "refreshAccessToke", "old", "String"] {
            #expect(!yes(line, word, "swift"), "word \(word)")
        }
    }

    // MARK: sh

    @Test func theShFunctionFormDeclaresTheWord() {
        for line in ["function computeChecksum {", "function computeChecksum()", "function computeChecksum() {", "  function computeChecksum {", "function computeChecksum"] {
            #expect(yes(line, "computeChecksum", "sh"), "\(line.debugDescription)")
        }
    }

    @Test func aShCallACommentAnotherNameOrAnotherCaseIsNotADefinition() {
        for line in [
            "computeChecksum 1 2 3", "  computeChecksum 1 2 3", "function ComputeChecksum {", "function computeChecksumAll {",
            "function xcomputeChecksum {", "# computeChecksum is called", "x=$(computeChecksum 1 2)", "echo computeChecksum",
            "function other { computeChecksum 1 2; }", "function other() {", "",
        ] {
            #expect(!yes(line, "computeChecksum", "sh"), "\(line.debugDescription)")
        }
    }

    // MARK: c h cpp java

    @Test func aTypeThenTheNameThenAnOpenBracketIsADefinitionInEveryCLikeLanguage() {
        let lines = [
            "int computeChecksum(const char *p) {", "static int computeChecksum(", "unsigned int computeChecksum(const unsigned char *data, int n) {",
            "static inline unsigned int computeChecksum(const unsigned char *data, int n) {", "    public static int computeChecksum(byte[] data) {",
            "int computeChecksum(const char *p);", "void computeChecksum(void)", "    int computeChecksum(", "boolean computeChecksum(String s) {",
            "String computeChecksum(byte[] data) {",
        ]
        var bad: [String] = []
        for ext in cLikeExts {
            for line in lines where !yes(line, "computeChecksum", ext) { bad.append("\(ext): \(line.debugDescription)") }
        }
        #expect(bad.isEmpty, "\(bad.count) of \(cLikeExts.count * lines.count) not a definition, first: \(bad.prefix(4))")
    }

    @Test func aCallAMentionAnotherNameOrAnotherCaseIsNotADefinitionInAnyCLikeLanguage() {
        let lines = [
            "return computeChecksum(x);", "computeChecksum(x);", "    return computeChecksum(d, 3);", "        return Checksum.computeChecksum(new byte[] {1, 2, 3});",
            "int ComputeChecksum(const char *p) {", "int computechecksum(const char *p) {", "int computeChecksumAll(const char *p) {",
            "int xcomputeChecksum(const char *p) {", "int computeChecksum;", "int computeChecksum = 3;", "// computeChecksum is called",
            "static int other(int computeChecksum) {", "computeChecksum", "",
        ]
        var bad: [String] = []
        for ext in cLikeExts {
            for line in lines where yes(line, "computeChecksum", ext) { bad.append("\(ext): \(line.debugDescription)") }
        }
        #expect(bad.isEmpty, "\(bad.count) of \(cLikeExts.count * lines.count) taken for a definition, first: \(bad.prefix(4))")
    }

    @Test func theNameMustBeTheWholeNameInTheCLikeFormToo() {
        let line = "static int computeChecksum(const char *p) {"
        for ext in cLikeExts {
            #expect(yes(line, "computeChecksum", ext), "\(ext)")
            for word in ["compute", "Checksum", "computeChecksumX", "ComputeChecksum", "p", "int"] {
                #expect(!yes(line, word, ext), "\(ext) word \(word)")
            }
        }
    }
}
