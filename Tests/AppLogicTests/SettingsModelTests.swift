import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t21, tester step. Written from the t21 entry of plan-2-tasks.md (its Tests paragraph), the Conventions and
// Decisions D11 of that file, design sections 1 and 3 ("Folder changes": the app writes `settings.json`, hides at once at
// query time through one `Visible` predicate, then sends `folders`; "Setup, before Start": the app only counts and a
// folder added or re-ticked waits for the next Start), spec S6.9, S6.10 and S7.9, and the plan-1 and plan-2 test files as
// the one place existing names are read (`SettingsFile`, `Settings.Folder`, `Visible`, `FolderCounts.count(folders:)`,
// `FolderRow` and the counter seam of t19's `SetupFoldersTests`, `HelperClient.sendFolders()` of `HelperClientTests`).
// No product source was read. Every expected count, text and flag below is written by hand from the folders and the
// settings each test builds. `Visible` is built from the file here, the way the entry says, from the file's own values.
//
// SUITE PLACEMENT. HOME is process-wide (SettingsFile and SesameFolder read it), so this suite is nested inside
// `ModelDownloadTests` like the Setup suites and runs one at a time with them.
//
// API SHAPES these tests pin. The entry names `SettingsModel`, the recording `FoldersSender` seam, the counter of t19,
// `Visible`, `confirmed: true`, `setCodeSearch(on:)` and `canTickCode`, and fixes no signatures. If a shape below is wrong,
// ask for a test change rather than guessing.
//   1. `FoldersSender` is a protocol in the `Sesame` target with one requirement, `func sendFolders()`: "send the
//      `folders` command". `HelperClient` already has that method (it reads settings.json itself and sends the folders
//      that are reading), so the real helper client is the one real conformer and a test recorder is the other. The model
//      calls it after the write it belongs to and never before.
//   2. `SettingsModel` is in the `Sesame` target, a final class, `@MainActor` (every test here is):
//        init(sender: any FoldersSender,
//             counter: @escaping @Sendable ([String]) -> FolderCounts = { FolderCounts.count(folders: $0) },
//             modelWhole: @escaping () -> Bool)
//      The folder list, the stored `speeds` and the stored `kindsOn` are read from `settings.json` through `SettingsFile`
//      (nothing is injected for them); `modelWhole` says whether the model is whole (an unwhole model makes every
//      estimate "after the model download"). The counter is the one of t19 (`SetupFolders`): called off the main thread
//      with a list of folder paths, returning what `FolderCounts.count(folders:)` returns for them. The model never
//      opens a window and never takes a `HelperClient` directly.
//   3. `model.rows: [FolderRow]` is the folder list in the order `settings.json` holds it. `FolderRow` is t19's value:
//      `path`, `name` (last path component), `ticked`, `counts: [String: Int]` (kind to files, an absent kind is 0),
//      `estimateText`, `state` equal to `.counting` or `.ready`. Rows are built at `init`: the folders whose `reading` is
//      true start ticked and are counted at once (`.counting`, then `.ready`); a folder whose `reading` is false starts
//      unticked (what it holds is not pinned). A ticked row's text is `Estimator.estimate`'s text for its counts, the
//      stored `speeds`, the stored `kindsOn` and `modelWhole()`.
//   4. `ticked` is the person's choice as the window shows it; `reading` in `settings.json` is what the helper has been
//      told. They differ on purpose before a Start: a folder added or re-ticked is ticked in the model and its `reading`
//      stays false on disk until Start indexing (design section 3). `startIndexing()` is the one thing that writes
//      `reading` true.
//   5. `model.addFolder(_ url: URL)`: appends a ticked row at the end (`.counting` then `.ready`, counted by the counter,
//      estimate as in 3), stores the folder in `settings.json` with `reading` false and `code` false, writes nothing else,
//      and sends nothing.
//   6. `model.setTicked(_ path: String, _ ticked: Bool)`. Unticking a folder that is reading: writes `reading` false for
//      it through `SettingsFile` (nothing else in the file changes), then calls the sender once; when the write fails
//      nothing is sent and `model.errorText: String?` becomes a non-empty text (it is nil otherwise). Ticking again: the
//      row is counted again (`.counting`, then `.ready` with the counts of that moment), the model sends nothing and
//      writes nothing.
//   7. `model.removeFolder(_ path: String, confirmed: Bool)`: with `confirmed` false nothing changes (not the file, not
//      the rows, nothing sent). With true it writes `settings.json` without that folder, then calls the sender once.
//   8. `model.setKind(_ kind: String, on: Bool)` writes that one kind's flag in `kindsOn` and nothing else; whether it
//      also sends `folders` is not pinned. (The entry says a kind switched off hides its results through `Visible` at
//      once; this is the call a Settings switch makes.)
//   9. `model.setCodeSearch(on: Bool)` writes `codeSearchOn` and nothing else and sends nothing. `model.codeSearchOn` reads
//      it back; `model.canTickCode` is false whether the switch is on or off (plan 2; plan 6 enables it).
//      (Amended in plan-6-t4: `canTickCode` follows the switch, and turning it off after Start sends `folders` once.)
//  10. `model.startIndexing()`: writes `startPressed` true, `indexDeleted` false and, for every folder, `reading` true
//      when it is ticked in the model and false when not (`code` as it was), nothing else, then calls the sender once.
//  11. Not pinned, on purpose: the wording of `errorText`, whether `setTicked` on an already-unticked folder writes, how
//      the same folder added twice is treated, the text of a counting row, the order of work inside `init`, any window,
//      and whether `setKind` sends.

// MARK: small helpers (file-private, so nothing collides with the other test files)

private let smKinds = ["photo", "pdf", "doc", "audio", "video", "code"]

private final class SMBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// Records every counter call; while `hold` is on the counter blocks (off the main thread) until `release`.
private final class SMCounterLog: @unchecked Sendable {
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

// The recording `FoldersSender`. Each call runs `onSend` at that moment, so a test can read the disk and the `Visible`
// predicate as they are when the send happens: that is how "write first, send second" is seen.
private final class SMSender: FoldersSender, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var hook: (@Sendable () -> Void)?

    func onSend(_ body: @escaping @Sendable () -> Void) { lock.lock(); hook = body; lock.unlock() }

