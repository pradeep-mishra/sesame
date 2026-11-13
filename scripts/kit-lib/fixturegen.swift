// fixturegen: the kit's picture and PDF maker (verify.md, Fixture tooling: short Swift programs).
// Compiled once per starting state by kit_tool (scripts/kit-lib/common.sh); never part of the product.
//
//   fixturegen photos <jobs.tsv> <outdir>   draws every job and writes it in its own format
//   fixturegen pdf-make <out.pdf> <text>    one page holding the text
//   fixturegen pdf-read <file.pdf>          prints "pages <n>" then the page text
//   fixturegen pdfs <jobs.tsv> <outdir>     the golden and boundary PDFs, written by hand (see "PDFs written by hand")
//
// A job is one tab-separated line: path, format, role, c1, c2, c3, objects, text.
//   role photo (target or other): c1 and c2 are the sky from top to bottom, c3 the ground colour
//   ("-" for none); objects is "glyph:cx,cy,size;..." with cx, cy fractions of the width and the
//   height and size a fraction of the height; text is "-".
//   role screenshot: c1 page, c2 title bar, c3 text colour; objects is "-"; text is lines
//   separated by "|".
//   role token: c1 page, c3 text colour, c2 and objects unused ("-"); text is lines separated by "|";
//   a 900 x 420 picture of big monospaced text (the matrix cells).
// Drawing is fixed (no random numbers, no clock), so two runs write the same bytes.
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: String) -> CGColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { die("bad colour \(hex)") }
    return CGColor(
        colorSpace: space,
        components: [CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255, 1]
    )!
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func textLine(_ text: String, font name: String, size: CGFloat, color: CGColor) -> CTLine {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
    let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    return CTLineCreateWithAttributedString(attributed)
}

struct Job {
    let path, format, role, c1, c2, c3, objects, text: String
}

