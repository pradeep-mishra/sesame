import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-5-t6, tester step. The group d golden test (spec S2(d), S2.5, S2.2 for audio and video, S4.1, S4.3, S4.10): audio recordings and videos
// found by a description, the stated moment, the exact file names. Written from the t6 entry and the t1 report (the GOLDEN line format),
// GroupCTests and GroupBTests for the rigs, the answer key fixtures/answers.csv and the kit's golden-av table; no product source read.
// Every expected value is the key's or hand-written here; none is computed from the code under test.
//
// Through the engine's public interface: `scripts/kit-golden.sh prepare --all` (a child process) makes the index of golden/photos, golden-docs
// and golden-av with the bundled helper and the real models and prints its path; `IndexReader` opens it; `LlamaEmbedder` (the cached text model)
// embeds each query; `Search.rank` ranks; the second of a hit is `passages.start` of `Hit.passageID`, read with this file's own read-only SQLite
// connection (the column is REAL: cast to integer), counted only when that passage is an `audio` window or a `frame`.
//
// What it prints (the lines `kit-golden.sh engine --group d` reads): `GOLDEN <id> rank <n|none> second <s|none>` for the 8 audio rows, the 8 video
// rows and the videospeech row, and `GOLDEN v12 above <no|yes>` (yes when clip-v12.mp4 is above clip-v11.mp4 in the videospeech query's list);
// then the summary line the kit prints too. The kit writes golden-engine.tsv itself, so this file does not.
//
// What it checks:
//   group d (S2(d), S2.5)  audio: the right file in the first 3 for at least 7 of 8 and the second of its best passage inside
//                          [locator, locator + 30] for at least 7 of 8; video: the same with 10 s. The odd and even rows are reported apart
//                          (`noted: overfitting risk`, never a failure).
//   S4.10                  videospeech: clip-v11.mp4 in the first 3 for its query, the second inside [20, 30], clip-v12.mp4 not above it, and a
//                          query that names a picture the frames do not hold ("a red double decker bus on a snowy street") does not list
//                          clip-v11.mp4 first.
//   S2.2                   the exact names of exact-09, exact-10 and exact-20 are first; each decoy file is in the index (done) and, if listed,
//                          below the exact file.
//   S2.3                   six strings in no file list no row of golden-av.
//   S2.8                   in a copy of the index in the test's own temp folder (never the shared one), after `kit-fixtures.sh build unrelated 1000`
//                          is indexed beside the golden folders, none of the three exact rows moves from first.
//   earlier groups         over the same all-kinds index: group a (10 photo rows: first for at least 6, in the first 3 for at least 9), the six
//                          photo exact rows first, group c (10 PDF rows: in the first 3 for at least 9 and the page right for at least 9; 6
//                          document rows: in the first 3 for at least 5; the scanned row in the first 3 with its page) and the 11 exact rows of a
//                          PDF or a document first. A row that moves because of frames or windows is a STOP-ASK naming the row and its rank
//                          (D9): no weight is changed to hide it.
//
// SHAPES THIS FILE PINS that the entry did not fix: the picture-negative query (the kit's); the second of a hit counts only when its best passage is
// an `audio` window or a `frame` (a `name` passage gives none); a moment is right when the second is inside the window whatever the rank (as the
// kit counts it); the three decoy files of the exact rows (hand-written below); the lines of the earlier groups print as `GROUPA`, `GROUPB` and
// `GROUPC` so the kit's group c and group d readers never take them.
//
// It never skips: a missing model, bundle, helper or index is a failure that names the missing piece.

// MARK: the hand-written rows

private struct MediaRow: Sendable {
    let id: String
    let group: String
    let file: String         // under golden-av
    let locator: Int         // seconds
    let window: Int          // seconds
}

private let audioRows: [MediaRow] = [
    MediaRow(id: "audio-01", group: "audio", file: "audio/sleep-interview.m4a", locator: 130, window: 30),
    MediaRow(id: "audio-02", group: "audio", file: "audio/memo-0417.mp3", locator: 70, window: 30),
    MediaRow(id: "audio-03", group: "audio", file: "audio/standup-notes.flac", locator: 20, window: 30),
    MediaRow(id: "audio-04", group: "audio", file: "audio/call-recording-b.aac", locator: 55, window: 30),
    MediaRow(id: "audio-05", group: "audio", file: "audio/lecture-04.m4a", locator: 100, window: 30),
    MediaRow(id: "audio-06", group: "audio", file: "audio/field-recording.mp3", locator: 30, window: 30),
    MediaRow(id: "audio-07", group: "audio", file: "audio/voice-note-17.wav", locator: 85, window: 30),
    MediaRow(id: "audio-08", group: "audio", file: "audio/town-hall.flac", locator: 45, window: 30),
]

