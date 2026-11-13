import Foundation
import Testing
import SesameEngine

// plan-6-t3, tester step. Unticking a code folder reaches the index as a reconcile against an admitted set that no longer holds the code
// files. Every walk is a real `Walker.scan` of a real temp tree (WalkedFile cannot be built outside the module); the rows are seeded from
// what the walk saw with `IndexStore.addFile` and `addPassage`; the index file is read with this file's own read-only connection (`AtDB`).
// "One transaction" is observed from outside: a second connection takes consistent snapshots while the reconcile runs, and none may show
// some of the code files and not all of them, a passage without its file or its fts row, or an fts row without its passage.

private let rcDevice: Int64 = 1
private typealias RcFound = [(file: WalkedFile, device: Int64)]

private final class RcTree {
    let base: String
    private var made = 0

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sesame-rccode-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        base = url.resolvingSymlinksInPath().path
    }

    func path(_ relative: String) -> String { base + "/" + relative }

    @discardableResult
    func file(_ relative: String, _ text: String) throws -> String {
        made += 1
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(made))], ofItemAtPath: full)
        return full
    }

    func remove() { try? FileManager.default.removeItem(atPath: base) }
}

private func rcWithTree(_ body: (RcTree) throws -> Void) throws {
    let tree = try RcTree()
    defer { tree.remove() }
    try body(tree)
}

private func rcWalk(_ root: String, ticked: Bool) -> (found: RcFound, unreadable: [String]) {
    let scanned = Walker.scan(root: root, mode: .read, picks: [HelperFolder(path: root, code: ticked)])
    return (scanned.files.map { (file: $0, device: rcDevice) }, scanned.unreadable)
}

private func rcUnit(_ at: Int) -> [Float] {
    var vector = [Float](repeating: 0, count: 768)
    vector[at % 768] = 1
    return vector
}

private func rcSeed(_ store: IndexStore, _ found: RcFound, code: [String] = []) throws {
    var at = 0
    for entry in found {
        let name = (entry.file.path as NSString).lastPathComponent
        let id = try store.addFile(path: entry.file.path, kind: entry.file.kind, size: entry.file.size, mtimeNs: entry.file.mtimeNs,
                                   inode: Int64(entry.file.inode), device: entry.device, status: "done")
        _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: name, body: "")
        at += 1
        let word = "zq" + name.replacingOccurrences(of: ".", with: "") + "s1"
        _ = try store.addPassage(fileID: id, source: "chunk", start: 1, end: 1,
                                 modality: "text", vector: rcUnit(at), name: name, body: "body of \(word)")
    }
    for (number, path) in code.enumerated() {
        let name = (path as NSString).lastPathComponent
        let id = try store.addFile(path: path, kind: "code", size: 100, mtimeNs: 1_700_000_000_000_000_000,
                                   inode: Int64(900_000 + number), device: rcDevice, status: "done")
        _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: name, body: "")
        for stretch in 1...2 {
            at += 1
            let word = "zq" + name.replacingOccurrences(of: ".", with: "") + "s\(stretch)"
            _ = try store.addPassage(fileID: id, source: "code", start: Double(stretch), end: Double(stretch),
                                     modality: "text", vector: rcUnit(at), name: name, body: "body of \(word)")
        }
    }
}

private func rcReconcile(_ store: IndexStore, _ walk: (found: RcFound, unreadable: [String]), stamp: String) throws -> (added: Int, removed: Int) {
    let outcome = try store.reconcile(walk.found, unreadable: walk.unreadable, vectorSource: "v", walkDoneAt: stamp)
    return (Int(outcome.added), Int(outcome.removed))
}

private func rcDB(_ home: TempHome) -> AtDB? { AtDB(path: home.folder.appendingPathComponent("index.sqlite").path) }

private func rcRows(_ home: TempHome, _ sql: String) -> [[String]] {
    (rcDB(home)?.rows(sql) ?? []).map { $0.map { $0 ?? "NULL" } }
}

private func rcInt(_ home: TempHome, _ sql: String) -> Int { rcDB(home)?.int(sql) ?? -1 }

private func rcPassageIDs(_ home: TempHome) -> [String: [Int]] {
    var out: [String: [Int]] = [:]
    for row in rcRows(home, "select f.path, p.id from files f join passages p on p.file_id = f.id order by p.id") {
        if let id = Int(row[1]) { out[row[0], default: []].append(id) }
    }
    return out
}

private func rcTreeFiles(_ tree: RcTree) throws {
    try tree.file("pick/src/alpha.swift", "func zqalphaword() {}\nlet a = 1\n")
    try tree.file("pick/src/beta.py", "def zqbetaword():\n    return 2\n")
    try tree.file("pick/lib/gamma.js", "function zqgammaword() { return 3 }\n")
    try tree.file("pick/notes/one.txt", "a plain note zqonenote\n")
    try tree.file("pick/notes/two.md", "# two\nanother note zqtwonote\n")
}

