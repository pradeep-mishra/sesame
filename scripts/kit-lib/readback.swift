// The kit's readback tool: what the Mac itself says, read through Apple's own APIs. It never posts a key,
// never opens an app and never changes a file of the person's (it writes only the PNG it is told to write).
// scripts/kit-readback.sh runs it.
//
//   readback pasteboard                 the general pasteboard: file URLs as "file <path>", a string as "string <text>";
//                                       a pasteboard that holds only a string prints the text itself, nothing else
//   readback default-app <ext>          the app Launch Services names to open a file with that extension
//   readback app-installed <bundle id>  the app's path, or exit 1 when none is installed
//   readback pdf-pages <pdf>            the page count alone; exit 1 for a file that is missing, damaged, locked or empty
//   readback render-pdf-page <pdf> <n> <out.png>
//                                       page n (1-based) at the fixed scale (2: points times 2 pixels), white background;
//                                       prints `wrote <out> <w> x <h> pixels, scale 2`; exit 1 when n is out of range
//   readback page-scores <shot.png> <pdf>
//                                       finds each page of the PDF inside the picture (zero-mean normalised cross
//                                       correlation over scale and place) and prints `score <n> <value>` for every page,
//                                       then `page <n> via picture` (exit 0) when the best page is at least 0.55 and ahead
//                                       of the runner-up by 0.15, else `NEEDS A PERSON: ...` (exit 3)
//   readback mark-check <shot.png> <pdf> <page> <x:y:w:h>
//                                       finds the page inside the picture, takes the contiguous region whose colour the
//                                       unmarked render does not hold, and compares it with the passage box (points, origin
//                                       bottom left). Prints `match`, `pixels`, `region x y w h`, `inside` and `overlap`;
//                                       exit 0 pass, 1 no mark or a mark that misses the box, 4 no picture of the page
//
//   readback speech-assets              `true <locale>` or `false <locale>`: SFSpeechRecognizer.supportsOnDeviceRecognition for the system language
//   readback waveform-check <shot.png> <audio> <start-s>
//                                       the bars drawn in the picture against the 30 s blocks (5 s steps, one RMS value a second) of the
//                                       audio file; prints `bars`, `best <s> correlation <c>`, `earlier`, `later` and a verdict line; exit
//                                       0 the drawn waveform is the block within 2 s of <start-s> (correlation 0.70 or more, and it beats
//                                       the blocks 30 s earlier and later), 1 not, 4 no readable picture
//   readback frame-check <shot.png> <video> <second>
//                                       finds the video's frame at <second> and the one 20 s earlier inside the picture; prints `frame now`
//                                       and `frame earlier` (correlations); exit 0 when the first is at least 0.55 and 0.05 above the
//                                       second, 1 not, 4 no readable picture
//
// Exit codes: 0 done; 1 nothing found; 2 usage; 3 NEEDS A PERSON; 4 not valid.
import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Speech
import UniformTypeIdentifiers

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func usage() -> Never {
    fail("""
    usage: readback pasteboard
           readback default-app <ext>
           readback app-installed <bundle id>
           readback pdf-pages <pdf>
           readback render-pdf-page <pdf> <n> <out.png>
           readback page-scores <shot.png> <pdf>
           readback mark-check <shot.png> <pdf> <page> <x:y:w:h>
    """, 2)
}

func appName(_ url: URL) -> String {
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
}

// MARK: PDF pages and pictures

/// The fixed scale of render-pdf-page and of the reference of mark-check: pixels per point.
let renderScale: CGFloat = 2

func openPDF(_ path: String) -> PDFDocument {
    guard FileManager.default.fileExists(atPath: path) else { fail("no such file: \(path)") }
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { fail("damaged: \(path) cannot be opened as a PDF") }
    if doc.isLocked { fail("locked: \(path) is password-protected") }
    if doc.pageCount < 1 { fail("damaged: \(path) has no pages") }
    return doc
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
    let b = page.bounds(for: .mediaBox)
    let w = Int((b.width * scale).rounded()), h = Int((b.height * scale).rounded())
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: CGFloat(w) / b.width, y: CGFloat(h) / b.height)
    ctx.translateBy(x: -b.origin.x, y: -b.origin.y)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func readImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("cannot read the picture: \(path)")
    }
    return image
}

