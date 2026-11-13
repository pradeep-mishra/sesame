import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t39, tester step. Spec S1.20 (spec.md line 92: "files already read are found" while indexing runs) and
// design section 3 ("new passages are appended"; the helper says `changed` after each commit). Real-app batch 2 found
// `CHECK S1.20 FAIL the file already read (f000001.jpg) is not listed while indexing runs`: the pipeline loaded the
// matrix at the first search and ignored `changed` until the 60 s idle release.
//
// Reuses the harness of SearchPipelineTests.swift (SPHarness, spWithHome, spEventually, spWait, SPHit, spVisible,
// spWriteIndex, spDescription, spG1...spG5). Only the public names of product source were looked at (HelperEvent in
// SesameEngine/Protocol.swift; HelperEventRelay's current private shape in Panel.swift); expected values come from the
// spec and from dot products computed here.
//
// SUITE PLACEMENT. HOME is process-wide, so the pipeline suite is nested in `ModelDownloadTests` with the others and
// runs one at a time. The relay suite touches nothing process-wide and stands alone.
//
// API SHAPES these tests pin (smallest design that satisfies the spec; if a shape is wrong, ask for a test change):
//   1. `SearchPipeline.indexChanged()`: "the index helper committed". It only marks the pipeline stale; it does no
//      work, takes no lock a search holds, and may be called from any thread (the relay calls it from the helper's
//      reader thread). Cheap enough to call for every file.
//   2. At the next `submit`, if the pipeline is stale AND a matrix is loaded AND at least 2 s (`now() - lastReloadAt
//      >= 2`, the injected clock) have passed since the last reload, the pipeline reloads the matrix (the `Search`
//      matrix and the pipeline's id-to-path map) BEFORE the keyword list for that ticket is produced, and is no longer
//      stale. If less than 2 s have passed, it does not reload and STAYS stale, so the next search after the 2 s
//      reloads (a `changed` that arrives for every file is therefore never lost, only batched).
//   3. `SearchPipeline.reloadCount: Int`, readable from any thread, starts at 0. It counts the reloads of rule 2 and
//      nothing else: the first load of a search, and a load after `release()`, are NOT counted. The count is up to
//      date by the time the ranked list for the ticket has been handed out. `lastReloadAt` starts unset (the first
//      reload is never held back) and only a reload sets it.
//   4. `indexChanged()` with no matrix loaded (never searched, or after `release()`) changes nothing visible: the
//      next search loads the matrix fresh, which already includes everything written, and `reloadCount` stays.
//   5. The 60 s release counts from the last `submit`, as before; a reload does not restart it.
//   6. The relay seam (pure): `HelperEventRelay` becomes internal (not `private`) and has
//      `static func route(_ event: HelperEvent, onIndexChanged: () -> Void)`, which calls `onIndexChanged` exactly
//      once for `.changed` and never for any other event. The relay's `helperClient(_:didReceive:)` calls it with
//      `{ pipeline.indexChanged() }`. (That the relay hands the event on to the embedder and the preview closure stays
//      as it is.)

// MARK: small maths done here

private func icDot(_ a: [Float], _ b: [Float]) -> Double {
    var sum = 0.0
    for index in 0..<min(a.count, b.count) { sum += Double(a[index]) * Double(b[index]) }
    return sum
}

// A vector whose dot product with the unit vector `q` is `a`: a*q + sqrt(1-a*a)*u, u at right angles to q.
private func icVector(_ q: [Float], dot a: Float, axis k: Int) -> [Float] {
    var v = [Double](repeating: 0, count: q.count)
    v[k] = 1
    let along = Double(q[k])
    for i in 0..<q.count { v[i] -= along * Double(q[i]) }
    let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    let side = Double((1 - a * a).squareRoot())
    return (0..<q.count).map { Float(Double(a) * Double(q[$0]) + side * v[$0] / length) }
}

// What the person types: no stored word of the first index holds it, so it only matches the file added later.
private let icText = "harbour lantern"
private let icNewWords = "the harbour lantern at night"
private let icNewDot: Float = 0.99     // above g1's .95, so the new file leads the ranked list

