import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t36, tester step. Written from the t36 entry, design section 3 ("Searching"), spec S1 and S2(a), the t23
// tester's notes in SearchTests.swift (Search, Visible, FakeEmbedder, the hand-picked-vector method) and the t22 tests
// (IndexStore and IndexReader names) only; no product source read.
//
// The index is written here, through `IndexStore`, with hand-picked vectors. The query vector is whatever the
// `FakeEmbedder` gives for the typed text (it is deterministic, and tested in SearchTests); each stored vector is
// built from it as a*q + sqrt(1-a*a)*u, with u a unit vector at right angles to q, so its dot product with the query
// is exactly `a` (before half-float rounding, about 1e-3). The tests compute the dot products themselves and sort by
// them. Nothing is asked of the code under test about what the right order is.
//
// SUITE PLACEMENT. HOME is process-wide and these tests set it, and the pipeline emits probe events (SESAME_PROBE_FILE
// and `Probe.sink` are process-wide), so this suite is nested inside `ModelDownloadTests` with the other probe suites
// and runs one at a time with them. Side effect: `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin (the design names `SearchPipeline` and fixes no signatures; if a shape is wrong, ask for
// a test change rather than guessing). `SearchPipeline` is in the `Sesame` target; it may be `@MainActor`.
//   1. `init(search: Search, reader: IndexReader, embedder: any Embedder,
//            visible: @escaping () -> Visible, now: @escaping () -> Double)`
//      `search` is the t23 `Search` over `reader`; `visible` is asked on every `submit` (a folder unticked a moment
//      ago is hidden at the next search); `now` is a monotonic clock in seconds, injected so a test can move time.
//   2. `func newTicket() -> Int` (the same numbers `Search.newTicket()` gives: it is `search.newTicket()`).
//   3. `func submit(text: String, ticket: Int)` returns at once: it never waits for the embedding. For that ticket,
//      in this order: the keyword list is produced (the exact-word match over `IndexReader.keywordSearch`, mapped to
//      files), then the text is embedded with `embedder.embed(text, role: .query)` once, then `search.rank(...)` runs
//      with the newest-ticket check and the ranked list is produced. Both lists are handed out through
//      `var onKeyword: ((Int, [Hit]) -> Void)?` and `var onRanked: ((Int, [Hit]) -> Void)?`, called with the ticket
//      and the files (each `Hit` has `path: String` and `passageID: Int64`, as `Search`'s hits do). The callbacks may
//      run on any thread. A keyword list is produced for every ticket, empty when no word matches. A ranked list is
//      produced only for a ticket that is still the newest when the ranking finishes, and is produced (empty) when
//      nothing matches or no index exists, so the panel can say "No matches".
//   4. `func tick()` is the idle check a timer calls: if `now() - (the time of the last submit) >= 60`, it calls
//      `search.release()` before it returns; before that moment it does nothing. A later `submit` loads the matrix
//      again (`Search` does that on its own) and ranks the same.
//   5. The keyword list holds the files whose stored words hold the typed text as one phrase (`IndexReader.
//      keywordSearch` gives passage ids). These tests put the words in the body of a passage that has a vector (the
//      OCR text of a picture), the one case where a passage id leads to a file path through what `IndexReader`
//      already offers. A hit on a `name` passage is not tested here (see the t36 report).
//   6. Not pinned, on purpose: the order inside the keyword list; whether tier-1 (exact phrase) rows lead the ranked
//      list (the exact-text tier is slice 3); what happens when the embedder throws; whether a keyword list is
//      produced for a ticket that is already stale.

// MARK: small maths done here

private func spDot(_ a: [Float], _ b: [Float]) -> Double {
    var sum = 0.0
    for index in 0..<min(a.count, b.count) { sum += Double(a[index]) * Double(b[index]) }
    return sum
}

// A unit vector at right angles to `q`: axis `k` with its `q` part taken out, then scaled to length 1.
private func spUnit(orthogonalTo q: [Float], axis k: Int) -> [Float] {
    var v = [Double](repeating: 0, count: q.count)
    v[k] = 1
    let along = Double(q[k])
    for i in 0..<q.count { v[i] -= along * Double(q[i]) }
    let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { Float($0 / length) }
}

// A vector whose dot product with `q` is `a`.
private func spVector(_ q: [Float], dot a: Float, axis k: Int) -> [Float] {
    let u = spUnit(orthogonalTo: q, axis: k)
    let side = (1 - a * a).squareRoot()
    return (0..<q.count).map { a * q[$0] + side * u[$0] }
}

// MARK: what the pipeline hands out, recorded

struct SPHit: Equatable, Sendable {
    let path: String
    let passageID: Int64
}

final class SPLog: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var keywordByTicket: [Int: [SPHit]] = [:]
    private var rankedByTicket: [Int: [SPHit]] = [:]

    func keyword(_ ticket: Int, _ hits: [SPHit]) {
        lock.lock(); defer { lock.unlock() }
        order.append("keyword:\(ticket)")
        keywordByTicket[ticket] = hits
    }
    func ranked(_ ticket: Int, _ hits: [SPHit]) {
        lock.lock(); defer { lock.unlock() }
        order.append("ranked:\(ticket)")
        rankedByTicket[ticket] = hits
    }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return order }
    func keywordList(_ ticket: Int) -> [SPHit]? { lock.lock(); defer { lock.unlock() }; return keywordByTicket[ticket] }
    func rankedList(_ ticket: Int) -> [SPHit]? { lock.lock(); defer { lock.unlock() }; return rankedByTicket[ticket] }
}

