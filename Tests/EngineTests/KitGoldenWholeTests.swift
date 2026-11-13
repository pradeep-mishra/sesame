import Foundation
import Testing

// plan-4-t9, tester step. The whole-folder prepare of group c: `scripts/kit-golden.sh prepare --whole`, the marker
// `run/golden-index-whole`, `golden_indexed_whole` (golden.sh: `golden_whole_expect`) and the read-only `index-state --whole`
// that shows the shortcut's reading without a helper. Written from the t9 entry of plan-4-tasks.md, kit-golden.sh and
// golden.sh as plan 4's earlier kit tasks left them, and the t2 reading of the golden table; no product source is read.
//
// Text checks (`bash -n`, the usage line, the marker name, `--folders golden/photos` in prepare and both folders in
// `prepare --whole`, the gate of `panel --group c`), usage errors, and pure runs of the reading on a hand-made temp KIT_ROOT:
// a hand-made tree of six golden files with a reader and an index file made by `sqlite3` in the shape the other kit tests use.
// Nothing here starts the helper, the app or a nested `swift test`; the real `prepare --whole` is run by GroupCTests.
//
// Expected values are written here by hand: which files a hand-made tree has, which rows the index holds, and the verdict each
// case must give (the locked and the damaged pdf are `could_not_read` as the key says (S3.8), every other golden file with a
// reader is `done`, a file of boundary or of any other root does not count for the gate and does count for "no other file").

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let goldenScript = projectRoot.appendingPathComponent("scripts/kit-golden.sh").path
private let goldenLib = projectRoot.appendingPathComponent("scripts/kit-lib/golden.sh").path

