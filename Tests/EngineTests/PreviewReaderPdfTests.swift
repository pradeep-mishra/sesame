import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import SesameEngine

// plan-4-t7, tester step. Written from the t7 entry of plan-4-tasks.md (Tests), the Conventions of plan-4-tasks.md, Decision D7,
// design sections 3 and 5 and the spec's S3 only; no product source is read. The rigs reused, never edited: the `At...` harness of
// IndexAttemptTests.swift (AtWorld, AtDB, atStartHelper, atFoldersLine, atWaitStatuses, atCleanStop, atHelperWarm, atPast), `ScanPdf`
// of PdfScanTests.swift (the picture pages and its PDFKit and Vision witness), `homeLock` of SesameFolderTests.swift, and
// `t34Decode` of PreviewReaderTests.swift.
//
// How a run is made. One shared world (a lazily built global, like the other helper suites): a folder of seven PDFs, every one drawn
// by this file, picked by the bundled release helper alone (`scripts/bundle.sh` first), fake embedder, throwaway HOME. When all seven
// files are `done` the helper is stopped, so the index is closed. Then each test calls `PreviewReader.reply(ticket:file:passage:query:)`
// in this process with the passage id this file reads from the index, under the world's HOME (the product reads HOME when it is
// called, as SesameFolderTests establishes) and under `homeLock`. The independent judge of the mark is the kit's
// `scripts/kit-readback.sh mark-check <png> <pdf> <page> --answers <csv>` (t3), run as a child process on the PNG the reply names:
// the test writes a one-row csv that holds the rectangle it drew as `box=x:y:w:h` (points, origin bottom left). Exit 0 means the
// mark lies on the known passage; exit 1 with `no mark` means the page was found in the picture and carries no mark; exit 4 means
// the picture is not that page.
//
// The files of the world (each test mutates only its own):
//   lease.pdf         12 text pages; a clause on page 7 at the rectangle (72, 430, 468, 60); a line about a zebrafinch on page 3
//   swap-match.pdf    the same 12 pages when indexed; replaced after indexing by a 3-page PDF whose page 2 holds the clause
//   swap-nomatch.pdf  the same 12 pages when indexed; replaced after indexing by a 3-page PDF with no clause on any page
//   gone-deleted.pdf  the same 12 pages; deleted after indexing
//   gone-moved.pdf    the same 12 pages; moved into a folder named Caches after indexing
//   broken.pdf        the same 12 pages; after indexing its bytes are overwritten in place with zeros, size and mtime restored
//   scan.pdf          3 picture pages with no text layer: SADDLE, WALNUT, COBBLER, one word each, at a known place
//
// SHAPES THIS FILE PINS (the entry names the fields, not these; each is one place to edit, the helpers `pvReply` and `pvKeyRow`):
//   1. `PreviewReader(scratch: Scratch()).reply(ticket: Int, file: String, passage: Int?, query: String) -> PreviewReply`: the entry
//      writes `PreviewReader.reply(ticket:file:passage:query:)`; the compiler shows the class `PreviewReader` with
//      `init(scratch: Scratch)` and the instance method `reply(ticket:file:)`, so the new method is an instance method of the same class
//      with the two new parameters after `file`, `passage` an `Int?` (the type `HelperCommand.preview` of ProtocolTests gives it) and
//      `query` a `String`. `Scratch()` with no argument is what the compiler accepted. The one place to edit is `pvReply`.
//   2. The PNG of a PDF reply is the whole page, so its proportions are the page's within 2 per cent; its size is not pinned.
//   3. `PreviewReply.kind` is "pdf" for a PDF; `name` is the file name; `size` and `mtime` are what `stat` says (as for a photo).
//   4. A gone reply has `png`, `size`, `mtime`, `page`, `pageCount`, `locator` all nil. The "Page N of M" locator, `page` and
//      `pageCount` are nil for the unopenable PDF as well (status `.ok`, no PNG: the pane's existing "Can't preview this file").
//   5. A scanned page is marked from the query word, matched case-insensitively against the words Vision read on that page.
//   6. The unopenable PDF is made by overwriting the indexed file in place with zeros of the same length and restoring its mtime to
//      the nanosecond, so the file's size, mtime and inode are exactly what the index holds and only its content is gone.
//
// Every expected value is written by hand: the page numbers (7 of 12, 2 of 3, 3 of 3), the locator strings, the rectangles, the words.

