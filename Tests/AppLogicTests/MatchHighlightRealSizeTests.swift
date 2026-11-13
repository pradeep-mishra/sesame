import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import SesameEngine

private struct RsRGB: Equatable {
    let r: Int
    let g: Int
    let b: Int
}

private let rsWhite = RsRGB(r: 255, g: 255, b: 255)
private let rsBlack = RsRGB(r: 0, g: 0, b: 0)
private let rsFillOnWhite = RsRGB(r: 255, g: 233, b: 166)
private let rsFillOnBlack = RsRGB(r: 89, g: 67, b: 0)
private let rsRingOnWhite = RsRGB(r: 255, g: 217, b: 102)
private let rsRingOnBlack = RsRGB(r: 153, g: 115, b: 0)
private let rsAmber = RsRGB(r: 255, g: 191, b: 0)

private func rsNear(_ pixel: RsRGB, _ want: RsRGB, _ tolerance: Int = 3) -> Bool {
    abs(pixel.r - want.r) <= tolerance && abs(pixel.g - want.g) <= tolerance && abs(pixel.b - want.b) <= tolerance
}

private func rsFillOver(_ pixel: RsRGB) -> RsRGB {
    RsRGB(r: Int((0.65 * Double(pixel.r) + 89.25).rounded()),
          g: Int((0.65 * Double(pixel.g) + 66.94).rounded()),
          b: Int((0.65 * Double(pixel.b)).rounded()))
}

private func rsRingOver(_ pixel: RsRGB) -> RsRGB {
    RsRGB(r: Int((0.4 * Double(pixel.r) + 153).rounded()),
          g: Int((0.4 * Double(pixel.g) + 114.75).rounded()),
          b: Int((0.4 * Double(pixel.b)).rounded()))
}

private func rsColour(_ value: RsRGB) -> CGColor {
    CGColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255, blue: CGFloat(value.b) / 255, alpha: 1)
}

private final class RsBitmap {
    let context: CGContext
    let width = 200
    let height = 100

    init(page: RsRGB) {
        context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        fill(CGRect(x: 0, y: 0, width: 200, height: 100), page)
    }

    func fill(_ rect: CGRect, _ colour: RsRGB) {
        context.setFillColor(rsColour(colour))
        context.fill(rect)
    }

    func pixel(_ x: Int, _ y: Int) -> RsRGB {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let at = (height - 1 - y) * context.bytesPerRow + x * 4
        return RsRGB(r: Int(bytes[at]), g: Int(bytes[at + 1]), b: Int(bytes[at + 2]))
    }
}

private func rsInside(_ x: Int, _ y: Int, _ rect: CGRect) -> Bool {
    x >= Int(rect.minX) && x < Int(rect.maxX) && y >= Int(rect.minY) && y < Int(rect.maxY)
}

private func rsWordProblems(page: RsRGB, ink: RsRGB, onInk: RsRGB, onPage: RsRGB, rect: CGRect, shapes: [CGRect]) -> (mismatches: [String], ringOrAmber: Int, shapePixels: Int) {
    let bitmap = RsBitmap(page: page)
    for shape in shapes { bitmap.fill(shape, ink) }
    MatchMark.paint([rect], in: bitmap.context)
    var mismatches: [String] = []
    var ringOrAmber = 0
    var shapePixels = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let onShape = shapes.contains { rsInside(x, y, $0) }
            if onShape { shapePixels += 1 }
            let got = bitmap.pixel(x, y)
            let want = onShape ? onInk : onPage
            if !rsNear(got, want), mismatches.count < 5 { mismatches.append("(\(x), \(y)) is \(got), expected \(want)") }
            if rsNear(got, rsRingOnWhite) || rsNear(got, rsRingOnBlack) || rsNear(got, rsAmber) { ringOrAmber += 1 }
        }
    }
    return (mismatches, ringOrAmber, shapePixels)
}

private func rsPainted(page: RsRGB = rsWhite, shapes: [(CGRect, RsRGB)] = [], _ rects: [CGRect]) -> RsBitmap {
    let bitmap = RsBitmap(page: page)
    for (shape, colour) in shapes { bitmap.fill(shape, colour) }
    MatchMark.paint(rects, in: bitmap.context)
    return bitmap
}

private func rsWrong(_ bitmap: RsBitmap, _ pixels: [(Int, Int)], _ want: RsRGB) -> [String] {
    let all: [String] = pixels.compactMap { x, y in
        let got = bitmap.pixel(x, y)
        return rsNear(got, want) ? nil : "(\(x), \(y)) is \(got), expected \(want)"
    }
    return Array(all.prefix(5))
}

