import Foundation
import Testing
import SesameEngine

// plan-5-t8, tester step. Written from the entry '### plan-5-t8' of plan-5-tasks.md (Tests: IndexSizeTests), the scenario S6.11 ("the estimate within
// 30 percent and at most 0.05 MB per file on the 500-file mix") and design section 1 (the columns files(path, kind, status, ...),
// passages(id, file_id, source, start, end, modality, vec), fts(name, body)); no product source is read.
//
// What this does: the kit builds the 500-file mix as a child process (`kit-fixtures.sh build mix500`, a throwaway KIT_ROOT, outside the sandbox;
// `kit-fixtures.sh expect listing mix500` says how many supported files it holds), then the bundled release helper alone, with the fake embedder,
// a throwaway HOME and nothing else, indexes the folder `mix500`. When every file has a final row and nothing has changed for a while, the test
// ends the helper's stdin and waits for its exit. Only then, before any SQLite connection of the test is opened, it takes the byte size of
// `index.sqlite` and of its `-wal` file (WAL checkpointed and truncated at close, so the second is expected empty or gone).
//
// The expected values are the entry's, written by hand:
//   - the folder holds 500 supported files: 220 photos, 120 documents, 100 PDFs, 40 audio files, 20 videos (counted by extension here);
//   - the index holds 500 `files` rows, one per file, and every row is `done` or `could_not_read` (the entry);
//   - (bytes of index.sqlite + bytes of index.sqlite-wal) / files count <= 50,000. The bar is 50,000 bytes per file and is never changed here;
//     if it fails the root cause is the product's (what the index stores, the checkpoint at close, an fts5 optimise at the end of a run).
//
// SHAPES THIS FILE PINS that the entry did not fix (each is one number or one line to change):
//   - `done` for at least 475 of the 500 files (95 percent): the entry accepts `could_not_read`, but the mix is built from valid files, and an index
//     in which most files were given up would be small and pass the size bar for the wrong reason. The count of `could_not_read` rows is printed.
//   - `files.kind` words are photo, doc, pdf, audio and video (the kind names of Estimator and of `Walker`), and each kind has at least one vector
//     (fake embedder) and at least one fts row.
//   - the helper exits 0 within 180 s of its stdin ending, `PRAGMA integrity_check` is `ok`, and the `-wal` file is absent or empty.
//   - the walk and the reading may take long with the fake embedder (100 PDFs of up to 12 pages, 40 minutes of speech audio, 10 minutes of video):
//     no tight wall-clock bound; the stall limit is 600 s with no new row, passage or status, and the cap is two hours.
//
// What it prints (read by the person and by the verifier, never asserted):
//   READING index_size ... the two files, the files count, the bytes per file;
//   READING index_size_kind <kind> ... per kind: files, passages, bytes of vectors, bytes of fts name text and fts body text;
//   READING index_size_pages ... the biggest tables or indexes by page bytes when SQLite's dbstat is available.

private let isBar = 50_000

private let isHandCounts: [String: Int] = ["photo": 220, "doc": 120, "pdf": 100, "audio": 40, "video": 20]

private let isExtensions: [String: Set<String>] = [
    "photo": ["jpg", "jpeg", "png", "heic", "webp", "tiff", "tif", "gif"],
    "doc": ["txt", "md", "rtf", "docx", "html", "odt"],
    "pdf": ["pdf"],
    "audio": ["mp3", "m4a", "wav", "aac", "flac"],
    "video": ["mp4", "mov", "m4v"],
]

private struct IsKindSize {
    let kind: String
    let files: Int
    let passages: Int
    let vectorBytes: Int
    let ftsNameBytes: Int
    let ftsBodyBytes: Int
}