/// Top row first, RGBA, drawn over white.
struct Bitmap {
    let w: Int
    let h: Int
    var rgba: [UInt8]
}

func bitmap(_ image: CGImage) -> Bitmap {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Bitmap(w: w, h: h, rgba: data)
}

func lumaOf(_ b: Bitmap) -> [Float] {
    var out = [Float](repeating: 0, count: b.w * b.h)
    b.rgba.withUnsafeBufferPointer { p in
        for i in 0..<(b.w * b.h) {
            out[i] = 0.299 * Float(p[i * 4]) + 0.587 * Float(p[i * 4 + 1]) + 0.114 * Float(p[i * 4 + 2])
        }
    }
    return out
}

/// A summed-area table: the sum of any rectangle of the picture in four reads.
struct Sat {
    let w: Int
    let h: Int
    var s: [Double]

    init(w: Int, h: Int, value: (Int) -> Double) {
        self.w = w
        self.h = h
        var t = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += value(y * w + x)
                t[(y + 1) * (w + 1) + x + 1] = t[y * (w + 1) + x + 1] + row
            }
        }
        s = t
    }

    /// The sum over x in [x0, x1) and y in [y0, y1), the rectangle clamped to the picture.
    @inline(__always)
    func sum(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
        let ax = min(max(x0, 0), w), bx = min(max(x1, 0), w), ay = min(max(y0, 0), h), by = min(max(y1, 0), h)
        return s[by * (w + 1) + bx] - s[ay * (w + 1) + bx] - s[by * (w + 1) + ax] + s[ay * (w + 1) + ax]
    }

    /// The mean over a fractional rectangle (rounded to whole pixels, at least one).
    @inline(__always)
    func mean(_ fx0: Double, _ fy0: Double, _ fx1: Double, _ fy1: Double) -> Double {
        let x0 = Int(fx0.rounded()), y0 = Int(fy0.rounded())
        let x1 = max(x0 + 1, Int(fx1.rounded())), y1 = max(y0 + 1, Int(fy1.rounded()))
        let cx0 = min(max(x0, 0), w - 1), cy0 = min(max(y0, 0), h - 1)
        let cx1 = min(max(x1, cx0 + 1), w), cy1 = min(max(y1, cy0 + 1), h)
        return sum(cx0, cy0, cx1, cy1) / Double((cx1 - cx0) * (cy1 - cy0))
    }
}

func downsample(_ g: [Float], w: Int, h: Int, by ds: Int) -> (px: [Float], w: Int, h: Int) {
    if ds <= 1 { return (g, w, h) }
    let gw = w / ds, gh = h / ds
    var out = [Float](repeating: 0, count: gw * gh)
    let inv = 1 / Float(ds * ds)
    for y in 0..<gh {
        for x in 0..<gw {
            var s: Float = 0
            for dy in 0..<ds {
                let row = (y * ds + dy) * w + x * ds
                for dx in 0..<ds { s += g[row + dx] }
            }
            out[y * gw + x] = s * inv
        }
    }
    return (out, gw, gh)
}

/// Where the page's reference sits in a picture: a shot pixel (x, y) shows the reference pixel ((x - ox) / k, (y - oy) / k).
struct Placement {
    var score: Double
    var k: Double
    var ox: Int
    var oy: Int
}

