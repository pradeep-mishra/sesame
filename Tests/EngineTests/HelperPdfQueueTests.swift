import Foundation
import Testing
import SesameEngine

// plan-4-t5, tester step. Written from the t5 entry of plan-4-tasks.md (Tests), design sections 1, 3 and 4 and the spec's S3 only; no
// product source is read. The harness (`At...`: AtWorld, AtDB, atStartHelper, atFoldersLine, atWaitStatuses, atCleanStop, atWrite,
// atPassageIDs, atRows, atMakePhotos, atHelperWarm, atPast) is the one IndexAttemptTests.swift holds; `PdfMaker` is the one
// PdfReaderTests.swift holds; `ScanPdf` (picture pages, with its own PDFKit and Vision witness) is the one PdfScanTests.swift holds.
//
// How a run is made: the bundled release helper alone (`dist/Sesame.app/Contents/MacOS/SesameHelper index`, run `scripts/bundle.sh`
// first: a stale bundle makes these tests fail, never pass), `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME. Vision still reads the
// pictures for real, so a scan page's words are found through `fts` whatever the embedder. The index is read with this file's own
// read-only SQLite connection, ONE STATEMENT PER POLL, so each poll is one consistent snapshot.
//
// THE SHARED RUN (`hqOutcome`): 33 files in one folder, every one made by this file. The newest first:
//   long60.pdf      60 picture pages (a word each; MARMALADE on page 12, TURQUOISE on page 55)         age 1
//   lnewer31.pdf    31 text pages                                                                       age 2
//   lolder31.pdf    31 text pages                                                                       age 3
//   scan3.pdf       3 picture pages: WALNUT, SADDLE, COBBLER                                            age 4
//   mixed4.pdf      4 pages: text, picture PUMPKIN, text, picture LADDER                                age 5
//   small-001 ... small-028   one text page each                                                        ages 11 ... 38
// The 60-page PDF is the newest, so the helper reaches it first: a reader that reads a file whole, or that takes its steps in file
// order, shows it `done` while the small files are still pending; and 28 small files are more than one batch of 25 can hold, so a
// reader that does one step of the first 25 files and then their second steps shows it `done` before the last small files have had
// their first. The expected order is the entry's: step one of every file first, later steps after everything else, newest first.
// What the poll records: the first snapshot with long60 `partial`, the first with it `done`, and every snapshot of mixed4.
//
// SHAPES THIS FILE PINS (the entry fixes names, not these):
//   - a scan page's passage is `source` "page", `start = end =` the page number, `modality` "image", the picture's words as the
//     `fts` body; a text page's is `source` "page", modality "text"; the `name` passage is `source` "name" in step one.
//   - the 28 + 2 + 3 files all end `done`; none ends `could_not_read` (every picture is readable).
//   - the order of batches (G21): the helper takes the file first in line, then up to 25 files that need the same model (newest
//     first); the next batch starts from the file first in line then. Observed from the order of the passage ids of the `name`
//     passages (an id is never reused and rises with every commit): 30 text PDFs and 30 photos in turn, newest first, are committed
//     as the 25 newest text PDFs, then the newest photo; this is HelperPdfQueueTests' only way to see a batch's size.
//   - a re-read of a partial row's next step adds its passages and leaves the passages of the earlier steps as they are.

// MARK: the words and the files

private let hqLongWords = (page12: "MARMALADE", page55: "TURQUOISE")
private let hqFillerWords = ["APRICOT", "BALLAD", "CANYON", "DOLPHIN", "EMBER", "FALCON", "GARNET", "HARVEST", "ISLAND", "JASMINE"]
private let hqFiles = 33

private func hqLongPages() -> [ScanPdf.Page] {
    (1...60).map { (page: Int) -> ScanPdf.Page in
        switch page {
        case 12: return .picture(hqLongWords.page12)
        case 55: return .picture(hqLongWords.page55)
        default: return .picture(hqFillerWords[page % hqFillerWords.count])
        }
    }
}

private func hqTextPages(_ family: String, count: Int) -> [ScanPdf.Page] {
    (1...count).map { .text(PdfMaker.rich(PdfMaker.token(family, $0))) }
}

@discardableResult
private func hqWrite(_ world: AtWorld, _ name: String, pages: [ScanPdf.Page], age: Int) throws -> String {
    let path = world.photos.appendingPathComponent(name + ".pdf").path
    try ScanPdf.write(pages, to: path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(age))], ofItemAtPath: path)
    return path
}

// MARK: reading the index

private struct HqHit {
    let file: String
    let source: String
    let start: Int?
    let modality: String
}

private func hqFind(_ db: AtDB, _ word: String) -> [HqHit]? {
    guard let rows = db.rows("""
        select f.path, p.source, cast(p.start as integer), p.modality from fts join passages p on p.id = fts.rowid \
        join files f on f.id = p.file_id where fts match 'body:\(word.lowercased())'
        """) else { return nil }
    return rows.map { HqHit(file: (($0[0] ?? "") as NSString).lastPathComponent, source: $0[1] ?? "", start: $0[2].flatMap { Int($0) }, modality: $0[3] ?? "") }
}

