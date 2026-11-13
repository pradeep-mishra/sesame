import Foundation
import Testing

// plan-2-t8, tester step: kit part 4, the fixture builders for the home folders, the mini mix and the mutations
// (scripts/kit-fixtures.sh). Written from verify.md (Kit scripts, Starting state), the S6 and S7 feature maps and the
// spec's file-type lists only; no product source is read.
//
// Every run is a child process of kit-fixtures.sh with its own temp KIT_ROOT (a folder named sesame-kit*), its own
// TMPDIR and a decoy HOME, so nothing is ever written to the real kit root or the real home, and no app is started.
// The expected values are written here by hand (a count table per folder and kind, the spec's extension lists); no
// expected value is read from the script, and no assertion is made on data the test itself built.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `build homefolders` fills $KIT_ROOT/home/{Desktop,Documents,Downloads,Pictures,Movies}, with
//     Documents/Work inside Documents, and one git repo under $KIT_ROOT/home/Developer/ whose .gitignore excludes
//     supported files. `build minimix` makes $KIT_ROOT/fixtures/minimix, `build extra` makes $KIT_ROOT/fixtures/extra.
//   - `expect counts <folder>` prints `<kind> <n>` lines (kinds photo, document, pdf, audio, video) and exits 0 when the
//     folder equals the kit's hand-written row; `expect listing <folder>` prints the sorted supported relative paths.
//   - `mutate create <path>` and a rewriting `mutate edit <path>` print `PHRASE <unique phrase>` for the text file they
//     write; `mutate edit <path> --same-size` keeps the size and gives a new modified time. The op lines are
//     `CREATED <path>`, `EDITED <path> (size <a> to <b> bytes...)`, `RENAMED <path> to <name>`,
//     `MOVED <path> to <folder>`, `DELETED <path>`.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: the hand-written tables (spec: the six extension lists; verify.md: five folders, different counts)

private let kindExtensions: [String: [String]] = [
    "photo": ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"],
    "document": ["txt", "md", "rtf", "docx", "html", "odt"],
    "audio": ["mp3", "m4a", "wav", "aac", "flac"],
    "video": ["mp4", "mov", "m4v"],
    "pdf": ["pdf"],
    "code": ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"],
]

/// Files per kind in each suggested folder, counted over everything under it (Documents holds Work).
private let homeTable: [(folder: String, counts: [String: Int])] = [
    ("Desktop", ["photo": 3, "document": 2, "pdf": 1]),
    ("Documents", ["photo": 6, "document": 12, "pdf": 8, "audio": 2]),
    ("Downloads", ["photo": 4, "document": 1, "pdf": 3, "audio": 2, "video": 1]),
    ("Pictures", ["photo": 9]),
    ("Movies", ["audio": 1, "video": 4]),
]
/// Documents/Work, the overlap: it lies inside Documents.
private let workCounts: [String: Int] = ["photo": 1, "document": 3, "pdf": 2]
private let extraCounts: [String: Int] = ["photo": 4, "document": 2, "pdf": 1]

// MARK: running the script

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 600) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitfx2-out-" + UUID().uuidString)
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
    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    return Ran(status: status, output: text)
}

private let fixturesScript = projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path

/// What is removed when the test process ends (the shared roots and the compiled tool seed).
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
    var home: String { kit + "/home" }
    var fixtures: String { kit + "/fixtures" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome,
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
}

/// A fresh base folder holding the KIT_ROOT (named sesame-kit*), a private TMPDIR and a decoy HOME. With `tools`, the
/// compiled fixture tool of the seed is copied in so no test compiles it again.
private func makeRoot(tools: Bool = true) throws -> Root {
    _ = cleanupRegistered
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-s2-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let base = made.resolvingSymlinksInPath().path
    let root = Root(base: base, kit: base + "/sesame-kit-s2", tmp: base + "/tmp", decoyHome: base + "/decoy-home")
    try fm.createDirectory(atPath: root.kit + "/run", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root.tmp, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root.decoyHome, withIntermediateDirectories: true)
    if tools, let seed = toolSeed, fm.fileExists(atPath: seed.kit + "/run/bin") {
        try fm.copyItem(atPath: seed.kit + "/run/bin", toPath: root.kit + "/run/bin")
    }
    return root
}

/// One KIT_ROOT where the fixture tool is compiled once (by a small filler build), for every test to copy.
private let toolSeed: Root? = {
    guard let root = try? makeRoot(tools: false) else { return nil }
    cleanup.add(root.base)
    _ = try? run("/bin/bash", [fixturesScript, "build", "filler", "3"], env: root.env)
    return root
}()

private func kit(_ root: Root, _ args: String...) throws -> Ran {
    try kitArgs(root, args)
}

private func kitArgs(_ root: Root, _ args: [String]) throws -> Ran {
    guard FileManager.default.fileExists(atPath: fixturesScript) else {
        Issue.record("scripts/kit-fixtures.sh not found")
        return Ran(status: 127, output: "scripts/kit-fixtures.sh not found")
    }
    return try run("/bin/bash", [fixturesScript] + args, env: root.env)
}

private func withRoot<T>(_ body: (Root) throws -> T) throws -> T {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(atPath: root.base) }
    return try body(root)
}

/// A root with `build homefolders` run in it (the run is returned so a red test can say why).
private func withHome<T>(_ body: (Root, Ran) throws -> T) throws -> T {
    try withRoot { root in
        let built = try kit(root, "build", "homefolders")
        return try body(root, built)
    }
}

/// The shared, read-only build: home folders, mini mix and extra, made once for the tests that only read them.
private struct Shared: Sendable {
    let root: Root
    let home: Ran
    let minimix: Ran
    let extra: Ran
}

private let shared: Shared? = {
    guard let root = try? makeRoot() else { return nil }
    cleanup.add(root.base)
    guard let home = try? kit(root, "build", "homefolders"),
          let minimix = try? kit(root, "build", "minimix"),
          let extra = try? kit(root, "build", "extra") else { return nil }
    return Shared(root: root, home: home, minimix: minimix, extra: extra)
}()

// MARK: reading a tree

