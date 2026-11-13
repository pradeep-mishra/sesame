import Foundation
import Testing
import SesameEngine

// plan-3-t19, tester step: tier 1 (an exact string comes first) and the weights in one file.
// Written from the t19 entry of plan-3-tasks.md, Decision D10, design sections 3 and 9.3, and the existing tests
// (SearchTests, SearchSmallLibraryTests, SearchFloorTests, IndexStoreTests, IndexReconcileDeviceTests) only; no
// product source read.
//
// The index is written through `IndexStore` with hand-picked vectors on the first basis vector: the query is
// e0 = (1, 0, 0, ...), a stored vector is a*e0 + sqrt(1-a^2)*e_k, so its dot product with the query is `a`. The tests
// compute the dot products themselves (`dot`) and sort by them; nothing is asked of the code under test.
//
// NAMES AND SHAPES THESE TESTS PIN (the entry fixes the type and method names; the rest are this file's picks, named
// here so the implementer matches them or asks for a test change):
//   Search.exactHits(text: String, visible: Visible) -> [Hit]     an instance method of `Search`, not throwing (as
//        `rank` does not throw); `Hit` is the type `rank` returns (`path`, `passageID`); one row per file, in tier-1 order.
//   IndexReader.keywordHits(_ text: String) -> [KeywordHit]       not throwing (as `keywordSearch` does not);
//        `KeywordHit` has `passageID: Int64`, `path: String`, `kind: String`; one value per passage that holds the
//        phrase, so a file whose name and whose text both hold it gives two values; it takes no `Visible`, so it lists
//        files of any folder.
//   RankingWeights.gate, .imageFloor, .smallLibraryCount, .relaxedCount, .clamp    static values (gate and floor are
//        numbers with a fraction; the three counts are whole numbers); the tests convert with `Double(...)` and
//        `Int(...)`, so the declared number type does not matter.
//
// THE RULE THESE TESTS PIN (entry t19, D10): a visible file whose `name` passage or whose text (`body`) passage holds
// the whole typed text as one FTS5 phrase is tier 1 and comes first in `rank`, whatever its dot product and whatever
// the gate says; tier-1 files order by score, then by path (the tests pin only the case of equal scores, because
// `exactHits(text:visible:)` has no query vector and the entry does not say what its score is); the file appears once,
// with a passage that holds the phrase; the tier-1 rows of `rank` are `exactHits`' rows (D10: one definition) [AMENDED in
// plan-4 review round 1, fix round, tester step: the same SET of rows first, but `rank` orders them by their best
// passage's dot with the query vector (highest first), then by path, while `exactHits` keeps its path order (the keyword
// list); the old words were "in its order". Reason: with the full text of PDFs and documents in the index, a phrase held by
// many files listed them alphabetically above the semantically best one (reviewer, must-fix 2). The tests below that still
// say "in exactHits' order" hold because their dots and their paths run the same way; the new tests at the end of the
// tier-1 section pin the dot order itself]; the rest of the list is the plan 2 fused ranking, unchanged. The phrase is normalised as FTS5's tokenizer does (case, diacritics,
// punctuation as separators). Text is cut at 500 characters. Typed quotes and operator words are text.
// What these tests do NOT pin, on purpose: the order of a name-only tier-1 hit against a vectored one; what follows the
// tier-1 rows when the typed text is one token (the relaxed top 5 may or may not be added after a tier-1 hit).

private let dimension = 768
private let query: [Float] = (0..<dimension).map { $0 == 0 ? 1 : 0 }

private func vector(dot a: Float, noise k: Int) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[0] = a
    v[k] = (1 - a * a).squareRoot()
    return v
}

private func dot(_ a: [Float], _ b: [Float]) -> Double {
    var sum = 0.0
    for index in 0..<min(a.count, b.count) { sum += Double(a[index]) * Double(b[index]) }
    return sum
}

private let allKinds: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]

private func folder(_ path: String) -> Settings.Folder { Settings.Folder(path: path, code: false, reading: true) }

private func visible(_ folders: [String], kindsOn: [String: Bool] = allKinds) -> Visible {
    Visible(folders: folders.map(folder), codeSearchOn: true, kindsOn: kindsOn)
}

private let everything = visible(["/photos", "/docs", "/other"])

private struct Found: Equatable {
    let path: String
    let passageID: Int64
}

private struct Part {
    let dot: Float
    let body: String
    init(_ dot: Float, _ body: String = "") { self.dot = dot; self.body = body }
}

/// One file: a `name` passage (words only, no vector) and one vectored passage per `Part`, in the order given.
private struct Entry {
    let path: String
    let kind: String
    let name: String?
    let parts: [Part]
    init(_ path: String, kind: String = "photo", name: String? = nil, _ parts: Part...) {
        self.path = path; self.kind = kind; self.name = name; self.parts = parts
    }
}

private struct Library {
    let search: Search
    let reader: IndexReader
    let nameID: [String: Int64]
    let partIDs: [String: [Int64]]
    let vectors: [String: [[Float]]]