final class SPClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double
    init(_ start: Double) { seconds = start }
    func set(_ value: Double) { lock.lock(); seconds = value; lock.unlock() }
    var now: Double { lock.lock(); defer { lock.unlock() }; return seconds }
}

final class SPVisible: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Visible
    init(_ value: Visible) { current = value }
    func set(_ value: Visible) { lock.lock(); current = value; lock.unlock() }
    var value: Visible { lock.lock(); defer { lock.unlock() }; return current }
}

// The real FakeEmbedder underneath; records what the pipeline asked for; can hold every call until the test lets go.
final class SPEmbedder: Embedder, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(text: String, role: EmbedRole)] = []
    private let inner = FakeEmbedder()
    private let gate = DispatchSemaphore(value: 0)
    private var gated = false

    func hold() { lock.lock(); gated = true; lock.unlock() }
    func release(_ permits: Int) { for _ in 0..<permits { gate.signal() } }

    func embed(_ text: String, role: EmbedRole) throws -> [Float] {
        lock.lock()
        calls.append((text, role))
        let wait = gated
        lock.unlock()
        if wait { _ = gate.wait(timeout: .now() + 5) }
        return try inner.embed(text, role: role)
    }

    var texts: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.text) }
    var roles: [EmbedRole] { lock.lock(); defer { lock.unlock() }; return calls.map(\.role) }
}

// MARK: the index the tests write

struct SPGraded {
    let path: String
    let dot: Double          // this file's best dot product with the query, computed here
    let bestPassage: Int64   // the passage that has it
}

struct SPFixture {
    let graded: [SPGraded]   // in the order written: g1 .. g5
    var bestFirst: [SPHit] {
        graded.sorted { $0.dot > $1.dot }.map { SPHit(path: $0.path, passageID: $0.bestPassage) }
    }
    func hit(_ path: String) -> SPHit {
        let row = graded.first { $0.path == path }!
        return SPHit(path: row.path, passageID: row.bestPassage)
    }
}

let spG1 = "/photos/a/g1.jpg"
let spG2 = "/photos/b/g2.pdf"
let spG3 = "/photos/a/g3.jpg"
let spG4 = "/photos/b/g4.pdf"
let spG5 = "/photos/a/g5.jpg"
let spGradedPaths = [spG1, spG2, spG3, spG4, spG5]

// words that sit in a picture's text; the phrase "pier lights" is in g5's alone ("pier" alone is in g1's too)
let spPhrase = "pier lights"
// a description no stored word holds
let spDescription = "a quiet harbour at dawn"

private let spKinds: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]

func spVisible(_ paths: String...) -> Visible {
    Visible(folders: paths.map { Settings.Folder(path: $0, code: false, reading: true) },
            codeSearchOn: true, kindsOn: spKinds)
}

// 5 graded files over 100 noise files, in the shape the t23 tests use (only the 5 stand out of the noise):
//   g1 photo .95 (a second passage, inserted after, at .30; its words hold "pier" but not "pier lights")
//   g2 pdf   .85
//   g3 photo .75 (a second passage, inserted BEFORE it, at .20)
//   g4 pdf   .65
//   g5 photo .55 (its words hold "pier lights")
//   noise: 100 pdf files, each at dot 0
func spWriteIndex(for text: String) throws -> SPFixture {
    let query = try FakeEmbedder().embed(text, role: .query)
    let store = try IndexStore()
    defer { store.close() }
    var inode: Int64 = 100
    var graded: [SPGraded] = []

    func add(path: String, kind: String, name: String,
             passages: [(source: String, dot: Float, axis: Int, body: String)]) throws {
        inode += 1
        let file = try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                     inode: inode, device: 16_777_220, status: "done")
        _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                                 vector: nil, name: name, body: "")
        var best: (dot: Float, id: Int64, vector: [Float])?
        for passage in passages {
            let vector = spVector(query, dot: passage.dot, axis: passage.axis)
            let id = try store.addPassage(fileID: file, source: passage.source, start: 0, end: 0,
                                          modality: "image", vector: vector, name: "", body: passage.body)
            if best == nil || passage.dot > best!.dot { best = (passage.dot, id, vector) }
        }
        if let best {
            graded.append(SPGraded(path: path, dot: spDot(best.vector, query), bestPassage: best.id))
        }
    }

    try add(path: spG1, kind: "photo", name: "harbour boats morning",
            passages: [("image", 0.95, 101, "red boats at the quiet pier"), ("image", 0.30, 102, "")])
    try add(path: spG2, kind: "pdf", name: "ledger summary", passages: [("page", 0.85, 103, "")])
    try add(path: spG3, kind: "photo", name: "market crowd",
            passages: [("image", 0.20, 104, ""), ("image", 0.75, 105, "")])
    try add(path: spG4, kind: "pdf", name: "tenancy terms", passages: [("page", 0.65, 106, "")])
    try add(path: spG5, kind: "photo", name: "mountain ridge", passages: [("image", 0.55, 107, spPhrase)])
    for k in 1...100 {
        inode += 1
        let path = String(format: "/photos/b/n%03d.pdf", k)
        let file = try store.addFile(path: path, kind: "pdf", size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                     inode: inode, device: 16_777_220, status: "done")
        _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                                 vector: nil, name: String(format: "scan%03d", k), body: "")
        _ = try store.addPassage(fileID: file, source: "page", start: 0, end: 0, modality: "image",
                                 vector: spVector(query, dot: 0, axis: k), name: "", body: "")
    }
    return SPFixture(graded: graded)
}