    func sendFolders() {
        lock.lock()
        count += 1
        let body = hook
        lock.unlock()
        body?()
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// What was on disk and what `Visible` said at the moment of a send.
private struct SMSeen: Sendable, Equatable {
    var folderPaths: [String]
    var reading: [String: Bool]
    var startPressed: Bool
    var indexDeleted: Bool
    var allowed: [String: Bool]   // path -> Visible.allows(path:kind: "photo")
}

private func smVisible() throws -> Visible {
    let settings = try SettingsFile().read()
    return Visible(folders: settings.folders.filter { $0.reading }, codeSearchOn: settings.codeSearchOn, kindsOn: settings.kindsOn)
}

private func smSeen(probing paths: [String]) -> SMSeen {
    let settings = (try? SettingsFile().read())
    var reading: [String: Bool] = [:]
    for folder in settings?.folders ?? [] { reading[folder.path] = folder.reading }
    let visible = try? smVisible()
    var allowed: [String: Bool] = [:]
    for path in paths { allowed[path] = visible?.allows(path: path, kind: "photo") }
    return SMSeen(folderPaths: (settings?.folders ?? []).map { $0.path }, reading: reading,
                  startPressed: settings?.startPressed ?? false, indexDeleted: settings?.indexDeleted ?? false,
                  allowed: allowed)
}

@MainActor
private final class SMKit {
    let log = SMCounterLog()
    let sender = SMSender()
    let modelWhole = SMBox<Bool>(true)

    func make() -> SettingsModel {
        let log = self.log, modelWhole = self.modelWhole
        return SettingsModel(
            sender: sender,
            counter: { folders in
                log.enter(folders)
                return FolderCounts.count(folders: folders)
            },
            modelWhole: { modelWhole.value })
    }

    func makeWithRealCounter() -> SettingsModel {
        let modelWhole = self.modelWhole
        return SettingsModel(sender: sender, modelWhole: { modelWhole.value })
    }
}

private struct SMEnv {
    let home: URL   // symlink-resolved, so a path compared as text cannot differ by a link
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

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

    func settingsBytes() -> Data? { try? Data(contentsOf: settings) }

    func settingsDictionary() -> NSDictionary? {
        guard let data = settingsBytes() else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    func folderEntries() -> [NSDictionary] { (settingsDictionary()?["folders"] as? [NSDictionary]) ?? [] }

    func reading() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for entry in folderEntries() { if let path = entry["path"] as? String { result[path] = entry["reading"] as? Bool } }
        return result
    }

    func codeFlags() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for entry in folderEntries() { if let path = entry["path"] as? String { result[path] = entry["code"] as? Bool } }
        return result
    }

    // Writes settings.json through SettingsFile from JSON with the given folders: (path, reading, code).
    func seed(folders: [(path: String, reading: Bool, code: Bool)] = [], startPressed: Bool = false, indexDeleted: Bool = false,
              speedsJSON: String = "{\"photo\": 3.0}") throws {
        let entries = folders.map { "{\"path\": \"\($0.path)\", \"code\": \($0.code), \"reading\": \($0.reading)}" }.joined(separator: ", ")
        let json = """
        {
          "version": 3,
          "startPressed": \(startPressed),
          "indexDeleted": \(indexDeleted),
          "folders": [\(entries)],
          "codeSearchOn": false,
          "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
          "hotkey": "cmd+opt+k",
          "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
          "speeds": \(speedsJSON),
          "loginDefaultApplied": true
        }
        """
        let file = SettingsFile()
        let value = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        try file.write(value)
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder, runs the body, puts HOME back and removes the folder.
@MainActor
private func smRun(_ body: (SMEnv) async throws -> Void) async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-settingsmodel-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = SMEnv(home: base.resolvingSymlinksInPath())
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", env.home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        chmod(env.folder.path, 0o700)
        try? fm.removeItem(at: base)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try await body(env)
}

// Polls the main actor until the condition holds; a generous slack, never a tight bound.
@MainActor
private func smEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func smReady(_ model: SettingsModel) async -> Bool {
    await smEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
}

private func smCell(_ counts: [String: Int], _ kind: String) -> Int { counts[kind] ?? 0 }

private func smExpectCounts(_ actual: [String: Int], _ expected: [String: Int], _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
    for kind in smKinds {
        #expect(smCell(actual, kind) == (expected[kind] ?? 0),
                "\(label), \(kind): got \(smCell(actual, kind)), want \(expected[kind] ?? 0) (all: \(actual))",
                sourceLocation: sourceLocation)
    }
}

// Every top-level key of two settings values equal, except the keys named.
private func smOtherFieldsUnchanged(_ before: NSDictionary?, _ after: NSDictionary?, except changed: Set<String>,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
    guard let before, let after else {
        Issue.record("settings.json missing before or after", sourceLocation: sourceLocation)
        return
    }
    for key in ["version", "startPressed", "indexDeleted", "folders", "codeSearchOn", "kindsOn", "hotkey", "openWith",
                "speeds", "loginDefaultApplied"] where !changed.contains(key) {
        #expect((after[key] as? NSObject) == (before[key] as? NSObject),
                "field \(key) changed: before \(String(describing: before[key])), after \(String(describing: after[key]))",
                sourceLocation: sourceLocation)
    }
}

// A moment for a wrongly sent command to show up. Generous, and only ever used to prove an absence.
private func smQuietPeriod() async { try? await Task.sleep(nanoseconds: 400_000_000) }

extension ModelDownloadTests {
    @Suite("SettingsModelTests", .serialized)
    struct SettingsModelTests {

        // MARK: the folder list is read from settings.json

