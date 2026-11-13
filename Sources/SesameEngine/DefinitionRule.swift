import Foundation

public enum DefinitionRule {
    private static let keywordExtensions: Set<String> = ["swift", "go", "py", "rb", "js", "ts", "tsx", "jsx", "rs", "kt"]
    private static let keywords: Set<String> = [
        "func", "def", "function", "fn", "fun", "class", "struct", "enum", "interface", "trait", "type",
    ]
    private static let cLikeExtensions: Set<String> = ["c", "h", "cpp", "java"]
    private static let statementWords: Set<String> = [
        "return", "else", "throw", "new", "delete", "case", "goto", "do", "yield", "await", "co_return",
    ]
    private static let typeCharacters: Set<Character> = [" ", "\t", "*", "&", "<", ">", ",", "[", "]", ":"]

    public static func isDefinition(line: String, word: String, ext: String) -> Bool {
        guard !word.isEmpty else { return false }
        let characters = Array(line.drop { $0 == " " || $0 == "\t" })
        guard !characters.isEmpty, !isComment(characters) else { return false }
        let name = Array(word)
        let found = occurrences(of: name, in: characters)
        if keywordExtensions.contains(ext) { return found.contains { follows(keywords, in: characters, before: $0) } }
        if ext == "sh" { return found.contains { follows(["function"], in: characters, before: $0) } }
        if cLikeExtensions.contains(ext) {
            return found.contains { startsWithType(characters, before: $0) && opensBracket(characters, after: $0 + name.count) }
        }
        return false
    }

    static func declares(stretch: String, words: [String], ext: String) -> Bool {
        stretch.split(whereSeparator: \.isNewline).contains { line in
            words.contains { isDefinition(line: String(line), word: $0, ext: ext) }
        }
    }

    private static func isComment(_ line: [Character]) -> Bool {
        line[0] == "#" || line[0] == "*" || line.starts(with: ["/", "/"]) || line.starts(with: ["/", "*"])
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func occurrences(of name: [Character], in line: [Character]) -> [Int] {
        guard line.count >= name.count else { return [] }
        return (0...(line.count - name.count)).filter { start in
            let end = start + name.count
            return line[start..<end].elementsEqual(name)
                && (start == 0 || !isIdentifier(line[start - 1]))
                && (end == line.count || !isIdentifier(line[end]))
        }
    }

    private static func follows(_ words: Set<String>, in line: [Character], before start: Int) -> Bool {
        guard start > 0, line[start - 1] == " " || line[start - 1] == "\t" else { return false }
        var end = start
        while end > 0, line[end - 1] == " " || line[end - 1] == "\t" { end -= 1 }
        var begin = end
        while begin > 0, isIdentifier(line[begin - 1]) { begin -= 1 }
        return begin < end && words.contains(String(line[begin..<end]))
    }

    private static func startsWithType(_ line: [Character], before start: Int) -> Bool {
        let before = line[0..<start]
        guard let last = before.last, last == " " || last == "\t" || last == "*" || last == "&",
              before.allSatisfy({ isIdentifier($0) || typeCharacters.contains($0) }) else { return false }
        let words = String(before).split { !isIdentifier($0) }.map(String.init)
        return !words.isEmpty && words.allSatisfy { !statementWords.contains($0) }
    }

    private static func opensBracket(_ line: [Character], after start: Int) -> Bool {
        var index = start
        while index < line.count, line[index] == " " || line[index] == "\t" { index += 1 }
        return index < line.count && line[index] == "("
    }
}
