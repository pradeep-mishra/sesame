import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t28, tester step. Written from design sections 1, 2, 7 and 9 ("Setup, before Start"), spec S6 and the
// t28 entry only; no product source read. The window itself (SetupWindow, FolderPicker) is checked by the kit
// (S6.5 to S6.7, S6.12, S8.13); these tests are on SetupModel alone. Every test runs against a throwaway HOME, so
// the real Sesame folder is never touched. No server is needed: the model reads only the files under `models/`.
// A large synthetic size is a sparse `.partial` file (truncate to N bytes), so a "100 MB" model costs nothing.
//
// SUITE PLACEMENT. HOME is process-wide and ModelDownloadTests (t26) and its nested ModelWatcherTests (t27) set
// it, so this suite is nested inside `ModelDownloadTests` too and runs one at a time with them. Side effect:
// `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin (the design names "setup" and "SetupModel" and fixes no signatures; if a shape is
// wrong, ask for a test change rather than guessing).
//   1. `SetupModel` is in the `Sesame` target (`@testable import Sesame`), a final class. It may be
//      `@MainActor`: every test is `@MainActor`, so both an isolated and a nonisolated class compile.
//   2. `init(files: [ModelFile] = ModelFiles.all, onStart: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {})`.
//      `files` is the injection point for a synthetic expected total. `onStart` is the one hook that t35 connects
//      to `HelperClient`; `onRetry` is called once by `retry()` (the app restarts the download there).
//   3. Progress is derived from disk, never copied (design section 1, "download = bytes of `.partial`"):
//      `func refresh()` re-reads, now, the files under `<Sesame folder>/models/` and updates every property below
//      before it returns. A file under its real name is whole and counts as its full size; a `<name>.partial`
//      counts as its size on disk. Nothing in these tests waits, so the model may also poll by itself.
//   4. `var progressText: String` is exactly "<N> of <M> MB": N is the bytes on disk and M the sum of the
//      expected sizes, both in decimal megabytes (1,000,000 bytes) rounded to the nearest whole number. The design
//      gives 864,676,480 bytes as the spec's "865 MB", which fixes both the unit (not 1,048,576) and the rounding
//      (not down). With no files and no `.partial`, "0 of 865 MB" for the default files.
//   5. Errors. `func downloadFailed(_ text: String)` is how the download side reports a failure (the app calls it
//      when `ModelDownload.start()` returns false). Then `var errorText: String?` equals that text and
//      `var showsRetry: Bool` is true. With no error, `errorText` is nil and `showsRetry` is false. The bytes
//      already downloaded stay on disk and in `progressText` (the model never deletes a `.partial`).
//   6. `func retry()` calls `onRetry` once, clears `errorText` and `showsRetry`, and keeps the bytes.
//   7. The damaged model. `func modelWasDamaged()` (the app calls it from ModelWatcher's `onMessage`) sets
//      `var damagedText: String?` to exactly "The model file was damaged, so it was deleted. Downloading it again."
//      (design section 7, the text of t27). `damagedText` is nil until then. The model holds the literal itself.
//   8. `var canStartIndexing: Bool` is true only when every file of `files` is under its real name (nothing
//      renamed from `.partial` yet means not whole, even when every byte has arrived) and at least one folder is
//      picked. Call `refresh()` first.
//   9. `var pickedFolders: [String]`: the absolute paths added with `func addFolder(_ url: URL)`, in the order
//      added, empty at the start of a bare setup. Adding a folder does not start reading it.
//  10. `func startIndexing()`, when `canStartIndexing` is false, does nothing at all: no write to settings.json,
//      no hook. When true it first reads settings.json through `SettingsFile`, then writes it back through
//      `SettingsFile` with `startPressed` true, `indexDeleted` false (design section 1: Start sets it false),
//      `folders` holding exactly the picked folders each with `reading` true and `code` false (code is off unless
//      ticked, a later slice), every other field as it was; and only after that write calls `onStart` once.
//      A second press does not call it again.
//  11. `static let startTitle = "Start indexing"`, `static let addFolderTitle = "Add folder\u{2026}"` (the
//      ellipsis character) and `static let retryTitle = "Retry"`: the labels the kit clicks by.
//  12. Not pinned, on purpose: whether a file under its real name is hashed again here (the watcher of t27
//      does that); the text shown when the model is whole; what `canStartIndexing` says with no folder picked
//      once the model is whole other than the above; the wording of any error; whether adding a folder writes
//      settings.json (only that no folder is `reading` and `startPressed` is false before Start); how
//      `pickedFolders` treats the same folder added twice; the progress text when a `.partial` is larger than
//      its file; anything in SetupWindow or FolderPicker.