        @MainActor
        @Test func theFolderListIsReadFromSettingsJsonInOrderWithTicksFromReadingAndTheHandCountedFiles() async throws {
            try await smRun { env in
                let desktop = try env.fill("Desktop", photo: 5, pdf: 2, doc: 3)
                let archive = try env.fill("Archive", photo: 9)
                let pictures = try env.fill("Pictures", photo: 12)
                try env.seed(folders: [(desktop.path, true, false), (archive.path, false, false), (pictures.path, true, false)],
                             startPressed: true)
                let before = env.settingsBytes()

                let kit = SMKit()
                kit.log.hold()
                let model = kit.make()

                // init came back with the counter held: the main thread is not waiting for it
                #expect(model.rows.map { $0.path } == [desktop.path, archive.path, pictures.path], "rows: \(model.rows.map { $0.path })")
                #expect(model.rows.map { $0.name } == ["Desktop", "Archive", "Pictures"], "names: \(model.rows.map { $0.name })")
                #expect(model.rows.map { $0.ticked } == [true, false, true], "ticks: \(model.rows.map { $0.ticked })")
                let ticked = model.rows.filter { $0.ticked }
                #expect(ticked.allSatisfy { $0.state == .counting }, "states while held: \(ticked.map { $0.state })")
                #expect(await smEventually { !kit.log.calls.isEmpty }, "the counter was never called")

                kit.log.release()
                #expect(await smReady(model), "rows never became ready: \(model.rows.map { ($0.name, $0.state) })")

                let byName = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.name, $0) })
                let desktopRow = try #require(byName["Desktop"], "no Desktop row")
                let picturesRow = try #require(byName["Pictures"], "no Pictures row")
                smExpectCounts(desktopRow.counts, ["photo": 5, "pdf": 2, "doc": 3], "Desktop")
                smExpectCounts(picturesRow.counts, ["photo": 12], "Pictures")
                // 5 photos x 3.0 s = 15 s, 12 photos x 3.0 s = 36 s: pdf and doc have no measured speed in plan 2
                #expect(desktopRow.estimateText == "under a minute", "Desktop: \(desktopRow.estimateText)")
                #expect(picturesRow.estimateText == "under a minute", "Pictures: \(picturesRow.estimateText)")
                #expect(!kit.log.calls.isEmpty && kit.log.calls.allSatisfy { !$0.onMain },
                        "the counter ran on the main thread: \(kit.log.calls.map { $0.onMain })")
                #expect(kit.log.callsTouching(archive.path) == 0, "a folder that is not reading was counted at init")

                // reading the list wrote nothing and sent nothing
                await smQuietPeriod()
                #expect(kit.sender.calls == 0, "folders was sent \(kit.sender.calls) times by building the model")
                #expect(env.settingsBytes() == before, "settings.json changed by building the model")
            }
        }

        @MainActor
        @Test func theRealCounterIsTheDefaultAndCountsTempFolders() async throws {
            try await smRun { env in
                let pictures = try env.fill("Pictures", photo: 6, pdf: 1)
                try env.seed(folders: [(pictures.path, true, false)])
                let model = SMKit().makeWithRealCounter()
                #expect(await smReady(model))
                let row = try #require(model.rows.first { $0.path == pictures.path })
                smExpectCounts(row.counts, ["photo": 6, "pdf": 1], "Pictures")
            }
        }

        // MARK: adding a folder counts and times it, stores reading false, sends nothing

        @MainActor
        @Test func addingAFolderCountsAndTimesItStoresItWithReadingFalseAndSendsNothing() async throws {
            try await smRun { env in
                let pictures = try env.fill("Pictures", photo: 2)
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true)
                let kit = SMKit()
                let model = kit.make()
                #expect(await smReady(model))
                let before = env.settingsDictionary()
                let rowsBefore = model.rows.count

                let trips = try env.fill("Trips", photo: 40, pdf: 4, doc: 1)
                kit.log.hold()
                model.addFolder(trips)

                // appended last, ticked, counting while the counter is held
                #expect(model.rows.count == rowsBefore + 1, "rows: \(model.rows.map { $0.name })")
                let added = try #require(model.rows.last, "no rows")
                #expect(added.path == trips.path, "added path \(added.path)")
                #expect(added.name == "Trips")
                #expect(added.ticked, "an added folder is not ticked")
                #expect(added.state == .counting, "state while held: \(added.state)")

                kit.log.release()
                #expect(await smReady(model))
                let ready = try #require(model.rows.first { $0.path == trips.path })
                smExpectCounts(ready.counts, ["photo": 40, "pdf": 4, "doc": 1], "Trips")
                // 40 photos x 3.0 s = 120 s
                #expect(ready.estimateText == "about 2 min", "Trips estimate: \(ready.estimateText)")
                #expect(kit.log.callsTouching(trips.path) >= 1, "the added folder was never counted")

                // stored with reading false, code false; the one folder that was reading still is; nothing else changed
                let reading = env.reading()
                #expect(reading[trips.path] == false, "reading on disk for the added folder: \(String(describing: reading[trips.path]))")
                #expect(env.codeFlags()[trips.path] == false, "code on disk for the added folder: \(String(describing: env.codeFlags()[trips.path]))")
                #expect(reading[pictures.path] == true, "the existing folder's reading changed: \(reading)")
                #expect(env.folderEntries().count == 2, "folders on disk: \(env.folderEntries())")
                smOtherFieldsUnchanged(before, env.settingsDictionary(), except: ["folders"])

                // no folders command: its rows stay absent until Start
                await smQuietPeriod()
                #expect(kit.sender.calls == 0, "folders was sent \(kit.sender.calls) times when a folder was added")
            }
        }

        @MainActor
        @Test func anAddedFolderIsTimedAfterTheModelDownloadWhileTheModelIsNotWhole() async throws {
            try await smRun { env in
                try env.seed()
                let kit = SMKit()
                kit.modelWhole.value = false
                let model = kit.make()

                let trips = try env.fill("Trips", photo: 40, pdf: 3)
                model.addFolder(trips)
                #expect(await smReady(model))
                let row = try #require(model.rows.first { $0.path == trips.path })
                smExpectCounts(row.counts, ["photo": 40, "pdf": 3], "Trips")
                #expect(row.estimateText == "after the model download", "estimate with the model not whole: \(row.estimateText)")
                #expect(env.reading()[trips.path] == false)
                #expect(kit.sender.calls == 0)
            }
        }

        // MARK: S6.3: one folder under two path spellings is one row

        // plan-6-t10 part (b). The same real folder added through two spellings (the `/private/var` and the `/var` spelling
        // of the temp folder, and a symlink to it) is one row, one `folders` entry and one counter call, in either order;
        // a second add of a listed folder adds nothing; removing the row leaves no entry of either spelling.
        // Both spellings are built here by hand, never read back from the model.

        @MainActor
        private func smTwoSpellings(_ env: SMEnv, _ order: (first: Int, second: Int), through spellings: (URL) throws -> [String]) async throws {
            let real = try env.fill("Trips", photo: 3, pdf: 1)
            let names = try spellings(real)
            #expect(names.count == 2 && names[0] != names[1], "the two spellings must differ as text: \(names)")
            try env.seed()
            let kit = SMKit()
            let model = kit.make()
            #expect(await smReady(model))

            let first = names[order.first], second = names[order.second]
            model.addFolder(URL(fileURLWithPath: first))
            #expect(await smReady(model))
            model.addFolder(URL(fileURLWithPath: second))
            #expect(await smReady(model))

            #expect(model.rows.count == 1, "rows after adding \(first) then \(second): \(model.rows.map { $0.path })")
            #expect(model.rows.first?.path == first, "the row keeps the spelling of the first add: \(model.rows.map { $0.path })")
            smExpectCounts(model.rows.first?.counts ?? [:], ["photo": 3, "pdf": 1], "Trips")
            let entries = env.folderEntries()
            #expect(entries.count == 1, "folders on disk: \(entries)")
            #expect(entries.first?["path"] as? String == first, "folder on disk: \(entries)")
            #expect(kit.log.callsTouching(first) + kit.log.callsTouching(second) == 1,
                    "the folder was counted \(kit.log.callsTouching(first) + kit.log.callsTouching(second)) times")

            model.addFolder(URL(fileURLWithPath: first))
            model.addFolder(URL(fileURLWithPath: second))
            #expect(await smReady(model))
            #expect(model.rows.count == 1, "rows after re-adding both spellings: \(model.rows.map { $0.path })")
            #expect(env.folderEntries().count == 1, "folders on disk after re-adding: \(env.folderEntries())")
            #expect(kit.log.callsTouching(first) + kit.log.callsTouching(second) == 1,
                    "re-adding a listed folder counted it again")

            model.removeFolder(first, confirmed: true)
            #expect(model.rows.isEmpty, "rows after removing: \(model.rows.map { $0.path })")
            #expect(env.folderEntries().isEmpty, "folders on disk after removing: \(env.folderEntries())")
        }

        private static func varSpellings(_ real: URL) -> [String] {
            let path = real.path
            let other = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
            return [path, other]
        }

        private static func linkSpellings(_ env: SMEnv) -> (URL) throws -> [String] {
            { real in
                let link = env.home.appendingPathComponent("alias-of-trips").path
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real.path)
                return [real.path, link]
            }
        }

        @MainActor
        @Test(arguments: [(0, 1), (1, 0)])
        func theSameFolderUnderTheVarAndPrivateVarSpellingsIsOneRow(first: Int, second: Int) async throws {
            try await smRun { env in
                try await smTwoSpellings(env, (first, second), through: { Self.varSpellings($0) })
            }
        }

        @MainActor
        @Test(arguments: [(0, 1), (1, 0)])
        func aFolderAndASymlinkToItIsOneRow(first: Int, second: Int) async throws {
            try await smRun { env in
                try await smTwoSpellings(env, (first, second), through: Self.linkSpellings(env))
            }
        }

        // MARK: unticking: write first, send second, hidden at once

        @MainActor
        @Test func unTickingWritesReadingFalseThenSendsOnceAndTheFilesAreHiddenBeforeTheSend() async throws {
            try await smRun { env in
                let pictures = try env.fill("Pictures", photo: 3)
                let desktop = try env.fill("Desktop", doc: 2)
                let hiddenFile = pictures.path + "/photo-0.jpg"
                let keptFile = desktop.path + "/note-0.txt"
                try env.seed(folders: [(pictures.path, true, false), (desktop.path, true, false)], startPressed: true)
                let kit = SMKit()
                let model = kit.make()
                #expect(await smReady(model))
                let before = env.settingsDictionary()

                // before: both visible
                #expect(try smVisible().allows(path: hiddenFile, kind: "photo"))
                #expect(try smVisible().allows(path: keptFile, kind: "photo"))

                let seenAtSend = SMBox<[SMSeen]>([])
                kit.sender.onSend { seenAtSend.value += [smSeen(probing: [hiddenFile, keptFile])] }
                model.setTicked(pictures.path, false)

                let row = try #require(model.rows.first { $0.path == pictures.path })
                #expect(!row.ticked, "the row is still ticked")
                #expect(kit.sender.calls == 1, "folders was sent \(kit.sender.calls) times")

                // at the moment of the send the file already said reading false for it, and nothing under it was visible
                let seen = try #require(seenAtSend.value.first, "the sender saw nothing")
                #expect(seen.reading[pictures.path] == false, "at the send, reading for Pictures on disk: \(String(describing: seen.reading[pictures.path]))")
                #expect(seen.reading[desktop.path] == true, "at the send, Desktop's reading: \(String(describing: seen.reading[desktop.path]))")
                #expect(seen.allowed[hiddenFile] == false, "a file under the unticked folder was visible at the send")
                #expect(seen.allowed[keptFile] == true, "a file under a ticked folder was hidden at the send")

                // the same on disk and in Visible afterwards; nothing else in the file changed
                #expect(env.reading()[pictures.path] == false)
                #expect(env.reading()[desktop.path] == true)
                #expect(env.folderEntries().count == 2, "the folder left the list: \(env.folderEntries())")
                #expect(try !smVisible().allows(path: hiddenFile, kind: "photo"))
                #expect(try smVisible().allows(path: keptFile, kind: "photo"))
                smOtherFieldsUnchanged(before, env.settingsDictionary(), except: ["folders"])

                // untick the other one too: one more send, nothing is visible
                model.setTicked(desktop.path, false)
                #expect(kit.sender.calls == 2, "folders was sent \(kit.sender.calls) times after two unticks")
                #expect(try !smVisible().allows(path: keptFile, kind: "photo"))
            }
        }

        @MainActor
        @Test func aFailedWriteSendsNothingAndGivesAnErrorText() async throws {
            try await smRun { env in
                let pictures = try env.fill("Pictures", photo: 3)
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true)
                let kit = SMKit()
                let model = kit.make()
                #expect(await smReady(model))
                #expect(model.errorText == nil, "an error text before anything went wrong: \(String(describing: model.errorText))")
                let before = env.settingsBytes()

                // the Sesame folder is read-only, so a temp file cannot be made in it
                chmod(env.folder.path, 0o500)
                let probe = env.folder.appendingPathComponent("write-probe")
                if FileManager.default.createFile(atPath: probe.path, contents: Data()) {
                    try? FileManager.default.removeItem(at: probe)
                    chmod(env.folder.path, 0o700)
                    Issue.record("this process can write into a read-only folder, so a failed write cannot be made here")
                    return
                }

                model.setTicked(pictures.path, false)
                chmod(env.folder.path, 0o700)

                let text = try #require(model.errorText, "no error text after a write that failed")
                #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the error text is empty")
                #expect(kit.sender.calls == 0, "folders was sent \(kit.sender.calls) times after a failed write")
                await smQuietPeriod()
                #expect(kit.sender.calls == 0, "folders was sent after a failed write, late")
                #expect(env.settingsBytes() == before, "settings.json changed although the write failed")
                #expect(env.reading()[pictures.path] == true)
            }
        }

        // MARK: ticking again counts and times it again and waits for Start

        // Re-pinned in fix round B: this test used to expect settings.json byte-identical after a re-tick. The
        // controller ruled that pending ticks persist as a per-folder `ticked` key (omitted when equal to `reading`),
        // so a re-tick is stored. It now expects `ticked` true on the folder, `reading` still false, nothing else
        // changed, and nothing sent.
        @MainActor
        @Test func reTickingCountsItAgainAndSendsAndWritesNothing() async throws {
            try await smRun { env in
                let pictures = try env.fill("Pictures", photo: 3)
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true)
                let kit = SMKit()
                let model = kit.make()
                #expect(await smReady(model))
                let first = kit.log.callsTouching(pictures.path)
                #expect(first >= 1)

                model.setTicked(pictures.path, false)
                #expect(kit.sender.calls == 1)
                #expect(env.reading()[pictures.path] == false)
                let afterUntick = try #require(env.settingsDictionary())

                // a fresh photo on disk: counting again must see it
                try Data(repeating: 1, count: 16).write(to: URL(fileURLWithPath: pictures.path + "/new-photo.jpg"))
                kit.log.hold()
                model.setTicked(pictures.path, true)
                let again = try #require(model.rows.first { $0.path == pictures.path })
                #expect(again.ticked)
                #expect(again.state == .counting, "state right after ticking: \(again.state)")
                #expect(await smEventually { kit.log.callsTouching(pictures.path) > first }, "ticking it again did not count it")
                kit.log.release()
                #expect(await smReady(model))
                let done = try #require(model.rows.first { $0.path == pictures.path })
                smExpectCounts(done.counts, ["photo": 4], "Pictures counted again")
                // 4 photos x 3.0 s = 12 s
                #expect(done.estimateText == "under a minute", "estimate after ticking again: \(done.estimateText)")

                // it waits for Start: nothing sent, reading still false on disk, only the folder's `ticked` key stored
                await smQuietPeriod()
                #expect(kit.sender.calls == 1, "ticking again sent folders: \(kit.sender.calls) sends in all")
                #expect(env.reading()[pictures.path] == false, "ticking again wrote reading true before Start")
                let stored = env.folderEntries().first { ($0["path"] as? String) == pictures.path }
                #expect(stored?["ticked"] as? Bool == true, "the re-tick was not stored as ticked: \(String(describing: stored))")
                func withoutTicked(_ settings: NSDictionary) -> NSDictionary {
                    let copy = NSMutableDictionary(dictionary: settings)
                    let folders = ((settings["folders"] as? [NSDictionary]) ?? []).map { entry -> NSDictionary in
                        guard (entry["path"] as? String) == pictures.path else { return entry }
                        let e = NSMutableDictionary(dictionary: entry)
                        e.removeObject(forKey: "ticked")
                        return e
                    }
                    copy["folders"] = folders
                    return copy
                }
                let afterRetick = try #require(env.settingsDictionary())
                #expect(withoutTicked(afterRetick) == withoutTicked(afterUntick),
                        "ticking again changed settings.json beyond the folder's ticked key")
            }
        }

        // MARK: removing a folder

        @MainActor
        @Test func removingNeedsConfirmedTrueAndThenWritesFirstAndSendsOnce() async throws {
            try await smRun { env in
                let pictures = try env.fill("Pictures", photo: 3)
                let desktop = try env.fill("Desktop", doc: 2)
                let removedFile = pictures.path + "/photo-0.jpg"
                let keptFile = desktop.path + "/note-0.txt"
                try env.seed(folders: [(pictures.path, true, false), (desktop.path, true, false)], startPressed: true)
                let kit = SMKit()
                let model = kit.make()
                #expect(await smReady(model))
                let before = env.settingsDictionary()
                let bytes = env.settingsBytes()
                let rowsBefore = model.rows.map { $0.path }

                // without the confirmation nothing changes
                model.removeFolder(pictures.path, confirmed: false)
                await smQuietPeriod()
                #expect(model.rows.map { $0.path } == rowsBefore, "a row left without the confirmation: \(model.rows.map { $0.path })")
                #expect(env.settingsBytes() == bytes, "settings.json changed without the confirmation")
                #expect(kit.sender.calls == 0, "folders was sent without the confirmation")
                #expect(try smVisible().allows(path: removedFile, kind: "photo"))

                // with it: written, then sent once
                let seenAtSend = SMBox<[SMSeen]>([])
                kit.sender.onSend { seenAtSend.value += [smSeen(probing: [removedFile, keptFile])] }
                model.removeFolder(pictures.path, confirmed: true)

                #expect(!model.rows.contains { $0.path == pictures.path }, "the removed folder is still listed: \(model.rows.map { $0.path })")
                #expect(model.rows.map { $0.path } == [desktop.path])
                #expect(kit.sender.calls == 1, "folders was sent \(kit.sender.calls) times")
                let seen = try #require(seenAtSend.value.first, "the sender saw nothing")
                #expect(!seen.folderPaths.contains(pictures.path), "at the send the folder was still in settings.json: \(seen.folderPaths)")
                #expect(seen.folderPaths == [desktop.path], "folders on disk at the send: \(seen.folderPaths)")
                #expect(seen.allowed[removedFile] == false, "a file of the removed folder was visible at the send")
                #expect(seen.allowed[keptFile] == true, "a file of the kept folder was hidden at the send")

                #expect(env.folderEntries().compactMap { $0["path"] as? String } == [desktop.path])
                #expect(try !smVisible().allows(path: removedFile, kind: "photo"))
                #expect(try smVisible().allows(path: keptFile, kind: "photo"))
                smOtherFieldsUnchanged(before, env.settingsDictionary(), except: ["folders"])
            }
        }

        // MARK: a folder inside another picked folder

        @MainActor
        @Test func aFileStaysVisibleUnderTheOuterFolderWhenTheInnerOneIsUntickedOrRemoved() async throws {
            try await smRun { env in
                let documents = try env.fill("Documents", pdf: 1)
                let work = try env.fill("Documents/Work", photo: 2)   // inside Documents
                let inWork = work.path + "/photo-0.jpg"
                let inDocuments = documents.path + "/paper-0.pdf"
                let outside = env.path("Elsewhere/photo-0.jpg")
                try env.seed(folders: [(documents.path, true, false), (work.path, true, false)], startPressed: true)
                let kit = SMKit()
                let model = kit.make()
                #expect(await smReady(model))

                // the inner folder unticked: its files are still under the ticked outer folder
                model.setTicked(work.path, false)
                #expect(try smVisible().allows(path: inWork, kind: "photo"), "a file under the outer folder was hidden by unticking the inner one")
                #expect(try smVisible().allows(path: inDocuments, kind: "photo"))
                #expect(try !smVisible().allows(path: outside, kind: "photo"), "a file under no folder is visible")

                // the inner folder removed: the same
                model.removeFolder(work.path, confirmed: true)
                #expect(try smVisible().allows(path: inWork, kind: "photo"), "a file under the outer folder was hidden by removing the inner one")

                // the outer folder unticked now: both go at once
                model.setTicked(documents.path, false)
                #expect(try !smVisible().allows(path: inWork, kind: "photo"), "a file under the unticked outer folder is still visible")
                #expect(try !smVisible().allows(path: inDocuments, kind: "photo"))
            }
        }

        @MainActor
        @Test func removingTheOuterFolderHidesWhatLiesOutsideTheInnerOneAndKeepsTheInnerOnesFiles() async throws {
            try await smRun { env in
                let documents = try env.fill("Documents", pdf: 2)
                let work = try env.fill("Documents/Work", photo: 2)
                let inWork = work.path + "/photo-0.jpg"
                let inDocuments = documents.path + "/paper-0.pdf"
                try env.seed(folders: [(documents.path, true, false), (work.path, true, false)], startPressed: true)
                let kit = SMKit()
                let model = kit.make()
                #expect(await smReady(model))

                model.removeFolder(documents.path, confirmed: true)
                #expect(try !smVisible().allows(path: inDocuments, kind: "photo"), "a file of the removed outer folder is still visible")
                #expect(try smVisible().allows(path: inWork, kind: "photo"), "a file of the folder that is still ticked was hidden")
                #expect(kit.sender.calls == 1)
            }
        }

        // MARK: a kind switched off hides its results at once

        @MainActor
        @Test func aKindSwitchedOffHidesItsResultsThroughVisibleAtOnceAndOnlyThatKind() async throws {
            try await smRun { env in
                let pictures = try env.fill("Pictures", photo: 2, pdf: 2)
                let photoFile = pictures.path + "/photo-0.jpg"
                let pdfFile = pictures.path + "/paper-0.pdf"
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true)
                let kit = SMKit()
                let model = kit.make()
                #expect(await smReady(model))
                let before = env.settingsDictionary()

                #expect(try smVisible().allows(path: photoFile, kind: "photo"))
                #expect(try smVisible().allows(path: pdfFile, kind: "pdf"))

                model.setKind("photo", on: false)
                #expect(try !smVisible().allows(path: photoFile, kind: "photo"), "photos are still visible with the photo kind off")
                #expect(try smVisible().allows(path: pdfFile, kind: "pdf"), "switching photos off hid the PDFs")
                let kinds = env.settingsDictionary()?["kindsOn"] as? [String: Bool]
                #expect(kinds?["photo"] == false, "kindsOn on disk: \(String(describing: kinds))")
                #expect(kinds?["pdf"] == true && kinds?["doc"] == true && kinds?["audio"] == true && kinds?["video"] == true && kinds?["code"] == true,
                        "another kind changed: \(String(describing: kinds))")
                smOtherFieldsUnchanged(before, env.settingsDictionary(), except: ["kindsOn"])

                model.setKind("photo", on: true)
                #expect(try smVisible().allows(path: photoFile, kind: "photo"), "photos are hidden after the kind was switched back on")
                #expect((env.settingsDictionary()?["kindsOn"] as? [String: Bool])?["photo"] == true)
            }
        }

        // plan-5-t7 (new). The header pin 8 above ("whether it also sends `folders` is not pinned") is closed for the four kinds the
        // helper now skips when they are off (spec S4.6, S7). Entry: `model.setKind("audio", on: false)` writes `kindsOn.audio =
        // false` before anything else and sends nothing to the helper (nothing to read: the hiding is at query time through
        // `Visible`); `setKind("audio", on: true)` writes it and then sends `folders` once so the helper reconciles. Same for
        // "video", "pdf" and "doc". The send hook reads settings.json at the moment of the send, so "written first, sent second" is
        // seen from the disk. (Whether "photo" sends when it goes on is not pinned.) The off half holds today (setKind writes the
        // flag and sends nothing), so it is a guard; the on half is red until `setKind` sends.
        @MainActor
        @Test func aReaderKindSwitchedOffIsWrittenAndHiddenAndSendsNothingAndSwitchedOnIsWrittenFirstThenSendsFoldersOnce() async throws {
            try await smRun { env in
                let media = try env.fill("Media", photo: 1, pdf: 1, doc: 1)
                let samples: [(kind: String, path: String)] = [
                    ("photo", media.path + "/harbour.jpg"), ("pdf", media.path + "/lease.pdf"), ("doc", media.path + "/notes.txt"),
                    ("audio", media.path + "/interview.m4a"), ("video", media.path + "/safari.mp4"),
                ]
                try env.seed(folders: [(media.path, true, false)], startPressed: true)

                for kind in ["audio", "video", "pdf", "doc"] {
                    let kit = SMKit()
                    let model = kit.make()
                    #expect(await smReady(model), "\(kind): the folder never became ready")
                    let before = env.settingsDictionary()
                    let atSend = SMBox<[[String: Bool]]>([])
                    kit.sender.onSend { atSend.value += [(try? SettingsFile().read())?.kindsOn ?? [:]] }
                    let allOn: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]
                    var oneOff = allOn
                    oneOff[kind] = false

                    model.setKind(kind, on: false)
                    #expect(env.settingsDictionary()?["kindsOn"] as? [String: Bool] == oneOff,
                            "\(kind) off: kindsOn on disk is \(String(describing: env.settingsDictionary()?["kindsOn"])), expected \(oneOff)")
                    smOtherFieldsUnchanged(before, env.settingsDictionary(), except: ["kindsOn"])
                    let hidden = try smVisible()
                    for sample in samples {
                        #expect(hidden.allows(path: sample.path, kind: sample.kind) == (sample.kind != kind),
                                "\(kind) off: \(sample.kind) is \(hidden.allows(path: sample.path, kind: sample.kind) ? "shown" : "hidden"), expected \(sample.kind != kind ? "shown" : "hidden")")
                    }
                    await smQuietPeriod()
                    #expect(kit.sender.calls == 0, "\(kind) switched off sent folders \(kit.sender.calls) times")

                    model.setKind(kind, on: true)
                    #expect(await smEventually { kit.sender.calls >= 1 }, "\(kind) switched on sent no folders")
                    await smQuietPeriod()
                    #expect(kit.sender.calls == 1, "\(kind) switched on sent folders \(kit.sender.calls) times, expected once")
                    #expect(atSend.value == [allOn], "\(kind): settings.json read at the moment of the send was \(atSend.value), expected the kind already on: \(allOn)")
                    #expect(env.settingsDictionary()?["kindsOn"] as? [String: Bool] == allOn, "\(kind) on: kindsOn on disk is \(String(describing: env.settingsDictionary()?["kindsOn"]))")
                    smOtherFieldsUnchanged(before, env.settingsDictionary(), except: [])
                    let shown = try smVisible()
                    #expect(samples.allSatisfy { shown.allows(path: $0.path, kind: $0.kind) }, "\(kind) on: a kind is still hidden")
                }
            }
        }

        // MARK: Start indexing in Settings

        @MainActor
        @Test func startIndexingWritesReadingForTheTickedFoldersAndStartPressedThenSendsOnce() async throws {
            try await smRun { env in
                let pictures = try env.fill("Pictures", photo: 3)
                let archive = try env.fill("Archive", photo: 2)
                let trips = try env.fill("Trips", photo: 4)
                // Delete index was pressed earlier: nothing started, the folders were kept
                try env.seed(folders: [(pictures.path, false, false), (archive.path, false, false)], startPressed: false, indexDeleted: true)
                let kit = SMKit()
                let model = kit.make()
                let before = env.settingsDictionary()

                // the person ticks Pictures, adds Trips, leaves Archive unticked
                model.setTicked(pictures.path, true)
                model.addFolder(trips)
                #expect(await smReady(model))
                await smQuietPeriod()
                #expect(kit.sender.calls == 0, "folders was sent before Start: \(kit.sender.calls)")
                #expect(env.reading().values.allSatisfy { $0 == false }, "a folder is reading before Start: \(env.reading())")
                #expect(env.settingsDictionary()?["startPressed"] as? Bool == false)

                let seenAtSend = SMBox<[SMSeen]>([])
                kit.sender.onSend { seenAtSend.value += [smSeen(probing: [pictures.path + "/photo-0.jpg", archive.path + "/photo-0.jpg"])] }
                model.startIndexing()

                #expect(kit.sender.calls == 1, "folders was sent \(kit.sender.calls) times by Start indexing")
                let seen = try #require(seenAtSend.value.first, "the sender saw nothing")
                #expect(seen.startPressed, "at the send, startPressed was not yet written")
                #expect(!seen.indexDeleted, "at the send, indexDeleted was still true")
                #expect(seen.reading == [pictures.path: true, archive.path: false, trips.path: true],
                        "reading on disk at the send: \(seen.reading)")

                let onDisk = try #require(env.settingsDictionary(), "no settings.json after Start indexing")
                #expect(onDisk["startPressed"] as? Bool == true, "startPressed on disk: \(String(describing: onDisk["startPressed"]))")
                #expect(onDisk["indexDeleted"] as? Bool == false, "indexDeleted on disk: \(String(describing: onDisk["indexDeleted"]))")
                #expect(env.reading() == [pictures.path: true, archive.path: false, trips.path: true], "reading on disk: \(env.reading())")
                #expect(env.codeFlags().values.allSatisfy { $0 == false }, "a folder has code on: \(env.codeFlags())")
                #expect(env.folderEntries().count == 3, "folders on disk: \(env.folderEntries())")
                smOtherFieldsUnchanged(before, env.settingsDictionary(), except: ["startPressed", "indexDeleted", "folders"])

                // the files of the ticked folders are visible now, the unticked folder's are not
                #expect(try smVisible().allows(path: pictures.path + "/photo-0.jpg", kind: "photo"))
                #expect(try !smVisible().allows(path: archive.path + "/photo-0.jpg", kind: "photo"))
            }
        }
    }
}

