import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import Vision
import SesameEngine

// plan-4-t5, tester step. Written from the t5 entry of plan-4-tasks.md (Tests), design sections 3 and 4 and the spec's S3 only; no
// product source is read. The t4 rig is reused, never edited: `PdfMaker` (PdfReaderTests.swift) draws the text pages and its sizes.
//
// Names, and how they were found:
//   - `PdfReader.read(path:expecting:firstPage:)`, `PdfStep.pageCount`, `.pages`, `PdfPage.number`, `PdfPage.kind` and the case
//     `.scan`: t4's tests (PdfReaderTests.swift). The entry says a scan page comes back "as `.scan` with its recognised text
//     (`ocrText`) and a bitmap whose `rgb.count` is `width * height * 3`".
//
// SHAPE THIS FILE PINS (the entry names the pieces, not how `.scan` carries them; the two accessors `scanParts` and `isText`
// below are the one place to edit):
//   `PdfPage.kind` is an enum with `.text(String)` and `.scan(ocrText: String, bitmap: PhotoBitmap)`: two payloads in that
//   order. The tests bind them with `case .scan(let ocrText, let bitmap)`, so a label or none makes no difference.
//   `bitmap` is the engine's packed picture, the `PhotoBitmap` that `PhotoReader` makes for the encoder, with `width`, `height`
//   (whole numbers) and `rgb` (a byte sequence: `.count` and the bytes themselves are read).
//   A scan page that holds no words has `ocrText` empty (or only white space); it is still `.scan` with a bitmap.
//
// Every PDF is drawn by this file under $TMPDIR and removed again. Picture pages hold a word drawn large in bold black on white
// into a bitmap that is drawn into the page: no text layer. The independent witness of each sample is the test's own PDFKit and
// Vision (`ScanPdf.witnessWords`): the page has no text layer, and Vision reads the word on a half size thumbnail (500 x 300), so
// the word is readable by what the product is told to use (`PDFPage.thumbnail` and text recognition) and a red here is never a
// picture that nobody can read. Every expected value is written by hand.

// MARK: making PDFs with picture pages (shared with HelperPdfQueueTests.swift)

enum ScanPdf {
    enum Page {
        case text(String)
        case picture(String)
        case blank
    }

