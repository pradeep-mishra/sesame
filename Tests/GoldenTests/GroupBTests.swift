import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-3-t18, tester step. The group b golden test (spec S2.2, S2.3, S2.8 (i) to (iii)): an exact string typed whole finds
// its file first. Written from the t18 entry and Conventions of plan-3-tasks.md, GroupATests for the interface, the answer key
// fixtures/answers.csv and the spec only; no product source read. Every expected value is the key's or hand-written here;
// none is computed from the code under test.
//
// What it checks, through the engine's public interface (`scripts/kit-golden.sh prepare` as a child, `IndexReader`,
// `LlamaEmbedder` with the cached text model, `Search`), on the index of the 40 golden photos:
//   1. Each readable `exact` row (the six whose file is a photo: exact-01 to -04, -07, -08) has its file FIRST.
//   2. The decoy rows' photo files are in the index and below the exact file.
//   3. The `missing` row (one token, in no file) returns a non-empty list (the closest files) and nothing throws.
//   4. Strings of two, three and four words that are in no file return an EMPTY list. This is the one place a pass depends
//      on the model: the tester runs this suite before any product change and stops with STOP-ASK on a nonsense string
//      that already returns a row.
// It prints `GOLDEN <row id> rank <n|none>` for every readable row (the line `kit-golden.sh engine --group b` reads) and
// writes `golden-engine.tsv` rows of group `b` in the kit's format (header `id group query expected rank locator pass`),
// keeping the rows of other groups.
//
// This file also holds the helpers MergeTests and ExtensionsTests share (`GB`, `GBHelper`, `GBFailure`): the test target
// has no other common file and these three files are the only ones the task may write.
//
// It never skips: a missing model, bundle, helper or index is a failure that names the missing piece.

struct GBFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

