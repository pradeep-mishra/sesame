import Foundation
import Testing
import SesameEngine
@testable import SesameHelper

// plan-2 fix round A, tester step: items A1 (S7.12, S7.10) and A7 (S7.12). Written from the fix-round entries A1 and A7,
// the reviewer's report (the two findings) and design sections 1 and 8 only. Product source read: none for this file
// (the existing types used are `IndexStore.addFile`, `pendingPhotos(limit:)`, `beginAttempt`, `completePhoto`,
// `IndexStore.PendingPhoto.path` and `Watchdog(store:interval:footprint:exit:)`, `watch`, `sample`, all pinned by sealed
// tests).
//
// THE PROBLEM. In the real-model path one unit is up to 16 files and `beginAttempt` marks ALL of them before the first read,
// so a death during the read of file 3 spends a try on 16 files (A1). The watchdog watches the same whole unit and blames
// all of it for a preview render's memory spike (A7). No test runs the real model, so the rule "which files of the unit are
// in the call that is running" moves into one pure function that the fake path and the model path both call, and the
// watchdog is given the same answer.
//
// SHAPE THESE TESTS PIN (new names, in the SesameHelper module, reached with `@testable import SesameHelper`; any file in
// Sources/SesameHelper is fine; if a shape is wrong, ask for a test change rather than guessing):
//
//     enum UnitStep: Equatable, Sendable {
//         case read(Int)        // the read (decode, text recognition) of unit[index] is the call in flight
//         case embed([Int])     // one embed call is in flight, holding the inputs of unit[indices]
//         case preview          // a preview render runs between steps (pollInput)
//         case stopping         // stdin ended, Quit, reset, the app is gone, the idle exit: nothing is in flight
//     }
//     func filesInFlight(_ unit: [IndexStore.PendingPhoto], at step: UnitStep) -> [IndexStore.PendingPhoto]
//
// The rule (every expected value below is written by hand from it):
//   .read(i)        the one file unit[i]
//   .embed(indices) exactly the files unit[j] for the j in indices (no file twice, an index outside the unit ignored); the
//                   order of the answer is not pinned
//   .preview        none (A7: the watch is cleared and the unit's work is not blamed while a preview renders)
//   .stopping       none (A1: a stop spends no try)
// The same list is what `beginAttempt` marks for the step (A1) and what `Watchdog.watch` is given for the step (A7). The
// helper calls it for every step of a unit in the fake path and in the model path; that wiring cannot be seen from outside
// without the model, so the reviewer of the fix checks Sources/SesameHelper/Index.swift for it (the line
// `unitMarks = isFake ? [] : Array(files)` must be gone).
//
// Red today: none of these compiles, because `UnitStep` and `filesInFlight` do not exist.

private let upDevice: Int64 = 16_777_220

private func upAddPending(_ store: IndexStore, count: Int) throws {
    for number in 1...count {
        _ = try store.addFile(path: "/photos/u-\(String(format: "%04d", number)).jpg", kind: "photo",
                              size: Int64(2000 + number), mtimeNs: 1_700_000_000_000_000_000 + Int64(number) * 1_000_000_000,
                              inode: Int64(5000 + number), device: upDevice, status: "pending")
    }
}

private func upVector(_ phase: Double) -> [Float] {
    (0..<768).map { Float(sin(Double($0) * 0.37 + phase) * 0.9) }
}

private func upIndexPath(_ t: TempHome) -> String {
    t.folder.appendingPathComponent("index.sqlite").path
}

private func upRows(_ t: TempHome) -> [String: AtRow] {
    AtDB(path: upIndexPath(t)).flatMap(atRows) ?? [:]
}

/// The unit as the helper takes it: the 16 newest pending photos, in the order `pendingPhotos` gives them.
private func upUnit(_ store: IndexStore, size: Int = 16) throws -> [IndexStore.PendingPhoto] {
    let all = try store.pendingPhotos(limit: 50)
    try #require(all.count >= size, "setup: pendingPhotos listed \(all.count) files, expected at least \(size)")
    return Array(all.prefix(size))
}

private func upNames(_ files: [IndexStore.PendingPhoto]) -> Set<String> {
    Set(files.map { ($0.path as NSString).lastPathComponent })
}

extension EncodeHelperTests {
@Suite("IndexUnitMarkPolicyTests", .serialized)
struct IndexUnitMarkPolicyTests {

    // MARK: the rule, by hand

