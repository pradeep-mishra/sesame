import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

// plan-4-t3, tester step: kit part 2, the PDF readback of scripts/kit-readback.sh (modes pdf-pages, render-pdf-page, mark-check and
// preview-page) and scripts/kit-lib/readback.swift. Written from the entry plan-4-t3 of plan-4-tasks.md, the feature maps S3 and S2,
// verify.md and the kit as it stands; no product source is read.
//
// Every run is a child process: kit-readback.sh with its own temp KIT_ROOT (a folder named sesame-kit*), its own TMPDIR and HOME. The
// test makes its own PDFs and pictures with CoreGraphics and CoreText and reads pictures back with ImageIO; every expected value is
// written here (the page counts, the rectangle the test drew, the page that carries the large number), never read from the kit. No
// app is started: the live paths (Preview's accessibility tree by osascript, the screenshot of Preview's window) are only text-checked
// at the end; the picture reading runs on a picture the test made (`--from`), the tree reading on a hand-written dump (`--tree-sample`).
//
// The interface the test fixes (the tester's picks, listed in the report):
//   - `pdf-pages <pdf>` prints the page count alone on one line (exit 1 and one line for a missing, damaged, locked or empty file).
//   - `render-pdf-page <pdf> <n> [--out <png>]` writes a PNG of page n at the fixed scale, which the output states as `scale <s>`
//     (the PNG is round(page width * s) by round(page height * s)); with no --out the file is under the kit root, and the path is in
//     the output; n out of range (0, or past the last page) exits 1.
//   - `mark-check <shot> <pdf> <page> [--answers <csv>]`: the box is the `box=x:y:w:h` (points, origin bottom left) of the row of the
//     key whose `file` ends the pdf's path and whose locator is the page (default key: the project's fixtures/answers.csv). Output
//     lines `box x y w h`, `region x y w h` (points, same origin), `pixels <n>`, `inside <fraction>`, `overlap <fraction>`; exit 0
//     when at least 50 percent of the marked pixels lie inside the box grown by 10 points and the region overlaps the box by at least
//     0.5 of its own area (and at least 200 marked pixels); exit 1 `no mark` for fewer than 200 coloured pixels on the page, exit 1 for
//     a mark that misses the box, exit 4 `no picture of page <n>` for a shot that does not hold the page; it writes
//     `compare-s3-mark.txt` (kit_evidence_dir, here $KIT_ROOT/run).
//   - `preview-page [--tree-sample <file>] [--by-picture --from <png> --pdf <file>]`: tree reading prints `page <n> via tree`
//     (exit 0), exit 4 `tree lacks the page` when the dump holds no page or two that disagree; picture reading prints
//     `page <n> via picture` and writes `readback-preview.txt`, exit 3 `NEEDS A PERSON` for a tie or a match below the threshold,
//     exit 2 for `--by-picture` with no `--pdf`.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let readbackScript = projectRoot.appendingPathComponent("scripts/kit-readback.sh").path
private let readbackSwift = projectRoot.appendingPathComponent("scripts/kit-lib/readback.swift").path

// MARK: running things

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 300) throws -> Ran {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("kitrb4-out-" + UUID().uuidString)
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

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

// MARK: the rig: one temp kit root for the whole suite (the Swift tool is compiled once, in it)

private struct Rig: Sendable {
    let base: String
    let kit: String
    let tmp: String
    let work: String
    var env: [String: String] { ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": base + "/home"] }
    var runDir: String { kit + "/run" }
}

private final class Cleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    func run() {
        lock.lock(); let all = paths; lock.unlock()
        for p in all { try? FileManager.default.removeItem(atPath: p) }
    }
}
private let cleanup = Cleanup()

private let rig: Rig = {
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kitrb4-" + UUID().uuidString, isDirectory: true)
    try? fm.createDirectory(at: made, withIntermediateDirectories: true)
    let base = made.resolvingSymlinksInPath().path
    let r = Rig(base: base, kit: base + "/sesame-kit-rb4", tmp: base + "/tmp", work: base + "/work")
    for d in [r.kit + "/run", r.tmp, r.work, base + "/home"] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    cleanup.add(base)
    atexit { cleanup.run() }
    // compile the tool once, here, so the tests that run at the same time never compile it together
    _ = try? run("/bin/bash", [readbackScript, "app-installed", "com.apple.finder"], env: r.env, limit: 300)
    return r
}()

/// kit-readback.sh with the temp kit root.
private func readback(_ args: [String], limit: TimeInterval = 300) throws -> Ran {
    guard FileManager.default.fileExists(atPath: readbackScript) else {
        Issue.record("scripts/kit-readback.sh not found")
        return Ran(status: 127, output: "")
    }
    let ran = try run("/bin/bash", [readbackScript] + args, env: rig.env, limit: limit)
    if ran.output.contains("not built yet") { Issue.record(Comment(rawValue: "kit-readback.sh \(args.first ?? "") is still `not built yet`: the mode is missing")) }
    return ran
}

private func workPath(_ name: String) -> String { rig.work + "/" + name }

// MARK: drawing: pages, PDFs, renders, pictures

private struct Rand {
    var state: UInt64
    init(_ seed: Int) { state = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 12345) }
    mutating func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
}

private func drawText(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, gray: CGFloat = 0) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

private let words = ["harbour", "ledger", "orchard", "copper", "meadow", "lantern", "quarry", "velvet", "thistle", "granite", "willow", "ember",
                     "saddle", "marble", "falcon", "tundra", "bramble", "cinder", "plover", "nectar"]