/// Every regular file under the folder (relative paths, no .DS_Store), sorted by bytes.
private func filesIn(_ dir: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: dir) else { return [] }
    var found: [String] = []
    for case let rel as String in walker {
        if rel.hasSuffix(".DS_Store") { continue }
        let attrs = walker.fileAttributes
        if attrs?[.type] as? FileAttributeType == .typeRegular { found.append(rel) }
    }
    return found.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

private func kindOf(_ path: String) -> String? {
    let ext = (path as NSString).pathExtension.lowercased()
    for (kind, list) in kindExtensions where list.contains(ext) { return kind }
    return nil
}

/// Files per kind by the spec's extension lists (a file of any other extension is not counted).
private func kindCounts(_ dir: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for rel in filesIn(dir) { if let k = kindOf(rel) { counts[k, default: 0] += 1 } }
    return counts
}

private func supportedFiles(_ dir: String) -> [String] { filesIn(dir).filter { kindOf($0) != nil } }

private func contents(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

private func text(_ path: String) -> String? { contents(path).flatMap { String(data: $0, encoding: .utf8) } }

private func tree(_ dir: String) -> [String: Data] {
    var t: [String: Data] = [:]
    for rel in filesIn(dir) { t[rel] = contents(dir + "/" + rel) }
    return t
}

private struct Stat: Equatable {
    let inode: UInt64
    let mtimeNs: Int64
    let size: Int64
}

private func stat(_ path: String) -> Stat? {
    var st = Darwin.stat()
    guard lstat(path, &st) == 0 else { return nil }
    return Stat(inode: UInt64(st.st_ino),
                mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
                size: Int64(st.st_size))
}

/// inode, modified time and size of every file under each folder: what a rewrite would change.
private func snapshot(_ dirs: [String]) -> [String: Stat] {
    var snap: [String: Stat] = [:]
    for dir in dirs {
        for rel in filesIn(dir) { snap[dir + "/" + rel] = stat(dir + "/" + rel) }
    }
    return snap
}

private func isPictureMagic(_ data: Data) -> Bool {
    let b = [UInt8](data.prefix(12))
    if b.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
    if b.starts(with: Array("GIF8".utf8)) { return true }
    if b.starts(with: Array("RIFF".utf8)) { return true }
    if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
    return false
}

private func has(_ data: Data, _ needle: String) -> Bool { data.range(of: Data(needle.utf8)) != nil }

/// Every `PHRASE <phrase>` line of the output.
private func phrases(_ output: String) -> [String] {
    output.split(separator: "\n").compactMap { line in
        line.hasPrefix("PHRASE ") ? String(line.dropFirst("PHRASE ".count)).trimmingCharacters(in: .whitespaces) : nil
    }
}

private func looksLikePhrase(_ p: String) -> Bool {
    p.range(of: "^[A-Za-z0-9]+( [A-Za-z0-9]+)+$", options: .regularExpression) != nil
}

/// Parsed `<kind> <n>` lines of `expect counts`.
private func parsedCounts(_ output: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: " ")
        if parts.count == 2, kindExtensions.keys.contains(String(parts[0])), let n = Int(parts[1]) {
            counts[String(parts[0])] = n
        }
    }
    return counts
}

/// The path lines of `expect listing` (every line that is not a `KEYWORD ...` summary line).
private func listedPaths(_ output: String) -> [String] {
    output.split(separator: "\n").map(String.init).filter {
        $0.range(of: "^[A-Z][A-Z-]+( |:|$)", options: .regularExpression) == nil
    }
}

private func sortedBytes(_ a: [String]) -> [String] { a.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }

private func why(_ ran: Ran, _ what: String) -> Comment {
    "`\(what)` exited \(ran.status): \(ran.output.suffix(400))"
}

private func modified(_ path: String) -> Int64? { stat(path)?.mtimeNs }

// MARK: the suite

@Suite("KitFixturesSlice2Tests")
struct KitFixturesSlice2Tests {

    // MARK: build homefolders

