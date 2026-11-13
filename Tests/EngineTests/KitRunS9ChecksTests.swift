import Foundation
import Testing

private let codeExts = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]
private let folders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]
private let sampleLines = ["a dog on the beach", "the clause about pets in the lease", "where they talk about sleep"]

private final class Rig: @unchecked Sendable {
    let base: String
    let kit: String
    let fake: String
    let scripts: String
    let lib: String

    init() throws {
        base = try KC.tempDir("kit-s9-")
        scripts = base + "/scripts"
        lib = scripts + "/kit-lib"
        kit = base + "/sesame-kit"
        fake = kit + "/fake"
        let fm = FileManager.default
        try fm.copyItem(atPath: KC.scripts, toPath: scripts)
        try fm.createDirectory(atPath: base + "/fixtures", withIntermediateDirectories: true)
        try fm.copyItem(atPath: KC.root.path + "/fixtures/answers.csv", toPath: base + "/fixtures/answers.csv")
        try fm.createDirectory(atPath: fake, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: kit + "/run", withIntermediateDirectories: true)
        try installFakes()
        try standardWorld()
    }

    func put(_ name: String, _ text: String) throws { try KC.write(fake + "/" + name, text) }
    func remove(_ name: String) { try? FileManager.default.removeItem(atPath: fake + "/" + name) }
    func read(_ name: String) -> String { KC.read(fake + "/" + name) ?? "" }
    func log(_ name: String) -> [String] { KC.lines(read(name)) }

    private func script(_ name: String, _ body: String) throws {
        let path = scripts + "/" + name
        try KC.write(path, "#!/bin/bash\n" + body)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func installFakes() throws {
        let slug = #"slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }"#
        try script("kit-ax.sh", """
        \(slug)
        echo "$*" >> "$FAKE/ax.log"
        case "$1" in
          dump)
            case "$2" in
              setup) n="$(cat "$FAKE/step" 2>/dev/null || echo 1)"; f="$FAKE/setup-$n.txt" ;;
              settings) f="$FAKE/settings-$(slug "$(cat "$FAKE/section" 2>/dev/null || echo Folders)").txt" ;;
              menu) f="$FAKE/menu.txt" ;;
              panel)
                q="$(cat "$FAKE/lastq" 2>/dev/null)"
                f="$FAKE/panel-$(slug "$q").txt"
                [ -s "$FAKE/lastq" ] || f="$FAKE/panel-empty.txt"
                if [ -f "$f" ]; then cat "$f"; else printf 'window 960 x 560 at 100, 100\nAXWindow label="Sesame"\n  AXTextField label="Search" value="%s" [focused]\n' "$q"; fi
                exit 0 ;;
            esac
            if [ -f "$f" ]; then cat "$f"; else echo "no window"; exit 1; fi ;;
          click)
            case "$2" in
              Next) n="$(cat "$FAKE/step" 2>/dev/null || echo 1)"; echo $((n + 1)) > "$FAKE/step" ;;
              Folders|"File types"|Search|Indexing) [ -f "$FAKE/stuck" ] || printf '%s\\n' "$2" > "$FAKE/section" ;;
            esac ;;
          read)
            if [ "$2" = panel ]; then [ -f "$FAKE/panelopen" ] || exit 1; echo "panel"; else echo "status item: Ready"; fi ;;
          frontmost) echo Sesame ;;
          hotkey)
            if [ -f "$FAKE/panelopen" ]; then rm -f "$FAKE/panelopen"; else : > "$FAKE/panelopen"; : > "$FAKE/lastq"; fi ;;
        esac
        exit 0
        """)
        try script("kit-search.sh", """
        \(slug)
        echo "$1" >> "$FAKE/search.log"
        printf '%s' "$1" > "$FAKE/lastq"
        : > "$FAKE/panelopen"
        f="$FAKE/search-$(slug "$1").txt"
        if [ -f "$f" ]; then cat "$f"; else printf 'search box label="Search" value="%s"\\nrows 0\\n' "$1"; fi
        exit 0
        """)
        try script("kit-index.sh", """
        echo "$*" >> "$FAKE/index.log"
        case "$1" in
          under) if [ -f "$FAKE/under-$(basename "$2").txt" ]; then cat "$FAKE/under-$(basename "$2").txt"; else echo "0 files under $2"; fi ;;
          has) grep -qxF "$2" "$FAKE/has.txt" ;;
          settings) cat "$FAKE/old-settings.txt" ;;
          wait) exit "${FAKE_WAIT_RC:-0}" ;;
        esac
        """)
        try script("kit-fixtures.sh", """
        echo "$*" >> "$FAKE/fixtures.log"
        if [ "$1" = expect ] && [ "$2" = counts ]; then cat "$FAKE/counts-$(basename "$3").txt"; fi
        exit 0
        """)
        for name in ["kit-launch.sh", "kit-mirror.sh", "kit-perms.sh"] { try script(name, "exit 0\n") }
    }

    func standardWorld() throws {
        try put("step", "1\n")
        try put("setup-1.txt", setupDump(1, "Welcome", ["  AXStaticText label=\"Search your files by describing them.\"", "  AXButton label=\"Next\""]))
        var rows = ""
        for f in folders {
            rows += folderRow(f, "2 photos, about 1 min", "\(kit)/home/\(f)")
            try put("counts-\(f).txt", "photo 2\n")
        }
        rows += folderRow("api-client", "1 photo, 1 document, about 1 min", "\(kit)/home/Developer/api-client")
        try put("counts-api-client.txt", "photo 1\ndocument 3\n")
        try put("setup-2.txt", setupDump(2, "Folders", ["  AXButton label=\"Add folder…\""] + [rows.trimmingCharacters(in: .newlines), "  AXButton label=\"Start indexing\"", "  AXButton label=\"Next\""]))
        try put("setup-3.txt", setupDump(3, "Permissions", ["  AXButton label=\"Back\"", "  AXButton label=\"Next\""]))
        try put("setup-4.txt", setupDump(4, "Shortcut", ["  AXButton label=\"Back\"", "  AXButton label=\"Finish\""]))

        let apiRow = folderRow("api-client", "1 photo, 1 document, about 1 min", "\(kit)/home/Developer/api-client")
        try put("settings-Folders.txt", "AXWindow label=\"Settings\"\n  AXButton label=\"Add folder…\"\n\(apiRow)    AXButton label=\"Re-index\" help=\"api-client\"\n    AXButton label=\"Remove\" help=\"api-client\"\n")
        try put("settings-File_types.txt", "AXWindow label=\"Settings\"\n" + ["Photos", "PDFs", "Documents", "Audio", "Video"].map { "  AXCheckBox label=\"\($0)\" value=\"1\"\n" }.joined())
        try put("settings-Search.txt", "AXWindow label=\"Settings\"\n  AXButton label=\"Record new shortcut\"\n  AXPopUpButton label=\"PDF app\" value=\"Preview\"\n  AXPopUpButton label=\"Media app\" value=\"QuickTime Player\"\n")
        try put("settings-Indexing.txt", "AXWindow label=\"Settings\"\n  AXButton label=\"Start indexing\"\n  AXCheckBox label=\"Launch at login\" value=\"0\"\n")

        try put("menu.txt", "AXMenu label=\"Sesame\"\n" + ["Ready", "Photos 40", "PDFs 20", "Documents 6", "Audio 12", "Video 12", "Pause indexing", "Settings…", "Quit Sesame"].map { "  AXMenuItem label=\"\($0)\"\n" }.joined())

        try put("panel-empty.txt", panel(box: "", extra: hint(sampleLines)))
        try put("panel-code__qwv_zzkx_lorp_mnb.txt", panel(box: "code: qwv zzkx lorp mnb", extra: ["  AXStaticText label=\"No matches\"", "  AXStaticText label=\"Describe what is in the file, or type part of its exact name or text.\""]))
        try put("search-a_dog_on_the_beach.txt", "search box label=\"Search\" value=\"a dog on the beach\"\nrows 1\nrow 1 selected beach-dog.jpg | photos/beach-dog.jpg\n")
        try put("search-code__a_dog_on_the_beach.txt", "search box label=\"Search\" value=\"code: a dog on the beach\"\nrows 1\nrow 1 selected beach-dog.jpg | photos/beach-dog.jpg\n")
        try put("search-retry_a_failed_call_with_backoff.txt", "search box label=\"Search\" value=\"retry a failed call with backoff\"\nrows 2\nrow 1 selected retry-notes.md | docs\nrow 2 - retry-diagram.png | docs\n")
        try put("search-legacy_sync_diagram_old_store_to_new_store.txt", "search box label=\"Search\" value=\"legacy sync diagram old store to new store\"\nrows 1\nrow 1 selected diagram.png | docs\n")

        let docs = ["api-client/docs/retry-notes.md", "api-client/docs/retry-diagram.png", "legacy-sync/docs/diagram.png"]
        try put("has.txt", docs.map { "\(kit)/home/Developer/\($0)" }.joined(separator: "\n") + "\n")
        try put("under-api-client.txt", "\(kit)/home/Developer/api-client/docs/retry-notes.md\tdocument\tdone\n\(kit)/home/Developer/api-client/docs/retry-diagram.png\tphoto\tdone\n2 files under \(kit)/home/Developer/api-client\n")
        try put("under-legacy-sync.txt", "\(kit)/home/Developer/legacy-sync/docs/diagram.png\tphoto\tdone\n1 files under \(kit)/home/Developer/legacy-sync\n")
        try put("under-scratch-lab.txt", "0 files under \(kit)/home/Developer/scratch-lab\n")
        try put("under-matrix.txt", "\(kit)/fixtures/matrix/extdoc/txt_zq1201.txt\tdocument\tdone\n1 files under \(kit)/fixtures/matrix\n")

        try KC.write(kit + "/run/recipe", "upgrade\n")
        try KC.write(kit + "/run/upgrade-code-rows", "3\n")
        try put("old-settings.txt", "{\n  \"codeSearchOn\" => true\n}\n")
        try KC.write(kit + "/run/upgrade-old-settings", "{\n  \"codeSearchOn\" => true\n}\n")
        try KC.write(kit + "/home/Library/Application Support/Sesame/index.sqlite", "x")
        try KC.write(kit + "/home/Library/Application Support/Sesame/settings.json", "{}")
    }

    func useShellDumps() throws {
        let sections = [("Folders", "Folders"), ("File types", "File_types"), ("Search", "Search"), ("Indexing", "Indexing")]
        for (name, slug) in sections {
            let sidebar = sections.map { "  AXCheckBox/AXToggle label=\"\($0.0)\" value=\"\($0.0 == name ? 1 : 0)\"\n" }.joined()
            var body = read("settings-\(slug).txt")
            if slug == "File_types" {
                body = "AXWindow label=\"Settings\"\n" + ["Photos", "PDFs", "Documents", "Audio", "Video"].map { "  AXCheckBox/AXSwitch label=\"\($0)\" value=\"1\"\n" }.joined()
            }
            let first = body.firstIndex(of: "\n").map { body.index(after: $0) } ?? body.endIndex
            try put("settings-\(slug).txt", String(body[..<first]) + sidebar + String(body[first...]))
        }
    }

    func setupDump(_ n: Int, _ name: String, _ lines: [String]) -> String {
        "AXWindow label=\"Sesame\"\n  AXStaticText label=\"Step \(n) of 4: \(name)\"\n" + lines.joined(separator: "\n") + "\n"
    }

    func folderRow(_ name: String, _ detail: String, _ help: String) -> String {
        "  AXCheckBox label=\"\(name)\" desc=\"\(name), \(detail)\" help=\"\(help)\" value=\"1\"\n"
    }

    func panel(box: String, extra: [String]) -> String {
        "window 960 x 560 at 100, 100\nAXWindow label=\"Sesame\"\n  AXTextField label=\"Search\" value=\"\(box)\" [focused]\n" + extra.joined(separator: "\n") + (extra.isEmpty ? "" : "\n")
    }

    func hint(_ samples: [String]) -> [String] {
        ["  AXGroup label=\"Search hint\"", "    AXStaticText label=\"Describe what you want, or type part of a name or text.\""] + samples.map { "    AXStaticText label=\"\($0)\"" }
    }

    func run(_ body: String, plant: Bool = false, limit: TimeInterval = 120) throws -> KC.Ran {
        let script = """
        #!/bin/bash
        export KIT_ROOT="\(kit)" FAKE="\(fake)"
        . "\(lib)/common.sh"
        . "\(lib)/recipes.sh"
        for f in "\(lib)"/checks-*.sh; do [ -f "$f" ] && . "$f"; done
        tree_need() { echo "tree stub"; return "${TREE_RC:-0}"; }
        golden_need() { echo "golden stub"; return "${GOLDEN_RC:-0}"; }
        recipe_setup() { echo "setup stub"; return "${SETUP_RC:-0}"; }
        pick_folders() { return "${PICK_RC:-0}"; }
        settings_open() { return "${SETTINGS_RC:-0}"; }
        wait_menu_ready() { return 0; }
        \(plant ? "KIT_PLANT=1; export KIT_PLANT" : "")
        \(body)
        """
        let path = try KC.tempDir() + "/harness.sh"
        try KC.write(path, script)
        return try KC.run("/bin/bash", [path], env: ["FAKE": fake, "KIT_ROOT": kit], limit: limit)
    }

    func check(_ id: String, plant: Bool = false) throws -> (verdict: String, rc: Int32, output: String) {
        let fn = "check_" + id.replacingOccurrences(of: ".", with: "_")
        let r = try run("\(fn) </dev/null; echo \"RC $?\"", plant: plant)
        let rc = Int32(KC.lines(r.output).last(where: { $0.hasPrefix("RC ") })?.dropFirst(3) ?? "-1") ?? -1
        let verdictLine = KC.lines(r.output).first(where: { $0.hasPrefix("CHECK \(id) ") || $0.hasPrefix("RERUN \(id) ") }) ?? ""
        return (verdictLine, rc, r.output)
    }
}

private func pass(_ r: (verdict: String, rc: Int32, output: String), _ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.verdict.hasPrefix("CHECK \(id) PASS") && r.rc == 0, "\(id) did not pass: rc \(r.rc), \(r.output.suffix(900))", sourceLocation: sourceLocation)
}

