import Foundation
import Testing
import SesameEngine

// plan-1-t23: FakeEmbedder (the Embedder protocol), Search and the Visible predicate.
//
// Every expected value comes from this file. The index is filled with hand-picked vectors
// built on the first basis vector: the query is e0 = (1, 0, 0, ...), a stored vector is
// a*e0 + sqrt(1-a^2)*e_k, so its dot product with the query is exactly `a`. The tests compute
// the dot products themselves (`dot`) and sort by them; nothing is asked of the code under test.
//
// Contract these tests pin (names are the design's, signatures are this file's pick):
//   protocol Embedder { func embed(_ text: String, role: EmbedRole) throws -> [Float] }   // EmbedRole: .query, .document
//   struct FakeEmbedder: Embedder { init() }
//   struct Visible { init(folders: [Settings.Folder], codeSearchOn: Bool, kindsOn: [String: Bool]);
//                    func allows(path: String, kind: String) -> Bool }
//   final class Search { init(reader: IndexReader);
//                        func newTicket() -> Int;
//                        func rank(text: String, vector: [Float], ticket: Int, visible: Visible) -> [hit]?
//                        var matrixLoaded: Bool { get };  func release() }
//   hit has `path: String` and `passageID: Int64`. rank returns nil for a ticket that is not the newest.
// Search never embeds: the caller passes the query vector (the pipeline of t36 embeds).

// MARK: small maths done here

private func dot(_ a: [Float], _ b: [Float]) -> Double {
    var sum = 0.0
    for index in 0..<min(a.count, b.count) { sum += Double(a[index]) * Double(b[index]) }
    return sum
}

private func norm(_ a: [Float]) -> Double { dot(a, a).squareRoot() }

private let dimension = 768

// e0, the query vector of every Search test
private let query: [Float] = (0..<dimension).map { $0 == 0 ? 1 : 0 }

// A vector whose dot product with `query` is `a`, the rest of its length on coordinate `k` (k >= 1).
private func vector(dot a: Float, noise k: Int) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[0] = a
    v[k] = (1 - a * a).squareRoot()
    return v
}

private let description = "a quiet harbour at dawn"   // several tokens, no stored word matches it
private let loneToken = "zebrafish"                    // one token, no stored word matches it

// MARK: settings data built by hand

private func folder(_ path: String, code: Bool = false) -> Settings.Folder {
    Settings.Folder(path: path, code: code, reading: true)
}

private let allKinds: [String: Bool] = [
    "photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true,
]

private func kinds(except off: String...) -> [String: Bool] {
    var result = allKinds
    for kind in off { result[kind] = false }
    return result
}

private func visible(_ folders: [Settings.Folder], kindsOn: [String: Bool] = allKinds) -> Visible {
    Visible(folders: folders, codeSearchOn: true, kindsOn: kindsOn)
}

private let everythingUnderPhotos = visible([folder("/photos")])

// MARK: the rows the tests write

private struct Row {
    let path: String
    let kind: String
    let dot: Double          // the file's best dot product with the query
    let bestPassage: Int64   // the passage that has it
}

private struct Written {
    var rows: [Row] = []
    var inode: Int64 = 100

    func dotByPath() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0.dot) })
    }
}

// One file with a `name` passage (words only) and the given vectored passages, in the given order.
// Each passage is (source, modality, dot, noise coordinate).
private func add(_ written: inout Written, _ store: IndexStore, path: String, kind: String,
                 name: String, passages: [(source: String, modality: String, dot: Float, noise: Int)]) throws {
    written.inode += 1
    let file = try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                 inode: written.inode, device: 16_777_220, status: "done")
    _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                             vector: nil, name: name, body: "")
    var best: (dot: Float, id: Int64)?
    for passage in passages {
        let id = try store.addPassage(fileID: file, source: passage.source, start: 0, end: 0,
                                      modality: passage.modality,
                                      vector: vector(dot: passage.dot, noise: passage.noise),
                                      name: "", body: "")
        if best == nil || passage.dot > best!.dot { best = (passage.dot, id) }
    }
    let top = try #require(best)
    written.rows.append(Row(path: path, kind: kind, dot: Double(top.dot), bestPassage: top.id))
}