func drawPhoto(_ job: Job, w: Int, h: Int) -> CGContext {
    let ctx = makeContext(w, h)
    let sky = CGGradient(colorsSpace: space, colors: [rgb(job.c1), rgb(job.c2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    if job.c3 != "-" {
        ctx.setFillColor(rgb(job.c3))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: Int(Double(h) * 0.38)))
    }
    // plan 5 (video shots): a text that is a number is the seed of a faint 8 x 8 pattern of dark cells laid behind the objects, so that
    // two shots of one clip differ in the coarse picture too (an 8 x 8 average hash tells them apart); every other job has text "-".
    if let seed = UInt64(job.text) {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        for cell in 0..<64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            if (state >> 33) & 1 == 1 {
                ctx.fill(CGRect(x: (cell % 8) * w / 8, y: (cell / 8) * h / 8, width: w / 8, height: h / 8))
            }
        }
    }
    for item in job.objects.split(separator: ";") {
        guard let colon = item.lastIndex(of: ":") else { die("bad object \(item)") }
        let glyph = String(item[item.startIndex..<colon])
        let nums = item[item.index(after: colon)...].split(separator: ",").compactMap { Double($0) }
        guard nums.count == 3 else { die("bad object \(item)") }
        let size = CGFloat(nums[2]) * CGFloat(h)
        let line = textLine(glyph, font: "Apple Color Emoji", size: size, color: rgb("#000000"))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let x = CGFloat(nums[0]) * CGFloat(w) - bounds.width / 2 - bounds.minX
        let y = CGFloat(h) - CGFloat(nums[1]) * CGFloat(h) - size * 0.35
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
    return ctx
}

func drawScreenshot(_ job: Job, w: Int, h: Int) -> CGContext {
    let ctx = makeContext(w, h)
    ctx.setFillColor(rgb(job.c1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(rgb(job.c2))
    ctx.fill(CGRect(x: 0, y: h - 72, width: w, height: 72))
    for (i, dot) in ["#ff5f57", "#febc2e", "#28c840"].enumerated() {
        ctx.setFillColor(rgb(dot))
        ctx.fillEllipse(in: CGRect(x: 28 + i * 44, y: h - 52, width: 28, height: 28))
    }
    var baseline = CGFloat(h) - 180
    for text in job.text.split(separator: "|", omittingEmptySubsequences: false) {
        let line = textLine(String(text), font: "Menlo", size: 40, color: rgb(job.c3))
        ctx.textPosition = CGPoint(x: 60, y: baseline)
        CTLineDraw(line, ctx)
        baseline -= 84
    }
    return ctx
}

// role token (plan 3, the matrix cells): a 900 x 420 picture of big text, one line per "|" part, so text
// recognition reads a short token exactly (measured: Vision reads "zq0013" as "z00013" or "zą0013" in lower
// case, and reads "ZQ0013" in Menlo every time, so the kit passes the token in capitals). c1 is the page
// colour, c3 the text colour.
func drawToken(_ job: Job, w: Int, h: Int) -> CGContext {
    let ctx = makeContext(w, h)
    ctx.setFillColor(rgb(job.c1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    var baseline = CGFloat(h) - 120
    for text in job.text.split(separator: "|", omittingEmptySubsequences: false) {
        let line = textLine(String(text), font: "Menlo-Regular", size: 100, color: rgb(job.c3))
        ctx.textPosition = CGPoint(x: 50, y: baseline)
        CTLineDraw(line, ctx)
        baseline -= 120
    }
    return ctx
}

// ---- WebP: a lossless VP8L stream with no transform, no colour cache and one prefix-code group.
// Green, red and blue use a plain 8-bit code (all 256 symbols one length), alpha the single value
// 255. It is a valid stream any WebP reader decodes; it is large, which does not matter here.
struct BitWriter {
    var bytes = [UInt8]()
    var acc: UInt64 = 0
    var count = 0
    mutating func put(_ value: UInt32, _ bits: Int) {
        acc |= UInt64(value) << UInt64(count)
        count += bits
        while count >= 8 {
            bytes.append(UInt8(acc & 0xff))
            acc >>= 8
            count -= 8
        }
    }
    mutating func finish() -> [UInt8] {
        if count > 0 { bytes.append(UInt8(acc & 0xff)) }
        acc = 0
        count = 0
        return bytes
    }
}

func reverse8(_ v: UInt8) -> UInt32 {
    var r: UInt8 = 0
    var x = v
    for _ in 0..<8 {
        r = (r << 1) | (x & 1)
        x >>= 1
    }
    return UInt32(r)
}

func le32(_ v: Int) -> [UInt8] {
    [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]
}

func webpData(_ ctx: CGContext) -> Data {
    let w = ctx.width, h = ctx.height
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var bw = BitWriter()
    bw.put(0x2f, 8)
    bw.put(UInt32(w - 1), 14)
    bw.put(UInt32(h - 1), 14)
    bw.put(0, 1)  // alpha not used
    bw.put(0, 3)  // version
    bw.put(0, 1)  // no transform
    bw.put(0, 1)  // no colour cache
    bw.put(0, 1)  // no meta prefix image
    func uniformCode(useMaxSymbol: Bool) {
        bw.put(0, 1)  // normal code
        bw.put(8, 4)  // 12 code-length code lengths
        for i in 0..<12 { bw.put(i == 11 ? 1 : 0, 3) }  // only length symbol 8 is used
        if useMaxSymbol {
            bw.put(1, 1)
            bw.put(3, 3)  // 8 bits for max_symbol
            bw.put(254, 8)  // 256 lengths are read, the 24 length-prefix symbols stay 0
        } else {
            bw.put(0, 1)
        }
    }
    uniformCode(useMaxSymbol: true)  // green
    uniformCode(useMaxSymbol: false)  // red
    uniformCode(useMaxSymbol: false)  // blue
    bw.put(1, 1); bw.put(0, 1); bw.put(1, 1); bw.put(255, 8)  // alpha: the one symbol 255
    bw.put(1, 1); bw.put(0, 1); bw.put(0, 1); bw.put(0, 1)  // distance: the one symbol 0
    for y in 0..<h {
        for x in 0..<w {
            let p = px + (y * ctx.bytesPerRow + x * 4)
            bw.put(reverse8(p[1]), 8)
            bw.put(reverse8(p[0]), 8)
            bw.put(reverse8(p[2]), 8)
        }
    }
    var chunk = bw.finish()
    let size = chunk.count
    if size % 2 == 1 { chunk.append(0) }
    var out = [UInt8]("RIFF".utf8)
    out += le32(4 + 8 + chunk.count)
    out += [UInt8]("WEBP".utf8) + [UInt8]("VP8L".utf8) + le32(size) + chunk
    return Data(out)
}

// ---- HEIC: ImageIO's own HEIC encoder needs a temporary folder outside the kit's reach, so the
// picture is encoded to one HEVC frame by ffmpeg (libx265) and wrapped in a single-image HEIF file.
func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 255), UInt8(v & 255)] }

func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    be32(8 + payload.count) + [UInt8](type.utf8) + payload
}

func fullBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    box(type, [0, 0, 0, 0] + payload)
}

