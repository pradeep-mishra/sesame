import Foundation
import Testing
import SesameEngine

// plan-5-t7, tester step. Written from the entry plan-5-t7 of plan-5-tasks.md (Tests: HelperKindsOffTests), its Conventions (lessons 1 to 8)
// and spec S4.6 ("turning audio or video off hides their results at once, on shows them again, nothing of a kind that is off is read")
// and S7 ("a kind that is off is not read") only; no product source is read. The rig is MediaRig.swift and MediaRigVideo.swift (the audio
// and video clips), PdfReaderTests.swift's `PdfMaker`, DocReaderTests.swift's `DocMaker` (the long document) and IndexAttemptTests.swift
// (`AtWorld`, `AtDB`, `atStartHelper`, `atFoldersLine`, `atMakePhotos`, `atPassageIDs`, `atCleanStop`, `atHelperWarm`). The entry names
// IndexReconcileTests' rigs and PipeRig; the bundled-helper harness those use is `HelperProcess` through `atStartHelper`, which every
// other helper suite of plans 3 to 5 uses, so it is the one used here (PipeRig is a pipe the test may close, which nothing here needs).
//
// How a run is made: the bundled release helper alone (`dist/Sesame.app/Contents/MacOS/SesameHelper index`, run `scripts/bundle.sh`
// first: a stale bundle makes these tests fail, never pass), `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME. The test WRITES that HOME's
// `settings.json` itself (the whole file as the app writes it, mode 0600), changes it between `folders` lines the way the app does
// (setKind writes the file, then sends `folders` only when a kind goes on), and reads the index with the read-only connection of
// IndexAttemptTests.swift. Every file is made by this file under $TMPDIR and removed with its world.
//
// THE HELPER'S RULE the entry fixes, and what each test pins of it:
//   - at each `folders` line the helper reads `kindsOn` from the stored settings.json; a file of a kind whose key is false gets no row
//     (the row is made by the reconcile, so "no row" is read once the reconcile of that line has committed: right after `walked` for the
//     first line, as IndexReconcileTests' header says, and once a sentinel photo's row is there for a later line);
//   - rows of an off kind already in the index stay unchanged (the same `files` columns, the same passage ids) through further lines;
//   - a file created while the kind is off has no row; with the kind on again and one `folders` line it is read and the old rows keep
//     their ids;
//   - at each step the helper reads `kindsOn` again: a file `partial` when its kind goes off is not read further (the next step is
//     skipped and the row stays `partial` with the same `read_to` and the same passages) and is read to the end when the kind is on and
//     a `folders` line comes;
//   - a kind with no key is on; a settings.json that is missing or cannot be read or parsed means every kind is on.
//
// SHAPES THIS FILE PINS that the entry did not fix (each is one place to edit):
//   1. The helper says `walked` once, for its first walk (measured: a second `folders` line over a changed tree gives only `changed`, and
//      none when nothing changed). So the first line is awaited by `walked`, and every later line by a SENTINEL: a new photo made with
//      the line, whose row appearing means the line's reconcile (one transaction) has committed; "no row" for a file of an off kind
//      made beside the sentinel is then read at once, with no clock (`KoSession.sendFoldersAfterSentinel`).
//   2. A skipped file of an off kind is not a `could_not_read` row and not a `pending` row: it has no row at all (the entry: "leaves no
//      row for the audio file").
//   3. The partial test flips the switch right after it sees the first `partial` commit, with no `folders` line (the app's setKind(off)
//      sends nothing); the file then ends `partial` with a `read_to` of at least the first step's (the step in flight when the file
//      changes may finish: the rule is "the next step is skipped") and does not change for 8 s.
//   4. A photo beside the files is read in every run and ends `done` (the entry: "a `done` row for the photo"); the photo reading is the
//      only proof here that the helper kept working while a kind was off.
// WHAT THE RED MEANS: nothing in the helper reads `kindsOn` today, so every kind is read whatever the file says: the "no row" checks
// find a row, the partial files go on to `done`. The tests of a missing, broken, partial or empty settings.json are guards that hold
// before the change and must still hold after it (they cannot be red).

private let koAllKinds = ["photo", "pdf", "doc", "audio", "video", "code"]

// MARK: the files each kind is made of

