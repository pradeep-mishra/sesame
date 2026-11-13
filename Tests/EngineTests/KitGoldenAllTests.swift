import Foundation
import Testing

// plan-5-t1, tester step, part E: golden group d (audio and video) in the kit. Written from the entry plan-5-t1 of plan-5-tasks.md,
// the spec (S2(d)), verify.md, the feature map S4 and kit-golden.sh and golden.sh as plan 4 left them; no product source is read.
//
// What runs: `bash -n`, the usage lines, usage errors, text checks of the new prepare mode, pure runs of `index-state --all` on a
// hand-made tree and index, and pure runs of `engine|panel --group d --from <file>` on hand-written lines. Nothing starts the helper,
// the app, the panel or a nested `swift test`; the real `prepare --all` and `GroupDTests` are run by the accept stage.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `kit-golden.sh prepare [--all]` and `index-state [--all]`; `--all` is the whole index of golden/photos, golden-docs and golden-av,
//     with its own marker `run/golden-index-all`. `index-state --all` prints `INDEX GOLDEN ALL DONE: yes|no ...` (every file with a
//     reader under the three folders is as the key says: done, and the damaged clips of golden-av/damaged, the locked and the damaged
//     pdf could_not_read) and `INDEX GOLDEN ALL ONLY: yes|no ...` (no file outside the three folders); exit 0 only when both are yes.
//   - `engine|panel --group d --from <file>` (test-only, as for group c) reads `GOLDEN <id> rank <n|none> second <s|none>` lines, the
//     videospeech row's own line, and `GOLDEN v12 above <no|yes>`. The row line is `PASS|FAIL <id> query="<q>" expected=<file>
//     rank=<n|none> second=<s|none>[: <why>]` (PASS when the file is in the first 3 and the second is inside the true moment) and
//     the summary line is exactly the one of the entry. A row with no line is rank none; a missing v12 line is `FAIL no v12 line`.
//   - golden.sh: `golden_built d`, `golden_rows d` (the 8 audio and 8 video rows of the key, not the videospeech row).

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let goldenScript = projectRoot.appendingPathComponent("scripts/kit-golden.sh").path
private let goldenLib = projectRoot.appendingPathComponent("scripts/kit-lib/golden.sh").path

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("kitall-out-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    defer { try? fm.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    try? handle.synchronize()
    return Ran(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

private struct Rig {
    let base: String
    var kit: String { base + "/sesame-kit-all" }
    var tmp: String { base + "/tmp" }
    var decoyHome: String { base + "/decoy-home" }
    var fixtures: String { kit + "/fixtures" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
    var indexDir: String { kit + "/home/Library/Application Support/Sesame" }
    var db: String { indexDir + "/index.sqlite" }
    func remove() { try? FileManager.default.removeItem(atPath: base) }
}

private func makeRig() throws -> Rig {
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-all-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let rig = Rig(base: made.resolvingSymlinksInPath().path)
    for dir in [rig.kit + "/run", rig.tmp, rig.decoyHome] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    return rig
}

private func golden(_ rig: Rig, _ args: [String]) throws -> Ran { try run("/bin/bash", [goldenScript] + args, env: rig.env) }

private func touch(_ path: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data("x".utf8))
}

private func sqlite(_ db: String, _ sql: String) throws {
    let r = try run("/usr/bin/sqlite3", [db, sql], limit: 30)
    #expect(r.status == 0, "sqlite3 failed: \(r.output)")
}

private func readText(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

private func put(_ text: String, _ path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

private func functionText(_ script: String, _ name: String) -> String {
    var out: [String] = []
    var inside = false
    for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
        if !inside, line.hasPrefix(name + "() {") { inside = true }
        if inside {
            out.append(String(line))
            if line == "}" { break }
        }
    }
    return out.joined(separator: "\n")
}

// MARK: the hand-made tree of the whole index (photos, documents, pdfs, audio, video)

private typealias Row = (path: String, kind: String, status: String)

private let allFiles: [Row] = [
    ("golden/photos/p0.jpg", "photo", "done"), ("golden/photos/p1.png", "photo", "done"),
    ("golden-docs/pdfs/lease-2024.pdf", "pdf", "done"),
    ("golden-docs/pdfs/locked-contract.pdf", "pdf", "could_not_read"), ("golden-docs/pdfs/damaged-report.pdf", "pdf", "could_not_read"),
    ("golden-docs/docs/field-notes.txt", "doc", "done"),
    ("golden-av/audio/sleep-interview.m4a", "audio", "done"), ("golden-av/audio/quiet-room.wav", "audio", "done"),
    ("golden-av/video/safari-zebra.mp4", "video", "done"), ("golden-av/video/clip-v12.mp4", "video", "done"),
    ("golden-av/damaged/broken.m4a", "audio", "could_not_read"), ("golden-av/damaged/broken.mp4", "video", "could_not_read"),
]

private func makeTree(_ rig: Rig) throws {
    for f in allFiles { try touch(rig.fixtures + "/" + f.path) }
    try touch(rig.fixtures + "/golden-av/audio/notes.pages")   // no reader
    try touch(rig.fixtures + "/boundary/one-page.pdf")         // another root
}

private func makeIndex(_ rig: Rig, rows: [Row]) throws {
    try FileManager.default.createDirectory(atPath: rig.indexDir, withIntermediateDirectories: true)
    try sqlite(rig.db, "create table files(path text primary key, kind text, status text, reason text); create table passages(id integer primary key, file text);")
    guard !rows.isEmpty else { return }
    let values = rows.map { "('\(rig.fixtures)/\($0.path)','\($0.kind)','\($0.status)',NULL)" }.joined(separator: ",")
    try sqlite(rig.db, "insert into files values \(values);")
}

private func rows(_ change: (inout [Row]) -> Void) -> [Row] {
    var out = allFiles
    change(&out)
    return out
}

// MARK: group d lines, written by hand from the key (the second each moment starts at and the window)

private let audioRows: [(id: String, query: String, file: String, second: Int)] = [
    ("audio-01", "where they talk about sleep", "audio/sleep-interview.m4a", 130), ("audio-02", "where they explain how to make pancakes", "audio/memo-0417.mp3", 70),
    ("audio-03", "where they discuss when the bridge opens", "audio/standup-notes.flac", 20), ("audio-04", "where someone talks about a dentist appointment", "audio/call-recording-b.aac", 55),
    ("audio-05", "where they describe a volcano eruption", "audio/lecture-04.m4a", 100), ("audio-06", "where they talk about a marathon race", "audio/field-recording.mp3", 30),
    ("audio-07", "where they remind someone to water the garden", "audio/voice-note-17.wav", 85), ("audio-08", "where the council decides about a library", "audio/town-hall.flac", 45),
]
private let videoRows: [(id: String, query: String, file: String, second: Int)] = [
    ("video-01", "zebra in a video", "video/safari-zebra.mp4", 42), ("video-02", "a whale swimming in the ocean", "video/ocean-trip.mov", 20),
    ("video-03", "a helicopter flying over a city", "video/aerial-shoot.mp4", 35), ("video-04", "a surfer riding a wave", "video/weekend-0412.m4v", 15),
    ("video-05", "a flamingo standing in water", "video/wetland-walk.mov", 50), ("video-06", "a ferris wheel at an amusement park", "video/fair-day.mp4", 25),
    ("video-07", "a butterfly on a flower", "video/garden-clip.m4v", 40), ("video-08", "a tractor in a field", "video/farm-visit.mp4", 10),
]

/// The readings of a good run: every row first, every moment at its row's second, the videospeech row second, v12 not above.
private func goodLines() -> [String] {
    var lines: [String] = []
    for r in audioRows + videoRows { lines.append("GOLDEN \(r.id) rank 1 second \(r.second)") }
    lines.append("GOLDEN videospeech-01 rank 2 second 20")
    lines.append("GOLDEN v12 above no")
    return lines
}

private func withChange(_ id: String, _ line: String) -> [String] {
    goodLines().map { $0.hasPrefix("GOLDEN \(id) ") ? line : $0 }
}

private func runD(_ rig: Rig, _ mode: String, _ lines: [String]) throws -> Ran {
    try put(lines.joined(separator: "\n") + "\n", rig.base + "/readings.txt")
    return try golden(rig, [mode, "--group", "d", "--from", rig.base + "/readings.txt"])
}

private let goodSummary = "audio first-3 8 of 8, moment right 8 of 8; video first-3 8 of 8, moment right 8 of 8; videospeech first-3 yes, v12 above no: PASS"

// MARK: the suite

@Suite("KitGoldenAllTests")
struct KitGoldenAllTests {

    @Test("bash -n on kit-golden.sh and golden.sh; the usage names prepare [--all], index-state [--all] and group a|b|c|d")
    func syntaxAndUsage() throws {
        for path in [goldenScript, goldenLib] {
            let r = try run("/bin/bash", ["-n", path])
            #expect(r.status == 0, "bash -n \(path): \(r.output)")
        }
        let rig = try makeRig()
        defer { rig.remove() }
        let r = try golden(rig, ["no-such-mode"])
        #expect(r.status == 2, "exit \(r.status)")
        for word in ["kit-golden.sh prepare [--all]", "kit-golden.sh index-state [--all]", "--group a|b|c|d"] {
            #expect(r.output.contains(word), "usage lacks `\(word)`:\n\(r.output)")
        }
    }

    @Test("prepare and index-state take --whole or --all and nothing else; both together is a usage error (exit 2)")
    func usageErrors() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        for args in [["prepare", "--nope"], ["prepare", "--all", "--whole"], ["prepare", "--all", "extra"], ["index-state", "--all", "--whole"], ["index-state", "--all", "x"]] {
            let r = try golden(rig, args)
            #expect(r.status == 2, "\(args): expected exit 2, got \(r.status):\n\(r.output)")
        }
    }

    @Test("prepare --all has its own marker, indexes the three folders in one helper call and builds golden-av; golden_indexed_all gates panel --group d; prepare and prepare --whole stay as they were")
    func textChecks() {
        let text = readText(goldenScript)
        #expect(text.range(of: #"GOLDEN_MARK_ALL="\$KIT_ROOT/run/golden-index-all""#, options: .regularExpression) != nil, "GOLDEN_MARK_ALL is not \"$KIT_ROOT/run/golden-index-all\"")
        let all = functionText(text, "prepare_all_run")
        #expect(!all.isEmpty, "prepare_all_run is not defined")
        #expect(all.contains("--folders golden/photos golden-docs golden-av"), "prepare --all does not index the three folders in one helper call")
        #expect(all.contains("build golden-av") && all.contains("build golden-docs") && all.contains("build golden"), "prepare --all does not build all three folders")
        #expect(all.contains("GOLDEN_MARK_ALL") && all.contains("golden_indexed_all"), "prepare --all lacks its marker or golden_indexed_all")
        #expect(!all.contains("GOLDEN_MARK_WHOLE") && !all.contains("GOLDEN_MARK\""), "prepare --all writes another prepare's marker")
        #expect(functionText(text, "prepare_run").contains("--folders golden/photos") && !functionText(text, "prepare_run").contains("golden-av"), "the photo-scoped prepare changed")
        #expect(functionText(text, "prepare_whole_run").contains("--folders golden/photos golden-docs") && !functionText(text, "prepare_whole_run").contains("golden-av"), "prepare --whole changed")
        #expect(functionText(text, "panel_group_d").contains("golden_indexed_all"), "panel --group d does not stop on a missing whole index (golden_indexed_all)")
        #expect(functionText(text, "engine_group_d").contains("GroupDTests"), "engine --group d does not run GroupDTests")
        #expect(functionText(text, "engine_group_d").contains("build golden-av"), "engine --group d does not build golden-av first")
    }

    @Test("golden_built d, and golden_rows d is the 8 audio and 8 video rows of the key (the videospeech row is not one of them)")
    func goldenRows() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        let script = """
            . "$1/scripts/kit-lib/common.sh" || exit 90
            . "$1/scripts/kit-lib/golden.sh" || exit 91
            golden_built d && echo built-d
            golden_rows d
            """
        let r = try run("/bin/bash", ["-c", script, "bash", projectRoot.path], env: rig.env, limit: 60)
        #expect(r.status == 0 && r.lines.first == "built-d", "exit \(r.status): \(r.output)")
        let want = (audioRows + videoRows).map { "\($0.id)\t\($0.query)\t\($0.file)" }
        let got = r.lines.dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).prefix(3).joined(separator: "\t") }
        #expect(Array(got) == want, "golden_rows d gave\n\(got.joined(separator: "\n"))\nexpected\n\(want.joined(separator: "\n"))")
    }

    @Test("read-kinds.txt lists photo, document, pdf, audio and video and no code, so the whole index expects the media files")
    func readKinds() {
        #expect(readText(projectRoot.appendingPathComponent("scripts/kit-lib/read-kinds.txt").path) == "photo\ndocument\npdf\naudio\nvideo\n")
    }

    // MARK: index-state --all on a hand-made tree

    @Test("index-state --all: DONE is yes only when every file with a reader is done as the key says (the damaged clips could_not_read), ONLY is yes only when nothing else is indexed; exit 0 only when both are yes")
    func indexStateAll() throws {
        // (label, rows, DONE, ONLY)
        let cases: [(String, [Row]?, String, String)] = [
            ("a finished index", rows { _ in }, "yes", "yes"),
            ("a boundary file also indexed", rows { $0.append(("boundary/one-page.pdf", "pdf", "done")) }, "yes", "no"),
            ("an audio clip partial", rows { $0[6].status = "partial" }, "no", "yes"),
            ("a video pending", rows { $0[8].status = "pending" }, "no", "yes"),
            ("a readable video that could not be read", rows { $0[9].status = "could_not_read" }, "no", "yes"),
            ("the damaged audio clip done (it must be could_not_read)", rows { $0[10].status = "done" }, "no", "yes"),
            ("the damaged video clip done (it must be could_not_read)", rows { $0[11].status = "done" }, "no", "yes"),
            ("the damaged video clip missing", rows { $0.remove(at: 11) }, "no", "no"),
            ("the silent clip missing from the index", rows { $0.remove(at: 7) }, "no", "no"),
            ("the locked pdf done", rows { $0[3].status = "done" }, "no", "yes"),
            ("no index at all", nil, "no", "no"),
        ]
        for (label, indexRows, done, only) in cases {
            let rig = try makeRig()
            defer { rig.remove() }
            try makeTree(rig)
            if let indexRows { try makeIndex(rig, rows: indexRows) }
            let r = try golden(rig, ["index-state", "--all"])
            let doneLine = r.lines.first { $0.hasPrefix("INDEX GOLDEN ALL DONE:") } ?? "(no DONE line)"
            let onlyLine = r.lines.first { $0.hasPrefix("INDEX GOLDEN ALL ONLY:") } ?? "(no ONLY line)"
            #expect(doneLine.hasPrefix("INDEX GOLDEN ALL DONE: \(done)"), "\(label): \(doneLine)\n\(r.output)")
            #expect(onlyLine.hasPrefix("INDEX GOLDEN ALL ONLY: \(only)"), "\(label): \(onlyLine)\n\(r.output)")
            let both = done == "yes" && only == "yes"
            #expect(r.status == (both ? 0 : 1), "\(label): exit \(r.status), expected \(both ? 0 : 1)\n\(r.output)")
        }
    }

    @Test("the other prepares still re-make an index that holds the media: the whole one says ONLY no, the photo-scoped one says no")
    func otherPreparesRemake() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        try makeTree(rig)
        try makeIndex(rig, rows: allFiles)
        let whole = try golden(rig, ["index-state", "--whole"])
        #expect(whole.status == 1 && whole.lines.contains { $0.hasPrefix("INDEX GOLDEN WHOLE ONLY: no") }, "--whole:\n\(whole.output)")
        let photos = try golden(rig, ["index-state"])
        #expect(photos.status == 1 && photos.lines.contains { $0.hasPrefix("INDEX GOLDEN PHOTOS ONLY: no") }, "photos:\n\(photos.output)")
    }

    // MARK: group d on hand-written lines

    @Test("group d on good readings: every row PASS and the summary line is exactly the entry's, for engine and for panel")
    func goodRun() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        for mode in ["engine", "panel"] {
            let r = try runD(rig, mode, goodLines())
            #expect(r.status == 0, "\(mode): exit \(r.status):\n\(r.output)")
            #expect(r.lines.contains("GOLDEN \(mode) group d: \(goodSummary)"), "\(mode): no summary line:\n\(r.output)")
            for row in audioRows + videoRows {
                #expect(r.lines.contains { $0.hasPrefix("PASS \(row.id) query=\"\(row.query)\" expected=\(row.file) rank=1 second=\(row.second)") }, "\(mode): no PASS line for \(row.id):\n\(r.output)")
            }
            #expect(r.lines.contains("GOLDEN v12 above no") == false, "the kit must not echo the test's own line as a result")
            #expect(r.lines.contains { $0.hasPrefix("odd first ") && $0.contains(", even first ") }, "\(mode): no odd and even line:\n\(r.output)")
        }
    }

    @Test("group d bars: 7 of 8 are enough for the file in the first 3 and for the moment right; 6 are not; the videospeech row and the v12 control each decide alone")
    func bars() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        func verdict(_ lines: [String]) throws -> (Int32, String) {
            let r = try runD(rig, "panel", lines)
            return (r.status, r.lines.first { $0.hasPrefix("GOLDEN panel group d:") } ?? "(no summary)\n\(r.output)")
        }
        // one audio row at rank 4: 7 of 8 first-3, still 7 of 8 moment right when its second is right
        let one = try verdict(withChange("audio-02", "GOLDEN audio-02 rank 4 second 70"))
        #expect(one.0 == 0 && one.1.contains("audio first-3 7 of 8, moment right 8 of 8"), "one miss: exit \(one.0) \(one.1)")
        // two audio rows at rank 4 or none: 6 of 8, FAIL
        var two = withChange("audio-02", "GOLDEN audio-02 rank 4 second 70")
        two = two.map { $0.hasPrefix("GOLDEN audio-03 ") ? "GOLDEN audio-03 rank none second none" : $0 }
        let twoResult = try verdict(two)
        #expect(twoResult.0 == 1 && twoResult.1.contains("audio first-3 6 of 8") && twoResult.1.hasSuffix(": FAIL"), "two misses: \(twoResult)")
        // the moment: inside [start, start + 30] for audio, inclusive; one outside is still 7, two are 6
        let edge = try verdict(withChange("audio-01", "GOLDEN audio-01 rank 1 second 160"))
        #expect(edge.0 == 0 && edge.1.contains("audio first-3 8 of 8, moment right 8 of 8"), "second at the end of the window (160): \(edge)")
        let late = try verdict(withChange("audio-01", "GOLDEN audio-01 rank 1 second 161"))
        #expect(late.0 == 0 && late.1.contains("moment right 7 of 8"), "second 161 (outside): \(late)")
        let early = try verdict(withChange("video-01", "GOLDEN video-01 rank 1 second 41"))
        #expect(early.0 == 0 && early.1.contains("video first-3 8 of 8, moment right 7 of 8"), "second 41 for a video at 42: \(early)")
        let videoEdge = try verdict(withChange("video-01", "GOLDEN video-01 rank 1 second 52"))
        #expect(videoEdge.0 == 0 && videoEdge.1.contains("video first-3 8 of 8, moment right 8 of 8"), "second 52 for a video at 42 (the end of its 10 s): \(videoEdge)")
        var twoMoments = withChange("video-01", "GOLDEN video-01 rank 1 second 53")
        twoMoments = twoMoments.map { $0.hasPrefix("GOLDEN video-02 ") ? "GOLDEN video-02 rank 1 second 5" : $0 }
        let tm = try verdict(twoMoments)
        #expect(tm.0 == 1 && tm.1.contains("video first-3 8 of 8, moment right 6 of 8") && tm.1.hasSuffix(": FAIL"), "two wrong video moments: \(tm)")
        // videospeech and v12
        let outOfThree = try verdict(withChange("videospeech-01", "GOLDEN videospeech-01 rank 4 second 20"))
        #expect(outOfThree.0 == 1 && outOfThree.1.contains("videospeech first-3 no, v12 above no: FAIL"), "videospeech out of the first 3: \(outOfThree)")
        let v12 = try verdict(goodLines().map { $0 == "GOLDEN v12 above no" ? "GOLDEN v12 above yes" : $0 })
        #expect(v12.0 == 1 && v12.1.contains("videospeech first-3 yes, v12 above yes: FAIL"), "v12 above: \(v12)")
    }

    @Test("group d: a missing v12 line is `FAIL no v12 line`; a row with no line is rank none; the lines of a later reading replace an earlier one")
    func missingLines() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        let noV12 = try runD(rig, "engine", goodLines().filter { !$0.hasPrefix("GOLDEN v12") })
        #expect(noV12.status == 1, "exit \(noV12.status):\n\(noV12.output)")
        #expect(noV12.lines.contains { $0.contains("FAIL no v12 line") }, "no `FAIL no v12 line`:\n\(noV12.output)")
        let noRow = try runD(rig, "engine", goodLines().filter { !$0.hasPrefix("GOLDEN audio-08 ") })
        #expect(noRow.lines.contains { $0.hasPrefix("FAIL audio-08 ") && $0.contains("rank=none") }, "a row with no line:\n\(noRow.output)")
        #expect(noRow.lines.contains { $0.contains("audio first-3 7 of 8, moment right 7 of 8") }, "a row with no line counts as a miss:\n\(noRow.output)")
        let later = try runD(rig, "engine", ["GOLDEN audio-01 rank 9 second none"] + goodLines())
        #expect(later.lines.contains { $0.contains(goodSummary) }, "the last line of a row counts:\n\(later.output)")
    }

    @Test("--from is for groups c and d only: groups a, b and e are a usage error (exit 2), and a group e never runs or reads a line")
    func fromAndGroups() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        try put("GOLDEN audio-01 rank 1 second 130\n", rig.base + "/r.txt")
        for g in ["a", "b", "e"] {
            let r = try golden(rig, ["engine", "--group", g, "--from", rig.base + "/r.txt"])
            #expect(r.status == 2, "--from with group \(g): exit \(r.status):\n\(r.output)")
            #expect(!r.output.contains("group e:") && !r.output.contains("not built yet"), "group \(g) with --from ran or read a line:\n\(r.output)")
        }
        for mode in ["engine", "panel"] {
            let r = try golden(rig, [mode, "--group", "e"])
            #expect(r.status == 2 && r.output.contains("usage: kit-golden.sh"), "\(mode) --group e: exit \(r.status):\n\(r.output)")
        }
    }

    @Test("a run of group c or d saves its GOLDEN lines under run/golden-lines-<mode>-<group>.txt and a later run replaces them; the engine and panel paths of groups a and b call the saver")
    func savedLinesOfCAndD() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        try put("GOLDEN pdf-01 rank 1 page 7\n", rig.base + "/c.txt")
        _ = try golden(rig, ["engine", "--group", "c", "--from", rig.base + "/c.txt"])
        #expect(readText(rig.kit + "/run/golden-lines-engine-c.txt") == "GOLDEN pdf-01 rank 1 page 7\n", "group c saved: \(readText(rig.kit + "/run/golden-lines-engine-c.txt"))")
        try put("GOLDEN pdf-01 rank 4 page 9\n", rig.base + "/c2.txt")
        _ = try golden(rig, ["engine", "--group", "c", "--from", rig.base + "/c2.txt"])
        #expect(readText(rig.kit + "/run/golden-lines-engine-c.txt") == "GOLDEN pdf-01 rank 4 page 9\n", "a later group c run did not replace the file")
        try put("GOLDEN audio-01 rank 1 second 130\nGOLDEN v12 above no\n", rig.base + "/d.txt")
        _ = try golden(rig, ["panel", "--group", "d", "--from", rig.base + "/d.txt"])
        #expect(readText(rig.kit + "/run/golden-lines-panel-d.txt") == "GOLDEN audio-01 rank 1 second 130\nGOLDEN v12 above no\n", "group d saved: \(readText(rig.kit + "/run/golden-lines-panel-d.txt"))")
        #expect(readText(rig.kit + "/run/golden-lines-engine-c.txt") == "GOLDEN pdf-01 rank 4 page 9\n", "the panel run of group d touched group c's file")
        let text = readText(goldenScript)
        for fn in ["engine_group", "panel_group"] {
            #expect(functionText(text, fn).contains("golden_save_lines"), "\(fn) (groups a and b) does not call golden_save_lines")
        }
    }

    @Test("the odd and even rows are scored apart, and golden-panel.tsv gets the group d rows (group c's rows are kept)")
    func oddEvenAndTsv() throws {
        let rig = try makeRig()
        defer { rig.remove() }
        // odd rows (audio-01, 03, 05, 07 and video-01, 03, 05, 07) rank 1, even rows rank 3: odd first 8 of 8, even first 0 of 8
        var lines = goodLines()
        for r in audioRows + videoRows {
            let n = Int(r.id.suffix(2)) ?? 0
            if n % 2 == 0 { lines = lines.map { $0.hasPrefix("GOLDEN \(r.id) ") ? "GOLDEN \(r.id) rank 3 second \(r.second)" : $0 } }
        }
        let r = try runD(rig, "panel", lines)
        #expect(r.lines.contains("odd first 8 of 8, even first 0 of 8"), "odd/even line:\n\(r.output)")
        #expect(r.lines.contains("noted: overfitting risk"), "no overfitting note when even rows are 2 or more behind:\n\(r.output)")
        let tsv = readText(rig.kit + "/run/golden-panel.tsv")
        #expect(tsv.split(separator: "\n").filter { $0.split(separator: "\t").count > 1 && $0.split(separator: "\t")[1] == "d" }.count >= 16, "golden-panel.tsv holds no group d rows:\n\(tsv)")
    }
}
