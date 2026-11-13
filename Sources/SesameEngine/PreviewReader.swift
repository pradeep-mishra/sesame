import CoreGraphics
import Foundation
import ImageIO
import SQLite3

/// The right pane's reader (design section 3, "Preview"): re-admits the path, compares the file with the `files` row, and
/// answers with the facts of the file plus what the pane shows of it: a photo as a PNG at pane size in the helper's scratch
/// folder, a PDF as the PNG of one whole page with the matches marked and "Page N of M", a document as a window of its text
/// with the matched words marked. The file is opened only through `FileGate`; a preview loads no model.
public final class PreviewReader: @unchecked Sendable {
    /// The pane's largest picture: the 960 x 560 panel at 2x scale.
    static let paneWidth = 1920
    static let paneHeight = 1120
    /// A document passage is about this many UTF-16 units, around the stored chunk.
    static let passageUnits = 600

    /// The longest side of a video frame in the pane, leaving room for the timeline strip inside the pane's height.
    static let frameSide = paneHeight - 40

    private let scratch: Scratch
    private let speech: SpeechService
    private let lock = NSLock()
    private var newest = 0

    /// The live service: Apple's recognizer, on this Mac only.
    public convenience init(scratch: Scratch) {
        self.init(scratch: scratch, speech: LiveSpeech())
    }

    public init(scratch: Scratch, speech: SpeechService) {
        self.scratch = scratch
        self.speech = speech
    }

    /// The reply to one `preview` line. `gone` for a path that is not in the index, is no longer admitted, or cannot
    /// be read (the protocol has no other word; G20 asks for "Can't preview this file" there). `passage` is the id of the
    /// passage the result list showed and `query` the words typed: they choose the page or the window and what is marked.
    /// A call with a larger ticket makes every older call still running stop early.
    public func reply(ticket: Int, file path: String, passage: Int? = nil, query: String = "") -> PreviewReply {
        lock.lock()
        newest = max(newest, ticket)
        lock.unlock()
        let superseded: @Sendable () -> Bool = { [self] in
            lock.lock()
            defer { lock.unlock() }
            return newest > ticket
        }
        let name = (path as NSString).lastPathComponent
        let known = Rules.kind(forExtension: (name as NSString).pathExtension.lowercased())
        let kind = known.flatMap { ["pdf", "doc", "audio", "video", "code"].contains($0) ? $0 : nil } ?? "photo"
        let gone = PreviewReply(ticket: ticket, status: .gone, png: nil, name: name, kind: kind, size: nil, mtime: nil)
        guard path.hasPrefix("/"), let indexed = Self.indexedIdentity(of: path), let admitted = Rules.admit(path: path)
        else { return gone }
        switch admitted.kind {
        case "photo": return photoReply(ticket: ticket, admitted, name: name, indexed: indexed) ?? gone
        case "pdf": return pdfReply(ticket: ticket, admitted, name: name, indexed: indexed, passage: passage, query: query) ?? gone
        case "doc": return docReply(ticket: ticket, admitted, name: name, indexed: indexed, passage: passage, query: query) ?? gone
        case "audio": return audioReply(ticket: ticket, admitted, name: name, indexed: indexed, passage: passage, superseded) ?? gone
        case "video": return videoReply(ticket: ticket, admitted, name: name, indexed: indexed, passage: passage, superseded) ?? gone
        case "code": return codeReply(ticket: ticket, admitted, name: name, indexed: indexed, passage: passage, query: query) ?? gone
        default: return gone
        }
    }

    private struct CodeShown {
        let first: Int
        let last: Int
        let match: Int
        let lines: [String]
    }

