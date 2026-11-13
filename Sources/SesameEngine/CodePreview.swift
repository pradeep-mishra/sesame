import Foundation

public enum CodePreview {
    static let windowCharacters = CodeReader.stretchCharacters
    static let windowLines = 80

    public static func matchLine(lines: [String], words: [String], ext: String) -> Int {
        guard !lines.isEmpty, !words.isEmpty else { return 0 }
        let wanted = Set(words.map { $0.lowercased() })
        var best = 0, bestCount = 0
        for (index, line) in lines.enumerated() {
            if declares(line, words: words, wanted: wanted, ext: ext) { return index }
            let count = tokens(of: line).intersection(wanted).count
            if count > bestCount { best = index; bestCount = count }
        }
        return best
    }

    static func lines(of data: Data) -> [String]? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else { return nil }
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map { line -> String in
            String(decoding: line.last == 0x0D ? line.dropLast() : line, as: UTF8.self)
        }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func window(lines: [String], around centre: Int) -> ClosedRange<Int> {
        var low = centre, high = centre
        var characters = lines[centre].utf16.count
        var below = true
        while high - low + 1 < windowLines, characters < windowCharacters, low > 0 || high < lines.count - 1 {
            if below && low > 0 {
                low -= 1
                characters += lines[low].utf16.count + 1
            } else if high < lines.count - 1 {
                high += 1
                characters += lines[high].utf16.count + 1
            } else if low > 0 {
                low -= 1
                characters += lines[low].utf16.count + 1
            }
            below.toggle()
        }
        return low...high
    }

    private static func tokens(of text: String) -> Set<String> {
        Set(text.split { !isWordCharacter($0) }.map { $0.lowercased() })
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func declares(_ line: String, words: [String], wanted: Set<String>, ext: String) -> Bool {
        if words.contains(where: { DefinitionRule.isDefinition(line: line, word: $0, ext: ext) }) { return true }
        guard wanted.count >= 2 else { return false }
        return line.split(whereSeparator: { !isWordCharacter($0) }).contains { name in
            parts(of: String(name)).intersection(wanted).count >= 2
                && DefinitionRule.isDefinition(line: line, word: String(name), ext: ext)
        }
    }

    private static func parts(of name: String) -> Set<String> {
        var parts = Set<String>()
        var part = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            if character == "_" {
                if !part.isEmpty { parts.insert(part.lowercased()); part = "" }
                continue
            }
            if character.isUppercase, !part.isEmpty {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if !previous.isUppercase || nextIsLower { parts.insert(part.lowercased()); part = "" }
            }
            part.append(character)
        }
        if !part.isEmpty { parts.insert(part.lowercased()) }
        return parts
    }
}