    func found(_ path: String, part: Int = 0) -> Found { Found(path: path, passageID: partIDs[path]![part]) }
    func foundName(_ path: String) -> Found { Found(path: path, passageID: nameID[path]!) }
}

private func withLibrary(_ entries: [Entry], _ body: (Library) throws -> Void) throws {
    try withTempHome { t in
        guard try createFolder(t) else { return }
        let store = try IndexStore()
        var nameID: [String: Int64] = [:]
        var partIDs: [String: [Int64]] = [:]
        var vectors: [String: [[Float]]] = [:]
        for (number, entry) in entries.enumerated() {
            let file = try store.addFile(path: entry.path, kind: entry.kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                         inode: Int64(100 + number), device: 16_777_220, status: "done")
            nameID[entry.path] = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                                                      vector: nil, name: entry.name ?? "file\(number)", body: "")
            for (index, part) in entry.parts.enumerated() {
                let v = vector(dot: part.dot, noise: 1 + (number * 3 + index) % 700)
                let id = try store.addPassage(fileID: file, source: entry.kind == "photo" ? "image" : "page", start: 0, end: 0,
                                              modality: "image", vector: v, name: "", body: part.body)
                partIDs[entry.path, default: []].append(id)
                vectors[entry.path, default: []].append(v)
            }
        }
        store.close()
        let reader = IndexReader()
        defer { reader.close() }
        try body(Library(search: Search(reader: reader), reader: reader, nameID: nameID, partIDs: partIDs, vectors: vectors))
    }
}

private func exact(_ lib: Library, _ text: String, _ filter: Visible = everything) -> [Found] {
    lib.search.exactHits(text: text, visible: filter).map { Found(path: $0.path, passageID: $0.passageID) }
}

private func ranked(_ lib: Library, _ text: String, _ filter: Visible = everything) throws -> [Found] {
    let ticket = lib.search.newTicket()
    let hits = try #require(lib.search.rank(text: text, vector: query, ticket: ticket, visible: filter),
                            "the newest ticket must get a list")
    return hits.map { Found(path: $0.path, passageID: $0.passageID) }
}

private func keywordPaths(_ reader: IndexReader, _ text: String) -> [String] {
    reader.keywordHits(text).map { $0.path }
}

/// `count` flat image files at `dot`, paths /photos/flat00.jpg ...
private func flat(_ count: Int, dot: Float = 0.2) -> [Entry] {
    (0..<count).map { Entry(String(format: "/photos/flat%02d.jpg", $0), Part(dot)) }
}

@Suite("SearchExactTierTests")
struct SearchExactTierTests {

    // MARK: exactHits: what counts as "the whole text as one phrase"

    @Test func aNameHoldingTheWholeTextIsFoundWhateverTheCaseAndThePunctuation() throws {
        let entries = [
            Entry("/photos/a.png", name: "ERR_CONNECTION_RESET", Part(0.1)),
            Entry("/photos/b.png", name: "connection reset by peer", Part(0.1)),
            Entry("/photos/c.png", name: "reset err connection", Part(0.1)),
        ]
        try withLibrary(entries) { lib in
            for typed in ["err_connection_reset", "ERR_CONNECTION_RESET", "Err Connection Reset", "err-connection-reset",
                          "  err_connection_reset  ", "err connection reset"] {
                #expect(exact(lib, typed) == [lib.foundName("/photos/a.png")], "typed \"\(typed)\": got \(exact(lib, typed))")
            }
            // the same words in another order are another phrase: c's name is "reset err connection"
            #expect(exact(lib, "reset err connection").map(\.path) == ["/photos/c.png"])
            #expect(exact(lib, "reset connection err").isEmpty)
            #expect(exact(lib, "connection reset").map(\.path).sorted() == ["/photos/a.png", "/photos/b.png"])
        }
    }

    @Test func aScreenshotTextHoldsTheWholeTextAsAPhraseAndItsPassageIsTheOneThatHoldsIt() throws {
        let entries = [
            Entry("/photos/shot.png", name: "Screenshot 2026-03-11", Part(0.1, "Error code ERR_CONNECTION_RESET while loading")),
            Entry("/photos/other.png", name: "Screenshot 2026-03-12", Part(0.1, "Error code ERR_NAME_NOT_RESOLVED while loading")),
        ]
        try withLibrary(entries) { lib in
            #expect(exact(lib, "err_connection_reset") == [lib.found("/photos/shot.png")])
            #expect(exact(lib, "ERR_CONNECTION_RESET") == [lib.found("/photos/shot.png")])
            #expect(exact(lib, "error code err_connection_reset while") == [lib.found("/photos/shot.png")])
        }
    }