    private func codeReply(ticket: Int, _ admitted: Admitted, name: String, indexed: FileIdentity, passage: Int?, query: String) -> PreviewReply? {
        let words = QueryWords.of(query)
        let stored = Self.storedPassage(of: admitted.path, id: passage, fallback: "code")
        let ext = (admitted.path as NSString).pathExtension.lowercased()
        guard let (identity, shown) = stable(admitted, indexed: indexed, { changed, data -> CodeShown? in
            guard data.count <= CodeReader.maxBytes, let lines = CodePreview.lines(of: data), !lines.isEmpty else { return nil }
            let range: ClosedRange<Int>
            if !changed, let stored, stored.start >= 1, stored.start <= lines.count, stored.end >= stored.start {
                range = (stored.start - 1)...(min(stored.end, lines.count) - 1)
            } else {
                range = CodePreview.window(lines: lines, around: CodePreview.matchLine(lines: lines, words: words, ext: ext))
            }
            let shownLines = Array(lines[range])
            let match = CodePreview.matchLine(lines: shownLines, words: words, ext: ext)
            return CodeShown(first: range.lowerBound + 1, last: range.upperBound + 1, match: match, lines: shownLines)
        }) else { return nil }
        let status: PreviewStatus = identity == indexed ? .ok : .changed
        let size = Int(identity.size), mtime = Int(identity.mtimeNs / 1_000_000_000)
        guard let shown else {
            return PreviewReply(ticket: ticket, status: status, png: nil, name: name, kind: "code", size: size, mtime: mtime)
        }
        var offset = 0
        for line in shown.lines[..<shown.match] { offset += line.utf16.count + 1 }
        return PreviewReply(
            ticket: ticket, status: status, png: nil, name: name, kind: "code", size: size, mtime: mtime,
            locator: "Lines \(shown.first) to \(shown.last)", text: shown.lines.joined(separator: "\n"),
            marks: [offset, offset + shown.lines[shown.match].utf16.count], line: shown.first + shown.match, firstLine: shown.first)
    }

    private func photoReply(ticket: Int, _ admitted: Admitted, name: String, indexed: FileIdentity) -> PreviewReply? {
        let path = admitted.path
        // Stat, read, stat: a file that changes under the read is read again, once.
        var identity = FileIdentity.of(path: path)
        var data: Data?
        for _ in 0..<2 {
            guard let before = identity else { return nil }
            guard let bytes = try? FileGate.read(admitted) else { return nil }
            identity = FileIdentity.of(path: path)
            data = bytes
            if identity == before { break }
        }
        guard let identity, let data, let png = Self.paneImage(from: data),
              let written = try? scratch.write(png, name: "preview-\(ticket).png") else { return nil }
        return PreviewReply(
            ticket: ticket, status: identity == indexed ? .ok : .changed, png: written, name: name, kind: "photo",
            size: Int(identity.size), mtime: Int(identity.mtimeNs / 1_000_000_000))
    }

    /// Stat, read, work on the bytes, stat: the work is done again, once, when the file changed under it. Nil when the
    /// path is gone or cannot be read. `work` is told whether the file already differs from what the index holds.
    private func stable<T>(_ admitted: Admitted, indexed: FileIdentity, _ work: (_ changed: Bool, Data) -> T) -> (FileIdentity, T)? {
        var identity = FileIdentity.of(path: admitted.path)
        var done: (FileIdentity, T)?
        for _ in 0..<2 {
            guard let before = identity else { return nil }
            guard let bytes = try? FileGate.read(admitted) else { return nil }
            let result = work(before != indexed, bytes)
            identity = FileIdentity.of(path: admitted.path)
            guard let after = identity else { return nil }
            done = (after, result)
            if after == before { break }
        }
        return done
    }

    /// A PDF: one page of the bytes read, drawn whole with the query words marked. A file PDFKit cannot open stays `ok`
    /// with no picture and no locator, so the pane says "Can't preview this file".
    private func pdfReply(ticket: Int, _ admitted: Admitted, name: String, indexed: FileIdentity, passage: Int?, query: String) -> PreviewReply? {
        let words = QueryWords.of(query)
        let stored = Self.storedPassage(of: admitted.path, id: passage, fallback: "page")
        let storedPage = stored.map { $0.start } ?? 1
        guard let (identity, shown) = stable(admitted, indexed: indexed, { changed, data in
            PdfPreview.show(data: data, storedPage: storedPage, words: words, findFirst: changed)
        }) else { return nil }
        let status: PreviewStatus = identity == indexed ? .ok : .changed
        let size = Int(identity.size), mtime = Int(identity.mtimeNs / 1_000_000_000)
        guard let shown, let written = try? scratch.write(shown.png, name: "preview-\(ticket).png") else {
            return PreviewReply(ticket: ticket, status: status, png: nil, name: name, kind: "pdf", size: size, mtime: mtime)
        }
        return PreviewReply(
            ticket: ticket, status: status, png: written, name: name, kind: "pdf", size: size, mtime: mtime,
            page: shown.page, pageCount: shown.pageCount, locator: "Page \(shown.page) of \(shown.pageCount)")
    }

