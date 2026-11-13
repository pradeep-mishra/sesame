import Foundation
import Testing

// plan-2 fix round C, part C1, items C1-1 (R2-03) and C1-3 (R2-06), tester step: the Settings sections. "Start indexing",
// "Delete index…" and "Launch at login" live only in the Indexing section of Settings, and a section that is not selected is
// not in the accessibility tree (SettingsWindow.refresh hides every other section view; the sealed
// FolderRowAccessibilityTests pin that "Start indexing", "Delete index…" and "Launch at login" are in the tree only after the
// sidebar button "Indexing" is pressed, and that "Add folder…" and the row buttons are in it only on Folders). The kit never
// pressed a sidebar button, so every step that clicked one of those three labels failed on a correct product, and the S1.29
// walk looked for sidebar rows in an AXOutline that the product (five recessed buttons) does not have and passed, noted, on one
// page.
//
// Written from the fix-round document (C1-1: one shared helper in scripts/kit-lib, `settings_section <name>`, used by every
// step, and a grep that no check function clicks one of the three labels without it in the same function; C1-3: S1.29 walks
// each of the five sections by pressing the sidebar button and tab-walking the page, a button that cannot be found is RERUN or
// FAIL, never a pass with a "noted" line) and the product strings of FolderRowAccessibilityTests and SettingsScreenTests (the
// five sidebar titles, the controls of each section), copied here by hand.
//
// No kit script is run. `settings_section` and `s1c_29_sections` are run in a `bash -c` with the kit scripts they call (`kq`,
// `nr_walk`, ...) replaced by functions that record the call and answer from a hand-written dump.
//
// WHAT WOULD MAKE EACH FAIL ON A BROKEN PRODUCT (the plants, each also a test below):
//   - the sidebar button is missing or cannot be pressed: `settings_section` is not 0 and says "no sidebar button";
//   - the button is pressed but the section does not open (its control never reaches the tree): not 0, says it did not open;
//   - S1.29 with the Search button missing: a FAIL reason naming Search and no walk of that section, never a pass.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func bash(_ script: String, env: [String: String] = [:], limit: TimeInterval = 60) throws -> Ran {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
    let out = tmp.appendingPathComponent("kitsec-out-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    defer { try? fm.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["KIT_ROOT"] = tmp.appendingPathComponent("sesame-kit-sectest-" + UUID().uuidString).path
    environment["KIT_NO_EVIDENCE"] = "1"
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

/// Every function of recipes.sh and of the checks-*.sh files, comments removed: name to (file, body).
private func kitFunctions() -> [String: (file: String, body: String)] {
    var all: [String: (String, String)] = [:]
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: libDir.path)) ?? [])
        .filter { $0.hasSuffix(".sh") && ($0.hasPrefix("checks-") || $0 == "recipes.sh") }.sorted()
    for name in names {
        guard let text = read(libDir.appendingPathComponent(name)) else { continue }
        for (fn, body) in shellFunctions(in: stripComments(text)) where all[fn] == nil { all[fn] = (name, body) }
    }
    return all
}

/// The three controls that live only in the Indexing section, as a `click "<label>"` in a function body.
private let indexingLabels = ["Start indexing", "Delete index…", "Launch at login"]

private func positions(_ text: String, _ pattern: String) -> [(offset: Int, groups: [String])] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (m.range.location, (1..<max(m.numberOfRanges, 1)).map { i in
            m.range(at: i).location != NSNotFound ? ns.substring(with: m.range(at: i)) : ""
        })
    }
}

// MARK: samples: the Settings window with one section selected (strings of SettingsScreen, by hand)

private func settingsDump(with controls: [String]) -> String {
    var s = """
    window 700 x 480 at 100,100 title Settings
    AXWindow/AXStandardWindow label="Settings"
      AXGroup
        AXButton label="Folders"
        AXButton label="File types"
        AXButton label="Search"
        AXButton label="Indexing"

    """
    for c in controls { s += "    \(c)\n" }
    return s
}