// MARK: the words and rectangles

private let pvQuery = "written landlord consent"
private let pvClauseText = "One cat is allowed with written landlord consent"
private let pvLeaseBox = CGRect(x: 72, y: 430, width: 468, height: 60)
private let pvZebraBox = CGRect(x: 72, y: 300, width: 468, height: 40)
private let pvZebraText = "A zebrafinch sings near the orchard gate"
private let pvSwapBox = CGRect(x: 100, y: 300, width: 400, height: 60)
/// The word WALNUT of ScanPdf's page 2: drawn at (40, 250), 96 points bold, about 416 points wide and 70 high.
private let pvScanBox = CGRect(x: 30, y: 240, width: 440, height: 90)
private let pvFiller = ["harbour", "ledger", "orchard", "copper", "meadow", "lantern", "quarry", "velvet", "thistle", "granite",
                        "willow", "ember", "saddle", "marble", "falcon", "tundra", "bramble", "cinder", "plover", "nectar"]
private let pvPageWidth: CGFloat = 612
private let pvPageHeight: CGFloat = 792

// MARK: drawing text PDFs (a real text layer, a picture unique to each page)

private struct PvRand {
    var state: UInt64
    init(_ seed: Int) { state = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 12345) }
    mutating func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
}

private func pvDrawText(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, gray: CGFloat = 0) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
    ]
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)), ctx)
}

/// A letter page whose picture is unique to its number: a large grey number, 30 black squares and 16 lines of filler words, all placed
/// from the number. Each passage (a rectangle in points, origin bottom left, and its text) is drawn where it says; the lines of words
/// skip its band, so the passage's words are nowhere else on the page.
private func pvDrawPage(_ ctx: CGContext, number: Int, passages: [(CGRect, String)]) {
    var r = PvRand(number)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pvPageWidth, height: pvPageHeight))
    pvDrawText(ctx, String(number), x: 120, y: 90, size: 280, bold: true, gray: 0.55)
    for _ in 0..<30 {
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 40 + r.next(500), y: 40 + r.next(700), width: 16, height: 16))
    }
    var y: CGFloat = 740
    for _ in 0..<16 {
        var line: [String] = []
        for _ in 0..<7 { line.append(pvFiller[r.next(pvFiller.count)]) }
        let blocked = passages.contains { box, _ in y < box.maxY + 14 && y > box.minY - 26 }
        if !blocked { pvDrawText(ctx, line.joined(separator: " "), x: 40, y: y, size: 13) }
        y -= 22
    }
    for (box, text) in passages {
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        ctx.stroke(box)
        pvDrawText(ctx, text, x: box.minX + 6, y: box.minY + box.height / 2 - 5, size: 14)
    }
}

private struct PvError: Error, CustomStringConvertible {
    let description: String
}