func annexBUnits(_ data: [UInt8]) -> [[UInt8]] {
    var starts = [(start: Int, payload: Int)]()
    var i = 0
    while i + 3 <= data.count {
        if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
            starts.append((i, i + 3))
            i += 3
        } else {
            i += 1
        }
    }
    var units = [[UInt8]]()
    for (k, s) in starts.enumerated() {
        var end = k + 1 < starts.count ? starts[k + 1].start : data.count
        while end > s.payload, data[end - 1] == 0 { end -= 1 }  // zero bytes before the next start code
        units.append(Array(data[s.payload..<end]))
    }
    return units
}

func unescape(_ nal: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    var zeros = 0
    for b in nal {
        if zeros >= 2, b == 3 {
            zeros = 0
            continue
        }
        zeros = b == 0 ? zeros + 1 : 0
        out.append(b)
    }
    return out
}

func heicData(_ ctx: CGContext, scratch: String) -> Data {
    guard let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: scratch + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { die("cannot start \(scratch).png") }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { die("cannot write \(scratch).png") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [
        "ffmpeg", "-v", "error", "-y", "-i", scratch + ".png", "-frames:v", "1", "-c:v", "libx265",
        "-pix_fmt", "yuv420p", "-crf", "20", "-x265-params", "no-info=1:log-level=error:frame-threads=1:pools=1",
        "-f", "hevc", scratch + ".hevc",
    ]
    p.standardError = FileHandle.nullDevice  // ffmpeg warns about a timestamp of a one-frame stream; the exit status is what counts
    do { try p.run() } catch { die("cannot run ffmpeg") }
    p.waitUntilExit()
    defer {
        try? FileManager.default.removeItem(atPath: scratch + ".png")
        try? FileManager.default.removeItem(atPath: scratch + ".hevc")
    }
    guard p.terminationStatus == 0, let stream = FileManager.default.contents(atPath: scratch + ".hevc")
    else { die("ffmpeg could not encode \(scratch) with libx265") }
    var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
    var sample = [UInt8]()
    for nal in annexBUnits([UInt8](stream)) {
        let type = Int(nal[0] >> 1) & 0x3f
        switch type {
        case 32: vps = vps ?? nal
        case 33: sps = sps ?? nal
        case 34: pps = pps ?? nal
        case 0..<32: sample += be32(nal.count) + nal
        default: break
        }
    }
    guard let vps = vps, let sps = sps, let pps = pps, !sample.isEmpty else { die("the HEVC stream of \(scratch) has no parameter sets or no slice") }
    let rbsp = unescape(sps)
    var hvcc: [UInt8] = [1]
    hvcc += Array(rbsp[3..<15])  // profile space, tier, profile, compatibility, constraint flags, level
    hvcc += [0xF0, 0x00, 0xFC, 0xFD, 0xF8, 0xF8, 0x00, 0x00]
    let layers = Int((rbsp[2] >> 1) & 7) + 1
    hvcc += [UInt8((layers << 3) | (Int(rbsp[2] & 1) << 2) | 3), 3]
    for (type, nal) in [(32, vps), (33, sps), (34, pps)] {
        hvcc += [UInt8(0x80 | type)] + be16(1) + be16(nal.count) + nal
    }
    let ftyp = box("ftyp", [UInt8]("heic".utf8) + be32(0) + [UInt8]("mif1".utf8) + [UInt8]("heic".utf8))
    func meta(offset: Int) -> [UInt8] {
        let hdlr = fullBox("hdlr", be32(0) + [UInt8]("pict".utf8) + be32(0) + be32(0) + be32(0) + [0])
        let pitm = fullBox("pitm", be16(1))
        let infe = box("infe", [2, 0, 0, 0] + be16(1) + be16(0) + [UInt8]("hvc1".utf8) + [0])
        let iinf = fullBox("iinf", be16(1) + infe)
        let iloc = fullBox("iloc", [0x44, 0x00] + be16(1) + be16(1) + be16(0) + be16(1) + be32(offset) + be32(sample.count))
        let ipco = box("ipco", box("hvcC", hvcc) + fullBox("ispe", be32(ctx.width) + be32(ctx.height)))
        let ipma = fullBox("ipma", be32(1) + be16(1) + [2, 0x81, 0x02])
        return fullBox("meta", hdlr + pitm + iinf + iloc + box("iprp", ipco + ipma))
    }
    let offset = ftyp.count + meta(offset: 0).count + 8
    return Data(ftyp + meta(offset: offset) + box("mdat", sample))
}

func write(_ ctx: CGContext, format: String, to url: URL) {
    if format == "webp" {
        do { try webpData(ctx).write(to: url) } catch { die("cannot write \(url.path)") }
        return
    }
    if format == "heic" {
        do { try heicData(ctx, scratch: url.path + ".scratch").write(to: url) } catch { die("cannot write \(url.path)") }
        return
    }
    let type: String
    var props: [CFString: Any] = [:]
    switch format {
    case "jpeg":
        type = UTType.jpeg.identifier
        props[kCGImageDestinationLossyCompressionQuality] = 0.85
    case "png": type = UTType.png.identifier
    case "gif": type = UTType.gif.identifier
    case "heic":
        type = UTType.heic.identifier
        props[kCGImageDestinationLossyCompressionQuality] = 0.8
    case "tiff":
        type = UTType.tiff.identifier
        props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
    default: die("unknown format \(format)")
    }
    guard let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)
    else { die("cannot start \(url.path)") }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) { die("cannot encode \(url.path) as \(format)") }
}

