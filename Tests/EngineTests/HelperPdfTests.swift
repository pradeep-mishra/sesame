import Foundation
import Testing
import SesameEngine

// plan-4-t4, tester step. Written from the t4 entry of plan-4-tasks.md (Tests), design sections 1 and 3 and the spec's S3 only; no
// product source is read. The harness (`At...`: AtWorld, AtDB, atStartHelper, atFoldersLine, atWaitStatuses, atCleanStop, atWrite,
// atPassageIDs, atPast) is the one IndexAttemptTests.swift holds; the PDF maker (`PdfMaker`) is the one PdfReaderTests.swift holds.
//
// How a run is made: the bundled release helper alone (`dist/Sesame.app/Contents/MacOS/SesameHelper index`, run
// `scripts/bundle.sh` first: a stale bundle makes these tests fail, never pass), `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME, 120 s
// allowed to a start. The index is read with this file's own read-only SQLite connection (the `At...` one). The column names are
// the ones of design section 1: `files(path, kind, size, status, reason, read_to, tries)`, `passages(id, file_id, source, start,
// end, modality, vec)`, `fts(name, body)`.
//
// The one shared run (`hpOutcome`), as HelperTreeUnreadableTests does one: a folder of eight files, every one made by this file:
//   harbourledger.pdf   3 text pages, a word of its own on each (family `zorv`)
//   locked.pdf          2 text pages, a user password
//   damaged.pdf         the first 200 bytes of a 3-page PDF
//   onepage.pdf         1 text page; thirtypages.pdf 30; thirtyone.pdf 31; ninetyone.pdf 91 (one word per page, one family each)
//   holiday.jpg         a photo, the control that the picture path still works beside the PDFs
// While the helper works, a read-only connection takes a snapshot of each long PDF as fast as it can (one `BEGIN`, a few
// statements, one `COMMIT`: one consistent state) and records any state that is not one of the three the design allows: nothing
// yet (`pending`, no passage); `partial` with `read_to` a multiple of 30, one `name` passage and exactly `read_to` `page`
// passages, the last page's word not found yet; `done` with one `name` passage and every page's passage, the last page's word
// found and `read_to` cleared. The window between two steps is short, so the poll runs without a pause.
//
// What a PDF with no text layer (a scan page) does is the next task's; nothing here asserts it.

// MARK: the words of the files

private let hpHarbour = (1...3).map { PdfMaker.token("zorv", $0) }
private let hpOne = [PdfMaker.token("bamp", 1)]
private let hpThirty = (1...30).map { PdfMaker.token("quil", $0) }
private let hpThirtyOne = (1...31).map { PdfMaker.token("dros", $0) }
private let hpNinetyOne = (1...91).map { PdfMaker.token("kelv", $0) }

private func hpPages(_ tokens: [String]) -> [PdfMaker.Page] { tokens.map { .text(PdfMaker.rich($0)) } }

@discardableResult
private func hpWrite(_ world: AtWorld, _ name: String, pages: [PdfMaker.Page], age: Int, password: String? = nil) throws -> String {
    let path = world.photos.appendingPathComponent(name + ".pdf").path
    try PdfMaker.write(pages, to: path, userPassword: password)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(age))], ofItemAtPath: path)
    return path
}

// MARK: reading the index

private struct Hit {
    let file: String
    let source: String
    let start: String?
    let end: String?
    let modality: String?
    let vecBytes: Int
}

private let hpFindSQL = """
    select f.path, p.source, cast(p.start as integer), cast(p."end" as integer), p.modality, coalesce(length(p.vec), -1) \
    from fts join passages p on p.id = fts.rowid join files f on f.id = p.file_id where fts match
    """

private func hpFind(_ db: AtDB, column: String, _ word: String) -> [Hit]? {
    guard let rows = db.rows(hpFindSQL + " '\(column):\(word)'") else { return nil }
    return rows.map { row in
        Hit(file: ((row[0] ?? "") as NSString).lastPathComponent, source: row[1] ?? "", start: row[2], end: row[3],
            modality: row[4], vecBytes: Int(row[5] ?? "") ?? -2)
    }
}

private struct HpRow {
    let kind: String
    let status: String
    let reason: String?
    let readTo: String?
}

