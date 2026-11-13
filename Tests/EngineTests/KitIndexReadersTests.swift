import CryptoKit
import Foundation
import Testing
import SesameEngine

// plan-2-t9, tester step: kit part 5, the index readers (scripts/kit-index.sh). Written from the plan-2-t9 entry,
// verify.md (Kit scripts: kit-index.sh) and the S6 and S7 feature maps. No product source is read; the names used
// to write the index are the public IndexStore calls the engine tests already use (addFile, addPassage, setMeta,
// pendingPhotos, markCouldNotRead, close).
//
// Every run is a child process of scripts/kit-index.sh with its own KIT_ROOT (a folder named sesame-kit-idx), its own
// TMPDIR and HOME pointed at a throwaway home; the kit reads the index at $KIT_ROOT/home/Library/Application
// Support/Sesame/index.sqlite, so $KIT_ROOT/home is a link to that throwaway home. No app is started, the real kit
// root and the real home are never touched, and the script only reads (`sqlite3 -readonly -safe`).
//
// Every figure below is written here by hand from the rows this file writes; none is read from the script.
//
// Output formats the tests fix (the tester's picks, listed in the report):
//   under <folder>   one line for each files row under the folder that starts with the absolute path and ends with the
//                    row's status; no line for any other path. Other lines (a count line) do not start with "/".
//   size             no folder: a last line `size <bytes>`; with a folder: `size under <folder>: <bytes> bytes ...`.
//   rows             exactly the lines `files <n>`, `passages <m>`, `rows <n+m>`.
//   status           lines `<kind> <status> <n>` (whitespace separated), one for each kind and status with files.
//   estimate-check   a line holding the word PASS (exit 0) or the word FAIL (exit 1), never both.
//   wait <mode> <s>  exit 4 when the mode was not reached within <s> seconds (paused, resumed, rising).

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let indexScript = projectRoot.appendingPathComponent("scripts/kit-index.sh").path

// MARK: running the script

private struct Ran: Sendable {
    let status: Int32
    let output: String
    let seconds: Double
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitidx-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    let started = Date()
    try p.run()
    let deadline = started.addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    let seconds = Date().timeIntervalSince(started)
    try? handle.synchronize()
    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    return Ran(status: status, output: text, seconds: seconds)
}

private struct Rig: Sendable {
    let base: String
    let kit: String
    let tmp: String
    let home: String
    var db: String { home + "/Library/Application Support/Sesame/index.sqlite" }
    var env: [String: String] { ["KIT_ROOT": kit, "HOME": home, "TMPDIR": tmp + "/"] }

    func index(_ args: String..., limit: TimeInterval = 120) throws -> Ran {
        try run("/bin/bash", [indexScript] + args, env: env, limit: limit)
    }
}

