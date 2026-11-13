import Foundation
import Testing
import SesameEngine

// plan-5-t5, tester step. Written from the entry plan-5-t5 of plan-5-tasks.md (Tests, the sentence on `passageSpot`), Decision D6 and the
// sealed IndexReaderCountsTests (the style of the read-only calls) only; no product source is read. plan-4-t8 is parked and its tester has
// not run, so this file is created here with the audio, frame, page and chunk cases of the entry; the parked plan-4-t8 tester extends it
// and keeps these cases.
//
// THE SHAPE THESE TESTS PIN (new API; today it does not exist, so this file does not compile until it does):
//
//     public struct PassageSpot { public let source: String; public let start: <number>; public let end: <number> }
//     IndexReader.passageSpot(_ id: Int64) -> PassageSpot?      // never throws; nil for an id nobody has and while there is no index file
//
//   - `source` is the passage's `source` word as stored: "audio", "frame", "page", "chunk".
//   - `start` and `end` are what the passage stored, with no conversion: an audio window's whole seconds, a frame's second (start == end),
//     a page's page number (start == end), a chunk's character offsets. The tests read them as `Double(spot.start)`, so Int or Double both
//     compile (the entry fixes the names `source`, `start`, `end` only; the number type is the implementer's pick).
//   - Like every IndexReader call: the open is tried again on each call, so rows show up once the store has made the file.
// What is NOT pinned: the spot of a `name` passage (nil or source "name", start 0), because the entry does not say.

private func psAddFile(_ store: IndexStore, _ path: String, kind: String, inode: Int64) throws -> Int64 {
    try store.addFile(path: path, kind: kind, size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode, device: 1, status: "done")
}

private func psUnit(_ axis: Int) -> [Float] {
    var vector = [Float](repeating: 0, count: 768)
    vector[axis] = 1
    return vector
}

private func psAdd(_ store: IndexStore, _ file: Int64, source: String, start: Double, end: Double, modality: String, axis: Int) throws -> Int64 {
    try store.addPassage(fileID: file, source: source, start: start, end: end, modality: modality, vector: psUnit(axis), name: "", body: "")
}

@Suite("PassageSpotTests")
struct PassageSpotTests {