// MARK: small helpers (file-private, so nothing collides with the t26 and t27 files)

private let smDamagedMessage = "The model file was damaged, so it was deleted. Downloading it again."

private func smHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func smPattern(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(out)
}

private final class SMRecord<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item] = []
    func add(_ item: Item) { lock.lock(); items.append(item); lock.unlock() }
    var all: [Item] { lock.lock(); defer { lock.unlock() }; return items }
}

// A model file of a stated size whose bytes are never held: its expected hash is not needed by a `.partial`.
private func smBigFile(_ name: String, size: Int) -> ModelFile {
    ModelFile(name: name, size: size, sha256: String(repeating: "0", count: 64))
}

// A small whole file: the bytes are real, so the size and SHA-256 are right.
private struct SMSynthetic {
    let data: Data
    let file: ModelFile
    init(name: String, size: Int, seed: UInt64) {
        let data = smPattern(size, seed: seed)
        self.data = data
        self.file = ModelFile(name: name, size: size, sha256: smHex(data))
    }
}

private struct SMEnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }
    func whole(_ name: String) -> URL { models.appendingPathComponent(name) }
    func partial(_ name: String) -> URL { models.appendingPathComponent(name + ".partial") }

    // A `.partial` of exactly `bytes` bytes, sparse, so a size in the hundreds of megabytes costs nothing.
    func setPartial(_ name: String, bytes: Int) throws {
        let url = partial(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    // A real directory, made under the resolved home so a path compared as text cannot differ by a symlink.
    func makeFolder(_ name: String) throws -> URL {
        let url = home.resolvingSymlinksInPath().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // settings.json as it is on disk, nil when there is none.
    func settingsOnDisk() -> NSDictionary? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    func folderEntriesOnDisk() -> [NSDictionary] {
        (settingsOnDisk()?["folders"] as? [NSDictionary]) ?? []
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder and `models/`, runs the body, puts HOME back.
@MainActor
private func smRun(_ body: @MainActor (SMEnv) throws -> Void) throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-setup-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let env = SMEnv(home: home)
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

// The settings value read back through SettingsFile, as the dictionary of its JSON (the shape SettingsFileTests uses).
private func smSettingsDictionary() throws -> NSDictionary {
    let data = try JSONEncoder().encode(try SettingsFile().read())
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func smFolderEntriesViaSettingsFile() throws -> [NSDictionary] {
    try #require(try smSettingsDictionary()["folders"] as? [NSDictionary])
}

private func smDecode<T: Decodable>(like _: T, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// Settings a person might already have: a changed shortcut, kinds, openers, speeds, an index just deleted.
// Written here by hand from design section 1, so nothing in it comes from the code under test.
private let smSeedJSON = """
{
  "version": 3,
  "startPressed": false,
  "indexDeleted": true,
  "folders": [],
  "codeSearchOn": true,
  "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
  "hotkey": "cmd+opt+k",
  "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
  "speeds": {"photo": 1.5, "pdf": 2.25},
  "loginDefaultApplied": true
}
"""

// The expected model size of the design: two files, 309,855,456 + 554,821,024 = 864,676,480 bytes.
private let smRealText = "embeddinggemma-2-Q8_0.gguf"
private let smRealMM = "mmproj-embeddinggemma-2-Q8_0.gguf"

extension ModelDownloadTests {
    @Suite("SetupModelTests", .serialized)
    struct SetupModelTests {

        // MARK: the progress text, "N of 865 MB", from the bytes of the .partial files

        @MainActor
        @Test func theProgressTextForTheRealModelReadsNOf865MBFromThePartialBytes() throws {
            try smRun { env in
                let model = SetupModel()
                model.refresh()
                #expect(model.progressText == "0 of 865 MB", "nothing downloaded yet: \(model.progressText)")

                // 123,456,789 + 45,000,000 = 168,456,789 bytes = 168 decimal MB (160 in MiB)
                try env.setPartial(smRealText, bytes: 123_456_789)
                try env.setPartial(smRealMM, bytes: 45_000_000)
                model.refresh()
                #expect(model.progressText == "168 of 865 MB", "got \(model.progressText)")

                // the download only grows: 309,000,000 + 300,000,000 = 609 MB
                try env.setPartial(smRealText, bytes: 309_000_000)
                try env.setPartial(smRealMM, bytes: 300_000_000)
                model.refresh()
                #expect(model.progressText == "609 of 865 MB", "got \(model.progressText)")
            }
        }

        @MainActor
        @Test func theProgressTextUsesTheExpectedTotalItIsTold() throws {
            try smRun { env in
                let a = smBigFile("sm-a.gguf", size: 60_000_000)
                let b = smBigFile("sm-b.gguf", size: 40_000_000)
                let model = SetupModel(files: [a, b])
                model.refresh()
                #expect(model.progressText == "0 of 100 MB", "got \(model.progressText)")

                // the bytes of both files are added: 30,000,000 + 7,400,000 = 37.4 MB
                try env.setPartial(a.name, bytes: 30_000_000)
                try env.setPartial(b.name, bytes: 7_400_000)
                model.refresh()
                #expect(model.progressText == "37 of 100 MB", "got \(model.progressText)")

                // 52.9 MB reads 53: rounded to the nearest, as 864.68 reads 865 in the spec
                try env.setPartial(b.name, bytes: 22_900_000)
                model.refresh()
                #expect(model.progressText == "53 of 100 MB", "got \(model.progressText)")

                // every byte of both files, still under their .partial names
                try env.setPartial(a.name, bytes: 60_000_000)
                try env.setPartial(b.name, bytes: 40_000_000)
                model.refresh()
                #expect(model.progressText == "100 of 100 MB", "got \(model.progressText)")
            }
        }

        // MARK: an error shows its text, offers Retry and keeps the bytes

        @MainActor
        @Test func anErrorShowsItsTextOffersRetryAndKeepsTheBytes() throws {
            try smRun { env in
                let a = smBigFile("sm-err-a.gguf", size: 60_000_000)
                let b = smBigFile("sm-err-b.gguf", size: 40_000_000)
                let retries = SMRecord<String>()
                let model = SetupModel(files: [a, b], onRetry: { retries.add("retry") })
                try env.setPartial(a.name, bytes: 41_000_000)
                model.refresh()
                #expect(model.errorText == nil, "an error with nothing wrong: \(String(describing: model.errorText))")
                #expect(!model.showsRetry, "Retry offered with nothing wrong")
                #expect(model.progressText == "41 of 100 MB")

                let text = "The download stopped because the network is off."
                model.downloadFailed(text)
                model.refresh()

                #expect(model.errorText == text, "error text: \(String(describing: model.errorText))")
                #expect(model.showsRetry, "an error without Retry")
                // the bytes already downloaded are kept: on disk, and still shown
                #expect(env.size(of: env.partial(a.name)) == 41_000_000, "the .partial was changed or deleted")
                #expect(model.progressText == "41 of 100 MB", "the bytes are not shown after the error: \(model.progressText)")
                #expect(!model.canStartIndexing, "Start indexing is available while the model is not whole")
                #expect(retries.all.isEmpty, "Retry was called by the error itself")
            }
        }

        @MainActor
        @Test func retryClearsTheErrorCallsTheHookOnceAndKeepsTheBytes() throws {
            try smRun { env in
                let a = smBigFile("sm-retry-a.gguf", size: 80_000_000)
                let retries = SMRecord<String>()
                let model = SetupModel(files: [a], onRetry: { retries.add("retry") })
                try env.setPartial(a.name, bytes: 25_000_000)
                model.downloadFailed("The server did not answer.")
                model.refresh()
                #expect(model.showsRetry)

                model.retry()
                model.refresh()

                #expect(retries.all.count == 1, "the Retry hook was called \(retries.all.count) times")
                #expect(model.errorText == nil, "the error is still shown after Retry: \(String(describing: model.errorText))")
                #expect(!model.showsRetry, "Retry still offered after it was pressed")
                #expect(env.size(of: env.partial(a.name)) == 25_000_000, "Retry changed the kept bytes")
                #expect(model.progressText == "25 of 80 MB", "got \(model.progressText)")

                // a second failure shows its own text and offers Retry again
                model.downloadFailed("The connection was lost.")
                #expect(model.errorText == "The connection was lost.")
                #expect(model.showsRetry)
            }
        }

        // MARK: the damaged-model message

        @MainActor
        @Test func theDamagedModelMessageIsExactlyTheDesignsText() throws {
            try smRun { env in
                let a = smBigFile("sm-damaged-a.gguf", size: 50_000_000)
                let model = SetupModel(files: [a])
                model.refresh()
                #expect(model.damagedText == nil, "a damaged message before anything was damaged")

                model.modelWasDamaged()
                model.refresh()

                let text = try #require(model.damagedText, "no damaged message after the model file was damaged")
                #expect(text == "The model file was damaged, so it was deleted. Downloading it again.")
                #expect(Array(text.utf8) == Array(smDamagedMessage.utf8))
                #expect(!text.hasSuffix(" ") && !text.hasSuffix("\n"), "trailing space or newline in the message")
                // the file is gone, so the model is not whole and Start indexing is not available
                #expect(!model.canStartIndexing)
                _ = env
            }
        }

        // MARK: Start indexing is unavailable until the model is whole

        @MainActor
        @Test func startIndexingIsUnavailableUntilEveryModelFileIsWholeAndDoesNothingWhenPressed() throws {
            try smRun { env in
                let a = SMSynthetic(name: "sm-whole-a.gguf", size: 300_000, seed: 201)
                let b = SMSynthetic(name: "sm-whole-b.gguf", size: 250_000, seed: 202)
                let starts = SMRecord<String>()
                let model = SetupModel(files: [a.file, b.file], onStart: { starts.add("start") })
                model.addFolder(try env.makeFolder("Pictures"))

                @MainActor func pressedWithoutEffect(_ stage: String) {
                    model.refresh()
                    #expect(!model.canStartIndexing, "\(stage): Start indexing is available")
                    model.startIndexing()
                    #expect(starts.all.isEmpty, "\(stage): pressing Start called the hook")
                    #expect((env.settingsOnDisk()?["startPressed"] as? Bool ?? false) == false,
                            "\(stage): settings.json holds startPressed true")
                    #expect(env.folderEntriesOnDisk().allSatisfy { ($0["reading"] as? Bool) != true },
                            "\(stage): a folder is reading")
                }

                // nothing downloaded
                pressedWithoutEffect("no files")

                // every byte of the first file is there but still under its .partial name: not renamed, not whole
                try a.data.write(to: env.partial(a.file.name))
                pressedWithoutEffect("first file complete but still .partial")

                // first file whole, second half downloaded
                try FileManager.default.removeItem(at: env.partial(a.file.name))
                try a.data.write(to: env.whole(a.file.name))
                try b.data.prefix(b.data.count / 2).write(to: env.partial(b.file.name))
                pressedWithoutEffect("one whole, one partial")

                // both whole
                try FileManager.default.removeItem(at: env.partial(b.file.name))
                try b.data.write(to: env.whole(b.file.name))
                model.refresh()
                #expect(model.canStartIndexing, "both files whole and a folder picked, yet Start indexing is unavailable")
            }
        }

        // MARK: pressing Start indexing

        @MainActor
        @Test func startIndexingWritesStartPressedAndEachPickedFoldersReadingThroughSettingsFileAndCallsOneHook() throws {
            try smRun { env in
                let a = SMSynthetic(name: "sm-start-a.gguf", size: 280_000, seed: 211)
                try a.data.write(to: env.whole(a.file.name))

                // settings a person already has: nothing here may be lost
                let file = SettingsFile()
                try file.write(try smDecode(like: try file.read(), smSeedJSON))
                let before = try smSettingsDictionary()
                #expect(before["startPressed"] as? Bool == false)
                #expect(before["indexDeleted"] as? Bool == true)

                // what the hook finds in settings.json at the moment it is called
                let seenAtHook = SMRecord<[String: Bool]>()
                let starts = SMRecord<String>()
                let model = SetupModel(files: [a.file], onStart: {
                    let startPressed = (try? SettingsFile().read().startPressed) ?? false
                    let readings = (try? smFolderEntriesViaSettingsFile())?.allSatisfy { ($0["reading"] as? Bool) == true } ?? false
                    seenAtHook.add(["startPressed": startPressed, "everyFolderReading": readings])
                    starts.add("start")
                })
                let pictures = try env.makeFolder("Pictures")
                let photos = try env.makeFolder("My Photos")
                let screenshots = try env.makeFolder("Screenshots")
                model.addFolder(pictures)
                model.addFolder(photos)
                model.addFolder(screenshots)
                model.refresh()
                #expect(model.canStartIndexing)

                model.startIndexing()

                // settings.json on disk
                let onDisk = try #require(env.settingsOnDisk(), "no settings.json after Start indexing")
                #expect(onDisk["startPressed"] as? Bool == true, "startPressed on disk: \(String(describing: onDisk["startPressed"]))")
                #expect(onDisk["indexDeleted"] as? Bool == false, "indexDeleted on disk: \(String(describing: onDisk["indexDeleted"]))")
                let entries = env.folderEntriesOnDisk()
                let expectedPaths = [pictures.path, photos.path, screenshots.path]
                #expect(entries.count == 3, "folders on disk: \(entries)")
                #expect(Set(entries.compactMap { $0["path"] as? String }) == Set(expectedPaths),
                        "paths on disk: \(entries.compactMap { $0["path"] as? String })")
                for entry in entries {
                    #expect(entry["reading"] as? Bool == true, "folder not reading: \(entry)")
                    #expect(entry["code"] as? Bool == false, "code is on for a folder nobody ticked: \(entry)")
                }

                // the same, through SettingsFile
                let after = try smSettingsDictionary()
                #expect(after["startPressed"] as? Bool == true)
                #expect(after["indexDeleted"] as? Bool == false)
                let viaFile = try smFolderEntriesViaSettingsFile()
                #expect(Set(viaFile.compactMap { $0["path"] as? String }) == Set(expectedPaths))
                #expect(viaFile.allSatisfy { ($0["reading"] as? Bool) == true })

                // every other field is as it was
                for key in ["version", "codeSearchOn", "kindsOn", "hotkey", "openWith", "speeds", "loginDefaultApplied"] {
                    #expect((after[key] as? NSObject) == (before[key] as? NSObject), "field \(key) changed: \(String(describing: after[key]))")
                }

                // one hook, called after the settings were written
                #expect(starts.all.count == 1, "the Start hook was called \(starts.all.count) times")
                #expect(seenAtHook.all == [["startPressed": true, "everyFolderReading": true]],
                        "at the moment of the hook, settings.json held: \(seenAtHook.all)")

                // a second press is not a second Start
                model.startIndexing()
                #expect(starts.all.count == 1, "a second press called the hook again: \(starts.all.count)")
            }
        }

        // MARK: the picked list

        @MainActor
        @Test func thePickedListShowsTheFoldersAddedInOrderAndAddingOneStartsNothing() throws {
            try smRun { env in
                let model = SetupModel(files: [smBigFile("sm-list-a.gguf", size: 10_000_000)])
                model.refresh()
                #expect(model.pickedFolders.isEmpty, "a bare setup starts with a picked list: \(model.pickedFolders)")

                let pictures = try env.makeFolder("Pictures")
                let photos = try env.makeFolder("My Photos")
                let documents = try env.makeFolder("Documents")

                model.addFolder(pictures)
                #expect(model.pickedFolders == [pictures.path], "picked: \(model.pickedFolders)")

                model.addFolder(photos)
                model.addFolder(documents)
                #expect(model.pickedFolders == [pictures.path, photos.path, documents.path],
                        "picked: \(model.pickedFolders)")

                // nothing is read until Start indexing: no folder reading, startPressed false
                #expect((env.settingsOnDisk()?["startPressed"] as? Bool ?? false) == false)
                #expect(env.folderEntriesOnDisk().allSatisfy { ($0["reading"] as? Bool) != true },
                        "a folder is reading before Start: \(env.folderEntriesOnDisk())")
                #expect(try SettingsFile().read().startPressed == false)
            }
        }

        // MARK: the labels the kit clicks by

        @MainActor
        @Test func theButtonsAreLabelledForTheKit() {
            #expect(SetupModel.startTitle == "Start indexing")
            #expect(SetupModel.addFolderTitle == "Add folder\u{2026}")
            #expect(SetupModel.retryTitle == "Retry")
        }
    }
}