private let rsWordRect = CGRect(x: 60, y: 40, width: 75, height: 18)
private let rsWordShapes = [CGRect(x: 63, y: 43, width: 8, height: 12), CGRect(x: 124, y: 43, width: 8, height: 12), CGRect(x: 74, y: 48, width: 60, height: 2)]
private let rsScannedRect = CGRect(x: 60, y: 40, width: 60, height: 14)
private let rsScannedShapes = [CGRect(x: 63, y: 42, width: 7, height: 9), CGRect(x: 110, y: 42, width: 7, height: 9), CGRect(x: 72, y: 45, width: 36, height: 2)]

private func rsStripeIsBlack(_ x: Int, _ y: Int) -> Bool {
    ((x / 3) + (y / 2)) % 2 == 0
}

private let rsBodyBox = (minX: 285, maxX: 362, minY: 296, maxY: 312)

private func rsBodyPdf() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(box)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 11, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    let lines = [
        "The committee reviewed the budget for the coming fiscal year in detail",
        "and agreed that several recurring expenses could be reduced without harm",
        "Process review found that automation of the monthly reports saves hours",
        "each week, and the savings will be reinvested in staff training courses",
        "A final summary will be sent to every department head by the end of March",
    ]
    for (index, text) in lines.enumerated() {
        ctx.textPosition = CGPoint(x: 72, y: 600 - 13.2 * Double(index))
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), ctx)
    }
    ctx.endPDFPage()
    ctx.closePDF()
    return data as Data
}

private struct RsPicture {
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

    func pixel(_ x: Int, _ y: Int) -> RsRGB {
        let at = (y * width + x) * 4
        return RsRGB(r: Int(bytes[at]), g: Int(bytes[at + 1]), b: Int(bytes[at + 2]))
    }
}

@Suite("MatchHighlightRealSizeTests", .serialized)
struct MatchHighlightRealSizeTests {

    @Test func aWordRectangleOnAWhitePageKeepsTheFillOnItsFirstAndLastLetter() {
        let result = rsWordProblems(page: rsWhite, ink: rsBlack, onInk: rsFillOnBlack, onPage: rsFillOnWhite, rect: rsWordRect, shapes: rsWordShapes)
        #expect(result.shapePixels > 0)
        #expect(result.mismatches.isEmpty, "inside the 75 x 18 rectangle every black text pixel is (89, 67, 0) and every white one (255, 233, 166): \(result.mismatches)")
        #expect(result.ringOrAmber == 0, "\(result.ringOrAmber) pixels inside the 75 x 18 rectangle are the ring colour or amber")
    }

    @Test func aWordRectangleOnABlackPageKeepsTheFillOnItsFirstAndLastLetter() {
        let result = rsWordProblems(page: rsBlack, ink: rsWhite, onInk: rsFillOnWhite, onPage: rsFillOnBlack, rect: rsWordRect, shapes: rsWordShapes)
        #expect(result.shapePixels > 0)
        #expect(result.mismatches.isEmpty, "inside the 75 x 18 rectangle every white text pixel is (255, 233, 166) and every black one (89, 67, 0): \(result.mismatches)")
        #expect(result.ringOrAmber == 0, "\(result.ringOrAmber) pixels inside the 75 x 18 rectangle are the ring colour or amber")
    }

    @Test func aScannedLineRectangleOnAWhitePageKeepsTheFillOnItsLetters() {
        let result = rsWordProblems(page: rsWhite, ink: rsBlack, onInk: rsFillOnBlack, onPage: rsFillOnWhite, rect: rsScannedRect, shapes: rsScannedShapes)
        #expect(result.shapePixels > 0)
        #expect(result.mismatches.isEmpty, "inside the 60 x 14 rectangle every black text pixel is (89, 67, 0) and every white one (255, 233, 166): \(result.mismatches)")
        #expect(result.ringOrAmber == 0, "\(result.ringOrAmber) pixels inside the 60 x 14 rectangle are the ring colour or amber")
    }

    @Test func aScannedLineRectangleOnABlackPageKeepsTheFillOnItsLetters() {
        let result = rsWordProblems(page: rsBlack, ink: rsWhite, onInk: rsFillOnWhite, onPage: rsFillOnBlack, rect: rsScannedRect, shapes: rsScannedShapes)
        #expect(result.shapePixels > 0)
        #expect(result.mismatches.isEmpty, "inside the 60 x 14 rectangle every white text pixel is (255, 233, 166) and every black one (89, 67, 0): \(result.mismatches)")
        #expect(result.ringOrAmber == 0, "\(result.ringOrAmber) pixels inside the 60 x 14 rectangle are the ring colour or amber")
    }

