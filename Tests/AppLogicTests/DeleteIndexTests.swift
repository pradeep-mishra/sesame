import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t22, tester step. Written from the t22 entry of plan-2-tasks.md (its Tests paragraph), Decisions D7 of that file,
// design section 1 ("Delete index runs in this order: the app writes startPressed=false, indexDeleted=true to
// settings.json, then sends reset; Start sets indexDeleted=false. At launch, indexDeleted true with an index file present
// means a crash between the two, so the app sends reset again" and "the app closes IndexReader's connection, writes the
// settings as above, then sends reset"), spec S1.21 (b), S1.22, S6.12, S8.11, and the plan-1 and plan-2 test files as the
// one place existing names are read (`SettingsFile`, `Settings`, `SetupModel`, `SettingsModel`, `FoldersSender`,
// `ModelFile`). No product source was read. Every expected flag, order and byte below is written by hand from the settings
// and the files each test builds. No app is launched: the helper is never started, `reset` is a recording closure.
//
// SUITE PLACEMENT. HOME is process-wide (SettingsFile and SesameFolder read it), so this suite is nested inside
// `ModelDownloadTests` like the other Setup suites and runs one at a time with them.
//
// API SHAPES these tests pin. The entry names `DeleteIndex`, `run(confirmed:)`, `resumeIfNeeded(indexFileExists:settings:)`
// and "recording seams", and fixes no signatures. If a shape below is wrong, ask for a test change rather than guessing.
//   1. `DeleteIndex` is in the `Sesame` target, a class or struct, built by
//        DeleteIndex(closeIndex: @escaping () -> Void,
//                    sendReset: @escaping () -> Void,
//                    deleteCaches: @escaping () throws -> Void = { try SesameFolder.deleteCaches() })
//      `closeIndex` is step (1) (the app passes `IndexReader.close`), `sendReset` is step (3) (the app passes
//      `HelperClient.reset`), `deleteCaches` is step (4) and its default is the real `SesameFolder.deleteCaches()`. Step (2)
//      is not a seam: it is the real `SettingsFile`, read back from disk by the tests. `DeleteIndex` takes no
//      `ModelDownload`, no model path and no folder list.
//   2. `func run(confirmed: Bool) throws`. With `confirmed` false nothing happens at all (no seam, no write, no delete).
//      With true it does (1), (2), (3), (4) in that order. Step (2) reads `settings.json` through `SettingsFile` and writes
//      it back with `startPressed` false and `indexDeleted` true and every other field as it was (`folders` kept, each with
//      its `reading` and `code`). When the write fails `run` throws and (3) and (4) do not happen (a reset after a failed
//      write would delete the index while the file still says Start was pressed, which is the unrecoverable order).
//   3. `func resumeIfNeeded(indexFileExists: Bool, settings: Settings)` (not throwing, no result used): when
//      `settings.indexDeleted` is true and `indexFileExists` is true it calls `sendReset` once; in every other case it does
//      nothing (it calls no seam and writes nothing). Whether it also calls `closeIndex` is not pinned.
//   4. Start: `SetupModel.startIndexing()` and `SettingsModel.startIndexing()` (both already built) write `indexDeleted`
//      false and `startPressed` true over what `run` wrote.
//   5. Not pinned, on purpose: the type of `DeleteIndex` (class or struct), where it is called from, any text shown to the
//      person, what `run` does with a `closeIndex` that is called twice, and the Settings sheet that asks to confirm.

// MARK: small helpers (file-private, so nothing collides with the other test files)

private final class DIBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// What settings.json held at the moment a seam was called.
private struct DISeen: Sendable, Equatable {
    var startPressed: Bool
    var indexDeleted: Bool
    var reading: [String: Bool]   // folder path -> reading
}

private func diSeen() -> DISeen? {
    guard let settings = try? SettingsFile().read() else { return nil }
    var reading: [String: Bool] = [:]
    for folder in settings.folders { reading[folder.path] = folder.reading }
    return DISeen(startPressed: settings.startPressed, indexDeleted: settings.indexDeleted, reading: reading)
}

