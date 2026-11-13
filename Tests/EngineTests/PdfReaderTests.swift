import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import SesameEngine

// plan-4-t4, tester step. Written from the t4 entry of plan-4-tasks.md (Tests), the Conventions of plan-4-tasks.md and
// plan-3-tasks.md, design section 3 and the spec's S3 only; no product source is read.
//
// Names, and how they were found:
//   - `PdfReader.read(path:expecting:firstPage:) throws -> PdfStep`, `PdfStep.pageCount`, `.pages: [PdfPage]`, `.nameWords`,
//     `PdfPage.number` (1-based), `.text(String)` and `.scan`, `PdfReader.textThreshold` (200), `PdfReader.stepPages` (30) and
//     `PdfReadError` (`.locked`, `.unreadable`, `.changed`, `.notAdmitted`, `.cannotOpen`): the names the entry fixes. None exists yet.
//   - `FileIdentity(size:mtimeNs:inode:)` and the way the sealed PhotoDamageTests make one from `lstat`: the photo reader's
//     `expecting` argument, which the entry says the PDF reader shares.
//   - `Rules.admit(path:)` (name level, no picks): the sealed RulesTests. Used only to check this file's own samples (a key name
//     and a link are refused, the same bytes under an ordinary name are admitted), never to compute an expected value.
//
// SHAPE THIS FILE PINS (the entry gives `number` and the two cases, not the name of the property that holds the case; if the
// shape is wrong, ask for a test change; the two accessors `textOf` and `isScan` below are the one place to edit):
//   `PdfPage` has `number: Int` and `kind`, an enum with `.text(String)` and `.scan` (a `.scan` may carry more later: the
//   tests match it with `case .scan`, never with a payload).
//
// Every PDF is drawn by this file with CoreGraphics and CoreText (a real text layer) under $TMPDIR and removed again. Every
// expected value is written by hand: the page counts, the page numbers, the 199 and 200 character pages. The independent check of
// each sample is PDFKit's own reading of it, done by the test (never by the code under test).
//
// Counting a page's characters: the two boundary pages are one line of letters with no space in it (200 and 199 letters), so
// every sensible way of counting (trimmed or not, with or without spaces) gives the same number. The other text pages hold
// about 340 characters.

// MARK: making PDFs (shared with HelperPdfTests.swift)

struct PdfMakerError: Error, CustomStringConvertible {
    let description: String
}

enum PdfMaker {
    enum Page {
        case text(String)
        case blank
    }

    static let width: CGFloat = 1000
    static let height: CGFloat = 600

    static let fillerSentence = "The grey harbour keeps a copper lantern beside the old meadow gate. "

    /// A word no stemmer changes and no filler holds: `prefix` then four consonants that spell `number`.
    static func token(_ prefix: String, _ number: Int) -> String {
        let letters = Array("bfghjklmnpqrtvwxz")
        var rest = number
        var tail = ""
        for _ in 0..<4 {
            tail = String(letters[rest % letters.count]) + tail
            rest /= letters.count
        }
        return prefix + tail
    }

    /// About 340 characters of ordinary words with `token` in them once.
    static func rich(_ token: String) -> String {
        "Notes about \(token) follow. " + String(repeating: fillerSentence, count: 5)
    }

    /// Exactly `count` letters, no space.
    static func letters(_ count: Int) -> String {
        let source = Array("abcdefghij")
        return String((0..<count).map { source[$0 % source.count] })
    }