private func hpRows(_ db: AtDB) -> [String: HpRow]? {
    guard let rows = db.rows("select path, kind, status, reason, read_to from files") else { return nil }
    var out: [String: HpRow] = [:]
    for row in rows {
        guard let path = row[0], let kind = row[1], let status = row[2] else { continue }
        out[(path as NSString).lastPathComponent] = HpRow(kind: kind, status: status, reason: row[3], readTo: row[4])
    }
    return out
}

private struct HpPassage {
    let source: String
    let start: Int?
    let end: Int?
    let modality: String
    let vecBytes: Int
}

private func hpPassages(_ db: AtDB) -> [String: [HpPassage]]? {
    guard let rows = db.rows("""
        select f.path, p.source, cast(p.start as integer), cast(p."end" as integer), p.modality, coalesce(length(p.vec), -1) \
        from passages p join files f on f.id = p.file_id order by p.id
        """) else { return nil }
    var out: [String: [HpPassage]] = [:]
    for row in rows {
        guard let path = row[0] else { continue }
        out[(path as NSString).lastPathComponent, default: []].append(
            HpPassage(source: row[1] ?? "", start: row[2].flatMap { Int($0) }, end: row[3].flatMap { Int($0) },
                      modality: row[4] ?? "", vecBytes: Int(row[5] ?? "") ?? -2))
    }
    return out
}

private struct HpSnap {
    let status: String
    let readTo: Int?
    let names: Int
    let pages: Int
    let maxStart: Int
    let lastFound: Bool
}

/// One consistent state of one long PDF, or nil while it has no row (or the index cannot be read).
private func hpSnapshot(_ db: AtDB, file: String, lastToken: String) -> HpSnap? {
    guard db.rows("BEGIN") != nil else { return nil }
    defer { _ = db.rows("COMMIT") }
    guard let row = db.rows("select id, status, read_to from files where path like '%/\(file).pdf'")?.first,
          let idText = row[0], let id = Int(idText), let status = row[1],
          let counts = db.rows("""
              select coalesce(sum(source = 'name'), 0), coalesce(sum(source = 'page'), 0), \
              cast(coalesce(max(case when source = 'page' then start end), 0) as integer) from passages where file_id = \(id)
              """)?.first,
          let found = db.rows("select count(*) from fts join passages p on p.id = fts.rowid where p.file_id = \(id) and fts match 'body:\(lastToken)'")?.first?.first
    else { return nil }
    return HpSnap(status: status, readTo: row[2].flatMap { Int($0) }, names: Int(counts[0] ?? "") ?? -1,
                  pages: Int(counts[1] ?? "") ?? -1, maxStart: Int(counts[2] ?? "") ?? -1,
                  lastFound: (Int(found ?? "") ?? 0) > 0)
}

/// What is wrong with a snapshot of a PDF of `total` pages; nil when it is one of the three allowed states.
private func hpProblem(_ snap: HpSnap, total: Int) -> String? {
    switch snap.status {
    case "pending":
        return snap.names == 0 && snap.pages == 0 ? nil : "pending but holding \(snap.names) name and \(snap.pages) page passages"
    case "partial":
        guard total > 30, let readTo = snap.readTo, readTo % 30 == 0, readTo < total else {
            return "partial with read_to \(snap.readTo.map(String.init) ?? "none") for a \(total) page file"
        }
        if snap.names != 1 || snap.pages != readTo || snap.maxStart != readTo {
            return "partial at \(readTo) with \(snap.names) name passages, \(snap.pages) page passages, highest page \(snap.maxStart)"
        }
        return snap.lastFound ? "partial at \(readTo) but the last page's word is already found" : nil
    case "done":
        if snap.names != 1 || snap.pages != total || snap.maxStart != total {
            return "done with \(snap.names) name passages, \(snap.pages) page passages, highest page \(snap.maxStart), expected 1, \(total), \(total)"
        }
        if !snap.lastFound { return "done but the last page's word is not found" }
        if let readTo = snap.readTo, readTo != 0 { return "done but read_to is \(readTo)" }
        return nil
    default:
        return "status \(snap.status)"
    }
}

// MARK: the one shared run

private struct HpOutcome {
    var setupProblem: String?
    var rows: [String: HpRow] = [:]
    var passages: [String: [HpPassage]] = [:]
    var finds: [String: [Hit]] = [:]
    var nameFinds: [Hit] = []
    var violations: [String] = []
    var partials: [String: [Int]] = [:]
    var snapshots: [String: Int] = [:]
    var integrity = ""
    var helperExit: Int32?
    var summary = ""
}

