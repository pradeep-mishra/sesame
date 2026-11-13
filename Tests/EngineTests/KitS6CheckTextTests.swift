import Foundation
import Testing

// plan-2 fix round C, part C1, items C1-4 (R2-07, R2-08), C1-5 (R2-09) and C1-6 (R2-10, R2-11), tester step: the S6 and S7.9
// checks follow the product of fix round B.
//   C1-4  S6.1: setup shows the step names Welcome, Folders, Permissions, Shortcut ("Step n of 4: <Name>"); Finish without Start
//         and a relaunch show no setup; the picked folders persist as pending ticks and Settings lists them as "Waiting for
//         Start indexing". S6.8: finish setup with the picks, open Settings, select Indexing, press Start indexing, and the
//         trace must show reads after Start (RERUN when it sees none, FAIL when `wait started` never fires, as built).
//   C1-6  S6.4 and S6.11 read the line "About <time> in total" as the estimate total (never a row's estimate); the comparison
//         with the real time uses that total. S7.9 removes a folder by pressing the
//         Remove of the row whose help is the folder's name, then the confirm "Remove folder", and waits for its rows to go.
// Written from the fix-round documents (C and B), the report of fix round B (the strings), the product strings of
// SetupScreenTests and SettingsScreenTests (copied by hand as the samples below), and the existing kit scripts. No kit script is
// run: the readers the checks use are run in a `bash -c` with the scripts they call replaced by functions, on hand-written dumps.
//
// THE DUMP FORMAT IS A GUESS until the accept stage (see KitAxHelpTests): `desc=` holds "<name>, <counts>, <estimate>", `help=`
// the full path.
//
// WHAT WOULD MAKE EACH CHECK FAIL ON A BROKEN PRODUCT (the plants, each a test below):
//   S6.2/S6.3/S6.10 row counts: a row that shows 6 photos where the folder holds 5 -> "photo shows 6, expected 5"; a row with no
//     time -> "shows no time estimate"; no row -> "lists no row".
//   S6.4: a row that does not read exactly "after the model download" while the model is not whole; no "About <time> in total"
//     line once it is whole.
//   S6.11: no total line -> FAIL "no total"; a row's estimate is never taken for it.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func bash(_ script: String, limit: TimeInterval = 60) throws -> Ran {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
    let out = tmp.appendingPathComponent("kits6-out-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    defer { try? fm.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["KIT_ROOT"] = tmp.appendingPathComponent("sesame-kit-s6test-" + UUID().uuidString).path
    environment["KIT_NO_EVIDENCE"] = "1"
    environment.removeValue(forKey: "KIT_PLANT")
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

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func stripComments(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private func has(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func lines(_ ran: Ran) -> [String] {
    ran.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func shellFunctions(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if let r = line.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{( #.*)?$", options: .regularExpression) {
                name = String(line[r].split(separator: "(")[0])
                body = []
            } else if let r = line.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{ .* \\}$", options: .regularExpression) {
                result[String(line[r].split(separator: "(")[0])] = line
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

private func fn(_ name: String, in file: String) -> String {
    shellFunctions(in: read(libDir.appendingPathComponent(file)).map(stripComments) ?? "")[name] ?? ""
}

private func index(of pattern: String, in text: String, after: Int = 0) -> Int? {
    guard let start = text.index(text.startIndex, offsetBy: after, limitedBy: text.endIndex),
          let r = text.range(of: pattern, options: .regularExpression, range: start..<text.endIndex) else { return nil }
    return text.distance(from: text.startIndex, to: r.lowerBound)
}

/// Commit 080db8e: the status item's "Settings…" is pressed by `s6_press "$S6_AX" "Settings…"` (the same click, with kit-ax's
/// failure output printed), not by a bare `click "Settings…"`. The order pins of S6.1 and S6.8 use this pattern in its place.
private let settingsPress = "s6_press[ ]+\"\\$S6_AX\"[ ]+\"Settings…\""

/// The patterns, in order: each must be found after the one before.
private func inOrder(_ text: String, _ patterns: [String], _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    var from = 0
    for p in patterns {
        guard let at = index(of: p, in: text, after: from) else {
            ok(false, "\(what): `\(p)` is missing, or comes before `\(patterns[max(0, (patterns.firstIndex(of: p) ?? 1) - 1)])`", sourceLocation: sourceLocation)
            return
        }
        from = at + 1
    }
}

// MARK: the samples (strings of SetupScreen and SettingsScreen, by hand)

private let sb = "/private/var/folders/xx/sesame-kit/home"

private func setupDump(note: Bool = false, switchOn: Bool = false, codeEnabled: Bool = false, codeTicked: Bool = false, total: String? = "About 5 min in total",
                       speed: String? = "Photos: about 3 s each", code: Bool = true) -> String {
    var s = """
    window 560 x 600 at 120,80 title Set up Sesame
    AXWindow/AXStandardWindow label="Set up Sesame"
      AXGroup
        AXStaticText label="Step 2 of 4: Folders"
        AXStaticText label="Folders to read"
        AXStaticText label="11 files in the ticked folders."

    """
    if let total { s += "    AXStaticText label=\"\(total)\"\n" }
    if let speed { s += "    AXStaticText label=\"\(speed)\"\n" }
    s += """
        AXScrollArea label="Folders"
          AXGroup
            AXCheckBox label="Desktop" desc="Desktop, 5 photos, about 1 min" help="\(sb)/Desktop" value="1"
            AXCheckBox label="Documents" desc="Documents, 6 photos, 2 PDFs, about 2 min" help="\(sb)/Documents" value="1"

    """
    if code {
        s += "        AXStaticText label=\"Code folders\"\n"
        if note { s += "        AXStaticText label=\"Tick a folder to read its code.\"\n" }
        s += "        AXCheckBox label=\"atlas-notes\" desc=\"atlas-notes, code folder\" help=\"\(sb)/Developer/atlas-notes\" value=\"\(codeTicked ? 1 : 0)\"\(codeEnabled ? "" : " [disabled]")\n"
    }
    // plan-6-t10 AMENDMENT: the read note above the code switch; it read "Only photos are read in this version." until all kinds were read (D13)
    s += "    AXStaticText label=\"Photos, PDFs, documents, audio and video are read. Code is read only in the folders you tick under Search my code.\"\n"
    s += "    AXCheckBox label=\"Search my code\" value=\"\(switchOn ? 1 : 0)\"\n"
    s += "    AXButton label=\"Add folder…\"\n    AXButton label=\"Start indexing\"\n"
    return s
}

private func footerDump(step: String = "Step 2 of 4: Folders", buttons: [String], disabled: Set<String> = [], ticked: Bool = true) -> String {
    var s = "window 560 x 600 at 120,80 title Set up Sesame\nAXWindow/AXStandardWindow label=\"Set up Sesame\"\n  AXGroup\n    AXStaticText label=\"\(step)\"\n"
    if step.contains("Folders") {
        s += "    AXCheckBox label=\"Desktop\" desc=\"Desktop, 5 photos, about 1 min\" help=\"\(sb)/Desktop\" value=\"\(ticked ? 1 : 0)\"\n"
        s += "    AXButton label=\"Add folder…\"\n"
    }
    for b in buttons { s += "    AXButton label=\"\(b)\"\(disabled.contains(b) ? " [disabled]" : "")\n" }
    return s
}

private let settingsFoldersDump = """
window 700 x 480 at 100,100 title Settings
AXWindow/AXStandardWindow label="Settings"
  AXGroup
    AXButton label="Folders" value="1"
    AXGroup
      AXCheckBox label="extra" desc="extra, 4 photos, Waiting for Start indexing" help="/Users/x/fixtures/extra" value="1"
      AXButton label="Re-index" help="extra"
      AXButton label="Remove" help="extra"
      AXCheckBox label="photos" desc="photos, 40 photos, about 2 min" help="/Users/x/fixtures/golden/photos" value="1"
      AXButton label="Re-index" help="photos"
      AXButton label="Remove" help="photos"

"""

// MARK: the readers, run on samples

@Suite("KitS6CheckTextTests")
struct KitS6CheckTextTests {
    private let common = libDir.appendingPathComponent("common.sh").path
    private let recipes = libDir.appendingPathComponent("recipes.sh").path
    private let s6 = libDir.appendingPathComponent("checks-s6.sh").path
    private let s6b = libDir.appendingPathComponent("checks-s6b.sh").path

    /// A shell with the kit's S6 readers sourced and `body` run on the dump in S6_DUMP. Nothing but shell functions runs.
    private func reader(dump: String, body: String, expected: String = "photo 5") throws -> Ran {
        let fm = FileManager.default
        let sample = fm.temporaryDirectory.appendingPathComponent("kits6-dump-" + UUID().uuidString)
        try Data(dump.utf8).write(to: sample)
        defer { try? fm.removeItem(at: sample) }
        let script = """
        . "\(common)"
        . "\(recipes)"
        . "\(s6)"
        . "\(s6b)"
        s6b_expected() { printf '%b\\n' "\(expected)"; }
        S6_DUMP="$(cat "\(sample.path)")"
        S6_WHY=""
        \(body)
        """
        return try bash(script)
    }

    // MARK: the row readers (S6.2, S6.3, S6.10)

    @Test("s6b_row_counts: a row that shows the counts of expect counts and a time is clean")
    func rowCountsClean() throws {
        let ran = try reader(dump: setupDump(), body: "s6b_row_counts S6.2 folder Desktop /x/Desktop; echo \"WHY[$S6_WHY]\"")
        #expect(lines(ran).contains("WHY[]"), "a correct row was refused: \(lines(ran))")
        let two = try reader(dump: setupDump(), body: "s6b_row_counts S6.2 folder Documents /x/Documents; echo \"WHY[$S6_WHY]\"", expected: "photo 6\\npdf 2")
        #expect(lines(two).contains("WHY[]"), "a row with photos and PDFs was refused: \(lines(two))")
    }

    // PLANT: the row shows 5 photos where the folder holds 6.
    @Test("s6b_row_counts names a count that differs from expect counts")
    func rowCountsDiffer() throws {
        let ran = try reader(dump: setupDump(), body: "s6b_row_counts S6.2 folder Desktop /x/Desktop; echo \"WHY[$S6_WHY]\"", expected: "photo 6")
        #expect(lines(ran).contains { $0.hasPrefix("WHY[") && $0.contains("photo shows 5, expected 6") }, "no reason names the difference: \(lines(ran))")
        let extraKind = try reader(dump: setupDump(), body: "s6b_row_counts S6.2 folder Desktop /x/Desktop; echo \"WHY[$S6_WHY]\"", expected: "photo 5\\npdf 1")
        #expect(lines(extraKind).contains { $0.contains("pdf shows 0, expected 1") }, "a missing kind was not named: \(lines(extraKind))")
    }

    @Test("s6b_row_counts: no row, or a row with no time, is a reason")
    func rowCountsMissing() throws {
        let noRow = try reader(dump: setupDump(), body: "s6b_row_counts S6.2 folder Downloads /x/Downloads; echo \"WHY[$S6_WHY]\"")
        #expect(lines(noRow).contains { $0.hasPrefix("WHY[") && $0.contains("lists no row for Downloads") }, "\(lines(noRow))")
        let noTime = setupDump().replacingOccurrences(of: "Desktop, 5 photos, about 1 min", with: "Desktop, 5 photos")
        let ran = try reader(dump: noTime, body: "s6b_row_counts S6.2 folder Desktop /x/Desktop; echo \"WHY[$S6_WHY]\"")
        #expect(lines(ran).contains { $0.contains("Desktop shows no time estimate") }, "\(lines(ran))")
        let bare = setupDump().replacingOccurrences(of: " desc=\"Desktop, 5 photos, about 1 min\"", with: "")
        let none = try reader(dump: bare, body: "s6b_row_counts S6.2 folder Desktop /x/Desktop; echo \"WHY[$S6_WHY]\"")
        #expect(lines(none).contains { $0.contains("photo shows 0, expected 5") && $0.contains("shows no time estimate") }, "a row with no label detail passed: \(lines(none))")
    }

    // The digits of a folder's name are not a count.
    @Test("s6b_row_counts reads the counts after the folder's name, so a folder named \"10 photos, 2024\" shows its own 3")
    func rowCountsNameWithDigits() throws {
        let dump = """
        window 560 x 600 at 0,0 title Set up Sesame
        AXWindow label="Set up Sesame"
          AXCheckBox label="10 photos, 2024" desc="10 photos, 2024, 3 photos, about 1 min" help="/Users/x/10 photos, 2024" value="1"
        """
        let ran = try reader(dump: dump, body: "s6b_row_counts S6.2 folder '10 photos, 2024' /x/p; echo \"WHY[$S6_WHY]\"", expected: "photo 3")
        #expect(lines(ran).contains("WHY[]"), "the digits of the name were read as a count: \(lines(ran))")
    }

    @Test("s6b_ticked reads the tick of the row itself")
    func tickedFirstLineOnly() throws {
        let ran = try reader(dump: setupDump(), body: "s6b_ticked \"$(s6b_block Desktop)\" && echo desktop-on || echo desktop-off")
        #expect(lines(ran).contains("desktop-on"), "Desktop is ticked: \(lines(ran))")
        let dump = setupDump().replacingOccurrences(of: "label=\"Desktop\" desc=\"Desktop, 5 photos, about 1 min\" help=\"\(sb)/Desktop\" value=\"1\"", with: "label=\"Desktop\" desc=\"Desktop, 5 photos, about 1 min\" help=\"\(sb)/Desktop\" value=\"0\"")
        let off = try reader(dump: dump, body: "s6b_ticked \"$(s6b_block Desktop)\" && echo desktop-on || echo desktop-off")
        #expect(lines(off).contains("desktop-off"), "an unticked row read as ticked: \(lines(off))")
    }

    @Test("s6b_waiting_in recognises \"Waiting for Start indexing\" and nothing else")
    func waitingText() throws {
        let ran = try reader(dump: setupDump(), body: """
        s6b_waiting_in "4 photos, Waiting for Start indexing" && echo yes || echo no
        s6b_waiting_in "4 photos, about 1 min" && echo yes || echo no
        s6b_waiting_in "not read" && echo yes || echo no
        """)
        #expect(lines(ran) == ["yes", "no", "no"], "\(lines(ran))")
    }

    // MARK: the estimate total and the speed note (C1-6)

    @Test("s6b_estimate_seconds is the \"About <time> in total\" line, never a row's own estimate")
    func estimateSeconds() throws {
        for (total, seconds) in [("About 5 min in total", "300"), ("About 2 h 10 min in total", "7800"), ("Under a minute in total", "30")] {
            let ran = try reader(dump: setupDump(total: total), body: "s6b_estimate_seconds")
            #expect(lines(ran) == [seconds], "\"\(total)\": \(lines(ran))")
        }
        // PLANT: no total line. The rows still say "about 1 min" and "about 2 min": none of them is the total.
        let none = try reader(dump: setupDump(total: nil), body: "s6b_estimate_seconds")
        #expect(lines(none).isEmpty, "a row's estimate was taken for the total: \(lines(none))")
    }

    @Test("s6b_speed_note is the number of \"Photos: about <n> s each\"")
    func speedNote() throws {
        let three = try reader(dump: setupDump(), body: "s6b_speed_note")
        #expect(lines(three) == ["3"], "\(lines(three))")
        let none = try reader(dump: setupDump(speed: nil), body: "s6b_speed_note")
        #expect(lines(none).isEmpty, "a note that is not there was read: \(lines(none))")
    }

    // MARK: the checks' text

    @Test("S6.1 follows the product: step names as \"Step n of 4: <Name>\", a pick, Finish without Start, a relaunch, and the pick waiting in Settings")
    func s61() {
        let body = fn("s6_check_1", in: "checks-s6b.sh")
        ok(!body.isEmpty, "checks-s6b.sh has no s6_check_1")
        ok(has(body, "Step[^\\n]*of 4: "), "S6.1 does not read the step header \"Step n of 4: <Name>\" (the product draws the names there)")
        ok(body.contains("Welcome Folders Permissions Shortcut"), "S6.1 lost the four step names")
        ok(body.contains("Wellcome Folders Permissions Shortcut"), "the S6.1 plant (a wrong step name) is gone")
        inOrder(body, ["pick_folders[ ]+extra", "click \"Finish\"", "relaunch", "s6b_pending_row"], "S6.1 order: pick, Finish, relaunch, then the pick read in Settings")
        ok(!has(body, "click \"Start indexing\""), "S6.1 presses Start indexing: it must finish setup WITHOUT Start")
        ok(has(body, "setup is shown again|still shown"), "S6.1 no longer says the setup must not come back")
        // the Settings read: the status item's Settings…, the Folders section, the row of the folder, ticked and waiting
        let pending = fn("s6b_pending_row", in: "checks-s6b.sh")
        ok(!pending.isEmpty, "checks-s6b.sh has no s6b_pending_row")
        inOrder(pending, [settingsPress, "settings_section[ ]+Folders", "ax_row", "s6b_waiting_in"], "s6b_pending_row order: Settings…, the Folders section, the row, the waiting text")
        ok(pending.contains("Waiting for Start indexing"), "s6b_pending_row never names the text \"Waiting for Start indexing\"")
    }

    @Test("S6.4 reads each row's estimate exactly and, once the model is whole, the total line; it no longer reads the speed note the person removed")
    func s64() {
        let body = fn("s6_check_4", in: "checks-s6b.sh")
        ok(!body.isEmpty, "checks-s6b.sh has no s6_check_4")
        ok(body.contains("after the model download"), "S6.4 lost the text \"after the model download\"")
        ok(body.contains("after the model downloads"), "the S6.4 plant is gone")
        ok(has(body, "ax_row_estimate"), "S6.4 does not read a row's estimate through ax_row_estimate (exactly, not as a word anywhere in the dump)")
        ok(has(body, "s6b_estimate_seconds"), "S6.4 never reads the total (\"About <time> in total\")")
        ok(!has(body, "s6b_speed_note"), "S6.4 still calls s6b_speed_note: the line \"Photos: about <n> s each\" is off the screen (guide 11.1), so waiting for it never ends")
        ok(!body.contains("Photos: about"), "S6.4 still names the removed line \"Photos: about <n> s each\" in a wait, a failure or its done text")
        ok(!body.contains("per-photo note"), "S6.4 still speaks of a per-photo note")
        ok(!body.contains("N s per photo"), "S6.4 still looks for the old note \"N s per photo\", which the product does not write")
    }

    @Test("S6.4 keeps its not-whole rule and its whole rule, and the S6.4 and S6.11 plants, after the speed note is dropped")
    func s64KeepsEverythingElse() {
        let body = fn("s6_check_4", in: "checks-s6b.sh")
        ok(has(body, "\\[ \"\\$est\" = \"\\$want\" \\] \\|\\| s6_why"), "S6.4 lost the exact-text check of a row while the model is not whole")
        ok(has(body, "s6b_time_number \"\\$\\(s6b_detail \"\\$f\"\\)\" && s6_why"), "S6.4 lost the check that no number shows while the model is not whole")
        ok(has(body, "\\[ -z \"\\$\\(s6b_estimate_seconds\\)\" \\] \\|\\| s6_why"), "S6.4 lost the check that no total line shows while the model is not whole")
        ok(has(body, "s6b_final_time \"\\$f\" \"\\$p\" \\|\\| ok_all=0"), "S6.4 lost the whole rule: every folder shows a time or \"nothing to read\"")
        ok(has(body, "\\[ -n \"\\$\\(s6b_estimate_seconds\\)\" \\] \\|\\| ok_all=0"), "S6.4 no longer waits for the total line once the model is whole")
        ok(has(body, "no line \\\\\"About <time> in total\\\\\" once the model is whole"), "S6.4 lost its failure for a missing total line once the model is whole")
        ok(has(body, "KIT_PLANT[^\\n]*want=\"after the model downloads\""), "the S6.4 plant no longer expects the text with an s")
        let eleven = fn("s6_check_11", in: "checks-s6b.sh")
        ok(has(eleven, "KIT_PLANT[^\\n]*S6_SKEW=3"), "the S6.11 plant no longer skews the estimate three times")
        ok(has(eleven, "est=\\$\\(\\(est \\* S6_SKEW\\)\\)"), "S6.11 no longer applies the skew to the estimate")
    }

    @Test("A Folders dump with no speed line, as guide 11 draws it, still gives the total and each row's estimate")
    func foldersDumpWithNoSpeedLine() throws {
        let dump = setupDump(speed: nil)
        let total = try reader(dump: dump, body: "s6b_estimate_seconds")
        #expect(lines(total) == ["300"], "the total line was not read from a dump with no speed line: \(lines(total))")
        let estimate = try reader(dump: dump, body: "printf '%s\\n' \"$S6_DUMP\" | ax_row_estimate Desktop; printf '%s\\n' \"$S6_DUMP\" | ax_row_estimate Documents")
        #expect(lines(estimate) == ["about 1 min", "about 2 min"], "a row's estimate was not read from its label: \(lines(estimate))")
        let final = try reader(dump: dump, body: "s6b_final_time Desktop 5 && echo final || echo not-final")
        #expect(lines(final).contains("final"), "S6.4's final-time reader refused a row with a time: \(lines(final))")
        let fresh = try reader(dump: setupDump(total: nil, speed: nil), body: "s6b_estimate_seconds; echo END")
        #expect(lines(fresh) == ["END"], "a dump with neither total nor speed line gave a total: \(lines(fresh))")
    }

    @Test("S6.8: Finish with the picks, Settings, the Indexing section, Start indexing, then the trace after Start; RERUN with no read, FAIL with no start")
    func s68() {
        let body = fn("s6_check_8", in: "checks-s6b.sh")
        ok(!body.isEmpty, "checks-s6b.sh has no s6_check_8")
        inOrder(body, ["click \"Finish\"", settingsPress, "settings_section[ ]+Indexing", "click \"Start indexing\"", "wait started 120"],
                "S6.8 order after the picks")
        ok(body.contains("RERUN S6.8 not valid: the positive control failed"), "S6.8 lost the RERUN when the trace sees no read after Start")
        ok(body.contains("no file was read within 120 s of Start indexing"), "S6.8 lost the FAIL when `wait started` never fires")
    }

    @Test("S6.11 takes the total from \"About <time> in total\", no longer reads the speed note the person removed, and presses Start in the setup window through press_start")
    func s611() {
        let body = fn("s6_check_11", in: "checks-s6b.sh")
        ok(!body.isEmpty, "checks-s6b.sh has no s6_check_11")
        ok(has(body, "s6b_estimate_seconds"), "S6.11 does not take the estimate from the total line")
        ok(!has(body, "s6b_speed_note"), "S6.11 still calls s6b_speed_note: the line \"Photos: about <n> s each\" is off the screen (guide 11.1)")
        ok(!body.contains("Photos: about"), "S6.11 still names the removed line \"Photos: about <n> s each\" in a reason or in its echo")
        ok(!body.contains("per-photo note"), "S6.11 still speaks of a per-photo note in its echo")
        ok(body.contains("shows no total"), "S6.11 lost its failure for a missing total line")
        ok(has(body, "press_start"), "S6.11 does not press Start through press_start")
        ok(has(body, "estimate-check"), "S6.11 no longer compares with the real time (`kit-index.sh estimate-check`)")
        let est = fn("s6b_estimate_seconds", in: "checks-s6b.sh")
        ok(has(est, "ax_total_seconds") || has(est, "in total"), "s6b_estimate_seconds does not read the total line")
        ok(!est.contains("under a minute|about"), "s6b_estimate_seconds still takes the last time text of the dump, a row's estimate")
    }

    @Test("S6.10 accepts a row of Settings that waits for Start, and presses Indexing before Start indexing")
    func s610() {
        let within = fn("s6b_row_within", in: "checks-s6b.sh")
        ok(has(within, "s6b_waiting_in"), "s6b_row_within does not accept \"Waiting for Start indexing\" for a row of Settings")
        let body = fn("s6_check_10", in: "checks-s6b.sh")
        inOrder(body, ["s6b_row_within[^\\n]*\\(iii\\)", "settings_section[ ]+Indexing", "click \"Start indexing\""], "S6.10 order: (iii), then the Indexing section, then Start indexing")
    }

    @Test("S7.9 presses the more button of the row of extra, then the open menu's Remove, then the confirm \"Remove folder\", and waits for its rows")
    func s79() {
        let body = fn("s7_check_9", in: "checks-s7.sh")
        ok(!body.isEmpty, "checks-s7.sh has no s7_check_9")
        inOrder(body, ["settings_section[ ]+Folders", "click \"More actions for extra\"", "click \"Remove\"", "click \"Remove folder\"", "s7_wait_has[^\\n]*absent", "s7_rows_under extra"],
                "S7.9 order: the Folders section, the more button of the row of extra, its menu's Remove, the confirm, the file gone, the rows gone")
        ok(has(body, "click \"More actions for extra\"[^\\n]*\\|\\|[^\\n]*s7_why"), "S7.9 does not treat a more button it could not press as a failure")
        ok(has(body, "click \"Remove\"[^\\n]*\\|\\|[^\\n]*s7_why"), "S7.9 does not treat a Remove item of the open menu it could not press as a failure")
        ok(has(body, "click \"Remove folder\"[^\\n]*\\|\\|[^\\n]*s7_why"), "S7.9 does not treat a confirm it could not press as a failure")
        ok(!has(body, "click --help"), "S7.9 still selects a Remove by help text, which the open menu's items do not carry")
        ok(shellFunctionsDefined("checks-s7.sh")["s7_remove_label"] == nil, "s7_remove_label (the reader that gave the first Remove of the window) is still defined")
        ok(body.contains("30"), "S7.9 lost its 30 s for the rows to go")
    }

    private func pressedOn(_ dump: String) throws -> [String] {
        lines(try reader(dump: dump, body: "s6_dump() { return 0; }\ns6_press() { echo \"pressed $2\"; }\ns6b_forward; echo \"status $?\""))
    }

    @Test("the S6 walkers press Next, or Not now when the Folders footer reads Start indexing, and never press Start indexing")
    func forwardPressesNextOrNotNow() throws {
        let whole = footerDump(buttons: ["Back", "Start indexing", "Not now"])
        #expect(try pressedOn(whole) == ["pressed Not now", "status 0"], "a Folders step with a whole model (footer Start indexing, Not now, no Next) is left by Not now")
        let noTick = footerDump(buttons: ["Back", "Start indexing", "Not now"], disabled: ["Start indexing"], ticked: false)
        #expect(try pressedOn(noTick) == ["pressed Not now", "status 0"], "a Folders step with no row ticked is left by Not now too")
        let notWhole = footerDump(buttons: ["Back", "Next"])
        #expect(try pressedOn(notWhole) == ["pressed Next", "status 0"], "a Folders step with a model that is not whole is left by Next")
        let welcome = footerDump(step: "Step 1 of 4: Welcome", buttons: ["Next"])
        #expect(try pressedOn(welcome) == ["pressed Next", "status 0"], "Welcome is left by Next")
        let permissions = footerDump(step: "Step 3 of 4: Permissions", buttons: ["Back", "Next"])
        #expect(try pressedOn(permissions) == ["pressed Next", "status 0"], "Permissions is left by Next")
        let walker = fn("s6b_forward", in: "checks-s6b.sh")
        ok(!walker.isEmpty, "checks-s6b.sh has no s6b_forward")
        ok(!walker.contains("Start indexing"), "the walker names Start indexing: it must never press it")
    }

    @Test("a walker that gets a dump with Next and a stray Not now still presses Next, and a failing press is a failing walker")
    func forwardPrefersNextAndReportsAFailedPress() throws {
        let both = footerDump(buttons: ["Back", "Next", "Not now"])
        #expect(try pressedOn(both) == ["pressed Next", "status 0"], "Next comes first")
        let failing = try reader(dump: footerDump(buttons: ["Next"]), body: "s6_dump() { return 0; }\ns6_press() { return 1; }\ns6b_forward; echo \"status $?\"")
        #expect(lines(failing) == ["status 1"], "a press that failed was reported as worked: \(lines(failing))")
    }

    @Test("S6.1 walks Welcome, Folders, Permissions and Shortcut through s6b_forward, so the Folders step is left by Next or Not now, and never presses Start indexing")
    func s61WalksFoldersByNextOrNotNow() {
        let body = fn("s6_check_1", in: "checks-s6b.sh")
        ok(has(body, "s6b_forward \\|\\|"), "S6.1 does not leave the steps through s6b_forward")
        ok(!has(body, "click \"Start indexing\""), "S6.1 presses Start indexing")
        ok(body.contains("Finish (Start indexing not pressed)"), "S6.1 lost its text Finish (Start indexing not pressed)")
        ok(body.contains("Wellcome Folders Permissions Shortcut"), "the S6.1 plant is gone")
    }

    @Test("S6.8 walks the setup through s6b_forward, never presses Start indexing in it, and still proves 0 reads, an empty index and startPressed not true")
    func s68WalksFoldersByNextOrNotNow() {
        let body = fn("s6_check_8", in: "checks-s6b.sh")
        inOrder(body, ["pick_folders[ ]+extra", "s6_wait_whole", "s6b_forward", "click \"Finish\"", "sleep 120", "click \"Start indexing\""],
                "S6.8 order: the pick, the model whole, the walk by s6b_forward, Finish, 120 s, and Start only in Settings at the end")
        ok(!body.contains("\\\"Next\\\" before $step"), "S6.8 still presses a bare Next before Permissions")
        ok(body.contains("startPressed is true before Start indexing was pressed"), "S6.8 lost its startPressed failure")
        ok(body.contains("the index holds"), "S6.8 lost its empty-index failure")
        ok(body.contains("regular-file opens by Sesame or its helpers"), "S6.8 lost its zero-opens failure")
        ok(body.contains("KIT_PLANT") && body.contains("S6_SKEW=1"), "the S6.8 plant is gone")
        let starts = body.components(separatedBy: "click \"Start indexing\"").count - 1
        #expect(starts == 1, "S6.8 presses Start indexing \(starts) times; the one press is the positive control in Settings")
    }

    @Test("S6.7 reads the Folders footer: Start indexing disabled or absent passes, enabled fails, and a window that is not the Folders step is unread and fails")
    func s67StartDisabledOrAbsent() throws {
        func state(_ dump: String) throws -> String {
            lines(try reader(dump: dump, body: "s6_start_read; s6_start_read | { read -r s; s6_start_failed_ok \"$s\" && echo accepted || echo refused; }")).joined(separator: " ")
        }
        #expect(try state(footerDump(buttons: ["Back", "Next"])) == "absent accepted", "a failed model: the footer reads Next, Start indexing is absent, which the spec allows")
        #expect(try state(footerDump(buttons: ["Back", "Start indexing", "Not now"], disabled: ["Start indexing"], ticked: false)) == "disabled accepted", "Start indexing disabled is accepted")
        #expect(try state(footerDump(buttons: ["Back", "Start indexing", "Not now"])) == "enabled refused", "Start indexing enabled while the download has failed fails the check")
        #expect(try state(footerDump(step: "Step 1 of 4: Welcome", buttons: ["Next"])) == "unread refused", "the Welcome step is not the Folders step: nothing was read, and nothing passes")
        #expect(try state("") == "unread refused", "an empty dump (the window did not answer) is unread and fails")
    }

    @Test("s6_ticked_rows counts the ticked rows of the Folders step, so a failure of S6.7 step 5 says whether a row was ticked")
    func tickedRows() throws {
        let one = try reader(dump: footerDump(buttons: ["Back", "Next"]), body: "s6_ticked_rows")
        #expect(lines(one) == ["1"], "\(lines(one))")
        let none = try reader(dump: footerDump(buttons: ["Back", "Next"], ticked: false), body: "s6_ticked_rows")
        #expect(lines(none) == ["0"], "\(lines(none))")
    }

    @Test("S6.7 starts from the recipe setup (the five suggested folders exist and are ticked), accepts disabled or absent, reads the footer only on Folders and keeps its plant")
    func s67Text() {
        let body = fn("s6_check_7", in: "checks-s6.sh")
        ok(!body.isEmpty, "checks-s6.sh has no s6_check_7")
        ok(has(body, "s6b_state S6\\.7"), "S6.7 does not start from the recipe setup, so a ticked row cannot be counted on")
        ok(has(body, "s6_start_failed_ok \"\\$st\""), "S6.7 does not accept disabled or absent through s6_start_failed_ok")
        ok(!has(body, "\\[ \"\\$st\" = disabled \\]"), "S6.7 still requires exactly disabled")
        ok(has(body, "st=\"\\$\\(s6_start_read\\)\""), "S6.7 reads the footer through s6_start_read (unread when the window is not the Folders step)")
        ok(has(body, "st=unread"), "S6.7 reads a Start state when the press of Next failed: that must be unread, never absent")
        ok(has(body, "!= enabled|= enabled"), "S6.7 step 5 no longer asks for Start indexing enabled")
        ok(has(body, "= absent \\] && ! s6_has \"Add folder…\""), "S6.7 step 5 presses Next while already on Folders, which would walk to Permissions")
        ok(has(body, "ticked rows"), "S6.7 step 5 does not say how many rows were ticked when Start indexing is not available")
        ok(body.contains("S6_SKEW=1") && body.contains("the Range start expected one byte beyond the bytes kept"), "the S6.7 plant is gone")
    }

    @Test("S6.11 and S6.12 press Start indexing through press_start, print what it says (Permissions or the start error) and fail with its first line")
    func s611S612PressStartAndNameTheResult() {
        let eleven = fn("s6_check_11", in: "checks-s6b.sh")
        ok(has(eleven, "out=\"\\$\\(press_start 2>&1\\)\"; rc=\\$\\?"), "S6.11 does not keep the output of press_start")
        ok(!has(eleven, "press_start >/dev/null"), "S6.11 still throws the output of press_start away")
        ok(has(eleven, "awk 'NR == 1'"), "S6.11 does not name the first line of press_start in its failure")
        let rebuild = fn("s6b_rebuild", in: "checks-s6b.sh")
        ok(has(rebuild, "out=\"\\$\\(press_start 2>&1\\)\"; rc=\\$\\?"), "S6.12 does not keep the output of press_start")
        ok(!has(rebuild, "press_start >/dev/null"), "S6.12 still throws the output of press_start away")
        ok(has(rebuild, "awk 'NR == 1'"), "S6.12 does not name the first line of press_start in its failure")
        inOrder(rebuild, ["pick_folders[ ]+golden/photos", "press_start", "wait done 900", "s6b_delete_index", "click \"Start indexing\""], "S6.12 order: the pick, press_start, done, Delete index, then Start in Settings")
    }

    private func shellFunctionsDefined(_ file: String) -> [String: String] {
        shellFunctions(in: read(libDir.appendingPathComponent(file)).map(stripComments) ?? "")
    }
}