private let sectionControls: [String: [String]] = [
    "Folders": ["AXStaticText label=\"Folders\"", "AXButton label=\"Add folder…\""],
    "File types": ["AXStaticText label=\"File types\"", "AXCheckBox label=\"Photos\" value=\"1\"", "AXCheckBox label=\"PDFs\" value=\"1\"", "AXCheckBox label=\"Documents\" value=\"1\"", "AXCheckBox label=\"Audio\" value=\"1\"", "AXCheckBox label=\"Video\" value=\"1\""],
    "Search": ["AXStaticText label=\"Search\"", "AXButton label=\"Record new shortcut\"", "AXButton label=\"Back to default\""],
    "Indexing": ["AXStaticText label=\"Indexing\"", "AXButton label=\"Start indexing\"", "AXCheckBox label=\"Launch at login\" value=\"1\"", "AXButton label=\"Delete index…\""],
]

// MARK: settings_section

@Suite("KitRunSettingsSectionsTests")
struct KitRunSettingsSectionsTests {
    private let common = libDir.appendingPathComponent("common.sh").path
    private let recipes = libDir.appendingPathComponent("recipes.sh").path

    /// `settings_section <name>` with `kq` replaced: it logs "<script> <args>", `click <fail>` fails, `dump settings` prints the dump.
    private func section(_ name: String, dump: String, clickFails: String = "", dumpFile: URL? = nil) throws -> (Ran, [String]) {
        let fm = FileManager.default
        let sample = dumpFile ?? fm.temporaryDirectory.appendingPathComponent("kitsec-dump-" + UUID().uuidString)
        try Data(dump.utf8).write(to: sample)
        let log = fm.temporaryDirectory.appendingPathComponent("kitsec-log-" + UUID().uuidString)
        defer {
            try? fm.removeItem(at: sample)
            try? fm.removeItem(at: log)
        }
        let script = """
        . "\(common)"
        . "\(recipes)"
        sleep() { :; }
        kq() {
          echo "${1##*/} $2 $3" >> "\(log.path)"
          case "$2" in
            click) [ "$3" != "\(clickFails)" ] ;;
            dump) cat "\(sample.path)" ;;
          esac
        }
        settings_section '\(name)'
        echo "status $?"
        """
        let ran = try bash(script)
        let calls = (read(log) ?? "").split(separator: "\n").map(String.init)
        return (ran, calls)
    }

    @Test("settings_section is defined once, in recipes.sh, and recipes.sh reaches every check through it")
    func helperExists() {
        let fns = kitFunctions()
        ok(fns["settings_section"]?.file == "recipes.sh", "settings_section is not defined in scripts/kit-lib/recipes.sh (it is in \(fns["settings_section"]?.file ?? "no file"))")
    }

    @Test("settings_section presses the sidebar button of each of the four sections (the About tab is removed by decision, guide 16.16) and returns 0 once the section's control is in the dump",
          arguments: ["Folders", "File types", "Search", "Indexing"])
    func opensEachSection(_ name: String) throws {
        let (ran, calls) = try section(name, dump: settingsDump(with: sectionControls[name] ?? []))
        #expect(lines(ran).last == "status 0", "settings_section \(name): \(lines(ran))")
        #expect(calls.first == "kit-ax.sh click \(name)", "the first call was \(calls.first ?? "none"), wanted the press of the sidebar button \(name)")
        #expect(calls.contains("kit-ax.sh dump settings"), "settings_section never read the Settings window to see that the section opened: \(calls)")
    }

