import Foundation
import Testing
import SesameEngine

// plan-1-t39: the image-similarity floor of the ranked list (the "No matches" cutoff).
//
// The decision these tests pin (design section 9 item 3, extended; the numbers are the controller's,
// measured on the 40-photo golden index in .ril/evidence/S1/cutoff-measure/):
//   - For a DESCRIPTION (2 or more whitespace-separated tokens) the ranked list drops every
//     image-modality candidate when the best image dot (the query vector against the image
//     passages' vectors) is below the floor 0.69, so the list is empty.
//   - A best dot of exactly 0.69 keeps the usual z >= 2 gated list.
//   - A single token keeps the top-5 relaxation, with no floor.
//   - (Tier-1 exact-phrase hits are not in Search.rank yet: plan 2 scope, see the PLAN 2 note below.)
//   - Text-modality passages get no floor.
//   - The floor is `Search.imageFloor` (a Double, 0.69).
//
// Every expected value comes from that decision and from this file. The query is e0 = (1, 0, 0, ...) and a
// stored vector is a*e0 + sqrt(1-a^2)*e_k, so its dot product with the query is exactly `a`.
//
// One honest limit: the index stores vectors as half floats (fp16), so a stored dot can only be a multiple of
// 1/2048. 0.69 itself is not storable: the two storable values next to it are 1413/2048 = 0.689941 (below the
// floor) and 1414/2048 = 0.690430 (above it). "Exactly 0.69" is therefore tested with the storable value just
// at or above it, and its neighbour just below it must be dropped. The other dots (0.68, 0.70, 0.60 ...) are
// rounded to the nearest storable value, which moves them by less than 0.0003.

private let dimension = 768

private let query: [Float] = (0..<dimension).map { $0 == 0 ? 1 : 0 }

// The nearest storable value to `x` (x in [0.5, 1): spacing 1/2048).
private func storable(_ x: Double) -> Float { Float((x * 2048).rounded() / 2048) }
// The smallest storable value that is >= x, and the largest that is < x.
private func storableAtOrAbove(_ x: Double) -> Float { Float((x * 2048).rounded(.up) / 2048) }
private func storableBelow(_ x: Double) -> Float { Float(((x * 2048).rounded(.up) - 1) / 2048) }

private func vector(dot a: Float, noise k: Int) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[0] = a
    v[k] = (1 - a * a).squareRoot()
    return v
}

private let decidedFloor = 0.69                          // from the decision, not from product code
private let description = "a quiet harbour at dawn"      // 5 tokens, no stored word matches it
private let loneToken = "zebrafish"                      // 1 token, no stored word matches it
private let phrase = "blue ferry timetable"              // 3 tokens, held as a phrase by one file's words

private func folder(_ path: String) -> Settings.Folder {
    Settings.Folder(path: path, code: false, reading: true)
}

private let allKinds: [String: Bool] = [
    "photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true,
]

private let everythingUnderPhotos = Visible(folders: [folder("/photos")], codeSearchOn: true, kindsOn: allKinds)

// MARK: rows the tests write

private struct Spec {
    let source: String
    let modality: String
    let dot: Float
    let noise: Int
    var body: String = ""
}

private struct Row {
    let path: String
    let passageID: Int64
}

private struct Written {
    var rows: [String: Row] = [:]
    var inode: Int64 = 100
}

// One file: a `name` passage (words only) and one vectored passage per spec. Every file here has ONE vectored
// passage, so that passage is the file's best passage.
private func add(_ written: inout Written, _ store: IndexStore, path: String, kind: String, name: String,
                 _ spec: Spec) throws {
    written.inode += 1
    let file = try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                 inode: written.inode, device: 16_777_220, status: "done")
    _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                             vector: nil, name: name, body: "")
    let id = try store.addPassage(fileID: file, source: spec.source, start: 0, end: 0, modality: spec.modality,
                                  vector: vector(dot: spec.dot, noise: spec.noise), name: "", body: spec.body)
    written.rows[path] = Row(path: path, passageID: id)
}

private func image(_ dot: Float, _ noise: Int, body: String = "") -> Spec {
    Spec(source: "image", modality: "image", dot: dot, noise: noise, body: body)
}

private func text(_ dot: Float, _ noise: Int) -> Spec {
    Spec(source: "chunk", modality: "text", dot: dot, noise: noise)
}

private let standoutA = "/photos/a/hit1.jpg"
private let standoutB = "/photos/a/hit2.jpg"

