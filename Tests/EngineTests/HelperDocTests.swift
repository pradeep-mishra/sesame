import Foundation
import Testing
import SesameEngine

// plan-4-t6, tester step. Written from the t6 entry of plan-4-tasks.md (Tests), design sections 1, 3 and 4 and the spec's S3 only;
// no product source is read. The harness (`At...`: AtWorld, AtDB, atStartHelper, atFoldersLine, atWaitStatuses, atCleanStop, atPast,
// atMakePhotos) is the one IndexAttemptTests.swift holds; the PDF maker's `token` is PdfReaderTests.swift's; the document maker
// (`DocMaker`, `DocSample`) is DocReaderTests.swift's, whose header holds the shapes this file pins too (0-based `fromChunk`,
// UTF-16 offsets with an exclusive end, a text with no whitespace cut every `chunkCharacters` units).
//
// How a run is made: the bundled release helper alone (`dist/Sesame.app/Contents/MacOS/SesameHelper index`, run `scripts/bundle.sh`
// first: a stale bundle makes these tests fail, never pass), `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME, 120 s allowed to a start.
// The index is read with this file's own read-only SQLite connection. Column names are design section 1's: `files(path, kind,
// status, reason, read_to)`, `passages(id, file_id, source, start, end, modality, vec)`, `fts(name, body)`. SQLite stores
// `start` and `end` as REAL, so every read casts them to integers.
//
// The one shared run (`hdOutcome`): a folder holding, every one made by this file,
//   harbourmemo.txt, fieldnotes.md, quarterletter.rtf, tenancy.docx, bakingpage.html, neighbours.odt   the six types, each ~1,000
//       characters with an anchor phrase of three words of its own (rtf, docx and odt by `textutil`, html by hand)
//   emptynotes.txt        zero bytes [guess of the entry: readable, only its name passage]
//   hundredchunks.txt     100 chunks (no whitespace, 100 times `chunkCharacters` letters, a word of its own at the start of each)
//   holiday.jpg           a photo: the control that the picture path still works beside the documents
//   damaged/broken.docx   plain text under a docx name; damaged/gooddoc.txt a good text beside it
//   unsupported/          deck.pptx, sheet.xlsx, book.pages, raw.dng (bytes) and README (no extension): no row for any
// While the helper works, a read-only connection takes a snapshot of the 100-chunk file as fast as it can (one BEGIN, a few
// statements, one COMMIT) and records any state that is not one of the three the design allows: nothing yet; `partial` with
// `read_to` 40 or 80, one `name` passage, exactly `read_to` `chunk` passages, the last one ending at `read_to` times
// `chunkCharacters`, the last chunk's word not found yet; `done` with all 100 chunks, the last chunk's word found, `read_to`
// cleared. The window between two steps is short, so the poll runs without a pause.

// MARK: the files

private let hdSamples: [DocSample] = [
    DocMaker.sample("txt", stem: "harbourmemo", number: 11),
    DocMaker.sample("md", stem: "fieldnotes", number: 12),
    DocMaker.sample("rtf", stem: "quarterletter", number: 13),
    DocMaker.sample("docx", stem: "tenancy", number: 14),
    DocMaker.sample("html", stem: "bakingpage", number: 15),
    DocMaker.sample("odt", stem: "neighbours", number: 16),
]

private let hdHundred = DocMaker.spaceless(parts: 100, size: DocReader.chunkCharacters)
private let hdExpectedFiles = 11

/// The text a txt or md sample's file holds, as the reader must give it (the md has a heading line).
private func hdFileText(_ sample: DocSample) -> String {
    sample.ext == "md" ? "# " + sample.stem + "\n\n" + sample.source : sample.source
}

private func hdAge(_ path: String, _ seconds: Int) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(seconds))], ofItemAtPath: path)
}

// MARK: reading the index

private struct HdHit {
    let file: String
    let source: String
    let start: Int?
    let end: Int?
    let modality: String?
    let vecBytes: Int
}