/// Writes `pages` pages to `path`; `passages[page]` holds what that page carries.
private func pvWritePDF(_ path: String, pages: Int, passages: [Int: [(CGRect, String)]] = [:]) throws {
    var box = CGRect(x: 0, y: 0, width: pvPageWidth, height: pvPageHeight)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else {
        throw PvError(description: "the system could not start a PDF at \(path)")
    }
    for page in 1...pages {
        ctx.beginPDFPage(nil)
        pvDrawPage(ctx, number: page, passages: passages[page] ?? [])
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

private let pvLeasePassages: [Int: [(CGRect, String)]] = [
    3: [(pvZebraBox, pvZebraText)],
    7: [(pvLeaseBox, pvClauseText)],
]

// MARK: facts about a file, read by the test itself

private struct PvFacts: Equatable {
    var size: Int64
    var mtimeNs: Int64
    var inode: UInt64
    var bytes: Data
}

private func pvFacts(_ path: String) -> PvFacts? {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0, let bytes = FileManager.default.contents(atPath: path) else { return nil }
    return PvFacts(size: Int64(info.st_size),
                   mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                   inode: UInt64(info.st_ino), bytes: bytes)
}

private func pvSetMtime(_ path: String, ns: Int64) {
    let stamp = timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
    let times = [stamp, stamp]
    utimensat(AT_FDCWD, path, times, 0)
}

// MARK: the shared world

private final class PvKeeper: @unchecked Sendable {
    private let lock = NSLock()
    private var worlds: [AtWorld] = []
    private var paths: [String] = []
    func add(_ world: AtWorld) { lock.lock(); worlds.append(world); lock.unlock() }
    func add(path: String) { lock.lock(); paths.append(path); lock.unlock() }
    func run() {
        lock.lock(); let all = worlds; let folders = paths; lock.unlock()
        for world in all { world.remove() }
        for path in folders { try? FileManager.default.removeItem(atPath: path) }
        // The scratch folder this test process's readers made (`$TMPDIR/Sesame-<pid>`, design section 1).
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "Sesame-\(getpid())")
    }
}

private let pvKeeper = PvKeeper()

private struct PvWorld: @unchecked Sendable {
    var world: AtWorld?
    var problem: String?

    var folder: String { (world?.photos.path ?? "") + "/pdfs" }
    func path(_ name: String) -> String { folder + "/" + name }

    /// The id of the `page` passage of `file` for page number `page` (start is stored as REAL, so it is read as an integer).
    func passage(_ file: String, page: Int) -> Int? {
        world?.db()?.int("""
            select p.id from passages p join files f on f.id = p.file_id \
            where f.path like '%/\(file)' and p.source = 'page' and cast(p.start as integer) = \(page)
            """)
    }
}

private let pvWorld: PvWorld = {
    var out = PvWorld()
    _ = atHelperWarm
    guard let world = try? AtWorld() else { out.problem = "could not make a temp world"; return out }
    out.world = world
    pvKeeper.add(world)
    atexit { pvKeeper.run() }
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: out.folder, withIntermediateDirectories: true)
        let names = ["lease", "swap-match", "swap-nomatch", "gone-deleted", "gone-moved", "broken"]
        for (index, name) in names.enumerated() {
            let path = out.path(name + ".pdf")
            try pvWritePDF(path, pages: 12, passages: pvLeasePassages)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(index) - 10)], ofItemAtPath: path)
        }
        let scan = out.path("scan.pdf")
        try ScanPdf.write([.picture("SADDLE"), .picture("WALNUT"), .picture("COBBLER")], to: scan)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - 30)], ofItemAtPath: scan)
    } catch {
        out.problem = "could not make the files: \(error)"
        return out
    }
    // The witnesses: PDFKit finds the clause on page 7 only, every page has a real text layer, and the picture pages have none and
    // are readable by Vision. A red below is then never a sample that nobody can read.
    guard let strings = PdfMaker.pageStrings(out.path("lease.pdf")), strings.count == 12 else {
        out.problem = "setup: PDFKit does not read lease.pdf as 12 pages"
        return out
    }
    for (index, text) in strings.enumerated() {
        let page = index + 1
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 200 { out.problem = "setup: page \(page) of lease.pdf has no real text layer"; return out }
        if text.contains("landlord") != (page == 7) { out.problem = "setup: PDFKit finds the clause words on page \(page)"; return out }
        if text.contains("zebrafinch") != (page == 3) { out.problem = "setup: PDFKit finds the zebrafinch line on page \(page)"; return out }
    }
    for (index, word) in ["SADDLE", "WALNUT", "COBBLER"].enumerated() {
        guard let witness = ScanPdf.witnessWords(out.path("scan.pdf"), page: index),
              witness.layerCharacters == 0, witness.seen.uppercased().contains(word) else {
            out.problem = "setup: scan.pdf page \(index + 1) is not an image-only page that Vision reads as \(word)"
            return out
        }
    }
    let helper: HelperProcess
    do { helper = try atStartHelper(world) } catch {
        out.problem = "the bundled helper could not be started: \(error)"
        return out
    }
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    let wait = atWaitStatuses(world, helper, stall: 150, cap: 900, until: { $0 == ["done": 7] })
    guard wait.met else {
        out.problem = "the 7 PDFs did not all reach done: \(wait.statuses), stderr: \(helper.errors)"
        return out
    }
    guard atCleanStop(helper) == 0 else {
        out.problem = "the helper did not exit 0 within 120 s of its stdin ending; stderr: \(helper.errors)"
        return out
    }
    return out
}()

private struct PvStop: Error {}

private func pvWorldOrStop() throws -> PvWorld {
    let outcome = pvWorld
    if let problem = outcome.problem {
        Issue.record("setup failed: \(problem)")
        throw PvStop()
    }
    return outcome
}

