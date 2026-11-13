import Foundation
import Testing
import SesameEngine

// plan-2-t39, tester step (S7.6, S7.7, S7.9, S7.15; design section 9, 1a). Written from the t39 entry, plan-2 Decisions
// D10, design sections 1, 3 and 9 and the Helper protocol table only; no product source read. The harness (`At...`) is
// in IndexAttemptTests.swift.
//
// The model-based test: through the real bundled helper (`SESAME_FAKE_EMBEDDER=1`, a throwaway HOME, one long-lived
// helper per seed, warmed once per test process, 120 s allowed) over a temp tree of small generated photos with unique
// name words, 200 seeded random operations in rounds of 10. The operations are create, edit, same-size edit with a new
// modified time, rename (a file, or a folder), move (inside a picked folder or into another one), delete and unplug of
// a whole picked folder (the folder is carried out of the tree, so its root no longer exists, and a later unplug of the
// same folder brings it back: the drive returns). There are three picked folders, always all in the `folders` line.
// After each round the test sends `folders`, waits until the index agrees with the tree (so no file is `pending`; each
// round has 120 s of slack, 60 s with no progress at all) and compares the index with a listing the test computes itself
// with `FileManager`:
//   1. the same set of paths, one row per path;
//   2. status `done` for each, and each row holds the size, modified time and inode that `stat` gives for the file now;
//   3. every present file is found by the keyword for its unique name word (and by nothing else), and the word of every
//      name that no longer exists (deleted, renamed away) finds nothing; matching is `fts MATCH 'name:<word>'` on the
//      index file, the same text index `IndexReader.keywordSearch` reads;
//   4. the index is whole (`atWholeProblems`: passages all-or-none, an fts row for each, `integrity_check` ok);
//   5. NOTHING IS READ AGAIN WHEN NOTHING CHANGED (D10, design section 3 "moved by inode"): a file that is in the tree
//      at both syncs with the same inode, size and modified time (a pure rename or move, or a folder rename or move, or
//      an unplug and return between two syncs) keeps its row id and its passage ids. This is the check that fails today,
//      where a moved file is deleted and added again with a new row id and is read again.
// The expected values are the test's own: the words, the listing and the stat of the tree. The seed is printed and three
// fixed seeds run (one test each). The operation counts are printed and each kind must have happened at least once, so a
// degenerate seed cannot pass by doing nothing.

private let mbRoots = 3
private let mbRounds = 20
private let mbOpsPerRound = 10

private struct MbStat: Equatable {
    let size: Int64
    let mtimeNs: Int64
    let inode: Int64
}

private func mbStat(_ path: String) -> MbStat? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return MbStat(size: Int64(info.st_size),
                  mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                  inode: Int64(info.st_ino))
}

private struct MbRow {
    let id: Int64
    let status: String
    let stat: MbStat
}

/// What the index says about one file the last time it agreed with the tree, by inode.
private struct MbKept {
    let path: String
    let rowID: Int64
    let passages: [Int64]
    let stat: MbStat
}

private final class MbRig {
    let world: AtWorld
    private var rng: AtRNG
    let roots: [URL]
    let parked: URL
    private var unplugged = Set<Int>()
    private var counter = 0
    private(set) var words = Set<String>()
    private(set) var applied: [String: Int] = [:]

