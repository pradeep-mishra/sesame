import Foundation
import Testing
import SesameEngine

// plan-3-t18, tester step. The merge checks of spec S2.8 (i) to (iv), through the bundled helper alone (no app, no window)
// and the engine's `IndexReader`, `LlamaEmbedder` and `Search`. Written from the t18 entry of plan-3-tasks.md, GroupATests,
// IndexOverlapTests (for the helper rig) and the answer key only; no product source read. Every expected value is the
// key's or hand-written here.
//
// One run, in order, in a temp folder (the shared golden fixture is only copied from, never touched):
//   stage 1  the golden folder (40 photos: the targets, the decoys, the 4 screenshots) is copied; the helper with the REAL
//            models indexes the copy. (i) with the decoys present the six readable exact rows stay first.
//   stage 2  `kit-fixtures.sh build unrelated 1000` (in a temp kit root) makes 1,000 unrelated photos; a helper with the FAKE
//            embedder indexes them beside the copy (the 40 golden rows stay as they are). (ii) none of the six moves from
//            first. (iv) the RANK lines are taken here, with every file present.
//   stage 3  the test deletes one exact file from its copy (exact-03's screenshot) and a fresh helper reconciles. (iii) its
//            string no longer lists the file and a single-token string still returns a non-empty closest list.
// The three stages run once, on the first use, and each test reads what was recorded for its stage.
//
// It prints `RANK <id> <n|none> odd|even` for every readable exact row and every group a row, then the line
// `odd first x of n, even first y of m` and `noted: overfitting risk` when the even rows hit at least 2 fewer than the odd
// rows (spec S2.8 iv; the number is the one in the row id; a hit is rank 1). That note never fails a test.

private struct MergeStage: Sendable {
    let name: String
    let rowCount: Int
    let statuses: [String: Int]
    /// answer id to the ranked paths of its query
    let lists: [String: [String]]
}

private final class MergeOutcome: @unchecked Sendable {
    var stages: [String: MergeStage] = [:]
    var failure: String?
    var queries: [GB.Answer] = []
    var deletedFile = ""
    var sharedFileStillThere = false
    var unrelatedBuilt = 0

    static let shared = MergeOutcome.perform()

    func stage(_ name: String) throws -> MergeStage {
        if let found = stages[name] { return found }
        throw GBFailure("stage \(name) did not run: \(failure ?? "no reason recorded")")
    }

    private static func perform() -> MergeOutcome {
        let outcome = MergeOutcome()
        do { try outcome.run() } catch let failure as GBFailure { outcome.failure = failure.description } catch {
            outcome.failure = "\(error)"
        }
        return outcome
    }

    private func buildEnv(base: String) throws -> (env: [String: String], kit: String) {
        let kit = base + "/sesame-kit-merge"
        let tmp = base + "/tmp"
        let decoyHome = base + "/decoy-home"
        for dir in [kit + "/run", tmp, decoyHome] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return (["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome,
                 "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"], kit)
    }

    private func take(_ name: String, home: String, folders: [String], files: Int,
                      vectors: [String: [Float]], settled: GB.Settled) throws {
        var statuses: [String: Int] = [:]
        for row in settled.rows { statuses[row.status, default: 0] += 1 }
        let opened = GB.openReader(home: home, files: files)
        guard let reader = opened.reader else {
            throw GBFailure("stage \(name): the index holds \(opened.count) files, expected \(files)")
        }
        defer { reader.close() }
        let search = Search(reader: reader)
        defer { search.release() }
        let visible = GB.visible(folders)
        var lists: [String: [String]] = [:]
        for answer in queries {
            guard let vector = vectors[answer.query] else { throw GBFailure("no vector for \(answer.id)") }
            lists[answer.id] = GB.ranked(search, answer.query, vector, visible) ?? []
        }
        stages[name] = MergeStage(name: name, rowCount: settled.rows.count, statuses: statuses, lists: lists)
    }