enum GB {
    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let bundledHelper = projectRoot.appendingPathComponent("dist/Sesame.app/Contents/MacOS/SesameHelper")
    static let photoExtensions: Set<String> = ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]
    static let homeLock = NSLock()

    // MARK: places

    static func kitRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let kit = env["KIT_ROOT"], !kit.isEmpty { return URL(fileURLWithPath: kit, isDirectory: true) }
        if let tmp = env["TMPDIR"], !tmp.isEmpty {
            return URL(fileURLWithPath: (tmp as NSString).appendingPathComponent("sesame-kit"), isDirectory: true)
        }
        return nil
    }

    /// The system's own resolution (`/var/...` and `/private/var/...` come out the same).
    static func realpathOf(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func models(kit: URL) throws -> (text: URL, mm: URL) {
        let text = kit.appendingPathComponent("cache/embeddinggemma-2-Q8_0.gguf")
        let mm = kit.appendingPathComponent("cache/mmproj-embeddinggemma-2-Q8_0.gguf")
        for url in [text, mm] where !FileManager.default.fileExists(atPath: url.path) {
            throw GBFailure("model file missing: \(url.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
        }
        return (text, mm)
    }

    static func tail(_ text: String, _ lines: Int = 6) -> String {
        text.split(separator: "\n").suffix(lines).joined(separator: " / ")
    }

    // MARK: the answer key

    struct Answer: Sendable {
        let id: String
        let group: String
        let query: String
        let file: String
        let note: String
        /// The number at the end of the id (`exact-07` is 7).
        var number: Int? {
            let digits = id.reversed().prefix { $0.isNumber }.reversed()
            return Int(String(digits))
        }
        var isPhoto: Bool { GB.photoExtensions.contains((file as NSString).pathExtension.lowercased()) }
    }

    /// Every row of fixtures/answers.csv: `id,group,query,file,locator,window_s,note`, no comma inside a field.
    static func answers() throws -> [Answer] {
        let url = projectRoot.appendingPathComponent("fixtures/answers.csv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GBFailure("fixtures/answers.csv is missing: \(url.path)")
        }
        var rows: [Answer] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            rows.append(Answer(id: f[0], group: f[1], query: f[2], file: f[3], note: f.count > 6 ? f[6] : ""))
        }
        return rows
    }

    /// The six readable exact rows, written by hand from the key: the exact rows whose expected file is a photo.
    static let readableIds = ["exact-01", "exact-02", "exact-03", "exact-04", "exact-07", "exact-08"]

    static func readableExact() throws -> [Answer] {
        let rows = try answers().filter { $0.group == "exact" && $0.isPhoto }
        guard rows.map(\.id) == readableIds else {
            throw GBFailure("the key's exact rows with a photo file are \(rows.map(\.id)), expected \(readableIds)")
        }
        return rows
    }

    // MARK: children and the golden folder

    static func runChild(_ exe: String, _ args: [String], env: [String: String] = [:], cwd: URL? = nil,
                         limit: TimeInterval) -> (status: Int32, output: String)? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("gb-out-" + UUID().uuidString)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        guard let handle = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        process.environment = environment
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(limit)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        var status: Int32
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            status = 124
        } else {
            status = process.terminationStatus
        }
        try? handle.synchronize()
        return (status, (try? String(contentsOf: out, encoding: .utf8)) ?? "")
    }

    /// An advisory lock in the kit root while `body` runs, so the tests that build or copy the shared golden folder (these
    /// three suites, GroupATests and IndexPhotosTests) never touch it at once.
    static func withGoldenLock<T>(_ kit: URL, _ body: () throws -> T) rethrows -> T {
        let path = kit.appendingPathComponent(".t32-golden.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }

    /// The folder the kit writes golden-engine.tsv into: the evidence folder of the starting state, else `run/`.
    static func evidenceFolder(_ kit: URL) -> URL {
        let pointer = kit.appendingPathComponent("run/evidence-dir")
        if let text = try? String(contentsOf: pointer, encoding: .utf8) {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return kit.appendingPathComponent("run", isDirectory: true)
    }

    static func passWord(_ rank: Int?) -> String {
        switch rank {
        case 1: return "first"
        case 2, 3: return "top3"
        default: return "miss"
        }
    }

    // MARK: the index

    static func indexFile(home: String) -> String { home + "/Library/Application Support/Sesame/index.sqlite" }

    static func makeSupportFolder(home: String) throws {
        let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Every `files` row as (path, status), read with this file's own read-only connection; nil while it cannot be read.
    static func indexRows(home: String) -> [(path: String, status: String)]? {
        let path = indexFile(home: home)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close_v2(db); return nil }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select path, status from files", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [(path: String, status: String)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let path = sqlite3_column_text(statement, 0), let status = sqlite3_column_text(statement, 1) else { continue }
            out.append((String(cString: path), String(cString: status)))
        }
        return out
    }

    /// IndexReader finds the index under HOME the first time it answers; HOME is set for that one call only and put back
    /// at once, under a lock (the three suites of this target share the process).
    static func openReader(home: String, files: Int) -> (reader: IndexReader?, count: Int) {
        var count = -1
        for _ in 0..<25 {
            homeLock.lock()
            let previous = getenv("HOME").map { String(cString: $0) }
            setenv("HOME", home, 1)
            let candidate = IndexReader()
            count = candidate.fileCount()
            if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") }
            homeLock.unlock()
            if count == files { return (candidate, count) }
            candidate.close()
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (nil, count)
    }

    static func visible(_ folders: [String]) -> Visible {
        var paths = Set<String>()
        for folder in folders {
            paths.insert(folder)
            paths.insert(realpathOf(folder))
            paths.insert(URL(fileURLWithPath: folder).resolvingSymlinksInPath().path)
        }
        let list = paths.sorted().map { Settings.Folder(path: $0, code: false, reading: true) }
        return Visible(folders: list, codeSearchOn: false,
                       kindsOn: ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true])
    }

    /// The ranked paths for one typed text, or nil when the newest ticket got no list.
    static func ranked(_ search: Search, _ text: String, _ vector: [Float], _ visible: Visible) -> [String]? {
        let ticket = search.newTicket()
        guard let hits = search.rank(text: text, vector: vector, ticket: ticket, visible: visible) else { return nil }
        return hits.map { $0.path }
    }

    /// The 1-based place of `<folder>/<file>` in the paths, or nil.
    static func place(of file: String, in paths: [String], folder: String = "golden") -> Int? {
        let wanted = "/\(folder)/" + file
        return paths.firstIndex { $0.hasSuffix(wanted) }.map { $0 + 1 }
    }

    /// The cached text model embeds the queries (the helper embeds the photos with the other one).
    static func embedQueries(_ texts: [String], textModel: URL) throws -> [String: [Float]] {
        let embedder = LlamaEmbedder(textModel: textModel)
        try embedder.load()
        defer { embedder.unload() }
        var out: [String: [Float]] = [:]
        for text in texts where out[text] == nil { out[text] = try embedder.embed(text, role: .query) }
        return out
    }

    // MARK: settling a helper

    struct Settled {
        let ok: Bool
        let note: String
        let rows: [(path: String, status: String)]
    }

    /// Waits until the index holds `expected` rows, none is `pending` and the rows have stayed the same for 3 seconds. Gives
    /// up when the helper has exited, when nothing has changed for `stall` seconds or after `cap` seconds.
    static func settle(home: String, helper: GBHelper, rows expected: Int,
                       stall: TimeInterval = 300, cap: TimeInterval = 1500) -> Settled {
        let started = Date()
        var lastChange = Date()
        var last = ""
        var rows: [(path: String, status: String)] = []
        while Date().timeIntervalSince(started) < cap {
            if let read = indexRows(home: home) {
                rows = read
                let key = rows.map { "\($0.path)|\($0.status)" }.sorted().joined(separator: "\n")
                if key != last { last = key; lastChange = Date() }
                let pending = rows.filter { $0.status == "pending" }.count
                if rows.count == expected && pending == 0 && Date().timeIntervalSince(lastChange) >= 3 {
                    return Settled(ok: true, note: "", rows: rows)
                }
            }
            if !helper.isRunning {
                Thread.sleep(forTimeInterval: 0.3)
                return Settled(ok: false, note: "the helper exited with \(rows.count) rows (want \(expected)); stderr: \(helper.stderrText.suffix(400))", rows: rows)
            }
            if Date().timeIntervalSince(lastChange) > stall {
                return Settled(ok: false, note: "no change for \(Int(stall)) s: \(rows.count) rows (want \(expected)), pending \(rows.filter { $0.status == "pending" }.count); stderr: \(helper.stderrText.suffix(400))", rows: rows)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return Settled(ok: false, note: "no settled index within \(Int(cap)) s: \(rows.count) rows (want \(expected))", rows: rows)
    }

    // MARK: golden-engine.tsv and the odd/even split

    /// Writes the rows of one group into golden-engine.tsv, keeping the rows of other groups.
    static func writeGroupRows(kit: URL, group: String, rows: [(answer: Answer, rank: Int?)]) throws -> URL {
        let folder = evidenceFolder(kit)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tsv = folder.appendingPathComponent("golden-engine.tsv")
        var kept: [String] = []
        if let old = try? String(contentsOf: tsv, encoding: .utf8) {
            for (index, line) in old.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                if fields.count > 1, fields[1] != group { kept.append(String(line)) }
            }
        }
        var out = "id\tgroup\tquery\texpected\trank\tlocator\tpass\n"
        for line in kept { out += line + "\n" }
        for (answer, rank) in rows {
            out += "\(answer.id)\t\(group)\t\(answer.query)\t\(answer.file)\t\(rank.map(String.init) ?? "none")\t\t\(passWord(rank))\n"
        }
        try Data(out.utf8).write(to: tsv, options: .atomic)
        return tsv
    }
}

/// A bundled helper process alone (no app, no window): `SesameHelper index`, HOME at a throwaway folder, the fake embedder
/// unless `models` is given. Its stdout goes to the null device, so the test reads the index and not the events; the folders
/// line is sent on stdin.
final class GBHelper: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stderrFile: URL

    init(home: String, models: (text: URL, mm: URL)?, scratch: URL) throws {
        let executable = GB.bundledHelper
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw GBFailure("the bundled helper is missing: run `scripts/bundle.sh` (expected \(executable.path))")
        }
        signal(SIGPIPE, SIG_IGN)
        stderrFile = scratch.appendingPathComponent("helper-stderr-" + UUID().uuidString + ".txt")
        FileManager.default.createFile(atPath: stderrFile.path, contents: Data())
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        if models == nil { environment["SESAME_FAKE_EMBEDDER"] = "1" } else { environment.removeValue(forKey: "SESAME_FAKE_EMBEDDER") }
        process.executableURL = executable
        var arguments = ["index"]
        if let models { arguments += ["--text-model", models.text.path, "--mm-model", models.mm.path] }
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: stderrFile)
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    var stderrText: String { (try? String(contentsOf: stderrFile, encoding: .utf8)) ?? "" }

    /// One `folders` line: every path with its code tick off.
    func sendFolders(_ paths: [String]) {
        let items = paths.map { ["path": $0, "code": false] as [String: Any] }
        let object: [String: Any] = ["cmd": "folders", "folders": items]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
    }

    func stop() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: stderrFile)
    }
}

