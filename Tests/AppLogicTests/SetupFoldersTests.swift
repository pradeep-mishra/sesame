import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t19, tester step. Written from the t19 entry of plan-2-tasks.md (its Tests paragraph), Decisions D11, spec S6
// (S6.2, S6.3, S6.4, S6.9, S6.10), design section 3 ("Setup, before Start": the app only counts, sends no `folders`
// command until Start) and the plan-1/plan-2 test files as the one place the settings and engine names are read
// (`SettingsFile`, `FolderCounts.count(folders:)`, `Estimator`). No product source was read. Every expected number and
// text below is written by hand from the folders the test builds and from the Estimator's wording rule; the Estimator
// is compared only where the entry says the row text "equals Estimator.estimate".
//
// SUITE PLACEMENT. HOME is process-wide (SettingsFile and SesameFolder read it), so this suite is nested inside
// `ModelDownloadTests` like SetupModelTests and SetupFlowTests and runs one at a time with them.
//
// API SHAPES these tests pin. The entry names `SetupFolders`, `FolderRow` (path, name, ticked, counts by kind,
// `estimateText`, state `counting` or `ready`), the counter, the estimator inputs and the picker seams, "Add folder...",
// and fixes no signatures. If a shape below is wrong, ask for a test change rather
// than guessing.
//   1. `SetupFolders` is in the `Sesame` target, a final class (the tests are @MainActor, so an isolated class is fine):
//        init(home: URL,
//             counter: @escaping @Sendable ([String]) -> FolderCounts = { FolderCounts.count(folders: $0) },
//             picker: @escaping () -> [URL],
//             speeds: @escaping () -> [String: Double],      // the stored `speeds`, seconds per file per kind
//             kindsOn: @escaping () -> [String: Bool],       // the stored `kindsOn`
//             modelWhole: @escaping () -> Bool)
//      `home` is the folder the five suggested folders live under (the tests pass the temp HOME, already symlink-resolved).
//      The counter is called off the main thread, with a list of folder paths (one or several; the test does not say
//      which), and returns what `FolderCounts.count(folders:)` returns for them. The test counters wrap the real one.
//      Counting of every ticked row begins at init; no extra call is needed.
//   2. `folders.rows: [FolderRow]` is the main list in order: Desktop, Documents, Downloads, Pictures, Movies, then each
//      folder added with "Add folder..." in the order added. `FolderRow` has `path: String`, `name: String` (last path
//      component), `ticked: Bool`, `counts: [String: Int]` (kind -> files; an absent kind means 0), `estimateText: String`,
//      `state` equal to `.counting` or `.ready`, and `note: String?` (nil, or "not found" for a folder that does not
//      exist, compared case-insensitively as a contained phrase). A missing suggested folder is unticked and is never
//      counted.
//   3. `folders.setTicked(_ path: String, _ ticked: Bool)` ticks or unticks a row. Ticking a row
//      counts it again (state `.counting`, then `.ready`); unticking does not call the counter.
//   4. `folders.addFolder()` is "Add folder...": it calls the picker once and adds each returned URL as a ticked row at the
//      end, `.counting` then `.ready`. An empty pick adds nothing.
//   5. `folders.summaryTotal: Int` and `folders.summaryCounts: [String: Int]`: what the ticked rows hold, each file counted
//      once (by path) however the folders overlap. They are final once every ticked row is `.ready`.
//   6. `folders.refreshEstimates()` recomputes every row's `estimateText` from the current seams (a model that became
//      whole, a speed just measured, a kind switched off). Texts are those of `Estimator.estimate(counts:speeds:kindsOn:modelWhole:)`.
//   8. Not pinned, on purpose: the wording of the summary line, the text of a row while it is `.counting`, how the same
//      folder added twice is treated, any window or view, and whether the counter is called
//      once per folder or once for the whole ticked set. Nothing in SetupFolders takes a HelperClient: the tests show that
//      no step here writes `startPressed` or a `reading` true folder, which is what "sends no `folders` command" means.

