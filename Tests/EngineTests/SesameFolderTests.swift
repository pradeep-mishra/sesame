import Foundation
import Testing
import SesameEngine

// Every test runs against a throwaway HOME, so `~/Library/Application Support/Sesame/`
// is a folder under a temp directory and the person's real folder is never touched.
// HOME is process-wide, so tests that use it take this one lock (SettingsFileTests too).
let homeLock = NSLock()

struct TempHome {
    let home: URL
    var support: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
    var folder: URL { support.appendingPathComponent("Sesame", isDirectory: true) }
}

func withTempHome(_ body: (TempHome) throws -> Void) throws {
    homeLock.lock()
    defer { homeLock.unlock() }
    let fm = FileManager.default
    let home = fm.temporaryDirectory
        .appendingPathComponent("sesame-engine-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let previous = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: home)
    }
    try body(TempHome(home: home))
}

// Creates the Sesame folder, and stops the test before it writes anything if the folder
// did not land under the temp HOME (the code must read HOME at call time: NSHomeDirectory()
// ignores a HOME set after launch, so it would write into the person's real folder).
func createFolder(_ t: TempHome) throws -> Bool {
    _ = try SesameFolder.create()
    guard FileManager.default.fileExists(atPath: t.folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before writing anything")
        return false
    }
    return true
}

func names(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

func posixMode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? Int)
    return permissions & 0o777
}

func inode(of url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let number = try #require(attributes[.systemFileNumber] as? UInt64)
    return number
}

func bytes(_ text: String) -> Data { Data(text.utf8) }

let logCap = 1_048_576

@Suite("SesameFolderTests")
struct SesameFolderTests {

    @Test func createMakesTheFolderWithMode0700AndASecondCallKeepsIt() throws {
        try withTempHome { t in
            let fm = FileManager.default
            #expect(!fm.fileExists(atPath: t.folder.path))

            _ = try SesameFolder.create()

            var isDirectory: ObjCBool = false
            #expect(fm.fileExists(atPath: t.folder.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            #expect(try posixMode(of: t.folder) == 0o700)

            let kept = t.folder.appendingPathComponent("kept.txt")
            try bytes("still here").write(to: kept)

            _ = try SesameFolder.create()

            #expect(try names(in: t.folder) == ["kept.txt"])
            #expect(try Data(contentsOf: kept) == bytes("still here"))
            #expect(try posixMode(of: t.folder) == 0o700)
        }
    }

    @Test func writeLeavesOnlyTheFinalNameAndAReplacedFileHoldsTheNewBytesWhole() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let before = try names(in: t.folder)
            let target = t.folder.appendingPathComponent("settings.json")

            try SesameFolder.write(bytes("first version, the longer one"), to: "settings.json")
            #expect(try Set(names(in: t.folder)).subtracting(before) == ["settings.json"])
            #expect(try Data(contentsOf: target) == bytes("first version, the longer one"))
            let firstInode = try inode(of: target)

            try SesameFolder.write(bytes("second"), to: "settings.json")
            #expect(try Set(names(in: t.folder)).subtracting(before) == ["settings.json"])
            #expect(try Data(contentsOf: target) == bytes("second"))
            // temp file then rename: the final name now points at a new file, never a rewrite in place
            #expect(try inode(of: target) != firstInode)