func decodes(_ url: URL, width: Int, height: Int) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return false }
    return img.width == width && img.height == height
}

func photos(jobsFile: String, outDir: String) {
    guard let text = try? String(contentsOfFile: jobsFile, encoding: .utf8) else { die("cannot read \(jobsFile)") }
    var n = 0
    for raw in text.split(separator: "\n") where !raw.isEmpty {
        let f = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 8 else { die("job line has \(f.count) fields, expected 8: \(raw)") }
        let job = Job(path: f[0], format: f[1], role: f[2], c1: f[3], c2: f[4], c3: f[5], objects: f[6], text: f[7])
        let isShot = job.role == "screenshot", isToken = job.role == "token"
        let w = isToken ? 900 : isShot ? 1280 : 640, h = isToken ? 420 : isShot ? 800 : 480
        let ctx = isToken ? drawToken(job, w: w, h: h) : isShot ? drawScreenshot(job, w: w, h: h) : drawPhoto(job, w: w, h: h)
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(job.path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(ctx, format: job.format, to: url)
        if !decodes(url, width: w, height: h) { die("\(job.path) was written but does not read back as a \(w) x \(h) \(job.format)") }
        n += 1
    }
    print("drew \(n) pictures")
}

func pdfMake(out: String, text: String) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(URL(fileURLWithPath: out) as CFURL, mediaBox: &box, nil) else { die("cannot make \(out)") }
    ctx.beginPDFPage(nil)
    ctx.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(textLine(text, font: "Helvetica", size: 18, color: rgb("#000000")), ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}

func pdfRead(_ path: String) {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { die("cannot open \(path)") }
    print("pages \(doc.pageCount)")
    print(doc.string ?? "")
}

// ---- PDFs written by hand (plan 4, kit part 1): the golden PDFs and the boundary PDFs. The bytes are written by this
// program (no PDF writer of the system: it stamps the clock and, for a locked file, random bytes), so two runs write the
// same bytes. One job is a block of lines:
//   PDF <path> <kind> <pages> <title> <password or ->     kind text, picture, locked or damaged
//   TXT <page> <x> <y> <w> <h> <size> <text>              text wrapped inside the box (points, origin bottom left)
// text: Helvetica text on every page (a title, three filler lines, the passages). picture: every page drawn to a 612 x 792
// bitmap, stored as a JPEG with no text layer. locked: a text PDF encrypted with the standard handler (RC4, 128 bit,
// revision 3) with the given user password, fixed owner password and file id. damaged: a text PDF cut after 200 bytes.
struct PdfPass {
    let page: Int
    let x, y, w, h, size: Double
    let text: String
}

struct PdfJob {
    let path, kind, title, password: String
    let pages: Int
    var passes: [PdfPass] = []
}

let pdfFillers = [
    "General terms apply to every section of this document.",
    "Please keep a copy of this page with your other records.",
    "Amounts are shown in local currency unless stated otherwise.",
    "This page was prepared for the person named on the first page.",
    "Questions about this document can be sent to the office in writing.",
    "All dates follow the calendar year unless a section says otherwise.",
    "Further details are listed in the sections that follow.",
    "Changes to this document are made only in writing.",
]

func textWidth(_ s: String, size: Double) -> Double {
    Double(CTLineGetTypographicBounds(textLine(s, font: "Helvetica", size: CGFloat(size), color: rgb("#000000")), nil, nil, nil))
}

/// The words of the text in lines no wider than `width` points.
func wrapLines(_ text: String, width: Double, size: Double) -> [String] {
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        let trial = current.isEmpty ? String(word) : current + " " + word
        if current.isEmpty || textWidth(trial, size: size) <= width {
            current = trial
        } else {
            lines.append(current)
            current = String(word)
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// The baselines of a passage: lines from the top of the box down, 1.25 leading; stops when the lines do not fit.
func passageLines(_ pass: PdfPass, path: String) -> [(text: String, y: Double)] {
    let lines = wrapLines(pass.text, width: pass.w, size: pass.size)
    let leading = pass.size * 1.25
    var out: [(String, Double)] = []
    for (i, line) in lines.enumerated() {
        let y = pass.y + pass.h - pass.size - Double(i) * leading
        if y - pass.size * 0.25 < pass.y - 0.5 { die("\(path) page \(pass.page): the passage does not fit its box (\(lines.count) lines): \(pass.text)") }
        out.append((line, y))
    }
    return out
}

func pdfNumber(_ v: Double) -> String { String(format: "%g", v) }

func pdfString(_ s: String, path: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        if u.value < 32 || u.value > 126 { die("\(path): text outside plain ASCII: \(s)") }
        if u == "(" || u == ")" || u == "\\" { out += "\\" }
        out.unicodeScalars.append(u)
    }
    return out
}

func textOp(_ s: String, x: Double, y: Double, size: Double, path: String) -> String {
    "BT /F1 \(pdfNumber(size)) Tf \(pdfNumber(x)) \(pdfNumber(y)) Td (\(pdfString(s, path: path))) Tj ET\n"
}

func textPageContent(_ job: PdfJob, page: Int) -> String {
    var s = textOp(job.title, x: 72, y: 740, size: 16, path: job.path)
    for i in 0..<3 {
        s += textOp(pdfFillers[(page * 3 + i) % pdfFillers.count], x: 72, y: 712 - Double(i) * 16, size: 11, path: job.path)
    }
    for pass in job.passes where pass.page == page {
        for l in passageLines(pass, path: job.path) { s += textOp(l.text, x: pass.x, y: l.y, size: pass.size, path: job.path) }
    }
    return s
}

func drawPicturePage(_ job: PdfJob, page: Int) -> CGImage {
    let ctx = makeContext(612, 792)
    ctx.setFillColor(rgb("#ffffff"))
    ctx.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    let black = rgb("#000000")
    ctx.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(textLine("\(job.title) page \(page)", font: "Helvetica", size: 30, color: black), ctx)
    ctx.textPosition = CGPoint(x: 72, y: 650)
    CTLineDraw(textLine("Chapter \((page - 1) / 6 + 1) figures and notes", font: "Helvetica", size: 22, color: black), ctx)
    for pass in job.passes where pass.page == page {
        for l in passageLines(pass, path: job.path) {
            ctx.textPosition = CGPoint(x: pass.x, y: l.y)
            CTLineDraw(textLine(l.text, font: "Helvetica", size: CGFloat(pass.size), color: black), ctx)
        }
    }
    guard let image = ctx.makeImage() else { die("\(job.path): cannot draw page \(page)") }
    return image
}

func jpegBytes(_ image: CGImage, path: String) -> [UInt8] {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { die("\(path): no JPEG encoder") }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    if !CGImageDestinationFinalize(dest) { die("\(path): cannot encode a page picture") }
    return [UInt8](data as Data)
}

func rc4(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
    var s = (0..<256).map { UInt8($0) }
    var j = 0
    for i in 0..<256 {
        j = (j + Int(s[i]) + Int(key[i % key.count])) & 255
        s.swapAt(i, j)
    }
    var out = data
    var i = 0
    j = 0
    for k in 0..<data.count {
        i = (i + 1) & 255
        j = (j + Int(s[i])) & 255
        s.swapAt(i, j)
        out[k] ^= s[(Int(s[i]) + Int(s[j])) & 255]
    }
    return out
}

func md5(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: Data(bytes))) }