// MARK: small helpers (file-private, so nothing collides with the other Setup test files)

private let sfoKinds = ["photo", "pdf", "doc", "audio", "video", "code"]

private final class SFOBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// Records every counter call; while `hold` is on the counter blocks (off the main thread) until `release`.
private final class SFOCounterLog: @unchecked Sendable {
    private let cond = NSCondition()
    private var held = false
    private var recorded: [(folders: [String], onMain: Bool)] = []

    func hold() { cond.lock(); held = true; cond.unlock() }
    func release() { cond.lock(); held = false; cond.broadcast(); cond.unlock() }

    func enter(_ folders: [String]) {
        cond.lock()
        recorded.append((folders, Thread.isMainThread))
        while held { cond.wait() }
        cond.unlock()
    }

    var calls: [(folders: [String], onMain: Bool)] { cond.lock(); defer { cond.unlock() }; return recorded }
    func callsTouching(_ path: String) -> Int { calls.filter { $0.folders.contains(path) }.count }
}

@MainActor
private final class SFOKit {
    let log = SFOCounterLog()
    let speeds = SFOBox<[String: Double]>([:])
    let kindsOn = SFOBox<[String: Bool]>(Dictionary(uniqueKeysWithValues: sfoKinds.map { ($0, true) }))
    let modelWhole = SFOBox<Bool>(true)
    let picks = SFOBox<[URL]>([])
    let pickerCalls = SFOBox<Int>(0)

    func make(home: URL) -> SetupFolders {
        let log = self.log, speeds = self.speeds, kindsOn = self.kindsOn, modelWhole = self.modelWhole
        let picks = self.picks, pickerCalls = self.pickerCalls
        return SetupFolders(
            home: home,
            counter: { folders in
                log.enter(folders)
                return FolderCounts.count(folders: folders)
            },
            picker: {
                pickerCalls.value += 1
                return picks.value
            },
            speeds: { speeds.value },
            kindsOn: { kindsOn.value },
            modelWhole: { modelWhole.value })
    }

    // The real counter: the default of the initializer.
    func makeWithRealCounter(home: URL) -> SetupFolders {
        let speeds = self.speeds, kindsOn = self.kindsOn, modelWhole = self.modelWhole
        return SetupFolders(
            home: home,
            picker: { [] },
            speeds: { speeds.value },
            kindsOn: { kindsOn.value },
            modelWhole: { modelWhole.value })
    }
}

private struct SFOEnv {
    let home: URL   // symlink-resolved, so a path compared as text cannot differ by a link
    var settings: URL { home.appendingPathComponent("Library/Application Support/Sesame/settings.json") }

    func dir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Hand-made files: `photo` jpg/png, `pdf` pdf, `doc` txt/md, unique names, a few in a nested folder.
    func fill(_ relative: String, photo: Int = 0, pdf: Int = 0, doc: Int = 0) throws -> URL {
        let url = try dir(relative)
        func write(_ name: String) throws {
            let nested = name.count % 2 == 0 ? "sub/" : ""
            try FileManager.default.createDirectory(at: url.appendingPathComponent(nested), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent(nested + name))
        }
        for n in 0..<photo { try write("photo-\(n).\(n % 2 == 0 ? "jpg" : "png")") }
        for n in 0..<pdf { try write("paper-\(n).pdf") }
        for n in 0..<doc { try write("note-\(n).\(n % 2 == 0 ? "txt" : "md")") }
        return url
    }

    func path(_ name: String) -> String { home.appendingPathComponent(name).path }