// MARK: HOME and the harness

@MainActor
func spWithHome(_ body: @MainActor (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-pipeline-home-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: home)
    }
    _ = try SesameFolder.create()
    let folder = home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
    guard fm.fileExists(atPath: folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try await body(home)
}

@MainActor
final class SPHarness {
    let pipeline: SearchPipeline
    let search: Search
    let reader: IndexReader
    let embedder: SPEmbedder
    let clock: SPClock
    let visible: SPVisible
    let log: SPLog
    let fixture: SPFixture?

    init(fixture: SPFixture?, visible start: Visible = spVisible("/photos"), clockStart: Double = 1000) {
        self.fixture = fixture
        reader = IndexReader()
        search = Search(reader: reader)
        embedder = SPEmbedder()
        clock = SPClock(clockStart)
        visible = SPVisible(start)
        log = SPLog()
        let clock = self.clock
        let visibleHolder = self.visible
        pipeline = SearchPipeline(search: search, reader: reader, embedder: embedder,
                                  visible: { visibleHolder.value }, now: { clock.now })
        let log = self.log
        // @Sendable, so the closures belong to no actor: the pipeline may call them from any thread
        pipeline.onKeyword = { @Sendable ticket, hits in
            log.keyword(ticket, hits.map { SPHit(path: $0.path, passageID: $0.passageID) })
        }
        pipeline.onRanked = { @Sendable ticket, hits in
            log.ranked(ticket, hits.map { SPHit(path: $0.path, passageID: $0.passageID) })
        }
    }

    // One submit under a fresh ticket.
    @discardableResult
    func submit(_ text: String) -> Int {
        let ticket = pipeline.newTicket()
        pipeline.submit(text: text, ticket: ticket)
        return ticket
    }

    func close() { reader.close() }
}

// A temp HOME, an index written for `text` (or none), a pipeline over it, the body, everything put back.
@MainActor
func spWithPipeline(text: String, writeIndex: Bool = true, visible: Visible = spVisible("/photos"),
                    _ body: @MainActor (SPHarness) async throws -> Void) async throws {
    try await spWithHome { _ in
        let fixture = writeIndex ? try spWriteIndex(for: text) : nil
        let harness = SPHarness(fixture: fixture, visible: visible)
        defer { harness.close() }
        try await body(harness)
    }
}