    @Test func anAudioPassageGivesItsWindowStartAndEndSeconds() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let file = try psAddFile(store, "/m/interview.m4a", kind: "audio", inode: 1)
            _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: "interview m4a", body: "")
            let early = try psAdd(store, file, source: "audio", start: 25, end: 55, modality: "audio", axis: 0)
            let late = try psAdd(store, file, source: "audio", start: 130, end: 160, modality: "audio", axis: 1)
            let shorter = try psAdd(store, file, source: "audio", start: 205, end: 220, modality: "audio", axis: 2)

            let reader = IndexReader()
            defer { reader.close() }
            let first = try #require(reader.passageSpot(early), "no spot for the first window")
            #expect(first.source == "audio")
            #expect(Double(first.start) == 25 && Double(first.end) == 55, "start \(first.start), end \(first.end), wanted 25 and 55")
            let second = try #require(reader.passageSpot(late), "no spot for the second window")
            #expect(second.source == "audio")
            #expect(Double(second.start) == 130 && Double(second.end) == 160, "start \(second.start), end \(second.end), wanted 130 and 160")
            let last = try #require(reader.passageSpot(shorter), "no spot for the last, shorter window")
            #expect(Double(last.start) == 205 && Double(last.end) == 220, "start \(last.start), end \(last.end), wanted 205 and 220")
        }
    }

    @Test func aFramePassageGivesItsSecondAsStartAndEnd() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let file = try psAddFile(store, "/m/zebra.mp4", kind: "video", inode: 1)
            _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: "zebra mp4", body: "")
            let opening = try psAdd(store, file, source: "frame", start: 0, end: 0, modality: "image", axis: 0)
            let zebra = try psAdd(store, file, source: "frame", start: 42, end: 42, modality: "image", axis: 1)
            let soundtrack = try psAdd(store, file, source: "audio", start: 20, end: 50, modality: "audio", axis: 2)

            let reader = IndexReader()
            defer { reader.close() }
            let one = try #require(reader.passageSpot(opening))
            #expect(one.source == "frame" && Double(one.start) == 0 && Double(one.end) == 0, "got \(one.source) \(one.start) \(one.end)")
            let two = try #require(reader.passageSpot(zebra))
            #expect(two.source == "frame" && Double(two.start) == 42 && Double(two.end) == 42, "got \(two.source) \(two.start) \(two.end)")
            let three = try #require(reader.passageSpot(soundtrack), "no spot for the audio window of a video")
            #expect(three.source == "audio" && Double(three.start) == 20 && Double(three.end) == 50, "got \(three.source) \(three.start) \(three.end)")
        }
    }

    @Test func aPagePassageGivesItsPage() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let file = try psAddFile(store, "/d/lease.pdf", kind: "pdf", inode: 1)
            _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: "lease pdf", body: "")
            let first = try psAdd(store, file, source: "page", start: 1, end: 1, modality: "text", axis: 0)
            let seventh = try psAdd(store, file, source: "page", start: 7, end: 7, modality: "text", axis: 1)

            let reader = IndexReader()
            defer { reader.close() }
            let one = try #require(reader.passageSpot(first))
            #expect(one.source == "page" && Double(one.start) == 1 && Double(one.end) == 1, "got \(one.source) \(one.start) \(one.end)")
            let two = try #require(reader.passageSpot(seventh))
            #expect(two.source == "page" && Double(two.start) == 7 && Double(two.end) == 7, "got \(two.source) \(two.start) \(two.end)")
        }
    }

    @Test func aChunkPassageGivesItsOffsets() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let file = try psAddFile(store, "/d/notes.txt", kind: "doc", inode: 1)
            _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: "notes txt", body: "")
            let head = try psAdd(store, file, source: "chunk", start: 0, end: 480, modality: "text", axis: 0)
            let tail = try psAdd(store, file, source: "chunk", start: 480, end: 1_130, modality: "text", axis: 1)

            let reader = IndexReader()
            defer { reader.close() }
            let one = try #require(reader.passageSpot(head))
            #expect(one.source == "chunk" && Double(one.start) == 0 && Double(one.end) == 480, "got \(one.source) \(one.start) \(one.end)")
            let two = try #require(reader.passageSpot(tail))
            #expect(two.source == "chunk" && Double(two.start) == 480 && Double(two.end) == 1_130, "got \(two.source) \(two.start) \(two.end)")
        }
    }

    @Test func eachIdGivesTheSpotOfItsOwnPassageWhateverFileOrKindItBelongsTo() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let audio = try psAddFile(store, "/m/a.m4a", kind: "audio", inode: 1)
            let video = try psAddFile(store, "/m/v.mp4", kind: "video", inode: 2)
            let pdf = try psAddFile(store, "/d/p.pdf", kind: "pdf", inode: 3)
            let doc = try psAddFile(store, "/d/t.txt", kind: "doc", inode: 4)
            let ids = [
                try psAdd(store, doc, source: "chunk", start: 10, end: 90, modality: "text", axis: 0),
                try psAdd(store, pdf, source: "page", start: 3, end: 3, modality: "text", axis: 1),
                try psAdd(store, video, source: "frame", start: 9, end: 9, modality: "image", axis: 2),
                try psAdd(store, audio, source: "audio", start: 60, end: 90, modality: "audio", axis: 3),
                try psAdd(store, video, source: "audio", start: 75, end: 105, modality: "audio", axis: 4),
            ]
            let wanted: [(String, Double, Double)] = [("chunk", 10, 90), ("page", 3, 3), ("frame", 9, 9), ("audio", 60, 90), ("audio", 75, 105)]

            let reader = IndexReader()
            defer { reader.close() }
            for (id, expected) in zip(ids, wanted).reversed() {
                let spot = try #require(reader.passageSpot(id), "no spot for passage \(id)")
                #expect(spot.source == expected.0 && Double(spot.start) == expected.1 && Double(spot.end) == expected.2,
                        "passage \(id): got \(spot.source) \(spot.start) \(spot.end), wanted \(expected)")
            }
        }
    }

    @Test func anIdNobodyHasGivesNil() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let file = try psAddFile(store, "/m/a.m4a", kind: "audio", inode: 1)
            let known = try psAdd(store, file, source: "audio", start: 0, end: 30, modality: "audio", axis: 0)

            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.passageSpot(known) != nil, "setup: the known id has no spot")
            #expect(reader.passageSpot(known + 1_000) == nil, "an id nobody has gave a spot")
            #expect(reader.passageSpot(0) == nil)
            #expect(reader.passageSpot(-1) == nil)
        }
    }

    @Test func withNoIndexFileTheAnswerIsNilAndItDoesNotThrow() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.passageSpot(1) == nil)
            #expect(reader.passageSpot(1) == nil, "a second call with still no file")
        }
    }

    @Test func theSpotFollowsLaterWritesThroughTheSameReaderAndAfterClose() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.passageSpot(1) == nil, "no index file yet")

            let store = try IndexStore()
            defer { store.close() }
            let file = try psAddFile(store, "/m/a.m4a", kind: "audio", inode: 1)
            let first = try psAdd(store, file, source: "audio", start: 0, end: 30, modality: "audio", axis: 0)
            let one = try #require(reader.passageSpot(first), "a passage written after the first call was not found")
            #expect(Double(one.start) == 0 && Double(one.end) == 30)

            let second = try psAdd(store, file, source: "audio", start: 25, end: 55, modality: "audio", axis: 1)
            let two = try #require(reader.passageSpot(second))
            #expect(Double(two.start) == 25 && Double(two.end) == 55)

            reader.close()
            let again = try #require(reader.passageSpot(second), "after close() the next call opens it again")
            #expect(Double(again.start) == 25 && Double(again.end) == 55)
        }
    }

    // plan-6-t8 (the entry's `PassageSpotTests` extension): a `code` passage's start and end are its first and last line, with no conversion.

    @Test func aCodePassageGivesItsStartAndEndLine() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let file = try psAddFile(store, "/c/api-client/retry.swift", kind: "code", inode: 1)
            _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: "retry.swift", body: "")
            let first = try psAdd(store, file, source: "code", start: 1, end: 40, modality: "text", axis: 0)
            let second = try psAdd(store, file, source: "code", start: 41, end: 78, modality: "text", axis: 1)
            let last = try psAdd(store, file, source: "code", start: 79, end: 79, modality: "text", axis: 2)

            let reader = IndexReader()
            defer { reader.close() }
            let one = try #require(reader.passageSpot(first), "no spot for the first stretch")
            #expect(one.source == "code" && Double(one.start) == 1 && Double(one.end) == 40, "got \(one.source) \(one.start) \(one.end)")
            let two = try #require(reader.passageSpot(second), "no spot for the second stretch")
            #expect(two.source == "code" && Double(two.start) == 41 && Double(two.end) == 78, "got \(two.source) \(two.start) \(two.end)")
            let three = try #require(reader.passageSpot(last), "no spot for a one-line last stretch")
            #expect(three.source == "code" && Double(three.start) == 79 && Double(three.end) == 79, "got \(three.source) \(three.start) \(three.end)")
        }
    }

    @Test func eachCodeStretchOfSeveralFilesGivesItsOwnLinesAndOtherKindsAreUnchanged() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let swift = try psAddFile(store, "/c/a.swift", kind: "code", inode: 1)
            let python = try psAddFile(store, "/c/b.py", kind: "code", inode: 2)
            let doc = try psAddFile(store, "/d/t.txt", kind: "doc", inode: 3)
            let ids = [
                try psAdd(store, python, source: "code", start: 120, end: 150, modality: "text", axis: 0),
                try psAdd(store, doc, source: "chunk", start: 10, end: 90, modality: "text", axis: 1),
                try psAdd(store, swift, source: "code", start: 12, end: 40, modality: "text", axis: 2),
                try psAdd(store, python, source: "code", start: 3, end: 30, modality: "text", axis: 3),
            ]
            let wanted: [(String, Double, Double)] = [("code", 120, 150), ("chunk", 10, 90), ("code", 12, 40), ("code", 3, 30)]

            let reader = IndexReader()
            defer { reader.close() }
            for (id, expected) in zip(ids, wanted).reversed() {
                let spot = try #require(reader.passageSpot(id), "no spot for passage \(id)")
                #expect(spot.source == expected.0 && Double(spot.start) == expected.1 && Double(spot.end) == expected.2,
                        "passage \(id): got \(spot.source) \(spot.start) \(spot.end), wanted \(expected)")
            }
        }
    }

    @Test func anIdNobodyHasGivesNilBesideCodePassages() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let file = try psAddFile(store, "/c/a.swift", kind: "code", inode: 1)
            let known = try psAdd(store, file, source: "code", start: 12, end: 40, modality: "text", axis: 0)

            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.passageSpot(known) != nil, "setup: the known code stretch has no spot")
            #expect(reader.passageSpot(known + 1_000) == nil, "an id nobody has gave a spot")
            #expect(reader.passageSpot(0) == nil)
            #expect(reader.passageSpot(-1) == nil)
        }
    }
}
