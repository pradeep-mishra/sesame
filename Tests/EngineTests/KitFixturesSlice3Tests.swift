import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Testing
import Vision

// plan-3-t2, tester step: the matrix fixture builder and the two expect checks of scripts/kit-fixtures.sh
// (`build matrix`, `expect matrix`, `expect extensions [--kinds <list>]`). Written from the plan entry, the spec's
// extension lists, verify.md and the sealed table scripts/kit-lib/gate-matrix.csv only; no product source is read.
//
// Every run is a child process of kit-fixtures.sh with its own temp KIT_ROOT (a folder named sesame-kit*), its own
// TMPDIR and a decoy HOME, so nothing is written to the real kit root or the real home, and no app is started.
// Expected values come from the table (paths, picks) and from lists written here by hand (the spec's extension
// lists, which folders are git repos, which file each repo ignores, the extensions of the unsupported cells);
// none is read from the script, and no assertion is made on data the test itself built.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `build matrix` makes $KIT_ROOT/fixtures/matrix from the table. First build prints `BUILT matrix: ...`; a build
//     that finds everything already right prints `UNCHANGED matrix: ...` and rewrites nothing.
//   - `expect matrix` prints `MATRIX OK <n> cells` (n = the table's data rows) and exits 0, else exits 1 and prints
//     `MISSING <cell> <path>` for every cell whose file (or link) is not there.
//   - `expect extensions [--kinds a,b]` prints `FOUND <kind> <ext> <path under fixtures/>` or `MISSING <kind> <ext>`
//     for every extension of the kinds (all six kinds when --kinds is absent), then `EXTENSIONS OK ...` (exit 0) or
//     `EXTENSIONS FAILED ...` (exit 4). A fixture file is any regular file of that extension under fixtures/golden,
//     fixtures/tree or fixtures/matrix.
//   - A `.gitignore` of an ignored cell's repo holds the one file name that cell is (nothing else), so
//     `git check-ignore` agrees. Pictures draw the cell's token as text (three lines; text recognition is compared
//     in lower case, so the drawing may use capitals).

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: hand-written tables

/// The spec's six extension lists (Goals, "Files Sesame reads, by extension").
private let kindExtensions: [(kind: String, exts: [String])] = [
    ("photo", ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]),
    ("document", ["txt", "md", "rtf", "docx", "html", "odt"]),
    ("audio", ["mp3", "m4a", "wav", "aac", "flac"]),
    ("video", ["mp4", "mov", "m4v"]),
    ("pdf", ["pdf"]),
    ("code", ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]),
]
private let photoExtensions = kindExtensions[0].exts

/// The picture type each photo extension must really be (ImageIO reads the bytes, not the name).
private let pictureType: [String: String] = [
    "jpeg": "public.jpeg", "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic",
    "webp": "org.webmproject.webp", "tiff": "public.tiff", "tif": "public.tiff", "gif": "com.compuserve.gif",
]

/// The top folders of the table that are git repos (verify.md Fixture key, plan entry t1): a repo that is not ticked,
/// a ticked one, the two whose one file is git-ignored, and the repo that holds the six vendored names.
private let repoFolders: Set<String> = ["repo-off", "ignored-off", "ignored-on", "vend-in"]

/// The cells whose file is git-ignored by its repo's .gitignore, with the file name the .gitignore lists.
private let ignoredCells: [(cell: String, repo: String, name: String)] = [
    ("ignored-off-png", "ignored-off", "local_zq0131.png"),
    ("ignored-off-txt", "ignored-off", "local_zq1602.txt"),
    ("ignored-on-py", "ignored-on", "local_zq0133.py"),
    ("ignored-on-txt", "ignored-on", "local_zq1603.txt"),
]

private let ignoredEntries: [String: [String]] = [
    "ignored-off": ["local_zq0131.png", "local_zq1602.txt"],
    "ignored-on": ["genfolder", "local_zq0133.py", "local_zq1603.txt"],
]

/// The only files under matrix/ that no row names (besides everything inside a .git folder).
private let allowedUnnamed: Set<String> = ["ignored-off/.gitignore", "ignored-on/.gitignore"]

/// The extension each unsupported cell must have ("" for none): a key extension or no extension is not a type.
private let unsupportedExtension: [String: String] = [
    "unsup-pptx": "pptx", "unsup-xlsx": "xlsx", "unsup-pages": "pages", "unsup-dng": "dng", "unsup-noext": "",
    "key-pem": "pem", "key-key": "key", "key-p12": "p12", "key-pfx": "pfx", "key-kdbx": "kdbx",
    "key-id_rsa-bare": "", "key-env-bare": "",
]

private let vendoredNames = ["node_modules", "Pods", "build", "dist", ".build", "vendor"]

// MARK: the table (read, never changed)