@MainActor
func spEventually(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

func spWait(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

extension ModelDownloadTests {
    @Suite("SearchPipelineTests", .serialized)
    struct SearchPipelineTests {

        // MARK: the ranked list

        @MainActor
        @Test func aDescriptionIsEmbeddedAsAQueryAndTheRankedListIsInTheDotProductOrderTheTestComputed() async throws {
            try await spWithPipeline(text: spDescription) { h in
                let fixture = try #require(h.fixture)
                let ticket = h.submit(spDescription)
                let arrived = await spEventually { h.log.rankedList(ticket) != nil }
                #expect(arrived, "no ranked list arrived; events: \(h.log.events)")
                let ranked = h.log.rankedList(ticket) ?? []

                // the test's own order: the 5 graded files by their dot product with the query, best passage each
                #expect(ranked == fixture.bestFirst, "got \(ranked.map(\.path)), expected \(fixture.bestFirst.map(\.path))")
                #expect(ranked.first?.path == spG1)
                #expect(Set(ranked.map(\.path)).count == ranked.count, "a file is listed twice")
                // the noise files at dot 0 do not stand out, so none is listed
                #expect(ranked.allSatisfy { spGradedPaths.contains($0.path) }, "listed: \(ranked.map(\.path))")

                // the text went to the embedder once, as typed, as a query
                #expect(h.embedder.texts == [spDescription], "embedded: \(h.embedder.texts)")
                #expect(h.embedder.roles == [.query], "roles: \(h.embedder.roles)")
            }
        }

        @MainActor
        @Test func theKeywordListIsProducedBeforeTheRankedListForTheSameTicketEvenWhenItIsEmpty() async throws {
            try await spWithPipeline(text: spDescription) { h in
                let ticket = h.submit(spDescription)
                let arrived = await spEventually { h.log.rankedList(ticket) != nil }
                #expect(arrived)
                // no stored word holds the description: an empty keyword list, but a list was produced
                #expect(h.log.keywordList(ticket) == [], "keyword list: \(String(describing: h.log.keywordList(ticket)))")
                #expect(h.log.events == ["keyword:\(ticket)", "ranked:\(ticket)"], "events: \(h.log.events)")
            }
        }

        @MainActor
        @Test func theKeywordListHoldsTheFileWhoseWordsHoldTheTextAsAPhraseAndComesFirst() async throws {
            try await spWithPipeline(text: spPhrase) { h in
                let fixture = try #require(h.fixture)
                let ticket = h.submit(spPhrase)
                let arrived = await spEventually { h.log.rankedList(ticket) != nil }
                #expect(arrived, "no ranked list arrived; events: \(h.log.events)")

                // "pier lights" is in g5's words only; g1's words hold "pier" but not the phrase
                let keyword = h.log.keywordList(ticket) ?? []
                #expect(keyword.map(\.path) == [spG5], "keyword list: \(keyword.map(\.path))")
                #expect(keyword.first?.passageID == fixture.hit(spG5).passageID, "wrong passage: \(keyword)")

                #expect(h.log.events == ["keyword:\(ticket)", "ranked:\(ticket)"], "events: \(h.log.events)")

                // the same files are ranked by meaning: all five are there, each once
                let ranked = h.log.rankedList(ticket) ?? []
                #expect(Set(ranked.map(\.path)) == Set(spGradedPaths), "ranked: \(ranked.map(\.path))")
                #expect(ranked.count == 5)
            }
        }

        @MainActor
        @Test func eachFileIsListedOnceWithItsBestPassage() async throws {
            try await spWithPipeline(text: spDescription) { h in
                let fixture = try #require(h.fixture)
                let ticket = h.submit(spDescription)
                _ = await spEventually { h.log.rankedList(ticket) != nil }
                let ranked = h.log.rankedList(ticket) ?? []
                // g1's best passage was written first, g3's last: neither "first" nor "last" is the rule
                #expect(ranked.first { $0.path == spG1 } == fixture.hit(spG1))
                #expect(ranked.first { $0.path == spG3 } == fixture.hit(spG3))
                #expect(ranked.count == 5)
            }
        }

        // MARK: nothing matches, nothing indexed

        @MainActor
        @Test func anIndexThatDoesNotExistGivesAnEmptyRankedListAndAnEmptyKeywordList() async throws {
            try await spWithPipeline(text: spDescription, writeIndex: false) { h in
                let ticket = h.submit(spDescription)
                let arrived = await spEventually { h.log.rankedList(ticket) != nil }
                #expect(arrived, "an empty ranked list must still arrive, so the panel can say No matches; events: \(h.log.events)")
                #expect(h.log.rankedList(ticket) == [])
                #expect(h.log.keywordList(ticket) == [])
                #expect(h.log.events == ["keyword:\(ticket)", "ranked:\(ticket)"], "events: \(h.log.events)")
            }
        }

        // MARK: tickets

        @MainActor
        @Test func aTicketThatIsAlreadyStaleGetsNoRankedListAndTheNewestOneDoes() async throws {
            try await spWithPipeline(text: spDescription) { h in
                let older = h.pipeline.newTicket()
                let newer = h.pipeline.newTicket()
                #expect(older != newer)
                h.pipeline.submit(text: spDescription, ticket: older)
                h.pipeline.submit(text: spDescription, ticket: newer)

                let arrived = await spEventually { h.log.rankedList(newer) != nil }
                #expect(arrived, "the newest ticket got no list; events: \(h.log.events)")
                await spWait(0.4)
                #expect(h.log.rankedList(older) == nil, "a ranked list came back for a ticket that is no longer the newest")
                #expect(!h.log.events.contains("ranked:\(older)"), "events: \(h.log.events)")
                #expect(h.log.rankedList(newer) == h.fixture?.bestFirst)
            }
        }

        @MainActor
        @Test func submitReturnsAtOnceAndAKeystrokeDuringTheEmbeddingMakesTheOlderListNeverArrive() async throws {
            try await spWithPipeline(text: spDescription) { h in
                h.embedder.hold()
                defer { h.embedder.release(4) }

                let clock = ContinuousClock()
                var older = 0
                let took = clock.measure { older = h.submit(spDescription) }
                #expect(took < .seconds(1), "submit waited \(took) for the embedding: it must return at once")

                let entered = await spEventually { !h.embedder.texts.isEmpty }
                #expect(entered, "the embedder was never asked")
                #expect(h.log.rankedList(older) == nil, "a list arrived while the embedder was still held")

                // the next keystroke: a newer ticket while the older embedding is still running
                let newer = h.submit(spDescription)
                h.embedder.release(4)

                let arrived = await spEventually { h.log.rankedList(newer) != nil }
                #expect(arrived, "the newest ticket got no list; events: \(h.log.events)")
                await spWait(0.4)
                #expect(h.log.rankedList(older) == nil, "the older ticket's list arrived after a newer keystroke")
            }
        }

        // MARK: what is visible, read at each search

        @MainActor
        @Test func theVisiblePredicateIsReadAtEachSubmitSoAnUntickedFolderIsHiddenAtOnce() async throws {
            try await spWithPipeline(text: spDescription) { h in
                let fixture = try #require(h.fixture)
                let all = h.submit(spDescription)
                _ = await spEventually { h.log.rankedList(all) != nil }
                #expect(h.log.rankedList(all) == fixture.bestFirst)

                // /photos/a unticked: g1, g3 and g5 vanish, g2 and g4 stay in dot order
                h.visible.set(spVisible("/photos/b"))
                let onlyB = h.submit(spDescription)
                let second = await spEventually { h.log.rankedList(onlyB) != nil }
                #expect(second)
                let expectedB = fixture.bestFirst.filter { $0.path.hasPrefix("/photos/b/") }
                #expect(h.log.rankedList(onlyB) == expectedB, "got \(String(describing: h.log.rankedList(onlyB)?.map(\.path)))")
                #expect(expectedB.map(\.path) == [spG2, spG4])

                // ticked again: they are back
                h.visible.set(spVisible("/photos"))
                let again = h.submit(spDescription)
                _ = await spEventually { h.log.rankedList(again) != nil }
                #expect(h.log.rankedList(again) == fixture.bestFirst)
            }
        }

        // MARK: the matrix is released 60 s after the last search

        @MainActor
        @Test func theMatrixIsReleasedSixtySecondsAfterTheLastSearchAndLoadedAgainBySearchThatFollows() async throws {
            try await spWithPipeline(text: spDescription) { h in
                let fixture = try #require(h.fixture)

                // nothing loaded yet: a tick changes nothing and breaks nothing
                h.clock.set(1000)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == false)

                // the search at t = 1000 loads the matrix
                let first = h.submit(spDescription)
                _ = await spEventually { h.log.rankedList(first) != nil }
                #expect(h.search.matrixLoaded == true, "the search did not load the matrix")
                let firstList = h.log.rankedList(first) ?? []
                #expect(firstList == fixture.bestFirst)

                // 59.9 s after it: still loaded
                h.clock.set(1059.9)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == true, "released before 60 s")

                // 60 s after it: released, by the time tick() returns
                h.clock.set(1060)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == false, "not released 60 s after the last search")

                // a later search loads it again and ranks the same
                let second = h.submit(spDescription)
                _ = await spEventually { h.log.rankedList(second) != nil }
                #expect(h.search.matrixLoaded == true, "the later search did not load the matrix again")
                #expect(h.log.rankedList(second) == firstList, "the ranking changed after the release")
            }
        }

        @MainActor
        @Test func theSixtySecondsCountFromTheLastSearchNotTheFirst() async throws {
            try await spWithPipeline(text: spDescription) { h in
                h.clock.set(1000)
                let first = h.submit(spDescription)
                _ = await spEventually { h.log.rankedList(first) != nil }
                #expect(h.search.matrixLoaded == true)

                // a second search 59 s later restarts the count
                h.clock.set(1059)
                let second = h.submit(spDescription)
                _ = await spEventually { h.log.rankedList(second) != nil }

                h.clock.set(1118.9)   // 119.9 s after the first, 59.9 s after the second
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == true, "released 60 s after the first search, not the last")

                h.clock.set(1119)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == false, "not released 60 s after the last search")

                // a tick on an already released matrix is fine
                h.clock.set(5000)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == false)
            }
        }
    }
}