private func hdFind(_ db: AtDB, column: String, phrase: String) -> [HdHit]? {
    guard let rows = db.rows("""
        select f.path, p.source, cast(p.start as integer), cast(p."end" as integer), p.modality, coalesce(length(p.vec), -1) \
        from fts join passages p on p.id = fts.rowid join files f on f.id = p.file_id where fts match '\(column):"\(phrase)"'
        """) else { return nil }
    return rows.map { row in
        HdHit(file: ((row[0] ?? "") as NSString).lastPathComponent, source: row[1] ?? "", start: row[2].flatMap { Int($0) },
              end: row[3].flatMap { Int($0) }, modality: row[4], vecBytes: Int(row[5] ?? "") ?? -2)
    }
}

private struct HdRow {
    let kind: String
    let status: String
    let reason: String?
    let readTo: String?
}

private func hdRows(_ db: AtDB) -> [String: HdRow]? {
    guard let rows = db.rows("select path, kind, status, reason, read_to from files") else { return nil }
    var out: [String: HdRow] = [:]
    for row in rows {
        guard let path = row[0], let kind = row[1], let status = row[2] else { continue }
        out[(path as NSString).lastPathComponent] = HdRow(kind: kind, status: status, reason: row[3], readTo: row[4])
    }
    return out
}

private func hdPassages(_ db: AtDB) -> [String: [HdHit]]? {
    guard let rows = db.rows("""
        select f.path, p.source, cast(p.start as integer), cast(p."end" as integer), p.modality, coalesce(length(p.vec), -1) \
        from passages p join files f on f.id = p.file_id order by p.id
        """) else { return nil }
    var out: [String: [HdHit]] = [:]
    for row in rows {
        guard let path = row[0] else { continue }
        let name = (path as NSString).lastPathComponent
        out[name, default: []].append(HdHit(file: name, source: row[1] ?? "", start: row[2].flatMap { Int($0) },
                                            end: row[3].flatMap { Int($0) }, modality: row[4], vecBytes: Int(row[5] ?? "") ?? -2))
    }
    return out
}

private struct HdSnap {
    let status: String
    let readTo: Int?
    let names: Int
    let chunks: Int
    let maxEnd: Int
    let lastFound: Bool
}

private func hdSnapshot(_ db: AtDB, lastPiece: String) -> HdSnap? {
    guard db.rows("BEGIN") != nil else { return nil }
    defer { _ = db.rows("COMMIT") }
    guard let row = db.rows("select id, status, read_to from files where path like '%/hundredchunks.txt'")?.first,
          let idText = row[0], let id = Int(idText), let status = row[1],
          let counts = db.rows("""
              select coalesce(sum(source = 'name'), 0), coalesce(sum(source = 'chunk'), 0), \
              cast(coalesce(max(case when source = 'chunk' then "end" end), 0) as integer) from passages where file_id = \(id)
              """)?.first,
          let found = db.rows("select count(*) from fts join passages p on p.id = fts.rowid where p.file_id = \(id) and fts match 'body:\"\(lastPiece)\"'")?.first?.first
    else { return nil }
    return HdSnap(status: status, readTo: row[2].flatMap { Int($0) }, names: Int(counts[0] ?? "") ?? -1,
                  chunks: Int(counts[1] ?? "") ?? -1, maxEnd: Int(counts[2] ?? "") ?? -1, lastFound: (Int(found ?? "") ?? 0) > 0)
}

/// What is wrong with a snapshot of the 100-chunk file; nil when it is one of the three allowed states.
private func hdProblem(_ snap: HdSnap) -> String? {
    let size = DocReader.chunkCharacters
    switch snap.status {
    case "pending":
        return snap.names == 0 && snap.chunks == 0 ? nil : "pending but holding \(snap.names) name and \(snap.chunks) chunk passages"
    case "partial":
        guard let readTo = snap.readTo, readTo == 40 || readTo == 80 else {
            return "partial with read_to \(snap.readTo.map(String.init) ?? "none"), expected 40 or 80"
        }
        if snap.names != 1 || snap.chunks != readTo || snap.maxEnd != readTo * size {
            return "partial at \(readTo) with \(snap.names) name passages, \(snap.chunks) chunk passages, highest end \(snap.maxEnd), expected 1, \(readTo), \(readTo * size)"
        }
        return snap.lastFound ? "partial at \(readTo) but the last chunk's word is already found" : nil
    case "done":
        if snap.names != 1 || snap.chunks != 100 || snap.maxEnd != 100 * size {
            return "done with \(snap.names) name passages, \(snap.chunks) chunk passages, highest end \(snap.maxEnd), expected 1, 100, \(100 * size)"
        }
        if !snap.lastFound { return "done but the last chunk's word is not found" }
        if let readTo = snap.readTo, readTo != 0 { return "done but read_to is \(readTo)" }
        return nil
    default:
        return "status \(snap.status)"
    }
}