// 5 graded files over 100 noise files (image modality). Only the 5 stand out: with the
// noise at dot 0 the 5 have z-scores above 3 in the image population, the noise about -0.2.
//   g1 photo /photos/a  .95 (its other passage, inserted after it, is .30)
//   g2 pdf   /photos/b  .85
//   g3 photo /photos/a  .75 (its .20 passage is inserted BEFORE the .75 one)
//   g4 pdf   /photos/b  .65
//   g5 photo /photos/a  .55
// noise: 100 pdf files under /photos/b, each at dot 0.
private let gradedOrder = ["/photos/a/g1.jpg", "/photos/b/g2.pdf", "/photos/a/g3.jpg",
                           "/photos/b/g4.pdf", "/photos/a/g5.jpg"]

private func fillGraded(_ store: IndexStore, into written: inout Written) throws {
    try add(&written, store, path: "/photos/a/g1.jpg", kind: "photo", name: "harbour boats morning",
            passages: [("image", "image", 0.95, 101), ("image", "image", 0.30, 102)])
    try add(&written, store, path: "/photos/b/g2.pdf", kind: "pdf", name: "ledger summary",
            passages: [("page", "image", 0.85, 103)])
    try add(&written, store, path: "/photos/a/g3.jpg", kind: "photo", name: "market crowd",
            passages: [("image", "image", 0.20, 104), ("image", "image", 0.75, 105)])
    try add(&written, store, path: "/photos/b/g4.pdf", kind: "pdf", name: "tenancy terms",
            passages: [("page", "image", 0.65, 106)])
    try add(&written, store, path: "/photos/a/g5.jpg", kind: "photo", name: "mountain ridge",
            passages: [("image", "image", 0.55, 107)])
    for k in 1...100 {
        try add(&written, store, path: String(format: "/photos/b/n%03d.pdf", k), kind: "pdf",
                name: String(format: "scan%03d", k), passages: [("page", "image", 0, k)])
    }
}

// 40 files whose dots are evenly spaced from 0.1000 to 0.1975: nothing stands out (the largest
// z-score of an evenly spaced population is about 1.7, below the gate of 2).
private func flatPath(_ i: Int) -> String { String(format: "/photos/flat/f%02d.jpg", i) }

private func fillFlat(_ store: IndexStore, into written: inout Written) throws {
    for i in 0..<40 {
        try add(&written, store, path: flatPath(i), kind: "photo", name: String(format: "frame%02d", i),
                passages: [("image", "image", 0.10 + 0.0025 * Float(i), i + 1)])
    }
}

private func flatTopFive() -> [String] { (35...39).reversed().map(flatPath) }

// 40 text-modality files at dots .5000 to .5975: evenly spaced, so none stands out in its own
// modality, although every one is above the raw dot of g5 (.55) or close to it.
private func fillText(_ store: IndexStore, into written: inout Written) throws {
    for i in 0..<40 {
        try add(&written, store, path: String(format: "/photos/docs/t%02d.txt", i), kind: "doc",
                name: String(format: "note%02d", i),
                passages: [("chunk", "text", 0.5 + 0.0025 * Float(i), 200 + i)])
    }
}

private struct Found: Equatable {
    let path: String
    let passageID: Int64
}

// Fills a temp index through the one writer, closes it, and hands the test a Search over a reader.
private func withSearch(_ fill: (IndexStore, inout Written) throws -> Void,
                        _ body: (Search, Written) throws -> Void) throws {
    try withTempHome { t in
        guard try createFolder(t) else { return }
        var written = Written()
        let store = try IndexStore()
        try fill(store, &written)
        store.close()
        let reader = IndexReader()
        defer { reader.close() }
        try body(Search(reader: reader), written)
    }
}

// A fresh ticket, then the ranked list for it.
private func rankedNow(_ search: Search, _ text: String, _ filter: Visible = everythingUnderPhotos,
                       vector queryVector: [Float] = query) throws -> [Found] {
    let ticket = search.newTicket()
    let hits = try #require(search.rank(text: text, vector: queryVector, ticket: ticket, visible: filter),
                            "the newest ticket must get a list")
    return hits.map { Found(path: $0.path, passageID: $0.passageID) }
}

private func gradedExpected(_ written: Written) -> [Found] {
    gradedOrder.map { path in
        let row = written.rows.first { $0.path == path }!
        return Found(path: path, passageID: row.bestPassage)
    }
}