    func settingsDictionary() -> NSDictionary? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    // Nothing started: no startPressed true, no folder reading, in settings.json as stored and as SettingsFile reads it.
    func assertNothingStarted(_ stage: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let onDisk = settingsDictionary()
        #expect((onDisk?["startPressed"] as? Bool ?? false) == false, "\(stage): startPressed is true on disk", sourceLocation: sourceLocation)
        let entries = (onDisk?["folders"] as? [NSDictionary]) ?? []
        #expect(entries.allSatisfy { ($0["reading"] as? Bool) != true }, "\(stage): a folder is reading: \(entries)", sourceLocation: sourceLocation)
        #expect(entries.allSatisfy { ($0["code"] as? Bool) != true }, "\(stage): a folder has code on: \(entries)", sourceLocation: sourceLocation)
        #expect((try? SettingsFile().read().startPressed) == false, "\(stage): SettingsFile says Start was pressed", sourceLocation: sourceLocation)
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder, runs the body, puts HOME back and removes the folder.
@MainActor
private func sfoRun(_ body: (SFOEnv) async throws -> Void) async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-setupfolders-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = SFOEnv(home: base.resolvingSymlinksInPath())
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", env.home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: base)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.home.appendingPathComponent("Library/Application Support/Sesame").path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try await body(env)
}

// Polls the main actor until the condition holds; a generous slack, never a tight bound.
@MainActor
private func sfoEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func sfoReady(_ folders: SetupFolders) async -> Bool {
    await sfoEventually { folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
}

private func sfoCell(_ counts: [String: Int], _ kind: String) -> Int { counts[kind] ?? 0 }

private func sfoExpectCounts(_ actual: [String: Int], _ expected: [String: Int], _ label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
    for kind in sfoKinds {
        #expect(sfoCell(actual, kind) == (expected[kind] ?? 0),
                "\(label), \(kind): got \(sfoCell(actual, kind)), want \(expected[kind] ?? 0) (all: \(actual))",
                sourceLocation: sourceLocation)
    }
}

extension ModelDownloadTests {
    @Suite("SetupFoldersTests", .serialized)
    struct SetupFoldersTests {

        // MARK: the suggested list

        @MainActor
        @Test func theFiveSuggestedFoldersAreListedTickedInOrderWhenTheyExist() async throws {
            try await sfoRun { env in
                for name in ["Desktop", "Documents", "Downloads", "Pictures", "Movies"] { _ = try env.dir(name) }
                let kit = SFOKit()
                let folders = kit.make(home: env.home)

                #expect(folders.rows.map { $0.name } == ["Desktop", "Documents", "Downloads", "Pictures", "Movies"],
                        "rows: \(folders.rows.map { $0.name })")
                #expect(folders.rows.map { $0.path } == ["Desktop", "Documents", "Downloads", "Pictures", "Movies"].map { env.path($0) },
                        "paths: \(folders.rows.map { $0.path })")
                #expect(folders.rows.allSatisfy { $0.ticked }, "unticked suggestion: \(folders.rows.map { ($0.name, $0.ticked) })")
                #expect(folders.rows.allSatisfy { $0.note == nil }, "a note on an existing folder: \(folders.rows.map { $0.note as Any })")
                #expect(await sfoReady(folders), "the rows never became ready")
                env.assertNothingStarted("suggested list")
            }
        }