    /// A document: the text as `DocReader` reads it, a window of about `passageUnits` units around the stored chunk (around
    /// the first match when the file is not what was indexed) and the whole-word matches inside it. A document with no
    /// chunk, or with no text, is `ok` with only its facts.
    private func docReply(ticket: Int, _ admitted: Admitted, name: String, indexed: FileIdentity, passage: Int?, query: String) -> PreviewReply? {
        let words = QueryWords.of(query)
        let stored = Self.storedPassage(of: admitted.path, id: passage, fallback: "chunk")
        let ext = (admitted.path as NSString).pathExtension
        guard let (identity, shown) = stable(admitted, indexed: indexed, { changed, data -> Passage? in
            guard stored != nil || changed, let text = try? DocReader.text(from: data, extension: ext) else { return nil }
            return Self.passage(in: text, chunk: stored.map { ($0.start, $0.end) }, words: words, findFirst: changed)
        }) else { return nil }
        return PreviewReply(
            ticket: ticket, status: identity == indexed ? .ok : .changed, png: nil, name: name, kind: "doc",
            size: Int(identity.size), mtime: Int(identity.mtimeNs / 1_000_000_000), text: shown?.text, marks: shown?.marks ?? [])
    }

    /// Why a media read did not give a picture: the file is gone (or no longer admitted, opened, or wanted), or it no longer opens.
    private enum MediaTrouble: Error {
        case gone, unreadable
    }

    /// `read` takes the file's identity as it is now and gives what the reader returned. A file that changes under the read
    /// (the reader says so, or the identity after differs) is read again, once.
    private static func settled<T>(_ path: String, _ read: (FileIdentity) throws -> T) -> Result<(FileIdentity, T), MediaTrouble> {
        for attempt in 0..<2 {
            guard let before = FileIdentity.of(path: path) else { return .failure(.gone) }
            do {
                let value = try read(before)
                guard let after = FileIdentity.of(path: path) else { return .failure(.gone) }
                if after == before || attempt == 1 { return .success((after, value)) }
            } catch AudioReadError.changed {
                if attempt == 1 { return .failure(.unreadable) }
            } catch VideoReadError.changed {
                if attempt == 1 { return .failure(.unreadable) }
            } catch AudioReadError.unreadable {
                return .failure(.unreadable)
            } catch VideoReadError.unreadable {
                return .failure(.unreadable)
            } catch {
                return .failure(.gone)
            }
        }
        return .failure(.unreadable)
    }

    private static func opensAt(_ seconds: Int) -> String {
        String(format: "Opens at %02d:%02d", seconds / 60, seconds % 60)
    }

    /// An audio file: the waveform of the stored window (the first window when the file is not what was indexed and the stored
    /// start is past its end now), the words an on-device recognizer hears in exactly those samples, and "Opens at mm:ss". A file
    /// the decoder no longer takes stays `ok` with no picture and no locator, so the pane says "Can't preview this file".
    private func audioReply(
        ticket: Int, _ admitted: Admitted, name: String, indexed: FileIdentity, passage: Int?, _ superseded: @escaping @Sendable () -> Bool
    ) -> PreviewReply? {
        let wanted = Self.storedPassage(of: admitted.path, id: passage, fallback: "audio")?.start ?? 0
        let outcome = Self.settled(admitted.path) { identity -> (Int, AudioWindow) in
            for start in wanted == 0 ? [0] : [wanted, 0] {
                if let window = try AudioReader.window(
                    path: admitted.path, expecting: identity, start: start, scratch: scratch, shouldStop: superseded) {
                    return (start, window)
                }
            }
            throw AudioReadError.unreadable
        }
        switch outcome {
        case .failure(.gone): return nil
        case .failure:
            return unopened(ticket: ticket, name: name, kind: "audio", admitted, indexed: indexed)
        case let .success((identity, shown)):
            let status: PreviewStatus = identity == indexed ? .ok : .changed
            guard let png = AudioPreview.png(samples: shown.1.samples), let written = try? scratch.write(png, name: "preview-\(ticket).png")
            else { return PreviewReply(ticket: ticket, status: status, png: nil, name: name, kind: "audio", size: Int(identity.size), mtime: Int(identity.mtimeNs / 1_000_000_000)) }
            var words: String?
            if speech.supportsOnDevice {
                words = speech.transcribe(samples: shown.1.samples, request: LiveSpeech.makeRequest(), isCancelled: superseded)
            }
            return PreviewReply(
                ticket: ticket, status: status, png: written, name: name, kind: "audio", size: Int(identity.size),
                mtime: Int(identity.mtimeNs / 1_000_000_000), locator: Self.opensAt(shown.0), text: words, seconds: shown.0)
        }
    }