// MARK: running things

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("kitwhole-out-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    defer { try? fm.removeItem(at: out) }
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
    try p.run()
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    try? handle.synchronize()
    return Ran(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

/// A temp KIT_ROOT (a folder named sesame-kit*), its own TMPDIR and a decoy HOME; removed by the caller's `defer`.
private struct Rig {
    let base: String
    var kit: String { base + "/sesame-kit-whole" }
    var tmp: String { base + "/tmp" }
    var decoyHome: String { base + "/decoy-home" }
    var fixtures: String { kit + "/fixtures" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome,
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
    var indexDir: String { kit + "/home/Library/Application Support/Sesame" }
    var db: String { indexDir + "/index.sqlite" }
    func remove() { try? FileManager.default.removeItem(atPath: base) }
}

private func makeRig() throws -> Rig {
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-whole-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let rig = Rig(base: made.resolvingSymlinksInPath().path)
    for dir in [rig.kit + "/run", rig.tmp, rig.decoyHome] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    return rig
}

private func golden(_ rig: Rig, _ args: [String]) throws -> Ran {
    try run("/bin/bash", [goldenScript] + args, env: rig.env)
}

private func touch(_ path: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data("x".utf8))
}

private func sqlite(_ db: String, _ sql: String) throws {
    let r = try run("/usr/bin/sqlite3", [db, sql], limit: 30)
    #expect(r.status == 0, "sqlite3 failed: \(r.output)")
}

// MARK: the hand-made golden tree and index

/// The six golden files of the hand-made tree that have a reader, written by hand: two photos, three pdfs (one locked, one
/// damaged, as golden-docs.tsv names them) and a document, each with the status a finished whole-folder index holds for it.
private let treeFiles: [(path: String, kind: String, status: String)] = [
    ("golden/photos/p0.jpg", "photo", "done"),
    ("golden/photos/p1.png", "photo", "done"),
    ("golden-docs/pdfs/lease-2024.pdf", "pdf", "done"),
    ("golden-docs/pdfs/locked-contract.pdf", "pdf", "could_not_read"),
    ("golden-docs/pdfs/damaged-report.pdf", "pdf", "could_not_read"),
    ("golden-docs/docs/field-notes.txt", "doc", "done"),
]

/// Files that exist on disk and have no reader (the `.pages` extension is in no list of extensions.txt) or are of another root.
private let otherFiles = ["golden-docs/docs/notes.pages", "boundary/one-page.pdf"]

private func makeTree(_ rig: Rig) throws {
    for file in treeFiles { try touch(rig.fixtures + "/" + file.path) }
    for file in otherFiles { try touch(rig.fixtures + "/" + file) }
}

private func makeIndex(_ rig: Rig, rows: [(path: String, kind: String, status: String)]) throws {
    try FileManager.default.createDirectory(atPath: rig.indexDir, withIntermediateDirectories: true)
    try sqlite(rig.db, "create table files(path text primary key, kind text, status text, reason text); create table passages(id integer primary key, file text);")
    guard !rows.isEmpty else { return }
    let values = rows.map { "('\(rig.fixtures)/\($0.path)','\($0.kind)','\($0.status)',NULL)" }.joined(separator: ",")
    try sqlite(rig.db, "insert into files values \(values);")
}

private func readText(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

/// The text of one shell function of a script: from `name() {` to the first line that is exactly `}`.
private func functionText(_ script: String, _ name: String) -> String {
    var out: [String] = []
    var inside = false
    for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
        if !inside, line.hasPrefix(name + "() {") { inside = true }
        if inside {
            out.append(String(line))
            if line == "}" { break }
        }
    }
    return out.joined(separator: "\n")
}

// MARK: the suite

@Suite("KitGoldenWholeTests")
struct KitGoldenWholeTests {

    @Test("bash -n on kit-golden.sh and kit-lib/golden.sh")
    func syntax() throws {
        for path in [goldenScript, goldenLib] {
            let r = try run("/bin/bash", ["-n", path])
            #expect(r.status == 0, "bash -n \(path): \(r.output)")
        }
    }

    @Test("the usage names `prepare [--whole]` and `index-state [--whole]`; an unknown mode is exit 2")
    func usageLine() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        let r = try golden(rig, ["no-such-mode"])
        #expect(r.status == 2, "exit \(r.status): \(r.output)")
        #expect(r.output.contains("kit-golden.sh prepare [--whole]"), "usage lacks `kit-golden.sh prepare [--whole]`:\n\(r.output)")
        #expect(r.output.contains("kit-golden.sh index-state [--whole]"), "usage lacks `kit-golden.sh index-state [--whole]`:\n\(r.output)")
    }

    @Test("prepare and index-state take only --whole: any other argument is a usage error (exit 2) before anything runs")
    func usageErrors() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        for args in [["prepare", "--nope"], ["prepare", "--whole", "extra"], ["prepare", "photos"], ["index-state", "--nope"],
                     ["index-state", "--whole", "extra"]] {
            let r = try golden(rig, args)
            #expect(r.status == 2, "\(args): expected exit 2, got \(r.status):\n\(r.output)")
        }
    }

    @Test("the whole-folder prepare has its own marker, indexes both folders in one helper call, and the photo-scoped prepare is unchanged")
    func textChecks() {
        let text = readText(goldenScript)
        #expect(text.contains("run/golden-index-whole"), "the marker run/golden-index-whole is not named in kit-golden.sh")
        #expect(text.contains("run/golden-index\""), "the photo marker run/golden-index is gone from kit-golden.sh")

        let photo = functionText(text, "prepare_run")
        #expect(!photo.isEmpty, "prepare_run is not defined")
        #expect(photo.contains("--folders golden/photos"), "prepare indexes more than golden/photos, or no longer golden/photos")
        #expect(!photo.contains("golden-docs"), "the photo-scoped prepare names golden-docs")

        let whole = functionText(text, "prepare_whole_run")
        #expect(!whole.isEmpty, "prepare_whole_run is not defined")
        #expect(whole.contains("--folders golden/photos golden-docs"), "prepare --whole does not index golden/photos and golden-docs in one helper call")
        #expect(whole.contains("GOLDEN_MARK_WHOLE"), "prepare --whole does not use its own marker")
        #expect(whole.contains("build golden-docs"), "prepare --whole does not build golden-docs")
        #expect(whole.contains("golden_indexed_whole"), "prepare --whole does not read golden_indexed_whole")
        #expect(!whole.contains("GOLDEN_MARK\""), "prepare --whole writes the photo marker")
        #expect(text.range(of: #"GOLDEN_MARK_WHOLE="\$KIT_ROOT/run/golden-index-whole""#, options: .regularExpression) != nil,
                "GOLDEN_MARK_WHOLE is not \"$KIT_ROOT/run/golden-index-whole\"")
    }

    @Test("golden_indexed_whole counts only the two folders (boundary does not count) and is the gate of panel --group c")
    func gateText() {
        let text = readText(goldenScript)
        let gate = functionText(text, "golden_indexed_whole")
        #expect(!gate.isEmpty, "golden_indexed_whole is not defined in kit-golden.sh")
        let panelC = functionText(text, "panel_group_c")
        #expect(panelC.contains("golden_indexed_whole"), "panel --group c does not stop on a missing whole-folder index (golden_indexed_whole)")
        let reading = functionText(text, "golden_whole_reading") + functionText(text, "golden_whole_index")
        #expect(!reading.contains("boundary"), "the whole-folder reading names boundary: files of other roots must not count")
        #expect(readText(goldenLib).contains("golden_whole_expect"), "golden.sh has no golden_whole_expect")
    }

    // MARK: pure runs on a hand-made tree

    @Test("golden_whole_expect lists the files with a reader under golden/photos and golden-docs, the locked and the damaged pdf as could_not_read, and nothing of boundary or of a type with no reader")
    func expectList() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        try makeTree(rig)
        let script = """
            . "$1/scripts/kit-lib/common.sh" || exit 90
            . "$1/scripts/kit-lib/golden.sh" || exit 91
            golden_whole_expect | sort
            """
        var env = rig.env
        env["LC_ALL"] = "C"
        let r = try run("/bin/bash", ["-c", script, "bash", projectRoot.path], env: env, limit: 60)
        let want = treeFiles.map { "\($0.path)\t\($0.status == "done" ? "done" : "could_not_read")" }.sorted()
        #expect(r.status == 0, "exit \(r.status): \(r.output)")
        #expect(r.lines == want, "golden_whole_expect gave\n\(r.lines.joined(separator: "\n"))\nexpected\n\(want.joined(separator: "\n"))")
    }

    private typealias Row = (path: String, kind: String, status: String)

    /// The finished index of the hand-made tree, with one change.
    private func rows(_ change: (inout [Row]) -> Void) -> [Row] {
        var out = treeFiles
        change(&out)
        return out
    }

    @Test("index-state --whole: DONE is yes only when every golden file with a reader is done as the key says; ONLY is yes only when the index holds nothing else; exit 0 only when both are yes")
    func indexStateWhole() throws {
        // (label, rows, DONE, ONLY)
        let cases: [(String, [Row]?, String, String)] = [
            ("a finished index", rows { _ in }, "yes", "yes"),
            ("a boundary file also indexed (the recipe golden's index)", rows { $0.append(("boundary/one-page.pdf", "pdf", "done")) }, "yes", "no"),
            ("a pdf still pending", rows { $0[2].status = "pending" }, "no", "yes"),
            ("a pdf partial (later steps left)", rows { $0[2].status = "partial" }, "no", "yes"),
            ("a readable pdf that could not be read", rows { $0[2].status = "could_not_read" }, "no", "yes"),
            ("the locked pdf done (it must be could_not_read)", rows { $0[3].status = "done" }, "no", "yes"),
            ("the damaged pdf done (it must be could_not_read)", rows { $0[4].status = "done" }, "no", "yes"),
            ("the damaged pdf missing from the index", rows { $0.remove(at: 4) }, "no", "no"),
            ("a golden photo missing from the index", rows { $0.remove(at: 1) }, "no", "no"),
            ("a document pending", rows { $0[5].status = "pending" }, "no", "yes"),
            ("no index at all", nil, "no", "no"),
        ]
        for (label, indexRows, done, only) in cases {
            let rig = try makeRig()
            defer { rig.remove() }
            try makeTree(rig)
            if let indexRows { try makeIndex(rig, rows: indexRows) }
            let r = try golden(rig, ["index-state", "--whole"])
            let doneLine = r.lines.first { $0.hasPrefix("INDEX GOLDEN WHOLE DONE:") } ?? "(no DONE line)"
            let onlyLine = r.lines.first { $0.hasPrefix("INDEX GOLDEN WHOLE ONLY:") } ?? "(no ONLY line)"
            #expect(doneLine.hasPrefix("INDEX GOLDEN WHOLE DONE: \(done)"), "\(label): \(doneLine)\n\(r.output)")
            #expect(onlyLine.hasPrefix("INDEX GOLDEN WHOLE ONLY: \(only)"), "\(label): \(onlyLine)\n\(r.output)")
            let both = done == "yes" && only == "yes"
            #expect(r.status == (both ? 0 : 1), "\(label): exit \(r.status), expected \(both ? 0 : 1)\n\(r.output)")
        }
    }

    @Test("index-state --whole with no golden file on disk is not ready (nothing with a reader to be done)")
    func emptyTree() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        try makeIndex(rig, rows: [])
        let r = try golden(rig, ["index-state", "--whole"])
        #expect(r.status == 1, "exit \(r.status): \(r.output)")
        #expect(r.lines.contains { $0.hasPrefix("INDEX GOLDEN WHOLE DONE: no") }, "\(r.output)")
    }

    @Test("the photo-scoped index-state still reads yes for the 40-photo index only (the whole-folder change leaves it alone)")
    func photoIndexStateUnchanged() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        try FileManager.default.createDirectory(atPath: rig.indexDir, withIntermediateDirectories: true)
        try sqlite(rig.db, "create table files(path text primary key, kind text, status text, reason text); create table passages(id integer primary key, file text);")
        let photos = (0..<40).map { "('\(rig.fixtures)/golden/photos/p\($0).jpg','photo','done',NULL)" }
        try sqlite(rig.db, "insert into files values \(photos.joined(separator: ","));")
        let only = try golden(rig, ["index-state"])
        #expect(only.status == 0 && only.lines.contains { $0.hasPrefix("INDEX GOLDEN PHOTOS ONLY: yes") }, "photos only:\n\(only.output)")
        try sqlite(rig.db, "insert into files values ('\(rig.fixtures)/golden-docs/pdfs/lease-2024.pdf','pdf','done',NULL);")
        let withPdf = try golden(rig, ["index-state"])
        #expect(withPdf.status == 1 && withPdf.lines.contains { $0.hasPrefix("INDEX GOLDEN PHOTOS ONLY: no") }, "with a pdf:\n\(withPdf.output)")
    }
}