// MARK: plan-2 fix round B, tester step, item B6 (R2-13): the damaged model after Start
//
// Written from the fix-round document ("when the model is found damaged after Start was pressed, the setup window is not
// offered with an enabled Start. It shows the damaged-model message and the download progress, offers no Start, and never
// rewrites `settings.folders`. When Start was never pressed the normal setup continues as today") and the review report
// (R2-13: a fresh `SetupModel` has `started` false, so Start is enabled once the model is whole again). No product source
// was read. Everything above is sealed and unchanged.
//
// API SHAPE B6 pins here (no new name): `SetupModel` reads `startPressed` from `settings.json` (through `SettingsFile`, at
// `init` and again at each `refresh()`), and `canStartIndexing` is false whenever it is true, whatever the model files say,
// so a setup window built after Start was pressed (the damaged-model re-show) can never press Start. `startIndexing()` then
// does nothing at all (no write, no hook), as it already does when `canStartIndexing` is false.

private let smPressedJSON = smSeedJSON
    .replacingOccurrences(of: "\"startPressed\": false", with: "\"startPressed\": true")
    .replacingOccurrences(of: "\"indexDeleted\": true", with: "\"indexDeleted\": false")

private func smSeedFolders(_ json: String, folders: [String]) -> String {
    let entries = folders.map { "{\"path\": \"\($0)\", \"code\": false, \"reading\": true}" }.joined(separator: ", ")
    return json.replacingOccurrences(of: "\"folders\": []", with: "\"folders\": [\(entries)]")
}

