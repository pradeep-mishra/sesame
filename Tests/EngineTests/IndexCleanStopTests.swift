import Foundation
import Testing

// plan-2-t33, tester step (carry-over F8). Written from the t33 entry, design sections 1, 3 and 9 and the Helper
// protocol table only; no product source read. The harness (`At...`) is in IndexAttemptTests.swift.
//
// What the entry fixes (expected values, none from the code under test): a stop from stdin ending, an idle exit, a
// requeue or a skipped, deferred or needs_permission file never leaves `tries` above 0; only a death does. After a
// clean stop the index is whole (`integrity_check` ok, every file all-new or all-old) and a second helper run over
// the same folder finishes the rest while the files that were already `done` keep their passage ids (none re-read).
//
// All of it through the bundled release helper (`SESAME_FAKE_EMBEDDER=1`, a throwaway HOME), which is warmed once per
// test process (120 s allowed). The index is read with the test's own read-only connection. Time is never asserted
// tightly: every wait has a generous cap.
//
// What a person can and cannot see here:
// - "a clean stop leaves no marker" is only meaningful if the helper DOES set a marker while it works, so the control
//   test below kills the helper instead and shows a marker left behind. Without the attempt marker that control is red.
// - `reset` deletes the index file, so a marker put back "first" by a reset cannot be read afterwards; reset is covered
//   by IndexResetTests (no index file is left) and is not repeated here.

private func atStoppedProblems(_ db: AtDB, tag: String) -> [String] {
    var problems: [String] = []
    let rows = atRows(db)
    let marked = (rows ?? [:]).values.filter { $0.tries != 0 }.map { "\($0.name) tries \($0.tries)" }.sorted()
    if !marked.isEmpty { problems.append("\(tag): rows with tries above 0 after a clean stop: \(marked)") }
    problems += atWholeProblems(db).map { "\(tag): \($0)" }
    return problems
}

extension EncodeHelperTests {
@Suite("IndexCleanStopTests", .serialized)
struct IndexCleanStopTests {

    // The entry's test: 40 photos, stdin ends after the K-th `changed` line, 30 seeded K. After each stop no row has
    // tries above 0, the index is whole, and a second run finishes the rest without reading the finished files again.
    @Test func endingStdinAfterTheKthChangedLineLeavesNoMarkerAWholeIndexAndTheNextRunReadsOnlyTheRest() throws {
        _ = atHelperWarm
        let seed = atSeed()
        print("SEED clean-stop=\(seed)")
        var rng = AtRNG(seed: seed)
        var stoppedEarly = 0
        for round in 1...30 {
            let k = Int.random(in: 1...30, using: &rng)
            if try cleanStopRound(round: round, k: k, seed: seed) { stoppedEarly += 1 }
        }
        // Not hollow: the stop must really come while files are still waiting in most rounds (a unit is at most 16 inputs).
        print("READING clean-stop rounds_stopped_with_work_left=\(stoppedEarly)/30 seed=\(seed)")
        #expect(stoppedEarly >= 8, "only \(stoppedEarly) of 30 stops came while files were still waiting, so the stops proved little (seed \(seed))")
    }

