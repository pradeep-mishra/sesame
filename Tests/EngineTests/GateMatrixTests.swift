import Foundation
import Testing
import SesameEngine

// plan-3-t15, tester step: the gate matrix against `Rules.admit(path:picks:)`. Written from the entry of plan-3-tasks.md
// (t15 Tests, t1 for the table's columns and the three forms of `picks`) and the table `scripts/kit-lib/gate-matrix.csv`
// only; no product source is read.
//
// The suite builds the matrix with `scripts/kit-fixtures.sh build matrix` as a child process under a temp KIT_ROOT (no app
// is started, nothing outside the temp folder is written), reads every row of the hand-written table, and for each row
// that `Rules` decides compares `Rules.admit(path:picks:) != nil` with the table's `expected_in_index` column. The expected
// column is read from the CSV, never computed. The `git-ignored` class is decided by t17 and skipped here. The `extra`
// group (design's extra key names) is printed `EXTRA <cell> excluded|read` and never asserted.
//
// `picks`, as plan 7 t1 fixes it: `folder|folder|...` relative to `matrix/`, a folder path alone; blank, the cell's own top
// folder; `-`, the cell's top folder is in no pick. For `-` the test passes one pick of a different folder (`plain`), so
// the nil is the cell's place and not an empty list. Code is never read: every decision is made twice, once with the code
// tick of every pick false and once with it true, and the table's answer is the same for both.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let tablePath = projectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv").path
private let fixturesScript = projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path

// MARK: the table (read, never changed)

private struct Row {
    let cell: String
    let path: String
    let picks: String
    let expectedInIndex: String
    let reason: String
    let group: String
    var top: String { String(path.split(separator: "/", maxSplits: 1)[0]) }
}

private let rows: [Row] = {
    guard let text = try? String(contentsOfFile: tablePath, encoding: .utf8) else { return [] }
    var parsed: [Row] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7 else { continue }
        parsed.append(Row(cell: f[0], path: f[1], picks: f[2], expectedInIndex: f[3], reason: f[5], group: f[6]))
    }
    return parsed
}()

// MARK: building the matrix in a temp KIT_ROOT

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String], limit: TimeInterval = 600) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("gatematrix-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(limit)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        status = 124
    } else {
        status = process.terminationStatus
    }
    try? handle.synchronize()
    return Ran(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

private final class Cleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }
    func run() {
        lock.lock()
        let all = paths
        lock.unlock()
        for path in all { try? FileManager.default.removeItem(atPath: path) }
    }
}
private let cleanup = Cleanup()
private let cleanupRegistered: Void = { atexit { cleanup.run() } }()

private struct Built {
    let matrix: String
    let ran: Ran
}

/// One build for the whole suite: a fresh KIT_ROOT, TMPDIR and decoy HOME under a temp folder, removed at exit.
private let built: Built? = {
    _ = cleanupRegistered
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("gate-matrix-" + UUID().uuidString, isDirectory: true)
    guard (try? fm.createDirectory(at: made, withIntermediateDirectories: true)) != nil else { return nil }
    let base = made.resolvingSymlinksInPath().path
    cleanup.add(base)
    let kit = base + "/sesame-kit-gate"
    let tmp = base + "/tmp"
    let home = base + "/decoy-home"
    for dir in [kit + "/run", tmp, home] {
        guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else { return nil }
    }
    let env = ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": home,
               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    guard fm.fileExists(atPath: fixturesScript),
          let ran = try? run("/bin/bash", [fixturesScript, "build", "matrix"], env: env) else {
        return Built(matrix: kit + "/fixtures/matrix", ran: Ran(status: 127, output: "scripts/kit-fixtures.sh not found or not started"))
    }
    return Built(matrix: kit + "/fixtures/matrix", ran: ran)
}()

// MARK: the picks of a row

private let codeTicks = [false, true]

private func picks(for row: Row, matrix: String, code: Bool) -> [HelperFolder] {
    switch row.picks {
    case "":
        return [HelperFolder(path: matrix + "/" + row.top, code: code)]
    case "-":
        return [HelperFolder(path: matrix + "/plain", code: code)]
    default:
        return row.picks.split(separator: "|").map { HelperFolder(path: matrix + "/" + String($0), code: code) }
    }
}

@Suite("GateMatrixTests")
struct GateMatrixTests {

