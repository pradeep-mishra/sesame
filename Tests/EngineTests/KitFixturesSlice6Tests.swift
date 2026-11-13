import Foundation
import Testing

// plan-6-t1, tester step, parts A and B: the golden repos, the answer rows and the matrix cells of
// slice 6. Written from the entry plan-6-t1 of plan-6-tasks.md, the spec (S5, S2(e), S8(b)), verify.md and the feature
// maps S5, S2 and S8; no product source is read.
//
// Every run is a child process: kit-fixtures.sh with its own temp KIT_ROOT (a folder named sesame-kit*), its own TMPDIR
// and a decoy HOME, with a real git and the global git config switched off. No app is started and `swift test` is never
// nested. The files are checked here with independent readers (awk, git, shasum, grep); every expected value is a hand
// table in this file. The kit's own tables (repos.tsv, answers.csv, gate-matrix.csv) are read only to be
// compared with these hand tables and with the built files.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `build repos` makes $KIT_ROOT/home/Developer/{api-client,legacy-sync,scratch-lab} (only those three folders are
//     written; the rest of home/ is left alone) and prints BUILT repos or UNCHANGED repos.
//   - scripts/kit-lib/repos.tsv: `<type> TAB <repo> TAB <file> TAB <name> TAB <line or kind>`, types def, call, decoy,
//     picture and excluded.
//   - answers.csv: no group `code`; group `repodoc` ids repodoc-01 and repodoc-02; a file starting `api-client/` is
//     under home/Developer/.
//   - gate-matrix.csv: the code extension cells are `ext-<ext>` under extcode/ (picks `extcode`), each no, 0, unsupported.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixturesScript = projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path
private let kitLib = projectRoot.appendingPathComponent("scripts/kit-lib")

// MARK: hand-written tables

private struct Fn: Sendable {
    let name: String
    let repo: String
    let file: String
    let line: Int
}

/// Every function of the three repos and the line its `func` is on: counted by hand from the files of scripts/kit-lib/repo-src.
private let handFunctions: [Fn] = [
    Fn(name: "retryWithBackoff", repo: "api-client", file: "retry.swift", line: 4),
    Fn(name: "refreshAccessToken", repo: "api-client", file: "auth.swift", line: 9),
    Fn(name: "fetchAllPages", repo: "api-client", file: "pagination.swift", line: 4),
    Fn(name: "cachedResponse", repo: "api-client", file: "cache.swift", line: 6),
    Fn(name: "waitForRateLimit", repo: "api-client", file: "ratelimit.swift", line: 4),
    Fn(name: "buildQueryString", repo: "api-client", file: "url.swift", line: 4),
    Fn(name: "uploadInChunks", repo: "api-client", file: "upload.swift", line: 4),
    Fn(name: "describeHttpError", repo: "api-client", file: "errors.swift", line: 9),
    Fn(name: "signRequest", repo: "api-client", file: "signing.swift", line: 4),
    Fn(name: "decodeResponseBody", repo: "api-client", file: "json.swift", line: 4),
    Fn(name: "mergeStaleRecords", repo: "legacy-sync", file: "merge.swift", line: 4),
    Fn(name: "parseLooseDates", repo: "scratch-lab", file: "dates.swift", line: 4),
]

/// refreshAccessToken is called from these three other files and no other.
private let handCallers = ["client.swift", "session.swift", "upload.swift"]

private let handDecoys = ["api-client/docs/retry-notes.md", "api-client/docs/retry-diagram.png"]

/// The excluded files of api-client (S5.8): path, the unique string inside, the kind of exclusion.
private let handExcluded: [(path: String, string: String, kind: String)] = [
    ("scratch-output.swift", "exclzx7101", "ignored"),
    ("node_modules/leftpad/index.js", "exclzx7102", "node_modules"),
    ("Pods/Alamofire/Source.swift", "exclzx7103", "Pods"),
    ("build/output.js", "exclzx7104", "build"),
    ("dist/bundle.js", "exclzx7105", "dist"),
    (".build/debug/module.swift", "exclzx7106", ".build"),
    ("vendor/github/lib.go", "exclzx7107", "vendor"),
    ("certs/server.pem", "exclzx7111", "pem"),
    ("certs/signing.key", "exclzx7112", "key"),
    ("certs/bundle.p12", "exclzx7113", "p12"),
    ("certs/client.pfx", "exclzx7114", "pfx"),
    ("id_rsa.txt", "exclzx7115", "id_rsa"),
    (".env.local.md", "exclzx7116", "env"),
    ("vault.kdbx", "exclzx7117", "kdbx"),
]

