import Foundation
import Testing
import SesameEngine

// The settings value is built from JSON written here from design section 1 (the ten keys),
// so the expected values come from this file, never from the code under test.
// Contract these tests pin: `SettingsFile()` reads and writes `settings.json` in
// `~/Library/Application Support/Sesame/` (HOME is a temp folder, see withTempHome);
// `read()` returns the settings value (defaults when no file), `write(_:)` stores it;
// the value is Codable and each property is named as in design section 1.

private let designKeys: Set<String> = [
    "version", "startPressed", "indexDeleted", "folders", "codeSearchOn",
    "kindsOn", "hotkey", "openWith", "speeds", "loginDefaultApplied",
]

private let allOnJSON = """
{
  "version": 3,
  "startPressed": true,
  "indexDeleted": true,
  "folders": [
    {"path": "/Users/test/Pictures", "code": false, "reading": true},
    {"path": "/Users/test/Developer/api-client", "code": true, "reading": false}
  ],
  "codeSearchOn": true,
  "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
  "hotkey": "ctrl+opt+space",
  "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
  "speeds": {"photo": 1.5, "pdf": 2.25},
  "loginDefaultApplied": true
}
"""

private let allOffJSON = """
{
  "version": 4,
  "startPressed": false,
  "indexDeleted": false,
  "folders": [],
  "codeSearchOn": false,
  "kindsOn": {"photo": false, "pdf": true, "doc": false, "audio": true, "video": true, "code": false},
  "hotkey": "cmd+opt+k",
  "openWith": {"pdf": "Skim", "media": "IINA", "code": "Cursor"},
  "speeds": {"photo": 0.75},
  "loginDefaultApplied": false
}
"""

private func decode<T: Decodable>(like _: T, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func dictionary(fromJSON json: String) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
}

private func dictionary<T: Encodable>(of value: T) throws -> NSDictionary {
    let data = try JSONEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func settingsJSONOnDisk(_ t: TempHome) throws -> NSDictionary {
    let data = try Data(contentsOf: t.folder.appendingPathComponent("settings.json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

@Suite("SettingsFileTests")
struct SettingsFileTests {

    @Test func aMissingFileReadsStartPressedFalseAndIndexDeletedFalse() throws {
        try withTempHome { t in
            // first launch: not even the Sesame folder exists yet
            let first = try SettingsFile().read()
            #expect(first.startPressed == false)
            #expect(first.indexDeleted == false)

            // the folder exists, settings.json does not
            _ = try SesameFolder.create()
            let second = try SettingsFile().read()
            #expect(second.startPressed == false)
            #expect(second.indexDeleted == false)
        }
    }

    @Test func aWriteThenReadGivesTheSameValuesForEveryField() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = SettingsFile()
            let wanted = try decode(like: try file.read(), allOnJSON)

            try file.write(wanted)
            let got = try file.read()

            #expect(got.startPressed == true)
            #expect(got.indexDeleted == true)
            let expected = try dictionary(fromJSON: allOnJSON)
            let actual = try dictionary(of: got)
            #expect(Set(actual.allKeys.compactMap { $0 as? String }) == designKeys)
            for key in designKeys.sorted() {
                #expect((actual[key] as? NSObject) == (expected[key] as? NSObject), "field \(key)")
            }
        }
    }

    @Test func theFileOnDiskIsJSONHoldingExactlyTheDesignKeys() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = SettingsFile()
            try file.write(try decode(like: try file.read(), allOnJSON))

            let onDisk = try settingsJSONOnDisk(t)
            #expect(Set(onDisk.allKeys.compactMap { $0 as? String }) == designKeys)
            let expected = try dictionary(fromJSON: allOnJSON)
            for key in designKeys.sorted() {
                #expect((onDisk[key] as? NSObject) == (expected[key] as? NSObject), "key \(key) on disk")
            }
        }
    }

    @Test func theFolderHoldsOnlySettingsJsonAfterAWrite() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let before = try names(in: t.folder)
            let file = SettingsFile()

            try file.write(try decode(like: try file.read(), allOnJSON))
            #expect(try Set(names(in: t.folder)).subtracting(before) == ["settings.json"])

            try file.write(try decode(like: try file.read(), allOffJSON))
            #expect(try Set(names(in: t.folder)).subtracting(before) == ["settings.json"])
        }
    }

    @Test func aSecondInstanceSeesTheFirstsWriteAndItsLaterChange() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let first = SettingsFile()
            let second = SettingsFile()   // made before any write: it must not hold a stale copy

            try first.write(try decode(like: try first.read(), allOnJSON))
            let seen = try second.read()
            #expect(seen.startPressed == true)
            #expect(seen.indexDeleted == true)
            #expect(try dictionary(of: seen) == dictionary(fromJSON: allOnJSON))

            // every flag turned off, a shorter folder list and shorter maps: nothing stale survives
            try first.write(try decode(like: try first.read(), allOffJSON))
            let later = try second.read()
            #expect(later.startPressed == false)
            #expect(later.indexDeleted == false)
            #expect(try dictionary(of: later) == dictionary(fromJSON: allOffJSON))
            #expect(try settingsJSONOnDisk(t) == dictionary(fromJSON: allOffJSON))
        }
    }
}