    /// A picture of `words`: bold black letters, 96 points, on white, the size of a PdfMaker page.
    static func pictureImage(_ words: String) -> CGImage? {
        let width = Int(PdfMaker.width), height = Int(PdfMaker.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.textPosition = CGPoint(x: 40, y: 250)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: attributes)), context)
        return context.makeImage()
    }

    /// Writes `pages` to `path` with the system PDF writer. A picture page is one bitmap drawn over the page and nothing else.
    static func write(_ pages: [Page], to path: String) throws {
        var box = CGRect(x: 0, y: 0, width: PdfMaker.width, height: PdfMaker.height)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else {
            throw PdfMakerError(description: "the system could not start a PDF at \(path)")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text):
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                var y = PdfMaker.height - 30
                for line in PdfMaker.wrap(text) {
                    context.textPosition = CGPoint(x: 20, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
                    y -= 12
                }
            case .picture(let words):
                guard let image = pictureImage(words) else {
                    context.endPDFPage()
                    context.closePDF()
                    throw PdfMakerError(description: "the test could not draw the picture \(words)")
                }
                context.draw(image, in: box)
            case .blank:
                break
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// The words Vision reads in `image`, joined by spaces (the test's own witness, never the product's).
    static func recognised(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { recordVisionFailure(error) }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// The number of file descriptors this process holds open right now (proc_pidinfo, so it opens none itself).
    static func openDescriptorCount() -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        return bytes > 0 ? Int(bytes) / MemoryLayout<proc_fdinfo>.size : -1
    }

    /// A thrown Vision error is a failure with its cause, never a quiet empty read.
    static func recordVisionFailure(_ error: Error) {
        Issue.record("Vision threw: \(error) (\(error.localizedDescription)); open file descriptors in this process: \(openDescriptorCount())")
    }

    /// What PDFKit and Vision say about page `index` (0-based): the characters of its text layer and the words on a 500 x 300
    /// thumbnail. nil when PDFKit cannot open the file or the page.
    static func witnessWords(_ path: String, page index: Int) -> (layerCharacters: Int, seen: String)? {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked, let page = document.page(at: index) else {
            return nil
        }
        let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
        let thumbnail = page.thumbnail(of: CGSize(width: 500, height: 300), for: .mediaBox)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        guard let cg = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return (layer, recognised(cg))
    }
}

// MARK: a temp folder

private final class ScanDir {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-pdfscan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }

    func file(_ name: String) -> String { path + "/" + name }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

private func withScanDir(_ body: (ScanDir) throws -> Void) throws {
    let dir = try ScanDir()
    defer { dir.remove() }
    try body(dir)
}

// MARK: reading through the interface

private func identityOf(_ path: String) -> FileIdentity {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0 else { return FileIdentity(size: 0, mtimeNs: 0, inode: 0) }
    return FileIdentity(size: Int64(info.st_size),
                        mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                        inode: UInt64(info.st_ino))
}

private func readStep(_ path: String, firstPage: Int = 1) throws -> PdfStep {
    try PdfReader.read(path: path, expecting: identityOf(path), firstPage: firstPage)
}

private struct ScanParts {
    let ocr: String
    let width: Int
    let height: Int
    let rgbCount: Int
    let darkest: UInt8
    let lightest: UInt8
}

private func scanParts(_ page: PdfPage) -> ScanParts? {
    guard case .scan(let ocrText, let bitmap) = page.kind else { return nil }
    let bytes = Array(bitmap.rgb)
    return ScanParts(ocr: ocrText, width: Int(bitmap.width), height: Int(bitmap.height), rgbCount: bitmap.rgb.count,
                     darkest: bytes.min() ?? 255, lightest: bytes.max() ?? 0)
}

private func textOf(_ page: PdfPage) -> String? {
    if case .text(let text) = page.kind { return text }
    return nil
}

/// The sample is what the test says it is: no text layer on a picture page, and Vision reads `word` on its thumbnail.
private func checkPicturePage(_ path: String, page index: Int, word: String) {
    guard let witness = ScanPdf.witnessWords(path, page: index) else {
        Issue.record("setup: PDFKit cannot read page \(index + 1) of the sample")
        return
    }
    #expect(witness.layerCharacters == 0, "setup: page \(index + 1) has a text layer of \(witness.layerCharacters) characters, it must be a picture only")
    #expect(witness.seen.lowercased().contains(word.lowercased()),
            "setup: Vision reads \"\(witness.seen)\" on page \(index + 1), not \(word): the sample cannot be told from a blank page")
}

// MARK: the tests

@Suite("PdfScanTests", .serialized)
struct PdfScanTests {

