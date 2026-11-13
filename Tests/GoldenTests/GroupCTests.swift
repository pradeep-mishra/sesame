import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-4-t9, tester step. The group c golden test (spec S2(c), S2.4) and the whole-folder parts of S2.2, S2.3, S2.8 and S2.17
// that the photo-only sealed tests cannot hold. Written from the t9 entry and Conventions of plan-4-tasks.md, GroupATests,
// GroupBTests, MergeTests and ExtensionsTests for the rigs, the answer key fixtures/answers.csv, scripts/kit-lib/golden-docs.tsv
// and gate-matrix.csv; no product source read. Every expected value is the key's or hand-written here (the row table, the
// pages, the eleven exact ids, the nonsense strings, the matrix cells, the file counts); none is computed from the code under test.
//
// Through the engine's public interface: `scripts/kit-golden.sh prepare --whole` (a child process) makes the index of
// golden/photos and golden-docs with the bundled helper and the cached real model and prints its path; `IndexReader` opens it;
// `LlamaEmbedder` (the cached text model) embeds each query; `Search.rank` ranks; the page of a PDF hit is `passages.start` of
// `Hit.passageID`, read with this file's own read-only SQLite connection (the column is REAL: cast to integer).
//
// What it checks:
//   group c (S2.4)   10 `pdf` rows: the right PDF in the first 3 for at least 9 and the page of its best passage right for at
//                    least 9; 6 `doc` rows: the right document in the first 3 for at least 5; the `scanned` row: the scanned PDF
//                    in the first 3 with its page. It prints `GOLDEN <id> rank <n|none> page <p|none>` for every row (the line
//                    `kit-golden.sh engine --group c` reads), writes the rows to golden-engine.tsv (the 8th column is the page)
//                    and reports the odd and even rows apart (`noted: overfitting risk`, as in plan 3; never a failure).
//   S2.2 / S3.1      the 11 readable exact rows whose file is a PDF or a document are first on the whole-folder index.
//   S2.3             strings of two, three and four words that are in no file find no row of golden-docs (no PDF, no document).
//                    The single-token `missing` row is reported, not asserted: S2.3 says it shows the closest files by meaning.
//   S2.8             in a copy of golden and golden-docs in the test's own temp folder (never the shared ones), after
//                    `kit-fixtures.sh build unrelated 1000` is indexed beside it none of the 11 moves from first; after one PDF
//                    is deleted from the copy and a fresh helper reconciles, that PDF is no longer listed.
//   S2.17            each `extdoc-` cell of the matrix (txt, md, rtf, docx, html, odt, pdf), built in a temp kit root and indexed
//                    alone as ExtensionsTests does with matrix/ext, is `done` and found first by its name stem.
//   D8 guard         the scanned pages are `image` modality and share the image gate with photos. The ten group a rows and the six
//                    photo exact rows are ranked on the whole-folder index too (the bars of GroupATests and GroupBTests, never
//                    lowered); a red test here is the STOP-ASK of the entry, naming the row.
//
// It never skips: a missing model, bundle, helper or index is a failure that names the missing piece.

// MARK: the hand-written rows

private struct Wanted: Sendable {
    let id: String
    let group: String
    let file: String         // under golden-docs
    let page: Int?           // the page that holds the passage (pdf and scanned rows)
}

/// The 17 rows of group c, written by hand from the spec's examples and the key; the key is checked against them.
private let groupCRows: [Wanted] = [
    Wanted(id: "pdf-01", group: "pdf", file: "pdfs/lease-2024.pdf", page: 7),
    Wanted(id: "pdf-02", group: "pdf", file: "pdfs/employee-handbook.pdf", page: 5),
    Wanted(id: "pdf-03", group: "pdf", file: "pdfs/warranty-maple-street.pdf", page: 3),
    Wanted(id: "pdf-04", group: "pdf", file: "pdfs/tax-return-2025-draft.pdf", page: 4),
    Wanted(id: "pdf-05", group: "pdf", file: "pdfs/insurance-policy.pdf", page: 4),
    Wanted(id: "pdf-06", group: "pdf", file: "pdfs/car-service-report.pdf", page: 2),
    Wanted(id: "pdf-07", group: "pdf", file: "pdfs/recipe-collection.pdf", page: 6),
    Wanted(id: "pdf-08", group: "pdf", file: "pdfs/conference-schedule.pdf", page: 3),
    Wanted(id: "pdf-09", group: "pdf", file: "pdfs/dishwasher-manual.pdf", page: 9),
    Wanted(id: "pdf-10", group: "pdf", file: "pdfs/boarding-pass.pdf", page: 1),
    Wanted(id: "doc-01", group: "doc", file: "docs/field-notes.txt", page: nil),
    Wanted(id: "doc-02", group: "doc", file: "docs/field-notes.md", page: nil),
    Wanted(id: "doc-03", group: "doc", file: "docs/shipping-update.html", page: nil),
    Wanted(id: "doc-04", group: "doc", file: "docs/meeting-minutes-2026-02-19.docx", page: nil),
    Wanted(id: "doc-05", group: "doc", file: "docs/budget-2026.odt", page: nil),
    Wanted(id: "doc-06", group: "doc", file: "docs/todo-list.rtf", page: nil),
    Wanted(id: "scanned-01", group: "scanned", file: "pdfs/scanned-receipt.pdf", page: 2),
]

