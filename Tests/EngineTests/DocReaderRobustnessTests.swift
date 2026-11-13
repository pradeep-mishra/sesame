import Foundation
import Testing
import SesameEngine

// plan-4 review round 1, fix round, tester step: the two "noted" findings about the document reader (the html tag scanner and
// the text decoding). Written from the reviewer's report (the first two noted findings, with the probes it measured) and the
// brief only; no product source read. Names come from DocReaderTests: `DocReader.text(from:extension:)`,
// `DocReader.read(path:expecting:fromChunk:)`, `DocStep.chunks`, `DocChunk.text`, `DocReadError` (printed as its case name),
// `FileIdentity(size:mtimeNs:inode:)`.
//
// WHAT THEY PIN (every expected value is written by hand):
//   1. HTML. One stray quote or apostrophe inside a tag must not swallow the real text after it, and a quote inside an attribute
//      VALUE still hides a `>` inside the quotes:
//        `<p class="a>visible one</p><p>visible two</p>`        text holds "visible one" and "visible two"
//        `<div data-x=it's fine>Alpha</div><div>Bravo</div>`     text holds Alpha and Bravo, and not the attribute
//        `<a title="x > y">link</a>`                             text is "link", the `y` after the `>` inside the quotes is not text
//        `<a title='x > y'>link</a>`                             the same with single quotes (a shape this file adds: same rule)
//   2. NUL bytes. A text whose bytes hold NULs comes back with the NULs removed and the text after them kept ("abc\0def" gives
//      "abcdef"), for txt and for html. (The index binds text with a length of -1, which stops at the first NUL.)
//   3. Encodings. A txt or md in UTF-16LE with a BOM, in UTF-16BE with a BOM, or in Windows-1252 (the bytes 0x63 0x61 0x66 0xE9
//      are "café") is READ, with the same visible words, instead of throwing `unreadable`. A UTF-16LE file WITHOUT a BOM is valid
//      UTF-8 full of NULs: it reads as its letters.
//   4. A binary blob under a text extension (seeded random bytes in a .txt): still `unreadable` or read, but never a crash and
//      never a NUL in a text that was read. Which of the two it is today is in the report of this step.
//
// SHAPES THIS FILE PINS that the brief did not fix: single-quoted attribute values behave like double-quoted ones (item 1, fourth
// line); a BOM is not asserted away (the words are asserted, not the first character); md is checked with the same bytes as txt.

// MARK: a temp folder and the reading calls

private final class RbDir {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-docrobust-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }

    func file(_ name: String) -> String { path + "/" + name }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

private func withDir(_ body: (RbDir) throws -> Void) throws {
    let dir = try RbDir()
    defer { dir.remove() }
    try body(dir)
}

private func identity(of path: String) -> FileIdentity {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0 else { return FileIdentity(size: 0, mtimeNs: 0, inode: 0) }
    return FileIdentity(size: Int64(info.st_size),
                        mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                        inode: UInt64(info.st_ino))
}

/// The text of `DocReader.text(from:extension:)`, or the case name of the error it threw.
private func textOf(_ data: Data, _ ext: String) -> (text: String?, error: String?) {
    do {
        return (try DocReader.text(from: data, extension: ext), nil)
    } catch let error as DocReadError {
        return (nil, String(describing: error))
    } catch {
        return (nil, "other: \(error)")
    }
}

/// Writes `data` as `<dir>/robust.<ext>` and reads it the way the helper does: all chunks, joined; or the error case name.
private func readFile(_ data: Data, _ ext: String, in dir: RbDir) throws -> (text: String?, error: String?) {
    let path = dir.file("robust." + ext)
    try data.write(to: URL(fileURLWithPath: path))
    do {
        let step = try DocReader.read(path: path, expecting: identity(of: path), fromChunk: 0)
        return (step.chunks.map(\.text).joined(), nil)
    } catch let error as DocReadError {
        return (nil, String(describing: error))
    } catch {
        return (nil, "other: \(error)")
    }
}

private func data(_ text: String, as encoding: String.Encoding, bom: [UInt8] = []) -> Data {
    Data(bom) + (text.data(using: encoding) ?? Data())
}

