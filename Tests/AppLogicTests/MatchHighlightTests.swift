import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import SesameEngine
@testable import Sesame

private struct MhRGB: Equatable {
    let r: Int
    let g: Int
    let b: Int
}

private let mhWhite = MhRGB(r: 255, g: 255, b: 255)
private let mhBlack = MhRGB(r: 0, g: 0, b: 0)
private let mhGrey = MhRGB(r: 128, g: 128, b: 128)
private let mhRingOnWhite = MhRGB(r: 255, g: 217, b: 102)
private let mhRingOnBlack = MhRGB(r: 153, g: 115, b: 0)
private let mhRingOnGrey = MhRGB(r: 204, g: 166, b: 51)
private let mhFillOnWhite = MhRGB(r: 255, g: 233, b: 166)
private let mhFillOnBlack = MhRGB(r: 89, g: 67, b: 0)
private let mhFillOnGrey = MhRGB(r: 172, g: 150, b: 83)

private let mhBigRect = CGRect(x: 10, y: 30, width: 100, height: 40)

private func mhNear(_ pixel: MhRGB, _ want: MhRGB, _ tolerance: Int = 3) -> Bool {
    abs(pixel.r - want.r) <= tolerance && abs(pixel.g - want.g) <= tolerance && abs(pixel.b - want.b) <= tolerance
}

private final class MhBitmap {
    let context: CGContext
    let width = 200
    let height = 100

    init(page: MhRGB, block: MhRGB? = nil) {
        context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: CGFloat(page.r) / 255, green: CGFloat(page.g) / 255, blue: CGFloat(page.b) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        if let block {
            context.setFillColor(CGColor(srgbRed: CGFloat(block.r) / 255, green: CGFloat(block.g) / 255, blue: CGFloat(block.b) / 255, alpha: 1))
            context.fill(CGRect(x: 20, y: 40, width: 40, height: 20))
        }
    }

    func pixel(_ x: Int, _ y: Int) -> MhRGB {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let at = (height - 1 - y) * context.bytesPerRow + x * 4
        return MhRGB(r: Int(bytes[at]), g: Int(bytes[at + 1]), b: Int(bytes[at + 2]))
    }

    func strayCount(in rect: CGRect, page: MhRGB, fill: MhRGB) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where !mhNear(pixel(x, y), page) && !mhNear(pixel(x, y), fill) { count += 1 }
        }
        return count
    }

    func ringRun(fromX x: Int, y: Int, dx: Int, _ ring: MhRGB) -> Int {
        var run = 0
        var cursor = x
        while cursor >= 0, cursor < width, mhNear(pixel(cursor, y), ring) { run += 1; cursor += dx }
        return run
    }

    func ringRun(x: Int, fromY y: Int, dy: Int, _ ring: MhRGB) -> Int {
        var run = 0
        var cursor = y
        while cursor >= 0, cursor < height, mhNear(pixel(x, cursor), ring) { run += 1; cursor += dy }
        return run
    }

    func wrong(_ pixels: [(Int, Int)], _ want: MhRGB) -> [String] {
        let all: [String] = pixels.compactMap { x, y in
            let got = pixel(x, y)
            return mhNear(got, want) ? nil : "(\(x), \(y)) is \(got), expected \(want)"
        }
        return Array(all.prefix(5))
    }
}

private func mhMarked(page: MhRGB, block: MhRGB? = nil, _ rects: [CGRect] = [mhBigRect]) -> MhBitmap {
    let bitmap = MhBitmap(page: page, block: block)
    MatchMark.paint(rects, in: bitmap.context)
    return bitmap
}

private func mhLinear(_ value: Double) -> Double {
    value < 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}

private func mhLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
    0.2126 * mhLinear(r) + 0.7152 * mhLinear(g) + 0.0722 * mhLinear(b)
}

private func mhLuminance(_ pixel: MhRGB) -> Double {
    mhLuminance(Double(pixel.r) / 255, Double(pixel.g) / 255, Double(pixel.b) / 255)
}

private func mhContrast(_ one: Double, _ other: Double) -> Double {
    (max(one, other) + 0.05) / (min(one, other) + 0.05)
}

private func mhOver(_ top: [CGFloat], _ bottom: [Double]) -> [Double] {
    let alpha = Double(top[3])
    return (0..<3).map { Double(top[$0]) * alpha + bottom[$0] * (1 - alpha) }
}

