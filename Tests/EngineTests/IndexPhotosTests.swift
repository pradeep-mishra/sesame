import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SQLite3
import Testing
import Vision

// plan-1-t32, tester step. Written from the t32 entry, the Helper protocol table of the plan's Conventions and
// design sections 1, 2, 3, 4, 8 and 9 only; no product source read.
//
// These tests start the helper the way the app does: `SesameHelper index` with `HOME` pointing at a throwaway
// folder, send hand-written `folders` lines on its stdin and read the JSON lines it writes on stdout. The index is
// looked at with this file's own read-only SQLite connection (`$HOME/Library/Application Support/Sesame/index.sqlite`),
// so what is checked is what is on disk, not what the product says about itself. Expected values come from this
// file's own inputs (the photos it draws, their names, the text it draws on them) and from `stat` of the files it made,
// never from the code under test.
//
// Fake runs: `SESAME_FAKE_EMBEDDER=1`, no model path. One run is real: the cached model files, the golden photos the
// kit builds. The helper is the debug build `swift test` builds next to the test bundle. The suite is nested in
// `EncodeHelperTests` (Reading.swift), so no helper suite runs beside it.
//
// What the entry fixes, and how each clause is observed from outside:
// - "all 40 reach done, each has a name passage (words only) and an image passage": every `files` row is `done`, and
//   holds exactly one `name` passage (modality none, no vector, its words in the fts `name` column) and exactly one
//   `image` passage (modality image, a 1,536 byte vector). Two passages and one file row make three rows per photo,
//   which is the arithmetic of the kit's filler (guess G4).
// - "a MATCH for the text on the fts body finds the file that carries it": the test draws "INV-2026-04417" large on
//   one photo and asks the fts table (`body:"INV-2026-04417"`) which passage holds it.
// - "crash-always-1.jpg kills the helper while the other photos are untouched": the helper exits by itself, not with
//   status 0, with stdin still open; afterwards the index is whole, every other file is all-new (pending, no
//   passages) or all-old (done, complete), and a fresh helper over the folder without that file finishes the rest.
// - "SIGKILL at several points": `PRAGMA integrity_check` equals `ok`, every file is all-new or all-old, nothing is
//   duplicated or orphaned, and a restarted helper finishes the folder.
// - "a file changed between batches is replaced in one transaction": a tight polling reader never sees a half state.
// - "batches are up to 25 files": the index never gains more than 25 finished files in one step, and at least
//   one commit per 25 files is announced (see `batchesAreUpToTwentyFiveFiles`).
// - "`changed` follows each commit": after every commit a reader can see, a `changed` event arrives, and a `changed`
//   never arrives before its commit is visible.
// - "embed units are at most 16 inputs, each one typed line `unit n=<k>` in index.log": read back from the file.
// - "with the cached model the golden photos reach done with the model loaded for the batch and unloaded after":
//   the helper's open files and footprint are sampled while it works and after it is done (stdin still open).
//
// Not observable from outside, so not asserted: the number of model loads per run (a batch's size is only seen as
// "no commit holds more than 25 files").

// MARK: raw read-only SQLite, independent of the product

private final class T32DB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close_v2(db) }

    /// Every row as text (nil for NULL), or nil when the statement cannot run (no such table yet, a lock).
    func rows(_ sql: String) -> [[String?]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            var row: [String?] = []
            for column in 0..<sqlite3_column_count(statement) {
                if sqlite3_column_type(statement, column) == SQLITE_NULL {
                    row.append(nil)
                } else if let text = sqlite3_column_text(statement, column) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }

    /// The raw bytes of the first column of every row (nil for NULL), or nil when the statement cannot run.
    func blobs(_ sql: String) -> [Data?]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [Data?] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                out.append(nil)
            } else {
                let count = Int(sqlite3_column_bytes(statement, 0))
                if let pointer = sqlite3_column_blob(statement, 0) {
                    out.append(Data(bytes: pointer, count: count))
                } else {
                    out.append(Data())
                }
            }
        }
        return out
    }

    func int(_ sql: String) -> Int? {
        guard let result = rows(sql), let row = result.first, let cell = row.first, let text = cell else { return nil }
        return Int(text)
    }

    func begin() -> Bool { rows("BEGIN") != nil }
    func end() { _ = rows("COMMIT") }

    /// The answer of `pragma integrity_check`: `ok`, or what it said, or why it could not run.
    func integrity() -> String {
        guard let result = rows("pragma integrity_check") else { return "integrity_check could not run" }
        return result.compactMap { $0.first ?? nil }.joined(separator: " | ")
    }

    /// `files` rows per status in one statement, e.g. ["done": 12, "pending": 28].
    func statuses() -> [String: Int]? {
        guard let result = rows("select status, count(*) from files group by status") else { return nil }
        var out: [String: Int] = [:]
        for row in result {
            if let status = row[0], let text = row[1], let n = Int(text) { out[status] = n }
        }
        return out
    }
}

private func t32Normal(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

private func t32Stat(_ url: URL) -> (size: Int64, mtimeNs: Int64, inode: UInt64)? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return (Int64(info.st_size),
            Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            UInt64(info.st_ino))
}

// Little-endian IEEE half floats, decoded here and not by the product.
private func t32Half(_ data: Data) -> [Float] {
    (0..<(data.count / 2)).map { index in
        let low = UInt16(data[data.startIndex + 2 * index])
        let high = UInt16(data[data.startIndex + 2 * index + 1])
        return Float(Float16(bitPattern: low | (high << 8)))
    }
}

// MARK: the one consistency rule: every file all-new or all-old

private struct T32Passage {
    let id: Int64
    let fileID: Int64
    let source: String
    let modality: String
    let vecBytes: Int
}