// MARK: plan-2 fix round B, tester step, item B1 (R2-01, R2-02): the pending tick
//
// Everything above is sealed and unchanged. Written from the fix-round document ("Pending ticks ... store a per-folder
// pending tick in `settings.json` through `SettingsFile` (a new per-folder key, `ticked`, default equal to `reading`, so
// older files read the same). `reading` stays what the helper reads. Unticking or removing a folder writes `reading` false
// at once ... and syncs"), the review report (R2-01, R2-02) and the pins of the sealed tests above. No product source was
// read. Every expected value is written by hand from the folders each test builds.
//
// API SHAPES B1 pins (the key names are the document's; the rest is this file's pick):
//   1. A folder entry in settings.json may carry `"ticked": <Bool>`. `SettingsModel.rows[].ticked` is read from it at
//      `init`; a missing key reads as the entry's `reading` (the sealed seed files have no key and read as before).
//   2. `addFolder(_:)` stores the folder with `reading` false and `ticked` true. `setTicked(path, false)` stores `reading`
//      false and `ticked` false (and sends once, as the sealed tests pin). `setTicked(path, true)` stores `ticked` true and
//      leaves `reading` false, and sends nothing (it waits for Start indexing). `startIndexing()` stores `reading` equal
//      to the row's tick for every folder. A stored `ticked` equal to `reading` may be omitted from the file (see
//      SettingsFileTickedTests); the tests below read the tick as "the `ticked` key, else `reading`".
//   3. A new `SettingsModel` over the same file (the person closes Settings and opens it again, or relaunches) shows the
//      same ticks: a pending folder is ticked, counted again (`.counting` then `.ready`), and still not reading.

