import Foundation
import PDFKit

/// One page of a step: its number (1-based) and what the page is.
public struct PdfPage: Sendable {
    public enum Kind: Sendable {
        /// A page with at least `PdfReader.textThreshold` text characters: its text, trimmed.
        case text(String)
        /// Fewer characters than that, or none: the page drawn as a picture, the words Vision reads in it (empty when it
        /// reads none) and the picture at the size the vision encoder takes.
        case scan(ocrText: String, bitmap: PhotoBitmap)
    }

    public let number: Int
    public let kind: Kind
}

/// What one call of `PdfReader.read` returns: the file's page count, up to `stepPages` pages from `firstPage` on, and
/// the words of the file's own name and folder.
public struct PdfStep: Sendable {
    public let pageCount: Int
    public let pages: [PdfPage]
    public let nameWords: String
}

public enum PdfReadError: Error, Equatable {
    /// The path is gone, is not a regular PDF any more, or `Rules.admit` no longer takes it.
    case notAdmitted
    /// Its size, modified time or inode differ from `expecting`, before or after the read.
    case changed
    /// The bytes could not be got: the process may not open the file. The caller leaves it to be tried again.
    case cannotOpen
    /// The file asks for a password.
    case locked
    /// The bytes were read and PDFKit finds no page in them, or none at `firstPage`, or a page that cannot be drawn.
    case unreadable
}

/// PDF file to pages (design sections 3 and 4): stat before and after, PDFKit on the bytes `FileGate` read, a page with
/// 200 or more text characters is text, any other is a scan (drawn, read by Vision, cut to the encoder's size). The file is opened only through `FileGate`.
public enum PdfReader {
    public static let textThreshold = 200
    /// A long file is read this many pages at a time.
    public static let stepPages = 30
    /// A scan page is drawn with its long side this many pixels, enough for Vision to read small print.
    static let scanSide: CGFloat = 1600

    /// `shouldStop` is asked once before each page; true throws `MediaStopped` and the step is dropped.
    public static func read(
        path: String, expecting: FileIdentity, firstPage: Int, shouldStop: () -> Bool = { false }
    ) throws -> PdfStep {
        guard let admitted = Rules.admit(path: path), admitted.kind == "pdf" else { throw PdfReadError.notAdmitted }
        guard FileIdentity.of(path: path) == expecting else { throw PdfReadError.changed }
        let data: Data
        do { data = try FileGate.read(admitted) } catch { throw PdfReadError.cannotOpen }
        guard FileIdentity.of(path: path) == expecting else { throw PdfReadError.changed }

        guard let document = PDFDocument(data: data) else { throw PdfReadError.unreadable }
        if document.isLocked { throw PdfReadError.locked }
        let count = document.pageCount
        guard count > 0, (1...count).contains(firstPage) else { throw PdfReadError.unreadable }

        var pages: [PdfPage] = []
        for number in firstPage...min(firstPage + stepPages - 1, count) {
            if shouldStop() { throw MediaStopped() }
            try autoreleasepool {
                let page = document.page(at: number - 1)
                let text = (page?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= textThreshold {
                    pages.append(PdfPage(number: number, kind: .text(text)))
                } else if let page, let scan = try scanKind(of: page) {
                    pages.append(PdfPage(number: number, kind: scan))
                } else {
                    throw PdfReadError.unreadable
                }
            }
        }
        return PdfStep(pageCount: count, pages: pages, nameWords: PhotoReader.nameWords(for: path))
    }

    /// A page with no text layer drawn with `PDFPage.thumbnail` (its long side `scanSide` pixels), read by Vision and cut
    /// to the encoder's size. nil when the page has no size or cannot be drawn; throws `RecognitionFailed` when Vision fails twice.
    private static func scanKind(of page: PDFPage) throws -> PdfPage.Kind? {
        var bounds = page.bounds(for: .cropBox)
        if page.rotation % 180 != 0 { bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width) }
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let scale = scanSide / max(bounds.width, bounds.height)
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let bitmap = PhotoReader.bitmap(of: image) else { return nil }
        return .scan(ocrText: try PhotoReader.recognizeText(in: image, orientation: .up), bitmap: bitmap)
    }
}