    init(world: AtWorld, seed: UInt64) throws {
        self.world = world
        rng = AtRNG(seed: seed)
        roots = (0..<mbRoots).map { world.photos.appendingPathComponent("r\($0)", isDirectory: true) }
        parked = world.root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
        for root in roots {
            for sub in ["", "sub0", "sub1"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
        }
    }

    // MARK: the tree, listed by the test itself

    private var pluggedRoots: [URL] { roots.indices.filter { !unplugged.contains($0) }.map { roots[$0] } }

    /// Every regular `.jpg` under a picked folder that is plugged in, by path, sorted.
    func listing() -> [String] {
        var out: [String] = []
        for root in pluggedRoots {
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let relative as String in walker where relative.hasSuffix(".jpg") {
                var isFolder: ObjCBool = false
                let full = root.path + "/" + relative
                if FileManager.default.fileExists(atPath: full, isDirectory: &isFolder), !isFolder.boolValue { out.append(full) }
            }
        }
        return out.sorted()
    }

    /// Every folder that exists under a plugged root, the root itself included.
    private func folders() -> [String] {
        var out: [String] = []
        for root in pluggedRoots {
            out.append(root.path)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let relative as String in walker {
                var isFolder: ObjCBool = false
                let full = root.path + "/" + relative
                if FileManager.default.fileExists(atPath: full, isDirectory: &isFolder), isFolder.boolValue { out.append(full) }
            }
        }
        return out.sorted()
    }

    // MARK: random choices

    private func roll(_ upper: Int) -> Int { Int(rng.next() % UInt64(upper)) }
    private func pick<T>(_ items: [T]) -> T { items[roll(items.count)] }

    /// A new unique name word: nine letters ending in a letter no stemmer changes, sharing no six-letter start with an earlier one.
    private func newWord() -> String {
        let consonants = Array("bdfghjklmnprstvwz"), vowels = Array("aeiou"), endings = Array("kpzxqvbw")
        while true {
            var letters: [Character] = []
            for index in 0..<8 {
                letters.append(index % 2 == 0 ? consonants[roll(consonants.count)] : vowels[roll(vowels.count)])
            }
            letters.append(endings[roll(endings.count)])
            let word = String(letters)
            if words.contains(where: { $0.prefix(6) == word.prefix(6) }) { continue }
            words.insert(word)
            return word
        }
    }

    private func setTime(_ path: String) throws {
        counter += 1
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(counter))],
                                              ofItemAtPath: path)
    }

    private func dir(of path: String) -> String { (path as NSString).deletingLastPathComponent }

    // MARK: the operations

    func baseline() throws {
        for root in roots {
            for sub in ["", "sub0", "sub1"] {
                for _ in 0..<(sub.isEmpty ? 2 : 3) { try create(in: root.appendingPathComponent(sub).path, count: false) }
            }
        }
    }

    private func create(in folder: String, count: Bool = true) throws {
        let word = newWord()
        counter += 1
        try atMakePhotos(in: URL(fileURLWithPath: folder), names: [word], seedBase: counter * 13)
        try setTime(folder + "/" + word + ".jpg")
        if count { applied["create", default: 0] += 1 }
    }

    func operate() throws {
        let files = listing()
        let value = roll(100)
        if files.isEmpty || value < 22 {
            try create(in: pick(folders()))
        } else if value < 32 {                                   // edit: new pixels and a new modified time, same name
            let file = pick(files)
            counter += 1
            let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            try atMakePhotos(in: URL(fileURLWithPath: dir(of: file)), names: [stem], seedBase: counter * 17 + 5)
            try setTime(file)
            applied["edit", default: 0] += 1
        } else if value < 40 {                                   // same-size edit: the same bytes written again, a new modified time
            let file = pick(files)
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            try data.write(to: URL(fileURLWithPath: file))
            try setTime(file)
            applied["touch", default: 0] += 1
        } else if value < 55 {                                   // rename: a file (new unique name word) or a folder
            let subfolders = folders().filter { path in !roots.contains { $0.path == path } }
            if !subfolders.isEmpty && roll(4) == 0 {
                let folder = pick(subfolders)
                counter += 1
                try FileManager.default.moveItem(atPath: folder, toPath: dir(of: folder) + "/box\(counter)")
            } else {
                let file = pick(files)
                try FileManager.default.moveItem(atPath: file, toPath: dir(of: file) + "/" + newWord() + ".jpg")
            }
            applied["rename", default: 0] += 1
        } else if value < 72 {                                   // move: into another folder, maybe of another picked folder
            let file = pick(files)
            let targets = folders().filter { $0 != dir(of: file) }
            let target = pick(targets)
            try FileManager.default.moveItem(atPath: file, toPath: target + "/" + (file as NSString).lastPathComponent)
            applied["move", default: 0] += 1
        } else if value < 90 {                                   // delete
            try FileManager.default.removeItem(atPath: pick(files))
            applied["delete", default: 0] += 1
        } else {                                                 // unplug a plugged picked folder, or bring an unplugged one back
            let index = roll(mbRoots)
            let away = parked.appendingPathComponent("r\(index)")
            if unplugged.contains(index) {
                try FileManager.default.moveItem(at: away, to: roots[index])
                unplugged.remove(index)
            } else if unplugged.count < mbRoots - 1 {
                try FileManager.default.moveItem(at: roots[index], to: away)
                unplugged.insert(index)
            } else if let back = unplugged.sorted().first {
                try FileManager.default.moveItem(at: parked.appendingPathComponent("r\(back)"), to: roots[back])
                unplugged.remove(back)
            }
            applied["unplug", default: 0] += 1
        }
    }
}

// MARK: reading the index

