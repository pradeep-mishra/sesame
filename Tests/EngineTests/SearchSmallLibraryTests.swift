import Foundation
import Testing
import SesameEngine

// plan-1 review round A, tester step: finding F3 (a description finds nothing in a library of a few photos).
// Written from the review report (F3), the brief's acceptance line and design sections 3 and 9.3 only. Product
// source read for names only: Sources/SesameEngine/Search.swift (public names `Search.rank`, `Search.imageFloor`).
//
// The finding: with fewer than 8 image passages the z >= 2 gate cannot pass (the largest possible z for n points is
// (n - 1) / sqrt(n): 1.15 at 3, 1.79 at 5, 2.04 at 6), so a library of 3 or 5 photos answers "No matches" to a
// description even when one passage is the obvious match.
//
// THE RULE THESE TESTS PIN (the brief's suggestion; say so if the controller picks another):
//   When a library holds FEWER THAN 8 image passages, z cannot discriminate, so for a description (2 or more tokens)
//   the image rows kept are those whose dot is at or above `Search.imageFloor` (0.69), one row per file, best first,
//   at most 5 files. With 8 or more image passages the existing z >= 2 gate plus the floor apply, unchanged
//   (SearchTests and SearchFloorTests stay as they are). The count is of IMAGE passages; text passages do not count
//   toward it and keep their own z gate.
// Why this rule: the floor (0.69) is the only absolute evidence of "this picture matches" the engine has; in a
// small library the relative evidence (z) does not exist, so the absolute one must decide alone, and the cap of 5
// is the same list length the single-token relaxation already shows.
//
// Every expected value comes from that rule and from this file. The query is e0 = (1, 0, 0, ...); a stored vector is
// a*e0 + sqrt(1-a^2)*e_k, so its dot with the query is `a` (stored as half floats, so within 0.0003 of `a`).

private let dimension = 768
private let query: [Float] = (0..<dimension).map { $0 == 0 ? 1 : 0 }
private let description = "a quiet harbour at dawn"   // 5 tokens

private func vector(dot a: Float, noise k: Int) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[0] = a
    v[k] = (1 - a * a).squareRoot()
    return v
}

private func storableAtOrAbove(_ x: Double) -> Float { Float((x * 2048).rounded(.up) / 2048) }
private func storableBelow(_ x: Double) -> Float { Float(((x * 2048).rounded(.up) - 1) / 2048) }

private let everything = Visible(
    folders: [Settings.Folder(path: "/photos", code: false, reading: true)], codeSearchOn: true,
    kindsOn: ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true])

private struct Found: Equatable {
    let path: String
    let passageID: Int64
}

/// One file per entry: a `name` passage (words only) and one vectored passage of the given modality and dot.
private struct Entry {
    let path: String
    let modality: String   // "image" or "text"
    let dot: Float
}

private func withLibrary(_ entries: [Entry], _ body: (Search, [String: Int64]) throws -> Void) throws {
    try withTempHome { t in
        guard try createFolder(t) else { return }
        let store = try IndexStore()
        var ids: [String: Int64] = [:]
        for (number, entry) in entries.enumerated() {
            let file = try store.addFile(path: entry.path, kind: entry.modality == "image" ? "photo" : "doc", size: 1000,
                                         mtimeNs: 1_700_000_000_000_000_000, inode: Int64(100 + number),
                                         device: 16_777_220, status: "done")
            _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                     name: "file\(number)", body: "")
            ids[entry.path] = try store.addPassage(
                fileID: file, source: entry.modality == "image" ? "image" : "chunk", start: 0, end: 0,
                modality: entry.modality, vector: vector(dot: entry.dot, noise: 1 + number % 700), name: "", body: "")
        }
        store.close()
        let reader = IndexReader()
        defer { reader.close() }
        try body(Search(reader: reader), ids)
    }
}

private func ranked(_ search: Search, _ typed: String = description) throws -> [Found] {
    let ticket = search.newTicket()
    let hits = try #require(search.rank(text: typed, vector: query, ticket: ticket, visible: everything),
                            "the newest ticket must get a list")
    return hits.map { Found(path: $0.path, passageID: $0.passageID) }
}

/// `count` image passages: one at `best` (path /photos/best.jpg), the others spread over 0.10 ... 0.20.
private func oneStandout(count: Int, best: Float = 0.9) -> [Entry] {
    var entries = [Entry(path: "/photos/best.jpg", modality: "image", dot: best)]
    for i in 0..<(count - 1) {
        let dot = 0.10 + 0.10 * Double(i) / Double(max(count - 2, 1))
        entries.append(Entry(path: String(format: "/photos/rest%02d.jpg", i), modality: "image", dot: Float(dot)))
    }
    return entries
}