/// A letter page whose picture is unique to its number: a large number, 30 black squares and lines of words, all placed from the number.
/// `passage` (a rectangle in points, origin bottom left, and its text) is drawn where the key says; the lines of words skip that band.
private func drawPage(_ ctx: CGContext, number: Int, passage: (CGRect, String)? = nil, identical: Bool = false) {
    let n = identical ? 1 : number
    var r = Rand(n)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    drawText(ctx, String(n), x: 120, y: 90, size: 280, bold: true, gray: 0.55)
    for _ in 0..<30 {
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 40 + r.next(500), y: 40 + r.next(700), width: 16, height: 16))
    }
    var y: CGFloat = 740
    for _ in 0..<16 {
        var line: [String] = []
        for _ in 0..<7 { line.append(words[r.next(words.count)]) }
        if let (box, _) = passage, y < box.maxY + 14, y > box.minY - 26 { y -= 22; continue }
        drawText(ctx, line.joined(separator: " "), x: 40, y: y, size: 13)
        y -= 22
    }
    if let (box, text) = passage {
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        ctx.stroke(box)
        drawText(ctx, text, x: box.minX + 6, y: box.minY + box.height / 2 - 5, size: 14)
    }
}

@discardableResult
private func makePDF(_ name: String, pages: Int, passage: (page: Int, box: CGRect, text: String)? = nil, identical: Bool = false) -> String {
    let path = workPath(name)
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil) else {
        Issue.record("could not make the pdf \(name)")
        return path
    }
    for p in 1...pages {
        ctx.beginPDFPage(nil)
        var pass: (CGRect, String)?
        if let ps = passage, ps.page == p { pass = (ps.box, ps.text) }
        drawPage(ctx, number: p, passage: pass, identical: identical)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return path
}

private func srgbContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// The test's own render of a page (PDFKit), at a scale: white background, the whole media box.
private func render(_ pdf: String, page: Int, scale: CGFloat) -> CGImage {
    let doc = PDFDocument(url: URL(fileURLWithPath: pdf))!
    let pg = doc.page(at: page - 1)!
    let b = pg.bounds(for: .mediaBox)
    let ctx = srgbContext(Int((b.width * scale).rounded()), Int((b.height * scale).rounded()))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -b.origin.x, y: -b.origin.y)
    pg.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()!
}

/// `image` with an opaque yellow rectangle; `rect` is in pixels, origin bottom left.
private func marked(_ image: CGImage, rect: CGRect, color: CGColor = CGColor(srgbRed: 1, green: 0.92, blue: 0, alpha: 1)) -> CGImage {
    let ctx = srgbContext(image.width, image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.setFillColor(color)
    ctx.fill(rect)
    return ctx.makeImage()!
}

/// `base` drawn at `scale` into a larger window picture with chrome (a dark toolbar, a sidebar of thumbnail-like boxes, a gray
/// background): the page's top-left corner is `offset` pixels from the window's top-left.
private func inWindow(_ base: CGImage, scale: CGFloat, window: (w: Int, h: Int), offset: (x: Int, y: Int)) -> CGImage {
    let ctx = srgbContext(window.w, window.h)
    ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: window.w, height: window.h))
    ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: window.h - 90, width: window.w, height: 90))
    ctx.setFillColor(CGColor(gray: 0.94, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 220, height: window.h - 90))
    for i in 0..<6 {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 30, y: window.h - 200 - i * 170, width: 150, height: 130))
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
        ctx.stroke(CGRect(x: 30, y: window.h - 200 - i * 170, width: 150, height: 130))
    }
    let w = CGFloat(base.width) * scale, h = CGFloat(base.height) * scale
    ctx.interpolationQuality = .high
    ctx.draw(base, in: CGRect(x: CGFloat(offset.x), y: CGFloat(window.h - offset.y) - h, width: w, height: h))
    return ctx.makeImage()!
}

private func writePNG(_ image: CGImage, _ name: String) -> String {
    let path = workPath(name)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return path
}

private func flatPicture(_ w: Int, _ h: Int, gray: CGFloat) -> CGImage {
    let ctx = srgbContext(w, h)
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

private func pngSize(_ path: String) -> (w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

private func pixels(_ path: String) -> (w: Int, h: Int, bytes: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let ctx = srgbContext(image.width, image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = ctx.data else { return nil }
    let count = ctx.bytesPerRow * ctx.height
    return (image.width, image.height, Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count)))
}

/// The fraction of pixels that differ by more than a little between two pictures of the same size.
private func differingFraction(_ a: String, _ b: String) -> Double? {
    guard let pa = pixels(a), let pb = pixels(b), pa.w == pb.w, pa.h == pb.h, pa.bytes.count == pb.bytes.count else { return nil }
    var diff = 0
    var i = 0
    while i + 3 < pa.bytes.count {
        let d = abs(Int(pa.bytes[i]) - Int(pb.bytes[i])) + abs(Int(pa.bytes[i + 1]) - Int(pb.bytes[i + 1])) + abs(Int(pa.bytes[i + 2]) - Int(pb.bytes[i + 2]))
        if d > 30 { diff += 1 }
        i += 4
    }
    return Double(diff) / Double(pa.w * pa.h)
}

// MARK: reading the output

private func numbers(after label: String, in output: String) -> [Double]? {
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: " ").map(String.init)
        if parts.first == label {
            let nums = parts.dropFirst().compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ",:"))) }
            if !nums.isEmpty { return nums }
        }
    }
    return nil
}

private func statedScale(_ output: String) -> Double? {
    guard let r = output.range(of: "scale [0-9.]+", options: .regularExpression) else { return nil }
    return Double(output[r].dropFirst(6))
}

