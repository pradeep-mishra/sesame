import Foundation
import Testing
import SesameEngine

private let dimension = 768

private func unit(_ axis: Int) -> [Float] {
    var vector = [Float](repeating: 0, count: dimension)
    vector[axis % dimension] = 1
    return vector
}

private func tilted(dot a: Float, noise k: Int) -> [Float] {
    var vector = [Float](repeating: 0, count: dimension)
    vector[0] = a
    vector[k] = (1 - a * a).squareRoot()
    return vector
}

private let queryVector: [Float] = unit(0)

private func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
}

private struct Stat {
    let size: Int64
    let mtimeNs: Int64
    let inode: Int64
    let device: Int64
}

private func statOf(_ path: String) throws -> Stat {
    var info = Darwin.stat()
    try #require(lstat(path, &info) == 0, "setup: cannot stat \(path)")
    return Stat(size: Int64(info.st_size),
                mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                inode: Int64(info.st_ino), device: Int64(info.st_dev))
}

private func writeFile(_ path: String, _ data: Data) throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 3600)], ofItemAtPath: path)
}

private struct Old {
    let pick: String
    let photo: String
    let codeDone: String
    let codePartial: String
}

private func oldTree(_ t: TempHome) throws -> Old {
    let work = t.home.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let pick = resolved(work.path) + "/pick"
    try writeFile(pick + "/pic.png", rxPicture(seed: 11, type: "public.png"))
    try writeFile(pick + "/alpha.swift", Data("func zqretrybackoff() {}\nlet zqexactline = 1\n".utf8))
    try writeFile(pick + "/beta.py", Data("def zqotherthing():\n    return 2\n".utf8))
    return Old(pick: pick, photo: pick + "/pic.png", codeDone: pick + "/alpha.swift", codePartial: pick + "/beta.py")
}

@discardableResult
private func plant(_ store: IndexStore, _ path: String, kind: String, status: String, source: String, stretches: [String]) throws -> Int64 {
    let info = try statOf(path)
    let id = try store.addFile(path: path, kind: kind, size: info.size, mtimeNs: info.mtimeNs, inode: info.inode,
                               device: info.device, status: status)
    _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                             name: (path as NSString).lastPathComponent, body: "")
    for (index, body) in stretches.enumerated() {
        _ = try store.addPassage(fileID: id, source: source, start: Double(index + 1), end: Double(index + 1),
                                 modality: kind == "photo" ? "image" : "text", vector: tilted(dot: 0.5, noise: 5 + index),
                                 name: "", body: body)
    }
    return id
}

private func plantOldIndex(_ old: Old) throws {
    let store = try IndexStore()
    defer { store.close() }
    try store.setMeta("vector_source", LlamaEmbedder.vectorSource)
    try plant(store, old.photo, kind: "photo", status: "done", source: "image", stretches: ["a quiet harbour at dawn"])
    try plant(store, old.codeDone, kind: "code", status: "done", source: "code",
              stretches: ["func zqretrybackoff() {}", "let zqexactline = 1"])
    try plant(store, old.codePartial, kind: "code", status: "partial", source: "code", stretches: ["def zqotherthing():"])
}

private let oldSettingsJSON = """
{
  "version": 4,
  "startPressed": true,
  "indexDeleted": false,
  "folders": [
    {"path": "@PICK@", "code": true, "reading": true}
  ],
  "codeSearchOn": true,
  "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
  "hotkey": "ctrl+opt+space",
  "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "Zed"},
  "speeds": {"photo": 1.5, "pdf": 2.25, "code": 3.5},
  "loginDefaultApplied": true
}
"""

private func foldersLine(_ path: String, code: Bool) -> String {
    "{\"cmd\":\"folders\",\"folders\":[{\"path\":\(rxJSONString(path)),\"code\":\(code)}]}"
}

private struct Snapshot: Equatable {
    var photoFile: [[String?]]
    var photoPassages: [[String?]]
    var photoFts: [[String?]]
}

