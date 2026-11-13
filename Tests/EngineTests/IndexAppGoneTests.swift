import Foundation
import Testing
import SesameEngine

// plan-2 fix round A, tester step: item A2 (S7.12, S7.2). Written from the fix-round entry A2, the reviewer's report
// (finding "when the app dies or closes the pipe mid-unit, the helper exits without putting the attempt marker back"),
// design section 1 ("app gone" must put the marker back) and IndexCleanStopTests.swift. No product source read. The
// harness is `At...` (IndexAttemptTests.swift) and `PipeRig` (PipeRig.swift: a helper whose stdout read side the test closes).
//
// What the entry fixes (expected values, none from the code under test): when the pipe to the app is gone (the app was
// killed, crashed or closed its read side; stdin is NOT ended) the helper puts every marker of the unit back before it
// exits, the same way as when stdin ends. Seen from outside, after the helper has exited: no `files` row has `tries` above
// 0, and `integrity_check` is ok (and the index is whole). A helper that never notices must also be seen: it exits within
// 120 s (it has an idle exit of 60 s, so an unnoticed pipe cannot hold it for long). The exit STATUS is not pinned.
//
// Two ways, because they see different things:
//   1. FAKE EMBEDDER (the entry's test, as IndexCleanStopTests does): a unit is one file, so a marker is outstanding only
//      for the file being read. Seeded K (printed), 120 photos, the read side closed after the K-th `changed` line.
//      This is expected to pass today when the helper's `send` is never called with a marker set; if it passes it is a
//      guard (listed as one in the report).
//   2. REAL MODEL (the bundled release helper with the kit's two cached model files, read only): a unit is 16 files and
//      today `beginAttempt` marks all 16 before the first read, so the first `changed` line after a commit is sent while
//      15 files still hold a marker, and a closed pipe makes `send` exit without putting them back. 20 photos, the read side
//      closed after the 2nd to 4th `changed` line (the first is the walk's commit), seeded. No app, no window.
// Time is never asserted tightly; every wait has a generous cap.

private func agFindings(_ world: AtWorld, tag: String) -> [String] {
    guard let db = world.db(), let rows = atRows(db) else { return ["\(tag): the index cannot be read after the exit"] }
    var problems: [String] = []
    let marked = rows.values.filter { $0.tries != 0 }.map { "\($0.name) tries \($0.tries)" }.sorted()
    if !marked.isEmpty { problems.append("\(tag): rows with tries above 0 after the helper exited: \(marked.prefix(20))") }
    problems += atWholeProblems(db).map { "\(tag): \($0)" }
    return problems
}

private func agBundledHelper() throws -> URL {
    let executable = KitPaths.bundledHelper
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw AtError("the bundled helper is missing: \(executable.path) (run scripts/bundle.sh)")
    }
    return executable
}

extension EncodeHelperTests {
@Suite("IndexAppGoneTests", .serialized)
struct IndexAppGoneTests {

    // MARK: 1. the fake embedder, as the entry says

    @Test func closingTheReadSideOfStdoutAfterTheKthChangedLineLeavesNoMarkerAndAnOkIndexSeededK() throws {
        _ = atHelperWarm
        let helper = try agBundledHelper()
        let seed = atSeed()
        print("SEED app-gone-fake=\(seed)")
        var rng = AtRNG(seed: seed)
        var exitedWithWorkLeft = 0
        for round in 1...6 {
            let k = Int.random(in: 1...25, using: &rng)
            let tag = "round \(round), K=\(k), seed \(seed)"
            let world = try AtWorld()
            defer { world.remove() }
            try atMakePhotos(in: world.photos, names: atNames("ag", 1...120), seedBase: 0)
            let rig = try PipeRig(helper: helper, home: world.home, models: nil, scratch: world.root)
            defer { rig.cleanup() }
            rig.send(atFoldersLine([world.photos]))
            guard rig.read(cap: 120, until: { rig.changed >= k }) else {
                Issue.record("\(tag): the helper sent \(rig.changed) `changed` lines and never the \(k)th; stderr: \(rig.stderrText.prefix(300))")
                continue
            }
            rig.closeStdoutReader()                           // the app is gone: its read side of the pipe is closed, stdin stays open
            let exit = rig.waitForExit(timeout: 120)
            #expect(exit != nil, "\(tag): the helper was still running 120 s after the pipe to the app was closed; stderr: \(rig.stderrText.prefix(300))")
            let problems = agFindings(world, tag: tag)
            #expect(problems.isEmpty, "\(problems)")
            if let db = world.db(), (db.int("select count(*) from files where status = 'done'") ?? 0) < 120 { exitedWithWorkLeft += 1 }
        }
        print("READING app-gone-fake rounds_exited_with_work_left=\(exitedWithWorkLeft)/6 seed=\(seed)")
        #expect(exitedWithWorkLeft >= 3, "only \(exitedWithWorkLeft) of 6 helpers exited with files still waiting, so the closed pipe came too late to prove much (seed \(seed))")
    }

    // MARK: 2. the real model: a unit of 16 files

    @Test func withTheRealModelAClosedPipeMidUnitPutsEveryMarkerBackBeforeTheHelperExits() throws {
        _ = atHelperWarm
        let helper = try agBundledHelper()
        guard let text = KitPaths.textModel() else {
            Issue.record("model file missing: $KIT_ROOT/cache/\(KitPaths.textModelName) (the real-model check cannot run; seed the cache: scripts/kit-mirror.sh seed --real)")
            return
        }
        let mm = text.deletingLastPathComponent().appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
        guard FileManager.default.fileExists(atPath: mm.path) else {
            Issue.record("model file missing: \(mm.path) (the real-model check cannot run; seed the cache: scripts/kit-mirror.sh seed --real)")
            return
        }
        let seed = atSeed()
        print("SEED app-gone-real=\(seed)")
        var rng = AtRNG(seed: seed)
        var markedAtExit = 0
        for round in 1...2 {
            let k = Int.random(in: 2...4, using: &rng)
            let tag = "real model, round \(round), K=\(k), seed \(seed)"
            let world = try AtWorld()
            defer { world.remove() }
            try atMakePhotos(in: world.photos, names: atNames("rm", 1...20), seedBase: 500)
            let rig = try PipeRig(helper: helper, home: world.home, models: (text, mm), scratch: world.root)
            defer { rig.cleanup() }
            rig.send(atFoldersLine([world.photos]))
            guard rig.read(cap: 240, until: { rig.changed >= k }) else {
                Issue.record("\(tag): the helper sent \(rig.changed) `changed` lines and never the \(k)th; stderr: \(rig.stderrText.prefix(300))")
                continue
            }
            rig.closeStdoutReader()
            let exit = rig.waitForExit(timeout: 180)
            #expect(exit != nil, "\(tag): the helper was still running 180 s after the pipe to the app was closed; stderr: \(rig.stderrText.prefix(300))")
            let problems = agFindings(world, tag: tag)
            if problems.contains(where: { $0.contains("tries above 0") }) { markedAtExit += 1 }
            #expect(problems.isEmpty, "\(problems)")
        }
        print("READING app-gone-real rounds_with_marker_left=\(markedAtExit)/2 seed=\(seed)")
    }
}
}