    @Test func aReadStepIsTheOneFileBeingRead() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 20)
            let unit = try upUnit(store)
            for index in [0, 2, 15] {
                let flying = filesInFlight(unit, at: .read(index))
                #expect(flying.count == 1 && upNames(flying) == upNames([unit[index]]),
                        "read(\(index)): the file in flight is unit[\(index)] alone, got \(upNames(flying).sorted())")
            }
        }
    }

    @Test func anEmbedStepIsExactlyTheFilesWhoseInputsAreInTheCall() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 20)
            let unit = try upUnit(store)

            let whole = filesInFlight(unit, at: .embed(Array(0..<16)))
            #expect(whole.count == 16 && upNames(whole) == upNames(unit), "an embed over all 16 inputs has all 16 in flight, got \(whole.count)")

            let some = filesInFlight(unit, at: .embed([3, 4, 9]))
            #expect(some.count == 3 && upNames(some) == upNames([unit[3], unit[4], unit[9]]),
                    "embed([3, 4, 9]): got \(upNames(some).sorted())")

            let single = filesInFlight(unit, at: .embed([7]))
            #expect(single.count == 1 && upNames(single) == upNames([unit[7]]), "embed([7]): got \(upNames(single).sorted())")

            let repeated = filesInFlight(unit, at: .embed([5, 5, 2, 5]))
            #expect(repeated.count == 2 && upNames(repeated) == upNames([unit[2], unit[5]]),
                    "a file named twice in the call is one file in flight, got \(repeated.count): \(upNames(repeated).sorted())")

            let none = filesInFlight(unit, at: .embed([]))
            #expect(none.isEmpty, "an embed with no inputs has no file in flight, got \(upNames(none).sorted())")
        }
    }

    @Test func anIndexOutsideTheUnitIsIgnoredAndNeverMarksAnotherFile() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 20)
            let unit = try upUnit(store, size: 5)
            #expect(filesInFlight(unit, at: .read(5)).isEmpty, "read(5) of a unit of 5 marked a file")
            #expect(filesInFlight(unit, at: .read(-1)).isEmpty, "read(-1) marked a file")
            #expect(filesInFlight(unit, at: .read(99)).isEmpty, "read(99) marked a file")
            let mixed = filesInFlight(unit, at: .embed([-1, 1, 5, 40]))
            #expect(mixed.count == 1 && upNames(mixed) == upNames([unit[1]]), "embed([-1, 1, 5, 40]) of a unit of 5: got \(upNames(mixed).sorted())")
            #expect(filesInFlight([], at: .read(0)).isEmpty, "an empty unit has no file in flight")
        }
    }

    @Test func aStopAndAPreviewHaveNoFileInFlight() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 20)
            let unit = try upUnit(store)
            #expect(filesInFlight(unit, at: .stopping).isEmpty, "a stop has files in flight: \(upNames(filesInFlight(unit, at: .stopping)).sorted())")
            #expect(filesInFlight(unit, at: .preview).isEmpty, "a preview render has files in flight: \(upNames(filesInFlight(unit, at: .preview)).sorted())")
        }
    }

    // MARK: A1, through a real store: 16 queued files, a death at the third file's read

    // The helper's loop for one unit, written the way the entry describes it: before each step the files in flight get the
    // marker (`beginAttempt`), a finished read writes the file (`completePhoto`, which puts the marker back). A death at the
    // third file's read leaves a marker on that file only; the two files before it are done and the thirteen after it were
    // never touched.
    @Test func sixteenQueuedFilesADeathAtTheThirdFilesReadSpendsATryOnThatFileOnly() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 16)
            let unit = try upUnit(store)
            #expect(unit.count == 16)

            for index in 0..<16 {
                try store.beginAttempt(filesInFlight(unit, at: .read(index)))
                if index == 2 { break }                       // the helper dies here: the read of the third file is running
                #expect(try store.completePhoto(unit[index], nameWords: "word\(index)", ocrText: "", vector: upVector(Double(index))),
                        "completePhoto of unit[\(index)] changed nothing")
            }

            let rows = upRows(t)
            let marked = rows.values.filter { $0.tries > 0 }.map { "\($0.name) tries \($0.tries)" }.sorted()
            let thirdName = (unit[2].path as NSString).lastPathComponent
            #expect(marked == ["\(thirdName) tries 1"], "after a death at the third file's read the files with a marker are \(marked), expected only \(thirdName) with tries 1; rows \(atDescribe(rows))")
            #expect(rows.values.filter { $0.status == "done" }.count == 2, "two files were written before the death: \(atDescribe(rows))")
            #expect(rows.values.filter { $0.status == "pending" && $0.tries == 0 }.count == 13,
                    "thirteen files were only queued and must have tries 0: \(atDescribe(rows))")
        }
    }

    @Test func aDeathDuringAnEmbedCallSpendsATryOnTheFilesInThatCallAndNoOther() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 16)
            let unit = try upUnit(store)

            // all 16 reads finished (nothing is written before the embed), then the embed over files 4 to 7 runs and the helper dies
            try store.beginAttempt(filesInFlight(unit, at: .embed([4, 5, 6, 7])))
            let rows = upRows(t)
            let marked = Set(rows.values.filter { $0.tries == 1 }.map(\.name))
            #expect(marked == upNames([unit[4], unit[5], unit[6], unit[7]]),
                    "the files with a marker are \(marked.sorted()), expected the four whose inputs were in the call")
            #expect(rows.values.allSatisfy { $0.tries <= 1 }, "a file has more than one try: \(atDescribe(rows))")
        }
    }

    @Test func aSecondDeathOnTheSameFileMakesTriesTwoAndNeverTouchesItsNeighbours() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 16)
            let unit = try upUnit(store)
            // run 1 and run 2 both die while reading unit[2]; the files before it were written in run 1
            for index in 0...2 {
                try store.beginAttempt(filesInFlight(unit, at: .read(index)))
                if index < 2 { _ = try store.completePhoto(unit[index], nameWords: "w\(index)", ocrText: "", vector: upVector(Double(index))) }
            }
            try store.beginAttempt(filesInFlight(unit, at: .read(2)))
            let rows = upRows(t)
            let thirdName = (unit[2].path as NSString).lastPathComponent
            #expect(rows[thirdName]?.tries == 2, "the file that died twice has tries \(rows[thirdName]?.tries ?? -1), expected 2")
            #expect(rows.filter { $0.key != thirdName }.values.allSatisfy { $0.tries == 0 }, "a neighbour holds a try: \(atDescribe(rows))")
        }
    }

    // MARK: A1, a clean stop marks none

    @Test func aCleanStopBetweenReadsMarksNothingAndLeavesNoMarker() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 16)
            let unit = try upUnit(store)
            for index in 0..<2 {
                try store.beginAttempt(filesInFlight(unit, at: .read(index)))
                _ = try store.completePhoto(unit[index], nameWords: "w\(index)", ocrText: "", vector: upVector(Double(index)))
            }
            // stdin ends: the helper marks nothing for the stop and puts nothing back (nothing is outstanding)
            try store.beginAttempt(filesInFlight(unit, at: .stopping))
            let rows = upRows(t)
            #expect(rows.values.allSatisfy { $0.tries == 0 }, "a clean stop left a marker: \(atDescribe(rows))")
            #expect(rows.values.filter { $0.status == "done" }.count == 2, "the two finished files are not done: \(atDescribe(rows))")
        }
    }

    // MARK: A7, a trip during a preview render blames nobody

    @Test func aWatchdogTripDuringAPreviewStepLeavesEveryRowOfTheUnitUntouched() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 16)
            let unit = try upUnit(store)
            // the unit is mid-way: file 0 is written, file 1 is read, and a preview request is polled before file 2
            _ = try store.completePhoto(unit[0], nameWords: "w0", ocrText: "", vector: upVector(0))
            let before = upRows(t)

            let dog = Watchdog(store: store, footprint: { Watchdog.capBytes + 100_000_000 }, exit: {})
            dog.watch(filesInFlight(unit, at: .preview))
            dog.sample()                                      // the render's memory spike: the footprint is over the cap
            let after = upRows(t)
            #expect(after.mapValues { "\($0.status)|\($0.reason ?? "nil")|\($0.tries)" } == before.mapValues { "\($0.status)|\($0.reason ?? "nil")|\($0.tries)" },
                    "a trip during a preview changed rows: before \(atDescribe(before)); after \(atDescribe(after))")
            #expect(after.values.allSatisfy { $0.reason == nil }, "a file was given a hint during a preview: \(atDescribe(after))")
        }
    }

    // The control: the same footprint while one file's read is in flight blames that file alone (the entry's first-trip rule),
    // never its 15 queued neighbours.
    @Test func aWatchdogTripDuringOneFilesReadBlamesThatFileAlone() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 16)
            let unit = try upUnit(store)
            try store.beginAttempt(filesInFlight(unit, at: .read(2)))

            let dog = Watchdog(store: store, footprint: { Watchdog.capBytes }, exit: {})
            dog.watch(filesInFlight(unit, at: .read(2)))
            dog.sample()

            let rows = upRows(t)
            let thirdName = (unit[2].path as NSString).lastPathComponent
            #expect(rows[thirdName]?.reason == IndexStore.soloHint && rows[thirdName]?.tries == 0,
                    "the file in flight should hold hint:solo and tries 0, rows \(atDescribe(rows))")
            #expect(rows.filter { $0.key != thirdName }.values.allSatisfy { $0.reason == nil && $0.tries == 0 },
                    "a queued neighbour was blamed: \(atDescribe(rows))")
        }
    }

    // MARK: plan-2 fix round D, tester step, item D3 (R3-03): the model load is a step with no file in flight
    //
    // Written from the fix-round document D3 ("the helper calls `settle(.stopping)` (puts markers back and clears the watchdog
    // watch) before the model is loaded, so a death or Quit-kill during model load spends no try on the last-read file; add a
    // `UnitStep` case or reuse `.stopping` and pin it in the policy tests (`filesInFlight` for a load step gives no file)") and
    // the review report (R3-03: `Index.swift:301` runs `PhotoEmbedder(...)` before the first `.inFlight`, while `marked` and the
    // watchdog watch still hold the last-read file of the unit). No product source was read.
    //
    // SHAPE D3 pins (new): `UnitStep` gains `case modelLoad`: the (lazy) model load of a unit, which runs after the reads of
    // the unit and before its first embed call. The rule, by hand: `.modelLoad` has NO file in flight, like `.stopping` and
    // `.preview`, whatever the unit holds and whatever file was read last. The helper takes `filesInFlight(unit, at:
    // .modelLoad)` for the marks and the watchdog watch before it loads the model; that wiring cannot be seen without the real
    // model (a death inside the load is not reproducible from outside), so the reviewer of the fix reads
    // Sources/SesameHelper/Index.swift for the `settle` call before `PhotoEmbedder(...)`. `.stopping` is kept as it is: the
    // fixer must not reuse it for this, the new case is pinned by name.

    @Test func aModelLoadStepHasNoFileInFlightWhateverTheUnitHolds() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 20)
            for size in [1, 5, 16] {
                let unit = try upUnit(store, size: size)
                let flying = filesInFlight(unit, at: .modelLoad)
                #expect(flying.isEmpty, "a unit of \(size): the model load has files in flight: \(upNames(flying).sorted())")
            }
            #expect(filesInFlight([], at: .modelLoad).isEmpty, "an empty unit has a file in flight at the model load")
            #expect(UnitStep.modelLoad != UnitStep.stopping && UnitStep.modelLoad != UnitStep.preview, "the model load is not a step of its own")
        }
    }

    // The step before and after: the last read of the unit is the one file in flight, the load that follows is none, and the
    // first embed call that follows holds exactly its inputs. The marks and the watch given for each step are these lists.
    @Test func betweenTheLastReadAndTheFirstEmbedCallTheModelLoadBlamesNoFile() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 16)
            let unit = try upUnit(store)
            let lastRead = filesInFlight(unit, at: .read(15))
            #expect(lastRead.count == 1 && upNames(lastRead) == upNames([unit[15]]), "the last read is unit[15] alone")
            #expect(filesInFlight(unit, at: .modelLoad).isEmpty, "the load right after the last read still has a file in flight")
            let firstEmbed = filesInFlight(unit, at: .embed(Array(0..<16)))
            #expect(upNames(firstEmbed) == upNames(unit), "the first embed call holds the 16 inputs")
        }
    }

    // A trip during the load blames nobody: the watch is what `filesInFlight` gives for the step, which is empty (A7's rule
    // for a preview, now for the load). The control above blames a file when one is in flight.
    @Test func aWatchdogTripDuringTheModelLoadLeavesEveryRowOfTheUnitUntouched() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try upAddPending(store, count: 16)
            let unit = try upUnit(store)
            let before = upRows(t)

            let dog = Watchdog(store: store, footprint: { Watchdog.capBytes + 100_000_000 }, exit: {})
            dog.watch(filesInFlight(unit, at: .read(15)))
            dog.watch(filesInFlight(unit, at: .modelLoad))      // the load starts: the watch is replaced by nothing
            dog.sample()                                         // the load's memory spike: the footprint is over the cap
            let after = upRows(t)
            #expect(after.mapValues { "\($0.status)|\($0.reason ?? "nil")|\($0.tries)" } == before.mapValues { "\($0.status)|\($0.reason ?? "nil")|\($0.tries)" },
                    "a trip during the model load changed rows: before \(atDescribe(before)); after \(atDescribe(after))")
            #expect(after.values.allSatisfy { $0.reason == nil }, "a file was given a hint during the model load: \(atDescribe(after))")
        }
    }
}
}