// The recording seams. Each call is noted with the settings.json of that moment, so "write second, reset third" is seen.
private final class DIRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var firstSeen: [String: DISeen] = [:]

    func note(_ event: String) {
        let now = diSeen()
        lock.lock()
        log.append(event)
        if firstSeen[event] == nil, let now { firstSeen[event] = now }
        lock.unlock()
    }

    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func seen(_ event: String) -> DISeen? { lock.lock(); defer { lock.unlock() }; return firstSeen[event] }
    func count(_ event: String) -> Int { events.filter { $0 == event }.count }

    // closeIndex, sendReset and deleteCaches all record.
    func makeRecordingAll() -> DeleteIndex {
        DeleteIndex(closeIndex: { self.note("close") }, sendReset: { self.note("reset") }, deleteCaches: { self.note("caches") })
    }

    // closeIndex and sendReset record; deleteCaches is the real default.
    func makeWithRealCaches() -> DeleteIndex {
        DeleteIndex(closeIndex: { self.note("close") }, sendReset: { self.note("reset") })
    }
}

private final class DISender: FoldersSender, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func sendFolders() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct DIEnv {
    let home: URL   // symlink-resolved, so a path compared as text cannot differ by a link
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }
    var index: URL { folder.appendingPathComponent("index.sqlite") }
    var caches: URL { home.appendingPathComponent("Library/Caches", isDirectory: true) }

    func dir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func plant(_ relative: String, _ text: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path) }
    func text(_ relative: String) -> String? {
        (try? Data(contentsOf: home.appendingPathComponent(relative))).flatMap { String(data: $0, encoding: .utf8) }
    }

    func settingsBytes() -> Data? { try? Data(contentsOf: settings) }
    func settingsDictionary() -> NSDictionary? {
        guard let data = settingsBytes() else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    // Writes settings.json through SettingsFile from JSON with the given folders: (path, reading, code). Written by hand
    // from design section 1: a person with a changed shortcut, kinds, openers and speeds.
    func seed(folders: [(path: String, reading: Bool, code: Bool)] = [], startPressed: Bool = true, indexDeleted: Bool = false) throws {
        let entries = folders.map { "{\"path\": \"\($0.path)\", \"code\": \($0.code), \"reading\": \($0.reading)}" }.joined(separator: ", ")
        let json = """
        {
          "version": 3,
          "startPressed": \(startPressed),
          "indexDeleted": \(indexDeleted),
          "folders": [\(entries)],
          "codeSearchOn": true,
          "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
          "hotkey": "cmd+opt+j",
          "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
          "speeds": {"photo": 1.5, "pdf": 2.25},
          "loginDefaultApplied": true
        }
        """
        try SettingsFile().write(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)))
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder, runs the body, puts HOME back and removes the folder. Stops before
// anything is written if the folder did not land under the temp HOME.
@MainActor
private func diRun(_ body: @MainActor (DIEnv) throws -> Void) throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-deleteindex-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = DIEnv(home: base.resolvingSymlinksInPath())
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
    try body(env)
}

// Every top-level key of two settings values equal, except the keys named.
private func diOtherFieldsUnchanged(_ before: NSDictionary?, _ after: NSDictionary?, except changed: Set<String>,
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

// Plants the three Caches folders of the entry, with the files of the entry.
private func diPlantCaches(_ env: DIEnv) throws {
    try env.plant("Library/Caches/app.sesame.Sesame/x/y", "sesame cache")
    try env.plant("Library/Caches/SesameHelper/z", "helper cache")
    try env.plant("Library/Caches/other.app/keep", "someone else's cache")
}

private func diPattern(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(out)
}

// A small whole model file: real bytes, so its size and SHA-256 are right and `SetupModel` counts it whole.
private struct DISynthetic {
    let data: Data
    let file: ModelFile
    init(name: String, size: Int, seed: UInt64) {
        let data = diPattern(size, seed: seed)
        self.data = data
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.file = ModelFile(name: name, size: size, sha256: hash)
    }
}

// What a file looks like to "untouched": bytes, inode and modified time.
private struct DIStamp: Equatable {
    var bytes: Data
    var inode: UInt64
    var modified: Date
}

private func diStamp(_ url: URL) -> DIStamp? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let inode = attributes[.systemFileNumber] as? UInt64,
          let modified = attributes[.modificationDate] as? Date else { return nil }
    return DIStamp(bytes: (try? Data(contentsOf: url)) ?? Data(), inode: inode, modified: modified)
}