private let videoRows: [MediaRow] = [
    MediaRow(id: "video-01", group: "video", file: "video/safari-zebra.mp4", locator: 42, window: 10),
    MediaRow(id: "video-02", group: "video", file: "video/ocean-trip.mov", locator: 20, window: 10),
    MediaRow(id: "video-03", group: "video", file: "video/aerial-shoot.mp4", locator: 35, window: 10),
    MediaRow(id: "video-04", group: "video", file: "video/weekend-0412.m4v", locator: 15, window: 10),
    MediaRow(id: "video-05", group: "video", file: "video/wetland-walk.mov", locator: 50, window: 10),
    MediaRow(id: "video-06", group: "video", file: "video/fair-day.mp4", locator: 25, window: 10),
    MediaRow(id: "video-07", group: "video", file: "video/garden-clip.m4v", locator: 40, window: 10),
    MediaRow(id: "video-08", group: "video", file: "video/farm-visit.mp4", locator: 10, window: 10),
]

private let videospeechRow = MediaRow(id: "videospeech-01", group: "videospeech", file: "video/clip-v11.mp4", locator: 20, window: 10)
private let v12File = "video/clip-v12.mp4"
private let pictureNegative = "a red double decker bus on a snowy street"

/// The three exact rows of audio and video and the file of each one's decoy (decoy-09, decoy-10, decoy-20 of the key).
private let exactMedia: [(id: String, file: String, decoy: String)] = [
    ("exact-09", "audio/sleep-interview.m4a", "audio/sleep-podcast.m4a"),
    ("exact-10", "video/safari-zebra.mp4", "video/safari-giraffe.mp4"),
    ("exact-20", "audio/interview-raw-take3.wav", "audio/sleep-interview.m4a"),
]

/// Words in no file name and no text of the golden folders (the same made-up words GroupCTests uses).
private let nonsense: [String] = [
    "flurbo wazzik", "mrrgl tszzkq", "glorp snazzle quibbet", "yepnoh vlorbx drazzit",
    "blorf tszzk yepnoh vlimmer", "quazzle frimbo oglax dwemp",
]

/// The 17 rows of group c, written by hand (as GroupCTests does): id, group, file under golden-docs, page.
private let groupCRows: [(id: String, group: String, file: String, page: Int?)] = [
    ("pdf-01", "pdf", "pdfs/lease-2024.pdf", 7), ("pdf-02", "pdf", "pdfs/employee-handbook.pdf", 5),
    ("pdf-03", "pdf", "pdfs/warranty-maple-street.pdf", 3), ("pdf-04", "pdf", "pdfs/tax-return-2025-draft.pdf", 4),
    ("pdf-05", "pdf", "pdfs/insurance-policy.pdf", 4), ("pdf-06", "pdf", "pdfs/car-service-report.pdf", 2),
    ("pdf-07", "pdf", "pdfs/recipe-collection.pdf", 6), ("pdf-08", "pdf", "pdfs/conference-schedule.pdf", 3),
    ("pdf-09", "pdf", "pdfs/dishwasher-manual.pdf", 9), ("pdf-10", "pdf", "pdfs/boarding-pass.pdf", 1),
    ("doc-01", "doc", "docs/field-notes.txt", nil), ("doc-02", "doc", "docs/field-notes.md", nil),
    ("doc-03", "doc", "docs/shipping-update.html", nil), ("doc-04", "doc", "docs/meeting-minutes-2026-02-19.docx", nil),
    ("doc-05", "doc", "docs/budget-2026.odt", nil), ("doc-06", "doc", "docs/todo-list.rtf", nil),
    ("scanned-01", "scanned", "pdfs/scanned-receipt.pdf", 2),
]

private let docExactRows: [(id: String, file: String)] = [
    ("exact-05", "pdfs/invoice-2026-04417.pdf"), ("exact-06", "pdfs/Q3-board-deck.pdf"), ("exact-11", "docs/field-notes.txt"),
    ("exact-12", "docs/field-notes.md"), ("exact-13", "docs/shipping-update.html"), ("exact-14", "pdfs/employee-handbook.pdf"),
    ("exact-15", "pdfs/boarding-pass.pdf"), ("exact-16", "pdfs/tax-return-2025-draft.pdf"),
    ("exact-17", "docs/meeting-minutes-2026-02-19.docx"), ("exact-18", "docs/budget-2026.odt"), ("exact-19", "pdfs/warranty-maple-street.pdf"),
]

/// 40 photos, 20 PDFs and 6 documents, and 12 audio clips, 12 video clips and the 2 damaged clips of golden-av, written by hand.
private let allFileCount = 40 + 20 + 6 + 12 + 12 + 2

private func mmss(_ text: String) -> Int {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
}

// MARK: the key

private struct Key: Sendable {
    let id: String
    let group: String
    let query: String
    let file: String
    let locator: String
    let window: String
}