    @Test("build homefolders makes the five suggested folders; expect counts equals the hand-written table per folder and kind")
    func homeFolderCounts() throws {
        let s = try #require(shared, "the shared build could not start")
        try #require(s.home.status == 0, why(s.home, "kit-fixtures.sh build homefolders"))
        for (folder, want) in homeTable {
            let dir = s.root.home + "/" + folder
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue,
                    "\(folder) is not a folder under the throwaway home")
            #expect(kindCounts(dir) == want, "\(folder): the files on disk hold \(kindCounts(dir)), the table says \(want)")
            let ran = try kit(s.root, "expect", "counts", dir)
            #expect(ran.status == 0, why(ran, "expect counts \(folder)"))
            #expect(parsedCounts(ran.output) == want, "expect counts \(folder) printed \(parsedCounts(ran.output)), the table says \(want)")
        }
    }

    @Test("homefolders holds Documents/Work, and the unique total over Documents plus Documents/Work is not the sum")
    func overlapDocumentsWork() throws {
        let s = try #require(shared, "the shared build could not start")
        try #require(s.home.status == 0, why(s.home, "kit-fixtures.sh build homefolders"))
        let documents = s.root.home + "/Documents"
        let work = documents + "/Work"
        var isDir: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: work, isDirectory: &isDir) && isDir.boolValue,
                     "Documents/Work is not a folder inside Documents")
        #expect(kindCounts(work) == workCounts, "Work holds \(kindCounts(work)), the table says \(workCounts)")
        let workRan = try kit(s.root, "expect", "counts", work)
        #expect(workRan.status == 0, why(workRan, "expect counts Documents/Work"))
        #expect(parsedCounts(workRan.output) == workCounts, "expect counts Work printed \(parsedCounts(workRan.output))")

        let docsRan = try kit(s.root, "expect", "counts", documents)
        let docs = parsedCounts(docsRan.output)
        let docsWant = try #require(homeTable.first { $0.folder == "Documents" }).counts
        #expect(docs == docsWant, "expect counts Documents printed \(docs), the table says \(docsWant)")
        var sum: [String: Int] = docs
        for (k, n) in parsedCounts(workRan.output) { sum[k, default: 0] += n }
        #expect(sum != docs, "the sum of Documents and Work equals the Documents counts: Work has no files of its own")

        // The unique file set over both folders, from the kit's own listings.
        let docsList = listedPaths(try kit(s.root, "expect", "listing", documents).output).map { documents + "/" + $0 }
        let workList = listedPaths(try kit(s.root, "expect", "listing", work).output).map { work + "/" + $0 }
        let unique = Set(docsList).union(workList)
        #expect(unique.count == docsWant.values.reduce(0, +),
                "the unique total over Documents and Work is \(unique.count), the table's Documents total is \(docsWant.values.reduce(0, +))")
        #expect(unique.count != docsList.count + workList.count, "the unique total equals the sum of the two listings")
        for p in workList { #expect(docsList.contains(p), "\(p) is in Work but not in the Documents listing") }
    }

    @Test("homefolders makes a git repo whose .gitignore excludes supported files, and leaves the rest of the home alone")
    func repoWithGitignore() throws {
        try withRoot { root in
            let marker = root.home + "/Library/Application Support/Sesame/marker.txt"
            try FileManager.default.createDirectory(atPath: (marker as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try "keep me".write(toFile: marker, atomically: true, encoding: .utf8)
            let built = try kit(root, "build", "homefolders")
            try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
            #expect(text(marker) == "keep me", "build homefolders removed or changed a file of the home it does not own")

            let developer = root.home + "/Developer"
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: developer)) ?? []
            let repos = entries.sorted().map { developer + "/" + $0 }.filter {
                FileManager.default.fileExists(atPath: $0 + "/.git")
            }
            try #require(!repos.isEmpty, "no git repo under \(developer)")
            let repo = repos[0]
            let ignoreText = try #require(text(repo + "/.gitignore"), "the repo has no .gitignore")
            #expect(!ignoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ".gitignore is empty")

            let git = "/usr/bin/git"
            let ignored = try run(git, ["-C", repo, "ls-files", "--others", "--ignored", "--exclude-standard"], env: root.env)
            let kept = try run(git, ["-C", repo, "ls-files", "--others", "--exclude-standard"], env: root.env)
            try #require(ignored.status == 0, why(ignored, "git ls-files --ignored"))
            try #require(kept.status == 0, why(kept, "git ls-files"))
            let ignoredSupported = ignored.lines.filter { kindOf($0) != nil && !$0.hasPrefix(".git/") }
            let keptSupported = kept.lines.filter { kindOf($0) != nil }
            #expect(!ignoredSupported.isEmpty, ".gitignore excludes no supported file (git says ignored: \(ignored.lines))")
            #expect(!keptSupported.isEmpty, "every supported file of the repo is ignored (the repo reads nothing, so it proves nothing)")
        }
    }

    // MARK: build minimix, build extra

    @Test("build minimix makes exactly 400 generated photos and expect listing lists 400 paths")
    func miniMix() throws {
        let s = try #require(shared, "the shared build could not start")
        try #require(s.minimix.status == 0, why(s.minimix, "kit-fixtures.sh build minimix"))
        let dir = s.root.fixtures + "/minimix"
        let onDisk = filesIn(dir)
        #expect(onDisk.count == 400, "fixtures/minimix holds \(onDisk.count) files, expected exactly 400")
        #expect(onDisk.filter { kindOf($0) == "photo" }.count == 400, "not every file of the mini mix is a photo by extension")
        for rel in onDisk {
            let data = contents(dir + "/" + rel) ?? Data()
            if data.isEmpty || !isPictureMagic(data) {
                Issue.record("\(rel) is not a generated picture (empty or no picture header)")
                break
            }
        }
        let ran = try kit(s.root, "expect", "listing", "minimix")
        #expect(ran.status == 0, why(ran, "expect listing minimix"))
        let listed = listedPaths(ran.output)
        #expect(listed.count == 400, "expect listing minimix printed \(listed.count) paths, expected 400")
        #expect(listed == sortedBytes(listed), "the listing is not sorted")
        #expect(listed == onDisk, "the listing differs from the files on disk")
        let counts = try kit(s.root, "expect", "counts", "minimix")
        #expect(counts.status == 0, why(counts, "expect counts minimix"))
        #expect(parsedCounts(counts.output) == ["photo": 400], "expect counts minimix printed \(parsedCounts(counts.output))")
    }

    @Test("build extra makes fixtures/extra with the hand-written counts")
    func extraFolder() throws {
        let s = try #require(shared, "the shared build could not start")
        try #require(s.extra.status == 0, why(s.extra, "kit-fixtures.sh build extra"))
        let dir = s.root.fixtures + "/extra"
        var isDir: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue, "fixtures/extra is not a folder")
        #expect(kindCounts(dir) == extraCounts, "fixtures/extra holds \(kindCounts(dir)), the table says \(extraCounts)")
        let ran = try kit(s.root, "expect", "counts", "extra")
        #expect(ran.status == 0, why(ran, "expect counts extra"))
        #expect(parsedCounts(ran.output) == extraCounts, "expect counts extra printed \(parsedCounts(ran.output))")
        // The home folders, golden and the extra folder never share a file name by accident: no file of extra is in a home folder.
        let extraNames = Set(filesIn(dir).map { ($0 as NSString).lastPathComponent })
        for (folder, _) in homeTable {
            let overlap = Set(filesIn(s.root.home + "/" + folder).map { ($0 as NSString).lastPathComponent }).intersection(extraNames)
            #expect(overlap.isEmpty, "fixtures/extra and \(folder) share file names \(overlap.sorted())")
        }
    }

    // MARK: nothing rewritten, nothing outside KIT_ROOT

    @Test("building a folder that is already right rewrites no file: inodes and modified times are kept")
    func buildAgainRewritesNothing() throws {
        try withRoot { root in
            for mode in ["homefolders", "minimix", "extra"] {
                let ran = try kit(root, "build", mode)
                try #require(ran.status == 0, why(ran, "kit-fixtures.sh build \(mode)"))
            }
            let dirs = [root.home, root.fixtures + "/minimix", root.fixtures + "/extra"]
            let before = snapshot(dirs)
            #expect(before.count > 400, "the first builds made only \(before.count) files")
            for mode in ["homefolders", "minimix", "extra"] {
                let ran = try kit(root, "build", mode)
                #expect(ran.status == 0, why(ran, "second kit-fixtures.sh build \(mode)"))
            }
            let after = snapshot(dirs)
            #expect(Set(after.keys) == Set(before.keys), "a second build added or removed files: \(Set(after.keys).symmetricDifference(Set(before.keys)).sorted().prefix(5))")
            let changed = before.keys.filter { after[$0] != nil && after[$0] != before[$0] }.sorted()
            #expect(changed.isEmpty, "a second build rewrote \(changed.count) files, for example \(changed.prefix(3))")
        }
    }

    @Test("two builds in two kit roots make identical files")
    func buildsAreIdentical() throws {
        try withRoot { a in
            try withRoot { b in
                for root in [a, b] {
                    let ran = try kit(root, "build", "homefolders")
                    try #require(ran.status == 0, why(ran, "kit-fixtures.sh build homefolders"))
                }
                let ta = tree(a.home), tb = tree(b.home)
                #expect(Set(ta.keys) == Set(tb.keys), "the two builds hold different files")
                #expect(ta == tb, "the two builds hold files with different bytes")
            }
        }
    }

    @Test("the builders touch only files under KIT_ROOT: the home, the temp folder and the base stay clean")
    func touchOnlyKitRoot() throws {
        try withRoot { root in
            for mode in ["homefolders", "minimix", "extra"] {
                let ran = try kit(root, "build", mode)
                try #require(ran.status == 0, why(ran, "kit-fixtures.sh build \(mode)"))
            }
            let desktop = root.home + "/Desktop"
            for args in [["mutate", "create", desktop + "/touch-check.txt"], ["mutate", "edit", desktop + "/touch-check.txt"]] {
                let ran = try kitArgs(root, args)
                #expect(ran.status == 0, why(ran, args.joined(separator: " ")))
            }
            #expect(filesIn(root.decoyHome).isEmpty, "the decoy HOME was written to: \(filesIn(root.decoyHome))")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.tmp)) ?? []
            #expect(leftovers.isEmpty, "the builders left entries in TMPDIR: \(leftovers)")
            let top = ((try? FileManager.default.contentsOfDirectory(atPath: root.base)) ?? []).sorted()
            #expect(top == ["decoy-home", "sesame-kit-s2", "tmp"], "something was made next to the kit root: \(top)")
            let inside = ((try? FileManager.default.contentsOfDirectory(atPath: root.kit)) ?? []).sorted()
            #expect(Set(inside).isSubset(of: ["fixtures", "home", "run"]), "KIT_ROOT holds unexpected entries: \(inside)")
        }
    }

    // MARK: mutate create

    @Test("mutate create writes a text file that carries a unique phrase the script prints")
    func createPrintsUniquePhrase() throws {
        try withHome { root, built in
            try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
            let desktop = root.home + "/Desktop"
            var seen: [String] = []
            for i in 1...5 {
                let path = "\(desktop)/new-\(i).txt"
                let ran = try kit(root, "mutate", "create", path)
                try #require(ran.status == 0, why(ran, "mutate create new-\(i).txt"))
                let printed = phrases(ran.output)
                try #require(printed.count == 1, "mutate create printed \(printed.count) PHRASE lines: \(ran.output)")
                #expect(looksLikePhrase(printed[0]), "the phrase `\(printed[0])` is not plain words and digits")
                let data = try #require(contents(path), "mutate create wrote no file at \(path)")
                #expect(has(data, printed[0]), "new-\(i).txt does not carry its printed phrase `\(printed[0])`")
                seen.append(printed[0])
            }
            #expect(Set(seen).count == 5, "two creates printed the same phrase: \(seen)")
            for phrase in seen {
                let holders = filesIn(root.home).filter { contents(root.home + "/" + $0).map { has($0, phrase) } ?? false }
                #expect(holders.count == 1, "the phrase `\(phrase)` is in \(holders.count) files: \(holders)")
            }
        }
    }

    @Test("mutate create refuses an existing file and any path outside KIT_ROOT, and changes nothing")
    func createRefuses() throws {
        try withHome { root, built in
            try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
            let existing = root.home + "/Desktop/new-1.txt"
            let first = try kit(root, "mutate", "create", existing)
            try #require(first.status == 0, why(first, "mutate create new-1.txt"))
            let content = contents(existing)
            let again = try kit(root, "mutate", "create", existing)
            #expect(again.status != 0, "mutate create on an existing file exited 0")
            #expect(contents(existing) == content, "mutate create changed an existing file")
            let outside = root.decoyHome + "/escape.txt"
            let out = try kit(root, "mutate", "create", outside)
            #expect(out.status != 0, "mutate create outside KIT_ROOT exited 0")
            #expect(!FileManager.default.fileExists(atPath: outside), "mutate create wrote outside KIT_ROOT")
            let dots = try kit(root, "mutate", "create", root.home + "/Desktop/../../escape.txt")
            #expect(dots.status != 0, "mutate create with .. exited 0")
            #expect(filesIn(root.decoyHome).isEmpty && !FileManager.default.fileExists(atPath: root.kit + "/escape.txt"),
                    "mutate create wrote a file through ..")
        }
    }

    // MARK: mutate edit

    @Test("mutate edit rewrites a text file: new unique phrase, old phrase gone, a different size, a newer modified time")
    func editRewritesText() throws {
        try withHome { root, built in
            try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
            let path = root.home + "/Desktop/edit-me.txt"
            let created = try kit(root, "mutate", "create", path)
            try #require(created.status == 0, why(created, "mutate create"))
            var oldPhrase = try #require(phrases(created.output).first, "mutate create printed no PHRASE")
            for round in 1...3 {
                let before = try #require(stat(path))
                let ran = try kit(root, "mutate", "edit", path)
                try #require(ran.status == 0, why(ran, "mutate edit round \(round)"))
                let newPhrase = try #require(phrases(ran.output).first, "mutate edit printed no PHRASE (round \(round)): \(ran.output)")
                #expect(looksLikePhrase(newPhrase), "the phrase `\(newPhrase)` is not plain words and digits")
                #expect(newPhrase != oldPhrase, "edit round \(round) printed the old phrase again")
                let data = try #require(contents(path))
                #expect(has(data, newPhrase), "round \(round): the file does not carry the new phrase `\(newPhrase)`")
                #expect(!has(data, oldPhrase), "round \(round): the old phrase `\(oldPhrase)` is still in the file")
                let after = try #require(stat(path))
                #expect(after.size != before.size, "round \(round): the size stayed \(before.size)")
                #expect(after.mtimeNs > before.mtimeNs, "round \(round): the modified time is not newer")
                oldPhrase = newPhrase
            }
        }
    }

    @Test("mutate edit on a built text file and on a photo: a different size, a newer modified time, a photo still a picture")
    func editBuiltFiles() throws {
        try withHome { root, built in
            try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
            let desktop = root.home + "/Desktop"
            let txt = try #require(supportedFiles(desktop).first { $0.hasSuffix(".txt") }, "Desktop holds no .txt file")
            let jpg = try #require(supportedFiles(root.home + "/Pictures").first { kindOf($0) == "photo" })
            for (path, isText) in [(desktop + "/" + txt, true), (root.home + "/Pictures/" + jpg, false)] {
                let before = try #require(stat(path))
                let bytes = contents(path)
                let ran = try kit(root, "mutate", "edit", path)
                #expect(ran.status == 0, why(ran, "mutate edit \(path)"))
                let after = try #require(stat(path))
                #expect(after.size != before.size, "\(path): the size stayed \(before.size)")
                #expect(after.mtimeNs > before.mtimeNs, "\(path): the modified time is not newer")
                #expect(contents(path) != bytes, "\(path): the bytes did not change")
                if isText, let printed = phrases(ran.output).first {
                    #expect(contents(path).map { has($0, printed) } ?? false, "the edited text file does not carry `\(printed)`")
                } else if !isText {
                    #expect(contents(path).map(isPictureMagic) ?? false, "the edited photo is no longer a picture")
                }
            }
        }
    }

    @Test("a same-size edit keeps the size and gives a newer modified time (text with a new phrase, a photo with new bytes)")
    func sameSizeEdit() throws {
        try withHome { root, built in
            try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
            let path = root.home + "/Desktop/same-size.txt"
            let created = try kit(root, "mutate", "create", path)
            try #require(created.status == 0, why(created, "mutate create"))
            let oldPhrase = try #require(phrases(created.output).first)
            let before = try #require(stat(path))
            let ran = try kit(root, "mutate", "edit", path, "--same-size")
            try #require(ran.status == 0, why(ran, "mutate edit --same-size"))
            let newPhrase = try #require(phrases(ran.output).first, "a same-size edit of a text file printed no PHRASE: \(ran.output)")
            #expect(newPhrase != oldPhrase, "the same-size edit printed the old phrase")
            let data = try #require(contents(path))
            #expect(has(data, newPhrase), "the file does not carry `\(newPhrase)`")
            #expect(!has(data, oldPhrase), "the old phrase `\(oldPhrase)` is still in the file")
            let after = try #require(stat(path))
            #expect(after.size == before.size, "the size changed from \(before.size) to \(after.size)")
            #expect(after.mtimeNs > before.mtimeNs, "the modified time is not newer")

            let photoName = try #require(supportedFiles(root.home + "/Pictures").first)
            let photo = root.home + "/Pictures/" + photoName
            let photoBefore = try #require(stat(photo))
            let photoBytes = contents(photo)
            let photoRan = try kit(root, "mutate", "edit", photo, "--same-size")
            try #require(photoRan.status == 0, why(photoRan, "mutate edit --same-size on a photo"))
            let photoAfter = try #require(stat(photo))
            #expect(photoAfter.size == photoBefore.size, "the photo's size changed")
            #expect(photoAfter.mtimeNs > photoBefore.mtimeNs, "the photo's modified time is not newer")
            #expect(contents(photo) != photoBytes, "the photo's bytes did not change")
        }
    }

    // MARK: rename, move, delete

    @Test("mutate rename, move and delete change the tree as named")
    func renameMoveDelete() throws {
        try withHome { root, built in
            try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
            let desktop = root.home + "/Desktop"
            let files = supportedFiles(desktop)
            try #require(files.count >= 3, "Desktop holds fewer than 3 supported files")
            let renamed = desktop + "/" + files[0], moved = desktop + "/" + files[1], deleted = desktop + "/" + files[2]
            let renamedBytes = contents(renamed), movedBytes = contents(moved)

            let r = try kit(root, "mutate", "rename", renamed, "renamed-by-kit.jpg")
            #expect(r.status == 0, why(r, "mutate rename"))
            #expect(!FileManager.default.fileExists(atPath: renamed), "the old name is still there after rename")
            #expect(contents(desktop + "/renamed-by-kit.jpg") == renamedBytes, "the new name does not hold the same bytes")

            let target = root.home + "/Pictures"
            let m = try kit(root, "mutate", "move", moved, target)
            #expect(m.status == 0, why(m, "mutate move"))
            #expect(!FileManager.default.fileExists(atPath: moved), "the old path is still there after move")
            #expect(contents(target + "/" + (moved as NSString).lastPathComponent) == movedBytes, "the moved file is not in the folder")

            let d = try kit(root, "mutate", "delete", deleted)
            #expect(d.status == 0, why(d, "mutate delete"))
            #expect(!FileManager.default.fileExists(atPath: deleted), "the file is still there after delete")
            #expect(filesIn(desktop).count == files.count - 2, "Desktop should hold \(files.count - 2) files (one renamed, one moved out, one deleted, none added)")
        }
    }

    // MARK: expect listing

    @Test("expect listing prints the sorted supported paths of a folder and leaves out the unsupported ones")
    func listingSortedSupported() throws {
        try withHome { root, built in
            try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
            let documents = root.home + "/Documents"
            for rel in ["readme.xyz", "Work/notes.xyz", "Work/zz-last.txt", "aa-first.txt"] {
                let ran = try kit(root, "mutate", "create", documents + "/" + rel)
                try #require(ran.status == 0, why(ran, "mutate create \(rel)"))
            }
            let ran = try kit(root, "expect", "listing", documents)
            #expect(ran.status == 0, why(ran, "expect listing Documents"))
            let listed = listedPaths(ran.output)
            let want = sortedBytes(supportedFiles(documents))
            #expect(want.contains("aa-first.txt") && want.contains("Work/zz-last.txt") && !want.contains("readme.xyz"),
                    "the folder the test built is not what the test expects")
            #expect(listed == want, "expect listing printed \(listed.count) paths, the supported files on disk are \(want.count); first difference: \(zip(listed, want).first { $0 != $1 } as Any)")
            #expect(!listed.contains { $0.hasSuffix(".xyz") }, "an unsupported .xyz file is listed")
        }
    }

    // MARK: mutate random

    /// Runs `mutate random 15 --seed <s> <folder>` and checks the printed ops against the folder before and after.
    private func randomRound(_ root: Root, seed: Int, folder: String, verbs: inout Set<String>, sameSize: inout Int, grew: inout Int) throws -> Ran {
        let before = tree(folder)
        let beforeStat = snapshot([folder])
        let ran = try kit(root, "mutate", "random", "15", "--seed", String(seed), folder)
        try #require(ran.status == 0, why(ran, "mutate random 15 --seed \(seed)"))
        let after = tree(folder)
        let afterStat = snapshot([folder])
        let lines = ran.lines
        let opLines = lines.filter { l in ["CREATED ", "EDITED ", "RENAMED ", "MOVED ", "DELETED "].contains { l.hasPrefix($0) } }
        #expect(opLines.count == 15, "round \(seed): \(opLines.count) operations printed, expected 15: \(ran.output)")
        let stray = lines.filter { l in
            !(l.hasPrefix("RANDOM ") || l.hasPrefix("PHRASE ") || opLines.contains(l))
        }
        #expect(stray.isEmpty, "round \(seed): unexpected output lines \(stray)")

        var gone = Set<String>(), added = Set<String>(), rewritten = Set<String>()
        var seenPaths = Set<String>()
        for (i, line) in lines.enumerated() {
            let nextPhrase = (i + 1 < lines.count && lines[i + 1].hasPrefix("PHRASE ")) ? phrases(lines[i + 1]).first : nil
            if line.hasPrefix("CREATED ") {
                let p = String(line.dropFirst("CREATED ".count))
                verbs.insert("create")
                added.insert(p)
                #expect(before[String(p.dropFirst(folder.count + 1))] == nil, "round \(seed): created \(p) already existed")
                let data = contents(p)
                #expect(data != nil, "round \(seed): created file \(p) is missing")
                let phrase = nextPhrase
                #expect(phrase != nil, "round \(seed): CREATED \(p) is not followed by a PHRASE line")
                if let data, let phrase { #expect(has(data, phrase), "round \(seed): \(p) does not carry `\(phrase)`") }
                #expect(seenPaths.insert(p).inserted, "round \(seed): \(p) appears twice")
            } else if line.hasPrefix("EDITED ") {
                let rest = String(line.dropFirst("EDITED ".count))
                guard let range = rest.range(of: " (size ") else {
                    Issue.record("round \(seed): `\(line)` has no `(size a to b bytes` part"); continue
                }
                let p = String(rest[..<range.lowerBound])
                let figures = rest[range.upperBound...].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                verbs.insert("edit")
                rewritten.insert(p)
                #expect(seenPaths.insert(p).inserted, "round \(seed): \(p) appears twice")
                guard figures.count >= 2, let b = beforeStat[p], let a = afterStat[p] else {
                    Issue.record("round \(seed): cannot compare `\(line)` with the folder"); continue
                }
                #expect(Int64(figures[0]) == b.size && Int64(figures[1]) == a.size,
                        "round \(seed): `\(line)` says sizes \(figures[0]) and \(figures[1]), the folder says \(b.size) and \(a.size)")
                #expect(a.mtimeNs > b.mtimeNs, "round \(seed): \(p) has no newer modified time after the edit")
                if b.size == a.size { sameSize += 1 } else { grew += 1 }
                if let phrase = nextPhrase, let data = contents(p) {
                    #expect(has(data, phrase), "round \(seed): \(p) does not carry `\(phrase)`")
                }
            } else if line.hasPrefix("RENAMED ") {
                let rest = String(line.dropFirst("RENAMED ".count))
                guard let range = rest.range(of: " to ", options: .backwards) else { Issue.record("`\(line)` has no ` to `"); continue }
                let p = String(rest[..<range.lowerBound]), name = String(rest[range.upperBound...])
                let dest = (p as NSString).deletingLastPathComponent + "/" + name
                verbs.insert("rename")
                gone.insert(p); added.insert(dest)
                #expect(seenPaths.insert(p).inserted, "round \(seed): \(p) appears twice")
                #expect(!FileManager.default.fileExists(atPath: p), "round \(seed): \(p) is still there after RENAMED")
                #expect(contents(dest) == before[String(p.dropFirst(folder.count + 1))], "round \(seed): \(dest) is not the renamed file")
            } else if line.hasPrefix("MOVED ") {
                let rest = String(line.dropFirst("MOVED ".count))
                guard let range = rest.range(of: " to ", options: .backwards) else { Issue.record("`\(line)` has no ` to `"); continue }
                let p = String(rest[..<range.lowerBound]), to = String(rest[range.upperBound...])
                let dest = to + "/" + (p as NSString).lastPathComponent
                verbs.insert("move")
                gone.insert(p); added.insert(dest)
                #expect(seenPaths.insert(p).inserted, "round \(seed): \(p) appears twice")
                #expect(!FileManager.default.fileExists(atPath: p), "round \(seed): \(p) is still there after MOVED")
                #expect(contents(dest) == before[String(p.dropFirst(folder.count + 1))], "round \(seed): \(dest) is not the moved file")
                #expect(dest.hasPrefix(folder + "/"), "round \(seed): \(p) was moved out of the folder to \(to)")
            } else if line.hasPrefix("DELETED ") {
                let p = String(line.dropFirst("DELETED ".count))
                verbs.insert("delete")
                gone.insert(p)
                #expect(seenPaths.insert(p).inserted, "round \(seed): \(p) appears twice")
                #expect(!FileManager.default.fileExists(atPath: p), "round \(seed): \(p) is still there after DELETED")
            }
        }
        // Nothing else moved: every other file keeps its bytes and its modified time.
        for (rel, data) in before {
            let p = folder + "/" + rel
            if gone.contains(p) || rewritten.contains(p) { continue }
            #expect(after[rel] == data && afterStat[p]?.mtimeNs == beforeStat[p]?.mtimeNs,
                    "round \(seed): \(p) changed but no operation names it")
        }
        let expectedAfter = Set(before.keys.map { folder + "/" + $0 }).subtracting(gone).union(added)
        #expect(Set(after.keys.map { folder + "/" + $0 }) == expectedAfter,
                "round \(seed): the files after the round are not the files before, minus gone, plus added")
        return ran
    }

    private func randomRun(_ root: Root, seeds: [Int], verbs: inout Set<String>, sameSize: inout Int, grew: inout Int) throws -> ([Ran], [String: Data]) {
        let built = try kit(root, "build", "homefolders")
        try #require(built.status == 0, why(built, "kit-fixtures.sh build homefolders"))
        let folder = root.home + "/Documents"
        var outputs: [Ran] = []
        for seed in seeds {
            outputs.append(try randomRound(root, seed: seed, folder: folder, verbs: &verbs, sameSize: &sameSize, grew: &grew))
        }
        return (outputs, tree(folder))
    }

    @Test("mutate random changes the tree as named, and the same seed makes the identical sequence and final tree")
    func randomIsNamedAndRepeatable() throws {
        var verbs = Set<String>()
        var sameSize = 0, grew = 0
        try withRoot { a in
            try withRoot { b in
                try withRoot { c in
                    let (outA, treeA) = try randomRun(a, seeds: [11, 12, 13], verbs: &verbs, sameSize: &sameSize, grew: &grew)
                    var v2 = Set<String>(); var s2 = 0, g2 = 0
                    let (outB, treeB) = try randomRun(b, seeds: [11, 12, 13], verbs: &v2, sameSize: &s2, grew: &g2)
                    var v3 = Set<String>(); var s3 = 0, g3 = 0
                    let (outC, _) = try randomRun(c, seeds: [21, 22, 23], verbs: &v3, sameSize: &s3, grew: &g3)

                    func normal(_ ran: Ran, _ root: Root) -> String { ran.output.replacingOccurrences(of: root.kit, with: "<KIT>") }
                    for (x, y) in zip(outA, outB) {
                        #expect(normal(x, a) == normal(y, b), "the same seed printed two different sequences:\n\(normal(x, a))\n----\n\(normal(y, b))")
                    }
                    #expect(treeA == treeB, "the same seeds left two different final trees")
                    #expect(outA.map { normal($0, a) } != outC.map { normal($0, c) }, "different seeds printed the same sequences")
                }
            }
        }
        #expect(verbs == ["create", "edit", "rename", "move", "delete"],
                "three rounds of 15 operations did not show every operation, only \(verbs.sorted())")
        #expect(sameSize > 0, "no same-size edit in 45 operations")
        #expect(grew > 0, "no size-changing edit in 45 operations")
    }

    // MARK: plan 1's expect counts and expect listing cases stay

    @Test("plan 1: build empty, then expect listing empty prints LISTING OK and nothing else")
    func planOneEmpty() throws {
        try withRoot { root in
            let built = try kit(root, "build", "empty")
            try #require(built.status == 0, why(built, "build empty"))
            let ran = try kit(root, "expect", "listing", "empty")
            #expect(ran.status == 0, why(ran, "expect listing empty"))
            #expect(ran.output.contains("LISTING OK empty: 0 paths"), "no `LISTING OK empty: 0 paths` line: \(ran.output)")
            try "x".write(toFile: root.fixtures + "/empty/stray.txt", atomically: true, encoding: .utf8)
            let bad = try kit(root, "expect", "listing", "empty")
            #expect(bad.status != 0, "expect listing empty passes with a stray file in it")
        }
    }

    @Test("plan 1: build golden, then expect counts and expect listing pass, and a missing photo fails them")
    func planOneGolden() throws {
        try withRoot { root in
            let built = try kit(root, "build", "golden")
            try #require(built.status == 0, why(built, "build golden"))
            let counts = try kit(root, "expect", "counts", "golden")
            #expect(counts.status == 0, why(counts, "expect counts golden"))
            #expect(parsedCounts(counts.output) == ["photo": 40], "expect counts golden printed \(parsedCounts(counts.output))")
            #expect(counts.output.contains("COUNTS OK golden"), "no `COUNTS OK golden` line")
            let listing = try kit(root, "expect", "listing", "golden")
            #expect(listing.status == 0, why(listing, "expect listing golden"))
            #expect(listing.output.contains("LISTING OK golden: 40 paths"), "no `LISTING OK golden: 40 paths` line")
            let victim = try #require(filesIn(root.fixtures + "/golden").first)
            try FileManager.default.removeItem(atPath: root.fixtures + "/golden/" + victim)
            #expect(try kit(root, "expect", "counts", "golden").status != 0, "expect counts golden passes with a photo missing")
            #expect(try kit(root, "expect", "listing", "golden").status != 0, "expect listing golden passes with a photo missing")
        }
    }

    @Test("plan 1: build tree, then expect counts tree and expect listing tree pass, and a missing file fails them")
    func planOneTree() throws {
        try withRoot { root in
            let built = try kit(root, "build", "tree")
            try #require(built.status == 0, why(built, "build tree"))
            let counts = try kit(root, "expect", "counts", "tree")
            #expect(counts.status == 0, why(counts, "expect counts tree"))
            #expect(counts.output.contains("COUNTS OK tree"), "no `COUNTS OK tree` line")
            let listing = try kit(root, "expect", "listing", "tree")
            #expect(listing.status == 0, why(listing, "expect listing tree"))
            #expect(listing.output.contains("LISTING OK tree"), "no `LISTING OK tree` line")
            let victim = try #require(supportedFiles(root.fixtures + "/tree").first)
            try FileManager.default.removeItem(atPath: root.fixtures + "/tree/" + victim)
            #expect(try kit(root, "expect", "counts", "tree").status != 0, "expect counts tree passes with a file missing")
            #expect(try kit(root, "expect", "listing", "tree").status != 0, "expect listing tree passes with a file missing")
        }
    }

    // MARK: kit repair: sync_into with an empty listing on one side (plan 3 self-run defect)

    /// Runs the real `sync_into` of scripts/kit-fixtures.sh (cut out of the script by name) with `manifest_of` stubbed to
    /// print the given rows, over throwaway src and dest folders holding the given files. No app, no builder.
    private func stubSync(srcFiles: [String], destFiles: [String], srcRows: [String], destRows: [String]) throws -> (ran: Ran, destLeft: [String], srcLeft: [String]) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("kit-s2-sync-" + UUID().uuidString).resolvingSymlinksInPath().path
        defer { try? fm.removeItem(atPath: base) }
        for d in ["src", "dest", "manifests", "tmp"] { try fm.createDirectory(atPath: base + "/" + d, withIntermediateDirectories: true) }
        for f in srcFiles { try "new \(f)".write(toFile: base + "/src/" + f, atomically: true, encoding: .utf8) }
        for f in destFiles { try "old \(f)".write(toFile: base + "/dest/" + f, atomically: true, encoding: .utf8) }
        func table(_ rows: [String]) -> String { rows.map { $0 + "\n" }.joined() }
        try table(srcRows).write(toFile: base + "/manifests/src.tsv", atomically: true, encoding: .utf8)
        try table(destRows).write(toFile: base + "/manifests/dest.tsv", atomically: true, encoding: .utf8)
        let script = """
        eval "$(sed -n '/^sync_into() {/,/^}/p' "$FIXTURES_SCRIPT")"
        manifest_of() { cat "$MANIFESTS/$(basename "$1").tsv"; }
        sync_into "$BASE/src" "$BASE/dest"
        """
        let ran = try run("/bin/bash", ["-c", script], env: ["FIXTURES_SCRIPT": fixturesScript, "MANIFESTS": base + "/manifests",
                                                            "BASE": base, "KIT_TMP": base + "/tmp"])
        return (ran, filesIn(base + "/dest"), filesIn(base + "/src"))
    }

    private func row(_ name: String, _ digest: String) -> String { "\(name)\t644\t5\t1000\t\(digest)" }

    @Test("sync_into with nothing in the destination listing writes every wanted file and removes none")
    func syncIntoEmptyDestination() throws {
        let r = try stubSync(srcFiles: ["a.txt", "b.txt", "c.txt"], destFiles: [], srcRows: [row("a.txt", "x1"), row("b.txt", "x2"), row("c.txt", "x3")], destRows: [])
        #expect(r.ran.status == 0, why(r.ran, "sync_into, empty destination"))
        #expect(r.ran.output.split(separator: "\n").last == "3 0 0", "sync_into printed \(r.ran.output.suffix(200)), expected `3 0 0` (written, kept, removed)")
        #expect(r.destLeft == ["a.txt", "b.txt", "c.txt"], "the destination holds \(r.destLeft) after the sync")
        #expect(r.srcLeft.isEmpty, "the built folder still holds \(r.srcLeft): nothing was moved in")
    }

    @Test("sync_into with nothing wanted removes every file of a destination that has some")
    func syncIntoEmptyWanted() throws {
        let r = try stubSync(srcFiles: [], destFiles: ["x.txt", "y.txt"], srcRows: [], destRows: [row("x.txt", "d1"), row("y.txt", "d2")])
        #expect(r.ran.status == 0, why(r.ran, "sync_into, empty wanted list"))
        #expect(r.ran.output.split(separator: "\n").last == "0 0 2", "sync_into printed \(r.ran.output.suffix(200)), expected `0 0 2`")
        #expect(r.destLeft.isEmpty, "the destination still holds \(r.destLeft)")
    }

    @Test("sync_into with both listings filled writes what differs or is new, keeps what is right, removes what is not wanted")
    func syncIntoMixed() throws {
        let r = try stubSync(srcFiles: ["b.txt", "d.txt"], destFiles: ["a.txt", "b.txt", "c.txt"],
                             srcRows: [row("a.txt", "s1"), row("b.txt", "s2-new"), row("d.txt", "s4")],
                             destRows: [row("a.txt", "s1"), row("b.txt", "s2-old"), row("c.txt", "s3")])
        #expect(r.ran.status == 0, why(r.ran, "sync_into, both listings filled"))
        #expect(r.ran.output.split(separator: "\n").last == "2 1 1", "sync_into printed \(r.ran.output.suffix(200)), expected `2 1 1`")
        #expect(r.destLeft == ["a.txt", "b.txt", "d.txt"], "the destination holds \(r.destLeft) after the sync")
    }

    @Test("build extra into a folder whose files are all gone (empty folders left) writes them again and removes nothing")
    func buildIntoEmptiedFolder() throws {
        try withRoot { root in
            let first = try kit(root, "build", "extra")
            try #require(first.status == 0, why(first, "build extra"))
            let total = extraCounts.values.reduce(0, +)
            let dir = root.fixtures + "/extra"
            for rel in filesIn(dir) { try FileManager.default.removeItem(atPath: dir + "/" + rel) }
            try #require(filesIn(dir).isEmpty, "the test could not empty fixtures/extra")
            let again = try kit(root, "build", "extra")
            #expect(again.status == 0, why(again, "build extra into an emptied folder"))
            #expect(again.output.contains("BUILT extra: \(total) files written, 0 left as they were, 0 removed"),
                    "build extra into an emptied folder printed: \(again.output.suffix(300))")
            #expect(kindCounts(dir) == extraCounts, "fixtures/extra holds \(kindCounts(dir)), the table says \(extraCounts)")
            let third = try kit(root, "build", "extra")
            #expect(third.output.contains("UNCHANGED extra: \(total) files already right"), "a build after the repair printed: \(third.output.suffix(300))")
        }
    }
}
