import Foundation
import Testing
import SesameEngine

// plan-4-t6, tester step. Written from the t6 entry of plan-4-tasks.md (Tests), the Conventions of plan-4-tasks.md and
// plan-3-tasks.md, Decisions D4 and D7, design sections 3 and 4 and the spec's S3 only; no product source is read.
//
// Names, and how they were found:
//   - `DocReader.read(path:expecting:fromChunk:) throws -> DocStep`, `DocStep.chunkCount`, `.chunks: [DocChunk]`, `.nameWords`,
//     `DocChunk.index`, `.start`, `.end`, `.text`, `DocReader.text(from: Data, extension: String) throws -> String`,
//     `DocReader.chunkCharacters` (about 1,600), `DocReader.stepChunks` (40) and `DocReadError`: the names the entry fixes. None
//     exists yet.
//   - `FileIdentity(size:mtimeNs:inode:)` and the way PdfReaderTests make one from `lstat`: the `expecting` argument, which the
//     entry says the document reader shares with the PDF reader. `DocReadError` carries the identity and admission errors "as in
//     t4's PdfReadError": `.notAdmitted`, `.changed`, `.cannotOpen`, and `.unreadable` (there is no password for a document).
//   - `Rules.admit(path:)` (name level): used only to check this file's own samples (a key name and a link are refused, the
//     same bytes under an ordinary name are admitted), never to compute an expected value.
//
// SHAPES THIS FILE PINS (the entry gives names, not these; if one is wrong, ask for a test change; each is one place to edit):
//   1. `fromChunk` is 0-based: `fromChunk: 0` reads the first chunk, `fromChunk: 40` the forty-first, and `DocChunk.index` is the
//      chunk's 0-based position in the whole text. (The PDF reader's `firstPage` is 1-based; a chunk has no number a person
//      sees, `read_to` counts chunks, and 0-based makes `fromChunk` equal the `read_to` of the step before it.)
//   2. `DocChunk.start` and `.end` are UTF-16 offsets into the extracted text with `end` exclusive, so `chunk.text` is exactly
//      the UTF-16 slice `[start, end)` of `DocReader.text(from:extension:)`, and the chunks are contiguous and cover the text
//      (the first starts at 0, each starts where the one before ended, the last ends at the text's UTF-16 length).
//   3. `DocReader.text(from:extension:)` takes the extension without a dot ("txt"), and for txt and md gives the file's text
//      exactly as the utf-8 bytes spell it (no trimming).
//   4. `DocStep.chunkCount` is the number of chunks of the whole text, not of the step; a zero-byte txt has chunkCount 0 and no
//      chunk [guess, the entry's own: "readable with no chunk (only its name passage)"].
//   5. A text with no whitespace at all is cut every `chunkCharacters` UTF-16 units, whatever the cutting rule is for text with
//      spaces: that is how the 100-chunk text below has exactly 100 chunks. For text with spaces only "about 1,600" is pinned
//      (every chunk but the last is 1,200 to 2,000 UTF-16 units long).
//
// Documents are made by this file under $TMPDIR and removed again: txt and md as utf-8, rtf, docx and odt with the system's
// `textutil` from a txt source, html by hand with a `<script>`, a `<style>` and tags. Every expected value is written by hand:
// the chunk counts (1, 100, 40, 40, 20), the offsets, the anchor phrases. The test's own independent witness of an rtf, docx or
// odt sample is `textutil -convert txt -stdout` (never the code under test).

// MARK: making documents (shared with HelperDocTests.swift)

struct DocMakerError: Error, CustomStringConvertible {
    let description: String
}

struct DocSample {
    let ext: String
    let stem: String
    let before: String
    let after: String
    let anchor: String
    /// The text the sample is made from. For txt this is the file's whole text; for md the file is a heading line and this.
    let source: String

    var fileName: String { stem + "." + ext }
}

enum DocMaker {
    static let extensions = ["txt", "md", "rtf", "docx", "html", "odt"]