private func snapshot(_ db: AtDB) -> Snapshot {
    Snapshot(
        photoFile: db.rows("select id, path, kind, status, size, mtime_ns, inode from files where kind = 'photo' order by id") ?? [],
        photoPassages: db.rows("select id, file_id, source from passages where file_id in (select id from files where kind = 'photo') order by id") ?? [],
        photoFts: db.rows("select rowid, name, body from fts where rowid in (select p.id from passages p join files f on f.id = p.file_id where f.kind = 'photo') order by rowid") ?? [])
}

private func runHelper(_ t: TempHome, old: Old, tick: Bool) throws -> AtDB {
    let executable = KitPaths.bundledHelper
    try #require(FileManager.default.isExecutableFile(atPath: executable.path),
                 "the bundled helper is missing: run `scripts/bundle.sh` (expected \(executable.path))")
    let rig = try PipeRig(helper: executable, home: t.home, models: nil, scratch: t.home)
    defer { rig.cleanup() }
    rig.send(foldersLine(old.pick, code: tick))
    #expect(rig.read(cap: 120, until: { rig.walked }), "no `walked` event; stderr: \(rig.stderrText.prefix(300))")
    rig.closeStdin()
    let exit = rig.waitForExit(timeout: 60)
    #expect(exit?.status == 0, "the helper should exit 0 when its stdin ends; stderr: \(rig.stderrText.prefix(300))")
    return try #require(AtDB(path: t.folder.appendingPathComponent("index.sqlite").path), "no index after the run")
}

private func expectReconciled(_ db: AtDB, before: Snapshot, label: String) {
    #expect(db.int("select count(*) from files") == 1, "\(label): only the photo row is left")
    #expect(db.int("select count(*) from files where kind = 'code'") == 0, "\(label): a code row is left")
    #expect(db.int("select count(*) from passages where source = 'code'") == 0, "\(label): a code passage is left")
    #expect(db.int("select count(*) from passages where file_id not in (select id from files)") == 0, "\(label): a passage has no file")
    #expect(db.int("select count(*) from passages") == 2, "\(label): the photo keeps its two passages")
    #expect(db.int("select count(*) from fts") == 2, "\(label): the photo keeps its two fts rows")
    #expect(db.int("select count(*) from passages where id not in (select rowid from fts)") == 0, "\(label): a passage lost its fts row")
    #expect(db.int("select count(*) from fts where rowid not in (select id from passages)") == 0, "\(label): an fts row of a deleted passage is left")
    for word in ["zqretrybackoff", "zqexactline", "zqotherthing"] {
        #expect(db.int("select count(*) from fts where fts match 'body:\(word)'") == 0, "\(label): \(word) is still found")
    }
    #expect(snapshot(db) == before, "\(label): the photo row, its passages or its fts rows changed")
    #expect(db.integrity() == "ok", "\(label): PRAGMA integrity_check gave \(db.integrity())")
}

@Suite("OldCodeRowsTests", .serialized)
struct OldCodeRowsTests {