    @Test("the File types marker is the PDFs kind checkbox, and no label of the other four sections, no sidebar button and no fixture folder is PDFs (plan-7-t10: the marker was Search my code)")
    func fileTypesMarkerIsPDFs() throws {
        let ran = try bash("""
        . "\(common)"
        . "\(recipes)"
        settings_section_marker "File types"
        for s in Folders Search Indexing; do settings_section_marker "$s"; done
        """)
        #expect(lines(ran) == ["PDFs", "Add folder…", "Record new shortcut", "Start indexing"], "the markers are \(lines(ran))")
        func labels(_ controls: [String]) -> [String] {
            controls.compactMap { c in
                guard let r = c.range(of: "label=\"[^\"]*\"", options: .regularExpression) else { return nil }
                return String(c[r].dropFirst(7).dropLast())
            }
        }
        for (name, controls) in sectionControls where name != "File types" {
            #expect(!labels(controls).contains("PDFs"), "the \(name) section holds a label PDFs")
        }
        let sidebar = labels(settingsDump(with: []).split(separator: "\n").map(String.init))
        #expect(sidebar == ["Settings", "Folders", "File types", "Search", "Indexing"] && !sidebar.contains("PDFs"), "the sidebar labels are \(sidebar)")
        for table in ["golden-roots.tsv", "home.tsv", "repo-cells.tsv", "tree.tsv", "overlap.tsv"] {
            let text = read(libDir.appendingPathComponent(table)) ?? ""
            let parts = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.flatMap { $0.split(whereSeparator: { "\t,/ ".contains($0) }) }.map(String.init)
            #expect(!parts.contains("PDFs"), "\(table) names a folder or file PDFs")
        }
        let fixtures = ((try? FileManager.default.contentsOfDirectory(atPath: projectRoot.appendingPathComponent("fixtures").path)) ?? [])
        #expect(!fixtures.contains("PDFs"), "a fixture folder is named PDFs")
    }

    // PLANT: the sidebar button cannot be pressed (the product has no such button, or it is disabled).
    @Test("settings_section is not 0 and says there is no sidebar button when the press fails", arguments: ["Indexing", "Folders"])
    func noButton(_ name: String) throws {
        let (ran, calls) = try section(name, dump: settingsDump(with: sectionControls[name] ?? []), clickFails: name)
        #expect(lines(ran).last != "status 0", "settings_section \(name) passed although the button could not be pressed: \(lines(ran))")
        #expect(lines(ran).contains { $0.contains("no sidebar button") && $0.contains(name) }, "no line names the missing sidebar button \(name): \(lines(ran))")
        #expect(!calls.contains("kit-ax.sh dump settings"), "it read the window after a press that failed")
    }

    // PLANT: the press works but the section does not open: the dump still shows the old section.
    @Test("settings_section is not 0 when the control of the section never reaches the dump")
    func sectionDoesNotOpen() throws {
        let (ran, _) = try section("Indexing", dump: settingsDump(with: sectionControls["Folders"] ?? []))
        #expect(lines(ran).last != "status 0", "settings_section Indexing passed with the Folders section on screen: \(lines(ran))")
        #expect(lines(ran).contains { $0.contains("Start indexing") && $0.contains("Indexing") }, "no line says Start indexing never showed after Indexing was pressed: \(lines(ran))")
    }

    // PLANT: a label that only starts like the marker must not do. "Start indexing" is the Indexing marker.
    @Test("a marker is matched whole: \"Start indexing now\" is not \"Start indexing\"")
    func markerMatchedWhole() throws {
        let dump = settingsDump(with: ["AXButton label=\"Start indexing now\""])
        let (ran, _) = try section("Indexing", dump: dump)
        #expect(lines(ran).last != "status 0", "a label that only starts with the marker opened the section")
    }

    @Test("settings_section refuses a name that is not a section (status 2) and presses nothing")
    func unknownSection() throws {
        let (ran, calls) = try section("Preferences", dump: settingsDump(with: []))
        #expect(lines(ran).last == "status 2", "settings_section Preferences: \(lines(ran))")
        #expect(calls.isEmpty, "a press or a read was made for a name that is not a section: \(calls)")
    }

