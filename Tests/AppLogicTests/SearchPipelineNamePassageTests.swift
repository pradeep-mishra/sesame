import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1 review round B (app), tester step: findings F5 and F6 (the app side). The keyword path of `SearchPipeline` maps
// passage ids to files by loading every vector a second time (`IndexReader.vectoredPassages()`), only to build an id-to-
// path map. Measured in the review at 50,000 vectors: 228 ms, rss 9 to 117 MB, repeated at every matrix reload. And a
// passage with no vector (a file NAME) leads to no file that way, so a word from a file's name is not found by the
// keyword list (F5: "typing a string from a screenshot's text shows the file, then it vanishes"; names were the plan-2 gap).
// Written from the review report (F5, F6), the brief's acceptance line, design section 3 ("Searching": the keyword list is
// the exact-word match over the index's words, name and body) and the sealed SearchPipelineTests/IndexChangeTests only.
// Product source read for names and where the logic lives: Sources/Sesame/SearchPipeline.swift (`keywordHits`, `places`),
// Sources/SesameEngine/IndexReader.swift (`pathForPassage`, `keywordSearch`, `vectoredPassages`). The expected lists come
// from the words the tests write into the index.
//
// SUITE PLACEMENT. Nested in `ModelDownloadTests` with the other pipeline suites (HOME and the probe are process-wide).
// It reuses `spWithPipeline`, `SPHarness`, `spWriteIndex` and the fixture of SearchPipelineTests.swift:
//   g1 photo /photos/a/g1.jpg   name "harbour boats morning", words "red boats at the quiet pier"
//   g2 pdf   /photos/b/g2.pdf   name "ledger summary"
//   g4 pdf   /photos/b/g4.pdf   name "tenancy terms"
// Every name passage has no vector. No product API is added by these tests; they fail today on behaviour.
//
// WHAT THESE PIN
//   - A phrase that is in a file's NAME only gives that file in the keyword list (photo and pdf), one entry per file even
//     when the name and the words both hold the phrase.
//   - The panel's filters still apply to a name hit: a folder that is not ticked, and a kind that is switched off, hide it.
//     (These two pass today for a vacuous reason, because a name hit gives nothing at all; they are here so the fix cannot
//     open a hole.)
//   - A file written after the first search is found by its name at the next search with no `indexChanged()`, no reload
//     and no release. This is the observable half of "no id-to-path map built from `vectoredPassages()`": a map built
//     once per loaded matrix cannot hold a passage written later. (`keywordSearch` itself reads the live index; the
//     sealed IndexChange tests leave "the keyword list may already hold it" open, so this does not contradict them.)
//
// WHAT THESE CANNOT PIN: that `vectoredPassages()` is never called. `IndexReader` is a final class in the engine with no
// call counter or hook, and the test target may not change it. A reload counter does not see it either
// (`SearchPipeline.reloadCount` counts matrix reloads of `Search`, not this map). A reviewer reads the source for that, or
// the controller adds a counter to `IndexReader` as a later step.

@MainActor
private func npHits(_ h: SPHarness, _ text: String) async -> (keyword: [SPHit], ticket: Int, arrived: Bool) {
    let ticket = h.submit(text)
    // Wait for both lists so nothing of this search is still running when the harness closes the reader.
    let arrived = await spEventually { h.log.keywordList(ticket) != nil && h.log.rankedList(ticket) != nil }
    return (h.log.keywordList(ticket) ?? [], ticket, arrived)
}

private let npKinds: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]

extension ModelDownloadTests {
    @Suite("SearchPipelineNamePassageTests", .serialized)
    struct SearchPipelineNamePassageTests {