/// What is wrong with the index, read in one snapshot. Empty means: every `done` file holds exactly one `name`
/// passage (modality none, no vector, words in fts `name`) and exactly one `image` passage (modality image, 1,536
/// vector bytes, an fts row); every `pending` file holds no passage; no other status; no passage without a file or
/// without an fts row; no fts row without a passage.
private func t32Problems(_ db: T32DB) -> [String] {
    guard db.begin() else { return ["the index cannot be read"] }
    defer { db.end() }
    guard let files = db.rows("select id, path, status from files"),
          let passageRows = db.rows("select id, file_id, source, modality, coalesce(length(vec), -1) from passages"),
          let ftsRows = db.rows("select rowid, name, body from fts") else {
        return ["a table of the index cannot be read"]
    }
    var problems: [String] = []
    var passagesByFile: [Int64: [T32Passage]] = [:]
    var passageIDs = Set<Int64>()
    for row in passageRows {
        guard let id = row[0].flatMap({ Int64($0) }), let fileID = row[1].flatMap({ Int64($0) }) else { continue }
        let passage = T32Passage(id: id, fileID: fileID, source: row[2] ?? "", modality: row[3] ?? "",
                                 vecBytes: row[4].flatMap { Int($0) } ?? -1)
        passagesByFile[fileID, default: []].append(passage)
        passageIDs.insert(id)
    }
    var ftsByID: [Int64: (name: String, body: String)] = [:]
    for row in ftsRows {
        if let id = row[0].flatMap({ Int64($0) }) { ftsByID[id] = (row[1] ?? "", row[2] ?? "") }
    }
    var fileIDs = Set<Int64>()
    for row in files {
        guard let id = row[0].flatMap({ Int64($0) }) else { continue }
        fileIDs.insert(id)
        let name = ((row[1] ?? "") as NSString).lastPathComponent
        let status = row[2] ?? "nil"
        let mine = passagesByFile[id] ?? []
        switch status {
        case "done":
            let names = mine.filter { $0.source == "name" }
            let images = mine.filter { $0.source == "image" }
            if names.count != 1 || images.count != 1 || mine.count != 2 {
                problems.append("\(name): done with \(mine.map { $0.source }) passages, expected one name and one image")
                continue
            }
            if names[0].modality != "none" || names[0].vecBytes != -1 {
                problems.append("\(name): the name passage has modality \(names[0].modality) and \(names[0].vecBytes) vector bytes, expected none and no vector")
            }
            if (ftsByID[names[0].id]?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(name): the name passage has no words in the fts name column")
            }
            if images[0].modality != "image" || images[0].vecBytes != 1536 {
                problems.append("\(name): the image passage has modality \(images[0].modality) and \(images[0].vecBytes) vector bytes, expected image and 1536")
            }
        case "pending":
            if !mine.isEmpty { problems.append("\(name): pending but holds \(mine.count) passages (half written)") }
        default:
            problems.append("\(name): status \(status), expected done or pending")
        }
    }
    for fileID in passagesByFile.keys where !fileIDs.contains(fileID) {
        problems.append("passages of file id \(fileID) have no files row")
    }
    for id in passageIDs where ftsByID[id] == nil { problems.append("passage \(id) has no fts row") }
    for id in ftsByID.keys where !passageIDs.contains(id) { problems.append("fts row \(id) has no passage") }
    return problems
}

/// Records one issue naming the first problems (not the whole list) when the index is not whole.
private func t32ExpectWhole(_ db: T32DB, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let problems = t32Problems(db)
    if !problems.isEmpty {
        Issue.record("\(label): \(problems.count) problems, first: \(problems.prefix(3).joined(separator: "; "))",
                     sourceLocation: sourceLocation)
    }
}

// MARK: drawing the photos

private enum T32Content {
    case noise(seed: Int, side: Int)
    case text(String)
}

private func t32Noise(seed: Int, side: Int) -> CGImage? {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    var state = UInt64(truncatingIfNeeded: seed) &* 2_654_435_761 &+ 12_345
    for index in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        pixels[index] = UInt8(truncatingIfNeeded: state >> 33)
        pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 41)
        pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 49)
        pixels[index + 3] = 255
    }
    return pixels.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
}

/// Large, clear, black bold text on white, centred: what "Vision OCR on the full image" must read.
private func t32Text(_ text: String) -> CGImage? {
    let width = 1500, height = 500
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 190, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, [])
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                                   y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, context)
    return context.makeImage()
}

private func t32Data(_ content: T32Content, png: Bool) -> Data {
    let image: CGImage?
    switch content {
    case .noise(let seed, let side): image = t32Noise(seed: seed, side: side)
    case .text(let text): image = t32Text(text)
    }
    let data = NSMutableData()
    if let image, let destination = CGImageDestinationCreateWithData(
        data, (png ? "public.png" : "public.jpeg") as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return data as Data
}

/// Writes (or rewrites in place) one photo and sets its modified time.
private func t32WritePhoto(_ url: URL, _ content: T32Content, mtime: TimeInterval) throws {
    let data = t32Data(content, png: url.pathExtension == "png")
    #expect(!data.isEmpty, "the test could not draw \(url.lastPathComponent)")
    try data.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                                          ofItemAtPath: url.path)
}

/// An hour or more in the past, so no "modified a moment ago" wait applies.
private let t32Past = Date().timeIntervalSince1970.rounded(.down) - 3600

/// One distinct word per photo; the name passage of photo n must be found by its word.
private let t32Words = [
    "amber", "basalt", "cedar", "dune", "ember", "fjord", "glacier", "harbor", "island", "jungle",
    "kelp", "lagoon", "meadow", "nebula", "orchid", "prairie", "quartz", "ridge", "savanna", "tundra",
    "umber", "valley", "willow", "xenon", "yarrow", "zenith", "alpine", "bramble", "canyon", "delta",
    "estuary", "fern", "grove", "heron", "iris", "juniper", "kestrel", "lotus", "moss", "nimbus",
]

private func t32Name(_ number: Int) -> String {
    String(format: "%@-%02d.%@", t32Words[(number - 1) % t32Words.count], number, number % 2 == 0 ? "png" : "jpg")
}