    @Test func anInvoiceNumberTypedWholeIsOnePhraseOfItsParts() throws {
        let entries = [
            Entry("/photos/target.png", Part(0.1, "Invoice INV-2026-04417 total 120.00")),
            Entry("/photos/next.png", Part(0.1, "Invoice INV-2026-04418 total 120.00")),
            Entry("/photos/reversed.png", Part(0.1, "04417 2026 INV")),
            Entry("/photos/apart.png", Part(0.1, "INV 2026 then 04417")),
            Entry("/photos/prefix.png", Part(0.1, "INV-2026 only")),
        ]
        try withLibrary(entries) { lib in
            #expect(exact(lib, "INV-2026-04417") == [lib.found("/photos/target.png")], "got \(exact(lib, "INV-2026-04417"))")
            #expect(exact(lib, "inv-2026-04417") == [lib.found("/photos/target.png")])
            #expect(exact(lib, "INV-2026-99999").isEmpty)
        }
    }

    @Test func diacriticsAreFoldedInTheTextAndInTheStoredWords() throws {
        let entries = [
            Entry("/photos/accent.png", Part(0.1, "Café au lait on the terrace")),
            Entry("/photos/plain.png", Part(0.1, "cafe au lait at home")),
            Entry("/photos/tea.png", Part(0.1, "tea au lait")),
        ]
        try withLibrary(entries) { lib in
            for typed in ["cafe au lait", "CAFÉ AU LAIT", "café au lait"] {
                #expect(Set(exact(lib, typed).map(\.path)) == ["/photos/accent.png", "/photos/plain.png"], "typed \"\(typed)\": \(exact(lib, typed))")
            }
        }
    }