private func diDirectoryStamp(_ url: URL) -> (names: [String], inode: UInt64?, modified: Date?) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (names, attributes?[.systemFileNumber] as? UInt64, attributes?[.modificationDate] as? Date)
}

// A local listener that counts the connections made to it. SESAME_MODEL_HOST points at it, so a download started by
// anything the tests run shows up as a connection. It answers nothing.
private enum DIListenerError: Error { case socket, bind }

private final class DIListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var accepted = 0
    private var stopped = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DIListenerError.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw DIListenerError.bind }
        var length = size
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); throw DIListenerError.bind }
        self.fd = fd
        self.port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in self.loop() }
    }

    private func loop() {
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { break }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 100) > 0 {
                let client = accept(fd, nil, nil)
                if client >= 0 {
                    close(client)
                    lock.lock(); accepted += 1; lock.unlock()
                }
            }
        }
        close(fd)
    }

    var connections: Int { lock.lock(); defer { lock.unlock() }; return accepted }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

extension ModelDownloadTests {
    @Suite("DeleteIndexTests", .serialized)
    struct DeleteIndexTests {

        // MARK: the order of design section 1

        @MainActor
        @Test func theOrderIsCloseTheIndexThenWriteTheSettingsThenResetThenDeleteTheCaches() throws {
            try diRun { env in
                let pictures = try env.dir("Pictures")
                let archive = try env.dir("Archive")
                try env.seed(folders: [(pictures.path, true, false), (archive.path, false, true)], startPressed: true, indexDeleted: false)
                let before = env.settingsDictionary()
                #expect(before?["startPressed"] as? Bool == true)
                #expect(before?["indexDeleted"] as? Bool == false)

                let recorder = DIRecorder()
                try recorder.makeRecordingAll().run(confirmed: true)

                #expect(recorder.events == ["close", "reset", "caches"], "order of the four steps: \(recorder.events)")

                // (1) the reader is closed first: the settings are not yet written
                let atClose = recorder.seen("close")
                #expect(atClose == DISeen(startPressed: true, indexDeleted: false, reading: [pictures.path: true, archive.path: false]),
                        "settings.json at the close: \(String(describing: atClose))")

                // (2) written before the reset goes out, folders kept
                let expected = DISeen(startPressed: false, indexDeleted: true, reading: [pictures.path: true, archive.path: false])
                #expect(recorder.seen("reset") == expected, "settings.json at the reset: \(String(describing: recorder.seen("reset")))")

                // (4) after the reset, and the settings are still the written ones
                #expect(recorder.seen("caches") == expected, "settings.json at the Caches delete: \(String(describing: recorder.seen("caches")))")

                // on disk at the end: only the two flags changed, the folders are kept whole (code flags too)
                let after = env.settingsDictionary()
                #expect(after?["startPressed"] as? Bool == false)
                #expect(after?["indexDeleted"] as? Bool == true)
                diOtherFieldsUnchanged(before, after, except: ["startPressed", "indexDeleted"])
                let entries = (after?["folders"] as? [NSDictionary]) ?? []
                #expect(entries.compactMap { $0["path"] as? String } == [pictures.path, archive.path], "folders after: \(entries)")
                #expect(entries.compactMap { $0["code"] as? Bool } == [false, true], "code flags after: \(entries)")
            }
        }