// MARK: the one shared run

private struct HdOutcome {
    var setupProblem: String?
    var rows: [String: HdRow] = [:]
    var passages: [String: [HdHit]] = [:]
    var anchorFinds: [String: [HdHit]] = [:]
    var nameFinds: [String: [HdHit]] = [:]
    var pieceFinds: [Int: [HdHit]] = [:]
    var missingFinds: [HdHit] = []
    var violations: [String] = []
    var partials: [Int] = []
    var snapshots = 0
    var integrity = ""
    var helperExit: Int32?
    var summary = ""
}

private let hdOutcome: HdOutcome = {
    var out = HdOutcome()
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    let fm = FileManager.default
    let top = world.photos.path
    do {
        for (index, sample) in hdSamples.enumerated() {
            let path = try DocMaker.write(sample, in: top)
            try hdAge(path, 1 + index)
        }
        let empty = top + "/emptynotes.txt"
        try Data().write(to: URL(fileURLWithPath: empty))
        try hdAge(empty, 8)
        let hundred = top + "/hundredchunks.txt"
        try Data(hdHundred.text.utf8).write(to: URL(fileURLWithPath: hundred))
        try hdAge(hundred, 9)
        try atMakePhotos(in: world.photos, names: ["holiday"], seedBase: 5, age: 10)
        try fm.createDirectory(atPath: top + "/damaged", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: top + "/unsupported", withIntermediateDirectories: true)
        try Data("This is plain text, not a zip file.\n".utf8).write(to: URL(fileURLWithPath: top + "/damaged/broken.docx"))
        try Data("A good text file next to the damaged one.\n".utf8).write(to: URL(fileURLWithPath: top + "/damaged/gooddoc.txt"))
        for name in ["deck.pptx", "sheet.xlsx", "book.pages", "raw.dng"] {
            try Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ name.utf8.count) }).write(to: URL(fileURLWithPath: top + "/unsupported/" + name))
        }
        try Data("A file with no extension.\n".utf8).write(to: URL(fileURLWithPath: top + "/unsupported/README"))
        for name in ["damaged/broken.docx", "damaged/gooddoc.txt"] { try hdAge(top + "/" + name, 12) }
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

    let lastPiece = hdHundred.pieces[99]
    let started = Date()
    var lastChange = started
    var lastSignature = ""
    var db: AtDB?
    var settled = false
    while true {
        if db == nil { db = world.db() }
        if let db {
            if let snap = hdSnapshot(db, lastPiece: lastPiece) {
                out.snapshots += 1
                if let problem = hdProblem(snap), out.violations.count < 20 { out.violations.append(problem) }
                if snap.status == "partial", let readTo = snap.readTo, !out.partials.contains(readTo) { out.partials.append(readTo) }
            }
            if let counts = db.rows("select status, count(*) from files group by status") {
                let signature = counts.map { "\($0[0] ?? "")=\($0[1] ?? "")" }.sorted().joined(separator: ",")
                if signature != lastSignature { lastSignature = signature; lastChange = Date() }
                let total = counts.reduce(0) { $0 + (Int($1[1] ?? "") ?? 0) }
                let open = counts.filter { $0[0] != "done" && $0[0] != "could_not_read" }.count
                if total == hdExpectedFiles && open == 0 { settled = true; break }
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
        out.rows = hdRows(db) ?? [:]
        out.passages = hdPassages(db) ?? [:]
        // A new connection: fts5 keeps its row totals per connection, and `integrity_check` does not refresh them, so the
        // poll connection above can hold totals from before the helper's last commits and report a mismatch that is not there.
        out.integrity = (world.db() ?? db).integrity()
        for sample in hdSamples {
            out.anchorFinds[sample.fileName] = hdFind(db, column: "body", phrase: sample.anchor) ?? []
            out.nameFinds[sample.fileName] = hdFind(db, column: "name", phrase: sample.stem) ?? []
        }
        for number in [0, 39, 40, 79, 80, 99] { out.pieceFinds[number] = hdFind(db, column: "body", phrase: hdHundred.pieces[number]) ?? [] }
        out.missingFinds = hdFind(db, column: "body", phrase: "zanxqqqq zanyqqqq zanzqqqq") ?? []
    }
    helper.closeStdin()
    out.helperExit = helper.waitForExit(timeout: 60)?.status
    return out
}()

private struct HdStop: Error {}

private func hdOutcomeOrStop() throws -> HdOutcome {
    let outcome = hdOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw HdStop()
    }
    return outcome
}