/// The first 91 lines of answers.csv before plan 6 (the header and 90 rows): never changed.
private let oldKeySha = "489586c7250695c211bc7e0bdff41ae2bb1eef2283a5ee365f33beb6cf32d7cd"

/// The cells plan 6 adds to gate-matrix.csv, by hand: id, path, picks, in index, rows, reason, group.
private let handNewCells: [(id: String, path: String, picks: String, inIndex: String, rows: String, reason: String)] = [
    ("ignored-on-folder-py", "ignored-on/genfolder/gen_zq1503.py", "ignored-on", "no", "0", "unsupported"),
    ("vend-in-Pods-py", "vend-in/Pods/code_zq1511.py", "vend-in", "no", "0", "unsupported"),
    ("vend-in-build-py", "vend-in/build/code_zq1512.py", "vend-in", "no", "0", "unsupported"),
    ("vend-in-dist-py", "vend-in/dist/code_zq1513.py", "vend-in", "no", "0", "unsupported"),
    ("vend-in-dot-build-py", "vend-in/.build/code_zq1514.py", "vend-in", "no", "0", "unsupported"),
    ("vend-in-vendor-py", "vend-in/vendor/code_zq1515.py", "vend-in", "no", "0", "unsupported"),
    ("key-code-id_rsa-py", "keys-code/id_rsa.zq1521.py", "keys-code", "no", "0", "unsupported"),
    ("key-code-env-py", "keys-code/.env.zq1522.py", "keys-code", "no", "0", "unsupported"),
    ("never-picked-code", "never-picked/secret_zq1531.py", "-", "no", "0", "unsupported"),
    ("damaged-swift", "damaged-code/broken_zq1541.swift", "damaged-code", "no", "0", "unsupported"),
    ("good-swift", "damaged-code/good_zq1542.swift", "damaged-code", "no", "0", "unsupported"),
]

/// The code extension cells: extension and the token of its file name.
private let handExtCells: [(ext: String, token: String)] = [
    ("swift", "zq1401"), ("py", "zq1402"), ("js", "zq1403"), ("ts", "zq1404"), ("tsx", "zq1405"), ("jsx", "zq1406"),
    ("go", "zq1407"), ("rs", "zq1408"), ("java", "zq1409"), ("kt", "zq1410"), ("c", "zq1411"), ("h", "zq1412"),
    ("cpp", "zq1413"), ("rb", "zq1414"), ("sh", "zq1415"),
]

// MARK: running things

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 900) throws -> Ran {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("kitfx6-out-" + UUID().uuidString)
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
        for p in all { try? FileManager.default.removeItem(atPath: p) }
    }
}
private let cleanup = Cleanup()
private let cleanupRegistered: Void = { atexit { cleanup.run() } }()