// MARK: the golden index and its ranked lists

nonisolated(unsafe) private var gbExitContext: GBContext?

/// The golden index made once by `kit-golden.sh prepare` and the ranked list of every readable exact row.
final class GBContext: @unchecked Sendable {
    let kit: URL
    let home: String
    let reader: IndexReader
    let search: Search
    let embedder: LlamaEmbedder
    let visible: Visible
    let readable: [GB.Answer]
    /// answer id to the ranked paths of its query
    var lists: [String: [String]] = [:]
    var ranks: [(answer: GB.Answer, rank: Int?)] = []

    init(kit: URL, home: String, reader: IndexReader, embedder: LlamaEmbedder, readable: [GB.Answer]) {
        self.kit = kit
        self.home = home
        self.reader = reader
        self.search = Search(reader: reader)
        self.embedder = embedder
        self.readable = readable
        let golden = kit.appendingPathComponent("fixtures/golden", isDirectory: true)
        self.visible = GB.visible([golden.path])
    }

    static let shared: Result<GBContext, GBFailure> = {
        do { return .success(try build()) } catch let failure as GBFailure { return .failure(failure) } catch {
            return .failure(GBFailure("\(error)"))
        }
    }()

    private static func build() throws -> GBContext {
        let readable = try GB.readableExact()
        guard let kit = GB.kitRoot() else { throw GBFailure("no KIT_ROOT and no TMPDIR: cannot find the kit") }
        let models = try GB.models(kit: kit)

        // The index of the 40 golden photos, made by the bundled helper through the kit.
        let prepared = GB.withGoldenLock(kit) {
            GB.runChild("/bin/bash", [GB.projectRoot.appendingPathComponent("scripts/kit-golden.sh").path, "prepare"],
                        cwd: GB.projectRoot, limit: 2400)
        }
        guard let prepare = prepared else { throw GBFailure("scripts/kit-golden.sh could not be run") }
        guard prepare.status == 0 else {
            throw GBFailure("kit-golden.sh prepare exited \(prepare.status): \(GB.tail(prepare.output))")
        }
        let lastLine = prepare.output.split(separator: "\n").last.map(String.init) ?? ""
        let suffix = "/Library/Application Support/Sesame/index.sqlite"
        guard lastLine.hasPrefix("/"), lastLine.hasSuffix(suffix) else {
            throw GBFailure("kit-golden.sh prepare did not end with the index path: \(GB.tail(prepare.output))")
        }
        guard FileManager.default.fileExists(atPath: lastLine) else { throw GBFailure("the index is missing: \(lastLine)") }
        let home = String(lastLine.dropLast(suffix.count))

        let opened = GB.openReader(home: home, files: 40)
        guard let reader = opened.reader else {
            throw GBFailure("the index at \(lastLine) holds \(opened.count) files, expected the 40 golden photos")
        }
        let embedder = LlamaEmbedder(textModel: models.text)
        try embedder.load()
        let context = GBContext(kit: kit, home: home, reader: reader, embedder: embedder, readable: readable)
        // The model stays loaded for the whole run; ggml aborts at process exit when its Metal device is freed while a
        // model is still loaded, so it is unloaded by an exit handler registered after the load (handlers run last in, first out).
        gbExitContext = context
        atexit {
            gbExitContext?.search.release()
            gbExitContext?.embedder.unload()
            gbExitContext?.reader.close()
        }

        for answer in readable {
            let vector = try embedder.embed(answer.query, role: .query)
            let paths = GB.ranked(context.search, answer.query, vector, context.visible) ?? []
            context.lists[answer.id] = paths
            let rank = GB.place(of: answer.file, in: paths)
            context.ranks.append((answer, rank))
            print("GOLDEN \(answer.id) rank \(rank.map(String.init) ?? "none")")
        }
        let tsv = try GB.writeGroupRows(kit: kit, group: "b", rows: context.ranks)
        let first = context.ranks.filter { $0.rank == 1 }.count
        print("GOLDEN engine group b: first \(first) of \(context.ranks.count) readable (need every readable row first); wrote \(tsv.path)")
        return context
    }
}