private struct KoKind: Sendable {
    let key: String
    let ext: String
    /// A small file that reaches `done` in a few seconds; `n` makes the contents differ between files.
    let small: @Sendable (_ path: String, _ n: Int) throws -> Void
    /// A file whose reading takes several steps (the first commit shows `partial`).
    let long: @Sendable (_ path: String) throws -> Void
}

private let koAudio = KoKind(
    key: "audio", ext: "wav",
    small: { try MediaRig.writeWav($0, [.tone(5, db: -20, hz: 300 + Double($1) * 40)]) },
    long: { try MediaRig.writeWav($0, rate: 8000, [.tone(2000, db: -20, hz: 250)]) })   // four steps of 500 s

private let koVideo = KoKind(
    key: "video", ext: "mp4",
    small: { try MediaRig.writeVideo($0, shots: MediaRig.shots([6, 6], firstShade: $1)) },
    long: { try MediaRig.writeVideo($0, shots: MediaRig.shots(Array(repeating: 10, count: 40))) })   // 400 s: steps of 180 s

private let koPdf = KoKind(
    key: "pdf", ext: "pdf",
    small: { path, n in
        try PdfMaker.write([.text(PdfMaker.rich(PdfMaker.token("kopa", n))), .text(PdfMaker.rich(PdfMaker.token("kopb", n)))], to: path)
    },
    long: { path in
        let pages: [PdfMaker.Page] = (1...301).map { .text(PdfMaker.rich(PdfMaker.token("kolp", $0))) }   // steps of 30 pages
        try PdfMaker.write(pages, to: path)
    })

private let koDoc = KoKind(
    key: "doc", ext: "txt",
    small: { path, n in
        try Data("Harbour memo \(n). The grey harbour keeps a copper lantern beside the old meadow gate.\n".utf8).write(to: URL(fileURLWithPath: path))
    },
    long: { path in
        try Data(DocMaker.spaceless(parts: 400, size: DocReader.chunkCharacters).text.utf8).write(to: URL(fileURLWithPath: path))
    })

private func koName(_ kind: KoKind, _ tag: String) -> String { "\(kind.key)-\(tag).\(kind.ext)" }

@discardableResult
private func koMake(_ world: AtWorld, _ kind: KoKind, tag: String, n: Int, age: Int) throws -> String {
    let path = world.photos.appendingPathComponent(koName(kind, tag)).path
    try kind.small(path, n)
    try mrAge(path, age)
    return path
}

// MARK: settings.json, written by the test

private func koSettingsURL(_ world: AtWorld) -> URL { world.support.appendingPathComponent("settings.json") }

private func koKindsOn(off: [String] = []) -> [String: Bool] {
    var out: [String: Bool] = [:]
    for key in koAllKinds { out[key] = !off.contains(key) }
    return out
}