func hexBytes(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

/// The standard security handler, revision 3 (RC4 with a 128 bit key): the owner and user entries, the file key and the
/// object keys. Everything is computed from the two passwords and a fixed file id, so the bytes repeat.
struct Encryption {
    static let padding: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ]
    let fileKey: [UInt8]
    let owner: [UInt8]
    let user: [UInt8]
    let id: [UInt8]

    init(userPassword: String, ownerPassword: String) {
        func padded(_ pw: String) -> [UInt8] { Array((Array(pw.utf8) + Encryption.padding).prefix(32)) }
        var h = md5(padded(ownerPassword))
        for _ in 0..<50 { h = md5(h) }
        let ownerKey = Array(h.prefix(16))
        var o = rc4(ownerKey, padded(userPassword))
        for i in 1...19 { o = rc4(ownerKey.map { $0 ^ UInt8(i) }, o) }
        let permissions: [UInt8] = [0xFC, 0xFF, 0xFF, 0xFF]   // -4: everything allowed
        let fileId = md5(Array("sesame-kit golden-docs locked pdf".utf8))
        var k = md5(padded(userPassword) + o + permissions + fileId)
        for _ in 0..<50 { k = md5(Array(k.prefix(16))) }
        let key = Array(k.prefix(16))
        var u = rc4(key, md5(Encryption.padding + fileId))
        for i in 1...19 { u = rc4(key.map { $0 ^ UInt8(i) }, u) }
        self.fileKey = key
        self.owner = o
        self.user = u + [UInt8](repeating: 0, count: 16)
        self.id = fileId
    }

    func encrypt(_ data: [UInt8], object n: Int) -> [UInt8] {
        let objectKey = Array(md5(fileKey + [UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), 0, 0]).prefix(16))
        return rc4(objectKey, data)
    }
}