extension ModelDownloadTests.SetupModelTests {

    @MainActor
    @Test func aModelDamagedAfterStartIsNeverOfferedAnEnabledStartNotEvenWhenItIsWholeAgain() throws {
        try smRun { env in
            let a = SMSynthetic(name: "sm-b6-a.gguf", size: 270_000, seed: 601)
            try a.data.write(to: env.whole(a.file.name))
            let pictures = try env.makeFolder("Pictures")
            let file = SettingsFile()
            try file.write(try smDecode(like: try file.read(), smSeedFolders(smPressedJSON, folders: [pictures.path])))
            let bytes = try Data(contentsOf: env.settings)

            let starts = SMRecord<String>()
            // the app's re-show after the damage: a new model, built after Start was pressed
            let model = SetupModel(files: [a.file], onStart: { starts.add("start") })
            model.refresh()
            #expect(!model.canStartIndexing, "Start is offered with the model whole although Start was pressed before")

            // the damage: the file is deleted, the message shows, the download runs again
            try FileManager.default.removeItem(at: env.whole(a.file.name))
            model.modelWasDamaged()
            model.refresh()
            #expect(model.damagedText == "The model file was damaged, so it was deleted. Downloading it again.")
            #expect(!model.canStartIndexing, "Start is offered while the model is damaged")

            // the model is whole again: still no Start, because Start was already pressed
            try a.data.write(to: env.whole(a.file.name))
            model.refresh()
            #expect(!model.canStartIndexing, "Start is offered once the model is whole again, after Start was pressed")
            model.startIndexing()
            #expect(starts.all.isEmpty, "a press called the Start hook \(starts.all.count) times")
            #expect(try Data(contentsOf: env.settings) == bytes, "a press changed settings.json")
            #expect(env.folderEntriesOnDisk().compactMap { $0["path"] as? String } == [pictures.path], "folders on disk: \(env.folderEntriesOnDisk())")
        }
    }

