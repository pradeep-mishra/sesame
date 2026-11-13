import Foundation
import Testing
import SesameEngine

// plan-2 fix round B, tester step, items B1 (R2-01, R2-02) and B2 (R2-07): the two new `settings.json` keys.
// Written from the fix-round document (plan-2-fix-round-B.md, "Rulings": a per-folder `ticked` key through `SettingsFile`,
// default equal to `reading` so older files read the same; a `setupFinished` flag) and the sealed SettingsFileTests (the
// ten design keys, the JSON-from-text pattern). No product source was read. Every expected value is written by hand from
// the JSON each test builds. Nothing in this file names a new Swift property: a value is decoded from JSON text, written
// through `SettingsFile`, and read back as the JSON on disk, so the keys themselves are what is pinned.
//
// SHAPES THIS FILE PINS (new; the document names the keys and the default, not the encoding):
//   1. `ticked` (per folder entry, Bool) and `setupFinished` (top level, Bool) are Codable keys of the settings value.
//   2. ENCODING: a folder entry is written with a `ticked` key only when `ticked` differs from `reading`; the top level
//      is written with a `setupFinished` key only when it is true. A missing key reads as the default (`ticked` equal to
//      `reading`, `setupFinished` false). Why: an older-looking file must round-trip with no new keys, because sealed
//      tests (SpeedsStoreTests: "a key other than `speeds` changed") compare a hand-written file with what a
//      `SettingsFile` write leaves, and the sealed SettingsFileTests compare the whole key set of an old-shaped file.
//
// WHAT THE RED MEANS. Today the decoder ignores both keys, so the first and third test lose the value (the key is absent
// on disk). The second and fourth are guards: they pass today and keep the omitted-default rule from being broken.

private func decode<T: Decodable>(like _: T, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func settingsJSON(folders: String, setupFinished: String? = nil) -> String {
    let finished = setupFinished.map { ",\n  \"setupFinished\": \($0)" } ?? ""
    return """
    {
      "version": 3,
      "startPressed": true,
      "indexDeleted": false,
      "folders": [\(folders)],
      "codeSearchOn": false,
      "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
      "hotkey": "cmd+opt+k",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 1.5},
      "loginDefaultApplied": true\(finished)
    }
    """
}

private func onDisk(_ t: TempHome) throws -> NSDictionary {
    let data = try Data(contentsOf: t.folder.appendingPathComponent("settings.json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func entries(_ dictionary: NSDictionary) -> [String: NSDictionary] {
    var result: [String: NSDictionary] = [:]
    for entry in (dictionary["folders"] as? [NSDictionary]) ?? [] {
        if let path = entry["path"] as? String { result[path] = entry }
    }
    return result
}

@Suite("SettingsFileTickedTests")
struct SettingsFileTickedTests {

    @Test func aFolderTickedDifferentlyFromReadingKeepsItsTickThroughAWriteAndARead() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = SettingsFile()
            let folders = """
            {"path": "/Users/test/Waiting", "code": false, "reading": false, "ticked": true},
            {"path": "/Users/test/Dropped", "code": false, "reading": true, "ticked": false}
            """
            try file.write(try decode(like: try file.read(), settingsJSON(folders: folders)))

            let disk = entries(try onDisk(t))
            #expect(disk["/Users/test/Waiting"]?["reading"] as? Bool == false, "Waiting: \(String(describing: disk["/Users/test/Waiting"]))")
            #expect(disk["/Users/test/Waiting"]?["ticked"] as? Bool == true, "a pending tick was not stored: \(String(describing: disk["/Users/test/Waiting"]))")
            #expect(disk["/Users/test/Dropped"]?["reading"] as? Bool == true, "Dropped: \(String(describing: disk["/Users/test/Dropped"]))")
            #expect(disk["/Users/test/Dropped"]?["ticked"] as? Bool == false, "an unticked folder that is still reading lost its tick: \(String(describing: disk["/Users/test/Dropped"]))")

            // read it back and write it again: the ticks survive a second round trip
            try file.write(try file.read())
            let again = entries(try onDisk(t))
            #expect(again["/Users/test/Waiting"]?["ticked"] as? Bool == true, "second round trip, Waiting: \(String(describing: again["/Users/test/Waiting"]))")
            #expect(again["/Users/test/Dropped"]?["ticked"] as? Bool == false, "second round trip, Dropped: \(String(describing: again["/Users/test/Dropped"]))")
        }
    }

    // GUARD: passes today. A tick equal to `reading`, written or implied, adds no key.
    @Test func aFolderTickedLikeReadingWritesNoTickedKey() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = SettingsFile()
            let folders = """
            {"path": "/Users/test/Old-reading", "code": false, "reading": true},
            {"path": "/Users/test/Old-not-reading", "code": false, "reading": false},
            {"path": "/Users/test/Same-true", "code": false, "reading": true, "ticked": true},
            {"path": "/Users/test/Same-false", "code": false, "reading": false, "ticked": false}
            """
            try file.write(try decode(like: try file.read(), settingsJSON(folders: folders)))

            let disk = entries(try onDisk(t))
            #expect(disk.count == 4, "folders on disk: \(disk.keys.sorted())")
            for (path, entry) in disk {
                #expect(entry["ticked"] == nil, "\(path) got a `ticked` key although it equals `reading`: \(entry)")
                #expect(Set(entry.allKeys.compactMap { $0 as? String }) == ["path", "code", "reading"], "\(path) keys: \(entry.allKeys)")
            }
        }
    }

    @Test func setupFinishedIsStoredWhenTrue() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = SettingsFile()
            try file.write(try decode(like: try file.read(), settingsJSON(folders: "", setupFinished: "true")))
            let before = try onDisk(t)
            #expect(before["setupFinished"] as? Bool == true, "setupFinished on disk: \(String(describing: before["setupFinished"]))")

            // it survives a read and a write, and nothing else in the file moves
            try file.write(try file.read())
            let after = try onDisk(t)
            #expect(after["setupFinished"] as? Bool == true, "lost on the second round trip")
            #expect(after == before, "a plain read and write changed the file: before \(before), after \(after)")
        }
    }

    // GUARD: passes today. False or missing writes no `setupFinished` key, so an old-shaped file keeps its ten keys.
    @Test func setupFinishedIsNotWrittenWhileFalseOrMissing() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = SettingsFile()
            try file.write(try decode(like: try file.read(), settingsJSON(folders: "")))
            let missing = try onDisk(t)
            #expect(missing["setupFinished"] == nil, "a key was written for a missing flag: \(missing)")

            try file.write(try decode(like: try file.read(), settingsJSON(folders: "", setupFinished: "false")))
            let explicitFalse = try onDisk(t)
            #expect(explicitFalse["setupFinished"] == nil, "a key was written for a false flag: \(explicitFalse)")
            #expect(Set(explicitFalse.allKeys.compactMap { $0 as? String }) == [
                "version", "startPressed", "indexDeleted", "folders", "codeSearchOn", "kindsOn", "hotkey", "openWith", "speeds",
                "loginDefaultApplied",
            ])
        }
    }
}