private func mbRows(_ db: AtDB) -> [String: MbRow]? {
    guard let rows = db.rows("select path, id, status, size, mtime_ns, inode from files") else { return nil }
    var out: [String: MbRow] = [:]
    for row in rows {
        guard let path = row[0], let id = Int64(row[1] ?? ""), let status = row[2], let size = Int64(row[3] ?? ""),
              let mtime = Int64(row[4] ?? ""), let inode = Int64(row[5] ?? "") else { continue }
        out[path] = MbRow(id: id, status: status, stat: MbStat(size: size, mtimeNs: mtime, inode: inode))
    }
    return out
}

private func mbPassages(_ db: AtDB) -> [Int64: [Int64]] {
    guard let rows = db.rows("select file_id, id from passages order by id") else { return [:] }
    var out: [Int64: [Int64]] = [:]
    for row in rows { if let file = Int64(row[0] ?? ""), let id = Int64(row[1] ?? "") { out[file, default: []].append(id) } }
    return out
}

/// The paths of the files whose name passage holds `word`.
private func mbFound(_ db: AtDB, _ word: String) -> [String]? {
    guard let rows = db.rows("""
        select distinct f.path from fts join passages p on p.id = fts.rowid join files f on f.id = p.file_id \
        where fts match 'name:\(word)' order by f.path
        """) else { return nil }
    return rows.compactMap { $0[0] }
}

private func mbAgrees(_ rows: [String: MbRow], _ tree: [String: MbStat]) -> Bool {
    guard rows.count == tree.count else { return false }
    for (path, info) in tree {
        guard let row = rows[path], row.status == "done", row.stat == info else { return false }
    }
    return true
}