private struct IsOutcome {
    var setupProblem: String?
    var onDisk: [String: Int] = [:]
    var onDiskOther = 0
    var listingStatus: Int32?
    var listing = ""
    var filesCount = -1
    var byKindRows: [String: Int] = [:]
    var statuses: [String: Int] = [:]
    var indexBytes = -1
    var walBytes = -1
    var shmBytes = -1
    var perKind: [IsKindSize] = []
    var pages = ""
    var integrity = ""
    var exit: Int32?
    var settled = false
    var summary = ""
    var seconds = 0.0
}

private func isSize(_ path: String) -> Int {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let size = attributes[.size] as? Int else { return -1 }
    return size
}

private func isCountOnDisk(_ folder: String) -> (byKind: [String: Int], other: Int) {
    var byKind: [String: Int] = [:]
    var other = 0
    guard let walker = FileManager.default.enumerator(atPath: folder) else { return (byKind, other) }
    for case let relative as String in walker {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder + "/" + relative, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
        let name = (relative as NSString).lastPathComponent
        if name == ".DS_Store" { continue }
        let ext = (name as NSString).pathExtension.lowercased()
        if let kind = isExtensions.first(where: { $0.value.contains(ext) })?.key { byKind[kind, default: 0] += 1 } else { other += 1 }
    }
    return (byKind, other)
}

private func isPerKind(_ db: AtDB) -> [IsKindSize] {
    var sizes: [String: (files: Int, passages: Int, vec: Int)] = [:]
    for row in db.rows("""
        select f.kind, count(distinct f.id), count(p.id), coalesce(sum(length(p.vec)), 0) \
        from files f left join passages p on p.file_id = f.id group by f.kind
        """) ?? [] {
        sizes[row[0] ?? "?"] = (Int(row[1] ?? "") ?? -1, Int(row[2] ?? "") ?? -1, Int(row[3] ?? "") ?? -1)
    }
    var texts: [String: (name: Int, body: Int)] = [:]
    for row in db.rows("""
        select f.kind, coalesce(sum(length(cast(fts.name as blob))), 0), coalesce(sum(length(cast(fts.body as blob))), 0) \
        from files f join passages p on p.file_id = f.id join fts on fts.rowid = p.id group by f.kind
        """) ?? [] {
        texts[row[0] ?? "?"] = (Int(row[1] ?? "") ?? -1, Int(row[2] ?? "") ?? -1)
    }
    return sizes.keys.sorted().map { kind in
        IsKindSize(kind: kind, files: sizes[kind]?.files ?? 0, passages: sizes[kind]?.passages ?? 0, vectorBytes: sizes[kind]?.vec ?? 0,
                   ftsNameBytes: texts[kind]?.name ?? 0, ftsBodyBytes: texts[kind]?.body ?? 0)
    }
}