    /// A video: the frame at the stored second (the first frame when the file is not what was indexed and that second is past
    /// its end now) on a timeline strip. A soundtrack window shows the frame of its start second.
    private func videoReply(
        ticket: Int, _ admitted: Admitted, name: String, indexed: FileIdentity, passage: Int?, _ superseded: @escaping @Sendable () -> Bool
    ) -> PreviewReply? {
        let wanted = Self.storedPassage(of: admitted.path, id: passage, fallback: "frame", also: "audio")?.start ?? 0
        let outcome = Self.settled(admitted.path) { identity -> (Int, VideoStill) in
            let still = try VideoReader.frame(
                path: admitted.path, expecting: identity, second: wanted, maxSide: Self.frameSide, scratch: scratch, shouldStop: superseded)
            guard Double(wanted) >= still.duration else { return (wanted, still) }
            return (0, try VideoReader.frame(
                path: admitted.path, expecting: identity, second: 0, maxSide: Self.frameSide, scratch: scratch, shouldStop: superseded))
        }
        switch outcome {
        case .failure(.gone): return nil
        case .failure:
            return unopened(ticket: ticket, name: name, kind: "video", admitted, indexed: indexed)
        case let .success((identity, shown)):
            let status: PreviewStatus = identity == indexed ? .ok : .changed
            guard let png = VideoPreview.png(frame: shown.1.image, second: shown.0, duration: shown.1.duration),
                  let written = try? scratch.write(png, name: "preview-\(ticket).png")
            else { return PreviewReply(ticket: ticket, status: status, png: nil, name: name, kind: "video", size: Int(identity.size), mtime: Int(identity.mtimeNs / 1_000_000_000)) }
            return PreviewReply(
                ticket: ticket, status: status, png: written, name: name, kind: "video", size: Int(identity.size),
                mtime: Int(identity.mtimeNs / 1_000_000_000), locator: Self.opensAt(shown.0), seconds: shown.0)
        }
    }

    /// A media file the decoder no longer takes: `ok` (or `changed`) with only its facts.
    private func unopened(ticket: Int, name: String, kind: String, _ admitted: Admitted, indexed: FileIdentity) -> PreviewReply? {
        guard let identity = FileIdentity.of(path: admitted.path) else { return nil }
        return PreviewReply(
            ticket: ticket, status: identity == indexed ? .ok : .changed, png: nil, name: name, kind: kind,
            size: Int(identity.size), mtime: Int(identity.mtimeNs / 1_000_000_000))
    }

    struct Passage {
        let text: String
        let marks: [Int]
    }