private let rcCodePaths = ["pick/src/alpha.swift", "pick/src/beta.py", "pick/lib/gamma.js"]
private let rcKeptPaths = ["pick/notes/one.txt", "pick/notes/two.md"]

@Suite("IndexReconcileCodeTests")
struct IndexReconcileCodeTests {

    @Test func theWalkNeverListsTheCodeFilesWhateverTheTickSoOldCodeRowsAreAlwaysAbsentFromTheAdmittedSet() throws {
        try rcWithTree { tree in
            try rcTreeFiles(tree)
            let on = rcWalk(tree.path("pick"), ticked: true).found.map { ($0.file.path, $0.file.kind) }
            let off = rcWalk(tree.path("pick"), ticked: false).found.map { ($0.file.path, $0.file.kind) }
            #expect(Set(on.map(\.0)) == Set(rcKeptPaths.map(tree.path)), "ticked walk: \(on)")
            #expect(Set(off.map(\.0)) == Set(rcKeptPaths.map(tree.path)), "unticked walk: \(off)")
            #expect(on.filter { $0.1 == "code" }.isEmpty && off.filter { $0.1 == "code" }.isEmpty, "a walk listed a code file")
        }
    }

    @Test func reconcilingAgainstAnAdmittedSetWithoutTheCodeFilesDeletesExactlyThoseRowsAndTheirFtsRowsAndKeepsEveryOtherRow() throws {
        try rcWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try rcTreeFiles(tree)
                try rcSeed(store, rcWalk(tree.path("pick"), ticked: true).found, code: rcCodePaths.map(tree.path))

                #expect(rcInt(home, "select count(*) from files") == 5 && rcInt(home, "select count(*) from files where kind = 'code'") == 3, "setup: five rows, three of them code")
                #expect(rcInt(home, "select count(*) from passages") == 3 * 3 + 2 * 2, "setup: three code files of three passages and two notes of two")
                #expect(rcInt(home, "select count(*) from fts") == 13, "setup: one fts row per passage")
                #expect(rcInt(home, "select count(*) from fts where fts match 'body:zqalphaswifts1'") == 1, "setup: the code word of alpha.swift is found")

                let filesBefore = rcRows(home, "select * from files where kind <> 'code' order by id")
                let idsBefore = rcPassageIDs(home)
                let ftsBefore = rcRows(home, "select rowid, name, body from fts where rowid in (select p.id from passages p join files f on f.id = p.file_id where f.kind <> 'code') order by rowid")
                #expect(filesBefore.count == 2 && ftsBefore.count == 4, "setup: two kept rows and four fts rows of theirs")

                let outcome = try rcReconcile(store, rcWalk(tree.path("pick"), ticked: true), stamp: "t2")
                #expect(outcome.removed == 3 && outcome.added == 0, "three code rows removed and none added: \(outcome)")

                let paths = rcRows(home, "select path from files order by path").map { $0[0] }
                #expect(paths == rcKeptPaths.map(tree.path).sorted(), "rows left: \(paths)")
                #expect(rcRows(home, "select * from files where kind <> 'code' order by id") == filesBefore, "a kept row changed")
                #expect(rcPassageIDs(home) == idsBefore.filter { !rcCodePaths.contains(String($0.key.dropFirst(tree.base.count + 1))) },
                        "the passages of the kept files changed: \(rcPassageIDs(home)) from \(idsBefore)")
                #expect(rcInt(home, "select count(*) from passages") == 4, "four passages of the two notes remain")
                #expect(rcInt(home, "select count(*) from fts") == 4, "four fts rows remain: \(rcInt(home, "select count(*) from fts"))")
                #expect(rcInt(home, "select count(*) from passages where id not in (select rowid from fts)") == 0, "a passage lost its fts row")
                #expect(rcInt(home, "select count(*) from fts where rowid not in (select id from passages)") == 0, "an fts row of a deleted passage is left")
                #expect(rcRows(home, "select rowid, name, body from fts order by rowid") == ftsBefore, "an fts row of a kept passage changed")
                for word in ["zqalphaswifts1", "zqalphaswifts2", "zqbetapys1", "zqgammajss1"] {
                    #expect(rcInt(home, "select count(*) from fts where fts match 'body:\(word)'") == 0, "\(word) is still found after its file was removed")
                }
                for word in ["zqonetxts1", "zqtwomds1"] {
                    #expect(rcInt(home, "select count(*) from fts where fts match 'body:\(word)'") == 1, "\(word) of a kept note is gone")
                }
            }
        }
    }

    @Test func theDeletionOfManyCodeRowsIsOneTransactionNoSnapshotShowsSomeOfThem() throws {
        try rcWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let total = 1_500
                for number in 0..<total {
                    try tree.file("big/gen/g\(String(format: "%04d", number)).py", "def zqgen\(number)():\n    return \(number)\n")
                }
                try tree.file("big/keep.txt", "a kept note\n")
                let genPaths = (0..<total).map { tree.path("big/gen/g\(String(format: "%04d", $0)).py") }
                try rcSeed(store, rcWalk(tree.path("big"), ticked: true).found, code: genPaths)
                #expect(rcInt(home, "select count(*) from files where kind = 'code'") == total, "setup: \(total) code rows")
                let codePassages = rcInt(home, "select count(*) from passages p join files f on f.id = p.file_id where f.kind = 'code'")
                #expect(codePassages == total * 3, "setup: three passages a code file")

                let watch = RcWatch(path: home.folder.appendingPathComponent("index.sqlite").path, total: total, passages: total * 3)
                watch.start()
                Thread.sleep(forTimeInterval: 0.3)
                let outcome = try rcReconcile(store, rcWalk(tree.path("big"), ticked: false), stamp: "t1")
                Thread.sleep(forTimeInterval: 0.3)
                let result = watch.finish()
                #expect(outcome.removed == total, "all \(total) code rows are removed: \(outcome)")
                #expect(result.snapshots >= 10, "the second connection took only \(result.snapshots) snapshots, so it cannot show anything")
                #expect(result.violations.isEmpty, "a snapshot showed a half-made state (\(result.snapshots) snapshots): \(result.violations.prefix(3))")
                #expect(result.sawAll && result.sawNone, "the watcher should see the state before and the state after: all \(result.sawAll), none \(result.sawNone)")
                #expect(rcInt(home, "select count(*) from files") == 1, "only the note is left")
            }
        }
    }
}