private let isOutcome: IsOutcome = {
    var out = IsOutcome()
    let begun = Date()
    guard let kit = MrKit() else { out.setupProblem = "could not make a temp kit root"; return out }
    let built = kit.build("mix500", limit: 3600)
    guard let built, built.status == 0 else {
        out.setupProblem = "kit-fixtures.sh build mix500 failed (status \(built.map { String($0.status) } ?? "not run")): \(mrTail(built?.output ?? "no output"))"
        return out
    }
    let folder = kit.fixtures + "/mix500"
    let counted = isCountOnDisk(folder)
    out.onDisk = counted.byKind
    out.onDiskOther = counted.other
    let script = KitPaths.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path
    if let listing = mrRun("/bin/bash", [script, "expect", "listing", "mix500"], env: kit.env, limit: 300) {
        out.listingStatus = listing.status
        out.listing = listing.output
    }
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    guard let helper = try? atStartHelper(world) else { out.setupProblem = "the bundled helper could not be started (run scripts/bundle.sh)"; return out }
    defer { helper.stop() }
    helper.send(atFoldersLine([URL(fileURLWithPath: folder, isDirectory: true)]))

    let started = Date()
    var lastChange = started
    var lastSignature = ""
    var stableSince: Date?
    var db: AtDB?
    while true {
        if db == nil { db = world.db() }
        if let db,
           let files = db.int("select count(*) from files"),
           let final = db.int("select count(*) from files where status in ('done', 'could_not_read', 'needs_permission')"),
           let passages = db.int("select count(*) from passages") {
            let signature = "\(files)/\(final)/\(passages)"
            if signature != lastSignature { lastSignature = signature; lastChange = Date(); stableSince = nil }
            if files == 500 && final == 500 {
                if stableSince == nil { stableSince = Date() }
                if Date().timeIntervalSince(stableSince!) >= 3 { out.settled = true; break }
            }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > 600 || now.timeIntervalSince(started) > 7200 { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.5)
    }
    out.summary = "settled \(out.settled), files/final/passages \(lastSignature), helper \(helper.isRunning ? "running" : "gone"), stderr: \(helper.errors)"
    db = nil
    helper.closeStdin()
    out.exit = helper.waitForExit(timeout: 180)?.status
    out.indexBytes = isSize(world.indexFile)
    out.walBytes = isSize(world.indexFile + "-wal")
    out.shmBytes = isSize(world.indexFile + "-shm")
    guard let reading = world.db() else { out.setupProblem = "no readable index after the helper exited"; return out }
    out.filesCount = reading.int("select count(*) from files") ?? -1
    for row in reading.rows("select kind, count(*) from files group by kind") ?? [] { out.byKindRows[row[0] ?? "?"] = Int(row[1] ?? "") ?? -1 }
    for row in reading.rows("select status, count(*) from files group by status") ?? [] { out.statuses[row[0] ?? "?"] = Int(row[1] ?? "") ?? -1 }
    out.perKind = isPerKind(reading)
    if let pages = reading.rows("select name, sum(pgsize) from dbstat group by name order by 2 desc limit 12") {
        out.pages = pages.map { "\($0[0] ?? "?")=\($0[1] ?? "?")" }.joined(separator: " ")
    } else {
        out.pages = "dbstat is not available in this SQLite"
    }
    out.integrity = reading.integrity()
    out.seconds = Date().timeIntervalSince(begun)
    return out
}()

private struct IsStop: Error {}

private func isOutcomeOrStop() throws -> IsOutcome {
    let outcome = isOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw IsStop()
    }
    return outcome
}

private func isPrintReading(_ outcome: IsOutcome) {
    let bytes = outcome.indexBytes + max(0, outcome.walBytes)
    let perFile = outcome.filesCount > 0 ? Double(bytes) / Double(outcome.filesCount) : -1
    print("READING index_size index_sqlite=\(outcome.indexBytes) wal=\(outcome.walBytes) shm=\(outcome.shmBytes) files=\(outcome.filesCount) per_file=\(String(format: "%.1f", perFile)) bar=\(isBar) seconds=\(Int(outcome.seconds))")
    for item in outcome.perKind {
        print("READING index_size_kind \(item.kind) files=\(item.files) passages=\(item.passages) vector_bytes=\(item.vectorBytes) fts_name_bytes=\(item.ftsNameBytes) fts_body_bytes=\(item.ftsBodyBytes)")
    }
    print("READING index_size_pages \(outcome.pages)")
    print("READING index_size_status \(outcome.statuses.keys.sorted().map { "\($0)=\(outcome.statuses[$0] ?? 0)" }.joined(separator: " "))")
}

extension EncodeHelperTests {
@Suite("IndexSizeTests", .serialized)
struct IndexSizeTests {