private struct HqRow {
    let kind: String
    let status: String
    let reason: String?
    let readTo: String?
}

private func hqRows(_ db: AtDB) -> [String: HqRow]? {
    guard let rows = db.rows("select path, kind, status, reason, read_to from files") else { return nil }
    var out: [String: HqRow] = [:]
    for row in rows {
        guard let path = row[0], let kind = row[1], let status = row[2] else { continue }
        out[(path as NSString).lastPathComponent] = HqRow(kind: kind, status: status, reason: row[3], readTo: row[4])
    }
    return out
}

private struct HqPassage {
    let id: Int
    let source: String
    let start: Int?
    let end: Int?
    let modality: String
    let vecBytes: Int
}

private func hqPassages(_ db: AtDB) -> [String: [HqPassage]]? {
    guard let rows = db.rows("""
        select f.path, p.id, p.source, cast(p.start as integer), cast(p."end" as integer), p.modality, coalesce(length(p.vec), -1) \
        from passages p join files f on f.id = p.file_id order by p.id
        """) else { return nil }
    var out: [String: [HqPassage]] = [:]
    for row in rows {
        guard let path = row[0], let idText = row[1], let id = Int(idText) else { continue }
        out[(path as NSString).lastPathComponent, default: []].append(
            HqPassage(id: id, source: row[2] ?? "", start: row[3].flatMap { Int($0) }, end: row[4].flatMap { Int($0) },
                      modality: row[5] ?? "", vecBytes: Int(row[6] ?? "") ?? -2))
    }
    return out
}

private func hqDescribe(_ rows: [String: HqRow]) -> String {
    rows.keys.sorted().map { "\($0)=\(rows[$0]!.status)\(rows[$0]!.reason.map { "(\($0))" } ?? "")" }.joined(separator: ", ")
}

private func hqCleared(_ row: HqRow?) -> Bool { row?.readTo == nil || row?.readTo == "0" }

/// One statement, one consistent snapshot: long60's row and whether each of its two words is found, how many other files are not
/// yet `done` or `could_not_read`, how many files there are, and what mixed4 holds.
private let hqSnapshotSQL = """
    select \
    (select status from files where path like '%/long60.pdf'), \
    (select read_to from files where path like '%/long60.pdf'), \
    (select count(*) from fts join passages p on p.id = fts.rowid join files f on f.id = p.file_id \
        where f.path like '%/long60.pdf' and fts match 'body:\(hqLongWords.page12.lowercased())'), \
    (select count(*) from fts join passages p on p.id = fts.rowid join files f on f.id = p.file_id \
        where f.path like '%/long60.pdf' and fts match 'body:\(hqLongWords.page55.lowercased())'), \
    (select count(*) from files where status not in ('done', 'could_not_read') and path not like '%/long60.pdf'), \
    (select count(*) from files), \
    (select count(*) from passages p join files f on f.id = p.file_id where f.path like '%/mixed4.pdf' and p.source = 'page'), \
    (select coalesce(sum(p.modality = 'text'), 0) from passages p join files f on f.id = p.file_id \
        where f.path like '%/mixed4.pdf' and p.source = 'page'), \
    (select coalesce(sum(p.modality = 'image'), 0) from passages p join files f on f.id = p.file_id \
        where f.path like '%/mixed4.pdf' and p.source = 'page'), \
    (select count(*) from files f where f.path not like '%/long60.pdf' and f.status not in ('done', 'could_not_read') \
        and (f.status = 'pending' or not exists (select 1 from passages p where p.file_id = f.id)))
    """

private struct HqSnap {
    let status: String?
    let readTo: Int?
    let found12: Int
    let found55: Int
    let othersOpen: Int
    let othersFirstStepOpen: Int
    let total: Int
    let mixedPages: Int
    let mixedText: Int
    let mixedImage: Int
}

private func hqPoll(_ db: AtDB) -> HqSnap? {
    guard let row = db.rows(hqSnapshotSQL)?.first, row.count == 10 else { return nil }
    func number(_ index: Int) -> Int { Int(row[index] ?? "") ?? -1 }
    return HqSnap(status: row[0], readTo: row[1].flatMap { Int($0) }, found12: number(2), found55: number(3), othersOpen: number(4),
                  othersFirstStepOpen: number(9), total: number(5), mixedPages: number(6), mixedText: number(7), mixedImage: number(8))
}

// MARK: the one shared run

private struct HqOutcome {
    var setupProblem: String?
    var polls = 0
    var firstPartial: HqSnap?
    var partialReadTos: [Int] = []
    var firstDone: HqSnap?
    var partialSeenBeforeDone = false
    var mixedViolations: [String] = []
    var rows: [String: HqRow] = [:]
    var passages: [String: [HqPassage]] = [:]
    var finds: [String: [HqHit]] = [:]
    var integrity = ""
    var helperExit: Int32?
    var summary = ""
}