    @Test func theMatrixBuildsInATempKitRoot() throws {
        let result = try #require(built, "could not make the temp KIT_ROOT")
        #expect(result.ran.status == 0, "kit-fixtures.sh build matrix exited \(result.ran.status): \(result.ran.output.suffix(600))")
        #expect(!rows.isEmpty, "the table scripts/kit-lib/gate-matrix.csv has no rows")
        for row in rows {
            var info = stat()
            #expect(lstat(result.matrix + "/" + row.path, &info) == 0, "cell \(row.cell): \(row.path) was not built")
        }
    }

    @Test func rulesDecidesEveryRowOfTheTableLikeItsExpectedInIndexColumn() throws {
        let result = try #require(built, "could not make the temp KIT_ROOT")
        try #require(result.ran.status == 0, "the matrix did not build (exit \(result.ran.status)): \(result.ran.output.suffix(600))")
        try #require(!rows.isEmpty, "the table has no rows")

        let decided = rows.filter { $0.group == "spec" && $0.reason != "git-ignored" }
        try #require(!decided.isEmpty)
        var checked = 0
        for row in decided {
            for tick in codeTicks {
                let admitted = Rules.admit(path: result.matrix + "/" + row.path, picks: picks(for: row, matrix: result.matrix, code: tick)) != nil
                let expected = row.expectedInIndex == "yes"
                checked += 1
                #expect(
                    admitted == expected,
                    "cell \(row.cell) (class \(row.reason), code tick \(tick)): expected_in_index \(row.expectedInIndex), Rules.admit(path:picks:) says \(admitted ? "admitted" : "nil")")
            }
        }
        #expect(checked == decided.count * 2)
        // The table holds both answers, so a rule that admits everything or nothing cannot pass.
        #expect(decided.contains { $0.expectedInIndex == "yes" })
        #expect(decided.contains { $0.expectedInIndex == "no" })
    }

    @Test func theGitIgnoredClassIsLeftToTheGitFileListAndTheExtraGroupIsOnlyPrinted() throws {
        let result = try #require(built, "could not make the temp KIT_ROOT")
        try #require(result.ran.status == 0, "the matrix did not build (exit \(result.ran.status))")
        for row in rows where row.group == "extra" {
            let admitted = Rules.admit(path: result.matrix + "/" + row.path, picks: picks(for: row, matrix: result.matrix, code: false)) != nil
            print("EXTRA \(row.cell) \(admitted ? "read" : "excluded")")
        }
        // Not asserted: the `git-ignored` rows are t17's, the `extra` rows are only reported.
        #expect(rows.contains { $0.group == "extra" }, "the table should hold the extra group")
        #expect(rows.contains { $0.reason == "git-ignored" }, "the table should hold the git-ignored class that this suite skips")
    }

    private static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif", "gif"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]
    private static let decidedExtensions: Set<String> = pictureExtensions.union(["pdf", "txt", "md", "rtf", "docx", "html", "odt"]).union(audioExtensions).union(videoExtensions).union(codeExtensions)
    private static let repoTops = ["repo-off", "ignored-off", "ignored-on", "vend-in"]
    private static let systemGit = "/usr/bin/git"

    private static func isDecided(_ row: Row) -> Bool {
        decidedExtensions.contains((row.path as NSString).pathExtension.lowercased())
    }

    @Test func readModeOverTheRepoCellsReturnsAFileExactlyWhenTheTableSaysYesWhateverTheCodeTick() throws {
        let result = try #require(built, "could not make the temp KIT_ROOT")
        try #require(result.ran.status == 0, "the matrix did not build (exit \(result.ran.status)): \(result.ran.output.suffix(600))")
        try #require(FileManager.default.isExecutableFile(atPath: Self.systemGit), "setup: no git at \(Self.systemGit)")
        var yesCells = 0
        var noCells = 0
        for tick in codeTicks {
            for top in Self.repoTops {
                let topRows = rows.filter { $0.top == top && $0.group == "spec" }
                try #require(!topRows.isEmpty, "the table holds no row for the repo folder \(top)")
                let rowPicks = picks(for: topRows[0], matrix: result.matrix, code: tick)
                let scanned = Walker.scan(root: result.matrix + "/" + top, mode: .read, picks: rowPicks)
                let got = Set(scanned.files.map { String($0.path.dropFirst(result.matrix.count + 1)) })

                var want: Set<String> = []
                for row in topRows where Self.isDecided(row) {
                    let expected = row.expectedInIndex == "yes"
                    if expected { want.insert(row.path); yesCells += 1 } else { noCells += 1 }
                    #expect(got.contains(row.path) == expected,
                            "cell \(row.cell) (class \(row.reason), code tick \(tick)): expected_in_index \(row.expectedInIndex), read mode says \(got.contains(row.path) ? "returned" : "not returned")")
                }
                #expect(got == want, "\(top) (code tick \(tick)): missing \(want.subtracting(got).sorted()), unexpected \(got.subtracting(want).sorted())")
            }
        }
        #expect(yesCells > 0, "the repo cells should hold a file that is read")
        #expect(noCells > 0, "the repo cells should hold a file that is not read")
    }

    @Test func aRepoReadsItsPicturesItsDocumentsAndItsPdfAndNeverItsCodeWhateverTheCodeTick() throws {
        let result = try #require(built, "could not make the temp KIT_ROOT")
        try #require(result.ran.status == 0, "the matrix did not build (exit \(result.ran.status)): \(result.ran.output.suffix(600))")
        func cell(_ name: String) throws -> Row { try #require(rows.first { $0.cell == name }, "the table holds no cell \(name)") }
        func returned(_ row: Row, _ tick: Bool) -> Bool {
            let scanned = Walker.scan(root: result.matrix + "/" + row.top, mode: .read, picks: picks(for: row, matrix: result.matrix, code: tick))
            return scanned.files.contains { String($0.path.dropFirst(result.matrix.count + 1)) == row.path }
        }
        for tick in codeTicks {
            for name in ["repo-off-png", "repo-off-txt", "repo-off-pdf"] {
                let row = try cell(name)
                #expect(row.expectedInIndex == "yes", "setup: the table says \(name) is \(row.expectedInIndex)")
                #expect(returned(row, tick), "\(name) (\(row.path)) is a supported file in a picked repo and must be returned by read mode (code tick \(tick))")
            }
            let code = try cell("repo-off-py")
            #expect(code.expectedInIndex == "no", "setup: the table says repo-off-py is \(code.expectedInIndex)")
            #expect(!returned(code, tick), "repo-off-py (\(code.path)) is code and must never be returned (code tick \(tick))")
            for name in ["ignored-off-txt", "ignored-on-txt", "vend-in-node_modules-txt", "vend-in-Pods-txt"] {
                let row = try cell(name)
                #expect(!returned(row, tick), "\(name) (\(row.path)) is a text file that git ignores or a vendored folder holds and must not be returned (code tick \(tick))")
            }
        }
        #expect(!rows.contains { $0.cell.hasPrefix("repo-on-") }, "the table still holds a ticked-repo cell")
    }

    private static let overlapPhotoCells: [String: Int] = [
        "ov-a-inner-photo": 1, "ov-a-outer-photo": 1,
        "ov-b-inner-photo": 1, "ov-b-outer-photo": 1,
        "ov-c-inner-photo": 1, "ov-c-outer-photo": 1,
        "ov-d-inner-photo": 1, "ov-d-outer-photo": 1,
    ]

    @Test func readModeReturnsNoCodeCellWhateverTheCodeTickAndEveryOverlapPhotoExactlyOnce() throws {
        let result = try #require(built, "could not make the temp KIT_ROOT")
        try #require(result.ran.status == 0, "the matrix did not build (exit \(result.ran.status)): \(result.ran.output.suffix(600))")
        let wanted = rows.filter { $0.group == "spec" && (Self.codeExtensions.contains(($0.path as NSString).pathExtension.lowercased()) || $0.top.hasPrefix("ov-")) }
        try #require(wanted.count == 45, "the table holds \(wanted.count) code and overlap cells, hand count 45 (37 code, 8 overlap photos)")
        var groups: [String: [Row]] = [:]
        for row in wanted { groups[row.top + "|" + row.picks, default: []].append(row) }
        var yes = 0
        var no = 0
        for tick in codeTicks {
            var seen: [String: Int] = [:]
            for (_, group) in groups {
                let first = group[0]
                let scanned = Walker.scan(root: result.matrix + "/" + first.top, mode: .read, picks: picks(for: first, matrix: result.matrix, code: tick))
                let paths = scanned.files.map { String($0.path.dropFirst(result.matrix.count + 1)) }
                for row in group {
                    let count = paths.filter { $0 == row.path }.count
                    seen[row.cell] = count
                    let expected = row.expectedInIndex == "yes" ? 1 : 0
                    if expected == 1 { yes += 1 } else { no += 1 }
                    #expect(count == expected, "cell \(row.cell) (class \(row.reason), code tick \(tick)): expected_in_index \(row.expectedInIndex), read mode returned it \(count) time(s)")
                }
            }
            for (name, count) in Self.overlapPhotoCells {
                #expect(seen[name] == count, "overlap cell \(name) (code tick \(tick)): read mode returned it \(seen[name].map(String.init) ?? "never scanned") time(s), expected \(count)")
            }
            for name in ["ov-a-inner-code", "ov-a-outer-code", "ov-b-inner-code", "ov-b-outer-code", "ov-c-inner-code", "ov-d-inner-code",
                         "plain-code-on", "plain-code-off", "damaged-swift", "good-swift", "never-picked-code", "key-code-id_rsa-py", "key-code-env-py", "ignored-on-folder-py"] {
                #expect(seen[name] == 0, "\(name) (code tick \(tick)): read mode returned it \(seen[name].map(String.init) ?? "never scanned") time(s), expected 0: code is never read")
            }
        }
        #expect(yes == 16 && no == 74, "the cells hold \(yes) read and \(no) not read over two ticks, hand count 16 and 74")
    }

    @Test func readModeReturnsTheAudioCellsAndTheVideoCells() throws {
        let result = try #require(built, "could not make the temp KIT_ROOT")
        try #require(result.ran.status == 0, "the matrix did not build (exit \(result.ran.status)): \(result.ran.output.suffix(600))")
        func cell(_ name: String) throws -> Row { try #require(rows.first { $0.cell == name }, "the table holds no cell \(name)") }
        func returned(_ row: Row) -> Bool {
            let scanned = Walker.scan(root: result.matrix + "/" + row.top, mode: .read, picks: picks(for: row, matrix: result.matrix, code: false))
            return scanned.files.contains { String($0.path.dropFirst(result.matrix.count + 1)) == row.path }
        }
        for name in ["plain-audio", "extav-mp3", "extav-m4a", "extav-wav", "extav-aac", "extav-flac"] {
            let row = try cell(name)
            #expect(row.expectedInIndex == "yes", "setup: the table says \(name) is \(row.expectedInIndex)")
            #expect(returned(row), "\(name) (\(row.path)) is an audio file the rules admit and audio has a reader: read mode must return it")
        }
        for name in ["plain-video", "extav-mp4", "extav-mov", "extav-m4v"] {
            let row = try cell(name)
            #expect(row.expectedInIndex == "yes", "setup: the table says \(name) is \(row.expectedInIndex)")
            #expect(returned(row), "\(name) (\(row.path)) is a video file the rules admit and video has a reader: read mode must return it")
        }
    }

    @Test func gitAnswersForEveryRepoCellFolderAndLeavesOutTheIgnoredFiles() throws {
        let result = try #require(built, "could not make the temp KIT_ROOT")
        try #require(result.ran.status == 0, "the matrix did not build (exit \(result.ran.status))")
        var ignoredSeen = 0
        for top in Self.repoTops {
            let listed = GitFiles.list(repo: result.matrix + "/" + top, git: Self.systemGit)
            try #require(listed != nil, "git gave no answer for the repo folder \(top)")
            let files = listed ?? []
            if top.hasPrefix("ignored") {
                #expect(files.contains(".gitignore"), "\(top): the untracked, not ignored .gitignore is listed, got \(files.sorted())")
            }
            for row in rows where row.top == top && row.group == "spec" {
                let inRepo = String(row.path.dropFirst(top.count + 1))
                if row.reason == "git-ignored" {
                    ignoredSeen += 1
                    #expect(!files.contains(inRepo), "cell \(row.cell): git lists the ignored file \(inRepo)")
                } else if row.reason == "ok" {
                    #expect(files.contains(inRepo), "cell \(row.cell): git does not list \(inRepo), got \(files.sorted())")
                }
            }
        }
        #expect(ignoredSeen == 3, "the table holds three git-ignored cells (ignored-off-png, ignored-off-txt, ignored-on-txt), saw \(ignoredSeen)")
    }
}
