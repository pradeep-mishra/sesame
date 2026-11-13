import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

// plan-3-t3, tester step: the unrelated photos, golden group b, `merge` and `extensions` of the golden kit
// (scripts/kit-fixtures.sh `build unrelated <n>`, scripts/kit-golden.sh, scripts/kit-lib/golden.sh,
// scripts/kit-lib/read-kinds.txt). Written from the plan entry, the spec's extension lists, verify.md, the S2 feature
// map, fixtures/answers.csv and scripts/kit-lib/golden-photos.tsv only; no product source is read.
//
// Every run is a child process: kit-fixtures.sh with its own temp KIT_ROOT (a folder named sesame-kit*), its own TMPDIR
// and a decoy HOME, and bash children that source scripts/kit-lib/common.sh and golden.sh and call one helper. Nothing
// here starts the app, runs `kit-golden.sh engine|merge|extensions|panel` or starts a nested `swift test`: those are
// proven by text checks of the script, the sourced helpers on hand-written samples and hand-written tsv files.
// Expected values come from answers.csv and lists written here by hand; none is read from the code under test.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `build unrelated <n>` (n a whole number from 1 to 9999; anything else exit 2 and nothing built) makes exactly n
//     files directly in $KIT_ROOT/fixtures/unrelated/, named `unrel0001` to `unrel<n>` (four digits, one-based) with a
//     photo extension. File k has the same bytes whatever n is, every file has its own bytes. A build that finds
//     everything right prints `UNCHANGED unrelated` and rewrites nothing; otherwise it prints `BUILT unrelated`.
//   - golden.sh helpers, run in a child shell that sources common.sh and golden.sh. They read `$KIT_LIB/read-kinds.txt`
//     and `$KIT_LIB/extensions.txt` when they are called, so a test points KIT_LIB at a folder of its own:
//       golden_built <a|b>               status 0 for a and b
//       golden_read_kinds                the kinds of read-kinds.txt (one kind a line), comma separated
//       golden_rows <letter>             "id<TAB>query<TAB>file<TAB>locator"; for b only the exact rows whose file has
//                                        an extension of a kind listed in read-kinds.txt
//       golden_key_rows <letter>         how many rows the key holds for the group, readable or not
//       golden_oddeven <tsv> <letter>    `odd first <x> of <n>, even first <y> of <m>` and, when the even rows hit at
//                                        least 2 fewer than the odd rows, a second line `noted: overfitting risk`;
//                                        odd and even are the number in the row id, a hit is rank 1
//       golden_line_b <mode> <readable> <first> <total>
//                                        the verdict line; status 0 PASS, 1 FAIL
//       golden_none_why <letter>         (output of `swift test` on stdin) why a row has no rank
//       golden_rank_lines                (output of `swift test` on stdin) the `RANK <id> <n|none> odd|even` lines

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

private func kind(ofExtension ext: String) -> String? {
    kindExtensions.first { $0.exts.contains(ext) }?.kind
}

/// The picture type each photo extension must really be (ImageIO reads the bytes, not the name).
private let pictureType: [String: String] = [
    "jpeg": "public.jpeg", "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic",
    "webp": "org.webmproject.webp", "tiff": "public.tiff", "tif": "public.tiff", "gif": "com.compuserve.gif",
]

/// The exact rows whose expected file is a picture, worked out by hand from answers.csv: exact-01 to exact-04 are the
/// four `screenshot-only` pngs, exact-07 is a jpg and exact-08 a png by file name; exact-05, -06, -14, -15, -16 and -19
/// are pdfs, -09 and -20 audio, -10 video, -11 to -13, -17 and -18 documents (six of 20 are readable with photos only).
private let photoReadableExact = ["exact-01", "exact-02", "exact-03", "exact-04", "exact-07", "exact-08"]
private let photoAndPdfReadableExact = [
    "exact-01", "exact-02", "exact-03", "exact-04", "exact-05", "exact-06", "exact-07", "exact-08",
    "exact-14", "exact-15", "exact-16", "exact-19",
]
private let audioVideoDocumentReadableExact = [
    "exact-09", "exact-10", "exact-11", "exact-12", "exact-13", "exact-17", "exact-18", "exact-20",
]

// MARK: the key (read, never changed)

private struct Answer: Sendable {
    let id: String
    let group: String
    let query: String
    let file: String
    let locator: String
    var ext: String { (file as NSString).pathExtension.lowercased() }
}