/// Photos 1...count in `directory`: noise unless `text` names a number; photo n is n seconds older than photo n-1
/// (so the newest is photo 1). `extra` adds named files with their own content and age rank.
private func t32MakePhotos(in directory: URL, count: Int, side: Int = 200, text: [Int: String] = [:]) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var made: [URL] = []
    for number in 1...count {
        let url = directory.appendingPathComponent(t32Name(number))
        let content: T32Content = text[number].map { .text($0) } ?? .noise(seed: number, side: side)
        try t32WritePhoto(url, content, mtime: t32Past - Double(number))
        made.append(url)
    }
    return made
}

// MARK: the throwaway world and the helper

private final class T32World {
    let root: URL
    let home: URL
    let photos: URL

    var support: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var indexFile: String { support.appendingPathComponent("index.sqlite").path }
    var indexLog: URL { sesameLogURL(support, "index.log") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sesame-t32-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        photos = root.appendingPathComponent("photos", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        // The app makes this folder (mode 0700) before it ever starts a helper.
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The first text recognition on a Mac compiles its model, which takes tens of seconds and is kept for every later
/// process. The test does it once itself, so a helper's first photo is not mistaken for a stall.
private let t32VisionWarm: Bool = {
    guard let image = t32Text("WARM UP 0123") else { return false }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return true
}()

/// Warming the test process does not warm the helper: the first text recognition in a freshly signed helper binary
/// compiles its model again, about 35 s measured, and a 30 s stall limit trips on the first photo (finding F19).
/// So, once per test process, one photo goes through a real helper first, with up to 120 s allowed for it (cap 150 s);
/// the tests' own stall limits then start from a warm binary. The throwaway world is its own; nothing is asserted
/// here, a helper that never warms makes the real test fail with its own message.
private let t32HelperWarm: Bool = {
    guard let world = try? T32World() else { return false }
    defer { world.remove() }
    guard (try? t32MakePhotos(in: world.photos, count: 1, text: [1: "WARM UP 0123"])) != nil,
          let helper = try? t32StartHelper(world) else { return false }
    defer { helper.stop() }
    helper.send(t32FoldersLine([world.photos]))
    return t32WaitDone(world, helper, total: 1, stall: 120, cap: 150).reachedAll
}()

private func t32WithWorld(_ body: (T32World) throws -> Void) throws {
    _ = t32VisionWarm
    _ = t32HelperWarm
    let world = try T32World()
    defer { world.remove() }
    try body(world)
}

private struct T32Models {
    let text: URL
    let mm: URL
}

private func t32StartHelper(_ world: T32World, models: T32Models? = nil) throws -> HelperProcess {
    let executable = try #require(KitPaths.debugHelper(),
                                  "debug SesameHelper not found next to the test bundle or in .build/debug")
    homeLock.lock()
    defer { homeLock.unlock() }
    let previousHome = getenv("HOME").map { String(cString: $0) }
    let previousFake = getenv("SESAME_FAKE_EMBEDDER").map { String(cString: $0) }
    setenv("HOME", world.home.path, 1)
    if models == nil { setenv("SESAME_FAKE_EMBEDDER", "1", 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if let previousFake { setenv("SESAME_FAKE_EMBEDDER", previousFake, 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    }
    var arguments = ["index"]
    if let models { arguments += ["--text-model", models.text.path, "--mm-model", models.mm.path] }
    return try HelperProcess(executable: executable, arguments: arguments)
}

private func t32JSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

/// The hand-written `folders` line of the Helper protocol table: the whole list, `code` false.
private func t32FoldersLine(_ folders: [URL]) -> String {
    let items = folders.map { "{\"path\":\(t32JSONString($0.path)),\"code\":false}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

private func t32Event(_ line: (text: String, at: Date)) -> HelperReply? {
    if let reply = HelperReply(line.text), reply.event != nil { return reply }
    Issue.record("a line from the helper is not one JSON object with an `event`: \(line.text.prefix(200))")
    return nil
}

private func t32Open(_ world: T32World) -> T32DB? { T32DB(path: world.indexFile) }

// MARK: waiting for the index, from outside

private struct T32Wait {
    let done: Int
    let total: Int
    let statuses: [String: Int]
    let seconds: Double
    let helperRunning: Bool
    var reachedAll: Bool { done == total }

    func why(_ helper: HelperProcess) -> String {
        "\(done) of \(total) files reached done after \(Int(seconds)) s, statuses \(statuses.isEmpty ? "none (no files rows)" : "\(statuses)"), helper \(helperRunning ? "still running" : "exited"), stderr: \(helper.errors)"
    }
}

/// Polls the index until `total` files are `done`, until nothing has changed for `stall` seconds, until `cap`
/// seconds in all, or until the helper is gone and nothing more can come.
private func t32WaitDone(_ world: T32World, _ helper: HelperProcess, total: Int,
                         stall: TimeInterval = 30, cap: TimeInterval = 240) -> T32Wait {
    let started = Date()
    var lastChange = started
    var lastDone = -1
    var db: T32DB?
    var statuses: [String: Int] = [:]
    while true {
        if db == nil { db = t32Open(world) }
        if let found = db?.statuses() {
            statuses = found
            let done = found["done"] ?? 0
            if done != lastDone { lastDone = done; lastChange = Date() }
            if done == total { break }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > stall || now.timeIntervalSince(started) > cap { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.2); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return T32Wait(done: max(lastDone, 0), total: total, statuses: statuses,
                   seconds: Date().timeIntervalSince(started), helperRunning: helper.isRunning)
}

/// Reads the whole `index.log` as lines, nil when there is none.
private func t32LogLines(_ world: T32World) -> [String]? {
    guard let text = try? String(contentsOf: world.indexLog, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

/// The embed units in the log: every line must be exactly `unit n=<k>`; returns the k's or the lines that are not.
private func t32Units(_ lines: [String]) -> (units: [Int], odd: [String]) {
    var units: [Int] = []
    var odd: [String] = []
    for line in lines {
        let parts = line.split(separator: "=", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "unit n", !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
           let k = Int(parts[1]) {
            units.append(k)
        } else {
            odd.append(line)
        }
    }
    return (units, odd)
}

/// The unit rule of the entry, applied to a log read back: only typed `unit n=<k>` lines, each k from 1 to 16,
/// and the k's add up to the number of embed inputs (one image per photo).
private func t32CheckUnits(_ world: T32World, inputs: Int, _ label: String) {
    guard let lines = t32LogLines(world) else {
        Issue.record("\(label): there is no index.log at \(world.indexLog.path)")
        return
    }
    let parsed = t32Units(lines)
    #expect(parsed.odd.isEmpty, "\(label): index.log holds lines that are not `unit n=<k>`: \(parsed.odd.prefix(3))")
    #expect(!parsed.units.isEmpty, "\(label): index.log holds no unit line")
    #expect(parsed.units.allSatisfy { (1...16).contains($0) },
            "\(label): a unit has n outside 1...16: \(parsed.units.filter { !(1...16).contains($0) })")
    #expect(parsed.units.reduce(0, +) == inputs,
            "\(label): the units add up to \(parsed.units.reduce(0, +)) inputs, expected \(inputs) (one image per photo); units \(parsed.units)")
    #expect(parsed.units.count >= (inputs + 15) / 16,
            "\(label): \(parsed.units.count) units cannot hold \(inputs) inputs at 16 a unit")
}

// MARK: the golden photos and the kit, for the real-model run

private func t32KitRoot() -> URL? {
    let env = ProcessInfo.processInfo.environment
    if let kit = env["KIT_ROOT"], !kit.isEmpty { return URL(fileURLWithPath: kit, isDirectory: true) }
    if let tmp = env["TMPDIR"], !tmp.isEmpty {
        return URL(fileURLWithPath: (tmp as NSString).appendingPathComponent("sesame-kit"), isDirectory: true)
    }
    return nil
}

/// Holds an advisory lock on a file in the kit root while `body` runs, so two tests (this one and GroupATests,
/// which builds the same golden folder through `kit-golden.sh prepare`) never build it at once.
private func t32WithGoldenLock<T>(_ kit: URL, _ body: () throws -> T) rethrows -> T {
    let path = kit.appendingPathComponent(".t32-golden.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return try body()
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("IndexPhotosTests", .serialized)
struct IndexPhotosTests {

    // MARK: all 40 reach done

    @Test func all40PhotosReachDoneEachWithOneNamePassageOfWordsAndOneImagePassage() throws {
        try t32WithWorld { world in
            let photos = try t32MakePhotos(in: world.photos, count: 40, text: [18: "INV-2026-04417"])
            let helper = try t32StartHelper(world)
            defer { helper.stop() }
            helper.send(t32FoldersLine([world.photos]))

            let wait = t32WaitDone(world, helper, total: 40)
            #expect(wait.reachedAll, "rows stay pending: \(wait.why(helper))")
            guard wait.reachedAll else { return }

            let db = try #require(t32Open(world), "no index.sqlite once all files are done")
            #expect(db.int("select count(*) from files") == 40, "the index does not hold exactly 40 files rows")
            t32ExpectWhole(db, "the index is not whole")
            // Three rows per photo: one file row, one name passage, one image passage (kit guess G4).
            #expect(db.int("select count(*) from passages") == 80, "passages: \(String(describing: db.int("select count(*) from passages"))), expected 80")
            #expect(db.int("select count(*) from files where status = 'done'") == 40)

            // The row of each photo still describes the file on disk after reading (stat before and after).
            let rows = try #require(db.rows("select path, kind, size, mtime_ns, inode, status from files"))
            for url in photos {
                let name = url.lastPathComponent
                let row = try #require(rows.first { t32Normal($0[0] ?? "") == t32Normal(url.path) }, "\(name) has no row")
                let info = try #require(t32Stat(url))
                #expect(row[1] == "photo", "\(name): kind \(row[1] ?? "nil")")
                #expect(row[2].flatMap { Int64($0) } == info.size, "\(name): size \(row[2] ?? "nil"), file is \(info.size)")
                #expect(row[3].flatMap { Int64($0) } == info.mtimeNs, "\(name): mtime_ns \(row[3] ?? "nil"), file is \(info.mtimeNs)")
                #expect(row[4].flatMap { UInt64($0) } == info.inode, "\(name): inode \(row[4] ?? "nil"), file is \(info.inode)")
                #expect(row[5] == "done", "\(name): status \(row[5] ?? "nil")")
            }

            // The name passage of each photo is words only: no vector, and its words (the file's own word) are
            // found by an fts MATCH on the name column, and by nothing else.
            let nameIDs = try #require(db.rows("select p.id, f.path from passages p join files f on f.id = p.file_id where p.source = 'name'"))
            #expect(nameIDs.count == 40, "\(nameIDs.count) name passages, expected 40")
            let nameByPath = Dictionary(uniqueKeysWithValues: nameIDs.compactMap { row -> (String, String)? in
                guard let id = row[0], let path = row[1] else { return nil }
                return (t32Normal(path), id)
            })
            for (index, url) in photos.enumerated() {
                let word = t32Words[index]
                let found = try #require(db.rows("select rowid from fts where fts match 'name:\(word)'"))
                    .compactMap { $0[0] }
                #expect(found == [nameByPath[t32Normal(url.path)] ?? "?"],
                        "a MATCH for the name word \"\(word)\" found passages \(found), expected only the name passage of \(url.lastPathComponent)")
            }
            let vectors = try #require(db.rows("select count(*) from passages where source = 'name' and vec is not null"))
            #expect(vectors.first?.first == "0", "a name passage holds a vector")

            // The image passage holds a real vector: 768 finite half floats of unit length (the fake's too).
            let blobs = try #require(db.blobs("select vec from passages where source = 'image'"))
            #expect(blobs.count == 40)
            for blob in blobs {
                let vector = t32Half(blob ?? Data())
                #expect(vector.count == 768, "an image vector has \(vector.count) numbers")
                #expect(vector.allSatisfy { $0.isFinite })
                let length = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
                #expect(abs(length - 1) < 0.01, "an image vector has length \(length), expected 1")
            }
        }
    }

    // MARK: OCR

    @Test func aMatchForTheLargeTextOnTheFtsBodyFindsTheFileThatCarriesIt() throws {
        try t32WithWorld { world in
            let photos = try t32MakePhotos(in: world.photos, count: 40, text: [18: "INV-2026-04417"])
            let carrier = photos[17]
            let helper = try t32StartHelper(world)
            defer { helper.stop() }
            helper.send(t32FoldersLine([world.photos]))
            let wait = t32WaitDone(world, helper, total: 40)
            #expect(wait.reachedAll, "rows stay pending: \(wait.why(helper))")
            guard wait.reachedAll else { return }

            let db = try #require(t32Open(world))
            let hits = try #require(db.rows("""
                select p.id, f.path, p.source from fts join passages p on p.id = fts.rowid join files f on f.id = p.file_id \
                where fts match 'body:"INV-2026-04417"'
                """))
            #expect(hits.count == 1, "a MATCH for INV-2026-04417 on the body found \(hits.count) passages: \(hits.map { (($0[1] ?? "") as NSString).lastPathComponent })")
            if let hit = hits.first {
                #expect(t32Normal(hit[1] ?? "") == t32Normal(carrier.path),
                        "the MATCH found \((hit[1] ?? "") as NSString), expected \(carrier.lastPathComponent)")
                #expect(hit[2] == "image", "the text is held by a \(hit[2] ?? "nil") passage, expected the image passage")
            }
            // A MATCH on the text finds nothing among the file names, and a word nobody drew finds nothing.
            let inName = try #require(db.rows("select rowid from fts where fts match 'name:\"INV-2026-04417\"'"))
            #expect(inName.isEmpty, "the text is in a name passage: the name is words of the file name only")
            let absent = try #require(db.rows("select rowid from fts where fts match 'body:\"INV-2026-99999\"'"))
            #expect(absent.isEmpty, "a MATCH for a text no photo carries found \(absent.count) passages")
        }
    }

    // MARK: crash safety

    @Test func aPhotoNamedCrashAlways1KillsTheHelperWhileTheOtherPhotosAreUntouched() throws {
        try t32WithWorld { world in
            let photos = try t32MakePhotos(in: world.photos, count: 39)
            let crash = world.photos.appendingPathComponent("crash-always-1.jpg")
            // Born in the middle of the queue, whichever end the helper starts from.
            try t32WritePhoto(crash, .noise(seed: 777, side: 200), mtime: t32Past - 19.5)
            let before = photos.compactMap { url in t32Stat(url).map { (url, $0) } }

            let helper = try t32StartHelper(world)
            defer { helper.stop() }
            helper.send(t32FoldersLine([world.photos]))
            // stdin stays open: this is a death, not the EOF exit and not the 60 s idle exit.
            let exit = helper.waitForExit(timeout: 45)
            #expect(exit != nil, "the helper was still running 45 s after it was given crash-always-1.jpg; it should have died")
            guard let exit else { return }
            #expect(exit.status != 0, "the helper exited with status 0 on crash-always-1.jpg; a crash is not a clean exit")

            let db = try #require(t32Open(world), "no index.sqlite after the helper died")
            #expect(db.integrity() == "ok", "integrity_check after the crash: \(db.integrity())")
            #expect(db.int("select count(*) from files") == 40, "the index lost files rows in the crash")
            t32ExpectWhole(db, "after the crash a file is half written")
            let crashed = try #require(db.rows("select status from files where path like '%/crash-always-1.jpg'"))
            #expect(crashed.first?.first != "done", "crash-always-1.jpg reached done though reading it kills the helper")
            for (url, info) in before {
                let now = t32Stat(url)
                #expect(now?.size == info.size && now?.mtimeNs == info.mtimeNs, "\(url.lastPathComponent) was touched on disk")
            }

            // The app starts a fresh helper after a death. Without the one bad file, it finishes the rest.
            try FileManager.default.removeItem(at: crash)
            let second = try t32StartHelper(world)
            defer { second.stop() }
            second.send(t32FoldersLine([world.photos]))
            let wait = t32WaitDone(world, second, total: 39)
            #expect(wait.reachedAll, "a fresh helper did not finish the other photos: \(wait.why(second))")
            if let after = t32Open(world) {
                #expect(after.integrity() == "ok")
                t32ExpectWhole(after, "after the restart")
                #expect(after.int("select count(*) from passages") == 78, "passages after the restart: \(String(describing: after.int("select count(*) from passages"))), expected 78")
            }
        }
    }

    @Test func sigkillAtSeveralPointsLeavesIntegrityOkAndEveryFileAllNewOrAllOld() throws {
        try t32WithWorld { world in
            _ = try t32MakePhotos(in: world.photos, count: 40, side: 256)
            let line = t32FoldersLine([world.photos])
            // Kill points: right after the walk, then after 1 more file, 5, 7, 8 and 9 more, each time on a fresh
            // helper over the same index (the app restarts the helper after a death).
            let steps = [0, 1, 5, 7, 8, 9]
            var killedMidWork = 0
            var doneBefore = 0
            for (cycle, step) in steps.enumerated() {
                let helper = try t32StartHelper(world)
                helper.send(line)
                if step == 0 {
                    var sawWalked = false
                    let deadline = Date().addingTimeInterval(60)
                    while Date() < deadline, !sawWalked {
                        guard let got = helper.nextLine(timeout: 1) else { if helper.isRunning { continue } else { break } }
                        if t32Event(got)?.event == "walked" { sawWalked = true }
                    }
                    #expect(sawWalked, "cycle \(cycle): no `walked` event; stderr: \(helper.errors)")
                } else {
                    let target = min(39, doneBefore + step)
                    var db: T32DB?
                    var lastChange = Date()
                    var lastDone = -1
                    while true {
                        if db == nil { db = t32Open(world) }
                        let done = db?.statuses()?["done"] ?? 0
                        if done != lastDone { lastDone = done; lastChange = Date() }
                        if done >= target { break }
                        if Date().timeIntervalSince(lastChange) > 30 || !helper.isRunning { break }
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    #expect(lastDone >= target, "cycle \(cycle): the helper never got to \(target) done files (at \(max(lastDone, 0))): rows stay pending; stderr: \(helper.errors)")
                }
                kill(helper.pid, SIGKILL)
                _ = helper.waitForExit(timeout: 10)
                helper.stop()

                let db = try #require(t32Open(world), "cycle \(cycle): no index.sqlite after SIGKILL")
                #expect(db.integrity() == "ok", "cycle \(cycle): integrity_check after SIGKILL: \(db.integrity())")
                t32ExpectWhole(db, "cycle \(cycle): after SIGKILL a file is neither all-new nor all-old")
                #expect(db.int("select count(*) from files") == 40, "cycle \(cycle): files rows after SIGKILL: \(String(describing: db.int("select count(*) from files")))")
                let done = db.int("select count(*) from files where status = 'done'") ?? 0
                #expect(done >= doneBefore, "cycle \(cycle): files went back from done to pending across a kill (\(doneBefore) to \(done))")
                if done > 0 && done < 40 { killedMidWork += 1 }
                doneBefore = done
            }
            #expect(killedMidWork >= 3, "only \(killedMidWork) of \(steps.count) kills landed while work was left (some done, some pending): the kill points did not land mid-work")

            // A restarted helper finishes the folder, with nothing doubled by the interrupted attempts.
            let last = try t32StartHelper(world)
            defer { last.stop() }
            last.send(line)
            let wait = t32WaitDone(world, last, total: 40, stall: 30)
            #expect(wait.reachedAll, "after the kills a fresh helper did not finish: \(wait.why(last))")
            if let db = t32Open(world) {
                #expect(db.integrity() == "ok")
                t32ExpectWhole(db, "after the last restart")
                #expect(db.int("select count(*) from passages") == 80, "passages after the kills: \(String(describing: db.int("select count(*) from passages"))), expected 80")
            }
        }
    }

    // MARK: a changed file

    @Test func aFileChangedBetweenBatchesIsReplacedInOneTransaction() throws {
        try t32WithWorld { world in
            let oldText = "ZEBRA-OLD-1111", newText = "KITE-NEW-2222"
            let photos = try t32MakePhotos(in: world.photos, count: 40, text: [5: oldText])
            let target = photos[4]
            let helper = try t32StartHelper(world)
            defer { helper.stop() }
            let line = t32FoldersLine([world.photos])
            helper.send(line)
            let first = t32WaitDone(world, helper, total: 40)
            #expect(first.reachedAll, "rows stay pending: \(first.why(helper))")
            guard first.reachedAll else { return }

            let db = try #require(t32Open(world))
            let oldSize = try #require(t32Stat(target)?.size)
            let escaped = target.path.replacingOccurrences(of: "'", with: "''")
            let normalized = t32Normal(target.path).replacingOccurrences(of: "'", with: "''")
            let before = try #require(db.rows("select p.id from passages p join files f on f.id = p.file_id where f.path != '\(escaped)' and f.path != '\(normalized)' order by p.id"))
            #expect(before.count == 78)
            let oldHit = try #require(db.rows("select rowid from fts where fts match 'body:\"\(oldText)\"'"))
            #expect(oldHit.count == 1, "before the change a MATCH for \(oldText) found \(oldHit.count) passages, expected 1")

            // The file changes between batches: new picture, new text, new size and time. Then the same folders line.
            try t32WritePhoto(target, .text(newText), mtime: t32Past - 1800)
            let newSize = try #require(t32Stat(target)?.size)
            #expect(newSize != oldSize, "the test's rewrite did not change the file's size")
            helper.send(line)

            // A reader that looks as fast as it can may see the old file, a pending one with nothing in it, or the
            // new one complete. Never a file with its new size and old words, or done with half its passages.
            var states: [String] = []
            var violations: [String] = []
            var reader: T32DB?
            let started = Date()
            var lastChange = started
            var lastState = ""
            while Date().timeIntervalSince(started) < 90 {
                if reader == nil { reader = t32Open(world) }
                guard let db = reader, db.begin() else { continue }
                let row = db.rows("select id, size, status from files where path in ('\(escaped)', '\(normalized)')")
                var state = "no row"
                if let row = row?.first, let id = row[0] {
                    let size = row[1].flatMap { Int64($0) }
                    let status = row[2] ?? "nil"
                    let parts = db.rows("select p.source, p.modality, coalesce(length(p.vec), -1), x.body from passages p join fts x on x.rowid = p.id where p.file_id = \(id) order by p.id") ?? []
                    let image = parts.first { $0[0] == "image" }
                    let body = (image?[3] ?? "").uppercased()
                    let complete = parts.count == 2 && image != nil && parts.contains { $0[0] == "name" } && image?[2] == "1536"
                    if size == oldSize, status == "done", complete, body.contains(oldText), !body.contains(newText) {
                        state = "old"
                    } else if size == newSize, status == "pending", parts.isEmpty {
                        state = "pending"
                    } else if size == newSize, status == "done", complete, body.contains(newText), !body.contains(oldText) {
                        state = "new"
                    } else {
                        state = "inconsistent"
                        violations.append("size \(String(describing: size)) (old \(oldSize), new \(newSize)), status \(status), passages \(parts.map { $0[0] ?? "?" }), body \"\(body.prefix(40))\"")
                    }
                }
                db.end()
                if state != lastState { states.append(state); lastState = state; lastChange = Date() }
                if state == "new" { break }
                if Date().timeIntervalSince(lastChange) > 30 { break }
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !violations.isEmpty {
                Issue.record("a reader saw the changed file in a half state (\(violations.count) times), first: \(violations[0])")
            }
            #expect(states.last == "new", "the changed file never became new and complete; states seen \(states); stderr: \(helper.errors)")

            let after = try #require(t32Open(world))
            #expect(after.integrity() == "ok")
            t32ExpectWhole(after, "after the replacement")
            let oldAfter = try #require(after.rows("select rowid from fts where fts match 'body:\"\(oldText)\"'"))
            #expect(oldAfter.isEmpty, "the old words of the file are still in the index")
            let newAfter = try #require(after.rows("select p.source, f.path from fts join passages p on p.id = fts.rowid join files f on f.id = p.file_id where fts match 'body:\"\(newText)\"'"))
            #expect(newAfter.count == 1 && newAfter.first?[0] == "image" && t32Normal(newAfter.first?[1] ?? "") == t32Normal(target.path),
                    "a MATCH for the new text found \(newAfter)")
            #expect(after.int("select count(*) from passages") == 80, "passages after the change: \(String(describing: after.int("select count(*) from passages"))), expected 80")
            let otherAfter = try #require(after.rows("select p.id from passages p join files f on f.id = p.file_id where f.path != '\(escaped)' and f.path != '\(normalized)' order by p.id"))
            #expect(otherAfter == before, "the passages of the 39 unchanged files changed")
        }
    }

    // MARK: batches, commits and `changed`

    private struct Observation {
        var changed: [(at: Date, files: Int, done: Int)] = []
        var rises: [(at: Date, from: Int, to: Int)] = []
        var finalDone = 0
        var seconds = 0.0
        var helperRunning = true
    }

    /// Looks at the index as fast as it can while the helper works, and stamps every `changed` event with what the
    /// index held when the event was read (and with the moment it arrived).
    private func observe(_ world: T32World, _ helper: HelperProcess, total: Int) -> Observation {
        var observation = Observation()
        let started = Date()
        var lastProgress = started
        var finishedAt: Date?
        var db: T32DB?
        var lastDone = 0
        while true {
            if let line = helper.nextLine(timeout: 0.003) {
                if let reply = t32Event(line), reply.event == "changed" {
                    if db == nil { db = t32Open(world) }
                    let row = db?.rows("select (select count(*) from files), (select count(*) from files where status = 'done')")?.first
                    observation.changed.append((line.at, row?[0].flatMap { Int($0) } ?? -1, row?[1].flatMap { Int($0) } ?? -1))
                }
            }
            if db == nil { db = t32Open(world) }
            let now = Date()
            if let done = db?.int("select count(*) from files where status = 'done'"), done != lastDone {
                if done > lastDone { observation.rises.append((now, lastDone, done)) }
                lastDone = done
                lastProgress = now
            }
            if lastDone == total {
                if finishedAt == nil { finishedAt = now }
                if now.timeIntervalSince(finishedAt!) > 2 { break }
            } else if now.timeIntervalSince(lastProgress) > 30 || now.timeIntervalSince(started) > 240 {
                break
            }
        }
        observation.finalDone = lastDone
        observation.seconds = Date().timeIntervalSince(started)
        observation.helperRunning = helper.isRunning
        return observation
    }

    @Test func batchesAreUpToTwentyFiveFiles() throws {
        try t32WithWorld { world in
            _ = try t32MakePhotos(in: world.photos, count: 80, side: 160)
            let helper = try t32StartHelper(world)
            defer { helper.stop() }
            helper.send(t32FoldersLine([world.photos]))
            let seen = observe(world, helper, total: 80)
            #expect(seen.finalDone == 80, "\(seen.finalDone) of 80 files reached done after \(Int(seen.seconds)) s: rows stay pending; stderr: \(helper.errors)")
            guard seen.finalDone == 80 else { return }
            // A commit that held more than 25 files would show as one step of more than 25 finished files.
            let widest = seen.rises.map { $0.to - $0.from }.max() ?? 0
            #expect(widest <= 25, "the index gained \(widest) finished files in one step: a batch is up to 25 files")
            // 80 files cannot be told about in fewer than the reconcile plus 4 batches of 25.
            #expect(seen.changed.count >= 5, "only \(seen.changed.count) `changed` events for 80 files: one for the walk and at least one per 25 files are due")
        }
    }

    @Test func changedFollowsEachCommitAndNeverComesBeforeIt() throws {
        try t32WithWorld { world in
            _ = try t32MakePhotos(in: world.photos, count: 40)
            let helper = try t32StartHelper(world)
            defer { helper.stop() }
            helper.send(t32FoldersLine([world.photos]))
            let seen = observe(world, helper, total: 40)
            #expect(seen.finalDone == 40, "\(seen.finalDone) of 40 files reached done after \(Int(seen.seconds)) s: rows stay pending; stderr: \(helper.errors)")
            guard seen.finalDone == 40 else { return }
            let first = try #require(seen.changed.first, "no `changed` event at all")
            #expect(first.files == 40, "the first `changed` arrived with \(first.files) files rows in the index, expected 40 (the walk's commit)")
            let last = try #require(seen.changed.last)
            #expect(last.done == 40, "the last `changed` arrived when \(last.done) of 40 files were done: a commit was not announced")
            // Every step the index took is followed by a `changed` within 2 s; none is announced late or never.
            let times = seen.changed.map { $0.at }
            for rise in seen.rises {
                let announced = times.contains { $0 >= rise.at.addingTimeInterval(-0.05) && $0 <= rise.at.addingTimeInterval(2) }
                #expect(announced, "the index went from \(rise.from) to \(rise.to) done files and no `changed` followed within 2 s")
            }
            // And never before: at its arrival, the index already holds everything it said.
            var previous = 0
            for event in seen.changed {
                #expect(event.done >= previous, "a `changed` arrived with fewer files done (\(event.done)) than the one before (\(previous))")
                previous = max(previous, event.done)
            }
        }
    }

    // MARK: embed units

    @Test func embedUnitsAreAtMost16InputsEachOneTypedLineInIndexLog() throws {
        try t32WithWorld { world in
            _ = try t32MakePhotos(in: world.photos, count: 40)
            let helper = try t32StartHelper(world)
            defer { helper.stop() }
            helper.send(t32FoldersLine([world.photos]))
            let wait = t32WaitDone(world, helper, total: 40)
            #expect(wait.reachedAll, "rows stay pending: \(wait.why(helper))")
            guard wait.reachedAll else { return }
            Thread.sleep(forTimeInterval: 1)
            t32CheckUnits(world, inputs: 40, "fake run over 40 photos")
        }
    }

    // MARK: the cached model

    @Test func withTheCachedModelTheGoldenPhotosReachDoneWithTheModelLoadedForTheBatchAndUnloadedAfter() throws {
        let kit = try #require(t32KitRoot(), "no KIT_ROOT and no TMPDIR: cannot find the kit")
        let textModel = kit.appendingPathComponent("cache/embeddinggemma-2-Q8_0.gguf")
        let mmModel = kit.appendingPathComponent("cache/mmproj-embeddinggemma-2-Q8_0.gguf")
        try #require(FileManager.default.fileExists(atPath: textModel.path),
                     "model file missing: \(textModel.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
        try #require(FileManager.default.fileExists(atPath: mmModel.path),
                     "model file missing: \(mmModel.path) (seed the cache: scripts/kit-mirror.sh seed --real)")

        // The kit builds the golden photos (nothing is rewritten when the folder is already right).
        let build = t32WithGoldenLock(kit) {
            Tools.capture("/bin/bash", [KitPaths.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", "golden"])
        }
        let built = try #require(build, "scripts/kit-fixtures.sh could not run")
        try #require(built.status == 0, "scripts/kit-fixtures.sh build golden exited \(built.status): \(built.output.suffix(300))")
        let golden = kit.appendingPathComponent("fixtures/golden", isDirectory: true).resolvingSymlinksInPath()
        try #require(FileManager.default.fileExists(atPath: golden.path), "the golden folder is missing: \(golden.path)")

        try t32WithWorld { world in
            let helper = try t32StartHelper(world, models: T32Models(text: textModel, mm: mmModel))
            defer { helper.stop() }
            helper.send(t32FoldersLine([golden]))

            // While photos are being read (some done, some not) the model must be in memory: a mapped .gguf in
            // the helper's open files, or a footprint no model-less helper reaches.
            var loadedWhileWorking = false
            var loadedEvidence = ""
            var db: T32DB?
            var done = 0
            var lastChange = Date()
            let started = Date()
            var nextSample = Date()
            while done < 40 {
                if db == nil { db = t32Open(world) }
                if let found = db?.statuses() {
                    let now = found["done"] ?? 0
                    if now != done { done = now; lastChange = Date() }
                }
                if done >= 40 { break }
                if !helper.isRunning || Date().timeIntervalSince(lastChange) > 180 || Date().timeIntervalSince(started) > 1200 { break }
                if !loadedWhileWorking, Date() >= nextSample {
                    let open = Tools.capture("/usr/sbin/lsof", ["-n", "-P", "-p", String(helper.pid)])?.output ?? ""
                    let footprint = Tools.footprintMB(pid: helper.pid) ?? 0
                    if open.contains(".gguf") || footprint >= 400 {
                        loadedWhileWorking = true
                        loadedEvidence = open.contains(".gguf") ? "a .gguf file is open" : "footprint \(Int(footprint)) MB"
                    }
                    nextSample = Date().addingTimeInterval(1)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            let statuses = db?.statuses() ?? [:]
            #expect(done == 40, "\(done) of 40 golden photos reached done after \(Int(Date().timeIntervalSince(started))) s, statuses \(statuses), helper \(helper.isRunning ? "still running" : "exited"), stderr: \(helper.errors)")
            guard done == 40 else { return }
            #expect(loadedWhileWorking, "the model never looked loaded while photos were being read: no .gguf in the helper's open files and a footprint under 400 MB")
            if loadedWhileWorking { print("T32 model loaded while working: \(loadedEvidence)") }

            // Done: stdin is still open and the helper alive; the model goes away with the batch, long before
            // the 60 s idle exit.
            var unloaded = false
            var last = ""
            let waitStart = Date()
            while Date().timeIntervalSince(waitStart) < 20, helper.isRunning {
                let open = Tools.capture("/usr/sbin/lsof", ["-n", "-P", "-p", String(helper.pid)])?.output ?? ""
                let footprint = Tools.footprintMB(pid: helper.pid) ?? .infinity
                last = "\(open.contains(".gguf") ? "a .gguf file is open" : "no .gguf open"), footprint \(Int(footprint)) MB"
                if !open.contains(".gguf") && footprint < 300 { unloaded = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            #expect(helper.isRunning, "the helper exited before the model could be seen unloaded; stderr: \(helper.errors)")
            #expect(unloaded, "20 s after the last photo was done the model still looks loaded: \(last)")

            let reader = try #require(t32Open(world))
            #expect(reader.integrity() == "ok")
            #expect(reader.int("select count(*) from files") == 40, "files rows: \(String(describing: reader.int("select count(*) from files"))), expected 40")
            t32ExpectWhole(reader, "the golden index is not whole")
            let blobs = try #require(reader.blobs("select vec from passages where source = 'image'"))
            #expect(blobs.count == 40, "\(blobs.count) image passages, expected 40")
            for blob in blobs {
                let vector = t32Half(blob ?? Data())
                let length = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
                #expect(vector.count == 768 && vector.allSatisfy { $0.isFinite } && abs(length - 1) < 0.01,
                        "a golden image vector is not 768 finite numbers of unit length (count \(vector.count), length \(length))")
            }
            t32CheckUnits(world, inputs: 40, "real run over the golden photos")
        }
    }
}
}