    /// About 1,000 characters of ordinary words with `before`, then `anchor`, then `after` in one sentence in the middle.
    static func sample(_ ext: String, stem: String, number: Int) -> DocSample {
        let before = PdfMaker.token("zbef", number)
        let after = PdfMaker.token("zaft", number)
        let anchor = [PdfMaker.token("zanx", number), PdfMaker.token("zany", number), PdfMaker.token("zanz", number)].joined(separator: " ")
        let intro = "Notes for the meeting. " + String(repeating: PdfMaker.fillerSentence, count: 7)
        let key = "It was agreed that \(before) comes first, then \(anchor), and last \(after). "
        let outro = String(repeating: PdfMaker.fillerSentence, count: 7)
        return DocSample(ext: ext, stem: stem, before: before, after: after, anchor: anchor,
                         source: intro + "\n\n" + key + "\n\n" + outro)
    }

    /// Writes the sample as `<dir>/<stem>.<ext>` and returns the path.
    @discardableResult
    static func write(_ sample: DocSample, in dir: String) throws -> String {
        let path = dir + "/" + sample.fileName
        switch sample.ext {
        case "txt":
            try Data(sample.source.utf8).write(to: URL(fileURLWithPath: path))
        case "md":
            try Data(("# " + sample.stem + "\n\n" + sample.source).utf8).write(to: URL(fileURLWithPath: path))
        case "html":
            try Data(html(sample).utf8).write(to: URL(fileURLWithPath: path))
        case "rtf", "docx", "odt":
            let source = dir + "/source-" + sample.stem + ".txt"
            try Data(sample.source.utf8).write(to: URL(fileURLWithPath: source))
            defer { try? FileManager.default.removeItem(atPath: source) }
            _ = try textutil(["-convert", sample.ext, "-output", path, source])
        default:
            throw DocMakerError(description: "no maker for \(sample.ext)")
        }
        return path
    }