// 40 image passages: 38 noise files at 0.40 and two files that stand out (z about 4.5 and 4.2, so the
// z >= 2 gate keeps exactly those two, the better one first). `best` is the better one's dot, the other is 0.02 less.
private func fillTwoStandouts(_ store: IndexStore, into written: inout Written, best: Float,
                              extraImage: (String, Spec)? = nil) throws {
    try add(&written, store, path: standoutA, kind: "photo", name: "harbour boats morning", image(best, 101))
    try add(&written, store, path: standoutB, kind: "photo", name: "market crowd",
            image(storable(Double(best) - 0.02), 102))
    let noiseCount = extraImage == nil ? 38 : 37
    for k in 1...noiseCount {
        try add(&written, store, path: String(format: "/photos/a/n%02d.jpg", k), kind: "photo",
                name: String(format: "scan%02d", k), image(0.40, k))
    }
    if let (path, spec) = extraImage {
        try add(&written, store, path: path, kind: "photo", name: "ferry", spec)
    }
}

private struct Found: Equatable {
    let path: String
    let passageID: Int64
}

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

private func rankedNow(_ search: Search, _ typed: String) throws -> [Found] {
    let ticket = search.newTicket()
    let hits = try #require(search.rank(text: typed, vector: query, ticket: ticket, visible: everythingUnderPhotos),
                            "the newest ticket must get a list")
    return hits.map { Found(path: $0.path, passageID: $0.passageID) }
}

private func found(_ written: Written, _ paths: [String]) -> [Found] {
    paths.map { Found(path: $0, passageID: written.rows[$0]!.passageID) }
}

@Suite("SearchFloorTests")
struct SearchFloorTests {

    // (1) best image dot 0.68: the z gate alone would keep two rows, the floor leaves none
    @Test func aDescriptionWhoseBestImageDotIsBelowTheFloorGetsNoRows() throws {
        let best = storable(0.68)
        #expect(Double(best) < decidedFloor)
        try withSearch({ store, written in try fillTwoStandouts(store, into: &written, best: best) }) { search, _ in
            let list = try rankedNow(search, description)
            #expect(list.isEmpty, "expected no rows under the floor, got \(list.map(\.path))")
        }
    }

    // (2) best image dot 0.70: the z-gated list as before, best first, each with its passage
    @Test func aDescriptionWhoseBestImageDotIsAboveTheFloorKeepsTheZGatedList() throws {
        let best = storable(0.70)
        #expect(Double(best) > decidedFloor)
        try withSearch({ store, written in try fillTwoStandouts(store, into: &written, best: best) }) { search, written in
            let list = try rankedNow(search, description)
            #expect(list == found(written, [standoutA, standoutB]), "got \(list.map(\.path))")
        }
    }

    // (3) the boundary: the storable value at or just above 0.69 keeps the list, the one just below it drops it
    @Test func aBestImageDotAtTheFloorKeepsTheListAndJustBelowItDropsTheList() throws {
        let atFloor = storableAtOrAbove(decidedFloor)
        #expect(Double(atFloor) >= decidedFloor)
        try withSearch({ store, written in try fillTwoStandouts(store, into: &written, best: atFloor) }) { search, written in
            let list = try rankedNow(search, description)
            #expect(list == found(written, [standoutA, standoutB]), "dot \(atFloor): got \(list.map(\.path))")
        }
        let justBelow = storableBelow(decidedFloor)
        #expect(Double(justBelow) < decidedFloor)
        try withSearch({ store, written in try fillTwoStandouts(store, into: &written, best: justBelow) }) { search, _ in
            let list = try rankedNow(search, description)
            #expect(list.isEmpty, "dot \(justBelow) is below 0.69, got \(list.map(\.path))")
        }
    }

    // (4) one token: the top-5 relaxation stays, with no floor, though every dot is under 0.69
    @Test func aSingleTokenQueryBelowTheFloorStillReturnsTheTopFive() throws {
        var order: [String] = []
        try withSearch({ store, written in
            // 40 files at 0.6000, 0.5975, ... evenly spaced: nothing stands out, the best dot is 0.60
            for i in 0..<40 {
                let path = String(format: "/photos/flat/f%02d.jpg", i)
                order.append(path)
                try add(&written, store, path: path, kind: "photo", name: String(format: "frame%02d", i),
                        image(storable(0.60 - 0.0025 * Double(i)), i + 1))
            }
        }) { search, written in
            let list = try rankedNow(search, loneToken)
            #expect(list == found(written, Array(order.prefix(5))), "got \(list.map(\.path))")
            #expect(list.count == 5)
        }
    }