    static func wrap(_ text: String, limit: Int = 90) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Writes `pages` to `path` with the system PDF writer. With `userPassword` the file asks for it before it opens.
    static func write(_ pages: [Page], to path: String, userPassword: String? = nil) throws {
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        var info: [String: Any] = [:]
        if let userPassword {
            info[kCGPDFContextUserPassword as String] = userPassword
            info[kCGPDFContextOwnerPassword as String] = userPassword + "-owner"
        }
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw PdfMakerError(description: "the system could not start a PDF at \(path)")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        for page in pages {
            context.beginPDFPage(nil)
            if case .text(let text) = page {
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                var y = height - 30
                for line in wrap(text) {
                    context.textPosition = CGPoint(x: 20, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
                    y -= 12
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// The first `bytes` bytes of `source`, written to `path`: a cut file.
    static func cut(_ source: String, to path: String, bytes: Int) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        try data.prefix(bytes).write(to: URL(fileURLWithPath: path))
    }

    /// A PDF by hand with a page tree that holds no page.
    static func writeZeroPagePdf(to path: String) throws {
        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        offsets.append(body.utf8.count)
        body += "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        offsets.append(body.utf8.count)
        body += "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
        let table = body.utf8.count
        body += "xref\n0 3\n0000000000 65535 f \n"
        for offset in offsets { body += String(format: "%010d 00000 n \n", offset) }
        body += "trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// What PDFKit itself reads on each page (the test's own witness), nil when PDFKit cannot open the file.
    static func pageStrings(_ path: String) -> [String]? {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked else { return nil }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    static func isLockedByPdfKit(_ path: String) -> Bool {
        PDFDocument(url: URL(fileURLWithPath: path))?.isLocked == true
    }
}

// MARK: a temp folder

private final class PdfDir {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-pdfreader-" + UUID().uuidString, isDirectory: true)
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

private func withPdfDir(_ body: (PdfDir) throws -> Void) throws {
    let dir = try PdfDir()
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

private func textOf(_ page: PdfPage) -> String? {
    if case .text(let text) = page.kind { return text }
    return nil
}

private func isScan(_ page: PdfPage) -> Bool {
    if case .scan = page.kind { return true }
    return false
}

private struct Outcome {
    let step: PdfStep?
    let error: String?
}

/// Reads one step. `expecting` defaults to what `lstat` says now. An error is its case name ("locked", "unreadable", ...).
private func attempt(_ path: String, expecting: Seen? = nil, firstPage: Int = 1) -> Outcome {
    let known = expecting ?? seen(path) ?? Seen(size: 0, mtimeNs: 0, inode: 0)
    do {
        return Outcome(step: try PdfReader.read(path: path, expecting: identity(known), firstPage: firstPage), error: nil)
    } catch let error as PdfReadError {
        return Outcome(step: nil, error: String(describing: error))
    } catch {
        return Outcome(step: nil, error: "other: \(error)")
    }
}

private func describe(_ outcome: Outcome) -> String {
    if let error = outcome.error { return "threw \(error)" }
    guard let step = outcome.step else { return "no step and no error" }
    return "read \(step.pages.count) page(s) of \(step.pageCount)"
}

private func canTestPermissions() -> Bool {
    if getuid() == 0 {
        Issue.record("this test runs as root, and root opens a file with mode 000: it cannot show anything; run it as the person")
        return false
    }
    return true
}

// MARK: the tests

@Suite("PdfReaderTests")
struct PdfReaderTests {

    // MARK: the two numbers

    @Test func theTextThresholdIs200CharactersAndAStepIs30Pages() {
        #expect(PdfReader.textThreshold == 200, "textThreshold is \(PdfReader.textThreshold)")
        #expect(PdfReader.stepPages == 30, "stepPages is \(PdfReader.stepPages)")
    }

    // MARK: a text PDF

    @Test func aThreePageTextPdfGivesItsThreePagesInOrderEachWithItsOwnWords() throws {
        try withPdfDir { dir in
            let tokens = (1...3).map { PdfMaker.token("zorv", $0) }
            let path = dir.file("harbourledger.pdf")
            try PdfMaker.write(tokens.map { .text(PdfMaker.rich($0)) }, to: path)
            let witness = try #require(PdfMaker.pageStrings(path), "setup: PDFKit cannot read the sample")
            #expect(witness.count == 3, "setup: PDFKit sees \(witness.count) pages")
            for (index, text) in witness.enumerated() {
                #expect(text.contains(tokens[index]), "setup: PDFKit finds no text layer with \(tokens[index]) on page \(index + 1)")
            }

            let outcome = attempt(path)
            let step = try #require(outcome.step, "a 3-page text PDF should read, it \(describe(outcome))")
            #expect(step.pageCount == 3, "pageCount is \(step.pageCount)")
            #expect(step.pages.map(\.number) == [1, 2, 3], "page numbers are \(step.pages.map(\.number))")
            for (index, page) in step.pages.enumerated() {
                let text = try #require(textOf(page), "page \(index + 1) should be text, it is not")
                #expect(text.contains(tokens[index]), "page \(index + 1) does not hold its own word \(tokens[index])")
                for other in tokens.indices where other != index {
                    #expect(!text.contains(tokens[other]), "page \(index + 1) holds the word of page \(other + 1)")
                }
            }
            #expect(String(describing: step.nameWords).lowercased().contains("harbourledger"),
                    "nameWords \(step.nameWords) does not hold the file name word")
        }
    }

    @Test func readingLeavesTheFileAsItWasAndTwoReadsAgree() throws {
        try withPdfDir { dir in
            let path = dir.file("steadyfile.pdf")
            try PdfMaker.write((1...3).map { .text(PdfMaker.rich(PdfMaker.token("quil", $0))) }, to: path)
            let before = try #require(seen(path))
            let first = try #require(attempt(path).step)
            let second = try #require(attempt(path).step)
            #expect(seen(path) == before, "reading changed the file's size, modified time or inode")
            #expect(first.pages.compactMap(textOf) == second.pages.compactMap(textOf), "two reads of one file differ")
        }
    }

    // MARK: text or scan

    @Test func aPageWith200CharactersIsTextAndOneWith199OrNoneIsScan() throws {
        try withPdfDir { dir in
            let path = dir.file("threshold.pdf")
            let rich = PdfMaker.rich(PdfMaker.token("bamp", 4))
            try PdfMaker.write([.text(PdfMaker.letters(200)), .text(PdfMaker.letters(199)), .blank, .text(rich)], to: path)
            let witness = try #require(PdfMaker.pageStrings(path), "setup: PDFKit cannot read the sample")
            let counts = witness.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).count }
            #expect(witness.count == 4 && counts[0] == 200 && counts[1] == 199 && counts[2] == 0 && counts[3] >= 250,
                    "setup: PDFKit counts \(counts) characters on the four pages, expected 200, 199, 0 and 250 or more")

            let step = try #require(attempt(path).step, "the sample should read")
            #expect(step.pageCount == 4 && step.pages.map(\.number) == [1, 2, 3, 4], "pages \(step.pages.map(\.number)) of \(step.pageCount)")
            guard step.pages.count == 4 else { return }
            #expect(textOf(step.pages[0]) != nil, "a page with exactly 200 characters should be text")
            #expect(textOf(step.pages[0])?.contains(PdfMaker.letters(200)) == true, "the 200 character page lost its text")
            #expect(isScan(step.pages[1]), "a page with 199 characters should be a scan")
            #expect(isScan(step.pages[2]), "a page with no text at all should be a scan")
            #expect(textOf(step.pages[3])?.contains(PdfMaker.token("bamp", 4)) == true, "the 340 character page should be text")
        }
    }

    // MARK: steps of at most 30 pages

    @Test func oneCallReturnsAtMostThirtyPagesAndFirstPageMovesTheStep() throws {
        try withPdfDir { dir in
            let tokens = (1...31).map { PdfMaker.token("dros", $0) }
            let path = dir.file("thirtyone.pdf")
            try PdfMaker.write(tokens.map { .text(PdfMaker.rich($0)) }, to: path)
            let witness = try #require(PdfMaker.pageStrings(path), "setup: PDFKit cannot read the sample")
            #expect(witness.count == 31, "setup: PDFKit sees \(witness.count) pages")

            let first = try #require(attempt(path, firstPage: 1).step, "firstPage 1 should read")
            #expect(first.pageCount == 31, "pageCount is \(first.pageCount), expected 31")
            #expect(first.pages.map(\.number) == Array(1...30), "firstPage 1 gave pages \(first.pages.map(\.number))")
            #expect(!first.pages.compactMap(textOf).contains { $0.contains(tokens[30]) }, "step one holds the text of page 31")

            let last = try #require(attempt(path, firstPage: 31).step, "firstPage 31 should read")
            #expect(last.pageCount == 31, "pageCount is \(last.pageCount), expected 31")
            #expect(last.pages.map(\.number) == [31], "firstPage 31 gave pages \(last.pages.map(\.number))")
            #expect(last.pages.first.flatMap(textOf)?.contains(tokens[30]) == true, "page 31 does not hold its own word")

            let second = try #require(attempt(path, firstPage: 2).step, "firstPage 2 should read")
            #expect(second.pages.map(\.number) == Array(2...31), "firstPage 2 gave pages \(second.pages.map(\.number))")
        }
    }

    @Test func aThirtyPageAndAOnePagePdfAreOneStep() throws {
        try withPdfDir { dir in
            let thirty = dir.file("thirty.pdf")
            let one = dir.file("single.pdf")
            try PdfMaker.write((1...30).map { .text(PdfMaker.rich(PdfMaker.token("kelv", $0))) }, to: thirty)
            try PdfMaker.write([.text(PdfMaker.rich(PdfMaker.token("kelv", 99)))], to: one)
            let step30 = try #require(attempt(thirty).step)
            #expect(step30.pageCount == 30 && step30.pages.map(\.number) == Array(1...30),
                    "30 pages: pageCount \(step30.pageCount), numbers \(step30.pages.map(\.number))")
            let step1 = try #require(attempt(one).step)
            #expect(step1.pageCount == 1 && step1.pages.map(\.number) == [1], "1 page: \(step1.pages.map(\.number)) of \(step1.pageCount)")
        }
    }

    // MARK: files that cannot be read

    @Test func aPdfWithAUserPasswordThrowsLocked() throws {
        try withPdfDir { dir in
            let path = dir.file("sealedfile.pdf")
            try PdfMaker.write([.text(PdfMaker.rich("secretword")), .text(PdfMaker.rich("hiddenword"))], to: path, userPassword: "kit-locked-7")
            #expect(PdfMaker.isLockedByPdfKit(path), "setup: PDFKit does not call the sample locked")
            let outcome = attempt(path)
            #expect(outcome.error == "locked", "a PDF with a user password should throw locked, it \(describe(outcome))")
        }
    }

    @Test func aCutPdfAndAFileThatIsNotAPdfAndAPdfWithNoPageThrowUnreadable() throws {
        try withPdfDir { dir in
            let whole = dir.file("whole.pdf")
            try PdfMaker.write((1...3).map { .text(PdfMaker.rich(PdfMaker.token("zorv", $0))) }, to: whole)
            let control = attempt(whole)
            #expect(control.step != nil, "control: the uncut PDF should read, it \(describe(control))")

            let cut = dir.file("cutfile.pdf")
            try PdfMaker.cut(whole, to: cut, bytes: 200)
            let notPdf = dir.file("textfile.pdf")
            try Data("This is plain text, not a PDF.\n".utf8).write(to: URL(fileURLWithPath: notPdf))
            let empty = dir.file("nopages.pdf")
            try PdfMaker.writeZeroPagePdf(to: empty)

            for path in [cut, notPdf, empty] {
                #expect((PdfMaker.pageStrings(path) ?? []).isEmpty, "setup: PDFKit still reads pages from \((path as NSString).lastPathComponent)")
                let outcome = attempt(path)
                #expect(outcome.error == "unreadable", "\((path as NSString).lastPathComponent) should throw unreadable, it \(describe(outcome))")
            }
        }
    }

    // MARK: the file changed since it was listed

    @Test func aChangedSizeOrMtimeOrInodeThrowsChangedAndTheUnchangedFileStillReads() throws {
        try withPdfDir { dir in
            let path = dir.file("shifting.pdf")
            try PdfMaker.write((1...2).map { .text(PdfMaker.rich(PdfMaker.token("plum", $0))) }, to: path)
            let before = try #require(seen(path))
            #expect(attempt(path, expecting: before).step != nil, "control: with the identity it has, the file reads")

            // size only: bytes added at the end, the modified time put back, the same inode
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n% added\n".utf8))
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
        try withPdfDir { dir in
            let real = dir.file("realpaper.pdf")
            try PdfMaker.write([.text(PdfMaker.rich(PdfMaker.token("zorv", 8)))], to: real)
            #expect(attempt(real).step != nil, "control: the plain PDF reads")

            let gone = dir.file("vanished.pdf")
            #expect(attempt(gone, expecting: Seen(size: 5, mtimeNs: 5, inode: 5)).error == "notAdmitted", "a path with nothing at it should throw notAdmitted")

            let key = dir.file("id_rsa.pdf")
            try FileManager.default.copyItem(atPath: real, toPath: key)
            #expect(Rules.admit(path: key) == nil, "setup: the rules should refuse a key name")
            #expect(Rules.admit(path: real) != nil, "setup: the rules should admit the plain name")
            #expect(attempt(key).error == "notAdmitted", "a key-name file should throw notAdmitted")

            let link = dir.file("linkedpaper.pdf")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
            #expect(Rules.admit(path: link) == nil, "setup: the rules should refuse a link")
            #expect(attempt(link).error == "notAdmitted", "a symbolic link should throw notAdmitted")

            let folder = dir.file("foldernamed.pdf")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            #expect(attempt(folder).error == "notAdmitted", "a folder named like a PDF should throw notAdmitted")
        }
    }

    @Test func aFileTheProcessMayNotOpenThrowsCannotOpen() throws {
        try withPdfDir { dir in
            guard canTestPermissions() else { return }
            let path = dir.file("closedpaper.pdf")
            try PdfMaker.write([.text(PdfMaker.rich(PdfMaker.token("zorv", 9)))], to: path)
            #expect(attempt(path).step != nil, "control: the file reads while it is open to the process")
            #expect(chmod(path, 0) == 0, "setup: could not remove the file's permissions")
            let outcome = attempt(path)
            #expect(outcome.error == "cannotOpen", "a file with mode 000 should throw cannotOpen, it \(describe(outcome))")
        }
    }
}

// MARK: plan-5-t3, tester step: a PDF step can be stopped (Pause within 5 s on a PDF unit)

// Written from the t3 entry of plan-5-tasks.md ("`PdfReaderTests` extended: `PdfReader.read(path:expecting:firstPage:shouldStop:)` (the new
// parameter defaults to never stopping, so every sealed call compiles) throws `MediaStopped` when `shouldStop` is true, polled before each page"),
// Decision D10 and t2's `MediaStopped` only; no product source is read. The default-parameter half is carried by every sealed call above, which
// are unchanged and call `PdfReader.read(path:expecting:firstPage:)`. No sealed test of this file or of HelperPdfQueueTests pins "one PDF step is
// uninterruptible" (the tester read both: every helper test there ends stdin only after the file is done), so none is amended.
//
// SHAPES PINNED that the entry did not fix: `shouldStop` is a `() -> Bool`; "before each page" means one call before page 1, one before page 2 and
// so on, so a read of n pages calls it n times (n + 1 is accepted: a last check before the result is built); a stop at the k-th call throws
// `MediaStopped` with no further call and no step; the check sits before the recognition of a scan page, so a stop after 3 pages of a long scan
// returns long before the whole step would. The time per scan page (the longest gap between two checks) is printed for the report (U10).

private final class PdfStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var stamps: [Date] = []
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; stamps.append(Date()); return n }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
    var times: [Date] { lock.lock(); defer { lock.unlock() }; return stamps }
}

private func stoppableRead(_ path: String, stopAt: Int? = nil, counter: PdfStopCounter) -> (step: PdfStep?, error: String?) {
    let known = seen(path) ?? Seen(size: 0, mtimeNs: 0, inode: 0)
    do {
        let step = try PdfReader.read(path: path, expecting: identity(known), firstPage: 1, shouldStop: {
            let call = counter.bump()
            if let stopAt { return call >= stopAt }
            return false
        })
        return (step, nil)
    } catch is MediaStopped {
        return (nil, "stopped")
    } catch let error as PdfReadError {
        return (nil, String(describing: error))
    } catch {
        return (nil, "other: \(error)")
    }
}

extension PdfReaderTests {

    @Test func aShouldStopThatIsTrueFromTheStartThrowsMediaStoppedAndReadsNoPage() throws {
        try withPdfDir { dir in
            let path = dir.file("stopfirst.pdf")
            try PdfMaker.write((1...5).map { .text(PdfMaker.rich(PdfMaker.token("stop", $0))) }, to: path)
            let counter = PdfStopCounter()
            let outcome = stoppableRead(path, stopAt: 1, counter: counter)
            #expect(outcome.error == "stopped" && outcome.step == nil, "a stop at the first check should throw MediaStopped and return no step, got \(outcome.error ?? "a step")")
            #expect(counter.calls == 1, "shouldStop was called \(counter.calls) times, expected once (no check after a stop)")
        }
    }

    @Test func shouldStopIsCalledBeforeEachPageAndAStopAtTheThirdCheckThrowsMediaStoppedWithNoFurtherCheck() throws {
        try withPdfDir { dir in
            let path = dir.file("fivepages.pdf")
            try PdfMaker.write((1...5).map { .text(PdfMaker.rich(PdfMaker.token("poll", $0))) }, to: path)
            let all = PdfStopCounter()
            let full = stoppableRead(path, counter: all)
            #expect(full.step?.pages.count == 5, "control: a shouldStop that never stops reads all 5 pages, it read \(full.step?.pages.count ?? 0) (\(full.error ?? "no error"))")
            #expect((5...6).contains(all.calls), "a read of 5 pages called shouldStop \(all.calls) times, expected one before each page (5, or 6 with a last check)")

            let some = PdfStopCounter()
            let stopped = stoppableRead(path, stopAt: 3, counter: some)
            #expect(stopped.error == "stopped" && stopped.step == nil, "a stop at the third check should throw MediaStopped and return no step, got \(stopped.error ?? "a step")")
            #expect(some.calls == 3, "shouldStop was called \(some.calls) times, expected 3 (it is not called again after it said stop)")
        }
    }

    @Test func aStopAfterThreePagesOfAScanReturnsLongBeforeTheWholeStepAndTheLongestGapBetweenChecksIsAPageNotAStep() throws {
        try withPdfDir { dir in
            let path = dir.file("longscan.pdf")
            try ScanPdf.write((1...16).map { .picture(["APRICOT", "BALLAD", "CANYON", "DOLPHIN"][$0 % 4] + String($0)) }, to: path)
            // a first read warms the recogniser; the second is the timed whole step
            _ = stoppableRead(path, counter: PdfStopCounter())
            let whole = PdfStopCounter()
            let started = Date()
            let full = stoppableRead(path, counter: whole)
            let fullSeconds = Date().timeIntervalSince(started)
            #expect(full.step?.pages.count == 16, "control: the 16 scan pages read, it read \(full.step?.pages.count ?? 0) (\(full.error ?? "no error"))")
            let gaps = zip(whole.times, whole.times.dropFirst()).map { $1.timeIntervalSince($0) }
            let longest = gaps.max() ?? 0
            print("READING pdf scan shouldStop calls=\(whole.calls) longest gap=\(String(format: "%.2f", longest)) s over a step of 16 scan pages (\(String(format: "%.1f", fullSeconds)) s)")
            #expect(whole.calls >= 16, "shouldStop was called \(whole.calls) times over 16 scan pages, expected one before each page")
            #expect(longest < 4.0, "the longest time between two stop checks is \(longest) s, the bar for one unit is 4.0 s")

            let part = PdfStopCounter()
            let stoppedStart = Date()
            let stopped = stoppableRead(path, stopAt: 4, counter: part)
            let stoppedSeconds = Date().timeIntervalSince(stoppedStart)
            #expect(stopped.error == "stopped", "a stop at the fourth check should throw MediaStopped, got \(stopped.error ?? "a step")")
            #expect(stoppedSeconds < fullSeconds * 0.6, "the stopped read took \(String(format: "%.2f", stoppedSeconds)) s, the whole step \(String(format: "%.1f", fullSeconds)) s: the check is not between pages (a stop after 3 of 16 pages should cost about a fifth)")
        }
    }
}
