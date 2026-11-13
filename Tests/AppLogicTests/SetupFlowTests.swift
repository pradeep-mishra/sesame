import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t18, tester step. Written from design sections 1, 2 and 6 ("Setup, before Start"), spec S6, the t18 entry
// and Decisions D11 of plan-2-tasks.md, plus the plan-1 SetupModelTests file (a test, not product source); no
// product source read. The window (SetupWindow, t20) and the folder rows with counts and estimates (SetupFolders,
// t19) are not here: these tests are on SetupFlow (a pure state machine), on SetupModel's Start and tick behaviour,
// and on the first-window rule. Every test runs against a throwaway HOME, so the real Sesame folder is never touched.
//
// SUITE PLACEMENT. HOME is process-wide, and ModelDownloadTests (and its nested SetupModelTests) set it, so this
// suite is nested inside `ModelDownloadTests` too and runs one at a time with them. Side effect:
// `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin. The design and the entry name SetupFlow and fix no signatures; the plan-1 shapes of
// SetupModel (init(files:onStart:onRetry:), refresh(), canStartIndexing, addFolder(_:), pickedFolders,
// startIndexing(), downloadFailed(_:), progressText) are used unchanged. If a shape below is wrong, ask for a test
// change rather than guessing.
//   1. `SetupFlow` is in the `Sesame` target, a value or class with `init()` (the tests hold it in a `var`).
//      `SetupFlow.Step` is an enum with the cases `.welcome`, `.folders`, `.permissions`, `.shortcut`, and
//      `var title: String` with exactly "Welcome", "Folders", "Permissions", "Shortcut" (the kit names the steps).
//      `SetupFlow.steps: [SetupFlow.Step]` is the four steps in that order.
//   2. `flow.step` is the current step, `.welcome` at the start. `flow.next()` and `flow.back()` move one step;
//      `back()` on Welcome and `next()` on Shortcut do nothing. `flow.canGoBack` is false only on Welcome,
//      `flow.canGoNext` is false only on Shortcut, `flow.canFinish` is true only on Shortcut. Nothing in the flow
//      takes the model state: it is the same whether the model is downloading, damaged, failed or whole.
//   3. `flow.showsStartIndexing` is true only while the step is `.folders` (Start indexing belongs to that step).
//      Whether Start is enabled is `SetupModel.canStartIndexing` (plan 1): the model is whole and Start was not yet
//      pressed. It is true also with no folder ticked, and false again after a press (D11).
//   4. Ticks on SetupModel: a folder added with `addFolder(_:)` is ticked. `model.setFolder(_ path: String, ticked: Bool)`
//      ticks or unticks a picked folder; `model.isTicked(_ path: String) -> Bool` reads it. `pickedFolders` still
//      lists every added folder, ticked or not, in the order added.
//   6. `startIndexing()` writes, through `SettingsFile`, `startPressed` true, `indexDeleted` false and `folders`
//      holding every picked folder with `reading` true when ticked and false when not and `code` false, every other
//      field as it was; and only after that write calls `onStart` once. A second press is not a second Start.
//   7. `SetupFlow.needed(settings:modelWhole:) -> Bool`, static: the first-window rule. `settings` is the value
//      `SettingsFile().read()` returns. True for fresh settings; true while the model is not whole whatever else
//      settings say (the launch shows the download); false once Start was pressed with the model whole; false after
//      Delete index (`indexDeleted` true, `startPressed` false) with the model whole.
//   8. The Permissions step's texts are static values: `SetupFlow.permissionFolders: [String]` (four lines, in this
//      order: Desktop, Documents, Downloads, removable volumes; each line starts with that name, any case) and
//      `SetupFlow.neverAskedLine: String` (one line that says Full Disk Access, camera and microphone are never
//      asked; it names all three and holds the word "never", any case).
//      (Pin 7 is superseded by plan-2 fix round B, B2: `needed` is true only while none of `setupFinished`, `startPressed`
//      and `indexDeleted` holds, whatever the model says. See the two rule tests below.)
//   9. Not pinned, on purpose: the wording beyond the above, what `isTicked` says for a folder never added, how
//      `pickedFolders` treats the same folder twice, whether a tick or the code switch writes settings.json (only
//      that `startPressed` stays unset or false and no folder is `reading` true before Start), anything in
//      SetupWindow, SetupFolders or SetupScreen.