private func fail(_ r: (verdict: String, rc: Int32, output: String), _ id: String, mentions: String..., sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.verdict.hasPrefix("CHECK \(id) FAIL") && r.rc == 1, "\(id) did not fail: rc \(r.rc), \(r.output.suffix(900))", sourceLocation: sourceLocation)
    for m in mentions { #expect(r.verdict.localizedCaseInsensitiveContains(m), "the FAIL line of \(id) does not mention \(m): \(r.verdict)", sourceLocation: sourceLocation) }
}

private func rerun(_ r: (verdict: String, rc: Int32, output: String), _ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.verdict.hasPrefix("RERUN \(id) not valid") && r.rc == 4, "\(id) was not a RERUN: rc \(r.rc), \(r.output.suffix(900))", sourceLocation: sourceLocation)
    #expect(!r.output.contains("CHECK \(id) "), "\(id) printed a CHECK line besides the RERUN: \(r.output.suffix(600))", sourceLocation: sourceLocation)
}

@Suite("KitRunS9ChecksTests", .serialized)
struct KitRunS9ChecksTests {
    let ids = ["S9.1", "S9.2", "S9.3", "S9.4", "S9.5", "S9.6"]

    @Test("checks.tsv gains S9.1 to S9.6 at slice 7, S9.6 the one auto-or-person; its own recount is 121 rows, 98 auto, 17 auto-or-person, 6 reading (plan-8-t9 amended: nine S10 rows added after them, so they are no longer the last six; was 112 96 10 6); checks.floor is 93 (91 plus the two S10 auto ids), at most the auto rows; slice is 8")
    func table() throws {
        let rows = KC.checksTSV()
        let s9 = rows.filter { $0.id.hasPrefix("S9.") }
        #expect(s9.map(\.id) == ids, "the S9 rows are \(s9.map(\.id))")
        #expect(s9.map(\.slice) == [7, 7, 7, 7, 7, 7], "the S9 slices are \(s9.map(\.slice))")
        #expect(s9.map(\.kind) == ["auto", "auto", "auto", "auto", "auto", "auto-or-person"], "the S9 kinds are \(s9.map(\.kind))")
        #expect(rows.dropLast(9).suffix(6).map(\.id) == ids, "the S9 rows are not the six rows before the S10 rows")
        let r = try KC.run("/usr/bin/awk", ["-F\t", "{ n++; c[$3]++ } END { print n, c[\"auto\"], c[\"auto-or-person\"], c[\"reading\"] }", KC.lib + "/checks.tsv"])
        #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "121 98 17 6", "rows, auto, auto-or-person, reading are \(r.output)")
        let floor = Int((KC.read(KC.lib + "/checks.floor") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(floor == 93, "checks.floor reads \(floor.map(String.init) ?? "nothing"), 91 + 2 = 93")
        #expect((floor ?? 999) <= 98, "the floor is above the 98 auto rows")
        #expect((KC.read(KC.lib + "/slice") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "8", "slice does not hold 8")
    }

    @Test("checks-s9.sh exists, parses, and defines check_S9_1 to check_S9_6; no check calls the product or reads a source file")
    func fileShape() throws {
        let text = KC.read(KC.lib + "/checks-s9.sh") ?? ""
        #expect(!text.isEmpty, "scripts/kit-lib/checks-s9.sh does not exist")
        for id in ids { #expect(text.contains("check_" + id.replacingOccurrences(of: ".", with: "_") + "()"), "no function for \(id)") }
        let r = try KC.run("/bin/bash", ["-n", KC.lib + "/checks-s9.sh"])
        #expect(r.status == 0 && !text.isEmpty, "bash -n: \(r.output)")
        #expect(!KC.has(text, #"(^|\n)[ ]*#"#), "checks-s9.sh holds a comment line")
        #expect(!text.contains("Sources/") && !text.contains("sqlite3") && !text.contains("plutil"), "checks-s9.sh reads source, sqlite or a plist itself")
    }

    @Test("kit-run.sh dispatches S9 to its checks, rejects S11, S5 and an unknown S9 id with the usage that lists S9 and prep upgrade")
    func dispatch() throws {
        let rig = try Rig()
        try KC.write(rig.lib + "/checks-zz.sh", "check_S9_1() { echo \"CHECK S9.1 PASS dispatched\"; }\n")
        let env = ["FAKE": rig.fake, "KIT_ROOT": rig.kit, "KIT_NO_EVIDENCE": "1"]
        let ok = try KC.run(rig.scripts + "/kit-run.sh", ["S9", "--ids", "S9.1"], env: env)
        #expect(ok.status == 0 && ok.output.contains("CHECK S9.1 PASS dispatched") && ok.output.contains("CHECKS: 1 passed, 0 failed"), "S9 --ids S9.1: \(ok.status) \(ok.output)")
        let usage = try KC.run(rig.scripts + "/kit-run.sh", ["S11"], env: env)
        #expect(usage.status == 2, "S11 exited \(usage.status)")
        #expect(usage.output.contains("S6..S10") && usage.output.contains("kit-run.sh prep upgrade"), "the usage does not list S9 and prep upgrade: \(usage.output)")
        for args in [["S5"], ["S9", "--ids", "S9.7"], ["S9", "--ids", "S8.1"]] {
            let r = try KC.run(rig.scripts + "/kit-run.sh", args, env: env)
            #expect(r.status == 2, "\(args) exited \(r.status): \(r.output)")
        }
        let all = try KC.run(rig.scripts + "/kit-run.sh", ["S9", "--slice", "6"], env: env)
        #expect(all.output.contains("no check of S9 is first drivable in slice 6"), "S9 at slice 6 runs something: \(all.output)")
    }

    @Test("S9.1 passes on four clean Setup steps whose Folders step lists the five suggested folders with counts, api-client with its documents and picture, Start indexing and a folder named for code")
    func s91Pass() throws {
        let rig = try Rig()
        let row = rig.folderRow("Xcode-notes", "2 photos, about 1 min", "\(rig.kit)/home/Xcode-notes")
        try rig.put("setup-2.txt", rig.read("setup-2.txt") + row)
        try rig.put("counts-Xcode-notes.txt", "photo 2\n")
        pass(try rig.check("S9.1"), "S9.1")
        let picks = rig.log("ax.log").filter { $0 == "click Next" }
        #expect(picks.count == 3, "Next was pressed \(picks.count) times, the four steps need 3")
        #expect(rig.log("fixtures.log").contains("build repos"), "the golden repos were not built")
    }

    @Test("S9.1 fails on code wording in any step, naming the step, and on an api-client row that counts a code file")
    func s91Fails() throws {
        for n in 1...4 {
            let rig = try Rig()
            try rig.put("setup-\(n).txt", rig.read("setup-\(n).txt") + "  AXStaticText label=\"Search my code\"\n")
            fail(try rig.check("S9.1"), "S9.1", mentions: "code")
        }
        let rig = try Rig()
        try rig.put("setup-2.txt", rig.read("setup-2.txt").replacingOccurrences(of: "1 photo, 1 document, about 1 min", with: "1 photo, 1 document, 9 code files, about 1 min"))
        fail(try rig.check("S9.1"), "S9.1", mentions: "api-client")
        for shown in ["3 documents", "5 documents"] {
            let wrong = try Rig()
            try wrong.put("setup-2.txt", wrong.read("setup-2.txt").replacingOccurrences(of: "api-client, 1 photo, 1 document", with: "api-client, 1 photo, \(shown)"))
            fail(try wrong.check("S9.1"), "S9.1", mentions: "api-client")
        }
    }

    @Test("S9.1 expects one document for api-client, the key-named id_rsa.txt and .env.local.md never counted: a row of three documents fails, a row of one passes, and the expected count is one")
    func s91ExpectsOneDocument() throws {
        let rig = try Rig()
        pass(try rig.check("S9.1"), "S9.1")
        let counted = try rig.run("s6b_expected \"$KIT_ROOT/home/Developer/api-client\" | LC_ALL=C sort")
        #expect(KC.lines(counted.output) == ["document 1", "photo 1"], "the expected counts of api-client are \(KC.lines(counted.output)), by hand: 1 document and 1 photo")
        let desktop = try rig.run("s6b_expected \"$KIT_ROOT/home/Desktop\"")
        #expect(KC.lines(desktop.output) == ["photo 2"], "the expected counts of Desktop are \(KC.lines(desktop.output)), the hand value is photo 2")
        let three = try Rig()
        try three.put("setup-2.txt", three.read("setup-2.txt").replacingOccurrences(of: "api-client, 1 photo, 1 document", with: "api-client, 1 photo, 3 documents"))
        let r = try three.check("S9.1")
        fail(r, "S9.1", mentions: "document")
    }

    @Test("S9.1 fails on a Folders row for legacy-sync or scratch-lab: no repo is suggested")
    func s91NoRepoRows() throws {
        for repo in ["legacy-sync", "scratch-lab"] {
            let rig = try Rig()
            try rig.put("setup-2.txt", rig.read("setup-2.txt") + rig.folderRow(repo, "1 photo, about 1 min", "\(rig.kit)/home/Developer/\(repo)"))
            fail(try rig.check("S9.1"), "S9.1", mentions: repo)
        }
    }

    @Test("S9.1 is exit 4, never a pass or a FAIL, when its control does not hold: no Start indexing, no folder rows, a step header missing, the window unreadable, the picker or the state failing")
    func s91Reruns() throws {
        let lackStart = try Rig()
        try lackStart.put("setup-2.txt", lackStart.read("setup-2.txt").replacingOccurrences(of: "  AXButton label=\"Start indexing\"\n", with: ""))
        rerun(try lackStart.check("S9.1"), "S9.1")
        let lackRows = try Rig()
        try lackRows.put("setup-2.txt", lackRows.setupDump(2, "Folders", ["  AXButton label=\"Start indexing\""]))
        rerun(try lackRows.check("S9.1"), "S9.1")
        let lackHeader = try Rig()
        try lackHeader.put("setup-3.txt", "AXWindow label=\"Sesame\"\n  AXButton label=\"Next\"\n")
        rerun(try lackHeader.check("S9.1"), "S9.1")
        let gone = try Rig()
        gone.remove("setup-1.txt")
        let r = try gone.check("S9.1")
        rerun(r, "S9.1")
        #expect(r.output.contains("kit-ax dump setup exited 1") || r.output.contains("no window"), "the driver's output was not printed: \(r.output.suffix(400))")
        let state = try Rig()
        let failedState = try state.run("SETUP_RC=1; check_S9_1; echo \"RC $?\"")
        #expect(failedState.output.contains("RERUN S9.1 not valid") && failedState.output.contains("RC 4"), "a failed starting state is not a RERUN: \(failedState.output.suffix(400))")
        let picker = try Rig()
        let failedPick = try picker.run("PICK_RC=3; check_S9_1; echo \"RC $?\"")
        #expect(failedPick.output.contains("RERUN S9.1 not valid") && failedPick.output.contains("RC 4") && !failedPick.output.contains("CHECK S9.1"), "a picker that cannot be driven is not a RERUN: \(failedPick.output.suffix(400))")
    }

    @Test("S9.2 passes on four clean Settings sections (the About tab is removed by decision, guide 16.16): File types lists exactly Photos, PDFs, Documents, Audio and Video, Search has two pop-ups, the api-client row shows counts and a time, and no section named About is pressed")
    func s92Pass() throws {
        let rig = try Rig()
        pass(try rig.check("S9.2"), "S9.2")
        let clicks = rig.log("ax.log").filter { ["Folders", "File types", "Search", "Indexing", "About"].map { "click " + $0 }.contains($0) }
        #expect(clicks == ["click Folders", "click File types", "click Search", "click Indexing"], "the sections were pressed as \(clicks)")
    }

    @Test("S9.2 is not a RERUN for a section About that the four-section Settings window no longer has, and its done text says four sections")
    func s92DoneTextSaysFour() throws {
        let rig = try Rig()
        let r = try rig.check("S9.2")
        pass(r, "S9.2")
        #expect(r.verdict.contains("the four Settings sections") && !r.verdict.contains("five"), "the S9.2 verdict counts the sections wrongly: \(r.verdict)")
        #expect(!r.output.contains("About"), "S9.2 still names About: \(r.output.suffix(400))")
    }

    @Test("neither checks-s9.sh nor checks-s8c.sh names About as a Settings section: a text scan, the word About whole, comments included; no match is ignored")
    func noScriptNamesAboutAsASection() {
        for name in ["checks-s9.sh", "checks-s8c.sh"] {
            let text = KC.read(KC.lib + "/" + name) ?? ""
            #expect(!text.isEmpty, "\(name) is empty or missing")
            let hits = KC.lines(text).enumerated().filter { KC.has($0.element, #"\bAbout\b"#) }.map { "\($0.offset + 1): \($0.element)" }
            #expect(hits.isEmpty, "\(name) names About: \(hits)")
        }
    }

    @Test("S9.2 on the real Settings shape: the four sidebar buttons are AXCheckBox/AXToggle in every Settings dump and the five kinds are AXCheckBox/AXSwitch, so File types lists exactly the five kinds and the sidebar buttons are not read as file kinds (guide 16.1, 16.12, 16.16)")
    func s92ReadsFiveKindsBesideTheSidebarToggles() throws {
        let rig = try Rig()
        try rig.useShellDumps()
        let r = try rig.check("S9.2")
        pass(r, "S9.2")
        let clicks = rig.log("ax.log").filter { ["Folders", "File types", "Search", "Indexing", "About"].map { "click " + $0 }.contains($0) }
        #expect(clicks == ["click Folders", "click File types", "click Search", "click Indexing"], "the sections were pressed as \(clicks)")
        let planted = try rig.check("S9.2", plant: true)
        #expect(planted.verdict.hasPrefix("CHECK S9.2 FAIL planted") && planted.rc == 1, "S9.2 --plant on the shell world: rc \(planted.rc), \(planted.output.suffix(400))")
    }

    @Test("S9.2 on the real Settings shape still fails when a real extra kind appears: a sixth AXCheckBox/AXSwitch, a sixth plain AXCheckBox, a sixth AXCheckBox/AXToggle with a name that is no sidebar button (About included), a missing kind; the exemption is the four sidebar names as AXCheckBox/AXToggle and nothing else")
    func s92ShellWorldStillFailsOnARealExtraKind() throws {
        let extras = [
            "  AXCheckBox/AXSwitch label=\"Archives\" value=\"1\"\n",
            "  AXCheckBox label=\"Archives\" value=\"1\"\n",
            "  AXCheckBox/AXToggle label=\"Archives\" value=\"0\"\n",
            "  AXCheckBox/AXToggle label=\"About\" value=\"0\"\n",
            "  AXCheckBox/AXSwitch label=\"Folders\" value=\"1\"\n",
        ]
        for extra in extras {
            let rig = try Rig()
            try rig.useShellDumps()
            try rig.put("settings-File_types.txt", rig.read("settings-File_types.txt") + extra)
            fail(try rig.check("S9.2"), "S9.2", mentions: "File types")
        }
        let fewer = try Rig()
        try fewer.useShellDumps()
        try fewer.put("settings-File_types.txt", fewer.read("settings-File_types.txt").replacingOccurrences(of: "  AXCheckBox/AXSwitch label=\"Video\" value=\"1\"\n", with: ""))
        fail(try fewer.check("S9.2"), "S9.2", mentions: "File types")
    }

    @Test("S9.2 fails on code wording in any section, a sixth kind, a third pop-up, and an api-client row with a size or \"not read yet\"")
    func s92Fails() throws {
        for section in ["Folders", "File_types", "Search", "Indexing"] {
            let rig = try Rig()
            try rig.put("settings-\(section).txt", rig.read("settings-\(section).txt") + "  AXStaticText label=\"Code editor\"\n")
            fail(try rig.check("S9.2"), "S9.2", mentions: "code")
        }
        let kinds = try Rig()
        try kinds.put("settings-File_types.txt", kinds.read("settings-File_types.txt") + "  AXCheckBox label=\"Archives\" value=\"1\"\n")
        fail(try kinds.check("S9.2"), "S9.2", mentions: "File types")
        let fewer = try Rig()
        try fewer.put("settings-File_types.txt", fewer.read("settings-File_types.txt").replacingOccurrences(of: "  AXCheckBox label=\"Video\" value=\"1\"\n", with: ""))
        fail(try fewer.check("S9.2"), "S9.2", mentions: "File types")
        let pops = try Rig()
        try pops.put("settings-Search.txt", pops.read("settings-Search.txt") + "  AXPopUpButton label=\"Other app\" value=\"x\"\n")
        fail(try pops.check("S9.2"), "S9.2", mentions: "pop-up")
        for bad in ["1 photo, 1 document, not read yet", "1 photo, 1 document, 120 KB, about 1 min"] {
            let rig = try Rig()
            try rig.put("settings-Folders.txt", rig.read("settings-Folders.txt").replacingOccurrences(of: "1 photo, 1 document, about 1 min", with: bad))
            fail(try rig.check("S9.2"), "S9.2", mentions: "api-client")
        }
        let nocount = try Rig()
        try nocount.put("settings-Folders.txt", nocount.read("settings-Folders.txt").replacingOccurrences(of: "1 photo, 1 document, about 1 min", with: "1 photo, about 1 min"))
        fail(try nocount.check("S9.2"), "S9.2", mentions: "api-client")
    }

    @Test("S9.2 is exit 4 when a section never opens, the api-client row is missing, the Settings window is unreadable, or the state fails")
    func s92Reruns() throws {
        let stuck = try Rig()
        try KC.write(stuck.fake + "/stuck", "1")
        stuck.remove("section")
        try stuck.put("settings-Folders.txt", "AXWindow label=\"Settings\"\n")
        rerun(try stuck.check("S9.2"), "S9.2")
        let norow = try Rig()
        try norow.put("settings-Folders.txt", "AXWindow label=\"Settings\"\n  AXButton label=\"Add folder…\"\n")
        rerun(try norow.check("S9.2"), "S9.2")
        let state = try Rig()
        let r = try state.run("TREE_RC=4; check_S9_2; echo \"RC $?\"")
        #expect(r.output.contains("RERUN S9.2 not valid") && r.output.contains("RC 4"), "a failed tree state is not a RERUN: \(r.output.suffix(300))")
        let wait = try Rig()
        let w = try wait.run("export FAKE_WAIT_RC=1; check_S9_2; echo \"RC $?\"")
        #expect(w.output.contains("RERUN S9.2 not valid") && w.output.contains("RC 4"), "indexing that does not finish is not a RERUN: \(w.output.suffix(300))")
    }

    @Test("S9.3 passes on a menu with its status line and counts lines and no code, fails on a Code count line or any item with code, and is exit 4 without its status line or counts")
    func s93() throws {
        let ok = try Rig()
        pass(try ok.check("S9.3"), "S9.3")
        let line = try Rig()
        try line.put("menu.txt", line.read("menu.txt") + "  AXMenuItem label=\"Code 5\"\n")
        fail(try line.check("S9.3"), "S9.3", mentions: "code")
        let item = try Rig()
        try item.put("menu.txt", item.read("menu.txt") + "  AXMenuItem label=\"Open in code editor\"\n")
        fail(try item.check("S9.3"), "S9.3", mentions: "code")
        let nostatus = try Rig()
        try nostatus.put("menu.txt", nostatus.read("menu.txt").replacingOccurrences(of: "  AXMenuItem label=\"Ready\"\n", with: ""))
        rerun(try nostatus.check("S9.3"), "S9.3")
        let nocounts = try Rig()
        try nocounts.put("menu.txt", "AXMenu label=\"Sesame\"\n  AXMenuItem label=\"Ready\"\n  AXMenuItem label=\"Quit Sesame\"\n")
        rerun(try nocounts.check("S9.3"), "S9.3")
        let gone = try Rig()
        gone.remove("menu.txt")
        rerun(try gone.check("S9.3"), "S9.3")
    }

    @Test("S9.4 passes: the plain control finds beach-dog.jpg, code: text shows no code notice, a no-match code: text says No matches with its hint, code: alone leaves its value and no hint group, the empty box shows the three samples")
    func s94Pass() throws {
        let rig = try Rig()
        pass(try rig.check("S9.4"), "S9.4")
        #expect(rig.log("search.log") == ["a dog on the beach", "code: a dog on the beach", "code: retry a failed call", "code: qwv zzkx lorp mnb", "code:"], "the searches were \(rig.log("search.log"))")
    }

    @Test("S9.4 fails when code: a dog on the beach lists no beach-dog.jpg, the positive control that code: text is searched like any other text, even with no notice and no code row")
    func s94ControlFails() throws {
        let empty = try Rig()
        try empty.put("search-code__a_dog_on_the_beach.txt", "search box label=\"Search\" value=\"code: a dog on the beach\"\nrows 0\n")
        fail(try empty.check("S9.4"), "S9.4", mentions: "beach-dog.jpg")
        let other = try Rig()
        try other.put("search-code__a_dog_on_the_beach.txt", "search box label=\"Search\" value=\"code: a dog on the beach\"\nrows 1\nrow 1 selected retry-notes.md | docs\n")
        fail(try other.check("S9.4"), "S9.4", mentions: "beach-dog.jpg")
    }

    @Test("S9.4 fails on a code notice, a no-match without its text, code: with a hint group or a sample, a changed box value, a code row, and a wrong or reordered sample list")
    func s94Fails() throws {
        let notice = try Rig()
        try notice.put("panel-code__retry_a_failed_call.txt", notice.panel(box: "code: retry a failed call", extra: ["  AXStaticText label=\"Code search is off. Turn it on in Settings, File types.\""]))
        fail(try notice.check("S9.4"), "S9.4", mentions: "code search")
        let nofolders = try Rig()
        try nofolders.put("panel-code__retry_a_failed_call.txt", nofolders.panel(box: "code: retry a failed call", extra: ["  AXStaticText label=\"No code folders are ticked.\""]))
        fail(try nofolders.check("S9.4"), "S9.4", mentions: "code")
        let nomatch = try Rig()
        try nomatch.put("panel-code__qwv_zzkx_lorp_mnb.txt", nomatch.panel(box: "code: qwv zzkx lorp mnb", extra: []))
        fail(try nomatch.check("S9.4"), "S9.4", mentions: "No matches")
        let off = try Rig()
        try off.put("panel-code__qwv_zzkx_lorp_mnb.txt", off.panel(box: "code: qwv zzkx lorp mnb", extra: ["  AXStaticText label=\"No matches\"", "  AXStaticText label=\"Describe what is in the file, or type part of its exact name or text.\"", "  AXStaticText label=\"Code search is off\""]))
        fail(try off.check("S9.4"), "S9.4", mentions: "code search")
        let group = try Rig()
        try group.put("panel-code_.txt", group.panel(box: "code:", extra: group.hint(sampleLines)))
        fail(try group.check("S9.4"), "S9.4", mentions: "Search hint")
        let sample = try Rig()
        try sample.put("panel-code_.txt", sample.panel(box: "code:", extra: ["  AXStaticText label=\"where they talk about sleep\""]))
        fail(try sample.check("S9.4"), "S9.4", mentions: "where they talk about sleep")
        let value = try Rig()
        try value.put("search-code_.txt", "search box label=\"Search\" value=\"\"\nrows 0\n")
        fail(try value.check("S9.4"), "S9.4", mentions: "code:")
        let row = try Rig()
        try row.put("search-code__retry_a_failed_call.txt", "search box label=\"Search\" value=\"code: retry a failed call\"\nrows 1\nrow 1 selected retry.swift | api-client\n")
        fail(try row.check("S9.4"), "S9.4", mentions: "retry.swift")
        for samples in [Array(sampleLines.prefix(2)), ["a dog on the beach", "where they talk about sleep", "the clause about pets in the lease"], sampleLines + ["code: retry a failed call with backoff"], ["a dog on the beach", "the clause about pets in the lease", "code: retry a failed call with backoff"]] {
            let rig = try Rig()
            try rig.put("panel-empty.txt", rig.panel(box: "", extra: rig.hint(samples)))
            fail(try rig.check("S9.4"), "S9.4", mentions: "sample")
        }
    }

    @Test("S9.4 is exit 4 when the plain control does not list beach-dog.jpg, a search fails, or the golden state cannot be made")
    func s94Reruns() throws {
        let control = try Rig()
        try control.put("search-a_dog_on_the_beach.txt", "search box label=\"Search\" value=\"a dog on the beach\"\nrows 0\n")
        rerun(try control.check("S9.4"), "S9.4")
        let state = try Rig()
        let r = try state.run("GOLDEN_RC=4; check_S9_4; echo \"RC $?\"")
        #expect(r.output.contains("RERUN S9.4 not valid") && r.output.contains("RC 4"), "a failed golden state is not a RERUN: \(r.output.suffix(300))")
        let broken = try Rig()
        try broken.put("search-a_dog_on_the_beach.txt", "")
        let search = try broken.run("kq() { if [ \"$2\" = \"a dog on the beach\" ]; then echo \"boom\"; return 1; fi; KIT_NO_EVIDENCE=1 \"$@\"; }; check_S9_4; echo \"RC $?\"")
        #expect(search.output.contains("RERUN S9.4 not valid") && search.output.contains("boom") && search.output.contains("RC 4"), "a failed search is not a printed RERUN: \(search.output.suffix(300))")
    }

    @Test("S9.5 passes: no code path under the three repos or the matrix, none of the four function names (read from repos.tsv) returns a code path with or without code:, the three documents are in the index and found")
    func s95Pass() throws {
        let rig = try Rig()
        pass(try rig.check("S9.5"), "S9.5")
        let searches = rig.log("search.log")
        for name in ["retryWithBackoff", "refreshAccessToken", "mergeStaleRecords", "parseLooseDates"] {
            #expect(searches.contains(name) && searches.contains("code: " + name), "\(name) was not searched plain and with code: in \(searches)")
        }
        #expect(searches.contains("retry a failed call with backoff") && searches.contains("legacy sync diagram old store to new store"), "the description searches are missing: \(searches)")
    }

    @Test("S9.5 reads its function names from the def lines of repos.tsv: a copy with retryWithBackoff renamed changes the searched word")
    func s95NamesFromRepos() throws {
        let rig = try Rig()
        let path = rig.lib + "/repos.tsv"
        let text = (KC.read(path) ?? "").replacingOccurrences(of: "retryWithBackoff", with: "retryZed")
        try KC.write(path, text)
        try KC.write(rig.base + "/fixtures/answers.csv", (KC.read(rig.base + "/fixtures/answers.csv") ?? "").replacingOccurrences(of: "retryWithBackoff", with: "answersWord"))
        pass(try rig.check("S9.5"), "S9.5")
        let searches = rig.log("search.log")
        #expect(searches.contains("retryZed") && searches.contains("code: retryZed") && !searches.contains("retryWithBackoff") && !searches.contains("answersWord"), "the searched words are \(searches)")
    }

    @Test("S9.5 fails on a code path under any picked folder, and on a function-name search that returns a code path")
    func s95Fails() throws {
        for repo in ["api-client", "legacy-sync", "scratch-lab"] {
            let rig = try Rig()
            let bad = "\(rig.kit)/home/Developer/\(repo)/src/main.swift\tcode\tdone\n"
            try rig.put("under-\(repo).txt", rig.read("under-\(repo).txt") + bad)
            fail(try rig.check("S9.5"), "S9.5", mentions: "main.swift")
        }
        let cells = try Rig()
        try cells.put("under-matrix.txt", cells.read("under-matrix.txt") + codeExts.map { "\(cells.kit)/fixtures/matrix/ext-\($0)/x_zq1.\($0)\tcode\tdone\n" }.joined())
        let each = try cells.run("""
        for ext in \(codeExts.joined(separator: " ")); do
          printf 'row %s\\n' "/m/x_zq1.$ext" | code_ext_rows | grep -c "\\.$ext" | sed "s/^/$ext /"
        done
        printf 'row /m/page.html /m/style.css /m/note.txt /m/pic.png /m/a.md\\n' | code_ext_rows | wc -l
        """)
        #expect(KC.lines(each.output).dropLast().allSatisfy { $0.hasSuffix(" 1") } && KC.lines(each.output).count == 16 && KC.lines(each.output).last?.trimmingCharacters(in: .whitespaces) == "0", "code_ext_rows by extension: \(each.output)")
        fail(try cells.check("S9.5"), "S9.5", mentions: ".swift")
        for query in ["retryWithBackoff", "code: parseLooseDates"] {
            let rig = try Rig()
            let slug = String(query.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            try rig.put("search-\(slug).txt", "search box label=\"Search\" value=\"\(query)\"\nrows 1\nrow 1 selected dates.swift | scratch-lab\n")
            fail(try rig.check("S9.5"), "S9.5", mentions: "dates.swift")
        }
    }

    @Test("S9.5 is exit 4 when a positive control is missing: a document or picture not in the index, a description search that does not list it, the matrix listing without its extdoc-txt cell, or the state fails")
    func s95Reruns() throws {
        for dropped in ["retry-notes.md", "retry-diagram.png", "diagram.png"] {
            let rig = try Rig()
            let kept = rig.read("has.txt").split(separator: "\n").filter { !$0.hasSuffix(dropped) || (dropped == "diagram.png" && $0.hasSuffix("retry-diagram.png")) }
            try rig.put("has.txt", kept.joined(separator: "\n") + "\n")
            rerun(try rig.check("S9.5"), "S9.5")
        }
        let found = try Rig()
        try found.put("search-retry_a_failed_call_with_backoff.txt", "search box label=\"Search\" value=\"x\"\nrows 1\nrow 1 selected retry-notes.md | docs\n")
        rerun(try found.check("S9.5"), "S9.5")
        let legacy = try Rig()
        try legacy.put("search-legacy_sync_diagram_old_store_to_new_store.txt", "search box label=\"Search\" value=\"x\"\nrows 0\n")
        rerun(try legacy.check("S9.5"), "S9.5")
        let emptyMatrix = try Rig()
        try emptyMatrix.put("under-matrix.txt", "0 files under \(emptyMatrix.kit)/fixtures/matrix\n")
        rerun(try emptyMatrix.check("S9.5"), "S9.5")
        let otherCellMatrix = try Rig()
        try otherCellMatrix.put("under-matrix.txt", "\(otherCellMatrix.kit)/fixtures/matrix/plain/doc_zq0002.txt\tdocument\tdone\n1 files under x\n")
        rerun(try otherCellMatrix.check("S9.5"), "S9.5")
        let state = try Rig()
        let r = try state.run("TREE_RC=3; check_S9_5; echo \"RC $?\"")
        #expect(r.output.contains("RERUN S9.5 not valid") && r.output.contains("RC 4"), "a failed tree state is not a RERUN: \(r.output.suffix(300))")
    }

    @Test("S9.6 passes after prep upgrade: old code rows and old settings were there before, Settings, the menu and the panel show no code and no error, and no code row is in the index after the first walk")
    func s96Pass() throws {
        let rig = try Rig()
        pass(try rig.check("S9.6"), "S9.6")
        #expect(rig.log("index.log").contains("wait walked 600"), "the first walk was not waited for: \(rig.log("index.log"))")
    }

    @Test("S9.6 fails on a code row after the walk, code wording, a code result row, and error text in the panel, Settings or the menu")
    func s96Fails() throws {
        let row = try Rig()
        try row.put("under-api-client.txt", row.read("under-api-client.txt") + "\(row.kit)/home/Developer/api-client/retry.swift\tcode\tdone\n")
        fail(try row.check("S9.6"), "S9.6", mentions: "retry.swift")
        let wording = try Rig()
        try wording.put("settings-File_types.txt", wording.read("settings-File_types.txt") + "  AXCheckBox label=\"Code\" value=\"1\"\n")
        fail(try wording.check("S9.6"), "S9.6", mentions: "code")
        let result = try Rig()
        try result.put("search-retryWithBackoff.txt", "search box label=\"Search\" value=\"x\"\nrows 1\nrow 1 selected retry.swift | api-client\n")
        fail(try result.check("S9.6"), "S9.6", mentions: "retry.swift")
        for (file, content) in [("menu.txt", "  AXMenuItem label=\"May be missing:\"\n"), ("settings-Indexing.txt", "  AXStaticText label=\"Settings error 12\"\n")] {
            let rig = try Rig()
            try rig.put(file, rig.read(file) + content)
            fail(try rig.check("S9.6"), "S9.6", mentions: "error")
        }
    }

    @Test("S9.6 passes when a result row of the panel is named screenshot-browser-error.png: a file name, a path or a row value is not an error state")
    func s96ErrorNamedRowPasses() throws {
        let rig = try Rig()
        try rig.put("panel-retryWithBackoff.txt", rig.panel(box: "retryWithBackoff", extra: [
            "  AXTable label=\"Results\"",
            "    AXRow",
            "      AXStaticText label=\"retry-notes.md\"",
            "    AXRow",
            "      AXStaticText label=\"screenshot-browser-error.png\" help=\"\(rig.kit)/home/Pictures/photos/screenshot-browser-error.png\" value=\"went wrong: may be missing\"",
            "      AXStaticText label=\"photos/screenshot-browser-error.png\""
        ]))
        try rig.put("search-retryWithBackoff.txt", "search box label=\"Search\" value=\"retryWithBackoff\"\nrows 2\nrow 1 selected retry-notes.md | docs\nrow 2 - screenshot-browser-error.png | photos\n")
        pass(try rig.check("S9.6"), "S9.6")
    }

    @Test("S9.6 still fails on a planted SearchFailedView in the panel: its label \"Could not search just now\" or its hint \"Try typing again in a moment.\"")
    func s96SearchFailedViewFails() throws {
        for extra in [
            ["  AXGroup label=\"Could not search just now\"", "    AXStaticText label=\"Could not search just now\"", "    AXStaticText label=\"Try typing again in a moment.\""],
            ["  AXGroup label=\"Could not search just now\""],
            ["  AXStaticText label=\"Try typing again in a moment.\""]
        ] {
            let rig = try Rig()
            try rig.put("panel-retryWithBackoff.txt", rig.panel(box: "retryWithBackoff", extra: extra))
            fail(try rig.check("S9.6"), "S9.6", mentions: "error", "panel")
        }
    }

    @Test("S9.2 and S9.3 print a progress line every S9_TICK seconds while the tree state is made, instead of nothing until it finishes")
    func treeStateStreamsProgress() throws {
        let rig = try Rig()
        let r = try rig.run("tree_need() { sleep 3; echo \"tree stub\"; }; S9_TICK=1; check_S9_2 </dev/null; echo \"RC $?\"")
        let progress = KC.lines(r.output).filter { $0.hasPrefix("recipe tree: still running") }
        #expect(progress.count >= 2, "no progress lines while the tree state was made: \(r.output.suffix(600))")
        #expect(r.output.contains("recipe tree: tree stub") && r.output.contains("CHECK S9.2 PASS") && r.output.contains("RC 0"), "the check no longer passes with the progress ticker: \(r.output.suffix(600))")
        let first = KC.lines(r.output).firstIndex { $0.hasPrefix("recipe tree: still running") } ?? Int.max
        let stub = KC.lines(r.output).firstIndex { $0 == "recipe tree: tree stub" } ?? -1
        #expect(first < stub, "the progress came after the recipe's own output, not while it ran")
    }

    @Test("S9.6 is NEEDS-A-PERSON when the old build left no state, and exit 4 when prep upgrade was not run, the old index held no code row, or the old settings are not old")
    func s96States() throws {
        let none = try Rig()
        try? FileManager.default.removeItem(atPath: none.kit + "/home")
        try KC.write(none.kit + "/run/recipe", "golden\n")
        let a = try none.check("S9.6")
        #expect(a.verdict.hasPrefix("CHECK S9.6 NEEDS-A-PERSON") && a.rc == 0, "no old state: \(a.output.suffix(300))")
        let notRun = try Rig()
        try KC.write(notRun.kit + "/run/recipe", "golden\n")
        rerun(try notRun.check("S9.6"), "S9.6")
        let zero = try Rig()
        try KC.write(zero.kit + "/run/upgrade-code-rows", "0\n")
        rerun(try zero.check("S9.6"), "S9.6")
        let missing = try Rig()
        try? FileManager.default.removeItem(atPath: missing.kit + "/run/upgrade-code-rows")
        rerun(try missing.check("S9.6"), "S9.6")
        let settings = try Rig()
        try KC.write(settings.kit + "/run/upgrade-old-settings", "{\n}\n")
        rerun(try settings.check("S9.6"), "S9.6")
        let walk = try Rig()
        let w = try walk.run("export FAKE_WAIT_RC=1; check_S9_6; echo \"RC $?\"")
        #expect(w.output.contains("RERUN S9.6 not valid") && w.output.contains("RC 4"), "a walk that never ends is not a RERUN: \(w.output.suffix(300))")
    }

    @Test("every S9 check, run with --plant, prints CHECK <id> FAIL planted and exits 1; S9.4 types a text that holds a code word")
    func plants() throws {
        for id in ids {
            let rig = try Rig()
            let r = try rig.check(id, plant: true)
            #expect(r.verdict.hasPrefix("CHECK \(id) FAIL planted") && r.rc == 1, "\(id) --plant: rc \(r.rc), \(r.output.suffix(600))")
        }
        let rig = try Rig()
        _ = try rig.check("S9.4", plant: true)
        #expect(rig.log("search.log").contains(where: { $0.localizedCaseInsensitiveContains("code search") }), "the S9.4 plant typed \(rig.log("search.log"))")
        let control = try Rig()
        let planted = try control.check("S9.4", plant: true)
        #expect(planted.verdict.contains("beach-dog.jpg"), "the S9.4 plant does not trip the code: control: \(planted.verdict)")
        #expect(control.log("search.log").contains("code: zzkx lorp qwv"), "the S9.4 plant did not type the planted control text: \(control.log("search.log"))")
    }

    @Test("S1.24 reads the new sample list: with the hint and the three samples in order nothing is wrong; the old code sample, a missing third, another order and six samples are each a reason; the words describe and type part are still read")
    func s124Samples() throws {
        let rig = try Rig()
        func why(_ samples: [String], hintText: String = "Describe what you want, or type part of a name or text.") throws -> String {
            var lines = rig.hint(samples)
            lines[1] = "    AXStaticText label=\"\(hintText)\""
            try rig.put("hint.txt", rig.panel(box: "", extra: lines))
            let r = try rig.run("PN_DUMP=\"$(cat \"$FAKE/hint.txt\")\"; nr_hint_why \"an empty box\" | sed '/^extra:/d'")
            return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try why(sampleLines) == "", "the three samples in order were refused")
        #expect(try why(["a dog on the beach", "the clause about pets in the lease", "code: retry a failed call with backoff"]).contains("sample"), "the old code sample was accepted")
        #expect(try why(Array(sampleLines.prefix(2))).contains("sample"), "two samples were accepted")
        #expect(try why([sampleLines[0], sampleLines[2], sampleLines[1]]).contains("sample"), "another order was accepted")
        #expect(try why(sampleLines + ["a fourth", "a fifth", "a sixth"]).contains("not 2 to 5"), "six samples were accepted")
        #expect(try why(sampleLines, hintText: "Nothing here").contains("no hint text"), "a hint without the words describe or type part was accepted")
    }

    @Test("a failed driver call prints the driver's output and the check ends exit 4, in each of the six checks")
    func driverOutputPrinted() throws {
        for id in ids {
            let rig = try Rig()
            let fn = "check_" + id.replacingOccurrences(of: ".", with: "_")
            let r = try rig.run("""
            kq() { echo "driver says boom"; return 1; }
            \(fn) </dev/null; echo "RC $?"
            """)
            #expect(r.output.contains("driver says boom"), "\(id): the driver's output was not printed: \(r.output.suffix(400))")
            #expect(!r.output.contains("CHECK \(id) FAIL") && !r.output.contains("CHECK \(id) PASS") && r.output.contains("RC 4"), "\(id): a driver failure was not a RERUN: \(r.output.suffix(400))")
        }
    }

    @Test("prep upgrade is in recipe_main and the usage; with a hand-made old home it swaps the bundle, launches and waits for Ready, and writes the before-facts S9.6 reads; with no old state it is exit 4 and launches nothing")
    func prepUpgrade() throws {
        let rig = try Rig()
        try FileManager.default.createDirectory(atPath: rig.base + "/dist/Sesame.app", withIntermediateDirectories: true)
        try KC.write(rig.kit + "/apps/Sesame.app/old", "1")
        try KC.write(rig.kit + "/run/id", "S9\n")
        try KC.write(rig.kit + "/run/version", "v1\n")
        try? FileManager.default.removeItem(atPath: rig.kit + "/run/recipe")
        try? FileManager.default.removeItem(atPath: rig.kit + "/run/upgrade-code-rows")
        try rig.put("under-api-client.txt", "\(rig.kit)/home/Developer/api-client/retry.swift\tcode\tdone\n\(rig.kit)/home/Developer/api-client/auth.swift\tcode\tdone\n\(rig.kit)/home/Developer/api-client/docs/retry-notes.md\tdocument\tdone\n3 files under x\n")
        try rig.put("launches.log", "")
        let launch = "#!/bin/bash\necho \"launch $*\" >> \"$FAKE/launches.log\"\nexit 0\n"
        try KC.write(rig.scripts + "/kit-launch.sh", launch)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.scripts + "/kit-launch.sh")
        let r = try rig.run("recipe_main upgrade; echo \"RC $?\"")
        #expect(r.output.contains("RC 0"), "prep upgrade: \(r.output.suffix(600))")
        #expect(FileManager.default.fileExists(atPath: rig.kit + "/apps/Sesame.app") && !FileManager.default.fileExists(atPath: rig.kit + "/apps/Sesame.app/old"), "the bundle was not replaced")
        #expect(FileManager.default.fileExists(atPath: rig.kit + "/home/Library/Application Support/Sesame/index.sqlite"), "the old home was not kept")
        #expect(rig.log("launches.log") == ["launch stop", "launch start"], "the app was handled as \(rig.log("launches.log"))")
        #expect((KC.read(rig.kit + "/run/recipe") ?? "") == "upgrade\n", "run/recipe holds \(KC.read(rig.kit + "/run/recipe") ?? "nothing")")
        #expect((KC.read(rig.kit + "/run/upgrade-code-rows") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "2", "the old code rows were \(KC.read(rig.kit + "/run/upgrade-code-rows") ?? "not recorded"), the hand count is 2")
        #expect((KC.read(rig.kit + "/run/upgrade-old-settings") ?? "").contains("codeSearchOn"), "the old settings were not recorded")

        let empty = try Rig()
        try FileManager.default.createDirectory(atPath: empty.base + "/dist/Sesame.app", withIntermediateDirectories: true)
        try KC.write(empty.kit + "/run/id", "S9\n")
        try KC.write(empty.kit + "/run/version", "v1\n")
        try? FileManager.default.removeItem(atPath: empty.kit + "/home")
        let n = try empty.run("recipe_main upgrade; echo \"RC $?\"")
        #expect(n.output.contains("RC 4") && n.output.contains("no old state"), "no old state: \(n.output.suffix(400))")
        let none = try Rig()
        try KC.write(none.kit + "/run/id", "S9\n")
        try KC.write(none.kit + "/run/version", "v1\n")
        try FileManager.default.createDirectory(atPath: none.base + "/dist/Sesame.app", withIntermediateDirectories: true)
        try none.put("under-api-client.txt", "1 files under x\n")
        let z = try none.run("recipe_main upgrade; echo \"RC $?\"")
        #expect(z.output.contains("RC 4") && z.output.contains("no code row"), "an old index with no code row: \(z.output.suffix(400))")
        let wrong = try Rig()
        let u = try wrong.run("recipe_main upgrade extra; echo \"RC $?\"")
        #expect(u.output.contains("RC 2"), "prep upgrade with an argument: \(u.output.suffix(300))")
    }

    @Test("kit-reset.sh --keep-home swaps apps/Sesame.app for dist/Sesame.app and nothing else: home and run stay, no driver is called; it needs a home and a bundle and takes no other option")
    func keepHome() throws {
        let rig = try Rig()
        try FileManager.default.createDirectory(atPath: rig.base + "/dist/Sesame.app", withIntermediateDirectories: true)
        try KC.write(rig.base + "/dist/Sesame.app/new", "1")
        try KC.write(rig.kit + "/apps/Sesame.app/old", "1")
        try KC.write(rig.kit + "/run/kept", "k")
        try KC.write(rig.kit + "/fixtures/f", "f")
        let env = ["FAKE": rig.fake, "KIT_ROOT": rig.kit, "KIT_NO_EVIDENCE": "1"]
        let r = try KC.run(rig.scripts + "/kit-reset.sh", ["--keep-home"], env: env)
        #expect(r.status == 0, "--keep-home exited \(r.status): \(r.output)")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: rig.kit + "/apps/Sesame.app/new") && !fm.fileExists(atPath: rig.kit + "/apps/Sesame.app/old"), "apps/Sesame.app was not swapped: \(r.output)")
        #expect(fm.fileExists(atPath: rig.kit + "/home/Library/Application Support/Sesame/index.sqlite") && fm.fileExists(atPath: rig.kit + "/home/Library/Application Support/Sesame/settings.json"), "home was touched")
        #expect(fm.fileExists(atPath: rig.kit + "/run/kept") && fm.fileExists(atPath: rig.kit + "/fixtures/f") && fm.fileExists(atPath: rig.kit + "/run/upgrade-code-rows"), "run or fixtures were touched")
        #expect(!fm.fileExists(atPath: rig.fake + "/ax.log"), "kit-ax.sh was called: restore_kit_state was reached")
        let text = KC.read(rig.scripts + "/kit-reset.sh") ?? ""
        let main = KC.shellFunction("main", in: text) ?? ""
        #expect(main.contains("--keep-home"), "main does not parse --keep-home")

        let nohome = try Rig()
        try FileManager.default.createDirectory(atPath: nohome.base + "/dist/Sesame.app", withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: nohome.kit + "/home")
        let a = try KC.run(nohome.scripts + "/kit-reset.sh", ["--keep-home"], env: ["FAKE": nohome.fake, "KIT_ROOT": nohome.kit])
        #expect(a.status == 1, "--keep-home with no home exited \(a.status): \(a.output)")
        let nobundle = try Rig()
        let b = try KC.run(nobundle.scripts + "/kit-reset.sh", ["--keep-home"], env: ["FAKE": nobundle.fake, "KIT_ROOT": nobundle.kit])
        #expect(b.status == 1 && FileManager.default.fileExists(atPath: nobundle.kit + "/home/Library/Application Support/Sesame/index.sqlite"), "--keep-home with no bundle exited \(b.status): \(b.output)")
        for args in [["--keep-home", "--id", "S9"], ["--keep-home", "--version", "v"], ["--keep-home", "--cleanup"], ["--keep-home", "--baseline"], ["--keep-home", "--model", "mirror"]] {
            let x = try KC.run(rig.scripts + "/kit-reset.sh", args, env: env)
            #expect(x.status == 2 && x.output.contains("usage: kit-reset.sh"), "\(args) exited \(x.status): \(x.output)")
        }
    }

    @Test("kit-reset.sh accepts the id S9 (and, plan-8-t9 amended, S10) and still refuses S11, S0 and S9x before any step")
    func resetIds() throws {
        let rig = try Rig()
        try FileManager.default.createDirectory(atPath: rig.base + "/dist/Sesame.app", withIntermediateDirectories: true)
        let env = ["FAKE": rig.fake, "KIT_ROOT": rig.kit, "KIT_NO_EVIDENCE": "1"]
        let ok = try KC.run(rig.scripts + "/kit-reset.sh", ["--bundle-only", "--id", "S9"], env: env)
        #expect(ok.status == 0, "--bundle-only --id S9 exited \(ok.status): \(ok.output)")
        for id in ["S11", "S0", "S9x"] {
            let b = try KC.run(rig.scripts + "/kit-reset.sh", ["--bundle-only", "--id", id], env: env)
            #expect(b.status == 2, "--bundle-only --id \(id) exited \(b.status)")
            let f = try KC.run(rig.scripts + "/kit-reset.sh", ["--id", id, "--version", "v1"], env: env)
            #expect(f.status == 2 && f.output.contains("usage: kit-reset.sh"), "--id \(id) exited \(f.status): \(f.output)")
        }
        let text = KC.read(rig.scripts + "/kit-reset.sh") ?? ""
        #expect(text.components(separatedBy: "S[1-9]|S10|kit").count == 3, "the reset does not accept S[1-9]|S10|kit in both places")
    }

    @Test("batches.sh builds its all-list from S1 to S9: the verify.sh batch lists S9.1 to S9.6 last, and kit-perms.sh keys_for returns the UI keys for S9 ids and 1 for an unknown id")
    func allListAndPerms() throws {
        let rig = try Rig()
        let env = ["FAKE": rig.fake, "KIT_ROOT": rig.kit]
        let out = try KC.run(rig.scripts + "/kit-run.sh", ["batches"], env: env)
        let header = KC.lines(out.output).first { $0.hasPrefix("BATCH F ") } ?? ""
        #expect(header.hasSuffix(",S8.12,S9.1,S9.2,S9.3,S9.4,S9.5,S9.6,S10.1,S10.2,S10.3,S10.4,S10.5,S10.6,S10.7,S10.8,S10.9"), "the verify.sh batch header ends \(header.suffix(120)) (plan-8-t9 amended: S10.1 to S10.9 follow S9)")
        let perms = try KC.run("/bin/bash", ["-c", "eval \"$(sed -n '/^keys_for() {/,/^}/p' '\(KC.scripts)/kit-perms.sh')\"; for id in S9.1 S9.2 S9.3 S9.4 S9.5 S9.6; do echo \"$id: $(keys_for $id)\"; done; keys_for S11.1; echo \"rc $?\"; keys_for S9; echo \"rc $?\""])
        let want = (1...6).map { "S9.\($0): accessibility screen sysevents" }
        #expect(Array(KC.lines(perms.output).prefix(6)) == want, "keys_for S9: \(perms.output)")
        #expect(KC.lines(perms.output).suffix(2).first == "rc 1", "keys_for S11.1 did not return 1: \(perms.output)")
    }

    @Test("batch S9 is in batches.tsv after the others with its six lines in this order, and kit-run.sh batches prints it with the ids S9.6 then S9.1 to S9.5")
    func batchS9() throws {
        let rows = (KC.read(KC.lib + "/batches.tsv") ?? "").split(separator: "\n").map { $0.components(separatedBy: "\t") }.filter { $0.count >= 3 && $0[1] == "S9" }
        #expect(rows.count == 7, "batch S9 has \(rows.count) rows")
        guard rows.count == 7 else { return }
        #expect(rows[0][0] == "batch" && rows[0][4] == "yes", "the batch row is \(rows[0])")
        #expect(rows[1][0] == "say" && rows[1][2].contains("job2-base") && rows[1][2].contains("~/sesame-job2-old-build/Sesame.app") && rows[1][2].contains("kit-reset.sh --id S9 --version @VERSION@ --model mirror") && rows[1][2].contains("kit-run.sh prep golden-code") && rows[1][2].contains("KIT_ROOT"), "the say line is \(rows[1])")
        #expect(rows[2...].map { $0[0] + " " + $0[2] } == ["run kit-run.sh prep upgrade", "run kit-run.sh S9 --ids S9.6", "run kit-reset.sh --id S9 --version @VERSION@ --model mirror", "run kit-run.sh prep golden", "run kit-run.sh S9 --ids S9.1,S9.2,S9.3,S9.4,S9.5"], "the run lines are \(rows[2...])")
        let lines = (KC.read(KC.lib + "/batches.tsv") ?? "").split(separator: "\n").map(String.init)
        let last = lines.lastIndex { $0.hasPrefix("batch\tH3") } ?? 0
        let first = lines.firstIndex { $0.hasPrefix("batch\tS9") } ?? 0
        #expect(first > last, "batch S9 is not after the other batches")
        let rig = try Rig()
        let out = try KC.run(rig.scripts + "/kit-run.sh", ["batches"], env: ["FAKE": rig.fake, "KIT_ROOT": rig.kit])
        let header = KC.lines(out.output).first { $0.hasPrefix("BATCH S9 ") } ?? ""
        #expect(header.hasSuffix(": S9.6,S9.1,S9.2,S9.3,S9.4,S9.5"), "the S9 header is \(header)")
    }
}