private struct ICNewFile {
    let path: String
    let dot: Double
    let passageID: Int64
    var hit: SPHit { SPHit(path: path, passageID: passageID) }
}

// The helper's commit, as the app sees it: one more done photo, one picture passage with a vector and words.
// Opened and closed here, like the helper's own writer; the pipeline's reader stays open across it.
private func icAddPhoto(_ path: String, inode: Int64, axis: Int, for text: String) throws -> ICNewFile {
    let query = try FakeEmbedder().embed(text, role: .query)
    let store = try IndexStore()
    defer { store.close() }
    let file = try store.addFile(path: path, kind: "photo", size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                 inode: inode, device: 16_777_220, status: "done")
    _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                             vector: nil, name: "late arrival", body: "")
    let vector = icVector(query, dot: icNewDot, axis: axis)
    let id = try store.addPassage(fileID: file, source: "image", start: 0, end: 0, modality: "image",
                                  vector: vector, name: "", body: icNewWords)
    return ICNewFile(path: path, dot: icDot(vector, query), passageID: id)
}

private let icNew1 = "/photos/a/f000001.jpg"
private let icNew2 = "/photos/a/f000002.jpg"

// One search, waited for. Returns the keyword and ranked lists and the ticket.
@MainActor
private func icSearch(_ h: SPHarness, _ text: String = icText) async -> (keyword: [SPHit], ranked: [SPHit], ticket: Int, arrived: Bool) {
    let ticket = h.submit(text)
    let arrived = await spEventually { h.log.rankedList(ticket) != nil }
    return (h.log.keywordList(ticket) ?? [], h.log.rankedList(ticket) ?? [], ticket, arrived)
}

extension ModelDownloadTests {
    @Suite("SearchPipelineIndexChangeTests", .serialized)
    struct SearchPipelineIndexChangeTests {

        // MARK: (1) a photo read after the first search

        @MainActor
        @Test func aPhotoAddedAfterTheFirstSearchIsNotFoundUntilIndexChangedAndThenIsInBothLists() async throws {
            try await spWithPipeline(text: icText) { h in
                let fixture = try #require(h.fixture)
                h.clock.set(1000)
                let first = await icSearch(h)
                #expect(first.arrived)
                #expect(first.keyword == [])
                #expect(first.ranked == fixture.bestFirst)
                #expect(h.search.matrixLoaded == true)

                // the helper reads the photo and commits; the pipeline has not been told
                let added = try icAddPhoto(icNew1, inode: 9001, axis: 110, for: icText)
                #expect(added.dot > 0.98 && added.dot < 1.0, "the test's own vector is wrong: dot \(added.dot)")

                h.clock.set(1001)
                let before = await icSearch(h)
                #expect(before.arrived)
                // (the keyword list may already hold it: it is read from the index at each search; not pinned either way)
                #expect(!before.ranked.contains { $0.path == icNew1 }, "found before indexChanged(): \(before.ranked.map(\.path))")
                #expect(h.pipeline.reloadCount == 0)

                // the helper says `changed`
                h.pipeline.indexChanged()
                h.clock.set(1002)
                let after = await icSearch(h)
                #expect(after.arrived)
                #expect(after.keyword == [added.hit], "keyword list after indexChanged(): \(after.keyword)")
                #expect(after.ranked == [added.hit] + fixture.bestFirst,
                        "ranked list after indexChanged(): \(after.ranked.map(\.path))")
                #expect(h.pipeline.reloadCount == 1)
                #expect(h.search.matrixLoaded == true)
            }
        }

        // MARK: (2) at most one reload per 2 seconds

        @MainActor
        @Test func twoIndexChangedWithinTwoSecondsCauseOneReloadAndASearchWithNothingNewDoesNotReloadAgain() async throws {
            try await spWithPipeline(text: icText) { h in
                h.clock.set(1000)
                _ = await icSearch(h)
                _ = try icAddPhoto(icNew1, inode: 9001, axis: 110, for: icText)

                h.pipeline.indexChanged()
                h.pipeline.indexChanged()
                h.clock.set(1000.5)
                let second = await icSearch(h)
                #expect(second.arrived)
                #expect(h.pipeline.reloadCount == 1, "two changes before one search: \(h.pipeline.reloadCount) reloads")

                // nothing changed since: another search does not reload
                h.clock.set(1001)
                _ = await icSearch(h)
                #expect(h.pipeline.reloadCount == 1)
                h.clock.set(1010)
                _ = await icSearch(h)
                #expect(h.pipeline.reloadCount == 1, "a search with nothing changed reloaded")
            }
        }