    @MainActor
    @Test func theNormalSetupStillOffersStartAfterADamagedModelWhenStartWasNeverPressed() throws {
        try smRun { env in
            let a = SMSynthetic(name: "sm-b6-b.gguf", size: 262_000, seed: 602)
            let file = SettingsFile()
            try file.write(try smDecode(like: try file.read(), smSeedJSON.replacingOccurrences(of: "\"indexDeleted\": true", with: "\"indexDeleted\": false")))
            let starts = SMRecord<String>()
            let model = SetupModel(files: [a.file], onStart: { starts.add("start") })
            model.addFolder(try env.makeFolder("Pictures"))
            model.modelWasDamaged()
            model.refresh()
            #expect(!model.canStartIndexing)

            try a.data.write(to: env.whole(a.file.name))
            model.refresh()
            #expect(model.canStartIndexing, "Start is unavailable with the model whole again and Start never pressed")
            model.startIndexing()
            #expect(starts.all.count == 1, "the hook was called \(starts.all.count) times")
        }
    }
}

// MARK: plan-2 fix round D, tester step, item D1 (R3-01): a failed model download and its Retry, after Start was pressed
//
// Written from the fix-round document D1 ("Retry restarts the download and keeps the bytes already downloaded", "no Start
// when Start was already pressed (Start follows the B6 rules)") and spec S6 ("setup says so, keeps the bytes already
// downloaded and offers Retry"). No product source was read. Everything above is sealed and unchanged.
//
// NO NEW NAME HERE. The download-failed state of `SetupModel` already exists and is the one this round uses: `downloadFailed(_:)`,
// `errorText`, `showsRetry`, `retry()` (which calls `onRetry` once and keeps the bytes) and `SetupModel.downloadFailedMessage`
// (the plain line the app reports when `ModelDownload.start()` gives up). The new behaviour is where the failure is SHOWN
// (OnDemandSetup, LaunchPrivacyTests; MenuState and the panel, MenuStateTests and PanelStateTests). The two tests below
// are GUARDS that pass today: they pin that the model's failed state also works for a setup built after Start was pressed,
// which is the window the app builds on demand for a failure.