private func hdDescribe(_ rows: [String: HdRow]) -> String {
    rows.keys.sorted().map { "\($0)=\(rows[$0]!.status)\(rows[$0]!.reason.map { "(\($0))" } ?? "")" }.joined(separator: ", ")
}

// MARK: the real model

private struct HdModels {
    let text: URL
    let mm: URL
}

private func hdModels() throws -> HdModels {
    let text = try #require(KitPaths.textModel(),
                            "model file missing: $KIT_ROOT/cache/\(KitPaths.textModelName) (seed the cache: scripts/kit-mirror.sh seed --real)")
    let mm = text.deletingLastPathComponent().appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
    try #require(FileManager.default.fileExists(atPath: mm.path), "model file missing: \(mm.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
    return HdModels(text: text, mm: mm)
}

private func hdStartReal(_ world: AtWorld, mode: String, arguments: [String]) throws -> HelperProcess {
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

// MARK: the tests

extension EncodeHelperTests {
@Suite("HelperDocTests", .serialized)
struct HelperDocTests {

    // MARK: the six types

    @Test func theSixDocumentsAreDoneKindDocWithANamePassageAndOneChunkPassageWithOffsets() throws {
        let outcome = try hdOutcomeOrStop()
        for sample in hdSamples {
            let row = outcome.rows[sample.fileName]
            #expect(row?.status == "done", "\(sample.fileName) should be done, got \(row?.status ?? "no row"); rows: \(hdDescribe(outcome.rows)); \(outcome.summary)")
            #expect(row?.kind == "doc", "the kind of \(sample.fileName) is \(row?.kind ?? "none"), expected doc")
            let passages = outcome.passages[sample.fileName] ?? []
            let names = passages.filter { $0.source == "name" }
            let chunks = passages.filter { $0.source == "chunk" }
            #expect(passages.count == 2 && names.count == 1 && chunks.count == 1,
                    "\(sample.fileName) passages: \(passages.map(\.source)), expected one name and one chunk (about 1,000 characters is one chunk)")
            #expect(names.first?.modality == "none" && names.first?.vecBytes == -1,
                    "the name passage of \(sample.fileName) is \(names.first?.modality ?? "none") with \(names.first?.vecBytes ?? -9) vector bytes, expected none and no vector")
            guard let chunk = chunks.first else { continue }
            #expect(chunk.modality == "text" && chunk.vecBytes == 1536, "the chunk of \(sample.fileName) is \(chunk.modality ?? "nil") with \(chunk.vecBytes) vector bytes, expected text and 1536")
            #expect(chunk.start == 0, "the chunk of \(sample.fileName) starts at \(chunk.start.map(String.init) ?? "nil"), expected 0")
            if sample.ext == "txt" || sample.ext == "md" {
                #expect(chunk.end == hdFileText(sample).utf16.count, "the chunk of \(sample.fileName) ends at \(chunk.end.map(String.init) ?? "nil"), expected \(hdFileText(sample).utf16.count) (the file's UTF-16 length)")
            } else {
                #expect((chunk.end ?? 0) >= 700, "the chunk of \(sample.fileName) ends at \(chunk.end.map(String.init) ?? "nil"), about 1,000 characters were written")
            }
        }
    }

    @Test func eachDocumentIsFoundByItsAnchorPhraseOnItsOwnChunkAndByItsFileNameWords() throws {
        let outcome = try hdOutcomeOrStop()
        for sample in hdSamples {
            let hits = outcome.anchorFinds[sample.fileName] ?? []
            #expect(hits.count == 1, "a phrase MATCH for the anchor of \(sample.fileName) found \(hits.count) passages")
            if let hit = hits.first {
                #expect(hit.file == sample.fileName && hit.source == "chunk" && hit.start == 0,
                        "the anchor of \(sample.fileName) was found in \(hit.file) \(hit.source) at \(hit.start.map(String.init) ?? "nil")")
            }
            let named = outcome.nameFinds[sample.fileName] ?? []
            #expect(named.count == 1 && named.first?.file == sample.fileName && named.first?.source == "name",
                    "a MATCH for the file name word \(sample.stem) found \(named.map { "\($0.file) \($0.source)" })")
        }
        #expect(outcome.missingFinds.isEmpty, "a phrase nobody wrote was found")
    }

    // MARK: damaged, empty, unsupported

    @Test func aDamagedDocxIsCouldNotReadDamagedAndTheOtherFilesAreDone() throws {
        let outcome = try hdOutcomeOrStop()
        let broken = outcome.rows["broken.docx"]
        #expect(broken?.status == "could_not_read" && broken?.reason == "damaged" && broken?.kind == "doc",
                "broken.docx should be a doc could_not_read (damaged), got \(broken?.kind ?? "no row") \(broken?.status ?? "") (\(broken?.reason ?? "no reason")); rows: \(hdDescribe(outcome.rows))")
        #expect(outcome.passages["broken.docx"]?.contains { $0.source == "chunk" } != true, "a damaged docx has a chunk passage")
        let others = outcome.rows.filter { $0.key != "broken.docx" }
        #expect(others.count == hdExpectedFiles - 1 && others.values.allSatisfy { $0.status == "done" },
                "every file but broken.docx should be done: \(hdDescribe(outcome.rows)); \(outcome.summary)")
        #expect(outcome.rows["holiday.jpg"]?.status == "done" && outcome.rows["holiday.jpg"]?.kind == "photo",
                "the photo beside the documents should be done as a photo: \(hdDescribe(outcome.rows))")
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.helperExit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.helperExit.map(String.init) ?? "still running")")
    }

    @Test func theTreeStyleFoldersGiveARowForTheGoodTextAndNoneForPptxXlsxPagesDngAndAFileWithNoExtension() throws {
        let outcome = try hdOutcomeOrStop()
        #expect(outcome.rows["gooddoc.txt"]?.status == "done" && outcome.rows["gooddoc.txt"]?.kind == "doc",
                "damaged/gooddoc.txt should be a done doc, got \(outcome.rows["gooddoc.txt"]?.status ?? "no row")")
        for name in ["deck.pptx", "sheet.xlsx", "book.pages", "raw.dng", "README"] {
            #expect(outcome.rows[name] == nil, "\(name) must have no row, got \(outcome.rows[name]?.status ?? "")")
        }
        #expect(outcome.rows.count == hdExpectedFiles, "the index holds \(outcome.rows.count) files rows, expected \(hdExpectedFiles): \(hdDescribe(outcome.rows))")
    }

    @Test func aZeroByteTxtIsDoneWithOnlyItsNamePassage() throws {
        let outcome = try hdOutcomeOrStop()
        let row = outcome.rows["emptynotes.txt"]
        #expect(row?.status == "done" && row?.kind == "doc", "emptynotes.txt should be a done doc, got \(row?.kind ?? "no row") \(row?.status ?? "")")
        let passages = outcome.passages["emptynotes.txt"] ?? []
        #expect(passages.map(\.source) == ["name"], "emptynotes.txt passages: \(passages.map(\.source)), expected only a name passage")
    }

    // MARK: a 100-chunk text: steps of 40

    @Test func aHundredChunkTxtIsPartialAtFortyThenEightyThenDoneAndItsLastChunkIsFoundOnlyAtTheEnd() throws {
        let outcome = try hdOutcomeOrStop()
        #expect(outcome.snapshots > 0, "the poll never saw a row for hundredchunks.txt: \(outcome.summary)")
        #expect(outcome.partials == [40, 80], "the 100 chunk file was seen partial at read_to \(outcome.partials), expected 40 then 80 (a poll without a pause sees the windows between its steps); \(outcome.summary)")
        #expect(outcome.violations.isEmpty, "a snapshot was not whole: \(outcome.violations.prefix(5)); \(outcome.summary)")
        let row = outcome.rows["hundredchunks.txt"]
        #expect(row?.status == "done" && row?.kind == "doc", "hundredchunks.txt ends \(row?.kind ?? "no row") \(row?.status ?? "")")
        #expect(row?.readTo == nil || row?.readTo == "0", "read_to is \(row?.readTo ?? "nil") on the finished file, expected it cleared")
        let size = DocReader.chunkCharacters
        for number in [0, 39, 40, 79, 80, 99] {
            let hits = outcome.pieceFinds[number] ?? []
            #expect(hits.count == 1, "the word of chunk \(number) found \(hits.count) passages")
            if let hit = hits.first {
                #expect(hit.file == "hundredchunks.txt" && hit.source == "chunk" && hit.start == number * size && hit.end == (number + 1) * size,
                        "chunk \(number) was found in \(hit.file) \(hit.source) at \(hit.start.map(String.init) ?? "nil")..<\(hit.end.map(String.init) ?? "nil"), expected \(number * size)..<\((number + 1) * size)")
            }
        }
        let passages = outcome.passages["hundredchunks.txt"] ?? []
        #expect(passages.filter { $0.source == "chunk" }.count == 100 && passages.filter { $0.source == "name" }.count == 1,
                "hundredchunks.txt passages: \(passages.filter { $0.source == "chunk" }.count) chunks and \(passages.filter { $0.source == "name" }.count) names, expected 100 and 1")
    }

    // MARK: the cached real model

    @Test func withTheCachedRealModelAChunkHasARealVectorOfModalityTextAndTheFilesAreDone() throws {
        let models = try hdModels()
        let world = try AtWorld()
        defer { world.remove() }
        let catText = "Our tabby cat sleeps on the sofa all afternoon, purring softly while the kitten chases a ball of wool across the warm living room floor. Feline pets need fresh water, gentle play and regular visits to the veterinarian to stay happy and healthy for many years."
        let taxText = "The annual tax return lists income, deductions and credits. The revenue authority expects payment of any tax owed before the filing deadline, and late payment adds interest and penalties to the amount due for the tax year."
        let cat = world.photos.path + "/felinecare.txt"
        let tax = world.photos.path + "/taxreturn.md"
        try Data(catText.utf8).write(to: URL(fileURLWithPath: cat))
        try Data(taxText.utf8).write(to: URL(fileURLWithPath: tax))
        try hdAge(cat, 1)
        try hdAge(tax, 2)

        let helper = try hdStartReal(world, mode: "index", arguments: ["--text-model", models.text.path, "--mm-model", models.mm.path])
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 300, cap: 900, until: { $0 == ["done": 2] })
        #expect(wait.met, "the two documents did not both reach done with the real model: \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")
        guard wait.met else { return }

        let db = try #require(world.db())
        let rows = try #require(hdRows(db))
        #expect(rows["felinecare.txt"]?.status == "done" && rows["taxreturn.md"]?.status == "done", "rows: \(hdDescribe(rows))")
        let passages = try #require(hdPassages(db))
        for name in ["felinecare.txt", "taxreturn.md"] {
            let list = passages[name] ?? []
            let chunks = list.filter { $0.source == "chunk" }
            #expect(chunks.count == 1, "\(name): \(chunks.count) chunk passages, expected 1")
            #expect(chunks.allSatisfy { $0.modality == "text" && $0.vecBytes == 1536 },
                    "\(name): a chunk is not text with a 1536 byte vector: \(chunks.map { "\($0.modality ?? "nil") \($0.vecBytes)" })")
            #expect(list.filter { $0.source == "name" }.allSatisfy { $0.vecBytes == -1 }, "\(name): the name passage holds a vector")
        }

        homeLock.lock()
        let previousHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", world.home.path, 1)
        let reader = IndexReader()
        let source = reader.meta("vector_source")
        reader.close()
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        homeLock.unlock()
        #expect(source == LlamaEmbedder.vectorSource, "meta.vector_source is \(source ?? "nil"), expected \(LlamaEmbedder.vectorSource)")
    }
}
}