    private func run() throws {
        let all = try GB.answers()
        let readable = try GB.readableExact()
        let groupA = all.filter { $0.group == "photo" }
        guard let missing = all.first(where: { $0.group == "missing" }) else { throw GBFailure("no missing row in answers.csv") }
        queries = readable + groupA + [missing]
        guard groupA.count == 10 else { throw GBFailure("the key holds \(groupA.count) photo rows, expected 10") }
        guard let kit = GB.kitRoot() else { throw GBFailure("no KIT_ROOT and no TMPDIR: cannot find the kit") }
        let models = try GB.models(kit: kit)
        guard FileManager.default.isExecutableFile(atPath: GB.bundledHelper.path) else {
            throw GBFailure("the bundled helper is missing: run `scripts/bundle.sh` (expected \(GB.bundledHelper.path))")
        }

        let work = GB.realpathOf(FileManager.default.temporaryDirectory.appendingPathComponent("sesame-merge-" + UUID().uuidString).path)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        let home = work + "/home"
        try GB.makeSupportFolder(home: home)

        // The golden folder, copied under the lock; the shared fixture is never written to (build is a no-op when right).
        let sharedGolden = kit.appendingPathComponent("fixtures/golden")
        let built = GB.withGoldenLock(kit) {
            GB.runChild("/bin/bash", [GB.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", "golden"],
                        env: ["KIT_ROOT": kit.path], limit: 1800)
        }
        guard let golden = built, golden.status == 0 else {
            throw GBFailure("kit-fixtures.sh build golden failed: \(GB.tail(built?.output ?? "not started"))")
        }
        let copyRoot = work + "/copy"
        let copy = copyRoot + "/golden"
        try FileManager.default.createDirectory(atPath: copyRoot, withIntermediateDirectories: true)
        try GB.withGoldenLock(kit) { try FileManager.default.copyItem(atPath: sharedGolden.path, toPath: copy) }

        // 1,000 unrelated photos in a temp kit root of their own.
        let kitEnv = try buildEnv(base: work)
        let unrelatedBuild = GB.runChild("/bin/bash",
                                         [GB.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", "unrelated", "1000"],
                                         env: kitEnv.env, limit: 1800)
        guard let unrelated = unrelatedBuild, unrelated.status == 0 else {
            throw GBFailure("kit-fixtures.sh build unrelated 1000 failed: \(GB.tail(unrelatedBuild?.output ?? "not started"))")
        }
        let unrelatedRoot = kitEnv.kit + "/fixtures/unrelated"
        let built1000 = (try? FileManager.default.contentsOfDirectory(atPath: unrelatedRoot))?.filter { $0.hasPrefix("unrel") }.count ?? 0
        unrelatedBuilt = built1000
        guard built1000 == 1000 else { throw GBFailure("build unrelated 1000 made \(built1000) photos in \(unrelatedRoot)") }

        // The cached text model embeds every query once; the helper embeds the photos.
        let vectors = try GB.embedQueries(queries.map(\.query), textModel: models.text)

        // Stage 1: real models over the golden copy.
        do {
            let helper = try GBHelper(home: home, models: models, scratch: URL(fileURLWithPath: work))
            defer { helper.stop() }
            helper.sendFolders([copy])
            let settled = GB.settle(home: home, helper: helper, rows: 40)
            guard settled.ok else { throw GBFailure("stage 1 (golden copy, real models): \(settled.note)") }
            helper.stop()
            try take("1", home: home, folders: [copy], files: 40, vectors: vectors, settled: settled)
        }

        // Stage 2: the 1,000 unrelated photos, fake embedder.
        do {
            let helper = try GBHelper(home: home, models: nil, scratch: URL(fileURLWithPath: work))
            defer { helper.stop() }
            helper.sendFolders([copy, unrelatedRoot])
            let settled = GB.settle(home: home, helper: helper, rows: 1040, stall: 600, cap: 2400)
            guard settled.ok else { throw GBFailure("stage 2 (1,000 unrelated photos added): \(settled.note)") }
            helper.stop()
            try take("2", home: home, folders: [copy, unrelatedRoot], files: 1040, vectors: vectors, settled: settled)
        }

        // Stage 3: one exact file deleted from the copy, a fresh helper reconciles.
        guard let exact03 = readable.first(where: { $0.id == "exact-03" }) else { throw GBFailure("no exact-03 row") }
        deletedFile = exact03.file
        let victim = copy + "/" + exact03.file
        guard FileManager.default.fileExists(atPath: victim) else { throw GBFailure("setup: \(victim) is not in the copy") }
        try FileManager.default.removeItem(atPath: victim)
        sharedFileStillThere = FileManager.default.fileExists(atPath: sharedGolden.path + "/" + exact03.file)
        do {
            let helper = try GBHelper(home: home, models: nil, scratch: URL(fileURLWithPath: work))
            defer { helper.stop() }
            helper.sendFolders([copy, unrelatedRoot])
            let settled = GB.settle(home: home, helper: helper, rows: 1039)
            guard settled.ok else { throw GBFailure("stage 3 (one exact file deleted): \(settled.note)") }
            helper.stop()
            try take("3", home: home, folders: [copy, unrelatedRoot], files: 1039, vectors: vectors, settled: settled)
        }
    }
}

private func outcome() -> MergeOutcome { MergeOutcome.shared }

/// The rank of an answer's file in a stage, or nil.
private func rank(_ answer: GB.Answer, in stage: MergeStage) -> Int? {
    GB.place(of: answer.file, in: stage.lists[answer.id] ?? [])
}

@Suite("MergeTests", .serialized)
struct MergeTests {

    private func readable() throws -> [GB.Answer] { try GB.readableExact() }

    // (i) with the decoys present the six stay first
    @Test func withTheDecoysPresentTheSixReadableExactRowsStayFirst() throws {
        let stage = try outcome().stage("1")
        #expect(stage.rowCount == 40, "stage 1 indexed \(stage.rowCount) files, expected the 40 golden photos")
        #expect(stage.statuses["done"] == 40, "stage 1 statuses: \(stage.statuses), expected 40 done")
        let rows = try readable()
        try #require(rows.count == 6)
        let notFirst = rows.filter { rank($0, in: stage) != 1 }
        let detail = notFirst.map { "\($0.id) \"\($0.query)\" want \($0.file) rank \(rank($0, in: stage).map(String.init) ?? "none")" }
        #expect(notFirst.isEmpty, "with the decoys present the exact photo is not first for \(notFirst.count) of 6 rows: \(detail.joined(separator: "; "))")
    }

    // (ii) after 1,000 unrelated photos none of the six moves from first
    @Test func afterTheThousandUnrelatedPhotosAreIndexedNoneOfTheSixMovesFromFirst() throws {
        let run = outcome()
        #expect(run.unrelatedBuilt == 1000, "kit-fixtures.sh build unrelated 1000 made \(run.unrelatedBuilt) photos")
        let stage = try run.stage("2")
        #expect(stage.rowCount == 1040, "stage 2 indexed \(stage.rowCount) files, expected 40 golden and 1,000 unrelated")
        #expect(stage.statuses["done"] == 1040, "stage 2 statuses: \(stage.statuses), expected 1040 done")
        let rows = try readable()
        let notFirst = rows.filter { rank($0, in: stage) != 1 }
        let detail = notFirst.map { "\($0.id) \"\($0.query)\" want \($0.file) rank \(rank($0, in: stage).map(String.init) ?? "none")" }
        #expect(notFirst.isEmpty, "with 1,000 unrelated photos the exact photo is not first for \(notFirst.count) of 6 rows: \(detail.joined(separator: "; "))")
    }

    // (iii) after one exact file is deleted and the helper reconciles
    @Test func afterOneExactFileIsDeletedItsStringNoLongerListsItAndASingleTokenStillGetsAClosestList() throws {
        let run = outcome()
        let stage = try run.stage("3")
        let rows = try readable()
        let deleted = try #require(rows.first { $0.id == "exact-03" }, "no exact-03 row")
        #expect(run.deletedFile == deleted.file, "the test deleted \(run.deletedFile), expected \(deleted.file)")
        #expect(run.sharedFileStillThere, "the shared golden fixture lost \(deleted.file): the test must only touch its copy")
        #expect(stage.rowCount == 1039, "stage 3 holds \(stage.rowCount) files, expected 1039 after one deletion")

        let list = stage.lists[deleted.id] ?? []
        #expect(GB.place(of: deleted.file, in: list) == nil,
                "after the file was deleted and reconciled \"\(deleted.query)\" still lists \(deleted.file)")
        // A single token with no exact hit left still returns the closest files, never an empty list.
        #expect(!deleted.query.contains(" "), "setup: \(deleted.id)'s string is one token: \(deleted.query)")
        #expect(!list.isEmpty, "\"\(deleted.query)\" (one token, its file deleted) must still return a non-empty closest list")
        let missing = try #require(try GB.answers().first { $0.group == "missing" }, "no missing row in answers.csv")
        #expect(!(stage.lists[missing.id] ?? []).isEmpty, "\"\(missing.query)\" (one token, in no file) must return a non-empty closest list")

        // The other five exact rows are untouched by the deletion.
        let others = rows.filter { $0.id != deleted.id }
        let notFirst = others.filter { rank($0, in: stage) != 1 }
        #expect(notFirst.isEmpty, "after the deletion these exact photos are not first: \(notFirst.map(\.id))")
    }

    // (iv) the RANK lines and the odd and even split
    @Test func itPrintsARankLineForEveryReadableExactRowAndEveryGroupARowAndTheOddEvenSplit() throws {
        let run = outcome()
        let stage = try run.stage("2")
        let all = try GB.answers()
        let rows = try readable() + all.filter { $0.group == "photo" }
        #expect(rows.count == 16, "the readable exact rows and the group a rows are 16, got \(rows.count)")
        var oddHit = 0, oddTotal = 0, evenHit = 0, evenTotal = 0
        for answer in rows {
            let place = rank(answer, in: stage)
            let number = answer.number ?? 0
            let parity = number % 2 == 1 ? "odd" : "even"
            print("RANK \(answer.id) \(place.map(String.init) ?? "none") \(parity)")
            if number % 2 == 1 { oddTotal += 1; if place == 1 { oddHit += 1 } } else { evenTotal += 1; if place == 1 { evenHit += 1 } }
        }
        print("odd first \(oddHit) of \(oddTotal), even first \(evenHit) of \(evenTotal)")
        if oddHit - evenHit >= 2 { print("noted: overfitting risk") }
        // The split is reported, never asserted: only that both halves have rows.
        #expect(oddTotal > 0 && evenTotal > 0, "odd rows \(oddTotal), even rows \(evenTotal)")
    }
}