private let hqFindWords = ["walnut", "saddle", "cobbler", "pumpkin", "ladder", "marmalade", "turquoise"]

private let hqOutcome: HqOutcome = {
    var out = HqOutcome()
    _ = atHelperWarm
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    do {
        try hqWrite(world, "long60", pages: hqLongPages(), age: 1)
        try hqWrite(world, "lnewer31", pages: hqTextPages("snew", count: 31), age: 2)
        try hqWrite(world, "lolder31", pages: hqTextPages("sold", count: 31), age: 3)
        try hqWrite(world, "scan3", pages: [.picture("WALNUT"), .picture("SADDLE"), .picture("COBBLER")], age: 4)
        try hqWrite(world, "mixed4", pages: [.text(PdfMaker.rich(PdfMaker.token("mixa", 1))), .picture("PUMPKIN"),
                                              .text(PdfMaker.rich(PdfMaker.token("mixa", 2))), .picture("LADDER")], age: 5)
        for number in 1...28 {
            try hqWrite(world, String(format: "small-%03d", number), pages: [.text(PdfMaker.rich(PdfMaker.token("smal", number)))], age: 10 + number)
        }
    } catch {
        out.setupProblem = "could not make the files: \(error)"
        return out
    }
    let helper: HelperProcess
    do { helper = try atStartHelper(world) } catch {
        out.setupProblem = "the bundled helper could not be started: \(error)"
        return out
    }
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))

    let started = Date()
    var lastChange = started
    var lastSignature = ""
    var db: AtDB?
    var settled = false
    while true {
        if db == nil { db = world.db() }
        if let db, let snap = hqPoll(db) {
            out.polls += 1
            if snap.status == "partial" {
                if out.firstPartial == nil { out.firstPartial = snap }
                if let readTo = snap.readTo, !out.partialReadTos.contains(readTo) { out.partialReadTos.append(readTo) }
            }
            if snap.status == "done", out.firstDone == nil {
                out.firstDone = snap
                out.partialSeenBeforeDone = out.firstPartial != nil
            }
            if snap.mixedPages != 0, !(snap.mixedText == 2 && snap.mixedImage == 2), out.mixedViolations.count < 10 {
                out.mixedViolations.append("mixed4 held \(snap.mixedText) text and \(snap.mixedImage) picture page passages (\(snap.mixedPages) in all)")
            }
            let signature = "\(snap.status ?? "-")|\(snap.readTo.map(String.init) ?? "-")|\(snap.othersOpen)|\(snap.total)|\(snap.mixedPages)"
            if signature != lastSignature { lastSignature = signature; lastChange = Date() }
            if snap.total == hqFiles, snap.othersOpen == 0, snap.status == "done" || snap.status == "could_not_read" {
                settled = true
                break
            }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > 300 || now.timeIntervalSince(started) > 450 { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.01)
    }
    out.summary = "settled \(settled), \(Int(Date().timeIntervalSince(started))) s, \(out.polls) polls, last state \(lastSignature), helper \(helper.isRunning ? "running" : "gone"), stderr: \(helper.errors)"
    if settled { Thread.sleep(forTimeInterval: 1.5) }

    if let db = db ?? world.db() {
        out.rows = hqRows(db) ?? [:]
        out.passages = hqPassages(db) ?? [:]
        // A new connection: fts5 keeps its row totals per connection, and `integrity_check` does not refresh them, so the
        // poll connection above can hold totals from before the helper's last commits and report a mismatch that is not there.
        out.integrity = (world.db() ?? db).integrity()
        for word in hqFindWords { out.finds[word] = hqFind(db, word) ?? [] }
    }
    helper.closeStdin()
    out.helperExit = helper.waitForExit(timeout: 60)?.status
    return out
}()

private struct HqStop: Error {}

private func hqOutcomeOrStop() throws -> HqOutcome {
    let outcome = hqOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw HqStop()
    }
    return outcome
}

// MARK: the run that shows a batch's size (G21)

private struct HqBatchOutcome {
    var setupProblem: String?
    var order: [String] = []
    var rows: [String: HqRow] = [:]
    var summary = ""
}