// MARK: FakeEmbedder

@Suite("SearchTests")
struct SearchTests {

    @Test func fakeEmbedderGivesA768NumberUnitVectorThroughTheEmbedderProtocol() throws {
        let embedder: any Embedder = FakeEmbedder()
        let texts = ["a dog on the beach", "INV-2026-04417", "x", "the clause about pets in the lease",
                     "code: retry a failed call with backoff", String(repeating: "long ", count: 200)]
        for text in texts {
            for role in [EmbedRole.query, EmbedRole.document] {
                let v = try embedder.embed(text, role: role)
                #expect(v.count == 768, "\(text.prefix(20)): \(v.count) numbers")
                #expect(abs(norm(v) - 1) < 1e-5, "\(text.prefix(20)): norm \(norm(v))")
                #expect(v.allSatisfy { $0.isFinite })
            }
        }
    }

    @Test func fakeEmbedderGivesTheSameVectorForTheSameInput() throws {
        let embedder = FakeEmbedder()
        let first = try embedder.embed("a dog on the beach", role: .query)
        let second = try embedder.embed("a dog on the beach", role: .query)
        #expect(first == second)
        // a separate instance agrees too: the vector is a function of the text
        let third = try FakeEmbedder().embed("a dog on the beach", role: .query)
        #expect(first == third)
    }

    @Test func fakeEmbedderGivesDifferentVectorsForDifferentInputs() throws {
        let embedder = FakeEmbedder()
        let texts = ["a dog on the beach", "a dog on the beach.", "INV-2026-04417", "INV-2026-04418",
                     "the clause about pets in the lease", "x", "y"]
        let vectors = try texts.map { try embedder.embed($0, role: .query) }
        for i in vectors.indices {
            for j in vectors.indices where j > i {
                #expect(vectors[i] != vectors[j], "\"\(texts[i])\" and \"\(texts[j])\" gave the same vector")
            }
        }
    }

    // MARK: Search: ranking, gate, best passage

    @Test func theTargetFileRanksFirstAndTheOrderEqualsTheDotProductOrder() throws {
        try withSearch({ store, written in try fillGraded(store, into: &written) }) { search, written in
            let found = try rankedNow(search, description)
            #expect(found.first?.path == "/photos/a/g1.jpg", "first is \(String(describing: found.first))")
            #expect(found.map(\.path) == gradedOrder, "got \(found.map(\.path))")

            // the whole list, whatever its length, is in non-increasing dot order, one row per file
            let dots = written.dotByPath()
            let listed = found.map { dots[$0.path] ?? -1 }
            #expect(listed == listed.sorted(by: >), "dots \(listed)")
            #expect(Set(found.map(\.path)).count == found.count, "a file is listed twice")
        }
    }

    @Test func perFileTheBestPassageIdIsReturned() throws {
        try withSearch({ store, written in try fillGraded(store, into: &written) }) { search, written in
            let found = try rankedNow(search, description)
            #expect(found == gradedExpected(written))
            // g1's best passage was inserted first, g3's last: neither "first" nor "last" is the rule
            let g1 = try #require(written.rows.first { $0.path == "/photos/a/g1.jpg" })
            let g3 = try #require(written.rows.first { $0.path == "/photos/a/g3.jpg" })
            #expect(found.first { $0.path == g1.path }?.passageID == g1.bestPassage)
            #expect(found.first { $0.path == g3.path }?.passageID == g3.bestPassage)
        }
    }

    @Test func aDescriptionThatNoRowMatchesReturnsNoRows() throws {
        try withSearch({ store, written in try fillFlat(store, into: &written) }) { search, _ in
            let found = try rankedNow(search, description)
            #expect(found.isEmpty, "expected no rows, got \(found.map(\.path))")
        }
    }

    @Test func aLoneTokenWithNoMatchRelaxesTheGateToTheTopFive() throws {
        try withSearch({ store, written in try fillFlat(store, into: &written) }) { search, written in
            let found = try rankedNow(search, loneToken)
            #expect(found.map(\.path) == flatTopFive(), "got \(found.map(\.path))")
            // the same population, asked as a description, keeps the gate
            #expect(try rankedNow(search, description).isEmpty)
            // and each row carries its file's best passage
            for hit in found {
                let row = try #require(written.rows.first { $0.path == hit.path })
                #expect(hit.passageID == row.bestPassage)
            }
        }
    }