/// The 11 readable exact rows whose file is a PDF or a document (spec S2.2; the entry names them).
private let exactRows: [(id: String, file: String)] = [
    ("exact-05", "pdfs/invoice-2026-04417.pdf"),
    ("exact-06", "pdfs/Q3-board-deck.pdf"),
    ("exact-11", "docs/field-notes.txt"),
    ("exact-12", "docs/field-notes.md"),
    ("exact-13", "docs/shipping-update.html"),
    ("exact-14", "pdfs/employee-handbook.pdf"),
    ("exact-15", "pdfs/boarding-pass.pdf"),
    ("exact-16", "pdfs/tax-return-2025-draft.pdf"),
    ("exact-17", "docs/meeting-minutes-2026-02-19.docx"),
    ("exact-18", "docs/budget-2026.odt"),
    ("exact-19", "pdfs/warranty-maple-street.pdf"),
]

/// Words in no file name and no text of the golden folders: two, three and four tokens (the same made-up words GroupBTests uses).
private let nonsense: [(words: Int, text: String)] = [
    (2, "flurbo wazzik"), (2, "mrrgl tszzkq"),
    (3, "glorp snazzle quibbet"), (3, "yepnoh vlorbx drazzit"),
    (4, "blorf tszzk yepnoh vlimmer"), (4, "quazzle frimbo oglax dwemp"),
]

/// The cells of the table for the PDF and the document extensions, written by hand from the spec's lists.
private let extdocCells = ["extdoc-txt", "extdoc-md", "extdoc-rtf", "extdoc-docx", "extdoc-html", "extdoc-odt", "extdoc-pdf"]

/// The whole-folder index: 40 photos, 20 PDFs (the locked and the damaged one are rows too) and 6 documents, written by hand.
private let wholeFileCount = 40 + 20 + 6

/// The file the removal stage deletes from the copy: the PDF of exact-15 (and of pdf-10).
private let removedFile = "pdfs/boarding-pass.pdf"

// MARK: the key

private struct Key: Sendable {
    let id: String
    let group: String
    let query: String
    let file: String
    let locator: String
}

/// Every row of fixtures/answers.csv: `id,group,query,file,locator,window_s,note`, no comma inside a field.
private func keyRows() throws -> [Key] {
    let url = GB.projectRoot.appendingPathComponent("fixtures/answers.csv")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw GBFailure("fixtures/answers.csv is missing: \(url.path)")
    }
    var rows: [Key] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5 else { continue }
        rows.append(Key(id: f[0], group: f[1], query: f[2], file: f[3], locator: f[4]))
    }
    return rows
}

/// The key must say what the hand-written tables say; a drift is a failure, not a changed expectation.
private func checkedKey(_ key: [Key]) throws -> (c: [(wanted: Wanted, query: String)], exact: [(id: String, file: String, query: String)]) {
    var c: [(wanted: Wanted, query: String)] = []
    for row in groupCRows {
        guard let k = key.first(where: { $0.id == row.id }) else { throw GBFailure("the key has no row \(row.id)") }
        guard k.group == row.group, k.file == row.file else {
            throw GBFailure("\(row.id): the key says group \(k.group) file \(k.file), expected \(row.group) \(row.file)")
        }
        if let page = row.page, k.locator != String(page) {
            throw GBFailure("\(row.id): the key's locator is \(k.locator), expected page \(page)")
        }
        c.append((row, k.query))
    }
    var exact: [(id: String, file: String, query: String)] = []
    for row in exactRows {
        guard let k = key.first(where: { $0.id == row.id }) else { throw GBFailure("the key has no row \(row.id)") }
        guard k.group == "exact", k.file == row.file else {
            throw GBFailure("\(row.id): the key says group \(k.group) file \(k.file), expected exact \(row.file)")
        }
        exact.append((row.id, row.file, k.query))
    }
    return (c, exact)
}

// MARK: ranking and the passage read

private struct Ranked: Sendable {
    let path: String
    let passageID: Int64?
}

private func int64(_ value: Any) -> Int64? {
    if let v = value as? Int64 { return v }
    if let v = value as? Int { return Int64(v) }
    return nil
}

private func rankHits(_ search: Search, _ text: String, _ vector: [Float], _ visible: Visible) -> [Ranked] {
    let ticket = search.newTicket()
    guard let hits = search.rank(text: text, vector: vector, ticket: ticket, visible: visible) else { return [] }
    return hits.map { Ranked(path: $0.path, passageID: int64($0.passageID)) }
}

/// A read-only connection to the index; `passages.start` is a REAL column, read as an integer.
private final class PassageReader: @unchecked Sendable {
    private var db: OpaquePointer?

    init?(home: String) {
        guard sqlite3_open_v2(GB.indexFile(home: home), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close_v2(db) }

    /// The source (`page`, `chunk`, `name`) and the integer start of a passage, nil for an unknown id.
    func passage(_ id: Int64) -> (source: String, start: Int?)? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select source, cast(start as integer) from passages where id = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW, let source = sqlite3_column_text(statement, 0) else { return nil }
        let start: Int? = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 1))
        return (String(cString: source), start)
    }

    /// The page a PDF hit names: the start of its best passage when that passage is a `page` passage.
    func page(of hit: Ranked) -> Int? {
        guard let id = hit.passageID, let found = passage(id), found.source == "page" else { return nil }
        return found.start
    }
}

// MARK: settling a helper (pending and partial both count as open work)