private func koWriteRaw(_ world: AtWorld, _ text: String) throws {
    let url = koSettingsURL(world)
    try Data(text.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func koWriteSettings(_ world: AtWorld, kindsOn: [String: Bool]) throws {
    let kinds = kindsOn.keys.sorted().map { "\"\($0)\": \(kindsOn[$0]! ? "true" : "false")" }.joined(separator: ", ")
    try koWriteRaw(world, """
    {
      "version": 3,
      "startPressed": true,
      "indexDeleted": false,
      "folders": [],
      "codeSearchOn": false,
      "kindsOn": {\(kinds)},
      "hotkey": "ctrl+opt+space",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 3.0},
      "loginDefaultApplied": true
    }
    """)
}

// MARK: the helper, folders lines and the index

private final class KoSession {
    let world: AtWorld
    let helper: HelperProcess
    private var walked = false

    init(_ world: AtWorld) throws {
        self.world = world
        helper = try atStartHelper(world)
    }

    func sendFolders() {
        helper.send(atFoldersLine([world.photos]))
    }

    /// The helper's `walked` event, which it says once, for its first walk (IndexReconcileTests: "exactly 1" `walked`); the reconcile
    /// has committed when it arrives. False on a timeout or when the helper is gone.
    func waitFirstWalk(timeout: TimeInterval = 300) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !walked, Date() < deadline {
            guard let line = helper.nextLine(timeout: 0.5) else {
                if !helper.isRunning { break }
                continue
            }
            if let reply = HelperReply(line.text), reply.event == "walked" { walked = true }
        }
        return walked
    }

    /// A later `folders` line gives no event when it changes nothing, so the test makes a SENTINEL: a new photo (a kind that is on) is
    /// created, the line is sent, and the test waits until the sentinel's row is in the index. The reconcile of that line is one
    /// transaction, so once the sentinel's row exists the decision for every other file the line found is made and committed: a file
    /// of an off kind created beside the sentinel has no row now or never (no clock). False on a timeout or when the helper is gone.
    func sendFoldersAfterSentinel(_ sentinel: String, seed: Int, timeout: TimeInterval = 120) throws -> Bool {
        try atMakePhotos(in: world.photos, names: [sentinel], seedBase: seed, age: 2)
        sendFolders()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if koRowNames(world).contains(sentinel + ".jpg") { return true }
            if !helper.isRunning { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    func stop() { helper.stop() }
}

private struct KoSnap {
    /// Per file name: id, kind, size, mtime_ns, inode, status, reason, read_to and tries as text.
    let files: [String: String]
    /// Per file name: its passage ids.
    let ids: [String: [Int]]
}

private func koSnap(_ world: AtWorld) -> KoSnap? {
    guard let db = world.db(),
          let rows = db.rows("select path, id, kind, size, mtime_ns, inode, status, reason, read_to, tries from files order by id"),
          let ids = atPassageIDs(db) else { return nil }
    var files: [String: String] = [:]
    for row in rows {
        guard let path = row[0] else { continue }
        files[(path as NSString).lastPathComponent] = row.dropFirst().map { $0 ?? "NULL" }.joined(separator: "|")
    }
    return KoSnap(files: files, ids: ids)
}

/// Every row of `before` is in `after` exactly as it was: the same columns and the same passage ids (nothing re-read).
private func koExpectKept(_ before: KoSnap, _ after: KoSnap, _ label: String) {
    #expect(!before.files.isEmpty, "\(label): setup: the snapshot before holds no row")
    for (name, row) in before.files {
        #expect(after.files[name] == row, "\(label): the row of \(name) changed: was \(row), now \(after.files[name] ?? "gone")")
        #expect(after.ids[name] == before.ids[name],
                "\(label): the passages of \(name) changed or were read again: were \(before.ids[name] ?? []), now \(after.ids[name] ?? [])")
    }
}

private func koRowNames(_ world: AtWorld) -> [String] {
    guard let db = world.db(), let rows = mrRows(db) else { return [] }
    return rows.keys.sorted()
}

private func koDescribe(_ world: AtWorld) -> String {
    guard let db = world.db() else { return "no index" }
    return mrDescribe(mrRows(db))
}

// MARK: scenario 1: the kind is off from the first `folders` line

private func koOffFromTheStart(_ kinds: [KoKind]) throws {
    _ = atHelperWarm
    let world = try AtWorld()
    defer { world.remove() }
    let off = kinds.map(\.key)
    try atMakePhotos(in: world.photos, names: ["koharbour"], seedBase: 41, age: 30)
    for (index, kind) in kinds.enumerated() { try koMake(world, kind, tag: "first", n: index, age: 10) }
    try koWriteSettings(world, kindsOn: koKindsOn(off: off))
    let session = try KoSession(world)
    defer { session.stop() }

    // the first line: no row for any file of a kind that is off, a done row for the photo
    session.sendFolders()
    #expect(session.waitFirstWalk(), "the helper never said walked for the first folders line; stderr \(session.helper.errors)")
    for kind in kinds {
        #expect(!koRowNames(world).contains(koName(kind, "first")),
                "\(kind.key) is off and \(koName(kind, "first")) has a row right after the walk: \(koDescribe(world))")
    }
    let first = mrWaitSettled(world, session.helper, expected: 1, stall: 20, cap: 600)
    #expect(first.met && first.rows["koharbour.jpg"]?.status == "done" && first.rows["koharbour.jpg"]?.kind == "photo",
            "the photo should be the one done row; got \(mrDescribe(first.rows)); stderr \(session.helper.errors)")
    #expect(first.rows.count == 1, "with \(off) off the index should hold only the photo: \(mrDescribe(first.rows))")

    // a file created while the kind is off: a second line (with a sentinel photo), still no row for it
    for (index, kind) in kinds.enumerated() { try koMake(world, kind, tag: "second", n: 10 + index, age: 5) }
    #expect(try session.sendFoldersAfterSentinel("kosentinelone", seed: 43), "the sentinel photo of the second folders line never got a row; stderr \(session.helper.errors)")
    for kind in kinds {
        let names = koRowNames(world)
        #expect(!names.contains(koName(kind, "second")), "\(kind.key) is off and a file created meanwhile has a row: \(koDescribe(world))")
        #expect(!names.contains(koName(kind, "first")), "\(kind.key) is off and \(koName(kind, "first")) has a row: \(koDescribe(world))")
    }
    #expect(koRowNames(world) == ["koharbour.jpg", "kosentinelone.jpg"], "rows after the second line: \(koDescribe(world))")
    let photoBefore = koSnap(world)

    // the kind goes on: one folders line reads both files, the photo row keeps its id and its passages
    try koWriteSettings(world, kindsOn: koKindsOn())
    session.sendFolders()
    let after = mrWaitSettled(world, session.helper, expected: 2 + 2 * kinds.count, stall: 20, cap: 900)
    #expect(after.met, "the files were not all read after the switch went on: \(mrDescribe(after.rows)); stderr \(session.helper.errors)")
    for kind in kinds {
        for tag in ["first", "second"] {
            let row = after.rows[koName(kind, tag)]
            #expect(row?.status == "done" && row?.kind == kind.key,
                    "\(koName(kind, tag)) should be done \(kind.key) after the switch went on, got \(row.map { "\($0.kind) \($0.status)" } ?? "no row")")
        }
    }
    if let photoBefore, let now = koSnap(world) {
        koExpectKept(KoSnap(files: photoBefore.files.filter { $0.key == "koharbour.jpg" }, ids: photoBefore.ids.filter { $0.key == "koharbour.jpg" }),
                     now, "the photo")
    }
    #expect(atCleanStop(session.helper) == 0, "the helper did not exit 0 at the end of its stdin")
}