        @MainActor
        @Test func aChangeThatArrivesLessThanTwoSecondsAfterAReloadWaitsAndIsNotLost() async throws {
            try await spWithPipeline(text: icText) { h in
                let fixture = try #require(h.fixture)
                h.clock.set(1000)
                _ = await icSearch(h)

                let first = try icAddPhoto(icNew1, inode: 9001, axis: 110, for: icText)
                h.pipeline.indexChanged()
                h.clock.set(1000)
                let reloaded = await icSearch(h)           // reload number 1, at t = 1000
                #expect(h.pipeline.reloadCount == 1)
                #expect(reloaded.keyword == [first.hit])

                // a second file, one `changed` per file: 1.9 s after the reload it is held back
                let second = try icAddPhoto(icNew2, inode: 9002, axis: 111, for: icText)
                h.pipeline.indexChanged()
                h.clock.set(1001.9)
                let held = await icSearch(h)
                #expect(h.pipeline.reloadCount == 1, "a second reload within 2 s: \(h.pipeline.reloadCount)")
                #expect(!held.ranked.contains { $0.path == icNew2 }, "held ranked list: \(held.ranked.map(\.path))")
                #expect(held.ranked.first == first.hit, "held ranked list: \(held.ranked.map(\.path))")

                // still stale: the next search 2 s after the reload picks it up
                h.clock.set(1002)
                let later = await icSearch(h)
                #expect(h.pipeline.reloadCount == 2, "the held change was lost: \(h.pipeline.reloadCount) reloads")
                #expect(Set(later.keyword.map(\.path)) == [icNew1, icNew2], "keyword list: \(later.keyword.map(\.path))")
                #expect(Set(later.ranked.map(\.path)) == Set(fixture.bestFirst.map(\.path) + [icNew1, icNew2]),
                        "ranked list: \(later.ranked.map(\.path))")
                #expect(later.ranked.contains(second.hit))
            }
        }

        @MainActor
        @Test func aChangeForEveryFileOverTenSecondsCausesAtMostOneReloadPerTwoSeconds() async throws {
            try await spWithPipeline(text: icText) { h in
                h.clock.set(1000)
                _ = await icSearch(h)
                // ten files, one `changed` each, one search after each, 1 s apart: t = 1001 ... 1010
                var inode: Int64 = 9000
                for step in 1...10 {
                    inode += 1
                    _ = try icAddPhoto("/photos/a/f\(String(format: "%06d", step)).jpg", inode: inode, axis: 110 + step, for: icText)
                    h.pipeline.indexChanged()
                    h.clock.set(1000 + Double(step))
                    _ = await icSearch(h)
                }
                // reloads can only fall at 1001, 1003, 1005, 1007, 1009 (first is never held back): 5, never 10
                #expect(h.pipeline.reloadCount == 5, "reloads: \(h.pipeline.reloadCount)")
            }
        }

        // MARK: (3) no change, no reload

        @MainActor
        @Test func withoutIndexChangedNoSearchReloadsAndANewFileStaysUnfound() async throws {
            try await spWithPipeline(text: icText) { h in
                h.clock.set(1000)
                _ = await icSearch(h)
                _ = try icAddPhoto(icNew1, inode: 9001, axis: 110, for: icText)
                for second in [1001.0, 1005.0, 1030.0] {
                    h.clock.set(second)
                    let result = await icSearch(h)
                    #expect(result.arrived)
                    #expect(!result.ranked.contains { $0.path == icNew1 }, "found without indexChanged(): at \(second)")
                    #expect(h.pipeline.reloadCount == 0, "reloaded at \(second) with nothing changed")
                    #expect(h.search.matrixLoaded == true)
                }
            }
        }

        // MARK: (4) after release()

        @MainActor
        @Test func aSearchAfterTheIdleReleaseLoadsFreshAndFindsAFileWrittenSinceWithoutIndexChanged() async throws {
            try await spWithPipeline(text: icText) { h in
                h.clock.set(1000)
                _ = await icSearch(h)
                let added = try icAddPhoto(icNew1, inode: 9001, axis: 110, for: icText)

                h.clock.set(1060)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == false)

                h.clock.set(1061)
                let result = await icSearch(h)
                #expect(h.search.matrixLoaded == true)
                #expect(result.keyword == [added.hit], "keyword list: \(result.keyword)")
                #expect(result.ranked.first == added.hit, "ranked list: \(result.ranked.map(\.path))")
            }
        }

        @MainActor
        @Test func indexChangedBeforeAReleaseOrBeforeTheFirstSearchIsHarmlessAndTheNextSearchIsFresh() async throws {
            try await spWithPipeline(text: icText) { h in
                let fixture = try #require(h.fixture)
                // before any search: nothing is loaded, nothing to reload
                h.pipeline.indexChanged()
                h.clock.set(1000)
                let first = await icSearch(h)
                #expect(first.ranked == fixture.bestFirst)
                #expect(h.pipeline.reloadCount == 0, "the first load was counted as a reload")

                // stale, then released, then a file arrives: the load that follows includes it, is not a reload,
                // and leaves no stale mark behind
                h.pipeline.indexChanged()
                h.clock.set(1060)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == false)
                let added = try icAddPhoto(icNew1, inode: 9001, axis: 110, for: icText)
                h.clock.set(1061)
                let fresh = await icSearch(h)
                #expect(fresh.ranked.first == added.hit, "ranked list: \(fresh.ranked.map(\.path))")
                #expect(h.pipeline.reloadCount == 0, "a load after release() was counted as a reload")

                h.clock.set(1070)
                _ = await icSearch(h)
                #expect(h.pipeline.reloadCount == 0, "a stale mark survived the release")
            }
        }

        // MARK: (5) the 60 s release is unchanged

        @MainActor
        @Test func theSixtySecondReleaseStillCountsFromTheLastSearchAndAReloadDoesNotRestartIt() async throws {
            try await spWithPipeline(text: icText) { h in
                h.clock.set(1000)
                _ = await icSearch(h)
                _ = try icAddPhoto(icNew1, inode: 9001, axis: 110, for: icText)
                h.pipeline.indexChanged()

                h.clock.set(1003)
                _ = await icSearch(h)                       // reloads; the last search is at 1003
                #expect(h.pipeline.reloadCount == 1)

                h.clock.set(1062.9)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == true, "released before 60 s after the last search")

                h.clock.set(1063)
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == false, "not released 60 s after the last search")

                // and indexChanged() itself is not a search: it does not push the release back
                h.clock.set(1100)
                _ = await icSearch(h)
                h.pipeline.indexChanged()
                h.clock.set(1159.9)
                h.pipeline.indexChanged()
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == true)
                h.clock.set(1160)
                h.pipeline.indexChanged()
                h.pipeline.tick()
                #expect(h.search.matrixLoaded == false, "indexChanged() restarted the idle count")
            }
        }
    }
}

// MARK: the panel wiring, as pure logic

@Suite("HelperEventRelayRouteTests")
struct HelperEventRelayRouteTests {

    private func count(_ event: HelperEvent) -> Int {
        var calls = 0
        HelperEventRelay.route(event, onIndexChanged: { calls += 1 })
        return calls
    }

    @Test func aChangedEventFromTheIndexHelperTellsThePipelineExactlyOnce() {
        #expect(count(.changed) == 1)
    }

    @Test func everyOtherEventLeavesThePipelineAlone() {
        #expect(count(.walked) == 0)
        #expect(count(.unit(size: 3)) == 0)
        #expect(count(.vector(id: 1, ms: 5, vec: [0.5, 0.5])) == 0)
        #expect(count(.refused(id: 2, reason: "busy")) == 0)
    }

    @Test func eachChangedEventIsOneCallSoTheRateLimitLivesInThePipelineNotTheRelay() {
        var calls = 0
        for _ in 0..<5 { HelperEventRelay.route(.changed, onIndexChanged: { calls += 1 }) }
        #expect(calls == 5)
    }
}