/// Like GB.settle, but a `partial` row (the later steps of a long PDF) is open work too: the 60-page scanned PDF is `partial`
/// for minutes after its first 30 pages, with no row changing.
private func settleDone(home: String, helper: GBHelper, rows expected: Int, stall: TimeInterval, cap: TimeInterval) -> GB.Settled {
    let started = Date()
    var lastChange = Date()
    var last = ""
    var rows: [(path: String, status: String)] = []
    while Date().timeIntervalSince(started) < cap {
        if let read = GB.indexRows(home: home) {
            rows = read
            let key = rows.map { "\($0.path)|\($0.status)" }.sorted().joined(separator: "\n")
            if key != last { last = key; lastChange = Date() }
            let open = rows.filter { $0.status == "pending" || $0.status == "partial" }.count
            if rows.count == expected && open == 0 && Date().timeIntervalSince(lastChange) >= 3 {
                return GB.Settled(ok: true, note: "", rows: rows)
            }
        }
        if !helper.isRunning {
            Thread.sleep(forTimeInterval: 0.3)
            return GB.Settled(ok: false, note: "the helper exited with \(rows.count) rows (want \(expected)); stderr: \(helper.stderrText.suffix(400))", rows: rows)
        }
        if Date().timeIntervalSince(lastChange) > stall {
            let open = rows.filter { $0.status == "pending" || $0.status == "partial" }.count
            return GB.Settled(ok: false, note: "no change for \(Int(stall)) s: \(rows.count) rows (want \(expected)), open \(open); stderr: \(helper.stderrText.suffix(400))", rows: rows)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return GB.Settled(ok: false, note: "no settled index within \(Int(cap)) s: \(rows.count) rows (want \(expected))", rows: rows)
}

// MARK: the whole-folder index and its readings

private struct Reading: Sendable {
    let wanted: Wanted
    let query: String
    let rank: Int?
    let page: Int?
    let source: String       // the source of the best passage of the expected file's hit, for the messages
    let list: [String]

    var first3: Bool { (rank ?? 99) <= 3 }
    var pageRight: Bool { rank != nil && page != nil && page == wanted.page }
}

private struct ExactReading: Sendable {
    let id: String
    let file: String
    let query: String
    let rank: Int?
    let list: [String]
}

private struct PhotoReading: Sendable {
    let id: String
    let file: String
    let rank: Int?
}

nonisolated(unsafe) private var gcExitContext: GCContext?

/// The whole-folder index made once by `kit-golden.sh prepare --whole`, and every ranked list the group c tests read.
private final class GCContext: @unchecked Sendable {
    let kit: URL
    let home: String
    let models: (text: URL, mm: URL)
    let reader: IndexReader
    let search: Search
    let embedder: LlamaEmbedder
    let visible: Visible
    let passages: PassageReader
    private var vectors: [String: [Float]] = [:]

    var readings: [Reading] = []
    var exact: [ExactReading] = []
    var photosA: [PhotoReading] = []
    var photosExact: [PhotoReading] = []
    /// per nonsense string: the paths it returned
    var nonsenseLists: [(text: String, paths: [String])] = []
    var missingText = ""
    var missingPaths: [String] = []
    var evidenceTSV = ""

    init(kit: URL, home: String, models: (text: URL, mm: URL), reader: IndexReader, embedder: LlamaEmbedder, passages: PassageReader,
         folders: [String]) {
        self.kit = kit
        self.home = home
        self.models = models
        self.reader = reader
        self.search = Search(reader: reader)
        self.embedder = embedder
        self.passages = passages
        self.visible = GB.visible(folders)
    }

    static let shared: Result<GCContext, GBFailure> = {
        do { return .success(try build()) } catch let failure as GBFailure { return .failure(failure) } catch {
            return .failure(GBFailure("\(error)"))
        }
    }()

    /// The query vector from the cached text model, embedded once per text.
    func vector(_ text: String) throws -> [Float] {
        if let known = vectors[text] { return known }
        let made = try embedder.embed(text, role: .query)
        vectors[text] = made
        return made
    }

    func ranked(_ text: String) throws -> [Ranked] {
        rankHits(search, text, try vector(text), visible)
    }

    private static func build() throws -> GCContext {
        let key = try keyRows()
        let checked = try checkedKey(key)
        guard let kit = GB.kitRoot() else { throw GBFailure("no KIT_ROOT and no TMPDIR: cannot find the kit") }
        let models = try GB.models(kit: kit)

        // The index of golden/photos and golden-docs, made by the bundled helper through the kit (minutes: the 60-page scanned
        // PDF is read by the helper on its own, page picture by page picture).
        let prepared = GB.withGoldenLock(kit) {
            GB.runChild("/bin/bash", [GB.projectRoot.appendingPathComponent("scripts/kit-golden.sh").path, "prepare", "--whole"],
                        cwd: GB.projectRoot, limit: 10800)
        }
        guard let prepare = prepared else { throw GBFailure("scripts/kit-golden.sh could not be run") }
        guard prepare.status == 0 else {
            throw GBFailure("kit-golden.sh prepare --whole exited \(prepare.status): \(GB.tail(prepare.output))")
        }
        let lastLine = prepare.output.split(separator: "\n").last.map(String.init) ?? ""
        let suffix = "/Library/Application Support/Sesame/index.sqlite"
        guard lastLine.hasPrefix("/"), lastLine.hasSuffix(suffix) else {
            throw GBFailure("kit-golden.sh prepare --whole did not end with the index path: \(GB.tail(prepare.output))")
        }
        guard FileManager.default.fileExists(atPath: lastLine) else { throw GBFailure("the index is missing: \(lastLine)") }
        let home = String(lastLine.dropLast(suffix.count))

        let opened = GB.openReader(home: home, files: wholeFileCount)
        guard let reader = opened.reader else {
            throw GBFailure("the index at \(lastLine) holds \(opened.count) files, expected \(wholeFileCount): the 40 golden photos, 20 PDFs and 6 documents")
        }
        guard let passages = PassageReader(home: home) else { throw GBFailure("the index at \(lastLine) cannot be opened read-only") }
        let embedder = LlamaEmbedder(textModel: models.text)
        try embedder.load()
        let golden = kit.appendingPathComponent("fixtures/golden", isDirectory: true).path
        let docs = kit.appendingPathComponent("fixtures/golden-docs", isDirectory: true).path
        let context = GCContext(kit: kit, home: home, models: models, reader: reader, embedder: embedder, passages: passages,
                                folders: [golden, docs])
        // The model stays loaded for the whole run; ggml aborts at process exit when its Metal device is freed while a model is
        // still loaded, so an exit handler registered after the load unloads it (handlers run last in, first out).
        gcExitContext = context
        atexit {
            gcExitContext?.search.release()
            gcExitContext?.embedder.unload()
            gcExitContext?.reader.close()
        }

        // group c
        for (wanted, query) in checked.c {
            let hits = try context.ranked(query)
            let paths = hits.map(\.path)
            let place = GB.place(of: wanted.file, in: paths, folder: "golden-docs")
            let hit = place.map { hits[$0 - 1] }
            let page = hit.flatMap { context.passages.page(of: $0) }
            let source = hit?.passageID.flatMap { context.passages.passage($0)?.source } ?? "none"
            context.readings.append(Reading(wanted: wanted, query: query, rank: place, page: page, source: source, list: paths))
            print("GOLDEN \(wanted.id) rank \(place.map(String.init) ?? "none") page \(page.map(String.init) ?? "none")")
        }

        // the 11 exact rows of a PDF or a document
        for (id, file, query) in checked.exact {
            let paths = try context.ranked(query).map(\.path)
            let place = GB.place(of: file, in: paths, folder: "golden-docs")
            context.exact.append(ExactReading(id: id, file: file, query: query, rank: place, list: paths))
            print("EXACT \(id) rank \(place.map(String.init) ?? "none")")
        }

        // the photos on the whole-folder index (D8)
        for row in key where row.group == "photo" {
            let paths = try context.ranked(row.query).map(\.path)
            let place = GB.place(of: row.file, in: paths)
            context.photosA.append(PhotoReading(id: row.id, file: row.file, rank: place))
            print("PHOTO \(row.id) rank \(place.map(String.init) ?? "none")")
        }
        for answer in try GB.readableExact() {
            let paths = try context.ranked(answer.query).map(\.path)
            let place = GB.place(of: answer.file, in: paths)
            context.photosExact.append(PhotoReading(id: answer.id, file: answer.file, rank: place))
            print("PHOTO \(answer.id) rank \(place.map(String.init) ?? "none")")
        }

        // strings in no file
        for (words, text) in nonsense {
            let paths = try context.ranked(text).map(\.path)
            context.nonsenseLists.append((text, paths))
            let docRows = paths.filter { $0.contains("/golden-docs/") }.count
            print("NONSENSE words \(words) \"\(text)\" rows \(paths.count) golden-docs rows \(docRows)")
        }
        if let missing = key.first(where: { $0.group == "missing" }) {
            context.missingText = missing.query
            context.missingPaths = try context.ranked(missing.query).map(\.path)
            let docRows = context.missingPaths.filter { $0.contains("/golden-docs/") }.count
            print("MISSING \"\(missing.query)\" rows \(context.missingPaths.count) golden-docs rows \(docRows)")
        }

        context.evidenceTSV = try writeGroupC(kit: kit, readings: context.readings)
        let pdf = context.readings.filter { $0.wanted.group == "pdf" }
        let doc = context.readings.filter { $0.wanted.group == "doc" }
        let scanned = context.readings.first { $0.wanted.group == "scanned" }
        print("GOLDEN engine group c: pdf first-3 \(pdf.filter(\.first3).count) of \(pdf.count), page right \(pdf.filter(\.pageRight).count) of \(pdf.count); doc first-3 \(doc.filter(\.first3).count) of \(doc.count); scanned first-3 \(scanned?.first3 == true ? "yes" : "no"); wrote \(context.evidenceTSV)")
        return context
    }
}

private func contextOrThrow() throws -> GCContext {
    switch GCContext.shared {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

/// golden-engine.tsv: the rows of group c replace the old ones, the rows of other groups stay; the 8th column is the page.
private func writeGroupC(kit: URL, readings: [Reading]) throws -> String {
    let folder = GB.evidenceFolder(kit)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let tsv = folder.appendingPathComponent("golden-engine.tsv")
    var kept: [String] = []
    if let old = try? String(contentsOf: tsv, encoding: .utf8) {
        for (index, line) in old.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count > 1, fields[1] != "c" { kept.append(String(line)) }
        }
    }
    var out = "id\tgroup\tquery\texpected\trank\tlocator\tpass\tpage\n"
    for line in kept { out += line + "\n" }
    for r in readings {
        let locator = r.wanted.page.map(String.init) ?? ""
        out += "\(r.wanted.id)\tc\t\(r.query)\t\(r.wanted.file)\t\(r.rank.map(String.init) ?? "none")\t\(locator)\t\(GB.passWord(r.rank))\t\(r.page.map(String.init) ?? "none")\n"
    }
    try Data(out.utf8).write(to: tsv, options: .atomic)
    return tsv.path
}

private func describe(_ r: Reading) -> String {
    "\(r.wanted.id) \"\(r.query)\" want \(r.wanted.file)\(r.wanted.page.map { " page \($0)" } ?? "") rank \(r.rank.map(String.init) ?? "none") page \(r.page.map(String.init) ?? "none") (best passage \(r.source); list \(r.list.prefix(5).map { ($0 as NSString).lastPathComponent }))"
}

// MARK: the copy, the 1,000 unrelated photos and the removal

private struct StageResult: Sendable {
    let rowCount: Int
    let statuses: [String: Int]
    /// query id to the ranked paths
    let lists: [String: [String]]
}

private final class MergeRun: @unchecked Sendable {
    var stages: [String: StageResult] = [:]
    var failure: String?
    var sharedFileStillThere = false
    var unrelatedBuilt = 0

    static let shared = MergeRun.perform()

    func stage(_ name: String) throws -> StageResult {
        if let found = stages[name] { return found }
        throw GBFailure("stage \(name) did not run: \(failure ?? "no reason recorded")")
    }

    private static func perform() -> MergeRun {
        let outcome = MergeRun()
        do { try outcome.run() } catch let failure as GBFailure { outcome.failure = failure.description } catch {
            outcome.failure = "\(error)"
        }
        return outcome
    }

    /// The queries every stage ranks: the 11 exact strings and the boarding pass description (pdf-10, same file as exact-15).
    private func queries(_ ctx: GCContext) throws -> [(id: String, text: String)] {
        let key = try keyRows()
        let checked = try checkedKey(key)
        var out = checked.exact.map { (id: $0.id, text: $0.query) }
        guard let pdf10 = checked.c.first(where: { $0.wanted.id == "pdf-10" }) else { throw GBFailure("no pdf-10 row") }
        out.append((id: "pdf-10", text: pdf10.query))
        return out
    }

    private func take(_ name: String, ctx: GCContext, home: String, folders: [String], files: Int, settled: GB.Settled) throws {
        var statuses: [String: Int] = [:]
        for row in settled.rows { statuses[row.status, default: 0] += 1 }
        let opened = GB.openReader(home: home, files: files)
        guard let reader = opened.reader else { throw GBFailure("stage \(name): the index holds \(opened.count) files, expected \(files)") }
        defer { reader.close() }
        let search = Search(reader: reader)
        defer { search.release() }
        let visible = GB.visible(folders)
        var lists: [String: [String]] = [:]
        for q in try queries(ctx) {
            lists[q.id] = rankHits(search, q.text, try ctx.vector(q.text), visible).map(\.path)
        }
        stages[name] = StageResult(rowCount: settled.rows.count, statuses: statuses, lists: lists)
    }

    private func run() throws {
        let ctx = try contextOrThrow()
        let kit = ctx.kit
        guard FileManager.default.isExecutableFile(atPath: GB.bundledHelper.path) else {
            throw GBFailure("the bundled helper is missing: run `scripts/bundle.sh` (expected \(GB.bundledHelper.path))")
        }
        let work = GB.realpathOf(FileManager.default.temporaryDirectory.appendingPathComponent("sesame-groupc-" + UUID().uuidString).path)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        let home = work + "/home"
        try GB.makeSupportFolder(home: home)

        // golden and golden-docs, copied under the lock; the shared fixtures are never written to (build is a no-op when right).
        let sharedGolden = kit.appendingPathComponent("fixtures/golden")
        let sharedDocs = kit.appendingPathComponent("fixtures/golden-docs")
        for mode in ["golden", "golden-docs"] {
            let built = GB.withGoldenLock(kit) {
                GB.runChild("/bin/bash", [GB.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", mode],
                            env: ["KIT_ROOT": kit.path], limit: 1800)
            }
            guard let result = built, result.status == 0 else {
                throw GBFailure("kit-fixtures.sh build \(mode) failed: \(GB.tail(built?.output ?? "not started"))")
            }
        }
        let copyRoot = work + "/copy"
        let copyGolden = copyRoot + "/golden"
        let copyDocs = copyRoot + "/golden-docs"
        try FileManager.default.createDirectory(atPath: copyRoot, withIntermediateDirectories: true)
        try GB.withGoldenLock(kit) {
            try FileManager.default.copyItem(atPath: sharedGolden.path, toPath: copyGolden)
            try FileManager.default.copyItem(atPath: sharedDocs.path, toPath: copyDocs)
        }

        // 1,000 unrelated photos in a temp kit root of their own.
        let tempKit = work + "/sesame-kit-groupc"
        let tmp = work + "/tmp"
        let decoyHome = work + "/decoy-home"
        for dir in [tempKit + "/run", tmp, decoyHome] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let env = ["KIT_ROOT": tempKit, "TMPDIR": tmp + "/", "HOME": decoyHome,
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        let unrelatedBuild = GB.runChild("/bin/bash",
                                         [GB.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", "unrelated", "1000"],
                                         env: env, limit: 1800)
        guard let unrelated = unrelatedBuild, unrelated.status == 0 else {
            throw GBFailure("kit-fixtures.sh build unrelated 1000 failed: \(GB.tail(unrelatedBuild?.output ?? "not started"))")
        }
        let unrelatedRoot = tempKit + "/fixtures/unrelated"
        unrelatedBuilt = (try? FileManager.default.contentsOfDirectory(atPath: unrelatedRoot))?.filter { $0.hasPrefix("unrel") }.count ?? 0
        guard unrelatedBuilt == 1000 else { throw GBFailure("build unrelated 1000 made \(unrelatedBuilt) photos in \(unrelatedRoot)") }

        // Stage 1: real models over the copy of the two folders.
        do {
            let helper = try GBHelper(home: home, models: ctx.models, scratch: URL(fileURLWithPath: work))
            defer { helper.stop() }
            helper.sendFolders([copyGolden, copyDocs])
            let settled = settleDone(home: home, helper: helper, rows: wholeFileCount, stall: 1200, cap: 7200)
            guard settled.ok else { throw GBFailure("stage 1 (copy of golden and golden-docs, real models): \(settled.note)") }
            helper.stop()
            try take("1", ctx: ctx, home: home, folders: [copyGolden, copyDocs], files: wholeFileCount, settled: settled)
        }

        // Stage 2: the 1,000 unrelated photos beside it, fake embedder.
        do {
            let helper = try GBHelper(home: home, models: nil, scratch: URL(fileURLWithPath: work))
            defer { helper.stop() }
            helper.sendFolders([copyGolden, copyDocs, unrelatedRoot])
            let settled = settleDone(home: home, helper: helper, rows: wholeFileCount + 1000, stall: 900, cap: 3600)
            guard settled.ok else { throw GBFailure("stage 2 (1,000 unrelated photos added): \(settled.note)") }
            helper.stop()
            try take("2", ctx: ctx, home: home, folders: [copyGolden, copyDocs, unrelatedRoot], files: wholeFileCount + 1000, settled: settled)
        }

        // Stage 3: one PDF deleted from the copy, a fresh helper reconciles.
        let victim = copyDocs + "/" + removedFile
        guard FileManager.default.fileExists(atPath: victim) else { throw GBFailure("setup: \(victim) is not in the copy") }
        try FileManager.default.removeItem(atPath: victim)
        sharedFileStillThere = FileManager.default.fileExists(atPath: sharedDocs.path + "/" + removedFile)
        do {
            let helper = try GBHelper(home: home, models: nil, scratch: URL(fileURLWithPath: work))
            defer { helper.stop() }
            helper.sendFolders([copyGolden, copyDocs, unrelatedRoot])
            let settled = settleDone(home: home, helper: helper, rows: wholeFileCount + 1000 - 1, stall: 900, cap: 1800)
            guard settled.ok else { throw GBFailure("stage 3 (one PDF deleted): \(settled.note)") }
            helper.stop()
            try take("3", ctx: ctx, home: home, folders: [copyGolden, copyDocs, unrelatedRoot], files: wholeFileCount + 1000 - 1, settled: settled)
        }
    }
}

// MARK: the extdoc cells

private struct ExtDocCell: Sendable {
    let cell: String
    let path: String          // under matrix/
    var file: String { (path as NSString).lastPathComponent }
    var stem: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    var ext: String { (path as NSString).pathExtension }
}

private struct ExtDocOutcome: Sendable {
    let cells: [ExtDocCell]
    let statuses: [String: String]
    let rowCount: Int
    let lists: [String: [String]]
}

private final class ExtDocRun: @unchecked Sendable {
    static let shared: Result<ExtDocOutcome, GBFailure> = {
        do { return .success(try perform()) } catch let failure as GBFailure { return .failure(failure) } catch {
            return .failure(GBFailure("\(error)"))
        }
    }()

    /// The `extdoc-*` rows of the table: `cell,path,picks,expected_in_index,expected_rows,expected_reason,group`.
    private static func tableCells() throws -> [ExtDocCell] {
        let url = GB.projectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GBFailure("scripts/kit-lib/gate-matrix.csv is missing: \(url.path)")
        }
        var cells: [ExtDocCell] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7, f[0].hasPrefix("extdoc-") else { continue }
            guard f[3] == "yes", f[4] == "1" else { throw GBFailure("the table's cell \(f[0]) is not a read cell: \(line)") }
            cells.append(ExtDocCell(cell: f[0], path: f[1]))
        }
        return cells
    }

    private static func perform() throws -> ExtDocOutcome {
        let cells = try tableCells()
        guard cells.map(\.cell) == extdocCells else {
            throw GBFailure("the table's extdoc cells are \(cells.map(\.cell)), expected \(extdocCells)")
        }
        let ctx = try contextOrThrow()
        guard FileManager.default.isExecutableFile(atPath: GB.bundledHelper.path) else {
            throw GBFailure("the bundled helper is missing: run `scripts/bundle.sh` (expected \(GB.bundledHelper.path))")
        }

        let work = GB.realpathOf(FileManager.default.temporaryDirectory.appendingPathComponent("sesame-extdoc-" + UUID().uuidString).path)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        // The matrix in a temp kit root.
        let tempKit = work + "/sesame-kit-extdoc"
        let tmp = work + "/tmp"
        let decoyHome = work + "/decoy-home"
        for dir in [tempKit + "/run", tmp, decoyHome] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let env = ["KIT_ROOT": tempKit, "TMPDIR": tmp + "/", "HOME": decoyHome,
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        let build = GB.runChild("/bin/bash", [GB.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", "matrix"],
                                env: env, limit: 1800)
        guard let built = build, built.status == 0 else {
            throw GBFailure("kit-fixtures.sh build matrix failed: \(GB.tail(build?.output ?? "not started"))")
        }
        let folder = tempKit + "/fixtures/matrix/extdoc"
        for cell in cells {
            let file = tempKit + "/fixtures/matrix/" + cell.path
            guard FileManager.default.fileExists(atPath: file) else { throw GBFailure("cell \(cell.cell): \(file) was not built") }
        }

        // The helper alone, fake embedder, over matrix/extdoc.
        let home = work + "/home"
        try GB.makeSupportFolder(home: home)
        let helper = try GBHelper(home: home, models: nil, scratch: URL(fileURLWithPath: work))
        defer { helper.stop() }
        helper.sendFolders([folder])
        let settled = settleDone(home: home, helper: helper, rows: cells.count, stall: 300, cap: 900)
        guard settled.ok else { throw GBFailure("indexing \(folder): \(settled.note)") }
        helper.stop()

        var statuses: [String: String] = [:]
        for cell in cells { statuses[cell.cell] = settled.rows.first { $0.path.hasSuffix("/" + cell.file) }?.status ?? "" }

        let opened = GB.openReader(home: home, files: cells.count)
        guard let reader = opened.reader else { throw GBFailure("the index holds \(opened.count) files, expected \(cells.count)") }
        defer { reader.close() }
        let search = Search(reader: reader)
        defer { search.release() }
        let visible = GB.visible([folder])
        var lists: [String: [String]] = [:]
        for cell in cells {
            lists[cell.cell] = rankHits(search, cell.stem, try ctx.vector(cell.stem), visible).map(\.path)
        }
        return ExtDocOutcome(cells: cells, statuses: statuses, rowCount: settled.rows.count, lists: lists)
    }
}

private func extDocOutcome() throws -> ExtDocOutcome {
    switch ExtDocRun.shared {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

private func rank(_ file: String, in paths: [String]) -> Int? {
    GB.place(of: file, in: paths, folder: "golden-docs")
}

// MARK: the suite

@Suite("GroupCTests", .serialized)
struct GroupCTests {

    // S2.4: the PDF passage descriptions

    @Test func theRightPdfIsInTheFirstThreeForAtLeastNineOfTheTenPdfDescriptions() throws {
        let ctx = try contextOrThrow()
        let pdf = ctx.readings.filter { $0.wanted.group == "pdf" }
        try #require(pdf.count == 10, "\(pdf.count) pdf rows were ranked, expected 10")
        let inFirst3 = pdf.filter(\.first3).count
        let detail = pdf.filter { !$0.first3 }.map(describe)
        #expect(inFirst3 >= 9, "the right PDF was within the first 3 for \(inFirst3) of 10 descriptions, need 9: \(detail.joined(separator: "; "))")
    }

    @Test func thePageOfTheBestPassageIsTheRightPageForAtLeastNineOfTheTenPdfDescriptions() throws {
        let ctx = try contextOrThrow()
        let pdf = ctx.readings.filter { $0.wanted.group == "pdf" }
        try #require(pdf.count == 10, "\(pdf.count) pdf rows were ranked, expected 10")
        let right = pdf.filter(\.pageRight).count
        let detail = pdf.filter { !$0.pageRight }.map(describe)
        #expect(right >= 9, "the page named was right for \(right) of 10 descriptions, need 9: \(detail.joined(separator: "; "))")
    }

    @Test func theRightDocumentIsInTheFirstThreeForAtLeastFiveOfTheSixDocumentDescriptions() throws {
        let ctx = try contextOrThrow()
        let docs = ctx.readings.filter { $0.wanted.group == "doc" }
        try #require(docs.count == 6, "\(docs.count) doc rows were ranked, expected 6 (txt, md, rtf, docx, html, odt)")
        let inFirst3 = docs.filter(\.first3).count
        let detail = docs.filter { !$0.first3 }.map(describe)
        #expect(inFirst3 >= 5, "the right document was within the first 3 for \(inFirst3) of 6 descriptions, need 5: \(detail.joined(separator: "; "))")
    }

    @Test func theScannedPdfIsInTheFirstThreeWithItsPage() throws {
        let ctx = try contextOrThrow()
        let row = try #require(ctx.readings.first { $0.wanted.group == "scanned" }, "the scanned row was not ranked")
        #expect(row.first3, "the scanned PDF is not in the first 3: \(describe(row))")
        #expect(row.pageRight, "the scanned PDF's page is not the right one: \(describe(row))")
    }

    @Test func theOddAndEvenRowsAreReportedApartAndNotedAsAnOverfittingRiskWhenTheEvenRowsHitTwoFewer() throws {
        let ctx = try contextOrThrow()
        var oddHit = 0, oddTotal = 0, evenHit = 0, evenTotal = 0
        for reading in ctx.readings {
            let digits = reading.wanted.id.reversed().prefix { $0.isNumber }.reversed()
            let number = Int(String(digits)) ?? 0
            let parity = number % 2 == 1 ? "odd" : "even"
            print("RANK \(reading.wanted.id) \(reading.rank.map(String.init) ?? "none") \(parity)")
            if number % 2 == 1 { oddTotal += 1; if reading.rank == 1 { oddHit += 1 } } else { evenTotal += 1; if reading.rank == 1 { evenHit += 1 } }
        }
        print("odd first \(oddHit) of \(oddTotal), even first \(evenHit) of \(evenTotal)")
        if oddHit - evenHit >= 2 { print("noted: overfitting risk") }
        // The split is reported, never asserted: only that both halves have rows.
        #expect(oddTotal > 0 && evenTotal > 0, "odd rows \(oddTotal), even rows \(evenTotal)")
    }

    // S2.2, S3.1: the exact strings inside PDFs and documents

    @Test func everyReadableExactRowOfAPdfOrADocumentIsFirstOnTheWholeFolderIndex() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.exact.count == 11, "\(ctx.exact.count) exact rows were ranked, expected 11")
        let notFirst = ctx.exact.filter { $0.rank != 1 }
        let detail = notFirst.map { "\($0.id) \"\($0.query)\" want \($0.file) rank \($0.rank.map(String.init) ?? "none") (list \($0.list.prefix(5).map { ($0 as NSString).lastPathComponent }))" }
        #expect(notFirst.isEmpty, "the exact file is not first for \(notFirst.count) of 11 rows: \(detail.joined(separator: "; "))")
    }

    // S2.3: a string in no file

    @Test func stringsOfTwoThreeAndFourWordsInNoFileFindNoPdfAndNoDocumentRow() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.nonsenseLists.count == nonsense.count, "\(ctx.nonsenseLists.count) nonsense strings were ranked, expected \(nonsense.count)")
        var gave: [String] = []
        for (text, paths) in ctx.nonsenseLists {
            let docRows = paths.filter { $0.contains("/golden-docs/") }
            if !docRows.isEmpty {
                gave.append("\"\(text)\" returned \(docRows.count) PDF or document rows: \(docRows.prefix(3).map { ($0 as NSString).lastPathComponent })")
            }
        }
        #expect(gave.isEmpty, "strings in no file found PDF or document rows: \(gave.joined(separator: "; "))")
    }

    // D8: the scanned pages share the image gate with the photos

    @Test func noGoldenPhotoMovesBecauseThePdfAndDocumentRowsAreInTheIndex() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.photosA.count == 10, "\(ctx.photosA.count) group a rows were ranked, expected 10")
        try #require(ctx.photosExact.count == 6, "\(ctx.photosExact.count) photo exact rows were ranked, expected 6")
        let first = ctx.photosA.filter { $0.rank == 1 }.count
        let top3 = ctx.photosA.filter { ($0.rank ?? 99) <= 3 }.count
        let moved = ctx.photosA.filter { $0.rank != 1 }.map { "\($0.id) rank \($0.rank.map(String.init) ?? "none")" }
        if !moved.isEmpty { print("noted: group a rows not first on the whole-folder index: \(moved.joined(separator: ", "))") }
        // The bars of GroupATests (6 first, 9 in the first 3), never lowered.
        #expect(first >= 6, "group a on the whole-folder index: first \(first) of 10, need 6 (not first: \(moved.joined(separator: ", ")))")
        #expect(top3 >= 9, "group a on the whole-folder index: top-3 \(top3) of 10, need 9 (rows: \(ctx.photosA.map { "\($0.id)=\($0.rank.map(String.init) ?? "none")" }.joined(separator: " ")))")
        // The bar of GroupBTests: every readable photo exact row first.
        let notFirst = ctx.photosExact.filter { $0.rank != 1 }.map { "\($0.id) rank \($0.rank.map(String.init) ?? "none")" }
        #expect(notFirst.isEmpty, "photo exact rows not first on the whole-folder index: \(notFirst.joined(separator: ", "))")
    }

    // S2.8 (i), (ii), (iii) in a copy

    @Test func afterOneThousandUnrelatedPhotosAreIndexedNoneOfTheElevenMovesFromFirst() throws {
        let run = MergeRun.shared
        #expect(run.unrelatedBuilt == 1000, "kit-fixtures.sh build unrelated 1000 made \(run.unrelatedBuilt) photos")
        let before = try run.stage("1")
        #expect(before.rowCount == wholeFileCount, "stage 1 indexed \(before.rowCount) files, expected \(wholeFileCount)")
        let after = try run.stage("2")
        #expect(after.rowCount == wholeFileCount + 1000, "stage 2 indexed \(after.rowCount) files, expected \(wholeFileCount + 1000)")
        #expect(after.statuses["done"] == after.rowCount - 2, "stage 2 statuses: \(after.statuses), expected every row done but the locked and the damaged PDF")
        for row in exactRows {
            let was = rank(row.file, in: before.lists[row.id] ?? [])
            let now = rank(row.file, in: after.lists[row.id] ?? [])
            print("MOVE \(row.id) before \(was.map(String.init) ?? "none") after \(now.map(String.init) ?? "none")")
        }
        let notFirstBefore = exactRows.filter { rank($0.file, in: before.lists[$0.id] ?? []) != 1 }.map(\.id)
        #expect(notFirstBefore.isEmpty, "before the unrelated photos these exact rows were not first in the copy: \(notFirstBefore)")
        let moved = exactRows.filter { rank($0.file, in: after.lists[$0.id] ?? []) != 1 }
        let detail = moved.map { "\($0.id) want \($0.file) rank \(rank($0.file, in: after.lists[$0.id] ?? []).map(String.init) ?? "none")" }
        #expect(moved.isEmpty, "with 1,000 unrelated photos the exact file is not first for \(moved.count) of 11 rows: \(detail.joined(separator: "; "))")
    }

    @Test func aRemovedPdfIsNoLongerListed() throws {
        let run = try MergeRun.shared.stage("3")
        #expect(MergeRun.shared.sharedFileStillThere, "the shared golden-docs fixture lost \(removedFile): the test must only touch its copy")
        #expect(run.rowCount == wholeFileCount + 1000 - 1, "stage 3 holds \(run.rowCount) files, expected \(wholeFileCount + 1000 - 1) after one deletion")
        for id in ["exact-15", "pdf-10"] {
            let list = run.lists[id] ?? []
            #expect(rank(removedFile, in: list) == nil, "after \(removedFile) was deleted and reconciled \(id) still lists it (place \(rank(removedFile, in: list).map(String.init) ?? "?"))")
        }
        // The other ten exact files are untouched by the deletion.
        let others = exactRows.filter { $0.id != "exact-15" }
        let notFirst = others.filter { rank($0.file, in: run.lists[$0.id] ?? []) != 1 }.map(\.id)
        #expect(notFirst.isEmpty, "after the deletion these exact files are not first: \(notFirst)")
    }

    // S2.17: the PDF and the document extensions

    @Test func everyExtdocCellOfTheBuiltMatrixIsDone() throws {
        let run = try extDocOutcome()
        #expect(run.rowCount == 7, "the helper indexed \(run.rowCount) files under matrix/extdoc, expected one per PDF or document extension (7)")
        for cell in run.cells {
            #expect(run.statuses[cell.cell] == "done",
                    "\(cell.cell) (\(cell.file)): row status \(run.statuses[cell.cell].map { $0.isEmpty ? "no row" : $0 } ?? "no row"), expected done")
        }
    }

    @Test func theUniqueNameStemOfEveryExtdocCellTypedAlonePutsItsFileFirst() throws {
        let run = try extDocOutcome()
        var notFirst: [String] = []
        for cell in run.cells {
            let list = run.lists[cell.cell] ?? []
            let place = list.firstIndex { $0.hasSuffix("/" + cell.file) }.map { $0 + 1 }
            print("EXTDOC \(cell.cell) \(cell.ext) stem \(cell.stem) rank \(place.map(String.init) ?? "none")")
            if place != 1 {
                notFirst.append("\(cell.cell) \"\(cell.stem)\" rank \(place.map(String.init) ?? "none") (list: \(list.map { ($0 as NSString).lastPathComponent }))")
            }
        }
        #expect(notFirst.isEmpty, "the file is not first for \(notFirst.count) of \(run.cells.count) cells: \(notFirst.joined(separator: "; "))")
    }
}