extension ModelDownloadTests.SetupModelTests {

    @MainActor
    @Test func aFailedDownloadAfterStartKeepsTheFailureAndRetryOffersNoStartAndRetryKeepsTheBytes() throws {
        try smRun { env in
            let a = smBigFile("sm-d1-a.gguf", size: 80_000_000)
            let pictures = try env.makeFolder("Pictures")
            let file = SettingsFile()
            try file.write(try smDecode(like: try file.read(), smSeedFolders(smPressedJSON, folders: [pictures.path])))
            let settingsBytes = try Data(contentsOf: env.settings)
            try env.setPartial(a.name, bytes: 31_000_000)

            let retries = SMRecord<String>()
            let starts = SMRecord<String>()
            let model = SetupModel(files: [a], onStart: { starts.add("start") }, onRetry: { retries.add("retry") })
            model.refresh()
            model.downloadFailed(SetupModel.downloadFailedMessage)
            model.refresh()

            #expect(model.errorText == SetupModel.downloadFailedMessage, "error text: \(String(describing: model.errorText))")
            #expect(model.showsRetry, "no Retry after the download failed")
            #expect(!model.canStartIndexing, "Start is offered after a failed download with Start already pressed")
            model.startIndexing()
            #expect(starts.all.isEmpty, "a press called the Start hook")
            #expect(model.progressText == "31 of 80 MB", "the bytes are not shown: \(model.progressText)")

            model.retry()
            model.refresh()
            #expect(retries.all.count == 1, "the Retry hook was called \(retries.all.count) times")
            #expect(model.errorText == nil && !model.showsRetry, "the failure stays after Retry: \(String(describing: model.errorText))")
            #expect(env.size(of: env.partial(a.name)) == 31_000_000, "Retry changed the kept bytes")
            #expect(model.progressText == "31 of 80 MB", "got \(model.progressText)")
            #expect(try Data(contentsOf: env.settings) == settingsBytes, "the failure or Retry rewrote settings.json")
        }
    }