private let hpLong: [(file: String, tokens: [String])] = [
    ("thirtypages", hpThirty), ("thirtyone", hpThirtyOne), ("ninetyone", hpNinetyOne),
]

private let hpOutcome: HpOutcome = {
    var out = HpOutcome()
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    do {
        try hpWrite(world, "harbourledger", pages: hpPages(hpHarbour), age: 1)
        try hpWrite(world, "locked", pages: hpPages([PdfMaker.token("locx", 1), PdfMaker.token("locx", 2)]), age: 2, password: "kit-locked-7")
        let whole = world.root.appendingPathComponent("whole.pdf").path
        try PdfMaker.write(hpPages(hpHarbour), to: whole)
        let damaged = world.photos.appendingPathComponent("damaged.pdf").path
        try PdfMaker.cut(whole, to: damaged, bytes: 200)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - 3)], ofItemAtPath: damaged)
        try hpWrite(world, "onepage", pages: hpPages(hpOne), age: 4)
        try hpWrite(world, "thirtypages", pages: hpPages(hpThirty), age: 5)
        try hpWrite(world, "thirtyone", pages: hpPages(hpThirtyOne), age: 6)
        try hpWrite(world, "ninetyone", pages: hpPages(hpNinetyOne), age: 7)
        try atMakePhotos(in: world.photos, names: ["holiday"], seedBase: 5, age: 8)
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

    let expectedFiles = 8
    let started = Date()
    var lastChange = started
    var lastSignature = ""
    var db: AtDB?
    var settled = false
    while true {
        if db == nil { db = world.db() }
        if let db {
            for item in hpLong {
                guard let snap = hpSnapshot(db, file: item.file, lastToken: item.tokens[item.tokens.count - 1]) else { continue }
                out.snapshots[item.file, default: 0] += 1
                if let problem = hpProblem(snap, total: item.tokens.count), out.violations.count < 20 {
                    out.violations.append("\(item.file): \(problem)")
                }
                if snap.status == "partial", let readTo = snap.readTo, out.partials[item.file]?.contains(readTo) != true {
                    out.partials[item.file, default: []].append(readTo)
                }
            }
            if let counts = db.rows("select status, count(*) from files group by status") {
                let signature = counts.map { "\($0[0] ?? "")=\($0[1] ?? "")" }.sorted().joined(separator: ",")
                if signature != lastSignature { lastSignature = signature; lastChange = Date() }
                let total = counts.reduce(0) { $0 + (Int($1[1] ?? "") ?? 0) }
                let open = counts.filter { $0[0] != "done" && $0[0] != "could_not_read" }.count
                if total == expectedFiles && open == 0 { settled = true; break }
            }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > 120 || now.timeIntervalSince(started) > 900 { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.0005)
    }
    out.summary = "settled \(settled), \(Int(Date().timeIntervalSince(started))) s, statuses \(lastSignature), helper \(helper.isRunning ? "running" : "gone"), stderr: \(helper.errors)"
    if settled { Thread.sleep(forTimeInterval: 1.5) }

    if let db = db ?? world.db() {
        out.rows = hpRows(db) ?? [:]
        out.passages = hpPassages(db) ?? [:]
        // A new connection: fts5 keeps its row totals per connection, and `integrity_check` does not refresh them, so the
        // poll connection above can hold totals from before the helper's last commits and report a mismatch that is not there.
        out.integrity = (world.db() ?? db).integrity()
        for token in hpHarbour + hpOne + [hpThirty[29], hpThirty[0], hpThirtyOne[0], hpThirtyOne[29], hpThirtyOne[30], hpNinetyOne[0], hpNinetyOne[90]] {
            out.finds[token] = hpFind(db, column: "body", token) ?? []
        }
        out.finds["zorvqqqq"] = hpFind(db, column: "body", "zorvqqqq") ?? []
        out.nameFinds = hpFind(db, column: "name", "harbourledger") ?? []
    }
    helper.closeStdin()
    out.helperExit = helper.waitForExit(timeout: 60)?.status
    return out
}()

private struct HpStop: Error {}

private func hpOutcomeOrStop() throws -> HpOutcome {
    let outcome = hpOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw HpStop()
    }
    return outcome
}