enum PdfObject {
    case plain([UInt8])
    case stream(dict: String, data: [UInt8])
}

func pdfBytes(_ job: PdfJob) -> [UInt8] {
    let picture = job.kind == "picture"
    var objects: [PdfObject] = [.plain([]), .plain([]), .plain(Array("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8))]
    var kids: [Int] = []
    for page in 1...job.pages {
        let pageNumber = objects.count + 1
        kids.append(pageNumber)
        if picture {
            let image = jpegBytes(drawPicturePage(job, page: page), path: job.path)
            objects.append(.plain(Array("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(pageNumber + 1) 0 R /Resources << /XObject << /Im0 \(pageNumber + 2) 0 R >> >> >>".utf8)))
            objects.append(.stream(dict: "", data: Array("q 612 0 0 792 0 0 cm /Im0 Do Q\n".utf8)))
            objects.append(.stream(dict: "/Type /XObject /Subtype /Image /Width 612 /Height 792 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", data: image))
        } else {
            objects.append(.plain(Array("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(pageNumber + 1) 0 R /Resources << /Font << /F1 3 0 R >> >> >>".utf8)))
            objects.append(.stream(dict: "", data: Array(textPageContent(job, page: page).utf8)))
        }
    }
    objects[0] = .plain(Array("<< /Type /Catalog /Pages 2 0 R >>".utf8))
    objects[1] = .plain(Array("<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(job.pages) >>".utf8))
    var encryption: Encryption?
    if job.kind == "locked" {
        let e = Encryption(userPassword: job.password, ownerPassword: "kit-owner-7")
        encryption = e
        objects.append(.plain(Array("<< /Filter /Standard /V 2 /R 3 /Length 128 /P -4 /O <\(hexBytes(e.owner))> /U <\(hexBytes(e.user))> >>".utf8)))
    }
    var out: [UInt8] = Array("%PDF-1.4\n".utf8) + [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
    var offsets: [Int] = []
    for (i, object) in objects.enumerated() {
        let number = i + 1
        offsets.append(out.count)
        out += Array("\(number) 0 obj\n".utf8)
        switch object {
        case .plain(let body):
            out += body
        case .stream(let dict, let raw):
            let data = (encryption != nil && number != objects.count) ? encryption!.encrypt(raw, object: number) : raw
            out += Array("<< \(dict) /Length \(data.count) >>\nstream\n".utf8) + data + Array("\nendstream".utf8)
        }
        out += Array("\nendobj\n".utf8)
    }
    let xref = out.count
    out += Array("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
    for o in offsets { out += Array(String(format: "%010d 00000 n \n", o).utf8) }
    var trailer = "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R"
    if let e = encryption { trailer += " /Encrypt \(objects.count) 0 R /ID [<\(hexBytes(e.id))> <\(hexBytes(e.id))>]" }
    trailer += " >>\nstartxref\n\(xref)\n%%EOF\n"
    out += Array(trailer.utf8)
    return out
}

func pdfs(jobsFile: String, outDir: String) {
    guard let text = try? String(contentsOfFile: jobsFile, encoding: .utf8) else { die("cannot read \(jobsFile)") }
    var jobs: [PdfJob] = []
    for raw in text.split(separator: "\n") where !raw.isEmpty {
        let f = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch f[0] {
        case "PDF":
            guard f.count == 6, let pages = Int(f[3]), pages >= 1, ["text", "picture", "locked", "damaged"].contains(f[2]) else { die("bad PDF line: \(raw)") }
            jobs.append(PdfJob(path: f[1], kind: f[2], title: f[4], password: f[5], pages: pages))
        case "TXT":
            guard f.count == 8, !jobs.isEmpty, let page = Int(f[1]), let x = Double(f[2]), let y = Double(f[3]), let w = Double(f[4]),
                let h = Double(f[5]), let size = Double(f[6]) else { die("bad TXT line: \(raw)") }
            if page > jobs[jobs.count - 1].pages { die("\(jobs[jobs.count - 1].path): a passage on page \(page) of \(jobs[jobs.count - 1].pages)") }
            jobs[jobs.count - 1].passes.append(PdfPass(page: page, x: x, y: y, w: w, h: h, size: size, text: f[7]))
        default: die("unknown line: \(raw)")
        }
    }
    for job in jobs {
        var bytes = pdfBytes(job)
        if job.kind == "damaged" { bytes = Array(bytes.prefix(200)) }
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(job.path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try Data(bytes).write(to: url) } catch { die("cannot write \(job.path)") }
    }
    print("wrote \(jobs.count) pdfs")
}

// ---- noise: deterministic junk bytes (a damaged file whose bytes are random).
func noise(out: String, bytes: Int, seed: UInt64) {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    if state == 0 { state = 88172645463325252 }
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { raw in
        for i in 0..<bytes {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            raw[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
    }
    do { try data.write(to: URL(fileURLWithPath: out)) } catch { die("cannot write \(out)") }
}

// ---- filler: small generated photos for the 50,000-row index (three index rows a photo, guess G4).
// Photo i is a 32 x 32 JPEG whose colours depend on i modulo 8 and which carries the comment
// "kit filler <i>", so every file has its own bytes and every file decodes. Files are spread over
// folders of 500 (d000/f000000.jpg ...). Drawing is fixed, so two runs write the same bytes.
let fillerPalette: [(String, String)] = [
    ("#e57373", "#ffcdd2"), ("#64b5f6", "#bbdefb"), ("#81c784", "#c8e6c9"), ("#ffd54f", "#fff9c4"),
    ("#ba68c8", "#e1bee7"), ("#4db6ac", "#b2dfdb"), ("#ff8a65", "#ffccbc"), ("#90a4ae", "#cfd8dc"),
]

func fillerBase(_ k: Int) -> [UInt8] {
    let ctx = makeContext(32, 32)
    let colors = [rgb(fillerPalette[k].0), rgb(fillerPalette[k].1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 32), end: CGPoint(x: 0, y: 0), options: [])
    let data = NSMutableData()
    guard let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    else { die("cannot start a filler picture") }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    if !CGImageDestinationFinalize(dest) { die("cannot encode a filler picture") }
    return [UInt8](data as Data)
}

func fillerFile(_ i: Int, bases: [[UInt8]]) -> Data {
    let base = bases[i % bases.count]
    let comment = Array("kit filler \(i)".utf8)
    var pos = 2
    if base.count > 6, base[2] == 0xFF, base[3] == 0xE0 { pos = 4 + (Int(base[4]) << 8 | Int(base[5])) }
    let len = comment.count + 2
    var out = Array(base[0..<pos])
    out += [0xFF, 0xFE, UInt8(len >> 8), UInt8(len & 255)] + comment
    out += base[pos...]
    return Data(out)
}

func fillerRel(_ i: Int) -> String { String(format: "d%03d/f%06d.jpg", i / 500, i) }

// check: exit 0 and "ok" when the folder holds exactly the photos, with the right bytes and time;
// else prints the first difference and exits 1. write: writes only the files that differ, removes
// every other file and folder, prints the counts.
func filler(mode: String, outDir: String, count: Int, epoch: Double) {
    let fm = FileManager.default
    let bases = (0..<fillerPalette.count).map(fillerBase)
    let root = URL(fileURLWithPath: outDir)
    var wantedFiles = Set<String>()
    var wantedDirs = Set<String>()
    var written = 0, kept = 0, removed = 0
    for i in 0..<count {
        let rel = fillerRel(i)
        wantedFiles.insert(rel)
        wantedDirs.insert(String(rel.split(separator: "/")[0]))
        let url = root.appendingPathComponent(rel)
        let want = fillerFile(i, bases: bases)
        var same = false
        if let have = fm.contents(atPath: url.path), have == want,
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let m = attrs[.modificationDate] as? Date, Int(m.timeIntervalSince1970) == Int(epoch)
        {
            same = true
        }
        if same { kept += 1; continue }
        if mode == "check" {
            print("differs \(rel)")
            exit(1)
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try want.write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: epoch)], ofItemAtPath: url.path)
        } catch { die("cannot write \(url.path)") }
        written += 1
    }
    var strayFiles = [String]()
    if let walker = fm.enumerator(atPath: outDir) {
        for case let rel as String in walker {
            if rel.hasSuffix(".DS_Store") { continue }
            let type = (walker.fileAttributes?[.type] as? FileAttributeType)
            if type == .typeRegular && !wantedFiles.contains(rel) { strayFiles.append(rel) }
            if type != .typeRegular && type != .typeDirectory { strayFiles.append(rel) }
        }
    }
    if mode == "check" {
        if let first = strayFiles.first {
            print("differs stray \(first)")
            exit(1)
        }
        var extraDir: String?
        for entry in (try? fm.contentsOfDirectory(atPath: outDir)) ?? [] where !wantedDirs.contains(entry) && entry != ".DS_Store" {
            extraDir = entry
        }
        if let d = extraDir {
            print("differs stray folder \(d)")
            exit(1)
        }
        print("ok")
        exit(0)
    }
    for rel in strayFiles {
        try? fm.removeItem(atPath: root.appendingPathComponent(rel).path)
        removed += 1
    }
    for entry in (try? fm.contentsOfDirectory(atPath: outDir)) ?? [] where !wantedDirs.contains(entry) {
        try? fm.removeItem(atPath: root.appendingPathComponent(entry).path)
    }
    print("written \(written) kept \(kept) removed \(removed)")
}

let args = CommandLine.arguments
switch (args.count > 1 ? args[1] : "", args.count) {
case ("photos", 4): photos(jobsFile: args[2], outDir: args[3])
case ("pdf-make", 4): pdfMake(out: args[2], text: args[3])
case ("pdf-read", 3): pdfRead(args[2])
case ("pdfs", 4): pdfs(jobsFile: args[2], outDir: args[3])
case ("noise", 5):
    guard let n = Int(args[3]), n >= 0, let s = UInt64(args[4]) else { die("noise: bytes and seed must be whole numbers") }
    noise(out: args[2], bytes: n, seed: s)
case ("filler-check", 5), ("filler-write", 5):
    guard let n = Int(args[3]), n >= 0, let e = Double(args[4]) else { die("filler: count and epoch must be numbers") }
    filler(mode: args[1] == "filler-check" ? "check" : "write", outDir: args[2], count: n, epoch: e)
default:
    die(
        "usage: fixturegen photos <jobs.tsv> <outdir> | pdfs <jobs.tsv> <outdir> | pdf-make <out> <text> | pdf-read <file> | noise <out> <bytes> <seed> | filler-check|filler-write <outdir> <count> <epoch>"
    )
}