private func keyRows() throws -> [Key] {
    let url = GB.projectRoot.appendingPathComponent("fixtures/answers.csv")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw GBFailure("fixtures/answers.csv is missing: \(url.path)") }
    var rows: [Key] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6 else { continue }
        rows.append(Key(id: f[0], group: f[1], query: f[2], file: f[3], locator: f[4], window: f[5]))
    }
    return rows
}

/// The key must say what the hand-written tables say; a drift is a failure, not a changed expectation.
private func queryOf(_ key: [Key], _ row: MediaRow) throws -> String {
    guard let k = key.first(where: { $0.id == row.id }) else { throw GBFailure("the key has no row \(row.id)") }
    guard k.group == row.group, k.file == row.file, mmss(k.locator) == row.locator, Int(k.window) == row.window else {
        throw GBFailure("\(row.id): the key says group \(k.group) file \(k.file) locator \(k.locator) window \(k.window), expected \(row.group) \(row.file) \(row.locator) s \(row.window) s")
    }
    return k.query
}

// MARK: the passage read and settling a helper

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

    func passage(_ id: Int64) -> (source: String, start: Int?)? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select source, cast(start as integer) from passages where id = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW, let source = sqlite3_column_text(statement, 0) else { return nil }
        let start: Int? = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 1))
        return (String(cString: source), start)
    }

    /// The status of the file whose path ends with `suffix`, nil when no row.
    func status(endingWith suffix: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select status from files where path like ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "%" + suffix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func page(of hit: Int64?) -> Int? {
        guard let hit, let found = passage(hit), found.source == "page" else { return nil }
        return found.start
    }
}

