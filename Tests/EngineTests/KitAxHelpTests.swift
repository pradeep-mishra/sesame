import Foundation
import Testing

// plan-2 fix round C, part C1, item C1-2 (R2-04), tester step: what the kit reads of a folder row. The product exposes each
// folder row as a tick control (title "<name>", label "<name>, <counts>, <estimate>", help the folder's full path) and the
// per-row Re-index and Remove buttons with the folder's name as help (fix round B, item B8). The kit used to read a row as an
// `AXStaticText label="/path"` and the counts as static text, neither of which the product has, so every reader came back
// empty. Written from the fix-round document (C1-2), the product strings of FolderRowAccessibilityTests, SetupScreenTests and
// SettingsScreenTests (copied here by hand as dump samples) and the existing kit scripts. No kit script is run: the pure
// readers (scripts/kit-lib/axdump.sh) and the shell functions the kit reads rows with are run in a `bash -c` on hand-written
// dump text, with the one kit script they call (`kq`) replaced by a function that prints the sample.
//
// THE DUMP FORMAT IS A GUESS until the accept stage drives it. The samples below are what `ax.applescript dumpTree` prints
// once it is changed (the task's guess, written in axdump.sh): `label="<title>"`, then `desc="<AXDescription>"` when it is
// not the label, `help="<AXHelp>"` when there is one, then `value=`. The probe in the review (title "Desktop", label
// "Desktop, 5 photos, about 1 min") says the title and the label are two different attributes; that the label reaches System
// Events as AXDescription and the help as AXHelp is inferred from AppKit's mapping, not measured.
//
// WHAT WOULD MAKE EACH CHECK FAIL ON A BROKEN PRODUCT (the plants, each also a test below):
//   - a row with no help (the product loses its full path): `ax_folders` lists nothing and the recipes see no folder;
//   - a row whose label carries 6 photos where the folder holds 5: the count read comes back 6, `s6b_compare` names it;
//   - a folder named "10 photos, 2024": the counts are read from the label after its name is cut off, so the digits of the
//     name are never read as a count;
//   - the old dump format (a static text holding the path): no folder, so a regression to the old reader is visible.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs `/bin/bash -c <script>` with the text on stdin. Only shell functions are run; no kit script is started.
private func bash(_ script: String, stdin: String = "", env: [String: String] = [:], limit: TimeInterval = 60) throws -> Ran {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
    let out = tmp.appendingPathComponent("kitax-out-" + UUID().uuidString)
    let input = tmp.appendingPathComponent("kitax-in-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    try Data(stdin.utf8).write(to: input)
    defer {
        try? fm.removeItem(at: out)
        try? fm.removeItem(at: input)
    }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["KIT_ROOT"] = tmp.appendingPathComponent("sesame-kit-axtest-" + UUID().uuidString).path
    environment["KIT_NO_EVIDENCE"] = "1"
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = try FileHandle(forReadingFrom: input)
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

private func axdump(_ call: String, stdin: String) throws -> Ran {
    try bash(". \"\(libDir.appendingPathComponent("axdump.sh").path)\"; \(call)", stdin: stdin)
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

/// The shell functions of a text: name to body (a function is `name() {` to a line that is just `}`).
private func shellFunctions(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if let r = line.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{$", options: .regularExpression) {
                name = String(line[r].dropLast(4))
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

// MARK: the samples (hand-written from the product strings)

private let sandbox = "/private/var/folders/xx/sesame-kit/home"

/// The setup window on its Folders step, as the dump reads after the change. Strings: SetupScreen.row ("<name>, <counts>,
/// <estimate>"; counts in the order photos, PDFs, documents, audio files, videos), SetupScreen.codeRow ("<name>, code folder"),
/// the summary, "About 5 min in total", "Photos: about 3 s each", and the read note above the code switch.
/// plan-6-t10 AMENDMENT: that note read "Only photos are read in this version." until photos, PDFs, documents, audio and video
/// were all read and code was read in the ticked folders (D13). The label changed in the dump and in the pins below, not the bar:
/// the helpers still read a whole label and still tell the speed note from any other text.
private let setupDump = """
window 560 x 600 at 120,80 title Set up Sesame
AXWindow/AXStandardWindow label="Set up Sesame"
  AXGroup
    AXStaticText label="Step 2 of 4: Folders"
    AXStaticText label="Folders to read"
    AXStaticText label="14 files in the ticked folders."
    AXStaticText label="About 5 min in total"
    AXStaticText label="Photos: about 3 s each"
    AXScrollArea label="Folders"
      AXGroup
        AXCheckBox label="Desktop" desc="Desktop, 5 photos, about 1 min" help="\(sandbox)/Desktop" value="1"
        AXCheckBox label="Documents" desc="Documents, 6 photos, 2 PDFs, about 2 min" help="\(sandbox)/Documents" value="1"
        AXCheckBox label="Downloads" desc="Downloads, no files, under a minute" help="\(sandbox)/Downloads" value="1"
        AXCheckBox label="Pictures" desc="Pictures, 1 photo, about 1 min" help="\(sandbox)/Pictures" value="0"
        AXCheckBox label="Movies" desc="Movies, not counted" help="\(sandbox)/Movies" value="0"
    AXStaticText label="Photos, PDFs, documents, audio and video are read. Code is read only in the folders you tick under Search my code."
    AXCheckBox label="Search my code" value="0"
    AXButton label="Add folder…"
    AXButton label="Start indexing"
    AXButton label="Back"
    AXButton label="Next"

"""

/// Settings on its Folders section. Strings: SettingsScreen (tick label "<name>, <counts>, <estimate or Waiting for Start
/// indexing>", "<name>, not read" for an unticked folder, Re-index and Remove with the folder's name as help).
private let settingsDump = """
window 700 x 480 at 100,100 title Settings
AXWindow/AXStandardWindow label="Settings"
  AXGroup
    AXButton label="Folders" value="1"
    AXButton label="File types" value="0"
    AXButton label="Search" value="0"
    AXButton label="Indexing" value="0"
    AXButton label="About" value="0"
    AXGroup
      AXStaticText label="Folders"
      AXScrollArea
        AXGroup
          AXGroup
            AXCheckBox label="Trips" desc="Trips, 40 photos, about 2 min" help="/Users/x/Trips" value="1"
            AXButton label="Re-index" help="Trips"
            AXButton label="Remove" help="Trips"
          AXGroup
            AXCheckBox label="Notes" desc="Notes, 7 PDFs, Waiting for Start indexing" help="/Users/x/Notes" value="1"
            AXButton label="Re-index" help="Notes"
            AXButton label="Remove" help="Notes"
          AXGroup
            AXCheckBox label="Extra" desc="Extra, not read" help="/Users/x/Extra" value="0"
            AXButton label="Re-index" help="Extra"
            AXButton label="Remove" help="Extra"
      AXButton label="Add folder…"

"""

/// The format the kit used to read (and the product no longer writes): a static text holding the path.
private let oldFormatDump = """
window 560 x 600 at 120,80 title Set up Sesame
AXWindow/AXStandardWindow label="Set up Sesame"
  AXScrollArea label="Folders"
    AXCheckBox label="Desktop" value="1"
    AXStaticText label="/private/var/folders/xx/sesame-kit/home/Desktop"
    AXStaticText label="5 photos, about 1 min"

"""

// MARK: the readers

@Suite("KitAxHelpTests")
struct KitAxHelpTests {

    @Test("axdump.sh exists, is bash, and has no syntax error (bash -n; it is only sourced)")
    func syntax() throws {
        let path = libDir.appendingPathComponent("axdump.sh").path
        guard let text = read(URL(fileURLWithPath: path)) else {
            Issue.record("scripts/kit-lib/axdump.sh does not exist: the pure readers of the dump are not written")
            return
        }
        ok(text.hasPrefix("#!/bin/bash\n"), "axdump.sh line 1 is not #!/bin/bash")
        let ran = try bash("/bin/bash -n '\(path)'")
        ok(ran.status == 0 && ran.output.isEmpty, "bash -n axdump.sh exited \(ran.status): \(ran.output)")
    }

    @Test("ax_folders lists the folder rows of the setup window by their help (the full path)")
    func foldersOfSetup() throws {
        let ran = try axdump("ax_folders", stdin: setupDump)
        ok(ran.status == 0, "ax_folders exited \(ran.status): \(ran.output)")
        #expect(lines(ran) == ["Desktop", "Documents", "Downloads", "Pictures", "Movies"].map { "\(sandbox)/\($0)" },
                "folders read: \(lines(ran))")
    }

    @Test("ax_folders lists the folder rows of Settings once each, and not a Re-index or Remove button")
    func foldersOfSettings() throws {
        let ran = try axdump("ax_folders", stdin: settingsDump)
        #expect(lines(ran) == ["/Users/x/Trips", "/Users/x/Notes", "/Users/x/Extra"], "folders read: \(lines(ran))")
    }

    // PLANT: the product loses the help (the full path). Nothing can be read, so every recipe and S1.6 stops at "no folder".
    @Test("a row with no help lists no folder (the plant: the full path gone)")
    func noHelpNoFolder() throws {
        let broken = setupDump.replacingOccurrences(of: " help=\"\(sandbox)/Desktop\"", with: "")
        let ran = try axdump("ax_folders", stdin: broken)
        #expect(!lines(ran).contains("\(sandbox)/Desktop"), "a row with no help was listed: \(lines(ran))")
        #expect(lines(ran).count == 4, "the other four rows must still be listed: \(lines(ran))")
    }

    // PLANT: the old format. The product has no static text holding a path, so a reader that went back to it reads nothing.
    @Test("the old format (a static text holding the path) lists no folder")
    func oldFormatListsNothing() throws {
        let ran = try axdump("ax_folders", stdin: oldFormatDump)
        #expect(lines(ran).isEmpty, "the old format was read as folders: \(lines(ran))")
    }

    @Test("ax_row_detail reads the counts and the estimate from the label, the name cut off")
    func detailOfRows() throws {
        let table: [(String, String)] = [
            ("Desktop", "5 photos, about 1 min"),
            ("Documents", "6 photos, 2 PDFs, about 2 min"),
            ("Downloads", "no files, under a minute"),
            ("Pictures", "1 photo, about 1 min"),
            ("Movies", "not counted"),
        ]
        for (name, want) in table {
            let ran = try axdump("ax_row_detail '\(name)'", stdin: setupDump)
            #expect(lines(ran) == [want], "\(name): detail \(lines(ran)), wanted \(want)")
        }
        let notes = try axdump("ax_row_detail Notes", stdin: settingsDump)
        #expect(lines(notes) == ["7 PDFs, Waiting for Start indexing"], "Notes: \(lines(notes))")
        let extra = try axdump("ax_row_detail Extra", stdin: settingsDump)
        #expect(lines(extra) == ["not read"], "Extra: \(lines(extra))")
    }

    @Test("ax_row_estimate is what follows the last comma of the detail")
    func estimateOfRows() throws {
        let table: [(String, String, String)] = [
            ("Desktop", setupDump, "about 1 min"), ("Documents", setupDump, "about 2 min"), ("Downloads", setupDump, "under a minute"),
            ("Notes", settingsDump, "Waiting for Start indexing"), ("Trips", settingsDump, "about 2 min"),
        ]
        for (name, dump, want) in table {
            let ran = try axdump("ax_row_estimate '\(name)'", stdin: dump)
            #expect(lines(ran) == [want], "\(name): estimate \(lines(ran)), wanted \(want)")
        }
    }

    // The digits of a folder's name are never a count: the name is cut off the label before the counts are read.
    @Test("a folder named \"10 photos, 2024\" shows the counts of its files, not the digits of its name")
    func nameWithDigitsAndComma() throws {
        let dump = """
        window 560 x 600 at 0,0 title Set up Sesame
        AXWindow label="Set up Sesame"
          AXCheckBox label="10 photos, 2024" desc="10 photos, 2024, 3 photos, about 1 min" help="/Users/x/10 photos, 2024" value="1"
        """
        let ran = try axdump("ax_row_detail '10 photos, 2024'", stdin: dump)
        #expect(lines(ran) == ["3 photos, about 1 min"], "detail: \(lines(ran))")
    }

    // The format guess: when the dump carries the whole label in `label=` and no `desc=`, the name comes from the help.
    @Test("a row with its whole label in label= (no desc) is read the same way")
    func labelOnlyFallback() throws {
        let dump = """
        window 560 x 600 at 0,0 title Set up Sesame
        AXWindow label="Set up Sesame"
          AXCheckBox label="Desktop, 5 photos, about 1 min" help="/Users/x/Desktop" value="1"
        """
        let ran = try axdump("ax_row_detail Desktop", stdin: dump)
        #expect(lines(ran) == ["5 photos, about 1 min"], "detail: \(lines(ran))")
    }

    @Test("ax_row gives the state and whether the tick is enabled")
    func rowState() throws {
        let desktop = try axdump("ax_row Desktop", stdin: setupDump)
        #expect(lines(desktop) == ["\(sandbox)/Desktop\tDesktop\ton\tenabled\t5 photos, about 1 min\tfolder"], "Desktop row: \(lines(desktop))")
        let movies = try axdump("ax_row Movies", stdin: setupDump)
        #expect(lines(movies).first?.contains("\toff\tenabled\t") == true, "Movies row: \(lines(movies))")
        let byPath = try axdump("ax_row '/Users/x/Trips'", stdin: settingsDump)
        #expect(lines(byPath).first?.hasPrefix("/Users/x/Trips\tTrips\ton\tenabled\t") == true, "row by path: \(lines(byPath))")
        let none = try axdump("ax_row Nowhere", stdin: setupDump)
        #expect(none.status != 0, "a row that is not there was found")
    }

    @Test("ax_row_block is the row's own lines up to the next row: a Settings row holds its Re-index and Remove, not the next row's")
    func blockOfRow() throws {
        let ran = try axdump("ax_row_block Trips", stdin: settingsDump)
        let got = lines(ran).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(got.count == 3 && got[0].hasPrefix("AXCheckBox label=\"Trips\"") && got[1] == "AXButton label=\"Re-index\" help=\"Trips\""
                && got[2] == "AXButton label=\"Remove\" help=\"Trips\"", "block: \(got)")
        let last = try axdump("ax_row_block Extra", stdin: settingsDump)
        let lastLines = lines(last).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(!lastLines.contains("AXButton label=\"Add folder…\""), "the last row's block ran on into the Add folder… button: \(lastLines)")
        let missing = try axdump("ax_row_block Nowhere", stdin: settingsDump)
        #expect(missing.status != 0, "the block of a row that is not there was not an error")
    }

    @Test("ax_switch reads the code switch, ax_has_label reads a text")
    func switchAndLabel() throws {
        let off = try axdump("ax_switch 'Search my code'", stdin: setupDump)
        #expect(lines(off) == ["off"], "switch: \(lines(off))")
        let on = try axdump("ax_switch 'Search my code'", stdin: setupDump.replacingOccurrences(of: "label=\"Search my code\" value=\"0\"", with: "label=\"Search my code\" value=\"1\""))
        #expect(lines(on) == ["on"], "switch on: \(lines(on))")
        let absent = try axdump("ax_switch 'Search my code'", stdin: settingsDump)
        #expect(lines(absent) == ["absent"], "switch absent: \(lines(absent))")
        let text = try axdump("ax_has_label 'Photos, PDFs, documents, audio and video are read. Code is read only in the folders you tick under Search my code.' && echo yes", stdin: setupDump)
        #expect(lines(text) == ["yes"])
        let prefix = try axdump("ax_has_label_prefix 'Step 2 of 4: ' && echo yes", stdin: setupDump)
        #expect(lines(prefix) == ["yes"])
        let partial = try axdump("ax_has_label 'Photos, PDFs' && echo yes || echo no", stdin: setupDump)
        #expect(lines(partial) == ["no"], "ax_has_label matched a part of a label")
    }

    @Test("ax_total_seconds reads the line \"About <time> in total\" and never a row's own estimate")
    func totalSeconds() throws {
        let table: [(String, String)] = [
            ("About 5 min in total", "300"), ("About 2 h 10 min in total", "7800"), ("About 2 h in total", "7200"),
            ("Under a minute in total", "30"), ("About 1 min in total", "60"),
        ]
        for (line, seconds) in table {
            let dump = setupDump.replacingOccurrences(of: "About 5 min in total", with: line)
            let ran = try axdump("ax_total_seconds", stdin: dump)
            #expect(lines(ran) == [seconds], "\"\(line)\": read \(lines(ran)), wanted \(seconds)")
        }
        // PLANT: no total line, only the rows' estimates (about 1 min, about 2 min ...): nothing is printed, not a row's figure
        let noTotal = setupDump.replacingOccurrences(of: "    AXStaticText label=\"About 5 min in total\"\n", with: "")
        let ran = try axdump("ax_total_seconds", stdin: noTotal)
        #expect(lines(ran).isEmpty, "a row's estimate was taken as the total: \(lines(ran))")
    }

    @Test("ax_speed_note reads \"Photos: about <n> s each\", whole or with one decimal")
    func speedNote() throws {
        let three = try axdump("ax_speed_note", stdin: setupDump)
        #expect(lines(three) == ["3"], "note: \(lines(three))")
        let slow = try axdump("ax_speed_note", stdin: setupDump.replacingOccurrences(of: "Photos: about 3 s each", with: "Photos: about 1.5 s each"))
        #expect(lines(slow) == ["1.5"], "note: \(lines(slow))")
        let other = try axdump("ax_speed_note", stdin: setupDump.replacingOccurrences(of: "Photos: about 3 s each", with: "Photos, PDFs, documents, audio and video are read."))
        #expect(lines(other).isEmpty, "a note that is not the speed note was read: \(lines(other))")
    }
}

// MARK: ax.applescript and kit-ax.sh: the help in the dump and the help selector of click

@Suite("KitAxHelpDriverTextTests")
struct KitAxHelpDriverTextTests {
    private var script: String { read(libDir.appendingPathComponent("ax.applescript")).map(stripComments) ?? "" }
    private var kitAx: String { read(scriptsDir.appendingPathComponent("kit-ax.sh")) ?? "" }

    /// The AppleScript text of one `else if cmd is "<name>"` branch, up to the next branch.
    private func branch(_ name: String) -> String {
        let s = read(libDir.appendingPathComponent("ax.applescript")) ?? ""
        guard let start = s.range(of: "else if cmd is \"\(name)\"") ?? s.range(of: "if cmd is \"\(name)\"") else { return "" }
        let rest = s[start.upperBound...]
        let end = rest.range(of: "\n\telse if cmd is ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("the dump line prints the help and, when it is not the label, the description")
    func dumpPrintsHelp() {
        let s = read(libDir.appendingPathComponent("ax.applescript")) ?? ""
        guard let start = s.range(of: "on dumpTree(el, depth)"), let end = s.range(of: "end dumpTree") else {
            Issue.record("ax.applescript has no dumpTree"); return
        }
        let body = String(s[start.lowerBound..<end.upperBound])
        // the help is read by the handler helpOf (one reader for the dump and for click), which reads AXHelp
        ok(body.contains("helpOf(el)") && has(stripComments(s), "on helpOf\\(el\\)[^\\n]*\\n[^\\n]*AXHelp"), "dumpTree never reads the help (AXHelp, through helpOf), so a folder row's full path cannot be in the dump")
        ok(has(body, "help=\\\\\""), "dumpTree prints no help=\"...\" on the dump line")
        ok(has(body, "AXDescription") && has(body, "desc=\\\\\""), "dumpTree prints no desc=\"...\" (the label \"<name>, <counts>\" is the description, the title is the name)")
        let order = ["label=\\\"", "desc=\\\"", "help=\\\"", "value=\\\""].compactMap { body.range(of: $0)?.lowerBound }
        ok(order.count == 4 && order == order.sorted(), "the dump line is not label, desc, help, value in that order (axdump.sh reads any order, the samples of these tests use this one)")
    }

    @Test("click takes a help selector: the element whose label is the label and whose help is the help")
    func clickHelp() {
        let b = branch("click")
        ok(!b.isEmpty, "ax.applescript has no click command")
        ok(has(b, "item 4 of argv"), "click reads no fourth argument (the help)")
        // Commit 080db8e moved the walk, the exact comparison and the press out of the click branch into the handler
        // findAndPress (children reached by position, so rows of one name are told apart). The branch now hands the help
        // to it; the same three clauses are pinned on the handler, none dropped.
        let handler: String = {
            let s = read(libDir.appendingPathComponent("ax.applescript")) ?? ""
            guard let a = s.range(of: "on findAndPress("), let e = s.range(of: "end findAndPress") else { return "" }
            return String(s[a.lowerBound..<e.upperBound])
        }()
        ok(!handler.isEmpty, "ax.applescript has no findAndPress handler")
        ok(has(b, "findAndPress\\([^\\n]*wantedHelp"), "click does not hand the help selector to findAndPress")
        ok(handler.contains("AXHelp") || handler.contains("helpOf"), "click never compares the help of an element")
        ok(has(handler, "considering case"), "click no longer compares exactly")
        ok(handler.contains("AXPress"), "click does not press")
        // with a help selector the status item's menu is not tried: a menu item has no help, so a wrong row is never pressed
        ok(has(b, "wantedHelp is[^\\n]*\"\"") || has(b, "wantedHelp is not \"\""), "click does not tell a help selector from none")
    }

    @Test("kit-ax.sh usage names click --help, and the plain click line stays")
    func usageLines() {
        let usage = kitAx.components(separatedBy: "usage() {").dropFirst().first?.components(separatedBy: "\nEOF").first ?? ""
        ok(usage.contains("kit-ax.sh click --help \"<help>\" \"<label>\""), "usage has no `kit-ax.sh click --help \"<help>\" \"<label>\"` line")
        ok(usage.contains("kit-ax.sh click \"<label>\""), "usage lost the `kit-ax.sh click \"<label>\"` line")
    }

    /// cmd_click as a shell would run it, with the three things it calls replaced: the usage text, the accessibility check and
    /// `osa`, which prints the arguments it was given. The function body is read from kit-ax.sh; nothing of kit-ax.sh runs.
    private func runClick(_ args: String) throws -> Ran {
        guard let body = shellFunctions(in: kitAx)["cmd_click"] else {
            Issue.record("kit-ax.sh has no cmd_click")
            return Ran(status: 99, output: "")
        }
        let prelude = """
        usage() { echo "USAGE" >&2; }
        need_ax() { return 0; }
        AX_APP=Sesame
        osa() { echo "OSA $*"; OSA_OUT="clicked"; OSA_ERR=""; return 0; }
        cmd_click() {
        \(body)
        }
        cmd_click \(args)
        echo "status $?"
        """
        return try bash(prelude)
    }

    @Test("click --help <help> <label> passes the label and the help to the driver; a plain click passes the label alone")
    func clickArguments() throws {
        let withHelp = try runClick("--help extra Remove")
        #expect(lines(withHelp).contains("OSA click Remove extra"), "click --help extra Remove: \(lines(withHelp))")
        #expect(lines(withHelp).last == "status 0")
        let plain = try runClick("Remove")
        #expect(lines(plain).contains("OSA click Remove"), "click Remove: \(lines(plain))")
        #expect(!lines(plain).contains { $0.hasPrefix("OSA click Remove ") }, "a plain click passed a help: \(lines(plain))")
    }

    @Test("click --help with no label, an empty help, or too many words is a usage error and presses nothing")
    func clickUsageErrors() throws {
        for args in ["--help extra", "--help", "--help '' Remove", "a b", "--help extra Remove again", ""] {
            let ran = try runClick(args)
            #expect(lines(ran).contains("USAGE") && lines(ran).last == "status 2" && !lines(ran).contains { $0.hasPrefix("OSA") },
                    "click \(args): \(lines(ran))")
        }
    }
}

// MARK: the readers of the kit use the pure readers

@Suite("KitAxHelpReadersTests")
struct KitAxHelpReadersTests {
    private func code(_ name: String) -> String { read(libDir.appendingPathComponent(name)).map(stripComments) ?? "" }

    @Test("recipes.sh, checks-s1c.sh and checks-s6b.sh no longer read a folder as `AXStaticText label=\"/...\"`")
    func oldReadersGone() {
        for name in ["recipes.sh", "checks-s1c.sh", "checks-s6b.sh"] {
            let t = code(name)
            ok(!t.contains("AXStaticText label=\"\\("), "\(name) still reads a static text holding a path")
            ok(!t.contains("label=\"\\(\\/"), "\(name) still reads an element whose label is an absolute path")
        }
        ok(code("recipes.sh").contains("axdump.sh"), "recipes.sh does not source axdump.sh, so no check has the pure readers")
    }

    @Test("setup_folders, s1c_folders and s6b_block read folder rows through ax_folders and ax_row_block")
    func readersUseAxdump() {
        let recipes = shellFunctions(in: code("recipes.sh"))
        ok(has(recipes["setup_folders"] ?? "", "ax_folders"), "setup_folders does not read through ax_folders")
        let s1c = shellFunctions(in: code("checks-s1c.sh"))
        ok(has(s1c["s1c_folders"] ?? "", "ax_folders"), "s1c_folders does not read through ax_folders")
        let s6b = shellFunctions(in: code("checks-s6b.sh"))
        ok(has(s6b["s6b_block"] ?? "", "ax_row_block"), "s6b_block does not read through ax_row_block")
    }

    /// setup_folders as the recipes run it, `kq` printing the sample for `dump <window>`.
    private func setupFolders(window: String, dump: String) throws -> Ran {
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("kitax-sample-" + UUID().uuidString)
        try Data(dump.utf8).write(to: sample)
        defer { try? FileManager.default.removeItem(at: sample) }
        let script = """
        . "\(libDir.appendingPathComponent("common.sh").path)"
        . "\(libDir.appendingPathComponent("recipes.sh").path)"
        kq() { if [ "$2" = dump ] && [ "$3" = "\(window)" ]; then cat "\(sample.path)"; return 0; fi; return 1; }
        PK_WINDOW=\(window)
        setup_folders
        echo "status $?"
        """
        return try bash(script)
    }

    @Test("setup_folders returns the folders the setup window lists, and the ones Settings lists")
    func setupFoldersOnSamples() throws {
        let setup = try setupFolders(window: "setup", dump: setupDump)
        #expect(lines(setup) == ["Desktop", "Documents", "Downloads", "Pictures", "Movies"].map { "\(sandbox)/\($0)" } + ["status 0"], "setup: \(lines(setup))")
        let settings = try setupFolders(window: "settings", dump: settingsDump)
        #expect(lines(settings) == ["/Users/x/Trips", "/Users/x/Notes", "/Users/x/Extra", "status 0"], "settings: \(lines(settings))")
        let none = try setupFolders(window: "setup", dump: oldFormatDump)
        #expect(lines(none) == ["status 0"], "the old format was read as folders: \(lines(none))")
    }

    @Test("setup_lists says the window lists a folder (or the one subfolder the picker selected in it) by the real path")
    func setupListsOnSample() throws {
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("kitax-sample-" + UUID().uuidString)
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kitax-listed-" + UUID().uuidString)
        let golden = tmpRoot.appendingPathComponent("golden/photos")
        try FileManager.default.createDirectory(at: golden, withIntermediateDirectories: true)
        // the real path as `pwd -P` spells it (/private/var/...): Foundation's resolvingSymlinksInPath would give /var/...
        var realGolden = ""
        if let resolved = realpath(tmpRoot.appendingPathComponent("golden").path, nil) {
            realGolden = String(cString: resolved)
            free(resolved)
        }
        #expect(realGolden.hasSuffix("/golden"), "realpath of the folder said \(realGolden)")
        let dump = """
        window 560 x 600 at 0,0 title Set up Sesame
        AXWindow label="Set up Sesame"
          AXCheckBox label="photos" desc="photos, 40 photos, about 2 min" help="\(realGolden)/photos" value="1"
        """
        try Data(dump.utf8).write(to: sample)
        defer {
            try? FileManager.default.removeItem(at: sample)
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        let script = """
        . "\(libDir.appendingPathComponent("common.sh").path)"
        . "\(libDir.appendingPathComponent("recipes.sh").path)"
        kq() { if [ "$2" = dump ]; then cat "\(sample.path)"; return 0; fi; return 1; }
        setup_lists "\(tmpRoot.appendingPathComponent("golden").path)" && echo listed || echo not-listed
        setup_lists "\(tmpRoot.appendingPathComponent("elsewhere").path)" && echo listed || echo not-listed
        """
        let ran = try bash(script)
        #expect(lines(ran) == ["listed", "not-listed"], "setup_lists: \(lines(ran))")
    }
}