private struct Root: Sendable {
    let base: String
    let kit: String
    let tmp: String
    let decoyHome: String
    var fixtures: String { kit + "/fixtures" }
    var developer: String { kit + "/home/Developer" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome,
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
}

private func makeRoot() throws -> Root {
    _ = cleanupRegistered
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-s6-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let base = made.resolvingSymlinksInPath().path
    let root = Root(base: base, kit: base + "/sesame-kit-s6", tmp: base + "/tmp", decoyHome: base + "/decoy-home")
    try fm.createDirectory(atPath: root.kit + "/run", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root.tmp, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root.decoyHome, withIntermediateDirectories: true)
    cleanup.add(root.base)
    return root
}

private func kit(_ root: Root, _ args: String...) throws -> Ran {
    guard FileManager.default.fileExists(atPath: fixturesScript) else {
        Issue.record("scripts/kit-fixtures.sh not found")
        return Ran(status: 127, output: "scripts/kit-fixtures.sh not found")
    }
    return try run("/bin/bash", [fixturesScript] + args, env: root.env)
}

/// The one repos build that most tests read (made once, removed at exit).
private let sharedRepos: (root: Root, built: Ran)? = {
    guard let root = try? makeRoot(), let ran = try? kit(root, "build", "repos") else { return nil }
    return (root, ran)
}()

private func reposBuilt() -> (root: Root, built: Ran) {
    guard let s = sharedRepos else {
        Issue.record("could not make the shared kit root")
        return (Root(base: "", kit: "", tmp: "", decoyHome: ""), Ran(status: 127, output: ""))
    }
    return s
}

// MARK: independent readers

private func exists(_ path: String) -> Bool {
    var st = Darwin.stat()
    return lstat(path, &st) == 0
}

private func isDir(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}

/// Every regular file under dir, relative, sorted, never inside `.git`.
private func filesUnder(_ dir: String) -> [String] {
    var out: [String] = []
    guard let walker = FileManager.default.enumerator(atPath: dir) else { return [] }
    for case let rel as String in walker {
        if rel == ".git" || rel.hasPrefix(".git/") { continue }
        var st = Darwin.stat()
        if lstat(dir + "/" + rel, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { out.append(rel) }
    }
    return out.sorted()
}

/// The lines of a file whose text holds the needle, as 1-based line numbers (awk's own index(), not the kit's reader).
private func linesHolding(_ needle: String, in file: String) -> [Int] {
    let ran = try? run("/usr/bin/awk", ["-v", "n=" + needle, "index($0, n) > 0 { print FNR }", file])
    return (ran?.lines ?? []).compactMap { Int($0) }
}

private func shaOf(_ path: String) -> String {
    let ran = try? run("/usr/bin/shasum", ["-a", "256", path])
    return ran?.output.split(separator: " ").first.map(String.init) ?? ""
}

private func mtimeOf(_ path: String) -> Int {
    var st = Darwin.stat()
    return lstat(path, &st) == 0 ? Int(st.st_mtimespec.tv_sec) : -1
}

/// `<relative path> sha mtime` for every non-.git file under dir.
private func manifest(_ dir: String) -> [String] {
    filesUnder(dir).map { "\($0) \(shaOf(dir + "/" + $0)) \(mtimeOf(dir + "/" + $0))" }
}

private func git(_ root: Root, _ repo: String, _ args: [String]) throws -> Ran {
    try run("/usr/bin/git", ["-C", repo] + args, env: root.env)
}

private func text(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

private func tsvRows(_ name: String) -> [[String]] {
    text(kitLib.appendingPathComponent(name).path).split(separator: "\n", omittingEmptySubsequences: true)
        .filter { !$0.hasPrefix("#") }
        .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
}

private func csvRows(_ path: String) -> [[String]] {
    text(path).split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
        .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
}

// MARK: part A, the golden repos

@Suite("KitFixturesSlice6Tests")
struct KitFixturesSlice6Tests {

    @Test func buildReposMakesTheThreeRepos() throws {
        let (root, built) = reposBuilt()
        #expect(built.status == 0, "build repos exited \(built.status): \(built.output.prefix(300))")
        #expect(built.output.contains("BUILT repos"), "the first build must print BUILT repos, got: \(built.output.prefix(300))")
        for repo in ["api-client", "legacy-sync", "scratch-lab"] {
            #expect(isDir(root.developer + "/" + repo + "/.git"), "\(repo) has no .git folder")
        }
    }

    @Test func developerHoldsOnlyTheThreeReposAndFixturesIsNotTouched() throws {
        let (root, _) = reposBuilt()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.developer))?.sorted() ?? []
        #expect(entries == ["api-client", "legacy-sync", "scratch-lab"], "home/Developer holds \(entries)")
        #expect(!exists(root.fixtures + "/golden"),
                "build repos wrote into fixtures/: \((try? FileManager.default.contentsOfDirectory(atPath: root.fixtures)) ?? [])")
    }

    @Test func eachRepoIsARealGitRepoWithNoCommit() throws {
        let (root, _) = reposBuilt()
        for repo in ["api-client", "legacy-sync", "scratch-lab"] {
            let dir = root.developer + "/" + repo
            let inside = try git(root, dir, ["rev-parse", "--is-inside-work-tree"])
            #expect(inside.status == 0 && inside.output.contains("true"), "\(repo): git does not see a work tree: \(inside.output)")
            let head = try git(root, dir, ["rev-parse", "--verify", "HEAD"])
            #expect(head.status != 0, "\(repo) has a commit: nothing may depend on the clock")
        }
    }

    @Test func everyNamedFunctionIsDefinedOnceAtTheStatedLine() throws {
        let (root, _) = reposBuilt()
        for fn in handFunctions {
            let dir = root.developer + "/" + fn.repo
            var hits: [(file: String, line: Int)] = []
            for rel in filesUnder(dir) {
                for needle in ["func \(fn.name)(", "func \(fn.name)<"] {
                    for l in linesHolding(needle, in: dir + "/" + rel) { hits.append((rel, l)) }
                }
            }
            #expect(hits.count == 1, "\(fn.name) is defined \(hits.count) times in \(fn.repo), expected once: \(hits)")
            #expect(hits.first?.file == fn.file, "\(fn.name) is defined in \(hits.first?.file ?? "nowhere"), expected \(fn.file)")
            #expect(hits.first?.line == fn.line, "\(fn.name) is defined at line \(hits.first?.line ?? 0), the hand table says \(fn.line)")
        }
    }

