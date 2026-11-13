import Foundation

public struct CodeStretch: Sendable {
    public let index: Int
    public let startLine: Int
    public let endLine: Int
    public let text: String
}

public struct CodeStep: Sendable {
    public let stretchCount: Int
    public let stretches: [CodeStretch]
    public let nameWords: String
}

public enum CodeReadError: Error, Equatable {
    case notAdmitted
    case changed
    case cannotOpen
    case damaged
    case tooLarge
}

public enum CodeReader {
    public static let stretchCharacters = 1800
    public static let stepStretches = 40
    public static let maxBytes: Int64 = 5 * 1_048_576

    public static func read(path: String, expecting: FileIdentity, fromStretch: Int) throws -> CodeStep {
        guard let admitted = Rules.admit(path: path), admitted.kind == "code" else { throw CodeReadError.notAdmitted }
        guard FileIdentity.of(path: path) == expecting else { throw CodeReadError.changed }
        guard expecting.size <= maxBytes else { throw CodeReadError.tooLarge }
        let data: Data
        do { data = try FileGate.read(admitted) } catch { throw CodeReadError.cannotOpen }
        guard FileIdentity.of(path: path) == expecting else { throw CodeReadError.changed }

        let all = try stretches(from: data)
        guard fromStretch >= 0, fromStretch == 0 || fromStretch < all.count else { throw CodeReadError.damaged }
        let step = all.enumerated().dropFirst(fromStretch).prefix(stepStretches).map { index, piece in
            CodeStretch(index: index, startLine: piece.start, endLine: piece.end, text: piece.text)
        }
        return CodeStep(stretchCount: all.count, stretches: step, nameWords: PhotoReader.nameWords(for: path))
    }

    private struct Piece {
        let start: Int
        let end: Int
        let text: String
    }

    private static func stretches(from data: Data) throws -> [Piece] {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else { throw CodeReadError.damaged }

        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.last == 0x0D ? line.dropLast() : line
            return String(decoding: trimmed, as: UTF8.self)
        }
        if lines.last == "" { lines.removeLast() }

        var pieces: [Piece] = []
        var current: [String] = []
        var currentStart = 0
        var currentLength = 0
        func flush(through end: Int) {
            guard !current.isEmpty else { return }
            pieces.append(Piece(start: currentStart, end: end, text: current.joined(separator: "\n")))
            current = []
            currentLength = 0
        }
        for (offset, line) in lines.enumerated() {
            let number = offset + 1
            let length = line.utf16.count
            if length > stretchCharacters {
                flush(through: number - 1)
                for part in split(line) { pieces.append(Piece(start: number, end: number, text: part)) }
                continue
            }
            if !current.isEmpty, currentLength + 1 + length > stretchCharacters { flush(through: number - 1) }
            if current.isEmpty {
                currentStart = number
                currentLength = length
            } else {
                currentLength += 1 + length
            }
            current.append(line)
        }
        flush(through: lines.count)
        return pieces.filter { !$0.text.allSatisfy(\.isWhitespace) }
    }

    private static func split(_ line: String) -> [String] {
        var parts: [String] = []
        var part = ""
        var length = 0
        for character in line {
            let units = character.utf16.count
            if length + units > stretchCharacters, !part.isEmpty {
                parts.append(part)
                part = ""
                length = 0
            }
            part.append(character)
            length += units
        }
        if !part.isEmpty { parts.append(part) }
        return parts
    }
}