private struct Cell: Sendable {
    let cell: String
    let path: String
    let picks: String
    let group: String
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var top: String { String(path.split(separator: "/", maxSplits: 1)[0]) }
    var name: String { (path as NSString).lastPathComponent }
    var token: String? {
        guard let r = path.range(of: #"zq[0-9]{4}"#, options: .regularExpression) else { return nil }
        return String(path[r])
    }
}

private let tablePath = projectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv").path

private let cells: [Cell] = {
    guard let text = try? String(contentsOfFile: tablePath, encoding: .utf8) else { return [] }
    var rows: [Cell] = []
    for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where i > 0 {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7 else { continue }
        rows.append(Cell(cell: f[0], path: f[1], picks: f[2], group: f[6]))
    }
    return rows
}()

private func cell(_ name: String) -> Cell {
    guard let c = cells.first(where: { $0.cell == name }) else {
        Issue.record("the table has no cell \(name)")
        return Cell(cell: name, path: "missing/\(name)", picks: "", group: "spec")
    }
    return c
}

private let pictureCells: [Cell] = cells.filter {
    // the damaged, link and sparse cells carry a picture extension but are not pictures (own tests below)
    photoExtensions.contains($0.ext) && !["damaged-png", "link-png", "cloud-sparse-jpg"].contains($0.cell)
}

// MARK: running the script

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 600) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitfx3-out-" + UUID().uuidString)
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
    var matrix: String { fixtures + "/matrix" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome,
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
}

private func makeRoot(tools: Bool = true) throws -> Root {
    _ = cleanupRegistered
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-s3-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let base = made.resolvingSymlinksInPath().path
    let root = Root(base: base, kit: base + "/sesame-kit-s3", tmp: base + "/tmp", decoyHome: base + "/decoy-home")
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
    guard FileManager.default.fileExists(atPath: fixturesScript) else {
        Issue.record("scripts/kit-fixtures.sh not found")
        return Ran(status: 127, output: "scripts/kit-fixtures.sh not found")
    }
    return try run("/bin/bash", [fixturesScript] + args, env: root.env)
}

/// A fresh root with `build matrix` run in it; the run is returned so a red test can say why.
private func builtRoot() throws -> (root: Root, built: Ran) {
    let root = try makeRoot()
    cleanup.add(root.base)
    return (root, try kit(root, "build", "matrix"))
}

/// The shared, read-only build: made once for the tests that only read it.
private let shared: (root: Root, built: Ran)? = try? builtRoot()

private func sharedBuilt() -> (root: Root, built: Ran) {
    guard let s = shared else {
        Issue.record("could not make the shared kit root")
        return (Root(base: "", kit: "", tmp: "", decoyHome: ""), Ran(status: 127, output: ""))
    }
    return s
}

// MARK: reading the built folder

private func isLink(_ path: String) -> Bool {
    var st = Darwin.stat()
    return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
}

private func isRegular(_ path: String) -> Bool {
    var st = Darwin.stat()
    return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
}

private func exists(_ path: String) -> Bool {
    var st = Darwin.stat()
    return lstat(path, &st) == 0
}

/// Every entry that is not a folder under dir (regular files and links, hidden ones too), relative, sorted.
private func entriesIn(_ dir: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: dir) else { return [] }
    var found: [String] = []
    for case let rel as String in walker {
        var st = Darwin.stat()
        guard lstat(dir + "/" + rel, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
        found.append(rel)
    }
    return found.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

private struct Entry: Equatable {
    let inode: UInt64
    let mtimeNs: Int64
    let digest: String
}

/// inode, modified time and content (or link target) of every entry, inside .git too.
private func snapshot(_ dir: String) -> [String: Entry] {
    var snap: [String: Entry] = [:]
    for rel in entriesIn(dir) {
        let p = dir + "/" + rel
        var st = Darwin.stat()
        guard lstat(p, &st) == 0 else { continue }
        let digest: String
        if isLink(p) {
            digest = "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: p)) ?? "?")
        } else {
            let data = FileManager.default.contents(atPath: p) ?? Data()
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        snap[rel] = Entry(
            inode: UInt64(st.st_ino),
            mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
            digest: digest)
    }
    return snap
}

private func text(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
}

private struct Picture {
    let decodes: Bool
    let type: String?
    let width: Int
    let height: Int
}

private func picture(_ path: String) -> Picture {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        return Picture(decodes: false, type: nil, width: 0, height: 0)
    }
    let type = CGImageSourceGetType(src) as String?
    guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        return Picture(decodes: false, type: type, width: 0, height: 0)
    }
    return Picture(decodes: true, type: type, width: img.width, height: img.height)
}

/// What text recognition reads in a picture (the same recognition a person's search would run).
private func recognizedText(_ path: String) -> String {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: img).perform([request]) } catch { ScanPdf.recordVisionFailure(error) }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