private func gdSettle(home: String, helper: GBHelper, rows expected: Int, stall: TimeInterval, cap: TimeInterval) -> GB.Settled {
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

// MARK: the whole index and its readings

private struct Reading: Sendable {
    let row: MediaRow
    let query: String
    let rank: Int?
    let second: Int?
    let source: String
    let list: [String]

    var first3: Bool { (rank ?? 99) <= 3 }
    var momentRight: Bool {
        guard let second else { return false }
        return second >= row.locator && second <= row.locator + row.window
    }
    var odd: Bool { (Int(String(row.id.reversed().prefix { $0.isNumber }.reversed())) ?? 0) % 2 == 1 }
}

private struct ExactReading: Sendable {
    let id: String
    let file: String
    let decoy: String
    let query: String
    let rank: Int?
    let decoyRank: Int?
    let decoyStatus: String?
    let list: [String]
}

private struct GroupCReading: Sendable {
    let id: String
    let group: String
    let file: String
    let wantedPage: Int?
    let rank: Int?
    let page: Int?
    var first3: Bool { (rank ?? 99) <= 3 }
    var pageRight: Bool { rank != nil && page != nil && page == wantedPage }
}

private struct PlainReading: Sendable {
    let id: String
    let file: String
    let rank: Int?
}

nonisolated(unsafe) private var gdExitContext: GDContext?

private final class GDContext: @unchecked Sendable {
    let kit: URL
    let home: String
    let models: (text: URL, mm: URL)
    let reader: IndexReader
    let search: Search
    let embedder: LlamaEmbedder
    let visible: Visible
    let passages: PassageReader
    private var vectors: [String: [Float]] = [:]

    var audio: [Reading] = []
    var video: [Reading] = []
    var videospeech: Reading?
    var v12Rank: Int?
    var v12Above = false
    var negativeRank11: Int?
    var negativeList: [String] = []
    var exact: [ExactReading] = []
    var nonsenseLists: [(text: String, golden: [String], all: Int)] = []
    var groupA: [PlainReading] = []
    var photoExact: [PlainReading] = []
    var groupC: [GroupCReading] = []
    var docExact: [PlainReading] = []

    init(kit: URL, home: String, models: (text: URL, mm: URL), reader: IndexReader, embedder: LlamaEmbedder, passages: PassageReader, folders: [String]) {
        self.kit = kit
        self.home = home
        self.models = models
        self.reader = reader
        self.search = Search(reader: reader)
        self.embedder = embedder
        self.passages = passages
        self.visible = GB.visible(folders)
    }

    static let shared: Result<GDContext, GBFailure> = {
        do { return .success(try build()) } catch let failure as GBFailure { return .failure(failure) } catch { return .failure(GBFailure("\(error)")) }
    }()

    func vector(_ text: String) throws -> [Float] {
        if let known = vectors[text] { return known }
        let made = try embedder.embed(text, role: .query)
        vectors[text] = made
        return made
    }

    func hits(_ text: String) throws -> [(path: String, passageID: Int64)] {
        let ticket = search.newTicket()
        guard let found = search.rank(text: text, vector: try vector(text), ticket: ticket, visible: visible) else { return [] }
        return found.map { ($0.path, $0.passageID) }
    }

    private func readMedia(_ row: MediaRow, query: String) throws -> Reading {
        let found = try hits(query)
        let paths = found.map(\.path)
        let place = GB.place(of: row.file, in: paths, folder: "golden-av")
        var second: Int?
        var source = "none"
        if let place, let passage = passages.passage(found[place - 1].passageID) {
            source = passage.source
            if passage.source == "audio" || passage.source == "frame" { second = passage.start }
        }
        return Reading(row: row, query: query, rank: place, second: second, source: source, list: paths)
    }

    private static func build() throws -> GDContext {
        let key = try keyRows()
        guard let kit = GB.kitRoot() else { throw GBFailure("no KIT_ROOT and no TMPDIR: cannot find the kit") }
        let models = try GB.models(kit: kit)
        var queries: [String: String] = [:]
        for row in audioRows + videoRows + [videospeechRow] { queries[row.id] = try queryOf(key, row) }

        let prepared = GB.withGoldenLock(kit) {
            GB.runChild("/bin/bash", [GB.projectRoot.appendingPathComponent("scripts/kit-golden.sh").path, "prepare", "--all"],
                        cwd: GB.projectRoot, limit: 14400)
        }
        guard let prepare = prepared else { throw GBFailure("scripts/kit-golden.sh could not be run") }
        guard prepare.status == 0 else { throw GBFailure("kit-golden.sh prepare --all exited \(prepare.status): \(GB.tail(prepare.output))") }
        let lastLine = prepare.output.split(separator: "\n").last.map(String.init) ?? ""
        let suffix = "/Library/Application Support/Sesame/index.sqlite"
        guard lastLine.hasPrefix("/"), lastLine.hasSuffix(suffix) else {
            throw GBFailure("kit-golden.sh prepare --all did not end with the index path: \(GB.tail(prepare.output))")
        }
        guard FileManager.default.fileExists(atPath: lastLine) else { throw GBFailure("the index is missing: \(lastLine)") }
        let home = String(lastLine.dropLast(suffix.count))

        let opened = GB.openReader(home: home, files: allFileCount)
        guard let reader = opened.reader else {
            throw GBFailure("the index at \(lastLine) holds \(opened.count) files, expected \(allFileCount): 40 golden photos, 20 PDFs, 6 documents, 12 audio clips, 12 video clips and 2 damaged clips")
        }
        guard let passages = PassageReader(home: home) else { throw GBFailure("the index at \(lastLine) cannot be opened read-only") }
        let embedder = LlamaEmbedder(textModel: models.text)
        try embedder.load()
        let roots = ["golden", "golden-docs", "golden-av"].map { kit.appendingPathComponent("fixtures/" + $0, isDirectory: true).path }
        let context = GDContext(kit: kit, home: home, models: models, reader: reader, embedder: embedder, passages: passages, folders: roots)
        gdExitContext = context
        atexit {
            gdExitContext?.search.release()
            gdExitContext?.embedder.unload()
            gdExitContext?.reader.close()
        }

        // group d
        for row in audioRows {
            let reading = try context.readMedia(row, query: queries[row.id] ?? "")
            context.audio.append(reading)
            print("GOLDEN \(row.id) rank \(reading.rank.map(String.init) ?? "none") second \(reading.second.map(String.init) ?? "none")")
        }
        for row in videoRows {
            let reading = try context.readMedia(row, query: queries[row.id] ?? "")
            context.video.append(reading)
            print("GOLDEN \(row.id) rank \(reading.rank.map(String.init) ?? "none") second \(reading.second.map(String.init) ?? "none")")
        }
        let speech = try context.readMedia(videospeechRow, query: queries[videospeechRow.id] ?? "")
        context.videospeech = speech
        print("GOLDEN \(videospeechRow.id) rank \(speech.rank.map(String.init) ?? "none") second \(speech.second.map(String.init) ?? "none")")
        context.v12Rank = GB.place(of: v12File, in: speech.list, folder: "golden-av")
        if let v12 = context.v12Rank { context.v12Above = speech.rank == nil || v12 < (speech.rank ?? Int.max) }
        print("GOLDEN v12 above \(context.v12Above ? "yes" : "no")")
        let negative = try context.hits(pictureNegative).map(\.path)
        context.negativeList = negative
        context.negativeRank11 = GB.place(of: videospeechRow.file, in: negative, folder: "golden-av")
        print("PICTURE-NEGATIVE \"\(pictureNegative)\" clip-v11 rank \(context.negativeRank11.map(String.init) ?? "none") of \(negative.count) rows")

        // the exact names and their decoys
        for (id, file, decoy) in exactMedia {
            guard let k = key.first(where: { $0.id == id }), k.group == "exact", k.file == file else {
                throw GBFailure("\(id): the key does not say exact \(file)")
            }
            let paths = try context.hits(k.query).map(\.path)
            let rank = GB.place(of: file, in: paths, folder: "golden-av")
            let decoyRank = GB.place(of: decoy, in: paths, folder: "golden-av")
            let status = passages.status(endingWith: "/golden-av/" + decoy)
            context.exact.append(ExactReading(id: id, file: file, decoy: decoy, query: k.query, rank: rank, decoyRank: decoyRank, decoyStatus: status, list: paths))
            print("EXACT \(id) rank \(rank.map(String.init) ?? "none") decoy rank \(decoyRank.map(String.init) ?? "none") decoy status \(status ?? "no row")")
        }

        // strings in no file
        for text in nonsense {
            let paths = try context.hits(text).map(\.path)
            let golden = paths.filter { $0.contains("/golden-av/") }
            context.nonsenseLists.append((text, golden, paths.count))
            print("NONSENSE \"\(text)\" rows \(paths.count) golden-av rows \(golden.count)")
        }

        // the earlier groups over the same index
        for row in key where row.group == "photo" {
            let paths = try context.hits(row.query).map(\.path)
            let place = GB.place(of: row.file, in: paths)
            context.groupA.append(PlainReading(id: row.id, file: row.file, rank: place))
            print("GROUPA \(row.id) rank \(place.map(String.init) ?? "none")")
        }
        for answer in try GB.readableExact() {
            let paths = try context.hits(answer.query).map(\.path)
            let place = GB.place(of: answer.file, in: paths)
            context.photoExact.append(PlainReading(id: answer.id, file: answer.file, rank: place))
            print("GROUPB \(answer.id) rank \(place.map(String.init) ?? "none")")
        }
        for wanted in groupCRows {
            guard let k = key.first(where: { $0.id == wanted.id }), k.group == wanted.group, k.file == wanted.file else {
                throw GBFailure("\(wanted.id): the key does not say \(wanted.group) \(wanted.file)")
            }
            if let page = wanted.page, k.locator != String(page) { throw GBFailure("\(wanted.id): the key's locator is \(k.locator), expected page \(page)") }
            let found = try context.hits(k.query)
            let place = GB.place(of: wanted.file, in: found.map(\.path), folder: "golden-docs")
            let page = place.flatMap { context.passages.page(of: found[$0 - 1].passageID) }
            context.groupC.append(GroupCReading(id: wanted.id, group: wanted.group, file: wanted.file, wantedPage: wanted.page, rank: place, page: page))
            print("GROUPC \(wanted.id) rank \(place.map(String.init) ?? "none") page \(page.map(String.init) ?? "none")")
        }
        for (id, file) in docExactRows {
            guard let k = key.first(where: { $0.id == id }), k.group == "exact", k.file == file else { throw GBFailure("\(id): the key does not say exact \(file)") }
            let paths = try context.hits(k.query).map(\.path)
            let place = GB.place(of: file, in: paths, folder: "golden-docs")
            context.docExact.append(PlainReading(id: id, file: file, rank: place))
            print("GROUPC-EXACT \(id) rank \(place.map(String.init) ?? "none")")
        }

        let a = context.audio, v = context.video
        let speechFirst3 = speech.first3
        print("GOLDEN engine group d: audio first-3 \(a.filter(\.first3).count) of \(a.count), moment right \(a.filter(\.momentRight).count) of \(a.count); video first-3 \(v.filter(\.first3).count) of \(v.count), moment right \(v.filter(\.momentRight).count) of \(v.count); videospeech first-3 \(speechFirst3 ? "yes" : "no"), v12 above \(context.v12Above ? "yes" : "no")")
        return context
    }
}

private func contextOrThrow() throws -> GDContext {
    switch GDContext.shared {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

private func describe(_ r: Reading) -> String {
    "\(r.row.id) \"\(r.query)\" want \(r.row.file) at \(r.row.locator) to \(r.row.locator + r.row.window) s: rank \(r.rank.map(String.init) ?? "none") second \(r.second.map(String.init) ?? "none") (best passage \(r.source); list \(r.list.prefix(5).map { ($0 as NSString).lastPathComponent }))"
}

// MARK: exact rows after the 1,000 unrelated photos (S2.8)

private struct UnrelatedOutcome: Sendable {
    let built: Int
    let rowCount: Int
    let firsts: [String: Int?]
}

private final class UnrelatedRun: @unchecked Sendable {
    static let shared: Result<UnrelatedOutcome, GBFailure> = {
        do { return .success(try perform()) } catch let failure as GBFailure { return .failure(failure) } catch { return .failure(GBFailure("\(error)")) }
    }()

    private static func perform() throws -> UnrelatedOutcome {
        let ctx = try contextOrThrow()
        guard FileManager.default.isExecutableFile(atPath: GB.bundledHelper.path) else {
            throw GBFailure("the bundled helper is missing: run `scripts/bundle.sh` (expected \(GB.bundledHelper.path))")
        }
        let work = GB.realpathOf(FileManager.default.temporaryDirectory.appendingPathComponent("sesame-groupd-" + UUID().uuidString).path)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        // 1,000 unrelated photos in a temp kit root of their own.
        let tempKit = work + "/sesame-kit-groupd"
        let tmp = work + "/tmp"
        let decoyHome = work + "/decoy-home"
        for dir in [tempKit + "/run", tmp, decoyHome] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let env = ["KIT_ROOT": tempKit, "TMPDIR": tmp + "/", "HOME": decoyHome, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        let build = GB.runChild("/bin/bash", [GB.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", "unrelated", "1000"],
                                env: env, limit: 1800)
        guard let unrelated = build, unrelated.status == 0 else {
            throw GBFailure("kit-fixtures.sh build unrelated 1000 failed: \(GB.tail(build?.output ?? "not started"))")
        }
        let unrelatedRoot = tempKit + "/fixtures/unrelated"
        let built = (try? FileManager.default.contentsOfDirectory(atPath: unrelatedRoot))?.filter { $0.hasPrefix("unrel") }.count ?? 0
        guard built == 1000 else { throw GBFailure("build unrelated 1000 made \(built) photos in \(unrelatedRoot)") }

        // A copy of the shared index (never the shared one) in a home of this test's own; the helper reads the shared golden folders and the
        // unrelated photos, writes only to the copy, and has no models: the golden rows stay as the real models made them.
        let home = work + "/home"
        try GB.makeSupportFolder(home: home)
        let source = (GB.indexFile(home: ctx.home) as NSString).deletingLastPathComponent
        let target = (GB.indexFile(home: home) as NSString).deletingLastPathComponent
        for name in try FileManager.default.contentsOfDirectory(atPath: source) where name.hasPrefix("index.sqlite") {
            try FileManager.default.copyItem(atPath: source + "/" + name, toPath: target + "/" + name)
        }
        let existing = GB.indexRows(home: home) ?? []
        guard existing.count == allFileCount else { throw GBFailure("the copy of the index holds \(existing.count) files, expected \(allFileCount)") }
        func root(_ marker: String) throws -> String {
            guard let path = existing.first(where: { $0.path.contains(marker) })?.path, let range = path.range(of: marker) else {
                throw GBFailure("no file of \(marker) in the index")
            }
            return String(path[..<range.upperBound])
        }
        let folders = [try root("/golden/photos"), try root("/golden-docs"), try root("/golden-av"), unrelatedRoot]
        let helper = try GBHelper(home: home, models: nil, scratch: URL(fileURLWithPath: work))
        defer { helper.stop() }
        helper.sendFolders(folders)
        let settled = gdSettle(home: home, helper: helper, rows: allFileCount + 1000, stall: 900, cap: 3600)
        guard settled.ok else { throw GBFailure("the 1,000 unrelated photos added beside the copy: \(settled.note)") }
        helper.stop()

        let opened = GB.openReader(home: home, files: allFileCount + 1000)
        guard let reader = opened.reader else { throw GBFailure("the copy holds \(opened.count) files, expected \(allFileCount + 1000)") }
        defer { reader.close() }
        let search = Search(reader: reader)
        defer { search.release() }
        let visible = GB.visible(folders)
        let key = try keyRows()
        var firsts: [String: Int?] = [:]
        for (id, file, _) in exactMedia {
            guard let k = key.first(where: { $0.id == id }) else { throw GBFailure("the key has no row \(id)") }
            let paths = GB.ranked(search, k.query, try ctx.vector(k.query), visible) ?? []
            firsts[id] = GB.place(of: file, in: paths, folder: "golden-av")
            print("MOVE \(id) after 1,000 unrelated photos rank \(firsts[id].flatMap { $0 }.map(String.init) ?? "none")")
        }
        return UnrelatedOutcome(built: built, rowCount: settled.rows.count, firsts: firsts)
    }
}

// MARK: the suite

@Suite("GroupDTests", .serialized)
struct GroupDTests {

    // S2(d), S2.5, S4.1: audio descriptions

    @Test func theRightRecordingIsInTheFirstThreeForAtLeastSevenOfTheEightAudioDescriptions() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.audio.count == 8, "\(ctx.audio.count) audio rows were ranked, expected 8")
        let inFirst3 = ctx.audio.filter(\.first3).count
        #expect(inFirst3 >= 7, "the right recording was within the first 3 for \(inFirst3) of 8 descriptions, need 7: \(ctx.audio.filter { !$0.first3 }.map(describe).joined(separator: "; "))")
    }

    @Test func theStatedMomentIsInsideTheTrueWindowForAtLeastSevenOfTheEightAudioDescriptions() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.audio.count == 8, "\(ctx.audio.count) audio rows were ranked, expected 8")
        let right = ctx.audio.filter(\.momentRight).count
        #expect(right >= 7, "the stated second was inside [locator, locator + 30] for \(right) of 8 descriptions, need 7: \(ctx.audio.filter { !$0.momentRight }.map(describe).joined(separator: "; "))")
    }

    // S2(d), S2.5, S4.3: video descriptions

    @Test func theRightVideoIsInTheFirstThreeForAtLeastSevenOfTheEightVideoDescriptions() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.video.count == 8, "\(ctx.video.count) video rows were ranked, expected 8")
        let inFirst3 = ctx.video.filter(\.first3).count
        #expect(inFirst3 >= 7, "the right video was within the first 3 for \(inFirst3) of 8 descriptions, need 7: \(ctx.video.filter { !$0.first3 }.map(describe).joined(separator: "; "))")
    }

    @Test func theStatedMomentIsInsideTheTrueShotForAtLeastSevenOfTheEightVideoDescriptions() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.video.count == 8, "\(ctx.video.count) video rows were ranked, expected 8")
        let right = ctx.video.filter(\.momentRight).count
        #expect(right >= 7, "the stated second was inside [locator, locator + 10] for \(right) of 8 descriptions, need 7: \(ctx.video.filter { !$0.momentRight }.map(describe).joined(separator: "; "))")
    }

    @Test func theOddAndEvenRowsAreReportedApartAndNotedAsAnOverfittingRiskWhenTheEvenRowsHitTwoFewer() throws {
        let ctx = try contextOrThrow()
        var oddHit = 0, oddTotal = 0, evenHit = 0, evenTotal = 0
        for reading in ctx.audio + ctx.video {
            print("RANK \(reading.row.id) \(reading.rank.map(String.init) ?? "none") \(reading.odd ? "odd" : "even")")
            if reading.odd { oddTotal += 1; if reading.rank == 1 { oddHit += 1 } } else { evenTotal += 1; if reading.rank == 1 { evenHit += 1 } }
        }
        print("odd first \(oddHit) of \(oddTotal), even first \(evenHit) of \(evenTotal)")
        if oddHit - evenHit >= 2 { print("noted: overfitting risk") }
        #expect(oddTotal > 0 && evenTotal > 0, "odd rows \(oddTotal), even rows \(evenTotal)")
    }

    // S4.10: words spoken in a soundtrack

    @Test func theVideoWhoseSoundtrackHoldsTheSentenceIsInTheFirstThreeAtItsMomentAndTheSilentTwinIsNotAboveIt() throws {
        let ctx = try contextOrThrow()
        let speech = try #require(ctx.videospeech, "the videospeech row was not ranked")
        #expect(speech.first3, "clip-v11.mp4 is not in the first 3 for \"\(speech.query)\": \(describe(speech))")
        let second = speech.second
        #expect(second != nil && second! >= 20 && second! <= 30, "the second of its best passage is \(second.map(String.init) ?? "none"), expected inside [20, 30] (source \(speech.source))")
        #expect(!ctx.v12Above, "clip-v12.mp4 (the same frames, a silent soundtrack) is above clip-v11.mp4: v12 rank \(ctx.v12Rank.map(String.init) ?? "none"), v11 rank \(speech.rank.map(String.init) ?? "none")")
    }

    @Test func aQueryThatNamesAPictureTheFramesDoNotHoldDoesNotListTheSpeechVideoFirst() throws {
        let ctx = try contextOrThrow()
        #expect(ctx.negativeRank11 != 1, "\"\(pictureNegative)\" lists clip-v11.mp4 first (its frames are plain gray); list \(ctx.negativeList.prefix(5).map { ($0 as NSString).lastPathComponent })")
    }

    // S2.2: the exact names of an audio and a video file

    @Test func theExactNamesOfTheAudioAndVideoRowsAreFirstWithTheirDecoysInTheIndexAndBelowThem() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.exact.count == 3, "\(ctx.exact.count) exact rows were ranked, expected 3")
        let notFirst = ctx.exact.filter { $0.rank != 1 }
        #expect(notFirst.isEmpty, "the exact file is not first for \(notFirst.map { "\($0.id) \"\($0.query)\" rank \($0.rank.map(String.init) ?? "none") (list \($0.list.prefix(5).map { ($0 as NSString).lastPathComponent }))" })")
        let missing = ctx.exact.filter { $0.decoyStatus != "done" }
        #expect(missing.isEmpty, "the decoy file is not a done row of the index: \(missing.map { "\($0.id) decoy \($0.decoy) status \($0.decoyStatus ?? "no row")" })")
        let above = ctx.exact.filter { ($0.decoyRank ?? Int.max) < ($0.rank ?? Int.max) }
        #expect(above.isEmpty, "the decoy is listed above the exact file: \(above.map { "\($0.id) decoy rank \($0.decoyRank.map(String.init) ?? "none")" })")
    }

    // S2.3: strings in no file

    @Test func stringsOfTwoThreeAndFourWordsInNoFileListNoAudioAndNoVideoRow() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.nonsenseLists.count == nonsense.count, "\(ctx.nonsenseLists.count) nonsense strings were ranked, expected \(nonsense.count)")
        let gave = ctx.nonsenseLists.filter { !$0.golden.isEmpty }
        #expect(gave.isEmpty, "strings in no file listed audio or video rows: \(gave.map { "\"\($0.text)\" -> \($0.golden.map { ($0 as NSString).lastPathComponent })" })")
    }

    // S2.8: 1,000 unrelated photos beside the golden folders

    @Test func afterOneThousandUnrelatedPhotosAreIndexedNoneOfTheThreeExactMediaRowsMovesFromFirst() throws {
        let outcome: UnrelatedOutcome
        switch UnrelatedRun.shared {
        case .success(let value): outcome = value
        case .failure(let failure): throw failure
        }
        #expect(outcome.built == 1000, "kit-fixtures.sh build unrelated 1000 made \(outcome.built) photos")
        #expect(outcome.rowCount == allFileCount + 1000, "the copy holds \(outcome.rowCount) files, expected \(allFileCount + 1000)")
        let moved = exactMedia.filter { (outcome.firsts[$0.id] ?? nil) != 1 }
        #expect(moved.isEmpty, "with 1,000 unrelated photos the exact file is not first for \(moved.map { "\($0.id) rank \((outcome.firsts[$0.id] ?? nil).map(String.init) ?? "none")" })")
    }

    // D9: video frames and audio windows must not hide an earlier group

    @Test func noGoldenPhotoMovesBecauseVideoFramesAndAudioWindowsAreInTheIndex() throws {
        let ctx = try contextOrThrow()
        try #require(ctx.groupA.count == 10, "\(ctx.groupA.count) group a rows were ranked, expected 10")
        try #require(ctx.photoExact.count == 6, "\(ctx.photoExact.count) photo exact rows were ranked, expected 6")
        let first = ctx.groupA.filter { $0.rank == 1 }.count
        let top3 = ctx.groupA.filter { ($0.rank ?? 99) <= 3 }.count
        let notFirst = ctx.groupA.filter { $0.rank != 1 }.map { "\($0.id) rank \($0.rank.map(String.init) ?? "none")" }
        if !notFirst.isEmpty { print("noted: group a rows not first on the all-kinds index: \(notFirst.joined(separator: ", "))") }
        #expect(first >= 6, "STOP-ASK: group a on the all-kinds index: first \(first) of 10, need 6 (not first: \(notFirst.joined(separator: ", ")))")
        #expect(top3 >= 9, "STOP-ASK: group a on the all-kinds index: top-3 \(top3) of 10, need 9 (rows: \(ctx.groupA.map { "\($0.id)=\($0.rank.map(String.init) ?? "none")" }.joined(separator: " ")))")
        let exactMoved = ctx.photoExact.filter { $0.rank != 1 }.map { "\($0.id) rank \($0.rank.map(String.init) ?? "none")" }
        #expect(exactMoved.isEmpty, "STOP-ASK: photo exact rows not first on the all-kinds index: \(exactMoved.joined(separator: ", "))")
    }

    @Test func noGroupCRowMovesBecauseVideoFramesAndAudioWindowsAreInTheIndex() throws {
        let ctx = try contextOrThrow()
        let pdf = ctx.groupC.filter { $0.group == "pdf" }
        let doc = ctx.groupC.filter { $0.group == "doc" }
        let scanned = try #require(ctx.groupC.first { $0.group == "scanned" }, "the scanned row was not ranked")
        try #require(pdf.count == 10 && doc.count == 6, "\(pdf.count) pdf rows and \(doc.count) doc rows were ranked, expected 10 and 6")
        func said(_ r: GroupCReading) -> String { "\(r.id) rank \(r.rank.map(String.init) ?? "none") page \(r.page.map(String.init) ?? "none") (want page \(r.wantedPage.map(String.init) ?? "-"))" }
        let pdfFirst3 = pdf.filter(\.first3).count
        #expect(pdfFirst3 >= 9, "STOP-ASK: PDF rows in the first 3: \(pdfFirst3) of 10, need 9: \(pdf.filter { !$0.first3 }.map(said))")
        let pageRight = pdf.filter(\.pageRight).count
        #expect(pageRight >= 9, "STOP-ASK: PDF pages right: \(pageRight) of 10, need 9: \(pdf.filter { !$0.pageRight }.map(said))")
        let docFirst3 = doc.filter(\.first3).count
        #expect(docFirst3 >= 5, "STOP-ASK: document rows in the first 3: \(docFirst3) of 6, need 5: \(doc.filter { !$0.first3 }.map(said))")
        #expect(scanned.first3 && scanned.pageRight, "STOP-ASK: the scanned PDF: \(said(scanned)), need the first 3 with page 2")
        let exactMoved = ctx.docExact.filter { $0.rank != 1 }.map { "\($0.id) rank \($0.rank.map(String.init) ?? "none")" }
        #expect(exactMoved.isEmpty, "STOP-ASK: PDF and document exact rows not first on the all-kinds index: \(exactMoved.joined(separator: ", "))")
    }
}