    @Test("settings_section About is refused with status 2 and the line that names the four sections, and presses nothing, because the About tab is removed by decision (guide 16.16)")
    func aboutIsNotASection() throws {
        let (ran, calls) = try section("About", dump: settingsDump(with: []))
        #expect(lines(ran) == ["settings_section: \"About\" is not a Settings section (Folders, File types, Search, Indexing)", "status 2"], "settings_section About: \(lines(ran))")
        #expect(calls.isEmpty, "a press or a read was made for About: \(calls)")
    }

    @Test("settings_section_marker and settings_section_has know no About: the marker is status 2 and no dump is taken for it")
    func aboutHasNoMarker() throws {
        let ran = try bash("""
        . "\(common)"
        . "\(recipes)"
        settings_section_marker About; echo "marker $?"
        printf 'AXStaticText label="Version 0.1, local build"\\n' | settings_section_has About; echo "has $?"
        """)
        #expect(lines(ran) == ["marker 2", "has 2"], "About reads as \(lines(ran))")
    }

    // MARK: the grep of C1-1

    @Test("no function of recipes.sh or checks-*.sh clicks Start indexing, Delete index… or Launch at login without settings_section Indexing before the click")
    func everyClickSelectsTheSectionFirst() {
        let fns = kitFunctions()
        var seen: [String] = []
        for (name, entry) in fns.sorted(by: { $0.key < $1.key }) {
            // Commit 080db8e: s7_delete_index and s7_rearm press through `s6_press "$S7_AX" "<label>"` (the same click, with
            // kit-ax's failure output printed), so that spelling counts as a click here and must follow settings_section too.
            let clicks = positions(entry.body, "(?:click|s6_press[ ]+\"?\\$\\{?S[0-9]_AX\\}?\"?)[ ]+\"(Start indexing|Delete index…|Launch at login)\"")
            if clicks.isEmpty { continue }
            // the one place that presses Start in the SETUP window (it has no sidebar): the recipes' own press_start
            if name == "press_start" { continue }
            seen.append(name)
            let selects = positions(entry.body, "settings_section[ ]+\"?(Folders|File types|Search|Indexing)\"?")
            for click in clicks {
                let last = selects.last { $0.offset < click.offset }
                ok(last?.groups.first == "Indexing",
                   "\(name) (\(entry.file)) clicks \"\(click.groups[0])\" with \(last.map { "settings_section \($0.groups[0])" } ?? "no settings_section") before it, not settings_section Indexing")
            }
        }
        // the functions known to click one of the three; a rename or a removal must not leave the test with nothing to read
        let known = ["s6_check_8", "s6_check_10", "s6b_delete_index", "s6b_rebuild", "s7_delete_index", "s7_rearm", "s7_check_8", "s7_check_9",
                     "s7_check_11", "s7_check_14", "s7_check_18", "s1c_delete_index", "s8_check_11"]
        for name in known { ok(seen.contains(name), "\(name) is expected to click one of the three Indexing controls and was not found doing so (found: \(seen))") }
    }

    @Test("the setup window's Start indexing is pressed through press_start only: S6.11 no longer clicks it by hand")
    func setupStartThroughPressStart() {
        let fns = kitFunctions()
        ok(has(fns["press_start"]?.body ?? "", "click[ ]+\"Start indexing\""), "press_start no longer presses Start indexing")
        ok(!(fns["press_start"]?.body ?? "").contains("settings_section"), "press_start selects a Settings section: the setup window has no sidebar")
        let s611 = fns["s6_check_11"]?.body ?? ""
        ok(!s611.isEmpty, "s6_check_11 not found")
        ok(!has(s611, "click[ ]+\"Start indexing\""), "s6_check_11 clicks the setup window's Start indexing by hand instead of press_start")
        ok(has(s611, "press_start"), "s6_check_11 does not press Start through press_start")
    }