    @Test func aScanPageIsScanWithItsRecognisedWordsAndABitmapOfWidthTimesHeightTimesThree() throws {
        try withScanDir { dir in
            let path = dir.file("walnutsaddle.pdf")
            try ScanPdf.write([.picture("WALNUT"), .picture("SADDLE")], to: path)
            checkPicturePage(path, page: 0, word: "WALNUT")
            checkPicturePage(path, page: 1, word: "SADDLE")

            let step = try readStep(path)
            #expect(step.pageCount == 2 && step.pages.map(\.number) == [1, 2], "pages \(step.pages.map(\.number)) of \(step.pageCount)")
            guard step.pages.count == 2 else { return }
            for (index, word, other) in [(0, "walnut", "saddle"), (1, "saddle", "walnut")] {
                let parts = try #require(scanParts(step.pages[index]), "page \(index + 1) is a picture only and should be .scan, it is not")
                #expect(parts.ocr.lowercased().contains(word), "page \(index + 1): the recognised text \"\(parts.ocr)\" does not hold \(word)")
                #expect(!parts.ocr.lowercased().contains(other), "page \(index + 1): the recognised text \"\(parts.ocr)\" holds the other page's word \(other)")
                #expect(parts.width > 0 && parts.height > 0, "page \(index + 1): the bitmap is \(parts.width) x \(parts.height)")
                #expect(parts.rgbCount == parts.width * parts.height * 3,
                        "page \(index + 1): rgb.count is \(parts.rgbCount), expected width * height * 3 = \(parts.width * parts.height * 3)")
                // The bitmap is the page's picture: black letters on white leave both very dark and very light bytes.
                #expect(parts.darkest < 128 && parts.lightest > 200,
                        "page \(index + 1): the bitmap's darkest byte is \(parts.darkest) and its lightest \(parts.lightest), it does not look like black letters on white")
            }
        }
    }

    @Test func aPageWithNothingOnItIsScanWithNoWordsAndStillHasABitmap() throws {
        try withScanDir { dir in
            let path = dir.file("emptysheet.pdf")
            try ScanPdf.write([.blank], to: path)
            let witness = try #require(ScanPdf.witnessWords(path, page: 0), "setup: PDFKit cannot read the sample")
            #expect(witness.layerCharacters == 0 && !witness.seen.contains(where: { $0.isLetter || $0.isNumber }),
                    "setup: the blank sample holds \(witness.layerCharacters) text characters and Vision reads \"\(witness.seen)\"")

            let step = try readStep(path)
            #expect(step.pageCount == 1 && step.pages.map(\.number) == [1], "pages \(step.pages.map(\.number)) of \(step.pageCount)")
            let page = try #require(step.pages.first, "no page came back")
            let parts = try #require(scanParts(page), "a page with nothing on it should be .scan")
            #expect(!parts.ocr.contains(where: { $0.isLetter || $0.isNumber }), "a blank page's recognised text is \"\(parts.ocr)\"")
            #expect(parts.width > 0 && parts.height > 0 && parts.rgbCount == parts.width * parts.height * 3,
                    "the blank page's bitmap is \(parts.width) x \(parts.height) with \(parts.rgbCount) bytes")
        }
    }

    @Test func aTextPageAndAScanPageOfOnePdfComeBackInOneStepInPageOrder() throws {
        try withScanDir { dir in
            let first = PdfMaker.token("zorv", 11), second = PdfMaker.token("zorv", 12)
            let path = dir.file("mixedsheets.pdf")
            try ScanPdf.write([.text(PdfMaker.rich(first)), .picture("SADDLE"), .text(PdfMaker.rich(second)), .picture("COBBLER")], to: path)
            let layers = try #require(PdfMaker.pageStrings(path), "setup: PDFKit cannot read the sample")
            #expect(layers.count == 4, "setup: PDFKit sees \(layers.count) pages")
            guard layers.count == 4 else { return }
            #expect(layers[0].contains(first) && layers[2].contains(second), "setup: the text layers of pages 1 and 3 do not hold their words")
            #expect(layers[0].trimmingCharacters(in: .whitespacesAndNewlines).count >= 250 && layers[2].trimmingCharacters(in: .whitespacesAndNewlines).count >= 250,
                    "setup: the text pages are shorter than 250 characters")
            checkPicturePage(path, page: 1, word: "SADDLE")
            checkPicturePage(path, page: 3, word: "COBBLER")

            let step = try readStep(path)
            #expect(step.pageCount == 4 && step.pages.map(\.number) == [1, 2, 3, 4],
                    "one call should give all 4 pages in order, it gave \(step.pages.map(\.number)) of \(step.pageCount)")
            guard step.pages.count == 4 else { return }
            #expect(textOf(step.pages[0])?.contains(first) == true, "page 1 should be text with \(first)")
            #expect(textOf(step.pages[2])?.contains(second) == true, "page 3 should be text with \(second)")
            #expect(textOf(step.pages[0])?.contains(second) != true && textOf(step.pages[2])?.contains(first) != true, "a text page holds the other text page's word")
            let scan2 = try #require(scanParts(step.pages[1]), "page 2 is a picture and should be .scan")
            let scan4 = try #require(scanParts(step.pages[3]), "page 4 is a picture and should be .scan")
            #expect(scan2.ocr.lowercased().contains("saddle") && !scan2.ocr.lowercased().contains("cobbler"), "page 2 recognised \"\(scan2.ocr)\", expected saddle only")
            #expect(scan4.ocr.lowercased().contains("cobbler") && !scan4.ocr.lowercased().contains("saddle"), "page 4 recognised \"\(scan4.ocr)\", expected cobbler only")
            for (number, parts) in [(2, scan2), (4, scan4)] {
                #expect(parts.rgbCount == parts.width * parts.height * 3 && parts.width > 0 && parts.height > 0,
                        "page \(number): the bitmap is \(parts.width) x \(parts.height) with \(parts.rgbCount) bytes")
            }
            #expect(scanParts(step.pages[0]) == nil && scanParts(step.pages[2]) == nil, "a text page also came back as .scan")
        }
    }
}