// MARK: scenario 2: indexed while on, then the kind goes off

private func koIndexedThenOff(_ kinds: [KoKind]) throws {
    _ = atHelperWarm
    let world = try AtWorld()
    defer { world.remove() }
    let off = kinds.map(\.key)
    try atMakePhotos(in: world.photos, names: ["koharbour"], seedBase: 51, age: 30)
    for (index, kind) in kinds.enumerated() { try koMake(world, kind, tag: "first", n: index, age: 10) }
    try koWriteSettings(world, kindsOn: koKindsOn())
    let session = try KoSession(world)
    defer { session.stop() }

    // everything is on: the photo and each first file reach done
    session.sendFolders()
    #expect(session.waitFirstWalk(), "the helper never said walked for the first folders line; stderr \(session.helper.errors)")
    let indexed = mrWaitSettled(world, session.helper, expected: 1 + kinds.count, stall: 20, cap: 900)
    #expect(indexed.met && indexed.rows.values.allSatisfy { $0.status == "done" },
            "the first files did not all reach done: \(mrDescribe(indexed.rows)); stderr \(session.helper.errors)")
    let before = try #require(koSnap(world), "setup: the index cannot be read")
    #expect(before.files.count == 1 + kinds.count, "setup: \(before.files.count) rows")
    for kind in kinds { #expect(!(before.ids[koName(kind, "first")] ?? []).isEmpty, "setup: \(koName(kind, "first")) holds no passage") }

    // the switch goes off (the app writes the file and sends nothing), a new file of each kind and a new photo appear, two folders lines
    try koWriteSettings(world, kindsOn: koKindsOn(off: off))
    for (index, kind) in kinds.enumerated() { try koMake(world, kind, tag: "second", n: 10 + index, age: 5) }
    for (line, sentinel) in ["kolatephotoone", "kolatephototwo"].enumerated() {
        #expect(try session.sendFoldersAfterSentinel(sentinel, seed: 61 + line), "the sentinel photo of folders line \(line + 1) never got a row; stderr \(session.helper.errors)")
        for kind in kinds {
            #expect(!koRowNames(world).contains(koName(kind, "second")),
                    "\(kind.key) is off and a file created meanwhile has a row after line \(line + 1): \(koDescribe(world))")
        }
    }
    let whileOff = mrWaitSettled(world, session.helper, expected: 3 + kinds.count, stall: 20, cap: 900)
    #expect(whileOff.met && whileOff.rows["kolatephotoone.jpg"]?.status == "done" && whileOff.rows["kolatephototwo.jpg"]?.status == "done",
            "the photos created while the kind was off should be read and done: \(mrDescribe(whileOff.rows)); stderr \(session.helper.errors)")
    #expect(whileOff.rows.count == 3 + kinds.count, "rows while off: \(mrDescribe(whileOff.rows))")
    if let off1 = koSnap(world) { koExpectKept(before, off1, "while \(off) is off") }

    // the switch goes on: one line reads the new files, every old row keeps its id and its passages
    try koWriteSettings(world, kindsOn: koKindsOn())
    session.sendFolders()
    let back = mrWaitSettled(world, session.helper, expected: 3 + 2 * kinds.count, stall: 20, cap: 900)
    #expect(back.met, "the new files were not all read after the switch went on: \(mrDescribe(back.rows)); stderr \(session.helper.errors)")
    for kind in kinds {
        let row = back.rows[koName(kind, "second")]
        #expect(row?.status == "done" && row?.kind == kind.key,
                "\(koName(kind, "second")) should be done \(kind.key) after the switch went on, got \(row.map { "\($0.kind) \($0.status)" } ?? "no row")")
    }
    if let now = koSnap(world) { koExpectKept(before, now, "after \(off) went on again") }
    #expect(atCleanStop(session.helper) == 0, "the helper did not exit 0 at the end of its stdin")
}