    // (5)
    // PLAN 2: tier-1 exact phrase hits must survive the floor (decided in plan 1, test not possible until tier-1 is in Search.rank)

    // (6) the named constant
    @Test func theImageFloorIsAConstantOfPointSixNine() {
        let floor: Double = Search.imageFloor
        #expect(floor == 0.69)
    }

    // (7) no floor on text: a high text dot stays while the image passage under the floor goes
    @Test func aTextCandidateIsNotRemovedWhenTheImagePassagesAreUnderTheFloor() throws {
        let textA = "/photos/docs/lease.txt"
        let textB = "/photos/docs/memo.txt"
        try withSearch({ store, written in
            // 40 image passages, best 0.68 (below the floor), two of them stand out among the images
            try fillTwoStandouts(store, into: &written, best: storable(0.68))
            // 40 text passages: 38 at 0.30 and two that stand out among the text at 0.85 and 0.80
            try add(&written, store, path: textA, kind: "doc", name: "lease", text(storable(0.85), 301))
            try add(&written, store, path: textB, kind: "doc", name: "memo", text(storable(0.80), 302))
            for k in 1...38 {
                try add(&written, store, path: String(format: "/photos/docs/t%02d.txt", k), kind: "doc",
                        name: String(format: "note%02d", k), text(0.30, 200 + k))
            }
        }) { search, written in
            let list = try rankedNow(search, description)
            #expect(list == found(written, [textA, textB]), "got \(list.map(\.path))")
        }
    }

    // (8) plan-2-t1: documents never use the image floor, in a library that is in the floor-only range (12 image
    // passages). The images are spread 0.10 ... 0.20 (nothing stands out, best under the floor, so no image rows); the
    // one document passage sits at 0.60, UNDER the image floor 0.69, among 15 text passages at 0.10: its text z is
    // about 3.9 (hand-computed), so it stays. A text row is never dropped by the image floor.
    @Test func aDocumentUnderTheImageFloorIsKeptInASmallImageLibrary() throws {
        let lease = "/photos/docs/lease.txt"
        try withSearch({ store, written in
            for i in 0..<12 {
                try add(&written, store, path: String(format: "/photos/a/i%02d.jpg", i), kind: "photo",
                        name: String(format: "frame%02d", i), image(storable(0.10 + 0.10 * Double(i) / 11), i + 1))
            }
            try add(&written, store, path: lease, kind: "doc", name: "lease", text(storable(0.60), 301))
            for k in 1...15 {
                try add(&written, store, path: String(format: "/photos/docs/t%02d.txt", k), kind: "doc",
                        name: String(format: "note%02d", k), text(storable(0.10), 200 + k))
            }
        }) { search, written in
            let list = try rankedNow(search, "quiet harbour")
            #expect(list == found(written, [lease]), "got \(list.map(\.path))")
        }
    }

    // (9) plan-2-t1: a library with an image that is a real match and a document that stands out: the image
    // (four photos at 0.90 ... 0.87 among 8 flat ones, 12 image passages: floor-only range; today their z is about
    // 1.4 and they are dropped) and the document (0.60, text z about 3.9) both come back, each by its own rule, one
    // row per file; the 8 flat images and the 15 flat text files do not.
    @Test func imagesAboveTheFloorAndADocumentThatStandsOutAreAllKeptInTheFloorOnlyRange() throws {
        let photos = (0..<4).map { "/photos/a/match\($0).jpg" }
        let lease = "/photos/docs/lease.txt"
        try withSearch({ store, written in
            for (i, path) in photos.enumerated() {
                try add(&written, store, path: path, kind: "photo", name: "harbour\(i)",
                        image(storable(0.90 - 0.01 * Double(i)), 101 + i))
            }
            for i in 0..<8 {
                try add(&written, store, path: String(format: "/photos/a/i%02d.jpg", i), kind: "photo",
                        name: String(format: "frame%02d", i), image(storable(0.20), i + 1))
            }
            try add(&written, store, path: lease, kind: "doc", name: "lease", text(storable(0.60), 301))
            for k in 1...15 {
                try add(&written, store, path: String(format: "/photos/docs/t%02d.txt", k), kind: "doc",
                        name: String(format: "note%02d", k), text(storable(0.10), 200 + k))
            }
        }) { search, written in
            let list = try rankedNow(search, "quiet harbour")
            #expect(Set(list.map(\.path)) == Set(photos + [lease]), "got \(list.map(\.path))")
            #expect(list.count == 5, "one row per file, got \(list.map(\.path))")
        }
    }
}