private func git(_ dir: String, _ args: String...) throws -> Ran {
    try run("/usr/bin/git", ["-C", dir] + args,
            env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"])
}

private func sha(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
}

// MARK: the tests

@Suite("KitFixturesSlice3Tests")
struct KitFixturesSlice3Tests {
    @Test("the table is there to build from: 60 or more rows with a path each")
    func tableIsRead() {
        #expect(cells.count >= 60, "scripts/kit-lib/gate-matrix.csv gave \(cells.count) rows")
    }

    @Test("the usage names build matrix, expect matrix and expect extensions; a stray argument is a usage error")
    func usageNamesTheNewModes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root.base) }
        let bare = try kit(root)
        #expect(bare.status == 2, "no mode: expected exit 2, got \(bare.status)")
        #expect(bare.output.contains("build matrix"), "usage does not name build matrix:\n\(bare.output)")
        #expect(bare.output.contains("expect matrix"), "usage does not name expect matrix")
        #expect(bare.output.contains("expect extensions"), "usage does not name expect extensions")
        let extra = try kit(root, "build", "matrix", "extra")
        #expect(extra.status == 2, "build matrix with a stray argument: expected exit 2, got \(extra.status):\n\(extra.output)")
        let badKind = try kit(root, "expect", "extensions", "--kinds", "nonsense")
        #expect(badKind.status == 2, "an unknown kind is a usage error: got \(badKind.status):\n\(badKind.output)")
    }

    @Test("build matrix makes every row's path under fixtures/matrix from the table alone")
    func everyRowExists() {
        let s = sharedBuilt()
        #expect(s.built.status == 0, "build matrix exited \(s.built.status):\n\(s.built.output)")
        #expect(s.built.output.contains("BUILT matrix"), "first build did not print BUILT matrix:\n\(s.built.output)")
        var missing: [String] = []
        for c in cells where !exists(s.root.matrix + "/" + c.path) { missing.append(c.path) }
        #expect(missing.isEmpty, "missing under matrix/: \(missing)")
    }

    @Test("a text cell holds its unique token")
    func textCellsHoldTheirToken() {
        let s = sharedBuilt()
        let textCells = cells.filter { ["txt", "md", "py"].contains($0.ext) }
        #expect(textCells.count >= 15, "the table has only \(textCells.count) text cells")
        for c in textCells {
            guard let token = c.token else { Issue.record("\(c.cell) has no token"); continue }
            let body = text(s.root.matrix + "/" + c.path)
            #expect(body?.contains(token) == true, "\(c.cell) (\(c.path)) does not hold \(token)")
        }
    }

    @Test("the cells job 2 adds hold their own token: the pdf in its text layer, the two txt cells of the ignored repos and of vend-in, the two outer photos drawn")
    func jobTwoCellsHoldTheirToken() {
        let s = sharedBuilt()
        let pdf = PDFDocument(url: URL(fileURLWithPath: s.root.matrix + "/" + cell("repo-off-pdf").path))
        #expect(pdf?.string?.contains("zq1601") == true, "repo-off-pdf does not hold zq1601 in its text layer: \(pdf?.string ?? "not a pdf")")
        for (name, token) in [("ignored-off-txt", "zq1602"), ("ignored-on-txt", "zq1603"), ("vend-in-node_modules-txt", "zq1611"), ("vend-in-Pods-txt", "zq1612"), ("repo-off-txt", "zq0122")] {
            #expect(text(s.root.matrix + "/" + cell(name).path)?.contains(token) == true, "\(name) does not hold \(token)")
        }
        for (name, token) in [("ov-a-outer-photo", "zq1621"), ("ov-b-outer-photo", "zq1622")] {
            let path = s.root.matrix + "/" + cell(name).path
            #expect(picture(path).decodes, "\(name) is not a decodable picture")
            #expect(recognizedText(path).lowercased().replacingOccurrences(of: " ", with: "").contains(token), "text recognition did not read \(token) in \(name)")
        }
    }

    @Test("a picture cell is a decodable picture of its extension, not an empty or renamed file")
    func pictureCellsDecode() {
        let s = sharedBuilt()
        #expect(pictureCells.count >= 30, "the table has only \(pictureCells.count) picture cells")
        for c in pictureCells {
            let p = picture(s.root.matrix + "/" + c.path)
            #expect(p.decodes, "\(c.cell) (\(c.path)) does not decode with ImageIO")
            #expect(p.width >= 64 && p.height >= 64, "\(c.cell) is only \(p.width) x \(p.height)")
            if let want = pictureType[c.ext] {
                #expect(p.type == want, "\(c.cell) (.\(c.ext)) is really \(p.type ?? "nothing"), expected \(want)")
            }
        }
        // one cell of each photo extension exists and decodes as that type
        for ext in photoExtensions {
            let c = cell("ext-\(ext)")
            #expect(picture(s.root.matrix + "/" + c.path).type == pictureType[ext], "ext-\(ext) is not a real .\(ext)")
        }
    }

    @Test("a picture cell draws its token as text that text recognition reads")
    func pictureTokensAreReadable() {
        let s = sharedBuilt()
        let names = photoExtensions.map { "ext-\($0)" } + ["plain-photo", "key-env-png", "key-id_rsa-png", "repo-off-png", "ov-a-outer-photo", "ov-b-outer-photo", "ov-d-inner-photo"]
        for name in names {
            let c = cell(name)
            guard let token = c.token else { Issue.record("\(name) has no token"); continue }
            let read = recognizedText(s.root.matrix + "/" + c.path).lowercased().replacingOccurrences(of: " ", with: "")
            #expect(read.contains(token), "text recognition read \(read.debugDescription) in \(name), expected \(token)")
        }
    }

    @Test("the sparse cell has a size above 0 and no blocks")
    func sparseCell() {
        let s = sharedBuilt()
        let path = s.root.matrix + "/" + cell("cloud-sparse-jpg").path
        var st = Darwin.stat()
        #expect(lstat(path, &st) == 0, "the sparse cell is missing")
        #expect(isRegular(path), "the sparse cell is not a regular file")
        #expect(st.st_size > 0, "the sparse cell has size \(st.st_size)")
        #expect(st.st_blocks == 0, "the sparse cell has \(st.st_blocks) blocks, expected none")
    }

    @Test("the link cell is a symbolic link whose target is the plain-photo file")
    func linkCell() throws {
        let s = sharedBuilt()
        let link = s.root.matrix + "/" + cell("link-png").path
        #expect(isLink(link), "link-png is not a symbolic link")
        let dest = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? ""
        let resolved = dest.hasPrefix("/") ? dest : (link as NSString).deletingLastPathComponent + "/" + dest
        let want = s.root.matrix + "/" + cell("plain-photo").path
        #expect(URL(fileURLWithPath: resolved).standardized.path == URL(fileURLWithPath: want).standardized.path,
                "link-png points at \(dest), expected the plain-photo file \(want)")
        #expect(isRegular(want), "the plain-photo file is not a regular file")
    }

    @Test("the repo folders are real git repos and no other top folder is inside one")
    func repoFoldersAreRepos() throws {
        let s = sharedBuilt()
        let tops = Set(cells.map(\.top))
        for top in tops.sorted() {
            let dir = s.root.matrix + "/" + top
            let hasGit = exists(dir + "/.git")
            if repoFolders.contains(top) {
                #expect(hasGit, "\(top) has no .git")
                let r = try git(dir, "rev-parse", "--show-toplevel")
                let toplevel = URL(fileURLWithPath: r.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    .resolvingSymlinksInPath().path
                let want = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
                #expect(r.status == 0 && toplevel == want, "git rev-parse in \(top): \(r.status) \(r.output) (expected \(want))")
            } else {
                #expect(!hasGit, "\(top) must not be a repo")
            }
        }
        for repo in repoFolders { #expect(tops.contains(repo), "the table has no folder \(repo)") }
    }

    @Test("a .gitignore lists exactly the ignored cells of its repo, and git agrees")
    func gitignoreListsTheIgnoredCells() throws {
        let s = sharedBuilt()
        for (repo, want) in ignoredEntries.sorted(by: { $0.key < $1.key }) {
            let body = text(s.root.matrix + "/\(repo)/.gitignore") ?? ""
            let entries = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            #expect(entries.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.sorted() == want,
                    "\(repo)/.gitignore lists \(entries), expected exactly \(want)")
        }
        for ignored in ignoredCells {
            let c = cell(ignored.cell)
            #expect(c.top == ignored.repo && c.name == ignored.name, "the table moved \(ignored.cell): \(c.path)")
            let check = try git(s.root.matrix + "/" + ignored.repo, "check-ignore", "-q", "--", ignored.name)
            #expect(check.status == 0, "git does not ignore \(ignored.name) in \(ignored.repo) (status \(check.status))")
        }
        let folder = try git(s.root.matrix + "/ignored-on", "check-ignore", "-q", "--", "genfolder/gen_zq1503.py")
        #expect(folder.status == 0, "git does not ignore genfolder/gen_zq1503.py in ignored-on (status \(folder.status))")
        for name in ["repo-off-png", "repo-off-txt", "repo-off-pdf", "vend-in-dist-png"] {
            let c = cell(name)
            let rel = String(c.path.dropFirst(c.top.count + 1))
            let check = try git(s.root.matrix + "/" + c.top, "check-ignore", "-q", "--", rel)
            #expect(check.status == 1, "git ignores \(name) (status \(check.status)), expected it listed")
        }
    }

    @Test("the vendored cells sit in folders of the six names inside a repo and outside one")
    func vendoredFolders() {
        let s = sharedBuilt()
        for name in vendoredNames {
            let inside = cells.filter { $0.top == "vend-in" && $0.path.split(separator: "/").contains(Substring(name)) }
            let outside = cells.filter { $0.top == "vend-out" && $0.path.split(separator: "/").contains(Substring(name)) }
            #expect(!inside.isEmpty, "no cell in vend-in/\(name)")
            #expect(!outside.isEmpty, "no cell in vend-out/\(name)")
            for c in inside + outside {
                var isDir: ObjCBool = false
                let folder = s.root.matrix + "/" + c.top + "/" + name
                #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue,
                        "\(c.cell): \(folder) is not a folder")
                #expect(isRegular(s.root.matrix + "/" + c.path), "\(c.cell) is not a file")
            }
        }
        #expect(exists(s.root.matrix + "/vend-in/.git"), "vend-in is not a repo")
        #expect(!exists(s.root.matrix + "/vend-out/.git"), "vend-out must not be a repo")
    }

    @Test("the unsupported cells have the extensions .pptx .xlsx .pages .dng and none, and key extensions are not types")
    func unsupportedCells() {
        let s = sharedBuilt()
        for (name, ext) in unsupportedExtension.sorted(by: { $0.key < $1.key }) {
            let c = cell(name)
            #expect(c.ext == ext, "\(name) has extension '\(c.ext)', expected '\(ext)'")
            let p = s.root.matrix + "/" + c.path
            #expect(isRegular(p), "\(name) is not a regular file")
            #expect((FileManager.default.contents(atPath: p)?.count ?? 0) > 0, "\(name) is empty")
            #expect(!picture(p).decodes, "\(name) must not be a picture")
        }
        for ext in ["pptx", "xlsx", "pages", "dng", "pem", "key", "p12", "pfx", "kdbx"] {
            #expect(!kindExtensions.contains { $0.exts.contains(ext) }, "the hand table lists .\(ext) as a supported type")
        }
    }

    @Test("the damaged cell is a truncated PNG: the PNG signature, shorter than a good PNG, and no picture decodes")
    func damagedCell() {
        let s = sharedBuilt()
        let path = s.root.matrix + "/" + cell("damaged-png").path
        let bytes = [UInt8](FileManager.default.contents(atPath: path) ?? Data())
        #expect(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "damaged-png does not start with the PNG signature")
        let good = FileManager.default.contents(atPath: s.root.matrix + "/" + cell("ext-png").path)?.count ?? 0
        #expect(bytes.count > 8 && bytes.count < good, "damaged-png is \(bytes.count) bytes, a good PNG is \(good)")
        #expect(!picture(path).decodes, "damaged-png decodes as a picture, it must be damaged")
    }

    @Test("the key picture cells are decodable pictures whose names keep the key name as a dotted segment")
    func keyPictureCells() {
        let s = sharedBuilt()
        let keyNames: [(String, String)] = [
            ("key-id_rsa-png", "id_rsa."), ("key-env-png", ".env."), ("key-env-local-png", ".env.local."),
            ("extra-id_ed25519-png", "id_ed25519."),
        ]
        for (name, prefix) in keyNames {
            let c = cell(name)
            #expect(c.name.hasPrefix(prefix), "\(name): the file name \(c.name) does not start with \(prefix)")
            #expect(c.ext == "png", "\(name) must have a picture extension")
            let p = picture(s.root.matrix + "/" + c.path)
            #expect(p.decodes && p.type == "public.png", "\(name) is not a decodable PNG")
        }
        // the bare cells keep the token with an underscore and have no extension
        #expect(cell("key-id_rsa-bare").name.hasPrefix("id_rsa_zq"))
        #expect(cell("key-env-bare").name.hasPrefix(".env_zq"))
    }

    @Test("the files of ov-a to ov-d sit in the outer and inner folders of their pair, nothing else is in those folders")
    func overlapPairs() {
        let s = sharedBuilt()
        for pair in ["ov-a", "ov-b", "ov-c", "ov-d"] {
            let inner = cells.filter { $0.cell.hasPrefix(pair + "-inner") }
            let outer = cells.filter { $0.cell.hasPrefix(pair + "-outer") }
            #expect(!inner.isEmpty && !outer.isEmpty, "\(pair) lost its inner or outer cells")
            for c in inner {
                #expect((c.path as NSString).deletingLastPathComponent == "\(pair)/outer/inner", "\(c.cell) is in \(c.path)")
                #expect(isRegular(s.root.matrix + "/" + c.path), "\(c.cell) is missing")
            }
            for c in outer {
                #expect((c.path as NSString).deletingLastPathComponent == "\(pair)/outer", "\(c.cell) is in \(c.path)")
                #expect(isRegular(s.root.matrix + "/" + c.path), "\(c.cell) is missing")
            }
            let want = Set((inner + outer).map(\.path))
            let got = Set(entriesIn(s.root.matrix + "/" + pair).map { pair + "/" + $0 })
            #expect(got == want, "\(pair) holds \(got.symmetricDifference(want))")
        }
    }

    @Test("no file is under matrix/ that no row names, except the .git folders and the two .gitignore files")
    func noUnnamedFiles() {
        let s = sharedBuilt()
        let named = Set(cells.map(\.path))
        var extra: [String] = []
        for rel in entriesIn(s.root.matrix) where !named.contains(rel) && !allowedUnnamed.contains(rel) {
            if rel.split(separator: "/").contains(".git") { continue }
            if (rel as NSString).lastPathComponent == ".DS_Store" { continue }
            extra.append(rel)
        }
        #expect(extra.isEmpty, "files no row names: \(extra)")
        for rel in allowedUnnamed { #expect(isRegular(s.root.matrix + "/" + rel), "\(rel) is missing") }
    }

    @Test("the plain pdf, audio and video cells are a pdf that holds its token, a wav and an mp4")
    func plainMediaCells() {
        let s = sharedBuilt()
        let pdf = s.root.matrix + "/" + cell("plain-pdf").path
        let doc = PDFDocument(url: URL(fileURLWithPath: pdf))
        #expect(doc?.pageCount == 1, "plain-pdf is not a one page pdf")
        #expect(doc?.string?.contains(cell("plain-pdf").token ?? "?") == true, "plain-pdf does not hold its token")
        let wav = [UInt8](FileManager.default.contents(atPath: s.root.matrix + "/" + cell("plain-audio").path) ?? Data())
        #expect(wav.starts(with: Array("RIFF".utf8)) && Array(wav.dropFirst(8).prefix(4)) == Array("WAVE".utf8), "plain-audio is not a wav")
        let mp4 = [UInt8](FileManager.default.contents(atPath: s.root.matrix + "/" + cell("plain-video").path) ?? Data())
        #expect(Array(mp4.dropFirst(4).prefix(4)) == Array("ftyp".utf8), "plain-video is not an mp4")
    }

    @Test("the builder touches only files under KIT_ROOT: the decoy home and the temp folder stay clean")
    func buildsOnlyUnderKitRoot() throws {
        let s = sharedBuilt()
        let home = (try? FileManager.default.contentsOfDirectory(atPath: s.root.decoyHome)) ?? []
        #expect(home.isEmpty, "the decoy home holds \(home)")
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: s.root.tmp)) ?? []).filter { !$0.hasPrefix(".") }
        #expect(left.isEmpty, "the builder left \(left) in the temp folder")
    }

    @Test("same bytes twice: the second build prints UNCHANGED and rewrites no file; a deleted cell is rebuilt, a stray file is removed")
    func secondBuildIsUnchanged() throws {
        let (root, first) = try builtRoot()
        #expect(first.status == 0, "first build exited \(first.status):\n\(first.output)")
        let before = snapshot(root.matrix)
        #expect(before.count >= cells.count, "the first build made only \(before.count) files")

        let second = try kit(root, "build", "matrix")
        #expect(second.status == 0, "second build exited \(second.status):\n\(second.output)")
        #expect(second.output.contains("UNCHANGED"), "second build did not print UNCHANGED:\n\(second.output)")
        let after = snapshot(root.matrix)
        #expect(after.keys.sorted() == before.keys.sorted(), "the second build changed the file list")
        var changed: [String] = []
        for (rel, was) in before where after[rel] != was { changed.append(rel) }
        #expect(changed.isEmpty, "the second build rewrote or changed \(changed.prefix(10))")

        // a deleted cell file is rebuilt with the same bytes
        let gone = cell("ext-jpg").path
        let goneDigest = before[gone]?.digest
        try FileManager.default.removeItem(atPath: root.matrix + "/" + gone)
        // a stray file and a stray folder are removed; a changed cell file is put back
        try FileManager.default.createDirectory(atPath: root.matrix + "/plain/stray-folder", withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: URL(fileURLWithPath: root.matrix + "/plain/stray-folder/stray.txt"))
        try Data("stray".utf8).write(to: URL(fileURLWithPath: root.matrix + "/plain/stray.txt"))
        let doc = cell("plain-doc").path
        try Data("changed".utf8).write(to: URL(fileURLWithPath: root.matrix + "/" + doc))
        let third = try kit(root, "build", "matrix")
        #expect(third.status == 0, "third build exited \(third.status):\n\(third.output)")
        #expect(!third.output.contains("UNCHANGED"), "a build that rebuilt a file said UNCHANGED:\n\(third.output)")
        #expect(sha(root.matrix + "/" + gone) == goneDigest, "the deleted \(gone) was not rebuilt with the same bytes")
        #expect(!exists(root.matrix + "/plain/stray.txt"), "the stray file was not removed")
        #expect(!exists(root.matrix + "/plain/stray-folder/stray.txt"), "the file in the stray folder was not removed")
        #expect(sha(root.matrix + "/" + doc) == before[doc]?.digest, "the changed plain-doc was not put back")
        let fourth = try kit(root, "build", "matrix")
        #expect(fourth.output.contains("UNCHANGED"), "the build after the repair was not UNCHANGED:\n\(fourth.output)")
    }

    @Test("two builds in two kit roots make identical files")
    func twoRootsMakeTheSameBytes() throws {
        let s = sharedBuilt()
        let (other, built) = try builtRoot()
        #expect(built.status == 0, "build matrix exited \(built.status):\n\(built.output)")
        let a = snapshot(s.root.matrix)
        let b = snapshot(other.matrix)
        #expect(a.keys.sorted() == b.keys.sorted(), "the two roots hold different files")
        var differ: [String] = []
        for (rel, entry) in a where b[rel]?.digest != entry.digest {
            // the .git folder holds nothing that differs either, but name the first few if it does
            differ.append(rel)
        }
        #expect(differ.isEmpty, "bytes differ between two builds: \(differ.prefix(10))")
    }

    @Test("expect matrix prints MATRIX OK <n> cells; a missing cell file is exit 1 naming the cell; no folder is exit 1")
    func expectMatrix() throws {
        let s = sharedBuilt()
        let ok = try kit(s.root, "expect", "matrix")
        #expect(ok.status == 0, "expect matrix exited \(ok.status):\n\(ok.output)")
        #expect(ok.output.contains("MATRIX OK \(cells.count) cells"), "expected 'MATRIX OK \(cells.count) cells':\n\(ok.output)")

        let (root, built) = try builtRoot()
        #expect(built.status == 0, "build matrix exited \(built.status)")
        let target = cell("ext-gif")
        try FileManager.default.removeItem(atPath: root.matrix + "/" + target.path)
        let bad = try kit(root, "expect", "matrix")
        #expect(bad.status == 1, "a missing cell file: expected exit 1, got \(bad.status):\n\(bad.output)")
        #expect(bad.output.contains("ext-gif"), "the missing cell ext-gif is not named:\n\(bad.output)")
        #expect(!bad.output.contains("MATRIX OK"), "a failing check printed MATRIX OK")

        let empty = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: empty.base) }
        let none = try kit(empty, "expect", "matrix")
        #expect(none.status == 1, "no matrix folder: expected exit 1, got \(none.status):\n\(none.output)")
    }

    /// The `FOUND <kind> <ext> <path>` lines of a run: ext to path.
    private func found(_ ran: Ran, kind: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in ran.lines {
            let f = line.split(separator: " ").map(String.init)
            if f.count >= 4, f[0] == "FOUND", f[1] == kind { map[f[2]] = f[3] }
        }
        return map
    }

    private func neverRead(_ ran: Ran) -> [String: String] {
        var map: [String: String] = [:]
        for line in ran.lines {
            let f = line.split(separator: " ").map(String.init)
            if f.count >= 3, f[0] == "NEVER-READ" { map[f[1]] = f[2] }
        }
        return map
    }

    private func missing(_ ran: Ran, kind: String) -> [String] {
        ran.lines.compactMap { line in
            let f = line.split(separator: " ").map(String.init)
            return f.count >= 3 && f[0] == "MISSING" && f[1] == kind ? f[2] : nil
        }
    }

    @Test("expect extensions --kinds photo: exit 0 and every photo extension with a fixture file; a removed ext-tif is exit 4 naming tif")
    func expectExtensionsPhoto() throws {
        let (root, built) = try builtRoot()
        #expect(built.status == 0, "build matrix exited \(built.status):\n\(built.output)")
        let ok = try kit(root, "expect", "extensions", "--kinds", "photo")
        #expect(ok.status == 0, "expect extensions --kinds photo exited \(ok.status):\n\(ok.output)")
        let files = found(ok, kind: "photo")
        for ext in photoExtensions {
            guard let path = files[ext] else { Issue.record("no FOUND line for photo .\(ext):\n\(ok.output)"); continue }
            #expect(path.hasPrefix("matrix/"), "photo .\(ext) found at \(path), expected a matrix file")
            #expect((path as NSString).pathExtension.lowercased() == ext && isRegular(root.fixtures + "/" + path),
                    "photo .\(ext): \(path) is not a file of that extension")
        }
        #expect(ok.output.contains("EXTENSIONS OK"), "no EXTENSIONS OK line:\n\(ok.output)")
        #expect(!ok.lines.contains { $0.hasPrefix("FOUND document") }, "--kinds photo also checked documents")

        try FileManager.default.removeItem(atPath: root.matrix + "/" + cell("ext-tif").path)
        let bad = try kit(root, "expect", "extensions", "--kinds", "photo")
        #expect(bad.status == 4, "a missing .tif: expected exit 4, got \(bad.status):\n\(bad.output)")
        #expect(missing(bad, kind: "photo") == ["tif"], "expected exactly tif missing, got \(missing(bad, kind: "photo")):\n\(bad.output)")
        #expect(bad.output.contains("EXTENSIONS FAILED"), "no EXTENSIONS FAILED line")
        #expect(found(bad, kind: "photo").keys.contains("tiff"), "tiff must still be found")

        // the golden and tree folders count too: a .tif planted in each is found again
        try FileManager.default.createDirectory(atPath: root.fixtures + "/tree", withIntermediateDirectories: true)
        try Data("II*\0".utf8).write(to: URL(fileURLWithPath: root.fixtures + "/tree/planted.tif"))
        let viaTree = try kit(root, "expect", "extensions", "--kinds", "photo")
        #expect(viaTree.status == 0, "a .tif under tree/ was not counted (exit \(viaTree.status)):\n\(viaTree.output)")
        #expect(found(viaTree, kind: "photo")["tif"] == "tree/planted.tif", "tif found at \(found(viaTree, kind: "photo")["tif"] ?? "nothing")")
        try FileManager.default.removeItem(atPath: root.fixtures + "/tree/planted.tif")
        try FileManager.default.createDirectory(atPath: root.fixtures + "/golden/photos", withIntermediateDirectories: true)
        try Data("II*\0".utf8).write(to: URL(fileURLWithPath: root.fixtures + "/golden/photos/planted.tif"))
        let viaGolden = try kit(root, "expect", "extensions", "--kinds", "photo")
        #expect(viaGolden.status == 0, "a .tif under golden/ was not counted (exit \(viaGolden.status)):\n\(viaGolden.output)")
        #expect(found(viaGolden, kind: "photo")["tif"] == "golden/photos/planted.tif", "tif found at \(found(viaGolden, kind: "photo")["tif"] ?? "nothing")")
    }

    // Amended in plan-4-t2 (it pinned exit 4 with rtf, docx, html and odt missing): the matrix now has the extdoc-* cells, one per
    // document extension, so with only the matrix built `--kinds document` finds all six and exits 0. Not weakened: the six
    // extensions and their FOUND lines are pinned, and a missing one is still exit 4 (the photo test above removes one).
    @Test("expect extensions --kinds document finds all six document extensions in the matrix (the extdoc cells); no --kinds checks every kind and still names what has no fixture")
    func expectExtensionsOtherKinds() throws {
        let s = sharedBuilt()
        let doc = try kit(s.root, "expect", "extensions", "--kinds", "document")
        #expect(doc.status == 0, "--kinds document: expected exit 0, got \(doc.status):\n\(doc.output)")
        #expect(missing(doc, kind: "document").isEmpty, "missing documents were \(missing(doc, kind: "document")):\n\(doc.output)")
        #expect(Set(found(doc, kind: "document").keys) == ["txt", "md", "rtf", "docx", "html", "odt"], "found documents were \(found(doc, kind: "document").keys)")
        for (ext, path) in found(doc, kind: "document") {
            #expect(path.hasPrefix("matrix/") && (path as NSString).pathExtension.lowercased() == ext, "document .\(ext) found at \(path)")
        }
        #expect(doc.output.contains("EXTENSIONS OK"), "no EXTENSIONS OK line:\n\(doc.output)")

        let two = try kit(s.root, "expect", "extensions", "--kinds", "photo,pdf")
        #expect(two.status == 0, "--kinds photo,pdf: expected exit 0, got \(two.status):\n\(two.output)")
        #expect(found(two, kind: "pdf")["pdf"]?.hasPrefix("matrix/") == true, "no pdf fixture was found:\n\(two.output)")
        #expect(found(two, kind: "photo").count == photoExtensions.count, "photo extensions found: \(found(two, kind: "photo").keys)")

        let all = try kit(s.root, "expect", "extensions")
        // Amended in plan-6-t1 (it pinned exit 4 with a code extension missing): the matrix now has the ext- code cells under extcode/,
        // one per code extension, so with only the matrix built every extension of every kind has a fixture file and the run exits 0.
        // Not weakened: the run still covers every extension of every kind, none is missing, and a missing one is still exit 4 and
        // named (a removed ext-kt, below).
        #expect(all.status == 0, "no --kinds with only matrix built: expected exit 0, got \(all.status):\n\(all.output)")
        for (kind, exts) in kindExtensions {
            let seen = Set((kind == "code" ? neverRead(all) : found(all, kind: kind)).keys).union(missing(all, kind: kind))
            #expect(seen == Set(exts), "kind \(kind): the run covered \(seen.sorted()), expected \(exts.sorted())")
        }
        // Amended in plan-5-t1 (it pinned mp3 as missing): the matrix now has the extav-* cells, one per audio and video extension, so all
        // eight are found there; what still has no fixture (some code extensions) is still named and still makes the run exit 4.
        #expect(missing(all, kind: "audio").isEmpty && missing(all, kind: "video").isEmpty, "audio missing \(missing(all, kind: "audio")), video missing \(missing(all, kind: "video"))")
        #expect(found(all, kind: "audio")["mp3"]?.hasPrefix("matrix/extav/") == true, "mp3 is not found in the extav cells: \(String(describing: found(all, kind: "audio")["mp3"]))")
        #expect(found(all, kind: "video")["m4v"]?.hasPrefix("matrix/") == true, "m4v is not found in the matrix")
        #expect(missing(all, kind: "code").isEmpty, "code extensions missing: \(missing(all, kind: "code"))")
        #expect(neverRead(all)["py"]?.hasPrefix("matrix/") == true, "the .py cells are never-read fixtures: \(String(describing: neverRead(all)["py"]))")
        #expect(neverRead(all)["swift"]?.hasPrefix("matrix/") == true, "swift is found in the matrix: \(String(describing: neverRead(all)["swift"]))")
        #expect(all.lines.contains("NEVER READ"), "the run has no NEVER READ section:\n\(all.output)")
        let codeExts = Set(kindExtensions.first { $0.kind == "code" }?.exts ?? [])
        #expect(Set(neverRead(all).keys) == codeExts, "the never read section holds \(neverRead(all).keys.sorted()), expected the fifteen code extensions")
        for kind in ["photo", "document", "audio", "video", "pdf"] {
            #expect(Set(found(all, kind: kind).keys).isDisjoint(with: codeExts), "kind \(kind) lists a code extension in the read list: \(found(all, kind: kind).keys.sorted())")
        }
        #expect(!all.lines.contains { $0.hasPrefix("FOUND code") }, "a code extension is in the read list (a FOUND code line)")
        let readHeading = all.lines.firstIndex(of: "NEVER READ") ?? 0
        #expect(all.lines.prefix(readHeading).allSatisfy { !$0.hasPrefix("NEVER-READ") }, "a never-read line comes before the NEVER READ heading")
        let (fresh, _) = try builtRoot()
        try FileManager.default.removeItem(atPath: fresh.matrix + "/" + cell("ext-kt").path)
        let bad = try kit(fresh, "expect", "extensions")
        #expect(bad.status == 4, "a missing .kt: expected exit 4, got \(bad.status):\n\(bad.output)")
        #expect(missing(bad, kind: "code") == ["kt"], "expected exactly kt missing, got \(missing(bad, kind: "code")):\n\(bad.output)")
        #expect(neverRead(bad).count == 14, "with .kt removed the never read section holds \(neverRead(bad).count) found extensions, expected 14")
    }
}