// MARK: scenario 3: a file in the middle of its steps when the kind goes off

private struct KoRow: Equatable {
    var status: String
    var readTo: Int?
    var ids: [Int]
}

private func koRow(_ world: AtWorld, _ name: String) -> KoRow? {
    guard let db = world.db(),
          let row = db.rows("select id, status, read_to from files where path like '%/\(name)'")?.first,
          let idText = row[0], let status = row[1] else { return nil }
    let ids = (db.rows("select id from passages where file_id = \(idText) order by id") ?? []).compactMap { $0[0].flatMap { Int($0) } }
    return KoRow(status: status, readTo: row[2].flatMap { Int($0) }, ids: ids)
}

private func koPartialThenOff(_ kind: KoKind) throws {
    _ = atHelperWarm
    let world = try AtWorld()
    defer { world.remove() }
    let name = koName(kind, "long")
    let path = world.photos.appendingPathComponent(name).path
    try kind.long(path)
    try mrAge(path, 1)
    try koWriteSettings(world, kindsOn: koKindsOn())
    let session = try KoSession(world)
    defer { session.stop() }
    session.sendFolders()

    // wait for the first commit of the file (partial), then switch the kind off at once, with no folders line
    var caught: KoRow?
    let started = Date()
    while Date().timeIntervalSince(started) < 300 {
        if let row = koRow(world, name) {
            if row.status == "partial" { caught = row; break }
            if row.status == "done" || row.status == "could_not_read" { break }
        }
        if !session.helper.isRunning { break }
        Thread.sleep(forTimeInterval: 0.0005)
    }
    guard let first = caught else {
        Issue.record("setup: \(name) never showed as partial (last row \(String(describing: koRow(world, name)))); a \(kind.key) clip made for this test should take several steps; stderr \(session.helper.errors)")
        return
    }
    try koWriteSettings(world, kindsOn: koKindsOn(off: [kind.key]))

    // the step in flight may finish; after that the row must not move for 8 s and must stay partial
    var last = first
    var changedAt = Date()
    let watchStart = Date()
    while Date().timeIntervalSince(watchStart) < 240 {
        guard let row = koRow(world, name) else { break }
        if row != last { last = row; changedAt = Date() }
        if row.status != "partial" { break }
        if Date().timeIntervalSince(changedAt) >= 8 { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    #expect(last.status == "partial",
            "\(kind.key) went off in the middle of \(name) and the file went on to \(last.status): the next step must be skipped and the row stay partial")
    #expect(last.readTo != nil && (last.readTo ?? 0) >= (first.readTo ?? 0) && (last.readTo ?? 0) > 0,
            "read_to is \(String(describing: last.readTo)), it was \(String(describing: first.readTo)) at the first commit")
    #expect(Set(first.ids).isSubset(of: Set(last.ids)), "passages of the first step are gone: \(first.ids) then \(last.ids)")
    guard last.status == "partial" else { return }

    // a folders line while the kind is still off does not resume the file
    #expect(try session.sendFoldersAfterSentinel("kosentinelpartial", seed: 91), "the sentinel photo of the folders line sent while the kind was off never got a row; stderr \(session.helper.errors)")
    Thread.sleep(forTimeInterval: 3)
    #expect(koRow(world, name) == last, "a folders line while \(kind.key) is off read the file again: was \(last), now \(String(describing: koRow(world, name)))")

    // the kind goes on and a folders line comes: the file is read to the end and keeps what it had
    try koWriteSettings(world, kindsOn: koKindsOn())
    session.sendFolders()
    let done = mrWaitSettled(world, session.helper, expected: 2, stall: 90, cap: 900)
    #expect(done.met && done.rows[name]?.status == "done", "the file was not read to the end after the switch went on: \(mrDescribe(done.rows)); stderr \(session.helper.errors)")
    let end = koRow(world, name)
    #expect(Set(last.ids).isSubset(of: Set(end?.ids ?? [])), "the passages already stored were read again: \(last.ids) then \(end?.ids ?? [])")
    #expect((end?.ids.count ?? 0) > last.ids.count, "no passage was added after the switch went on: \(last.ids.count) then \(end?.ids.count ?? 0)")
    #expect(end?.readTo == nil || end?.readTo == 0, "read_to is \(String(describing: end?.readTo)) on the finished file")
    #expect(world.db()?.integrity() == "ok", "integrity_check: \(world.db()?.integrity() ?? "no index")")
    #expect(atCleanStop(session.helper) == 0, "the helper did not exit 0 at the end of its stdin")
}