// MARK: plan-2-t36 (F14): the search never hangs on "Searching" when the embed fails
//
// Tester step, written from the t36 entry, design section 3 ("Searching") and the tests above only; no product source
// read. The nine tests above stay as they were.
//
// API SHAPE these tests pin (the entry names `onFailed`; if the shape is wrong, ask for a test change):
//   `var onFailed: (@Sendable (Int) -> Void)?` on `SearchPipeline`, set like `onKeyword` and `onRanked`; called with the
//   ticket, from any thread, ONCE for the newest ticket when its embedding throws (whatever the error: refused, a
//   timeout, a helper that died), after that ticket's keyword list, and never for a ticket that is no longer the newest
//   when the failure is known. No ranked list (and no `ranked` event) is produced for a failed ticket. The next ticket
//   is searched as if nothing had happened: it embeds again, and the failure of the older ticket is not repeated.
//
// The embedder here is a stand-in that throws on the calls the test names (by call number); the error values are the
// test's own, so the pipeline must not depend on which error it is.

enum SFFailure: String, Error, CaseIterable, Sendable, CustomTestStringConvertible {
    case refused, timedOut, died
    var testDescription: String { rawValue }
}

// The real FakeEmbedder underneath; throws on the calls `outcome` names; can hold every call until the test lets go.
final class SFEmbedder: Embedder, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let inner = FakeEmbedder()
    private let outcome: @Sendable (Int) -> SFFailure?
    private var calls: [(text: String, role: EmbedRole)] = []
    private var gated = false

    init(outcome: @escaping @Sendable (Int) -> SFFailure?) { self.outcome = outcome }

    func hold() { lock.lock(); gated = true; lock.unlock() }
    func release(_ permits: Int) { for _ in 0..<permits { gate.signal() } }

    func embed(_ text: String, role: EmbedRole) throws -> [Float] {
        lock.lock()
        let index = calls.count
        calls.append((text, role))
        let wait = gated
        lock.unlock()
        if wait { _ = gate.wait(timeout: .now() + 5) }
        if let failure = outcome(index) { throw failure }
        return try inner.embed(text, role: role)
    }

    var texts: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.text) }
    var roles: [EmbedRole] { lock.lock(); defer { lock.unlock() }; return calls.map(\.role) }
}

final class SFLog: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var keywordByTicket: [Int: [SPHit]] = [:]
    private var rankedByTicket: [Int: [SPHit]] = [:]

    func keyword(_ ticket: Int, _ hits: [SPHit]) {
        lock.lock(); defer { lock.unlock() }
        order.append("keyword:\(ticket)")
        keywordByTicket[ticket] = hits
    }
    func ranked(_ ticket: Int, _ hits: [SPHit]) {
        lock.lock(); defer { lock.unlock() }
        order.append("ranked:\(ticket)")
        rankedByTicket[ticket] = hits
    }
    func failed(_ ticket: Int) {
        lock.lock(); defer { lock.unlock() }
        order.append("failed:\(ticket)")
    }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return order }
    func failedCount(_ ticket: Int) -> Int { events.filter { $0 == "failed:\(ticket)" }.count }
    func keywordList(_ ticket: Int) -> [SPHit]? { lock.lock(); defer { lock.unlock() }; return keywordByTicket[ticket] }
    func rankedList(_ ticket: Int) -> [SPHit]? { lock.lock(); defer { lock.unlock() }; return rankedByTicket[ticket] }
}