    @Test func theWordsMustBeNextToEachOtherInTheTypedOrder() throws {
        let entries = [
            Entry("/photos/yes1.png", Part(0.1, "red pier lights at dusk")),
            Entry("/photos/yes2.png", Part(0.1, "the pier, lights and boats")),
            Entry("/photos/and.png", Part(0.1, "pier and lights")),
            Entry("/photos/reversed.png", Part(0.1, "lights pier")),
            Entry("/photos/apart.png", Part(0.1, "pier with many lights")),
            Entry("/photos/one.png", Part(0.1, "a quiet pier")),
        ]
        try withLibrary(entries) { lib in
            #expect(Set(exact(lib, "pier lights").map(\.path)) == ["/photos/yes1.png", "/photos/yes2.png"],
                    "got \(exact(lib, "pier lights"))")
        }
    }

    @Test func thePhraseMustSitInOnePassageNotAcrossTheNameAndTheText() throws {
        let entries = [
            Entry("/photos/split.png", name: "ERR CONNECTION", Part(0.1, "RESET")),
            Entry("/photos/whole.png", name: "ERR CONNECTION RESET", Part(0.1)),
        ]
        try withLibrary(entries) { lib in
            #expect(exact(lib, "err connection reset").map(\.path) == ["/photos/whole.png"])
        }
    }

    // MARK: exactHits: one row per file, its tier-1 passage

    @Test func aFileAppearsOnceAndItsTierOnePassageIsNotItsHighestDotPassage() throws {
        let entries = [
            // P1 has the highest dot and no phrase; the phrase is in P2 (dot 0.1) and in the name
            Entry("/photos/f.png", name: "amber lantern", Part(0.9, "unrelated words"), Part(0.1, "the amber lantern")),
            // two passages hold the phrase: the file is listed once, with one of them (which one is not pinned:
            // exactHits has no query vector, so "best" cannot mean the dot product there)
            Entry("/photos/g.png", name: "plain", Part(0.3, "an amber lantern"), Part(0.6, "amber lantern again")),
        ]
        try withLibrary(entries) { lib in
            let hits = exact(lib, "amber lantern")
            #expect(hits.count == 2 && Set(hits.map(\.path)).count == 2, "a file is listed twice: \(hits)")
            let f = try #require(hits.first { $0.path == "/photos/f.png" })
            let allowed = [lib.partIDs["/photos/f.png"]![1], lib.nameID["/photos/f.png"]!]
            #expect(allowed.contains(f.passageID), "f's passage \(f.passageID) is neither the body nor the name that hold the phrase")
            #expect(f.passageID != lib.partIDs["/photos/f.png"]![0], "the highest-dot passage holds no phrase")
            let g = try #require(hits.first { $0.path == "/photos/g.png" })
            #expect(lib.partIDs["/photos/g.png"]!.contains(g.passageID), "g's passage \(g.passageID) is not one of its two phrase passages")
        }
    }

    // Equal scores order by path. The four files hold the same words in the same place and have the same dot product,
    // so every score the entry could mean (the word match, the dot product) is equal; the order is the path order,
    // written by hand. (The direction of a score that differs is not pinned: `exactHits(text:visible:)` has no query
    // vector, so the entry's "score" there is the word match's own, which the entry does not define.)
    @Test func twoTierOneFilesWithTheSameScoreOrderByPath() throws {
        let phrase = "the silver kettle"
        let body = "bought the silver kettle at the fair"
        let entries = [
            Entry("/photos/z.jpg", Part(0.5, body)),
            Entry("/photos/a.jpg", Part(0.5, body)),
            Entry("/photos/q.jpg", Part(0.5, body)),
            Entry("/photos/m.jpg", Part(0.5, body)),
            Entry("/photos/n.jpg", Part(0.3, "a copper kettle")),
        ]
        try withLibrary(entries) { lib in
            let sameDot = Set(["/photos/z.jpg", "/photos/a.jpg", "/photos/q.jpg", "/photos/m.jpg"].map { dot(lib.vectors[$0]![0], query) })
            #expect(sameDot.count == 1, "setup: the four dot products must be equal, got \(sameDot)")
            let expected = ["/photos/a.jpg", "/photos/m.jpg", "/photos/q.jpg", "/photos/z.jpg"].map { lib.found($0) }
            let listed = exact(lib, phrase)
            #expect(listed == expected, "got \(listed.map(\.path))")
            let rankedList = try ranked(lib, phrase)
            #expect(rankedList == expected, "rank: got \(rankedList.map(\.path))")
        }
    }

    // plan-4 review round 1, fix round, tester step (must-fix 2): `rank` puts the tier-1 rows first and orders them by their
    // best passage's dot with the query vector, highest first, then by path; `exactHits` keeps the path order (the keyword
    // list). 30 files all hold "budget review" in their text, with 30 different dots in a hand-picked scrambled order, and
    // the best dot is on the file whose path sorts LAST. The expected order is the test's own sort of the dots it computed.
    private static let scrambled = [17, 3, 25, 9, 21, 0, 13, 28, 6, 19, 11, 2, 24, 15, 7, 26, 1, 20, 12, 4, 27, 8, 22, 14, 5, 18, 10, 23, 16, 29]

    @Test func theTierOneRowsOfRankAreInDescendingDotOrderAndExactHitsKeepsThePathOrder() throws {
        #expect(Set(Self.scrambled).count == 30 && Self.scrambled.last == 29, "setup: the permutation is not a permutation of 0..<30 ending in 29")
        let phrase = "budget review"
        let body = "notes of the budget review meeting in march"
        let entries = Self.scrambled.enumerated().map { index, step in
            Entry(String(format: "/photos/f%02d.jpg", index), Part(Float(0.30 + 0.02 * Double(step)), body))
        }
        try withLibrary(entries) { lib in
            let paths = entries.map(\.path)                                  // f00 ... f29, the path order
            let dots = Dictionary(uniqueKeysWithValues: paths.map { ($0, dot(lib.vectors[$0]![0], query)) })
            #expect(Set(dots.values).count == 30, "setup: the 30 dot products must differ")
            let byDot = paths.sorted { dots[$0]! != dots[$1]! ? dots[$0]! > dots[$1]! : $0 < $1 }
            #expect(byDot.first == "/photos/f29.jpg" && paths.last == "/photos/f29.jpg", "setup: the best dot is not on the last path: \(byDot.first ?? "")")
            #expect(byDot != paths, "setup: the dot order must differ from the path order")

            let listed = exact(lib, phrase)
            #expect(listed.map(\.path) == paths, "exactHits is the keyword list and keeps the path order: got \(listed.map(\.path))")
            #expect(Set(listed.map(\.path)).count == 30)

            let list = try ranked(lib, phrase)
            #expect(list.prefix(30).map(\.path) == byDot, "rank's tier-1 rows are not in descending dot order: got \(list.prefix(30).map(\.path))")
            #expect(list.first?.path == "/photos/f29.jpg", "the semantically best file is not first: \(list.first?.path ?? "none")")
            #expect(list.prefix(30).map { $0 } == byDot.map { lib.found($0) }, "passages: got \(list.prefix(30))")
            #expect(Set(list.map(\.path)).count == list.count, "a file is listed twice")
        }
    }

    // Equal dots order by path; a file's best passage decides its place (x1 has a poor passage first and its best passage
    // second, and both hold the phrase). Expected, by hand: x1 (0.95), m1 (0.90), a1 and z1 (0.70, by path), b1 and y1 (0.50, by path).
    @Test func tierOneRowsWithEqualDotsOrderByPathAndAFilesBestPassageDecidesItsPlace() throws {
        let body = "the budget review is on friday"
        let entries = [
            Entry("/photos/z1.jpg", Part(0.70, body)),
            Entry("/photos/a1.jpg", Part(0.70, body)),
            Entry("/photos/m1.jpg", Part(0.90, body)),
            Entry("/photos/b1.jpg", Part(0.50, body)),
            Entry("/photos/y1.jpg", Part(0.50, body)),
            Entry("/photos/x1.jpg", Part(0.20, body), Part(0.95, body)),
        ]
        try withLibrary(entries) { lib in
            let list = try ranked(lib, "budget review")
            #expect(list.prefix(6).map(\.path) == ["/photos/x1.jpg", "/photos/m1.jpg", "/photos/a1.jpg", "/photos/z1.jpg", "/photos/b1.jpg", "/photos/y1.jpg"],
                    "got \(list.map(\.path))")
            for path in ["/photos/m1.jpg", "/photos/a1.jpg", "/photos/z1.jpg", "/photos/b1.jpg", "/photos/y1.jpg"] {
                #expect(list.contains(lib.found(path)), "\(path) is not listed with its passage")
            }
            let x1 = list.first { $0.path == "/photos/x1.jpg" }
            #expect(x1.map { lib.partIDs["/photos/x1.jpg"]!.contains($0.passageID) } == true, "x1's passage is not one of its own: \(String(describing: x1))")
            #expect(Set(list.map(\.path)).count == list.count, "a file is listed twice")
        }
    }

    // MARK: exactHits: Visible

    @Test func aTierOneFileThatVisibleHidesIsAbsent() throws {
        let body = "the silver kettle"
        let entries = [
            Entry("/photos/a/x.jpg", Part(0.1, body)),
            Entry("/photos/b/y.jpg", Part(0.1, body)),
            Entry("/other/z.jpg", Part(0.1, body)),
            Entry("/photos/a/d.pdf", kind: "pdf", Part(0.1, body)),
        ]
        try withLibrary(entries) { lib in
            func paths(_ filter: Visible) throws -> (exact: Set<String>, ranked: Set<String>) {
                let rankedList = try ranked(lib, body, filter)
                return (Set(exact(lib, body, filter).map(\.path)), Set(rankedList.map(\.path)))
            }
            let all = try paths(visible(["/photos", "/other"]))
            #expect(all.exact == ["/photos/a/x.jpg", "/photos/b/y.jpg", "/other/z.jpg", "/photos/a/d.pdf"] && all.ranked == all.exact)

            let unticked = try paths(visible(["/photos/a"]))   // /photos/b and /other are not ticked
            #expect(unticked.exact == ["/photos/a/x.jpg", "/photos/a/d.pdf"], "exact: \(unticked.exact)")
            #expect(unticked.ranked == unticked.exact, "rank: \(unticked.ranked)")

            var noPhotos = allKinds; noPhotos["photo"] = false
            let kindOff = try paths(visible(["/photos", "/other"], kindsOn: noPhotos))
            #expect(kindOff.exact == ["/photos/a/d.pdf"], "exact: \(kindOff.exact)")
            #expect(kindOff.ranked == kindOff.exact, "rank: \(kindOff.ranked)")

            let none = try paths(visible([]))
            #expect(none.exact.isEmpty && none.ranked.isEmpty)
        }
    }

    // MARK: rank: tier 1 on top of the fused list

    // 36 flat files at 0.2, three decoys at 0.90, 0.89, 0.88 that pass the gate (z about 3) and the floor, and three
    // tier-1 files with the same words: k1 at 0.91 (it passes the gate itself, so it is in both lists), k2 at 0.1 and
    // k3 at 0.0 (the lowest dot of the library, far under the gate and the floor). The names run k1, k2, k3 in the
    // order of their dots, so the tier's order is the same whether it follows the path or the dot product.
    private static let phrase = "the silver kettle"
    private static let noHit = "a quiet harbour at dawn"
    private static func decoyLibrary() -> [Entry] {
        let hit = "bought the silver kettle at the fair"
        return flat(36) + [
            Entry("/photos/d0.jpg", Part(0.90, "silver kettle the")),
            Entry("/photos/d1.jpg", Part(0.89, "the silver tray")),
            Entry("/photos/d2.jpg", Part(0.88, "a copper kettle")),
            Entry("/photos/k1.jpg", Part(0.91, hit)),
            Entry("/photos/k2.jpg", Part(0.10, hit)),
            Entry("/photos/k3.jpg", Part(0.00, hit)),
        ]
    }

    @Test func anExactStringIsFirstEvenWithTheLowestDotUnderTheGateAndDecoysAboveIt() throws {
        try withLibrary(Self.decoyLibrary()) { lib in
            let list = try ranked(lib, Self.phrase)
            let expected = ["/photos/k1.jpg", "/photos/k2.jpg", "/photos/k3.jpg", "/photos/d0.jpg", "/photos/d1.jpg", "/photos/d2.jpg"]
            #expect(list.map(\.path) == expected, "got \(list.map(\.path))")
            #expect(list == expected.map { lib.found($0) }, "passages: got \(list)")
            #expect(Set(list.map(\.path)).count == list.count, "a file is listed twice: \(list.map(\.path))")
            // the lowest dot of the library is k3's, and k3 is listed (not lost under the gate)
            let lowest = lib.vectors.values.map { dot($0[0], query) }.min() ?? 1
            #expect(dot(lib.vectors["/photos/k3.jpg"]![0], query) == lowest)
            #expect(exact(lib, Self.phrase) == ["/photos/k1.jpg", "/photos/k2.jpg", "/photos/k3.jpg"].map { lib.found($0) })
        }
    }

    @Test func theRestOfTheListIsThePlanTwoFusedRankingUnchanged() throws {
        try withLibrary(Self.decoyLibrary()) { lib in
            // a description no stored word holds: the plan 2 list, by dot order; k1 passes the gate too
            let plain = try ranked(lib, Self.noHit)
            #expect(plain.map(\.path) == ["/photos/k1.jpg", "/photos/d0.jpg", "/photos/d1.jpg", "/photos/d2.jpg"], "got \(plain.map(\.path))")
            #expect(plain == ["/photos/k1.jpg", "/photos/d0.jpg", "/photos/d1.jpg", "/photos/d2.jpg"].map { lib.found($0) })
            // with the exact string typed, what follows the tier is that list without the tier-1 files
            let tier1: Set<String> = ["/photos/k1.jpg", "/photos/k2.jpg", "/photos/k3.jpg"]
            let withPhrase = try ranked(lib, Self.phrase)
            #expect(Array(withPhrase.drop(while: { tier1.contains($0.path) })) == plain.filter { !tier1.contains($0.path) })
        }
    }

    @Test func aNameThatHoldsTheWholeTextIsTierOneToo() throws {
        let entries = flat(36) + [
            Entry("/photos/d0.jpg", Part(0.90)), Entry("/photos/d1.jpg", Part(0.89)), Entry("/photos/d2.jpg", Part(0.88)),
            Entry("/photos/note.jpg", name: "Kettle Invoice Summary", Part(0.0)),
        ]
        try withLibrary(entries) { lib in
            let list = try ranked(lib, "kettle invoice summary")
            #expect(list.first == lib.foundName("/photos/note.jpg"), "got \(list)")
            #expect(list.map(\.path) == ["/photos/note.jpg", "/photos/d0.jpg", "/photos/d1.jpg", "/photos/d2.jpg"], "got \(list.map(\.path))")
        }
    }

    @Test func aTypedNumberIsOneTokenAndItsFileIsFirstEvenBelowTheGate() throws {
        let entries = flat(36) + [
            Entry("/photos/d0.jpg", Part(0.90, "invoice paid")),
            Entry("/photos/inv.jpg", Part(0.0, "Invoice INV-2026-04417 total 120.00")),
        ]
        try withLibrary(entries) { lib in
            let list = try ranked(lib, "INV-2026-04417")
            #expect(list.first == lib.found("/photos/inv.jpg"), "got \(list)")
            #expect(list.filter { $0.path == "/photos/inv.jpg" }.count == 1, "listed twice: \(list)")
        }
    }

    // MARK: rank: what stays as plan 2 had it

    @Test func aLoneTokenWithNoTierOneHitKeepsTheRelaxedTopFiveAndADescriptionKeepsTheGate() throws {
        var entries: [Entry] = []
        for i in 0..<12 {
            entries.append(Entry(String(format: "/photos/flat%02d.jpg", i), Part(Float(0.60 - 0.0025 * Double(i)))))
        }
        try withLibrary(entries) { lib in
            let lone = try ranked(lib, "zebrafish")
            let top5 = (0..<5).map { String(format: "/photos/flat%02d.jpg", $0) }
            #expect(lone == top5.map { lib.found($0) }, "got \(lone.map(\.path))")
            #expect(lone.count == Int(RankingWeights.relaxedCount))
            let description = try ranked(lib, "a quiet harbour at dawn")
            #expect(description.isEmpty, "a description with no hit keeps the gate, got \(description.map(\.path))")
            #expect(exact(lib, "zebrafish").isEmpty && exact(lib, "a quiet harbour at dawn").isEmpty)
        }
    }

    // MARK: typed text is only text

    @Test func quotesAndOperatorWordsAreOnlyText() throws {
        let entries = [
            Entry("/photos/plain.png", Part(0.1, "red pier lights at dusk")),
            Entry("/photos/and.png", Part(0.1, "red pier AND lights at dusk")),
            Entry("/photos/near.png", Part(0.1, "go near pier lights now")),
            Entry("/photos/say.png", Part(0.1, "they say hello to all")),
            Entry("/photos/colon.png", Part(0.1, "the name pier is old")),
        ]
        try withLibrary(entries) { lib in
            // the quotes are not a phrase marker: "pier lights" is plain and near ("near pier lights" holds it too)
            #expect(Set(exact(lib, "\"pier lights\"").map(\.path)) == ["/photos/plain.png", "/photos/near.png"], "quoted: \(exact(lib, "\"pier lights\""))")
            #expect(exact(lib, "pier AND lights").map(\.path) == ["/photos/and.png"], "AND: \(exact(lib, "pier AND lights"))")
            #expect(exact(lib, "NEAR(pier lights").map(\.path) == ["/photos/near.png"], "NEAR(: \(exact(lib, "NEAR(pier lights"))")
            #expect(exact(lib, "say \"hello").map(\.path) == ["/photos/say.png"], "an unbalanced quote: \(exact(lib, "say \"hello"))")
            #expect(exact(lib, "name:pier").map(\.path) == ["/photos/colon.png"], "a column filter is text: \(exact(lib, "name:pier"))")
            // text with no word in it holds no phrase and breaks nothing
            for junk in ["\"", "(", ")", "*", "-", ":", "^", "NEAR(", "OR", "NOT", "{}", "\"\"", "pier OR", "-pier*"] {
                _ = exact(lib, junk)
                _ = try ranked(lib, junk)
                _ = lib.reader.keywordHits(junk)
            }
            for punctuationOnly in ["\"", "(", ")", "*", "-", ":", "^", "{}", "\"\""] {
                #expect(exact(lib, punctuationOnly).isEmpty, "\"\(punctuationOnly)\" has no word: got \(exact(lib, punctuationOnly))")
            }
        }
    }

    @Test func anEmptyTextGivesAnEmptyListAndNothingThrows() throws {
        try withLibrary(flat(40) + [Entry("/photos/t.jpg", Part(0.0, "the silver kettle"))]) { lib in
            for empty in ["", " ", "   ", "\n", "\t \n"] {
                #expect(exact(lib, empty).isEmpty, "exactHits of \(empty.debugDescription)")
                let rankedEmpty = try ranked(lib, empty)
                #expect(rankedEmpty.isEmpty, "rank of \(empty.debugDescription): \(rankedEmpty.map(\.path))")
                #expect(lib.reader.keywordHits(empty).isEmpty, "keywordHits of \(empty.debugDescription)")
            }
        }
    }

    @Test func aTextOfSixHundredCharactersIsCutAtFiveHundred() throws {
        let word = "abcd"
        let first500 = Array(repeating: word, count: 100).joined(separator: " ") + " "
        #expect(first500.count == 500)
        let longText = first500 + String(repeating: "zzzz ", count: 25)
        #expect(longText.count == 625)
        let entries = [
            Entry("/photos/full.png", Part(0.1, Array(repeating: word, count: 100).joined(separator: " "))),
            Entry("/photos/short.png", Part(0.1, Array(repeating: word, count: 99).joined(separator: " "))),
        ]
        try withLibrary(entries + flat(20)) { lib in
            let clamped = exact(lib, first500)
            #expect(clamped == [lib.found("/photos/full.png")], "the 500 character text gave \(clamped.map(\.path))")
            #expect(exact(lib, longText) == clamped, "the 625 character text gave \(exact(lib, longText).map(\.path))")
            let rankedLong = try ranked(lib, longText)
            #expect(rankedLong.first == lib.found("/photos/full.png"), "rank gave \(rankedLong.map(\.path))")
            #expect(Int(RankingWeights.clamp) == 500)
        }
    }

    // MARK: release and a delete

    @Test func afterReleaseAndAStoreDeleteTheRemovedFileIsNotListed() throws {
        let tree = try EtTree()
        defer { tree.remove() }
        let a = try tree.photo("pics/a.jpg")
        let b = try tree.photo("pics/b.jpg")
        let c = try tree.photo("pics/c.jpg")
        let device: Int64 = 16_777_220
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let walked = Walker.scan(root: tree.path("pics"), mode: .read)
            #expect(Set(walked.files.map(\.path)) == [a, b, c], "setup: the walk saw \(walked.files.map(\.path))")
            let dots: [String: Float] = [a: 0.30, b: 0.20, c: 0.10]
            for (number, file) in walked.files.enumerated() {
                let id = try store.addFile(path: file.path, kind: file.kind, size: file.size, mtimeNs: file.mtimeNs,
                                           inode: Int64(file.inode), device: device, status: "done")
                _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                         name: "frame\(number)", body: "")
                _ = try store.addPassage(fileID: id, source: "image", start: 0, end: 0, modality: "image",
                                         vector: vector(dot: dots[file.path]!, noise: 1 + number),
                                         name: "", body: file.path == c ? "plain scene" : "the copper bell")
            }
            let reader = IndexReader()
            defer { reader.close() }
            let search = Search(reader: reader)
            let filter = visible([tree.path("pics")])
            let typed = "the copper bell"

            func exactPaths() -> [String] { search.exactHits(text: typed, visible: filter).map { $0.path } }
            func rankedPaths() throws -> [String] {
                let ticket = search.newTicket()
                return try #require(search.rank(text: typed, vector: query, ticket: ticket, visible: filter)).map(\.path)
            }
            let beforeExact = exactPaths()
            let beforeRanked = try rankedPaths()
            #expect(beforeExact == [a, b], "before: \(beforeExact)")
            #expect(beforeRanked == [a, b], "before, rank: \(beforeRanked)")
            #expect(search.matrixLoaded)

            // the file goes, the walk finds the rest, the store reconciles, the matrix is released
            try FileManager.default.removeItem(atPath: a)
            let again = Walker.scan(root: tree.path("pics"), mode: .read)
            let outcome = try store.reconcile(again.files.map { (file: $0, device: device) }, unreadable: again.unreadable,
                                              vectorSource: "v", walkDoneAt: "t2")
            #expect(outcome.removed == 1, "removed \(outcome.removed)")
            search.release()
            #expect(search.matrixLoaded == false)

            let afterExact = exactPaths()
            let afterRanked = try rankedPaths()
            let afterKeyword = keywordPaths(reader, typed)
            #expect(afterExact == [b], "after, exactHits: \(afterExact)")
            #expect(afterRanked == [b], "after, rank: \(afterRanked)")
            #expect(afterKeyword == [b], "after, keywordHits: \(afterKeyword)")
        }
    }

    // MARK: the weights

    @Test func theRankingWeightsHoldTheFiveNumbersByNameAndTheImageFloorIsStill069() {
        #expect(Double(RankingWeights.gate) == 2.0)
        #expect(abs(Double(RankingWeights.imageFloor) - 0.69) < 1e-6)
        #expect(Int(RankingWeights.smallLibraryCount) == 30)
        #expect(Int(RankingWeights.relaxedCount) == 5)
        #expect(Int(RankingWeights.clamp) == 500)
        #expect(abs(Search.imageFloor - 0.69) < 1e-9)
        #expect(abs(Search.imageFloor - Double(RankingWeights.imageFloor)) < 1e-6)
    }

    // MARK: IndexReader.keywordHits

    private struct Seen: Hashable {
        let passageID: Int64
        let path: String
        let kind: String
    }

    @Test func keywordHitsGiveThePassageThePathAndTheKindOfEveryPassageThatHoldsThePhrase() throws {
        let entries = [
            Entry("/photos/a.png", name: "ERR_CONNECTION_RESET", Part(0.1, "ERR_CONNECTION_RESET seen in the tab")),
            Entry("/docs/b.pdf", kind: "pdf", name: "report", Part(0.1, "err connection reset")),
            Entry("/photos/c.png", name: "browser", Part(0.1, "connection reset by peer")),
            Entry("/elsewhere/d.png", name: "other", Part(0.1, "nothing")),
        ]
        try withLibrary(entries) { lib in
            let expected: Set<Seen> = [
                Seen(passageID: lib.nameID["/photos/a.png"]!, path: "/photos/a.png", kind: "photo"),
                Seen(passageID: lib.partIDs["/photos/a.png"]![0], path: "/photos/a.png", kind: "photo"),
                Seen(passageID: lib.partIDs["/docs/b.pdf"]![0], path: "/docs/b.pdf", kind: "pdf"),
            ]
            for typed in ["err_connection_reset", "ERR CONNECTION RESET", "  err-connection-reset "] {
                let got = Set(lib.reader.keywordHits(typed).map { Seen(passageID: $0.passageID, path: $0.path, kind: $0.kind) })
                #expect(got == expected, "typed \"\(typed)\": got \(got)")
            }
            #expect(lib.reader.keywordHits("err_connection_reset").count == 3, "one value per passage")
            #expect(lib.reader.keywordHits("zebrafish").isEmpty)
            // no Visible here: a file of a folder nobody ticked is listed (Search.exactHits filters)
            let other = lib.reader.keywordHits("nothing").map { Seen(passageID: $0.passageID, path: $0.path, kind: $0.kind) }
            #expect(other == [Seen(passageID: lib.partIDs["/elsewhere/d.png"]![0], path: "/elsewhere/d.png", kind: "photo")], "got \(other)")
        }
    }

    @Test func keywordHitsTakeTypedQuotesAndOperatorsAsText() throws {
        let entries = [
            Entry("/photos/plain.png", Part(0.1, "red pier lights at dusk")),
            Entry("/photos/and.png", Part(0.1, "red pier AND lights at dusk")),
        ]
        try withLibrary(entries) { lib in
            #expect(keywordPaths(lib.reader, "\"pier lights\"") == ["/photos/plain.png"], "quotes are text")
            #expect(keywordPaths(lib.reader, "pier AND lights") == ["/photos/and.png"])
            #expect(lib.reader.keywordHits("NEAR(pier lights").isEmpty)
            #expect(lib.reader.keywordHits("\"").isEmpty && lib.reader.keywordHits("*").isEmpty && lib.reader.keywordHits("").isEmpty)
        }
    }
}

// A real temp tree of photo files, for the delete test (its own copy of the idea in IndexReconcileDeviceTests).
private final class EtTree {
    let base: String
    private var made = 0

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-exacttier-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        base = url.resolvingSymlinksInPath().path
    }

    func path(_ relative: String) -> String { base + "/" + relative }

    @discardableResult
    func photo(_ relative: String) throws -> String {
        made += 1
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: UInt8(truncatingIfNeeded: made), count: 100 + made).write(to: URL(fileURLWithPath: full))
        return full
    }

    func remove() { try? FileManager.default.removeItem(atPath: base) }
}