private let answers: [Answer] = {
    let path = projectRoot.appendingPathComponent("fixtures/answers.csv").path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var rows: [Answer] = []
    for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where i > 0 {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7 else { continue }
        rows.append(Answer(id: f[0], group: f[1], query: f[2], file: f[3], locator: f[4]))
    }
    return rows
}()
private let exactRows = answers.filter { $0.group == "exact" }

/// The golden photos' file names, from the hand-written scene table.
private let goldenPaths: [String] = {
    let path = projectRoot.appendingPathComponent("scripts/kit-lib/golden-photos.tsv").path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        .compactMap { $0.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init) }
}()

private func words(_ s: String) -> [String] {
    s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

/// Every word of every `exact` query and of every golden file name (the name without its extension).
private let keyWords: Set<String> = {
    var set = Set<String>()
    for r in exactRows { set.formUnion(words(r.query)) }
    for p in goldenPaths {
        let name = (p as NSString).lastPathComponent
        set.formUnion(words((name as NSString).deletingPathExtension))
    }
    return set
}()

private func readableIds(kinds: Set<String>) -> [String] {
    exactRows.filter { kind(ofExtension: $0.ext).map(kinds.contains) ?? false }.map(\.id)
}

// MARK: running things

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(
    _ exe: String, _ args: [String], env: [String: String] = [:], input: String? = nil, limit: TimeInterval = 600
) throws -> Ran {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("kitgs3-out-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    defer { try? fm.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    var inFile: URL?
    defer { if let f = inFile { try? fm.removeItem(at: f) } }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    if let input {
        let f = fm.temporaryDirectory.appendingPathComponent("kitgs3-in-" + UUID().uuidString)
        try Data(input.utf8).write(to: f)
        inFile = f
        p.standardInput = try FileHandle(forReadingFrom: f)
    } else {
        p.standardInput = FileHandle.nullDevice
    }
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
private let goldenScript = projectRoot.appendingPathComponent("scripts/kit-golden.sh").path
private let goldenLib = projectRoot.appendingPathComponent("scripts/kit-lib/golden.sh").path

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
    var unrelated: String { fixtures + "/unrelated" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome,
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
}

private func makeRoot(tools: Bool = true) throws -> Root {
    _ = cleanupRegistered
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-gs3-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let base = made.resolvingSymlinksInPath().path
    let root = Root(base: base, kit: base + "/sesame-kit-gs3", tmp: base + "/tmp", decoyHome: base + "/decoy-home")
    try fm.createDirectory(atPath: root.kit + "/run", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root.tmp, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root.decoyHome, withIntermediateDirectories: true)
    if tools, let seed = toolSeed, fm.fileExists(atPath: seed.kit + "/run/bin") {
        try fm.copyItem(atPath: seed.kit + "/run/bin", toPath: root.kit + "/run/bin")
    }
    cleanup.add(root.base)
    return root
}

/// One KIT_ROOT where the fixture tool is compiled once (by a small filler build), for every test to copy.
private let toolSeed: Root? = {
    guard let root = try? makeRoot(tools: false) else { return nil }
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

/// Runs `body` in a bash child that has sourced common.sh and golden.sh (the golden kit's helpers); `kitLib`, when
/// given, replaces KIT_LIB after the sourcing, so the helpers read read-kinds.txt and extensions.txt from there.
private func sourced(_ body: String, kitLib: String? = nil, input: String? = nil, env: [String: String] = [:]) throws -> Ran {
    let kitRoot = FileManager.default.temporaryDirectory.path + "/sesame-kit-gs3-sourced"
    let script = """
        . "$1/scripts/kit-lib/common.sh" || exit 90
        . "$1/scripts/kit-lib/golden.sh" || exit 91
        [ -z "$2" ] || KIT_LIB="$2"
        \(body)
        """
    var environment = ["KIT_ROOT": kitRoot, "TMPDIR": FileManager.default.temporaryDirectory.path + "/"]
    for (k, v) in env { environment[k] = v }
    return try run("/bin/bash", ["-c", script, "bash", projectRoot.path, kitLib ?? ""], env: environment, input: input, limit: 120)
}

/// A folder that holds a read-kinds.txt of the given kinds and the spec's extension lists written by hand.
private func kitLibFolder(kinds: [String]) throws -> String {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("kit-gs3-lib-" + UUID().uuidString).path
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    cleanup.add(dir)
    try Data(kinds.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: dir + "/read-kinds.txt"))
    let ext = kindExtensions.map { "\($0.kind): \($0.exts.joined(separator: " "))\n" }.joined()
    try Data(ext.utf8).write(to: URL(fileURLWithPath: dir + "/extensions.txt"))
    return dir
}

private func tempFile(_ text: String) throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("kit-gs3-file-" + UUID().uuidString).path
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    cleanup.add(path)
    return path
}

// MARK: reading folders and pictures

private func exists(_ path: String) -> Bool {
    var st = Darwin.stat()
    return lstat(path, &st) == 0
}

private func isRegular(_ path: String) -> Bool {
    var st = Darwin.stat()
    return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
}

/// Every entry that is not a folder under dir (hidden ones too), relative, sorted.
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

private func sha(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
}

private struct Entry: Equatable {
    let inode: UInt64
    let mtimeNs: Int64
    let digest: String
}

private func snapshot(_ dir: String) -> [String: Entry] {
    var snap: [String: Entry] = [:]
    for rel in entriesIn(dir) {
        var st = Darwin.stat()
        guard lstat(dir + "/" + rel, &st) == 0 else { continue }
        snap[rel] = Entry(
            inode: UInt64(st.st_ino),
            mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
            digest: sha(dir + "/" + rel) ?? "")
    }
    return snap
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

private func unrelName(_ k: Int) -> String { String(format: "unrel%04d", k) }

/// Checks the shape of a built unrelated folder: exactly `names` (stems), flat, each a small decodable picture of the
/// type its extension names. Returns the problems found, empty when it is right.
private func unrelatedProblems(_ root: Root, count n: Int) -> [String] {
    var problems: [String] = []
    let top = ((try? FileManager.default.contentsOfDirectory(atPath: root.unrelated)) ?? []).sorted()
    let entries = entriesIn(root.unrelated)
    if top != entries { problems.append("the folder is not flat or holds a folder: \(top.prefix(5)) vs \(entries.prefix(5))") }
    if entries.count != n { problems.append("expected \(n) files, found \(entries.count)") }
    let stems = Set(entries.map { ($0 as NSString).deletingPathExtension })
    let want = Set((1...max(n, 1)).map(unrelName)).filter { _ in n > 0 }
    if stems != want {
        problems.append("names differ from unrel0001...unrel\(String(format: "%04d", n)): extra \(stems.subtracting(want).sorted().prefix(3)), missing \(want.subtracting(stems).sorted().prefix(3))")
    }
    for rel in entries {
        let ext = (rel as NSString).pathExtension.lowercased()
        let path = root.unrelated + "/" + rel
        guard let want = pictureType[ext] else { problems.append("\(rel): .\(ext) is not a photo extension"); continue }
        guard isRegular(path), let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else {
            problems.append("\(rel): not a regular file"); continue
        }
        if size <= 0 || size >= 256_000 { problems.append("\(rel): \(size) bytes is not a small photo") }
        let pic = picture(path)
        if !pic.decodes { problems.append("\(rel): does not decode as a picture"); continue }
        if pic.type != want { problems.append("\(rel): is \(pic.type ?? "nothing"), the name says \(want)") }
        if pic.width < 8 || pic.width > 256 || pic.height < 8 || pic.height > 256 {
            problems.append("\(rel): \(pic.width) x \(pic.height) is not small")
        }
    }
    return problems
}

// MARK: the golden kit

@Suite("KitGoldenSlice3Tests")
struct KitGoldenSlice3Tests {
    // ---- the table the key gives, and read-kinds.txt

    @Test("the key is read: 20 exact rows, and the hand-written list of readable rows is what answers.csv says")
    func theKeyAndTheHandList() {
        #expect(exactRows.count == 20, "answers.csv gave \(exactRows.count) exact rows")
        #expect(readableIds(kinds: ["photo"]) == photoReadableExact, "hand list of photo rows differs from answers.csv: \(readableIds(kinds: ["photo"]))")
        #expect(readableIds(kinds: ["photo", "pdf"]) == photoAndPdfReadableExact)
        #expect(readableIds(kinds: ["audio", "video", "document"]) == audioVideoDocumentReadableExact)
        #expect(goldenPaths.count == 40, "golden-photos.tsv gave \(goldenPaths.count) paths")
    }

    @Test("scripts/kit-lib/read-kinds.txt exists and is five lines: photo, document, pdf, audio, video")
    func readKindsFile() {
        let path = projectRoot.appendingPathComponent("scripts/kit-lib/read-kinds.txt").path
        let text = FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
        #expect(text == "photo\ndocument\npdf\naudio\nvideo\n", "scripts/kit-lib/read-kinds.txt holds \(text.map { "\"\($0)\"" } ?? "nothing (the file is missing)")")
    }

    @Test("the three scripts parse: bash -n on kit-fixtures.sh, kit-golden.sh and kit-lib/golden.sh")
    func scriptsParse() throws {
        for path in [fixturesScript, goldenScript, goldenLib] {
            let r = try run("/bin/bash", ["-n", path])
            #expect(r.status == 0, "bash -n \(path) exited \(r.status):\n\(r.output)")
        }
    }

    // ---- golden.sh helpers, sourced in a child shell

    @Test("golden_built is true for group a and for group b")
    func goldenBuilt() throws {
        let a = try sourced("golden_built a")
        #expect(a.status == 0, "golden_built a: status \(a.status):\n\(a.output)")
        let b = try sourced("golden_built b")
        #expect(b.status == 0, "golden_built b is false (status \(b.status)):\n\(b.output)")
    }

    @Test("golden_rows b with the real read-kinds.txt (photo) is exact-01 to exact-04, exact-07 and exact-08 with their key fields")
    func rowsBPhotoOnly() throws {
        let r = try sourced("golden_rows b")
        #expect(r.status == 0, "golden_rows b: status \(r.status):\n\(r.output)")
        let rows = r.lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows.map { $0.first ?? "" } == photoReadableExact, "golden_rows b gave \(rows.map { $0.first ?? "" }):\n\(r.output)")
        for f in rows where f.count == 4 {
            guard let a = exactRows.first(where: { $0.id == f[0] }) else { continue }
            #expect(f[1] == a.query && f[2] == a.file && f[3] == a.locator, "\(f[0]): fields \(f) differ from the key")
        }
        #expect(rows.allSatisfy { $0.count == 4 }, "a row of golden_rows does not have four tab-separated fields:\n\(r.output)")
    }

    // Amended in plan-4-t2 (it was `rowsBFollowReadKinds`: group b followed read-kinds.txt, so photo and pdf gave twelve rows
    // and every kind gave all twenty). From plan 4 the pdf and document rows are group c's (the exact rows with a PDF or a
    // document go to group c's exact part), so group b is a photo-only selection of its own and read-kinds.txt, which now
    // lists document and pdf, must not change it. The pin is stricter, not weaker: whatever read-kinds.txt says, group b is
    // exactly the six photo rows, in the key's order.
    @Test("golden_rows b is the six photo rows whatever read-kinds.txt lists: photo and pdf, audio and video and document, every kind, code only, nothing")
    func rowsBArePhotoOnlyWhateverReadKindsSays() throws {
        let cases: [(kinds: [String], want: [String])] = [
            (["photo", "pdf"], photoReadableExact),
            (["audio", "video", "document"], photoReadableExact),
            (["photo", "document", "audio", "video", "pdf", "code"], photoReadableExact),
            (["code"], photoReadableExact),
            ([], photoReadableExact),
        ]
        for c in cases {
            let lib = try kitLibFolder(kinds: c.kinds)
            let r = try sourced("golden_rows b", kitLib: lib)
            let ids = r.lines.map { String($0.split(separator: "\t", omittingEmptySubsequences: false).first ?? "") }
            #expect(ids == c.want, "read-kinds \(c.kinds): golden_rows b gave \(ids), expected the six photo rows \(c.want):\n\(r.output)")
        }
    }

    @Test("golden_rows a still gives the 10 photo rows")
    func rowsAUnchanged() throws {
        let r = try sourced("golden_rows a")
        let ids = r.lines.map { String($0.split(separator: "\t", omittingEmptySubsequences: false).first ?? "") }
        #expect(ids == (1...10).map { String(format: "photo-%02d", $0) }, "golden_rows a gave \(ids):\n\(r.output)")
    }

    @Test("golden_key_rows counts the key's rows of the group, readable or not: a 10, b 20")
    func keyRows() throws {
        let a = try sourced("golden_key_rows a")
        #expect(a.lines == ["10"], "golden_key_rows a gave \(a.lines)")
        let b = try sourced("golden_key_rows b")
        #expect(b.lines == ["20"], "golden_key_rows b gave \(b.lines)")
        let lib = try kitLibFolder(kinds: ["photo"])
        let bPhoto = try sourced("golden_key_rows b", kitLib: lib)
        #expect(bPhoto.lines == ["20"], "the key's total does not depend on read-kinds: \(bPhoto.lines)")
    }

    @Test("golden_read_kinds prints the kinds of read-kinds.txt, comma separated")
    func readKindsList() throws {
        let real = try sourced("golden_read_kinds")
        #expect(real.lines == ["photo,document,pdf,audio,video"], "golden_read_kinds gave \(real.lines)")
        let lib = try kitLibFolder(kinds: ["photo", "pdf"])
        let two = try sourced("golden_read_kinds", kitLib: lib)
        #expect(two.lines == ["photo,pdf"], "golden_read_kinds for photo and pdf gave \(two.lines)")
    }

    // ---- the odd and even split

    private func engineTsv(_ rows: [(id: String, group: String, rank: String)]) -> String {
        var text = "id\tgroup\tquery\texpected\trank\tlocator\tpass\n"
        for r in rows {
            let pass: String
            switch Int(r.rank) {
            case 1: pass = "first"
            case 2, 3: pass = "top3"
            default: pass = "miss"
            }
            text += "\(r.id)\t\(r.group)\tq\tf\t\(r.rank)\t\t\(pass)\n"
        }
        return text
    }

    private func oddEven(_ rows: [(id: String, group: String, rank: String)], letter: String) throws -> Ran {
        let path = try tempFile(engineTsv(rows))
        return try sourced("golden_oddeven \"$TSV\" \"$LETTER\"", env: ["TSV": path, "LETTER": letter])
    }

    @Test("golden_oddeven: equal, one fewer and the reverse print the counts only; two fewer adds noted: overfitting risk")
    func oddEvenSplit() throws {
        let noise: [(id: String, group: String, rank: String)] = [("photo-01", "a", "none"), ("photo-02", "a", "none")]
        func b(_ ranks: [String]) -> [(id: String, group: String, rank: String)] {
            zip(["exact-01", "exact-02", "exact-03", "exact-04", "exact-07", "exact-08"], ranks).map { ($0, "b", $1) }
        }
        let cases: [(name: String, rows: [(id: String, group: String, rank: String)], letter: String, want: [String])] = [
            ("equal", noise + b(["1", "1", "1", "1", "1", "1"]), "b", ["odd first 3 of 3, even first 3 of 3"]),
            ("one fewer", noise + b(["1", "1", "1", "1", "1", "2"]), "b", ["odd first 3 of 3, even first 2 of 3"]),
            ("two fewer", noise + b(["1", "1", "1", "none", "1", "5"]), "b",
             ["odd first 3 of 3, even first 1 of 3", "noted: overfitting risk"]),
            ("odd fewer", noise + b(["2", "1", "3", "1", "1", "1"]), "b", ["odd first 1 of 3, even first 3 of 3"]),
            ("the other group is not counted",
             [("photo-01", "a", "1"), ("photo-02", "a", "1"), ("photo-03", "a", "1"), ("photo-04", "a", "none"),
              ("photo-05", "a", "1"), ("photo-06", "a", "none"), ("photo-07", "a", "1"), ("photo-08", "a", "none"),
              ("photo-09", "a", "1"), ("photo-10", "a", "none")] + b(["1", "1", "1", "1", "1", "1"]),
             "a", ["odd first 5 of 5, even first 1 of 5", "noted: overfitting risk"]),
        ]
        for c in cases {
            let r = try oddEven(c.rows, letter: c.letter)
            #expect(r.status == 0, "\(c.name): status \(r.status):\n\(r.output)")
            #expect(r.lines == c.want, "\(c.name): got \(r.lines), expected \(c.want)")
        }
    }

    @Test("golden_oddeven splits by the number in the row id, not by the place in the file")
    func oddEvenByIdNumber() throws {
        // by id: odd = 03 and 05 (both first), even = 02 (first) and 04 (second). By place in the file it would be the reverse.
        let rows: [(id: String, group: String, rank: String)] = [
            ("exact-02", "b", "1"), ("exact-03", "b", "1"), ("exact-04", "b", "2"), ("exact-05", "b", "1"),
        ]
        let r = try oddEven(rows, letter: "b")
        #expect(r.lines == ["odd first 2 of 2, even first 1 of 2"], "got \(r.lines)")
    }

    // ---- the verdict line of group b

    private func lineB(_ mode: String, _ readable: Int, _ first: Int, _ total: Int) throws -> Ran {
        try sourced("golden_line_b \(mode) \(readable) \(first) \(total)")
    }

    @Test("the group b verdict: every readable row first is PASS, one short is FAIL, nothing readable is FAIL")
    func verdictLine() throws {
        let cases: [(mode: String, readable: Int, first: Int, total: Int, status: Int32, line: String)] = [
            ("engine", 6, 6, 20, 0, "GOLDEN engine group b: first 6 of 6 readable (20 rows in the key), need every readable row first: PASS"),
            ("engine", 6, 5, 20, 1, "GOLDEN engine group b: first 5 of 6 readable (20 rows in the key), need every readable row first: FAIL"),
            ("engine", 6, 0, 20, 1, "GOLDEN engine group b: first 0 of 6 readable (20 rows in the key), need every readable row first: FAIL"),
            ("panel", 6, 6, 20, 0, "GOLDEN panel group b: first 6 of 6 readable (20 rows in the key), need every readable row first: PASS"),
            ("engine", 12, 12, 20, 0, "GOLDEN engine group b: first 12 of 12 readable (20 rows in the key), need every readable row first: PASS"),
            ("engine", 12, 11, 20, 1, "GOLDEN engine group b: first 11 of 12 readable (20 rows in the key), need every readable row first: FAIL"),
            ("engine", 0, 0, 20, 1, "GOLDEN engine group b: first 0 of 0 readable (20 rows in the key), need every readable row first: FAIL"),
        ]
        for c in cases {
            let r = try lineB(c.mode, c.readable, c.first, c.total)
            #expect(r.lines == [c.line], "\(c.mode) \(c.readable) \(c.first) \(c.total): got \(r.lines), expected [\(c.line)]")
            #expect(r.status == c.status, "\(c.mode) \(c.readable) \(c.first) \(c.total): status \(r.status), expected \(c.status)")
        }
    }

    @Test("when every kind is read the spec's bar applies: 19 of 20 first is PASS, 18 of 20 is FAIL")
    func verdictFullRead() throws {
        let pass = try lineB("engine", 20, 19, 20)
        #expect(pass.status == 0, "19 of 20 readable first must pass the spec's bar: status \(pass.status): \(pass.lines)")
        #expect(pass.lines.count == 1 && pass.lines[0].hasPrefix("GOLDEN engine group b: first 19 of 20 readable (20 rows in the key), need ")
                && pass.lines[0].hasSuffix(": PASS"), "got \(pass.lines)")
        let fail = try lineB("engine", 20, 18, 20)
        #expect(fail.status == 1, "18 of 20 readable first must fail: status \(fail.status): \(fail.lines)")
        #expect(fail.lines.count == 1 && fail.lines[0].hasSuffix(": FAIL"), "got \(fail.lines)")
    }

    // ---- why a row has no rank, and the RANK lines of merge

    @Test("a group with no test yet says `no group b test yet`; a test that did not build says its last error line; else no GOLDEN line")
    func noTestReason() throws {
        let cases: [(letter: String, output: String, want: String)] = [
            ("b", "error: No matching test cases were run\n", "no group b test yet"),
            ("b", "Test run with 0 tests in 0 suites passed after 0.001 seconds.\n", "no group b test yet"),
            ("b", "Test Suite 'All tests' passed.\n\t Executed 0 tests, with 0 failures (0 unexpected)\n", "no group b test yet"),
            ("a", "error: No matching test cases were run\n", "no group a test yet"),
            ("b", "Sources/X.swift:3:5: error: cannot find 'Foo' in scope\nerror: fatalError\n",
             "GroupBTests did not build or run: error: fatalError"),
            ("b", "Test run with 30 tests in 1 suite passed after 1.0 seconds.\n", "GroupBTests printed no GOLDEN line for this row"),
            ("a", "Test run with 30 tests in 1 suite passed after 1.0 seconds.\n", "GroupATests printed no GOLDEN line for this row"),
        ]
        for c in cases {
            let r = try sourced("golden_none_why \"$LETTER\"", input: c.output, env: ["LETTER": c.letter])
            #expect(r.lines == [c.want], "letter \(c.letter), output \"\(c.output.prefix(60))\": got \(r.lines), expected [\(c.want)]")
        }
    }

    @Test("golden_rank_lines prints every well-formed RANK <id> <n|none> odd|even line and nothing else")
    func rankLines() throws {
        let output = """
            Building for debugging...
            RANK exact-01 1 odd
            Test case 'MergeTests/decoys' started
            RANK exact-02 none even
            RANK exact-03 x odd
            RANK exact-04 2 weird
            rank exact-05 1 odd
            RANK exact-02 3 even
            Test run with 4 tests passed

            """
        let r = try sourced("golden_rank_lines", input: output)
        #expect(r.lines == ["RANK exact-01 1 odd", "RANK exact-02 none even", "RANK exact-02 3 even"],
                "golden_rank_lines gave \(r.lines)")
    }

    // ---- kit-golden.sh text

    @Test("kit-golden.sh runs GroupBTests, MergeTests and ExtensionsTests and the extension check through the helpers; merge and extensions are no longer stubs")
    func goldenScriptText() {
        let text = (FileManager.default.contents(atPath: goldenScript).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
        #expect(!text.isEmpty, "scripts/kit-golden.sh could not be read")
        for needle in [
            "GroupBTests", "swift test --filter MergeTests", "swift test --filter ExtensionsTests",
            "expect extensions", "--kinds", "golden_read_kinds", "golden_rank_lines", "golden_none_why", "golden_line_b",
            "golden_oddeven",
        ] where !text.contains(needle) {
            Issue.record("scripts/kit-golden.sh does not hold `\(needle)`")
        }
        #expect(!text.contains("merge|code-only|extensions)"), "merge and extensions are still handled with code-only as `not built yet`")
        #expect(text.contains("golden_built"), "the group gate golden_built is no longer used (panel --group b needs it too)")
    }

    // ---- build unrelated

    @Test("the usage names build unrelated <n>; a missing, zero, negative, non-numeric, too large or doubled n is exit 2 and builds nothing")
    func unrelatedUsage() throws {
        let root = try makeRoot()
        let bare = try kit(root)
        #expect(bare.status == 2, "no mode: expected exit 2, got \(bare.status)")
        #expect(bare.output.contains("build unrelated"), "usage does not name build unrelated:\n\(bare.output)")
        for args in [[], ["0"], ["abc"], ["-3"], ["10000"], ["5", "6"], [""], ["3.5"]] as [[String]] {
            let r = try run("/bin/bash", [fixturesScript, "build", "unrelated"] + args, env: root.env)
            #expect(r.status == 2, "build unrelated \(args): expected exit 2, got \(r.status):\n\(r.output)")
        }
        #expect(!exists(root.unrelated), "a refused build left a fixtures/unrelated folder")
    }

    @Test("build unrelated 5 makes exactly five small decodable photos named unrel0001 to unrel0005, directly in fixtures/unrelated, under KIT_ROOT only")
    func buildFive() throws {
        let root = try makeRoot()
        let r = try kit(root, "build", "unrelated", "5")
        #expect(r.status == 0, "build unrelated 5 exited \(r.status):\n\(r.output)")
        #expect(r.output.contains("BUILT unrelated"), "first build did not print BUILT unrelated:\n\(r.output)")
        let problems = unrelatedProblems(root, count: 5)
        #expect(problems.isEmpty, "\(problems.prefix(8))")
        #expect(exists(root.fixtures + "/.metadata_never_index"), "the fixture root has no .metadata_never_index (verify.md, Starting state)")
        let home = (try? FileManager.default.contentsOfDirectory(atPath: root.decoyHome)) ?? []
        #expect(home.isEmpty, "the decoy home holds \(home)")
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: root.tmp)) ?? []).filter { !$0.hasPrefix(".") }
        #expect(left.isEmpty, "the builder left \(left) in the temp folder")
        let top = ((try? FileManager.default.contentsOfDirectory(atPath: root.kit)) ?? []).sorted()
        #expect(Set(top).isSubset(of: ["fixtures", "run"]), "the build wrote \(top) under KIT_ROOT")
    }

    @Test("the second build prints UNCHANGED and rewrites no file; a stray file or folder is removed; a deleted or changed photo is put back")
    func rebuildAndStrays() throws {
        let root = try makeRoot()
        let first = try kit(root, "build", "unrelated", "5")
        #expect(first.status == 0, "first build exited \(first.status):\n\(first.output)")
        let before = snapshot(root.unrelated)
        #expect(before.count == 5, "the first build made \(before.count) files")

        let second = try kit(root, "build", "unrelated", "5")
        #expect(second.status == 0, "second build exited \(second.status):\n\(second.output)")
        #expect(second.output.contains("UNCHANGED unrelated"), "second build did not print UNCHANGED unrelated:\n\(second.output)")
        #expect(snapshot(root.unrelated) == before, "the second build rewrote a file (inode, modified time or bytes changed)")

        let names = before.keys.sorted()
        try Data("stray".utf8).write(to: URL(fileURLWithPath: root.unrelated + "/notes.txt"))
        try FileManager.default.createDirectory(atPath: root.unrelated + "/sub", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: root.unrelated + "/" + names[0], toPath: root.unrelated + "/sub/" + names[0])
        let ext = (names[0] as NSString).pathExtension
        try FileManager.default.copyItem(atPath: root.unrelated + "/" + names[0], toPath: root.unrelated + "/unrel0006." + ext)
        try FileManager.default.removeItem(atPath: root.unrelated + "/" + names[1])
        try Data("changed".utf8).write(to: URL(fileURLWithPath: root.unrelated + "/" + names[2]))
        let third = try kit(root, "build", "unrelated", "5")
        #expect(third.status == 0, "third build exited \(third.status):\n\(third.output)")
        #expect(third.output.contains("BUILT unrelated"), "a build that changed files did not print BUILT unrelated:\n\(third.output)")
        let after = snapshot(root.unrelated)
        #expect(after.keys.sorted() == names, "after the repair the folder holds \(after.keys.sorted())")
        for n in names { #expect(after[n]?.digest == before[n]?.digest, "\(n) does not have its original bytes after the repair") }
        #expect(!exists(root.unrelated + "/sub"), "the stray folder was not removed")
        let fourth = try kit(root, "build", "unrelated", "5")
        #expect(fourth.output.contains("UNCHANGED unrelated"), "the build after the repair was not UNCHANGED:\n\(fourth.output)")
    }

    @Test("1000 unrelated photos: names, bytes, no word of the key; 5 after 1000 removes the rest; expect listing prints n paths; two roots make the same bytes")
    func thousandThenFive() throws {
        let a = try makeRoot()
        let big = try kit(a, "build", "unrelated", "1000")
        #expect(big.status == 0, "build unrelated 1000 exited \(big.status):\n\(big.output)")
        let problems = unrelatedProblems(a, count: 1000)
        #expect(problems.isEmpty, "\(problems.count) problems, first: \(problems.prefix(5))")

        let snapBig = snapshot(a.unrelated)
        #expect(Set(snapBig.values.map(\.digest)).count == snapBig.count, "two of the 1000 photos have the same bytes")

        // No word of any exact query or golden file name is a word of a name (the extension is not part of the name).
        var clash = Set<String>()
        for rel in snapBig.keys { clash.formUnion(Set(words((rel as NSString).deletingPathExtension)).intersection(keyWords)) }
        #expect(clash.isEmpty, "names share words with the key: \(clash.sorted().prefix(10))")
        // Picture only: no long word of the key is hidden in the bytes of a photo either (a comment, a title).
        let longWords = keyWords.filter { $0.count >= 6 }
        var hidden = Set<String>()
        for rel in snapBig.keys {
            guard let data = FileManager.default.contents(atPath: a.unrelated + "/" + rel) else { continue }
            let body = String(decoding: data, as: UTF8.self).lowercased()
            for w in longWords where body.contains(w) { hidden.insert("\(rel): \(w)") }
        }
        #expect(hidden.isEmpty, "words of the key are inside photo files: \(hidden.sorted().prefix(5))")

        // 5 after 1000 removes the rest and keeps the same bytes for the five that stay.
        let five = try kit(a, "build", "unrelated", "5")
        #expect(five.status == 0, "build unrelated 5 after 1000 exited \(five.status):\n\(five.output)")
        let snapFive = snapshot(a.unrelated)
        let keep = snapBig.keys.filter { Set((1...5).map(unrelName)).contains(($0 as NSString).deletingPathExtension) }.sorted()
        #expect(snapFive.keys.sorted() == keep, "after 5 the folder holds \(snapFive.count) files: \(snapFive.keys.sorted().prefix(8))")
        #expect(keep.count == 5, "the 1000 build had no unrel0001 to unrel0005")
        for n in keep { #expect(snapFive[n]?.digest == snapBig[n]?.digest, "\(n) changed bytes between the 1000 and the 5 build") }
        let problemsFive = unrelatedProblems(a, count: 5)
        #expect(problemsFive.isEmpty, "\(problemsFive.prefix(5))")

        // expect listing prints the n paths and the closing line.
        let listing = try kit(a, "expect", "listing", "unrelated")
        #expect(listing.status == 0, "expect listing unrelated exited \(listing.status):\n\(listing.output)")
        let pathLines = listing.lines.filter { $0.hasPrefix("unrel") }
        #expect(pathLines == keep, "expect listing unrelated printed \(pathLines), expected \(keep)")
        #expect(listing.lines.last == "LISTING OK unrelated: 5 paths", "closing line: \(listing.lines.last ?? "none")")

        // A second root makes the same bytes.
        let b = try makeRoot()
        let other = try kit(b, "build", "unrelated", "5")
        #expect(other.status == 0, "build unrelated 5 in a second root exited \(other.status):\n\(other.output)")
        let snapOther = snapshot(b.unrelated)
        #expect(snapOther.keys.sorted() == keep, "the second root holds \(snapOther.keys.sorted())")
        for n in keep { #expect(snapOther[n]?.digest == snapFive[n]?.digest, "\(n) differs between two roots") }
    }
}