    /// The window of `text` to show, and the flat (start, end) offsets of the query words inside it. `chunk` is the stored
    /// place; `findFirst` looks for the first match in the whole text instead (the file changed since it was indexed).
    static func passage(in text: String, chunk: (Int, Int)?, words: [String], findFirst: Bool) -> Passage? {
        let whole = text as NSString
        guard whole.length > 0 else { return nil }
        let regex = QueryWords.regex(words)
        var low = 0, high = whole.length
        var middle: Int?
        if findFirst, let regex, let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: whole.length)) {
            middle = match.range.location + match.range.length / 2
        } else if let chunk, chunk.0 < whole.length {
            low = max(0, chunk.0)
            high = min(max(chunk.1, low), whole.length)
            if let regex, let match = regex.firstMatch(in: text, range: NSRange(location: low, length: high - low)) {
                middle = match.range.location + match.range.length / 2
            }
        }
        let centre = middle ?? (low + high) / 2
        var start = min(max(centre - passageUnits / 2, low), max(low, high - passageUnits))
        var end = min(start + passageUnits, whole.length)
        // Begin and end between words, and never inside a character made of several units.
        let limit = 60
        func isSpace(_ at: Int) -> Bool {
            Unicode.Scalar(whole.character(at: at)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        if start > 0, !isSpace(start - 1), let cut = (start..<min(start + limit, end)).first(where: isSpace) { start = cut + 1 }
        if end < whole.length, !isSpace(end), let cut = ((max(start, end - limit)..<end).reversed()).first(where: isSpace) { end = cut }
        if start > 0 { start = whole.rangeOfComposedCharacterSequence(at: start).location }
        if end < whole.length { end = whole.rangeOfComposedCharacterSequence(at: end).location }
        guard end > start else { return nil }
        let window = whole.substring(with: NSRange(location: start, length: end - start))
        var marks: [Int] = []
        if let regex {
            for match in regex.matches(in: window, range: NSRange(location: 0, length: (window as NSString).length)) {
                marks += [match.range.location, match.range.location + match.range.length]
            }
        }
        return Passage(text: window, marks: marks)
    }

    /// Deletes the PNG of a reply that is not going to be sent.
    public func discard(_ reply: PreviewReply) {
        if let png = reply.png { scratch.remove(path: png) }
    }

    /// Runs `body` on the index, opened read-only; nil when there is no index or it cannot be opened.
    private static func withIndex<T>(_ body: (OpaquePointer) -> T?) -> T? {
        guard FileManager.default.fileExists(atPath: Schema.indexPath) else { return nil }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(Schema.indexPath, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle = opened else {
            sqlite3_close_v2(opened)
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 1000)
        return body(handle)
    }

    /// What the index holds for the path: size, modified time and inode as they were when it was walked, or nil
    /// when there is no row (never picked, taken out of the list, or no index yet).
    private static func indexedIdentity(of path: String) -> FileIdentity? {
        withIndex { handle in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT size, mtime_ns, inode FROM files WHERE path = ?", -1, &statement, nil) == SQLITE_OK
            else {
                sqlite3_finalize(statement)
                return nil
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, path, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return FileIdentity(
                size: sqlite3_column_int64(statement, 0), mtimeNs: sqlite3_column_int64(statement, 1),
                inode: UInt64(bitPattern: sqlite3_column_int64(statement, 2)))
        }
    }

    /// A passage as the index stores it: its source and its `start` and `end` (a page number twice, or UTF-16 offsets).
    struct StoredPassage {
        let source: String
        let start: Int
        let end: Int
    }

    /// The passage `id` of the file at `path` when it is of source `fallback` ("page", "chunk", "audio" or "frame") or of `also`;
    /// else the first passage of the `fallback` source (a hit on the file's name shows the start of it); nil when the file has none.
    private static func storedPassage(of path: String, id: Int?, fallback: String, also: String? = nil) -> StoredPassage? {
        let select = """
            SELECT p.source, CAST(p.start AS INTEGER), CAST(p."end" AS INTEGER) FROM passages p
            JOIN files f ON f.id = p.file_id WHERE f.path = ?1
            """
        return withIndex { handle in
            if let id, let found = passageRow(handle, select + " AND p.id = ?2", path: path, id: Int64(id)),
               found.source == fallback || found.source == also { return found }
            return passageRow(handle, select + " AND p.source = '\(fallback)' ORDER BY p.start LIMIT 1", path: path, id: nil)
        }
    }

    private static func passageRow(_ handle: OpaquePointer, _ sql: String, path: String, id: Int64?) -> StoredPassage? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, sqliteTransient)
        if let id { sqlite3_bind_int64(statement, 2, id) }
        guard sqlite3_step(statement) == SQLITE_ROW, let source = sqlite3_column_text(statement, 0) else { return nil }
        return StoredPassage(
            source: String(cString: source), start: Int(sqlite3_column_int64(statement, 1)),
            end: Int(sqlite3_column_int64(statement, 2)))
    }

    /// The picture as PNG bytes, turned upright and fitted inside the pane, never enlarged.
    static func paneImage(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        let (shownWidth, shownHeight) = turned ? (height, width) : (width, height)
        let scale = min(1, Double(paneWidth) / Double(shownWidth), Double(paneHeight) / Double(shownHeight))
        let longest = max(1, Int((Double(max(shownWidth, shownHeight)) * scale).rounded(.down)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

/// The words of a query as the preview marks them: whole words, in any letter case.
enum QueryWords {
    /// Runs of letters, digits and the underscore, lowercase, each once, in the order typed.
    static func of(_ query: String) -> [String] {
        var seen = Set<String>()
        return query.split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }

    /// One expression for any of `words` as a whole word (a letter, digit or underscore on either side ends no word);
    /// nil when there are none.
    static func regex(_ words: [String]) -> NSRegularExpression? {
        guard !words.isEmpty else { return nil }
        let any = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])(?:\(any))(?![\\p{L}\\p{N}_])", options: [.caseInsensitive])
    }
}