// MARK: scenario 4: no key, a missing, broken or unreadable settings.json: every kind is on

private func koEverythingOn(_ label: String, prepare: (AtWorld) throws -> Void) throws {
    _ = atHelperWarm
    let world = try AtWorld()
    defer { world.remove() }
    try atMakePhotos(in: world.photos, names: ["koharbour"], seedBase: 71, age: 30)
    try koMake(world, koAudio, tag: "only", n: 0, age: 10)
    try koMake(world, koVideo, tag: "only", n: 1, age: 11)
    try koMake(world, koPdf, tag: "only", n: 2, age: 12)
    try koMake(world, koDoc, tag: "only", n: 3, age: 13)
    try prepare(world)
    let session = try KoSession(world)
    defer { session.stop() }
    session.sendFolders()
    #expect(session.waitFirstWalk(), "\(label): the helper never said walked; stderr \(session.helper.errors)")
    let settled = mrWaitSettled(world, session.helper, expected: 5, stall: 20, cap: 900)
    #expect(settled.met, "\(label): not every file was read: \(mrDescribe(settled.rows)); stderr \(session.helper.errors)")
    let expected = ["koharbour.jpg": "photo", "audio-only.wav": "audio", "video-only.mp4": "video", "pdf-only.pdf": "pdf", "doc-only.txt": "doc"]
    for (name, kind) in expected {
        #expect(settled.rows[name]?.status == "done" && settled.rows[name]?.kind == kind,
                "\(label): \(name) should be done \(kind), got \(settled.rows[name].map { "\($0.kind) \($0.status)" } ?? "no row")")
    }
    #expect(atCleanStop(session.helper) == 0, "\(label): the helper did not exit 0 at the end of its stdin")
}

extension EncodeHelperTests {
@Suite("HelperKindsOffTests", .serialized)
struct HelperKindsOffTests {

    // MARK: off from the first folders line, a new file while off, then on

    @Test func audioOffFromTheFirstFoldersLineLeavesNoAudioRowAPhotoDoneAndAFileCreatedWhileOffHasNoRowUntilItGoesOn() throws {
        try koOffFromTheStart([koAudio])
    }

    @Test func videoOffFromTheFirstFoldersLineLeavesNoVideoRowAPhotoDoneAndAFileCreatedWhileOffHasNoRowUntilItGoesOn() throws {
        try koOffFromTheStart([koVideo])
    }