private extension SMEnv {
    // The tick of a folder as the file holds it: the `ticked` key, else `reading` (the old shape).
    func tickedOnDisk(_ path: String) -> Bool? {
        guard let entry = folderEntries().first(where: { ($0["path"] as? String) == path }) else { return nil }
        return (entry["ticked"] as? Bool) ?? (entry["reading"] as? Bool)
    }

    // Writes settings.json through SettingsFile with `ticked` given per folder.
    func seedTicks(_ folders: [(path: String, reading: Bool, ticked: Bool)], startPressed: Bool = true) throws {
        let entries = folders.map {
            "{\"path\": \"\($0.path)\", \"code\": false, \"reading\": \($0.reading), \"ticked\": \($0.ticked)}"
        }.joined(separator: ", ")
        let json = """
        {
          "version": 3,
          "startPressed": \(startPressed),
          "indexDeleted": false,
          "folders": [\(entries)],
          "codeSearchOn": false,
          "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
          "hotkey": "cmd+opt+k",
          "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
          "speeds": {"photo": 3.0},
          "loginDefaultApplied": true
        }
        """
        let value = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        try SettingsFile().write(value)
    }
}

extension ModelDownloadTests.SettingsModelTests {

    @MainActor
    @Test func aFolderAddedAfterStartIsStoredAsAPendingTickAndComesBackTickedWhenTheModelIsBuiltAgain() async throws {
        try await smRun { env in
            let pictures = try env.fill("Pictures", photo: 2)
            try env.seed(folders: [(pictures.path, true, false)], startPressed: true)
            let first = SMKit()
            let model = first.make()
            #expect(await smReady(model))

            let trips = try env.fill("Trips", photo: 40, pdf: 1)
            model.addFolder(trips)
            #expect(await smReady(model))

            // on disk: waiting, not reading, and the tick is kept
            #expect(env.reading()[trips.path] == false, "reading for the added folder: \(String(describing: env.reading()[trips.path]))")
            #expect(env.tickedOnDisk(trips.path) == true, "the pending tick of the added folder is not stored: \(env.folderEntries())")
            #expect(try !smVisible().allows(path: trips.path + "/photo-0.jpg", kind: "photo"), "results of a folder that waits for Start are visible")

            // Settings is closed and opened again: a new model over the same file
            let second = SMKit()
            let reopened = second.make()
            let row = try #require(reopened.rows.first { $0.path == trips.path }, "the added folder is gone after the model was built again: \(reopened.rows.map { $0.path })")
            #expect(row.ticked, "the pending folder comes back unticked")
            #expect(reopened.rows.map { $0.ticked } == [true, true], "ticks after reopening: \(reopened.rows.map { ($0.name, $0.ticked) })")
            #expect(await smReady(reopened), "the reopened rows never became ready")
            let ready = try #require(reopened.rows.first { $0.path == trips.path })
            smExpectCounts(ready.counts, ["photo": 40, "pdf": 1], "Trips after reopening")
            #expect(second.log.callsTouching(trips.path) >= 1, "a pending folder was not counted when the model was built")

            // building it again changed nothing and sent nothing: it still waits for Start
            await smQuietPeriod()
            #expect(second.sender.calls == 0 && first.sender.calls == 0, "folders was sent: \(first.sender.calls) and \(second.sender.calls)")
            #expect(env.reading()[trips.path] == false)
        }
    }