// MARK: the tests

@Suite("DocReaderRobustnessTests")
struct DocReaderRobustnessTests {

    // MARK: html: a stray quote or apostrophe, and a quoted ">"

    struct Markup: CustomTestStringConvertible, Sendable {
        let html: String
        let holds: [String]
        let lacks: [String]
        var testDescription: String { html }
    }

    static let markups = [
        Markup(html: #"<p class="a>visible one</p><p>visible two</p>"#, holds: ["visible one", "visible two"], lacks: ["<p", "</p"]),
        Markup(html: "<div data-x=it's fine>Alpha</div><div>Bravo</div>", holds: ["Alpha", "Bravo"], lacks: ["data-x", "fine"]),
        Markup(html: #"<a title="x > y">link</a>"#, holds: ["link"], lacks: ["y", "x", ">"]),
        Markup(html: "<a title='x > y'>link</a>", holds: ["link"], lacks: ["y", "x", ">"]),
        // a quoted attribute that is closed, then more tags and text: the control for the rule "a quote in a value hides a >"
        Markup(html: #"<p title="a > b">first</p><p class="plain">second</p>"#, holds: ["first", "second"], lacks: ["b", "plain"]),
    ]

    @Test(arguments: markups)
    func aStrayQuoteInATagDoesNotSwallowTheTextAndAQuotedGreaterThanStaysHidden(_ markup: Markup) throws {
        let direct = textOf(Data(markup.html.utf8), "html")
        let text = try #require(direct.text, "html should read, it threw \(direct.error ?? "nothing")")
        for wanted in markup.holds {
            #expect(text.contains(wanted), "the text of \(markup.html) lacks \"\(wanted)\": got \(text.debugDescription)")
        }
        for forbidden in markup.lacks {
            #expect(!text.contains(forbidden), "the text of \(markup.html) holds \"\(forbidden)\": got \(text.debugDescription)")
        }
    }

    @Test func theSameMalformedHtmlReadAsAFileGivesTheSameWords() throws {
        try withDir { dir in
            let html = #"<html><body><p class="a>visible one</p><p>visible two</p><div data-x=it's fine>Alpha</div><div>Bravo</div></body></html>"#
            let read = try readFile(Data(html.utf8), "html", in: dir)
            let text = try #require(read.text, "the html file should read, it threw \(read.error ?? "nothing")")
            for wanted in ["visible one", "visible two", "Alpha", "Bravo"] {
                #expect(text.contains(wanted), "the file's text lacks \"\(wanted)\": got \(text.debugDescription)")
            }
        }
    }

    // MARK: NUL bytes

    @Test func aTxtWithANulKeepsTheTextOnBothSidesAndLosesTheNul() throws {
        let direct = textOf(Data("abc\u{0}def".utf8), "txt")
        #expect(direct.text == "abcdef", "txt \"abc\\0def\" should give \"abcdef\", got \(String(describing: direct.text?.debugDescription)) (error \(direct.error ?? "none"))")
        try withDir { dir in
            let words = "before the break\u{0}after the break and some more words\u{0}\u{0}end"
            let read = try readFile(Data(words.utf8), "txt", in: dir)
            #expect(read.text == "before the breakafter the break and some more wordsend",
                    "the file's text is \(String(describing: read.text?.debugDescription)) (error \(read.error ?? "none"))")
        }
    }

    @Test func anHtmlWithANulKeepsTheTextOnBothSidesAndLosesTheNul() throws {
        let direct = textOf(Data("<p>abc\u{0}def</p><p>tail</p>".utf8), "html")
        let text = try #require(direct.text, "html should read, it threw \(direct.error ?? "nothing")")
        #expect(text.contains("abcdef"), "html \"<p>abc\\0def</p>\" should hold \"abcdef\", got \(text.debugDescription)")
        #expect(text.contains("tail"), "the text after the NUL is lost: \(text.debugDescription)")
        #expect(!text.contains("\u{0}"), "a NUL is still in the text: \(text.debugDescription)")
        try withDir { dir in
            let read = try readFile(Data("<html><body><p>abc\u{0}def</p><p>tail</p></body></html>".utf8), "html", in: dir)
            let fileText = try #require(read.text, "the html file should read, it threw \(read.error ?? "nothing")")
            #expect(fileText.contains("abcdef") && fileText.contains("tail") && !fileText.contains("\u{0}"),
                    "the file's text is \(fileText.debugDescription)")
        }
    }

    // MARK: text in another encoding is read, not damaged

    struct Encoded: CustomTestStringConvertible, Sendable {
        let name: String
        let bytes: Data
        var testDescription: String { name }
    }

    static let sentence = "The café menu lists soup and bread"

    static let encodings: [Encoded] = [
        Encoded(name: "UTF-16LE with a BOM", bytes: data(sentence, as: .utf16LittleEndian, bom: [0xFF, 0xFE])),
        Encoded(name: "UTF-16BE with a BOM", bytes: data(sentence, as: .utf16BigEndian, bom: [0xFE, 0xFF])),
        Encoded(name: "Windows-1252", bytes: Data("The caf".utf8) + Data([0xE9]) + Data(" menu lists soup and bread".utf8)),
    ]

    @Test(arguments: encodings, ["txt", "md"])
    func aTextInAnotherEncodingIsReadWithItsWords(_ encoded: Encoded, _ ext: String) throws {
        let direct = textOf(encoded.bytes, ext)
        let text = try #require(direct.text, "\(encoded.name) as .\(ext) should read, it threw \(direct.error ?? "nothing")")
        for wanted in ["café", "menu lists soup and bread", "The"] {
            #expect(text.contains(wanted), "\(encoded.name) as .\(ext): the text lacks \"\(wanted)\": got \(text.debugDescription)")
        }
        #expect(!text.contains("\u{0}") && !text.contains("\u{FFFD}"), "\(encoded.name): the text holds a NUL or a replacement character: \(text.debugDescription)")
        try withDir { dir in
            let read = try readFile(encoded.bytes, ext, in: dir)
            let fileText = try #require(read.text, "the \(encoded.name) file as .\(ext) should read, it threw \(read.error ?? "nothing")")
            #expect(fileText.contains("café") && fileText.contains("menu lists soup and bread"),
                    "\(encoded.name): the file's text is \(fileText.debugDescription)")
        }
    }