/// The reference at scale k, sampled for a shot made smaller by `ds`, correlated with the shot over a range of places (in shot pixels
/// divided by ds). Returns the best zero-mean normalised correlation and its place, or nil when the template does not fit or is flat.
func correlate(shot: [Float], gw: Int, gh: Int, ds: Int, ref: Sat, k: Double, xs: ClosedRange<Int>? = nil, ys: ClosedRange<Int>? = nil, samples: Double = 1500) -> (score: Double, px: Int, py: Int)? {
    let tw = Int((Double(ref.w) * k / Double(ds)).rounded()), th = Int((Double(ref.h) * k / Double(ds)).rounded())
    guard tw >= 6, th >= 6, tw <= gw, th <= gh else { return nil }
    let step = Double(ds) / k
    let st = max(1, Int(sqrt(Double(tw * th) / samples).rounded(.up)))
    var tv: [Double] = []
    var toff: [Int] = []
    var j = 0
    while j < th {
        var i = 0
        while i < tw {
            tv.append(ref.mean(Double(i) * step, Double(j) * step, Double(i + 1) * step, Double(j + 1) * step))
            toff.append(j * gw + i)
            i += st
        }
        j += st
    }
    let n = Double(tv.count)
    var sumT = 0.0, sumTT = 0.0
    for v in tv { sumT += v; sumTT += v * v }
    let varT = sumTT - sumT * sumT / n
    guard varT > 1e-3 else { return nil }
    let xLo = max(xs?.lowerBound ?? 0, 0), xHi = min(xs?.upperBound ?? (gw - tw), gw - tw)
    let yLo = max(ys?.lowerBound ?? 0, 0), yHi = min(ys?.upperBound ?? (gh - th), gh - th)
    guard xLo <= xHi, yLo <= yHi else { return nil }
    let xr = xLo...xHi, yr = yLo...yHi
    var best = (score: -2.0, px: 0, py: 0)
    let count = tv.count
    shot.withUnsafeBufferPointer { sp in
        tv.withUnsafeBufferPointer { tp in
            toff.withUnsafeBufferPointer { op in
                for py in yr {
                    for px in xr {
                        let base = py * gw + px
                        var sg = 0.0, sgg = 0.0, sgt = 0.0
                        for s in 0..<count {
                            let g = Double(sp[base + op[s]])
                            sg += g
                            sgg += g * g
                            sgt += g * tp[s]
                        }
                        let varG = sgg - sg * sg / n
                        var score = 0.0
                        if varG > 1e-3 { score = (sgt - sg * sumT / n) / (varG * varT).squareRoot() }
                        if score > best.score { best = (score, px, py) }
                    }
                }
            }
        }
    }
    return best.score > -2 ? best : nil
}

/// The coarse search of one page: the best places at about 160 pixels across, a scale at every 6 percent from the largest page that fits.
/// Returns the three best (score, k, place in units of ds) and ds.
func coarseSearch(shot: [Float], w: Int, h: Int, ref: Sat) -> (seeds: [(score: Double, k: Double, px: Int, py: Int)], ds: Int) {
    let ds = max(1, Int((Double(max(w, h)) / 160).rounded(.up)))
    let (g, gw, gh) = downsample(shot, w: w, h: h, by: ds)
    let kmin = max(12 * Double(ds) / Double(ref.w), 12 * Double(ds) / Double(ref.h))
    let kmax = min(Double(gw) * Double(ds) / Double(ref.w), Double(gh) * Double(ds) / Double(ref.h))
    var found: [(score: Double, k: Double, px: Int, py: Int)] = []
    guard kmin <= kmax else { return ([], ds) }
    var k = kmax
    while k >= kmin {
        if let hit = correlate(shot: g, gw: gw, gh: gh, ds: ds, ref: ref, k: k) { found.append((hit.score, k, hit.px, hit.py)) }
        k /= 1.06
    }
    found.sort { $0.score > $1.score }
    return (Array(found.prefix(3)), ds)
}

/// The refinement of the seeds of a coarse search: two finer passes around each, the better one kept.
func refine(shot: [Float], w: Int, h: Int, ref: Sat, seeds: [(score: Double, k: Double, px: Int, py: Int)], ds: Int) -> Placement? {
    var best: Placement?
    let ds2 = max(1, ds / 4)
    let (g2, gw2, gh2) = downsample(shot, w: w, h: h, by: ds2)
    for seed in seeds {
        // pass A: scale within 7 percent at 1 percent, place within two coarse cells
        var a: (score: Double, k: Double, px: Int, py: Int)?
        let cx = seed.px * ds / ds2, cy = seed.py * ds / ds2
        let r = (ds / ds2) * 2 + 2
        var f = 0.93
        while f <= 1.0701 {
            let k = seed.k * f
            if let hit = correlate(shot: g2, gw: gw2, gh: gh2, ds: ds2, ref: ref, k: k, xs: (cx - r)...(cx + r), ys: (cy - r)...(cy + r), samples: 3000),
               hit.score > (a?.score ?? -2) { a = (hit.score, k, hit.px, hit.py) }
            f += 0.01
        }
        guard let a = a else { continue }
        // pass B: full resolution, scale within one percent at a quarter percent, place within two cells of pass A
        var b: Placement?
        let bx = a.px * ds2, by = a.py * ds2
        let rb = ds2 * 2 + 2
        let full = ds2 == 1 ? (g2, gw2, gh2) : (shot, w, h)
        var f2 = 0.99
        while f2 <= 1.0101 {
            let k = a.k * f2
            if let hit = correlate(shot: full.0, gw: full.1, gh: full.2, ds: 1, ref: ref, k: k, xs: (bx - rb)...(bx + rb), ys: (by - rb)...(by + rb), samples: 6000),
               hit.score > (b?.score ?? -2) { b = Placement(score: hit.score, k: k, ox: hit.px, oy: hit.py) }
            f2 += 0.0025
        }
        if let b = b, b.score > (best?.score ?? -2) { best = b }
    }
    return best
}