private func hpDescribe(_ rows: [String: HpRow]) -> String {
    rows.keys.sorted().map { "\($0)=\(rows[$0]!.status)\(rows[$0]!.reason.map { "(\($0))" } ?? "")" }.joined(separator: ", ")
}

// MARK: worlds for the tests that plant a row

private func hpIndexedWorld(_ names: [String]) throws -> AtWorld {
    let world = try AtWorld()
    do {
        for (index, name) in names.enumerated() {
            let tokens = [PdfMaker.token("tund", index * 2 + 1), PdfMaker.token("tund", index * 2 + 2)]
            try hpWrite(world, name, pages: hpPages(tokens), age: index)
        }
        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { $0 == ["done": names.count] })
        guard wait.met else {
            throw AtError("setup: the \(names.count) PDFs did not all reach done: \(wait.statuses), stderr: \(helper.errors)")
        }
        guard atCleanStop(helper) == 0 else {
            throw AtError("setup: the helper did not exit 0 within 120 s of its stdin ending; stderr: \(helper.errors)")
        }
    } catch {
        world.remove()
        throw error
    }
    return world
}

// MARK: the real model

private struct HpModels {
    let text: URL
    let mm: URL
}

private func hpModels() throws -> HpModels {
    let text = try #require(KitPaths.textModel(),
                            "model file missing: $KIT_ROOT/cache/\(KitPaths.textModelName) (seed the cache: scripts/kit-mirror.sh seed --real)")
    let mm = text.deletingLastPathComponent().appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
    try #require(FileManager.default.fileExists(atPath: mm.path), "model file missing: \(mm.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
    return HpModels(text: text, mm: mm)
}

private func hpStartReal(_ world: AtWorld, mode: String, arguments: [String]) throws -> HelperProcess {
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
    return try HelperProcess(executable: executable, arguments: [mode] + arguments)
}

/// The 768 half floats of a `hex(vec)` text, decoded here.
private func hpHalfVector(hex: String) -> [Double] {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
        bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
        index = next
    }
    return (0..<(bytes.count / 2)).map { number in
        Double(Float(Float16(bitPattern: UInt16(bytes[2 * number]) | (UInt16(bytes[2 * number + 1]) << 8))))
    }
}

private func hpCosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for index in 0..<min(a.count, b.count) {
        dot += a[index] * b[index]; na += a[index] * a[index]; nb += b[index] * b[index]
    }
    return dot / (na.squareRoot() * nb.squareRoot())
}