    /// By hand: a head with a style and a script (their text must never reach the index), tags round the key words.
    static func html(_ sample: DocSample) -> String {
        let filler = String(repeating: PdfMaker.fillerSentence, count: 7)
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8">
            <style>p { color: zqstyle; margin: 0 }</style>
            <script>var zqscript = 1 < 2 && 3 > 2; document.write("</p>");</script>
            </head><body>
            <h1>Notes for the meeting</h1>
            <p>\(filler)</p>
            <p>It was agreed that <b>\(sample.before)</b> comes first, then <i>\(sample.anchor)</i>, and last <b>\(sample.after)</b>.</p>
            <p>\(filler)</p>
            </body></html>
            """
    }

    /// `textutil` with these arguments; its standard output as text. Throws when it does not exit 0.
    @discardableResult
    static func textutil(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DocMakerError(description: "textutil \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// What the system itself reads from an rtf, docx or odt file: the test's own witness.
    static func witness(_ path: String) -> String? {
        try? textutil(["-convert", "txt", "-stdout", path])
    }

    /// `count` lowercase letters, no space, the pattern starting `rotate` letters in.
    static func letters(_ count: Int, rotate: Int) -> String {
        let source = Array("abcdefghij")
        return String((0..<count).map { source[($0 + rotate) % source.count] })
    }

    /// `parts` strings of exactly `size` letters each, none holding a space, every one beginning with a word of its own; the text is
    /// the parts one after the other. Cut every `size` units, it has exactly `parts` chunks and chunk k is `pieces[k]`.
    static func spaceless(parts: Int, size: Int) -> (text: String, pieces: [String]) {
        let pieces = (0..<parts).map { PdfMaker.token("zchk", $0 + 1) + letters(size - 8, rotate: $0) }
        return (pieces.joined(), pieces)
    }
}

// MARK: a temp folder

private final class DocDir {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-docreader-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }

    func file(_ name: String) -> String { path + "/" + name }

    func remove() {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: path) {
            for name in names { chmod(path + "/" + name, 0o600) }
        }
        try? fm.removeItem(atPath: path)
    }
}

private func withDocDir(_ body: (DocDir) throws -> Void) throws {
    let dir = try DocDir()
    defer { dir.remove() }
    try body(dir)
}

// MARK: reading through the interface

private struct Seen: Equatable {
    var size: Int64
    var mtimeNs: Int64
    var inode: UInt64
}

private func seen(_ path: String) -> Seen? {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0 else { return nil }
    return Seen(size: Int64(info.st_size),
                mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                inode: UInt64(info.st_ino))
}

private func identity(_ value: Seen) -> FileIdentity {
    FileIdentity(size: value.size, mtimeNs: value.mtimeNs, inode: value.inode)
}

private func setMtime(_ path: String, ns: Int64) {
    let stamp = timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
    let times = [stamp, stamp]
    utimensat(AT_FDCWD, path, times, 0)
}

private func canTestPermissions() -> Bool {
    if getuid() == 0 {
        Issue.record("this test runs as root, and root opens a file with mode 000: it cannot show anything; run it as the person")
        return false
    }
    return true
}

private struct Outcome {
    let step: DocStep?
    let error: String?
}

/// Reads one step. `expecting` defaults to what `lstat` says now. An error is its case name ("unreadable", "changed", ...).
private func attempt(_ path: String, expecting: Seen? = nil, fromChunk: Int = 0) -> Outcome {
    let known = expecting ?? seen(path) ?? Seen(size: 0, mtimeNs: 0, inode: 0)
    do {
        return Outcome(step: try DocReader.read(path: path, expecting: identity(known), fromChunk: fromChunk), error: nil)
    } catch let error as DocReadError {
        return Outcome(step: nil, error: String(describing: error))
    } catch {
        return Outcome(step: nil, error: "other: \(error)")
    }
}

private func describe(_ outcome: Outcome) -> String {
    if let error = outcome.error { return "threw \(error)" }
    guard let step = outcome.step else { return "no step and no error" }
    return "read \(step.chunks.count) chunk(s) of \(step.chunkCount)"
}

/// The error of `DocReader.text(from:extension:)` as its case name, "text" for a text, or "other: ..." for another error.
private func textOutcome(_ data: Data, _ ext: String) -> (text: String?, error: String?) {
    do {
        return (try DocReader.text(from: data, extension: ext), nil)
    } catch let error as DocReadError {
        return (nil, String(describing: error))
    } catch {
        return (nil, "other: \(error)")
    }
}

private func firstOf(_ chunk: DocChunk) -> Int { Int(chunk.start) }
private func lastOf(_ chunk: DocChunk) -> Int { Int(chunk.end) }
private func numberOf(_ chunk: DocChunk) -> Int { Int(chunk.index) }

/// The UTF-16 slice `[start, end)` of `text`, nil when it is out of range.
private func slice(_ text: String, _ start: Int, _ end: Int) -> String? {
    let ns = text as NSString
    guard start >= 0, end >= start, end <= ns.length else { return nil }
    return ns.substring(with: NSRange(location: start, length: end - start))
}

/// What is wrong with the chunks of a step about `text`, or nil: each chunk's text is its slice, each is where `index` says.
private func chunkProblem(_ chunks: [DocChunk], of text: String, firstIndex: Int) -> String? {
    for (position, chunk) in chunks.enumerated() {
        if numberOf(chunk) != firstIndex + position { return "chunk at position \(position) has index \(numberOf(chunk)), expected \(firstIndex + position)" }
        guard let expected = slice(text, firstOf(chunk), lastOf(chunk)) else {
            return "chunk \(numberOf(chunk)) has start \(firstOf(chunk)) and end \(lastOf(chunk)), outside the text of \((text as NSString).length) UTF-16 units"
        }
        if chunk.text != expected { return "chunk \(numberOf(chunk)) text is not the slice \(firstOf(chunk))..<\(lastOf(chunk)) of the text" }
        if position > 0, firstOf(chunk) != lastOf(chunks[position - 1]) {
            return "chunk \(numberOf(chunk)) starts at \(firstOf(chunk)), the one before ended at \(lastOf(chunks[position - 1]))"
        }
    }
    return nil
}

// MARK: the tests

@Suite("DocReaderTests")
struct DocReaderTests {

    // MARK: the numbers

    @Test func aChunkIsAbout1600CharactersAndAStepIs40Chunks() {
        #expect((1400...1800).contains(DocReader.chunkCharacters), "chunkCharacters is \(DocReader.chunkCharacters), expected about 1,600")
        #expect(DocReader.stepChunks == 40, "stepChunks is \(DocReader.stepChunks)")
    }

    // MARK: the six types

    @Test(arguments: DocMaker.extensions)
    func eachOfTheSixTypesGivesItsAnchorPhraseInsideOneChunkWithItsWordsOnBothSides(ext: String) throws {
        try withDocDir { dir in
            let sample = DocMaker.sample(ext, stem: "harbourmemo", number: 1)
            let path = try DocMaker.write(sample, in: dir.path)
            if ["rtf", "docx", "odt"].contains(ext) {
                let witness = try #require(DocMaker.witness(path), "setup: textutil cannot read the \(ext) sample")
                #expect(witness.contains(sample.anchor) && witness.contains(sample.before) && witness.contains(sample.after),
                        "setup: the system does not read the anchor, before and after words from the \(ext) sample")
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            let outcome = attempt(path)
            let step = try #require(outcome.step, "a \(ext) document should read, it \(describe(outcome))")
            #expect(step.chunkCount == 1 && step.chunks.count == 1, "a text of about 1,000 characters is one chunk; chunkCount \(step.chunkCount), chunks \(step.chunks.count)")
            let hit = step.chunks.first { $0.text.contains(sample.anchor) }
            let chunk = try #require(hit, "no chunk holds the anchor phrase \(sample.anchor)")
            #expect(chunk.text.contains(sample.before) && chunk.text.contains(sample.after),
                    "the chunk with the anchor lacks the words before (\(sample.before)) or after (\(sample.after)) it")
            #expect(firstOf(chunk) == 0, "the only chunk starts at \(firstOf(chunk)), expected 0")
            #expect(String(describing: step.nameWords).lowercased().contains("harbourmemo"),
                    "nameWords \(step.nameWords) does not hold the file name word")

            // The chunk is a slice of the extracted text, the one the preview reads again (D7).
            let extracted = try DocReader.text(from: bytes, extension: ext)
            #expect(extracted.contains(sample.anchor), "DocReader.text(from:extension:) of the \(ext) sample lacks the anchor phrase")
            #expect(lastOf(chunk) == (extracted as NSString).length, "the chunk ends at \(lastOf(chunk)), the extracted text is \((extracted as NSString).length) UTF-16 units")
            #expect(chunkProblem(step.chunks, of: extracted, firstIndex: 0) == nil, "\(chunkProblem(step.chunks, of: extracted, firstIndex: 0) ?? "")")
            #expect((extracted as NSString).length >= 700, "the \(ext) sample reads as \((extracted as NSString).length) units, about 1,000 were written")
        }
    }

    @Test func aTxtAndAnMdGiveTheirTextExactlyAndTheMdKeepsItsHeadingLine() throws {
        let sample = DocMaker.sample("txt", stem: "plainnotes", number: 2)
        let txt = textOutcome(Data(sample.source.utf8), "txt")
        #expect(txt.text == sample.source, "a txt's text is not the file's text (error \(txt.error ?? "none"))")
        let mdSource = "# Heading words\n\n" + sample.source
        let md = textOutcome(Data(mdSource.utf8), "md")
        #expect(md.text == mdSource, "an md's text is not the file's text (error \(md.error ?? "none"))")
        try withDocDir { dir in
            let path = dir.file("plainnotes.txt")
            try Data(sample.source.utf8).write(to: URL(fileURLWithPath: path))
            let step = try #require(attempt(path).step)
            #expect(step.chunks.count == 1 && step.chunks[0].text == sample.source && lastOf(step.chunks[0]) == sample.source.utf16.count,
                    "the one chunk of the txt is not the whole file text, or its end is not \(sample.source.utf16.count)")
        }
    }

    @Test func theHtmlTextHoldsNoTagAndNoScriptOrStyleContent() throws {
        let sample = DocMaker.sample("html", stem: "bakingpage", number: 3)
        let markup = DocMaker.html(sample)
        #expect(markup.contains("<") && markup.contains("zqscript") && markup.contains("zqstyle"), "setup: the html sample holds its tags, script and style")
        let direct = textOutcome(Data(markup.utf8), "html")
        let text = try #require(direct.text, "html should read, it threw \(direct.error ?? "nothing")")
        for forbidden in ["<", ">", "zqscript", "zqstyle", "color:", "document.write"] {
            #expect(!text.contains(forbidden), "the html text holds \(forbidden)")
        }
        for wanted in [sample.anchor, sample.before, sample.after, "Notes for the meeting", "grey harbour"] {
            #expect(text.contains(wanted), "the html text lacks \(wanted)")
        }
        try withDocDir { dir in
            let path = try DocMaker.write(sample, in: dir.path)
            let step = try #require(attempt(path).step, "the html file should read")
            let joined = step.chunks.map(\.text).joined()
            #expect(step.chunks.contains { $0.text.contains(sample.anchor) }, "no chunk holds the anchor phrase")
            for forbidden in ["<", ">", "zqscript", "zqstyle", "color:"] {
                #expect(!joined.contains(forbidden), "a chunk of the html holds \(forbidden)")
            }
        }
    }

    // MARK: chunks

    @Test func aLongerTextIsCutInChunksOfAbout1600CharactersThatAreContiguousAndCoverTheText() throws {
        try withDocDir { dir in
            // 6,000 characters or so, with spaces: sentences numbered by hand.
            let source = (1...90).map { "Sentence number \(PdfMaker.token("zsen", $0)) says that the grey harbour keeps a copper lantern. " }.joined()
            let length = source.utf16.count
            #expect((5000...7500).contains(length), "setup: the sample is \(length) UTF-16 units, expected about 6,000")
            let path = dir.file("longnotes.txt")
            try Data(source.utf8).write(to: URL(fileURLWithPath: path))
            let step = try #require(attempt(path).step, "the text should read")
            #expect((3...6).contains(step.chunkCount), "chunkCount is \(step.chunkCount) for \(length) units, expected 3 to 6")
            #expect(step.chunks.count == step.chunkCount, "one call returns all \(step.chunkCount) chunks of a short text, got \(step.chunks.count)")
            let firstChunk = try #require(step.chunks.first, "the text has no chunk")
            let lastChunk = try #require(step.chunks.last)
            #expect(firstOf(firstChunk) == 0, "the first chunk starts at \(firstOf(firstChunk))")
            #expect(lastOf(lastChunk) == length, "the last chunk ends at \(lastOf(lastChunk)), the text is \(length) units")
            #expect(chunkProblem(step.chunks, of: source, firstIndex: 0) == nil, "\(chunkProblem(step.chunks, of: source, firstIndex: 0) ?? "")")
            #expect(step.chunks.map(\.text).joined() == source, "the chunks together are not the text")
            for chunk in step.chunks.dropLast() {
                let size = lastOf(chunk) - firstOf(chunk)
                #expect((1200...2000).contains(size), "chunk \(numberOf(chunk)) is \(size) units long, expected about 1,600")
            }
            let lastSize = lastOf(lastChunk) - firstOf(lastChunk)
            #expect(lastSize > 0 && lastSize <= 2000, "the last chunk is \(lastSize) units long")
        }
    }

    @Test func theOffsetsAreUtf16UnitsSoEmojiAndCombiningMarksAgreeWithTheSlicesOfTheText() throws {
        try withDocDir { dir in
            // each unit: an emoji (2 UTF-16 units), a space, "cafe" and a combining acute accent (5), a space: 9 units
            let unit = "\u{1F600} cafe\u{301} "
            #expect(unit.utf16.count == 9, "setup: the unit is \(unit.utf16.count) UTF-16 units, expected 9")
            let source = String(repeating: unit, count: 400)
            let path = dir.file("emojinotes.txt")
            try Data(source.utf8).write(to: URL(fileURLWithPath: path))
            let step = try #require(attempt(path).step, "the text should read")
            #expect(step.chunks.count >= 2, "3,600 units are more than one chunk, got \(step.chunks.count)")
            let firstChunk = try #require(step.chunks.first, "the text has no chunk")
            let lastChunk = try #require(step.chunks.last)
            #expect(firstOf(firstChunk) == 0, "the first chunk starts at \(firstOf(firstChunk))")
            #expect(lastOf(lastChunk) == 3600, "the last chunk ends at \(lastOf(lastChunk)), expected 3600 UTF-16 units (400 times 9)")
            #expect(chunkProblem(step.chunks, of: source, firstIndex: 0) == nil, "\(chunkProblem(step.chunks, of: source, firstIndex: 0) ?? "")")
            #expect(step.chunks.map(\.text).joined() == source, "the chunks together are not the text")
            #expect(step.chunks.allSatisfy { !$0.text.contains("\u{FFFD}") && $0.text.utf16.count == lastOf($0) - firstOf($0) },
                    "a chunk was cut inside an emoji or lost a character: lengths \(step.chunks.map { "\($0.text.utf16.count) vs \(lastOf($0) - firstOf($0))" })")
        }
    }

    // MARK: steps of at most 40 chunks

    @Test func aHundredChunkTextReadsInStepsOf40And40And20ByFromChunk() throws {
        try withDocDir { dir in
            let size = DocReader.chunkCharacters
            let made = DocMaker.spaceless(parts: 100, size: size)
            let path = dir.file("hundredchunks.txt")
            try Data(made.text.utf8).write(to: URL(fileURLWithPath: path))
            #expect(made.text.utf16.count == 100 * size, "setup: the text is \(made.text.utf16.count) units, expected \(100 * size)")

            let first = try #require(attempt(path, fromChunk: 0).step, "fromChunk 0 should read")
            #expect(first.chunkCount == 100, "chunkCount is \(first.chunkCount), expected 100")
            #expect(first.chunks.map { numberOf($0) } == Array(0..<40), "fromChunk 0 gave chunks \(first.chunks.map { numberOf($0) })")
            let second = try #require(attempt(path, fromChunk: 40).step, "fromChunk 40 should read")
            #expect(second.chunkCount == 100, "chunkCount is \(second.chunkCount), expected 100")
            #expect(second.chunks.map { numberOf($0) } == Array(40..<80), "fromChunk 40 gave chunks \(second.chunks.map { numberOf($0) })")
            let third = try #require(attempt(path, fromChunk: 80).step, "fromChunk 80 should read")
            #expect(third.chunkCount == 100, "chunkCount is \(third.chunkCount), expected 100")
            #expect(third.chunks.map { numberOf($0) } == Array(80..<100), "fromChunk 80 gave chunks \(third.chunks.map { numberOf($0) })")

            for step in [first, second, third] {
                for chunk in step.chunks {
                    let number = numberOf(chunk)
                    guard (0..<100).contains(number) else { continue }
                    #expect(firstOf(chunk) == number * size && lastOf(chunk) == (number + 1) * size,
                            "chunk \(number) spans \(firstOf(chunk))..<\(lastOf(chunk)), expected \(number * size)..<\((number + 1) * size)")
                    #expect(chunk.text == made.pieces[number], "chunk \(number) does not hold its own letters")
                }
            }
            #expect(chunkProblem(second.chunks, of: made.text, firstIndex: 40) == nil, "\(chunkProblem(second.chunks, of: made.text, firstIndex: 40) ?? "")")
        }
    }

    // MARK: reading changes nothing

    @Test func readingLeavesTheFileAsItWasAndTwoReadsAgree() throws {
        try withDocDir { dir in
            let sample = DocMaker.sample("txt", stem: "steadyfile", number: 4)
            let path = try DocMaker.write(sample, in: dir.path)
            let before = try #require(seen(path))
            let first = try #require(attempt(path).step)
            let second = try #require(attempt(path).step)
            #expect(seen(path) == before, "reading changed the file's size, modified time or inode")
            #expect(first.chunks.map(\.text) == second.chunks.map(\.text), "two reads of one file differ")
        }
    }

    // MARK: an empty file

    @Test func aZeroByteTxtIsReadableWithNoChunkAndItsNameWords() throws {
        try withDocDir { dir in
            let path = dir.file("emptynotes.txt")
            try Data().write(to: URL(fileURLWithPath: path))
            #expect(seen(path)?.size == 0, "setup: the file is not empty")
            let outcome = attempt(path)
            let step = try #require(outcome.step, "a zero-byte txt should read, it \(describe(outcome))")
            #expect(step.chunkCount == 0 && step.chunks.isEmpty, "chunkCount \(step.chunkCount), chunks \(step.chunks.count): expected none")
            #expect(String(describing: step.nameWords).lowercased().contains("emptynotes"), "nameWords \(step.nameWords) does not hold the file name word")
            #expect(textOutcome(Data(), "txt").text == "", "the text of zero bytes should be the empty string")
        }
    }

    // MARK: files that cannot be read

    @Test func aDocxThatIsNotAZipAnOdtThatIsNotAZipACutDocxAndAnInvalidUtf8TxtAndMdThrowUnreadable() throws {
        try withDocDir { dir in
            let sample = DocMaker.sample("docx", stem: "wholefile", number: 5)
            let whole = try DocMaker.write(sample, in: dir.path)
            let control = attempt(whole)
            #expect(control.step != nil, "control: the real docx should read, it \(describe(control))")
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-tq", whole]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()
            #expect(unzip.terminationStatus == 0, "setup: unzip -t does not pass the control docx")

            let notZipDocx = dir.file("notzip.docx")
            try Data("This is plain text, not a zip file.\n".utf8).write(to: URL(fileURLWithPath: notZipDocx))
            let notZipOdt = dir.file("notzip.odt")
            try Data("This is plain text, not a zip file.\n".utf8).write(to: URL(fileURLWithPath: notZipOdt))
            let cutDocx = dir.file("cutfile.docx")
            try Data(try Data(contentsOf: URL(fileURLWithPath: whole)).prefix(300)).write(to: URL(fileURLWithPath: cutDocx))
            let badTxt = dir.file("badbytes.txt")
            // AMENDED in plan-4 review round 1, fix round, tester step. The bytes were 0xC3 0x28 0xA0 0xA1 0xFF 0xC0: invalid UTF-8,
            // but every one of them is a defined Windows-1252 character, so under the new rule (reviewer, noted finding 2: a txt or md
            // in UTF-16 with a BOM or in Windows-1252 is READ, not listed as damaged) that file is a readable Windows-1252 text and
            // must not throw. The case that stays unreadable is now one that none of UTF-8, UTF-16 with a BOM and Windows-1252
            // can decode: the five positions Windows-1252 leaves undefined (0x81 0x8D 0x8F 0x90 0x9D) among words. The test of
            // the old bytes as a text that reads is in DocReaderRobustnessTests (the Windows-1252 case). Nothing else here changed.
            var bad = Data("Some words before. ".utf8)
            bad.append(contentsOf: [0x81, 0x8D, 0x8F, 0x90, 0x9D])
            bad.append(Data(" and some words after.".utf8))
            try bad.write(to: URL(fileURLWithPath: badTxt))
            let badMd = dir.file("badbytes.md")
            try bad.write(to: URL(fileURLWithPath: badMd))
            #expect(String(data: bad, encoding: .utf8) == nil, "setup: the bytes are valid utf-8")
            #expect(String(data: bad, encoding: .windowsCP1252) == nil, "setup: the bytes are valid Windows-1252")
            #expect(!bad.starts(with: [0xFF, 0xFE]) && !bad.starts(with: [0xFE, 0xFF]) && !bad.starts(with: [0xEF, 0xBB, 0xBF]), "setup: the bytes start with a BOM")

            for path in [notZipDocx, notZipOdt, cutDocx, badTxt, badMd] {
                let name = (path as NSString).lastPathComponent
                let outcome = attempt(path)
                #expect(outcome.error == "unreadable", "\(name) should throw unreadable, it \(describe(outcome))")
                let text = textOutcome((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data(), (path as NSString).pathExtension)
                #expect(text.error == "unreadable", "DocReader.text(from:extension:) of \(name) should throw unreadable, got \(text.error ?? "a text")")
            }
        }
    }

    // MARK: the file changed since it was listed

    @Test func aChangedSizeOrMtimeOrInodeThrowsChangedAndTheUnchangedFileStillReads() throws {
        try withDocDir { dir in
            let path = try DocMaker.write(DocMaker.sample("txt", stem: "shifting", number: 6), in: dir.path)
            let before = try #require(seen(path))
            #expect(attempt(path, expecting: before).step != nil, "control: with the identity it has, the file reads")

            // size only: bytes added at the end, the modified time put back, the same inode
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\nA line added at the end.\n".utf8))
            try handle.close()
            setMtime(path, ns: before.mtimeNs)
            let grown = try #require(seen(path))
            #expect(grown.size != before.size && grown.mtimeNs == before.mtimeNs && grown.inode == before.inode,
                    "setup: the size-only change did not isolate the size: \(before) then \(grown)")
            #expect(attempt(path, expecting: before).error == "changed", "a different size should throw changed")

            // modified time only
            setMtime(path, ns: before.mtimeNs + 5_000_000_000)
            let later = try #require(seen(path))
            #expect(later.size == grown.size && later.mtimeNs != grown.mtimeNs && later.inode == grown.inode, "setup: the time-only change did not isolate the time")
            #expect(attempt(path, expecting: grown).error == "changed", "a different modified time should throw changed")

            // inode only: a copy renamed over the file, with the same bytes and the same modified time
            let copy = dir.file("copy-of-shifting.tmp")
            try FileManager.default.copyItem(atPath: path, toPath: copy)
            setMtime(copy, ns: later.mtimeNs)
            #expect(rename(copy, path) == 0, "setup: could not rename the copy over the file")
            let replaced = try #require(seen(path))
            #expect(replaced.size == later.size && replaced.mtimeNs == later.mtimeNs && replaced.inode != later.inode,
                    "setup: the inode-only change did not isolate the inode: \(later) then \(replaced)")
            #expect(attempt(path, expecting: later).error == "changed", "a different inode should throw changed")

            // and with the identity it has now, the same file reads again
            #expect(attempt(path, expecting: replaced).step != nil, "control: with its new identity the file reads")
        }
    }

    // MARK: gone, no longer admitted, not openable

    @Test func aGoneFileAKeyNameAndALinkAreNotAdmittedWhateverIdentityIsGiven() throws {
        try withDocDir { dir in
            let real = try DocMaker.write(DocMaker.sample("txt", stem: "realpaper", number: 7), in: dir.path)
            #expect(attempt(real).step != nil, "control: the plain document reads")

            let gone = dir.file("vanished.txt")
            #expect(attempt(gone, expecting: Seen(size: 5, mtimeNs: 5, inode: 5)).error == "notAdmitted", "a path with nothing at it should throw notAdmitted")

            let key = dir.file("id_rsa.txt")
            try FileManager.default.copyItem(atPath: real, toPath: key)
            #expect(Rules.admit(path: key) == nil, "setup: the rules should refuse a key name")
            #expect(Rules.admit(path: real) != nil, "setup: the rules should admit the plain name")
            #expect(attempt(key).error == "notAdmitted", "a key-name file should throw notAdmitted")

            let envKey = dir.file(".env.md")
            try FileManager.default.copyItem(atPath: real, toPath: envKey)
            #expect(Rules.admit(path: envKey) == nil, "setup: the rules should refuse an .env name")
            #expect(attempt(envKey).error == "notAdmitted", "an .env.md file should throw notAdmitted")

            let link = dir.file("linkedpaper.txt")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
            #expect(Rules.admit(path: link) == nil, "setup: the rules should refuse a link")
            #expect(attempt(link).error == "notAdmitted", "a symbolic link should throw notAdmitted")

            let folder = dir.file("foldernamed.txt")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            #expect(attempt(folder).error == "notAdmitted", "a folder named like a document should throw notAdmitted")
        }
    }

    @Test func aFileTheProcessMayNotOpenThrowsCannotOpen() throws {
        try withDocDir { dir in
            guard canTestPermissions() else { return }
            let path = try DocMaker.write(DocMaker.sample("txt", stem: "closedpaper", number: 8), in: dir.path)
            #expect(attempt(path).step != nil, "control: the file reads while it is open to the process")
            #expect(chmod(path, 0) == 0, "setup: could not remove the file's permissions")
            let outcome = attempt(path)
            #expect(outcome.error == "cannotOpen", "a file with mode 000 should throw cannotOpen, it \(describe(outcome))")
        }
    }
}