func luminance(_ image: CGImage) -> (px: [Float], w: Int, h: Int) {
    let b = bitmap(image)
    return (lumaOf(b), b.w, b.h)
}

func lumaSat(_ image: CGImage) -> Sat {
    let l = lumaOf(bitmap(image))
    let w = image.width, h = image.height
    return Sat(w: w, h: h) { Double(l[$0]) }
}

let matchThreshold = 0.55
let pageMargin = 0.15

func fixed(_ v: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", v) }

// MARK: the commands

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "pasteboard":
    guard args.count == 1 else { usage() }
    let board = NSPasteboard.general
    var files: [String] = []
    for item in board.pasteboardItems ?? [] {
        if let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL {
            files.append(url.path)
        }
    }
    let text = board.string(forType: .string)
    if files.isEmpty {
        if let text = text { print(text) } else { print("pasteboard is empty") }
    } else {
        for path in files { print("file \(path)") }
        if let text = text { print("string \(text)") }
    }

case "default-app":
    guard args.count == 2 else { usage() }
    let ext = args[1].hasPrefix(".") ? String(args[1].dropFirst()) : args[1]
    guard let type = UTType(filenameExtension: ext) else { fail("no type is known for the extension \(ext)") }
    guard let app = NSWorkspace.shared.urlForApplication(toOpen: type) else {
        fail("Launch Services names no app for .\(ext)")
    }
    print(appName(app))

case "app-installed":
    guard args.count == 2 else { usage() }
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: args[1]) else {
        fail("not installed: \(args[1])")
    }
    print(app.path)

case "pdf-pages":
    guard args.count == 2 else { usage() }
    print(openPDF(args[1]).pageCount)

case "render-pdf-page":
    guard args.count == 4, let n = Int(args[2]) else { usage() }
    let doc = openPDF(args[1])
    guard n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else { fail("page \(n) is out of range: the file has \(doc.pageCount) pages") }
    guard let image = renderPage(page, scale: renderScale), writePNG(image, to: args[3]) else { fail("could not render page \(n) to \(args[3])") }
    print("wrote \(args[3]) \(image.width) x \(image.height) pixels, scale \(Int(renderScale))")

case "page-scores":
    guard args.count == 3 else { usage() }
    let doc = openPDF(args[2])
    let shot = luminance(readImage(args[1]))
    // every page at scale 1 (the pictures are only matched, never marked)
    var refs: [Sat?] = []
    var coarse: [(seeds: [(score: Double, k: Double, px: Int, py: Int)], ds: Int)] = []
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i), let image = renderPage(page, scale: 1) else { refs.append(nil); coarse.append(([], 1)); continue }
        let sat = lumaSat(image)
        refs.append(sat)
        coarse.append(coarseSearch(shot: shot.px, w: shot.w, h: shot.h, ref: sat))
    }
    var scores = [Double](repeating: -1, count: doc.pageCount)
    for i in 0..<doc.pageCount { scores[i] = coarse[i].seeds.first?.score ?? 0 }
    // the four best by the coarse reading are measured again, finer; the others keep their coarse score (which can only hold a page back)
    let order = (0..<doc.pageCount).sorted { scores[$0] > scores[$1] }
    for i in order.prefix(4) {
        guard let sat = refs[i], !coarse[i].seeds.isEmpty else { continue }
        scores[i] = refine(shot: shot.px, w: shot.w, h: shot.h, ref: sat, seeds: coarse[i].seeds, ds: coarse[i].ds)?.score ?? 0
    }
    for i in 0..<doc.pageCount { print("score \(i + 1) \(fixed(scores[i]))") }
    let ranked = (0..<doc.pageCount).sorted { scores[$0] > scores[$1] }
    let top = ranked[0]
    let second = ranked.count > 1 ? scores[ranked[1]] : -1
    if scores[top] >= matchThreshold && scores[top] - second >= pageMargin {
        print("page \(top + 1) via picture")
    } else if scores[top] < matchThreshold {
        print("NEEDS A PERSON: no page of the file matches the picture (the best, page \(top + 1), scores \(fixed(scores[top])), the bar is \(matchThreshold))")
        exit(3)
    } else {
        print("NEEDS A PERSON: the page images are too similar for the picture to tell the pages apart (page \(top + 1) scores \(fixed(scores[top])), the runner-up \(fixed(second)), the margin is \(pageMargin)); the window title reading (preview-page with no flag) is preferred")
        exit(3)
    }