private let mhProjectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func mhSwiftFiles(under folder: String) -> [URL] {
    let root = mhProjectRoot.appendingPathComponent(folder)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func mhText(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func mhPdf() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(box)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    ctx.textPosition = CGPoint(x: 72, y: 600)
    let line = NSAttributedString(string: "Quarterly automation roadmap for the team", attributes: attributes)
    CTLineDraw(CTLineCreateWithAttributedString(line), ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    return data as Data
}

private struct MhPicture {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ png: Data) {
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        width = image.width
        height = image.height
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bytes = pixels
    }

    func pixel(_ x: Int, _ y: Int) -> MhRGB {
        let at = (y * width + x) * 4
        return MhRGB(r: Int(bytes[at]), g: Int(bytes[at + 1]), b: Int(bytes[at + 2]))
    }
}

private let mhOldUnmarkedSha256 = "007025a528d1e06050d4ca13a919f0365abccaf1224647f28e510d881c61a15e"
private let mhOldMarkRect = (minX: 245, maxX: 417, minY: 246, maxY: 280)

@Suite("MatchHighlightTests", .serialized)
struct MatchHighlightTests {

    @Test func aMarkedWhitePageShowsPaleAmberAndTheBlackTextUnderItIsDarkAmber() {
        let bitmap = mhMarked(page: mhWhite, block: mhBlack)
        let page = bitmap.pixel(80, 50)
        let text = bitmap.pixel(30, 50)
        #expect(mhNear(page, mhFillOnWhite), "page pixel under the fill \(page), expected (255, 233, 166)")
        #expect(mhNear(text, mhFillOnBlack), "black text pixel under the fill \(text), expected (89, 67, 0)")
    }

    @Test func aMarkedBlackPageShowsDarkAmberAndTheWhiteTextUnderItIsPaleAmber() {
        let bitmap = mhMarked(page: mhBlack, block: mhWhite)
        let page = bitmap.pixel(80, 50)
        let text = bitmap.pixel(30, 50)
        #expect(mhNear(page, mhFillOnBlack), "page pixel under the fill \(page), expected (89, 67, 0)")
        #expect(mhNear(text, mhFillOnWhite), "white text pixel under the fill \(text), expected (255, 233, 166)")
    }

    @Test func blackTextOnAWhitePageKeepsAContrastOfAtLeastFourPointFiveAndAboutSevenPointEightOne() {
        let bitmap = mhMarked(page: mhWhite, block: mhBlack)
        let contrast = mhContrast(mhLuminance(bitmap.pixel(30, 50)), mhLuminance(bitmap.pixel(80, 50)))
        #expect(contrast >= 4.5, "contrast \(contrast)")
        #expect(abs(contrast - 7.81) <= 0.15, "contrast \(contrast), expected 7.81 within 0.15")
    }

    @Test func whiteTextOnABlackPageKeepsAContrastOfAtLeastFourPointFiveAndAboutSevenPointEightOne() {
        let bitmap = mhMarked(page: mhBlack, block: mhWhite)
        let contrast = mhContrast(mhLuminance(bitmap.pixel(30, 50)), mhLuminance(bitmap.pixel(80, 50)))
        #expect(contrast >= 4.5, "contrast \(contrast)")
        #expect(abs(contrast - 7.81) <= 0.15, "contrast \(contrast), expected 7.81 within 0.15")
    }

    @Test func theFillLetsAGreyPageShowThrough() {
        let bitmap = mhMarked(page: mhGrey)
        let pixel = bitmap.pixel(80, 50)
        #expect(mhNear(pixel, mhFillOnGrey), "pixel over grey 128 is \(pixel), expected (172, 150, 83); alpha 0.5 gives (192, 160, 64), opaque gives (255, 191, 0)")
    }

    @Test func theRingIsTheFourPixelsOutsideEachEdgeAndTheFirstPixelInsideIsTheFill() {
        let pages = [
            ("white", mhMarked(page: mhWhite, block: mhBlack), mhWhite, mhRingOnWhite, mhFillOnWhite),
            ("black", mhMarked(page: mhBlack, block: mhWhite), mhBlack, mhRingOnBlack, mhFillOnBlack),
        ]
        let ringPixels = [(9, 50), (8, 50), (7, 50), (6, 50), (110, 50), (111, 50), (112, 50), (113, 50),
                          (80, 70), (80, 71), (80, 72), (80, 73), (80, 29), (80, 28), (80, 27), (80, 26)]
        let pagePixels = [(5, 50), (114, 50), (80, 74), (80, 25)]
        let fillPixels = [(10, 50), (109, 50), (80, 69), (80, 30)]
        for (name, bitmap, page, ring, fill) in pages {
            let ringWrong = bitmap.wrong(ringPixels, ring)
            let pageWrong = bitmap.wrong(pagePixels, page)
            let fillWrong = bitmap.wrong(fillPixels, fill)
            #expect(ringWrong.isEmpty, "\(name) page, the 4 px outside the edges are the ring: \(ringWrong)")
            #expect(pageWrong.isEmpty, "\(name) page, the 5th pixel outside is the page: \(pageWrong)")
            #expect(fillWrong.isEmpty, "\(name) page, the first pixel inside is the fill: \(fillWrong)")
        }
    }

    @Test func theRingOverAGreyPageIsTheTranslucentAmberOverGrey() {
        let bitmap = mhMarked(page: mhGrey)
        let ringWrong = bitmap.wrong([(9, 50), (6, 50), (110, 50), (113, 50), (80, 70), (80, 73), (80, 29), (80, 26)], mhRingOnGrey)
        let pageWrong = bitmap.wrong([(5, 50), (114, 50), (80, 74), (80, 25)], mhGrey)
        #expect(ringWrong.isEmpty, "the ring over grey 128 is (204, 166, 51); alpha 1 gives (255, 191, 0): \(ringWrong)")
        #expect(pageWrong.isEmpty, "the 5th pixel outside is the page: \(pageWrong)")
    }

    @Test func theRingIsFourPixelsWideOnEveryEdgeScannedOutward() {
        let pages = [
            ("white", mhMarked(page: mhWhite, block: mhBlack), mhRingOnWhite),
            ("black", mhMarked(page: mhBlack, block: mhWhite), mhRingOnBlack),
        ]
        for (name, bitmap, ring) in pages {
            let runs = [
                ("left", bitmap.ringRun(fromX: 9, y: 50, dx: -1, ring)),
                ("right", bitmap.ringRun(fromX: 110, y: 50, dx: 1, ring)),
                ("top", bitmap.ringRun(x: 80, fromY: 70, dy: 1, ring)),
                ("bottom", bitmap.ringRun(x: 80, fromY: 29, dy: -1, ring)),
            ]
            for (edge, run) in runs {
                #expect(abs(run - 4) <= 1, "\(name) page, the \(edge) ring is \(run) px wide, expected 4 within 1")
            }
        }
    }

    @Test func theCornersAreAPlainFillUnderAnOuterRingOfRadiusFourAroundTheCornerPoint() {
        let bitmap = mhMarked(page: mhWhite, block: mhBlack)
        let inside = bitmap.wrong([(10, 30), (109, 30), (10, 69), (109, 69)], mhFillOnWhite)
        let ringNear = bitmap.wrong([(9, 29), (110, 29), (9, 70), (110, 70), (8, 28), (111, 28), (8, 71), (111, 71)], mhRingOnWhite)
        let pageFar = bitmap.wrong([(6, 26), (113, 26), (6, 73), (113, 73)], mhWhite)
        #expect(inside.isEmpty, "the pixel just inside each corner is the fill, the fill is a plain rectangle: \(inside)")
        #expect(ringNear.isEmpty, "the pixels 1 and 2 px diagonally out from each corner are the ring: \(ringNear)")
        #expect(pageFar.isEmpty, "the pixel 4 px diagonally out is beyond the radius of 4 and is the page: \(pageFar)")
    }

    @Test func aRectangleTenPixelsSquareGetsTheFillAndNoOutline() {
        let rect = CGRect(x: 80, y: 40, width: 10, height: 10)
        let bitmap = mhMarked(page: mhWhite, [rect])
        #expect(mhNear(bitmap.pixel(85, 45), mhFillOnWhite), "centre is \(bitmap.pixel(85, 45))")
        #expect(mhNear(bitmap.pixel(81, 45), mhFillOnWhite), "1 px from the left edge is \(bitmap.pixel(81, 45))")
        #expect(mhNear(bitmap.pixel(88, 45), mhFillOnWhite), "1 px from the right edge is \(bitmap.pixel(88, 45))")
        #expect(mhNear(bitmap.pixel(85, 41), mhFillOnWhite), "1 px from the bottom edge is \(bitmap.pixel(85, 41))")
        #expect(mhNear(bitmap.pixel(85, 48), mhFillOnWhite), "1 px from the top edge is \(bitmap.pixel(85, 48))")
        #expect(bitmap.strayCount(in: rect.insetBy(dx: -5, dy: -5), page: mhWhite, fill: mhFillOnWhite) == 0, "a rectangle under 12 px carries ring pixels within 5 px of it")
    }

    @Test func aRectangleElevenPixelsWideOrHighGetsTheFillAndNoOutline() {
        let narrow = CGRect(x: 120, y: 20, width: 11, height: 30)
        let low = CGRect(x: 120, y: 60, width: 30, height: 11)
        let bitmap = mhMarked(page: mhWhite, [narrow, low])
        #expect(mhNear(bitmap.pixel(125, 35), mhFillOnWhite), "centre of the 11 wide one is \(bitmap.pixel(125, 35))")
        #expect(mhNear(bitmap.pixel(121, 35), mhFillOnWhite), "1 px from its left edge is \(bitmap.pixel(121, 35))")
        #expect(mhNear(bitmap.pixel(135, 65), mhFillOnWhite), "centre of the 11 high one is \(bitmap.pixel(135, 65))")
        #expect(mhNear(bitmap.pixel(135, 61), mhFillOnWhite), "1 px from its bottom edge is \(bitmap.pixel(135, 61))")
        #expect(bitmap.strayCount(in: narrow.insetBy(dx: -5, dy: -5), page: mhWhite, fill: mhFillOnWhite) == 0, "the 11 wide rectangle carries ring pixels within 5 px of it")
        #expect(bitmap.strayCount(in: low.insetBy(dx: -5, dy: -5), page: mhWhite, fill: mhFillOnWhite) == 0, "the 11 high rectangle carries ring pixels within 5 px of it")
    }

    @Test func aRectangleTwentyPixelsSquareGetsTheRingOutsideAndTheFillInside() {
        let bitmap = mhMarked(page: mhWhite, [CGRect(x: 150, y: 10, width: 20, height: 20)])
        let ring = bitmap.wrong([(149, 19), (146, 19), (170, 19), (173, 19), (159, 30), (159, 33), (159, 9), (159, 6)], mhRingOnWhite)
        let page = bitmap.wrong([(145, 19), (174, 19), (159, 34), (159, 5)], mhWhite)
        let fill = bitmap.wrong([(150, 19), (169, 19), (159, 19), (159, 10), (159, 29)], mhFillOnWhite)
        #expect(ring.isEmpty, "the 4 px outside a 20 x 20 rectangle are the ring: \(ring)")
        #expect(page.isEmpty, "the 5th pixel outside is the page: \(page)")
        #expect(fill.isEmpty, "inside is the fill, first pixel and centre: \(fill)")
    }

    @Test func severalRectanglesAreAllMarked() {
        let bitmap = mhMarked(page: mhWhite, [CGRect(x: 10, y: 30, width: 60, height: 40), CGRect(x: 120, y: 30, width: 60, height: 40)])
        let fill = bitmap.wrong([(40, 50), (150, 50), (10, 50), (120, 50)], mhFillOnWhite)
        let ring = bitmap.wrong([(7, 50), (72, 50), (117, 50), (182, 50)], mhRingOnWhite)
        let page = bitmap.wrong([(95, 50)], mhWhite)
        #expect(fill.isEmpty, "both rectangles are filled: \(fill)")
        #expect(ring.isEmpty, "both rectangles are ringed outside, 3 px out at the left of each and 3 px out at the right: \(ring)")
        #expect(page.isEmpty, "between them is the page: \(page)")
    }

    @Test func noRectanglesChangeNothing() {
        let bitmap = mhMarked(page: mhGrey, [])
        for (x, y) in [(5, 5), (50, 50), (150, 50), (199, 99)] {
            #expect(mhNear(bitmap.pixel(x, y), mhGrey, 0), "pixel (\(x), \(y)) is \(bitmap.pixel(x, y))")
        }
    }

    @Test func drawingAfterPaintIsNotMultipliedAndNotTranslucent() {
        let bitmap = mhMarked(page: mhGrey)
        bitmap.context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        bitmap.context.fill(CGRect(x: 130, y: 10, width: 40, height: 20))
        let pixel = bitmap.pixel(150, 20)
        #expect(mhNear(pixel, MhRGB(r: 255, g: 0, b: 0), 0), "an opaque red drawn after paint reads \(pixel), expected (255, 0, 0); multiply would give (128, 0, 0)")
    }

    @MainActor
    @Test func theMatchFillIsAmberAtThirtyFivePercentAndTheSameInLightAndDark() {
        let fillLight = dtRGBA(Design.matchFill, .light)
        let fillDark = dtRGBA(Design.matchFill, .dark)
        #expect(dtSame(fillLight, [1.0, 0.75, 0.0, 0.35]), "matchFill in Light is \(fillLight)")
        #expect(dtSame(fillDark, [1.0, 0.75, 0.0, 0.35]), "matchFill in Dark is \(fillDark)")
        #expect(dtSame(fillLight, fillDark, tolerance: 0.001), "matchFill differs between Light \(fillLight) and Dark \(fillDark)")
    }

    @Test func theOldYellowAndTheMultiplyBlendAreGoneFromTheSources() {
        let files = mhSwiftFiles(under: "Sources")
        #expect(!files.isEmpty, "no Swift file found under Sources")
        var problems: [String] = []
        for file in files {
            let text = mhText(file)
            for word in ["markColor", "findHighlightColor"] where text.contains(word) {
                problems.append("\(file.lastPathComponent) still holds \(word)")
            }
        }
        let preview = mhText(mhProjectRoot.appendingPathComponent("Sources/SesameEngine/PdfPreview.swift"))
        if !preview.contains("MatchMark") { problems.append("PdfPreview.swift does not hold MatchMark") }
        for word in [".multiply", "0.92"] where preview.contains(word) {
            problems.append("PdfPreview.swift still holds \(word)")
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func theColourNumbersLiveInMatchMarkAndDesignBuildsItsFillFromThemAndHasNoOutlineToken() {
        let design = mhText(mhProjectRoot.appendingPathComponent("Sources/Sesame/UI/Design.swift"))
        var problems: [String] = []
        for word in ["matchFill", "MatchMark"] where !design.contains(word) {
            problems.append("Design.swift does not hold \(word)")
        }
        for file in mhSwiftFiles(under: "Sources") where mhText(file).contains("matchOutline") {
            problems.append("\(file.lastPathComponent) still holds matchOutline")
        }
        for word in ["0.35", "0.75"] where design.contains(word) {
            problems.append("Design.swift holds the literal \(word), the numbers live in MatchMark")
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @MainActor
    @Test func aMarkedPassageUsesTheMatchFillOnTheMarkedWordsOnlyAndKeepsTheLabelColour() {
        let text = "The tenant may keep one cat with written landlord consent, and no other animal."
        let whole = text as NSString
        var flat: [Int] = []
        for word in ["written", "landlord", "consent"] {
            let range = whole.range(of: word)
            flat += [range.location, range.location + range.length]
        }
        let pane = Pane()
        let reply = PreviewReply(ticket: 2, status: .ok, png: nil, name: "tenancy.docx", kind: "doc", size: 9_001, mtime: 1_700_000_500,
                                 text: text, marks: flat)
        pane.show(reply, path: "/docs/tenancy.docx", image: nil)
        let holder = prViews(pane.view).compactMap { $0 as? NSTextView }.first { !$0.isHiddenOrHasHiddenAncestor && $0.string.contains(text) }
        guard let holder else {
            Issue.record("no shown text view holds the passage")
            return
        }
        let start = (holder.string as NSString).range(of: text).location
        let storage = holder.textStorage!
        for look in DTLook.allCases {
            var problems: [String] = []
            let want = dtRGBA(Design.label, look)
            for index in 0..<whole.length {
                var marked = false
                var pair = 0
                while pair + 1 < flat.count {
                    if index >= flat[pair] && index < flat[pair + 1] { marked = true }
                    pair += 2
                }
                let background = storage.attribute(.backgroundColor, at: start + index, effectiveRange: nil) as? NSColor
                if marked {
                    let got = background.map { dtRGBA($0, look) } ?? []
                    if !dtSame(got, [1.0, 0.75, 0.0, 0.35]) { problems.append("offset \(index) marked, background \(got)") }
                } else if background != nil {
                    problems.append("offset \(index) not marked but has a background")
                }
                let ink = (storage.attribute(.foregroundColor, at: start + index, effectiveRange: nil) as? NSColor) ?? holder.textColor
                let inkGot = ink.map { dtRGBA($0, look) } ?? []
                if !dtSame(inkGot, want) { problems.append("offset \(index) text colour \(inkGot), expected the label \(want)") }
            }
            #expect(problems.prefix(6).isEmpty, "\(look): \(Array(problems.prefix(6)))")
        }
    }

    @MainActor
    @Test func theLabelOverTheMatchFillIsReadableInLightAndInDark() {
        let pages: [(DTLook, [Double])] = [(.light, [1, 1, 1]), (.dark, [0.12, 0.12, 0.12])]
        for (look, page) in pages {
            let fill = dtRGBA(Design.matchFill, look)
            let label = dtRGBA(Design.label, look)
            let behind = mhOver(fill, page)
            let ink = mhOver(label, behind)
            let contrast = mhContrast(mhLuminance(ink[0], ink[1], ink[2]), mhLuminance(behind[0], behind[1], behind[2]))
            #expect(contrast >= 4.5, "\(look): label \(label) over fill \(fill) over page \(page) has contrast \(contrast)")
        }
    }

    @Test func theUnmarkedPdfPictureIsTheSameBytesAsTheOldBuildDrew() {
        guard let shown = PdfPreview.show(data: mhPdf(), storedPage: 1, words: ["zebrafinch"], findFirst: false) else {
            Issue.record("PdfPreview.show returned nothing for the test's one page PDF")
            return
        }
        let hash = SHA256.hash(data: shown.png).map { String(format: "%02x", $0) }.joined()
        let picture = MhPicture(shown.png)
        #expect(hash == mhOldUnmarkedSha256, "the unmarked PNG hashes to \(hash), the old build's was \(mhOldUnmarkedSha256)")
        #expect(picture.width == 865 && picture.height == 1120, "the picture is \(picture.width) x \(picture.height), the old build's was 865 x 1120")
        #expect(shown.png.count == 30_292, "the PNG is \(shown.png.count) bytes, the old build's was 30292")
        #expect(shown.page == 1 && shown.pageCount == 1, "page \(shown.page) of \(shown.pageCount)")
    }

    @Test func theMarkedPdfPictureHasTheSameSizeAndChangesOnlyInsideTheOldMarkRectangleAndItsRing() {
        let pdf = mhPdf()
        guard let plain = PdfPreview.show(data: pdf, storedPage: 1, words: ["zebrafinch"], findFirst: false),
              let marked = PdfPreview.show(data: pdf, storedPage: 1, words: ["automation"], findFirst: false) else {
            Issue.record("PdfPreview.show returned nothing")
            return
        }
        let before = MhPicture(plain.png)
        let after = MhPicture(marked.png)
        #expect(after.width == before.width && after.height == before.height, "the marked picture is \(after.width) x \(after.height), the plain one \(before.width) x \(before.height)")
        #expect(marked.page == 1 && marked.pageCount == 1, "page \(marked.page) of \(marked.pageCount)")
        var changed = 0
        var outside: [String] = []
        var ring = 0
        for y in 0..<before.height {
            for x in 0..<before.width {
                let grown = x >= mhOldMarkRect.minX - 5 && x <= mhOldMarkRect.maxX + 5 && y >= mhOldMarkRect.minY - 5 && y <= mhOldMarkRect.maxY + 5
                if before.pixel(x, y) != after.pixel(x, y) {
                    changed += 1
                    if !grown, outside.count < 5 { outside.append("(\(x), \(y))") }
                }
                let inRect = x >= mhOldMarkRect.minX && x <= mhOldMarkRect.maxX && y >= mhOldMarkRect.minY && y <= mhOldMarkRect.maxY
                let inBand = x >= mhOldMarkRect.minX - 4 && x <= mhOldMarkRect.maxX + 4 && y >= mhOldMarkRect.minY - 4 && y <= mhOldMarkRect.maxY + 4
                if inBand, !inRect, mhNear(after.pixel(x, y), mhRingOnWhite) { ring += 1 }
            }
        }
        #expect(outside.isEmpty, "pixels changed outside the old mark rectangle grown by 5 px: \(outside)")
        #expect(changed >= 5_000, "only \(changed) pixels changed, the old mark changed 5222 and the new fill also tints the glyphs")
        #expect(ring >= 1_200, "only \(ring) ring pixels (255, 217, 102) in the 4 px band around the mark, the band of a 173 x 35 px rectangle is about 1664")
    }
}