@MainActor
final class SFHarness {
    let pipeline: SearchPipeline
    let reader: IndexReader
    let embedder: SFEmbedder
    let log: SFLog
    let fixture: SPFixture

    init(fixture: SPFixture, outcome: @escaping @Sendable (Int) -> SFFailure?) {
        self.fixture = fixture
        reader = IndexReader()
        let search = Search(reader: reader)
        embedder = SFEmbedder(outcome: outcome)
        log = SFLog()
        pipeline = SearchPipeline(search: search, reader: reader, embedder: embedder,
                                  visible: { spVisible("/photos") }, now: { 1000 })
        let log = self.log
        pipeline.onKeyword = { @Sendable ticket, hits in
            log.keyword(ticket, hits.map { SPHit(path: $0.path, passageID: $0.passageID) })
        }
        pipeline.onRanked = { @Sendable ticket, hits in
            log.ranked(ticket, hits.map { SPHit(path: $0.path, passageID: $0.passageID) })
        }
        pipeline.onFailed = { @Sendable ticket in log.failed(ticket) }
    }

    @discardableResult
    func submit(_ text: String) -> Int {
        let ticket = pipeline.newTicket()
        pipeline.submit(text: text, ticket: ticket)
        return ticket
    }

    func close() { reader.close() }
}

// A temp HOME, the index written for `text`, a pipeline over it whose embedder fails as `outcome` says, the body.
@MainActor
func sfWithPipeline(text: String, outcome: @escaping @Sendable (Int) -> SFFailure?,
                    _ body: @MainActor (SFHarness) async throws -> Void) async throws {
    try await spWithHome { _ in
        let fixture = try spWriteIndex(for: text)
        let harness = SFHarness(fixture: fixture, outcome: outcome)
        defer { harness.close() }
        try await body(harness)
    }
}

extension ModelDownloadTests.SearchPipelineTests {

    @MainActor
    @Test(arguments: SFFailure.allCases)
    func anEmbedThatFailsGivesTheKeywordListThenOnFailedOnceAndNoRankedList(_ failure: SFFailure) async throws {
        try await sfWithPipeline(text: spDescription, outcome: { _ in failure }) { h in
            let ticket = h.submit(spDescription)
            let told = await spEventually { h.log.failedCount(ticket) >= 1 }
            #expect(told, "onFailed was never called for the ticket (\(failure)); events: \(h.log.events)")
            await spWait(0.4)
            #expect(h.log.failedCount(ticket) == 1, "onFailed was called \(h.log.failedCount(ticket)) times; events: \(h.log.events)")
            #expect(h.log.events == ["keyword:\(ticket)", "failed:\(ticket)"], "events: \(h.log.events)")
            #expect(h.log.rankedList(ticket) == nil, "a ranked list was produced for a ticket whose embed failed")
            #expect(h.log.keywordList(ticket) == [], "keyword list: \(String(describing: h.log.keywordList(ticket)))")
            #expect(h.embedder.texts == [spDescription], "embedded: \(h.embedder.texts)")
        }
    }

    @MainActor
    @Test func aTierOnePhraseKeepsItsKeywordListAndThenTheFailureIsReported() async throws {
        try await sfWithPipeline(text: spPhrase, outcome: { _ in .died }) { h in
            let ticket = h.submit(spPhrase)
            let told = await spEventually { h.log.failedCount(ticket) >= 1 }
            #expect(told, "onFailed was never called; events: \(h.log.events)")
            // "pier lights" is in g5's words only: the keyword list was handed out before the failure
            #expect(h.log.keywordList(ticket)?.map(\.path) == [spG5], "keyword list: \(String(describing: h.log.keywordList(ticket)))")
            #expect(h.log.events == ["keyword:\(ticket)", "failed:\(ticket)"], "events: \(h.log.events)")
            #expect(h.log.rankedList(ticket) == nil)
        }
    }

    @MainActor
    @Test func aStaleTicketNeverGetsOnFailedAndTheNewestGetsItOnce() async throws {
        try await sfWithPipeline(text: spDescription, outcome: { _ in .died }) { h in
            h.embedder.hold()
            defer { h.embedder.release(4) }
            let older = h.submit(spDescription)
            let entered = await spEventually { !h.embedder.texts.isEmpty }
            #expect(entered, "the embedder was never asked")

            // the next keystroke, while the older embed is still held; then both embeds fail
            let newer = h.submit(spDescription)
            h.embedder.release(4)

            let told = await spEventually { h.log.failedCount(newer) >= 1 }
            #expect(told, "the newest ticket was never told; events: \(h.log.events)")
            await spWait(0.4)
            #expect(h.log.failedCount(older) == 0, "onFailed came for a ticket that is no longer the newest; events: \(h.log.events)")
            #expect(h.log.failedCount(newer) == 1, "events: \(h.log.events)")
            #expect(h.log.events.filter { $0.hasPrefix("failed:") } == ["failed:\(newer)"], "events: \(h.log.events)")
            #expect(h.log.rankedList(older) == nil && h.log.rankedList(newer) == nil, "a ranked list came for a failed embed")
        }
    }