case "mark-check":
    guard args.count == 5, let pageNo = Int(args[3]) else { usage() }
    let box = args[4].split(separator: ":").compactMap { Double($0) }
    guard box.count == 4 else { usage() }
    let doc = openPDF(args[2])
    guard pageNo >= 1, pageNo <= doc.pageCount, let page = doc.page(at: pageNo - 1), let refImage = renderPage(page, scale: renderScale) else {
        fail("page \(pageNo) is out of range: the file has \(doc.pageCount) pages")
    }
    let shotImage = readImage(args[1])
    let shotBM = bitmap(shotImage)
    let shotLuma = lumaOf(shotBM)
    let ref = bitmap(refImage)
    let refSat = Sat(w: ref.w, h: ref.h) { Double(lumaOf1(ref, $0)) }
    let (seeds, ds) = coarseSearch(shot: shotLuma, w: shotBM.w, h: shotBM.h, ref: refSat)
    guard !seeds.isEmpty, let place = refine(shot: shotLuma, w: shotBM.w, h: shotBM.h, ref: refSat, seeds: seeds, ds: ds), place.score >= matchThreshold else {
        let got = seeds.isEmpty ? "no place for a page of this size" : "best match below \(matchThreshold)"
        print("no picture of page \(pageNo) in the shot: \(got)")
        exit(4)
    }
    print("match \(fixed(place.score, 2)) scale \(fixed(place.k)) offset \(place.ox) \(place.oy)")
    // the colour of the reference under each shot pixel, by summed-area tables of the three channels
    let rSat = Sat(w: ref.w, h: ref.h) { Double(ref.rgba[$0 * 4]) }
    let gSat = Sat(w: ref.w, h: ref.h) { Double(ref.rgba[$0 * 4 + 1]) }
    let bSat = Sat(w: ref.w, h: ref.h) { Double(ref.rgba[$0 * 4 + 2]) }
    let k = place.k
    let sw = shotBM.w, sh = shotBM.h
    let x0 = max(0, place.ox), y0 = max(0, place.oy)
    let x1 = min(sw, place.ox + Int((Double(ref.w) * k).rounded())), y1 = min(sh, place.oy + Int((Double(ref.h) * k).rounded()))
    var mask = [Bool](repeating: false, count: sw * sh)
    if x1 > x0 && y1 > y0 {
        for y in y0..<y1 {
            for x in x0..<x1 {
                let fx0 = (Double(x - place.ox)) / k, fy0 = (Double(y - place.oy)) / k
                let fx1 = (Double(x + 1 - place.ox)) / k, fy1 = (Double(y + 1 - place.oy)) / k
                let r = rSat.mean(fx0, fy0, fx1, fy1), g = gSat.mean(fx0, fy0, fx1, fy1), b = bSat.mean(fx0, fy0, fx1, fy1)
                let i = (y * sw + x) * 4
                let sr = Double(shotBM.rgba[i]), sg = Double(shotBM.rgba[i + 1]), sb = Double(shotBM.rgba[i + 2])
                let satShot = max(sr, sg, sb) - min(sr, sg, sb)
                let satRef = max(r, g, b) - min(r, g, b)
                if satShot - satRef >= 48 { mask[y * sw + x] = true }
            }
        }
    }
    // the largest contiguous region: marked pixels are joined across gaps of up to two pixels (the words under a mark stay dark)
    var near = [Bool](repeating: false, count: sw * sh)
    var total = 0
    for y in 0..<sh {
        for x in 0..<sw where mask[y * sw + x] {
            total += 1
            for dy in -2...2 {
                for dx in -2...2 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < sw, ny >= 0, ny < sh { near[ny * sw + nx] = true }
                }
            }
        }
    }
    var label = [Int32](repeating: 0, count: sw * sh)
    var bestLabel: Int32 = 0, bestCount = 0, nextLabel: Int32 = 0
    var stack: [Int] = []
    for start in 0..<(sw * sh) where near[start] && label[start] == 0 {
        nextLabel += 1
        var count = 0
        label[start] = nextLabel
        stack.append(start)
        while let p = stack.popLast() {
            if mask[p] { count += 1 }
            let px = p % sw, py = p / sw
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = px + dx, ny = py + dy
                    if nx >= 0, nx < sw, ny >= 0, ny < sh {
                        let q = ny * sw + nx
                        if near[q] && label[q] == 0 { label[q] = nextLabel; stack.append(q) }
                    }
                }
            }
        }
        if count > bestCount { bestCount = count; bestLabel = nextLabel }
    }
    print("pixels \(bestCount)")
    if bestCount < 200 {
        print("no mark: \(bestCount) coloured pixels on the page (of \(total) coloured in the picture), at least 200 are needed")
        exit(1)
    }
    // the region in page points, origin bottom left, and the share of its pixels inside the box grown by 10 points
    let pageH = Double(ref.h) / Double(renderScale)
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, inside = 0
    let gx0 = box[0] - 10, gx1 = box[0] + box[2] + 10, gy0 = box[1] - 10, gy1 = box[1] + box[3] + 10
    for y in 0..<sh {
        for x in 0..<sw where mask[y * sw + x] && label[y * sw + x] == bestLabel {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            let ptX = (Double(x) + 0.5 - Double(place.ox)) / k / Double(renderScale)
            let ptY = pageH - (Double(y) + 0.5 - Double(place.oy)) / k / Double(renderScale)
            if ptX >= gx0 && ptX <= gx1 && ptY >= gy0 && ptY <= gy1 { inside += 1 }
        }
    }
    let rx0 = (Double(minX) - Double(place.ox)) / k / Double(renderScale)
    let rx1 = (Double(maxX + 1) - Double(place.ox)) / k / Double(renderScale)
    let ryTop0 = (Double(minY) - Double(place.oy)) / k / Double(renderScale)
    let ryTop1 = (Double(maxY + 1) - Double(place.oy)) / k / Double(renderScale)
    let region = (x: rx0, y: pageH - ryTop1, w: rx1 - rx0, h: ryTop1 - ryTop0)
    let insideFraction = Double(inside) / Double(bestCount)
    let ix = max(0, min(region.x + region.w, box[0] + box[2]) - max(region.x, box[0]))
    let iy = max(0, min(region.y + region.h, box[1] + box[3]) - max(region.y, box[1]))
    let overlap = region.w * region.h > 0 ? (ix * iy) / (region.w * region.h) : 0
    print("region \(fixed(region.x, 1)) \(fixed(region.y, 1)) \(fixed(region.w, 1)) \(fixed(region.h, 1))")
    print("inside \(fixed(insideFraction, 2))")
    print("overlap \(fixed(overlap, 2))")
    if insideFraction >= 0.5 && overlap >= 0.5 {
        print("mark on the passage: \(fixed(insideFraction * 100, 0)) percent of the marked pixels are inside the box grown by 10 points, the region covers the box by \(fixed(overlap * 100, 0)) percent of its own area")
    } else {
        print("the mark is not on the passage: inside \(fixed(insideFraction, 2)) (at least 0.50 needed), overlap \(fixed(overlap, 2)) (at least 0.50 needed)")
        exit(1)
    }

