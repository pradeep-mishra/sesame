import Foundation
import Testing

// plan-2-t33, tester step (carry-over F8; design section 9, 1b). Written from the t33 entry, design sections 1, 3 and 9
// and the Helper protocol table only; no product source read. The harness (`At...`) is in IndexAttemptTests.swift.
//
// The loop, as the entry words it: 50 times, with a seeded generator, the test starts the helper, sends `folders`,
// waits for the K-th `changed` line plus a random 0 to 200 ms and sends SIGKILL. After each kill: `integrity_check` is
// `ok` and every file is all-new or all-old. The test tallies, from outside, one death for each file whose row holds
// `tries` of 1 or more. At the end one run is let to finish: every file is `done`, except a `could_not_read` file that
// the tally shows died at least twice; no `could_not_read` appears for a file the loop killed only once.
//
// Three choices the entry leaves open:
// - Work must remain at every start, and the kill must land while the helper is still working (a small photo takes
//   milliseconds, measured about 7 ms, so a short queue is finished before a 200 ms delay is over and the kill would
//   hit an idle helper). The folder starts with 30 photos and the test adds 40 new, older photos before each start
//   (the helper reads newest first, so a file that was in flight is reached again first, and the queue never runs
//   dry). K is 1 to 8, and 41 `changed` lines are always available (the reconcile and the 40 new files).
// - A death is counted when a file's `tries` after a kill is HIGHER than it was after the previous kill (it was
//   marked again in that run and the run died). A row that keeps its old marker because the run never reached it is
//   not counted twice. The tally therefore never excuses a `could_not_read` that two real deaths do not explain.
// - The kill must be able to hit: the number of kills that left a marker is printed and must be at least 3 of 50. With
//   no attempt marker in the helper that number is 0 and the loop is red for that reason, not for a flaky one.
//
// The helper is the bundled release one, `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME, warmed once per test process.
// Each start is allowed 120 s. The seed is printed (`SEED kill-loop=<n>`); `T33_SEED=<n>` replays it.

extension EncodeHelperTests {
@Suite("IndexKillLoopTests", .serialized)
struct IndexKillLoopTests {

    @Test func fiftySigkillsLeaveAWholeIndexAndOnlyAFileKilledTwiceEndsCouldNotRead() throws {
        _ = atHelperWarm
        let seed = atSeed()
        print("SEED kill-loop=\(seed)")
        var rng = AtRNG(seed: seed)
        let world = try AtWorld()
        defer { world.remove() }

        var photoCount = 30
        try atMakePhotos(in: world.photos, names: atNames("kl", 1...photoCount), seedBase: 0, age: 0)
        let line = atFoldersLine([world.photos])

        var lastTries: [String: Int] = [:]   // each file's tries after the previous kill
        var deaths: [String: Int] = [:]      // deaths the test has seen, by file name
        var killsWithMarker = 0
        var problems: [String] = []

        for kill in 1...50 {
            // New work, so the next helper has something to read: 40 photos, each older than every earlier one.
            try atMakePhotos(in: world.photos, names: atNames("kl", (photoCount + 1)...(photoCount + 40)),
                             seedBase: photoCount, age: photoCount)
            photoCount += 40

            let k = Int.random(in: 1...8, using: &rng)
            let jitter = Double(Int.random(in: 0...200, using: &rng)) / 1000
            let tag = "kill \(kill), K=\(k), +\(Int(jitter * 1000)) ms, seed \(seed)"
            let helper = try atStartHelper(world)
            let events = AtEvents(helper)
            helper.send(line)
            guard events.read(cap: 120, until: { events.changed >= k }) else {
                helper.stop()
                Issue.record("\(tag): the helper sent \(events.changed) `changed` lines and never the \(k)th; stderr: \(helper.errors)")
                return
            }
            Thread.sleep(forTimeInterval: jitter)
            atKill(helper)
            helper.stop()

            guard let db = world.db(), let rows = atRows(db) else {
                Issue.record("\(tag): the index cannot be read after the kill")
                return
            }
            let whole = atWholeProblems(db)
            if !whole.isEmpty { problems.append("\(tag): \(whole)") }

            var died = false
            for (name, row) in rows {
                if row.tries > (lastTries[name] ?? 0) { deaths[name, default: 0] += 1; died = true }
                lastTries[name] = row.tries
                if row.status == "could_not_read" {
                    if (deaths[name] ?? 0) < 2 {
                        problems.append("\(tag): \(name) is could_not_read(\(row.reason ?? "no reason")) but the loop killed it \(deaths[name] ?? 0) time(s)")
                    }
                    if row.reason != "damaged" {
                        problems.append("\(tag): \(name) is could_not_read with reason \(row.reason ?? "none"), expected damaged (no watchdog trip here)")
                    }
                }
            }
            if died { killsWithMarker += 1 }
        }

        // One run is let to finish: every file done, or could_not_read for a file the loop killed at least twice.
        let finish = try atStartHelper(world)
        defer { finish.stop() }
        finish.send(line)
        let total = photoCount
        let wait = atWaitStatuses(world, finish, stall: 90, cap: 300,
                                  until: { ($0["done"] ?? 0) + ($0["could_not_read"] ?? 0) == total })
        #expect(wait.met, "the last run did not finish all \(total) files: \(wait.statuses), stderr: \(finish.errors)")
        #expect(atCleanStop(finish) == 0, "the last helper did not exit 0 at stdin end; stderr: \(finish.errors)")

        guard let db = world.db(), let rows = atRows(db) else {
            Issue.record("the index cannot be read after the last run")
            return
        }
        let unfinished = rows.values.filter { $0.status != "done" && $0.status != "could_not_read" }.map { "\($0.name)=\($0.status)" }.sorted()
        #expect(unfinished.isEmpty, "files that are neither done nor could_not_read at the end: \(unfinished)")
        #expect(rows.count == total, "\(rows.count) rows at the end, expected \(total)")
        for (name, row) in rows where row.status == "could_not_read" {
            // The last run may itself turn a file with tries 2 into could_not_read: that file has the 2 deaths in the tally.
            #expect((deaths[name] ?? 0) >= 2, "\(name) ended could_not_read but the loop killed it \(deaths[name] ?? 0) time(s) (seed \(seed))")
            #expect(row.reason == "damaged", "\(name) ended could_not_read with reason \(row.reason ?? "none"), expected damaged")
        }
        #expect(rows.values.allSatisfy { $0.tries == 0 }, "rows still holding a marker after a clean finish: \(rows.values.filter { $0.tries != 0 }.map(\.name))")
        let finalProblems = atWholeProblems(db)
        #expect(finalProblems.isEmpty, "the index is not whole after the last run: \(finalProblems)")

        #expect(problems.isEmpty, "the index was not whole, or a file ended could_not_read it should not have, after a kill: \(problems)")
        let couldNotRead = rows.values.filter { $0.status == "could_not_read" }.map(\.name).sorted()
        print("READING kill-loop kills_with_marker=\(killsWithMarker)/50 deaths_tallied=\(deaths.values.reduce(0, +)) could_not_read=\(couldNotRead) seed=\(seed)")
        #expect(killsWithMarker >= 3,
                "only \(killsWithMarker) of 50 kills left a marker (a row whose tries went up): the helper does not set `tries` before it reads, so a kill proves nothing (seed \(seed))")
    }
}
}