    @Test("the folder controls (Add folder…, Remove, the row ticks) are only used after settings_section Folders")
    func folderControlsSelectFolders() {
        let fns = kitFunctions()
        // the picker adds a folder in the Settings window through "Add folder…": it selects Folders itself
        let attempt = fns["picker_attempt"]?.body ?? ""
        let add = attempt.range(of: "click \"Add folder…\"")
        let select = attempt.range(of: "settings_section Folders")
        ok(add != nil && select != nil && select!.lowerBound < add!.lowerBound,
           "picker_attempt does not select the Folders section before it presses \"Add folder…\" (a Settings window left on Indexing has no such button)")
        ok(has(attempt, "PK_WINDOW[^\\n]*settings"), "picker_attempt selects the section without asking whether the window is Settings (the setup window has no sidebar)")
        // S7.9 removes a folder: Folders first
        let s79 = fns["s7_check_9"]?.body ?? ""
        let remove = positions(s79, "click \"More actions for extra\"")
        let selects = positions(s79, "settings_section[ ]+\"?(Folders|File types|Search|Indexing)\"?")
        ok(!remove.isEmpty, "s7_check_9 does not press the more button of the row of extra")
        for r in remove { ok(selects.last { $0.offset < r.offset }?.groups.first == "Folders", "s7_check_9 presses the more button of the row of extra without settings_section Folders before it") }
    }
}

// MARK: S1.29 walks the four sections (the About tab is removed by decision, guide 16.16)

@Suite("KitRunS129SectionsTests")
struct KitRunS129SectionsTests {
    private let common = libDir.appendingPathComponent("common.sh").path
    private let recipes = libDir.appendingPathComponent("recipes.sh").path
    private let s1c = libDir.appendingPathComponent("checks-s1c.sh").path

    /// `s1c_29_sections` with every driver replaced by a recorder. `failOn` is the section whose button cannot be found.
    private func walk(failOn: String = "", openFails: Bool = false) throws -> (Ran, [String]) {
        let fm = FileManager.default
        let log = fm.temporaryDirectory.appendingPathComponent("kitsec29-log-" + UUID().uuidString)
        defer { try? fm.removeItem(at: log) }
        let script = """
        . "\(common)"
        . "\(recipes)"
        . "\(s1c)"
        sleep() { :; }
        NR_WHY=""
        nr_why() { NR_WHY="${NR_WHY:+$NR_WHY; }$1"; }
        nr_set_dump() { NR_SET=""; }
        nr_settings_open() { echo "OPEN" >> "\(log.path)"; \(openFails ? "PN_OUT='no Settings window'; return 1" : "return 0"); }
        settings_section() { echo "SECTION $1" >> "\(log.path)"; if [ "$1" = "\(failOn)" ]; then echo "no sidebar button \\"$1\\" in the Settings window"; return 1; fi; return 0; }
        pn_ax() { echo "PNAX $*" >> "\(log.path)"; return 0; }
        nr_walk() { echo "WALK $1" >> "\(log.path)"; }
        s1c_29_sections
        echo "status $?"
        echo "WHY[$NR_WHY]"
        """
        let ran = try bash(script)
        return (ran, (read(log) ?? "").split(separator: "\n").map(String.init))
    }