private func hpEmbedLine(id: Int, text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"cmd\":\"embed\",\"id\":\(id),\"text\":\"\(escaped)\",\"role\":\"query\"}"
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("HelperPdfTests", .serialized)
struct HelperPdfTests {

    // MARK: a text PDF

    @Test func aThreePageTextPdfIsDoneKindPdfWithOneNamePassageAndOnePagePassagePerTextPage() throws {
        let outcome = try hpOutcomeOrStop()
        let row = outcome.rows["harbourledger.pdf"]
        #expect(row?.status == "done", "harbourledger.pdf should be done, got \(row?.status ?? "no row"); rows: \(hpDescribe(outcome.rows)); \(outcome.summary)")
        #expect(row?.kind == "pdf", "the kind of harbourledger.pdf is \(row?.kind ?? "none"), expected pdf")
        let passages = outcome.passages["harbourledger.pdf"] ?? []
        #expect(passages.filter { $0.source == "name" }.count == 1, "name passages: \(passages.filter { $0.source == "name" }.count), expected 1")
        let pages = passages.filter { $0.source == "page" }
        #expect(pages.count == 3, "page passages: \(pages.count), expected 3 (one per text page)")
        #expect(pages.map(\.start).sorted { ($0 ?? 0) < ($1 ?? 0) } == [1, 2, 3], "page passages start at \(pages.map { $0.start.map(String.init) ?? "nil" })")
        #expect(pages.allSatisfy { $0.start == $0.end }, "a page passage's start and end are not the page number: \(pages.map { "\($0.start.map(String.init) ?? "nil")-\($0.end.map(String.init) ?? "nil")" })")
        #expect(pages.allSatisfy { $0.modality == "text" && $0.vecBytes == 1536 }, "a page passage is not text with a 1536 byte vector: \(pages.map { "\($0.modality) \($0.vecBytes)" })")
        let name = passages.first { $0.source == "name" }
        #expect(name?.modality == "none" && name?.vecBytes == -1, "the name passage is \(name?.modality ?? "none") with \(name?.vecBytes ?? -9) vector bytes, expected none and no vector")
        #expect(passages.count == 4, "passages: \(passages.map(\.source)), expected one name and three pages")
    }

    @Test func eachPageWordIsFoundByFtsOnItsOwnPagePassageAndTheFileNameWordsByName() throws {
        let outcome = try hpOutcomeOrStop()
        for (index, token) in hpHarbour.enumerated() {
            let hits = outcome.finds[token] ?? []
            #expect(hits.count == 1, "a MATCH for \(token) (page \(index + 1)) found \(hits.count) passages")
            guard let hit = hits.first else { continue }
            #expect(hit.file == "harbourledger.pdf" && hit.source == "page", "\(token) was found in \(hit.file) \(hit.source)")
            #expect(hit.start == String(index + 1) && hit.end == String(index + 1), "\(token) was found on page \(hit.start ?? "nil")-\(hit.end ?? "nil"), expected \(index + 1)")
        }
        #expect(outcome.nameFinds.count == 1, "a MATCH for the file name word found \(outcome.nameFinds.count) passages")
        if let hit = outcome.nameFinds.first {
            #expect(hit.file == "harbourledger.pdf" && hit.source == "name", "the file name word was found in \(hit.file) \(hit.source)")
        }
        #expect((outcome.finds["zorvqqqq"] ?? []).isEmpty, "a word nobody wrote was found")
    }

    // MARK: locked, damaged, the rest

    @Test func aLockedPdfIsCouldNotReadPasswordProtectedAndADamagedOneDamaged() throws {
        let outcome = try hpOutcomeOrStop()
        let locked = outcome.rows["locked.pdf"]
        #expect(locked?.status == "could_not_read" && locked?.reason == "password-protected",
                "locked.pdf should be could_not_read (password-protected), got \(locked?.status ?? "no row") (\(locked?.reason ?? "no reason"))")
        let damaged = outcome.rows["damaged.pdf"]
        #expect(damaged?.status == "could_not_read" && damaged?.reason == "damaged",
                "damaged.pdf should be could_not_read (damaged), got \(damaged?.status ?? "no row") (\(damaged?.reason ?? "no reason"))")
        #expect(locked?.kind == "pdf" && damaged?.kind == "pdf", "the kinds are \(locked?.kind ?? "none") and \(damaged?.kind ?? "none")")
    }

    @Test func everyOtherFileIsDoneAndTheIndexPassesItsIntegrityCheck() throws {
        let outcome = try hpOutcomeOrStop()
        #expect(outcome.rows.count == 8, "the index holds \(outcome.rows.count) files rows, expected 8: \(hpDescribe(outcome.rows)); \(outcome.summary)")
        let others = outcome.rows.filter { $0.key != "locked.pdf" && $0.key != "damaged.pdf" }
        #expect(others.count == 6 && others.values.allSatisfy { $0.status == "done" },
                "every file but the locked and the damaged one should be done: \(hpDescribe(outcome.rows))")
        #expect(outcome.rows["holiday.jpg"]?.status == "done" && outcome.rows["holiday.jpg"]?.kind == "photo",
                "the photo beside the PDFs should be done as a photo: \(hpDescribe(outcome.rows))")
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.helperExit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.helperExit.map(String.init) ?? "still running")")
    }

    // MARK: S3.10, the step edge

    @Test func pdfsOf1And30And31PagesEachFindTheirLastPageStringWithThatPageAsTheStart() throws {
        let outcome = try hpOutcomeOrStop()
        let cases: [(token: String, file: String, page: Int)] = [
            (hpOne[0], "onepage.pdf", 1),
            (hpThirty[29], "thirtypages.pdf", 30),
            (hpThirtyOne[30], "thirtyone.pdf", 31),
            (hpNinetyOne[90], "ninetyone.pdf", 91),
        ]
        for item in cases {
            let hits = outcome.finds[item.token] ?? []
            #expect(hits.count == 1, "the last page word of \(item.file) found \(hits.count) passages: \(outcome.summary)")
            guard let hit = hits.first else { continue }
            #expect(hit.file == item.file && hit.source == "page", "the last page word of \(item.file) was found in \(hit.file) \(hit.source)")
            #expect(hit.start == String(item.page), "the last page word of \(item.file) has start \(hit.start ?? "nil"), expected \(item.page)")
        }
    }

    @Test func aThirtyOnePageFileIsPartialAtThirtyAfterItsFirstStepAndDoneWithReadToClearedAtTheEnd() throws {
        let outcome = try hpOutcomeOrStop()
        #expect(outcome.snapshots["thirtyone"] ?? 0 > 0, "the poll never saw a row for thirtyone.pdf: \(outcome.summary)")
        let seen = outcome.partials["thirtyone"] ?? []
        #expect(seen == [30], "the 31 page file was seen partial at read_to \(seen), expected only 30 (a poll without a pause sees the window between its two steps); \(outcome.summary)")
        let row = outcome.rows["thirtyone.pdf"]
        #expect(row?.status == "done", "thirtyone.pdf ends \(row?.status ?? "no row")")
        #expect(row?.readTo == nil || row?.readTo == "0", "read_to is \(row?.readTo ?? "nil") on the finished file, expected it cleared")
        let page30 = outcome.finds[hpThirtyOne[0]] ?? []
        #expect(page30.count == 1 && page30.first?.start == "1", "the first page word of thirtyone.pdf: \(page30.map { $0.start ?? "nil" })")
    }

    @Test func aThirtyPageFileIsOneStepAndANinetyOnePageFileGoesThirtyThenSixtyThenNinety() throws {
        let outcome = try hpOutcomeOrStop()
        #expect(outcome.partials["thirtypages"] ?? [] == [], "a 30 page file was seen partial at \(outcome.partials["thirtypages"] ?? []): it is one step")
        let seen = outcome.partials["ninetyone"] ?? []
        #expect(!seen.isEmpty, "the poll never saw the 91 page file partial: \(outcome.summary)")
        #expect(Set(seen).isSubset(of: [30, 60, 90]), "the 91 page file was seen partial at \(seen), expected only 30, 60 or 90")
        #expect(seen == seen.sorted(), "read_to went down: \(seen)")
        #expect(outcome.rows["thirtypages.pdf"]?.status == "done" && outcome.rows["ninetyone.pdf"]?.status == "done",
                "the long files end \(hpDescribe(outcome.rows))")
    }

    @Test func noSnapshotOfALongPdfShowsAHalfWrittenStep() throws {
        let outcome = try hpOutcomeOrStop()
        for item in hpLong {
            #expect(outcome.snapshots[item.file] ?? 0 > 0, "the poll never saw \(item.file).pdf")
        }
        #expect(outcome.violations.isEmpty, "a snapshot was not whole: \(outcome.violations.prefix(5)); \(outcome.summary)")
    }

    // MARK: a PDF changed between batches

    @Test func aPdfChangedBetweenBatchesIsReplacedAndNeverMixedWithItsOldWords() throws {
        let world = try AtWorld()
        defer { world.remove() }
        let oldTokens = (1...31).map { PdfMaker.token("plum", $0) }
        let newTokens = (1...31).map { PdfMaker.token("wolf", $0) }
        let path = try hpWrite(world, "shifting", pages: hpPages(oldTokens), age: 3600)
        let oldSize = try #require(try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        let line = atFoldersLine([world.photos])
        helper.send(line)
        let first = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { $0 == ["done": 1] })
        #expect(first.met, "the 31 page PDF did not reach done: \(first.statuses), stderr: \(helper.errors)")
        guard first.met, let db = world.db() else { return }
        #expect(hpFind(db, column: "body", oldTokens[0])?.count == 1 && hpFind(db, column: "body", oldTokens[30])?.count == 1,
                "setup: the first and last words of the old version are not both found")

        // The file changes: other words on every page, longer pages (a different size), a different modified time.
        try PdfMaker.write(newTokens.map { .text(PdfMaker.rich($0) + PdfMaker.fillerSentence) }, to: path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - 1800)], ofItemAtPath: path)
        let newSize = try #require(try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        try #require(newSize != oldSize, "setup: the rewrite did not change the file's size")
        helper.send(line)

        var states: [String] = []
        var violations: [String] = []
        let started = Date()
        var lastChange = started
        var lastState = ""
        while Date().timeIntervalSince(started) < 240 {
            guard db.rows("BEGIN") != nil else { continue }
            let row = db.rows("select id, size, status from files where path like '%/shifting.pdf'")?.first
            var state = "no row"
            if let row, let idText = row[0], let id = Int(idText) {
                let size = row[1].flatMap { Int($0) }
                let status = row[2] ?? "nil"
                func count(_ token: String) -> Int {
                    db.int("select count(*) from fts join passages p on p.id = fts.rowid where p.file_id = \(id) and fts match 'body:\(token)'") ?? -1
                }
                let oldAny = count(oldTokens[0]) > 0 || count(oldTokens[30]) > 0
                let newAny = count(newTokens[0]) > 0 || count(newTokens[30]) > 0
                let pages = db.int("select count(*) from passages where file_id = \(id) and source = 'page'") ?? -1
                if oldAny && newAny {
                    state = "mixed"
                    violations.append("old and new words together (status \(status), size \(size.map(String.init) ?? "nil"))")
                } else if status == "partial" {
                    state = "partial"
                    if oldAny { state = "inconsistent"; violations.append("partial but the old words are still there") }
                } else if status == "done", size == oldSize {
                    state = "old"
                    if !oldAny || pages != 31 { state = "inconsistent"; violations.append("done with the old size but \(pages) page passages, old words found \(oldAny)") }
                } else if status == "done", size == newSize {
                    state = "new"
                    if !newAny || oldAny || pages != 31 { state = "inconsistent"; violations.append("done with the new size but \(pages) page passages, new words found \(newAny), old words found \(oldAny)") }
                } else if status == "done" {
                    state = "inconsistent"
                    violations.append("done with size \(size.map(String.init) ?? "nil"), neither \(oldSize) nor \(newSize)")
                } else {
                    state = status
                }
            }
            _ = db.rows("COMMIT")
            if state != lastState { states.append(state); lastState = state; lastChange = Date() }
            if state == "new" { break }
            if Date().timeIntervalSince(lastChange) > 120 { break }
            Thread.sleep(forTimeInterval: 0.0005)
        }
        #expect(violations.isEmpty, "a reader saw the changed PDF in a bad state (\(violations.count) times), first: \(violations.first ?? ""); states \(states)")
        #expect(states.last == "new", "the changed PDF never became new and complete; states seen \(states); stderr: \(helper.errors)")

        let after = try #require(world.db())
        #expect(after.integrity() == "ok", "integrity_check: \(after.integrity())")
        #expect(hpFind(after, column: "body", oldTokens[0])?.isEmpty == true && hpFind(after, column: "body", oldTokens[30])?.isEmpty == true,
                "the old words of the file are still in the index")
        let newLast = hpFind(after, column: "body", newTokens[30]) ?? []
        #expect(newLast.count == 1 && newLast.first?.start == "31", "the new last page word: \(newLast.map { $0.start ?? "nil" })")
        #expect(after.int("select count(*) from passages where source = 'page'") == 31, "page passages after the change: \(after.int("select count(*) from passages where source = 'page'").map(String.init) ?? "nil"), expected 31")
    }

    // MARK: the attempt marker and the hints of plan 2, on PDFs

    // `tries` 2 is not read: `could_not_read`, reason "damaged", or "needed too much memory" when the row's reason holds
    // `hint:memory`. A neighbour with tries 1 or 0 is read again.
    @Test func aPdfWithTriesTwoBecomesCouldNotReadDamagedOrNeededTooMuchMemoryByItsHintAndIsNeverReadAgain() throws {
        let names = atNames("q", 1...5)
        let world = try hpIndexedWorld(names)
        defer { world.remove() }
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2 where path like '%/q-001.pdf'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2, reason = 'hint:memory' where path like '%/q-002.pdf'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 1 where path like '%/q-003.pdf'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0 where path like '%/q-004.pdf'") == nil)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { $0 == ["done": 3, "could_not_read": 2] })
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
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }

    // A pending PDF holding `hint:solo` is read alone before any other work: the oldest (the one the queue would reach last)
    // carries the hint and must be the first written.
    @Test func aPendingPdfHoldingHintSoloIsReadFirstBeforeAnyOtherWork() throws {
        let names = atNames("s", 1...6)
        let world = try hpIndexedWorld(names)
        defer { world.remove() }
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0") == nil)
        #expect(atWrite(world.indexFile, "update files set reason = 'hint:solo' where path like '%/s-006.pdf'") == nil)
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { $0 == ["done": 6] })
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

    // MARK: the cached real model

    @Test func withTheCachedRealModelATextPageHasARealVectorAndTheFileIsDoneNeverCouldNotRead() throws {
        let models = try hpModels()
        let world = try AtWorld()
        defer { world.remove() }
        let catText = "Our tabby cat sleeps on the sofa all afternoon, purring softly while the kitten chases a ball of wool across the warm living room floor. Feline pets need fresh water, gentle play and regular visits to the veterinarian to stay happy and healthy for many years."
        let taxText = "The annual tax return lists income, deductions and credits. The revenue authority expects payment of any tax owed before the filing deadline, and late payment adds interest and penalties to the amount due for the tax year."
        try hpWrite(world, "felinecare", pages: [.text(catText)], age: 1)
        try hpWrite(world, "taxreturn", pages: [.text(taxText)], age: 2)

        let helper = try hpStartReal(world, mode: "index", arguments: ["--text-model", models.text.path, "--mm-model", models.mm.path])
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 300, cap: 900, until: { $0 == ["done": 2] })
        #expect(wait.met, "the two PDFs did not both reach done with the real model: \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")
        guard wait.met else { return }

        let db = try #require(world.db())
        let rows = try #require(hpRows(db))
        #expect(rows["felinecare.pdf"]?.status == "done" && rows["taxreturn.pdf"]?.status == "done", "rows: \(hpDescribe(rows))")
        let vectors = try #require(db.rows("select f.path, p.source, p.modality, coalesce(length(p.vec), -1), coalesce(hex(p.vec), '') from passages p join files f on f.id = p.file_id"))
        var pageVectors: [String: [Double]] = [:]
        for row in vectors {
            let name = ((row[0] ?? "") as NSString).lastPathComponent
            if row[1] == "name" {
                #expect(row[3] == "-1", "the name passage of \(name) holds a vector")
                continue
            }
            #expect(row[1] == "page" && row[2] == "text", "\(name): a \(row[1] ?? "nil") passage with modality \(row[2] ?? "nil"), expected a text page")
            #expect(row[3] == "1536", "\(name): the page passage holds \(row[3] ?? "nil") vector bytes, not NULL and not 1536")
            let vector = hpHalfVector(hex: row[4] ?? "")
            let length = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            #expect(vector.count == 768 && vector.allSatisfy { $0.isFinite } && abs(length - 1) < 0.02,
                    "\(name): the page vector is not 768 finite numbers of unit length (count \(vector.count), length \(length))")
            pageVectors[name] = vector
        }
        #expect(pageVectors.count == 2, "page vectors for \(pageVectors.keys.sorted()), expected both files")

        homeLock.lock()
        let previousHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", world.home.path, 1)
        let reader = IndexReader()
        let source = reader.meta("vector_source")
        reader.close()
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        homeLock.unlock()
        #expect(source == LlamaEmbedder.vectorSource, "meta.vector_source is \(source ?? "nil"), expected \(LlamaEmbedder.vectorSource)")

        // The vectors are the model's: a question about cats is closer to the cat page than to the tax page, and the other way round.
        let encoder = try hpStartReal(world, mode: "encode", arguments: ["--text-model", models.text.path])
        defer { encoder.stop() }
        let cats = encoder.roundTrip(hpEmbedLine(id: 1, text: "a small domesticated feline kept as a pet"), timeout: 300).reply
        let taxes = encoder.roundTrip(hpEmbedLine(id: 2, text: "money owed to the revenue authority for the tax year"), timeout: 300).reply
        let catQuery = try #require(cats?.vec, "no vector for the cat question; stderr: \(encoder.errors)")
        let taxQuery = try #require(taxes?.vec, "no vector for the tax question; stderr: \(encoder.errors)")
        let catPage = try #require(pageVectors["felinecare.pdf"])
        let taxPage = try #require(pageVectors["taxreturn.pdf"])
        let catToCat = hpCosine(catQuery, catPage), catToTax = hpCosine(catQuery, taxPage)
        let taxToTax = hpCosine(taxQuery, taxPage), taxToCat = hpCosine(taxQuery, catPage)
        print("READING pdf page vectors: cat question cat page \(catToCat) tax page \(catToTax); tax question tax page \(taxToTax) cat page \(taxToCat)")
        #expect(catToCat > catToTax + 0.02, "the cat question is not closer to the cat page (\(catToCat)) than to the tax page (\(catToTax))")
        #expect(taxToTax > taxToCat + 0.02, "the tax question is not closer to the tax page (\(taxToTax)) than to the cat page (\(taxToCat))")
    }
}
}