// MARK: small helpers (file-private, so nothing collides with the other Setup test files)

private final class SFRecord<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item] = []
    func add(_ item: Item) { lock.lock(); items.append(item); lock.unlock() }
    var all: [Item] { lock.lock(); defer { lock.unlock() }; return items }
}

// A model file of a stated size whose bytes are never held: only a `.partial` of it is made.
private func sfBigFile(_ name: String, size: Int) -> ModelFile {
    ModelFile(name: name, size: size, sha256: String(repeating: "0", count: 64))
}

// A small whole file: the bytes are real, so the size and SHA-256 are right.
private func sfWholeFile(_ name: String, size: Int) -> (data: Data, file: ModelFile) {
    var state: UInt64 = UInt64(size) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var bytes = [UInt8](repeating: 0, count: size)
    for i in 0..<size {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    let data = Data(bytes)
    return (data, ModelFile(name: name, size: size, sha256: sfHex(data)))
}

private func sfHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct SFEnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }
    func whole(_ name: String) -> URL { models.appendingPathComponent(name) }
    func partial(_ name: String) -> URL { models.appendingPathComponent(name + ".partial") }

    func setPartial(_ name: String, bytes: Int) throws {
        let url = partial(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    func makeFolder(_ name: String) throws -> URL {
        let url = home.resolvingSymlinksInPath().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func settingsOnDisk() -> NSDictionary? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    func folderEntriesOnDisk() -> [NSDictionary] {
        (settingsOnDisk()?["folders"] as? [NSDictionary]) ?? []
    }

    // startPressed as stored: a missing file or a missing key reads as not pressed.
    func startPressedOnDisk() -> Bool {
        (settingsOnDisk()?["startPressed"] as? Bool) ?? false
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder and `models/`, runs the body, puts HOME back.
@MainActor
private func sfRun(_ body: @MainActor (SFEnv) throws -> Void) throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-setupflow-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let env = SFEnv(home: home)
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: home)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try fm.createDirectory(at: env.models, withIntermediateDirectories: true)
    try body(env)
}

private func sfSettingsDictionary() throws -> NSDictionary {
    let data = try JSONEncoder().encode(try SettingsFile().read())
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func sfFolderEntriesViaSettingsFile() throws -> [NSDictionary] {
    try #require(try sfSettingsDictionary()["folders"] as? [NSDictionary])
}

private func sfDecode<T: Decodable>(like _: T, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// Settings a person might already have, written by hand from design section 1; the two flags are the cases.
private func sfSeedJSON(startPressed: Bool, indexDeleted: Bool) -> String {
    """
    {
      "version": 3,
      "startPressed": \(startPressed),
      "indexDeleted": \(indexDeleted),
      "folders": [],
      "codeSearchOn": true,
      "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
      "hotkey": "cmd+opt+k",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 1.5, "pdf": 2.25},
      "loginDefaultApplied": true
    }
    """
}

// plan-2 fix round B (B2): the same hand-made file with the new `setupFinished` key, written only when it is true.
private func sfSeedJSONFinished(startPressed: Bool, indexDeleted: Bool, setupFinished: Bool) -> String {
    let finished = setupFinished ? ",\n  \"setupFinished\": true" : ""
    return """
    {
      "version": 3,
      "startPressed": \(startPressed),
      "indexDeleted": \(indexDeleted),
      "folders": [],
      "codeSearchOn": true,
      "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
      "hotkey": "cmd+opt+k",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 1.5, "pdf": 2.25},
      "loginDefaultApplied": true\(finished)
    }
    """
}

private let sfSteps: [(title: String, step: SetupFlow.Step)] = [
    ("Welcome", .welcome), ("Folders", .folders), ("Permissions", .permissions), ("Shortcut", .shortcut),
]

extension ModelDownloadTests {
    @Suite("SetupFlowTests", .serialized)
    struct SetupFlowTests {

        // MARK: the four steps, in order

        @MainActor
        @Test func theStepsAreWelcomeFoldersPermissionsShortcutInThatOrderAndTheFlowStartsOnWelcome() {
            #expect(SetupFlow.steps.map { $0.title } == ["Welcome", "Folders", "Permissions", "Shortcut"],
                    "steps: \(SetupFlow.steps.map { $0.title })")
            #expect(SetupFlow.steps == sfSteps.map { $0.step })
            let flow = SetupFlow()
            #expect(flow.step == .welcome, "the flow starts on \(flow.step.title)")
            for (title, step) in sfSteps {
                #expect(step.title == title, "title of \(step): \(step.title)")
            }
        }

        @MainActor
        @Test func nextMovesOneStepAtATimeAndStopsOnShortcut() {
            var flow = SetupFlow()
            var seen = [flow.step.title]
            for _ in 0..<3 {
                flow.next()
                seen.append(flow.step.title)
            }
            #expect(seen == ["Welcome", "Folders", "Permissions", "Shortcut"], "Next walked: \(seen)")

            // next() on Shortcut does nothing, however often it is pressed
            flow.next()
            flow.next()
            #expect(flow.step == .shortcut, "Next on Shortcut moved to \(flow.step.title)")
        }

        @MainActor
        @Test func backMovesOneStepAtATimeAndStopsOnWelcome() {
            var flow = SetupFlow()
            flow.next(); flow.next(); flow.next()
            #expect(flow.step == .shortcut)

            var seen = [flow.step.title]
            for _ in 0..<3 {
                flow.back()
                seen.append(flow.step.title)
            }
            #expect(seen == ["Shortcut", "Permissions", "Folders", "Welcome"], "Back walked: \(seen)")

            // back() on Welcome does nothing
            flow.back()
            flow.back()
            #expect(flow.step == .welcome, "Back on Welcome moved to \(flow.step.title)")

            // Back after Next returns to the same step, not one before it
            flow.next()
            flow.next()
            flow.back()
            #expect(flow.step == .folders)
        }

        @MainActor
        @Test func theButtonsAreEnabledByStepAndFinishIsOnlyOnShortcut() {
            var flow = SetupFlow()
            // (step title, canGoBack, canGoNext, canFinish), written by hand from the spec
            let table: [(title: String, back: Bool, next: Bool, finish: Bool)] = [
                ("Welcome", false, true, false),
                ("Folders", true, true, false),
                ("Permissions", true, true, false),
                ("Shortcut", true, false, true),
            ]
            for (index, row) in table.enumerated() {
                #expect(flow.step.title == row.title, "walk out of step: \(flow.step.title) not \(row.title)")
                #expect(flow.canGoBack == row.back, "\(row.title): canGoBack \(flow.canGoBack)")
                #expect(flow.canGoNext == row.next, "\(row.title): canGoNext \(flow.canGoNext)")
                #expect(flow.canFinish == row.finish, "\(row.title): canFinish \(flow.canFinish)")
                if index < table.count - 1 { flow.next() }
            }
        }

        @MainActor
        @Test func startIndexingBelongsToTheFoldersStepOnly() {
            var flow = SetupFlow()
            var shown: [String] = []
            for _ in 0..<4 {
                if flow.showsStartIndexing { shown.append(flow.step.title) }
                flow.next()
            }
            #expect(shown == ["Folders"], "Start indexing shown on: \(shown)")

            // and again on the way back
            var back: [String] = []
            for _ in 0..<4 {
                if flow.showsStartIndexing { back.append(flow.step.title) }
                flow.back()
            }
            #expect(back == ["Folders"], "Start indexing shown on the way back on: \(back)")
        }

        // MARK: Next, Back and the folder step stay usable while the model downloads

        @MainActor
        @Test func theFlowMovesTheSameWhileTheModelDownloadsFailsOrIsDamaged() throws {
            try sfRun { env in
                let a = sfBigFile("sf-dl-a.gguf", size: 80_000_000)
                let b = sfBigFile("sf-dl-b.gguf", size: 40_000_000)
                let model = SetupModel(files: [a, b])
                try env.setPartial(a.name, bytes: 20_000_000)
                model.refresh()
                #expect(!model.canStartIndexing, "Start indexing available while the model downloads")

                func walkAllFour(_ state: String) {
                    var flow = SetupFlow()
                    var forward = [flow.step.title]
                    for _ in 0..<3 { flow.next(); forward.append(flow.step.title) }
                    #expect(forward == ["Welcome", "Folders", "Permissions", "Shortcut"], "\(state): forward \(forward)")
                    #expect(flow.canFinish, "\(state): Finish unavailable on Shortcut")
                    var backward = [flow.step.title]
                    for _ in 0..<3 { flow.back(); backward.append(flow.step.title) }
                    #expect(backward == ["Shortcut", "Permissions", "Folders", "Welcome"], "\(state): backward \(backward)")
                }

                walkAllFour("downloading")

                // the folder step is usable too: a folder can be picked while the bytes arrive
                let pictures = try env.makeFolder("Pictures")
                model.addFolder(pictures)
                #expect(model.pickedFolders == [pictures.path], "picked while downloading: \(model.pickedFolders)")
                model.setFolder(pictures.path, ticked: false)
                #expect(!model.isTicked(pictures.path))
                model.setFolder(pictures.path, ticked: true)
                #expect(model.isTicked(pictures.path))
                #expect(!model.canStartIndexing)

                model.downloadFailed("The download stopped because the network is off.")
                model.refresh()
                #expect(model.showsRetry)
                walkAllFour("download failed")

                model.modelWasDamaged()
                model.refresh()
                #expect(model.damagedText != nil)
                walkAllFour("model damaged")

                // none of that started anything
                #expect(!env.startPressedOnDisk(), "startPressed written while the model was not whole")
                #expect(env.folderEntriesOnDisk().allSatisfy { ($0["reading"] as? Bool) != true })
            }
        }

        // MARK: Start indexing: availability

        @MainActor
        @Test func startIndexingIsAvailableOnlyWhenTheModelIsWholeAndNotYetPressedAlsoWithNoFolderTicked() throws {
            try sfRun { env in
                let a = sfWholeFile("sf-avail-a.gguf", size: 300_000)
                let starts = SFRecord<String>()
                let model = SetupModel(files: [a.file], onStart: { starts.add("start") })

                // model not whole, no folder
                model.refresh()
                #expect(!model.canStartIndexing, "available with no model file")

                // model not whole, a folder ticked
                let pictures = try env.makeFolder("Pictures")
                model.addFolder(pictures)
                model.refresh()
                #expect(!model.canStartIndexing, "available with the model not whole and a folder ticked")

                // whole, and the only folder unticked: still available (D11)
                try a.data.write(to: env.whole(a.file.name))
                model.setFolder(pictures.path, ticked: false)
                model.refresh()
                #expect(model.canStartIndexing, "unavailable with the model whole and every folder unticked")

                // whole, a folder ticked
                model.setFolder(pictures.path, ticked: true)
                model.refresh()
                #expect(model.canStartIndexing, "unavailable with the model whole and a folder ticked")
                #expect(starts.all.isEmpty)

                model.startIndexing()
                model.refresh()
                #expect(starts.all.count == 1)
                #expect(!model.canStartIndexing, "still available after Start was pressed")
            }
        }

        @MainActor
        @Test func startIndexingWithNoFolderAtAllIsAllowedAndWritesAnEmptyFolderList() throws {
            try sfRun { env in
                let a = sfWholeFile("sf-nofolder-a.gguf", size: 260_000)
                try a.data.write(to: env.whole(a.file.name))
                let file = SettingsFile()
                try file.write(try sfDecode(like: try file.read(), sfSeedJSON(startPressed: false, indexDeleted: true)))

                let starts = SFRecord<String>()
                let model = SetupModel(files: [a.file], onStart: { starts.add("start") })
                model.refresh()
                #expect(model.pickedFolders.isEmpty)
                #expect(model.canStartIndexing, "Start indexing unavailable with no folder ticked")

                model.startIndexing()

                #expect(starts.all.count == 1, "the Start hook was called \(starts.all.count) times")
                let onDisk = try #require(env.settingsOnDisk(), "no settings.json after Start indexing")
                #expect(onDisk["startPressed"] as? Bool == true)
                #expect(onDisk["indexDeleted"] as? Bool == false)
                #expect(env.folderEntriesOnDisk().isEmpty, "folders on disk: \(env.folderEntriesOnDisk())")
            }
        }

        // MARK: Start indexing: what is written

        @MainActor
        @Test func startWritesReadingTrueForTickedAndFalseForUntickedAndCodeFalseThenCallsTheHookOnce() throws {
            try sfRun { env in
                let a = sfWholeFile("sf-start-a.gguf", size: 280_000)
                try a.data.write(to: env.whole(a.file.name))

                // settings a person already has: nothing outside the three Start fields may change
                let file = SettingsFile()
                try file.write(try sfDecode(like: try file.read(), sfSeedJSON(startPressed: false, indexDeleted: true)))
                let before = try sfSettingsDictionary()
                #expect(before["startPressed"] as? Bool == false)
                #expect(before["indexDeleted"] as? Bool == true)

                // what the hook finds in settings.json at the moment it is called
                let seenAtHook = SFRecord<[String: Bool]>()
                let starts = SFRecord<String>()
                let model = SetupModel(files: [a.file], onStart: {
                    let startPressed = (try? SettingsFile().read().startPressed) ?? false
                    let entries = (try? sfFolderEntriesViaSettingsFile()) ?? []
                    seenAtHook.add(["startPressed": startPressed, "threeEntries": entries.count == 3])
                    starts.add("start")
                })
                let pictures = try env.makeFolder("Pictures")
                let photos = try env.makeFolder("My Photos")
                let screenshots = try env.makeFolder("Screenshots")
                model.addFolder(pictures)
                model.addFolder(photos)
                model.addFolder(screenshots)
                model.setFolder(photos.path, ticked: false)
                model.refresh()
                #expect(model.canStartIndexing)
                #expect(model.isTicked(pictures.path) && !model.isTicked(photos.path) && model.isTicked(screenshots.path))

                model.startIndexing()

                let onDisk = try #require(env.settingsOnDisk(), "no settings.json after Start indexing")
                #expect(onDisk["startPressed"] as? Bool == true, "startPressed on disk: \(String(describing: onDisk["startPressed"]))")
                #expect(onDisk["indexDeleted"] as? Bool == false, "indexDeleted on disk: \(String(describing: onDisk["indexDeleted"]))")

                // every picked folder is listed, with reading as ticked; code is false for each
                let entries = env.folderEntriesOnDisk()
                #expect(entries.count == 3, "folders on disk: \(entries)")
                var readingByPath: [String: Bool] = [:]
                for entry in entries {
                    if let path = entry["path"] as? String { readingByPath[path] = entry["reading"] as? Bool }
                    #expect(entry["code"] as? Bool == false, "code is on for a folder nobody ticked for code: \(entry)")
                }
                #expect(readingByPath == [pictures.path: true, photos.path: false, screenshots.path: true],
                        "reading by path on disk: \(readingByPath)")

                // the same, through SettingsFile
                let after = try sfSettingsDictionary()
                #expect(after["startPressed"] as? Bool == true)
                #expect(after["indexDeleted"] as? Bool == false)
                let viaFile = try sfFolderEntriesViaSettingsFile()
                var viaFileReading: [String: Bool] = [:]
                for entry in viaFile {
                    if let path = entry["path"] as? String { viaFileReading[path] = entry["reading"] as? Bool }
                }
                #expect(viaFileReading == readingByPath, "via SettingsFile: \(viaFileReading)")

                // every other field is as it was
                for key in ["version", "codeSearchOn", "kindsOn", "hotkey", "openWith", "speeds", "loginDefaultApplied"] {
                    #expect((after[key] as? NSObject) == (before[key] as? NSObject), "field \(key) changed: \(String(describing: after[key]))")
                }

                // one hook, called after the settings were written
                #expect(starts.all.count == 1, "the Start hook was called \(starts.all.count) times")
                #expect(seenAtHook.all == [["startPressed": true, "threeEntries": true]],
                        "at the moment of the hook, settings.json held: \(seenAtHook.all)")

                // a second press is not a second Start
                model.startIndexing()
                #expect(starts.all.count == 1, "a second press called the hook again: \(starts.all.count)")
            }
        }

        // MARK: nothing before Start

        @MainActor
        @Test func steppingPickingAndTickingSendNothingAndWriteNoStartPressed() throws {
            try sfRun { env in
                let a = sfWholeFile("sf-quiet-a.gguf", size: 270_000)
                try a.data.write(to: env.whole(a.file.name))
                let starts = SFRecord<String>()
                let model = SetupModel(files: [a.file], onStart: { starts.add("start") })
                model.refresh()
                #expect(model.canStartIndexing, "the test needs a whole model so that only Start itself could send anything")

                func assertQuiet(_ stage: String) {
                    #expect(starts.all.isEmpty, "\(stage): the Start hook was called \(starts.all.count) times")
                    #expect(!env.startPressedOnDisk(), "\(stage): settings.json holds startPressed true")
                    #expect(env.folderEntriesOnDisk().allSatisfy { ($0["reading"] as? Bool) != true },
                            "\(stage): a folder is reading: \(env.folderEntriesOnDisk())")
                }

                var flow = SetupFlow()
                assertQuiet("Welcome")

                flow.next()
                #expect(flow.step == .folders)
                let pictures = try env.makeFolder("Pictures")
                let movies = try env.makeFolder("Movies")
                let extra = try env.makeFolder("Extra")
                model.addFolder(pictures)
                model.addFolder(movies)
                assertQuiet("two folders picked")

                model.setFolder(movies.path, ticked: false)
                assertQuiet("a folder unticked")
                model.setFolder(movies.path, ticked: true)
                assertQuiet("a folder ticked again")
                model.addFolder(extra)
                assertQuiet("a third folder added")

                flow.next()
                assertQuiet("Permissions")
                flow.next()
                #expect(flow.canFinish)
                assertQuiet("Shortcut")
                flow.back(); flow.back(); flow.back()
                assertQuiet("back to Welcome")

                #expect(model.pickedFolders == [pictures.path, movies.path, extra.path], "picked: \(model.pickedFolders)")
                #expect(try SettingsFile().read().startPressed == false)
            }
        }

        // MARK: the first-window rule

        // plan-2 fix round B, item B2 (R2-07): RE-PINNED by the round's fresh tester. The old rule (`!modelWhole || ...`) showed
        // setup again after Start, or after Delete index, whenever the model was not whole (a damaged model brought the
        // setup window back). The ruling: setup shows only until it is finished or Start is pressed, so a model that is not
        // whole after Start or after Delete index is shown by the panel and the menu as Downloading, never by setup.
        //   was: `#expect(SetupFlow.needed(settings: pressed, modelWhole: false), "Start pressed, model not whole")`
        //   now: `#expect(!SetupFlow.needed(settings: pressed, modelWhole: false), ...)`        (same for `deleted`)
        // The test was renamed to say what it holds now. The fresh and never-pressed rows are unchanged.
        @MainActor
        @Test func theFirstWindowRuleShowsSetupForFreshSettingsWhateverTheModelSaysButNotWhenStartOrDeleteIndexCameFirst() throws {
            try sfRun { _ in
                let fresh = try SettingsFile().read()
                #expect(SetupFlow.needed(settings: fresh, modelWhole: false), "fresh settings, model not whole")
                #expect(SetupFlow.needed(settings: fresh, modelWhole: true), "fresh settings, model whole")

                let neverPressed = try sfDecode(like: fresh, sfSeedJSON(startPressed: false, indexDeleted: false))
                #expect(SetupFlow.needed(settings: neverPressed, modelWhole: true), "Start never pressed, model whole")
                #expect(SetupFlow.needed(settings: neverPressed, modelWhole: false), "Start never pressed, model not whole")

                // after Start the download is shown by the panel and the menu, not by the setup window
                let pressed = try sfDecode(like: fresh, sfSeedJSON(startPressed: true, indexDeleted: false))
                #expect(!SetupFlow.needed(settings: pressed, modelWhole: false), "Start pressed, model not whole")
                let deleted = try sfDecode(like: fresh, sfSeedJSON(startPressed: false, indexDeleted: true))
                #expect(!SetupFlow.needed(settings: deleted, modelWhole: false), "index deleted, model not whole")
            }
        }

        // plan-2 fix round B, item B2 (R2-07): `setupFinished` (a new top-level key of settings.json, set by Finish and by
        // Start) joins `startPressed` and `indexDeleted`. `needed(settings:modelWhole:)` keeps its signature and is true only
        // when none of the three holds, whatever the model says. Hand table: (startPressed, indexDeleted, setupFinished).
        @MainActor
        @Test func setupIsNeededOnlyWhenNeitherFinishNorStartNorDeleteIndexCameFirstWhateverTheModelSays() throws {
            try sfRun { _ in
                let fresh = try SettingsFile().read()
                let table: [(name: String, pressed: Bool, deleted: Bool, finished: Bool, needed: Bool)] = [
                    ("nothing happened", false, false, false, true),
                    ("Finish pressed, no Start", false, false, true, false),
                    ("Start pressed", true, false, false, false),
                    ("Delete index", false, true, false, false),
                    ("Finish and Start", true, false, true, false),
                    ("Finish and Delete index", false, true, true, false),
                ]
                for row in table {
                    let settings = try sfDecode(like: fresh, sfSeedJSONFinished(startPressed: row.pressed, indexDeleted: row.deleted, setupFinished: row.finished))
                    for whole in [true, false] {
                        #expect(SetupFlow.needed(settings: settings, modelWhole: whole) == row.needed,
                                "\(row.name), model whole \(whole): needed is \(SetupFlow.needed(settings: settings, modelWhole: whole)), expected \(row.needed)")
                    }
                }
            }
        }

        @MainActor
        @Test func theFirstWindowRuleNeverShowsSetupAgainAfterStartOrAfterDeleteIndexWithTheModelWhole() throws {
            try sfRun { _ in
                let fresh = try SettingsFile().read()

                // after Finish and a relaunch: Start was pressed, the model is whole
                let pressed = try sfDecode(like: fresh, sfSeedJSON(startPressed: true, indexDeleted: false))
                #expect(!SetupFlow.needed(settings: pressed, modelWhole: true), "setup shown again after Start with the model whole")

                // Delete index: startPressed false, indexDeleted true, the model whole: the person starts again from Settings
                let deleted = try sfDecode(like: fresh, sfSeedJSON(startPressed: false, indexDeleted: true))
                #expect(!SetupFlow.needed(settings: deleted, modelWhole: true), "setup came back after Delete index")

                // a fresh Start after a Delete index sets indexDeleted false and startPressed true: still not needed
                #expect(!SetupFlow.needed(settings: pressed, modelWhole: true))
            }
        }

        @MainActor
        @Test func theRuleFollowsTheSettingsStartWritesNotAFlagOfItsOwn() throws {
            try sfRun { env in
                let a = sfWholeFile("sf-rule-a.gguf", size: 255_000)
                try a.data.write(to: env.whole(a.file.name))
                let model = SetupModel(files: [a.file])
                model.addFolder(try env.makeFolder("Pictures"))
                model.refresh()

                #expect(SetupFlow.needed(settings: try SettingsFile().read(), modelWhole: true), "needed before Start")
                model.startIndexing()
                #expect(!SetupFlow.needed(settings: try SettingsFile().read(), modelWhole: true),
                        "needed after Start, read back from settings.json")
            }
        }

        // MARK: the Permissions step's static texts

        @MainActor
        @Test func thePermissionsStepNamesTheFoldersMacOSAsksAboutOnce() {
            let lines = SetupFlow.permissionFolders
            #expect(lines.count == 4, "permission folder lines: \(lines)")
            for (line, name) in zip(lines, ["desktop", "documents", "downloads", "removable"]) {
                #expect(line.lowercased().hasPrefix(name), "line \"\(line)\" does not start with \(name)")
                #expect(!line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        @MainActor
        @Test func thePermissionsStepSaysFullDiskAccessCameraAndMicrophoneAreNeverAsked() {
            let line = SetupFlow.neverAskedLine
            let lower = line.lowercased()
            #expect(lower.contains("full disk access"), "no Full Disk Access in: \(line)")
            #expect(lower.contains("camera"), "no camera in: \(line)")
            #expect(lower.contains("microphone"), "no microphone in: \(line)")
            #expect(lower.contains("never"), "no \"never\" in: \(line)")
            #expect(!line.contains("\n"), "more than one line: \(line)")
        }
    }
}