private func context() throws -> GBContext {
    switch GBContext.shared {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

@Suite("GroupBTests", .serialized)
struct GroupBTests {

    @Test func everyReadableExactRowHasItsPhotoFirst() throws {
        let ctx = try context()
        try #require(ctx.ranks.count == 6, "\(ctx.ranks.count) readable rows were ranked, expected 6: \(GB.readableIds)")
        let notFirst = ctx.ranks.filter { $0.rank != 1 }
        let detail = notFirst.map { "\($0.answer.id) \"\($0.answer.query)\" want \($0.answer.file) rank \($0.rank.map(String.init) ?? "none") (list: \((ctx.lists[$0.answer.id] ?? []).map { ($0 as NSString).lastPathComponent }))" }
        #expect(notFirst.isEmpty, "the exact photo is not first for \(notFirst.count) of 6 rows: \(detail.joined(separator: "; "))")
    }

    @Test func theDecoyRowsPhotoFilesAreInTheIndexAndBelowTheExactFile() throws {
        let ctx = try context()
        let rows = try GB.answers()
        let decoys = rows.filter { row in
            guard row.group == "decoy", row.isPhoto else { return false }
            return GB.readableIds.contains { row.note.hasPrefix("decoy-for=\($0);") }
        }
        // Hand-written from the key: the decoys of the six readable rows are decoy-01 to -04, -07 and -08, all photos.
        #expect(decoys.map(\.id) == ["decoy-01", "decoy-02", "decoy-03", "decoy-04", "decoy-07", "decoy-08"],
                "decoy rows of the readable exact rows: \(decoys.map(\.id))")
        let indexed = try #require(GB.indexRows(home: ctx.home), "the index at \(ctx.home) cannot be read")
        for decoy in decoys {
            let exactId = GB.readableIds.first { decoy.note.hasPrefix("decoy-for=\($0);") }
            let exact = try #require(ctx.readable.first { $0.id == exactId }, "no exact row \(exactId ?? "?") for \(decoy.id)")
            let row = indexed.first { $0.path.hasSuffix("/golden/" + decoy.file) }
            #expect(row?.status == "done", "\(decoy.id): its file \(decoy.file) is not in the index as done (\(row?.status ?? "no row"))")
            let list = ctx.lists[exact.id] ?? []
            let exactPlace = GB.place(of: exact.file, in: list)
            let decoyPlace = GB.place(of: decoy.file, in: list)
            #expect(exactPlace != nil, "\(decoy.id): for \"\(exact.query)\" the exact file \(exact.file) is not listed at all, list has \(list.count) rows")
            if let exactPlace, let decoyPlace {
                #expect(decoyPlace > exactPlace, "\(decoy.id): the decoy \(decoy.file) (place \(decoyPlace)) is not below the exact file \(exact.file) (place \(exactPlace)) for \"\(exact.query)\"")
            }
        }
    }

    @Test func theMissingRowOneTokenInNoFileReturnsANonEmptyListAndNothingThrows() throws {
        let ctx = try context()
        let missing = try #require(try GB.answers().first { $0.group == "missing" }, "no missing row in answers.csv")
        #expect(!missing.query.contains(" "), "the missing row is one token: \(missing.query)")
        let vector = try ctx.embedder.embed(missing.query, role: .query)
        let list = try #require(GB.ranked(ctx.search, missing.query, vector, ctx.visible), "the newest ticket got no list")
        #expect(!list.isEmpty, "\"\(missing.query)\" is in no file: the closest files are shown, the list must not be empty")
    }

    // The nonsense strings: words that are in no file name and no text of the golden files. A pass here depends on the
    // model, so a string that returns a row is a STOP-ASK for the tester and a question for the gate for the implementer.
    private static let nonsense: [(words: Int, text: String)] = [
        (2, "flurbo wazzik"), (2, "mrrgl tszzkq"),
        (3, "glorp snazzle quibbet"), (3, "yepnoh vlorbx drazzit"),
        (4, "blorf tszzk yepnoh vlimmer"), (4, "quazzle frimbo oglax dwemp"),
    ]

    @Test func stringsOfTwoThreeAndFourWordsInNoFileReturnAnEmptyList() throws {
        let ctx = try context()
        var gave: [String] = []
        for (words, text) in Self.nonsense {
            let vector = try ctx.embedder.embed(text, role: .query)
            let list = try #require(GB.ranked(ctx.search, text, vector, ctx.visible), "the newest ticket got no list for \"\(text)\"")
            print("NONSENSE words \(words) \"\(text)\" rows \(list.count)")
            if !list.isEmpty {
                gave.append("\"\(text)\" (\(words) words) returned \(list.count) rows: \(list.prefix(3).map { ($0 as NSString).lastPathComponent })")
            }
        }
        #expect(gave.isEmpty, "strings in no file returned rows: \(gave.joined(separator: "; "))")
    }
}