    @Test func aUtf16LittleEndianTxtWithNoBomReadsAsItsLettersWithTheNulsStripped() throws {
        let bytes = Data("hello world".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        #expect(String(data: bytes, encoding: .utf8) != nil, "setup: the bytes are valid UTF-8 (letters and NULs)")
        #expect(bytes.contains(0), "setup: the bytes hold NULs")
        let direct = textOf(bytes, "txt")
        #expect(direct.text == "hello world", "got \(String(describing: direct.text?.debugDescription)) (error \(direct.error ?? "none"))")
        try withDir { dir in
            let read = try readFile(bytes, "txt", in: dir)
            #expect(read.text == "hello world", "the file's text is \(String(describing: read.text?.debugDescription)) (error \(read.error ?? "none"))")
        }
    }

    // MARK: a binary blob under a text name

    @Test func aBinaryBlobInATxtIsUnreadableOrReadWithoutNulAndNeverCrashes() throws {
        var generator = BlobGenerator(seed: 31_337)
        let blob = Data((0..<4096).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
        let direct = textOf(blob, "txt")
        #expect(direct.error == "unreadable" || direct.text != nil, "unexpected error \(direct.error ?? "none")")
        if let text = direct.text { #expect(!text.contains("\u{0}"), "a text read from a blob holds a NUL") }
        try withDir { dir in
            let read = try readFile(blob, "txt", in: dir)
            #expect(read.error == "unreadable" || read.text != nil, "unexpected error \(read.error ?? "none")")
            if let text = read.text { #expect(!text.contains("\u{0}"), "a file text read from a blob holds a NUL") }
        }
    }
}

/// A seeded generator (SplitMix64), written here so the blob is the same on every run.
private struct BlobGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