    @Test func apiClientHoldsAtLeastTenDistinctFunctionsAndTheOtherReposOne() throws {
        let (root, _) = reposBuilt()
        var names = Set<String>()
        for rel in filesUnder(root.developer + "/api-client") where rel.hasSuffix(".swift") && !rel.contains("/") {
            let t = text(root.developer + "/api-client/" + rel)
            for l in t.split(separator: "\n") where l.hasPrefix("func ") {
                let rest = l.dropFirst(5)
                names.insert(String(rest.prefix { $0 != "(" && $0 != "<" }))
            }
        }
        #expect(names.count >= 10, "api-client defines \(names.count) top-level functions at its top, expected at least 10: \(names.sorted())")
        #expect(filesUnder(root.developer + "/legacy-sync").filter { $0.hasSuffix(".swift") }.count == 1, "legacy-sync holds one code file")
        #expect(filesUnder(root.developer + "/scratch-lab").filter { $0.hasSuffix(".swift") }.count == 1, "scratch-lab holds one code file")
    }

    @Test func refreshAccessTokenIsCalledFromExactlyThreeOtherFiles() throws {
        let (root, _) = reposBuilt()
        let dir = root.developer + "/api-client"
        var callers: [String] = []
        for rel in filesUnder(dir) {
            let lines = linesHolding("refreshAccessToken(", in: dir + "/" + rel)
            let defs = linesHolding("func refreshAccessToken(", in: dir + "/" + rel)
            if !lines.isEmpty && lines.count > defs.count { callers.append(rel) }
        }
        #expect(callers.sorted() == handCallers, "refreshAccessToken is called from \(callers.sorted()), expected \(handCallers)")
    }

    @Test func theNonCodeDecoysAreThere() throws {
        let (root, _) = reposBuilt()
        let dir = root.developer
        for rel in handDecoys { #expect(exists(dir + "/" + rel), "the decoy \(rel) is missing") }
        let note = text(dir + "/api-client/docs/retry-notes.md").lowercased()
        #expect(note.contains("retry") && note.contains("failed") && note.contains("backoff"),
                "docs/retry-notes.md is not a note about retrying a failed call with backoff: \(note.prefix(200))")
        let png = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/api-client/docs/retry-diagram.png"))) ?? Data()
        #expect(png.count > 1000 && Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                "docs/retry-diagram.png is not a PNG of some size (\(png.count) bytes)")
        #expect(exists(dir + "/legacy-sync/docs/diagram.png"), "legacy-sync/docs/diagram.png is missing")
        #expect(!exists(dir + "/legacy-sync/docs/retry-notes.md") && !exists(dir + "/scratch-lab/docs"), "a decoy is in the wrong repo")
    }