    @MainActor
    @Test func anOlderEmbedThatFailsWhileTheNewestSucceedsGivesNoOnFailedAtAll() async throws {
        // call 0 (the older ticket's) fails; call 1 (the newest ticket's) works
        try await sfWithPipeline(text: spDescription, outcome: { $0 == 0 ? .timedOut : nil }) { h in
            h.embedder.hold()
            defer { h.embedder.release(4) }
            let older = h.submit(spDescription)
            let entered = await spEventually { !h.embedder.texts.isEmpty }
            #expect(entered, "the embedder was never asked")
            let newer = h.submit(spDescription)
            h.embedder.release(4)

            let arrived = await spEventually { h.log.rankedList(newer) != nil }
            #expect(arrived, "the newest ticket got no ranked list; events: \(h.log.events)")
            await spWait(0.4)
            #expect(h.log.rankedList(newer) == h.fixture.bestFirst)
            #expect(h.log.events.contains { $0.hasPrefix("failed:") } == false,
                    "the failure of a stale ticket was reported: \(h.log.events)")
            #expect(h.log.rankedList(older) == nil)
        }
    }

    @MainActor
    @Test func theNextKeystrokeSearchesAgainAndTheFailureIsNotRepeated() async throws {
        // the first embed is refused, every later one works
        try await sfWithPipeline(text: spDescription, outcome: { $0 == 0 ? .refused : nil }) { h in
            let first = h.submit(spDescription)
            let told = await spEventually { h.log.failedCount(first) >= 1 }
            #expect(told, "the first ticket was never told; events: \(h.log.events)")

            let second = h.submit(spDescription)
            let arrived = await spEventually { h.log.rankedList(second) != nil }
            #expect(arrived, "the next keystroke did not search again; events: \(h.log.events)")
            #expect(h.log.rankedList(second) == h.fixture.bestFirst,
                    "got \(String(describing: h.log.rankedList(second)?.map(\.path)))")
            await spWait(0.3)
            #expect(h.log.failedCount(second) == 0, "the failure was repeated for the next ticket; events: \(h.log.events)")
            #expect(h.log.events == ["keyword:\(first)", "failed:\(first)", "keyword:\(second)", "ranked:\(second)"],
                    "events: \(h.log.events)")
            #expect(h.embedder.texts == [spDescription, spDescription], "embedded: \(h.embedder.texts)")
            #expect(h.embedder.roles == [.query, .query], "roles: \(h.embedder.roles)")
        }
    }

    @MainActor
    @Test func aFailureAfterAnEarlierSuccessIsStillReportedAndTheEarlierListStays() async throws {
        try await sfWithPipeline(text: spDescription, outcome: { $0 == 1 ? .timedOut : nil }) { h in
            let first = h.submit(spDescription)
            let ranked = await spEventually { h.log.rankedList(first) != nil }
            #expect(ranked, "the first ticket got no ranked list; events: \(h.log.events)")

            let second = h.submit(spDescription)
            let told = await spEventually { h.log.failedCount(second) >= 1 }
            #expect(told, "the second ticket was never told; events: \(h.log.events)")
            #expect(h.log.rankedList(second) == nil)
            #expect(h.log.failedCount(first) == 0, "the first ticket was told of a failure; events: \(h.log.events)")
            #expect(h.log.rankedList(first) == h.fixture.bestFirst)
        }
    }

    @MainActor
    @Test func anEmbedThatWorksNeverCallsOnFailed() async throws {
        try await sfWithPipeline(text: spDescription, outcome: { _ in nil }) { h in
            let ticket = h.submit(spDescription)
            let arrived = await spEventually { h.log.rankedList(ticket) != nil }
            #expect(arrived, "no ranked list arrived; events: \(h.log.events)")
            await spWait(0.4)
            #expect(h.log.events == ["keyword:\(ticket)", "ranked:\(ticket)"], "events: \(h.log.events)")
            #expect(h.log.rankedList(ticket) == h.fixture.bestFirst)
        }
    }
}

// MARK: plan-3-t19: one definition of tier 1
//
// Tester step, written from the t19 entry, Decision D10 and the tests above only; no product source read. The tests
// above stay as they were.
//
// API SHAPE these tests pin (named by the entry): `Search.exactHits(text:visible:)`, an instance method of the `Search`
// the harness holds (`h.search`), returning the files with `path` and `passageID`, not throwing. The pipeline's keyword
// list for a ticket is that list, row for row, for the `Visible` the pipeline was given at that submit; and the ranked
// list of the same ticket starts with those rows (tier-1 rows stay first in the ranked list; D10: `exactHits` is the one
// definition, used by the pipeline's keyword rows and by `rank`).
//
// The expected sets of files are written by hand from the index `spWriteIndex` builds: "pier lights" is in g5's words
// only; "pier" is in g1's and in g5's; "boats" is in g1's name and in g1's words (one file, listed once); no stored word
// holds `spDescription`. The order inside a tier is not pinned here (the entry's tests pin it); the equality with
// `exactHits` is.

extension ModelDownloadTests.SearchPipelineTests {