    @MainActor
    @Test func unTickingAndTickingAgainStoresTheTicksAndKeepsReadingFalseUntilStart() async throws {
        try await smRun { env in
            let pictures = try env.fill("Pictures", photo: 3)
            let desktop = try env.fill("Desktop", doc: 2)
            try env.seed(folders: [(pictures.path, true, false), (desktop.path, true, false)], startPressed: true)
            let kit = SMKit()
            let model = kit.make()
            #expect(await smReady(model))

            model.setTicked(pictures.path, false)
            #expect(kit.sender.calls == 1)
            #expect(env.reading()[pictures.path] == false)
            #expect(env.tickedOnDisk(pictures.path) == false, "the untick is not stored: \(env.folderEntries())")
            let unticked = kit.make()
            #expect(unticked.rows.first { $0.path == pictures.path }?.ticked == false, "a reopened model shows the unticked folder ticked")
            #expect(unticked.rows.first { $0.path == desktop.path }?.ticked == true)

            model.setTicked(pictures.path, true)
            #expect(await smReady(model))
            #expect(env.reading()[pictures.path] == false, "ticking again wrote reading true before Start")
            #expect(env.tickedOnDisk(pictures.path) == true, "the new tick is not stored: \(env.folderEntries())")
            #expect(try !smVisible().allows(path: pictures.path + "/photo-0.jpg", kind: "photo"), "results show before Start")
            let reopened = SMKit().make()
            #expect(reopened.rows.first { $0.path == pictures.path }?.ticked == true, "a reopened model does not show the pending tick")
            #expect(await smReady(reopened))

            await smQuietPeriod()
            #expect(kit.sender.calls == 1, "ticking again sent folders: \(kit.sender.calls) in all")
        }
    }