// MARK: calling the reader, under the world's HOME

private func pvReply(_ world: PvWorld, file: String, passage: Int?, query: String, ticket: Int = 1) -> PreviewReply? {
    guard let home = world.world?.home.path else { return nil }
    homeLock.lock()
    defer { homeLock.unlock() }
    let previous = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home, 1)
    defer { if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") } }
    return PreviewReader(scratch: Scratch()).reply(ticket: ticket, file: file, passage: passage, query: query)
}

private func pvDropPNG(_ reply: PreviewReply?) {
    if let png = reply?.png { try? FileManager.default.removeItem(atPath: png) }
}

// MARK: the kit as judge of the mark (a child process, as the kit's own tests run it)

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let pvReadbackScript = projectRoot.appendingPathComponent("scripts/kit-readback.sh").path

private struct PvRan: Sendable {
    let status: Int32
    let output: String
}

private func pvRun(_ exe: String, _ args: [String], env: [String: String], limit: TimeInterval = 300) throws -> PvRan {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("pv7-out-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    defer { try? fm.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    try? handle.synchronize()
    return PvRan(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

private struct PvRig: Sendable {
    let base: String
    let kit: String
    let tmp: String
    let work: String
    var env: [String: String] { ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": base + "/home"] }
}

/// One temp kit root for the suite (the folder's name starts `sesame-kit`, as the kit insists); the Swift tool is compiled once in it.
private let pvRig: PvRig = {
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("pv7-" + UUID().uuidString, isDirectory: true)
    try? fm.createDirectory(at: made, withIntermediateDirectories: true)
    let base = made.resolvingSymlinksInPath().path
    let rig = PvRig(base: base, kit: base + "/sesame-kit-pv7", tmp: base + "/tmp", work: base + "/work")
    for d in [rig.kit + "/run", rig.tmp, rig.work, base + "/home"] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    pvKeeper.add(path: base)
    _ = try? pvRun("/bin/bash", [pvReadbackScript, "app-installed", "com.apple.finder"], env: rig.env, limit: 300)
    return rig
}()

/// A one-row key: `file` is the end of the PDF's path, `locator` the page, the rectangle `box=x:y:w:h` (points, origin bottom left).
private func pvKeyRow(file: String, page: Int, box: CGRect) -> String {
    let csv = """
        id,group,query,file,locator,window_s,note
        pdf-t7,pdf,the passage the test drew,\(file),\(page),,box=\(Int(box.minX)):\(Int(box.minY)):\(Int(box.width)):\(Int(box.height)); anchor=drawn by the test

        """
    let path = pvRig.work + "/key-" + UUID().uuidString + ".csv"
    try? csv.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func pvMarkCheck(png: String, pdf: String, page: Int, file: String, box: CGRect) throws -> PvRan {
    guard FileManager.default.fileExists(atPath: pvReadbackScript) else {
        Issue.record("scripts/kit-readback.sh not found")
        return PvRan(status: 127, output: "")
    }
    let key = pvKeyRow(file: file, page: page, box: box)
    let ran = try pvRun("/bin/bash", [pvReadbackScript, "mark-check", png, pdf, String(page), "--answers", key], env: pvRig.env)
    if ran.output.contains("not built yet") { Issue.record("kit-readback.sh mark-check is `not built yet`") }
    return ran
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("PreviewReaderPdfTests", .serialized)
struct PreviewReaderPdfTests {

    // MARK: the page, its numbers and the file left alone

    @Test func pageSevenOfAToTwelvePageLeaseIsOkWithItsLocatorItsNumbersAndAPngThatDecodes() throws {
        let world = try pvWorldOrStop()
        let path = world.path("lease.pdf")
        let id = try #require(world.passage("lease.pdf", page: 7), "the index holds no page passage for page 7 of lease.pdf")
        let before = try #require(pvFacts(path))
        guard let reply = pvReply(world, file: path, passage: id, query: pvQuery) else { return }
        defer { pvDropPNG(reply) }

        #expect(reply.status == .ok, "status is \(reply.status), expected ok")
        #expect(reply.ticket == 1)
        #expect(reply.name == "lease.pdf", "name is \(reply.name)")
        #expect(reply.kind == "pdf", "kind is \(reply.kind)")
        #expect(reply.size == Int(before.size), "size is \(String(describing: reply.size)), stat says \(before.size)")
        #expect(reply.mtime == Int(before.mtimeNs / 1_000_000_000), "mtime is \(String(describing: reply.mtime)), stat says \(before.mtimeNs / 1_000_000_000)")
        #expect(reply.page == 7, "page is \(String(describing: reply.page)), expected 7")
        #expect(reply.pageCount == 12, "pageCount is \(String(describing: reply.pageCount)), expected 12")
        #expect(reply.locator == "Page 7 of 12", "locator is \(String(describing: reply.locator)), expected exactly `Page 7 of 12`")
        #expect(reply.text == nil, "a PDF reply carries no passage text: \(String(describing: reply.text))")
        #expect(reply.marks.isEmpty, "a PDF reply carries no text marks: \(reply.marks)")

        let png = try #require(reply.png, "no png path in an ok PDF reply")
        #expect(png.hasPrefix("/"), "the png path is not absolute: \(png)")
        let decoded = try #require(t34Decode(URL(fileURLWithPath: png)), "the png at \(png) cannot be read by ImageIO")
        #expect(decoded.decodes, "the png at \(png) does not decode")
        #expect(decoded.type == "public.png", "the picture is of type \(decoded.type ?? "nil"), expected public.png")
        #expect(decoded.width >= 400 || decoded.height >= 400, "the png is \(decoded.width) x \(decoded.height): a thumbnail, not the page")
        let ratio = Double(decoded.width) / Double(decoded.height)
        #expect(abs(ratio - 612.0 / 792.0) < 612.0 / 792.0 * 0.02, "the png has proportions \(ratio), the page is 612 x 792 (the whole page is shown)")

        // The file is only read: size, mtime, inode and every byte are what they were.
        let after = try #require(pvFacts(path))
        #expect(after.size == before.size, "the render changed the file's size")
        #expect(after.mtimeNs == before.mtimeNs, "the render changed the file's mtime")
        #expect(after.inode == before.inode, "the render changed the file's inode")
        #expect(after.bytes == before.bytes, "the render changed the file's bytes")
    }

    // MARK: the mark, judged by the kit

    @Test func theMarkOnPageSevenLiesOnTheClauseAtTheKnownRectangleAsTheKitsMarkCheckReadsIt() throws {
        let world = try pvWorldOrStop()
        let path = world.path("lease.pdf")
        let id = try #require(world.passage("lease.pdf", page: 7))
        guard let reply = pvReply(world, file: path, passage: id, query: pvQuery) else { return }
        defer { pvDropPNG(reply) }
        let png = try #require(reply.png, "no png path in an ok PDF reply")

        let ran = try pvMarkCheck(png: png, pdf: path, page: 7, file: "pdfs/lease.pdf", box: pvLeaseBox)
        #expect(ran.status == 0, "mark-check exited \(ran.status), expected 0 (the mark lies on the clause): \(ran.output)")
    }

    @Test func aQueryWordThatIsNotOnThatPageShowsThePageUnmarkedAndStillSaysPageSevenOfTwelve() throws {
        let world = try pvWorldOrStop()
        let path = world.path("lease.pdf")
        let id = try #require(world.passage("lease.pdf", page: 7))
        // `zebrafinch` is on page 3 and on no other page (the setup checked it with PDFKit): the stored passage is page 7.
        guard let reply = pvReply(world, file: path, passage: id, query: "zebrafinch") else { return }
        defer { pvDropPNG(reply) }

        #expect(reply.status == .ok)
        #expect(reply.page == 7, "page is \(String(describing: reply.page)), expected the stored page 7")
        #expect(reply.locator == "Page 7 of 12", "locator is \(String(describing: reply.locator))")
        let png = try #require(reply.png, "no png path for an unmarked page")
        // Exit 1 with `no mark` means the picture is page 7 (a wrong page would be exit 4) and carries no coloured mark.
        let ran = try pvMarkCheck(png: png, pdf: path, page: 7, file: "pdfs/lease.pdf", box: pvLeaseBox)
        #expect(ran.status == 1 && ran.output.contains("no mark"), "mark-check exited \(ran.status), expected 1 `no mark` (page 7 shown, unmarked): \(ran.output)")
    }

    @Test func aScannedPageIsMarkedFromVisionsBoxesOfThatOnePageAndTheKitsMarkCheckAgrees() throws {
        let world = try pvWorldOrStop()
        let path = world.path("scan.pdf")
        let id = try #require(world.passage("scan.pdf", page: 2), "the index holds no page passage for page 2 of scan.pdf")
        guard let reply = pvReply(world, file: path, passage: id, query: "walnut") else { return }
        defer { pvDropPNG(reply) }

        #expect(reply.status == .ok, "status is \(reply.status)")
        #expect(reply.kind == "pdf")
        #expect(reply.page == 2, "page is \(String(describing: reply.page)), expected 2")
        #expect(reply.pageCount == 3, "pageCount is \(String(describing: reply.pageCount)), expected 3")
        #expect(reply.locator == "Page 2 of 3", "locator is \(String(describing: reply.locator)), expected exactly `Page 2 of 3`")
        let png = try #require(reply.png, "no png path for a scanned page")
        let ran = try pvMarkCheck(png: png, pdf: path, page: 2, file: "pdfs/scan.pdf", box: pvScanBox)
        #expect(ran.status == 0, "mark-check exited \(ran.status), expected 0 (the mark lies on the word WALNUT): \(ran.output)")
    }

    // MARK: changed

    @Test func aFileReplacedByAThreePagePdfIsChangedAndShowsTheFirstPageWhoseTextHoldsTheQueryWords() throws {
        let world = try pvWorldOrStop()
        let path = world.path("swap-match.pdf")
        let id = try #require(world.passage("swap-match.pdf", page: 7), "the index holds no page passage for page 7 of swap-match.pdf")
        try pvWritePDF(path, pages: 3, passages: [2: [(pvSwapBox, pvClauseText)]])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast + 600)], ofItemAtPath: path)
        let now = try #require(pvFacts(path))

        guard let reply = pvReply(world, file: path, passage: id, query: pvQuery) else { return }
        defer { pvDropPNG(reply) }
        #expect(reply.status == .changed, "status is \(reply.status), expected changed")
        #expect(reply.size == Int(now.size), "size is \(String(describing: reply.size)), stat says \(now.size) (the current size)")
        #expect(reply.mtime == Int(now.mtimeNs / 1_000_000_000), "mtime is \(String(describing: reply.mtime)) (the current time)")
        #expect(reply.page == 2, "page is \(String(describing: reply.page)), expected 2: the first page of the file as it is now that holds the query words")
        #expect(reply.pageCount == 3, "pageCount is \(String(describing: reply.pageCount)), expected 3")
        #expect(reply.locator == "Page 2 of 3", "locator is \(String(describing: reply.locator)), expected exactly `Page 2 of 3`")
        let png = try #require(reply.png, "no png path in a changed PDF reply")
        // A picture of the old file would not be page 2 of this file (exit 4); the mark must lie on the clause as drawn now.
        let ran = try pvMarkCheck(png: png, pdf: path, page: 2, file: "pdfs/swap-match.pdf", box: pvSwapBox)
        #expect(ran.status == 0, "mark-check exited \(ran.status), expected 0 (the current page 2, marked on the clause): \(ran.output)")
    }

    @Test func aFileReplacedByAThreePagePdfWithNoPageMatchingClampsTheStoredPageSevenToThree() throws {
        let world = try pvWorldOrStop()
        let path = world.path("swap-nomatch.pdf")
        let id = try #require(world.passage("swap-nomatch.pdf", page: 7))
        try pvWritePDF(path, pages: 3)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast + 700)], ofItemAtPath: path)

        guard let reply = pvReply(world, file: path, passage: id, query: pvQuery) else { return }
        defer { pvDropPNG(reply) }
        #expect(reply.status == .changed, "status is \(reply.status), expected changed")
        #expect(reply.page == 3, "page is \(String(describing: reply.page)), expected the stored page 7 clamped to 3")
        #expect(reply.pageCount == 3, "pageCount is \(String(describing: reply.pageCount)), expected 3")
        #expect(reply.locator == "Page 3 of 3", "locator is \(String(describing: reply.locator)), expected exactly `Page 3 of 3`")
        let png = try #require(reply.png, "no png path in a changed PDF reply")
        let ran = try pvMarkCheck(png: png, pdf: path, page: 3, file: "pdfs/swap-nomatch.pdf", box: pvLeaseBox)
        #expect(ran.status == 1 && ran.output.contains("no mark"), "mark-check exited \(ran.status), expected 1 `no mark` (the current page 3, unmarked): \(ran.output)")
    }

    // MARK: gone

    @Test func aDeletedPdfIsGoneWithNothingToShow() throws {
        let world = try pvWorldOrStop()
        let path = world.path("gone-deleted.pdf")
        let id = try #require(world.passage("gone-deleted.pdf", page: 7))
        try FileManager.default.removeItem(atPath: path)

        guard let reply = pvReply(world, file: path, passage: id, query: pvQuery) else { return }
        defer { pvDropPNG(reply) }
        #expect(reply.status == .gone, "status is \(reply.status), expected gone")
        #expect(reply.name == "gone-deleted.pdf", "name is \(reply.name)")
        #expect(reply.png == nil, "a gone file has a png: \(String(describing: reply.png))")
        #expect(reply.size == nil && reply.mtime == nil, "a gone file has size \(String(describing: reply.size)) and mtime \(String(describing: reply.mtime))")
        #expect(reply.page == nil && reply.pageCount == nil && reply.locator == nil,
                "a gone file keeps a page: \(String(describing: reply.page)) of \(String(describing: reply.pageCount)), \(String(describing: reply.locator))")
    }

    @Test func aPdfMovedIntoACachesFolderIsGoneAtItsNewPathAndAtItsOldOne() throws {
        let world = try pvWorldOrStop()
        let old = world.path("gone-moved.pdf")
        let id = try #require(world.passage("gone-moved.pdf", page: 7))
        let caches = world.folder + "/Caches"
        try FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let moved = caches + "/gone-moved.pdf"
        try FileManager.default.moveItem(atPath: old, toPath: moved)
        #expect(FileManager.default.fileExists(atPath: moved), "the test's moved file is not on disk")

        for (label, file) in [("its new path inside Caches", moved), ("its old path", old)] {
            guard let reply = pvReply(world, file: file, passage: id, query: pvQuery) else { continue }
            defer { pvDropPNG(reply) }
            #expect(reply.status == .gone, "\(label): status is \(reply.status), expected gone")
            #expect(reply.png == nil, "\(label): a gone file has a png: \(String(describing: reply.png))")
            #expect(reply.locator == nil && reply.page == nil, "\(label): a gone file keeps a page or a locator")
        }
    }

    // MARK: a PDF that no longer opens (G20)

    @Test func aPdfThatNoLongerOpensIsOkWithNoPngAndNoLocatorSoThePaneSaysItCannotPreviewIt() throws {
        let world = try pvWorldOrStop()
        let path = world.path("broken.pdf")
        let id = try #require(world.passage("broken.pdf", page: 7))
        let facts = try #require(pvFacts(path))
        // Same length, same inode (written in place), same mtime to the nanosecond: the index still holds what it read.
        let handle = try #require(FileHandle(forWritingAtPath: path), "the test cannot open broken.pdf for writing")
        try handle.write(contentsOf: Data(count: Int(facts.size)))
        try handle.close()
        pvSetMtime(path, ns: facts.mtimeNs)
        let now = try #require(pvFacts(path))
        #expect(now.size == facts.size && now.inode == facts.inode && now.mtimeNs == facts.mtimeNs,
                "setup: the test's overwrite changed the file's identity (size \(now.size) vs \(facts.size), mtime \(now.mtimeNs) vs \(facts.mtimeNs))")
        #expect((PDFDocument(url: URL(fileURLWithPath: path))?.pageCount ?? 0) == 0, "setup: PDFKit still opens the overwritten file")

        guard let reply = pvReply(world, file: path, passage: id, query: pvQuery) else { return }
        defer { pvDropPNG(reply) }
        #expect(reply.status == .ok, "status is \(reply.status), expected ok (the pane then says `Can't preview this file`)")
        #expect(reply.name == "broken.pdf", "name is \(reply.name)")
        #expect(reply.png == nil, "a PDF that does not open has a png: \(String(describing: reply.png))")
        #expect(reply.locator == nil, "a PDF that does not open has a locator: \(String(describing: reply.locator))")
        #expect(reply.page == nil && reply.pageCount == nil, "a PDF that does not open has a page: \(String(describing: reply.page)) of \(String(describing: reply.pageCount))")
    }
}
}