    @Test("S1.29 presses the sidebar button of each of the four sections and tab-walks its page, in the order of the sidebar, and never presses About, because the About tab is removed by decision (guide 16.16)")
    func walksFourSections() throws {
        let (ran, calls) = try walk()
        let sections = calls.filter { $0.hasPrefix("SECTION ") }.map { String($0.dropFirst(8)) }
        #expect(sections == ["Folders", "File types", "Search", "Indexing"], "sections pressed: \(sections)")
        #expect(calls.filter { $0 == "WALK settings" }.count == 4, "the Settings window was walked \(calls.filter { $0 == "WALK settings" }.count) times, once per section expected: \(calls)")
        var order: [String] = []
        for c in calls where c.hasPrefix("SECTION ") || c == "WALK settings" { order.append(c.hasPrefix("SECTION ") ? "S" : "W") }
        #expect(order == ["S", "W", "S", "W", "S", "W", "S", "W"], "press and walk interleave as \(order)")
        #expect(lines(ran).contains("Settings sections walked with Tab: 4 of 4"), "the count line is not \"4 of 4\": \(lines(ran))")
        #expect(lines(ran).contains("WHY[]"), "a reason was recorded for a walk where every button was found: \(lines(ran))")
        #expect(!lines(ran).contains { $0.contains("noted") }, "the walk still prints a noted line: \(lines(ran))")
        #expect(!lines(ran).contains { $0.contains("About") } && !calls.contains { $0.contains("About") }, "About is named in the walk: \(lines(ran)) \(calls)")
    }

    private func walkReal(buttons: [String]) throws -> Ran {
        let fm = FileManager.default
        let current = fm.temporaryDirectory.appendingPathComponent("kitsec29-current-" + UUID().uuidString)
        let log = fm.temporaryDirectory.appendingPathComponent("kitsec29-ax-" + UUID().uuidString)
        defer {
            try? fm.removeItem(at: current)
            try? fm.removeItem(at: log)
        }
        let sidebar = buttons.map { "    AXButton label=\"\($0)\"" }.joined(separator: "\\n")
        let panes = sectionControls.map { name, controls in
            "\"\(name)\") printf '%b\\n' '\(controls.map { "    " + $0 }.joined(separator: "\\n"))' ;;"
        }.joined(separator: "\n")
        let script = """
        . "\(common)"
        . "\(recipes)"
        . "\(s1c)"
        sleep() { :; }
        NR_WHY=""
        nr_why() { NR_WHY="${NR_WHY:+$NR_WHY; }$1"; }
        nr_set_dump() { NR_SET=""; }
        nr_settings_open() { return 0; }
        nr_walk() { echo "WALK $1"; }
        kq() {
          echo "${1##*/} $2 $3" >> "\(log.path)"
          case "$2" in
            click)
              case "$3" in
                \(buttons.map { "\"\($0)\"" }.joined(separator: "|"))) printf '%s' "$3" > "\(current.path)"; return 0 ;;
                *) return 1 ;;
              esac ;;
            dump)
              printf 'window 700 x 480 at 100,100 title Settings\\nAXWindow/AXStandardWindow label="Settings"\\n  AXGroup\\n%b\\n' '\(sidebar)'
              case "$(cat "\(current.path)" 2>/dev/null)" in
                \(panes)
              esac ;;
          esac
        }
        s1c_29_sections
        echo "status $?"
        echo "WHY[$NR_WHY]"
        """
        return try bash(script)
    }

    @Test("a fake Settings window with the four sidebar buttons and no About button gives the S1.29 section walk its pass: four of four walked, no reason, no press of About")
    func fourButtonWindowPasses() throws {
        let ran = try walkReal(buttons: ["Folders", "File types", "Search", "Indexing"])
        #expect(lines(ran).filter { $0.hasPrefix("Settings section: ") } == ["Settings section: Folders", "Settings section: File types", "Settings section: Search", "Settings section: Indexing"], "the sections walked: \(lines(ran))")
        #expect(lines(ran).filter { $0 == "WALK settings" }.count == 4, "walks: \(lines(ran))")
        #expect(lines(ran).contains("Settings sections walked with Tab: 4 of 4") && lines(ran).contains("WHY[]"), "the four-button window did not pass: \(lines(ran))")
        #expect(lines(ran).last == "WHY[]" && lines(ran).contains("status 0"), "status or reason: \(lines(ran))")
    }