    @MainActor
    @Test func aModelBuiltFromAFileWithPendingTicksStartsThemAndOnlyThem() async throws {
        try await smRun { env in
            let pictures = try env.fill("Pictures", photo: 3)
            let archive = try env.fill("Archive", photo: 2)
            let trips = try env.fill("Trips", photo: 4)
            // Pictures reads; Archive was unticked (reading false, ticked false); Trips was added and waits
            try env.seedTicks([(pictures.path, true, true), (archive.path, false, false), (trips.path, false, true)], startPressed: true)
            let kit = SMKit()
            let model = kit.make()
            #expect(model.rows.map { $0.ticked } == [true, false, true], "ticks read from the file: \(model.rows.map { ($0.name, $0.ticked) })")
            #expect(await smReady(model))
            let before = env.settingsDictionary()

            model.startIndexing()

            #expect(env.reading() == [pictures.path: true, archive.path: false, trips.path: true], "reading after Start: \(env.reading())")
            #expect(kit.sender.calls == 1, "folders was sent \(kit.sender.calls) times by Start")
            #expect(env.settingsDictionary()?["startPressed"] as? Bool == true)
            #expect(env.settingsDictionary()?["indexDeleted"] as? Bool == false)
            for path in [pictures.path, archive.path, trips.path] {
                #expect(env.tickedOnDisk(path) == env.reading()[path], "after Start the tick of \(path) and what is read differ: \(env.folderEntries())")
            }
            smOtherFieldsUnchanged(before, env.settingsDictionary(), except: ["folders"])
            #expect(try smVisible().allows(path: trips.path + "/photo-0.jpg", kind: "photo"), "the folder that waited is still hidden after Start")
            #expect(try !smVisible().allows(path: archive.path + "/photo-0.jpg", kind: "photo"))

            // and the next model has nothing left waiting
            #expect(SMKit().make().rows.map { $0.ticked } == [true, false, true])
        }
    }

    @MainActor
    @Test func aFileWithoutTheTickedKeyReadsTicksFromReadingAsBefore() async throws {
        try await smRun { env in
            let pictures = try env.fill("Pictures", photo: 2)
            let archive = try env.fill("Archive", photo: 2)
            try env.seed(folders: [(pictures.path, true, false), (archive.path, false, false)], startPressed: true)   // no `ticked` key
            let model = SMKit().make()
            #expect(model.rows.map { $0.ticked } == [true, false], "ticks of an older file: \(model.rows.map { ($0.name, $0.ticked) })")
        }
    }
}
