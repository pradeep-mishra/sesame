import Foundation
import Testing
import SesameEngine

// plan-4-t7, tester step. Written from the t7 entry of plan-4-tasks.md (Tests), the Conventions of plan-4-tasks.md, Decision D7,
// design sections 1, 3 and 5 and the spec's S3 only; no product source is read. The rigs reused, never edited: the `At...` harness of
// IndexAttemptTests.swift (AtWorld, AtDB, atStartHelper, atFoldersLine, atWaitStatuses, atCleanStop, atPast), `DocMaker` and
// `DocSample` of DocReaderTests.swift (the six document types made by this file, with an anchor phrase, a word before it and a word
// after it), `PdfMaker.token` and `PdfMaker.fillerSentence` of PdfReaderTests.swift, and `homeLock` of SesameFolderTests.swift.
//
// How a run is made. One shared world (a lazily built global): a folder of twelve documents, every one made by this file, picked by
// the bundled release helper alone (`scripts/bundle.sh` first), fake embedder, throwaway HOME. When all twelve files are `done`
// the helper is stopped, so the index is closed. Each test then calls `PreviewReader.reply(ticket:file:passage:query:)` in this
// process with the passage id this file reads from the index (`start` and `end` are stored as REAL, so they are cast to integers),
// under the world's HOME (the product reads HOME when it is called, as SesameFolderTests establishes) and under `homeLock`.
//
// The files of the world (each test mutates only its own):
//   pdmemo.txt, pdnotes.md, pdletter.rtf, pdtenancy.docx, pdbaking.html, pdneighbours.odt   the six types, ~1,100 characters each,
//        a word before an anchor of three words, then a word after it, in one sentence in the middle (DocMaker.sample)
//   wholeword.txt   one short paragraph with the word cat three times in three cases and four words that only contain it
//   longdoc.txt     60 numbered sections of ~107 characters, a word of its own in each: about four chunks
//   swap.txt        a document of the same kind; replaced after indexing by one that holds the query word twice, far apart
//   gone-deleted.txt   deleted after indexing; gone-moved.txt  moved into a folder named Caches after indexing
//   empty.txt       zero bytes: only its name passage
//
// SHAPES THIS FILE PINS (the entry names the fields, not these; each is one place to edit, the helpers `pdReply` and `pdExpectedMarks`):
//   1. `PreviewReader(scratch: Scratch()).reply(ticket: Int, file: String, passage: Int?, query: String)`: as PreviewReaderPdfTests.swift
//      says (the one place to edit is `pdReply`).
//   2. `text` is a window of the extracted text: for a txt or md document it is an exact substring of the file's text (no added
//      ellipsis), 400 to 800 UTF-16 units long ("about 600 characters"), and `marks` are flat (start, end) UTF-16 offsets into it
//      with `end` exclusive, ascending, not overlapping, an even count. The window lies around the stored chunk: it shares at least
//      300 characters with the chunk's [start, end), wherever in the chunk the product centres it.
//   3. A mark covers a query word as a whole word, case-insensitively: letters, digits and the underscore on either side end a word.
//      `cat` is marked in `Cat`, `cat` and `CAT` and not in `Concatenate`, `category`, `bobcat` or `cats`.
//   4. For a document `page`, `pageCount` and `locator` are not pinned (the entry fixes only the PDF's locator); `page` and
//      `pageCount` are nil. `kind` is "doc" and `name` the file name.
//   5. A changed document shows the window around the first occurrence of the query word in the file as it is now.
//   6. A document with no chunk (zero bytes) is `.ok` with its name; `text` is nil or empty and `marks` empty.
//
// The two protocol checks the entry puts in ProtocolTests are here, because ProtocolTests is not in this task's touch list: a photo
// reply line carries none of the new fields, and the new fields round-trip. The JSON keys are the field names `page`, `pageCount`,
// `locator`, `text` and `marks` (one place to edit: `pdKeys`).

// MARK: the files

private let pdSamples: [DocSample] = [
    DocMaker.sample("txt", stem: "pdmemo", number: 21),
    DocMaker.sample("md", stem: "pdnotes", number: 22),
    DocMaker.sample("rtf", stem: "pdletter", number: 23),
    DocMaker.sample("docx", stem: "pdtenancy", number: 24),
    DocMaker.sample("html", stem: "pdbaking", number: 25),
    DocMaker.sample("odt", stem: "pdneighbours", number: 26),
]