/// A throwaway home (the engine's own `withTempHome`, so `IndexStore` writes under it) and a kit root whose `home`
/// is that folder.
private func withRig(_ body: (TempHome, Rig) throws -> Void) throws {
    try withTempHome { t in
        guard try createFolder(t) else { return }
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("kit-idx-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: made) }
        let base = made.resolvingSymlinksInPath().path
        let rig = Rig(base: base, kit: base + "/sesame-kit-idx", tmp: base + "/tmp", home: t.home.path)
        try fm.createDirectory(atPath: rig.kit, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rig.tmp, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: rig.kit + "/home", withDestinationPath: t.home.path)
        try body(t, rig)
    }
}

// MARK: writing an index, every row by hand

private func vector(_ phase: Float) -> [Float] {
    (0..<768).map { index in sin(Float(index) * 0.37 + phase) * 0.9 }
}

private struct Lib {
    let photos: String       // the folder asked about
    let photosOld: String    // a sibling named like a prefix of it
    let photosBak: String    // another one
    let notes: String        // a folder name with a space and brackets
    let notes2: String       // matches the bracket class of `notes` if the brackets were read as a pattern
    init(_ root: String) {
        photos = root + "/Photos"
        photosOld = root + "/Photos-old"
        photosBak = root + "/Photos.bak"
        notes = root + "/Notes [2024]"
        notes2 = root + "/Notes 2"
    }
}

/// 11 files, 7 passages. Statuses: photo done 3, photo pending 2, photo could_not_read 1, photo needs_permission 1,
/// pdf partial 1, doc done 3. Returns the store, still open.
private func buildMain(_ lib: Lib) throws -> IndexStore {
    let store = try IndexStore()
    var inode: Int64 = 0
    @discardableResult
    func add(_ path: String, _ kind: String, _ status: String) throws -> Int64 {
        inode += 1
        return try store.addFile(path: path, kind: kind, size: 100, mtimeNs: 1_700_000_000_000_000_000,
                                 inode: inode, device: 1, status: status)
    }
    func passage(_ file: Int64, _ source: String, _ modality: String, _ phase: Float?, name: String, body: String) throws {
        _ = try store.addPassage(fileID: file, source: source, start: 0, end: 0, modality: modality,
                                 vector: phase.map(vector), name: name, body: body)
    }

    // Photos (6 files; 2 vectors; keyword bytes "a beach" 7 + "café sunset" 12 + "page one" 8 + "sub c" 5 = 32)
    let a = try add(lib.photos + "/a.jpg", "photo", "done")
    try passage(a, "name", "none", nil, name: "a beach", body: "")
    try passage(a, "image", "image", 0.1, name: "", body: "café sunset")
    try add(lib.photos + "/b.jpg", "photo", "pending")
    try add(lib.photos + "/odd*name?.jpg", "photo", "done")
    let c = try add(lib.photos + "/sub/c.pdf", "pdf", "partial")
    try passage(c, "chunk", "text", 0.2, name: "", body: "page one")
    try passage(c, "name", "none", nil, name: "sub c", body: "")
    try add(lib.photos + "/sub/deep/d.jpg", "photo", "pending")
    let queue = try store.pendingPhotos(limit: 50)
    let dead = try #require(queue.first { $0.path == lib.photos + "/sub/deep/d.jpg" }, "setup: d.jpg is not queued")
    _ = try store.markCouldNotRead(dead, reason: "damaged")
    try add(lib.photos + "/e.jpg", "photo", "needs_permission")

    // The prefix siblings (1 vector, 18 keyword bytes "sibling words zzzz"; and a pending file)
    let f = try add(lib.photosOld + "/f.jpg", "photo", "done")
    try passage(f, "image", "image", 0.3, name: "", body: "sibling words zzzz")
    try add(lib.photosBak + "/g.jpg", "photo", "pending")

    // Notes [2024] (2 files; 1 vector; keyword bytes "abc" 3 + "n two" 5 = 8) and its look-alike
    let n1 = try add(lib.notes + "/n1.txt", "doc", "done")
    try passage(n1, "chunk", "text", 0.4, name: "", body: "abc")
    let n2 = try add(lib.notes + "/n2.txt", "doc", "done")
    try passage(n2, "name", "none", nil, name: "n two", body: "")
    try add(lib.notes2 + "/z.txt", "doc", "done")
    return store
}

private func mainLib(_ rig: Rig) throws -> Lib {
    let lib = Lib(rig.base + "/lib")
    for folder in [lib.photos, lib.photosOld, lib.photosBak, lib.notes, lib.notes2, rig.base + "/lib/Empty"] {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }
    return lib
}

private let mainFiles = 11
private let mainPassages = 7

// MARK: reading the script's output

private func lineWords(_ line: String) -> [String] {
    line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
}

/// Compares the path lines of `under` with the expected rows: each line starts with an expected path and ends with
/// its status; no expected row is missing; no other path line.
private func underProblems(_ ran: Ran, expected: [(path: String, status: String)]) -> [String] {
    var problems: [String] = []
    var seen: [String: Int] = [:]
    for line in ran.lines where line.hasPrefix("/") {
        let match = expected.first { entry in
            guard line.hasPrefix(entry.path) else { return false }
            let rest = line.dropFirst(entry.path.count)
            return rest.isEmpty || rest.first == "\t" || rest.first == " "
        }
        guard let match else {
            problems.append("a path that is not under the folder is listed: \(line)")
            continue
        }
        seen[match.path, default: 0] += 1
        if lineWords(line).last != match.status {
            problems.append("wrong status for \(match.path): wanted \(match.status), line is: \(line)")
        }
    }
    for entry in expected where seen[entry.path] != 1 {
        problems.append("\(entry.path) is listed \(seen[entry.path] ?? 0) times, wanted once")
    }
    return problems
}

private func fileSize(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
}

private func sha256(of path: String) throws -> String {
    SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
}

@Suite("KitIndexReadersTests")
struct KitIndexReadersTests {

    // MARK: the script itself

    @Test func theScriptIsValidBashAndReadsNoProductSource() throws {
        let ran = try run("/bin/bash", ["-n", indexScript])
        #expect(ran.status == 0, "bash -n scripts/kit-index.sh failed: \(ran.output)")
        let text = try String(contentsOfFile: indexScript, encoding: .utf8)
        #expect(!text.contains("Sources/"), "kit-index.sh must not read Sources/")
        #expect(text.contains("sqlite3 -readonly -safe"), "kit-index.sh must read the index with sqlite3 -readonly -safe")
    }

    @Test func noModeIsUsageWithExit2AndNamesTheWaitModesUnderAndSize() throws {
        try withRig { _, rig in
            let ran = try rig.index()
            #expect(ran.status == 2, "no mode must exit 2, got \(ran.status): \(ran.output)")
            let waitLines = ran.lines.filter { $0.contains("wait") }
            #expect(!waitLines.isEmpty, "the usage text has no wait line: \(ran.output)")
            for mode in ["paused", "resumed", "stable", "rising"] {
                #expect(waitLines.contains { $0.contains(mode) }, "the usage text does not name wait \(mode): \(ran.output)")
            }
            #expect(ran.lines.contains { $0.contains("under <folder>") }, "the usage text does not name `under <folder>`")
            #expect(ran.lines.contains { $0.contains("size [<folder>]") }, "the usage text does not name `size [<folder>]`")
            #expect(!FileManager.default.fileExists(atPath: rig.db + "-journal"), "a usage call wrote to the index")
        }
    }

    // MARK: under <folder>

    @Test func underListsEveryFilesRowUnderTheFolderWithItsStatusAndNothingOutsideIt() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            try buildMain(lib).close()

            let ran = try rig.index("under", lib.photos)
            #expect(ran.status == 0, "under exited \(ran.status): \(ran.output)")
            let expected: [(path: String, status: String)] = [
                (lib.photos + "/a.jpg", "done"),
                (lib.photos + "/b.jpg", "pending"),
                (lib.photos + "/odd*name?.jpg", "done"),
                (lib.photos + "/sub/c.pdf", "partial"),
                (lib.photos + "/sub/deep/d.jpg", "could_not_read"),
                (lib.photos + "/e.jpg", "needs_permission"),
            ]
            #expect(underProblems(ran, expected: expected) == [], "under \(lib.photos): \(ran.output)")
            // the siblings named like a prefix of the folder are not under it
            #expect(!ran.output.contains("Photos-old"), "a sibling named Photos-old is listed: \(ran.output)")
            #expect(!ran.output.contains("Photos.bak"), "a sibling named Photos.bak is listed: \(ran.output)")
        }
    }

    @Test func underReadsABracketedFolderNameAsAnameNotAsAPattern() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            try buildMain(lib).close()

            let ran = try rig.index("under", lib.notes)
            #expect(ran.status == 0, "under exited \(ran.status): \(ran.output)")
            let expected: [(path: String, status: String)] = [
                (lib.notes + "/n1.txt", "done"),
                (lib.notes + "/n2.txt", "done"),
            ]
            #expect(underProblems(ran, expected: expected) == [], "under \(lib.notes): \(ran.output)")
            #expect(!ran.output.contains("z.txt"), "Notes 2/z.txt matched the bracket class of `Notes [2024]`: \(ran.output)")
        }
    }

    @Test func underAFolderWithNoRowsListsNoPathAndExits0() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            try buildMain(lib).close()
            let ran = try rig.index("under", rig.base + "/lib/Empty")
            #expect(ran.status == 0, "under an empty folder exited \(ran.status): \(ran.output)")
            #expect(ran.lines.filter { $0.hasPrefix("/") }.isEmpty, "paths are listed for a folder with no rows: \(ran.output)")
        }
    }

    // MARK: size

    @Test func sizeWithNoFolderIsTheIndexFileBytesPlusItsWalFileFromStat() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            let store = try buildMain(lib)       // left open: the store's write-ahead file is on disk
            defer { store.close() }
            let walSize = fileSize(rig.db + "-wal")
            #expect(walSize > 0, "setup: no -wal file next to the open index, so the plus -wal part would test nothing")
            let expected = fileSize(rig.db) + walSize

            let ran = try rig.index("size")
            #expect(ran.status == 0, "size exited \(ran.status): \(ran.output)")
            let last = try #require(ran.lines.last, "size printed nothing")
            #expect(last == "size \(expected)", "wanted `size \(expected)` (index.sqlite \(fileSize(rig.db)) + -wal \(walSize)), last line is: \(last)")
        }
    }

    private func sizeUnder(_ rig: Rig, _ folder: String) throws -> (status: Int32, bytes: Int?, output: String) {
        let ran = try rig.index("size", folder)
        let prefix = "size under \(folder): "
        let line = ran.lines.first { $0.hasPrefix(prefix) }
        let bytes = line.flatMap { l -> Int? in
            let rest = l.dropFirst(prefix.count)
            guard let word = rest.split(separator: " ").first else { return nil }
            return Int(word)
        }
        return (ran.status, bytes, ran.output)
    }

    @Test func sizeOfAFolderIs1536BytesTimesItsVectorsPlusItsKeywordTextBytes() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            try buildMain(lib).close()

            // Photos: 2 vectors, keyword text 7 + 12 (café is 5 bytes) + 8 + 5 = 32 bytes
            let photos = try sizeUnder(rig, lib.photos)
            #expect(photos.status == 0, "size <folder> exited \(photos.status): \(photos.output)")
            #expect(photos.bytes == 2 * 1536 + 32, "Photos: wanted 3104 bytes, got \(String(describing: photos.bytes)): \(photos.output)")

            // The sibling Photos-old: 1 vector, 18 keyword bytes; it is not part of Photos
            let old = try sizeUnder(rig, lib.photosOld)
            #expect(old.bytes == 1536 + 18, "Photos-old: wanted 1554 bytes, got \(String(describing: old.bytes)): \(old.output)")

            // Notes [2024]: 1 vector, keyword text 3 + 5 = 8 bytes
            let notes = try sizeUnder(rig, lib.notes)
            #expect(notes.bytes == 1536 + 8, "Notes [2024]: wanted 1544 bytes, got \(String(describing: notes.bytes)): \(notes.output)")

            // A folder with no rows: 0 bytes
            let none = try sizeUnder(rig, rig.base + "/lib/Empty")
            #expect(none.bytes == 0, "an empty folder: wanted 0 bytes, got \(String(describing: none.bytes)): \(none.output)")
        }
    }

    // MARK: rows and status

    @Test func rowsPrintsExactlyTheThreeLinesFilesPassagesRows() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            try buildMain(lib).close()
            let ran = try rig.index("rows")
            #expect(ran.status == 0, "rows exited \(ran.status): \(ran.output)")
            #expect(ran.lines == ["files \(mainFiles)", "passages \(mainPassages)", "rows \(mainFiles + mainPassages)"],
                    "wanted files 11, passages 7, rows 18; got: \(ran.output)")
        }
    }

    @Test func statusPrintsFilesPerKindAndStatusIncludingNeedsPermission() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            try buildMain(lib).close()
            let ran = try rig.index("status")
            #expect(ran.status == 0, "status exited \(ran.status): \(ran.output)")
            var got: [String: Int] = [:]
            for line in ran.lines {
                let words = lineWords(line)
                if words.count == 3, let n = Int(words[2]) { got["\(words[0]) \(words[1])"] = n }
            }
            let expected: [String: Int] = [
                "photo done": 3, "photo pending": 2, "photo could_not_read": 1, "photo needs_permission": 1,
                "pdf partial": 1, "doc done": 3,
            ]
            #expect(got == expected, "status lines (`<kind> <status> <n>`) are \(got), wanted \(expected); output: \(ran.output)")
        }
    }

    // MARK: snapshot --files-only and diff

    private enum Variant { case base, reread, status, count }

    /// Four files; a variant changes only what it names. `reread` has the same path, status and passage count for
    /// every file but new row ids (rows written in the other order), other vectors and other words.
    private func buildSnapshotIndex(_ t: TempHome, _ variant: Variant) throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: t.folder.path + "/index.sqlite" + suffix)
        }
        let store = try IndexStore()
        defer { store.close() }
        var rows: [(path: String, kind: String, status: String, passages: Int)] = [
            ("/s/a.jpg", "photo", variant == .status ? "partial" : "done", 2),
            ("/s/b.jpg", "photo", "done", variant == .count ? 2 : 1),
            ("/s/c.pdf", "pdf", "done", 3),
            ("/s/d.jpg", "photo", "pending", 0),
        ]
        if variant == .reread { rows.reverse() }
        let phase: Float = variant == .reread ? 2.5 : 0.5
        var inode: Int64 = variant == .reread ? 500 : 0
        for row in rows {
            inode += 1
            let file = try store.addFile(path: row.path, kind: row.kind, size: 10, mtimeNs: 1_700_000_000_000_000_000,
                                         inode: inode, device: 1, status: row.status)
            for p in 0..<row.passages {
                _ = try store.addPassage(fileID: file, source: "chunk", start: Double(p), end: Double(p),
                                         modality: "text", vector: vector(phase + Float(p)), name: "",
                                         body: (variant == .reread ? "reread words " : "first words ") + String(p))
            }
        }
    }

    @Test func aFilesOnlySnapshotIgnoresRowIdsVectorsAndWordsButSeesAStatusOrCountChange() throws {
        try withRig { t, rig in
            try buildSnapshotIndex(t, .base)
            let a = try rig.index("snapshot", "a", "--files-only")
            #expect(a.status == 0, "snapshot a --files-only exited \(a.status): \(a.output)")

            // The file is read again: new row ids, new vectors, new words, same path, status and passage count.
            try buildSnapshotIndex(t, .reread)
            let b = try rig.index("snapshot", "b", "--files-only")
            #expect(b.status == 0, "snapshot b --files-only exited \(b.status): \(b.output)")
            let same = try rig.index("diff", "a", "b")
            #expect(same.status == 0, "a re-read file must give the same files-only snapshot; diff exited \(same.status): \(same.output)")
            #expect(!same.output.contains("/s/"), "diff of identical snapshots names a path: \(same.output)")

            // A changed status gives a different snapshot, and the diff names the file.
            try buildSnapshotIndex(t, .status)
            let c = try rig.index("snapshot", "c", "--files-only")
            #expect(c.status == 0, "snapshot c --files-only exited \(c.status): \(c.output)")
            let status = try rig.index("diff", "a", "c")
            #expect(status.status == 1, "a changed status must make diff exit 1, got \(status.status): \(status.output)")
            #expect(status.output.contains("/s/a.jpg"), "diff does not name /s/a.jpg: \(status.output)")
            #expect(!status.output.contains("/s/b.jpg"), "diff names a file that did not change: \(status.output)")

            // A changed passage count gives a different snapshot.
            try buildSnapshotIndex(t, .count)
            let d = try rig.index("snapshot", "d", "--files-only")
            #expect(d.status == 0, "snapshot d --files-only exited \(d.status): \(d.output)")
            let count = try rig.index("diff", "a", "d")
            #expect(count.status == 1, "a changed passage count must make diff exit 1, got \(count.status): \(count.output)")
            #expect(count.output.contains("/s/b.jpg"), "diff does not name /s/b.jpg: \(count.output)")
            #expect(!count.output.contains("/s/a.jpg"), "diff names a file that did not change: \(count.output)")
        }
    }

    @Test func aDiffOfTwoSnapshotsOfDifferentModesExits4AndTheFullModeSeesWhatFilesOnlyIgnores() throws {
        try withRig { t, rig in
            try buildSnapshotIndex(t, .base)
            let filesOnly = try rig.index("snapshot", "fo", "--files-only")
            #expect(filesOnly.status == 0, "snapshot fo --files-only exited \(filesOnly.status): \(filesOnly.output)")
            // The full snapshot compiles the kit's Swift row hasher once: allowed 10 minutes.
            let full1 = try rig.index("snapshot", "f1", limit: 600)
            #expect(full1.status == 0, "full snapshot f1 exited \(full1.status): \(full1.output)")

            // Control: the same re-read that files-only ignores is seen by the full snapshot.
            try buildSnapshotIndex(t, .reread)
            let full2 = try rig.index("snapshot", "f2", limit: 600)
            #expect(full2.status == 0, "full snapshot f2 exited \(full2.status): \(full2.output)")
            let seen = try rig.index("diff", "f1", "f2")
            #expect(seen.status == 1, "the full snapshot must see new row ids and vectors; diff f1 f2 exited \(seen.status): \(seen.output)")

            let mixed = try rig.index("diff", "fo", "f1")
            #expect(mixed.status == 4, "diff of a files-only and a full snapshot must exit 4, got \(mixed.status): \(mixed.output)")
            let mixedBack = try rig.index("diff", "f1", "fo")
            #expect(mixedBack.status == 4, "diff of a full and a files-only snapshot must exit 4, got \(mixedBack.status): \(mixedBack.output)")
        }
    }

    // MARK: estimate-check

    /// A finished index: every file done and `walk_done_at` set; its last write is `end` (epoch seconds).
    private func buildFinishedIndex(_ rig: Rig, end: Int) throws {
        let store = try IndexStore()
        for number in 1...3 {
            let file = try store.addFile(path: "/e/\(number).jpg", kind: "photo", size: 10, mtimeNs: 1_700_000_000_000_000_000,
                                         inode: Int64(number), device: 1, status: "done")
            _ = try store.addPassage(fileID: file, source: "image", start: 0, end: 0, modality: "image",
                                     vector: vector(Float(number)), name: "", body: "words \(number)")
        }
        try store.setMeta("walk_done_at", "1700000123")
        store.close()
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: rig.db + suffix) {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(end))],
                                                  ofItemAtPath: rig.db + suffix)
        }
    }

    @Test func estimateCheckPrintsPassWithinThirtyPercentOfTheRealTimeAndFailOtherwise() throws {
        try withRig { _, rig in
            let end = 1_750_000_000
            try buildFinishedIndex(rig, end: end)
            // (estimate seconds, real seconds from Start to the last write, expected PASS), differences worked by hand:
            //   1000 vs 1000   0.0 percent over    -> PASS
            //   1299 vs 1000  29.9 percent over    -> PASS      1301 vs 1000  30.1 percent over   -> FAIL
            //    701 vs 1000  29.9 percent under   -> PASS       699 vs 1000  30.1 percent under  -> FAIL
            //    780 vs  600  30.0 percent over (at most 30 is a pass) -> PASS     781 vs 600 30.17 -> FAIL
            let cases: [(estimate: Int, real: Int, pass: Bool)] = [
                (1000, 1000, true), (1299, 1000, true), (1301, 1000, false),
                (701, 1000, true), (699, 1000, false), (780, 600, true), (781, 600, false),
            ]
            for item in cases {
                let ran = try rig.index("estimate-check", String(item.estimate), String(end - item.real))
                let hasPass = ran.output.range(of: #"\bPASS\b"#, options: .regularExpression) != nil
                let hasFail = ran.output.range(of: #"\bFAIL\b"#, options: .regularExpression) != nil
                let label = "estimate \(item.estimate) s, real \(item.real) s"
                if item.pass {
                    #expect(ran.status == 0 && hasPass && !hasFail, "\(label): wanted exit 0 and PASS, got exit \(ran.status): \(ran.output)")
                } else {
                    #expect(ran.status == 1 && hasFail && !hasPass, "\(label): wanted exit 1 and FAIL, got exit \(ran.status): \(ran.output)")
                }
            }
        }
    }

    // MARK: wait

    @Test func waitExits4WhenPausedResumedOrRisingIsNotReachedWithinTheTimeout() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            try buildMain(lib).close()       // nothing writes to it while the script waits
            for mode in ["paused", "resumed", "rising"] {
                let ran = try rig.index("wait", mode, "2")
                #expect(ran.status == 4, "wait \(mode) 2 on an index nobody writes to must exit 4 on its timeout, got \(ran.status): \(ran.output)")
                #expect(ran.seconds >= 1.0, "wait \(mode) 2 returned after \(ran.seconds) s: it did not wait for the timeout")
            }
        }
    }

    // MARK: read only

    @Test func theReadersNeverChangeTheIndexFile() throws {
        try withRig { _, rig in
            let lib = try mainLib(rig)
            try buildMain(lib).close()
            let before = try sha256(of: rig.db)
            let modified = try FileManager.default.attributesOfItem(atPath: rig.db)[.modificationDate] as? Date
            for args in [["under", lib.photos], ["size"], ["size", lib.photos], ["rows"], ["status"],
                         ["snapshot", "ro", "--files-only"], ["wait", "rising", "1"]] {
                _ = try run("/bin/bash", [indexScript] + args, env: rig.env)
            }
            #expect(try sha256(of: rig.db) == before, "a reader changed the bytes of index.sqlite")
            let after = try FileManager.default.attributesOfItem(atPath: rig.db)[.modificationDate] as? Date
            #expect(after == modified, "a reader changed the modified time of index.sqlite")
        }
    }
}