        @MainActor
        @Test func withoutConfirmedNothingHappensNotTheSeamsNotTheSettingsNotTheCaches() throws {
            try diRun { env in
                let pictures = try env.dir("Pictures")
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true, indexDeleted: false)
                try diPlantCaches(env)
                try env.plant("Library/Application Support/Sesame/index.sqlite", "the index")
                let before = env.settingsBytes()
                #expect(before != nil)

                let recorder = DIRecorder()
                let delete = recorder.makeWithRealCaches()
                try delete.run(confirmed: false)

                #expect(recorder.events.isEmpty, "seams called without a confirm: \(recorder.events)")
                #expect(env.settingsBytes() == before, "settings.json changed without a confirm")
                #expect(env.text("Library/Caches/app.sesame.Sesame/x/y") == "sesame cache")
                #expect(env.text("Library/Caches/SesameHelper/z") == "helper cache")
                #expect(env.text("Library/Caches/other.app/keep") == "someone else's cache")
                #expect(env.text("Library/Application Support/Sesame/index.sqlite") == "the index")
            }
        }

        @MainActor
        @Test func aFailedSettingsWriteSendsNoResetDeletesNoCachesAndARetryThenFollowsTheOrder() throws {
            try diRun { env in
                let pictures = try env.dir("Pictures")
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true, indexDeleted: false)
                try diPlantCaches(env)
                let before = env.settingsBytes()

                // a Sesame folder nothing can be written into, checked first so the test cannot pass by accident
                chmod(env.folder.path, 0o500)
                let probe = env.folder.appendingPathComponent("probe-\(UUID().uuidString)")
                if FileManager.default.createFile(atPath: probe.path, contents: Data("x".utf8)) {
                    try? FileManager.default.removeItem(at: probe)
                    chmod(env.folder.path, 0o700)
                    Issue.record("could not make the Sesame folder unwritable here (running as an account that ignores the mode?); stopped")
                    return
                }

                let recorder = DIRecorder()
                let delete = recorder.makeWithRealCaches()
                #expect(throws: (any Error).self) { try delete.run(confirmed: true) }

                #expect(recorder.count("reset") == 0, "reset was sent although the settings write failed: \(recorder.events)")
                #expect(env.settingsBytes() == before, "settings.json changed although the write failed")
                #expect(env.text("Library/Caches/app.sesame.Sesame/x/y") == "sesame cache", "Caches deleted after a failed write")
                #expect(env.text("Library/Caches/SesameHelper/z") == "helper cache", "Caches deleted after a failed write")

                // the person fixes the folder and tries again: the whole order runs
                chmod(env.folder.path, 0o700)
                let retry = DIRecorder()
                try retry.makeWithRealCaches().run(confirmed: true)
                #expect(retry.events == ["close", "reset"], "retry events: \(retry.events)")
                #expect(retry.seen("reset") == DISeen(startPressed: false, indexDeleted: true, reading: [pictures.path: true]))
                #expect(!env.exists("Library/Caches/app.sesame.Sesame"))
                #expect(!env.exists("Library/Caches/SesameHelper"))
                #expect(env.text("Library/Caches/other.app/keep") == "someone else's cache")
            }
        }

        // MARK: step (4), the real Caches delete, reached through DeleteIndex

        @MainActor
        @Test func theCachesStepRemovesTheTwoSesameFoldersWholeAndNothingElseUnderLibrary() throws {
            try diRun { env in
                try env.seed(startPressed: true, indexDeleted: false)
                try diPlantCaches(env)
                try env.plant("Library/Caches/app.sesame.Sesame.old/mine", "a different folder")
                try env.plant("Library/Preferences/app.sesame.Sesame.plist", "prefs")
                try env.plant("Library/Application Support/Sesame/models/keep.gguf", "model bytes")

                let recorder = DIRecorder()
                try recorder.makeWithRealCaches().run(confirmed: true)

                #expect(recorder.events == ["close", "reset"], "events: \(recorder.events)")
                #expect(!env.exists("Library/Caches/app.sesame.Sesame"), "Caches/app.sesame.Sesame is still there")
                #expect(!env.exists("Library/Caches/SesameHelper"), "Caches/SesameHelper is still there")
                #expect(env.text("Library/Caches/other.app/keep") == "someone else's cache")
                #expect(env.text("Library/Caches/app.sesame.Sesame.old/mine") == "a different folder")
                #expect(env.text("Library/Preferences/app.sesame.Sesame.plist") == "prefs")
                #expect(env.text("Library/Application Support/Sesame/models/keep.gguf") == "model bytes")
            }
        }

        // MARK: a crash between (2) and (3), recovered at launch

        @MainActor
        @Test func aCrashAfterTheWriteIsRecoveredAtLaunchWithOneMoreResetWhileTheIndexFileIsStillThere() throws {
            try diRun { env in
                let pictures = try env.dir("Pictures")
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true, indexDeleted: false)
                try env.plant("Library/Application Support/Sesame/index.sqlite", "the index")

                // the run reaches step (2) and the app dies before the reset reaches the helper: the reset seam does nothing
                let died = DIBox<Bool>(false)
                let first = DeleteIndex(closeIndex: {}, sendReset: { died.value = true }, deleteCaches: {})
                try first.run(confirmed: true)
                #expect(died.value)
                // what a fresh launch finds: the flags as step (2) left them and the index file still there
                let found = try SettingsFile().read()
                #expect(found.indexDeleted, "indexDeleted not on disk after step (2)")
                #expect(!found.startPressed, "startPressed still true after step (2)")
                #expect(FileManager.default.fileExists(atPath: env.index.path))

                let launch = DIRecorder()
                launch.makeRecordingAll().resumeIfNeeded(indexFileExists: FileManager.default.fileExists(atPath: env.index.path),
                                                         settings: found)
                #expect(launch.count("reset") == 1, "the launch sent reset \(launch.count("reset")) times: \(launch.events)")
                #expect(env.settingsDictionary()?["indexDeleted"] as? Bool == true, "the resume changed settings.json")
                #expect(env.settingsDictionary()?["startPressed"] as? Bool == false)
            }
        }

        @MainActor
        @Test func resumeDoesNothingWhenTheIndexFileIsGoneOrIndexDeletedIsFalse() throws {
            try diRun { env in
                let pictures = try env.dir("Pictures")

                // indexDeleted true, but the helper already deleted the index file: the reset had gone through
                try env.seed(folders: [(pictures.path, false, false)], startPressed: false, indexDeleted: true)
                let deleted = try SettingsFile().read()
                let goneRecorder = DIRecorder()
                goneRecorder.makeRecordingAll().resumeIfNeeded(indexFileExists: false, settings: deleted)
                #expect(goneRecorder.events.isEmpty, "a launch with the index file gone called \(goneRecorder.events)")

                // indexDeleted false with the index file there is the normal case of every launch after Start
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true, indexDeleted: false)
                let started = try SettingsFile().read()
                let normalRecorder = DIRecorder()
                normalRecorder.makeRecordingAll().resumeIfNeeded(indexFileExists: true, settings: started)
                #expect(normalRecorder.events.isEmpty, "a normal launch called \(normalRecorder.events)")

                // never started and never deleted, no file: nothing either
                try env.seed(folders: [], startPressed: false, indexDeleted: false)
                let fresh = try SettingsFile().read()
                let freshRecorder = DIRecorder()
                freshRecorder.makeRecordingAll().resumeIfNeeded(indexFileExists: false, settings: fresh)
                #expect(freshRecorder.events.isEmpty, "a first launch called \(freshRecorder.events)")

                // and nothing was written by any of them
                #expect(env.settingsDictionary()?["indexDeleted"] as? Bool == false)
            }
        }

        // MARK: Start sets indexDeleted false

        @MainActor
        @Test func startInTheSetupWindowModelAfterADeleteIndexSetsIndexDeletedFalseAndALaterLaunchDoesNotResetAgain() throws {
            try diRun { env in
                let whole = DISynthetic(name: "di-start-a.gguf", size: 280_000, seed: 331)
                try FileManager.default.createDirectory(at: env.models, withIntermediateDirectories: true)
                try whole.data.write(to: env.models.appendingPathComponent(whole.file.name))
                let pictures = try env.dir("Pictures")
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true, indexDeleted: false)
                try env.plant("Library/Application Support/Sesame/index.sqlite", "the index")

                try DeleteIndex(closeIndex: {}, sendReset: {}, deleteCaches: {}).run(confirmed: true)
                #expect(env.settingsDictionary()?["indexDeleted"] as? Bool == true)

                let model = SetupModel(files: [whole.file])
                model.addFolder(pictures)
                model.refresh()
                #expect(model.canStartIndexing)
                model.startIndexing()

                let after = env.settingsDictionary()
                #expect(after?["indexDeleted"] as? Bool == false, "indexDeleted after Start: \(String(describing: after?["indexDeleted"]))")
                #expect(after?["startPressed"] as? Bool == true)

                // the index file is there again (the helper rebuilds it): the next launch finds nothing to resume
                let launch = DIRecorder()
                launch.makeRecordingAll().resumeIfNeeded(indexFileExists: true, settings: try SettingsFile().read())
                #expect(launch.events.isEmpty, "a launch after Start called \(launch.events)")
            }
        }

        @MainActor
        @Test func startInSettingsAfterADeleteIndexSetsIndexDeletedFalseAndStartPressedTrue() throws {
            try diRun { env in
                let pictures = try env.dir("Pictures")
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true, indexDeleted: false)

                try DeleteIndex(closeIndex: {}, sendReset: {}, deleteCaches: {}).run(confirmed: true)
                #expect(env.settingsDictionary()?["indexDeleted"] as? Bool == true)
                #expect(env.settingsDictionary()?["startPressed"] as? Bool == false)

                let sender = DISender()
                let model = SettingsModel(sender: sender, modelWhole: { true })
                model.startIndexing()

                let after = env.settingsDictionary()
                #expect(after?["indexDeleted"] as? Bool == false, "indexDeleted after Start: \(String(describing: after?["indexDeleted"]))")
                #expect(after?["startPressed"] as? Bool == true)
                #expect(sender.calls == 1, "Start sent folders \(sender.calls) times")
            }
        }

        // MARK: S6.12, "the model is never downloaded again"

        @MainActor
        @Test func theModelsFolderIsUntouchedAndNoDownloadIsStartedByADeleteIndexOrByTheResume() throws {
            try diRun { env in
                let listener = try DIListener()
                defer { listener.stop() }
                let previousHost = getenv("SESAME_MODEL_HOST").map { String(cString: $0) }
                setenv("SESAME_MODEL_HOST", "http://127.0.0.1:\(listener.port)", 1)
                defer { if let previousHost { setenv("SESAME_MODEL_HOST", previousHost, 1) } else { unsetenv("SESAME_MODEL_HOST") } }

                let text = DISynthetic(name: "embeddinggemma-2-Q8_0.gguf", size: 200_000, seed: 401)
                let projector = DISynthetic(name: "mmproj-embeddinggemma-2-Q8_0.gguf", size: 120_000, seed: 402)
                try FileManager.default.createDirectory(at: env.models, withIntermediateDirectories: true)
                let textURL = env.models.appendingPathComponent(text.file.name)
                let projectorURL = env.models.appendingPathComponent(projector.file.name)
                let partialURL = env.models.appendingPathComponent("leftover.gguf.partial")
                try text.data.write(to: textURL)
                try projector.data.write(to: projectorURL)
                try Data(repeating: 9, count: 5_000).write(to: partialURL)
                let pictures = try env.dir("Pictures")
                try env.seed(folders: [(pictures.path, true, false)], startPressed: true, indexDeleted: false)
                try env.plant("Library/Application Support/Sesame/index.sqlite", "the index")
                try diPlantCaches(env)

                let beforeText = try #require(diStamp(textURL))
                let beforeProjector = try #require(diStamp(projectorURL))
                let beforePartial = try #require(diStamp(partialURL))
                let beforeFolder = diDirectoryStamp(env.models)
                #expect(beforeText.bytes == text.data)

                let recorder = DIRecorder()
                try recorder.makeWithRealCaches().run(confirmed: true)
                recorder.makeRecordingAll().resumeIfNeeded(indexFileExists: true, settings: try SettingsFile().read())
                #expect(recorder.count("reset") == 2, "one reset from the run and one from the resume: \(recorder.events)")

                // a moment for a wrongly started download to show up as a connection (generous, only proves an absence)
                Thread.sleep(forTimeInterval: 0.5)

                #expect(diStamp(textURL) == beforeText, "the text model file changed")
                #expect(diStamp(projectorURL) == beforeProjector, "the projector model file changed")
                #expect(diStamp(partialURL) == beforePartial, "a .partial file changed")
                let afterFolder = diDirectoryStamp(env.models)
                #expect(afterFolder.names == beforeFolder.names, "models/ now holds \(afterFolder.names), was \(beforeFolder.names)")
                #expect(afterFolder.inode == beforeFolder.inode)
                #expect(afterFolder.modified == beforeFolder.modified, "models/ was modified")
                #expect(listener.connections == 0, "a download connected to the model host \(listener.connections) times")
            }
        }
    }
}