/// The text a txt or md sample's file holds (the md has a heading line).
private func pdFileText(_ sample: DocSample) -> String {
    sample.ext == "md" ? "# " + sample.stem + "\n\n" + sample.source : sample.source
}

private let pdWholeWordText = "The Cat sat on the cat mat. Concatenate the category list. CAT! A bobcat and two cats nap here."

private let pdSections: [String] = (1...60).map { k in
    "Section \(k): " + PdfMaker.token("zsec", k) + " is recorded here. " + PdfMaker.fillerSentence
}
private let pdLongText = pdSections.joined()

private let pdSwapQuery = PdfMaker.token("zqry", 7)
private let pdSwapFirst = PdfMaker.token("zfst", 1)
private let pdSwapSecond = PdfMaker.token("zsnd", 1)
private let pdSwapNew: String = {
    let filler = PdfMaker.fillerSentence
    return String(repeating: filler, count: 7)
        + "Marker \(pdSwapFirst) then \(pdSwapQuery) appears here first. "
        + String(repeating: filler, count: 40)
        + "Marker \(pdSwapSecond) then \(pdSwapQuery) appears here again. "
        + String(repeating: filler, count: 7)
}()

// MARK: facts about a file, read by the test itself

private struct PdFacts: Equatable {
    var size: Int64
    var mtimeNs: Int64
    var inode: UInt64
    var bytes: Data
}

private func pdFacts(_ path: String) -> PdFacts? {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0, let bytes = FileManager.default.contents(atPath: path) else { return nil }
    return PdFacts(size: Int64(info.st_size),
                   mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                   inode: UInt64(info.st_ino), bytes: bytes)
}

// MARK: the shared world

private final class PdKeeper: @unchecked Sendable {
    private let lock = NSLock()
    private var worlds: [AtWorld] = []
    func add(_ world: AtWorld) { lock.lock(); worlds.append(world); lock.unlock() }
    func run() {
        lock.lock(); let all = worlds; lock.unlock()
        for world in all { world.remove() }
        // The scratch folder this test process's readers may have made (`$TMPDIR/Sesame-<pid>`, design section 1).
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "Sesame-\(getpid())")
    }
}

private let pdKeeper = PdKeeper()

private struct PdChunk {
    let id: Int
    let start: Int
    let end: Int
}

private struct PdWorld: @unchecked Sendable {
    var world: AtWorld?
    var problem: String?

    var folder: String { (world?.photos.path ?? "") + "/docs" }
    func path(_ name: String) -> String { folder + "/" + name }

    /// The `chunk` passages of a file, ascending by start, with their stored offsets read as integers.
    func chunks(_ file: String) -> [PdChunk] {
        guard let rows = world?.db()?.rows("""
            select p.id, cast(p.start as integer), cast(p."end" as integer) from passages p join files f on f.id = p.file_id \
            where f.path like '%/\(file)' and p.source = 'chunk' order by cast(p.start as integer)
            """) else { return [] }
        return rows.compactMap { row in
            guard let id = row[0].flatMap({ Int($0) }), let start = row[1].flatMap({ Int($0) }), let end = row[2].flatMap({ Int($0) }) else { return nil }
            return PdChunk(id: id, start: start, end: end)
        }
    }

    func namePassage(_ file: String) -> Int? {
        world?.db()?.int("select p.id from passages p join files f on f.id = p.file_id where f.path like '%/\(file)' and p.source = 'name'")
    }
}