extension IndexReconcileCodeTests {

    @Test func theWatcherDoesSeeAHalfMadeStateWhenTheSameRowsAreRemovedInSeveralTransactions() throws {
        try rcWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let total = 40
                for number in 0..<total { try tree.file("ctl/g\(String(format: "%02d", number)).py", "def zqctl\(number)():\n    return \(number)\n") }
                let ctlPaths = (0..<total).map { tree.path("ctl/g\(String(format: "%02d", $0)).py") }
                try rcSeed(store, rcWalk(tree.path("ctl"), ticked: true).found, code: ctlPaths)
                let path = home.folder.appendingPathComponent("index.sqlite").path
                let watch = RcWatch(path: path, total: total, passages: total * 3)
                watch.start()
                Thread.sleep(forTimeInterval: 0.3)
                for sql in ["delete from fts where rowid in (select id from passages)",
                            "delete from passages",
                            "delete from files"] {
                    #expect(atWrite(path, sql) == nil, "setup: the test's own write failed")
                    Thread.sleep(forTimeInterval: 0.3)
                }
                let result = watch.finish()
                #expect(!result.violations.isEmpty, "three separate transactions left a half-made state for 0.3 s and the watcher saw none of it (\(result.snapshots) snapshots)")
                #expect(result.sawAll && result.sawNone, "all \(result.sawAll), none \(result.sawNone)")
            }
        }
    }
}

private final class RcWatch: @unchecked Sendable {
    struct Result {
        var snapshots = 0
        var violations: [String] = []
        var sawAll = false
        var sawNone = false
    }

    private let path: String
    private let total: Int
    private let passages: Int
    private let lock = NSLock()
    private var stop = false
    private var result = Result()
    private let finished = DispatchSemaphore(value: 0)

    init(path: String, total: Int, passages: Int) {
        self.path = path
        self.total = total
        self.passages = passages
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stop
    }

    private func record(_ change: (inout Result) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&result)
    }

    func start() {
        let thread = Thread { [self] in
            guard let db = AtDB(path: path) else { finished.signal(); return }
            while !shouldStop {
                guard db.rows("BEGIN") != nil else { continue }
                let files = db.int("select count(*) from files where kind = 'code'") ?? -1
                let code = db.int("select count(*) from passages p join files f on f.id = p.file_id where f.kind = 'code'") ?? -1
                let loose = db.int("select count(*) from passages where file_id not in (select id from files)") ?? -1
                let lost = db.int("select count(*) from passages where id not in (select rowid from fts)") ?? -1
                let left = db.int("select count(*) from fts where rowid not in (select id from passages)") ?? -1
                _ = db.rows("COMMIT")
                record { result in
                    result.snapshots += 1
                    if files == total { result.sawAll = true }
                    if files == 0 { result.sawNone = true }
                    let whole = (files == total && code == passages) || (files == 0 && code == 0)
                    if !whole || loose != 0 || lost != 0 || left != 0 {
                        result.violations.append("code files \(files), code passages \(code), passages with no file \(loose), passages with no fts row \(lost), fts rows with no passage \(left)")
                    }
                }
            }
            finished.signal()
        }
        thread.start()
    }

    func finish() -> Result {
        lock.lock()
        stop = true
        lock.unlock()
        _ = finished.wait(timeout: .now() + 30)
        lock.lock(); defer { lock.unlock() }
        return result
    }
}