/// 30 text PDFs and 30 photos, in turn, newest first: txt-001, pic-002, txt-003, pic-004 ... pic-060.
private let hqBatchOutcome: HqBatchOutcome = {
    var out = HqBatchOutcome()
    _ = atHelperWarm
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    do {
        for position in 1...60 {
            let label = String(format: "%03d", position)
            if position % 2 == 1 {
                try hqWrite(world, "txt-\(label)", pages: [.text(PdfMaker.rich(PdfMaker.token("kalt", position)))], age: position)
            } else {
                try atMakePhotos(in: world.photos, names: ["pic-\(label)"], seedBase: 40 + position, age: position)
            }
        }
    } catch {
        out.setupProblem = "could not make the files: \(error)"
        return out
    }
    let helper: HelperProcess
    do { helper = try atStartHelper(world) } catch {
        out.setupProblem = "the bundled helper could not be started: \(error)"
        return out
    }
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    let wait = atWaitStatuses(world, helper, stall: 120, cap: 400, until: { $0 == ["done": 60] })
    out.summary = "met \(wait.met), statuses \(wait.statuses), stderr: \(helper.errors)"
    if wait.met { Thread.sleep(forTimeInterval: 1.0) }
    if let db = world.db() {
        out.rows = hqRows(db) ?? [:]
        let ordered = db.rows("select f.path, min(p.id) from files f join passages p on p.file_id = f.id group by f.id order by min(p.id)") ?? []
        out.order = ordered.compactMap { $0[0].map { ($0 as NSString).lastPathComponent } }
    }
    return out
}()

// MARK: worlds for the tests that plant a row

private func hqIndexedWorld(_ specs: [(name: String, pages: [ScanPdf.Page])], pictures: Int) throws -> AtWorld {
    _ = atHelperWarm
    let world = try AtWorld()
    do {
        for (index, spec) in specs.enumerated() { try hqWrite(world, spec.name, pages: spec.pages, age: index) }
        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 180, cap: 400, until: { $0 == ["done": specs.count] })
        guard wait.met else {
            throw AtError("setup: the \(specs.count) PDFs did not all reach done: \(wait.statuses), stderr: \(helper.errors)")
        }
        guard atCleanStop(helper) == 0 else {
            throw AtError("setup: the helper did not exit 0 within 120 s of its stdin ending; stderr: \(helper.errors)")
        }
        let held = world.db()?.int("select count(*) from passages where source = 'page' and modality = 'image'") ?? -1
        guard held == pictures else {
            throw AtError("setup: the index holds \(held) picture page passages, expected \(pictures): a scan page has no passage")
        }
    } catch {
        world.remove()
        throw error
    }
    return world
}

private func hqScanSpecs(_ names: [String]) -> [(name: String, pages: [ScanPdf.Page])] {
    let words = ["WALNUT", "SADDLE", "COBBLER", "PUMPKIN", "LADDER", "APRICOT", "BALLAD", "CANYON"]
    return names.enumerated().map { (name: $0.element, pages: [.picture(words[$0.offset % words.count])]) }
}

// MARK: the real model

private struct HqModels {
    let text: URL
    let mm: URL
}

private let hqModelFiles: HqModels? = {
    guard let text = KitPaths.textModel() else { return nil }
    let mm = text.deletingLastPathComponent().appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
    guard FileManager.default.fileExists(atPath: mm.path) else { return nil }
    return HqModels(text: text, mm: mm)
}()