@Suite("SearchSmallLibraryTests")
struct SearchSmallLibraryTests {

    // The finding: 3, 5 and 6 image passages, one at 0.9 and the rest 0.10 to 0.20: the best one is returned.
    // (7 is the last size below the pinned limit of 8.)
    @Test(arguments: [3, 5, 6, 7]) func aDescriptionInASmallLibraryReturnsTheOneClearMatch(images: Int) throws {
        try withLibrary(oneStandout(count: images)) { search, ids in
            let list = try ranked(search)
            #expect(list == [Found(path: "/photos/best.jpg", passageID: ids["/photos/best.jpg"]!)],
                    "\(images) image passages, one at 0.9: expected only the best, got \(list.map(\.path))")
        }
    }

    // The boundary of the pinned rule: at 8 image passages the z gate is back and keeps the clear standout (z about
    // 2.65 here). A guard that holds today.
    @Test func atEightImagePassagesTheZGateStillKeepsTheClearMatch() throws {
        try withLibrary(oneStandout(count: 8)) { search, ids in
            let list = try ranked(search)
            #expect(list == [Found(path: "/photos/best.jpg", passageID: ids["/photos/best.jpg"]!)], "got \(list.map(\.path))")
        }
    }

    // The floor still applies in a small library: a best dot of 0.5 gives no rows (a guard; it is empty today for the
    // other reason, the z gate).
    @Test func aSmallLibraryWhoseBestDotIsUnderTheFloorGetsNoRows() throws {
        try withLibrary(oneStandout(count: 3, best: 0.5)) { search, _ in
            let list = try ranked(search)
            #expect(list.isEmpty, "best dot 0.5 is under the floor 0.69, got \(list.map(\.path))")
        }
    }

    // The floor boundary in a small library: the storable value at or just above 0.69 is kept, the one just below is not.
    @Test func inASmallLibraryTheFloorKeepsADotAtItAndDropsOneJustBelowIt() throws {
        let atFloor = storableAtOrAbove(Search.imageFloor)
        #expect(Double(atFloor) >= Search.imageFloor)
        try withLibrary(oneStandout(count: 3, best: atFloor)) { search, ids in
            let list = try ranked(search)
            #expect(list == [Found(path: "/photos/best.jpg", passageID: ids["/photos/best.jpg"]!)],
                    "dot \(atFloor) is at the floor, expected it kept, got \(list.map(\.path))")
        }
        let justBelow = storableBelow(Search.imageFloor)
        #expect(Double(justBelow) < Search.imageFloor)
        try withLibrary(oneStandout(count: 3, best: justBelow)) { search, _ in
            let list = try ranked(search)
            #expect(list.isEmpty, "dot \(justBelow) is below the floor, got \(list.map(\.path))")
        }
    }

    // The rule keeps EVERY row at or above the floor, best first, not only the single best: 6 image passages,
    // five of them at 0.80 ... 0.72 and one at 0.15.
    @Test func inASmallLibraryEveryRowAtOrAboveTheFloorIsKeptBestFirst() throws {
        var entries: [Entry] = []
        let dots: [Float] = [0.72, 0.80, 0.76, 0.15, 0.78, 0.74]
        for (i, dot) in dots.enumerated() { entries.append(Entry(path: "/photos/f\(i).jpg", modality: "image", dot: dot)) }
        try withLibrary(entries) { search, ids in
            let list = try ranked(search)
            let order = ["/photos/f1.jpg", "/photos/f4.jpg", "/photos/f2.jpg", "/photos/f5.jpg", "/photos/f0.jpg"]
            #expect(list == order.map { Found(path: $0, passageID: ids[$0]!) }, "got \(list.map(\.path))")
        }
    }

    // The cap: 7 image passages all above the floor give 5 rows, the 5 best.
    @Test func inASmallLibraryAtMostFiveRowsAreReturned() throws {
        var entries: [Entry] = []
        for i in 0..<7 { entries.append(Entry(path: "/photos/g\(i).jpg", modality: "image", dot: Float(0.70 + 0.02 * Double(i)))) }
        try withLibrary(entries) { search, ids in
            let list = try ranked(search)
            let order = (2...6).reversed().map { "/photos/g\($0).jpg" }   // the 5 highest dots, best first
            #expect(list == order.map { Found(path: $0, passageID: ids[$0]!) }, "got \(list.map(\.path))")
        }
    }

    // Only IMAGE passages count toward the limit: 3 image passages beside 20 text passages is still a small image library.
    @Test func textPassagesDoNotCountTowardTheSmallLibraryLimit() throws {
        var entries = oneStandout(count: 3)
        for i in 0..<20 { entries.append(Entry(path: String(format: "/photos/t%02d.txt", i), modality: "text", dot: 0.30)) }
        try withLibrary(entries) { search, ids in
            let list = try ranked(search)
            #expect(list == [Found(path: "/photos/best.jpg", passageID: ids["/photos/best.jpg"]!)],
                    "3 image passages and 20 flat text passages: expected only the best image, got \(list.map(\.path))")
        }
    }

    // MARK: plan-2-t1 (carry-over R1): the cliff at 8 to 16 image passages
    //
    // Written from plan-2-tasks.md entry t1 and design section 3 and 9.3 only (no product source read; the names are
    // the ones this file already used: `Search.rank`, `Search.imageFloor`).
    //
    // THE RULE THESE TESTS PIN (entry t1): up to and including 30 image passages the floor alone decides for a
    // description (2 or more tokens): every image row whose dot is at or above `Search.imageFloor` (0.69), one row per
    // file, best first, at most 5 files. From 31 image passages the z >= 2 gate plus the floor decide, as before.
    // The old limit was 8; at 8 to 16 passages a handful of real matches inflate the standard deviation so that no z
    // reaches 2 and the list came back empty (the red).
    //
    // The numbers: the query is e0, a target stored vector has a dot of 0.90 (0.90, 0.89, 0.88, 0.87 for the first
    // four targets, so "best first" is observable), every other file has a dot of 0.20, a nonsense library has a best
    // dot of 0.60 (under the floor 0.69). Expected lists are the targets in dot order; nothing here is read from the
    // code under test.

    private let twoWords = "beach sunset"

    /// `count` image files: `targets` of them at 0.90, 0.89, ... (paths /photos/target0.jpg ...), the rest at 0.20.
    private func libraryWithTargets(count: Int, targets: Int, targetBest: Float = 0.90) -> [Entry] {
        var entries: [Entry] = []
        for i in 0..<targets {
            entries.append(Entry(path: "/photos/target\(i).jpg", modality: "image", dot: targetBest - 0.01 * Float(i)))
        }
        for i in 0..<(count - targets) {
            entries.append(Entry(path: String(format: "/photos/other%02d.jpg", i), modality: "image", dot: 0.20))
        }
        return entries
    }

    // The red: n = 8 to 16 returned nothing. The floor-only range is 8 to 30, so 29 and 30 are in it.
    @Test(arguments: [8, 9, 10, 12, 16, 20, 29, 30], [1, 2, 3, 4])
    func aTwoWordDescriptionReturnsExactlyTheTargetsInTheFloorOnlyRange(images n: Int, targets k: Int) throws {
        try withLibrary(libraryWithTargets(count: n, targets: k)) { search, ids in
            let list = try ranked(search, twoWords)
            let expected = (0..<k).map { "/photos/target\($0).jpg" }
            #expect(list == expected.map { Found(path: $0, passageID: ids[$0]!) },
                    "\(n) image passages, \(k) targets at 0.90: expected \(expected), got \(list.map(\.path))")
        }
    }

    // From 31 image passages the z gate plus the floor decide: with 1, 2 or 3 targets at 0.90 among flat 0.20 files
    // z is about 5.5, 4.0 and 3.1 (population standard deviation; checked by hand), so the targets come back.
    @Test(arguments: [31, 40, 50], [1, 2, 3])
    func aTwoWordDescriptionStillReturnsTheTargetsWhereTheZGateDecides(images n: Int, targets k: Int) throws {
        try withLibrary(libraryWithTargets(count: n, targets: k)) { search, ids in
            let list = try ranked(search, twoWords)
            let expected = (0..<k).map { "/photos/target\($0).jpg" }
            #expect(list == expected.map { Found(path: $0, passageID: ids[$0]!) },
                    "\(n) image passages, \(k) targets at 0.90: expected \(expected), got \(list.map(\.path))")
        }
    }

    // No target (best dot 0.60, under the floor): the list is empty at every library size from 3 to 50, on both sides
    // of the old limit 8 and of the new limit 30.
    @Test(arguments: Array(3...50))
    func aNonsenseDescriptionGetsNoRowsAtAnyLibrarySize(images n: Int) throws {
        var entries = [Entry(path: "/photos/nearest.jpg", modality: "image", dot: 0.60)]
        for i in 0..<(n - 1) {
            entries.append(Entry(path: String(format: "/photos/other%02d.jpg", i), modality: "image", dot: 0.20))
        }
        try withLibrary(entries) { search, _ in
            let list = try ranked(search, twoWords)
            #expect(list.isEmpty, "\(n) image passages, best dot 0.60: expected no rows, got \(list.map(\.path))")
        }
    }

    // The n < 8 rule is unchanged, including its known edge: a nonsense library whose best dot is 0.70 (just over the
    // floor; the margin is thin on purpose) shows that one hit, because the floor alone decides there.
    @Test(arguments: [3, 5, 7])
    func underEightPassagesABestDotOfPointSevenStillShowsOneHit(images n: Int) throws {
        try withLibrary(libraryWithTargets(count: n, targets: 1, targetBest: 0.70)) { search, ids in
            let list = try ranked(search, twoWords)
            #expect(list == [Found(path: "/photos/target0.jpg", passageID: ids["/photos/target0.jpg"]!)],
                    "\(n) image passages, best dot 0.70: expected one hit, got \(list.map(\.path))")
        }
    }

    // The cap of 5 files on the floor-only list stays at the new sizes: 8 files at 0.84, 0.82, ... 0.70 (all above the
    // floor) among flat 0.20 files give the 5 best.
    @Test(arguments: [12, 30])
    func theFloorOnlyListIsCappedAtFiveFiles(images n: Int) throws {
        var entries: [Entry] = []
        for i in 0..<8 {
            entries.append(Entry(path: "/photos/up\(i).jpg", modality: "image", dot: Float(0.84 - 0.02 * Double(i))))
        }
        for i in 0..<(n - 8) {
            entries.append(Entry(path: String(format: "/photos/other%02d.jpg", i), modality: "image", dot: 0.20))
        }
        try withLibrary(entries) { search, ids in
            let list = try ranked(search, twoWords)
            let expected = (0..<5).map { "/photos/up\($0).jpg" }
            #expect(list == expected.map { Found(path: $0, passageID: ids[$0]!) },
                    "\(n) image passages, 8 above the floor: expected the best 5, got \(list.map(\.path))")
        }
    }

    // The boundary: 8 files all at 0.75 (above the floor) among flat 0.20 files. At 30 image passages the floor alone
    // decides, so 5 rows come back (the cap). At 31 the z gate decides: mean 0.342, standard deviation 0.241, so each of
    // the 8 has z about 1.69 (1.67 with the sample deviation), under 2, and nothing comes back.
    @Test func atThirtyOneImagePassagesTheZGateDecidesAndAtThirtyTheFloorDoes() throws {
        func entries(count: Int) -> [Entry] {
            var all: [Entry] = []
            for i in 0..<8 { all.append(Entry(path: "/photos/up\(i).jpg", modality: "image", dot: 0.75)) }
            for i in 0..<(count - 8) {
                all.append(Entry(path: String(format: "/photos/other%02d.jpg", i), modality: "image", dot: 0.20))
            }
            return all
        }
        try withLibrary(entries(count: 30)) { search, _ in
            let list = try ranked(search, twoWords)
            #expect(list.count == 5 && list.allSatisfy { $0.path.hasPrefix("/photos/up") },
                    "30 image passages: expected 5 of the 8 rows above the floor, got \(list.map(\.path))")
        }
        try withLibrary(entries(count: 31)) { search, _ in
            let list = try ranked(search, twoWords)
            #expect(list.isEmpty, "31 image passages: the z gate (z about 1.69) decides, expected none, got \(list.map(\.path))")
        }
    }

    // A lone token keeps its relaxed top 5 in the sizes that used to fall off the cliff: 12 and 20 image passages,
    // nothing standing out (0.60 falling by 0.0025 per file), best dot 0.60 under the floor.
    @Test(arguments: [12, 20])
    func aLoneTokenKeepsItsRelaxedTopFive(images n: Int) throws {
        var entries: [Entry] = []
        for i in 0..<n {
            entries.append(Entry(path: String(format: "/photos/flat%02d.jpg", i), modality: "image",
                                 dot: Float(0.60 - 0.0025 * Double(i))))
        }
        try withLibrary(entries) { search, ids in
            let list = try ranked(search, "zebrafish")
            let expected = (0..<5).map { String(format: "/photos/flat%02d.jpg", $0) }
            #expect(list == expected.map { Found(path: $0, passageID: ids[$0]!) }, "got \(list.map(\.path))")
        }
    }
}