    @MainActor
    @Test(arguments: zip(
        [spPhrase, "PIER LIGHTS", "pier, lights", "pier", "boats", spDescription],
        [[spG5], [spG5], [spG5], [spG1, spG5], [spG1], []] as [[String]]))
    func theKeywordListEqualsExactHitsRowForRowAndTheRankedListStartsWithIt(text: String, files: [String]) async throws {
        try await spWithPipeline(text: text) { h in
            let ticket = h.submit(text)
            let arrived = await spEventually { h.log.rankedList(ticket) != nil }
            #expect(arrived, "no ranked list arrived; events: \(h.log.events)")

            let keyword = h.log.keywordList(ticket) ?? []
            let exact: [SPHit] = h.search.exactHits(text: text, visible: h.visible.value).map { SPHit(path: $0.path, passageID: $0.passageID) }
            #expect(keyword == exact, "\"\(text)\": keyword list \(keyword.map(\.path)), exactHits \(exact.map(\.path))")
            #expect(Set(keyword.map(\.path)) == Set(files) && keyword.count == files.count,
                    "\"\(text)\": expected the files \(files) once each, got \(keyword.map(\.path))")

            let ranked = h.log.rankedList(ticket) ?? []
            // files only: which of a file's passages shows is `exactHits`' and `rank`'s business (checked in SearchExactTierTests)
            // AMENDED in plan-4 review round 1, fix round, tester step. The old assertion was "the ranked list starts with exactHits'
            // rows, in exactHits' order". New rule (reviewer, must-fix 2): the same SET of rows first, ordered by the file's best
            // passage's dot with the query, highest first, then by path; `exactHits` (the keyword list) keeps its path order, which
            // the first assertion above still pins row for row. Reason: with the full text of PDFs and documents in the index, a
            // phrase held by many files listed them alphabetically above the semantically best one. The dots are the fixture's own
            // (`SPFixture.graded`, computed by the test), so the order asserted here is not weaker than before: it is stricter.
            let fixture = try #require(h.fixture)
            let dots = Dictionary(uniqueKeysWithValues: fixture.graded.map { ($0.path, $0.dot) })
            let expectedOrder = exact.map(\.path).sorted { first, second in
                let a = dots[first] ?? 0, b = dots[second] ?? 0
                return a != b ? a > b : first < second
            }
            #expect(Set(ranked.prefix(exact.count).map(\.path)) == Set(exact.map(\.path)),
                    "\"\(text)\": the ranked list starts with \(ranked.prefix(exact.count).map(\.path)), expected the files \(exact.map(\.path)) first")
            #expect(ranked.prefix(exact.count).map(\.path) == expectedOrder,
                    "\"\(text)\": the first rows are \(ranked.prefix(exact.count).map(\.path)), expected the dot order \(expectedOrder)")
            #expect(Set(ranked.map(\.path)).count == ranked.count, "a file is listed twice: \(ranked.map(\.path))")
        }
    }

    // "pier lights" is in g5's words alone and g5 has the lowest dot of the five: the ranked list puts it first, then
    // the other four in the dot order the test computed (the fused ranking, unchanged).
    @MainActor
    @Test func anExactPhraseIsFirstInTheRankedListAndTheRestIsTheFusedRanking() async throws {
        try await spWithPipeline(text: spPhrase) { h in
            let fixture = try #require(h.fixture)
            let ticket = h.submit(spPhrase)
            let arrived = await spEventually { h.log.rankedList(ticket) != nil }
            #expect(arrived, "no ranked list arrived; events: \(h.log.events)")
            let expected = [fixture.hit(spG5)] + fixture.bestFirst.filter { $0.path != spG5 }
            #expect(expected.map(\.path) == [spG5, spG1, spG2, spG3, spG4], "the test's own order")
            #expect(h.log.rankedList(ticket) == expected, "got \(String(describing: h.log.rankedList(ticket)?.map(\.path)))")
        }
    }

    // The visible predicate applies to the keyword list the same way it applies to `exactHits`.
    @MainActor
    @Test func aTierOneFileThatVisibleHidesIsNotInTheKeywordListNorFirstInTheRankedList() async throws {
        try await spWithPipeline(text: spPhrase) { h in
            let fixture = try #require(h.fixture)
            // /photos/a holds g1, g3 and g5; only /photos/b is ticked, so g5 is hidden
            h.visible.set(spVisible("/photos/b"))
            let hidden = h.submit(spPhrase)
            let arrivedHidden = await spEventually { h.log.rankedList(hidden) != nil }
            #expect(arrivedHidden)
            #expect(h.log.keywordList(hidden) == [], "keyword list: \(String(describing: h.log.keywordList(hidden)?.map(\.path)))")
            #expect(h.search.exactHits(text: spPhrase, visible: h.visible.value).isEmpty)
            let rankedHidden = h.log.rankedList(hidden) ?? []
            #expect(!rankedHidden.contains { $0.path == spG5 }, "ranked: \(rankedHidden.map(\.path))")
            #expect(rankedHidden == fixture.bestFirst.filter { $0.path.hasPrefix("/photos/b/") }, "ranked: \(rankedHidden.map(\.path))")

            h.visible.set(spVisible("/photos"))
            let shown = h.submit(spPhrase)
            _ = await spEventually { h.log.rankedList(shown) != nil }
            #expect(h.log.keywordList(shown) == [fixture.hit(spG5)])
            #expect(h.log.rankedList(shown)?.first == fixture.hit(spG5))
        }
    }
}