    /// One round. Returns true when the stop came before every file was done.
    private func cleanStopRound(round: Int, k: Int, seed: UInt64) throws -> Bool {
        let tag = "round \(round), K=\(k), seed \(seed)"
        let world = try AtWorld()
        defer { world.remove() }
        let names = atNames("cs", 1...40)
        try atMakePhotos(in: world.photos, names: names, seedBase: 0)

        let first = try atStartHelper(world)
        defer { first.stop() }
        let events = AtEvents(first)
        first.send(atFoldersLine([world.photos]))
        guard events.read(cap: 120, until: { events.changed >= k }) else {
            Issue.record("\(tag): the helper sent \(events.changed) `changed` lines and never the \(k)th; stderr: \(first.errors)")
            return false
        }
        let status = atCleanStop(first)
        #expect(status == 0, "\(tag): the helper did not exit 0 within 120 s of its stdin ending (status \(status.map(String.init) ?? "still running")); stderr: \(first.errors)")
        guard let db = world.db(), let rows = atRows(db), let ids = atPassageIDs(db) else {
            Issue.record("\(tag): the index cannot be read after the stop")
            return false
        }
        let problems = atStoppedProblems(db, tag: tag)
        #expect(problems.isEmpty, "\(problems)")
        let doneBefore = ids.filter { rows[$0.key]?.status == "done" }
        let early = doneBefore.count < 40

        // A second helper run over the same folder: finishes the rest, re-reads nothing that was done.
        let second = try atStartHelper(world)
        defer { second.stop() }
        second.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, second, stall: 60, cap: 240, until: { $0 == ["done": 40] })
        #expect(wait.met, "\(tag): the second run did not finish all 40 files: \(wait.statuses), stderr: \(second.errors)")
        #expect(atCleanStop(second) == 0, "\(tag): the second helper did not exit 0 at stdin end; stderr: \(second.errors)")
        guard let after = world.db(), let idsAfter = atPassageIDs(after) else {
            Issue.record("\(tag): the index cannot be read after the second run")
            return early
        }
        let reRead = doneBefore.keys.filter { idsAfter[$0] != doneBefore[$0] }.sorted()
        #expect(reRead.isEmpty, "\(tag): files that were done at the stop were read again (new passage ids): \(reRead)")
        #expect(idsAfter.count == 40, "\(tag): \(idsAfter.count) files hold passages after the second run, expected 40")
        let problems2 = atStoppedProblems(after, tag: tag + ", second run")
        #expect(problems2.isEmpty, "\(problems2)")
        return early
    }

    // The control: the same scenario with a kill instead of a stop. If the helper never set `tries`, a clean stop that
    // "leaves none" would prove nothing, so a kill must leave at least one row marked (a unit is always in flight
    // while work remains; a few tries, each with a seeded K and a seeded 0 to 200 ms after the line).
    @Test func aKillInsteadOfAStopLeavesAMarkerSoTheCleanStopsZeroIsMeaningful() throws {
        _ = atHelperWarm
        let seed = atSeed()
        print("SEED clean-stop-control=\(seed)")
        var rng = AtRNG(seed: seed)
        var found = false
        var report = "no kill left a marker"
        for attempt in 1...8 where !found {
            let k = Int.random(in: 2...8, using: &rng)
            let jitter = Double(Int.random(in: 0...200, using: &rng)) / 1000
            let world = try AtWorld()
            defer { world.remove() }
            // 600 photos, not 40: a small photo takes milliseconds, and a kill must land while the helper still works.
            try atMakePhotos(in: world.photos, names: atNames("cs", 1...600), seedBase: 0)
            let helper = try atStartHelper(world)
            defer { helper.stop() }
            let events = AtEvents(helper)
            helper.send(atFoldersLine([world.photos]))
            guard events.read(cap: 120, until: { events.changed >= k }) else {
                Issue.record("attempt \(attempt), K=\(k): the helper sent \(events.changed) `changed` lines and never the \(k)th; stderr: \(helper.errors)")
                continue
            }
            Thread.sleep(forTimeInterval: jitter)
            atKill(helper)
            guard let db = world.db(), let rows = atRows(db) else { continue }
            let marked = rows.values.filter { $0.tries >= 1 }.map(\.name).sorted()
            report = "attempt \(attempt), K=\(k), +\(Int(jitter * 1000)) ms: marked \(marked)"
            found = !marked.isEmpty
        }
        print("READING kill-left-marker \(report)")
        #expect(found, "a killed helper left no attempt marker in 6 tries: the helper does not set `tries` before it reads (seed \(seed)); last: \(report)")
    }

    // A clean stop over files that are locked (needs_permission) and one that vanished (skipped): the same rules, and
    // the markers of the skipped and needs_permission files are put back too. Six seeded K. Needs a user who is not root.
    @Test func aCleanStopOverLockedAndVanishedPhotosLeavesNoMarkerAndTheNextRunEndsEachWhereItBelongs() throws {
        guard getuid() != 0 else {
            Issue.record("this test runs as root, and root reads through chmod 000: it cannot show anything; run it as the person")
            return
        }
        _ = atHelperWarm
        let seed = atSeed()
        print("SEED clean-stop-locked=\(seed)")
        var rng = AtRNG(seed: seed)
        for round in 1...6 {
            let k = Int.random(in: 1...20, using: &rng)
            try lockedRound(round: round, k: k, seed: seed)
        }
    }