/// Polls the index (one statement is one snapshot) until it agrees with the tree, until nothing in it has changed for
/// `stall` seconds, until `cap` seconds in all, or until the helper is gone.
private func mbWait(_ world: AtWorld, _ helper: HelperProcess, tree: [String: MbStat], stall: TimeInterval = 60,
                    cap: TimeInterval = 120) -> (agreed: Bool, seconds: Double) {
    let started = Date()
    var lastChange = started
    var last: [String: String] = [:]
    var db: AtDB?
    while true {
        if db == nil { db = world.db() }
        if let rows = db.flatMap(mbRows) {
            if mbAgrees(rows, tree) { return (true, Date().timeIntervalSince(started)) }
            let signature = rows.mapValues { "\($0.id)\($0.status)\($0.stat.size)\($0.stat.mtimeNs)" }
            if signature != last { last = signature; lastChange = Date() }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > stall || now.timeIntervalSince(started) > cap { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return (false, Date().timeIntervalSince(started))
}

private func mbShort(_ items: [String]) -> String {
    let names = items.map { ($0 as NSString).lastPathComponent }.sorted()
    return names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : "")
}

// MARK: the run

private func mbRun(seed: UInt64) throws {
    _ = atHelperWarm
    print("SEED model-based=\(seed)")
    let started = Date()
    let world = try AtWorld()
    defer { world.remove() }
    let rig = try MbRig(world: world, seed: seed)
    try rig.baseline()

    var helper = try atStartHelper(world)
    defer { helper.stop() }
    var restarts = 0
    var previous: [Int64: MbKept] = [:]       // by inode, as the index held it when it last agreed with the tree
    var roundSeconds: [Double] = []
    var kept = 0                              // files that changed path between two syncs and were checked as kept

    for round in 0...mbRounds {
        let tag = "seed \(seed), round \(round)"
        if round > 0 { for _ in 0..<mbOpsPerRound { try rig.operate() } }

        let listed = rig.listing()
        var tree: [String: MbStat] = [:]
        for path in listed { if let info = mbStat(path) { tree[path] = info } }
        #expect(tree.count == listed.count, "\(tag): setup: some listed file could not be stat'ed")

        if !helper.isRunning {                    // the 60 s idle exit: a new helper is the same helper to the person
            restarts += 1
            helper = try atStartHelper(world)
        }
        let sent = Date()
        helper.send(atFoldersLine(rig.roots))
        let wait = mbWait(world, helper, tree: tree)
        roundSeconds.append(Date().timeIntervalSince(sent))

        guard let db = world.db(), let rows = mbRows(db) else {
            Issue.record("\(tag): the index cannot be read; stderr: \(helper.errors)")
            return
        }

        // 1. the same set of paths, one row per path
        let rowPaths = Set(rows.keys)
        let treePaths = Set(tree.keys)
        let rowCount = db.int("select count(*) from files") ?? -1
        var problems: [String] = []
        if rowPaths != treePaths {
            problems.append("missing from the index: \(mbShort(Array(treePaths.subtracting(rowPaths)))); not in the tree: \(mbShort(Array(rowPaths.subtracting(treePaths))))")
        }
        if rowCount != rows.count { problems.append("\(rowCount) rows for \(rows.count) paths") }
        // 2. done, and the row says what the file is now
        for path in treePaths.intersection(rowPaths).sorted() {
            guard let row = rows[path], let info = tree[path] else { continue }
            if row.status != "done" { problems.append("\((path as NSString).lastPathComponent) is \(row.status), expected done") }
            if row.stat != info { problems.append("\((path as NSString).lastPathComponent): the row holds \(row.stat), the file is \(info)") }
        }
        // 3. keywords: each present file by its own word, no removed name by any
        let present = Set(listed.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        for path in listed {
            let word = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let hit = mbFound(db, word)
            if hit != [path] { problems.append("the word \(word) should find only \(path), it finds \(String(describing: hit))") }
        }
        for word in rig.words.subtracting(present).sorted() {
            let hit = mbFound(db, word)
            if hit != [] { problems.append("the removed name \(word) still finds \(String(describing: hit))") }
        }
        // 4. a whole index
        problems += atWholeProblems(db)
        // 5. nothing read again when nothing changed
        let passages = mbPassages(db)
        var now: [Int64: MbKept] = [:]
        for (path, row) in rows where treePaths.contains(path) {
            now[row.stat.inode] = MbKept(path: path, rowID: row.id, passages: passages[row.id] ?? [], stat: row.stat)
        }
        for (inode, before) in previous {
            guard let after = now[inode], let info = tree.values.first(where: { $0.inode == inode }),
                  info.size == before.stat.size, info.mtimeNs == before.stat.mtimeNs else { continue }
            if after.path != before.path { kept += 1 }
            if after.rowID != before.rowID {
                problems.append("a file with inode \(inode) that was only moved or renamed (or unplugged and returned) went from row \(before.rowID) to row \(after.rowID): deleted and added again")
            } else if after.passages != before.passages {
                problems.append("a file with inode \(inode) that was only moved or renamed kept row \(after.rowID) but its passages went from \(before.passages) to \(after.passages): read again")
            }
        }

        if !wait.agreed {
            problems.insert("the index did not agree with the tree within \(Int(wait.seconds)) s (the helper is \(helper.isRunning ? "running" : "gone"); stderr: \(helper.errors))", at: 0)
        }
        #expect(problems.isEmpty, "\(tag) (\(treePaths.count) files): \(problems.prefix(10))")
        if !problems.isEmpty { return }
        previous = now
    }

    let status = atCleanStop(helper)
    #expect(status == 0, "seed \(seed): the helper did not exit 0 at stdin end (status \(status.map(String.init) ?? "still running")); stderr: \(helper.errors)")
    let counts = rig.applied.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    let total = rig.applied.values.reduce(0, +)
    print("READING model-based seed=\(seed) ops=\(total) \(counts) files=\(rig.listing().count) moved_checked=\(kept) restarts=\(restarts) seconds=\(Int(Date().timeIntervalSince(started))) slowest_round=\(Int(roundSeconds.max() ?? 0))")
    #expect(total == mbRounds * mbOpsPerRound, "seed \(seed): \(total) operations were applied, expected \(mbRounds * mbOpsPerRound)")
    for kind in ["create", "edit", "touch", "rename", "move", "delete", "unplug"] {
        #expect((rig.applied[kind] ?? 0) >= 1, "seed \(seed): no \(kind) operation happened, so the run proved nothing about it (\(counts))")
    }
    #expect(kept >= 5, "seed \(seed): only \(kept) moved or renamed files were checked for a kept row, so the check proved little")
}

extension EncodeHelperTests {
@Suite("IndexModelBasedTests", .serialized)
struct IndexModelBasedTests {

    @Test func twoHundredRandomOperationsInRoundsOfTenKeepTheIndexEqualToTheTreeSeedOne() throws {
        try mbRun(seed: 20_261_001)
    }

    @Test func twoHundredRandomOperationsInRoundsOfTenKeepTheIndexEqualToTheTreeSeedTwo() throws {
        try mbRun(seed: 7_719_053)
    }

    @Test func twoHundredRandomOperationsInRoundsOfTenKeepTheIndexEqualToTheTreeSeedThree() throws {
        try mbRun(seed: 424_242_424)
    }
}
}