private let pdWorld: PdWorld = {
    var out = PdWorld()
    guard let world = try? AtWorld() else { out.problem = "could not make a temp world"; return out }
    out.world = world
    pdKeeper.add(world)
    atexit { pdKeeper.run() }
    let fm = FileManager.default
    func age(_ path: String, _ seconds: Int) throws {
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(seconds))], ofItemAtPath: path)
    }
    do {
        try fm.createDirectory(atPath: out.folder, withIntermediateDirectories: true)
        for (index, sample) in pdSamples.enumerated() {
            let path = try DocMaker.write(sample, in: out.folder)
            try age(path, index + 10)
        }
        let plain: [(String, String)] = [
            ("wholeword.txt", pdWholeWordText), ("longdoc.txt", pdLongText),
            ("swap.txt", DocMaker.sample("txt", stem: "swap", number: 31).source),
            ("gone-deleted.txt", DocMaker.sample("txt", stem: "gonedeleted", number: 32).source),
            ("gone-moved.txt", DocMaker.sample("txt", stem: "gonemoved", number: 33).source),
            ("empty.txt", ""),
        ]
        for (index, item) in plain.enumerated() {
            let path = out.path(item.0)
            try Data(item.1.utf8).write(to: URL(fileURLWithPath: path))
            try age(path, index + 20)
        }
    } catch {
        out.problem = "could not make the files: \(error)"
        return out
    }
    // The witnesses: the system itself reads every anchor phrase out of its document, and the long text is long enough for three chunks.
    for sample in pdSamples where ["rtf", "docx", "odt"].contains(sample.ext) {
        guard let text = DocMaker.witness(out.path(sample.fileName)), text.contains(sample.anchor) else {
            out.problem = "setup: textutil does not read the anchor phrase out of \(sample.fileName)"
            return out
        }
    }
    guard pdLongText.utf16.count > 3 * 1_800 else { out.problem = "setup: the long text is too short for three chunks"; return out }
    let helper: HelperProcess
    do { helper = try atStartHelper(world) } catch {
        out.problem = "the bundled helper could not be started: \(error)"
        return out
    }
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    let wait = atWaitStatuses(world, helper, stall: 150, cap: 600, until: { $0 == ["done": 12] })
    guard wait.met else {
        out.problem = "the 12 documents did not all reach done: \(wait.statuses), stderr: \(helper.errors)"
        return out
    }
    guard atCleanStop(helper) == 0 else {
        out.problem = "the helper did not exit 0 within 120 s of its stdin ending; stderr: \(helper.errors)"
        return out
    }
    return out
}()

private struct PdStop: Error {}

private func pdWorldOrStop() throws -> PdWorld {
    let outcome = pdWorld
    if let problem = outcome.problem {
        Issue.record("setup failed: \(problem)")
        throw PdStop()
    }
    return outcome
}

// MARK: calling the reader, under the world's HOME

private func pdReply(_ world: PdWorld, file: String, passage: Int?, query: String, ticket: Int = 1) -> PreviewReply? {
    guard let home = world.world?.home.path else { return nil }
    homeLock.lock()
    defer { homeLock.unlock() }
    let previous = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home, 1)
    defer { if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") } }
    return PreviewReader(scratch: Scratch()).reply(ticket: ticket, file: file, passage: passage, query: query)
}

// MARK: reading marks, with logic of the test's own

/// Every whole-word, case-insensitive occurrence of `words` in `text`, as (start, end) UTF-16 pairs, ascending.
private func pdExpectedMarks(_ words: [String], in text: String) -> [[Int]] {
    var found: [[Int]] = []
    let whole = text as NSString
    for word in words where !word.isEmpty {
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            found.append([match.range.location, match.range.location + match.range.length])
        }
    }
    return found.sorted { $0[0] < $1[0] }
}

/// The marks as pairs, nil when the flat list is not an even count of ascending, non-overlapping, in-bounds offsets.
private func pdPairs(_ marks: [Int], textLength: Int) -> [[Int]]? {
    guard marks.count % 2 == 0 else { return nil }
    var pairs: [[Int]] = []
    var previousEnd = 0
    var index = 0
    while index < marks.count {
        let start = marks[index], end = marks[index + 1]
        guard start >= previousEnd, end > start, end <= textLength else { return nil }
        pairs.append([start, end])
        previousEnd = end
        index += 2
    }
    return pairs
}

private func pdSubstring(_ text: String, _ pair: [Int]) -> String {
    (text as NSString).substring(with: NSRange(location: pair[0], length: pair[1] - pair[0]))
}

// MARK: the JSON of the protocol lines

private let pdKeys = (page: "page", pageCount: "pageCount", locator: "locator", text: "text", marks: "marks")
private let pdNewKeys = [pdKeys.page, pdKeys.pageCount, pdKeys.locator, pdKeys.text, pdKeys.marks]

private func pdParsed(_ text: String) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    return try #require(value as? [String: Any], "the line is not one JSON object: \(text.prefix(200))")
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("PreviewReaderDocTests", .serialized)
struct PreviewReaderDocTests {

    // MARK: the six types