case "speech-assets":
    // plan 5, S4.2 and S4.8: does the system language have on-device recognition? One line, `true <locale>` or `false <locale>`.
    let locale = Locale.current
    let supported = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    print("\(supported) \(locale.identifier)")

case "waveform-check":
    // plan 5, S4.2: the bars drawn in a pane picture against the 30 s blocks (5 s steps) of the known clip's own envelope.
    guard args.count == 4, let stated = Double(args[3]) else { usage() }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil), let shotImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("no readable picture: \(args[1])")
        exit(4)
    }
    guard let clip = try? AVAudioFile(forReading: URL(fileURLWithPath: args[2])) else { fail("cannot read the audio file: \(args[2])") }
    let levels = secondLevels(clip)
    guard levels.count >= 30 else { fail("the clip is shorter than one 30 s block (\(levels.count) s)") }
    let (ink, bars) = drawnBars(bitmap(shotImage))
    if ink == 0 { print("the picture is blank: no ink at all"); exit(1) }
    guard bars.count >= 4 else { print("no waveform in the picture: \(bars.count) bars found"); exit(1) }
    let drawn = (0..<30).map { j -> Double in
        let a = Int(Double(j) * Double(bars.count) / 30), b = max(a + 1, Int(Double(j + 1) * Double(bars.count) / 30))
        let slice = bars[min(a, bars.count - 1)..<min(b, bars.count)]
        return slice.reduce(0, +) / Double(max(1, slice.count))
    }
    print("bars \(bars.count)")
    let mean = drawn.reduce(0, +) / 30
    let spread = (drawn.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 30).squareRoot()
    if mean <= 0 || spread / mean < 0.05 {
        print("the drawn waveform is flat (spread \(fixed(spread / max(mean, 1e-9), 3)) of its mean): it is the same for any block")
        exit(1)
    }
    var scores: [Int: Double] = [:]
    for s in stride(from: 0, through: levels.count - 30, by: 5) { scores[s] = pearson(drawn, Array(levels[s..<(s + 30)])) }
    let top = scores.values.max() ?? -1
    let tied = scores.filter { top - $0.value < 1e-9 }.map(\.key)
    let best = tied.min { abs(Double($0) - stated) < abs(Double($1) - stated) } ?? 0
    let earlier = scores[best - 30], later = scores[best + 30]
    print("best \(best) correlation \(fixed(top))")
    print("earlier \(earlier.map { fixed($0) } ?? "none")")
    print("later \(later.map { fixed($0) } ?? "none")")
    var why: [String] = []
    if abs(Double(best) - stated) > 2 { why.append("the best block starts at \(best) s, the stated start is \(fixed(stated, 1)) s (at most 2 s apart)") }
    if top < 0.7 { why.append("the correlation \(fixed(top)) is under 0.70") }
    if let e = earlier, top <= e { why.append("it does not beat the block 30 s earlier (\(fixed(e)))") }
    if let l = later, top <= l { why.append("it does not beat the block 30 s later (\(fixed(l)))") }
    if why.isEmpty {
        print("the drawn waveform is the block at \(best) s")
    } else {
        print("the drawn waveform does not show the block at \(fixed(stated, 1)) s: " + why.joined(separator: "; "))
        exit(1)
    }