    @Test func audioAndVideoBothOffLeaveNoRowForEitherAndBothAreReadWhenTheyGoOn() throws {
        try koOffFromTheStart([koAudio, koVideo])
    }

    @Test func pdfsOffFromTheFirstFoldersLineLeavesNoPdfRowAndAPdfCreatedWhileOffHasNoRowUntilItGoesOn() throws {
        try koOffFromTheStart([koPdf])
    }

    @Test func documentsOffFromTheFirstFoldersLineLeavesNoDocumentRowAndADocumentCreatedWhileOffHasNoRowUntilItGoesOn() throws {
        try koOffFromTheStart([koDoc])
    }

    // MARK: rows already in the index stay unchanged when the kind goes off

    @Test func audioRowsAlreadyIndexedStayUnchangedThroughFurtherFoldersLinesAndANewAudioFileWhileOffHasNoRowUntilItGoesOn() throws {
        try koIndexedThenOff([koAudio])
    }

    @Test func videoRowsAlreadyIndexedStayUnchangedThroughFurtherFoldersLinesAndANewVideoFileWhileOffHasNoRowUntilItGoesOn() throws {
        try koIndexedThenOff([koVideo])
    }

    @Test func audioAndVideoBothOffKeepTheirIndexedRowsUnchangedAndReadNothingNew() throws {
        try koIndexedThenOff([koAudio, koVideo])
    }

    @Test func pdfRowsAlreadyIndexedStayUnchangedThroughFurtherFoldersLinesAndANewPdfWhileOffHasNoRowUntilItGoesOn() throws {
        try koIndexedThenOff([koPdf])
    }

    @Test func documentRowsAlreadyIndexedStayUnchangedThroughFurtherFoldersLinesAndANewDocumentWhileOffHasNoRowUntilItGoesOn() throws {
        try koIndexedThenOff([koDoc])
    }

    // MARK: a file partial when its kind goes off is not read further, and is read to the end when it goes on

    @Test func anAudioFilePartialWhenAudioGoesOffIsNotReadFurtherAndIsReadToTheEndWhenAudioGoesOn() throws {
        try koPartialThenOff(koAudio)
    }

    @Test func aVideoFilePartialWhenVideoGoesOffIsNotReadFurtherAndIsReadToTheEndWhenVideoGoesOn() throws {
        try koPartialThenOff(koVideo)
    }

    @Test func aPdfPartialWhenPdfsGoOffIsNotReadFurtherAndIsReadToTheEndWhenPdfsGoOn() throws {
        try koPartialThenOff(koPdf)
    }

    @Test func aDocumentPartialWhenDocumentsGoOffIsNotReadFurtherAndIsReadToTheEndWhenDocumentsGoOn() throws {
        try koPartialThenOff(koDoc)
    }

    // MARK: no key, a missing, broken or unreadable settings.json: every kind is on (guards: they hold before the change too)

    @Test func aKindWithNoKeyInSettingsJsonIsOnWhileThePhotoKeyAloneIsStored() throws {
        try koEverythingOn("only the photo key") { world in
            try koWriteSettings(world, kindsOn: ["photo": true])
        }
    }

    @Test func anEmptyKindsOnMapMeansEveryKindIsOn() throws {
        try koEverythingOn("empty kindsOn") { world in
            try koWriteSettings(world, kindsOn: [:])
        }
    }

    @Test func aMissingSettingsJsonMeansEveryKindIsOn() throws {
        try koEverythingOn("no settings.json") { world in
            #expect(!FileManager.default.fileExists(atPath: koSettingsURL(world).path), "setup: settings.json exists")
        }
    }

    @Test func aSettingsJsonThatCannotBeParsedMeansEveryKindIsOn() throws {
        try koEverythingOn("a cut settings.json") { world in
            try koWriteRaw(world, "{\"version\": 3, \"startPressed\": true, \"kindsOn\": {\"audio\": fal")
        }
    }

    @Test func aSettingsJsonThatCannotBeReadMeansEveryKindIsOn() throws {
        guard mrCanTestPermissions() else { return }
        try koEverythingOn("an unreadable settings.json") { world in
            try koWriteSettings(world, kindsOn: koKindsOn(off: ["audio", "video", "pdf", "doc"]))
            world.lock(koSettingsURL(world))
        }
    }
}
}
