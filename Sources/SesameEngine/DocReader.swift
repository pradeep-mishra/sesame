import AppKit
import Foundation

/// One piece of a document's text: its place in the whole text (0-based `index`), the UTF-16 offsets `start` and `end`
/// (exclusive) into the text `DocReader.text(from:extension:)` gives, and that slice of it.
public struct DocChunk: Sendable {
    public let index: Int
    public let start: Int
    public let end: Int
    public let text: String
}

/// What one call of `DocReader.read` returns: the number of chunks of the whole text, up to `stepChunks` of them from
/// `fromChunk` on, and the words of the file's own name and folder.
public struct DocStep: Sendable {
    public let chunkCount: Int
    public let chunks: [DocChunk]
    public let nameWords: String
}

public enum DocReadError: Error, Equatable {
    /// The path is gone, is not a regular document any more, or `Rules.admit` no longer takes it.
    case notAdmitted
    /// Its size, modified time or inode differ from `expecting`, before or after the read.
    case changed
    /// The bytes could not be got: the process may not open the file. The caller leaves it to be tried again.
    case cannotOpen
    /// The bytes were read and no text can be got from them (not utf-8, not a zip, cut short, or not a document).
    case unreadable
}

/// Document file to text chunks (design sections 3 and 4): stat before and after, the bytes read through `FileGate`,
/// txt and md as utf-8, utf-16 with a byte-order mark or Windows-1252, html by a plain tokenizer and the other types through the system's text readers, then cut in chunks of about
/// `chunkCharacters`. The file is opened only through `FileGate`.
public enum DocReader {
    /// A chunk is cut at a space or line end at most `lookBack` units before this many UTF-16 units, else at exactly this many.
    public static let chunkCharacters = 1600
    /// A long file is read this many chunks at a time.
    public static let stepChunks = 40
    private static let lookBack = 200

    public static func read(path: String, expecting: FileIdentity, fromChunk: Int) throws -> DocStep {
        guard let admitted = Rules.admit(path: path), admitted.kind == "doc" else { throw DocReadError.notAdmitted }
        guard FileIdentity.of(path: path) == expecting else { throw DocReadError.changed }
        let data: Data
        do { data = try FileGate.read(admitted) } catch { throw DocReadError.cannotOpen }
        guard FileIdentity.of(path: path) == expecting else { throw DocReadError.changed }

        let text = try text(from: data, extension: (path as NSString).pathExtension)
        let cuts = Self.cuts(of: text as NSString)
        guard fromChunk >= 0, fromChunk == 0 || fromChunk < cuts.count else { throw DocReadError.unreadable }
        let whole = text as NSString
        let chunks = cuts.enumerated().dropFirst(fromChunk).prefix(stepChunks).map { index, range in
            DocChunk(index: index, start: range.location, end: range.location + range.length,
                     text: whole.substring(with: range))
        }
        return DocStep(chunkCount: cuts.count, chunks: Array(chunks), nameWords: PhotoReader.nameWords(for: path))
    }

