import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import Testing
import Vision

// plan-4-t2, tester step: kit part 1 (PDF and document fixtures, the answer key, the kinds that have a reader, golden
// group c). Written from the entry plan-4-t2 of plan-4-tasks.md, the spec (S2, S3, Fixtures), verify.md, the feature
// maps S2, S3 and S8 and the existing kit; no product source is read.
//
// Every run is a child process: kit-fixtures.sh and kit-golden.sh with their own temp KIT_ROOT (a folder named
// sesame-kit*), their own TMPDIR and a decoy HOME. No app is started, `swift test` is never nested, and
// kit-golden.sh engine|panel run only on hand-written lines through the test-only option `--from`. The files are
// checked here with independent readers (PDFKit, Vision, textutil, unzip, sqlite3); every expected value comes from the
// key (fixtures/answers.csv), the spec, or a list written here by hand, never from the kit's own tables.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `build golden-docs` makes $KIT_ROOT/fixtures/golden-docs/{pdfs,docs} (a sibling of golden, never inside it) and
//     prints BUILT golden-docs or UNCHANGED golden-docs. `build boundary` makes $KIT_ROOT/fixtures/boundary/*.pdf and
//     prints BUILT boundary or UNCHANGED boundary. Same bytes twice for every file, locked PDF included.
//   - A key `file` that starts pdfs/ or docs/ is under fixtures/golden-docs/, photos/ under fixtures/golden/, and
//     boundary/ under fixtures/ (so fixtures/boundary/).
//   - A comma cannot be inside a key field (the key has exactly seven fields), so the passage rectangle in the note of
//     a pdf row is `box=x:y:w:h` (points, origin bottom left) and the passage text is `anchor=<phrase>`; notes are
//     joined with "; ".
//   - The password of the locked PDF is `kit-locked-7`.
//   - `kit-golden.sh engine|panel --group c --from <file>` reads `GOLDEN <id> rank <n|none> page <p|none>` lines from
//     the file instead of running the tests or the panel; the per-row line is
//     `PASS|FAIL <id> query="<q>" expected=<file> rank=<n|none> page=<p|none>[: <why>]` and the summary line is
//     `GOLDEN <mode> group c: pdf first-3 <x> of 10, page right <y> of 10; doc first-3 <z> of 6; scanned first-3 <yes|no>: PASS|FAIL`.
//   - `kit-golden.sh index-state` is read-only: `INDEX GOLDEN PHOTOS ONLY: yes|no ...` for the index under KIT_ROOT.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: hand-written tables

private let lockedPassword = "kit-locked-7"
private let documentExtensions = ["txt", "md", "rtf", "docx", "html", "odt"]
private let expectedGroupSizes: [String: Int] = [
    "photo": 10, "exact": 20, "decoy": 20, "missing": 1, "pdf": 10, "doc": 6, "scanned": 1, "long60": 2, "boundary": 3,
    // plan-5-t1 (amended by the tester: the key gains the groups of slice 5, nothing before it changes): audio 8, video 8, videospeech 1
    "audio": 8, "video": 8, "videospeech": 1,
    "repodoc": 2,
]
/// The sha-256 of the header and the 51 rows the key held before plan 4 (lines 1 to 52 of answers.csv).
private let oldKeySha = "7529cb915c3ba46b70494977673db172954ee2bbabbfe801a6f0da8331edac69"
private let extdocCells = ["extdoc-txt", "extdoc-md", "extdoc-rtf", "extdoc-docx", "extdoc-html", "extdoc-odt", "extdoc-pdf"]

// MARK: the key (read, never changed)