    @Test func theMixHoldsFiveHundredSupportedFilesByTheHandCountAndTheKitsListingAgrees() throws {
        let outcome = try isOutcomeOrStop()
        #expect(outcome.onDisk == isHandCounts, "files on disk by kind \(outcome.onDisk.sorted { $0.key < $1.key }), expected \(isHandCounts.sorted { $0.key < $1.key })")
        #expect(outcome.onDiskOther == 0, "\(outcome.onDiskOther) files of no supported kind in the mix")
        #expect(outcome.onDisk.values.reduce(0, +) == 500, "the folder holds \(outcome.onDisk.values.reduce(0, +)) supported files, expected 500")
        #expect(outcome.listingStatus == 0 && outcome.listing.contains("LISTING OK mix500: 500 paths"),
                "kit-fixtures.sh expect listing mix500 gave status \(outcome.listingStatus.map(String.init) ?? "not run"): \(mrTail(outcome.listing, 2))")
    }

    @Test func everyFileGetsAFinalRowAndTheFilesCountIsTheHandCountOfFiveHundred() throws {
        let outcome = try isOutcomeOrStop()
        #expect(outcome.settled, "the index never settled with 500 final rows: \(outcome.summary)")
        #expect(outcome.filesCount == 500, "the files table holds \(outcome.filesCount) rows, expected 500; \(outcome.summary)")
        #expect(outcome.byKindRows == isHandCounts, "rows by kind \(outcome.byKindRows.sorted { $0.key < $1.key }), expected \(isHandCounts.sorted { $0.key < $1.key })")
        let other = outcome.statuses.filter { $0.key != "done" && $0.key != "could_not_read" }
        #expect(other.isEmpty, "rows in a state that is neither done nor could_not_read: \(other.sorted { $0.key < $1.key })")
        let done = outcome.statuses["done"] ?? 0
        #expect(done >= 475, "only \(done) of 500 files are done (could_not_read \(outcome.statuses["could_not_read"] ?? 0)): the mix is made of valid files")
        isPrintReading(outcome)
    }

    @Test func theIndexAndItsWalFileTogetherAreAtMostFiftyThousandBytesPerFile() throws {
        let outcome = try isOutcomeOrStop()
        isPrintReading(outcome)
        #expect(outcome.indexBytes > 0, "index.sqlite is \(outcome.indexBytes) bytes after the helper exited")
        #expect(outcome.filesCount > 0, "the files table holds \(outcome.filesCount) rows")
        guard outcome.indexBytes > 0, outcome.filesCount > 0 else { return }
        let bytes = outcome.indexBytes + max(0, outcome.walBytes)
        let perFile = Double(bytes) / Double(outcome.filesCount)
        #expect(perFile <= Double(isBar), "the index takes \(String(format: "%.0f", perFile)) bytes per file (index.sqlite \(outcome.indexBytes) plus -wal \(outcome.walBytes), over \(outcome.filesCount) files); the bar is \(isBar)")
    }

    @Test func theIndexIsWholeTheWalFileIsEmptyOrGoneAndTheHelperExitsZero() throws {
        let outcome = try isOutcomeOrStop()
        #expect(outcome.exit == 0, "the helper should exit 0 within 180 s of its stdin ending, status \(outcome.exit.map(String.init) ?? "still running")")
        #expect(outcome.walBytes <= 0, "the -wal file holds \(outcome.walBytes) bytes after the helper exited: the WAL was not checkpointed and truncated at close")
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
    }

    @Test func everyKindHasVectorsAndFtsTextAndThePerKindBytesArePrinted() throws {
        let outcome = try isOutcomeOrStop()
        isPrintReading(outcome)
        for kind in ["photo", "doc", "pdf", "audio", "video"] {
            let item = outcome.perKind.first { $0.kind == kind }
            #expect(item != nil && item!.files == isHandCounts[kind], "\(kind): \(item.map { "\($0.files) files" } ?? "no files"), expected \(isHandCounts[kind] ?? 0)")
            #expect((item?.vectorBytes ?? 0) > 0, "\(kind): no vector bytes in the index (fake embedder)")
            #expect((item?.ftsNameBytes ?? 0) + (item?.ftsBodyBytes ?? 0) > 0, "\(kind): no fts text in the index")
        }
    }
}
}