private func hqStartReal(_ world: AtWorld, models: HqModels) throws -> HelperProcess {
    let executable = KitPaths.bundledHelper
    try #require(FileManager.default.isExecutableFile(atPath: executable.path),
                 "the bundled helper is missing: run `scripts/bundle.sh` (expected \(executable.path))")
    homeLock.lock()
    defer { homeLock.unlock() }
    let previousHome = getenv("HOME").map { String(cString: $0) }
    let previousFake = getenv("SESAME_FAKE_EMBEDDER").map { String(cString: $0) }
    setenv("HOME", world.home.path, 1)
    unsetenv("SESAME_FAKE_EMBEDDER")
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if let previousFake { setenv("SESAME_FAKE_EMBEDDER", previousFake, 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    }
    return try HelperProcess(executable: executable, arguments: ["index", "--text-model", models.text.path, "--mm-model", models.mm.path])
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("HelperPdfQueueTests", .serialized)
struct HelperPdfQueueTests {

    // MARK: a PDF of pictures

    @Test func anImageOnlyThreePagePdfIsDoneWithImagePagePassagesFoundByAPictureWordTypedAlone() throws {
        let outcome = try hqOutcomeOrStop()
        let row = outcome.rows["scan3.pdf"]
        #expect(row?.status == "done" && row?.kind == "pdf", "scan3.pdf is \(row?.status ?? "no row") of kind \(row?.kind ?? "none"); rows: \(hqDescribe(outcome.rows)); \(outcome.summary)")
        let passages = outcome.passages["scan3.pdf"] ?? []
        #expect(passages.filter { $0.source == "name" }.count == 1, "name passages: \(passages.filter { $0.source == "name" }.count), expected 1")
        let pages = passages.filter { $0.source == "page" }.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        #expect(pages.map(\.start) == [1, 2, 3] && pages.allSatisfy { $0.start == $0.end },
                "the page passages start at \(pages.map { $0.start.map(String.init) ?? "nil" }) and end at \(pages.map { $0.end.map(String.init) ?? "nil" }), expected 1, 2, 3 each with start = end")
        #expect(pages.allSatisfy { $0.modality == "image" }, "the scan pages' modality is \(pages.map(\.modality)), expected image for every one")
        for (word, page) in [("walnut", 1), ("saddle", 2), ("cobbler", 3)] {
            let hits = outcome.finds[word] ?? []
            #expect(hits.count == 1, "a MATCH for \(word) alone found \(hits.count) passages, expected the one on page \(page) of scan3.pdf")
            guard let hit = hits.first else { continue }
            #expect(hit.file == "scan3.pdf" && hit.source == "page" && hit.start == page && hit.modality == "image",
                    "\(word) was found in \(hit.file) \(hit.source) start \(hit.start.map(String.init) ?? "nil") \(hit.modality), expected scan3.pdf page \(page), image")
        }
    }

    // MARK: S3.6, a long PDF: the first 30 pages before the rest, step one of every file first

    @Test func aSixtyPagePictureFileIsPartialAtThirtyWithPageTwelveFoundAndPageFiftyFiveNotYet() throws {
        let outcome = try hqOutcomeOrStop()
        let first = try #require(outcome.firstPartial, "the poll never saw long60.pdf partial in \(outcome.polls) polls: it was read whole or its first step stored no scan page; \(outcome.summary)")
        #expect(first.readTo == 30, "at the first partial poll read_to is \(first.readTo.map(String.init) ?? "nil"), expected 30")
        #expect(first.found12 >= 1, "at the first partial poll the page 12 word \(hqLongWords.page12) is found \(first.found12) times, expected it found")
        #expect(first.found55 == 0, "at the first partial poll the page 55 word \(hqLongWords.page55) is found \(first.found55) times, expected 0")
        #expect(outcome.partialReadTos == [30], "long60.pdf was seen partial at read_to \(outcome.partialReadTos), expected only 30 (60 pages are two steps)")
    }

    @Test func atTheFirstPollThatShowsItDoneEveryOtherFileIsAlreadyDoneAndPageFiftyFiveIsFoundWithReadToCleared() throws {
        let outcome = try hqOutcomeOrStop()
        let done = try #require(outcome.firstDone, "the poll never saw long60.pdf done in \(outcome.polls) polls; \(outcome.summary)")
        #expect(outcome.partialSeenBeforeDone, "long60.pdf was seen done without ever being seen partial first")
        #expect(done.othersFirstStepOpen == 0, "at the first poll that shows long60.pdf done, \(done.othersFirstStepOpen) other file(s) have their first step still open (pending, or no passage): its second step was taken before every file's first step")
        #expect(done.found55 >= 1, "at the first done poll the page 55 word \(hqLongWords.page55) is found \(done.found55) times, expected it found")
        #expect(done.found12 >= 1, "at the first done poll the page 12 word is found \(done.found12) times")
        #expect(done.readTo == nil || done.readTo == 0, "at the first done poll read_to is \(done.readTo.map(String.init) ?? "nil"), expected it cleared")
        let page55 = outcome.finds["turquoise"] ?? []
        #expect(page55.count == 1 && page55.first?.file == "long60.pdf" && page55.first?.start == 55,
                "the page 55 word is found at \(page55.map { "\($0.file) \($0.start.map(String.init) ?? "nil")" }), expected long60.pdf page 55")
        let page12 = outcome.finds["marmalade"] ?? []
        #expect(page12.count == 1 && page12.first?.file == "long60.pdf" && page12.first?.start == 12,
                "the page 12 word is found at \(page12.map { "\($0.file) \($0.start.map(String.init) ?? "nil")" }), expected long60.pdf page 12")
    }

    @Test func everyLaterStepIsStoredAfterEveryFirstStepAndTheLaterStepsGoNewestFirst() throws {
        let outcome = try hqOutcomeOrStop()
        func firstStepIDs(_ passages: [HqPassage]) -> [Int] {
            passages.filter { $0.source == "name" || ($0.source == "page" && ($0.start ?? 0) <= 30) }.map(\.id)
        }
        func laterStepIDs(_ passages: [HqPassage]) -> [Int] {
            passages.filter { $0.source == "page" && ($0.start ?? 0) > 30 }.map(\.id)
        }
        let everyFirstStep = outcome.passages.values.flatMap(firstStepIDs)
        let lastFirstStep = try #require(everyFirstStep.max(), "no passage of any first step: \(outcome.summary)")
        var firstLater: [String: Int] = [:]
        for name in ["long60.pdf", "lnewer31.pdf", "lolder31.pdf"] {
            let later = laterStepIDs(outcome.passages[name] ?? [])
            #expect(!later.isEmpty, "\(name) has no passage past page 30: \(outcome.rows[name]?.status ?? "no row"); \(outcome.summary)")
            if let lowest = later.min() { firstLater[name] = lowest }
            #expect((later.min() ?? 0) > lastFirstStep,
                    "\(name)'s later step was stored (passage \(later.min() ?? 0)) before the last first step (passage \(lastFirstStep))")
        }
        let order = ["long60.pdf", "lnewer31.pdf", "lolder31.pdf"].compactMap { firstLater[$0] }
        #expect(order.count == 3 && order == order.sorted(),
                "the later steps were stored in the order of the passages \(firstLater), expected long60 (newest), then lnewer31, then lolder31")
    }

    // MARK: text pages and scan pages of one PDF, stored in one step

    @Test func aPdfWithTwoTextPagesAndTwoScanPagesIsStoredInOneStepWithNoPollSeeingItsTextWithoutItsScans() throws {
        let outcome = try hqOutcomeOrStop()
        #expect(outcome.polls > 0, "the poll never read the index: \(outcome.summary)")
        #expect(outcome.mixedViolations.isEmpty, "a poll saw the mixed PDF half stored: \(outcome.mixedViolations.prefix(3)); \(outcome.summary)")
        let row = outcome.rows["mixed4.pdf"]
        #expect(row?.status == "done", "mixed4.pdf ends \(row?.status ?? "no row")")
        let pages = (outcome.passages["mixed4.pdf"] ?? []).filter { $0.source == "page" }.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        #expect(pages.map(\.start) == [1, 2, 3, 4], "the page passages start at \(pages.map { $0.start.map(String.init) ?? "nil" }), expected 1, 2, 3, 4")
        #expect(pages.map(\.modality) == ["text", "image", "text", "image"], "the modalities are \(pages.map(\.modality)), expected text, image, text, image")
        for (word, page) in [("pumpkin", 2), ("ladder", 4)] {
            let hits = outcome.finds[word] ?? []
            #expect(hits.count == 1 && hits.first?.file == "mixed4.pdf" && hits.first?.start == page && hits.first?.modality == "image",
                    "\(word) is found at \(hits.map { "\($0.file) \($0.start.map(String.init) ?? "nil") \($0.modality)" }), expected mixed4.pdf page \(page)")
        }
    }

    // MARK: the whole run

    @Test func everyFileOfTheRunEndsDoneTheIndexPassesItsIntegrityCheckAndTheHelperExitsCleanly() throws {
        let outcome = try hqOutcomeOrStop()
        #expect(outcome.rows.count == hqFiles, "the index holds \(outcome.rows.count) files rows, expected \(hqFiles): \(outcome.summary)")
        #expect(outcome.rows.values.allSatisfy { $0.status == "done" && $0.kind == "pdf" },
                "every file should be a done pdf: \(hqDescribe(outcome.rows)); \(outcome.summary)")
        #expect(outcome.rows.values.allSatisfy { hqCleared($0) }, "a done file keeps read_to: \(outcome.rows.filter { !hqCleared($0.value) }.keys.sorted())")
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.helperExit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.helperExit.map(String.init) ?? "still running")")
    }

    // MARK: G21, a batch holds up to 25 files that need the same model

    @Test func aBatchHoldsTheTwentyFiveNewestFilesOfOneModelBeforeTheNextBatchStartsFromTheFirstFileInLine() throws {
        let outcome = hqBatchOutcome
        if let problem = outcome.setupProblem {
            Issue.record("setup failed: \(problem)")
            return
        }
        #expect(outcome.rows.count == 60 && outcome.rows.values.allSatisfy { $0.status == "done" },
                "all 60 files should be done: \(outcome.summary); \(hqDescribe(outcome.rows))")
        let firstBatch = (0..<25).map { String(format: "txt-%03d.pdf", 2 * $0 + 1) }
        #expect(Array(outcome.order.prefix(25)) == firstBatch,
                "the first 25 files committed are \(Array(outcome.order.prefix(25))), expected the 25 newest text PDFs, txt-001 to txt-049, newest first")
        #expect(outcome.order.count > 25 && outcome.order[25] == "pic-002.jpg",
                "the 26th file committed is \(outcome.order.count > 25 ? outcome.order[25] : "none"), expected pic-002.jpg (the first photo in line: a full batch of 25 ends, the next starts from the file first in line)")
    }

    // MARK: the attempt marker and the hints of plan 2, on picture PDFs and on a later step

    // `tries` 2 is not read: `could_not_read`, reason "damaged", or "needed too much memory" when the row's `reason` holds
    // `hint:memory`. A neighbour with tries 1 or 0 is read again.
    @Test func aPictureOnlyPdfWithTriesTwoIsCouldNotReadByItsHintAndNeverReadAgainWhileTheOthersAreReadAgain() throws {
        let names = atNames("q", 1...5)
        let world = try hqIndexedWorld(hqScanSpecs(names), pictures: 5)
        defer { world.remove() }
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2 where path like '%/q-001.pdf'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2, reason = 'hint:memory' where path like '%/q-002.pdf'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 1 where path like '%/q-003.pdf'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0 where path like '%/q-004.pdf'") == nil)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 180, cap: 400, until: { $0 == ["done": 3, "could_not_read": 2] })
        #expect(wait.met, "expected 3 done and 2 could_not_read, got \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let rows = atRows(db)
        #expect(rows?["q-001.pdf"]?.status == "could_not_read" && rows?["q-001.pdf"]?.reason == "damaged",
                "tries 2 with no hint must be could_not_read (damaged), got \(atDescribe(rows))")
        #expect(rows?["q-002.pdf"]?.status == "could_not_read" && rows?["q-002.pdf"]?.reason == "needed too much memory",
                "tries 2 with hint:memory must be could_not_read (needed too much memory), got \(atDescribe(rows))")
        #expect(rows?["q-001.pdf"]?.tries == 0 && rows?["q-002.pdf"]?.tries == 0, "a could_not_read row holds tries 0, got \(atDescribe(rows))")
        for name in ["q-003.pdf", "q-004.pdf"] {
            #expect(rows?[name]?.status == "done" && rows?[name]?.tries == 0, "\(name) should be read again and end done with tries 0, got \(atDescribe(rows))")
        }
        let after = try #require(atPassageIDs(db))
        for name in ["q-001.pdf", "q-002.pdf"] {
            #expect(Set(after[name] ?? []).isSubset(of: Set(before[name] ?? [])), "\(name) (tries 2) was read again: ids \(before[name] ?? []) then \(after[name] ?? [])")
        }
        for name in ["q-003.pdf", "q-004.pdf"] {
            #expect(after[name] != nil && after[name] != before[name], "\(name) was not read again: ids \(before[name] ?? []) then \(after[name] ?? [])")
        }
        #expect(after["q-005.pdf"] == before["q-005.pdf"], "q-005.pdf was done and was read again")
        for name in ["q-003.pdf", "q-004.pdf"] {
            let held = db.int("select count(*) from passages p join files f on f.id = p.file_id where f.path like '%/\(name)' and p.source = 'page' and p.modality = 'image'")
            #expect(held == 1, "\(name) was read again and should hold one picture page passage, it holds \(held.map(String.init) ?? "nil")")
        }
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }

    // A pending PDF holding `hint:solo` is read alone before any other work: the oldest carries the hint and must be written first.
    @Test func aPendingPictureOnlyPdfHoldingHintSoloIsReadFirstBeforeAnyOtherWork() throws {
        let names = atNames("s", 1...6)
        let world = try hqIndexedWorld(hqScanSpecs(names), pictures: 6)
        defer { world.remove() }
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0") == nil)
        #expect(atWrite(world.indexFile, "update files set reason = 'hint:solo' where path like '%/s-006.pdf'") == nil)
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 180, cap: 400, until: { $0 == ["done": 6] })
        #expect(wait.met, "the six pending PDFs did not all end done: \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let after = try #require(atPassageIDs(db))
        let newest = before.values.flatMap { $0 }.max() ?? 0
        let first = after.compactMap { (name, ids) -> (String, Int)? in ids.min().map { (name, $0) } }.sorted { $0.1 < $1.1 }
        #expect(first.count == 6 && first.allSatisfy { $0.1 > newest }, "every PDF should have been read again (new ids above \(newest)): \(first)")
        #expect(first.first?.0 == "s-006.pdf", "the PDF with hint:solo must be written before every other file, but the order of writes is \(first.map(\.0))")
        #expect(atRows(db)?.values.allSatisfy { $0.tries == 0 && $0.status == "done" } == true, "rows: \(atDescribe(atRows(db)))")
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }

    // The marker covers a step of a long file: a partial row with tries 2 is `could_not_read` and is not read again; one with
    // tries 1 reads its next step (the pages after `read_to`), adds its passages, leaves the earlier steps' passages as they are.
    @Test func aPartialPdfWithTriesTwoIsCouldNotReadAndOneWithTriesOneReadsItsNextStepAndKeepsTheEarlierSteps() throws {
        let world = try hqIndexedWorld([(name: "u-001", pages: hqTextPages("ubra", count: 31)), (name: "u-002", pages: hqTextPages("uwin", count: 31))], pictures: 0)
        defer { world.remove() }
        func ids(_ db: AtDB, _ file: String, _ clause: String) -> [Int] {
            (db.rows("select p.id from passages p join files f on f.id = p.file_id where f.path like '%/\(file).pdf' and \(clause) order by p.id") ?? [])
                .compactMap { $0[0].flatMap { Int($0) } }
        }
        let before = try #require(world.db())
        let oneEarlier = ids(before, "u-001", "p.start <= 30"), oneAll = ids(before, "u-001", "1 = 1")
        let twoEarlier = ids(before, "u-002", "p.start <= 30"), twoAll = ids(before, "u-002", "1 = 1")
        #expect(oneAll.count == 32 && twoAll.count == 32, "setup: each 31-page PDF should hold 1 name and 31 page passages, they hold \(oneAll.count) and \(twoAll.count)")
        #expect(atWrite(world.indexFile, "update files set status = 'partial', read_to = 30, tries = 2 where path like '%/u-001.pdf'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'partial', read_to = 30, tries = 1 where path like '%/u-002.pdf'") == nil)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 180, cap: 400, until: { $0 == ["done": 1, "could_not_read": 1] })
        #expect(wait.met, "expected 1 done and 1 could_not_read, got \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let rows = try #require(hqRows(db))
        #expect(rows["u-001.pdf"]?.status == "could_not_read" && rows["u-001.pdf"]?.reason == "damaged" && hqCleared(rows["u-001.pdf"]),
                "a partial row with tries 2 should be could_not_read (damaged) with read_to cleared, got \(hqDescribe(rows))")
        #expect(Set(ids(db, "u-001", "1 = 1")).isSubset(of: Set(oneAll)), "u-001.pdf (tries 2) was read again: ids \(oneAll) then \(ids(db, "u-001", "1 = 1"))")
        #expect(rows["u-002.pdf"]?.status == "done" && hqCleared(rows["u-002.pdf"]), "a partial row with tries 1 should be read and end done with read_to cleared, got \(hqDescribe(rows))")
        #expect(db.int("select tries from files where path like '%/u-002.pdf'") == 0, "u-002.pdf keeps tries \(db.int("select tries from files where path like '%/u-002.pdf'").map(String.init) ?? "nil")")
        #expect(ids(db, "u-002", "p.start <= 30") == twoEarlier, "the passages of the earlier step of u-002.pdf were replaced: \(twoEarlier) then \(ids(db, "u-002", "p.start <= 30"))")
        let added = ids(db, "u-002", "p.id > \(twoAll.max() ?? 0)")
        #expect(!added.isEmpty, "the next step of u-002.pdf stored no new passage")
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }

    // MARK: the cached real model, and the swap inside one helper

    @Test(.enabled(if: hqModelFiles != nil, "the cached model files are missing under $KIT_ROOT/cache (the text model and mmproj-embeddinggemma-2-Q8_0.gguf): seed the cache with scripts/kit-mirror.sh seed --real; this test never downloads"))
    func withTheCachedRealModelAScannedPageAndATextPageOfAnotherPdfBothHaveARealVectorAndBothFilesAreDone() throws {
        let models = try #require(hqModelFiles)
        _ = atHelperWarm
        let world = try AtWorld()
        defer { world.remove() }
        let taxText = "The annual tax return lists income, deductions and credits. The revenue authority expects payment of any tax owed before the filing deadline, and late payment adds interest and penalties to the amount due for the tax year."
        try hqWrite(world, "scannedpage", pages: [.picture("WALNUT")], age: 1)
        try hqWrite(world, "textpage", pages: [.text(taxText)], age: 2)
        let witness = try #require(ScanPdf.witnessWords(world.photos.appendingPathComponent("scannedpage.pdf").path, page: 0), "setup: PDFKit cannot read the scanned sample")
        #expect(witness.layerCharacters == 0 && witness.seen.lowercased().contains("walnut"), "setup: the scanned sample has \(witness.layerCharacters) text characters and Vision reads \"\(witness.seen)\"")

        let helper = try hqStartReal(world, models: models)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 300, cap: 500, until: { $0 == ["done": 2] })
        #expect(wait.met, "the two PDFs did not both reach done with the real model: \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")
        guard wait.met else { return }

        let db = try #require(world.db())
        let rows = try #require(hqRows(db))
        #expect(rows["scannedpage.pdf"]?.status == "done" && rows["textpage.pdf"]?.status == "done", "rows: \(hqDescribe(rows))")
        let passages = try #require(hqPassages(db))
        let scan = (passages["scannedpage.pdf"] ?? []).filter { $0.source == "page" }
        let text = (passages["textpage.pdf"] ?? []).filter { $0.source == "page" }
        #expect(scan.count == 1 && scan.first?.start == 1 && scan.first?.modality == "image" && scan.first?.vecBytes == 1536,
                "the scanned page's passage is \(scan.map { "\($0.modality) \($0.vecBytes) bytes, start \($0.start.map(String.init) ?? "nil")" }), expected one image passage with a 1536 byte vector, not NULL")
        #expect(text.count == 1 && text.first?.start == 1 && text.first?.modality == "text" && text.first?.vecBytes == 1536,
                "the text page's passage is \(text.map { "\($0.modality) \($0.vecBytes) bytes, start \($0.start.map(String.init) ?? "nil")" }), expected one text passage with a 1536 byte vector, not NULL")
        let found = hqFind(db, "walnut") ?? []
        #expect(found.count == 1 && found.first?.file == "scannedpage.pdf" && found.first?.modality == "image",
                "the picture word is found at \(found.map { "\($0.file) \($0.modality)" }), expected scannedpage.pdf image")
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }
}
}
