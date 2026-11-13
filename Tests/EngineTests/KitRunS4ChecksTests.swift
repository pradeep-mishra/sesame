import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// plan-5-t1b, tester step, part F: the checks S4.1 to S4.10, S2.5 and S8.8 (a new scripts/kit-lib/checks-s4.sh), the recipes `mix500` and
// `pauselong <unit>`, the four-root recipe `golden`, `kit-readback.sh frame-check` (the picture compare of S4.4), the S7.2 extension for
// the three long units, S6.11 on mix500, S2.11 on top of the 50,000-row index, checks.tsv, checks.floor, slice 5 and the verify.sh --quick
// guard. Written from the entry plan-5-t1 (part F) of plan-5-tasks.md, verify.md, the feature maps S2, S4, S6, S7 and S8 and the kit as it
// stands; no product source is read, and no kit function may read it.
//
// Static proof only (plan-5-tasks.md, Conventions: no app launch in any task): a check needs the app, the panel, QuickTime Player, the
// model, the speech daemon and an administrator session, so NOTHING here runs a check, a recipe, `kit-run.sh`, `verify.sh`,
// `kit-golden.sh engine|panel` or any script that starts or drives an app. What runs: `bash -n`, the pure helpers of recipes.sh and
// checks-s4.sh sourced in a child bash on hand-written keys, tables, panes and outputs (the expected values are written in this file, never
// read from the kit), the text of the check files with their comment lines removed (a comment never satisfies a test), and
// `kit-readback.sh frame-check` on pictures this test draws (with ffmpeg making the clip and its frames: the test's own, independent
// reader of the frames).
//
// Picks of the tester that the entry did not fix (listed in the report):
//   - the pause units are `pdf`, `audio` and `video`; `kit-fixtures.sh build pauselong` also makes pdf/annual-report-60p.pdf (the 60-page
//     PDF of golden-docs, built by the same table) so that each unit has a folder of its own; `prep pauselong <unit>` picks pauselong/<unit>
//     and presses Start indexing;
//   - `kit-readback.sh frame-check <pane-shot> <video> <second>` compares the pane picture with the video's frame at <second> and at
//     <second> - 20 (the first frame when under 20), prints `frame now <score>` and `frame earlier <score>`, exit 0 when the first is at
//     least 0.55 and higher than the second, 1 when not, 4 when the shot is not a picture, writes compare-s4-frame.txt;
//   - the media app choice of Settings is named IINA and VLC; the ten selections of S4.8 and S8.8 are the eight audio rows and then the
//     first two again; the S4.9 reason of a damaged clip is `damaged`; S3.8 counts golden-av as its fourth root.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")
private let checkFile = libDir.appendingPathComponent("checks-s4.sh")
private let recipesFile = libDir.appendingPathComponent("recipes.sh")
private let readbackScript = scriptsDir.appendingPathComponent("kit-readback.sh").path

private let s4Ids = ["S4.1", "S4.2", "S4.3", "S4.4", "S4.5", "S4.6", "S4.7", "S4.8", "S4.9", "S4.10"]
private let allIds = s4Ids + ["S2.5", "S8.8"]
private let personIds: Set<String> = ["S4.2", "S4.5", "S4.7", "S4.8", "S8.8"]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun4-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
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

private func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func firstIndex(_ text: String, _ pattern: String) -> Int? {
    guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
    return text.distance(from: text.startIndex, to: r.lowerBound)
}

private func groups(_ text: String, _ pattern: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (1..<max(m.numberOfRanges, 1)).map { i in
            m.range(at: i).location != NSNotFound ? ns.substring(with: m.range(at: i)) : ""
        }
    }
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func stripComments(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private func shellFunctions(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if let n = groups(line, "^([A-Za-z_][A-Za-z0-9_]*)\\(\\) \\{( #.*)?$").first?.first {
                name = n
                body = []
            } else if let g = groups(line, "^([A-Za-z_][A-Za-z0-9_]*)\\(\\) \\{ (.*) \\}$").first, g.count == 2 {
                result[g[0]] = g[1]
            }
        } else if line == "}" {
            result[name!] = body.joined(separator: "\n")
            name = nil
        } else {
            body.append(line)
        }
    }
    return result
}

private func kitShellSources() -> [(name: String, code: String)] {
    var all: [(String, String)] = []
    if let text = read(scriptsDir.appendingPathComponent("kit-run.sh")) { all.append(("kit-run.sh", stripComments(text))) }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: libDir.path)) ?? []).filter { $0.hasSuffix(".sh") }.sorted()
    for name in names {
        if let text = read(libDir.appendingPathComponent(name)) { all.append(("kit-lib/" + name, stripComments(text))) }
    }
    return all
}

private func allFunctions() -> [String: String] {
    var merged: [String: String] = [:]
    for (_, code) in kitShellSources() {
        for (k, v) in shellFunctions(in: code) where merged[k] == nil { merged[k] = v }
    }
    return merged
}

private func topLevelValues() -> [String: String] {
    var values: [String: String] = [:]
    for (_, code) in kitShellSources() {
        for line in code.split(separator: "\n").map(String.init) {
            if let g = groups(line, "^([A-Z][A-Z0-9_]*)=\"([^\"]*)\"").first, g.count == 2, !g[1].contains("$("), !g[1].contains("`") {
                values[g[0]] = g[1]
            }
        }
    }
    return values
}

private func substitute(_ text: String, _ values: [String: String]) -> String {
    var result = text
    for _ in 0..<2 {
        for (name, value) in values where result.contains("$" + name) || result.contains("${" + name + "}") {
            let esc = NSRegularExpression.escapedPattern(for: name)
            guard let re = try? NSRegularExpression(pattern: "\\$\\{\(esc)\\}|\\$\(esc)(?![A-Za-z0-9_])") else { continue }
            result = re.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: NSRegularExpression.escapedTemplate(for: value))
        }
    }
    return result
}

private func checkFunctionName(_ id: String) -> String { "check_" + id.replacingOccurrences(of: ".", with: "_") }

/// The function that holds a check's logic: `s4_check_<n>` (S4.n), `s4_check_s2_5`, `s4_check_s8_8`.
private func logicName(_ id: String) -> String {
    switch id {
    case "S2.5": return "s4_check_s2_5"
    case "S8.8": return "s4_check_s8_8"
    default: return "s4_check_" + String(id.dropFirst(3))
    }
}