case "frame-check":
    // plan 5 (t1b), S4.4: the pane picture against the video's own frames: the frame at the stated second and the one 20 s earlier, each
    // found inside the picture with the same correlation search as the PDF pages (zero-mean normalised correlation over scale and place).
    guard args.count == 4, let stated = Int(args[3]), stated >= 0 else { usage() }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil), let shotImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("no readable picture: \(args[1])")
        exit(4)
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
    func videoFrame(_ second: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? generator.copyCGImage(at: CMTime(seconds: Double(second), preferredTimescale: 600), actualTime: nil)
    }
    let earlierSecond = max(0, stated - 20)
    guard let nowFrame = videoFrame(stated), let earlierFrame = videoFrame(earlierSecond) else { fail("cannot read the frames at \(stated) s and \(earlierSecond) s of the video: \(args[2])") }
    let paneShot = luminance(shotImage)
    func frameScore(_ image: CGImage) -> Double {
        let sat = lumaSat(image)
        let coarse = coarseSearch(shot: paneShot.px, w: paneShot.w, h: paneShot.h, ref: sat)
        return refine(shot: paneShot.px, w: paneShot.w, h: paneShot.h, ref: sat, seeds: coarse.seeds, ds: coarse.ds)?.score ?? 0
    }
    let nowScore = frameScore(nowFrame), earlierScore = frameScore(earlierFrame)
    print("frame now \(fixed(nowScore))")
    print("frame earlier \(fixed(earlierScore))")
    if nowScore >= matchThreshold && nowScore - earlierScore >= 0.05 {
        print("the pane shows the frame at \(stated) s, closer than the frame at \(earlierSecond) s")
    } else {
        print("the pane does not show the frame at \(stated) s more closely than the frame at \(earlierSecond) s (the bar is \(matchThreshold) and a margin of 0.05)")
        exit(1)
    }