    @Test("the same fake window with the Search button missing still gives the section walk a reason naming Search and the count \"3 of 4\": a section whose button cannot be found stays a FAIL")
    func fourButtonWindowMissingSearch() throws {
        let ran = try walkReal(buttons: ["Folders", "File types", "Indexing"])
        let why = lines(ran).first { $0.hasPrefix("WHY[") } ?? ""
        #expect(why.contains("Search") && why.contains("only 3 of the 4 Settings sections were walked with Tab"), "reason: \(lines(ran))")
        #expect(lines(ran).contains("Settings sections walked with Tab: 3 of 4"), "count: \(lines(ran))")
    }

    // PLANT: the Search button cannot be found. A pass with a "noted" line is exactly what the review found (R2-06).
    @Test("a sidebar button that cannot be found is a FAIL reason naming the section, and that page is not walked")
    func missingButtonIsAFailure() throws {
        let (ran, calls) = try walk(failOn: "Search")
        let why = lines(ran).first { $0.hasPrefix("WHY[") } ?? ""
        #expect(why.contains("Search") && why != "WHY[]", "no reason names the missing Search button: \(lines(ran))")
        #expect(calls.filter { $0 == "WALK settings" }.count == 3, "the three other pages were not all walked, or the missing one was: \(calls)")
        #expect(!lines(ran).contains { $0.contains("noted") }, "a missing button was passed with a noted line: \(lines(ran))")
    }

    @Test("a Settings window that cannot be put in front is a FAIL reason for every section, never a pass")
    func settingsWindowGone() throws {
        let (ran, calls) = try walk(openFails: true)
        let why = lines(ran).first { $0.hasPrefix("WHY[") } ?? ""
        #expect(why != "WHY[]", "no reason although the Settings window could not be opened: \(lines(ran))")
        #expect(!calls.contains("WALK settings"), "a window that could not be opened was walked")
    }

    @Test("the check's text: the old sidebar-row reader and the \"one page was walked\" pass path are gone")
    func noNotedPath() {
        let t = read(libDir.appendingPathComponent("checks-s1c.sh")).map(stripComments) ?? ""
        let fns = shellFunctions(in: t)
        let body = fns["s1c_29_sections"] ?? ""
        ok(!body.isEmpty, "checks-s1c.sh has no s1c_29_sections")
        ok(!t.contains("noted: the Settings window shows no sidebar rows"), "the \"noted: ... one page was walked\" pass path is still in checks-s1c.sh")
        ok(!has(body, "noted"), "s1c_29_sections still prints a noted line")
        ok(fns["s1c_rows"] == nil, "s1c_rows (the reader of sidebar rows in an AXOutline) is still defined, so the vacuous path can come back")
        for name in ["Folders", "File types", "Search", "Indexing"] {
            ok(body.contains(name), "s1c_29_sections does not name the section \(name)")
        }
        ok(!body.contains("About"), "s1c_29_sections still names the removed About section")
        ok(has(body, "settings_section"), "s1c_29_sections does not press the sidebar button through settings_section")
        ok(has(body, "nr_walk[ ]+settings"), "s1c_29_sections does not tab-walk the Settings window")
    }

    @Test("none of recipes.sh, checks-s1c.sh, checks-s3.sh and checks-s4.sh holds the word About, comments included, because the About tab is removed by decision (guide 16.16); the one match the scan ignores, \"About <time> in total\" (the Setup total line, not a section), is in none of the four files today")
    func noScriptNamesAboutAsASection() {
        let ignored = "About(?! <time> in total)"
        for name in ["recipes.sh", "checks-s1c.sh", "checks-s3.sh", "checks-s4.sh"] {
            let text = read(libDir.appendingPathComponent(name)) ?? ""
            ok(!text.isEmpty, "\(name) could not be read")
            let hits = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .filter { has(String($0.element), "\\b" + ignored + "\\b") }
                .map { "\(name):\($0.offset + 1)" }
            ok(hits.isEmpty, "\(name) still holds the word About at \(hits)")
        }
    }
}
