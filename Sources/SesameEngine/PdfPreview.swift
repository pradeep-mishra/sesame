import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

public enum MatchMark {
    public static let red: CGFloat = 1
    public static let green: CGFloat = 0.75
    public static let blue: CGFloat = 0
    public static let fillAlpha: CGFloat = 0.35
    public static let outlineAlpha: CGFloat = 0.6
    public static let outlineWidth: CGFloat = 4
    public static let outlineRadius: CGFloat = 4
    public static let smallestOutlined: CGFloat = 12

    public static func paint(_ rects: [CGRect], in context: CGContext) {
        guard !rects.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.normal)
        context.setAlpha(1)
        let ringed = rects.filter { $0.width >= smallestOutlined && $0.height >= smallestOutlined }
        if !ringed.isEmpty {
            let inside = CGMutablePath()
            inside.addRects(rects)
            let reach = outlineWidth + 1
            let page = rects.dropFirst().reduce(rects[0]) { $0.union($1) }.insetBy(dx: -reach, dy: -reach)
            let outside = CGPath(rect: page, transform: nil).subtracting(inside, using: .winding)
            let ring = CGMutablePath()
            for rect in ringed {
                let grown = rect.insetBy(dx: -outlineWidth, dy: -outlineWidth)
                ring.addPath(CGPath(roundedRect: grown, cornerWidth: outlineRadius, cornerHeight: outlineRadius, transform: nil))
            }
            context.saveGState()
            context.addPath(outside)
            context.clip()
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: outlineAlpha))
            context.addPath(ring)
            context.fillPath(using: .winding)
            context.restoreGState()
        }
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: fillAlpha))
        for rect in rects {
            context.fill(rect)
        }
    }
}

/// One page of a PDF drawn whole for the pane, with the query words marked (design section 3, "Preview"). A page with a
/// text layer is marked where PDFKit puts the words; a page that is a picture (the index's own test: fewer than
/// `PdfReader.textThreshold` characters) is marked from the boxes Vision finds the words in on that one page.
enum PdfPreview {
    struct Shown {
        let png: Data
        let page: Int
        let pageCount: Int
    }

    /// The picture of the page the preview shows: `storedPage` (clamped to the page count), or, when `findFirst`, the first
    /// page whose text holds every query word as a whole word, the stored page when none does. Nil when the bytes are no
    /// PDF PDFKit opens (a password included) or the page cannot be drawn.
    static func show(data: Data, storedPage: Int, words: [String], findFirst: Bool) -> Shown? {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { return nil }
        let count = document.pageCount
        var number = min(max(storedPage, 1), count)
        if findFirst {
            let each = words.compactMap { QueryWords.regex([$0]) }
            if !each.isEmpty, each.count == words.count {
                for candidate in 1...count {
                    let found: Bool = autoreleasepool {
                        let text = document.page(at: candidate - 1)?.string ?? ""
                        let range = NSRange(location: 0, length: (text as NSString).length)
                        return each.allSatisfy { $0.firstMatch(in: text, range: range) != nil }
                    }
                    if found { number = candidate; break }
                }
            }
        }
        guard let page = document.page(at: number - 1) else { return nil }
        let png: Data? = autoreleasepool { render(page, regex: QueryWords.regex(words)) }
        return png.map { Shown(png: $0, page: number, pageCount: count) }
    }

    /// The whole page at pane size, never cropped, with the marks on it, as PNG bytes.
    private static func render(_ page: PDFPage, regex: NSRegularExpression?) -> Data? {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let turned = rotation % 180 != 0
        let shown = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard shown.width >= 1, shown.height >= 1 else { return nil }
        let scale = min(CGFloat(PreviewReader.paneWidth) / shown.width, CGFloat(PreviewReader.paneHeight) / shown.height)
        let width = max(1, Int((shown.width * scale).rounded())), height = max(1, Int((shown.height * scale).rounded()))
        let thumbnail = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        guard let base = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        if let regex {
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let marks = text.count >= PdfReader.textThreshold
                ? textMarks(page, regex: regex, box: box, rotation: rotation, scale: scale)
                : scanMarks(page, regex: regex, width: CGFloat(width), height: CGFloat(height))
            MatchMark.paint(marks, in: context)
        }
        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// The rectangles of the matches in the page's text layer, in the picture's pixels (origin bottom left): PDFKit's
    /// bounds of each line of each match, moved from the page's space into the turned and scaled picture.
    private static func textMarks(_ page: PDFPage, regex: NSRegularExpression, box: CGRect, rotation: Int,
                                  scale: CGFloat) -> [CGRect] {
        let text = page.string ?? ""
        func place(_ point: CGPoint) -> CGPoint {
            switch rotation {
            case 90: return CGPoint(x: point.y - box.minY, y: box.maxX - point.x)
            case 180: return CGPoint(x: box.maxX - point.x, y: box.maxY - point.y)
            case 270: return CGPoint(x: box.maxY - point.y, y: point.x - box.minX)
            default: return CGPoint(x: point.x - box.minX, y: point.y - box.minY)
            }
        }
        var marks: [CGRect] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            guard let selection = page.selection(for: match.range) else { continue }
            for line in selection.selectionsByLine() {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let a = place(CGPoint(x: bounds.minX, y: bounds.minY)), b = place(CGPoint(x: bounds.maxX, y: bounds.maxY))
                marks.append(CGRect(x: min(a.x, b.x) * scale, y: min(a.y, b.y) * scale,
                                    width: abs(a.x - b.x) * scale, height: abs(a.y - b.y) * scale))
            }
        }
        return marks
    }

    /// The rectangles of the matches in what Vision reads on the page drawn at the size the index read it, in the
    /// picture's pixels (origin bottom left). Vision's boxes are fractions of the image, so any picture size takes them.
    private static func scanMarks(_ page: PDFPage, regex: NSRegularExpression, width: CGFloat, height: CGFloat) -> [CGRect] {
        var box = page.bounds(for: .cropBox)
        if page.rotation % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        guard box.width >= 1, box.height >= 1 else { return [] }
        let factor = PdfReader.scanSide / max(box.width, box.height)
        let size = CGSize(width: (box.width * factor).rounded(), height: (box.height * factor).rounded())
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil else { return [] }
        var marks: [CGRect] = []
        for observation in request.results ?? [] {
            guard let line = observation.topCandidates(1).first else { continue }
            let text = line.string
            for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                guard let range = Range(match.range, in: text), let found = try? line.boundingBox(for: range) else { continue }
                let fraction = found.boundingBox
                marks.append(CGRect(x: fraction.minX * width, y: fraction.minY * height,
                                    width: fraction.width * width, height: fraction.height * height))
            }
        }
        return marks
    }
}