    @Test func theNextWalkRemovesOldCodeRowsTheirPassagesAndFtsRowsAndLeavesThePhotoRowAsItWas() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let old = try oldTree(t)
            try plantOldIndex(old)
            let planted = try #require(AtDB(path: t.folder.appendingPathComponent("index.sqlite").path))
            #expect(planted.int("select count(*) from files") == 3 && planted.int("select count(*) from files where kind = 'code'") == 2,
                    "setup: three rows, two of them code")
            #expect(planted.int("select count(*) from files where kind = 'code' and status = 'partial'") == 1, "setup: one code row is partial")
            #expect(planted.int("select count(*) from passages") == 2 + 3 + 2, "setup: the photo (two) and the two code files (three and two) hold 7 passages")
            #expect(planted.int("select count(*) from fts") == 7, "setup: one fts row per passage")
            let before = snapshot(planted)
            #expect(before.photoFile.count == 1 && before.photoPassages.count == 2 && before.photoFts.count == 2, "setup: the photo row holds two passages")

            let db = try runHelper(t, old: old, tick: true)
            expectReconciled(db, before: before, label: "tick on")
        }
    }

    @Test func theSameRunWithAnOldSettingsFileHoldingTheCodeKeysLoadsAndGivesTheSameRows() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let old = try oldTree(t)
            try plantOldIndex(old)
            let settingsText = oldSettingsJSON.replacingOccurrences(of: "@PICK@", with: old.pick)
            try Data(settingsText.utf8).write(to: t.folder.appendingPathComponent("settings.json"))

            let loaded = try SettingsFile().read()
            let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? NSDictionary)
            #expect(json["codeSearchOn"] as? Bool == true, "codeSearchOn as found")
            #expect((json["openWith"] as? NSDictionary)?["code"] as? String == "Zed", "openWith.code as found")
            let folders = try #require(json["folders"] as? [NSDictionary])
            #expect(folders.count == 1 && folders[0]["code"] as? Bool == true && folders[0]["path"] as? String == old.pick, "folders[].code as found")
            #expect((json["speeds"] as? NSDictionary)?["code"] as? Double == 3.5, "speeds.code as found")

            let planted = try #require(AtDB(path: t.folder.appendingPathComponent("index.sqlite").path))
            let before = snapshot(planted)
            let db = try runHelper(t, old: old, tick: true)
            expectReconciled(db, before: before, label: "old settings file")

            let after = try SettingsFile().read()
            let afterJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(after)) as? NSDictionary)
            #expect(afterJSON["codeSearchOn"] as? Bool == true && (afterJSON["openWith"] as? NSDictionary)?["code"] as? String == "Zed",
                    "the run left the settings file as it was")
        }
    }

    @Test func beforeTheReconcileASearchOverTheOldIndexReturnsNoCodeRow() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let old = try oldTree(t)
            let docPath = old.pick + "/notes.txt"
            try writeFile(docPath, Data("zqexactline is also in a note\n".utf8))
            let store = try IndexStore()
            try plant(store, old.photo, kind: "photo", status: "done", source: "image", stretches: ["a quiet harbour at dawn"])
            try plant(store, old.codeDone, kind: "code", status: "done", source: "code",
                      stretches: ["func zqretrybackoff() {}", "let zqexactline = 1"])
            try plant(store, docPath, kind: "doc", status: "done", source: "chunk", stretches: ["zqexactline is also in a note"])
            var inode: Int64 = 800_000
            for number in 0..<150 {
                inode += 1
                let filler = try store.addFile(path: "\(old.pick)/gen/g\(number).py", kind: "code", size: 10,
                                               mtimeNs: 1_700_000_000_000_000_000, inode: inode, device: 1, status: "done")
                _ = try store.addPassage(fileID: filler, source: "code", start: 1, end: 1, modality: "text",
                                         vector: tilted(dot: 0.0, noise: 1 + number % 700), name: "", body: "filler \(number)")
            }
            store.close()

            let oldSettings = Visible(folders: [Settings.Folder(path: old.pick, code: true, reading: true)], codeSearchOn: true,
                                      kindsOn: ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true])
            let reader = IndexReader()
            defer { reader.close() }
            let search = Search(reader: reader)

            let exact = search.exactHits(text: "zqexactline", visible: oldSettings)
            #expect(exact.map(\.path) == [docPath], "exactHits for the exact text of a code line: the note only, got \(exact.map(\.path))")
            let plain = try #require(search.rank(text: "zqexactline", vector: queryVector, ticket: search.newTicket(), visible: oldSettings))
            #expect(!plain.contains { $0.path.hasSuffix(".swift") || $0.path.hasSuffix(".py") }, "a plain search listed a code row: \(plain.map(\.path))")

            let codeScope = search.rank(text: "zqexactline", vector: queryVector, ticket: search.newTicket(), visible: oldSettings, scope: .code) ?? []
            #expect(codeScope.isEmpty, "the code scope listed a row although code is off: \(codeScope.map(\.path))")
            let codeExact = search.exactHits(text: "zqexactline", visible: oldSettings, scope: .code)
            #expect(codeExact.isEmpty, "the code scope's exact hits listed a row although code is off: \(codeExact.map(\.path))")
        }
    }
}