    @MainActor
    @Test func theDefaultFailureLineIsPlainWordsWithNoPathAndNoAddress() {
        let line = SetupModel.downloadFailedMessage
        #expect(!line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the default failure line is blank")
        #expect(!line.contains("/") && !line.lowercased().contains("http"), "the failure line names a path or an address: \(line)")
    }
}

// MARK: plan-2 fix round E, tester step, items E3 and E4 (R4-03, R4-04): a stale error line, and a `started` that never goes back
//
// Written from the fix-round document ("E3: `modelWasDamaged()` also clears `SetupModel.errorText` so Retry cannot start a launch
// download beside the watcher. E4: `SetupModel.refresh()` sets `started` from `settings.startPressed` in both directions (after
// Delete index it becomes false again)"). No product source was read.
//
// NO NEW NAME HERE. E3 pins `SetupModel.modelWasDamaged()` (it exists; the app calls it when the watcher fetches a damaged file
// again): after it, `errorText` is nil and `showsRetry` is false, so a Retry that would start a launch download beside the
// watcher's fetch is not offered. A later `downloadFailed(_:)` shows its own text and Retry again. E4 pins `SetupModel.started`
// (readable, exists): it equals `startPressed` of settings.json after every `refresh()`, true or false, and `canStartIndexing`
// follows it (an already whole model with a folder picked offers Start again once Delete index made `startPressed` false).

extension ModelDownloadTests.SetupModelTests {

    // E3
    @MainActor
    @Test func aModelDamagedAfterAFailedDownloadClearsTheErrorLineAndRetryAndKeepsTheBytes() throws {
        try smRun { env in
            let a = smBigFile("sm-e3-a.gguf", size: 80_000_000)
            try env.setPartial(a.name, bytes: 33_000_000)
            let retries = SMRecord<String>()
            let model = SetupModel(files: [a], onRetry: { retries.add("retry") })
            model.refresh()
            model.downloadFailed("The download stopped because the network is off.")
            model.refresh()
            #expect(model.errorText != nil && model.showsRetry, "the failure did not show before the damage")

            model.modelWasDamaged()
            #expect(model.errorText == nil, "the stale error line stays after the model was damaged: \(String(describing: model.errorText))")
            #expect(!model.showsRetry, "Retry is still offered while the watcher fetches the model again")
            model.refresh()
            #expect(model.errorText == nil && !model.showsRetry, "a refresh brought the stale failure back: \(String(describing: model.errorText))")
            #expect(model.damagedText == "The model file was damaged, so it was deleted. Downloading it again.")
            #expect(retries.all.isEmpty, "the damage called the Retry hook")
            #expect(env.size(of: env.partial(a.name)) == 33_000_000, "the damage changed the kept bytes")
            #expect(model.progressText == "33 of 80 MB", "got \(model.progressText)")
        }
    }