            let pattern = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            try SesameFolder.write(pattern, to: "blob.bin")
            #expect(try Data(contentsOf: t.folder.appendingPathComponent("blob.bin")) == pattern)
            #expect(try Set(names(in: t.folder)).subtracting(before) == ["settings.json", "blob.bin"])
        }
    }

    @Test func appendAddsBytesAfterTheOnesAlreadyThere() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let notes = t.folder.appendingPathComponent("notes.txt")

            try SesameFolder.append(bytes("abc"), to: "notes.txt")
            #expect(try Data(contentsOf: notes) == bytes("abc"))

            try SesameFolder.append(bytes("def"), to: "notes.txt")
            #expect(try Data(contentsOf: notes) == bytes("abcdef"))
            #expect(try SesameFolder.size(of: "notes.txt") == 6)
            #expect(try names(in: t.folder) == ["notes.txt"])
        }
    }

    @Test func aLogNameNeverGrowsPastOneMebibyte() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let log = t.folder.appendingPathComponent("index.log")
            let chunk = Data(repeating: UInt8(ascii: "x"), count: 65_536)

            for round in 1...20 {   // 20 x 64 KiB = 1.25 MiB offered
                try SesameFolder.append(chunk, to: "index.log")
                let onDisk = try #require(
                    FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int)
                #expect(onDisk <= logCap, "after append \(round) the log is \(onDisk) bytes")
                #expect(try SesameFolder.size(of: "index.log") == onDisk)
            }
            #expect(try SesameFolder.size(of: "index.log") > 0)

            // one single append larger than the cap
            try SesameFolder.append(Data(repeating: UInt8(ascii: "y"), count: 2 * logCap), to: "app.log")
            let appLog = try #require(
                FileManager.default.attributesOfItem(
                    atPath: t.folder.appendingPathComponent("app.log").path)[.size] as? Int)
            #expect(appLog <= logCap)
            #expect(appLog > 0)
        }
    }

    @Test func renameAndDeleteWorkOnAFileInsideTheFolder() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }

            try SesameFolder.write(bytes("payload"), to: "a.txt")
            try SesameFolder.rename("a.txt", to: "b.txt")
            #expect(try names(in: t.folder) == ["b.txt"])
            #expect(try Data(contentsOf: t.folder.appendingPathComponent("b.txt")) == bytes("payload"))

            try SesameFolder.write(bytes("sibling"), to: "keep.txt")
            try SesameFolder.delete("b.txt")
            #expect(try names(in: t.folder) == ["keep.txt"])
            #expect(try Data(contentsOf: t.folder.appendingPathComponent("keep.txt")) == bytes("sibling"))
        }
    }

    @Test func aNameThatIsNotAPlainFileNameIsRefusedAndNothingOutsideTheFolderChanges() throws {
        try withTempHome { t in
            let fm = FileManager.default
            guard try createFolder(t) else { return }
            try SesameFolder.write(bytes("inside"), to: "ok.txt")

            // files outside the Sesame folder that must come through untouched
            let sentinel = t.support.appendingPathComponent("sentinel.txt")
            try bytes("keep me").write(to: sentinel)
            let victim = t.home.appendingPathComponent("abs-victim.txt")
            try bytes("keep me too").write(to: victim)
            let absoluteTarget = t.home.appendingPathComponent("abs-target.txt").path

            let badNames = [
                "../escape.txt", "../sentinel.txt", "a/b.txt", "sub/../x.txt",
                "..", absoluteTarget, victim.path,
            ]
            let payload = bytes("should never land")
            for name in badNames {
                #expect(throws: (any Error).self, "write to \(name)") {
                    try SesameFolder.write(payload, to: name)
                }
                #expect(throws: (any Error).self, "append to \(name)") {
                    try SesameFolder.append(payload, to: name)
                }
                #expect(throws: (any Error).self, "delete \(name)") {
                    try SesameFolder.delete(name)
                }
                #expect(throws: (any Error).self, "rename ok.txt to \(name)") {
                    try SesameFolder.rename("ok.txt", to: name)
                }
                #expect(throws: (any Error).self, "rename \(name) to stolen.txt") {
                    try SesameFolder.rename(name, to: "stolen.txt")
                }
            }

            #expect(try names(in: t.folder) == ["ok.txt"])
            #expect(try Data(contentsOf: t.folder.appendingPathComponent("ok.txt")) == bytes("inside"))
            #expect(try names(in: t.support) == ["Sesame", "sentinel.txt"])
            #expect(try Data(contentsOf: sentinel) == bytes("keep me"))
            #expect(try names(in: t.home) == ["Library", "abs-victim.txt"])
            #expect(try Data(contentsOf: victim) == bytes("keep me too"))
            #expect(!fm.fileExists(atPath: absoluteTarget))
        }
    }

    // MARK: plan-2-t22, the Caches delete
    //
    // Written from the t22 entry and Decisions D7 of plan-2-tasks.md: `SesameFolder.deleteCaches()` removes
    // `~/Library/Caches/app.sesame.Sesame` and `~/Library/Caches/SesameHelper` whole and nothing else. Expected folders and
    // texts are written by hand from the folders each test plants.
    //
    // SHAPES THESE TESTS PIN (the entry names the call and a new `SesameFolder.Place`, and fixes no signature):
    //   `static func SesameFolder.deleteCaches() throws`, no argument, reading HOME at call time like `create()`.
    //   `SesameFolder.Place` is NOT named by any test: its shape is not given, so "nothing else under Caches can be named"
    //   is read through what exists. `deleteCaches()` takes no name, and every call that does take a name
    //   (`write`, `append`, `delete`, `rename`) refuses a name that reaches into `Caches` (a slash, `..`, an absolute path).

    private func planted(_ t: TempHome, _ relative: String, _ text: String) throws {
        let url = t.home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes(text).write(to: url)
    }

    private func text(_ t: TempHome, _ relative: String) -> String? {
        (try? Data(contentsOf: t.home.appendingPathComponent(relative))).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func deleteCachesRemovesTheTwoSesameCacheFoldersWholeAndLeavesEverythingElse() throws {
        try withTempHome { t in
            let fm = FileManager.default
            guard try createFolder(t) else { return }   // stops first if SesameFolder ignores the HOME of this test
            try planted(t, "Library/Caches/app.sesame.Sesame/x/y", "sesame cache")
            try planted(t, "Library/Caches/SesameHelper/z", "helper cache")
            try planted(t, "Library/Caches/other.app/keep", "someone else's cache")
            // names that only look like the two: neither may go
            try planted(t, "Library/Caches/app.sesame.Sesame.old/mine", "a different folder")
            try planted(t, "Library/Caches/SesameHelper2/mine", "a different folder")
            try planted(t, "Library/Preferences/app.sesame.Sesame.plist", "prefs")
            try SesameFolder.write(bytes("settings"), to: "settings.json")

            try SesameFolder.deleteCaches()

            #expect(!fm.fileExists(atPath: t.home.appendingPathComponent("Library/Caches/app.sesame.Sesame").path),
                    "Caches/app.sesame.Sesame is still there")
            #expect(!fm.fileExists(atPath: t.home.appendingPathComponent("Library/Caches/SesameHelper").path),
                    "Caches/SesameHelper is still there")
            let caches = t.home.appendingPathComponent("Library/Caches", isDirectory: true)
            let held = try names(in: caches)
            #expect(Set(held) == ["other.app", "app.sesame.Sesame.old", "SesameHelper2"], "Caches now holds \(held)")
            #expect(text(t, "Library/Caches/other.app/keep") == "someone else's cache")
            #expect(text(t, "Library/Caches/app.sesame.Sesame.old/mine") == "a different folder")
            #expect(text(t, "Library/Caches/SesameHelper2/mine") == "a different folder")
            #expect(text(t, "Library/Preferences/app.sesame.Sesame.plist") == "prefs")
            #expect(text(t, "Library/Application Support/Sesame/settings.json") == "settings")
        }
    }

    @Test func deleteCachesIsNoErrorWhenFoldersAreMissingOrAlreadyGoneAndASecondCallIsFine() throws {
        try withTempHome { t in
            let fm = FileManager.default
            guard try createFolder(t) else { return }
            let library = t.home.appendingPathComponent("Library", isDirectory: true)

            // no Caches folder at all: no error, and nothing is made
            try SesameFolder.deleteCaches()
            let inLibrary = try names(in: library)
            #expect(inLibrary == ["Application Support"], "Library now holds \(inLibrary)")

            // only one of the two there
            try planted(t, "Library/Caches/SesameHelper/z", "helper cache")
            try planted(t, "Library/Caches/other.app/keep", "someone else's cache")
            try SesameFolder.deleteCaches()
            #expect(!fm.fileExists(atPath: t.home.appendingPathComponent("Library/Caches/SesameHelper").path))
            #expect(text(t, "Library/Caches/other.app/keep") == "someone else's cache")

            // a second call right after: still no error, still the same result
            try SesameFolder.deleteCaches()
            try SesameFolder.deleteCaches()
            #expect(try names(in: t.home.appendingPathComponent("Library/Caches", isDirectory: true)) == ["other.app"])
            #expect(text(t, "Library/Caches/other.app/keep") == "someone else's cache")
        }
    }

    @Test func aNameThatReachesIntoCachesIsRefusedByEveryCallThatTakesAName() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            try planted(t, "Library/Caches/other.app/keep", "someone else's cache")
            try planted(t, "Library/Caches/app.sesame.Sesame/x/y", "sesame cache")
            try planted(t, "Library/Caches/SesameHelper/z", "helper cache")
            let absoluteCaches = t.home.appendingPathComponent("Library/Caches/other.app/keep").path

            let badNames = [
                "../../Caches/other.app/keep", "../../Caches/other.app", "../../Caches",
                "../../Caches/app.sesame.Sesame", "../../Caches/SesameHelper/z",
                "..", "../..", absoluteCaches,
            ]
            let payload = bytes("should never land")
            for name in badNames {
                #expect(throws: (any Error).self, "write to \(name)") { try SesameFolder.write(payload, to: name) }
                #expect(throws: (any Error).self, "append to \(name)") { try SesameFolder.append(payload, to: name) }
                #expect(throws: (any Error).self, "delete \(name)") { try SesameFolder.delete(name) }
                #expect(throws: (any Error).self, "rename to \(name)") {
                    try SesameFolder.write(bytes("inside"), to: "ok.txt")
                    try SesameFolder.rename("ok.txt", to: name)
                }
                #expect(throws: (any Error).self, "rename \(name) to stolen.txt") { try SesameFolder.rename(name, to: "stolen.txt") }
            }

            #expect(text(t, "Library/Caches/other.app/keep") == "someone else's cache")
            #expect(text(t, "Library/Caches/app.sesame.Sesame/x/y") == "sesame cache")
            #expect(text(t, "Library/Caches/SesameHelper/z") == "helper cache")
            #expect(try Set(names(in: t.home.appendingPathComponent("Library/Caches", isDirectory: true)))
                    == ["other.app", "app.sesame.Sesame", "SesameHelper"])
        }
    }
}