default:
    usage()
}

/// The loudness of each whole second of an audio file: the RMS of all its samples in that second (every channel).
func secondLevels(_ file: AVAudioFile) -> [Double] {
    let rate = Int(file.processingFormat.sampleRate)
    guard rate > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate)) else { return [] }
    var out: [Double] = []
    while true {
        buffer.frameLength = 0
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(rate)) } catch { break }
        let n = Int(buffer.frameLength)
        if n < rate { break }
        var sum = 0.0
        if let data = buffer.floatChannelData {
            for c in 0..<Int(buffer.format.channelCount) { for i in 0..<n { sum += Double(data[c][i]) * Double(data[c][i]) } }
        }
        out.append((sum / Double(n * Int(buffer.format.channelCount))).squareRoot())
    }
    return out
}

/// The ink of a picture and the bars in it. Ink is a pixel far from the most common brightness. A bar column is one whose ink is one
/// vertical run (a bar, not a line of text or a rule); the bars are the longest stretch of such columns (gaps of up to 6 pixels), each
/// bar as long as its longest column.
func drawnBars(_ b: Bitmap) -> (ink: Int, bars: [Double]) {
    let luma = lumaOf(b)
    var counts = [Int](repeating: 0, count: 32)
    for v in luma { counts[min(31, Int(v / 8))] += 1 }
    let background = Float(counts.firstIndex(of: counts.max() ?? 0) ?? 31) * 8 + 4
    var total = 0
    var longest = [Int](repeating: 0, count: b.w), inkIn = [Int](repeating: 0, count: b.w)
    for x in 0..<b.w {
        var run = 0
        for y in 0..<b.h {
            if abs(luma[y * b.w + x] - background) > 40 {
                run += 1; inkIn[x] += 1; total += 1
                longest[x] = max(longest[x], run)
            } else { run = 0 }
        }
    }
    let isBar = (0..<b.w).map { longest[$0] >= 3 && longest[$0] * 10 >= inkIn[$0] * 7 }
    // stretches of bar columns with gaps of up to 6 pixels; keep the one that spans the most columns
    var best: (from: Int, to: Int) = (0, -1)
    var x = 0
    while x < b.w {
        guard isBar[x] else { x += 1; continue }
        var end = x, gap = 0, y = x
        while y < b.w && gap <= 6 { if isBar[y] { end = y; gap = 0 } else { gap += 1 }; y += 1 }
        if end - x > best.to - best.from { best = (x, end) }
        x = end + 1
    }
    guard best.to >= best.from else { return (total, []) }
    var bars: [Double] = []
    var run = 0, top = 0
    for c in best.from...best.to {
        if isBar[c] { run += 1; top = max(top, longest[c]) } else if run > 0 { bars.append(Double(top)); run = 0; top = 0 }
    }
    if run > 0 { bars.append(Double(top)) }
    return (total, bars)
}

/// Pearson correlation of two equal-length series; 0 when either is constant.
func pearson(_ x: [Double], _ y: [Double]) -> Double {
    let n = Double(x.count)
    let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for i in 0..<x.count { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx); syy += (y[i] - my) * (y[i] - my) }
    guard sxx > 1e-12, syy > 1e-12 else { return 0 }
    return sxy / (sxx * syy).squareRoot()
}

/// The luma of one pixel of a bitmap (index into the picture), for the reference's table.
func lumaOf1(_ b: Bitmap, _ i: Int) -> Float {
    0.299 * Float(b.rgba[i * 4]) + 0.587 * Float(b.rgba[i * 4 + 1]) + 0.114 * Float(b.rgba[i * 4 + 2])
}