    @MainActor
    @Test func aFailureThatComesAfterTheDamageShowsItsOwnTextAndRetryAgain() throws {
        try smRun { env in
            let a = smBigFile("sm-e3-b.gguf", size: 80_000_000)
            try env.setPartial(a.name, bytes: 12_000_000)
            let model = SetupModel(files: [a])
            model.refresh()
            model.downloadFailed("First failure.")
            model.modelWasDamaged()
            model.refresh()
            #expect(model.errorText == nil)

            model.downloadFailed("The watcher could not fetch the model again.")
            model.refresh()
            #expect(model.errorText == "The watcher could not fetch the model again.", "got \(String(describing: model.errorText))")
            #expect(model.showsRetry, "no Retry after a failure that came after the damage")
            _ = env
        }
    }

    // GUARD: passes today. Damage with no earlier failure leaves no error line and no Retry.
    @MainActor
    @Test func aModelDamagedWithNoEarlierFailureShowsNoErrorLineAndNoRetry() throws {
        try smRun { env in
            let a = smBigFile("sm-e3-c.gguf", size: 50_000_000)
            let model = SetupModel(files: [a])
            model.refresh()
            model.modelWasDamaged()
            model.refresh()
            #expect(model.errorText == nil, "an error line appeared: \(String(describing: model.errorText))")
            #expect(!model.showsRetry)
            _ = env
        }
    }

    // E4
    @MainActor
    @Test func startedFollowsStartPressedOfSettingsInBothDirectionsAtEveryRefresh() throws {
        try smRun { env in
            let a = SMSynthetic(name: "sm-e4-a.gguf", size: 255_000, seed: 701)
            try a.data.write(to: env.whole(a.file.name))
            let file = SettingsFile()
            try file.write(try smDecode(like: try file.read(), smSeedJSON))        // startPressed false, indexDeleted true
            let model = SetupModel(files: [a.file])
            model.refresh()
            #expect(!model.started, "started is true although Start was never pressed")

            try file.write(try smDecode(like: try file.read(), smPressedJSON))     // Start was pressed elsewhere (Settings)
            model.refresh()
            #expect(model.started, "started is false after Start was pressed")

            try file.write(try smDecode(like: try file.read(), smSeedJSON))        // Delete index: startPressed is false again
            model.refresh()
            #expect(!model.started, "started stays true after Delete index made startPressed false again")

            try file.write(try smDecode(like: try file.read(), smPressedJSON))
            model.refresh()
            #expect(model.started, "started did not come back after Start was pressed a second time")
        }
    }

    @MainActor
    @Test func afterDeleteIndexTheReusedWindowOffersStartAgainWithTheModelWholeAndAFolderPicked() throws {
        try smRun { env in
            let a = SMSynthetic(name: "sm-e4-b.gguf", size: 261_000, seed: 702)
            try a.data.write(to: env.whole(a.file.name))
            let pictures = try env.makeFolder("Pictures")
            let file = SettingsFile()
            try file.write(try smDecode(like: try file.read(), smPressedJSON))
            let starts = SMRecord<String>()
            let model = SetupModel(files: [a.file], onStart: { starts.add("start") })
            model.addFolder(pictures)
            model.refresh()
            #expect(model.started && !model.canStartIndexing, "with Start pressed: started \(model.started), canStart \(model.canStartIndexing)")

            try file.write(try smDecode(like: try file.read(), smSeedJSON))        // Delete index
            model.refresh()
            #expect(!model.started, "started stays true after Delete index")
            #expect(model.canStartIndexing, "Start stays disabled in the reused window after Delete index")
            model.startIndexing()
            #expect(starts.all.count == 1, "Start called the hook \(starts.all.count) times")
            model.refresh()
            #expect(model.started, "a refresh after Start put started back to false")
        }
    }
}