    @Test func everyPixelInsideARectangleOfAnySizeIsTheFillOfThePagePixelOnAStripedPage() {
        let sizes = [(75, 18), (60, 14), (12, 12), (40, 20), (173, 35)]
        for (width, height) in sizes {
            let page = RsBitmap(page: rsWhite)
            for cellY in 0..<50 {
                for cellX in 0..<67 where rsStripeIsBlack(cellX * 3, cellY * 2) {
                    page.fill(CGRect(x: cellX * 3, y: cellY * 2, width: 3, height: 2), rsBlack)
                }
            }
            let rect = CGRect(x: 14, y: 30, width: width, height: height)
            MatchMark.paint([rect], in: page.context)
            var wrong: [String] = []
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let want = rsStripeIsBlack(x, y) ? rsFillOnBlack : rsFillOnWhite
                    let got = page.pixel(x, y)
                    if !rsNear(got, want), wrong.count < 5 { wrong.append("(\(x), \(y)) is \(got), expected \(want)") }
                }
            }
            #expect(wrong.isEmpty, "\(width) x \(height): \(wrong)")
        }
    }

    @Test func aRectangleTwelvePixelsSquareGetsTheRingOutsideAndTheFillInside() {
        let bitmap = rsPainted([CGRect(x: 60, y: 40, width: 12, height: 12)])
        let ring = rsWrong(bitmap, [(59, 46), (56, 46), (72, 46), (75, 46), (66, 39), (66, 36), (66, 52), (66, 55)], rsRingOnWhite)
        let page = rsWrong(bitmap, [(55, 46), (76, 46), (66, 35), (66, 56)], rsWhite)
        let fill = rsWrong(bitmap, [(60, 46), (71, 46), (66, 40), (66, 51), (66, 46)], rsFillOnWhite)
        #expect(ring.isEmpty, "the 4 px outside a 12 x 12 rectangle: \(ring)")
        #expect(page.isEmpty, "the 5th pixel outside: \(page)")
        #expect(fill.isEmpty, "inside: \(fill)")
    }

    @Test func rectanglesTwelvePixelsApartKeepAFourPixelPageGapAndRingsThatOverlapDoNotAddUp() {
        let apart = rsPainted([CGRect(x: 10, y: 30, width: 60, height: 40), CGRect(x: 82, y: 30, width: 60, height: 40)])
        let rings = rsWrong(apart, [(9, 50), (70, 50), (73, 50), (78, 50), (81, 50), (142, 50), (145, 50)], rsRingOnWhite)
        let gap = rsWrong(apart, [(74, 50), (75, 50), (76, 50), (77, 50)], rsWhite)
        let fills = rsWrong(apart, [(69, 50), (82, 50), (40, 50), (110, 50)], rsFillOnWhite)
        #expect(rings.isEmpty, "each rectangle is ringed 4 px: \(rings)")
        #expect(gap.isEmpty, "the 4 px gap between the rings: \(gap)")
        #expect(fills.isEmpty, "inside: \(fills)")
        let close = rsPainted([CGRect(x: 10, y: 30, width: 60, height: 40), CGRect(x: 76, y: 30, width: 60, height: 40)])
        let between = rsWrong(close, (70...75).map { ($0, 50) }, rsRingOnWhite)
        #expect(between.isEmpty, "the 6 px between rectangles 6 px apart is the ring once, not twice: \(between)")
    }

    @Test func twoLinesTwoPixelsApartKeepTheFillOverTheInkOfTheLowerOneAndOneRingInTheGap() {
        let lower = CGRect(x: 60, y: 30, width: 75, height: 18)
        let upper = CGRect(x: 60, y: 50, width: 75, height: 18)
        let ink = CGRect(x: 70, y: 45, width: 40, height: 2)
        let bitmap = rsPainted(shapes: [(ink, rsBlack)], [lower, upper])
        var wrong: [String] = []
        for rect in [lower, upper] {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let want = rsInside(x, y, ink) ? rsFillOnBlack : rsFillOnWhite
                    let got = bitmap.pixel(x, y)
                    if !rsNear(got, want), wrong.count < 5 { wrong.append("(\(x), \(y)) is \(got), expected \(want)") }
                }
            }
        }
        #expect(wrong.isEmpty, "inside the two rectangles: \(wrong)")
        let gap = rsWrong(bitmap, (60..<135).flatMap { x in [(x, 48), (x, 49)] }, rsRingOnWhite)
        let outer = rsWrong(bitmap, [(90, 68), (90, 71), (90, 26), (90, 29)], rsRingOnWhite)
        #expect(gap.isEmpty, "the 2 px gap is the ring once over white: \(gap.prefix(5))")
        #expect(outer.isEmpty, "the ring above the upper and below the lower rectangle: \(outer)")
    }

    @Test func aNeighboursInkTwoPixelsOutsideTheRectangleIsTintedByTheRingAndNotHidden() {
        let bitmap = rsPainted(shapes: [(CGRect(x: 58, y: 47, width: 1, height: 3), rsBlack)], [rsWordRect])
        let got = bitmap.pixel(58, 48)
        #expect(rsNear(got, rsRingOnBlack), "a black pixel 2 px outside the rectangle is \(got), expected (153, 115, 0)")
        #expect(!rsNear(got, rsAmber, 12), "the ring hid the ink: the pixel is \(got)")
        let beside = bitmap.pixel(59, 48)
        #expect(rsNear(beside, rsRingOnWhite), "the page pixel beside it is \(beside), expected (255, 217, 102)")
    }

    @Test func aRealElevenPointLineKeepsEveryGlyphPixelInsideTheMarkAndPutsTheRingOutsideIt() {
        let pdf = rsBodyPdf()
        guard let plain = PdfPreview.show(data: pdf, storedPage: 1, words: ["zebrafinch"], findFirst: false),
              let marked = PdfPreview.show(data: pdf, storedPage: 1, words: ["automation"], findFirst: false) else {
            Issue.record("PdfPreview.show returned nothing for the body text PDF")
            return
        }
        let before = RsPicture(plain.png)
        let after = RsPicture(marked.png)
        #expect(after.width == before.width && after.height == before.height, "the marked picture is \(after.width) x \(after.height), the plain one \(before.width) x \(before.height)")
        guard after.width == before.width, after.height == before.height else { return }
        let box = rsBodyBox
        var insideWrong: [String] = []
        var darkInside = 0
        for y in (box.minY + 1)...(box.maxY - 1) {
            for x in (box.minX + 1)...(box.maxX - 1) {
                let source = before.pixel(x, y)
                if source.r < 100 { darkInside += 1 }
                let want = rsFillOver(source)
                let got = after.pixel(x, y)
                if !rsNear(got, want), insideWrong.count < 5 { insideWrong.append("(\(x), \(y)) was \(source), is \(got), expected \(want)") }
            }
        }
        #expect(darkInside >= 150, "only \(darkInside) dark pixels inside the mark, the word has about 253")
        #expect(insideWrong.isEmpty, "inside the mark every pixel is the fill over the unmarked pixel, so every glyph pixel is (89, 67, 0)-like: \(insideWrong)")
        var outsideChanged: [String] = []
        var ringOverWhite = 0
        var bandWrong: [String] = []
        for y in 0..<before.height {
            for x in 0..<before.width {
                let grown = x >= box.minX - 5 && x <= box.maxX + 5 && y >= box.minY - 5 && y <= box.maxY + 5
                if !grown, before.pixel(x, y) != after.pixel(x, y), outsideChanged.count < 5 { outsideChanged.append("(\(x), \(y))") }
                let inBox = x >= box.minX && x <= box.maxX && y >= box.minY && y <= box.maxY
                let side = x < box.minX || x > box.maxX
                let verticalSide = y < box.minY || y > box.maxY
                if !inBox, x >= box.minX - 4, x <= box.maxX + 4, y >= box.minY - 4, y <= box.maxY + 4, rsNear(after.pixel(x, y), rsRingOnWhite) { ringOverWhite += 1 }
                let nearBand = !inBox && x >= box.minX - 2 && x <= box.maxX + 2 && y >= box.minY - 2 && y <= box.maxY + 2
                if nearBand, !(side && verticalSide) {
                    let want = rsRingOver(before.pixel(x, y))
                    let got = after.pixel(x, y)
                    if !rsNear(got, want), bandWrong.count < 5 { bandWrong.append("(\(x), \(y)) was \(before.pixel(x, y)), is \(got), expected \(want)") }
                }
            }
        }
        #expect(outsideChanged.isEmpty, "pixels changed outside the mark rectangle grown by 5 px: \(outsideChanged)")
        #expect(ringOverWhite >= 400, "only \(ringOverWhite) pixels in the 4 px band around the mark are the ring over white (255, 217, 102), a 78 x 17 mark has about 700")
        #expect(bandWrong.isEmpty, "the 2 px next to the mark are the ring over the unmarked pixel, ink of the lines above and below included: \(bandWrong)")
    }
}