    @Test(arguments: DocMaker.extensions)
    func theTextHoldsAboutSixHundredCharactersAroundTheStoredChunkAndTheMarksCoverEachQueryWordInsideIt(_ ext: String) throws {
        let world = try pdWorldOrStop()
        let sample = try #require(pdSamples.first { $0.ext == ext })
        let path = world.path(sample.fileName)
        let chunk = try #require(world.chunks(sample.fileName).first, "the index holds no chunk passage for \(sample.fileName)")
        let words = sample.anchor.split(separator: " ").map(String.init)
        // The first query word is typed in capitals: the mark is case-insensitive.
        let query = ([words[0].uppercased()] + words.dropFirst()).joined(separator: " ")
        let before = try #require(pdFacts(path))

        guard let reply = pdReply(world, file: path, passage: chunk.id, query: query) else { return }
        #expect(reply.status == .ok, "\(ext): status is \(reply.status), expected ok")
        #expect(reply.kind == "doc", "\(ext): kind is \(reply.kind)")
        #expect(reply.name == sample.fileName, "\(ext): name is \(reply.name)")
        #expect(reply.size == Int(before.size), "\(ext): size is \(String(describing: reply.size)), stat says \(before.size)")
        #expect(reply.mtime == Int(before.mtimeNs / 1_000_000_000), "\(ext): mtime is \(String(describing: reply.mtime))")
        #expect(reply.page == nil && reply.pageCount == nil, "\(ext): a document has no page: \(String(describing: reply.page)) of \(String(describing: reply.pageCount))")

        let text = try #require(reply.text, "\(ext): no passage text in the reply")
        let length = text.utf16.count
        #expect(length >= 400 && length <= 800, "\(ext): the text is \(length) UTF-16 units, expected about 600 (400 to 800)")
        #expect(text.contains(sample.anchor), "\(ext): the text lacks the anchor phrase `\(sample.anchor)`")
        #expect(text.contains(sample.before), "\(ext): the text lacks the source word before the anchor, `\(sample.before)`")
        #expect(text.contains(sample.after), "\(ext): the text lacks the source word after the anchor, `\(sample.after)`")
        if ext == "txt" || ext == "md" {
            #expect(pdFileText(sample).contains(text), "\(ext): the text is not a piece of the file's own text")
        }

        let pairs = try #require(pdPairs(reply.marks, textLength: length), "\(ext): the marks \(reply.marks) are not ascending, in-bounds (start, end) pairs of the \(length) unit text")
        #expect(pairs.map { pdSubstring(text, $0).lowercased() } == words, "\(ext): the marked words are \(pairs.map { pdSubstring(text, $0) }), expected \(words) once each")
        #expect(pairs == pdExpectedMarks(words, in: text), "\(ext): the marks \(pairs) differ from every whole-word occurrence of the query words in the text")

        // The file is only read.
        let after = try #require(pdFacts(path))
        #expect(after == before, "\(ext): the reply changed the file (size, mtime, inode or bytes)")
    }

    // MARK: whole words only, any case