    private func lockedRound(round: Int, k: Int, seed: UInt64) throws {
        let tag = "round \(round), K=\(k), seed \(seed)"
        let world = try AtWorld()
        defer { world.remove() }
        let names = atNames("cs", 1...40)
        let urls = try atMakePhotos(in: world.photos, names: names, seedBase: 0)
        for number in [7, 15, 23, 31] { world.lock(urls[number - 1]) }
        let oldest = urls[39]

        let first = try atStartHelper(world)
        defer { first.stop() }
        let events = AtEvents(first)
        first.send(atFoldersLine([world.photos]))
        guard events.read(cap: 120, until: { events.walked }) else {
            Issue.record("\(tag): no `walked` event; stderr: \(first.errors)")
            return
        }
        try FileManager.default.removeItem(at: oldest)   // vanishes after the walk, long before it is read (oldest is read last)
        guard events.read(cap: 120, until: { events.changed >= k }) else {
            Issue.record("\(tag): the helper sent \(events.changed) `changed` lines and never the \(k)th; stderr: \(first.errors)")
            return
        }
        #expect(atCleanStop(first) == 0, "\(tag): the helper did not exit 0 within 120 s of its stdin ending; stderr: \(first.errors)")
        guard let db = world.db() else { Issue.record("\(tag): the index cannot be read after the stop"); return }
        let problems = atStoppedProblems(db, tag: tag)
        #expect(problems.isEmpty, "\(problems)")

        let second = try atStartHelper(world)
        defer { second.stop() }
        second.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, second, stall: 60, cap: 240, until: { $0 == ["done": 35, "needs_permission": 4] })
        #expect(wait.met, "\(tag): expected 35 done and 4 needs_permission (the vanished file's row is gone), got \(wait.statuses), stderr: \(second.errors)")
        #expect(atCleanStop(second) == 0, "\(tag): the second helper did not exit 0 at stdin end; stderr: \(second.errors)")
        guard let after = world.db() else { Issue.record("\(tag): the index cannot be read after the second run"); return }
        let problems2 = atStoppedProblems(after, tag: tag + ", second run")
        #expect(problems2.isEmpty, "\(problems2)")
        let rows = atRows(after)
        #expect(rows?["cs-040.jpg"] == nil, "\(tag): the vanished file still has a row: \(atDescribe(rows))")
        for number in [7, 15, 23, 31] {
            let row = rows?[String(format: "cs-%03d.jpg", number)]
            #expect(row?.status == "needs_permission" && row?.tries == 0, "\(tag): the locked photo \(number) is \(row.map { "\($0.status) tries \($0.tries)" } ?? "missing")")
        }
    }

    // The idle exit: all work done, one photo locked and one vanished; the helper leaves by itself about 60 s later with
    // status 0 and no row holds a marker.
    @Test func theIdleExitLeavesNoMarkerEvenWithALockedPhotoAndAVanishedOne() throws {
        guard getuid() != 0 else {
            Issue.record("this test runs as root, and root reads through chmod 000: it cannot show anything; run it as the person")
            return
        }
        _ = atHelperWarm
        let world = try AtWorld()
        defer { world.remove() }
        let urls = try atMakePhotos(in: world.photos, names: atNames("id", 1...12), seedBase: 100)
        world.lock(urls[4])
        let helper = try atStartHelper(world)
        defer { helper.stop() }
        let events = AtEvents(helper)
        helper.send(atFoldersLine([world.photos]))
        #expect(events.read(cap: 120, until: { events.walked }), "no `walked` event; stderr: \(helper.errors)")
        try FileManager.default.removeItem(at: urls[11])
        let wait = atWaitStatuses(world, helper, stall: 60, cap: 240, until: { $0 == ["done": 10, "needs_permission": 1, "pending": 1] || $0 == ["done": 11, "needs_permission": 1] })
        #expect(wait.met, "the files did not settle (10 done, 1 locked, the vanished one pending or gone): \(wait.statuses), stderr: \(helper.errors)")

        // No more input and no stdin end: the helper must leave by itself after its idle time (60 s), with status 0.
        let exited = helper.waitForExit(timeout: 150)
        #expect(exited != nil, "the helper was still running 150 s after its work ended: no idle exit; stderr: \(helper.errors)")
        #expect(exited?.status == 0, "the idle exit status is \(exited.map { String($0.status) } ?? "none"), expected 0")
        guard let db = world.db() else { Issue.record("the index cannot be read after the idle exit"); return }
        let problems = atStoppedProblems(db, tag: "idle exit")
        #expect(problems.isEmpty, "\(problems)")
    }
}
}