    @Test func theZScoreGateIsPerModality() throws {
        try withSearch({ store, written in
            try fillGraded(store, into: &written)
            try fillText(store, into: &written)
        }) { search, _ in
            let found = try rankedNow(search, description)
            // the 5 image hits stand out among the image rows; no text row stands out among
            // the text rows, however high its raw dot is
            #expect(found.map(\.path) == gradedOrder, "got \(found.map(\.path))")
        }
    }

    // MARK: Search: tickets

    @Test func aResultForAStaleTicketNeverReturns() throws {
        try withSearch({ store, written in try fillGraded(store, into: &written) }) { search, _ in
            let older = search.newTicket()
            let newer = search.newTicket()
            #expect(older != newer)
            #expect(search.rank(text: description, vector: query, ticket: older,
                                visible: everythingUnderPhotos) == nil,
                    "a list came back for a ticket that is no longer the newest")
            let current = try #require(search.rank(text: description, vector: query, ticket: newer,
                                                   visible: everythingUnderPhotos))
            #expect(current.first?.path == "/photos/a/g1.jpg")
            // still stale after the newer one was served
            #expect(search.rank(text: description, vector: query, ticket: older,
                                visible: everythingUnderPhotos) == nil)
            // a keystroke later makes the newer one stale in turn
            let latest = search.newTicket()
            #expect(search.rank(text: description, vector: query, ticket: newer,
                                visible: everythingUnderPhotos) == nil)
            #expect(search.rank(text: description, vector: query, ticket: latest,
                                visible: everythingUnderPhotos) != nil)
        }
    }

    // MARK: Search: the 500-character clamp

    @Test func textLongerThan500CharactersGivesTheSameResultAsItsFirst500() throws {
        try withSearch({ store, written in try fillFlat(store, into: &written) }) { search, _ in
            // the first 500 characters are one token with no match, so a lone token: top five.
            // Not clamped, "<token> tail" would be a two-token description and return no rows.
            let first500 = String(repeating: "x", count: 500)
            let longer = first500 + " tail"
            #expect(longer.count > 500)
            let clamped = try rankedNow(search, first500)
            #expect(clamped.map(\.path) == flatTopFive(), "the 500 character text gave \(clamped.map(\.path))")
            let long = try rankedNow(search, longer)
            #expect(long == clamped, "the 505 character text gave \(long.map(\.path))")
            let veryLong = try rankedNow(search, first500 + String(repeating: "y", count: 100))
            #expect(veryLong == clamped)
        }
    }

    // MARK: Search: the matrix

    @Test func theFirstSearchLoadsTheMatrixAndReleaseDropsItAndTheNextSearchLoadsItAgain() throws {
        try withSearch({ store, written in try fillGraded(store, into: &written) }) { search, written in
            #expect(search.matrixLoaded == false)
            _ = search.newTicket()
            #expect(search.matrixLoaded == false, "a ticket alone must not load the matrix")

            let first = try rankedNow(search, description)
            #expect(search.matrixLoaded == true)
            #expect(first.map(\.path) == gradedOrder)

            search.release()
            #expect(search.matrixLoaded == false)
            search.release()   // dropping nothing is fine
            #expect(search.matrixLoaded == false)

            let second = try rankedNow(search, description)
            #expect(search.matrixLoaded == true)
            #expect(second == first, "the ranking changed after release")
            #expect(second == gradedExpected(written))
        }
    }

    // MARK: Visible

    private static let folders = [
        folder("/Users/test/Pictures"),
        folder("/Users/test/Developer"),
        folder("/Users/test/Developer/api-client", code: true),
    ]

    @Test func visibleHidesAPathThatIsNotUnderATickedFolder() {
        let v = visible(Self.folders)
        #expect(v.allows(path: "/Users/test/Pictures/trip/a.jpg", kind: "photo"))
        #expect(v.allows(path: "/Users/test/Pictures/a.jpg", kind: "photo"))
        #expect(!v.allows(path: "/Users/test/Documents/b.jpg", kind: "photo"))
        #expect(!v.allows(path: "/Users/test/PicturesOld/c.jpg", kind: "photo"), "a sibling that shares a prefix")
        #expect(!v.allows(path: "/Users/test/Pictures.jpg", kind: "photo"))
        #expect(!v.allows(path: "/elsewhere/Pictures/a.jpg", kind: "photo"))
        // nothing ticked, nothing visible
        let none = visible([])
        #expect(!none.allows(path: "/Users/test/Pictures/a.jpg", kind: "photo"))
        // a photo under a folder that is not ticked for code is fine: only code needs the code tick
        #expect(v.allows(path: "/Users/test/Developer/other/shot.png", kind: "photo"))
    }

    @Test func visibleNeverShowsACodeFileWhateverTheFolderTicks() {
        let v = visible(Self.folders)
        #expect(!v.allows(path: "/Users/test/Developer/api-client/src/main.swift", kind: "code"),
                "a code folder holds it, and code is still hidden")
        #expect(!v.allows(path: "/Users/test/Developer/other/main.swift", kind: "code"))
        #expect(!v.allows(path: "/Users/test/Pictures/script.py", kind: "code"))
        #expect(!v.allows(path: "/Users/test/Developer/api-client-old/main.swift", kind: "code"))
        let ticked = visible([folder("/Users/test/Developer", code: true)])
        #expect(!ticked.allows(path: "/Users/test/Developer/other/main.swift", kind: "code"))
        let unticked = visible([folder("/Users/test/Developer", code: false)])
        #expect(!unticked.allows(path: "/Users/test/Developer/other/main.swift", kind: "code"))
        #expect(ticked.allows(path: "/Users/test/Developer/other/shot.png", kind: "photo"), "control: a photo in the same folder")
    }

    @Test func visibleHidesAKindThatIsSwitchedOff() {
        let path = "/Users/test/Pictures/file"
        let allOn = visible(Self.folders)
        for kind in ["photo", "pdf", "doc", "audio", "video"] {
            #expect(allOn.allows(path: path + "." + kind, kind: kind), "\(kind) is on")
        }
        for off in ["photo", "pdf", "doc", "audio", "video"] {
            let v = visible(Self.folders, kindsOn: kinds(except: off))
            #expect(!v.allows(path: path + "." + off, kind: off), "\(off) is switched off")
            for other in ["photo", "pdf", "doc", "audio", "video"] where other != off {
                #expect(v.allows(path: path + "." + other, kind: other), "\(other) stays on when \(off) is off")
            }
        }
        // code switched off hides code even inside a code folder
        let noCode = visible(Self.folders, kindsOn: kinds(except: "code"))
        #expect(!noCode.allows(path: "/Users/test/Developer/api-client/src/main.swift", kind: "code"))
    }

    // MARK: Visible inside Search

    @Test func searchHidesResultsOutsideTheTickedFoldersAtQueryTime() throws {
        try withSearch({ store, written in try fillGraded(store, into: &written) }) { search, written in
            let all = try rankedNow(search, description)
            #expect(all.map(\.path) == gradedOrder)

            // untick /photos/a: g1, g3 and g5 vanish, g2 and g4 stay in dot order, no new write
            let onlyB = visible([folder("/photos/b")])
            let found = try rankedNow(search, description, onlyB)
            #expect(found.map(\.path) == ["/photos/b/g2.pdf", "/photos/b/g4.pdf"], "got \(found.map(\.path))")
            let expected = gradedExpected(written).filter { $0.path.hasPrefix("/photos/b/") }
            #expect(found == expected)

            // ticked again: they are back
            #expect(try rankedNow(search, description).map(\.path) == gradedOrder)
        }
    }

    @Test func searchHidesAKindThatIsSwitchedOffAtQueryTime() throws {
        try withSearch({ store, written in try fillGraded(store, into: &written) }) { search, _ in
            let noPhotos = visible([folder("/photos")], kindsOn: kinds(except: "photo"))
            let found = try rankedNow(search, description, noPhotos)
            #expect(found.map(\.path) == ["/photos/b/g2.pdf", "/photos/b/g4.pdf"], "got \(found.map(\.path))")
            // switched on again: they are back
            #expect(try rankedNow(search, description).map(\.path) == gradedOrder)
        }
    }
}