    @Test func aWordIsMarkedOnlyAsAWholeWordInAnyCaseAndNeverInsideALongerWord() throws {
        let world = try pdWorldOrStop()
        let chunk = try #require(world.chunks("wholeword.txt").first, "the index holds no chunk passage for wholeword.txt")
        guard let reply = pdReply(world, file: world.path("wholeword.txt"), passage: chunk.id, query: "cat") else { return }
        #expect(reply.status == .ok)
        let text = try #require(reply.text, "no passage text in the reply")
        #expect(text.contains("Concatenate the category list"), "the text lacks the words that only contain `cat`: \(text)")
        let pairs = try #require(pdPairs(reply.marks, textLength: text.utf16.count), "the marks \(reply.marks) are not ascending, in-bounds (start, end) pairs")
        #expect(pairs.map { pdSubstring(text, $0) } == ["Cat", "cat", "CAT"],
                "the marked words are \(pairs.map { pdSubstring(text, $0) }), expected Cat, cat and CAT: not Concatenate, category, bobcat or cats")
    }

    // MARK: a long document: the window, not the whole chunk

    @Test func inALongDocumentTheTextIsAWindowAroundTheStoredChunkAndNoFarSectionIsInIt() throws {
        let world = try pdWorldOrStop()
        let chunks = world.chunks("longdoc.txt")
        guard chunks.count >= 3 else {
            Issue.record("the long document has \(chunks.count) chunk passages, expected at least 3 (about 1,600 characters each)")
            return
        }
        let chunk = chunks[1]
        let whole = pdLongText as NSString
        // The words of the sections that lie inside the stored chunk (the test knows where each section is: a txt's text is the file).
        var words: [String] = []
        for k in 1...60 {
            let token = PdfMaker.token("zsec", k)
            let at = whole.range(of: token).location
            if at >= chunk.start && at < chunk.end { words.append(token) }
        }
        #expect(words.count >= 8, "the stored chunk [\(chunk.start), \(chunk.end)) holds only \(words.count) section words")

        guard let reply = pdReply(world, file: world.path("longdoc.txt"), passage: chunk.id, query: words.joined(separator: " ")) else { return }
        #expect(reply.status == .ok)
        let text = try #require(reply.text, "no passage text in the reply")
        let length = text.utf16.count
        #expect(length >= 400 && length <= 800, "the text is \(length) UTF-16 units, expected about 600 (400 to 800), not the whole \(chunk.end - chunk.start) unit chunk")
        let place = whole.range(of: text)
        #expect(place.location != NSNotFound, "the text is not a piece of the file's own text")
        if place.location != NSNotFound {
            let overlap = max(0, min(place.location + place.length, chunk.end) - max(place.location, chunk.start))
            #expect(overlap >= 300, "the text at [\(place.location), \(place.location + place.length)) shares only \(overlap) characters with the stored chunk [\(chunk.start), \(chunk.end))")
        }
        #expect(!text.contains(PdfMaker.token("zsec", 1)) && !text.contains(PdfMaker.token("zsec", 60)),
                "the text reaches the first or the last section of the document: it is not a window")
        let pairs = try #require(pdPairs(reply.marks, textLength: length), "the marks \(reply.marks) are not ascending, in-bounds (start, end) pairs of the \(length) unit text")
        #expect(pairs.count >= 2, "only \(pairs.count) words are marked in a window that holds several of the query words")
        #expect(pairs == pdExpectedMarks(words, in: text), "the marks differ from every whole-word occurrence of the query words in the text")
    }

    // MARK: changed

    @Test func aChangedDocumentShowsTheFirstBestMatchOfTheFileAsItIsNowWithItsOwnMarks() throws {
        let world = try pdWorldOrStop()
        let path = world.path("swap.txt")
        let chunk = try #require(world.chunks("swap.txt").first, "the index holds no chunk passage for swap.txt")
        try Data(pdSwapNew.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast + 600)], ofItemAtPath: path)
        let now = try #require(pdFacts(path))

        guard let reply = pdReply(world, file: path, passage: chunk.id, query: pdSwapQuery) else { return }
        #expect(reply.status == .changed, "status is \(reply.status), expected changed")
        #expect(reply.size == Int(now.size), "size is \(String(describing: reply.size)), stat says \(now.size) (the current size)")
        #expect(reply.mtime == Int(now.mtimeNs / 1_000_000_000), "mtime is \(String(describing: reply.mtime)) (the current time)")
        let text = try #require(reply.text, "no passage text in a changed document's reply")
        let length = text.utf16.count
        #expect(length >= 400 && length <= 800, "the text is \(length) UTF-16 units, expected about 600 (400 to 800)")
        #expect(text.contains(pdSwapFirst), "the text lacks the marker beside the first occurrence of the query word")
        #expect(!text.contains(pdSwapSecond), "the text holds the second occurrence's marker: the first best match is the first one")
        let pairs = try #require(pdPairs(reply.marks, textLength: length), "the marks \(reply.marks) are not ascending, in-bounds (start, end) pairs")
        #expect(pairs.map { pdSubstring(text, $0) } == [pdSwapQuery], "the marked words are \(pairs.map { pdSubstring(text, $0) }), expected the query word once")
    }

    // MARK: gone

    @Test func aDeletedDocumentIsGoneWithNothingToShow() throws {
        let world = try pdWorldOrStop()
        let path = world.path("gone-deleted.txt")
        let chunk = try #require(world.chunks("gone-deleted.txt").first)
        try FileManager.default.removeItem(atPath: path)

        guard let reply = pdReply(world, file: path, passage: chunk.id, query: "anything") else { return }
        #expect(reply.status == .gone, "status is \(reply.status), expected gone")
        #expect(reply.name == "gone-deleted.txt", "name is \(reply.name)")
        #expect(reply.png == nil && reply.size == nil && reply.mtime == nil, "a gone file keeps a picture, a size or a time")
        #expect(reply.text == nil || reply.text == "", "a gone file keeps passage text: \(String(describing: reply.text))")
        #expect(reply.marks.isEmpty, "a gone file keeps marks: \(reply.marks)")
        #expect(reply.page == nil && reply.pageCount == nil && reply.locator == nil, "a gone file keeps a page or a locator")
    }

    @Test func aDocumentMovedIntoACachesFolderIsGoneAtItsNewPathAndAtItsOldOne() throws {
        let world = try pdWorldOrStop()
        let old = world.path("gone-moved.txt")
        let chunk = try #require(world.chunks("gone-moved.txt").first)
        let caches = world.folder + "/Caches"
        try FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let moved = caches + "/gone-moved.txt"
        try FileManager.default.moveItem(atPath: old, toPath: moved)
        #expect(FileManager.default.fileExists(atPath: moved), "the test's moved file is not on disk")

        for (label, file) in [("its new path inside Caches", moved), ("its old path", old)] {
            guard let reply = pdReply(world, file: file, passage: chunk.id, query: "anything") else { continue }
            #expect(reply.status == .gone, "\(label): status is \(reply.status), expected gone")
            #expect(reply.text == nil || reply.text == "", "\(label): a gone file keeps passage text")
            #expect(reply.marks.isEmpty, "\(label): a gone file keeps marks")
        }
    }

    // MARK: no chunk

    @Test func aDocumentWithNoChunkIsOkWithOnlyItsName() throws {
        let world = try pdWorldOrStop()
        #expect(world.chunks("empty.txt").isEmpty, "setup: the empty file holds a chunk passage")
        let name = try #require(world.namePassage("empty.txt"), "the index holds no name passage for empty.txt")

        guard let reply = pdReply(world, file: world.path("empty.txt"), passage: name, query: "empty") else { return }
        #expect(reply.status == .ok, "status is \(reply.status), expected ok")
        #expect(reply.name == "empty.txt", "name is \(reply.name)")
        #expect(reply.kind == "doc", "kind is \(reply.kind)")
        #expect(reply.size == 0, "size is \(String(describing: reply.size)), the file holds no byte")
        #expect(reply.text == nil || reply.text == "", "a document with no chunk shows text: \(String(describing: reply.text))")
        #expect(reply.marks.isEmpty, "a document with no chunk has marks: \(reply.marks)")
    }

    // MARK: the protocol lines (the entry puts these two in ProtocolTests, which is not in this task's touch list)

    @Test func aPhotoReplyLineCarriesNoneOfTheNewFieldsAndIsTheLineItWasBefore() throws {
        let png = "/var/folders/ab/cdef/T/Sesame-4242/p1.png"
        let ok = PreviewReply(ticket: 12, status: .ok, png: png, name: "beach-dog.jpg", kind: "photo", size: 48213, mtime: 1_760_000_000)
        let line = try HelperProtocol.line(for: .preview(ok))
        let object = try pdParsed(line)
        #expect(Set(object.keys) == ["event", "ticket", "status", "png", "name", "kind", "size", "mtime"],
                "a photo line holds the keys \(object.keys.sorted()), exactly the eight it held before")
        #expect(object["event"] as? String == "preview")
        #expect((object["ticket"] as? NSNumber)?.intValue == 12)
        #expect(object["status"] as? String == "ok")
        #expect(object["png"] as? String == png)
        #expect(object["name"] as? String == "beach-dog.jpg")
        #expect(object["kind"] as? String == "photo")
        #expect((object["size"] as? NSNumber)?.intValue == 48213)
        #expect((object["mtime"] as? NSNumber)?.intValue == 1_760_000_000)
        for key in pdNewKeys { #expect(!line.contains("\"\(key)\""), "a photo line holds the key \(key): \(line)") }

        // A gone photo keeps its three nulls, and still no new key.
        let gone = PreviewReply(ticket: 15, status: .gone, png: nil, name: "beach-dog.jpg", kind: "photo", size: nil, mtime: nil)
        let goneLine = try HelperProtocol.line(for: .preview(gone))
        let goneObject = try pdParsed(goneLine)
        #expect(Set(goneObject.keys) == ["event", "ticket", "status", "png", "name", "kind", "size", "mtime"],
                "a gone photo line holds the keys \(goneObject.keys.sorted())")
        #expect(goneObject["png"] is NSNull && goneObject["size"] is NSNull && goneObject["mtime"] is NSNull)
        for key in pdNewKeys { #expect(!goneLine.contains("\"\(key)\""), "a gone photo line holds the key \(key): \(goneLine)") }

        // A line written before the new fields existed still decodes, to a reply with none of them.
        let old = #"{"event":"preview","ticket":12,"status":"ok","png":""# + png + #"","name":"beach-dog.jpg","kind":"photo","size":48213,"mtime":1760000000}"#
        #expect(try HelperProtocol.event(from: old) == .preview(ok))
        let decoded = try HelperProtocol.event(from: old)
        if case .preview(let reply) = decoded {
            #expect(reply.page == nil && reply.pageCount == nil && reply.locator == nil && reply.text == nil && reply.marks.isEmpty,
                    "an old line decodes with new fields set: \(reply)")
        } else {
            Issue.record("an old preview line did not decode as a preview event")
        }
    }

    @Test func aPdfReplyAndADocumentReplyKeepTheirNewFieldsThroughTheEncoderAndTheDecoder() throws {
        let png = "/var/folders/ab/cdef/T/Sesame-4242/p2.png"
        let pdf = PreviewReply(ticket: 21, status: .ok, png: png, name: "lease-2024.pdf", kind: "pdf", size: 48213, mtime: 1_760_000_000,
                               page: 7, pageCount: 12, locator: "Page 7 of 12")
        let pdfLine = try HelperProtocol.line(for: .preview(pdf))
        let pdfObject = try pdParsed(pdfLine)
        #expect((pdfObject[pdKeys.page] as? NSNumber)?.intValue == 7, "page is \(String(describing: pdfObject[pdKeys.page]))")
        #expect((pdfObject[pdKeys.pageCount] as? NSNumber)?.intValue == 12, "pageCount is \(String(describing: pdfObject[pdKeys.pageCount]))")
        #expect(pdfObject[pdKeys.locator] as? String == "Page 7 of 12", "locator is \(String(describing: pdfObject[pdKeys.locator]))")
        #expect(pdfObject[pdKeys.text] == nil && pdfObject[pdKeys.marks] == nil, "a PDF line holds text or marks, which are encoded only when set: \(pdfLine)")
        #expect(try HelperProtocol.event(from: pdfLine) == .preview(pdf), "the PDF reply does not survive the encoder and the decoder")

        let text = "He said \"hello\"\nthen café 犬 left, and 😀 too"
        let document = PreviewReply(ticket: 22, status: .changed, png: nil, name: "tenancy.docx", kind: "doc", size: 9_001, mtime: 1_760_000_500,
                                    text: text, marks: [3, 7, 20, 24])
        let documentLine = try HelperProtocol.line(for: .preview(document))
        #expect(!documentLine.contains("\n"), "a line must not hold a newline: \(documentLine)")
        let documentObject = try pdParsed(documentLine)
        #expect(documentObject[pdKeys.text] as? String == text, "text is \(String(describing: documentObject[pdKeys.text]))")
        let marks = try #require(documentObject[pdKeys.marks] as? [NSNumber], "marks is \(String(describing: documentObject[pdKeys.marks])), expected an array of numbers")
        #expect(marks.map { $0.intValue } == [3, 7, 20, 24], "marks are \(marks)")
        #expect(documentObject[pdKeys.page] == nil && documentObject[pdKeys.pageCount] == nil && documentObject[pdKeys.locator] == nil,
                "a document line holds a page or a locator, which are encoded only when set: \(documentLine)")
        #expect(try HelperProtocol.event(from: documentLine) == .preview(document), "the document reply does not survive the encoder and the decoder")

        // A line written by hand, with the keys the entry names, decodes to the same reply.
        let byHand = #"{"event":"preview","ticket":21,"status":"ok","png":""# + png
            + #"","name":"lease-2024.pdf","kind":"pdf","size":48213,"mtime":1760000000,"page":7,"pageCount":12,"locator":"Page 7 of 12"}"#
        #expect(try HelperProtocol.event(from: byHand) == .preview(pdf), "a hand-written PDF line does not decode to the PDF reply")
    }
}
}