    @Test func eachExcludedFileIsThereWithItsOwnUniqueString() throws {
        let (root, _) = reposBuilt()
        let dir = root.developer + "/api-client"
        for e in handExcluded {
            #expect(exists(dir + "/" + e.path), "the excluded file \(e.path) (\(e.kind)) is missing")
            let ran = try run("/usr/bin/grep", ["-rlF", "--exclude-dir=.git", e.string, dir])
            let holders = ran.lines.map { $0.replacingOccurrences(of: dir + "/", with: "") }
            #expect(holders == [e.path], "the string \(e.string) is held by \(holders), expected only \(e.path)")
        }
        let ignore = text(dir + "/.gitignore")
        #expect(ignore.split(separator: "\n").contains("scratch-output.swift"), ".gitignore does not list scratch-output.swift: \(ignore)")
        let others = try git(root, dir, ["ls-files", "--others", "--exclude-standard"])
        #expect(others.status == 0)
        let listed = Set(others.lines)
        #expect(!listed.contains("scratch-output.swift"), "git does not ignore scratch-output.swift")
        #expect(listed.contains("retry.swift") && listed.contains("docs/retry-notes.md") && listed.contains("node_modules/leftpad/index.js"),
                "git's own listing misses a file the repo holds: \(listed.sorted())")
    }

    @Test func repoTableAgreesWithTheHandTable() throws {
        let rows = tsvRows("repos.tsv")
        #expect(!rows.isEmpty, "scripts/kit-lib/repos.tsv is missing or empty")
        let defs = rows.filter { $0.first == "def" }
        #expect(defs.count == handFunctions.count, "repos.tsv holds \(defs.count) def rows, expected \(handFunctions.count)")
        for fn in handFunctions {
            #expect(defs.contains { $0.count == 5 && $0[1] == fn.repo && $0[2] == fn.file && $0[3] == fn.name && $0[4] == String(fn.line) },
                    "repos.tsv has no def row \(fn.repo) \(fn.file) \(fn.name) \(fn.line)")
        }
        let calls = rows.filter { $0.first == "call" }.map { $0.count > 2 ? $0[2] : "" }.sorted()
        #expect(calls == handCallers, "repos.tsv call rows name \(calls), expected \(handCallers)")
        let excluded = rows.filter { $0.first == "excluded" }
        #expect(excluded.count == handExcluded.count, "repos.tsv holds \(excluded.count) excluded rows, expected \(handExcluded.count)")
        for e in handExcluded {
            #expect(excluded.contains { $0.count == 5 && $0[1] == "api-client" && $0[2] == e.path && $0[3] == e.string && $0[4] == e.kind },
                    "repos.tsv has no excluded row for \(e.path)")
        }
    }

    @Test func rebuildingChangesNothingAndTwoRootsMakeTheSameBytes() throws {
        let (root, _) = reposBuilt()
        let again = try kit(root, "build", "repos")
        #expect(again.status == 0 && again.output.contains("UNCHANGED repos"), "a second build must print UNCHANGED repos, got: \(again.output.prefix(300))")
        let other = try makeRoot()
        let second = try kit(other, "build", "repos")
        #expect(second.status == 0, "second root: \(second.output.prefix(300))")
        for repo in ["api-client", "legacy-sync", "scratch-lab"] {
            let a = manifest(root.developer + "/" + repo)
            let b = manifest(other.developer + "/" + repo)
            #expect(!a.isEmpty && a == b, "\(repo): two builds in two roots differ")
        }
    }

    @Test func aDeletedFileIsBuiltAgainAndAStrayFileIsRemoved() throws {
        let root = try makeRoot()
        _ = try kit(root, "build", "repos")
        let target = root.developer + "/api-client/retry.swift"
        let before = shaOf(target)
        #expect(!before.isEmpty)
        try FileManager.default.removeItem(atPath: target)
        let stray = root.developer + "/legacy-sync/stray-notes.swift"
        try "let stray = 1\n".write(toFile: stray, atomically: true, encoding: .utf8)
        let strayDir = root.developer + "/scratch-lab/extra-folder"
        try FileManager.default.createDirectory(atPath: strayDir, withIntermediateDirectories: true)
        try "x\n".write(toFile: strayDir + "/x.py", atomically: true, encoding: .utf8)
        let fixed = try kit(root, "build", "repos")
        #expect(fixed.status == 0 && fixed.output.contains("BUILT repos"), "the repair build must print BUILT repos: \(fixed.output.prefix(300))")
        #expect(shaOf(target) == before, "retry.swift was not rebuilt with the same bytes")
        #expect(!exists(stray) && !exists(strayDir + "/x.py"), "a stray file was not removed")
    }

    @Test func buildReposLeavesAnotherFolderOfHomeDeveloperAlone() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(atPath: root.developer + "/atlas-notes", withIntermediateDirectories: true)
        try "keep\n".write(toFile: root.developer + "/atlas-notes/keep.txt", atomically: true, encoding: .utf8)
        let ran = try kit(root, "build", "repos")
        #expect(ran.status == 0, "build repos: \(ran.output.prefix(300))")
        #expect(text(root.developer + "/atlas-notes/keep.txt") == "keep\n", "build repos touched another folder of home/Developer")
    }

    // MARK: part B, the answer rows

    @Test func answersKeepTheOldRowsHoldNoCodeGroupAndKeepTheTwoRepoDocuments() throws {
        let keyPath = projectRoot.appendingPathComponent("fixtures/answers.csv").path
        let lines = text(keyPath).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "id,group,query,file,locator,window_s,note", "the header changed")
        let head = lines.prefix(91).joined(separator: "\n") + "\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("answers-head-" + UUID().uuidString)
        try head.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(shaOf(tmp.path) == oldKeySha, "one of the first 91 lines of answers.csv (the header and the 90 earlier rows) changed")
        let rows = csvRows(keyPath)
        for r in rows { #expect(r.count == 7, "a row of the key has \(r.count) fields: \(r.first ?? "")") }
        #expect(!rows.contains { $0.count == 7 && ($0[1] == "code" || $0[1] == "codedecoy") }, "the key still holds a code or codedecoy row")
        #expect(!rows.contains { $0.count == 7 && $0[0].hasPrefix("code-") }, "the key still holds a row with an id code-NN")
        let repodoc = rows.filter { $0.count == 7 && $0[1] == "repodoc" }
        #expect(repodoc.map { $0[3] }.sorted() == handDecoys.sorted(), "the repodoc rows name \(repodoc.map { $0[3] })")
        #expect(repodoc.count == 2 && repodoc.allSatisfy { $0[0].hasPrefix("repodoc-") && $0[4].isEmpty && $0[2] == "retry a failed call with backoff" })
        #expect(rows.count == 92, "the key holds \(rows.count) rows, expected 92: the 102 rows of before job 2 less the 10 code rows")
    }

    @Test func everyRepodocRowNamesAFileOfApiClientDocsThatExists() throws {
        let (root, _) = reposBuilt()
        let keyPath = projectRoot.appendingPathComponent("fixtures/answers.csv").path
        let rows = csvRows(keyPath).filter { $0.count == 7 && $0[1] == "repodoc" }
        #expect(rows.count == 2)
        for r in rows {
            #expect(r[3].hasPrefix("api-client/docs/"), "\(r[0]): the file `\(r[3])` is not under api-client/docs/")
            #expect(exists(root.developer + "/" + r[3]), "\(r[0]): \(r[3]) does not exist under home/Developer")
        }
    }

    // MARK: part B, the matrix cells

    private struct Cell {
        let id: String, path: String, picks: String, inIndex: String, rows: String, reason: String, group: String
    }

    private func cells() -> [Cell] {
        csvRows(kitLib.appendingPathComponent("gate-matrix.csv").path).compactMap { f in
            f.count == 7 ? Cell(id: f[0], path: f[1], picks: f[2], inIndex: f[3], rows: f[4], reason: f[5], group: f[6]) : nil
        }
    }

    @Test func theMissingCodeCellsAreAddedWithHandValues() throws {
        let all = cells()
        for h in handNewCells {
            guard let c = all.first(where: { $0.id == h.id }) else {
                #expect(Bool(false), "the matrix has no cell \(h.id)")
                continue
            }
            #expect(c.path == h.path, "\(h.id): path `\(c.path)`, expected `\(h.path)`")
            #expect(c.picks == h.picks, "\(h.id): picks `\(c.picks)`, expected `\(h.picks)`")
            #expect(c.inIndex == h.inIndex && c.rows == h.rows && c.reason == h.reason && c.group == "spec",
                    "\(h.id): \(c.inIndex), \(c.rows), \(c.reason), \(c.group) differs from the hand values \(h.inIndex), \(h.rows), \(h.reason), spec")
        }
        for existing in ["plain-code-off", "plain-code-on", "vend-in-node_modules-py", "repo-off-py", "ignored-on-py",
                         "ov-a-inner-code", "ov-a-outer-code", "ov-b-inner-code", "ov-b-outer-code", "ov-c-inner-code", "ov-d-inner-code"] {
            let c = all.first { $0.id == existing }
            #expect(c != nil, "the cell \(existing) of plan 3 is gone")
            #expect(c?.inIndex == "no" && c?.rows == "0" && c?.reason == "unsupported", "\(existing): a code cell reads no, 0, unsupported, got \(c?.inIndex ?? ""), \(c?.rows ?? ""), \(c?.reason ?? "")")
        }
        for gone in ["repo-on-png", "repo-on-txt", "repo-on-py"] {
            #expect(!all.contains { $0.id == gone }, "the cell \(gone) is still in the table: without a tick it equals the repo-off cell")
        }
    }

    @Test func everyCodeExtensionHasAnExtCodeCell() throws {
        let all = cells()
        #expect(handExtCells.count == 15)
        for h in handExtCells {
            guard let c = all.first(where: { $0.id == "ext-\(h.ext)" }) else {
                #expect(Bool(false), "the matrix has no cell ext-\(h.ext)")
                continue
            }
            #expect(c.path == "extcode/\(h.ext)_\(h.token).\(h.ext)", "ext-\(h.ext): path `\(c.path)`")
            #expect(c.picks == "extcode", "ext-\(h.ext): picks `\(c.picks)`, the folder path alone")
            #expect(c.inIndex == "no" && c.rows == "0" && c.reason == "unsupported" && c.group == "spec", "ext-\(h.ext): no, 0, unsupported, spec")
        }
    }

    @Test func buildMatrixMakesTheNewCodeCells() throws {
        let root = try makeRoot()
        let ran = try kit(root, "build", "matrix")
        #expect(ran.status == 0, "build matrix exited \(ran.status): \(ran.output.suffix(300))")
        let m = root.fixtures + "/matrix"
        for h in handNewCells { #expect(exists(m + "/" + h.path), "the cell \(h.id) has no file \(h.path)") }
        for h in handExtCells { #expect(exists(m + "/extcode/\(h.ext)_\(h.token).\(h.ext)"), "ext-\(h.ext) has no file") }
        // the damaged .swift is bytes that are not UTF-8, the good one beside it is text
        let bad = (try? Data(contentsOf: URL(fileURLWithPath: m + "/damaged-code/broken_zq1541.swift"))) ?? Data()
        #expect(!bad.isEmpty && String(data: bad, encoding: .utf8) == nil, "the damaged .swift must hold bytes that are not valid UTF-8")
        let good = (try? Data(contentsOf: URL(fileURLWithPath: m + "/damaged-code/good_zq1542.swift"))) ?? Data()
        #expect(String(data: good, encoding: .utf8)?.contains("zq1542") == true, "the good .swift must be text holding its token")
        // the git-ignored folder is ignored as a folder: git's own listing leaves it out
        let others = try git(root, m + "/ignored-on", ["ls-files", "--others", "--exclude-standard"])
        #expect(!others.lines.contains { $0.hasPrefix("genfolder/") }, "git lists genfolder/ although it is a git-ignored folder: \(others.output)")
        #expect(ran.output.contains("BUILT matrix") || ran.output.contains("UNCHANGED matrix"))
        let check = try kit(root, "expect", "matrix")
        #expect(check.status == 0 && check.output.contains("MATRIX OK"), "expect matrix: \(check.output.suffix(300))")
    }

    @Test func readKindsListsFiveKindsAndNoCode() throws {
        let kinds = text(kitLib.appendingPathComponent("read-kinds.txt").path).split(separator: "\n").map(String.init)
        #expect(kinds == ["photo", "document", "pdf", "audio", "video"], "read-kinds.txt holds \(kinds)")
    }

    @Test func expectExtensionsFindsAFileForEachOfTheFifteenCodeExtensionsInTheNeverReadSectionOnceReposAndTheMatrixAreBuilt() throws {
        let root = try makeRoot()
        let before = try kit(root, "expect", "extensions", "--kinds", "code")
        #expect(before.status == 4, "with nothing built, expect extensions must exit 4, got \(before.status)")
        _ = try kit(root, "build", "repos")
        _ = try kit(root, "build", "matrix")
        let after = try kit(root, "expect", "extensions", "--kinds", "code")
        #expect(after.status == 0, "expect extensions exited \(after.status): \(after.output.suffix(400))")
        #expect(after.output.contains("EXTENSIONS OK code: 15 extensions"), "got: \(after.output.suffix(300))")
        #expect(after.lines.contains("NEVER READ"), "no NEVER READ section: \(after.output.suffix(400))")
        for h in handExtCells { #expect(after.output.contains("NEVER-READ \(h.ext) "), "no NEVER-READ line for \(h.ext)") }
        #expect(!after.lines.contains { $0.hasPrefix("FOUND ") }, "a code extension is in the read list: \(after.lines.filter { $0.hasPrefix("FOUND ") })")
    }

    private static let readExtensions: [String: String] = {
        var table: [String: String] = [:]
        let lists: [(String, [String])] = [
            ("photo", ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]),
            ("document", ["txt", "md", "rtf", "docx", "html", "odt"]),
            ("audio", ["mp3", "m4a", "wav", "aac", "flac"]),
            ("video", ["mp4", "mov", "m4v"]),
            ("pdf", ["pdf"]),
        ]
        for (kind, exts) in lists { for e in exts { table[e] = kind } }
        return table
    }()

    private func recount(_ dir: String) -> [String] {
        recount(filesUnder(dir))
    }

    private func recount(_ files: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for rel in files {
            let base = (rel as NSString).lastPathComponent
            guard base != ".DS_Store" else { continue }
            let ext = (base as NSString).pathExtension.lowercased()
            if let kind = Self.readExtensions[ext] { counts[kind, default: 0] += 1 }
        }
        return ["photo", "document", "audio", "video", "pdf"].compactMap { k in counts[k].map { "\(k) \($0)" } }
    }

    @Test func expectedCountsHoldNoCodeRowAndTheReposCountOnlyDocumentsAndPictures() throws {
        let rows = tsvRows("expected-counts.tsv")
        #expect(!rows.isEmpty)
        #expect(!rows.contains { $0.count >= 3 && $0[1] == "code" }, "expected-counts.tsv still holds a code row: \(rows.filter { $0.count >= 3 && $0[1] == "code" })")
        let (root, _) = reposBuilt()
        let wanted: [(folder: String, counts: [String])] = [
            ("api-client", ["photo 1", "document 3"]), ("legacy-sync", ["photo 1"]), ("scratch-lab", []),
        ]
        for w in wanted {
            let dir = root.developer + "/" + w.folder
            #expect(recount(dir) == w.counts, "\(w.folder): the independent recount of the built folder is \(recount(dir)), hand value \(w.counts)")
            let notIgnored = try git(root, dir, ["ls-files", "--others", "--exclude-standard"])
            let ignored = try git(root, dir, ["ls-files", "--others", "--ignored", "--exclude-standard"])
            #expect(notIgnored.status == 0 && ignored.status == 0, "\(w.folder): git ls-files failed: \(notIgnored.output) \(ignored.output)")
            #expect(recount(notIgnored.lines + ignored.lines) == w.counts, "\(w.folder): the recount over git ls-files is \(recount(notIgnored.lines + ignored.lines)), hand value \(w.counts)")
            let ran = try kit(root, "expect", "counts", dir)
            #expect(ran.status == 0, "\(w.folder): expect counts exited \(ran.status): \(ran.output.suffix(300))")
            let kinds = ran.lines.filter { $0.range(of: #"^(photo|document|audio|video|pdf|code) \d+$"#, options: .regularExpression) != nil }
            #expect(kinds == w.counts, "\(w.folder): expect counts printed \(kinds), hand value \(w.counts)")
            #expect(!ran.lines.contains { $0.hasPrefix("code ") }, "\(w.folder): a code count is printed: \(ran.lines)")
            if !w.counts.isEmpty { #expect(ran.output.contains("COUNTS OK \(w.folder)"), "\(w.folder): \(ran.output.suffix(300))") }
        }
        let api = try kit(root, "expect", "counts", root.developer + "/api-client")
        #expect(api.lines.contains { $0.hasPrefix("IGNORED ") }, "the code files and the key files are not named as ignored: \(api.lines)")
    }

    @Test func theTreeRowsOfExpectedCountsCountOnlyWhatIsRead() throws {
        let root = try makeRoot()
        let built = try kit(root, "build", "tree")
        try #require(built.status == 0, "build tree exited \(built.status): \(built.output.suffix(300))")
        let rows = tsvRows("expected-counts.tsv")
        let tree = root.fixtures + "/tree"
        let tops = ["plain", "excluded", "unsupported", "damaged", "repo", "never-picked"]
        for top in tops {
            let want = rows.filter { $0.count >= 3 && $0[0] == top }.map { "\($0[1]) \($0[2])" }
            let have = recount(tree + "/" + top)
            #expect(Set(want) == Set(have), "\(top): expected-counts.tsv says \(want.sorted()), the recount of the built folder is \(have.sorted())")
        }
        let total = rows.filter { $0.count >= 3 && $0[0] == "tree" }.map { "\($0[1]) \($0[2])" }
        #expect(Set(total) == Set(recount(tree)), "tree: expected-counts.tsv says \(total.sorted()), the recount is \(recount(tree).sorted())")
        #expect(!total.contains { $0.hasPrefix("code ") }, "the tree total holds a code row")
        let ran = try kit(root, "expect", "counts", "tree")
        #expect(ran.status == 0 && ran.output.contains("COUNTS OK tree") && ran.lines.contains { $0.hasPrefix("IGNORED ") }, "expect counts tree: \(ran.output.suffix(300))")
    }

    @Test func repoCellsListEveryCodeFileAndEveryExcludedFileAsNotInTheIndexAndTheDocumentsAndPicturesAsIn() throws {
        let (root, _) = reposBuilt()
        let cells = tsvRows("repo-cells.tsv")
        #expect(cells.count == 2 && cells.allSatisfy { $0.count == 4 }, "repo-cells.tsv holds \(cells.map(\.count)) columns, expected two cells of four")
        let codeExts: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]
        for c in cells where c.count == 4 {
            let dir = root.developer + "/" + c[1]
            let inIndex = c[2].split(separator: ",").map(String.init)
            let notIndexed = Set(c[3].split(separator: ",").map(String.init))
            for f in inIndex {
                #expect(exists(dir + "/" + f), "\(c[0]): \(f) is in the index list and is not in the built repo")
                #expect(Self.readExtensions[(f as NSString).pathExtension.lowercased()] != nil, "\(c[0]): \(f) is in the index list and is not a read extension")
                #expect(!notIndexed.contains(f), "\(c[0]): \(f) is in both lists")
            }
            let code = filesUnder(dir).filter { codeExts.contains(($0 as NSString).pathExtension.lowercased()) }
            for f in code { #expect(notIndexed.contains(f), "\(c[0]): the code file \(f) is not in the not-in-the-index list") }
            if c[1] == "api-client" {
                #expect(inIndex == ["docs/retry-notes.md", "docs/retry-diagram.png"], "api-client in the index: \(inIndex)")
                for e in handExcluded { #expect(notIndexed.contains(e.path), "api-client: the excluded file \(e.path) is not in the not-in-the-index list") }
            } else {
                #expect(inIndex == ["docs/diagram.png"], "legacy-sync in the index: \(inIndex)")
            }
        }
    }
}