        @MainActor
        @Test func aWordFromAPhotosNameFindsThePhotoInTheKeywordList() async throws {
            try await spWithPipeline(text: "harbour boats") { h in
                let result = await npHits(h, "harbour boats")
                #expect(result.arrived, "no lists arrived; events: \(h.log.events)")
                #expect(result.keyword.map(\.path) == [spG1], "keyword list: \(result.keyword.map(\.path)), wanted the file whose name holds the phrase")
                if let hit = result.keyword.first {
                    #expect(h.reader.pathForPassage(hit.passageID) == spG1,
                            "the hit's passage \(hit.passageID) belongs to \(String(describing: h.reader.pathForPassage(hit.passageID)))")
                }
            }
        }

        @MainActor
        @Test func aWordFromAPdfsNameFindsThePdfInTheKeywordList() async throws {
            try await spWithPipeline(text: "ledger summary") { h in
                let result = await npHits(h, "ledger summary")
                #expect(result.arrived, "no lists arrived; events: \(h.log.events)")
                #expect(result.keyword.map(\.path) == [spG2], "keyword list: \(result.keyword.map(\.path))")
            }
        }

        @MainActor
        @Test func aFileWhoseNameAndWordsBothHoldTheTextIsListedOnce() async throws {
            // "boats" is in g1's name ("harbour boats morning") and in its words ("red boats at the quiet pier")
            try await spWithPipeline(text: "boats") { h in
                let result = await npHits(h, "boats")
                #expect(result.arrived, "no lists arrived; events: \(h.log.events)")
                #expect(result.keyword.map(\.path) == [spG1], "keyword list: \(result.keyword.map(\.path)), wanted g1 once")
            }
        }

        @MainActor
        @Test func aNameHitInAFolderThatIsNotTickedIsHidden() async throws {
            try await spWithPipeline(text: "ledger summary", visible: spVisible("/photos/a")) { h in
                let result = await npHits(h, "ledger summary")
                #expect(result.arrived, "no lists arrived; events: \(h.log.events)")
                #expect(result.keyword.isEmpty, "g2 is under /photos/b, which is not ticked: \(result.keyword.map(\.path))")
            }
        }

        @MainActor
        @Test func aNameHitOfAKindThatIsSwitchedOffIsHiddenAndTheOtherKindsStayVisible() async throws {
            var kinds = npKinds
            kinds["pdf"] = false
            let pdfOff = Visible(folders: [Settings.Folder(path: "/photos", code: false, reading: true)],
                                 codeSearchOn: true, kindsOn: kinds)
            try await spWithPipeline(text: "ledger summary", visible: pdfOff) { h in
                let hidden = await npHits(h, "ledger summary")
                #expect(hidden.arrived, "no lists arrived; events: \(h.log.events)")
                #expect(hidden.keyword.isEmpty, "pdf is switched off: \(hidden.keyword.map(\.path))")
                let shown = await npHits(h, "harbour boats")
                #expect(shown.arrived)
                #expect(shown.keyword.map(\.path) == [spG1], "photos are on: \(shown.keyword.map(\.path))")
            }
        }

        @MainActor
        @Test func aFileWrittenAfterTheFirstSearchIsFoundByItsNameAtTheNextSearchWithNoReload() async throws {
            try await spWithPipeline(text: "harbour boats") { h in
                let first = await npHits(h, "harbour boats")
                #expect(first.arrived)
                #expect(first.keyword.map(\.path) == [spG1], "setup: the first search should find g1 by its name; got \(first.keyword.map(\.path))")

                // The index helper commits a new photo; nobody tells the pipeline.
                let added = "/photos/a/new-lighthouse.jpg"
                do {
                    let store = try IndexStore()
                    defer { store.close() }
                    let file = try store.addFile(path: added, kind: "photo", size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                                 inode: 9001, device: 16_777_220, status: "done")
                    _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                                             vector: nil, name: "lighthouse keeper", body: "")
                }

                let second = await npHits(h, "lighthouse keeper")
                #expect(second.arrived)
                #expect(second.keyword.map(\.path) == [added],
                        "keyword list: \(second.keyword.map(\.path)); a name written after the first search must be found without a reload")
                #expect(h.pipeline.reloadCount == 0, "a reload happened: \(h.pipeline.reloadCount)")
            }
        }
    }
}