/// The logic of a check with the driving helpers it calls written in (the pure readers stay calls). Records and returns nil when missing.
private func logic(_ id: String) -> String? {
    let all = allFunctions()
    guard let text = all[logicName(id)] else {
        Issue.record(Comment(rawValue: "\(logicName(id)) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    var full = text
    for helper in ["s4_row", "s4_open_pane", "s4_quicktime_open", "s4_speech_run", "s4_pick_media_app", "s4_switch", "s4_media_open"] where text.contains(helper) {
        if let h = all[helper] { full += "\n" + h }
    }
    return substitute(full, topLevelValues())
}

private func before(_ text: String, _ a: String, _ b: String, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let ia = firstIndex(text, a), let ib = firstIndex(text, b) else {
        ok(false, "\(message) (missing: \(firstIndex(text, a) == nil ? a : b))", sourceLocation: sourceLocation)
        return
    }
    ok(ia < ib, message, sourceLocation: sourceLocation)
}

private func tsvRows() -> [(id: String, slice: String, kind: String)]? {
    guard let text = read(libDir.appendingPathComponent("checks.tsv")) else {
        Issue.record("scripts/kit-lib/checks.tsv not found")
        return nil
    }
    return text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return f.count >= 3 ? (f[0], f[1], f[2]) : nil
    }
}

private func lines(_ ran: Ran) -> [String] { ran.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun4-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sesame-kit-t/run"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
    return dir
}

private func put(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// Sources common.sh, recipes.sh and checks-s4.sh in a child bash (definitions only), points GOLDEN_ANSWERS and KIT_LIB at the scratch
/// folder's hand-written key and tables, then runs `call` with `stdin` (a file) as its input.
private func pure(_ call: String, in dir: URL, stdin: String? = nil, extra: String = "") throws -> Ran {
    var input = ""
    if let stdin {
        let f = dir.appendingPathComponent("stdin.txt")
        try put(stdin, f)
        input = " < '\(f.path)'"
    }
    let script = """
    export KIT_ROOT='\(dir.path)/sesame-kit-t'; . '\(libDir.path)/common.sh' && . '\(recipesFile.path)' && . '\(checkFile.path)'
    GOLDEN_ANSWERS='\(dir.path)/answers.csv'; KIT_LIB='\(dir.path)/lib'; \(extra)
    { \(call); }\(input)
    """
    return try run("/bin/bash", ["-c", script])
}

private func one(_ ran: Ran) -> String { ran.output.trimmingCharacters(in: .whitespacesAndNewlines) }

private let key = """
id,group,query,file,locator,window_s,note
audio-01,audio,where they talk about sleep,audio/sleep-interview.m4a,02:10,30,I sleep badly these days so the doctor told me to go to bed earlier
audio-02,audio,where they explain how to make pancakes,audio/memo-0417.mp3,01:10,30,To make the pancakes you whisk two eggs
audio-03,audio,where they discuss when the bridge opens,audio/standup-notes.flac,00:20,30,The new bridge will open in the spring
audio-04,audio,where someone talks about a dentist appointment,audio/call-recording-b.aac,00:55,30,Our dentist said the cavity is small
audio-05,audio,where they describe a volcano eruption,audio/lecture-04.m4a,01:40,30,The volcano erupted for three days
audio-06,audio,where they talk about a marathon race,audio/field-recording.mp3,00:30,30,The marathon starts at dawn
audio-07,audio,where they remind someone to water the garden,audio/voice-note-17.wav,01:25,30,Remember to water the tomato plants
audio-08,audio,where the council decides about a library,audio/town-hall.flac,00:45,30,The council voted to build a new library
video-01,video,zebra in a video,video/safari-zebra.mp4,00:42,10,a zebra standing on green grass
videospeech-01,videospeech,someone fixing the light in a tower by the sea,video/clip-v11.mp4,00:20,10,The lighthouse keeper climbed the long stairs

"""

private func keyed() throws -> URL {
    let dir = try scratch()
    try put(key, dir.appendingPathComponent("answers.csv"))
    return dir
}

@Suite("KitRunS4ChecksTests")
struct KitRunS4ChecksTests {

    // MARK: syntax and wiring

    @Test("bash -n finds no syntax error in kit-run.sh, verify.sh, kit-readback.sh, recipes.sh, checks-s4.sh, checks-s3.sh, checks-s7.sh, checks-s2.sh and checks-s6b.sh (none is run)")
    func bashSyntax() throws {
        for url in [scriptsDir.appendingPathComponent("kit-run.sh"), scriptsDir.appendingPathComponent("verify.sh"), scriptsDir.appendingPathComponent("kit-readback.sh"),
                    scriptsDir.appendingPathComponent("kit-fixtures.sh"), recipesFile, checkFile, libDir.appendingPathComponent("checks-s3.sh"),
                    libDir.appendingPathComponent("checks-s7.sh"), libDir.appendingPathComponent("checks-s2.sh"), libDir.appendingPathComponent("checks-s6b.sh")] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record(Comment(rawValue: "\(url.path) not found"))
                continue
            }
            let ran = try run("/bin/bash", ["-n", url.path])
            ok(ran.status == 0 && ran.output.isEmpty, "bash -n \(url.path) exited \(ran.status): \(ran.output)")
        }
    }

    @Test("checks-s4.sh holds no top-level command when it is sourced: only variables, `. \"$KIT_LIB/<file>.sh\"` lines and function definitions")
    func noTopLevelCommands() {
        guard let text = read(checkFile) else { Issue.record("scripts/kit-lib/checks-s4.sh not found"); return }
        var depth = 0
        var strays: [String] = []
        for line in stripComments(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if depth == 0, !line.trimmingCharacters(in: .whitespaces).isEmpty,
               !has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"^[A-Z][A-Z0-9_]*="#), !has(line, #"^\. "\$KIT_LIB/[a-z0-9-]+\.sh"$"#) {
                strays.append(line)
            }
            if has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"\}$"#) { depth += 1 }
            if line == "}" { depth = max(0, depth - 1) }
        }
        ok(strays.isEmpty, "checks-s4.sh runs code when it is sourced: \(strays.prefix(3))")
    }

    @Test("no kit file touched here names product source (Sources/): no kit function may read it")
    func noProductSource() {
        for (name, code) in kitShellSources() where ["kit-lib/checks-s4.sh", "kit-lib/recipes.sh", "kit-lib/checks-s7.sh", "kit-lib/checks-s2.sh", "kit-lib/checks-s6b.sh"].contains(name) {
            ok(!has(code, "Sources/"), "\(name) names product source (Sources/)")
        }
        ok(!has(read(scriptsDir.appendingPathComponent("kit-readback.sh")).map(stripComments) ?? "", "Sources/"), "kit-readback.sh names product source")
    }

    // MARK: the registry, the slice and the floor

    @Test("checks.tsv holds the 12 ids at slice 5 once each: S4.2, S4.5, S4.7, S4.8 and S8.8 auto-or-person, every other one auto", arguments: allIds)
    func registered(_ id: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            ok(row.slice == "5", "\(id) is registered at slice \(row.slice), expected 5")
            let want = personIds.contains(id) ? "auto-or-person" : "auto"
            ok(row.kind == want, "\(id) has kind \(row.kind), expected \(want) (feature map: only the ids that may print NEEDS-A-PERSON are auto-or-person)")
        }
    }

    @Test("each of the 12 checks is defined once in the kit, in checks-s4.sh, as the wrapper `check_<id>() { s1_run <logic>; }`", arguments: allIds)
    func definedOnce(_ id: String) {
        let name = checkFunctionName(id)
        var where_: [String] = []
        for (file, code) in kitShellSources() where shellFunctions(in: code)[name] != nil { where_.append(file) }
        ok(where_ == ["kit-lib/checks-s4.sh"], "\(name) is defined in \(where_), expected exactly checks-s4.sh")
        if let body = allFunctions()[name] {
            ok(has(body, "^[ ]*s1_run[ ]+\(logicName(id))[ ]*;?[ ]*$"), "\(name) is `\(body)`, expected `s1_run \(logicName(id))` (the panel and the kit window are closed on every path)")
        }
    }

    @Test("slice holds 8 and checks.floor is the hand recount: 78 plus S2.5, S4.1, S4.3, S4.4, S4.6, S4.9 and S4.10 = 85 of slices 1 to 5, plus S2.15, plus the five S9 auto ids plus the two S10 auto ids = 93 (plan-8-t9 amended: S10.5 and S10.8 added, slice 7 to 8; was 91 and 7)")
    func sliceAndFloor() {
        let slice = read(libDir.appendingPathComponent("slice"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        ok(slice == "8", "scripts/kit-lib/slice holds \(slice ?? "nothing"), expected 8")
        guard let rows = tsvRows() else { return }
        let admin: Set<String> = ["S6.8", "S8.2", "S8.3", "S8.7", "S6.13"]
        let counted = rows.filter { $0.kind == "auto" && (Int($0.slice) ?? 99) <= 5 && !admin.contains($0.id) }
        ok(counted.count == 85, "the recount from checks.tsv is \(counted.count) auto ids, the hand recount is 85")
        let added = Set(counted.filter { $0.slice == "5" }.map(\.id))
        ok(added == ["S2.5", "S4.1", "S4.3", "S4.4", "S4.6", "S4.9", "S4.10"], "slice 5 adds \(added.sorted()), expected S2.5, S4.1, S4.3, S4.4, S4.6, S4.9, S4.10 (S4.2, S4.5, S4.7, S4.8 and S8.8 are auto-or-person and never count)")
        let floor = Int((read(libDir.appendingPathComponent("checks.floor")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        ok(!rows.contains { $0.id.hasPrefix("S5.") }, "checks.tsv still holds an S5 id")
        let second = ["S2.15"].filter { id in rows.contains { $0.id == id && $0.slice == "6" && $0.kind == "auto" } }
        ok(second.count == 1, "checks.tsv does not hold S2.15 as an auto id of slice 6")
        let s9 = ["S9.1", "S9.2", "S9.3", "S9.4", "S9.5"].filter { id in rows.contains { $0.id == id && $0.slice == "7" && $0.kind == "auto" } }
        ok(s9.count == 5, "checks.tsv does not hold S9.1 to S9.5 as auto ids of slice 7")
        let s10 = ["S10.5", "S10.8"].filter { id in rows.contains { $0.id == id && $0.slice == "8" && $0.kind == "auto" } }
        ok(s10.count == 2, "checks.tsv does not hold S10.5 and S10.8 as auto ids of slice 8")
        ok(floor == counted.count + second.count + s9.count + s10.count && floor == 93, "checks.floor reads \(floor.map(String.init) ?? "nothing"), the recount is 85 + 1 + 5 + 2 = 93")
    }

    @Test("verify.sh --quick keeps the slice 5 ids out: no quick step runs S4.n, S2.5 or S8.8 by itself; the full run still runs kit-run.sh all --slice")
    func quickRunKeepsSlice5Out() {
        guard let code = read(scriptsDir.appendingPathComponent("verify.sh")).map(stripComments) else { Issue.record("scripts/verify.sh not found"); return }
        guard let main = shellFunctions(in: code)["main"] else { Issue.record("verify.sh defines no main"); return }
        ok(!has(main, "run_check[ ]+S4\\.|check_S4_|run_check[ ]+S2\\.5|check_S2_5|run_check[ ]+S8\\.8|check_S8_8"), "verify.sh main runs a check of slice 5 by itself: they belong to the full run (kit-run.sh all --slice N)")
        ok(has(code, "QUICK_FLOOR=3"), "QUICK_FLOOR changed")
        ok(has(code, #"kit-run\.sh"?[ ]+all[ ]+--slice"#), "the full run no longer runs kit-run.sh all --slice")
    }

    // MARK: pure helpers of checks-s4.sh

    @Test("s4_secs turns mm:ss and h:mm:ss into seconds; s4_opens_at reads the first `Opens at` of a pane and nothing when there is none")
    func opensAt() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (text, want) in [("00:42", "42"), ("02:10", "130"), ("2:10", "130"), ("1:02:03", "3723"), ("00:00", "0")] {
            let ran = try pure("s4_secs \(text)", in: dir)
            ok(one(ran) == want, "s4_secs \(text) printed \(ran.output.debugDescription), expected \(want)")
        }
        let cases: [(String, String)] = [
            ("pane sleep-interview.m4a\npane Opens at 02:10\npane Opens at 09:09\n", "130"), ("pane Opens at 2:40\n", "160"),
            ("pane Opens at 1:02:03 in the file\n", "3723"), ("pane 02:10 – 02:40\n", ""), ("pane Opens at soon\n", ""), ("", ""),
        ]
        for (pane, want) in cases {
            let ran = try pure("s4_opens_at", in: dir, stdin: pane)
            ok(one(ran) == want, "s4_opens_at of \(pane.debugDescription) printed \(ran.output.debugDescription), expected \(want.debugDescription)")
        }
    }

    @Test("s4_span reads the window's span from a pane: two times joined by a dash, an en dash, an em dash or `to`; nothing for one time or none")
    func span() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(String, String)] = [
            ("pane 02:10 – 02:40\n", "130 160"), ("pane Window 02:10-02:40\n", "130 160"), ("pane 02:10 — 02:40\n", "130 160"), ("pane from 02:10 to 02:40 of the file\n", "130 160"),
            ("pane Opens at 02:10\n", ""), ("pane nothing\n", ""),
        ]
        for (pane, want) in cases {
            let ran = try pure("s4_span", in: dir, stdin: pane)
            ok(one(ran) == want, "s4_span of \(pane.debugDescription) printed \(ran.output.debugDescription), expected \(want.debugDescription)")
        }
    }

    @Test("s4_time_ok: QuickTime's time is within 2 s of the stated time, allowing 1.5 s of play between open and pause (stated minus 2 to stated plus 3.5)")
    func timeOk() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (stated, time, want) in [("130", "130.4", 0), ("130", "128.0", 0), ("130", "127.9", 1), ("130", "133.5", 0), ("130", "133.6", 1), ("42", "43.2", 0), ("42", "0.0", 1), ("42", "", 1)] {
            let ran = try pure("s4_time_ok \(stated) '\(time)'; echo $?", in: dir)
            ok(one(ran) == String(want), "s4_time_ok \(stated) \(time) returned \(ran.output.debugDescription), expected \(want)")
        }
    }

    @Test("s4_words_overlap prints `<found> <total>`: the distinct words of the spoken sentence that the pane holds as whole words; s4_words_ok wants at least half")
    func wordsOverlap() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = "I sleep badly these days so the doctor"
        let hit = try pure("s4_words_overlap '\(note)'", in: dir, stdin: "pane Sleep badly these days, said the Doctor\n")
        ok(one(hit) == "6 8", "s4_words_overlap printed \(hit.output.debugDescription), expected `6 8` (sleep badly these days the doctor of the 8 distinct words)")
        let part = try pure("s4_words_overlap '\(note)'", in: dir, stdin: "pane doctor visit about nothing\n")
        ok(one(part) == "1 8", "s4_words_overlap printed \(part.output.debugDescription) for one shared word, expected `1 8`")
        let inside = try pure("s4_words_overlap 'so the sleep'", in: dir, stdin: "pane sleepy soothing theory\n")
        ok(one(inside) == "0 3", "s4_words_overlap printed \(inside.output.debugDescription) when the pane only holds longer words, expected `0 3`")
        let twice = try pure("s4_words_overlap 'sleep sleep sleep well'", in: dir, stdin: "pane sleep\n")
        ok(one(twice) == "1 2", "a word said three times counts once: printed \(twice.output.debugDescription), expected `1 2`")
        for (k, n, want) in [("4", "8", 0), ("3", "8", 1), ("1", "2", 0), ("0", "0", 1), ("5", "9", 0), ("4", "9", 1)] {
            let ran = try pure("s4_words_ok \(k) \(n); echo $?", in: dir)
            ok(one(ran) == String(want), "s4_words_ok \(k) \(n) returned \(ran.output.debugDescription), expected \(want) (at least half, never for no words)")
        }
    }

    @Test("s4_field reads the query, file, locator, window and note of a key row; s4_ten_queries lists the eight audio rows and then the first two again")
    func fieldsAndTen() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (id, field, want) in [("audio-01", "query", "where they talk about sleep"), ("audio-01", "file", "audio/sleep-interview.m4a"), ("audio-01", "locator", "02:10"), ("audio-01", "window", "30"),
                                  ("audio-01", "note", "I sleep badly these days so the doctor told me to go to bed earlier"), ("video-01", "window", "10"), ("videospeech-01", "file", "video/clip-v11.mp4"), ("audio-99", "file", "")] {
            let ran = try pure("s4_field \(id) \(field)", in: dir)
            ok(one(ran) == want, "s4_field \(id) \(field) printed \(ran.output.debugDescription), expected \(want.debugDescription)")
        }
        let ten = try pure("s4_ten_queries", in: dir)
        let got = lines(ten).map { $0.components(separatedBy: "\t").first ?? "" }
        ok(got == ["audio-01", "audio-02", "audio-03", "audio-04", "audio-05", "audio-06", "audio-07", "audio-08", "audio-01", "audio-02"], "s4_ten_queries printed \(got), expected the eight audio rows then audio-01 and audio-02")
        ok(lines(ten).first == "audio-01\twhere they talk about sleep\taudio/sleep-interview.m4a\t02:10", "the first line is \(lines(ten).first ?? "nothing"), expected id, query, file, locator tab separated")
    }

    @Test("s4_unreadable lists the two damaged golden-av clips with the reason Settings and the index show: damaged")
    func unreadable() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ran = try pure("s4_unreadable", in: dir)
        ok(lines(ran) == ["golden-av/damaged/broken.m4a\tdamaged", "golden-av/damaged/broken.mp4\tdamaged"], "s4_unreadable printed \(lines(ran))")
    }

    @Test("s4_changed_done counts the done files a `kit-index.sh diff` says changed or went missing, and nothing else")
    func changedDone() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let diff = "- /x/golden-av/audio/a.m4a\tdone\n+ /x/golden-av/audio/a.m4a\tdone\n- /x/golden-av/audio/b.m4a\tpending\n- /x/golden-av/video/c.mp4\tdone\n0 same\n"
        let ran = try pure("s4_changed_done", in: dir, stdin: diff)
        ok(one(ran) == "2", "s4_changed_done printed \(ran.output.debugDescription), expected 2")
        let none = try pure("s4_changed_done", in: dir, stdin: "same 40\n")
        ok(one(none) == "0", "s4_changed_done of a diff with no change printed \(none.output.debugDescription), expected 0")
    }

    // MARK: each check, as text (a check is never run here)

    @Test("every check starts with golden_need: it comes before the first kit script, search or readback of the body", arguments: allIds)
    func startsWithGoldenNeed(_ id: String) {
        guard let t = logic(id) else { return }
        guard let g = firstIndex(t, "\\bgolden_need\\b") else { ok(false, "\(id) never calls golden_need"); return }
        for other in ["kit-[a-z]+\\.sh", "\\bs1_search\\b", "\\bs1_kq\\b", "\\bkq[ ]", "\\bpick_folders\\b", "\\brecipe_golden\\b", "\\brecipe_photos\\b", "\\bs1_need_photos\\b"] {
            if let o = firstIndex(t, other) { ok(g < o, "\(id) calls `\(other)` before golden_need") }
        }
        ok(!has(t, "kit-golden\\.sh\"?[ ]+prepare|\\bs1_need_photos\\b|\\brecipe_photos\\b"), "\(id) makes the photo-only state (prepare, photos): the checks start from the recipe golden")
        ok(!has(t, "golden_need[ ]+--hold"), "\(id) asks for a held state: only S3.6 does")
        ok(has(t, "s3_need"), "\(id) does not turn a golden_need that needs a person or is not valid into the CHECK or RERUN line (s3_need)")
    }

    @Test("no check starts, stops or resets the app, or edits the key or a fixture; no check but S4.8 and S8.8 reads a trace or asks for administrator rights", arguments: allIds)
    func noDirectLaunch(_ id: String) {
        guard let t = logic(id) else { return }
        ok(!has(t, "kit-launch\\.sh\"?[ ]+(start|relaunch|quit|stop)|kit-reset\\.sh|killall|pkill|ask-admin"), "\(id) starts, stops or resets the app, or asks for a password")
        ok(!has(t, "(rm|mv|cp|>)[ ]+[^\\n]*fixtures/answers\\.csv"), "\(id) writes the key")
        if id == "S4.8" || id == "S8.8" {
            ok(has(t, "sudo[ ]+-n[ ]+true"), "\(id) does not look for the administrator session without asking (sudo -n true)")
        } else {
            ok(!has(t, "kit-trace\\.sh|kit-net\\.sh|\\bsudo\\b"), "\(id) reads a trace: it would be an administrator id")
        }
    }

    @Test("S4.1 and S4.3: the first 3 rows hold the file of the key row (audio-01 and video-01), the query and the file come from the key")
    func s41s43() {
        for (id, row, file) in [("S4.1", "audio-01", "sleep"), ("S4.3", "video-01", "zebra")] {
            guard let t = logic(id) else { continue }
            ok(has(t, row) && has(t, "s4_field[^\\n]*(query|file)"), "\(id) does not take the query and the file of the key row \(row) (\(file))")
            before(t, "golden_need", "s1_search", "\(id) searches before it has a state")
            ok(has(t, "s3_rank_of") && has(t, "-le[ ]+3"), "\(id) does not require the file in the first 3 rows")
            ok(has(t, "CHECK \(id.replacingOccurrences(of: ".", with: "\\.")) PASS") && has(t, "s1_fail[ ]+\(id.replacingOccurrences(of: ".", with: "\\."))"), "\(id) lacks a PASS line or a FAIL line")
        }
    }

    @Test("S4.2: Opens at inside [02:10, 02:40], the span, a pane shot, waveform-check against 130 s, the spoken words at half or more, the words alone NEEDS-A-PERSON without speech assets; --plant moves the drawn block and prints FAIL planted")
    func s42() {
        guard let t = logic("S4.2") else { return }
        ok(has(t, "audio-01") && has(t, "s4_field[^\\n]*(locator|note)"), "S4.2 does not take the locator and the note of the key row audio-01")
        ok(has(t, "s4_opens_at") && has(t, "s4_secs") && has(t, "window"), "S4.2 does not read `Opens at mm:ss` and compare it with [locator, locator + window]")
        ok(has(t, "s4_span"), "S4.2 does not read the window's span from the pane (s4_span)")
        before(t, "kit-ax\\.sh\"?[ ]+shot[^\\n]*--panel", "kit-readback\\.sh\"?[ ]+waveform-check", "S4.2 must take the pane screenshot before waveform-check")
        ok(has(t, "waveform-check[^\\n]*\\$") && has(t, "compare-s4-waveform"), "S4.2 does not pass the shot, the file and the start to waveform-check, or name compare-s4-waveform.txt")
        ok(has(t, "RERUN S4\\.2 not valid") && has(t, "return 4"), "S4.2 does not turn a waveform-check that cannot see a picture (exit 4) into RERUN and status 4")
        ok(has(t, "kit-readback\\.sh\"?[ ]+speech-assets"), "S4.2 does not ask speech-assets before it reads the words")
        ok(has(t, "s4_words_overlap") && has(t, "s4_words_ok"), "S4.2 does not compare the pane's words with the note (s4_words_overlap, s4_words_ok)")
        ok(has(t, "NEEDS-A-PERSON"), "S4.2 has no NEEDS-A-PERSON line for the words when on-device recognition is not there")
        ok(has(t, "KIT_PLANT") && has(t, "FAIL planted"), "S4.2 has no plant: with KIT_PLANT it must print `FAIL planted`")
        ok(has(t, "KIT_PLANT[^\\n]*\\n?[^\\n]*(start|block|wrong)|wrong block|drawn waveform"), "S4.2's plant does not say that the waveform is taken for the wrong block")
        ok(has(t, "CHECK S4\\.2 PASS") && has(t, "s1_fail[ ]+S4\\.2"), "S4.2 lacks a PASS line or a FAIL line")
    }

    @Test("S4.2's plant asks waveform-check for a block 60 s away from the stated one, and only then")
    func s42Plant() {
        guard let t = logic("S4.2") else { return }
        ok(has(t, "KIT_PLANT[^\\n]*\\n[^\\n]*\\+[ ]*60|\\+[ ]*60[^\\n]*KIT_PLANT|start=\\$\\(\\(.*\\+[ ]*60"), "S4.2's plant does not move the start by 60 s (a block that is not the drawn one)")
    }

    @Test("S4.4: Opens at inside [00:42, 00:52], a pane shot, frame-check against the builder's frame of that second and the frame 20 s earlier")
    func s44() {
        guard let t = logic("S4.4") else { return }
        ok(has(t, "video-01") && has(t, "s4_opens_at") && has(t, "s4_secs"), "S4.4 does not read `Opens at mm:ss` and compare it with the key row video-01")
        before(t, "kit-ax\\.sh\"?[ ]+shot[^\\n]*--panel", "kit-readback\\.sh\"?[ ]+frame-check", "S4.4 must take the pane screenshot before frame-check")
        ok(has(t, "frame-check[^\\n]*\\$") && has(t, "compare-s4-frame"), "S4.4 does not pass the shot, the video and the second to frame-check, or name compare-s4-frame.txt")
        ok(has(t, "RERUN S4\\.4 not valid") && has(t, "return 4"), "S4.4 does not turn a frame-check that cannot see a picture (exit 4) into RERUN and status 4")
        ok(has(t, "CHECK S4\\.4 PASS") && has(t, "s1_fail[ ]+S4\\.4"), "S4.4 lacks a PASS line or a FAIL line")
    }

    @Test("S4.5: for the audio and the video, QuickTime documents closed before Enter, Enter, QuickTime Player frontmost with the file name, quicktime-time within 2 s of the stated time; scripting refused is NEEDS-A-PERSON")
    func s45() {
        guard let t = logic("S4.5") else { return }
        ok(has(t, "audio-01") && has(t, "video-01"), "S4.5 does not take both the audio and the video rows")
        before(t, "s4_close_quicktime|close every document", "--open", "S4.5 must close QuickTime's documents before Enter")
        ok(has(t, "s1_wait_front[ ]+\"?QuickTime Player"), "S4.5 does not wait for QuickTime Player to be frontmost")
        ok(has(t, "s3_title_holds"), "S4.5 does not read the file name in QuickTime's window (s3_title_holds)")
        before(t, "--open", "kit-readback\\.sh\"?[ ]+quicktime-time", "S4.5 reads the time before Enter")
        ok(has(t, "s4_time_ok") && has(t, "s4_opens_at"), "S4.5 does not compare the time with the pane's stated time (s4_opens_at, s4_time_ok)")
        ok(has(t, "NEEDS-A-PERSON") && has(t, "\\$rc[ ]*=[ ]*3|3\\)"), "S4.5 does not make a refused scripting reply (exit 3) NEEDS-A-PERSON")
        ok(has(t, "CHECK S4\\.5 PASS") && has(t, "s1_fail[ ]+S4\\.5"), "S4.5 lacks a PASS line or a FAIL line")
    }

    @Test("S4.6: the Audio and Video switches in Settings, File types; each state is read within 2 s with no re-read of any done file; a new audio file added while Audio is off is absent after 60 s")
    func s46() {
        guard let t = logic("S4.6") else { return }
        ok(has(t, "click[ ]+\"\\$?[^\"\\n]*(Audio|label)") && t.contains("Audio") && t.contains("Video"), "S4.6 does not press the Audio and Video switches")
        ok(has(t, "settings_section[ ]+\"?File types|File types"), "S4.6 does not put Settings on File types")
        ok(has(t, "--expect-absent") && has(t, "--wait-for") && has(t, "--within[ ]+2"), "S4.6 does not read the absence and the return of the audio row within 2 s (--expect-absent, --wait-for ... --within 2)")
        ok(has(t, "kit-index\\.sh\"?[ ]+snapshot") && has(t, "kit-index\\.sh\"?[ ]+diff") && has(t, "s4_changed_done"), "S4.6 does not prove that nothing was re-read (kit-index.sh snapshot, diff, s4_changed_done)")
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+mutate[ ]+create") && has(t, "kit-index\\.sh\"?[ ]+has") && has(t, "60"), "S4.6 does not add a new audio file (mutate create) and look for it with `kit-index.sh has` after 60 s")
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+restore"), "S4.6 does not put the added file back (kit-fixtures.sh restore)")
        ok(has(t, "both|Video[^\\n]*Audio"), "S4.6 does not try both kinds off")
        ok(has(t, "CHECK S4\\.6 PASS") && has(t, "s1_fail[ ]+S4\\.6"), "S4.6 lacks a PASS line or a FAIL line")
    }

    @Test("S4.7: IINA and VLC are asked for; (a) an absent one chosen shows `not installed` and Enter puts the default m4a app in front, (b) an installed one chosen shows none; the exact NOT RUN line; both installed makes (a) NEEDS-A-PERSON")
    func s47() {
        guard let t = logic("S4.7") else { return }
        ok(t.contains("com.colliderli.iina") && t.contains("org.videolan.vlc"), "S4.7 does not ask app-installed for com.colliderli.iina and org.videolan.vlc")
        ok(t.contains("S4.7 (b) NOT RUN: no listed media app other than QuickTime Player is installed"), "S4.7 lacks the exact line `S4.7 (b) NOT RUN: no listed media app other than QuickTime Player is installed`")
        ok(has(t, "not installed"), "S4.7 does not read Settings' `not installed` message")
        ok(has(t, "kit-readback\\.sh\"?[ ]+default-app[ ]+m4a"), "S4.7 does not compare the frontmost app with `default-app m4a`")
        ok(has(t, "--open") && has(t, "s3_app_matches"), "S4.7 does not press Enter and compare the front app (s3_app_matches)")
        ok(has(t, "NEEDS-A-PERSON"), "S4.7 has no NEEDS-A-PERSON line (both apps installed, or the Settings choice cannot be driven)")
        ok(has(t, "chosen app[^\\n]*frontmost|frontmost[^\\n]*chosen|\\$present_name[^\\n]*READBACK|READBACK[^\\n]*\\$present_name"), "S4.7 (b) does not say that the chosen app must not be frontmost when it is not the default app")
        ok(has(t, "CHECK S4\\.7 PASS") && has(t, "s1_fail[ ]+S4\\.7"), "S4.7 lacks a PASS line or a FAIL line")
    }

    @Test("S4.8 and S8.8: the administrator session without a prompt, fs_usage trace and nettop before the app search, a plant before and after ten audio selections, both stopped, then speech, summary and trace net; exit 4 when fs_usage misses a plant")
    func s48s88() {
        for (id, name) in [("S4.8", "s4-speech"), ("S8.8", "s8-speech")] {
            guard let t = logic(id) else { continue }
            ok(t.contains(name), "\(id) does not name its observers \(name)")
            ok(has(t, "sudo[ ]+-n[ ]+true") && has(t, "NEEDS-A-PERSON"), "\(id) does not make a missing administrator session NEEDS-A-PERSON without asking for a password")
            before(t, "kit-trace\\.sh\"?[ ]+start[^\\n]*--net", "kit-net\\.sh\"?[ ]+start", "\(id): the fs_usage trace must start before nettop")
            before(t, "kit-net\\.sh\"?[ ]+start", "kit-net\\.sh\"?[ ]+control", "\(id): the first plant must come after the observers start")
            before(t, "kit-net\\.sh\"?[ ]+control", "s4_ten_queries", "\(id): the first plant must come before the ten selections")
            before(t, "s4_ten_queries", "kit-net\\.sh\"?[ ]+stop", "\(id): both observers stop after the ten selections")
            ok(groups(t, "kit-net\\.sh\"?[ ]+(control)").count + groups(t, "s4_plant").count >= 2, "\(id) plants only once: a plant before and one after the ten selections")
            before(t, "kit-net\\.sh\"?[ ]+stop", "kit-trace\\.sh\"?[ ]+stop", "\(id): nettop stops before the trace")
            before(t, "kit-trace\\.sh\"?[ ]+stop", "kit-net\\.sh\"?[ ]+speech", "\(id): the speech reading comes after both observers stop")
            ok(has(t, "kit-net\\.sh\"?[ ]+summary") && has(t, "kit-trace\\.sh\"?[ ]+net") && has(t, "s8d_net_status|s8d_failure_lines|s8d_destinations"), "\(id) does not read both observers (kit-net.sh summary, kit-trace.sh net) as S8.7 does")
            // the shared run takes the id as its argument, so its lines say `$id`
            ok(has(t, "RERUN \\$id not valid") && has(t, "return 4"), "\(id) does not make an fs_usage trace that missed a plant RERUN and status 4")
            ok(has(t, "cannot attribute|NEEDS-A-PERSON"), "\(id) does not make an unattributable daemon NEEDS-A-PERSON")
            ok(has(t, "CHECK \\$id PASS") && has(t, "s1_fail[ ]+\"?\\$id"), "\(id) lacks a PASS line or a FAIL line")
            ok(has(t, "s4_speech_run[ ]+\(id.replacingOccurrences(of: ".", with: "\\."))[ ]+\(name)"), "\(id) does not run the observers under the name \(name)")
        }
    }

    @Test("S4.9: Settings lists both damaged clips with `damaged`, kit-index.sh reasons says the same, every other media file of golden-av is done")
    func s49() {
        guard let t = logic("S4.9") else { return }
        ok(has(t, "s4_unreadable"), "S4.9 does not take the damaged clips from s4_unreadable")
        ok(has(t, "s8c_settings_open") && has(t, "s8c_section_dump") && has(t, "s3_in_dump"), "S4.9 does not read the Settings list in every section (s8c_settings_open, s8c_section_dump, s3_in_dump)")
        ok(has(t, "kit-index\\.sh\"?[ ]+reasons") && has(t, "s3_reasons_hold"), "S4.9 does not read `kit-index.sh reasons`")
        ok(has(t, "kit-index\\.sh\"?[ ]+under[ ]+golden-av") && has(t, "s3_not_done"), "S4.9 does not name a golden-av file that is not done (kit-index.sh under golden-av, s3_not_done)")
        ok(has(t, "CHECK S4\\.9 PASS") && has(t, "s1_fail[ ]+S4\\.9"), "S4.9 lacks a PASS line or a FAIL line")
    }

    @Test("S4.10: the videospeech row's clip is in the first 3 with Opens at in [locator, locator + 10 s], clip-v12 is not above it, and a picture query the frames do not hold does not list it")
    func s410() {
        guard let t = logic("S4.10") else { return }
        ok(has(t, "videospeech-01") && has(t, "s4_field"), "S4.10 does not take the row videospeech-01")
        ok(has(t, "s3_rank_of") && has(t, "-le[ ]+3"), "S4.10 does not require the clip in the first 3 rows")
        ok(has(t, "s4_opens_at") && has(t, "s4_secs"), "S4.10 does not read `Opens at mm:ss` and compare it with [locator, locator + 10]")
        ok(has(t, "clip-v12\\.mp4"), "S4.10 does not look at the negative control clip-v12.mp4")
        ok(has(t, "clip-v12[^\\n]*(rank|above)|above"), "S4.10 does not say that clip-v12 must not be above clip-v11")
        ok(has(t, "does not hold|picture the frames"), "S4.10 does not name the picture query that the frames do not hold")
        ok(has(t, "CHECK S4\\.10 PASS") && has(t, "s1_fail[ ]+S4\\.10"), "S4.10 lacks a PASS line or a FAIL line")
        ok(!has(t, "NEEDS-A-PERSON"), "S4.10 goes to a person: the feature map says it fails when the audio path cannot read speech in a soundtrack")
    }

    @Test("S2.5: the panel run of group d first, the engine run last, the recipe mark dropped after the engine, never prepare, both lines scored and printed")
    func s25() {
        guard let t = logic("S2.5") else { return }
        before(t, "kit-golden\\.sh\"?[ ]+panel[ ]+--group[ ]+d", "kit-golden\\.sh\"?[ ]+engine[ ]+--group[ ]+d", "S2.5: the panel run must come before the engine run (the engine's prepare --all resets the kit)")
        let enginePos = firstIndex(t, "kit-golden\\.sh\"?[ ]+engine[ ]+--group[ ]+d"), dropPos = firstIndex(t, "rm[ ]+-f[ ]+[^\\n]*run/recipe")
        ok(enginePos != nil && dropPos != nil && dropPos! > enginePos!, "S2.5 does not drop run/recipe after the engine run: the next check would trust a reset kit")
        ok(!has(t, "kit-golden\\.sh\"?[ ]+prepare"), "S2.5 calls kit-golden.sh prepare itself")
        ok(has(t, "golden-panel\\.tsv") && has(t, "golden-engine\\.tsv"), "S2.5 does not read golden-panel.tsv and golden-engine.tsv")
        ok(has(t, "group d"), "S2.5 does not read the `group d` line of kit-golden.sh")
        ok(has(t, "RERUN S2\\.5 not valid") && has(t, "NEEDS-A-PERSON"), "S2.5 lacks `RERUN S2.5 not valid` or its NEEDS-A-PERSON line")
        ok(has(t, "CHECK S2\\.5 PASS") && has(t, "CHECK S2\\.5 FAIL"), "S2.5 lacks a PASS or a FAIL line")
    }

    // MARK: the four-root recipe `golden`

    @Test("golden_pick_list on a hand-written table of four roots: golden and its lone subfolder, golden-docs, boundary, and golden-av (three subfolders, so once), in table order")
    func pickListFourRoots() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try put("# folder\tsubfolders\ngolden\tphotos\ngolden-docs\tpdfs,docs\nboundary\t\ngolden-av\taudio,video,damaged\n", dir.appendingPathComponent("hand.tsv"))
        let ran = try pure("golden_pick_list '\(dir.path)/hand.tsv'", in: dir)
        ok(ran.status == 0 && lines(ran) == ["golden", "golden/photos", "golden-docs", "boundary", "golden-av"], "golden_pick_list printed \(lines(ran)) (exit \(ran.status))")
    }

    @Test("scripts/kit-lib/golden-roots.tsv holds the four golden folders and golden_pick_list of it lists them: golden-av with audio, video and damaged")
    func realRoots() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let text = read(libDir.appendingPathComponent("golden-roots.tsv")) else { Issue.record("golden-roots.tsv not found"); return }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let got = rows.map { r in [r.first ?? "", r.count > 1 ? r[1] : ""] }
        ok(got == [["golden", "photos"], ["golden-docs", "pdfs,docs"], ["boundary", ""], ["golden-av", "audio,video,damaged"]], "golden-roots.tsv holds \(got)")
        let ran = try pure("golden_pick_list '\(libDir.path)/golden-roots.tsv'", in: dir)
        ok(lines(ran) == ["golden", "golden/photos", "golden-docs", "boundary", "golden-av"], "golden_pick_list of the real table printed \(lines(ran))")
    }

    @Test("recipe_golden also builds golden-av, before it picks, and says four roots")
    func recipeGoldenBuildsAv() {
        guard let fn = shellFunctions(in: read(recipesFile).map(stripComments) ?? "")["recipe_golden"] else { Issue.record("recipes.sh has no recipe_golden"); return }
        let t = substitute(fn, topLevelValues())
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+build[ ]+golden-av"), "recipe_golden does not build golden-av")
        before(t, "kit-fixtures\\.sh\"?[ ]+build[ ]+boundary", "kit-fixtures\\.sh\"?[ ]+build[ ]+golden-av", "recipe_golden: boundary before golden-av")
        before(t, "kit-fixtures\\.sh\"?[ ]+build[ ]+golden-av", "pick_folders", "recipe_golden must build golden-av before it picks")
        ok(!has(t, "the three roots") && has(t, "four roots"), "recipe_golden still says `the three roots`")
    }

    @Test("S3.8 counts golden-av as its fourth root and lists the two damaged clips with their reason, so the done count still equals the readable files")
    func s38FourRoots() {
        guard let t = allFunctions()["s3_check_8"].map({ substitute($0, topLevelValues()) }) else { Issue.record("s3_check_8 not defined"); return }
        ok(has(t, "for root in golden golden-docs boundary golden-av"), "S3.8 does not count golden-av among its roots")
        ok(has(t, "s4_unreadable"), "S3.8 does not list the damaged golden-av clips (s4_unreadable) among the unreadable files")
    }

    // MARK: the recipes mix500 and pauselong

    @Test("kit-run.sh shows `prep mix500 [--no-start]` and `prep pauselong <pdf|audio|video>` in its usage and keeps every other prep line")
    func usageLines() {
        guard let text = read(scriptsDir.appendingPathComponent("kit-run.sh")) else { Issue.record("scripts/kit-run.sh not found"); return }
        let usage = shellFunctions(in: stripComments(text))["usage"] ?? ""
        ok(usage.contains("kit-run.sh prep mix500 [--no-start]"), "the usage lacks `kit-run.sh prep mix500 [--no-start]`")
        ok(usage.contains("kit-run.sh prep pauselong <pdf|audio|video>"), "the usage lacks `kit-run.sh prep pauselong <pdf|audio|video>`")
        for old in ["prep fresh-throttled", "prep photos [--no-wait] [--cache-dir <dir>]", "prep busy50k", "prep setup [--trace <name>]", "prep minimix [--no-start]", "prep tree [--trace <name>]", "prep golden [--hold-start]"] {
            ok(usage.contains(old), "the usage lost `\(old)`")
        }
    }

    // plan-6-t1 (amended by the tester, never weakened; reason: the entry says "the recipes `golden-code` and `overlap` replace `not built yet`"):
    // they have their own branches; only index50k stays on the not-built line, found by its name.
    @Test("recipe_main runs recipe_mix500 and recipe_pauselong; no recipe is left on a `not built yet` line")
    func recipeMainDispatch() {
        guard let text = read(recipesFile).map(stripComments) else { Issue.record("scripts/kit-lib/recipes.sh not found"); return }
        let main = shellFunctions(in: text)["recipe_main"] ?? ""
        ok(has(main, "(^|\\n)[ \\t]*mix500\\)[^\\n]*recipe_mix500"), "recipe_main has no `mix500)` branch that runs recipe_mix500")
        ok(has(main, "(^|\\n)[ \\t]*pauselong\\)[^\\n]*recipe_pauselong"), "recipe_main has no `pauselong)` branch that runs recipe_pauselong")
        // plan-6-t9 (amended by the tester, never weakened; reason: the entry says `index50k` "replaces `not built yet`"): index50k has its own branch that
        // runs recipe_index50k and no recipe is left on a not-built line, so the line is gone; no built recipe may be listed on any `not built yet` line.
        let notBuilt = main.split(separator: "\n").first { $0.contains("not built yet") }.map(String.init) ?? ""
        ok(has(main, "(^|\\n)[ \\t]*index50k\\)[^\\n]*recipe_index50k"), "recipe_main has no `index50k)` branch that runs recipe_index50k")
        ok(!has(notBuilt, "(^|[ |])index50k(\\||\\))"), "recipe_main still lists `index50k` as not built yet: \(notBuilt)")
        ok(!has(notBuilt, "golden-code") && !has(notBuilt, "overlap"), "recipe_main still lists golden-code or overlap as not built yet: \(notBuilt)")
        ok(!has(notBuilt, "(^|[ |])mix500(\\||\\))"), "recipe_main still lists `mix500` as not built yet: \(notBuilt)")
        ok(!main.contains("not built yet"), "recipe_main still has a `not built yet` line although every recipe is built")
    }

    @Test("recipe_mix500: state, models, reset with the cached model, the app, build mix500, the setup window, pick_folders mix500, Start only without --no-start")
    func recipeMix500Text() {
        guard let fn = shellFunctions(in: read(recipesFile).map(stripComments) ?? "")["recipe_mix500"] else { Issue.record("recipes.sh has no recipe_mix500"); return }
        let t = substitute(fn, topLevelValues())
        before(t, "recipe_state", "recipe_reset[ ]+cache", "recipe_mix500 must read the starting state before it resets")
        ok(has(t, "models_check"), "recipe_mix500 does not check the model files")
        before(t, "recipe_reset[ ]+cache", "kit-fixtures\\.sh\"?[ ]+build[ ]+mix500", "recipe_mix500 must reset before the build")
        before(t, "kit-launch\\.sh\"?[ ]+start", "pick_folders[ ]+mix500", "recipe_mix500 picks before the app started")
        before(t, "wait_setup_window", "pick_folders[ ]+mix500", "recipe_mix500 must wait for the setup window before it picks")
        ok(has(t, "--no-start") && has(t, "press_start"), "recipe_mix500 has no --no-start option or never presses Start")
        before(t, "pick_folders[ ]+mix500", "press_start", "recipe_mix500 presses Start before it picks")
    }

    @Test("pauselong_folder maps a unit to its folder under the fixtures root: pdf, audio and video; any other unit is status 2")
    func pauselongFolder() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (unit, want) in [("pdf", "pauselong/pdf"), ("audio", "pauselong/audio"), ("video", "pauselong/video")] {
            let ran = try pure("pauselong_folder \(unit)", in: dir)
            ok(ran.status == 0 && one(ran) == want, "pauselong_folder \(unit) printed \(ran.output.debugDescription) (exit \(ran.status)), expected \(want)")
        }
        for bad in ["", "photo", "audio/", "../x"] {
            let ran = try pure("pauselong_folder '\(bad)'; echo \"rc=$?\"", in: dir)
            ok(ran.output.contains("rc=2"), "pauselong_folder '\(bad)': \(ran.output.debugDescription), expected status 2")
        }
    }

    @Test("recipe_pauselong: a unit is required (usage, status 2 otherwise), state, models, reset, build pauselong, the setup window, pick_folders of that one folder, then Start")
    func recipePauselongText() {
        guard let fn = shellFunctions(in: read(recipesFile).map(stripComments) ?? "")["recipe_pauselong"] else { Issue.record("recipes.sh has no recipe_pauselong"); return }
        let t = substitute(fn, topLevelValues())
        ok(has(t, "pauselong_folder") && has(t, "usage") && has(t, "return 2"), "recipe_pauselong does not refuse an unknown unit (pauselong_folder, usage, return 2)")
        before(t, "recipe_state", "recipe_reset[ ]+cache", "recipe_pauselong must read the starting state before it resets")
        ok(has(t, "models_check"), "recipe_pauselong does not check the model files")
        before(t, "recipe_reset[ ]+cache", "kit-fixtures\\.sh\"?[ ]+build[ ]+pauselong", "recipe_pauselong must reset before the build")
        before(t, "wait_setup_window", "pick_folders", "recipe_pauselong must wait for the setup window before it picks")
        ok(has(t, "pick_folders[^\\n]*\\$"), "recipe_pauselong does not pick the unit's folder with pick_folders")
        before(t, "pick_folders", "press_start", "recipe_pauselong presses Start before it picks")
    }

    @Test("kit-fixtures.sh build pauselong also makes pdf/annual-report-60p.pdf, the one-file folder of the pdf unit: its usage line, and the builder takes it from golden-docs.tsv")
    func pauselongMakesPdf() {
        let code = read(scriptsDir.appendingPathComponent("kit-fixtures.sh")).map(stripComments) ?? ""
        let b = shellFunctions(in: code)["build_pauselong"] ?? ""
        ok(has(b, "annual-report-60p\\.pdf") && has(b, "docs_pdfs_into"), "build_pauselong does not make annual-report-60p.pdf through docs_pdfs_into")
        ok(has(b, "mkdir[^\\n]*pdf"), "build_pauselong does not make the folder pdf/")
    }

    // MARK: S7.2, S6.11 and S2.11

    @Test("S7.2 runs the pause measurement on the mini mix and then once for each of pdf, audio and video: the recipe pauselong, exactly one unit open, Pause, 5 s and 20 s, Resume, the snapshots")
    func s72Units() {
        let all = allFunctions()
        guard let check = all["s7_check_2"], let unit = all["s7_pause_unit"] else { Issue.record("s7_check_2 or s7_pause_unit is not defined"); return }
        let c = substitute(check, topLevelValues()), u = substitute(unit, topLevelValues())
        ok(has(c, "recipe_minimix|s7_arm"), "S7.2 no longer starts with the mini mix")
        ok(has(c, "for[ ]+\\w+[ ]+in[ ]+pdf[ ]+audio[ ]+video") && has(c, "s7_pause_unit"), "S7.2 does not run s7_pause_unit for pdf, audio and video")
        ok(!c.contains("units are slice 5"), "S7.2's PASS line still says the long units are slice 5")
        ok(has(c, "60-page PDF") && has(c, "60-minute") && has(c, "2-minute"), "S7.2's PASS line does not name the three long units")
        // The same commit (080db8e) presses through s6_press (it prints the driver's output on a failed press) instead of a bare click.
        before(u, "recipe_pauselong", #"s6_press[ ]+"[^"]*"[ ]+"Pause indexing""#, "the unit's recipe must run before Pause")
        ok(has(u, "kit-index\\.sh\"?[ ]+status|s7_open_rows|s7_in_flight"), "s7_pause_unit does not confirm with kit-index.sh status that only that unit is in flight")
        ok(has(u, "RERUN[^\\n]*not valid") || has(u, "S7_RC=4"), "s7_pause_unit does not make a second unit in flight a RERUN")
        ok(has(u, "sleep[ ]+0\\.25") && has(u, "[^0-9]5[^0-9]") && has(u, "[^0-9]20[^0-9]") || has(u, "s7_sig"), "s7_pause_unit does not poll every 250 ms for 5 s and 20 s")
        // The wait after Resume is per unit since the round-2 kit fix (commit 080db8e): a 60-page PDF takes longer than 10 s to start
        // climbing again, so pdf waits 30 s; audio and video keep 10 s. The wait is passed as $rwait and named in the failure text.
        ok(has(u, "Paused"), "s7_pause_unit does not read the Paused label")
        ok(has(u, #"rwait=10"#), "s7_pause_unit does not default the wait after Resume to 10 s")
        ok(has(u, #"\[ "\$unit" = pdf \][ ]+&&[ ]+rwait=30"#), "s7_pause_unit does not give pdf, and only pdf, a 30 s wait after Resume")
        ok(!has(u, #"rwait=(?!10\b|30\b)[0-9]+"#), "s7_pause_unit sets a wait after Resume that is neither 10 nor 30")
        ok(has(u, #"wait[ ]+rising[ ]+"?\$rwait"?"#), "s7_pause_unit does not wait `rising $rwait` after Resume")
        ok(!has(u, #"wait[ ]+rising[ ]+[0-9]"#), "s7_pause_unit still waits a fixed number of seconds after Resume instead of the unit's own wait")
        ok(has(u, #"did not rise within \$rwait s of Resume indexing"#) && has(u, #"wait rising \$rwait exited"#), "s7_pause_unit's failure text does not name the wait it used")
        ok(has(u, "snapshot[ ]+\"?before-pause\"?[ ]+--files-only") && has(u, "snapshot[ ]+\"?after-resume\"?[ ]+--files-only") && has(u, "diff[ ]+\"?before-pause"), "s7_pause_unit does not compare the files-only snapshots before and after")
        before(u, #"s6_press[ ]+"[^"]*"[ ]+"Pause indexing""#, #"s6_press[ ]+"[^"]*"[ ]+"Resume indexing""#, "s7_pause_unit presses Resume before Pause")
        ok(has(u, "kit-index\\.sh\"?[ ]+wait[ ]+done|kit-index\\.sh\"?[ ]+wait[ ]+stable|s7_ready"), "s7_pause_unit never lets the unit finish before the next unit starts")
    }

    @Test("S6.11 runs on the 500-file mix: recipe mix500 --no-start, expect listing mix500 as the hand count, both figures printed, no `partial` and no `minimix`")
    func s611Mix500() {
        let all = allFunctions()
        guard let check = all["s6_check_11"] else { Issue.record("s6_check_11 is not defined"); return }
        let t = substitute(check + "\n" + (all["s6b_need_mix500"] ?? ""), topLevelValues())
        ok(has(t, "recipe_mix500[ ]+--no-start"), "S6.11 does not start from `recipe_mix500 --no-start`")
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+expect[ ]+listing[ ]+\"?mix500"), "S6.11 does not cross-check the divisor against `kit-fixtures.sh expect listing mix500`")
        ok(!has(t, "minimix"), "S6.11 still names the mini mix")
        ok(!t.contains("partial"), "S6.11 still labels its figures `partial`")
        ok(has(t, "estimate-check") && has(t, "50000") && has(t, "hand count") && has(t, "-wal"), "S6.11 lost its estimate-check, its 50000 byte bar, its hand count or its -wal note")
        ok(has(t, "500-file mix"), "S6.11's PASS line does not say it ran on the 500-file mix")
        ok(has(t, "estimated[^\\n]*\\$est[^\\n]*(bytes|size)|\\$est[^\\n]*\\$size|\\$size[^\\n]*\\$est"), "S6.11's PASS line does not print both figures (the estimate and the bytes a file)")
        ok(has(t, "30 percent|30%|0\\.3|1\\.3"), "S6.11 does not state the estimate bar of 30 percent")
    }

    @Test("S2.11 starts the 500-file mix on top of the 50,000-row index in launches B and C, and reads unread rows before the first and after the last measurement (else RERUN)")
    func s211Mix500() {
        let all = allFunctions()
        guard let launch = all["s2_launch_bc"], let top = all["s2_mix_on_top"], let check = all["s2_check_11"] else { Issue.record("s2_launch_bc, s2_mix_on_top or s2_check_11 is not defined"); return }
        ok(has(launch, "s2_mix_on_top"), "launches B and C do not start the mix on top of the busy index")
        // Amended in plan-6-t9 part 2 (never weakened): S2.9 to S2.14 run on the real 50,000-row index, so launches B and C restore it with
        // `index50k_launch` instead of the stand-in's `busy50k_launch`. The bar is the same (the mix goes on after the index is restored) and the
        // pin is stricter: the stand-in's name must be gone from the launch. The behaviour is pinned in KitRunS2ClosingTests.
        before(launch, "index50k_launch", "s2_mix_on_top", "the mix is started before the real 50,000-row index is restored")
        ok(!has(launch, "busy50k"), "launches B and C still restore the stand-in index (busy50k)")
        let t = substitute(top, topLevelValues())
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+build[ ]+mix500") && has(t, "drive_picker[^\\n]*mix500") && has(t, "click[ ]+\"Start indexing\""), "s2_mix_on_top does not build mix500, pick it in Settings and press Start indexing")
        ok(has(launch, "s2_unread[^\\n]*-before") && has(launch, "s2_unread[^\\n]*-after"), "launches B and C do not read the unread rows before the first and after the last measurement")
        ok(has(substitute(check, topLevelValues()), "s2_still_indexing"), "S2.11 does not check that indexing was still running at both ends")
        let c = substitute(check + "\n" + (all["s2_still_indexing"] ?? "") + "\n" + (all["s2_unread"] ?? ""), topLevelValues())
        ok(has(c, "s2_state[^\\n]* 4"), "S2.11 does not make a mix that is already read a RERUN (status 4)")
        ok(has(c, "kit-index\\.sh\"?[ ]+status") && has(c, "pending") && has(c, "partial"), "S2.11 does not read the index status for pending or partial rows")
        ok(has(c, "Indexing"), "S2.11 does not read that the menu bar says Indexing")
    }
}

// MARK: kit-readback.sh frame-check, on pictures this test draws

private struct Rig {
    let base: String
    var kit: String { base + "/sesame-kit-fc" }
    var tmp: String { base + "/tmp" }
    var env: [String: String] { ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": base + "/home"] }
}

private func makeRig() throws -> Rig {
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-fc-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let rig = Rig(base: made.resolvingSymlinksInPath().path)
    for dir in [rig.kit + "/run", rig.tmp, rig.base + "/home"] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    return rig
}

private func ffmpegPath() -> String? {
    for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: p) { return p }
    return nil
}

/// A 24 s clip: ten seconds of the test card, fourteen of a Mandelbrot zoom (two different pictures with their own structure), 160 x 120.
private func makeClip(_ rig: Rig) throws -> String? {
    guard let ff = ffmpegPath() else { return nil }
    let out = rig.tmp + "/clip.mp4"
    let r = try run(ff, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=5:duration=10", "-f", "lavfi", "-i", "mandelbrot=size=160x120:rate=5",
                         "-filter_complex", "[1:v]trim=duration=14,setpts=PTS-STARTPTS[b];[0:v][b]concat=n=2:v=1:a=0,format=yuv420p", "-c:v", "libx264", "-t", "24", out])
    return r.status == 0 ? out : nil
}

/// The frame of the clip at a second, written by ffmpeg (the test's own reader of the frames).
private func frame(_ rig: Rig, clip: String, second: Int, name: String) throws -> String? {
    guard let ff = ffmpegPath() else { return nil }
    let out = rig.tmp + "/" + name
    let r = try run(ff, ["-nostdin", "-v", "error", "-y", "-ss", String(second), "-i", clip, "-frames:v", "1", out])
    return r.status == 0 ? out : nil
}

/// A pane picture: a grey canvas with a rule and some text-like bars, and the frame (when given) pasted at 2x at a place.
private func paneShot(_ rig: Rig, name: String, frame framePath: String?) throws -> String {
    let w = 640, h = 420
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
    for i in 0..<6 { ctx.fill(CGRect(x: 30, y: 20 + i * 14, width: 120 + (i * 37) % 90, height: 5)) }
    if let framePath, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: framePath) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        ctx.draw(img, in: CGRect(x: 250, y: 150, width: 320, height: 240))
    }
    let path = rig.tmp + "/" + name
    guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "pane", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "pane", code: 2) }
    return path
}

@Suite("KitReadbackFrameCheckTests", .serialized)
struct KitReadbackFrameCheckTests {

    private func frameCheck(_ rig: Rig, _ args: [String]) throws -> Ran {
        try run("/bin/bash", [readbackScript, "frame-check"] + args, env: rig.env, limit: 600)
    }

    @Test("kit-readback.sh names frame-check in its usage")
    func usageNamesIt() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(atPath: rig.base) }
        let u = try run("/bin/bash", [readbackScript, "no-such-mode"], env: rig.env)
        ok(u.status == 2 && u.output.contains("kit-readback.sh frame-check <pane-shot> <video> <second>"), "the usage lacks `kit-readback.sh frame-check <pane-shot> <video> <second>`:\n\(u.output)")
    }

    @Test("frame-check passes on the pane picture that holds the frame of the stated second, fails on the picture that holds the frame 20 s earlier, and on a picture with no frame; it writes compare-s4-frame.txt")
    func rightAndWrong() throws {
        guard ffmpegPath() != nil else { Issue.record("ffmpeg is not installed: the frames cannot be made"); return }
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(atPath: rig.base) }
        guard let clip = try makeClip(rig), let now = try frame(rig, clip: clip, second: 22, name: "now.png"), let earlier = try frame(rig, clip: clip, second: 2, name: "earlier.png") else {
            Issue.record("the test clip or its frames could not be made")
            return
        }
        let right = try paneShot(rig, name: "right.png", frame: now)
        let ran = try frameCheck(rig, [right, clip, "22"])
        ok(ran.status == 0, "the picture of the frame at 22 s: exit \(ran.status):\n\(ran.output)")
        ok(ran.output.split(separator: "\n").contains { $0.hasPrefix("frame now ") } && ran.output.split(separator: "\n").contains { $0.hasPrefix("frame earlier ") }, "no `frame now` and `frame earlier` lines:\n\(ran.output)")
        let file = (try? String(contentsOfFile: rig.kit + "/run/compare-s4-frame.txt", encoding: .utf8)) ?? ""
        ok(file.contains("frame now"), "compare-s4-frame.txt does not hold the readings:\n\(file)")
        let wrong = try paneShot(rig, name: "wrong.png", frame: earlier)
        ok(try frameCheck(rig, [wrong, clip, "22"]).status == 1, "the picture of the frame 20 s earlier passed")
        let none = try paneShot(rig, name: "none.png", frame: nil)
        ok(try frameCheck(rig, [none, clip, "22"]).status == 1, "a picture with no frame passed")
    }

    @Test("frame-check: a shot that is not a picture or does not exist is exit 4 (never a pass), a missing video is exit 1, bad arguments exit 2")
    func inputs() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(atPath: rig.base) }
        try "not a picture".write(toFile: rig.base + "/shot.png", atomically: true, encoding: .utf8)
        try "not a video either".write(toFile: rig.base + "/some.mp4", atomically: true, encoding: .utf8)
        ok(try frameCheck(rig, [rig.base + "/shot.png", rig.base + "/some.mp4", "22"]).status == 4, "a shot that is not a picture is not exit 4")
        ok(try frameCheck(rig, [rig.base + "/missing.png", rig.base + "/some.mp4", "22"]).status == 4, "a missing shot is not exit 4")
        let png = try paneShot(rig, name: "pane.png", frame: nil)
        ok(try frameCheck(rig, [png, rig.base + "/none.mp4", "22"]).status == 1, "a missing video is not exit 1")
        ok(try frameCheck(rig, [png, rig.base + "/some.mp4", "22"]).status == 1, "a file that is no video is not exit 1")
        ok(try frameCheck(rig, [png, rig.base + "/none.mp4"]).status == 2, "two arguments are not exit 2")
        ok(try frameCheck(rig, [png, rig.base + "/none.mp4", "abc"]).status == 2, "a second that is not a number is not exit 2")
    }
}