        @MainActor
        @Test func aMissingSuggestedFolderIsListedUntickedWithNotFoundAndIsNeverCounted() async throws {
            try await sfoRun { env in
                for name in ["Desktop", "Documents", "Downloads", "Pictures"] { _ = try env.dir(name) }
                // Movies does not exist
                let kit = SFOKit()
                let folders = kit.make(home: env.home)

                #expect(folders.rows.map { $0.name } == ["Desktop", "Documents", "Downloads", "Pictures", "Movies"],
                        "rows: \(folders.rows.map { $0.name })")
                let movies = try #require(folders.rows.first { $0.name == "Movies" }, "no Movies row")
                #expect(!movies.ticked, "a missing folder is ticked")
                let note = try #require(movies.note, "no note on a missing folder")
                #expect(note.lowercased().contains("not found"), "note: \(note)")
                for name in ["Desktop", "Documents", "Downloads", "Pictures"] {
                    let row = try #require(folders.rows.first { $0.name == name })
                    #expect(row.ticked && row.note == nil, "\(name): ticked \(row.ticked), note \(String(describing: row.note))")
                }
                #expect(await sfoReady(folders))
                #expect(kit.log.callsTouching(env.path("Movies")) == 0, "the missing folder was counted")
                // it cannot be summed either: nothing counted for it
                #expect(folders.summaryTotal == 0, "empty folders summed to \(folders.summaryTotal)")
            }
        }

        // MARK: counts arrive off the main thread, then the row is ready

        @MainActor
        @Test func rowsAreCountingUntilTheCounterAnswersThenReadyWithTheHandTableCountedOffTheMainThread() async throws {
            try await sfoRun { env in
                _ = try env.fill("Desktop", photo: 5, pdf: 2, doc: 3)
                _ = try env.fill("Documents", photo: 1, pdf: 7, doc: 6)
                _ = try env.fill("Pictures", photo: 12)
                // Downloads and Movies are missing
                let kit = SFOKit()
                kit.log.hold()
                let folders = kit.make(home: env.home)

                // the counter is blocked, and init came back: the main thread is not waiting for it
                let ticked = folders.rows.filter { $0.ticked }
                #expect(ticked.map { $0.name } == ["Desktop", "Documents", "Pictures"], "ticked: \(ticked.map { $0.name })")
                #expect(ticked.allSatisfy { $0.state == .counting }, "states while held: \(ticked.map { $0.state })")
                let arrived = await sfoEventually { !kit.log.calls.isEmpty }
                #expect(arrived, "the counter was never called")

                kit.log.release()
                #expect(await sfoReady(folders), "rows never became ready: \(folders.rows.map { ($0.name, $0.state) })")

                let byName = Dictionary(uniqueKeysWithValues: folders.rows.map { ($0.name, $0) })
                sfoExpectCounts(try #require(byName["Desktop"]).counts, ["photo": 5, "pdf": 2, "doc": 3], "Desktop")
                sfoExpectCounts(try #require(byName["Documents"]).counts, ["photo": 1, "pdf": 7, "doc": 6], "Documents")
                sfoExpectCounts(try #require(byName["Pictures"]).counts, ["photo": 12], "Pictures")
                #expect(folders.summaryTotal == 10 + 14 + 12, "summary total \(folders.summaryTotal), want 36")
                sfoExpectCounts(folders.summaryCounts, ["photo": 18, "pdf": 9, "doc": 9], "summary")

                #expect(!kit.log.calls.isEmpty && kit.log.calls.allSatisfy { !$0.onMain },
                        "the counter ran on the main thread: \(kit.log.calls.map { $0.onMain })")
                env.assertNothingStarted("counted")
            }
        }

        @MainActor
        @Test func theRealCounterIsTheDefaultAndCountsTempFolders() async throws {
            try await sfoRun { env in
                _ = try env.fill("Pictures", photo: 6, pdf: 1)
                _ = try env.fill("Desktop", doc: 4)
                let kit = SFOKit()
                let folders = kit.makeWithRealCounter(home: env.home)
                #expect(await sfoReady(folders))
                let byName = Dictionary(uniqueKeysWithValues: folders.rows.map { ($0.name, $0) })
                sfoExpectCounts(try #require(byName["Pictures"]).counts, ["photo": 6, "pdf": 1], "Pictures")
                sfoExpectCounts(try #require(byName["Desktop"]).counts, ["doc": 4], "Desktop")
                #expect(folders.summaryTotal == 11, "got \(folders.summaryTotal)")
            }
        }

        // MARK: the estimate

        @MainActor
        @Test func theEstimateIsAfterTheModelDownloadWhileTheModelIsNotWholeThenNumbersAfter() async throws {
            try await sfoRun { env in
                _ = try env.fill("Pictures", photo: 100)
                _ = try env.fill("Desktop", photo: 10, pdf: 50)
                _ = try env.fill("Documents", pdf: 5, doc: 3)
                _ = try env.dir("Downloads")
                // Movies missing
                let kit = SFOKit()
                kit.modelWhole.value = false
                kit.speeds.value = ["photo": 3.0]
                let folders = kit.make(home: env.home)
                #expect(await sfoReady(folders))

                #expect(SetupFolders.readNote == "Photos, PDFs, documents, audio and video are read.")

                // model not whole: the same words for every ticked folder, whatever the speeds
                for row in folders.rows.filter({ $0.ticked }) {
                    #expect(row.estimateText == "after the model download", "\(row.name): \(row.estimateText)")
                }

                // the model becomes whole and photos have a speed: 3.0 s per photo
                kit.modelWhole.value = true
                folders.refreshEstimates()
                let byName = Dictionary(uniqueKeysWithValues: folders.rows.map { ($0.name, $0) })
                // 100 x 3.0 = 300 s
                #expect(try #require(byName["Pictures"]).estimateText == "about 5 min", "Pictures: \(String(describing: byName["Pictures"]?.estimateText))")
                // 10 x 3.0 = 30 s; the 50 pdfs have no measured speed and add nothing
                #expect(try #require(byName["Desktop"]).estimateText == "under a minute", "Desktop: \(String(describing: byName["Desktop"]?.estimateText))")
                // no photo: only pdf and doc, which are not timed in plan 2
                #expect(try #require(byName["Documents"]).estimateText == "nothing to read", "Documents: \(String(describing: byName["Documents"]?.estimateText))")
                #expect(try #require(byName["Downloads"]).estimateText == "nothing to read", "Downloads: \(String(describing: byName["Downloads"]?.estimateText))")

                // each text is also what the Estimator says for that row's counts and the same inputs
                for row in folders.rows.filter({ $0.ticked }) {
                    let said = Estimator.estimate(counts: row.counts, speeds: kit.speeds.value, kindsOn: kit.kindsOn.value, modelWhole: true)
                    #expect(row.estimateText == said.text, "\(row.name): row \"\(row.estimateText)\", Estimator \"\(said.text)\"")
                }

                // no speed measured yet
                kit.speeds.value = [:]
                folders.refreshEstimates()
                for row in folders.rows.filter({ $0.ticked }) {
                    #expect(row.estimateText == "measuring speed", "\(row.name): \(row.estimateText)")
                }

                // photos switched off in kindsOn: nothing is read
                kit.speeds.value = ["photo": 3.0]
                var off = kit.kindsOn.value
                off["photo"] = false
                kit.kindsOn.value = off
                folders.refreshEstimates()
                let afterOff = Dictionary(uniqueKeysWithValues: folders.rows.map { ($0.name, $0) })
                #expect(try #require(afterOff["Pictures"]).estimateText == "nothing to read",
                        "Pictures with photos off: \(String(describing: afterOff["Pictures"]?.estimateText))")
                env.assertNothingStarted("estimates")
            }
        }

        // MARK: the summary counts a file once

        @MainActor
        @Test func theSummaryCountsAFileOnceWhenTwoTickedFoldersOverlapAndUntickingRemovesAFolder() async throws {
            try await sfoRun { env in
                _ = try env.fill("Pictures", photo: 4)
                let documents = try env.fill("Documents", pdf: 3)
                let work = try env.fill("Documents/Work", photo: 1, doc: 2)   // inside Documents
                let kit = SFOKit()
                let folders = kit.make(home: env.home)
                #expect(await sfoReady(folders))

                kit.picks.value = [work]
                folders.addFolder()
                #expect(await sfoReady(folders), "the added row never became ready")

                let byPath = Dictionary(uniqueKeysWithValues: folders.rows.map { ($0.path, $0) })
                sfoExpectCounts(try #require(byPath[documents.path]).counts, ["pdf": 3, "photo": 1, "doc": 2], "Documents holds what lies under it")
                sfoExpectCounts(try #require(byPath[work.path]).counts, ["photo": 1, "doc": 2], "Work")
                // Pictures 4 photos + Documents (3 pdf, 1 photo, 2 doc) with Work inside it: 10 files, not 13
                #expect(folders.summaryTotal == 10, "summary total \(folders.summaryTotal), want 10 (a sum would be 13)")
                sfoExpectCounts(folders.summaryCounts, ["photo": 5, "pdf": 3, "doc": 2], "summary")

                // Work is inside Documents, which is still ticked: nothing leaves the summary
                folders.setTicked(work.path, false)
                #expect(await sfoEventually { folders.summaryTotal == 10 }, "unticking the inner folder changed the summary to \(folders.summaryTotal)")

                // Documents leaves: Work is unticked too, so only Pictures remains
                folders.setTicked(documents.path, false)
                #expect(await sfoEventually { folders.summaryTotal == 4 }, "Pictures alone should be 4, got \(folders.summaryTotal)")
                sfoExpectCounts(folders.summaryCounts, ["photo": 4], "Pictures alone")

                // Work back on, Documents still off: Work's 3 files and Pictures' 4
                folders.setTicked(work.path, true)
                #expect(await sfoReady(folders))
                #expect(await sfoEventually { folders.summaryTotal == 7 }, "Pictures and Work should be 7, got \(folders.summaryTotal)")
                sfoExpectCounts(folders.summaryCounts, ["photo": 5, "doc": 2], "Pictures and Work")

                // nothing ticked: nothing in the summary
                for row in folders.rows { folders.setTicked(row.path, false) }
                #expect(await sfoEventually { folders.summaryTotal == 0 }, "nothing ticked but the summary is \(folders.summaryTotal)")
                sfoExpectCounts(folders.summaryCounts, [:], "nothing ticked")
                env.assertNothingStarted("overlap")
            }
        }

        // MARK: Add folder... through the picker seam

        @MainActor
        @Test func addFolderThroughThePickerAddsATickedRowCountingThenReadyAndSendsNothing() async throws {
            try await sfoRun { env in
                _ = try env.fill("Pictures", photo: 2)
                let kit = SFOKit()
                kit.speeds.value = ["photo": 6.0]
                let folders = kit.make(home: env.home)
                #expect(await sfoReady(folders))
                let before = folders.rows.count

                // a cancelled picker adds nothing
                kit.picks.value = []
                folders.addFolder()
                #expect(kit.pickerCalls.value == 1)
                #expect(folders.rows.count == before, "a cancelled pick added a row")

                // a folder picked while the counter is held: ticked, counting
                let trips = try env.fill("Trips", photo: 10, pdf: 4, doc: 1)
                kit.picks.value = [trips]
                kit.log.hold()
                folders.addFolder()
                #expect(kit.pickerCalls.value == 2, "the picker was called \(kit.pickerCalls.value) times")
                #expect(folders.rows.count == before + 1, "rows: \(folders.rows.map { $0.name })")
                let added = try #require(folders.rows.last, "no rows")
                #expect(added.path == trips.path, "added path \(added.path)")
                #expect(added.name == "Trips")
                #expect(added.ticked, "an added folder is not ticked")
                #expect(added.state == .counting, "added state: \(added.state)")

                kit.log.release()
                #expect(await sfoReady(folders))
                let ready = try #require(folders.rows.first { $0.path == trips.path })
                sfoExpectCounts(ready.counts, ["photo": 10, "pdf": 4, "doc": 1], "Trips")
                // 10 photos x 6.0 s = 60 s
                #expect(ready.estimateText == "about 1 min", "Trips estimate: \(ready.estimateText)")
                #expect(kit.log.callsTouching(trips.path) >= 1, "the added folder was never counted")

                // nothing was told to read it, and Start was not pressed
                env.assertNothingStarted("Add folder")
            }
        }

        // MARK: untick and tick again

        @MainActor
        @Test func untickingAndReTickingAFolderCountsItAgainAndStillSendsNothing() async throws {
            try await sfoRun { env in
                _ = try env.fill("Pictures", photo: 3)
                _ = try env.fill("Desktop", doc: 2)
                let kit = SFOKit()
                let folders = kit.make(home: env.home)
                #expect(await sfoReady(folders))
                let pictures = env.path("Pictures")
                #expect(kit.log.callsTouching(pictures) >= 1)
                #expect(folders.summaryTotal == 5)

                // unticked: no new count, and it leaves the summary
                let afterFirst = kit.log.callsTouching(pictures)
                folders.setTicked(pictures, false)
                let unticked = try #require(folders.rows.first { $0.path == pictures })
                #expect(!unticked.ticked)
                #expect(await sfoEventually { folders.summaryTotal == 2 }, "summary after unticking: \(folders.summaryTotal)")
                #expect(kit.log.callsTouching(pictures) == afterFirst, "unticking called the counter for it")

                // ticked again, with a fresh file on disk: counted again, counting then ready
                try Data(repeating: 1, count: 16).write(to: URL(fileURLWithPath: pictures + "/new-photo.jpg"))
                kit.log.hold()
                folders.setTicked(pictures, true)
                let again = try #require(folders.rows.first { $0.path == pictures })
                #expect(again.ticked)
                #expect(again.state == .counting, "state right after ticking: \(again.state)")
                let counted = await sfoEventually { kit.log.callsTouching(pictures) > afterFirst }
                #expect(counted, "ticking it again did not count it")
                kit.log.release()
                #expect(await sfoReady(folders))
                let done = try #require(folders.rows.first { $0.path == pictures })
                sfoExpectCounts(done.counts, ["photo": 4], "Pictures counted again")
                #expect(await sfoEventually { folders.summaryTotal == 6 }, "summary after ticking again: \(folders.summaryTotal)")
                env.assertNothingStarted("untick and tick again")
            }
        }

        // MARK: one folder, two spellings (plan 5 close, S6.3)
        //
        // On macOS a temp folder is /var/folders/... and the same folder is /private/var/folders/... (/var is a link to
        // /private/var). The suggested rows use the HOME spelling; the picker hands back the other one. Both name one
        // folder, so a file in it is counted, listed and shown once. Counts below are hand counts of the files each test
        // makes. Which spelling a row keeps is not pinned.

        @MainActor
        @Test func aSuggestedFolderPickedAgainUnderItsOtherSpellingIsCountedOnce() async throws {
            try await sfoRun { env in
                let sp = try sfoSpell(env)
                _ = try env.fill("Pictures", photo: 4)
                _ = try env.fill("Documents", photo: 1, pdf: 3, doc: 2)
                let kit = SFOKit()
                let folders = kit.make(home: sp.homeURL)
                #expect(await sfoReady(folders))
                #expect(folders.summaryTotal == 10, "before the pick: \(folders.summaryTotal), want 10")

                kit.picks.value = [sp.canonicalURL("Documents")]
                folders.addFolder()
                #expect(await sfoReady(folders), "rows never became ready: \(folders.rows.map { ($0.path, $0.state) })")

                // Pictures 4 photos + Documents (1 photo, 3 pdf, 2 doc) = 10 files; counting Documents twice would give 16
                #expect(folders.summaryTotal == 10, "summary total \(folders.summaryTotal), want 10 (Documents twice would be 16)")
                sfoExpectCounts(folders.summaryCounts, ["photo": 5, "pdf": 3, "doc": 2], "summary")
            }
        }

        @MainActor
        @Test func aChildPickedUnderTheOtherSpellingOfItsListedParentIsCountedOnce() async throws {
            try await sfoRun { env in
                let sp = try sfoSpell(env)
                _ = try env.fill("Pictures", photo: 4)
                _ = try env.fill("Documents", pdf: 3)
                _ = try env.fill("Documents/Work", photo: 1, doc: 2)
                let kit = SFOKit()
                let folders = kit.make(home: sp.homeURL)
                #expect(await sfoReady(folders))

                kit.picks.value = [sp.canonicalURL("Documents/Work")]
                folders.addFolder()
                #expect(await sfoReady(folders), "rows never became ready: \(folders.rows.map { ($0.path, $0.state) })")

                // Pictures 4 + Documents (3 pdf, then Work's 1 photo and 2 doc inside it) = 10 files, not 13
                #expect(folders.summaryTotal == 10, "summary total \(folders.summaryTotal), want 10 (Work twice would be 13)")
                sfoExpectCounts(folders.summaryCounts, ["photo": 5, "pdf": 3, "doc": 2], "summary")
            }
        }

        @MainActor
        @Test func aParentPickedUnderOneSpellingAndItsChildUnderTheOtherAreCountedOnce() async throws {
            try await sfoRun { env in
                let sp = try sfoSpell(env)
                _ = try env.fill("Archive", pdf: 2)
                _ = try env.fill("Archive/2023", photo: 1, doc: 1)
                let kit = SFOKit()
                let folders = kit.make(home: sp.homeURL)
                #expect(await sfoReady(folders))

                kit.picks.value = [sp.canonicalURL("Archive"), sp.shortURL("Archive/2023")]
                folders.addFolder()
                #expect(await sfoReady(folders), "rows never became ready: \(folders.rows.map { ($0.path, $0.state) })")

                // Archive holds 2 pdf and, in 2023, 1 photo and 1 doc: 4 files; 2023 again would give 6
                #expect(folders.summaryTotal == 4, "summary total \(folders.summaryTotal), want 4 (2023 twice would be 6)")
                sfoExpectCounts(folders.summaryCounts, ["photo": 1, "pdf": 2, "doc": 1], "summary")
            }
        }

        @MainActor
        @Test func addingAFolderUnderItsOtherSpellingAddsNoSecondRow() async throws {
            try await sfoRun { env in
                let sp = try sfoSpell(env)
                _ = try env.fill("Documents", pdf: 2)
                _ = try env.fill("Trips", photo: 3)
                let kit = SFOKit()
                let folders = kit.make(home: sp.homeURL)
                #expect(await sfoReady(folders))
                let before = folders.rows.count

                // a suggested folder, picked under the other spelling
                kit.picks.value = [sp.canonicalURL("Documents")]
                folders.addFolder()
                #expect(await sfoReady(folders))
                #expect(folders.rows.count == before, "a second row for Documents: \(folders.rows.map { $0.path })")
                #expect(folders.rows.filter { $0.name == "Documents" }.count == 1, "Documents rows: \(folders.rows.map { $0.path })")

                // an added folder, added again under the other spelling
                kit.picks.value = [sp.shortURL("Trips")]
                folders.addFolder()
                #expect(await sfoReady(folders))
                #expect(folders.rows.count == before + 1, "rows after Trips: \(folders.rows.map { $0.path })")
                kit.picks.value = [sp.canonicalURL("Trips")]
                folders.addFolder()
                #expect(await sfoReady(folders))
                #expect(folders.rows.count == before + 1, "a second row for Trips: \(folders.rows.map { $0.path })")
                #expect(folders.rows.filter { $0.name == "Trips" }.count == 1, "Trips rows: \(folders.rows.map { $0.path })")
            }
        }
    }
}

// The temp HOME spelled both ways: `short` as the app gets HOME (/var/folders/...), `canonical` as the picker returns it
// (/private/var/folders/...). A temp folder outside /private cannot show the bug, so the test stops there.
private struct SFOSpell {
    let short: String
    let canonical: String
    var homeURL: URL { URL(fileURLWithPath: short, isDirectory: true) }
    func shortURL(_ relative: String) -> URL { URL(fileURLWithPath: short + "/" + relative, isDirectory: true) }
    func canonicalURL(_ relative: String) -> URL { URL(fileURLWithPath: canonical + "/" + relative, isDirectory: true) }
}

private func sfoSpell(_ env: SFOEnv) throws -> SFOSpell {
    let resolved = try #require(realpath(env.home.path, nil), "realpath failed for \(env.home.path)")
    defer { free(resolved) }
    let canonical = String(cString: resolved)
    let prefix = "/private"
    try #require(canonical.hasPrefix(prefix + "/"), "the temp folder \(canonical) is not under /private, so it has no second spelling")
    let short = String(canonical.dropFirst(prefix.count))
    #expect(FileManager.default.fileExists(atPath: short), "\(short) is not the same folder as \(canonical)")
    return SFOSpell(short: short, canonical: canonical)
}