    /// The text of a document's bytes, with no NUL in it (the index binds text up to the first NUL). `ext` is the
    /// extension without its dot, in any letter case.
    public static func text(from data: Data, extension ext: String) throws -> String {
        let text = try rawText(from: data, extension: ext)
        guard text.unicodeScalars.contains(where: { $0.value == 0 }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0 }))
    }

    /// txt and md: utf-8, else utf-16 with a byte-order mark (checked by hand: Foundation's BOM-less `.utf16` takes any
    /// bytes), else Windows-1252, which leaves its five undefined bytes unreadable.
    private static func plainText(from data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            let encoding: String.Encoding = data[data.startIndex] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            guard let text = String(data: data.dropFirst(2), encoding: encoding) else { throw DocReadError.unreadable }
            return text
        }
        guard let text = String(data: data, encoding: .windowsCP1252) else { throw DocReadError.unreadable }
        return text
    }

    private static func rawText(from data: Data, extension ext: String) throws -> String {
        let type: NSAttributedString.DocumentType
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext.lowercased() {
        case "txt", "md":
            return try plainText(from: data)
        case "rtf": type = .rtf
        case "docx": type = .officeOpenXML
        case "odt": type = .openDocument
        case "html":
            // Never the system's html importer: it is a WebKit renderer that may fetch what an untrusted page points at.
            return try HtmlText.text(from: data)
        default: throw DocReadError.unreadable
        }
        options[.documentType] = type
        do {
            return try NSAttributedString(data: data, options: options, documentAttributes: nil).string
        } catch {
            throw DocReadError.unreadable
        }
    }

    /// The ranges of the chunks of `text`, in order, each starting where the one before ended and together covering it.
    /// A chunk ends after the last space or line end in the `lookBack` units before `chunkCharacters`, else exactly
    /// `chunkCharacters` units on; it never ends inside an emoji or a letter with its accent.
    private static func cuts(of text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        while start < text.length {
            var end = min(start + chunkCharacters, text.length)
            if end < text.length {
                end = lastBreak(in: text, from: max(start + chunkCharacters - lookBack, start + 1), to: end) ?? end
                let composed = text.rangeOfComposedCharacterSequence(at: end)
                if composed.location > start { end = composed.location }
            }
            ranges.append(NSRange(location: start, length: end - start))
            start = end
        }
        return ranges
    }

    /// The offset just after the last whitespace character at `from..<to`, or nil when there is none.
    private static func lastBreak(in text: NSString, from: Int, to: Int) -> Int? {
        var position = to
        while position > from {
            position -= 1
            if let scalar = Unicode.Scalar(text.character(at: position)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return position + 1
            }
        }
        return nil
    }
}

/// The visible text of an html file by a plain tokenizer that opens no connection and loads nothing: `<script>`, `<style>`
/// and comments go with their content, every other tag goes, block tags become a line break and table cells a space,
/// entities are decoded. The bytes are utf-8; any other bytes are read by the charset a `<meta>` names, else refused.
enum HtmlText {
    static func text(from data: Data) throws -> String {
        strip(try decode(data))
    }