private func write(_ text: String, _ name: String) -> String {
    let path = workPath(name)
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// The key the mark tests use: a row for page 2 of `pdfs/mark-doc.pdf` with its box, and a row of another file.
private let markBox = CGRect(x: 72, y: 430, width: 468, height: 60)
private func markKey() -> String {
    write("""
    id,group,query,file,locator,window_s,note
    pdf-90,pdf,a passage about orchards,pdfs/other-doc.pdf,1,,box=100:100:200:50; anchor=something else
    pdf-91,pdf,the clause about copper lanterns,pdfs/mark-doc.pdf,2,,box=72:430:468:60; anchor=copper lanterns are allowed

    """, "key/answers.csv")
}

private func markPDF() -> String {
    makePDF("pdfs/mark-doc.pdf", pages: 3, passage: (2, markBox, "copper lanterns are allowed only with the written consent"))
}

private func pixelRect(_ pt: CGRect, scale: CGFloat) -> CGRect {
    CGRect(x: pt.minX * scale, y: pt.minY * scale, width: pt.width * scale, height: pt.height * scale)
}

// MARK: the suite

@Suite("KitReadbackSlice4Tests")
struct KitReadbackSlice4Tests {

    // MARK: syntax, usage, dispatch

    @Test("bash -n finds no syntax error in kit-readback.sh and the readback tool compiles")
    func syntaxAndCompile() throws {
        let ran = try run("/bin/bash", ["-n", readbackScript])
        ok(ran.status == 0 && ran.output.isEmpty, "bash -n kit-readback.sh exited \(ran.status): \(ran.output)")
        ok(FileManager.default.fileExists(atPath: readbackSwift), "scripts/kit-lib/readback.swift not found")
        let bin = rig.kit + "/run/bin/readback"
        ok(FileManager.default.isExecutableFile(atPath: bin), "the Swift tool readback was not compiled in the temp kit root (see \(rig.kit)/run/bin/readback.log)")
    }

    @Test("the four modes are in the usage and are no longer `not built yet`; the three that are not built still are")
    func usageAndDispatch() throws {
        let text = (try? String(contentsOfFile: readbackScript, encoding: .utf8)) ?? ""
        let code = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        for line in ["kit-readback.sh pdf-pages <pdf>", "kit-readback.sh render-pdf-page <pdf> <n> [--out <png>]",
                     "kit-readback.sh mark-check <shot> <pdf> <page> [--answers <csv>]", "kit-readback.sh preview-page"] {
            ok(code.contains(line), "the usage of kit-readback.sh lacks `\(line)`")
        }
        let notBuilt = code.split(separator: "\n").first { $0.contains("not built yet") || $0.contains("waveform-check") }.map(String.init) ?? ""
        for mode in ["pdf-pages", "render-pdf-page", "mark-check", "preview-page"] {
            ok(!notBuilt.contains(mode), "the dispatch still lists `\(mode)` as not built yet")
            ok(has(code, "(^|\\n)[ \\t]*\(mode)\\)[ \\t]+cmd_"), "the dispatch has no `\(mode)) cmd_...` branch of its own")
        }
        for mode in ["waveform-check", "quicktime-time", "speech-assets"] {
            ok(notBuilt.contains(mode) || text.contains(mode), "the dispatch lost `\(mode)`")
        }
        let ran = try readback(["pdf-pages"])
        ok(ran.status == 2, "pdf-pages with no file exited \(ran.status), expected 2 (usage)")
        ok(!ran.output.contains("not built yet"), "pdf-pages still prints `not built yet`: \(ran.output)")
    }

    // MARK: pdf-pages

    @Test("pdf-pages prints the page count of a 1-page and of a 3-page PDF the test made")
    func pdfPages() throws {
        let one = makePDF("pages/one.pdf", pages: 1)
        let three = makePDF("pages/three.pdf", pages: 3)
        let a = try readback(["pdf-pages", one])
        let b = try readback(["pdf-pages", three])
        ok(a.status == 0 && a.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "pdf-pages of the 1-page file: exit \(a.status), printed \(a.output.debugDescription), expected 1")
        ok(b.status == 0 && b.output.trimmingCharacters(in: .whitespacesAndNewlines) == "3", "pdf-pages of the 3-page file: exit \(b.status), printed \(b.output.debugDescription), expected 3")
    }

    @Test("pdf-pages exits 1 for a damaged file, a text file named .pdf, an empty file and a missing file")
    func pdfPagesDamaged() throws {
        let good = makePDF("pages/good.pdf", pages: 3)
        let data = try Data(contentsOf: URL(fileURLWithPath: good))
        let cut = workPath("pages/cut.pdf")
        try data.prefix(200).write(to: URL(fileURLWithPath: cut))
        let text = write("this is not a pdf at all\n", "pages/text.pdf")
        let empty = write("", "pages/empty.pdf")
        for (label, path) in [("cut", cut), ("text", text), ("empty", empty), ("missing", workPath("pages/none.pdf"))] {
            let ran = try readback(["pdf-pages", path])
            ok(ran.status == 1, "pdf-pages of the \(label) file exited \(ran.status), expected 1: \(ran.output)")
        }
    }

    // MARK: render-pdf-page

    @Test("render-pdf-page writes a PNG whose size is the page size times the scale it states, for two page sizes, and the fixed scale is at least 1")
    func renderSize() throws {
        let letter = makePDF("render/letter.pdf", pages: 3)
        let out = workPath("render/letter-2.png")
        let ran = try readback(["render-pdf-page", letter, "2", "--out", out])
        ok(ran.status == 0, "render-pdf-page exited \(ran.status): \(ran.output)")
        guard let g = statedScale(ran.output) else {
            ok(false, "render-pdf-page printed no `scale <s>`: \(ran.output)")
            return
        }
        ok(g >= 1, "the fixed scale is \(g), expected at least 1 so a page is rendered at readable size")
        guard let size = pngSize(out) else { ok(false, "no PNG was written to \(out)"); return }
        ok(size.w == Int((612 * g).rounded()) && size.h == Int((792 * g).rounded()), "the PNG is \(size.w) x \(size.h), expected \(Int((612 * g).rounded())) x \(Int((792 * g).rounded())) for a 612 x 792 page at scale \(g)")
        // a page of another size: a small box, the same scale
        let small = workPath("render/small.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        if let ctx = CGContext(URL(fileURLWithPath: small) as CFURL, mediaBox: &box, nil) {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
            ctx.endPDFPage()
            ctx.closePDF()
        }
        let out2 = workPath("render/small-1.png")
        let ran2 = try readback(["render-pdf-page", small, "1", "--out", out2])
        ok(ran2.status == 0, "render-pdf-page of the small page exited \(ran2.status): \(ran2.output)")
        if let s2 = pngSize(out2) {
            ok(s2.w == Int((300 * g).rounded()) && s2.h == Int((400 * g).rounded()), "the small page's PNG is \(s2.w) x \(s2.h), expected \(Int((300 * g).rounded())) x \(Int((400 * g).rounded()))")
        } else { ok(false, "no PNG was written to \(out2)") }
    }

    @Test("two pages that carry different large numbers render differently, and the same page twice renders the same")
    func renderDiffers() throws {
        let pdf = makePDF("render/three.pdf", pages: 3)
        let a = workPath("render/a1.png"), b = workPath("render/a2.png"), c = workPath("render/a1-again.png")
        for (n, out) in [("1", a), ("2", b), ("1", c)] {
            let ran = try readback(["render-pdf-page", pdf, n, "--out", out])
            ok(ran.status == 0, "render-pdf-page \(n) exited \(ran.status): \(ran.output)")
        }
        let different = differingFraction(a, b)
        ok(different != nil && different! > 0.02, "pages 1 and 2 differ in \(different.map { String($0) } ?? "no comparable size") of their pixels, expected more than 2 percent")
        let same = differingFraction(a, c)
        ok(same != nil && same! < 0.001, "page 1 rendered twice differs in \(same.map { String($0) } ?? "no comparable size") of its pixels, expected none")
    }

    @Test("render-pdf-page of a page out of range exits 1, and with no --out names a file under the kit root that exists")
    func renderRange() throws {
        let pdf = makePDF("render/range.pdf", pages: 3)
        for n in ["0", "4", "99"] {
            let ran = try readback(["render-pdf-page", pdf, n, "--out", workPath("render/never-\(n).png")])
            ok(ran.status == 1, "render-pdf-page of page \(n) of a 3-page file exited \(ran.status), expected 1: \(ran.output)")
            ok(!FileManager.default.fileExists(atPath: workPath("render/never-\(n).png")), "a PNG was written for page \(n) out of range")
        }
        let plain = try readback(["render-pdf-page", pdf, "2"])
        ok(plain.status == 0, "render-pdf-page with no --out exited \(plain.status): \(plain.output)")
        let path = plain.output.split(whereSeparator: { " \n\t".contains($0) }).map(String.init).first { $0.hasSuffix(".png") && $0.hasPrefix("/") }
        ok(path != nil && FileManager.default.fileExists(atPath: path!), "the output names no .png path that exists: \(plain.output)")
        if let p = path { ok(p.hasPrefix(rig.kit) || p.hasPrefix((rig.kit as NSString).resolvingSymlinksInPath), "the default PNG is outside the temp kit root: \(p)") }
        let bad = try readback(["render-pdf-page", pdf, "two"])
        ok(bad.status == 2, "render-pdf-page of page `two` exited \(bad.status), expected 2 (usage)")
    }

    // MARK: mark-check

    private func check(shot: CGImage, name: String, page: Int = 2, pdf: String? = nil, extra: [String] = []) throws -> Ran {
        let shotPath = writePNG(shot, name + ".png")
        return try readback(["mark-check", shotPath, pdf ?? markPDF(), String(page), "--answers", markKey()] + extra)
    }

    private func assertGood(_ ran: Ran, drawn: CGRect, tolerance: Double, _ label: String) {
        ok(ran.status == 0, "\(label): mark-check exited \(ran.status), expected 0: \(ran.output)")
        guard let region = numbers(after: "region", in: ran.output), region.count == 4 else {
            ok(false, "\(label): no `region x y w h` line: \(ran.output)")
            return
        }
        ok(abs(region[0] - drawn.minX) <= tolerance && abs(region[1] - drawn.minY) <= tolerance && abs(region[2] - drawn.width) <= 2 * tolerance && abs(region[3] - drawn.height) <= 2 * tolerance,
           "\(label): the region is \(region), the test drew x \(drawn.minX) y \(drawn.minY) w \(drawn.width) h \(drawn.height) (points, tolerance \(tolerance))")
        if let box = numbers(after: "box", in: ran.output) {
            ok(box == [72, 430, 468, 60], "\(label): the box line is \(box), the key row says 72:430:468:60")
        } else { ok(false, "\(label): no `box x y w h` line: \(ran.output)") }
        if let inside = numbers(after: "inside", in: ran.output)?.first { ok(inside >= 0.5, "\(label): inside is \(inside), expected at least 0.5") } else { ok(false, "\(label): no `inside` line") }
        if let overlap = numbers(after: "overlap", in: ran.output)?.first { ok(overlap >= 0.5, "\(label): overlap is \(overlap), expected at least 0.5") } else { ok(false, "\(label): no `overlap` line") }
        if let px = numbers(after: "pixels", in: ran.output)?.first { ok(px >= 200, "\(label): pixels is \(px)") } else { ok(false, "\(label): no `pixels` line") }
    }

    @Test("mark-check passes on the page render with a mark inside the grown box, read at the same scale")
    func markPlain() throws {
        let pdf = markPDF()
        let drawn = CGRect(x: 80, y: 436, width: 452, height: 48)
        let base = render(pdf, page: 2, scale: 2)
        let ran = try check(shot: marked(base, rect: pixelRect(drawn, scale: 2)), name: "mark-plain", pdf: pdf)
        assertGood(ran, drawn: drawn, tolerance: 4, "plain")
        let file = (try? String(contentsOfFile: rig.runDir + "/compare-s3-mark.txt", encoding: .utf8)) ?? ""
        ok(file.contains("region") && file.contains("inside") && file.contains("overlap"), "compare-s3-mark.txt is missing or lacks the region, inside and overlap lines: \(file.debugDescription)")
    }

    @Test("mark-check passes on a shot with the page composited at 0.8 scale and an offset into a larger window with chrome; a mark that reaches into the 10 point margin passes too")
    func markInWindow() throws {
        let pdf = markPDF()
        let base = render(pdf, page: 2, scale: 2)
        let drawn = CGRect(x: 82, y: 440, width: 448, height: 44)
        let shot = inWindow(marked(base, rect: pixelRect(drawn, scale: 2)), scale: 0.8, window: (1700, 1500), offset: (350, 120))
        assertGood(try check(shot: shot, name: "mark-window", pdf: pdf), drawn: drawn, tolerance: 6, "0.8 scale in a window")
        // the mark spills into the margin of 10 points on each side: still inside the grown box
        let wide = CGRect(x: 66, y: 424, width: 480, height: 72)
        let shot2 = inWindow(marked(base, rect: pixelRect(wide, scale: 2)), scale: 0.65, window: (1500, 1400), offset: (400, 200))
        let ran2 = try check(shot: shot2, name: "mark-window-wide", pdf: pdf)
        ok(ran2.status == 0, "a mark that fills the box and its 10 point margin exited \(ran2.status), expected 0: \(ran2.output)")
    }

    @Test("mark-check exits 1 for a mark away from the passage, on another passage of the page and on the chrome of the window")
    func markOffTarget() throws {
        let pdf = markPDF()
        let base = render(pdf, page: 2, scale: 2)
        // another passage: a rectangle low on the page, far from the box
        let other = CGRect(x: 80, y: 150, width: 300, height: 40)
        let r1 = try check(shot: inWindow(marked(base, rect: pixelRect(other, scale: 2)), scale: 0.8, window: (1700, 1500), offset: (350, 120)), name: "mark-other", pdf: pdf)
        ok(r1.status == 1, "a mark on another passage exited \(r1.status), expected 1: \(r1.output)")
        if let inside = numbers(after: "inside", in: r1.output)?.first { ok(inside < 0.5, "inside is \(inside) for a mark outside the box") } else { ok(false, "a mark on another passage printed no `inside` line, so the mark was not even found: \(r1.output)") }
        if let region = numbers(after: "region", in: r1.output), region.count == 4 {
            ok(abs(region[0] - 80) <= 6 && abs(region[1] - 150) <= 6, "the region of the mark on the other passage is \(region), the test drew x 80 y 150")
        }
        // a rectangle that only touches the box's edge from below: most of it lies outside the grown box
        let edge = CGRect(x: 72, y: 330, width: 468, height: 105)
        let r2 = try check(shot: inWindow(marked(base, rect: pixelRect(edge, scale: 2)), scale: 0.8, window: (1700, 1500), offset: (350, 120)), name: "mark-edge", pdf: pdf)
        ok(r2.status == 1, "a mark that is mostly below the box exited \(r2.status), expected 1: \(r2.output)")
        ok(numbers(after: "inside", in: r2.output) != nil, "a mark that is mostly below the box printed no `inside` line, so the mark was not found: \(r2.output)")
        // the chrome: a coloured rectangle in the sidebar of the window, none on the page
        let window = inWindow(base, scale: 0.8, window: (1700, 1500), offset: (350, 120))
        let r3 = try check(shot: marked(window, rect: CGRect(x: 40, y: 600, width: 140, height: 90)), name: "mark-chrome", pdf: pdf)
        ok(r3.status == 1 && r3.output.contains("no mark"), "a mark on the chrome of the window exited \(r3.status), expected 1 and `no mark` (the page itself holds none): \(r3.output)")
    }

    @Test("mark-check exits 1 `no mark` for the unmarked render and for fewer than 200 coloured pixels")
    func markTooSmall() throws {
        let pdf = markPDF()
        let base = render(pdf, page: 2, scale: 2)
        let none = try check(shot: inWindow(base, scale: 0.8, window: (1700, 1500), offset: (350, 120)), name: "mark-none", pdf: pdf)
        ok(none.status == 1 && none.output.contains("no mark"), "the unmarked page exited \(none.status) with \(none.output.debugDescription), expected 1 and `no mark`")
        // 12 x 12 pixels of the shot, at the box
        let shot = inWindow(base, scale: 0.8, window: (1700, 1500), offset: (350, 120))
        let tiny = try check(shot: marked(shot, rect: CGRect(x: 800, y: 700, width: 12, height: 12)), name: "mark-tiny", pdf: pdf)
        ok(tiny.status == 1, "a mark of 144 pixels exited \(tiny.status), expected 1: \(tiny.output)")
    }

    @Test("mark-check exits 4, never a pass, for a shot of another page, for a flat picture and for a page that is not in the shot at all")
    func markNoPicture() throws {
        let pdf = markPDF()
        let drawn = CGRect(x: 80, y: 436, width: 452, height: 48)
        // a shot of page 3 (a different large number) with a mark where the box would be
        let page3 = render(pdf, page: 3, scale: 2)
        let r1 = try check(shot: inWindow(marked(page3, rect: pixelRect(drawn, scale: 2)), scale: 0.8, window: (1700, 1500), offset: (350, 120)), name: "mark-page3", pdf: pdf)
        ok(r1.status == 4, "a shot of page 3 asked as page 2 exited \(r1.status), expected 4: \(r1.output)")
        ok(has(r1.output, "no picture of page 2|below"), "exit 4 says nothing about the picture of the page: \(r1.output)")
        let flat = try check(shot: marked(flatPicture(1700, 1500, gray: 0.8), rect: CGRect(x: 500, y: 600, width: 300, height: 200)), name: "mark-flat", pdf: pdf)
        ok(flat.status == 4, "a flat picture with a coloured rectangle exited \(flat.status), expected 4: \(flat.output)")
        let r2 = try check(shot: flatPicture(900, 700, gray: 0.5), name: "mark-gray", pdf: pdf)
        ok(r2.status == 4, "a flat gray picture exited \(r2.status), expected 4: \(r2.output)")
    }

    @Test("mark-check takes the box from the row of the key that names this file and this page, and says so when the key has none")
    func markKeyLookup() throws {
        let pdf = markPDF()
        let base = render(pdf, page: 2, scale: 2)
        let shotPath = writePNG(marked(base, rect: pixelRect(CGRect(x: 80, y: 436, width: 452, height: 48), scale: 2)), "mark-key.png")
        // page 3 has no row of the key for this file
        let noRow = try readback(["mark-check", shotPath, pdf, "3", "--answers", markKey()])
        ok(noRow.status == 1 && has(noRow.output, "no box"), "a page with no row in the key exited \(noRow.status) with \(noRow.output.debugDescription), expected 1 and `no box`")
        // a file the key does not name
        let other = makePDF("pdfs/unnamed.pdf", pages: 3)
        let noFile = try readback(["mark-check", shotPath, other, "2", "--answers", markKey()])
        ok(noFile.status == 1 && has(noFile.output, "no box"), "a file the key does not name exited \(noFile.status) with \(noFile.output.debugDescription), expected 1 and `no box`")
        // a missing shot
        let missing = try readback(["mark-check", workPath("nope.png"), pdf, "2", "--answers", markKey()])
        ok(missing.status == 1, "a missing shot exited \(missing.status), expected 1: \(missing.output)")
        // usage
        let usage = try readback(["mark-check", shotPath, pdf])
        ok(usage.status == 2, "mark-check with no page exited \(usage.status), expected 2")
    }

    @Test("mark-check with no --answers reads the project's fixtures/answers.csv: the box of the lease row, drawn by the test at the key's own rectangle")
    func markDefaultKey() throws {
        let key = (try? String(contentsOf: projectRoot.appendingPathComponent("fixtures/answers.csv"), encoding: .utf8)) ?? ""
        guard let row = key.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("pdf-01,") }) else {
            ok(false, "the key has no pdf-01 row")
            return
        }
        let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7, f[3] == "pdfs/lease-2024.pdf", let page = Int(f[4]),
              let boxPart = f[6].components(separatedBy: "; ").first(where: { $0.hasPrefix("box=") }) else {
            ok(false, "the pdf-01 row is not `pdfs/lease-2024.pdf` with a page and a box=: \(row)")
            return
        }
        let n = boxPart.dropFirst(4).split(separator: ":").compactMap { Double($0) }
        guard n.count == 4 else { ok(false, "the box of pdf-01 is not four numbers: \(boxPart)"); return }
        let box = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        let pdf = makePDF("pdfs/lease-2024.pdf", pages: page + 2, passage: (page, box, "the lease key row"))
        let drawn = box.insetBy(dx: 6, dy: 6)
        let shot = inWindow(marked(render(pdf, page: page, scale: 2), rect: pixelRect(drawn, scale: 2)), scale: 0.8, window: (1700, 1500), offset: (350, 120))
        let ran = try readback(["mark-check", writePNG(shot, "mark-default.png"), pdf, String(page)])
        ok(ran.status == 0, "mark-check with the project key exited \(ran.status): \(ran.output)")
        if let b = numbers(after: "box", in: ran.output) { ok(b == n, "the box line is \(b), the key says \(n)") } else { ok(false, "no `box` line: \(ran.output)") }
    }

    // MARK: preview-page, the tree reading

    private let treeHeader = "window \"lease-2024.pdf\"\n"

    private func tree(_ lines: [String], header: String? = nil) -> String {
        write((header ?? treeHeader) + lines.joined(separator: "\n") + "\n", "tree/sample-\(UUID().uuidString).txt")
    }

    @Test("preview-page reads page 7 from a hand-written tree: the page field `7 of 12`, the selected thumbnail `Page 7`, or both")
    func treeReads() throws {
        let field = tree(["  AXTextField label=\"Page\" value=\"7 of 12\"", "  AXButton label=\"Zoom\""])
        let thumb = tree(["  AXScrollArea label=\"Thumbnails\"", "    AXRow label=\"Page 6\"", "    AXRow label=\"Page 7\" [selected]", "    AXRow label=\"Page 8\""])
        let both = tree(["  AXScrollArea label=\"Thumbnails\"", "    AXRow label=\"Page 7\" [selected]", "  AXTextField label=\"Page\" value=\"7 of 12\""])
        let titled = tree(["  AXButton label=\"Zoom\""], header: "window \"lease-2024.pdf – Page 7 of 12\"\n")
        for (label, file) in [("the page field", field), ("the selected thumbnail", thumb), ("both", both), ("the window title", titled)] {
            let ran = try readback(["preview-page", "--tree-sample", file])
            ok(ran.status == 0 && ran.output.contains("page 7 via tree"), "\(label): exit \(ran.status), printed \(ran.output.debugDescription), expected `page 7 via tree`")
        }
    }

    @Test("preview-page exits 4 `tree lacks the page` for a dump with no page, with no selected thumbnail, and with two pages that disagree")
    func treeLacks() throws {
        let none = tree(["  AXButton label=\"Zoom\"", "  AXStaticText label=\"lease-2024.pdf\""])
        let unselected = tree(["  AXScrollArea label=\"Thumbnails\"", "    AXRow label=\"Page 6\"", "    AXRow label=\"Page 7\"", "    AXRow label=\"Page 8\""])
        let disagree = tree(["  AXRow label=\"Page 7\" [selected]", "  AXTextField label=\"Page\" value=\"3 of 12\""])
        for (label, file) in [("no page", none), ("unselected thumbnails", unselected), ("two pages that disagree", disagree)] {
            let ran = try readback(["preview-page", "--tree-sample", file])
            ok(ran.status == 4 && ran.output.contains("tree lacks the page"), "\(label): exit \(ran.status), printed \(ran.output.debugDescription), expected 4 and `tree lacks the page`")
            ok(!ran.output.contains("via tree"), "\(label): a page was read from a tree that lacks one: \(ran.output)")
        }
    }

    // plan-4-kit-repair-1: Preview's window title already carries the page (`lease-2024.pdf – Page 1 of 12`, measured live); it is the first
    // evidence of the tree reading. Window-name dumps: `window "<title>"` lines (what the live reading prints, one per window) or bare names.

    @Test("preview-page reads the page from window titles alone: `window \"…\"` lines, bare names, a `(Page N of M)` variant, and two windows that show the same page")
    func titleReads() throws {
        let quoted = tree([], header: "window \"lease-2024.pdf – Page 7 of 12\"\n")
        let bare = tree(["lease-2024.pdf – Page 7 of 12"], header: "")
        let paren = tree([], header: "window \"lease-2024.pdf (Page 7 of 12)\"\n")
        let hyphen = tree([], header: "window \"lease-2024.pdf - page 7 of 12\"\n")
        let twice = tree(["window \"lease-2024.pdf – Page 7 of 12\"", "window \"lease-2024 copy.pdf – Page 7 of 12\""], header: "")
        let plusOther = tree(["window \"lease-2024.pdf – Page 7 of 12\"", "window \"Preview Settings\""], header: "")
        for (label, file) in [("a quoted window title", quoted), ("a bare window name", bare), ("a (Page N of M) title", paren), ("a lower-case page", hyphen),
                              ("two windows on the same page", twice), ("a second window with no page in its name", plusOther)] {
            let ran = try readback(["preview-page", "--tree-sample", file])
            ok(ran.status == 0 && ran.output.contains("page 7 via tree"), "\(label): exit \(ran.status), printed \(ran.output.debugDescription), expected `page 7 via tree`")
        }
    }

    @Test("preview-page exits 4 `tree lacks the page`, never a guess, for two windows with different pages and for a window title with no page")
    func titleLacks() throws {
        let two = tree(["window \"lease-2024.pdf – Page 7 of 12\"", "window \"other.pdf – Page 3 of 9\""], header: "")
        let twoBare = tree(["lease-2024.pdf – Page 7 of 12", "other.pdf – Page 3 of 9"], header: "")
        // a selected thumbnail that matches one of the two windows does not choose between them
        let twoPlusThumb = tree(["window \"lease-2024.pdf – Page 7 of 12\"", "window \"other.pdf – Page 3 of 9\"", "  AXRow label=\"Page 7\" [selected]"], header: "")
        let noPage = tree([], header: "window \"lease-2024.pdf\"\n")
        let noPageBare = tree(["lease-2024.pdf"], header: "")
        let none = write("no Preview window\n", "tree/no-window.txt")
        for (label, file) in [("two windows, quoted", two), ("two windows, bare", twoBare), ("two windows and a selected thumbnail", twoPlusThumb),
                              ("a title with no page", noPage), ("a bare title with no page", noPageBare), ("no Preview window", none)] {
            let ran = try readback(["preview-page", "--tree-sample", file])
            ok(ran.status == 4 && ran.output.contains("tree lacks the page"), "\(label): exit \(ran.status), printed \(ran.output.debugDescription), expected 4 and `tree lacks the page`")
            ok(!ran.output.contains("via tree"), "\(label): a page was read where the titles name none or two: \(ran.output)")
        }
    }

    @Test("a page in the window title is the first evidence: it wins over a selected thumbnail or a page field that say another page; the other evidence still reads when the title has no page")
    func titleFirst() throws {
        let thumb = tree(["  AXRow label=\"Page 3\" [selected]"], header: "window \"lease-2024.pdf – Page 7 of 12\"\n")
        let field = tree(["  AXTextField label=\"Page\" value=\"3 of 12\""], header: "window \"lease-2024.pdf – Page 7 of 12\"\n")
        for (label, file) in [("a selected thumbnail", thumb), ("a page field", field)] {
            let ran = try readback(["preview-page", "--tree-sample", file])
            ok(ran.status == 0 && ran.output.contains("page 7 via tree"), "title Page 7 against \(label) Page 3: exit \(ran.status), printed \(ran.output.debugDescription), expected `page 7 via tree` (the title decides)")
            let written = (try? String(contentsOfFile: rig.runDir + "/readback-preview.txt", encoding: .utf8)) ?? ""
            ok(written.contains("title"), "readback-preview.txt is \(written.debugDescription), expected it to say the window title decided")
        }
        let fallback = tree(["  AXRow label=\"Page 4\" [selected]"], header: "window \"lease-2024.pdf\"\n")
        let ran = try readback(["preview-page", "--tree-sample", fallback])
        ok(ran.status == 0 && ran.output.contains("page 4 via tree"), "a title with no page and a selected thumbnail Page 4: exit \(ran.status), printed \(ran.output.debugDescription), expected `page 4 via tree`")
    }

    // MARK: preview-page, the picture reading

    private func pictureShot(pdf: String, page: Int, scale: CGFloat = 0.7, name: String) -> String {
        let image = inWindow(render(pdf, page: page, scale: 2), scale: scale, window: (1600, 1500), offset: (380, 110))
        return writePNG(image, name)
    }

    @Test("preview-page --by-picture reads page 7, page 1 and page 12 of a 12-page PDF from pictures of a window, and says which reading decided in readback-preview.txt")
    func pictureReads() throws {
        let pdf = makePDF("preview/twelve.pdf", pages: 12)
        for page in [7, 1, 12] {
            let shot = pictureShot(pdf: pdf, page: page, name: "preview-shot-\(page).png")
            let ran = try readback(["preview-page", "--by-picture", "--from", shot, "--pdf", pdf])
            ok(ran.status == 0 && ran.output.contains("page \(page) via picture"), "the picture of page \(page): exit \(ran.status), printed \(ran.output.debugDescription), expected `page \(page) via picture`")
            let file = (try? String(contentsOfFile: rig.runDir + "/readback-preview.txt", encoding: .utf8)) ?? ""
            ok(file.contains("picture") && file.contains(String(page)), "readback-preview.txt after page \(page) is \(file.debugDescription): it should say the picture reading decided and name the page")
        }
    }

    @Test("preview-page --by-picture exits 3 NEEDS A PERSON for a tie (two identical pages) and for a flat picture; --by-picture with no --pdf exits 2")
    func pictureCannotTell() throws {
        // a tie: both pages carry the same picture, so neither is ahead of the other
        let twin = makePDF("preview/twin.pdf", pages: 2, identical: true)
        let tieShot = pictureShot(pdf: twin, page: 1, name: "preview-shot-twin.png")
        let tie = try readback(["preview-page", "--by-picture", "--from", tieShot, "--pdf", twin])
        ok(tie.status == 3 && tie.output.contains("NEEDS A PERSON"), "a tie: exit \(tie.status), printed \(tie.output.debugDescription), expected 3 and `NEEDS A PERSON`")
        ok(!tie.output.contains("via picture"), "a tie printed a page: \(tie.output)")
        // plan-4-kit-repair-1: near-identical lease pages tie live (pages 3 and 11 both 0.980); the line must say why and what to use instead
        ok(has(tie.output, "NEEDS A PERSON[^\\n]*too similar") && has(tie.output, "NEEDS A PERSON[^\\n]*title"), "a tie's NEEDS A PERSON line does not say the page images are too similar and that the title reading is preferred: \(tie.output.debugDescription)")
        // below the threshold: the window shows no page of the file
        let pdf = makePDF("preview/twelve.pdf", pages: 12)
        let flat = writePNG(flatPicture(1600, 1500, gray: 0.8), "preview-shot-flat.png")
        let low = try readback(["preview-page", "--by-picture", "--from", flat, "--pdf", pdf])
        ok(low.status == 3 && low.output.contains("NEEDS A PERSON"), "a flat picture: exit \(low.status), printed \(low.output.debugDescription), expected 3 and `NEEDS A PERSON`")
        let noPdf = try readback(["preview-page", "--by-picture", "--from", flat])
        ok(noPdf.status == 2, "--by-picture with no --pdf exited \(noPdf.status), expected 2")
        let bad = try readback(["preview-page", "--no-such-option"])
        ok(bad.status == 2, "an unknown option exited \(bad.status), expected 2")
    }

    // MARK: the live paths are text-checked only

    @Test("the live paths of preview-page are in the script and were never run here: Preview's tree through System Events by osascript, and the screenshot of Preview's window by kit-ax.sh shot --app Preview; nothing launches or closes an app")
    func livePathsText() throws {
        let text = (try? String(contentsOfFile: readbackScript, encoding: .utf8)) ?? ""
        let code = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        ok(has(code, "osascript"), "the script has no osascript call for Preview's tree")
        ok(has(code, "System Events") && has(code, "Preview"), "the live tree reading does not go through System Events for the Preview process")
        ok(has(code, "kit-ax\\.sh\"?[ ]+shot[^\\n]*--app[ ]+Preview"), "the live picture reading does not take the screenshot with `kit-ax.sh shot ... --app Preview` (one window by id, never the screen)")
        ok(!has(code, "screencapture[^\\n]*-x[^\\n]*[^-]\\b(png|jpg)\\b[^l]*$"), "the script takes a picture of the whole screen")
        ok(!has(code, "\\bkillall\\b|\\bpkill\\b|close every window|keystroke|key code"), "kit-readback.sh closes or keys an app: it only reads")
        ok(!has(code, "Sources/"), "kit-readback.sh reads product source")
    }

    @Test("the live tree reading guards every property read of an element with try (a role that has no text made `role of e` fail with -1700 live), and reads the window names first, one per window")
    func liveTreeGuarded() throws {
        let text = (try? String(contentsOfFile: readbackScript, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("#") }
        var depth = 0
        var reads = 0
        for line in lines {
            if line == "'try' \\" || line == "'try'" { depth += 1; continue }
            if line.hasPrefix("'end try'") { depth = max(0, depth - 1); continue }
            if has(line, "\\b(role|title|description|value|selected|name|subrole) of (e|w)\\b") && line.hasPrefix("'") {
                reads += 1
                ok(depth > 0, "an AppleScript property read is outside a try block: \(line)")
            }
        }
        ok(reads >= 5, "found only \(reads) element property reads in the live osascript lines; the check cannot see the live reading")
        ok(has(text, "name of w"), "the live reading does not read the window names (name of w)")
        // the window names come before the entire contents, and the tree is only read when the names hold no page
        let titles = text.range(of: "pp_live_titles")?.lowerBound
        let treeCall = text.range(of: "pp_live_tree")?.lowerBound
        ok(titles != nil && treeCall != nil && titles! < treeCall!, "pp_live_titles must be defined and called before pp_live_tree")
        let body = text.components(separatedBy: "cmd_preview_page() {").last ?? ""
        let firstTitles = body.range(of: "pp_live_titles")?.lowerBound
        let firstTree = body.range(of: "pp_live_tree")?.lowerBound
        ok(firstTitles != nil && firstTree != nil && firstTitles! < firstTree!, "cmd_preview_page does not read the window names (pp_live_titles) before the tree (pp_live_tree)")
    }
}