private struct Answer: Sendable {
    let id: String
    let group: String
    let query: String
    let file: String
    let locator: String
    let note: String
    var page: Int? { Int(locator) }
    var noteParts: [String] { note.components(separatedBy: "; ") }
    var anchor: String? { noteParts.first { $0.hasPrefix("anchor=") }.map { String($0.dropFirst(7)) } }
    var box: CGRect? {
        guard let part = noteParts.first(where: { $0.hasPrefix("box=") }) else { return nil }
        let n = part.dropFirst(4).split(separator: ":").compactMap { Double($0) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
    var ext: String { (file as NSString).pathExtension.lowercased() }
}

private let keyText: String = {
    (try? String(contentsOf: projectRoot.appendingPathComponent("fixtures/answers.csv"), encoding: .utf8)) ?? ""
}()

private let answers: [Answer] = {
    var rows: [Answer] = []
    for (i, line) in keyText.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where i > 0 {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7 else { continue }
        rows.append(Answer(id: f[0], group: f[1], query: f[2], file: f[3], locator: f[4], note: f[6]))
    }
    return rows
}()

private func rows(_ group: String) -> [Answer] { answers.filter { $0.group == group } }

/// Every `.pdf` path of the key, any group.
private let keyPdfPaths: [String] = Array(Set(answers.map(\.file).filter { $0.hasSuffix(".pdf") && $0.hasPrefix("pdfs/") })).sorted()

// MARK: running things

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(
    _ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 600
) throws -> Ran {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("kitfx4-out-" + UUID().uuidString)
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
    var golden: String { fixtures + "/golden" }
    var docs: String { fixtures + "/golden-docs" }
    var boundary: String { fixtures + "/boundary" }
    var matrix: String { fixtures + "/matrix" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome,
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
}

private func makeRoot(tools: Bool = true) throws -> Root {
    _ = cleanupRegistered
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-s4-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let base = made.resolvingSymlinksInPath().path
    let root = Root(base: base, kit: base + "/sesame-kit-s4", tmp: base + "/tmp", decoyHome: base + "/decoy-home")
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

private func golden(_ root: Root, _ args: [String]) throws -> Ran {
    try run("/bin/bash", [goldenScript] + args, env: root.env, limit: 120)
}

private func builtDocs() throws -> (root: Root, built: Ran) {
    let root = try makeRoot()
    return (root, try kit(root, "build", "golden-docs"))
}

private let sharedDocs: (root: Root, built: Ran)? = try? builtDocs()

private func docsBuilt() -> (root: Root, built: Ran) {
    guard let s = sharedDocs else {
        Issue.record("could not make the shared kit root")
        return (Root(base: "", kit: "", tmp: "", decoyHome: ""), Ran(status: 127, output: ""))
    }
    return s
}

private func builtBoundary() throws -> (root: Root, built: Ran) {
    let root = try makeRoot()
    return (root, try kit(root, "build", "boundary"))
}

private let sharedBoundary: (root: Root, built: Ran)? = try? builtBoundary()

private func boundaryBuilt() -> (root: Root, built: Ran) {
    guard let s = sharedBoundary else {
        Issue.record("could not make the shared kit root")
        return (Root(base: "", kit: "", tmp: "", decoyHome: ""), Ran(status: 127, output: ""))
    }
    return s
}

private let sharedMatrix: (root: Root, built: Ran)? = {
    guard let root = try? makeRoot() else { return nil }
    guard let ran = try? kit(root, "build", "matrix") else { return nil }
    return (root, ran)
}()

// MARK: reading folders and files

private func exists(_ path: String) -> Bool {
    var st = Darwin.stat()
    return lstat(path, &st) == 0
}

/// Every entry that is not a folder under dir, relative, sorted.
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

/// Lower case, runs of white space made one space.
private func norm(_ s: String) -> String {
    s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Lower case, letters and digits only, words joined by one space (what a reading of a picture can be compared with).
private func words(_ s: String) -> [String] {
    s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

private func openPdf(_ path: String) -> PDFDocument? { PDFDocument(url: URL(fileURLWithPath: path)) }

/// The page drawn to a picture (white behind it), the way a person's viewer would.
private func renderPage(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
    let b = page.bounds(for: .mediaBox)
    let w = Int(b.width * scale), h = Int(b.height * scale)
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

/// What text recognition reads in a picture (the same recognition a person's search would run).
private func recognized(_ image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { ScanPdf.recordVisionFailure(error) }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

private func recognizedHolds(_ page: PDFPage?, _ phrase: String) -> Bool {
    guard let page, let image = renderPage(page) else { return false }
    let read = Set(words(recognized(image)))
    return words(phrase).allSatisfy(read.contains)
}

/// A document's text through the system's own readers: utf-8 for txt and md, textutil for the rest.
private func documentText(_ path: String) -> String? {
    let ext = (path as NSString).pathExtension.lowercased()
    if ext == "txt" || ext == "md" { return FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) } }
    guard let r = try? run("/usr/bin/textutil", ["-convert", "txt", "-stdout", path], limit: 60), r.status == 0 else { return nil }
    return r.output
}

/// The unique `zq` token of a matrix cell's path.
private func token(of path: String) -> String? {
    guard let r = path.range(of: #"zq[0-9]{4}"#, options: .regularExpression) else { return nil }
    return String(path[r])
}

// MARK: the tests

@Suite("KitFixturesSlice4Tests")
struct KitFixturesSlice4Tests {
    // ---- the key

    @Test("the key keeps its header and its 51 old rows byte for byte and gains pdf 10, doc 6, scanned 1, long60 2 and boundary 3")
    func theKeyGainsTheNewGroups() {
        let lines = keyText.components(separatedBy: "\n")
        #expect(lines.first == "id,group,query,file,locator,window_s,note", "the header changed: \(lines.first ?? "")")
        let old = lines.prefix(52).joined(separator: "\n") + "\n"
        let digest = SHA256.hash(data: Data(old.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == oldKeySha, "the first 52 lines of answers.csv changed (header or an old row)")
        for (i, line) in lines.enumerated() where i > 0 && !line.isEmpty {
            #expect(line.split(separator: ",", omittingEmptySubsequences: false).count == 7, "line \(i + 1) does not have 7 fields: \(line)")
        }
        var counts: [String: Int] = [:]
        for a in answers { counts[a.group, default: 0] += 1 }
        #expect(counts == expectedGroupSizes, "group sizes are \(counts.sorted { $0.key < $1.key }), expected \(expectedGroupSizes.sorted { $0.key < $1.key })")
        #expect(Set(answers.map(\.id)).count == answers.count, "a row id is used twice")
    }

    @Test("the pdf rows: the pets clause is the spec's lease row on page 7; every row names a pdfs/ file, a page, a box of four numbers and an anchor")
    func pdfRows() {
        let pdf = rows("pdf")
        let pets = pdf.filter { $0.query == "the clause about pets in the lease" }
        #expect(pets.count == 1, "the key has \(pets.count) rows for \"the clause about pets in the lease\"")
        #expect(pets.first?.file == "pdfs/lease-2024.pdf" && pets.first?.page == 7, "the pets row is \(String(describing: pets.first))")
        for r in pdf {
            #expect(r.file.hasPrefix("pdfs/") && r.ext == "pdf", "\(r.id): file \(r.file)")
            #expect((r.page ?? 0) >= 1, "\(r.id): locator \(r.locator) is not a page")
            #expect(r.box != nil, "\(r.id): the note has no box=x:y:w:h of four numbers: \(r.note)")
            if let b = r.box { #expect(b.minX >= 0 && b.minY >= 0 && b.maxX <= 612 && b.maxY <= 792 && b.width > 100 && b.height > 20, "\(r.id): box \(b) is not on a letter page") }
            #expect((r.anchor ?? "").count >= 20, "\(r.id): the note has no anchor= phrase: \(r.note)")
            #expect(!r.query.isEmpty, "\(r.id): empty query")
        }
        #expect(Set(pdf.map(\.query)).count == 10, "the 10 pdf descriptions are not distinct")
    }

    @Test("the doc rows: one per extension txt md rtf docx html odt, each a docs/ file with an anchor; scanned, long60 and boundary rows name the pages the spec says")
    func otherNewRows() {
        let docs = rows("doc")
        #expect(docs.map(\.ext).sorted() == documentExtensions.sorted(), "doc rows have the extensions \(docs.map(\.ext))")
        for r in docs {
            #expect(r.file.hasPrefix("docs/"), "\(r.id): file \(r.file)")
            #expect((r.anchor ?? "").count >= 20, "\(r.id): no anchor= phrase: \(r.note)")
        }
        let scanned = rows("scanned")
        #expect(scanned.count == 1 && scanned[0].file.hasPrefix("pdfs/") && (scanned[0].page ?? 0) >= 1 && (scanned[0].anchor ?? "").count >= 10,
                "scanned row: \(scanned)")
        let long60 = rows("long60")
        #expect(long60.map { $0.page ?? 0 }.sorted() == [12, 55], "long60 pages are \(long60.map(\.locator))")
        #expect(Set(long60.map(\.file)).count == 1 && long60.allSatisfy { $0.file.hasPrefix("pdfs/") }, "long60 rows name \(long60.map(\.file))")
        #expect(Set(long60.map(\.query)).count == 2 && long60.allSatisfy { words($0.query).count >= 2 }, "long60 strings: \(long60.map(\.query))")
        let boundary = rows("boundary")
        #expect(boundary.map { $0.page ?? 0 }.sorted() == [1, 30, 31], "boundary pages are \(boundary.map(\.locator))")
        #expect(boundary.allSatisfy { $0.file.hasPrefix("boundary/") && $0.ext == "pdf" } && Set(boundary.map(\.file)).count == 3,
                "boundary files: \(boundary.map(\.file))")
        #expect(Set(boundary.map(\.query)).count == 3, "boundary strings are not distinct: \(boundary.map(\.query))")
    }

    // ---- usage

    @Test("the usage names build golden-docs and build boundary; a stray argument is exit 2; the scripts parse")
    func usageAndSyntax() throws {
        let root = try makeRoot()
        let bare = try kit(root)
        #expect(bare.status == 2, "no mode: expected exit 2, got \(bare.status)")
        #expect(bare.output.contains("build golden-docs"), "usage does not name build golden-docs:\n\(bare.output)")
        #expect(bare.output.contains("build boundary"), "usage does not name build boundary:\n\(bare.output)")
        for mode in ["golden-docs", "boundary"] {
            let extra = try kit(root, "build", mode, "extra")
            #expect(extra.status == 2, "build \(mode) with a stray argument: expected exit 2, got \(extra.status):\n\(extra.output)")
        }
        #expect(!exists(root.docs) && !exists(root.boundary), "a refused build made a folder")
        for path in [fixturesScript, goldenScript, goldenLib] {
            let r = try run("/bin/bash", ["-n", path])
            #expect(r.status == 0, "bash -n \(path) exited \(r.status):\n\(r.output)")
        }
    }

    // ---- build golden-docs: the folder, the PDFs

    @Test("build golden-docs makes golden-docs/pdfs and golden-docs/docs next to golden, never inside it, and nothing else")
    func goldenDocsFolders() throws {
        let s = docsBuilt()
        #expect(s.built.status == 0, "build golden-docs exited \(s.built.status):\n\(s.built.output)")
        #expect(s.built.output.contains("BUILT golden-docs"), "the first build did not print BUILT golden-docs:\n\(s.built.output)")
        #expect(!exists(s.root.golden), "build golden-docs made a golden folder (it is photo-only and made by build golden)")
        let tops = Set(entriesIn(s.root.docs).map { String($0.split(separator: "/").first ?? "") })
        #expect(tops == ["pdfs", "docs"], "golden-docs holds the folders \(tops)")
        #expect(exists(s.root.fixtures + "/.metadata_never_index"), "the fixture root has no .metadata_never_index")
        let home = (try? FileManager.default.contentsOfDirectory(atPath: s.root.decoyHome)) ?? []
        #expect(home.isEmpty, "the decoy home holds \(home)")
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: s.root.tmp)) ?? []).filter { !$0.hasPrefix(".") }
        #expect(left.isEmpty, "the builder left \(left) in the temp folder")
        let top = Set((try? FileManager.default.contentsOfDirectory(atPath: s.root.kit)) ?? [])
        #expect(top.isSubset(of: ["fixtures", "run"]), "the build wrote \(top) under KIT_ROOT")
    }

    @Test("golden-docs/pdfs holds 20 pdfs: every pdf path of the key, plus one locked and one damaged file; every named file of the new groups is there")
    func twentyPdfs() {
        let s = docsBuilt()
        let pdfs = entriesIn(s.root.docs + "/pdfs")
        #expect(pdfs.allSatisfy { $0.hasSuffix(".pdf") && !$0.contains("/") }, "pdfs/ holds \(pdfs)")
        #expect(pdfs.count == 20, "pdfs/ holds \(pdfs.count) files, the spec says 20: \(pdfs)")
        for p in keyPdfPaths { #expect(exists(s.root.docs + "/" + p), "the key names \(p), which is not built") }
        for g in ["pdf", "doc", "scanned", "long60"] {
            for r in rows(g) { #expect(exists(s.root.docs + "/" + r.file), "\(r.id): \(r.file) is not under golden-docs") }
        }
        let extras = pdfs.map { "pdfs/" + $0 }.filter { !keyPdfPaths.contains($0) }
        #expect(extras.count == 2, "the pdfs the key does not name are \(extras), expected the locked one and the damaged one")
        let opened = extras.map { (path: $0, doc: openPdf(s.root.docs + "/" + $0)) }
        let locked = opened.filter { $0.doc?.isLocked == true }
        let damaged = opened.filter { $0.doc == nil || $0.doc?.pageCount == 0 }
        #expect(locked.count == 1, "locked pdfs among the extras: \(locked.map(\.path))")
        #expect(damaged.count == 1, "damaged pdfs among the extras: \(damaged.map(\.path)) (not openable)")
        for d in damaged {
            let bytes = FileManager.default.contents(atPath: s.root.docs + "/" + d.path) ?? Data()
            #expect(bytes.starts(with: Array("%PDF-".utf8)) && bytes.count > 100, "\(d.path) is not a cut pdf: \(bytes.count) bytes")
        }
    }

    @Test("the locked pdf asks for a password (empty is refused), opens with the password the test fixes and then holds a text layer")
    func lockedPdf() {
        let s = docsBuilt()
        let extras = entriesIn(s.root.docs + "/pdfs").map { "pdfs/" + $0 }.filter { !keyPdfPaths.contains($0) }
        guard let path = extras.first(where: { openPdf(s.root.docs + "/" + $0)?.isLocked == true }),
              let doc = openPdf(s.root.docs + "/" + path) else {
            Issue.record("no locked pdf among \(extras)")
            return
        }
        #expect(doc.isEncrypted, "the locked pdf is not encrypted")
        #expect(!doc.unlock(withPassword: ""), "the empty password opened the locked pdf")
        #expect(!doc.unlock(withPassword: "wrong-password"), "a wrong password opened the locked pdf")
        #expect(doc.unlock(withPassword: lockedPassword), "the password \(lockedPassword) did not open the locked pdf")
        #expect(doc.pageCount >= 1 && (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count > 20,
                "the unlocked pdf has \(doc.pageCount) pages and the text \(String(describing: doc.string))")
    }

    @Test("the pdf rows: on the page the key names, the box holds the anchor and nothing of it is on another page; the pets clause is on page 7 of the lease")
    func passagesAreInTheBox() {
        let s = docsBuilt()
        for r in rows("pdf") {
            guard let doc = openPdf(s.root.docs + "/" + r.file), let n = r.page, let box = r.box, let anchor = r.anchor else {
                Issue.record("\(r.id): \(r.file) does not open or the row lacks page, box or anchor")
                continue
            }
            #expect(doc.pageCount >= n, "\(r.id): \(r.file) has \(doc.pageCount) pages, the key names page \(n)")
            guard let page = doc.page(at: n - 1) else { continue }
            let a = norm(anchor)
            #expect(norm(page.string ?? "").contains(a), "\(r.id): page \(n) of \(r.file) does not hold \"\(anchor)\"")
            let inBox = page.selection(for: box)
            let boxText = norm(inBox?.string ?? "")
            #expect(boxText.contains(a), "\(r.id): the box \(box) does not hold \"\(anchor)\": \(boxText)")
            if let sel = inBox {
                let b = sel.bounds(for: page)
                #expect(box.insetBy(dx: -4, dy: -4).contains(b), "\(r.id): the text lies at \(b), outside the box \(box)")
            }
            for i in 0..<doc.pageCount where i != n - 1 {
                if norm(doc.page(at: i)?.string ?? "").contains(a) { Issue.record("\(r.id): the anchor is also on page \(i + 1)") }
            }
        }
        let pets = rows("pdf").first { $0.query == "the clause about pets in the lease" }
        let lease = pets.flatMap { openPdf(docsBuilt().root.docs + "/" + $0.file) }
        #expect((lease?.pageCount ?? 0) >= 8, "the lease has \(lease?.pageCount ?? 0) pages, page 7 must not be the last")
        let pageSeven = norm(lease?.page(at: 6)?.string ?? "")
        #expect(pageSeven.contains("pet"), "page 7 of the lease does not speak of pets")
    }

    @Test("every pdf that is not picture-only, locked or damaged has a text layer; the exact rows named `in the text of` have their string on their page; decoy pdfs do not hold the string")
    func textLayers() {
        let s = docsBuilt()
        let noText = Set((rows("scanned") + rows("long60")).map(\.file))
        for p in keyPdfPaths where !noText.contains(p) {
            guard let doc = openPdf(s.root.docs + "/" + p) else { Issue.record("\(p) does not open"); continue }
            #expect((doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count > 20, "\(p) has no text layer")
        }
        for r in rows("exact") where r.file.hasPrefix("pdfs/") && r.note.contains("in the text of") {
            guard let doc = openPdf(s.root.docs + "/" + r.file), let n = r.page, let page = doc.page(at: n - 1) else {
                Issue.record("\(r.id): \(r.file) page \(r.locator) is not there")
                continue
            }
            #expect(norm(page.string ?? "").contains(norm(r.query)), "\(r.id): page \(n) of \(r.file) does not hold \(r.query)")
        }
        for r in rows("decoy") where r.file.hasPrefix("pdfs/") {
            guard let doc = openPdf(s.root.docs + "/" + r.file) else { Issue.record("\(r.id): \(r.file) does not open"); continue }
            #expect(!norm(doc.string ?? "").contains(norm(r.query)), "\(r.id): the decoy \(r.file) holds the exact string \(r.query)")
        }
    }

    @Test("the 60-page pdf has no text layer, and text recognition reads the page 12 and the page 55 string from their page pictures (and not on page 1)")
    func sixtyPages() {
        let s = docsBuilt()
        let long = rows("long60")
        guard let first = long.first, let doc = openPdf(s.root.docs + "/" + first.file) else { Issue.record("the 60-page pdf does not open"); return }
        #expect(doc.pageCount == 60, "the long pdf has \(doc.pageCount) pages")
        let layered = (0..<doc.pageCount).filter { !(doc.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(layered.isEmpty, "pages with a text layer: \(layered.map { $0 + 1 })")
        for r in long {
            guard let n = r.page else { continue }
            #expect(recognizedHolds(doc.page(at: n - 1), r.query), "text recognition does not read \"\(r.query)\" on page \(n)")
            #expect(!recognizedHolds(doc.page(at: 0), r.query), "text recognition reads \"\(r.query)\" on page 1 too")
        }
        if long.count == 2, let a = long.first(where: { $0.page == 12 }), let b = long.first(where: { $0.page == 55 }) {
            #expect(!recognizedHolds(doc.page(at: 54), a.query), "the page 12 string is on page 55")
            #expect(!recognizedHolds(doc.page(at: 11), b.query), "the page 55 string is on page 12")
        }
    }

    @Test("the scanned pdf has no text layer and text recognition reads its words on the page the key names")
    func scannedPdf() {
        let s = docsBuilt()
        guard let r = rows("scanned").first, let n = r.page, let anchor = r.anchor, let doc = openPdf(s.root.docs + "/" + r.file) else {
            Issue.record("the scanned row or file is missing")
            return
        }
        #expect(doc.pageCount >= n && doc.pageCount >= 2, "the scanned pdf has \(doc.pageCount) pages, the key names page \(n)")
        #expect((doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the scanned pdf has a text layer: \(doc.string ?? "")")
        #expect(recognizedHolds(doc.page(at: n - 1), anchor), "text recognition does not read \"\(anchor)\" on page \(n)")
        #expect(!recognizedHolds(doc.page(at: 0 == n - 1 ? 1 : 0), anchor), "the words are on another page too")
    }

    // ---- build golden-docs: the documents

    @Test("golden-docs/docs holds the six documents (txt md rtf docx html odt), every docs/ file of the key; each is a real file of its format")
    func documentFormats() throws {
        let s = docsBuilt()
        let built = entriesIn(s.root.docs + "/docs")
        let keyDocs = Set(answers.map(\.file).filter { $0.hasPrefix("docs/") }.map { String($0.dropFirst(5)) })
        #expect(Set(built) == keyDocs, "docs/ holds \(built), the key names \(keyDocs.sorted())")
        #expect(Set(built.map { ($0 as NSString).pathExtension }) == Set(documentExtensions), "extensions in docs/: \(built)")
        #expect(built.count == 6, "docs/ holds \(built.count) files")
        for name in built {
            let path = s.root.docs + "/docs/" + name
            let bytes = FileManager.default.contents(atPath: path) ?? Data()
            switch (name as NSString).pathExtension {
            case "rtf": #expect(bytes.starts(with: Array("{\\rtf".utf8)), "\(name) is not rtf")
            case "docx", "odt":
                #expect(bytes.starts(with: Array("PK".utf8)), "\(name) is not a zip")
                let t = try run("/usr/bin/unzip", ["-t", path], limit: 60)
                #expect(t.status == 0, "unzip -t \(name) exited \(t.status): \(t.output)")
                let names = try run("/usr/bin/unzip", ["-Z1", path], limit: 60).lines
                if name.hasSuffix(".docx") { #expect(names.contains("word/document.xml"), "\(name) holds \(names)") }
                else {
                    #expect(names.first == "mimetype" && names.contains("content.xml"), "\(name) holds \(names)")
                    let mt = try run("/usr/bin/unzip", ["-p", path, "mimetype"], limit: 60)
                    #expect(mt.output == "application/vnd.oasis.opendocument.text", "\(name) mimetype is \(mt.output)")
                }
            case "html": #expect(String(decoding: bytes, as: UTF8.self).lowercased().contains("<html"), "\(name) is not html")
            default: #expect(String(data: bytes, encoding: .utf8) != nil, "\(name) is not utf-8")
            }
        }
    }

    @Test("each doc row: its anchor is in the extracted text of its document, with text on both sides, in about 1,000 characters; the exact rows named `in the text of` hold their string; decoy documents do not")
    func documentsHoldTheirAnchors() {
        let s = docsBuilt()
        for r in rows("doc") {
            let path = s.root.docs + "/" + r.file
            guard let anchor = r.anchor, let text = documentText(path) else { Issue.record("\(r.id): \(r.file) cannot be read"); continue }
            let t = norm(text)
            #expect(t.count >= 800 && t.count <= 1500, "\(r.id): \(r.file) holds \(t.count) characters, about 1,000 are expected")
            guard let range = t.range(of: norm(anchor)) else { Issue.record("\(r.id): the anchor \"\(anchor)\" is not in \(r.file): \(t.prefix(200))"); continue }
            let before = t.distance(from: t.startIndex, to: range.lowerBound)
            let after = t.distance(from: range.upperBound, to: t.endIndex)
            #expect(before >= 150 && after >= 150, "\(r.id): \(r.file) has \(before) characters before the anchor and \(after) after it")
            #expect(!r.query.isEmpty && !t.contains(norm(r.query)), "\(r.id): the description is copied into the document")
        }
        for r in rows("exact") where r.file.hasPrefix("docs/") && r.note.contains("in the text of") {
            let text = documentText(s.root.docs + "/" + r.file) ?? ""
            #expect(norm(text).contains(norm(r.query)), "\(r.id): \(r.file) does not hold \(r.query)")
        }
        for r in rows("decoy") where r.file.hasPrefix("docs/") {
            let text = documentText(s.root.docs + "/" + r.file) ?? ""
            #expect(!text.isEmpty && !norm(text).contains(norm(r.query)), "\(r.id): the decoy \(r.file) is empty or holds \(r.query)")
        }
    }

    @Test("expect listing golden-docs prints the 26 pdf and document paths")
    func listing() throws {
        let s = docsBuilt()
        let r = try kit(s.root, "expect", "listing", "golden-docs")
        #expect(r.status == 0, "expect listing golden-docs exited \(r.status):\n\(r.output)")
        #expect(r.lines.last == "LISTING OK golden-docs: 26 paths", "closing line: \(r.lines.last ?? "none")")
    }

    // ---- same bytes twice

    @Test("same bytes twice: the second build prints UNCHANGED and rewrites no file; a deleted file is rebuilt, a changed one put back, a stray file and folder removed")
    func rebuildAndStrays() throws {
        let (root, first) = try builtDocs()
        #expect(first.status == 0, "first build exited \(first.status):\n\(first.output)")
        let before = snapshot(root.docs)
        #expect(before.count == 26, "the first build made \(before.count) files")
        let second = try kit(root, "build", "golden-docs")
        #expect(second.status == 0, "second build exited \(second.status):\n\(second.output)")
        #expect(second.output.contains("UNCHANGED golden-docs"), "second build did not print UNCHANGED golden-docs:\n\(second.output)")
        var changed: [String] = []
        let afterSecond = snapshot(root.docs)
        for (rel, was) in before where afterSecond[rel] != was { changed.append(rel) }
        #expect(afterSecond.count == before.count && changed.isEmpty, "the second build rewrote or changed \(changed.prefix(10))")

        let names = before.keys.sorted()
        let gone = names.first { $0.hasPrefix("pdfs/") } ?? ""
        let docName = names.first { $0.hasPrefix("docs/") } ?? ""
        try FileManager.default.removeItem(atPath: root.docs + "/" + gone)
        try Data("stray".utf8).write(to: URL(fileURLWithPath: root.docs + "/pdfs/stray.pdf"))
        try FileManager.default.createDirectory(atPath: root.docs + "/stray-folder", withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: URL(fileURLWithPath: root.docs + "/stray-folder/a.txt"))
        try Data("changed".utf8).write(to: URL(fileURLWithPath: root.docs + "/" + docName))
        let third = try kit(root, "build", "golden-docs")
        #expect(third.status == 0, "third build exited \(third.status):\n\(third.output)")
        #expect(third.output.contains("BUILT golden-docs"), "a build that changed files did not print BUILT golden-docs:\n\(third.output)")
        let after = snapshot(root.docs)
        #expect(after.keys.sorted() == names, "after the repair the folder holds \(after.keys.sorted())")
        #expect(after[gone]?.digest == before[gone]?.digest, "the deleted \(gone) was not rebuilt with the same bytes")
        #expect(after[docName]?.digest == before[docName]?.digest, "the changed \(docName) was not put back")
        #expect(!exists(root.docs + "/stray-folder"), "the stray folder was not removed")
        #expect(try kit(root, "build", "golden-docs").output.contains("UNCHANGED golden-docs"), "the build after the repair was not UNCHANGED")
    }

    @Test("two kit roots make identical bytes for every file of golden-docs (the locked pdf too), and the build in the second root leaves golden alone")
    func twoRootsMakeTheSameBytes() throws {
        let s = docsBuilt()
        let (other, built) = try builtDocs()
        #expect(built.status == 0, "build golden-docs exited \(built.status):\n\(built.output)")
        let a = snapshot(s.root.docs), b = snapshot(other.docs)
        #expect(a.keys.sorted() == b.keys.sorted(), "the two roots hold different files")
        var differ: [String] = []
        for (rel, entry) in a where b[rel]?.digest != entry.digest { differ.append(rel) }
        #expect(differ.isEmpty, "bytes differ between two builds: \(differ)")
    }

    // ---- build golden stays photo-only

    @Test("build golden still makes only the 40 photos under golden/photos; building golden-docs after it adds a sibling and leaves golden as it was")
    func goldenStaysPhotoOnly() throws {
        let root = try makeRoot()
        let g = try kit(root, "build", "golden")
        #expect(g.status == 0, "build golden exited \(g.status):\n\(g.output)")
        let before = snapshot(root.golden)
        #expect(before.count == 40 && before.keys.allSatisfy { $0.hasPrefix("photos/") && !$0.dropFirst(7).contains("/") },
                "golden holds \(before.count) files: \(before.keys.sorted().filter { !$0.hasPrefix("photos/") })")
        #expect(before.keys.allSatisfy { !$0.hasSuffix(".pdf") && !["txt", "md", "rtf", "docx", "html", "odt"].contains(($0 as NSString).pathExtension) },
                "golden holds a pdf or a document")
        let d = try kit(root, "build", "golden-docs")
        #expect(d.status == 0, "build golden-docs exited \(d.status):\n\(d.output)")
        #expect(snapshot(root.golden) == before, "building golden-docs changed golden")
        #expect(entriesIn(root.docs).count == 26, "golden-docs holds \(entriesIn(root.docs).count) files")
        let again = try kit(root, "build", "golden")
        #expect(again.output.contains("UNCHANGED golden"), "build golden after golden-docs was not UNCHANGED:\n\(again.output)")
    }

    // ---- build boundary

    @Test("build boundary makes fixtures/boundary with three pdfs of 1, 30 and 31 pages, the key's string on the last page of each and on no other page")
    func boundaryPdfs() throws {
        let s = boundaryBuilt()
        #expect(s.built.status == 0, "build boundary exited \(s.built.status):\n\(s.built.output)")
        #expect(s.built.output.contains("BUILT boundary"), "the first build did not print BUILT boundary:\n\(s.built.output)")
        let built = entriesIn(s.root.boundary)
        #expect(built.count == 3 && built.allSatisfy { $0.hasSuffix(".pdf") && !$0.contains("/") }, "boundary holds \(built)")
        #expect(!exists(s.root.golden) && !exists(s.root.docs), "build boundary made golden or golden-docs")
        for r in rows("boundary") {
            guard let n = r.page, let doc = openPdf(s.root.fixtures + "/" + r.file) else { Issue.record("\(r.id): \(r.file) does not open"); continue }
            #expect(doc.pageCount == n, "\(r.id): \(r.file) has \(doc.pageCount) pages, expected \(n)")
            let lastPage = norm(doc.page(at: n - 1)?.string ?? "")
            #expect(lastPage.contains(norm(r.query)), "\(r.id): the last page does not hold \"\(r.query)\"")
            for i in 0..<max(n - 1, 0) where norm(doc.page(at: i)?.string ?? "").contains(norm(r.query)) {
                Issue.record("\(r.id): the string is also on page \(i + 1)")
            }
        }
        #expect(Set(built.map { String($0) }) == Set(rows("boundary").map { String($0.file.dropFirst("boundary/".count)) }),
                "boundary holds \(built), the key names \(rows("boundary").map(\.file))")
    }

    @Test("build boundary twice: UNCHANGED, nothing rewritten; a deleted pdf is rebuilt, a stray file removed")
    func boundaryRepeats() throws {
        let (root, first) = try builtBoundary()
        #expect(first.status == 0, "first build exited \(first.status):\n\(first.output)")
        let before = snapshot(root.boundary)
        let second = try kit(root, "build", "boundary")
        #expect(second.output.contains("UNCHANGED boundary"), "second build did not print UNCHANGED boundary:\n\(second.output)")
        #expect(snapshot(root.boundary) == before, "the second build rewrote a file")
        let gone = before.keys.sorted()[0]
        try FileManager.default.removeItem(atPath: root.boundary + "/" + gone)
        try Data("stray".utf8).write(to: URL(fileURLWithPath: root.boundary + "/stray.txt"))
        let third = try kit(root, "build", "boundary")
        #expect(third.output.contains("BUILT boundary"), "a repair build did not print BUILT boundary:\n\(third.output)")
        let after = snapshot(root.boundary)
        #expect(after.keys.sorted() == before.keys.sorted() && after[gone]?.digest == before[gone]?.digest, "the repair is wrong: \(after.keys.sorted())")
        let (other, _) = try builtBoundary()
        let b = snapshot(other.boundary)
        #expect(b.mapValues(\.digest) == before.mapValues(\.digest), "two roots made different bytes")
    }

    // ---- the matrix cells extdoc-*

    private struct MatrixCell { let id, path, picks, inIndex, rows, reason, group: String }

    private func matrixCells() -> [MatrixCell] {
        let text = (try? String(contentsOf: projectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return f.count == 7 ? MatrixCell(id: f[0], path: f[1], picks: f[2], inIndex: f[3], rows: f[4], reason: f[5], group: f[6]) : nil
        }
    }

    @Test("gate-matrix.csv gains extdoc-txt md rtf docx html odt pdf under matrix/extdoc (yes, 1, ok, spec, a unique zq token); the eight ext- photo cells and matrix/ext are unchanged")
    func extdocCellsInTheTable() {
        let cells = matrixCells()
        let byId = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in extdocCells {
            guard let c = byId[id] else { Issue.record("the table has no cell \(id)"); continue }
            let ext = String(id.dropFirst("extdoc-".count))
            #expect(c.path.hasPrefix("extdoc/") && (c.path as NSString).pathExtension == ext && !c.path.dropFirst(7).contains("/"), "\(id): path \(c.path)")
            #expect(c.picks.isEmpty && c.inIndex == "yes" && c.rows == "1" && c.reason == "ok" && c.group == "spec", "\(id): \(c)")
            #expect(token(of: (c.path as NSString).lastPathComponent) != nil, "\(id): no zq token in the file name")
        }
        let tokens = cells.compactMap { token(of: $0.path) }
        #expect(Set(tokens).count == tokens.count, "a zq token is used twice")
        // plan-6-t1 amendment (it pinned exactly eight ext- cells, all under ext/): check_S2_17 finds a cell by the id `ext-<ext>`
        // (checks-s2c.sh, s2c_ext_cells), so the fifteen code extension cells are `ext-<ext>` too, under extcode/ and ticked for code.
        // Not weakened: the eight photo cells under ext/ are still exactly those, and matrix/ext holds nothing else.
        let ext = cells.filter { $0.id.hasPrefix("ext-") && $0.path.hasPrefix("ext/") }
        #expect(ext.count == 8, "ext- photo cells: \(ext.map(\.id))")
        let codeExt = cells.filter { $0.id.hasPrefix("ext-") && !$0.path.hasPrefix("ext/") }
        #expect(codeExt.count == 15 && codeExt.allSatisfy { $0.path.hasPrefix("extcode/") }, "ext- code cells: \(codeExt.map(\.id))")
        #expect(cells.filter { $0.path.hasPrefix("ext/") }.count == 8, "matrix/ext holds a cell that is not an ext- photo cell")
        #expect(!extdocCells.contains { id in id.hasPrefix("ext-") }, "an extdoc cell is named ext-")
    }

    @Test("build matrix makes each extdoc cell a real file of its type that holds its token (txt, md, rtf, docx, html, odt through the system's own readers, pdf in PDFKit)")
    func extdocFilesHoldTheirTokens() throws {
        guard let s = sharedMatrix else { Issue.record("could not build the matrix"); return }
        #expect(s.built.status == 0, "build matrix exited \(s.built.status):\n\(s.built.output)")
        for c in matrixCells() where extdocCells.contains(c.id) {
            let path = s.root.matrix + "/" + c.path
            guard let tok = token(of: c.path) else { continue }
            let ext = (c.path as NSString).pathExtension
            if ext == "pdf" {
                let doc = openPdf(path)
                let body = norm(doc?.string ?? "")
                #expect(doc?.pageCount == 1 && body.contains(tok), "\(c.id): the pdf does not hold \(tok)")
                continue
            }
            let text = documentText(path)
            #expect(text != nil && norm(text ?? "").contains(tok), "\(c.id): \(c.path) read as \(String(describing: text?.prefix(80))), expected \(tok)")
            let bytes = FileManager.default.contents(atPath: path) ?? Data()
            if ext == "rtf" { #expect(bytes.starts(with: Array("{\\rtf".utf8)), "\(c.id) is not rtf") }
            if ext == "docx" || ext == "odt" { #expect(try run("/usr/bin/unzip", ["-t", path], limit: 60).status == 0, "\(c.id): unzip -t failed") }
        }
        #expect(entriesIn(s.root.matrix + "/ext").count == 8, "matrix/ext holds \(entriesIn(s.root.matrix + "/ext"))")
    }

    @Test("expect extensions --kinds photo,document,pdf is exit 0 with a fixture file for every extension, once the matrix is built")
    func extensionsOfTheReadKinds() throws {
        guard let s = sharedMatrix else { Issue.record("could not build the matrix"); return }
        let r = try kit(s.root, "expect", "extensions", "--kinds", "photo,document,pdf")
        #expect(r.status == 0, "expect extensions exited \(r.status):\n\(r.output)")
        let found = Set(r.lines.compactMap { l -> String? in
            let f = l.split(separator: " ").map(String.init)
            return f.count >= 4 && f[0] == "FOUND" && f[1] == "document" ? f[2] : nil
        })
        #expect(found == Set(documentExtensions), "documents found: \(found.sorted())")
        #expect(!r.lines.contains { $0.hasPrefix("MISSING") }, "a fixture is missing:\n\(r.output)")
    }

    // ---- golden group c, on hand-written lines

    private func idNumber(_ id: String) -> Int { Int(id.split(separator: "-").last ?? "") ?? 0 }

    /// The 17 rows of group c, in key order: pdf, doc, scanned.
    private var groupC: [Answer] { rows("pdf") + rows("doc") + rows("scanned") }

    private func lineFile(_ per: (Answer) -> (rank: String, page: String)) throws -> String {
        let text = groupC.map { r in let v = per(r); return "GOLDEN \(r.id) rank \(v.rank) page \(v.page)" }.joined(separator: "\n") + "\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kitfx4-from-" + UUID().uuidString).path
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        cleanup.add(path)
        return path
    }

    private func summary(_ mode: String, pdfFirst: Int, pageRight: Int, docFirst: Int, scannedFirst: Bool, pass: Bool) -> String {
        "GOLDEN \(mode) group c: pdf first-3 \(pdfFirst) of 10, page right \(pageRight) of 10; doc first-3 \(docFirst) of 6; scanned first-3 \(scannedFirst ? "yes" : "no"): \(pass ? "PASS" : "FAIL")"
    }

    /// A group c reading with the given misses: the first `pdfMiss` pdf rows (by key order) ranked 5, the first `pageMiss`
    /// rows after them on a wrong page, `docMiss` doc rows ranked none and the scanned row at `scannedRank`.
    private func scenario(pdfMiss: Int = 0, pageMiss: Int = 0, docMiss: Int = 0, scannedRank: String = "1") -> (file: () throws -> String, pdfFirst: Int, pageRight: Int, docFirst: Int) {
        let pdf = rows("pdf"), doc = rows("doc")
        let missed = Set(pdf.prefix(pdfMiss).map(\.id))
        let wrongPage = Set(pdf.dropFirst(pdfMiss).prefix(pageMiss).map(\.id))
        let docMissed = Set(doc.prefix(docMiss).map(\.id))
        let file: () throws -> String = {
            try self.lineFile { r in
                if r.group == "pdf" {
                    if missed.contains(r.id) { return ("5", "none") }
                    if wrongPage.contains(r.id) { return ("1", String((r.page ?? 1) + 1)) }
                    return ("1", r.locator)
                }
                if r.group == "doc" { return (docMissed.contains(r.id) ? "none" : "1", "none") }
                return (scannedRank, r.locator)
            }
        }
        return (file, pdf.count - pdfMiss, pdf.count - pdfMiss - pageMiss, doc.count - docMiss)
    }

    @Test("golden_rows c and golden_key_rows c are the 17 key rows of pdf, doc and scanned, with the key's fields; group b and group a are what they were")
    func groupCRows() throws {
        let script = """
            . "$1/scripts/kit-lib/common.sh" || exit 90
            . "$1/scripts/kit-lib/golden.sh" || exit 91
            golden_rows c
            echo "KEYROWS $(golden_key_rows c)"
            echo "BOUND $(golden_rows b | cut -f1 | tr '\\n' ' ')"
            """
        let r = try run("/bin/bash", ["-c", script, "bash", projectRoot.path],
                        env: ["KIT_ROOT": FileManager.default.temporaryDirectory.path + "/sesame-kit-s4-sourced"], limit: 60)
        let lines = r.lines
        let c = lines.filter { !$0.hasPrefix("KEYROWS") && !$0.hasPrefix("BOUND") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(c.map { $0.first ?? "" } == groupC.map(\.id), "golden_rows c gave \(c.map { $0.first ?? "" }), expected \(groupC.map(\.id))")
        for (f, a) in zip(c, groupC) { #expect(f == [a.id, a.query, a.file, a.locator], "\(a.id): \(f)") }
        #expect(lines.contains("KEYROWS 17"), "golden_key_rows c: \(lines.filter { $0.hasPrefix("KEYROWS") })")
        #expect(lines.contains("BOUND exact-01 exact-02 exact-03 exact-04 exact-07 exact-08 "), "golden_rows b changed: \(lines.filter { $0.hasPrefix("BOUND") })")
    }

    @Test("a group with no test yet says `no group c test yet`; a test that did not build says its last error line")
    func noGroupCTestYet() throws {
        let script = """
            . "$1/scripts/kit-lib/common.sh" || exit 90
            . "$1/scripts/kit-lib/golden.sh" || exit 91
            printf 'error: No matching test cases were run\\n' | golden_none_why c
            printf 'Sources/X.swift:3:5: error: cannot find Foo in scope\\nerror: fatalError\\n' | golden_none_why c
            printf 'Test run with 30 tests in 1 suite passed\\n' | golden_none_why c
            """
        let r = try run("/bin/bash", ["-c", script, "bash", projectRoot.path],
                        env: ["KIT_ROOT": FileManager.default.temporaryDirectory.path + "/sesame-kit-s4-sourced"], limit: 60)
        #expect(r.lines == ["no group c test yet", "GroupCTests did not build or run: error: fatalError", "GroupCTests printed no GOLDEN line for this row"], "got \(r.lines)")
    }

    @Test("engine --group c --from: the verdict is PASS at pdf 9, page 9, doc 5 and the scanned row in the first 3, and FAIL one step below each; the line has the fixed wording")
    func groupCVerdict() throws {
        let root = try makeRoot()
        // (label, scenario, expected counts, scanned yes, pass)
        let cases: [(String, (file: () throws -> String, pdfFirst: Int, pageRight: Int, docFirst: Int), String, Bool, Bool)] = [
            ("all right", scenario(), "1", true, true),
            ("the bar exactly", scenario(pdfMiss: 1, pageMiss: 0, docMiss: 1, scannedRank: "3"), "3", true, true),
            ("page right 9 of 10", scenario(pageMiss: 1), "1", true, true),
            ("pdf first-3 8", scenario(pdfMiss: 2), "1", true, false),
            ("page right 8", scenario(pageMiss: 2), "1", true, false),
            ("doc first-3 4", scenario(docMiss: 2), "1", true, false),
            ("scanned fourth", scenario(scannedRank: "4"), "4", false, false),
            ("scanned none", scenario(scannedRank: "none"), "none", false, false),
        ]
        for (label, sc, scannedRank, scannedYes, pass) in cases {
            let file = try sc.file()
            let r = try golden(root, ["engine", "--group", "c", "--from", file])
            let expected = summary("engine", pdfFirst: sc.pdfFirst, pageRight: sc.pageRight, docFirst: sc.docFirst, scannedFirst: scannedYes, pass: pass)
            #expect(r.lines.contains(expected), "\(label): expected the line\n  \(expected)\ngot\n\(r.output)")
            #expect(r.status == (pass ? 0 : 1), "\(label): exit \(r.status), expected \(pass ? 0 : 1)")
            let panel = try golden(root, ["panel", "--group", "c", "--from", file])
            let expectedPanel = summary("panel", pdfFirst: sc.pdfFirst, pageRight: sc.pageRight, docFirst: sc.docFirst, scannedFirst: scannedYes, pass: pass)
            #expect(panel.lines.contains(expectedPanel), "\(label): panel: expected the line\n  \(expectedPanel)\ngot\n\(panel.output)")
            #expect(panel.status == (pass ? 0 : 1), "\(label): panel exit \(panel.status)")
            _ = scannedRank
        }
    }

    @Test("engine --group c --from prints one line per key row (PASS for rank 1 to 3, FAIL otherwise, with the page), the odd and even rows apart, and writes group c rows to golden-engine.tsv")
    func groupCRowLines() throws {
        let root = try makeRoot()
        let file = try lineFile { r in
            // odd numbered rows first, even numbered rows second: the odd rows hit 9 times and the even rows never
            (idNumber(r.id) % 2 == 1 ? "1" : "2", r.group == "doc" ? "none" : r.locator)
        }
        let r = try golden(root, ["engine", "--group", "c", "--from", file])
        for a in groupC {
            let rank = idNumber(a.id) % 2 == 1 ? "1" : "2"
            let prefix = "PASS \(a.id) query=\"\(a.query)\" expected=\(a.file) rank=\(rank)"
            guard let line = r.lines.first(where: { $0.hasPrefix(prefix) }) else { Issue.record("no line starting\n  \(prefix)\nin\n\(r.output)"); continue }
            #expect(line.contains(a.group == "doc" ? "page=none" : "page=\(a.locator)"), "\(a.id): \(line)")
        }
        let odd = groupC.filter { idNumber($0.id) % 2 == 1 }.count, even = groupC.count - odd
        #expect(r.lines.contains("odd first \(odd) of \(odd), even first 0 of \(even)"), "odd and even line missing:\n\(r.output)")
        #expect(r.lines.contains("noted: overfitting risk"), "the overfitting note is missing:\n\(r.output)")
        let tsv = try String(contentsOfFile: root.kit + "/run/golden-engine.tsv", encoding: .utf8)
        let cRows = tsv.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count > 2 && $0[1] == "c" }
        #expect(cRows.count == 17 && Set(cRows.map { $0[0] }) == Set(groupC.map(\.id)), "golden-engine.tsv holds \(cRows.count) group c rows")
        for f in cRows { #expect(f[4] == (idNumber(f[0]) % 2 == 1 ? "1" : "2"), "\(f[0]): rank column is \(f[4])") }

        let missing = try lineFile { _ in ("1", "1") }
        let text = (try String(contentsOfFile: missing, encoding: .utf8)).split(separator: "\n").dropFirst().joined(separator: "\n") + "\n"
        let short = FileManager.default.temporaryDirectory.appendingPathComponent("kitfx4-short-" + UUID().uuidString).path
        try Data(text.utf8).write(to: URL(fileURLWithPath: short))
        cleanup.add(short)
        let one = try golden(root, ["engine", "--group", "c", "--from", short])
        let first = groupC[0]
        #expect(one.lines.contains { $0.hasPrefix("FAIL \(first.id) ") && $0.contains("rank=none") }, "a row with no line is not a FAIL with rank none:\n\(one.output)")
        #expect(one.status == 1, "a row with no line: exit \(one.status)")
    }

    @Test("--from is for group c only: with no group or another group, or no file, it is a usage error (exit 2) and nothing runs")
    func fromUsage() throws {
        let root = try makeRoot()
        let file = try lineFile { _ in ("1", "1") }
        for args in [["engine", "--from", file], ["engine", "--group", "b", "--from", file], ["panel", "--group", "a", "--from", file],
                     ["engine", "--group", "c", "--from"], ["engine", "--group", "c", "--from", "/no/such/file"]] {
            let r = try golden(root, args)
            #expect(r.status == 2, "\(args): expected exit 2, got \(r.status):\n\(r.output)")
        }
    }

    // ---- prepare stays photo-scoped

    private func sqlite(_ db: String, _ sql: String) throws {
        let r = try run("/usr/bin/sqlite3", [db, sql], limit: 30)
        #expect(r.status == 0, "sqlite3 failed: \(r.output)")
    }

    private func indexRoot(photosDone: Int, extra: [(String, String, String)]) throws -> Root {
        let root = try makeRoot(tools: false)
        let dir = root.kit + "/home/Library/Application Support/Sesame"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let db = dir + "/index.sqlite"
        try sqlite(db, "create table files(path text primary key, kind text, status text, reason text); create table passages(id integer primary key, file text);")
        var values: [String] = []
        for i in 0..<40 {
            values.append("('\(root.fixtures)/golden/photos/p\(i).jpg','photo','\(i < photosDone ? "done" : "pending")',NULL)")
        }
        for (p, k, st) in extra { values.append("('\(root.fixtures)/\(p)','\(k)','\(st)',NULL)") }
        try sqlite(db, "insert into files values \(values.joined(separator: ","));")
        return root
    }

    @Test("index-state: the golden index is ready only when the 40 photos under golden/photos are done and the index holds no other file; a pdf or a document in it, or 39 done photos, is not")
    func shortcutNeedsOnlyThePhotos() throws {
        let cases: [(String, Int, [(String, String, String)], String)] = [
            ("40 photos only", 40, [], "yes"),
            ("with a pdf of golden-docs", 40, [("golden-docs/pdfs/lease-2024.pdf", "pdf", "done")], "no"),
            ("with a document", 40, [("golden-docs/docs/field-notes.txt", "document", "done")], "no"),
            ("39 done photos", 39, [], "no"),
        ]
        for (label, done, extra, want) in cases {
            let root = try indexRoot(photosDone: done, extra: extra)
            let r = try golden(root, ["index-state"])
            #expect(r.status == (want == "yes" ? 0 : 1), "\(label): index-state exit \(r.status):\n\(r.output)")
            #expect(r.lines.contains { $0.hasPrefix("INDEX GOLDEN PHOTOS ONLY: \(want)") }, "\(label): expected `INDEX GOLDEN PHOTOS ONLY: \(want)`:\n\(r.output)")
        }
        let empty = try makeRoot(tools: false)
        let none = try golden(empty, ["index-state"])
        #expect(none.status == 1 && none.lines.contains { $0.hasPrefix("INDEX GOLDEN PHOTOS ONLY: no") }, "no index:\n\(none.output)")
    }

    @Test("prepare still makes the helper index golden/photos (never the whole golden folder or golden-docs), and its shortcut uses the same index-state reading")
    func prepareIsPhotoScoped() {
        let text = (try? String(contentsOfFile: goldenScript, encoding: .utf8)) ?? ""
        #expect(text.contains("helper index --folders golden/photos"), "prepare does not index golden/photos")
        #expect(text.range(of: #"--folders golden(?!/photos)"#, options: .regularExpression) == nil, "a helper index call names golden or golden-docs as a whole")
        #expect(text.contains("GroupCTests"), "kit-golden.sh does not run GroupCTests for group c")
    }
}