    private static func decode(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard let head = String(data: data.prefix(4096), encoding: .isoLatin1),
              let found = head.range(of: #"charset\s*=\s*["']?\s*([A-Za-z0-9_.:\-]+)"#, options: [.regularExpression, .caseInsensitive])
        else { throw DocReadError.unreadable }
        let name = String(head[found]).drop { $0 != "=" }.dropFirst()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId,
              let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)))
        else { throw DocReadError.unreadable }
        return text
    }

    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "section", "article",
        "header", "footer", "blockquote", "pre", "hr", "dt", "dd",
    ]
    private static let cellTags: Set<String> = ["td", "th"]

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "copy": "\u{A9}", "reg": "\u{AE}",
        "euro": "\u{20AC}", "pound": "\u{A3}", "yen": "\u{A5}", "cent": "\u{A2}", "trade": "\u{2122}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bull": "\u{2022}", "middot": "\u{B7}", "laquo": "\u{AB}",
        "raquo": "\u{BB}", "deg": "\u{B0}", "times": "\u{D7}", "divide": "\u{F7}", "sect": "\u{A7}", "para": "\u{B6}",
        "plusmn": "\u{B1}", "frac12": "\u{BD}", "eacute": "\u{E9}", "egrave": "\u{E8}", "agrave": "\u{E0}",
        "aacute": "\u{E1}", "uuml": "\u{FC}", "ouml": "\u{F6}", "auml": "\u{E4}", "szlig": "\u{DF}",
        "ccedil": "\u{E7}", "ntilde": "\u{F1}",
    ]

    private static func strip(_ source: String) -> String {
        let s = Array(source.unicodeScalars)
        var out: [Unicode.Scalar] = []
        var pendingSpace = false
        var i = 0

        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }
        func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
            ("A"..."Z").contains(c) ? Unicode.Scalar(c.value + 32) ?? c : c
        }
        func flush() {
            if pendingSpace, let last = out.last, last != "\n" { out.append(" ") }
            pendingSpace = false
        }
        func put(_ c: Unicode.Scalar) {
            if c == "\u{FFFC}" { return }
            if isSpace(c) { pendingSpace = true; return }
            flush()
            out.append(c)
        }
        func newline() {
            while out.last == " " { out.removeLast() }
            pendingSpace = false
            guard !out.isEmpty, !(out.count >= 2 && out[out.count - 1] == "\n" && out[out.count - 2] == "\n") else { return }
            out.append("\n")
        }
        /// The index just after the next `>` at or after `from`; the end when there is none. A quote hides a `>` only as an
        /// attribute value (after `=`) that closes before the next `<`: any other quote is plain text, so a stray one
        /// never swallows what follows.
        func tagEnd(from: Int) -> Int {
            var k = from
            var openAfter: [Unicode.Scalar: Int] = [:]
            while k < s.count {
                let c = s[k]
                if c == ">" { return k + 1 }
                if c == "=" {
                    var v = k + 1
                    while v < s.count, isSpace(s[v]) { v += 1 }
                    if v < s.count, s[v] == "\"" || s[v] == "'", v >= (openAfter[s[v]] ?? 0) {
                        let quote = s[v]
                        var close = v + 1
                        while close < s.count, s[close] != quote, s[close] != "<" { close += 1 }
                        if close < s.count, s[close] == quote {
                            k = close + 1
                            continue
                        }
                        // No closing quote before the next `<` (or the end): none after `v` and before `close` has one either.
                        openAfter[quote] = close
                    }
                }
                k += 1
            }
            return s.count
        }
        /// The index of the first `needle` (lowercase letters and symbols) at or after `from`, in any letter case.
        func find(_ needle: String, from: Int) -> Int? {
            let n = Array(needle.unicodeScalars)
            guard s.count >= n.count else { return nil }
            var k = from
            while k + n.count <= s.count {
                var hit = true
                for (offset, c) in n.enumerated() where lower(s[k + offset]) != c {
                    hit = false
                    break
                }
                if hit { return k }
                k += 1
            }
            return nil
        }

        while i < s.count {
            let c = s[i]
            if c == "<", i + 1 < s.count {
                let next = s[i + 1]
                if next == "!", i + 3 < s.count, s[i + 2] == "-", s[i + 3] == "-" {
                    if let close = find("-->", from: i + 4) { i = close + 3 } else { i = s.count }
                    continue
                }
                if isLetter(next) || (next == "/" && i + 2 < s.count && isLetter(s[i + 2])) {
                    let closing = next == "/"
                    var k = i + (closing ? 2 : 1)
                    var name = ""
                    while k < s.count, !isSpace(s[k]), s[k] != "/", s[k] != ">" { name.unicodeScalars.append(s[k]); k += 1 }
                    name = name.lowercased()
                    var end = tagEnd(from: k)
                    if !closing, name == "script" || name == "style" {
                        if let close = find("</" + name, from: end) { end = tagEnd(from: close + 2) } else { end = s.count }
                    } else if blockTags.contains(name) {
                        newline()
                    } else if cellTags.contains(name) {
                        pendingSpace = true
                    }
                    i = end
                    continue
                }
                if next == "!" || next == "?" {
                    i = tagEnd(from: i + 2)
                    continue
                }
            }
            if c == "&", let (decoded, length) = entity(s, at: i) {
                if decoded == "\u{A0}" { flush(); out.append(" ") } else { put(decoded) }
                i += length
                continue
            }
            put(c)
            i += 1
        }
        while let last = out.last, isSpace(last) { out.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: out)
        return String(view)
    }

    /// The character an entity at `s[at]` (an `&`) stands for and how many scalars it takes, or nil for text that is not one.
    private static func entity(_ s: [Unicode.Scalar], at: Int) -> (Unicode.Scalar, Int)? {
        var end = at + 1
        while end < s.count, end - at <= 12, s[end] != ";", s[end] != "&", s[end] != "<", s[end] != " " { end += 1 }
        guard end < s.count, s[end] == ";", end > at + 1 else { return nil }
        var name = ""
        name.unicodeScalars.append(contentsOf: s[(at + 1)..<end])
        var scalar: Unicode.Scalar?
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            scalar = value.flatMap { $0 == 0 ? nil : Unicode.Scalar($0) }
        } else {
            scalar = entities[name]?.unicodeScalars.first
        }
        guard let scalar else { return nil }
        return (scalar, end - at + 1)
    }
}
