import Foundation
import Testing

private final class Rig: @unchecked Sendable {
    let base: String
    let kit: String
    let fake: String
    let scripts: String
    let lib: String
    let before: String

    init(long: Bool = false) throws {
        base = try KC.tempDir("kit-s10-")
        scripts = base + "/scripts"
        lib = scripts + "/kit-lib"
        kit = base + "/sesame-kit"
        fake = kit + "/fake"
        before = base + "/before"
        let fm = FileManager.default
        try fm.copyItem(atPath: KC.scripts, toPath: scripts)
        try fm.createDirectory(atPath: base + "/fixtures", withIntermediateDirectories: true)
        try fm.copyItem(atPath: KC.root.path + "/fixtures/answers.csv", toPath: base + "/fixtures/answers.csv")
        try fm.createDirectory(atPath: fake, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: kit + "/run", withIntermediateDirectories: true)
        try KC.write(kit + "/fixtures/golden/photos/beach-dog.jpg", "jpg")
        try KC.write(kit + "/home/Library/Application Support/Sesame/settings.json", "{}")
        try installFakes()
        try put(s10World(old: false, long: long, root: kit))
        try put("step", "1\n")
        try put("lc", "PASS\n")
        try put("rows-qwv_zzkx_lorp_mnb", "0")
        try putBaseline(s10World(old: true, long: false, root: kit))
    }

    func put(_ name: String, _ text: String) throws { try KC.write(fake + "/" + name, text) }
    func put(_ files: [String: String]) throws { for (k, v) in files { try put(k, v) } }
    func remove(_ name: String) { try? FileManager.default.removeItem(atPath: fake + "/" + name) }
    func read(_ name: String) -> String { KC.read(fake + "/" + name) ?? "" }
    func log(_ name: String) -> [String] { KC.lines(read(name)) }

    func putBaseline(_ world: [String: String]) throws {
        for (new, old) in s10BaselineNames { try KC.write(before + "/" + old, world[new] ?? "") }
    }

    private func script(_ name: String, _ body: String) throws {
        let path = scripts + "/" + name
        try KC.write(path, "#!/bin/bash\n" + body)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func installFakes() throws {
        try script("kit-ax.sh", #"""
        echo "$*" >> "$FAKE/ax.log"
        slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
        look=""; [ "$(cat "$FAKE/look" 2>/dev/null)" = dark ] && look=dark
        serve() {
          local base="${1%.txt}"
          if [ -n "$look" ] && [ -f "$base-dark.txt" ]; then cat "$base-dark.txt"; return 0; fi
          [ -f "$1" ] && { cat "$1"; return 0; }
          return 1
        }
        case "$1" in
          dump)
            case "$2" in
              setup)
                n="$(cat "$FAKE/step" 2>/dev/null || echo 1)"
                if [ -f "$FAKE/offline" ] && [ -f "$FAKE/setup-$n-offline.txt" ]; then cat "$FAKE/setup-$n-offline.txt"; exit 0; fi
                serve "$FAKE/setup-$n.txt" || { echo "no window"; exit 1; } ;;
              settings)
                s="$(slug "$(cat "$FAKE/section" 2>/dev/null || echo Folders)")"
                if [ -f "$FAKE/clicked-PDFs" ] && [ -f "$FAKE/settings-$s-saved-failed.txt" ]; then cat "$FAKE/settings-$s-saved-failed.txt"; exit 0; fi
                if [ -f "$FAKE/confirm" ] && [ -f "$FAKE/settings-$s-confirm.txt" ]; then cat "$FAKE/settings-$s-confirm.txt"; exit 0; fi
                serve "$FAKE/settings-$s.txt" || { echo "no window"; exit 1; } ;;
              menu) serve "$FAKE/menu.txt" || { echo "no window"; exit 1; } ;;
              panel)
                d="$(cat "$FAKE/pdumps" 2>/dev/null || echo 0)"; echo $((d + 1)) > "$FAKE/pdumps"
                q="$(cat "$FAKE/lastq" 2>/dev/null)"
                f="$FAKE/panel-$(slug "$q").txt"; [ -s "$FAKE/lastq" ] || f="$FAKE/panel-empty.txt"
                if [ -f "$FAKE/killed" ] && [ -f "$FAKE/panel-failed.txt" ]; then cat "$FAKE/panel-failed.txt"; exit 0; fi
                if [ -f "${f%.txt}-d$d.txt" ]; then cat "${f%.txt}-d$d.txt"; exit 0; fi
                serve "$f" || { echo "no window"; exit 1; } ;;
            esac
            exit 0 ;;
          click)
            case "$2" in
              Next|"Not now") n="$(cat "$FAKE/step" 2>/dev/null || echo 1)"; echo $((n + 1)) > "$FAKE/step" ;;
              Back) n="$(cat "$FAKE/step" 2>/dev/null || echo 1)"; echo $((n - 1)) > "$FAKE/step" ;;
              Folders|"File types"|Search|Indexing) printf '%s\n' "$2" > "$FAKE/section" ;;
              "Delete index…") : > "$FAKE/confirm" ;;
              Cancel) rm -f "$FAKE/confirm" ;;
              PDFs) : > "$FAKE/clicked-PDFs" ;;
            esac
            exit 0 ;;
          appearance)
            case "$2" in
              light|dark) echo "$2" > "$FAKE/look"; echo "$2" ;;
              restore) rm -f "$FAKE/look" ;;
              get) cat "$FAKE/look" 2>/dev/null || echo light ;;
            esac
            exit 0 ;;
          shot)
            : > "$FAKE/shot-$2.png"
            printf 'saved %s (Sesame window 1)\n' "$FAKE/shot-$2.png"
            exit 0 ;;
          read) if [ "$2" = panel ]; then [ -f "$FAKE/panelopen" ] || exit 1; echo panel; else echo "status item: Ready"; fi ;;
          frontmost) echo Sesame ;;
        esac
        exit 0
        """#)
        try script("kit-search.sh", #"""
        echo "$*" >> "$FAKE/search.log"
        printf '%s' "$1" > "$FAKE/lastq"
        : > "$FAKE/panelopen"
        n="$(cat "$FAKE/rows-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')" 2>/dev/null || echo 1)"
        printf 'search box label="Search" value="%s"\nrows %s\n' "$1" "$n"
        exit 0
        """#)
        try script("kit-index.sh", #"""
        echo "$*" >> "$FAKE/index.log"
        case "$1" in wait) exit "${FAKE_WAIT_RC:-0}" ;; esac
        exit 0
        """#)
        try script("kit-launch.sh", #"""
        echo "$*" >> "$FAKE/launch.log"
        [ "$1 $2" = "kill9 index" ] && : > "$FAKE/killed"
        exit "${FAKE_KILL_RC:-0}"
        """#)
        try script("kit-mirror.sh", #"""
        echo "$*" >> "$FAKE/mirror.log"
        case "$1" in offline) : > "$FAKE/offline" ;; online) rm -f "$FAKE/offline" ;; esac
        exit 0
        """#)
        try script("check-static.sh", #"""
        echo "$*" >> "$FAKE/static.log"
        echo "STATIC plist-lint PASS"
        s="$(cat "$FAKE/lc" 2>/dev/null || echo PASS)"
        echo "STATIC literal-colours $s"
        [ "$s" = PASS ] || echo "  Sources/Sesame/Planted.swift:2: NSColor.white"
        echo "STATIC-RESULT ok"
        exit 0
        """#)
        for name in ["kit-fixtures.sh", "kit-perms.sh"] { try script(name, "exit 0\n") }
    }

    func run(_ body: String, plant: Bool = false, env: [String: String] = [:], limit: TimeInterval = 180) throws -> KC.Ran {
        let script = """
        #!/bin/bash
        export KIT_ROOT="\(kit)" FAKE="\(fake)" S10_BEFORE="\(before)" S10_FLIP_WAIT=0 S10_DL_WAIT=1 S10_SETTLE=0
        . "\(lib)/common.sh"
        . "\(lib)/recipes.sh"
        for f in "\(lib)"/checks-*.sh; do [ -f "$f" ] && . "$f"; done
        tree_need() { echo "tree stub"; return "${TREE_RC:-0}"; }
        golden_need() { echo "golden stub"; return "${GOLDEN_RC:-0}"; }
        recipe_setup() { echo "setup stub"; return "${SETUP_RC:-0}"; }
        recipe_fresh_throttled() { echo "fresh stub"; return "${FRESH_RC:-0}"; }
        pick_folders() { echo "$PK_WINDOW:$*" >> "$FAKE/pick.log"; return "${PICK_RC:-0}"; }
        settings_open() { return "${SETTINGS_RC:-0}"; }
        wait_menu_ready() { return 0; }
        pn_open_panel() { : > "$FAKE/lastq"; : > "$FAKE/panelopen"; return "${PANEL_RC:-0}"; }
        pn_close_panel() { return 0; }
        s10_luma() { case "$(cat "$FAKE/look" 2>/dev/null)" in dark) echo "${LUMA_DARK:-40}" ;; *) echo "${LUMA_LIGHT:-200}" ;; esac; }
        s10_ua_state() {
          if [ -n "${UA_FIXED:-}" ]; then echo "$UA_FIXED"; return 0; fi
          local n; n="$(cat "$FAKE/uan" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$FAKE/uan"
          case $((n % 4)) in 0) echo "0 0" ;; 1) echo "1 0" ;; 2) echo "0 1" ;; *) echo "1 1" ;; esac
        }
        \(plant ? "KIT_PLANT=1; export KIT_PLANT" : "")
        \(body)
        """
        let path = try KC.tempDir() + "/harness.sh"
        try KC.write(path, script)
        var e = ["FAKE": fake, "KIT_ROOT": kit]
        for (k, v) in env { e[k] = v }
        return try KC.run("/bin/bash", [path], env: e, limit: limit)
    }

    typealias Verdict = (verdict: String, rc: Int32, output: String)

    func check(_ id: String, plant: Bool = false, env: [String: String] = [:], pre: String = "") throws -> Verdict {
        let fn = "check_" + id.replacingOccurrences(of: ".", with: "_")
        let r = try run("\(pre)\n\(fn) </dev/null; echo \"RC $?\"", plant: plant, env: env)
        let rc = Int32(KC.lines(r.output).last(where: { $0.hasPrefix("RC ") })?.dropFirst(3) ?? "-1") ?? -1
        let line = KC.lines(r.output).first(where: { $0.hasPrefix("CHECK \(id) ") || $0.hasPrefix("RERUN \(id) ") }) ?? ""
        return (line, rc, r.output)
    }

    func addLine(_ name: String, _ role: String, _ label: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, flags: String = "", window: Bool = true, depth: Int = 1) throws {
        let ox = window ? 100 : 0, oy = window ? 50 : 0
        let f = flags.isEmpty ? "" : " " + flags
        try put(name, s10Append(read(name), String(repeating: "  ", count: depth) + "\(role) label=\"\(label)\"\(f) frame=\(x + ox),\(y + oy),\(w),\(h)"))
    }

    func edit(_ name: String, _ transform: (String) -> String) throws { try put(name, transform(read(name))) }
}

private func pass(_ r: Rig.Verdict, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.verdict.hasPrefix("CHECK \(id) PASS") && r.rc == 0, "\(id) did not pass: rc \(r.rc), \(r.output.suffix(900))", sourceLocation: sourceLocation)
}

private func fail(_ r: Rig.Verdict, _ id: String, mentions: String..., sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.verdict.hasPrefix("CHECK \(id) FAIL") && r.rc == 1, "\(id) did not fail: rc \(r.rc), \(r.output.suffix(900))", sourceLocation: sourceLocation)
    for m in mentions { #expect(r.verdict.localizedCaseInsensitiveContains(m), "the FAIL line of \(id) does not mention \(m): \(r.verdict)", sourceLocation: sourceLocation) }
}

private func person(_ r: Rig.Verdict, _ id: String, mentions: String..., sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.verdict.hasPrefix("CHECK \(id) NEEDS-A-PERSON") && r.rc == 0, "\(id) was not NEEDS-A-PERSON: rc \(r.rc), \(r.output.suffix(900))", sourceLocation: sourceLocation)
    for m in mentions { #expect(r.verdict.localizedCaseInsensitiveContains(m), "the NEEDS-A-PERSON line of \(id) does not mention \(m): \(r.verdict)", sourceLocation: sourceLocation) }
}

private func rerun(_ r: Rig.Verdict, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.verdict.hasPrefix("RERUN \(id) not valid") && r.rc == 4, "\(id) was not a RERUN: rc \(r.rc), \(r.output.suffix(900))", sourceLocation: sourceLocation)
    #expect(!r.output.contains("CHECK \(id) "), "\(id) printed a CHECK line besides the RERUN: \(r.output.suffix(600))", sourceLocation: sourceLocation)
}

private func h(_ call: String, _ dump: String) -> KC.Ran { (try? helper(call, dump)) ?? KC.Ran(status: -1, output: "") }

private func helper(_ call: String, _ dump: String) throws -> KC.Ran {
    let dir = try KC.tempDir("axh-")
    try KC.write(dir + "/d.txt", dump)
    return try KC.run("/bin/bash", ["-c", ". \"\(KC.lib)/axdump.sh\"; \(call) < \"\(dir)/d.txt\"; echo \"rc $?\""])
}

private func outAndRc(_ r: KC.Ran) -> (lines: [String], rc: Int) {
    var ls = KC.lines(r.output)
    let rc = Int(ls.popLast()?.dropFirst(3) ?? "-1") ?? -1
    return (ls, rc)
}

private let handDump = """
window 400 x 300 at 100, 50 title T
AXWindow label="T" frame=100,50,400,300
  AXStaticText label="A" frame=120,70,100,20
  AXStaticText label="B" frame=200,80,100,20
  AXButton label="Re-index" help="x" frame=320,70,60,20
    AXTextField label="Re-index" frame=316,70,68,15
  AXButton label="Remove" frame=380,70,60,20
  AXGroup frame=120,150,200,100
    AXStaticText label="Inside" frame=130,160,50,20
    AXStaticText label="Out" frame=300,160,100,20
  AXScrollArea frame=100,240,400,60
    AXStaticText label="Scrolled" frame=110,280,100,40

"""

@Suite("KitRunS10ChecksTests", .serialized)
struct KitRunS10ChecksTests {
    let ids = (1...9).map { "S10.\($0)" }

    @Test("checks.tsv gains S10.1 to S10.9 at slice 8 as the last nine rows: S10.5 and S10.8 auto, the other seven auto-or-person; its own recount is 121 rows, 98 auto, 17 auto-or-person, 6 reading; checks.floor is 93 (91 plus 2 auto ids), at most the auto rows; slice is 8")
    func table() throws {
        let rows = KC.checksTSV()
        let s10 = rows.filter { $0.id.hasPrefix("S10.") }
        #expect(s10.map(\.id) == ids, "the S10 rows are \(s10.map(\.id))")
        #expect(s10.map(\.slice) == Array(repeating: 8, count: 9), "the S10 slices are \(s10.map(\.slice))")
        #expect(s10.map(\.kind) == ["auto-or-person", "auto-or-person", "auto-or-person", "auto-or-person", "auto", "auto-or-person", "auto-or-person", "auto", "auto-or-person"], "the S10 kinds are \(s10.map(\.kind))")
        #expect(rows.suffix(9).map(\.id) == ids, "the S10 rows are not the last nine rows")
        let r = try KC.run("/usr/bin/awk", ["-F\t", "{ n++; c[$3]++ } END { print n, c[\"auto\"], c[\"auto-or-person\"], c[\"reading\"] }", KC.lib + "/checks.tsv"])
        #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "121 98 17 6", "rows, auto, auto-or-person, reading are \(r.output): 112 + 9 = 121, 96 + 2 = 98, 10 + 7 = 17, 6")
        let floor = Int((KC.read(KC.lib + "/checks.floor") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(floor == 93, "checks.floor reads \(floor.map(String.init) ?? "nothing"), 91 + 2 = 93 (98 auto rows less the five administrator ids)")
        #expect((floor ?? 999) <= 98, "the floor is above the 98 auto rows")
        #expect((KC.read(KC.lib + "/slice") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "8", "slice does not hold 8")
    }

    @Test("checks-s10.sh exists, parses, defines check_S10_1 to check_S10_9, holds no comment line and reads no source file")
    func fileShape() throws {
        let text = KC.read(KC.lib + "/checks-s10.sh") ?? ""
        #expect(!text.isEmpty, "scripts/kit-lib/checks-s10.sh does not exist")
        for id in ids { #expect(text.contains("check_" + id.replacingOccurrences(of: ".", with: "_") + "()"), "no function for \(id)") }
        let r = try KC.run("/bin/bash", ["-n", KC.lib + "/checks-s10.sh"])
        #expect(r.status == 0 && !text.isEmpty, "bash -n: \(r.output)")
        #expect(!KC.has(text, #"(^|\n)[ ]*#"#), "checks-s10.sh holds a comment line")
        #expect(!text.contains("Sources/") && !text.contains("sqlite3") && !text.contains("plutil"), "checks-s10.sh reads source, sqlite or a plist itself")
    }

    @Test("kit-run.sh dispatches S10 to its checks, rejects S11 and an unknown S10 id with the usage that lists S10, and runs nothing for S10 at slice 7")
    func dispatch() throws {
        let rig = try Rig()
        try KC.write(rig.lib + "/checks-zz.sh", "check_S10_5() { echo \"CHECK S10.5 PASS dispatched\"; }\n")
        let env = ["FAKE": rig.fake, "KIT_ROOT": rig.kit, "KIT_NO_EVIDENCE": "1"]
        let ok = try KC.run(rig.scripts + "/kit-run.sh", ["S10", "--ids", "S10.5"], env: env)
        #expect(ok.status == 0 && ok.output.contains("CHECK S10.5 PASS dispatched") && ok.output.contains("CHECKS: 1 passed, 0 failed"), "S10 --ids S10.5: \(ok.status) \(ok.output)")
        let usage = try KC.run(rig.scripts + "/kit-run.sh", ["S11"], env: env)
        #expect(usage.status == 2 && usage.output.contains("S6..S10"), "S11 exited \(usage.status): \(usage.output)")
        for args in [["S10", "--ids", "S10.10"], ["S10", "--ids", "S9.1"], ["S10", "--plant", "S9.1"]] {
            let r = try KC.run(rig.scripts + "/kit-run.sh", args, env: env)
            #expect(r.status == 2, "\(args) exited \(r.status): \(r.output)")
        }
        let all = try KC.run(rig.scripts + "/kit-run.sh", ["S10", "--slice", "7"], env: env)
        #expect(all.output.contains("no check of S10 is first drivable in slice 7"), "S10 at slice 7 runs something: \(all.output)")
    }

    @Test("the drivers accept S10: kit-reset.sh --id S10, verify.sh --only S10 (and refuse S11), the batches all-list and kit-perms.sh keys_for")
    func drivers() throws {
        let rig = try Rig()
        try FileManager.default.createDirectory(atPath: rig.base + "/dist/Sesame.app", withIntermediateDirectories: true)
        let env = ["FAKE": rig.fake, "KIT_ROOT": rig.kit, "KIT_NO_EVIDENCE": "1"]
        let ok = try KC.run(rig.scripts + "/kit-reset.sh", ["--bundle-only", "--id", "S10"], env: env)
        #expect(ok.status == 0, "--bundle-only --id S10 exited \(ok.status): \(ok.output)")
        for id in ["S11", "S0", "S10x", "S100"] {
            let b = try KC.run(rig.scripts + "/kit-reset.sh", ["--bundle-only", "--id", id], env: env)
            #expect(b.status == 2, "--bundle-only --id \(id) exited \(b.status)")
            let f = try KC.run(rig.scripts + "/kit-reset.sh", ["--id", id, "--version", "v1"], env: env)
            #expect(f.status == 2 && f.output.contains("usage: kit-reset.sh"), "--id \(id) exited \(f.status): \(f.output)")
        }
        let bin = try KC.tempDir() + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in ["kit-reset.sh", "kit-run.sh"] {
            try KC.write(bin + "/" + name, "#!/bin/bash\necho \"\(name) $*\" >> \"$STUB_LOG\"\necho \"CHECKS: 0 passed, 0 failed, 0 skipped, 0 needs-a-person\"\nexit 0\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/" + name)
        }
        let log = try KC.tempDir() + "/log"
        let venv = ["KIT_VERIFY_BIN": bin, "KIT_ROOT": rig.kit, "KIT_NO_EVIDENCE": "1", "STUB_LOG": log]
        let only = try KC.run(rig.scripts + "/verify.sh", ["--only", "S10"], env: venv)
        #expect(only.status == 0 && only.output.contains("ONLY S10:") && (KC.read(log) ?? "").contains("kit-run.sh S10 --slice 8"), "--only S10 exited \(only.status): \(only.output)")
        let bad = try KC.run(rig.scripts + "/verify.sh", ["--only", "S11"], env: venv)
        #expect(bad.status == 2 && bad.output.contains("S11"), "--only S11 exited \(bad.status): \(bad.output)")
        let out = try KC.run(rig.scripts + "/kit-run.sh", ["batches"], env: env)
        let header = KC.lines(out.output).first { $0.hasPrefix("BATCH F ") } ?? ""
        #expect(header.hasSuffix(",S9.6,S10.1,S10.2,S10.3,S10.4,S10.5,S10.6,S10.7,S10.8,S10.9"), "the verify.sh batch header ends \(header.suffix(90))")
        let keys = try KC.run("/bin/bash", ["-c", "eval \"$(sed -n '/^keys_for() {/,/^}/p' '\(KC.scripts)/kit-perms.sh')\"; for n in 1 2 3 4 5 6 7 8 9; do echo \"S10.$n: $(keys_for S10.$n)\"; done; keys_for S11.1; echo \"rc $?\"; keys_for S10; echo \"rc $?\"; echo \"S1: $(keys_for S1.1)\"; echo \"S9: $(keys_for S9.1)\""])
        let want = (1...9).map { "S10.\($0): accessibility screen sysevents" }
        #expect(Array(KC.lines(keys.output).prefix(9)) == want, "keys_for S10: \(keys.output)")
        #expect(KC.lines(keys.output).contains("rc 1") && !KC.lines(keys.output).contains("rc 0"), "keys_for S11.1 or S10 did not return 1: \(keys.output)")
        #expect(KC.lines(keys.output).contains("S1: accessibility screen sysevents") && KC.lines(keys.output).contains("S9: accessibility screen sysevents"), "S1 and S9 keys changed: \(keys.output)")
    }

    @Test("batch S10 is in batches.tsv after the others with its lines in this order, and kit-run.sh batches prints it with the ids in order")
    func batchS10() throws {
        let lines = (KC.read(KC.lib + "/batches.tsv") ?? "").split(separator: "\n").map(String.init)
        let rows = lines.map { $0.components(separatedBy: "\t") }.filter { $0.count >= 3 && $0[1] == "S10" }
        #expect(rows.count == 6, "batch S10 has \(rows.count) rows")
        guard rows.count == 6 else { return }
        #expect(rows[0][0] == "batch" && rows[0][3] == "many" && rows[0][4] == "yes", "the batch row is \(rows[0])")
        #expect(rows[1...].map { $0[0] + " " + $0[2] }.enumerated().allSatisfy { i, s in
            ["run kit-reset.sh --id S10 --version @VERSION@ --model mirror", "run kit-run.sh prep golden", "run kit-run.sh S10 --ids S10.1,S10.2,S10.3,S10.5,S10.7,S10.9"][safe: i].map { s == $0 } ?? true
        }, "the first run lines are \(rows[1...])")
        #expect(rows[4][0] == "say" && rows[4][2].contains("kit-mirror.sh offline") && rows[4][2].contains("kit-mirror.sh online"), "the say line is \(rows[4])")
        #expect(rows[5][0] + " " + rows[5][2] == "run kit-run.sh S10 --ids S10.8", "the last line is \(rows[5])")
        let last = lines.lastIndex { $0.hasPrefix("batch\tS9") } ?? 0
        let first = lines.firstIndex { $0.hasPrefix("batch\tS10") } ?? 0
        #expect(first > last, "batch S10 is not after batch S9")
        let rig = try Rig()
        let out = try KC.run(rig.scripts + "/kit-run.sh", ["batches"], env: ["FAKE": rig.fake, "KIT_ROOT": rig.kit])
        let header = KC.lines(out.output).first { $0.hasPrefix("BATCH S10 ") } ?? ""
        #expect(header.hasSuffix(": S10.1,S10.2,S10.3,S10.5,S10.7,S10.9,S10.8"), "the S10 header is \(header)")
    }

    @Test("the dump's frame field: ax.applescript prints frame=x,y,w,h from AXPosition and AXSize, the element limit is a named 1200 and the cut line text is kept; axdump.sh documents the field and names one filter")
    func frameField() throws {
        let osa = KC.read(KC.lib + "/ax.applescript") ?? ""
        #expect(osa.contains("property maxElements : 1200") && !osa.contains("property maxElements : 600"), "the element limit is not 1200")
        #expect(osa.contains("AXPosition") && osa.contains("AXSize") && osa.contains("\" frame=\""), "ax.applescript does not print frame= from AXPosition and AXSize")
        #expect(osa.contains("\"(tree cut at \" & maxElements & \" elements)\""), "the cut line text changed")
        let sh = KC.read(KC.lib + "/axdump.sh") ?? ""
        #expect(sh.contains("ax_strip_frames()") && sh.contains("frame="), "axdump.sh names no ax_strip_frames filter or does not document frame=")
    }

    @Test("the parsers give the same rows with and without the frame field: ax_elements, ax_rows, ax_row, ax_switch, ax_has_label and ax_total_seconds")
    func parsersIgnoreFrames() throws {
        let bare = """
        window 560 x 628 at 100, 50 title Set up Sesame
        AXWindow label="Set up Sesame"
          AXStaticText label="Step 2 of 4: Folders"
          AXStaticText label="About 5 min in total"
          AXCheckBox label="Desktop" desc="Desktop, 2 photos, about 1 min" help="/k/home/Desktop" value="1"
          AXCheckBox label="Pictures" desc="Pictures, 3 photos, about 1 min" help="/k/home/Pictures" value="0" [disabled]
          AXCheckBox label="Launch at login" value="1" [focused]
          AXButton label="Start indexing"
        (tree cut at 1200 elements)

        """
        var framed: [String] = []
        for (i, line) in bare.components(separatedBy: "\n").enumerated() {
            framed.append(line.hasPrefix("AX") || line.hasPrefix("  AX") ? line + " frame=\(120 + i),\(70 + i),\(300),\(20)" : line)
        }
        let withFrames = framed.joined(separator: "\n")
        for call in ["ax_elements", "ax_rows", "ax_folders", "ax_row Desktop", "ax_row_detail Pictures", "ax_row_estimate Desktop", "ax_switch 'Launch at login'", "ax_switch Desktop", "ax_has_label 'Start indexing'; echo $?", "ax_has_label_prefix 'Step 2'; echo $?", "ax_total_seconds"] {
            let a = h(call, bare), b = h(call, withFrames)
            #expect(a.output == b.output && !a.output.isEmpty, "\(call) differs with the field: \(a.output) | \(b.output)")
        }
        let stripped = h("ax_strip_frames", withFrames)
        let plain = h("cat", bare)
        #expect(stripped.output == plain.output, "ax_strip_frames does not give the dump without the field: \(stripped.output)")
    }

    @Test("ax_boxes prints n, parent, role, label, x, y, w, h, parent role, help with x and y relative to the window")
    func boxes() throws {
        let r = h("ax_boxes", handDump)
        let rows = outAndRc(r).lines.map { $0.components(separatedBy: "\t") }
        #expect(rows.count == 11, "ax_boxes printed \(rows.count) rows: \(r.output)")
        guard rows.count == 11 else { return }
        #expect(rows[0].prefix(9).elementsEqual(["1", "0", "AXWindow", "T", "0", "0", "400", "300", ""]), "the window row is \(rows[0])")
        #expect(rows[1].elementsEqual(["2", "1", "AXStaticText", "A", "20", "20", "100", "20", "AXWindow", ""]), "the A row is \(rows[1])")
        #expect(rows[4].prefix(4).elementsEqual(["5", "4", "AXTextField", "Re-index"]) && rows[4][8] == "AXButton", "the child row is \(rows[4])")
        #expect(rows[3][9] == "x", "the help of Re-index is \(rows[3])")
    }

    @Test("ax_overlaps names two siblings whose frames overlap and ignores a button's own text field, nested elements and touching frames")
    func overlaps() throws {
        let r = outAndRc(h("ax_overlaps", handDump))
        #expect(r.rc == 0 && r.lines.count == 1, "overlaps: \(r.lines)")
        #expect(r.lines.first?.contains("\"A\"") == true && r.lines.first?.contains("\"B\"") == true && r.lines.first?.contains("overlaps") == true, "the line is \(r.lines)")
        let touching = handDump.replacingOccurrences(of: "frame=200,80,100,20", with: "frame=220,80,100,20")
        #expect(outAndRc(h("ax_overlaps", touching)).lines.isEmpty, "A and B touching were reported")
    }

    @Test("ax_outside names an element outside its parent's frame, sideways everywhere and downwards only outside a scroll area, and nothing else")
    func outside() throws {
        let r = outAndRc(h("ax_outside", handDump))
        #expect(r.lines.count == 1 && r.lines[0].contains("\"Out\""), "outside: \(r.lines)")
        let below = handDump.replacingOccurrences(of: "frame=130,160,50,20", with: "frame=130,160,50,200")
        let b = outAndRc(h("ax_outside", below))
        #expect(b.lines.contains { $0.contains("\"Inside\"") }, "a child that runs below its group was not reported: \(b.lines)")
        let wide = handDump.replacingOccurrences(of: "frame=110,280,100,40", with: "frame=110,280,500,40")
        #expect(outAndRc(h("ax_outside", wide)).lines.contains { $0.contains("\"Scrolled\"") }, "a child wider than its scroll area was not reported")
    }

    @Test("ax_centred, ax_wide, ax_crosses, ax_frame, ax_gap_above, ax_near_bottom and ax_first_row_gap read the frames by hand-checked numbers")
    func measures() throws {
        func one(_ call: String, _ dump: String = handDump) -> (lines: [String], rc: Int) { outAndRc(h(call, dump)) }
        let a = one("ax_centred A 0 140 2")
        #expect(a.lines == ["0"] && a.rc == 0, "A centred in 0..140: \(a)")
        let b = one("ax_centred A 0 400 8")
        #expect(b.lines == ["-130"] && b.rc == 1, "A centred in 0..400: \(b)")
        #expect(one("ax_centred Nope 0 400 8").rc == 2, "an absent label is not rc 2")
        let prefixed = one("ax_centred 'Ins*' 0 100 5")
        #expect(prefixed.rc == 1 || prefixed.rc == 0, "a prefix label is not read: \(prefixed)")
        #expect(one("ax_wide A 100").rc == 0 && (one("ax_wide A 99")).rc == 1 && (one("ax_wide A 99")).lines == ["100"], "ax_wide does not read 100")
        let c = one("ax_crosses 25 0 100")
        #expect(c.lines.count == 1 && c.lines[0].contains("\"A\""), "crosses x = 25: \(c)")
        #expect(one("ax_frame B").lines == ["100 30 100 20"], "ax_frame B")
        #expect(one("ax_gap_above Inside").lines == ["60"], "the gap above Inside is not 60: \(one("ax_gap_above Inside"))")
        let nb = one("ax_near_bottom 300 20")
        #expect(nb.lines.isEmpty, "something near the bottom outside a scroll area: \(nb.lines)")
        let low = handDump.replacingOccurrences(of: "frame=130,160,50,20", with: "frame=130,340,50,20")
        #expect(one("ax_near_bottom 300 20", low).lines.contains { $0.contains("\"Inside\"") }, "an element near the bottom was not reported")
        let rows = """
        window 400 x 300 at 100, 50 title T
        AXWindow label="T" frame=100,50,400,300
          AXScrollArea frame=120,100,300,150
            AXCheckBox label="Desktop" help="/k/Desktop" value="1" frame=130,106,200,20
        """
        #expect(one("ax_first_row_gap", rows).lines == ["6"], "the first row gap is not 6")
    }

    @Test("ax_warnings prints the text next to a Warning image and nothing for a Warning far from a text; ax_ellipsis prints x and label of an element ending in the ellipsis")
    func warningsAndEllipsis() throws {
        let d = """
        window 400 x 300 at 100, 50 title T
        AXWindow label="T" frame=100,50,400,300
          AXImage label="Warning" [disabled] frame=120,100,24,24
          AXStaticText label="Could not do it" frame=152,102,200,20
          AXStaticText label="Try again in a moment." frame=152,130,200,16
          AXStaticText label="Far text" frame=120,250,100,20
        """
        #expect(outAndRc(h("ax_warnings", d)).lines == ["Could not do it"], "ax_warnings: \(h("ax_warnings", d).output)")
        let lone = d.replacingOccurrences(of: "frame=152,102,200,20", with: "frame=152,202,200,20")
        #expect(outAndRc(h("ax_warnings", lone)).lines.isEmpty, "a text far from the image was taken for its text")
        let e = """
        window 400 x 300 at 100, 50 title T
        AXWindow label="T" frame=100,50,400,300
          AXStaticText label="zqlong…" frame=140,100,100,20
          AXStaticText label="zqlongfull" frame=140,130,100,20
          AXStaticText label="other…" frame=140,160,100,20
        """
        #expect(outAndRc(h("ax_ellipsis zqlong", e)).lines == ["40\tzqlong…"], "ax_ellipsis: \(h("ax_ellipsis zqlong", e).output)")
    }

    @Test("ax_warnings also prints the text centred directly below a Warning image (the state view's layout: image above, title centred under it, at most 24 pt between and 12 pt off centre) and not a text off centre, too far below, above the image or the next-step line under the title")
    func warningsAbove() throws {
        let d = """
        window 400 x 300 at 100, 50 title T
        AXWindow label="T" frame=100,50,400,300
          AXImage label="Warning" [disabled] frame=286,100,28,28
          AXStaticText label="Search failed" frame=200,138,200,20
          AXStaticText label="Try typing again in a moment." frame=200,166,200,16
        """
        #expect(outAndRc(h("ax_warnings", d)).lines == ["Search failed"], "above and centred: \(h("ax_warnings", d).output)")
        let nudged = d.replacingOccurrences(of: "frame=200,138,200,20", with: "frame=190,138,200,20")
        #expect(outAndRc(h("ax_warnings", nudged)).lines == ["Search failed"], "a title 10 pt off centre was refused: \(h("ax_warnings", nudged).output)")
        let off = d.replacingOccurrences(of: "frame=200,138,200,20", with: "frame=100,138,200,20")
        #expect(outAndRc(h("ax_warnings", off)).lines.isEmpty, "a title 100 pt off centre was taken for the image's text: \(h("ax_warnings", off).output)")
        let far = d.replacingOccurrences(of: "frame=200,138,200,20", with: "frame=200,200,200,20")
        #expect(outAndRc(h("ax_warnings", far)).lines.isEmpty, "a title 72 pt below the image was taken for its text: \(h("ax_warnings", far).output)")
        let over = d.replacingOccurrences(of: "frame=200,138,200,20", with: "frame=200,60,200,20")
        #expect(outAndRc(h("ax_warnings", over)).lines.isEmpty, "a centred text above the image was taken for its text: \(h("ax_warnings", over).output)")
        let beside = """
        window 400 x 300 at 100, 50 title T
        AXWindow label="T" frame=100,50,400,300
          AXImage label="Warning" [disabled] frame=120,100,28,28
          AXStaticText label="Could not do it" frame=156,104,200,20
        """
        #expect(outAndRc(h("ax_warnings", beside)).lines == ["Could not do it"], "the beside placement broke: \(h("ax_warnings", beside).output)")
    }

    @Test("ax_near_bottom is given the window height: an element ending 514 pt down a 548 pt window outside a scroll area is not near the bottom, one ending at 530 is")
    func nearBottomWindowHeight() throws {
        let d = """
        window 400 x 548 at 100, 50 title T
        AXWindow label="T" frame=100,50,400,548
          AXButton label="Low" frame=120,540,100,24
          AXButton label="Lower" frame=120,556,100,24
        """
        let r = outAndRc(h("ax_near_bottom 548 20", d))
        #expect(r.lines.count == 1 && r.lines[0].contains("\"Lower\""), "near the bottom of 548: \(r.lines)")
    }

    @Test("S10.1 passes the auto parts on a clean panel in both looks and is NEEDS-A-PERSON for what the frames cannot show, listing P4 and the states that were not reached")
    func s101Pass() throws {
        let rig = try Rig()
        let r = try rig.check("S10.1")
        person(r, "S10.1", mentions: "P4", "P5", "P9", "Not ready")
        #expect(!r.output.contains("CHECK S10.1 FAIL"), "a clean panel failed: \(r.output.suffix(600))")
        let ax = rig.log("ax.log")
        #expect(ax.contains("appearance light --keep") && ax.contains("appearance dark --keep"), "the looks were not set: \(ax)")
        #expect(rig.log("search.log").contains("a dog on the beach --keep-open") && rig.log("search.log").contains("qwv zzkx lorp mnb --keep-open"), "the searches were \(rig.log("search.log"))")
        #expect(ax.contains { $0.hasPrefix("shot s10-1-light") } && ax.contains { $0.hasPrefix("shot s10-1-dark") }, "no shot in both looks: \(ax)")
        #expect(rig.log("static.log").contains("--quick"), "check-static.sh was not run")
    }

    @Test("S10.1 fails on each panel fault it reads, naming the pass-list item")
    func s101Fails() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("P1", ["P1", "divider"], { try $0.edit("panel-a_dog_on_the_beach.txt") { s10Moved($0, "beach-dog", 350, 330, 300, 20) } }),
            ("P2 title", ["P2", "No matches", "centred"], { try $0.edit("panel-qwv_zzkx_lorp_mnb.txt") { s10Moved($0, "No matches", 20, 240, 200, 24) } }),
            ("P2 hint", ["P2", "centred"], { try $0.edit("panel-empty.txt") { s10Moved($0, "Describe what you want, or type part of a name or text.", 400, 230, 320, 34) } }),
            ("P3", ["P3", "320"], { try $0.edit("panel-qwv_zzkx_lorp_mnb.txt") { s10Moved($0, "Describe what is in the file, or type part of its exact name or text.", 0, 276, 400, 40) } }),
            ("P7", ["P7", "literal"], { try $0.put("lc", "FAIL\n") }),
            ("P8", ["P8", "luma"], { _ in }),
            ("P10", ["P10", "footer"], { try $0.addLine("panel-qwv_zzkx_lorp_mnb.txt", "AXStaticText", "No matches here", 300, 536, 100, 14) }),
            ("overlap", ["overlap"], { try $0.addLine("panel-empty.txt", "AXStaticText", "Planted sample", 20, 536, 100, 14) }),
            ("outside", ["outside"], { try $0.addLine("panel-empty.txt", "AXStaticText", "Planted wide", 900, 400, 100, 20) }),
            ("dark only", ["dark", "centred"], { try $0.put("panel-qwv_zzkx_lorp_mnb-dark.txt", s10Moved($0.read("panel-qwv_zzkx_lorp_mnb.txt"), "No matches", 10, 240, 200, 24)) }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.1", env: name == "P8" ? ["LUMA_DARK": "190"] : [:])
            #expect(r.verdict.hasPrefix("CHECK S10.1 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.1 reads the empty hint centred on the whole 960 pt panel (guide 17, mockup A): the old right-region layout, a sample off centre and a hint off centre each FAIL naming P2 and centred")
    func s101EmptyHintCentredOnTheWholePanel() throws {
        let hint = "Describe what you want, or type part of a name or text."
        let cases: [(String, String, (Rig) throws -> Void)] = [
            ("old layout, hint text at centre 672", "Describe what you want", { try $0.edit("panel-empty.txt") { s10Moved($0, hint, 512, 230, 320, 34) } }),
            ("old layout, first sample at centre 670", "a dog on the beach", { try $0.edit("panel-empty.txt") { s10Moved($0, "a dog on the beach", 560, 280, 220, 22) } }),
            ("hint centred, first sample off", "a dog on the beach", { try $0.edit("panel-empty.txt") { s10Moved($0, "a dog on the beach", 300, 280, 220, 22) } }),
        ]
        for (name, named, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.1")
            #expect(r.verdict.hasPrefix("CHECK S10.1 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in ["P2", "centred", named] { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
        let edge = try Rig()
        try edge.edit("panel-empty.txt") { s10Moved($0, "a dog on the beach", 370 + 8, 280, 220, 22) }
        #expect(!(try edge.check("S10.1")).verdict.hasPrefix("CHECK S10.1 FAIL"), "a sample 8 pt off centre, the tolerance, failed")
        let past = try Rig()
        try past.edit("panel-empty.txt") { s10Moved($0, "a dog on the beach", 370 + 10, 280, 220, 22) }
        #expect((try past.check("S10.1")).verdict.hasPrefix("CHECK S10.1 FAIL"), "a sample 10 pt off centre did not fail")
    }

    @Test("S10.1 is exit 4 for a state it cannot reach or read: no frames in a dump, a cut dump, no panel, a failed golden state, an unreadable dump")
    func s101Reruns() throws {
        let noFrames = try Rig()
        try noFrames.put("panel-empty.txt", s10PanelDump("empty", old: true))
        rerun(try noFrames.check("S10.1"), "S10.1")
        let cut = try Rig()
        try cut.edit("panel-empty.txt") { $0 + "(tree cut at 1200 elements)\n" }
        let c = try cut.check("S10.1")
        rerun(c, "S10.1")
        #expect(c.output.contains("tree cut"), "the cut line was not named: \(c.output.suffix(300))")
        let gone = try Rig()
        gone.remove("panel-empty.txt")
        let g = try gone.check("S10.1")
        rerun(g, "S10.1")
        #expect(g.output.contains("no window"), "the driver's output was not printed: \(g.output.suffix(300))")
        let state = try Rig()
        rerun(try state.check("S10.1", pre: "GOLDEN_RC=4"), "S10.1")
        let panel = try Rig()
        rerun(try panel.check("S10.1", pre: "PANEL_RC=1"), "S10.1")
    }

    @Test("S10.1 is exit 4, never a PASS or a FAIL, when the search for a dog on the beach lists no row (rows 0 or no rows line), and the no-match search listing none is not an error")
    func s101NeedsRows() throws {
        let control = try Rig()
        #expect(control.read("rows-qwv_zzkx_lorp_mnb") == "0" && control.read("rows-a_dog_on_the_beach") == "", "the control world is not a search with results and a no-match search")
        person(try control.check("S10.1"), "S10.1", mentions: "P4")
        for count in ["0", "x"] {
            let rig = try Rig()
            try rig.put("rows-a_dog_on_the_beach", count)
            let r = try rig.check("S10.1")
            rerun(r, "S10.1")
            #expect(r.output.contains("no result row"), "rows \(count): the RERUN does not say that no row was listed: \(r.output.suffix(300))")
            #expect(!r.output.contains("FAIL"), "rows \(count): a missing row was a FAIL: \(r.output.suffix(300))")
        }
    }

    @Test("S10.2 reads the four Setup steps in both looks (1 to 4 in Light, back from 4 to 1 in Dark), goes on from Folders with a whole model through Not now and never presses Start indexing (guide 15.3), and is NEEDS-A-PERSON for what the frames cannot show")
    func s102Pass() throws {
        let rig = try Rig()
        let r = try rig.check("S10.2")
        person(r, "S10.2", mentions: "only the footer's right button and the current dot carry the accent (W5)", "the model block, every checkbox name fully visible and the 4.5 to 1 contrast on the window and card surfaces over glass in both looks", "shot-s10-2-light-N and shot-s10-2-dark-N", "the Permissions card, its hairlines and the note are read from the shots shot-s10-2-light-3 and shot-s10-2-dark-3", "the keycaps (neutral fill, hairline border, lower edge, symbol and caption, Light and Dark repaint) are read from the shots shot-s10-2-light-4 and shot-s10-2-dark-4", "the footer's Start indexing is the only accent button and is easy to see, the hint line and Not now read quietly, and the Shortcut running line fits are read from the shots shot-s10-2-light-2, shot-s10-2-dark-2, shot-s10-2-light-4 and shot-s10-2-dark-4")
        #expect(!r.verdict.contains("accent tint"), "the person line still asks for the accent tint of Start indexing: \(r.verdict)")
        #expect(!r.verdict.contains("Start indexing is plain"), "the person line still says Start indexing is plain: \(r.verdict)")
        let ax = rig.log("ax.log")
        #expect(ax.filter { $0 == "click Next" }.count == 2 && ax.filter { $0 == "click Not now" }.count == 1 && ax.filter { $0 == "click Back" }.count == 3, "Next, Not now and Back were pressed as \(ax.filter { $0.hasPrefix("click") })")
        #expect(!ax.contains("click Start indexing"), "S10.2 pressed Start indexing: \(ax.filter { $0.hasPrefix("click") })")
        #expect(ax.contains("appearance light --keep") && ax.contains("appearance dark --keep"), "the looks were not set")
    }

    @Test("S10.2 fails on each Setup fault it reads, naming the pass-list item")
    func s102Fails() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("S1 size", ["S1", "560 x 628"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "window 560 x 628", with: "window 560 x 600") } }),
            ("S2 row", ["S2", "footer"], { try $0.edit("setup-3.txt") { s10Moved($0, "Next", 440, 500, 100, 24) } }),
            ("S2 side", ["S2", "footer"], { try $0.edit("setup-4.txt") { s10Moved($0, "Finish", 300, 556, 100, 24) } }),
            ("S1 blank", ["S1", "blank"], { try $0.edit("setup-1.txt") { s10Moved($0, "Search model ready", 180, 380, 200, 18) } }),
            ("W3 Back on step 1", ["W3", "Back"], { try $0.addLine("setup-1.txt", "AXButton", "Back", 20, 556, 80, 24) }),
            ("W3 dots off centre", ["W3", "centred"], { try $0.edit("setup-3.txt") { s10Moved($0, "Step 3 of 4: Permissions", 100, 564, 56, 8) } }),
            ("W4 no dots group", ["W4", "dots"], { try $0.edit("setup-2.txt") { s10Without($0, containing: "Step 2 of 4: Folders") } }),
            ("W4 wrong title", ["W4", "Step 2 of 4: Folders"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "Step 2 of 4: Folders", with: "Step 2 of 4: Folder") } }),
            ("W4 caption is a text", ["W4", "group"], { try $0.edit("setup-3.txt") { $0.replacingOccurrences(of: "AXGroup label=\"Step 3 of 4: Permissions\"", with: "AXStaticText label=\"Step 3 of 4: Permissions\"") } }),
            ("S3", ["S3", "first folder row"], { try $0.edit("setup-2.txt") { s10Moved($0, "Desktop", 36, 200, 300, 20) } }),
            ("S4 Add folder below the read note", ["S4", "Add folder", "above the read note"], { try $0.edit("setup-2.txt") { s10Moved($0, "Add folder…", 20, 400, 110, 20) } }),
            ("S4 no read note", ["S4", "read note"], { try $0.edit("setup-2.txt") { s10Without($0, containing: s10ReadNote) } }),
            ("W11 ready line on Folders", ["W11", "Search model ready"], { try $0.addLine("setup-2.txt", "AXStaticText", "Search model ready", 180, 522, 200, 18) }),
            ("S6", ["S6", "scroller"], { try $0.addLine("setup-1.txt", "AXScrollBar", "vertical scroll bar", 540, 240, 12, 100) }),
            ("overlap", ["overlap"], { try $0.edit("setup-3.txt") { $0.components(separatedBy: "\n").flatMap { $0.contains("label=\"USB drives and external disks\"") ? [$0, "    AXStaticText label=\"Planted\" frame=136,154,200,16"] : [$0] }.joined(separator: "\n") } }),
            ("outside", ["outside"], { try $0.addLine("setup-3.txt", "AXStaticText", "Planted wide", 500, 400, 200, 16) }),
            ("dark only", ["dark", "footer"], { try $0.put("setup-2-dark.txt", s10Moved($0.read("setup-2.txt"), "Back", 40, 556, 80, 24)) }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.2")
            #expect(r.verdict.hasPrefix("CHECK S10.2 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    private func foldersWorld(_ state: S10Folders, shortcutStarted: Bool? = nil) throws -> Rig {
        let rig = try Rig()
        try rig.put("setup-2.txt", s10SetupDump(2, old: false, long: false, root: rig.kit, folders: state))
        try rig.put("setup-4.txt", s10SetupDump(4, old: false, long: false, root: rig.kit, started: shortcutStarted ?? (state == .started)))
        return rig
    }

    @Test("S10.2 passes the Folders footer the person chose (guide 15.1 to 15.5, W22 to W24) in every state the screen can be in, with a Shortcut step that matches how Folders was left: a whole model shows Start indexing as the footer's right button with the hint and Not now (disabled with the tick-one hint when no row is ticked); the model not whole or Start already pressed shows Next, no hint, no Not now and no Start indexing; after Start the Shortcut step holds the running line (W25) with the keycaps centred between the lead and the note (W26)", arguments: [S10Folders.whole, S10Folders.noTick, S10Folders.notWhole, S10Folders.started])
    func s102FoldersFooterPass(state: S10Folders) throws {
        let rig = try foldersWorld(state)
        person(try rig.check("S10.2"), "S10.2")
        let ax = rig.log("ax.log")
        #expect(!ax.contains("click Start indexing"), "S10.2 pressed Start indexing: \(ax.filter { $0.hasPrefix("click") })")
        let notNow = (state == .whole || state == .noTick) ? 1 : 0
        #expect(ax.filter { $0 == "click Not now" }.count == notNow && ax.filter { $0 == "click Next" }.count == 3 - notNow, "Next and Not now were pressed as \(ax.filter { $0.hasPrefix("click") })")
    }

    @Test("S10.2 passes the Folders footer and the Shortcut running line at the edge of each tolerance: Start indexing ending 538 and 542 from the window's left edge, 4 pt off the Back row's centre, the hint and Not now 8 pt off centre, and after Start the running line ending 24 pt above the footer, 8 pt off centre, the keycaps 7 pt off the middle of their space")
    func s102FoldersFooterEdges() throws {
        let whole: [(String, (String) -> String)] = [
            ("Start indexing ends at 538", { s10Moved($0, "Start indexing", 418, 556, 120, 24) }),
            ("Start indexing ends at 542", { s10Moved($0, "Start indexing", 422, 556, 120, 24) }),
            ("Start indexing 4 pt below the Back row's centre", { s10Moved($0, "Start indexing", 420, 560, 120, 24) }),
            ("hint 8 pt right of centre", { s10Moved($0, s10HintStart, 88, 330, 400, 14) }),
            ("Not now 8 pt left of centre", { s10Moved($0, "Not now", 227, 382, 90, 20) }),
        ]
        for (name, change) in whole {
            let rig = try foldersWorld(.whole)
            try rig.edit("setup-2.txt", change)
            let r = try rig.check("S10.2")
            #expect(r.verdict.hasPrefix("CHECK S10.2 NEEDS-A-PERSON") && r.rc == 0, "\(name): not a pass: \(r.verdict) rc \(r.rc)")
        }
        let started: [(String, (String) -> String)] = [
            ("running line ends 24 above the footer", { s10Moved($0, s10Running, 80, 517, 400, 15) }),
            ("running line 8 pt right of centre", { s10Moved($0, s10Running, 88, 525, 400, 15) }),
            ("keycaps 7 pt below the middle of the space", { s10Moved($0, s10ShortcutKeys, 176, 267, 208, 62) }),
        ]
        for (name, change) in started {
            let rig = try foldersWorld(.started)
            try rig.edit("setup-4.txt", change)
            let r = try rig.check("S10.2")
            #expect(r.verdict.hasPrefix("CHECK S10.2 NEEDS-A-PERSON") && r.rc == 0, "\(name): not a pass: \(r.verdict) rc \(r.rc)")
        }
    }

    @Test("S10.2 fails on each Folders footer fault of guide 15.2 to 15.5 and each Shortcut running-line fault of guide 15.6, naming W22 to W26: the hint missing, not centred, below the read note, above Add folder or with the other text (W23); a Next beside Start indexing, Start indexing not at the footer's right, off the Back row, a text and not a button, or disabled with a ticked row (W22); Not now missing, not centred or above the read note (W24); no ticked row with Start indexing enabled or the wrong hint (W23); the model not whole, or Start already pressed, with a Start indexing button, a hint or Not now (W22); the Shortcut step after Start with no running line, the line above the note or off centre, or without Start with the line (W25); the keycaps not centred between the lead and the note after Start, or left where they were without the line (W26); the S1 blank block read from the lowest text")
    func s102FoldersFooterFails() throws {
        func addStart(_ r: Rig) throws { try r.addLine("setup-2.txt", "AXButton", "Start indexing", 420, 556, 120, 24) }
        let cases: [(String, S10Folders, Bool?, [String], (Rig) throws -> Void)] = [
            ("W23 the hint is missing", .whole, nil, ["W23", "hint"], { try $0.edit("setup-2.txt") { s10Without($0, containing: s10HintStart) } }),
            ("W23 the hint is not centred", .whole, nil, ["W23", "hint", "centred"], { try $0.edit("setup-2.txt") { s10Moved($0, s10HintStart, 20, 330, 400, 14) } }),
            ("W23 the hint is 9 pt off centre", .whole, nil, ["W23", "hint", "centred"], { try $0.edit("setup-2.txt") { s10Moved($0, s10HintStart, 89, 330, 400, 14) } }),
            ("W23 the hint is below the read note", .whole, nil, ["W23", "hint", "above the read note"], { try $0.edit("setup-2.txt") { s10Moved($0, s10HintStart, 80, 410, 400, 14) } }),
            ("W23 the hint is above Add folder", .whole, nil, ["W23", "hint", "below Add folder"], { try $0.edit("setup-2.txt") { s10Moved($0, s10HintStart, 80, 280, 400, 14) } }),
            ("W23 the hint has the text of the no-tick world", .whole, nil, ["W23", "hint reads"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "label=\"\(s10HintStart)\"", with: "label=\"\(s10HintTick)\"") } }),
            ("W22 a Next button beside Start indexing", .whole, nil, ["W22", "Next"], { try $0.addLine("setup-2.txt", "AXButton", "Next", 440, 556, 100, 24) }),
            ("W22 Start indexing not at the footer's right", .whole, nil, ["W22", "Start indexing", "right edge"], { try $0.edit("setup-2.txt") { s10Moved($0, "Start indexing", 225, 500, 120, 24) } }),
            ("W22 Start indexing ends at 537", .whole, nil, ["W22", "right edge"], { try $0.edit("setup-2.txt") { s10Moved($0, "Start indexing", 417, 556, 120, 24) } }),
            ("W22 Start indexing 5 pt below the Back row's centre", .whole, nil, ["W22", "one row"], { try $0.edit("setup-2.txt") { s10Moved($0, "Start indexing", 420, 561, 120, 24) } }),
            ("W22 Start indexing disabled with a ticked row", .whole, nil, ["W22", "disabled", "ticked"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "label=\"Start indexing\" frame", with: "label=\"Start indexing\" [disabled] frame") } }),
            ("W22 Start indexing is a text, not a button", .whole, nil, ["W22", "not a button"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "AXButton label=\"Start indexing\"", with: "AXStaticText label=\"Start indexing\"") } }),
            ("W24 Not now is missing", .whole, nil, ["W24", "Not now"], { try $0.edit("setup-2.txt") { s10Without($0, containing: "label=\"Not now\"") } }),
            ("W24 Not now is not centred", .whole, nil, ["W24", "centred"], { try $0.edit("setup-2.txt") { s10Moved($0, "Not now", 20, 382, 90, 20) } }),
            ("W24 Not now is above the read note", .whole, nil, ["W24", "below the read note"], { try $0.edit("setup-2.txt") { s10Moved($0, "Not now", 235, 340, 90, 20) } }),
            ("W23 no row ticked and Start indexing enabled", .noTick, nil, ["W23", "enabled"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "label=\"Start indexing\" [disabled] frame", with: "label=\"Start indexing\" frame") } }),
            ("W23 no row ticked and the hint of a ticked row", .noTick, nil, ["W23", "hint reads"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "label=\"\(s10HintTick)\"", with: "label=\"\(s10HintStart)\"") } }),
            ("W23 no row ticked and a hint with other words", .noTick, nil, ["W23", "no hint line"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "label=\"\(s10HintTick)\"", with: "label=\"Tick a folder to start.\"") } }),
            ("W23 a ticked row and the no-tick hint", .whole, nil, ["W23", "hint reads"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "label=\"\(s10HintStart)\"", with: "label=\"\(s10HintTick)\"") } }),
            ("W22 the model not whole and a Start indexing button", .notWhole, nil, ["W22", "not whole", "Start indexing"], addStart),
            ("W22 the model not whole and a hint", .notWhole, nil, ["W22", "hint"], { try $0.addLine("setup-2.txt", "AXStaticText", s10HintStart, 80, 330, 400, 14) }),
            ("W22 the model not whole and Not now", .notWhole, nil, ["W22", "Not now"], { try $0.addLine("setup-2.txt", "AXButton", "Not now", 235, 382, 90, 20) }),
            ("W22 after Start and a Start indexing button", .started, nil, ["W22", "Next"], addStart),
            ("W22 after Start and a hint", .started, nil, ["W22", "hint"], { try $0.addLine("setup-2.txt", "AXStaticText", s10HintStart, 80, 330, 400, 14) }),
            ("W22 after Start and Not now", .started, nil, ["W22", "Not now"], { try $0.addLine("setup-2.txt", "AXButton", "Not now", 235, 382, 90, 20) }),
            ("W25 after Start and no running line", .started, false, ["W25", "running line"], { _ in }),
            ("W25 after Start and the running line above the note", .started, nil, ["W25", "above the note"], { try $0.edit("setup-4.txt") { s10Moved($0, s10Running, 80, 480, 400, 15) } }),
            ("W25 after Start and the running line off centre", .started, nil, ["W25", "centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10Running, 20, 525, 400, 15) } }),
            ("W25 after Start and the running line 9 pt off centre", .started, nil, ["W25", "centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10Running, 89, 525, 400, 15) } }),
            ("W25 after Start and the running line without a frame", .started, nil, ["W25", "no frame"], { try $0.edit("setup-4.txt") { $0.replacingOccurrences(of: "label=\"\(s10Running)\" frame=180,575,400,15", with: "label=\"\(s10Running)\"") } }),
            ("W25 without Start and the running line", .whole, true, ["W25", "Start was not pressed"], { _ in }),
            ("W25 with the model not whole and the running line", .notWhole, true, ["W25", "Start was not pressed"], { _ in }),
            ("W26 after Start and the keycaps too high in their space", .started, nil, ["W26", "vertically centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 176, 200, 208, 62) } }),
            ("W26 after Start and the keycaps left where they were without the line", .started, nil, ["W26", "vertically centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 176, 270, 208, 62) } }),
            ("S1 blank block with the running line above the note", .started, nil, ["S1", "blank"], { try $0.edit("setup-4.txt") { s10Moved($0, s10Running, 80, 400, 400, 15) } }),
        ]
        for (name, state, shortcutStarted, words, mutate) in cases {
            let rig = try foldersWorld(state, shortcutStarted: shortcutStarted)
            try mutate(rig)
            let r = try rig.check("S10.2")
            #expect(r.verdict.hasPrefix("CHECK S10.2 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.2 keeps its plant on the new Folders footer and the started Shortcut: with --plant, a text added on top of the first text of every Setup dump fails, in the whole, started and no-tick worlds", arguments: [S10Folders.whole, S10Folders.started, S10Folders.noTick])
    func s102FoldersFooterKeepsItsPlant(state: S10Folders) throws {
        let rig = try foldersWorld(state)
        let r = try rig.check("S10.2", plant: true)
        #expect(r.verdict.hasPrefix("CHECK S10.2 FAIL planted") && r.rc == 1, "S10.2 --plant on \(state): rc \(r.rc), \(r.verdict)")
    }

    @Test("S10.2 goes on from a Folders step that has neither Next nor Not now by pressing Not now, never Start indexing, and fails the missing Not now (W24)")
    func s102ForwardFromFolders() throws {
        let neither = try foldersWorld(.whole)
        try neither.edit("setup-2.txt") { s10Without($0, containing: "label=\"Not now\"") }
        let r = try neither.check("S10.2")
        #expect(r.verdict.hasPrefix("CHECK S10.2 FAIL") && r.verdict.contains("W24"), "a Folders dump with no Not now and no Next was not a W24 FAIL: \(r.verdict)")
        #expect(neither.log("ax.log").contains("click Not now") && !neither.log("ax.log").contains("click Start indexing"), "the walk pressed \(neither.log("ax.log").filter { $0.hasPrefix("click") })")
    }

    @Test("S10.2 is exit 4 when Not now cannot be pressed on Folders, naming the press")
    func s102ForwardFails() throws {
        let rig = try foldersWorld(.whole)
        let r = try rig.check("S10.2", pre: "kq() { case \"$*\" in *\"click Not now\"*) echo \"no such button\"; return 1 ;; esac; KIT_NO_EVIDENCE=1 \"$@\"; }")
        rerun(r, "S10.2")
        #expect(r.output.contains("Not now"), "the RERUN does not name the press: \(r.output.suffix(300))")
    }

    @Test("S10.2 passes the Permissions step as the person chose it (guide 12.1: a card as tall as its four rows, the read note centred, no status line with a whole model), with the card group in the dump and without it, because the real dump shows the texts straight under the window")
    func s102PermissionsPass() throws {
        let grouped = try Rig()
        person(try grouped.check("S10.2"), "S10.2")
        let flat = try Rig()
        try flat.edit("setup-3.txt") { s10Without($0, containing: "AXGroup frame=").replacingOccurrences(of: "\n    AXStaticText", with: "\n  AXStaticText") }
        #expect(!flat.read("setup-3.txt").contains("\n    AX"), "the flat Permissions dump still has a nested element")
        person(try flat.check("S10.2"), "S10.2")
    }

    @Test("S10.2 fails on each Permissions fault of guide 12.1 and 12.4, naming W13 or W14: a blank block above the first name or below the last reason, a read note off centre, a status line with a whole model, names out of order or below their reason, a name with no frame")
    func s102PermissionsFails() throws {
        func rows(_ text: String, dy: Int) -> String {
            var t = text
            for (i, f) in ["Desktop", "Documents", "Downloads", "Removable volumes"].enumerated() {
                t = s10Moved(t, f, 36, 104 + 49 * i + dy, 200, 16)
                t = s10Moved(t, ["Files on your Desktop", "Files in your Documents folder", "Files in your Downloads folder", "USB drives and external disks"][i], 36, 122 + 49 * i + dy, 300, 15)
            }
            return t
        }
        let note = "Sesame never asks for Full Disk Access, camera or microphone."
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("W13 blank block above the first name", ["W13", "first name", "blank"], { try $0.edit("setup-3.txt") { rows($0, dy: 30) } }),
            ("W13 blank block below the last reason", ["W13", "last reason", "blank"], { try $0.edit("setup-3.txt") { s10Moved($0, note, 99, 342, 362, 15) } }),
            ("W13 read note off centre", ["W13", "read note", "centred"], { try $0.edit("setup-3.txt") { s10Moved($0, note, 20, 312, 362, 15) } }),
            ("W14 ready line with a whole model", ["W14", "Search model ready"], { try $0.addLine("setup-3.txt", "AXStaticText", "Search model ready", 180, 522, 200, 18) }),
            ("W13 Documents above Desktop", ["W13", "Documents", "not below"], {
                try $0.edit("setup-3.txt") { t in
                    var u = s10Moved(t, "Desktop", 36, 153, 200, 16)
                    u = s10Moved(u, "Files on your Desktop", 36, 171, 300, 15)
                    u = s10Moved(u, "Documents", 36, 104, 200, 16)
                    return s10Moved(u, "Files in your Documents folder", 36, 122, 300, 15)
                }
            }),
            ("W13 a name below its reason", ["W13", "Desktop", "not above its reason"], { try $0.edit("setup-3.txt") { s10Moved($0, "Desktop", 36, 140, 200, 16) } }),
            ("W13 Desktop has no frame", ["W13", "Desktop"], { try $0.edit("setup-3.txt") { s10Without($0, containing: "label=\"Desktop\"") } }),
            ("W13 a reason has no frame", ["W13", "USB drives and external disks"], { try $0.edit("setup-3.txt") { s10Without($0, containing: "label=\"USB drives and external disks\"") } }),
            ("W14 in Dark only", ["W14", "dark"], { try $0.put("setup-3-dark.txt", s10Append($0.read("setup-3.txt"), "  AXStaticText label=\"Search model ready\" frame=280,572,200,18")) }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.2")
            #expect(r.verdict.hasPrefix("CHECK S10.2 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.2 passes the Shortcut step as the person chose it (guide 13.1 to 13.3: the heading and the lead centred, the keycaps one accessibility group of at most 520 pt centred between the lead and the note, the note centred, no status line with a whole model), also at the edges of each tolerance: a group exactly 520 wide, a group, a heading and a note 8 pt off centre, a group 15 half-points off the middle of the space")
    func s102ShortcutPass() throws {
        let plain = try Rig()
        person(try plain.check("S10.2"), "S10.2")
        let edges: [(String, (String) -> String)] = [
            ("group 520 wide", { s10Moved($0, s10ShortcutKeys, 20, 270, 520, 62) }),
            ("group 8 pt right of centre", { s10Moved($0, s10ShortcutKeys, 184, 270, 208, 62) }),
            ("group 7 pt lower than the middle", { s10Moved($0, s10ShortcutKeys, 176, 277, 208, 62) }),
            ("heading 8 pt right of centre", { s10Moved($0, s10ShortcutHeading, 138, 24, 300, 30) }),
            ("lead 8 pt left of centre", { s10Moved($0, s10ShortcutLead, 187, 62, 170, 18) }),
            ("note 8 pt right of centre", { s10Moved($0, s10ShortcutNote, 143, 521, 290, 15) }),
            ("note ending 24 pt above the footer", { s10Moved($0, s10ShortcutNote, 135, 517, 290, 15) }),
        ]
        for (name, change) in edges {
            let rig = try Rig()
            try rig.edit("setup-4.txt", change)
            let r = try rig.check("S10.2")
            #expect(r.verdict.hasPrefix("CHECK S10.2 NEEDS-A-PERSON") && r.rc == 0, "\(name): not a pass: \(r.verdict) rc \(r.rc)")
        }
    }

    @Test("S10.2 fails on each Shortcut fault of guide 13.1 to 13.4, naming W15, W16 or W17: the heading, the lead or the note off centre, the lead above the heading, no keycaps group, the shortcut still a plain text or a text field, the group wider than 520 pt, off centre, not between the lead and the note or not vertically centred in that space, a child inside the group, a missing frame, a status line with a whole model, and the S1 blank block on step 4")
    func s102ShortcutFails() throws {
        func underGroup(_ text: String) -> String {
            text.components(separatedBy: "\n").flatMap { $0.contains("AXGroup label=\"\(s10ShortcutKeys)\"") ? [$0, "    AXStaticText label=\"Control\" frame=276,340,44,15"] : [$0] }.joined(separator: "\n")
        }
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("W15 heading off centre", ["W15", "heading", "centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutHeading, 10, 24, 300, 30) } }),
            ("W15 lead off centre", ["W15", "lead", "centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutLead, 20, 62, 170, 18) } }),
            ("W15 lead above the heading", ["W15", "lead", "under the heading"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutLead, 195, 2, 170, 18) } }),
            ("W15 note off centre", ["W15", "note", "centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutNote, 20, 521, 290, 15) } }),
            ("W15 heading has no frame", ["W15", "heading"], { try $0.edit("setup-4.txt") { s10Without($0, containing: "label=\"\(s10ShortcutHeading)\"") } }),
            ("W15 lead has no frame", ["W15", "lead"], { try $0.edit("setup-4.txt") { s10Without($0, containing: "label=\"\(s10ShortcutLead)\"") } }),
            ("W15 note has no frame", ["W15", "note"], { try $0.edit("setup-4.txt") { s10Without($0, containing: "label=\"\(s10ShortcutNote)\"") } }),
            ("W16 no keycaps group", ["W16", "AXGroup", s10ShortcutKeys], { try $0.edit("setup-4.txt") { s10Without($0, containing: "AXGroup label=\"\(s10ShortcutKeys)\"") } }),
            ("W16 the shortcut is a plain text", ["W16", "AXStaticText", "group"], { try $0.edit("setup-4.txt") { $0.replacingOccurrences(of: "AXGroup label=\"\(s10ShortcutKeys)\"", with: "AXStaticText label=\"\(s10ShortcutKeys)\"") } }),
            ("W16 the shortcut is a text field", ["W16", "AXTextField", "group"], { try $0.edit("setup-4.txt") { $0.replacingOccurrences(of: "AXGroup label=\"\(s10ShortcutKeys)\"", with: "AXTextField label=\"\(s10ShortcutKeys)\"") } }),
            ("W16 the old text kept beside the group", ["W16", "AXStaticText"], { try $0.addLine("setup-4.txt", "AXStaticText", s10ShortcutKeys, 200, 200, 160, 30) }),
            ("W16 group wider than 520", ["W16", "520"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 10, 270, 540, 62) } }),
            ("W16 a child inside the group", ["W16", "children"], { try $0.edit("setup-4.txt", underGroup) }),
            ("W15 group has no frame", ["W15", "group"], { try $0.edit("setup-4.txt") { $0.replacingOccurrences(of: "AXGroup label=\"\(s10ShortcutKeys)\" frame=276,320,208,62", with: "AXGroup label=\"\(s10ShortcutKeys)\"") } }),
            ("W15 group off centre", ["W15", "group", "centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 20, 270, 208, 62) } }),
            ("W15 group 9 pt off centre", ["W15", "group", "centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 185, 270, 208, 62) } }),
            ("W15 group below the note", ["W15", "between the lead and the note"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 176, 540, 208, 62) } }),
            ("W15 group above the lead", ["W15", "between the lead and the note"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 176, 0, 208, 20) } }),
            ("W15 group too high in the space", ["W15", "vertically centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 176, 100, 208, 62) } }),
            ("W15 group too low in the space", ["W15", "vertically centred"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutKeys, 176, 285, 208, 62) } }),
            ("W17 ready line with a whole model", ["W17", "Search model ready"], { try $0.addLine("setup-4.txt", "AXStaticText", "Search model ready", 180, 522, 200, 18) }),
            ("W17 ready line in Dark only", ["W17", "dark"], { try $0.put("setup-4-dark.txt", s10Append($0.read("setup-4.txt"), "  AXStaticText label=\"Search model ready\" frame=280,572,200,18")) }),
            ("W15 heading off centre in Dark only", ["W15", "dark", "heading"], { try $0.put("setup-4-dark.txt", s10Moved($0.read("setup-4.txt"), s10ShortcutHeading, 10, 24, 300, 30)) }),
            ("S1 blank block on step 4", ["S1", "blank"], { try $0.edit("setup-4.txt") { s10Moved($0, s10ShortcutNote, 135, 400, 290, 15) } }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.2")
            #expect(r.verdict.hasPrefix("CHECK S10.2 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.2 is exit 4 when a step label is missing, the dumps hold no frames, or the Setup state fails")
    func s102Reruns() throws {
        let step = try Rig()
        try step.put("setup-3.txt", "window 560 x 628 at 100, 50 title Set up Sesame\nAXWindow label=\"Set up Sesame\" frame=100,50,560,628\n")
        rerun(try step.check("S10.2"), "S10.2")
        let frames = try Rig()
        try frames.put("setup-1.txt", s10SetupDump(1, old: true, long: false, root: frames.kit))
        rerun(try frames.check("S10.2"), "S10.2")
        let state = try Rig()
        rerun(try state.check("S10.2", pre: "SETUP_RC=1"), "S10.2")
        let stuck = try Rig()
        try stuck.put("setup-2.txt", s10SetupDump(1, old: false, long: false, root: stuck.kit))
        rerun(try stuck.check("S10.2"), "S10.2")
    }

    @Test("ax_has_label finds the dots group by its exact title in the new Setup dump of every step and the static caption in the old one, and no other title")
    func stepTitleIsReadFromTheGroup() throws {
        let names = ["Welcome", "Folders", "Permissions", "Shortcut"]
        for n in 1...4 {
            let title = "Step \(n) of 4: \(names[n - 1])"
            for old in [false, true] {
                let r = outAndRc(h("ax_has_label \"\(title)\"", s10SetupDump(n, old: old, long: false, root: "/k")))
                #expect(r.rc == 0, "ax_has_label \"\(title)\" did not find the title in the \(old ? "old" : "new") dump of step \(n)")
            }
            let other = "Step \(n % 4 + 1) of 4: \(names[n % 4])"
            #expect(outAndRc(h("ax_has_label \"\(other)\"", s10SetupDump(n, old: false, long: false, root: "/k"))).rc != 0, "the dump of step \(n) answers to \"\(other)\"")
        }
    }

    @Test("S10.3 reads the four Settings sections of the System Settings shell and the open Delete index confirm in both looks, never presses About, and is NEEDS-A-PERSON for what the frames cannot show (the flat full-height sidebar column, 12 pt cards, the more button and its menu, the sidebar icons and the File types switches); the world holds the sidebar buttons at x 8, the pane title at 197 and the scroll area at 181, 539 wide, because the real sidebar moved (guide 18), so this pass reads W54 and W55 on the world itself; the Indexing world is layout A (guide 16.15): the Launch at login switch at the right of its caption, Start indexing and Delete index… under it on one left edge, so this pass reads W42 and W43 on the world and the person text carries T11 with the shots shot-s10-3-light-indexing, shot-s10-3-dark-indexing and shot-s10-3-light-confirm")
    func s103Pass() throws {
        let rig = try Rig()
        let r = try rig.check("S10.3")
        person(r, "S10.3", mentions: "T3", "T5", "T8", "T9", "12 pt", "more button", "flat full-height column", "no rounded corner", "thin line on its right edge", "on the sidebar column", "four sidebar labels start at one x", "no lighter fill inside", "File types switches")
        #expect(!r.output.contains("rounded panel") && !r.output.contains("floats") && !r.output.contains("W54") && !r.output.contains("W55"), "the S10.3 text still describes a floating panel, or the world failed W54 or W55: \(r.output.suffix(600))")
        person(r, "S10.3", mentions: "T11 Indexing is a Launch at login card with its caption at the left and a switch at the right, then a card with Start indexing at normal size and Delete index... under a hairline in red text, and each file Sesame could not read as a name over its reason", "read the shots shot-s10-3-light-indexing, shot-s10-3-dark-indexing and shot-s10-3-light-confirm")
        #expect(!r.output.contains("W42") && !r.output.contains("W43"), "the Indexing layout A world failed W42 or W43: \(r.output.suffix(600))")
        let ax = rig.log("ax.log")
        #expect(ax.contains("shot s10-3-light-indexing") && ax.contains("shot s10-3-dark-indexing") && ax.contains("shot s10-3-light-confirm"), "the Indexing shots T11 names were not taken: \(ax.filter { $0.hasPrefix("shot") })")
        #expect(ax.contains("click Delete index…") && ax.contains("click Cancel"), "the confirm was not opened and closed: \(ax.filter { $0.hasPrefix("click") })")
        #expect(ax.contains("appearance light --keep") && ax.contains("appearance dark --keep"), "the looks were not set")
        #expect(["Folders", "File types", "Search", "Indexing"].allSatisfy { ax.contains("click \($0)") } && !ax.contains("click About"), "the sidebar presses were \(ax.filter { $0.hasPrefix("click") })")
    }

    @Test("S10.3 passes the new Settings shell worlds with the more button read in either role the guide allows (AXPopUpButton or AXMenuButton), and with a row's open more menu holding Re-index and Remove as menu items")
    func s103ShellWorldsPass() throws {
        for role in ["AXPopUpButton", "AXMenuButton"] {
            let rig = try Rig()
            try rig.put("settings-Folders.txt", s10SettingsDump("Folders", old: false, long: false, root: rig.kit, moreRole: role))
            person(try rig.check("S10.3"), "S10.3", mentions: "T5")
        }
        let open = try Rig()
        try open.edit("settings-Folders.txt") { s10Append(s10Append(s10Append($0, "    AXMenu"), "      AXMenuItem label=\"Re-index\""), "      AXMenuItem label=\"Remove\"") }
        let r = try open.check("S10.3")
        person(r, "S10.3", mentions: "T5")
        #expect(!r.output.contains("W32"), "an open menu's Re-index and Remove were read as row buttons: \(r.output.suffix(400))")
    }

    @Test("S10.3 fails on each Settings fault it reads, naming the pass-list item")
    func s103Fails() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("size", ["720 x 548"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: "window 720 x 548", with: "window 720 x 520") } }),
            ("T1 height", ["T1", "28"], { try $0.edit("settings-Folders.txt") { s10Moved($0, "Search", 8, 106, 164, 30) } }),
            ("T1 gap", ["T1", "2 pt"], { try $0.edit("settings-Folders.txt") { s10Moved($0, "Indexing", 8, 144, 164, 28) } }),
            ("T2", ["T2", "title"], { try $0.edit("settings-Search.txt") { s10Without($0, containing: "AXStaticText label=\"Search\"") } }),
            ("T4", ["T4", "pop-up"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Media app", 380, 240, 200, 24) } }),
            ("T6", ["T6", "Cancel"], { try $0.edit("settings-Indexing-confirm.txt") { s10Moved($0, "Cancel", 640, 266, 80, 24) } }),
            ("T7", ["T7", "bottom"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: "  AXScrollArea", with: "  AXButton label=\"Planted\" frame=108,570,100,24\n  AXScrollArea") } }),
            ("overlap", ["overlap"], { try $0.addLine("settings-Search.txt", "AXStaticText", "Planted", 542, 99, 100, 20, depth: 2) }),
            ("outside", ["outside"], { try $0.edit("settings-Folders.txt") { s10Moved($0, "More actions for Desktop", 700, 95, 22, 22) } }),
            ("dark only", ["dark", "T4"], { try $0.put("settings-Search-dark.txt", s10Moved($0.read("settings-Search.txt"), "PDF app", 300, 200, 200, 24)) }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.3")
            #expect(r.verdict.hasPrefix("CHECK S10.3 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.3 fails on each fault of the System Settings shell the person chose (guide 16.1), naming its pass-list item: the sidebar panel exposed as a group or a text that holds the four buttons inside x 0 to 188 and ends within 20 pt of the window bottom, as the old floating panel at x 8 to 188 and as the flat full-height column at x 0 to 180 (W27, T7; the real sidebar moved, guide 18); no pane title equal to the section name, a Search field, a back button or a forward button (W29); a Re-index or Remove button outside an open menu in a section dump (W32); the Folders dump missing the title or the note (W33); a Folders row with no \"More actions for <name>\" control, or one of another role (W31); an About element in a dump, a sidebar button or a pane title (T1, guide 16.16)")
    func s103ShellFails() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("the sidebar panel exposed as a group", ["W27", "T7", "sidebar panel"], { try $0.edit("settings-Search.txt") { $0.replacingOccurrences(of: "  AXScrollArea", with: "  AXGroup label=\"Sidebar\" frame=108,58,180,532\n  AXScrollArea") } }),
            ("the sidebar panel exposed as a text", ["W27", "T7", "AXStaticText"], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: "  AXScrollArea", with: "  AXStaticText label=\"Panel\" frame=108,58,180,520\n  AXScrollArea") } }),
            ("the flat full-height column exposed as a group", ["W27", "T7", "sidebar panel", "x 0 to 188"], { try $0.edit("settings-Search.txt") { $0.replacingOccurrences(of: "  AXScrollArea", with: "  AXGroup label=\"Sidebar\" frame=100,50,180,548\n  AXScrollArea") } }),
            ("the flat full-height column exposed as a text", ["W27", "T7", "sidebar panel", "AXStaticText"], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: "  AXScrollArea", with: "  AXStaticText label=\"Column\" frame=100,50,180,548\n  AXScrollArea") } }),
            ("no pane title in the strip", ["W29", "pane title"], { try $0.edit("settings-Indexing.txt") { s10Without($0, containing: "AXStaticText label=\"Indexing\"") } }),
            ("a Search field", ["W29", "Search"], { try $0.addLine("settings-Folders.txt", "AXTextField", "Search", 560, 10, 120, 24) }),
            ("a back button", ["W29", "Back"], { try $0.addLine("settings-File_types.txt", "AXButton", "Back", 192, 10, 24, 24) }),
            ("a forward button", ["W29", "Forward"], { try $0.addLine("settings-Search.txt", "AXButton", "Forward", 220, 10, 24, 24) }),
            ("a Re-index button in Folders", ["W32", "Re-index"], { try $0.addLine("settings-Folders.txt", "AXButton", "Re-index", 560, 130, 60, 20, depth: 3) }),
            ("a Remove button in Indexing", ["W32", "Remove"], { try $0.addLine("settings-Indexing.txt", "AXButton", "Remove", 560, 130, 60, 20, depth: 2) }),
            ("the Folders title missing", ["W33", "Folders Sesame reads"], { try $0.edit("settings-Folders.txt") { s10Without($0, containing: "Folders Sesame reads") } }),
            ("the Folders note missing", ["W33", "Tick a folder to read it"], { try $0.edit("settings-Folders.txt") { s10Without($0, containing: "Tick a folder to read it") } }),
            ("a row with no more control", ["W31", "More actions for Documents"], { try $0.edit("settings-Folders.txt") { s10Without($0, containing: "More actions for Documents") } }),
            ("a more control that is a plain button", ["W31", "More actions for Desktop"], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: "AXPopUpButton label=\"More actions for Desktop\"", with: "AXButton label=\"More actions for Desktop\"") } }),
            ("a more control named for another folder", ["W31", "More actions for api-client"], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: "More actions for api-client", with: "More actions for repo") } }),
            ("an About button in Folders", ["T1", "16.16", "About"], { try $0.addLine("settings-Folders.txt", "AXCheckBox/AXToggle", "About", 8, 166, 164, 28, flags: "value=\"0\"") }),
            ("an About pane title", ["T1", "16.16", "About"], { try $0.addLine("settings-Search.txt", "AXStaticText", "About", 197, 13, 100, 20) }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.3")
            #expect(r.verdict.hasPrefix("CHECK S10.3 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
        let low = try Rig()
        try low.edit("settings-Search.txt") { $0.replacingOccurrences(of: "  AXScrollArea", with: "  AXGroup label=\"Sidebar\" frame=108,58,180,460\n  AXScrollArea") }
        let l = try low.check("S10.3")
        #expect(!l.output.contains("W27"), "a group ending far above the window bottom was read as the sidebar panel: \(l.output.suffix(400))")
        let lowColumn = try Rig()
        try lowColumn.edit("settings-Search.txt") { $0.replacingOccurrences(of: "  AXScrollArea", with: "  AXGroup label=\"Sidebar\" frame=100,50,180,460\n  AXScrollArea") }
        #expect(!(try lowColumn.check("S10.3")).output.contains("W27"), "a group at x 0 ending far above the window bottom was read as the sidebar panel")
        let wide = try Rig()
        try wide.edit("settings-Search.txt") { $0.replacingOccurrences(of: "  AXScrollArea", with: "  AXGroup label=\"Wide\" frame=100,50,720,548\n  AXScrollArea") }
        #expect(!(try wide.check("S10.3")).output.contains("W27"), "a group as wide as the window was read as the sidebar panel")
    }

    @Test("S10.3 fails the sidebar and pane numbers of the flat full-height column, the real sidebar moved (guide 18): the first sidebar button must start at x 8 within 1 and be 164 wide within 2 (W54, so the old floating panel at x 16 fails and names x 16), and the pane title equal to the section name must start at x 197 within 1 and the scroll area must start at x 181 within 1 and be 539 wide within 1 (W55, so the old title at x 204 and the old scroll area at x 188 fail); each plant fails for its own rule and the numbers at the edge pass")
    func s103FlatSidebarNumbers() throws {
        func buttons(_ text: String, x: Int, w: Int = 164) -> String {
            ["Folders", "File types", "Search", "Indexing"].enumerated().reduce(text) { s10Moved($0, $1.element, x, 46 + 30 * $1.offset, w, 28) }
        }
        let scroll = "frame=281,97,539,501"
        let fails: [(String, [String], [String], (Rig) throws -> Void)] = [
            ("W54 the four buttons at x 16, the old floating shape", ["W54", "x 16", "floating", "guide 18"], ["W55", "W27"], { try $0.edit("settings-Folders.txt") { buttons($0, x: 16) } }),
            ("W54 the four buttons at x 10", ["W54", "x 10"], ["W55"], { try $0.edit("settings-Search.txt") { buttons($0, x: 10) } }),
            ("W54 the four buttons at x 6", ["W54", "x 6"], ["W55"], { try $0.edit("settings-Indexing.txt") { buttons($0, x: 6) } }),
            ("W54 the four buttons 160 wide", ["W54", "160 pt wide"], ["W55"], { try $0.edit("settings-Folders.txt") { buttons($0, x: 8, w: 160) } }),
            ("W54 the four buttons 168 wide", ["W54", "168 pt wide"], ["W55"], { try $0.edit("settings-File_types.txt") { buttons($0, x: 8, w: 168) } }),
            ("W54 in Dark only", ["dark", "W54", "x 16"], ["W55"], { try $0.put("settings-Search-dark.txt", buttons($0.read("settings-Search.txt"), x: 16)) }),
            ("W55 the old pane title at x 204", ["W55", "197", "204"], ["W54"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Search", 204, 13, 200, 20, nth: 1) } }),
            ("W55 the pane title at x 199", ["W55", "199"], ["W54"], { try $0.edit("settings-Folders.txt") { s10Moved($0, "Folders", 199, 13, 200, 20, nth: 1) } }),
            ("W55 the pane title at x 195", ["W55", "195"], ["W54"], { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Indexing", 195, 13, 200, 20, nth: 1) } }),
            ("W55 the old scroll area at x 188", ["W55", "starts at x 188", "181"], ["W54"], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: scroll, with: "frame=288,97,532,501") } }),
            ("W55 the scroll area at x 183", ["W55", "starts at x 183"], ["W54"], { try $0.edit("settings-Search.txt") { $0.replacingOccurrences(of: scroll, with: "frame=283,97,539,501") } }),
            ("W55 the scroll area at x 179", ["W55", "starts at x 179"], ["W54"], { try $0.edit("settings-Search.txt") { $0.replacingOccurrences(of: scroll, with: "frame=279,97,539,501") } }),
            ("W55 the scroll area 532 wide at x 181", ["W55", "532 pt wide", "539"], ["W54"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: scroll, with: "frame=281,97,532,501") } }),
            ("W55 the scroll area 541 wide at x 181", ["W55", "541 pt wide"], ["W54"], { try $0.edit("settings-File_types.txt") { $0.replacingOccurrences(of: scroll, with: "frame=281,97,541,501") } }),
            ("W55 in Dark only", ["dark", "W55", "204"], ["W54"], { try $0.put("settings-Folders-dark.txt", s10Moved($0.read("settings-Folders.txt"), "Folders", 204, 13, 200, 20, nth: 1)) }),
        ]
        for (name, words, absent, mutate) in fails {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.3")
            #expect(r.verdict.hasPrefix("CHECK S10.3 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
            for a in absent { #expect(!r.output.contains(a), "\(name): the fault was read as \(a) as well: \(r.output.suffix(500))") }
        }
        let edges: [(String, (Rig) throws -> Void)] = [
            ("the four buttons at x 7, 162 wide", { try $0.edit("settings-Folders.txt") { buttons($0, x: 7, w: 162) } }),
            ("the four buttons at x 9, 166 wide", { try $0.edit("settings-Search.txt") { buttons($0, x: 9, w: 166) } }),
            ("the pane title at x 196", { try $0.edit("settings-Search.txt") { s10Moved($0, "Search", 196, 13, 200, 20, nth: 1) } }),
            ("the pane title at x 198", { try $0.edit("settings-Folders.txt") { s10Moved($0, "Folders", 198, 13, 200, 20, nth: 1) } }),
            ("the scroll area at x 180, 538 wide", { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: scroll, with: "frame=280,97,538,501") } }),
            ("the scroll area at x 182, 540 wide", { try $0.edit("settings-File_types.txt") { $0.replacingOccurrences(of: scroll, with: "frame=282,97,540,501") } }),
        ]
        for (name, mutate) in edges {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.3")
            #expect(!r.output.contains("W54") && !r.output.contains("W55"), "\(name): read as a W54 or W55 fault: \(r.output.suffix(500))")
        }
    }

    @Test("S10.3 passes the Indexing tab of layout A (guide 16.15, the person's choice) at the edge of every number it allows, with the person text T11: Delete index… 6 pt right or left of the left edge of Start indexing (W43), Start indexing 220 wide (W43), the switch ending exactly where the caption begins (W42)")
    func s103IndexingLayoutAEdgesPass() throws {
        let cases: [(String, (Rig) throws -> Void)] = [
            ("Delete index… 6 pt right of Start indexing", { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Delete index…", 217, 177, 110, 24) } }),
            ("Delete index… 6 pt left of Start indexing", { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Delete index…", 205, 177, 110, 24) } }),
            ("Start indexing 220 wide", { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Start indexing", 211, 137, 220, 24) } }),
            ("the switch touching the caption", { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Launch at login", 541, 76, 54, 24) } }),
            ("the switch off in the golden world", { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: "label=\"Launch at login\" value=\"1\"", with: "label=\"Launch at login\" value=\"0\"") } }),
        ]
        for (name, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.3")
            person(r, "S10.3", mentions: "T11", "shot-s10-3-light-indexing", "shot-s10-3-dark-indexing", "shot-s10-3-light-confirm", "Delete index... under a hairline in red text")
            #expect(!r.output.contains("W42") && !r.output.contains("W43"), "\(name): an Indexing rule fired: \(r.output.suffix(500))")
        }
    }

    @Test("S10.3 fails on each fault of the Indexing tab of layout A, naming its pass-list item: no AXCheckBox/AXSwitch labelled Launch at login with a frame, a plain AXCheckBox of that label (W42); Launch at login not above Start indexing, Start indexing not above Delete index… (W42, W43); the left edges of Start indexing and Delete index… more than 6 pt apart, Start indexing wider than 220 pt or at card width, Delete index… with no frame (W43); the switch overlapping the caption (W42), in Light and in Dark")
    func s103IndexingLayoutAFails() throws {
        let switchLine = "AXCheckBox/AXSwitch label=\"Launch at login\""
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("no switch", ["W42", "AXCheckBox/AXSwitch", "Launch at login"], { try $0.edit("settings-Indexing.txt") { s10Without($0, containing: "label=\"Launch at login\"") } }),
            ("a plain AXCheckBox", ["W42", "plain AXCheckBox", "system switch by decision", "guide 16.15"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: switchLine, with: "AXCheckBox label=\"Launch at login\"") } }),
            ("a plain AXCheckBox beside the switch", ["W42", "plain AXCheckBox"], { try $0.addLine("settings-Indexing.txt", "AXCheckBox", "Launch at login", 300, 76, 40, 24, flags: "value=\"1\"", depth: 2) }),
            ("a switch with no frame", ["W42", "with a frame"], { try $0.edit("settings-Indexing.txt") { s10Unframed($0, "label=\"Launch at login\"") } }),
            ("Launch at login below Start indexing", ["W42", "W43", "Launch at login", "not above"], { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Launch at login", 636, 150, 54, 24) } }),
            ("Start indexing below Delete index…", ["W43", "Start indexing", "Delete index…", "not above"], { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Delete index…", 211, 112, 110, 24) } }),
            ("Delete index… 7 pt right of Start indexing", ["W43", "7 pt", "left edge"], { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Delete index…", 218, 177, 110, 24) } }),
            ("Delete index… 7 pt left of Start indexing", ["W43", "7 pt", "left edge"], { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Delete index…", 204, 177, 110, 24) } }),
            ("Start indexing 221 wide", ["W43", "221 pt wide", "220"], { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Start indexing", 211, 137, 221, 24) } }),
            ("Start indexing planted at card width", ["W43", "507 pt wide", "never the card width"], { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Start indexing", 197, 137, 507, 24) } }),
            ("Delete index… with no frame", ["W43", "Delete index…", "no frame"], { try $0.edit("settings-Indexing.txt") { s10Unframed($0, "label=\"Delete index…\"") } }),
            ("the switch over the caption", ["W42", "overlaps", "caption"], { try $0.edit("settings-Indexing.txt") { s10Moved($0, "Launch at login", 400, 76, 54, 24) } }),
            ("no switch in Dark only", ["dark", "W42"], { try $0.put("settings-Indexing-dark.txt", s10Without($0.read("settings-Indexing.txt"), containing: "label=\"Launch at login\"")) }),
            ("Start indexing at card width in Dark only", ["dark", "W43", "507 pt wide"], { try $0.put("settings-Indexing-dark.txt", s10Moved($0.read("settings-Indexing.txt"), "Start indexing", 197, 137, 507, 24)) }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.3")
            #expect(r.verdict.hasPrefix("CHECK S10.3 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.3 reads the Indexing rules (W42, W43) in the Indexing section only: a plain Launch at login checkbox, a wide Start indexing and a missing Delete index… placed in the Folders, File types or Search dump are not read as W42 or W43, and the S10.3 plant over the Indexing world still fails")
    func s103IndexingRulesStayInIndexing() throws {
        let rig = try Rig()
        for name in ["settings-Folders.txt", "settings-File_types.txt", "settings-Search.txt"] {
            try rig.addLine(name, "AXCheckBox", "Launch at login", 300, 400, 40, 20, flags: "value=\"1\"", depth: 2)
            try rig.addLine(name, "AXButton", "Start indexing", 300, 430, 400, 24, depth: 2)
        }
        let r = try rig.check("S10.3")
        #expect(!r.output.contains("W42") && !r.output.contains("W43"), "an Indexing rule fired on another section: \(r.output.suffix(500))")
        let planted = try Rig()
        let p = try planted.check("S10.3", plant: true)
        #expect(p.verdict.hasPrefix("CHECK S10.3 FAIL planted") && p.rc == 1, "S10.3 --plant over the layout A world: rc \(p.rc), \(p.verdict)")
    }

    @Test("S10.3 passes the Search shortcut row of layout A (guide 16.14, the person's choice) at the edge of every number it allows: a keycaps group 22 and 30 tall, 6 and 20 pt left of Record, 4 pt off its vertical centre, Back to default whose top is at Record's bottom (W38, W39, W40), and the person text carries T10")
    func s103SearchShortcutRowEdgesPass() throws {
        let cases: [(String, (Rig) throws -> Void)] = [
            ("the group 30 tall", { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 412, 94, 116, 30) } }),
            ("the group 22 tall", { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 412, 98, 116, 22) } }),
            ("the group 6 pt left of Record", { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 418, 96, 116, 26) } }),
            ("the group 20 pt left of Record", { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 404, 96, 116, 26) } }),
            ("the group 4 pt off the centre of Record", { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 412, 100, 116, 26) } }),
            ("Back to default with its top at the bottom of Record", { try $0.edit("settings-Search.txt") { s10Moved($0, "Back to default", 208, 121, 100, 16) } }),
        ]
        for (name, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.3")
            person(r, "S10.3", mentions: "T10", "shot-s10-3-light-search", "Back to default")
            #expect(!r.output.contains("W38") && !r.output.contains("W39") && !r.output.contains("W40"), "\(name): a Search shortcut rule fired: \(r.output.suffix(500))")
        }
    }

    @Test("S10.3 fails on each fault of the Search shortcut row of layout A, naming its pass-list item: no AXGroup labelled \"Control Option Space\" with a frame, the shortcut as a static text or a text field, an element labelled \"Keyboard shortcut\", a child inside the group, a group taller than 30 or shorter than 22 (W39); a group whose right edge is not 6 to 20 pt left of Record, one not centred within 4 pt of Record, one over Record (W38); Back to default not below Record and left of it, or over it (W40), in Light and in Dark")
    func s103SearchShortcutRowFails() throws {
        let group = "AXGroup label=\"Control Option Space\""
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("no group", ["W39", "AXGroup labelled"], { try $0.edit("settings-Search.txt") { s10Without($0, containing: group) } }),
            ("the shortcut as a static text", ["W39", "AXStaticText"], { try $0.edit("settings-Search.txt") { $0.replacingOccurrences(of: group, with: "AXStaticText label=\"Control Option Space\"") } }),
            ("the shortcut as a text field", ["W39", "AXTextField"], { try $0.edit("settings-Search.txt") { $0.replacingOccurrences(of: group, with: "AXTextField label=\"Control Option Space\"") } }),
            ("an element labelled Keyboard shortcut", ["W39", "Keyboard shortcut"], { try $0.addLine("settings-Search.txt", "AXStaticText", "Keyboard shortcut", 300, 300, 100, 16, depth: 2) }),
            ("a child inside the group", ["W39", "children"], { try $0.edit("settings-Search.txt") { s10InsertAfter($0, containing: group, "      AXStaticText label=\"Space\" frame=520,150,40,18") } }),
            ("a group 40 tall", ["W39", "40 pt tall"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 412, 90, 116, 40) } }),
            ("a group 18 tall", ["W39", "18 pt tall"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 412, 100, 116, 18) } }),
            ("a group 4 pt left of Record", ["W38", "4 pt left"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 420, 96, 116, 26) } }),
            ("a group 44 pt left of Record", ["W38", "44 pt left"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 380, 96, 116, 26) } }),
            ("a group not centred with Record", ["W38", "centred"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 412, 110, 116, 26) } }),
            ("the group planted over the Record button", ["W38", "overlaps", "Record new shortcut"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Control Option Space", 545, 96, 116, 26) } }),
            ("Back to default above Record", ["W40", "below"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Back to default", 208, 80, 100, 16) } }),
            ("Back to default with its top 1 pt above the bottom of Record", ["W40", "below"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Back to default", 208, 120, 100, 16) } }),
            ("Back to default right of Record", ["W40", "left of it"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Back to default", 600, 142, 100, 16) } }),
            ("Back to default over Record", ["W40", "overlaps"], { try $0.edit("settings-Search.txt") { s10Moved($0, "Back to default", 560, 110, 100, 16) } }),
            ("no group in Dark only", ["dark", "W39"], { try $0.put("settings-Search-dark.txt", s10Without($0.read("settings-Search.txt"), containing: group)) }),
            ("Back to default over Record in Dark only", ["dark", "W40"], { try $0.put("settings-Search-dark.txt", s10Moved($0.read("settings-Search.txt"), "Back to default", 560, 110, 100, 16)) }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.3")
            #expect(r.verdict.hasPrefix("CHECK S10.3 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.3 reads the Search shortcut rules in the Search section only: the same keycaps group, text or Back to default faults placed in the Folders dump are not read as W38, W39 or W40")
    func s103SearchShortcutRulesStayInSearch() throws {
        let rig = try Rig()
        try rig.addLine("settings-Folders.txt", "AXStaticText", "Keyboard shortcut", 300, 300, 100, 16, depth: 2)
        try rig.addLine("settings-Folders.txt", "AXTextField", "Control Option Space", 300, 330, 100, 16, depth: 2)
        let r = try rig.check("S10.3")
        #expect(!r.output.contains("W38") && !r.output.contains("W39") && !r.output.contains("W40"), "a Search shortcut rule fired on the Folders dump: \(r.output.suffix(500))")
    }

    @Test("S10.3 is exit 4 when a section never opens, the confirm never shows Cancel, the dumps hold no frames or the state fails")
    func s103Reruns() throws {
        let confirm = try Rig()
        confirm.remove("settings-Indexing-confirm.txt")
        rerun(try confirm.check("S10.3"), "S10.3")
        let frames = try Rig()
        try frames.put("settings-Folders.txt", s10SettingsDump("Folders", old: true, long: false, root: frames.kit))
        rerun(try frames.check("S10.3"), "S10.3")
        let state = try Rig()
        rerun(try state.check("S10.3", pre: "GOLDEN_RC=4"), "S10.3")
        let open = try Rig()
        rerun(try open.check("S10.3", pre: "SETTINGS_RC=1"), "S10.3")
    }

    @Test("S10.4 reads the menu dump text of the tidy menu the person chose (guide 14.1): the status line first with its header group, a Pause, Resume or Retry item before Open Sesame exactly when the header names Indexing, Paused by you or stalled, or a failed download, then Open Sesame, Settings… and Quit Sesame last; the icon picture and the text beside the status icon (W21) are the person's")
    func s104() throws {
        let ok = try Rig()
        person(try ok.check("S10.4"), "S10.4", mentions: "icon", "W21", "no text")
        let order = try Rig()
        try order.edit("menu.txt") { $0.replacingOccurrences(of: "  AXMenuItem label=\"Quit Sesame\"", with: "  AXMenuItem label=\"Quit Sesame\"\n  AXMenuItem label=\"Settings…\"") }
        fail(try order.check("S10.4"), "S10.4", mentions: "Settings…")
        let quit = try Rig()
        try quit.edit("menu.txt") { s10Without($0, containing: "Quit Sesame") }
        fail(try quit.check("S10.4"), "S10.4", mentions: "Quit Sesame")
        let status = try Rig()
        try status.edit("menu.txt") { s10Without($0, containing: "label=\"Ready\"") }
        fail(try status.check("S10.4"), "S10.4", mentions: "status")
        let pause = try Rig()
        try pause.put("menu.txt", s10MenuDump(old: false, state: "indexing"))
        try pause.edit("menu.txt") { s10Without($0, containing: "Pause indexing") }
        fail(try pause.check("S10.4"), "S10.4", mentions: "Pause", "W19")
        let gone = try Rig()
        gone.remove("menu.txt")
        rerun(try gone.check("S10.4"), "S10.4")
        let state = try Rig()
        rerun(try state.check("S10.4", pre: "GOLDEN_RC=4"), "S10.4")
    }

    @Test("S10.4 passes the tidy menu of every state: no action item in Ready, Ready before Start and Downloading, Pause while Indexing, Resume when Paused by you or stalled, Retry when the download failed, Resume anyway on battery, no action when the Mac is busy or in Low Power Mode, the header group labelled with the state word", arguments: s10MenuStateNames)
    func s104PassesEveryState(state: String) throws {
        let rig = try Rig()
        try rig.put("menu.txt", s10MenuDump(old: false, state: state))
        #expect(!rig.read("menu.txt").contains("Last indexed"), "the new menu world of \(state) still holds a Last indexed row, which the person removed (guide 19)")
        person(try rig.check("S10.4"), "S10.4", mentions: "icon", "W21")
    }

    @Test("S10.4 still passes when a Paused by you menu also offers Resume anyway: only the named states require an action and only Ready and Downloading forbid one")
    func s104OptionalActionsPass() throws {
        let both = try Rig()
        try both.put("menu.txt", s10MenuDump(old: false, state: "pausedbyyou").replacingOccurrences(of: "  AXMenuItem label=\"Resume indexing\"", with: "  AXMenuItem label=\"Resume anyway, on battery\" frame=800,48,260,22\n  AXMenuItem label=\"Resume indexing\""))
        person(try both.check("S10.4"), "S10.4", mentions: "icon")
    }

    @Test("S10.4 fails when the menu is not the tidy one the person chose: a [disabled] Pause, Resume or Retry (W19), an action item in a Ready or Downloading menu (W19), a state that needs an action and has none or has it after Open Sesame (W19), the header group missing, with a label of another state, with a trailing comma, with no label, as another role or with children (W18), Nothing indexed yet or an empty-titled item that is not a separator (W19), a Last indexed item of any state, enabled or not, with or without a file name, in any letters (W60, guide 19), two separators in a row, one first or one last (W20)")
    func s104Fails() throws {
        func disable(_ text: String, _ label: String) -> String { text.replacingOccurrences(of: "label=\"\(label)\" frame", with: "label=\"\(label)\" [disabled] frame") }
        func beforeOpen(_ text: String, _ line: String) -> String { text.replacingOccurrences(of: "  AXMenuItem label=\"Open Sesame\"", with: "\(line)\n  AXMenuItem label=\"Open Sesame\"") }
        func action(_ label: String) -> String { "  AXMenuItem label=\"\(label)\" frame=800,0,260,22" }
        let cases: [(String, String, (String) -> String, [String])] = [
            ("a disabled Pause while Indexing", "indexing", { disable($0, "Pause indexing") }, ["W19", "Pause indexing", "disabled"]),
            ("a disabled Resume when Paused by you", "pausedbyyou", { disable($0, "Resume indexing") }, ["W19", "Resume indexing", "disabled"]),
            ("a disabled Resume when stalled", "stalled", { disable($0, "Resume indexing") }, ["W19", "Resume indexing", "disabled"]),
            ("a disabled Retry when the download failed", "failed", { disable($0, "Retry model download") }, ["W19", "Retry model download", "disabled"]),
            ("a disabled Resume anyway on battery", "battery", { disable($0, "Resume anyway, on battery") }, ["W19", "Resume anyway", "disabled"]),
            ("a Pause item in a Ready menu", "ready", { beforeOpen($0, action("Pause indexing")) }, ["W19", "Pause indexing", "Ready"]),
            ("a Resume item in a Ready menu", "ready", { beforeOpen($0, action("Resume indexing")) }, ["W19", "Resume indexing", "Ready"]),
            ("a Retry item in a Ready menu", "ready", { beforeOpen($0, action("Retry model download")) }, ["W19", "Retry model download", "Ready"]),
            ("a Pause item in a Ready before Start menu", "notstarted", { beforeOpen($0, action("Pause indexing")) }, ["W19", "Pause indexing"]),
            ("a Pause item in a Downloading menu", "downloading", { beforeOpen($0, action("Pause indexing")) }, ["W19", "Pause indexing", "Downloading"]),
            ("a Retry item in a Downloading menu", "downloading", { beforeOpen($0, action("Retry model download")) }, ["W19", "Retry model download", "Downloading"]),
            ("Indexing with no Pause", "indexing", { s10Without($0, containing: "Pause indexing") }, ["W19", "Indexing 62%", "Pause"]),
            ("Paused by you with no Resume", "pausedbyyou", { s10Without($0, containing: "Resume indexing") }, ["W19", "Paused by you", "Resume"]),
            ("stalled with no Resume", "stalled", { s10Without($0, containing: "Resume indexing") }, ["W19", "Paused", "Resume"]),
            ("a failed download with no Retry", "failed", { s10Without($0, containing: "Retry model download") }, ["W19", "Model download failed", "Retry"]),
            ("Pause only after Open Sesame", "indexing", { s10Without($0, containing: "Pause indexing").replacingOccurrences(of: "  AXMenuItem label=\"Settings…\"", with: "\(action("Pause indexing"))\n  AXMenuItem label=\"Settings…\"") }, ["W19", "before Open Sesame"]),
            ("the header group missing", "ready", { s10Without($0, containing: "AXGroup") }, ["W18", "AXGroup"]),
            ("the header group with the label of another state", "ready", { $0.replacingOccurrences(of: "AXGroup label=\"Ready\"", with: "AXGroup label=\"Paused, By you\"") }, ["W18", "state word"]),
            ("the header group of an Indexing menu saying Ready", "indexing", { $0.replacingOccurrences(of: "AXGroup label=\"Indexing 62%, 4,520 files left \u{00B7} about 12 min left\"", with: "AXGroup label=\"Ready\"") }, ["W18", "state word"]),
            ("the header group label with a trailing comma", "ready", { $0.replacingOccurrences(of: "AXGroup label=\"Ready\"", with: "AXGroup label=\"Ready,\"") }, ["W18", "Ready,"]),
            ("the header group with no label", "ready", { $0.replacingOccurrences(of: "AXGroup label=\"Ready\"", with: "AXGroup") }, ["W18", "no label"]),
            ("the header text as a static text, not a group", "indexing", { $0.replacingOccurrences(of: "AXGroup label=", with: "AXStaticText label=") }, ["W18", "AXGroup"]),
            ("the header group holding the title as a child", "ready", { $0.replacingOccurrences(of: "    AXGroup label=\"Ready\" frame=800,0,260,40", with: "    AXGroup label=\"Ready\" frame=800,0,260,40\n      AXStaticText label=\"Ready\" frame=830,8,200,16") }, ["W18", "child"]),
            ("Nothing indexed yet", "ready", { beforeOpen($0, "  AXMenuItem label=\"Nothing indexed yet\" [disabled] frame=800,0,260,22") }, ["W19", "Nothing indexed yet"]),
            ("a Last indexed item in a Ready menu", "ready", { beforeOpen($0, "  AXMenuItem label=\"Last indexed: annual-report-60p.pdf\" [disabled] frame=800,0,260,22") }, ["W60", "Last indexed: annual-report-60p.pdf", "guide 19"]),
            ("a Last indexed item in an Indexing menu", "indexing", { beforeOpen($0, "  AXMenuItem label=\"Last indexed: annual-report-60p.pdf\" [disabled] frame=800,0,260,22") }, ["W60", "Last indexed", "guide 19"]),
            ("a Last indexed item in a Paused by you menu", "pausedbyyou", { beforeOpen($0, "  AXMenuItem label=\"Last indexed: annual-report-60p.pdf\" [disabled] frame=800,0,260,22") }, ["W60", "Last indexed", "guide 19"]),
            ("a Last indexed item that is enabled", "ready", { beforeOpen($0, "  AXMenuItem label=\"Last indexed: annual-report-60p.pdf\" frame=800,0,260,22") }, ["W60", "Last indexed", "guide 19"]),
            ("a Last indexed item with no file name", "ready", { beforeOpen($0, "  AXMenuItem label=\"Last indexed\" [disabled] frame=800,0,260,22") }, ["W60", "Last indexed", "guide 19"]),
            ("a last indexed item in other letters", "ready", { beforeOpen($0, "  AXMenuItem label=\"LAST INDEXED: a.pdf\" [disabled] frame=800,0,260,22") }, ["W60", "LAST INDEXED", "guide 19"]),
            ("an empty-titled item that is not a separator", "ready", { beforeOpen($0, "  AXMenuItem frame=800,0,260,22") }, ["W19", "empty title"]),
            ("two separators in a row", "ready", { beforeOpen($0, "  AXMenuItem [disabled] frame=800,0,260,8") }, ["W20", "two separators"]),
            ("a separator first", "ready", { $0.replacingOccurrences(of: "AXMenu frame=800,0,260,300\n", with: "AXMenu frame=800,0,260,300\n  AXMenuItem [disabled] frame=800,0,260,8\n") }, ["W20", "starts"]),
            ("a separator last", "ready", { s10Append($0, "  AXMenuItem [disabled] frame=800,0,260,8") }, ["W20", "ends"]),
        ]
        for (name, state, mutate, words) in cases {
            let rig = try Rig()
            try rig.put("menu.txt", mutate(s10MenuDump(old: false, state: state)))
            let r = try rig.check("S10.4")
            #expect(r.verdict.hasPrefix("CHECK S10.4 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.4 keeps its plant: with --plant the menu with Quit Sesame taken out fails, in a Ready and in an Indexing menu", arguments: ["ready", "indexing"])
    func s104KeepsItsPlant(state: String) throws {
        let rig = try Rig()
        try rig.put("menu.txt", s10MenuDump(old: false, state: state))
        let r = try rig.check("S10.4", plant: true)
        #expect(r.verdict.hasPrefix("CHECK S10.4 FAIL planted") && r.rc == 1, "S10.4 --plant on \(state): rc \(r.rc), \(r.verdict)")
        #expect(r.verdict.contains("Quit Sesame"), "the planted FAIL line does not name Quit Sesame: \(r.verdict)")
    }

    @Test("S10.5 passes when no dump of Setup (four steps), the panel, Settings (four sections) or the menu has an AXSwitch role except the five File types kinds, which the person chose as system switches (guide 16.12), and the positive controls hold, and reads all ten dumps")
    func s105Pass() throws {
        let rig = try Rig()
        let r = try rig.check("S10.5")
        pass(r, "S10.5")
        #expect(r.verdict.contains("four sections") && r.verdict.contains("five File types kinds") && r.verdict.contains("Launch at login") && r.verdict.contains("Indexing dump"), "the done text is \(r.verdict)")
        #expect(rig.read("settings-Indexing.txt").contains("AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\""), "the control Indexing world does not hold Launch at login as AXCheckBox/AXSwitch with value 1")
        let ax = rig.log("ax.log")
        #expect(ax.filter { $0 == "dump setup" }.count >= 4 && ax.contains("dump panel") && ax.contains("dump menu") && ax.filter { $0 == "dump settings" }.count >= 4, "the dumps read were \(ax.filter { $0.hasPrefix("dump") })")
        #expect(!ax.contains("click About"), "About was pressed: \(ax.filter { $0.hasPrefix("click") })")
        #expect(rig.read("settings-File_types.txt").components(separatedBy: "\n").filter { $0.contains("AXCheckBox/AXSwitch label=") }.count == 5, "the control File types world does not hold five AXCheckBox/AXSwitch kinds")
    }

    @Test("S10.5 fails on a switch role in any dump, naming it", arguments: ["setup-1.txt", "setup-2.txt", "setup-3.txt", "setup-4.txt", "settings-Folders.txt", "settings-File_types.txt", "settings-Search.txt", "settings-Indexing.txt", "panel-empty.txt", "menu.txt"])
    func s105Fails(file: String) throws {
        let rig = try Rig()
        try rig.edit(file) { s10Append($0, "  AXCheckBox/AXSwitch label=\"Planted switch\" value=\"1\"") }
        fail(try rig.check("S10.5"), "S10.5", mentions: "AXSwitch", "Planted switch")
    }

    @Test("S10.5 allows an AXCheckBox/AXSwitch in the File types dump only and only for Photos, PDFs, Documents, Audio and Video, each once with value 1 or 0: a sixth switch (Code), a repeated kind, a kind with another value or none, a kind switch in another dump and a kind in the Setup dump each fail, naming the label; a kind drawn as a plain AXCheckBox fails naming the decision (Launch at login is a system switch in the Indexing dump by decision, guide 16.15, and has its own test)")
    func s105FileTypesSwitches() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("a sixth switch", ["AXSwitch", "Code"], { try $0.edit("settings-File_types.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Code\" value=\"1\"") } }),
            ("a repeated kind", ["AXSwitch", "PDFs"], { try $0.edit("settings-File_types.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"PDFs\" value=\"0\"") } }),
            ("a kind with a value that is not 1 or 0", ["AXSwitch", "Audio"], { try $0.edit("settings-File_types.txt") { $0.replacingOccurrences(of: "label=\"Audio\" value=\"1\"", with: "label=\"Audio\" value=\"2\"") } }),
            ("a kind with no value", ["AXSwitch", "Video"], { try $0.edit("settings-File_types.txt") { $0.replacingOccurrences(of: "label=\"Video\" value=\"1\"", with: "label=\"Video\"") } }),
            ("a kind switch in the Folders dump", ["AXSwitch", "Photos"], { try $0.edit("settings-Folders.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Photos\" value=\"1\"") } }),
            ("a kind switch in the Setup Folders dump", ["AXSwitch", "Photos"], { try $0.edit("setup-2.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Photos\" value=\"1\"") } }),
            ("a kind drawn as a plain AXCheckBox", ["system switches by decision", "guide 16.12", "PDFs"], { try $0.edit("settings-File_types.txt") { $0.replacingOccurrences(of: "AXCheckBox/AXSwitch label=\"PDFs\"", with: "AXCheckBox label=\"PDFs\"") } }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.5")
            #expect(r.verdict.hasPrefix("CHECK S10.5 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.5 allows an AXCheckBox/AXSwitch in the Indexing dump too, because Launch at login is a system switch by decision (guide 16.15, reversing the plain-checkbox clause of task 25), and only for the single label Launch at login with value 1 or 0: a second switch of that label, a switch of another label (a File types kind among them), one with value 2 or none, Launch at login drawn as a switch in any other dump, and Launch at login left as a plain AXCheckBox in the Indexing dump each fail, the plain one naming the decision; the File types switches and the Folders positive controls stay as task 25 left them")
    func s105LaunchAtLoginSwitchInIndexing() throws {
        let switchLine = "AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\""
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("a second Launch at login switch", ["AXSwitch", "Launch at login"], { try $0.edit("settings-Indexing.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\" frame=700,400,54,24") } }),
            ("a switch of another label", ["AXSwitch", "Planted switch"], { try $0.edit("settings-Indexing.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Planted switch\" value=\"1\" frame=700,400,54,24") } }),
            ("a File types kind switch", ["AXSwitch", "Audio"], { try $0.edit("settings-Indexing.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Audio\" value=\"1\" frame=700,400,54,24") } }),
            ("Launch at login with value 2", ["AXSwitch", "Launch at login"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: switchLine, with: "AXCheckBox/AXSwitch label=\"Launch at login\" value=\"2\"") } }),
            ("Launch at login with no value", ["AXSwitch", "Launch at login"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: switchLine, with: "AXCheckBox/AXSwitch label=\"Launch at login\"") } }),
            ("Launch at login as a switch in the Folders dump", ["AXSwitch", "Launch at login"], { try $0.edit("settings-Folders.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\"") } }),
            ("Launch at login as a switch in the File types dump", ["AXSwitch", "Launch at login"], { try $0.edit("settings-File_types.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\"") } }),
            ("Launch at login as a switch in the Search dump", ["AXSwitch", "Launch at login"], { try $0.edit("settings-Search.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\"") } }),
            ("Launch at login as a switch in the Setup Folders dump", ["AXSwitch", "Launch at login"], { try $0.edit("setup-2.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\"") } }),
            ("Launch at login as a switch in the menu dump", ["AXSwitch", "Launch at login"], { try $0.edit("menu.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\"") } }),
            ("Launch at login left as a plain AXCheckBox", ["Launch at login", "system switch by decision", "guide 16.15"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: "AXCheckBox/AXSwitch label=\"Launch at login\"", with: "AXCheckBox label=\"Launch at login\"") } }),
            ("a plain AXCheckBox beside the switch", ["Launch at login", "system switch by decision", "guide 16.15"], { try $0.edit("settings-Indexing.txt") { s10Append($0, "  AXCheckBox label=\"Launch at login\" value=\"1\" frame=700,400,54,24") } }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.5")
            #expect(r.verdict.hasPrefix("CHECK S10.5 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
        let off = try Rig()
        try off.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: switchLine, with: "AXCheckBox/AXSwitch label=\"Launch at login\" value=\"0\"") }
        pass(try off.check("S10.5"), "S10.5")
    }

    @Test("S10.5 keeps its plant over the layout A world: the Indexing world holds the allowed Launch at login switch and passes without --plant, and with --plant the switch planted in every dump fails and the FAIL line says planted")
    func s105PlantStillFailsWithTheAllowedLoginSwitch() throws {
        let clean = try Rig()
        pass(try clean.check("S10.5"), "S10.5")
        let planted = try Rig()
        let r = try planted.check("S10.5", plant: true)
        #expect(r.verdict.hasPrefix("CHECK S10.5 FAIL planted") && r.rc == 1, "S10.5 --plant: rc \(r.rc), \(r.verdict)")
    }

    @Test("S10.5 is exit 4, never a FAIL, for a File types kind that is missing from the dump, and a dump with all five kinds as switches is read unchanged by S9.2 and the recipes (the sidebar toggles left out, as the S9 worlds have them): ax_switch reads the switch's on or off, S9.2's File types section lists exactly the five labels, the S9 code-wording reader finds nothing in the two new Folders texts, and settings_section finds the section by PDFs")
    func s105MissingKindAndReaders() throws {
        let rig = try Rig()
        try rig.edit("settings-File_types.txt") { s10Without($0, containing: "label=\"Audio\"") }
        rerun(try rig.check("S10.5"), "S10.5")
        let pass = try Rig()
        let kinds = pass.fake + "/settings-File_types.txt"
        let folders = pass.fake + "/settings-Folders.txt"
        let r = try pass.run("""
        S6_DUMP="$(grep -v AXToggle "\(kinds)")"; S6_WHY=""
        s9_section_2 "File types"
        echo "S92 why=[$S6_WHY]"
        printf '%s\\n' "$S6_DUMP" | ax_switch "PDFs" | sed 's/^/pdfs /'
        printf '%s\\n' "$S6_DUMP" | settings_section_has "File types" && echo "marker yes"
        printf '%s\\n' "$S6_DUMP" | settings_section_has "Folders" || echo "folders marker no"
        S6_DUMP="$(cat "\(folders)")"
        printf '%s\\n' "$S6_DUMP" | s9_code_hits | sed 's/^/code hit /'
        echo "end"
        """)
        let out = KC.lines(r.output)
        #expect(out.contains("S92 why=[]"), "S9.2 did not accept the five switches: \(r.output.suffix(500))")
        #expect(out.contains("pdfs on") && out.contains("marker yes") && out.contains("folders marker no"), "the readers did not read the switch dump: \(r.output.suffix(500))")
        #expect(!out.contains { $0.hasPrefix("code hit") } && out.contains("end"), "S9.2's code-wording reader hit the new Folders dump: \(r.output.suffix(500))")
    }

    @Test("S10.5 is exit 4 when a positive control does not hold: no checkbox on the Folders step, none in the Folders section, no File types kind as a switch, Launch at login absent, or a dump unreadable")
    func s105Reruns() throws {
        let setup = try Rig()
        try setup.edit("setup-2.txt") { s10Without($0, containing: "AXCheckBox") }
        rerun(try setup.check("S10.5"), "S10.5")
        let kinds = try Rig()
        try kinds.edit("settings-File_types.txt") { s10Without($0, containing: "AXCheckBox") }
        rerun(try kinds.check("S10.5"), "S10.5")
        let login = try Rig()
        try login.edit("settings-Indexing.txt") { s10Without($0, containing: "Launch at login") }
        rerun(try login.check("S10.5"), "S10.5")
        let folders = try Rig()
        try folders.edit("settings-Folders.txt") { s10Without($0, containing: "AXCheckBox") }
        rerun(try folders.check("S10.5"), "S10.5")
        let gone = try Rig()
        gone.remove("setup-3.txt")
        rerun(try gone.check("S10.5"), "S10.5")
    }

    @Test("S10.6 waits for each of the four combinations of Increase Contrast and Reduce Transparency, shoots the panel and Settings in both looks for each, and is NEEDS-A-PERSON for the 4.5 to 1 contrast")
    func s106Pass() throws {
        let rig = try Rig()
        let r = try rig.check("S10.6")
        person(r, "S10.6", mentions: "4.5")
        let shots = rig.log("ax.log").filter { $0.hasPrefix("shot s10-6-") }
        #expect(shots.count == 16, "the shots were \(shots)")
        for combo in ["00", "10", "01", "11"] {
            #expect(shots.contains { $0.hasPrefix("shot s10-6-\(combo)-light") } && shots.contains { $0.hasPrefix("shot s10-6-\(combo)-dark") }, "no shot for combination \(combo): \(shots)")
        }
    }

    @Test("S10.6 fails when an element is lost under a setting, and is NEEDS-A-PERSON naming Increase Contrast when the person has not flipped it")
    func s106LostAndWaiting() throws {
        let lost = try Rig()
        try lost.edit("panel-a_dog_on_the_beach.txt") { $0 }
        let base = lost.read("panel-a_dog_on_the_beach.txt")
        try lost.put("panel-a_dog_on_the_beach-d4.txt", s10Without(base, containing: "label=\"photos\""))
        fail(try lost.check("S10.6"), "S10.6", mentions: "lost", "photos")
        let waiting = try Rig()
        let r = try waiting.check("S10.6", env: ["UA_FIXED": "0 0"])
        person(r, "S10.6", mentions: "Increase Contrast", "Reduce Transparency")
        let state = try Rig()
        rerun(try state.check("S10.6", pre: "GOLDEN_RC=4"), "S10.6")
    }

    @Test("S10.7 plants a 120-character folder and file name, reads the four places (Setup Folders row, Settings Folders row, panel row, preview) and passes when no frames overlap or leave their parent and each shows the ellipsis")
    func s107Pass() throws {
        let rig = try Rig(long: true)
        for (name, dump) in [("setup-2.txt", rig.read("setup-2.txt")), ("settings-Folders.txt", rig.read("settings-Folders.txt")), ("panel-zqlongfile.txt", rig.read("panel-zqlongfile.txt"))] {
            try rig.put(name, dump.replacingOccurrences(of: "label=\"\(s10LongFolder)\"", with: "label=\"\(s10LongFolder.prefix(40))…\"")
                .replacingOccurrences(of: "label=\"\(s10LongFile).jpg\"", with: "label=\"\(s10LongFile.prefix(40))….jpg…\"")
                .replacingOccurrences(of: "label=\"\(s10LongFile).jpg \"", with: "label=\"\(s10LongFile.prefix(60))…\"")
                .replacingOccurrences(of: "label=\"~/fixtures/long-names/\(s10LongFolder)/\(s10LongFile).jpg\"", with: "label=\"~/fixtures/long-names/…/\(s10LongFile.prefix(20))…\""))
        }
        let r = try rig.check("S10.7")
        pass(r, "S10.7")
        let dir = rig.kit + "/fixtures/long-names"
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        #expect(kids.contains { $0.count == 120 && $0.hasPrefix("zqlongfolder") }, "no 120-character folder in \(kids)")
        let files = kids.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: dir + "/" + $0)) ?? [] }
        #expect(files.contains { $0.hasPrefix("zqlongfile") && $0.count >= 120 }, "no long file name in \(files)")
        #expect(rig.log("pick.log").contains { $0.contains("zqlongfolder") }, "the planted folder was not picked: \(rig.log("pick.log"))")
        #expect(rig.log("search.log").contains { $0.hasPrefix("zqlongfile") }, "the planted file was not searched: \(rig.log("search.log"))")
    }

    @Test("S10.7 is NEEDS-A-PERSON for each place where no dumped value ends in the ellipsis, naming the place")
    func s107Ellipsis() throws {
        let rig = try Rig(long: true)
        let r = try rig.check("S10.7")
        person(r, "S10.7", mentions: "ellipsis", "Setup", "Settings", "panel row", "preview")
        let some = try Rig(long: true)
        try some.edit("setup-2.txt") { $0.replacingOccurrences(of: "label=\"\(s10LongFolder)\"", with: "label=\"\(s10LongFolder.prefix(40))…\"") }
        let s = try some.check("S10.7")
        person(s, "S10.7", mentions: "Settings", "panel row")
        #expect(!s.verdict.contains("Setup Folders row"), "Setup was listed though its value ends in the ellipsis: \(s.verdict)")
    }

    @Test("S10.7 fails on an overlap or an element outside its parent in each of the four places, naming the place")
    func s107Fails() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("Setup overlap", ["overlap", "Setup"], { try $0.addLine("setup-2.txt", "AXStaticText", "Planted over the long row", 300, 286, 90, 16, depth: 3) }),
            ("Settings overlap, the more button on the name", ["overlap", "Settings"], { try $0.edit("settings-Folders.txt") { s10Moved($0, "More actions for \(s10LongFolder)", 400, 230, 22, 22) } }),
            ("panel overlap", ["overlap", "panel"], { try $0.edit("panel-zqlongfile.txt") { s10Moved($0, "long-names", 150, 66, 100, 16) } }),
            ("Settings outside, the more button past the card", ["outside", "Settings"], { try $0.edit("settings-Folders.txt") { s10Moved($0, "More actions for \(s10LongFolder)", 700, 230, 22, 22) } }),
            ("preview outside", ["outside", "panel"], { try $0.edit("panel-zqlongfile.txt") { s10Moved($0, "Photo · 1.2 MB · Jan 2", 900, 378, 300, 16) } }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig(long: true)
            try mutate(rig)
            let r = try rig.check("S10.7")
            #expect(r.verdict.hasPrefix("CHECK S10.7 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.7 reads the Settings Folders long-name row of layout B through s10_layout and s10_ellipsis_place zqlongfolder with the more button in the row: the name ends in the ellipsis, the name, the breakdown-less row and the more button overlap nothing and stay inside the card, for the more button read as an AXPopUpButton and as an AXMenuButton", arguments: ["AXPopUpButton", "AXMenuButton"])
    func s107MoreButtonRow(role: String) throws {
        let rig = try Rig(long: true)
        let truncated = String(s10LongFolder.prefix(40)) + "…"
        try rig.put("settings-Folders.txt", s10SettingsDump("Folders", old: false, long: true, root: rig.kit, moreRole: role).replacingOccurrences(of: "label=\"\(s10LongFolder)\"", with: "label=\"\(truncated)\""))
        #expect(rig.read("settings-Folders.txt").contains("\(role) label=\"More actions for \(s10LongFolder)\""), "the long row holds no more button")
        for name in ["setup-2.txt", "panel-zqlongfile.txt"] {
            try rig.edit(name) { $0.replacingOccurrences(of: "label=\"\(s10LongFolder)\"", with: "label=\"\(truncated)\"").replacingOccurrences(of: "label=\"\(s10LongFile).jpg\"", with: "label=\"\(s10LongFile.prefix(40))….jpg…\"").replacingOccurrences(of: "label=\"\(s10LongFile).jpg \"", with: "label=\"\(s10LongFile.prefix(60))…\"").replacingOccurrences(of: "label=\"~/fixtures/long-names/\(s10LongFolder)/\(s10LongFile).jpg\"", with: "label=\"~/fixtures/long-names/…/\(s10LongFile.prefix(20))…\"") }
        }
        let r = try rig.check("S10.7")
        pass(r, "S10.7")
    }

    @Test("S10.7 is exit 4 when the planted folder cannot be picked, the state fails, the walk never ends or a dump is unreadable")
    func s107Reruns() throws {
        let pick = try Rig(long: true)
        rerun(try pick.check("S10.7", pre: "PICK_RC=3"), "S10.7")
        let state = try Rig(long: true)
        rerun(try state.check("S10.7", pre: "GOLDEN_RC=4"), "S10.7")
        let setup = try Rig(long: true)
        rerun(try setup.check("S10.7", pre: "SETUP_RC=1"), "S10.7")
        let walk = try Rig(long: true)
        rerun(try walk.check("S10.7", pre: "export FAKE_WAIT_RC=1"), "S10.7")
        let gone = try Rig(long: true)
        gone.remove("panel-zqlongfile.txt")
        rerun(try gone.check("S10.7"), "S10.7")
    }

    @Test("S10.7 is exit 4, never a PASS or a FAIL, when the panel dump holds no zqlongfile name, even with an overlap in it, and passes the same world with the name there")
    func s107NeedsName() throws {
        let control = try Rig(long: true)
        #expect(control.read("panel-zqlongfile.txt").contains("zqlongfile"), "the control panel dump holds no zqlongfile name")
        person(try control.check("S10.7"), "S10.7", mentions: "ellipsis")
        let nameless = try Rig(long: true)
        try nameless.edit("panel-zqlongfile.txt") { s10Without($0, containing: "zqlongfile") }
        let r = try nameless.check("S10.7")
        rerun(r, "S10.7")
        #expect(r.output.contains("zqlongfile"), "the RERUN does not name the missing name: \(r.output.suffix(300))")
        let overlapping = try Rig(long: true)
        try overlapping.edit("panel-zqlongfile.txt") { s10Without($0, containing: "zqlongfile") }
        try overlapping.addLine("panel-zqlongfile.txt", "AXStaticText", "Planted A", 300, 300, 100, 20)
        try overlapping.addLine("panel-zqlongfile.txt", "AXStaticText", "Planted B", 310, 300, 100, 20)
        let o = try overlapping.check("S10.7")
        rerun(o, "S10.7")
        #expect(!o.output.contains("FAIL"), "a missing name with an overlap was a FAIL: \(o.output.suffix(300))")
    }

    @Test("S10.3 reads the window bottom from the dump's own height: an element ending 514 pt down in the 548 pt Settings window outside the scroll area is not near the bottom, and one ending at 540 is")
    func s103BottomUsesWindowHeight() throws {
        let fine = try Rig()
        try fine.addLine("settings-Indexing.txt", "AXButton", "Planted low", 200, 490, 100, 24)
        let f = try fine.check("S10.3")
        person(f, "S10.3", mentions: "T3")
        #expect(!f.output.contains("T7"), "an element ending 514 down a 548 window was reported near the bottom: \(f.output.suffix(400))")
        let near = try Rig()
        try near.addLine("settings-Indexing.txt", "AXButton", "Planted lower", 200, 516, 100, 24)
        fail(try near.check("S10.3"), "S10.3", mentions: "T7", "Planted lower")
    }

    @Test("S10.3 is exit 4, never a PASS or a FAIL, when a Settings dump has no window size header, and the same world with the header passes the sections")
    func s103NeedsWindowSize() throws {
        let control = try Rig()
        #expect(control.read("settings-Folders.txt").contains("window 720 x 548 at "), "the control dump holds no window size header")
        let c = try control.check("S10.3")
        person(c, "S10.3", mentions: "T3")
        #expect(!c.output.contains("RERUN"), "the control world was a RERUN: \(c.output.suffix(300))")
        let headless = try Rig()
        try headless.edit("settings-Folders.txt") { s10Without($0, containing: "window 720 x 548 at ") }
        #expect(!headless.read("settings-Folders.txt").contains("window 720"), "the header is still in the dump")
        let r = try headless.check("S10.3")
        rerun(r, "S10.3")
        #expect(!r.output.contains("FAIL"), "a dump with no window size was a FAIL: \(r.output.suffix(300))")
        #expect(!r.output.contains("T7"), "a dump with no window size reached the bottom check: \(r.output.suffix(300))")
        #expect(r.output.localizedCaseInsensitiveContains("size"), "the RERUN does not name the missing size: \(r.output.suffix(300))")
    }

    private func s108Rig() throws -> Rig {
        let rig = try Rig()
        try rig.put("panel-failed.txt", s10Append(s10Append(s10Append(s10PanelDump("empty", old: false), "  AXImage label=\"Warning\" [disabled] frame=658,250,28,28"), "  AXStaticText label=\"The search could not run\" frame=542,288,260,20"), "  AXStaticText label=\"Try typing again in a moment.\" frame=542,314,260,16"))
        var d = rig.read("settings-File_types.txt")
        d = s10Append(s10Append(s10Append(d, "  AXImage label=\"Warning\" [disabled] frame=316,300,24,24"), "  AXStaticText label=\"Settings could not be saved\" frame=348,302,260,20"), "  AXStaticText label=\"Try again in a moment.\" frame=348,328,260,16")
        try rig.put("settings-File_types-saved-failed.txt", d)
        var s = rig.read("setup-1.txt")
        s = s10Append(s10Append(s10Append(s, "  AXImage label=\"Warning\" [disabled] frame=36,440,24,24"), "  AXStaticText label=\"Could not download the model\" frame=68,442,300,20"), "  AXStaticText label=\"Try again in a moment.\" frame=68,468,300,16")
        try rig.put("setup-1-offline.txt", s)
        return rig
    }

    @Test("S10.8 reads a failed search (the index helper killed), a failed Settings save (the Sesame folder read-only) and a failed model download (the mirror offline): each shows the Warning image next to a text and a next-step line; every failure is undone")
    func s108Pass() throws {
        let rig = try s108Rig()
        let r = try rig.check("S10.8")
        pass(r, "S10.8")
        #expect(rig.log("launch.log").contains("kill9 index"), "the helper was not killed: \(rig.log("launch.log"))")
        #expect(rig.log("mirror.log").contains("offline") && rig.log("mirror.log").last == "online", "the mirror was not put back online: \(rig.log("mirror.log"))")
        let dir = rig.kit + "/home/Library/Application Support/Sesame"
        #expect(FileManager.default.isWritableFile(atPath: dir), "the Sesame folder was left read-only")
    }

    @Test("S10.8 fails when a failure shows no Warning image, a Warning with no text beside it, or no next-step line, naming the failure")
    func s108Fails() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("search no image", ["search", "Warning"], { try $0.edit("panel-failed.txt") { s10Without($0, containing: "AXImage") } }),
            ("search image off its title", ["search", "Warning"], { try $0.edit("panel-failed.txt") { s10Moved($0, "Warning", 20, 450, 28, 28) } }),
            ("search no step", ["search", "next step"], { try $0.edit("panel-failed.txt") { s10Without($0, containing: "Try typing again") } }),
            ("save no image", ["save", "Warning"], { try $0.edit("settings-File_types-saved-failed.txt") { s10Without($0, containing: "AXImage") } }),
            ("save no step", ["save", "next step"], { try $0.edit("settings-File_types-saved-failed.txt") { s10Without($0, containing: "Try again in a moment.") } }),
            ("download no image", ["download", "Warning"], { try $0.edit("setup-1-offline.txt") { s10Without($0, containing: "AXImage") } }),
            ("download no step", ["download", "next step"], { try $0.edit("setup-1-offline.txt") { s10Without($0, containing: "Try again in a moment.") } }),
            ("red text alone", ["download", "Warning"], { try $0.edit("setup-1-offline.txt") { s10Moved($0, "Warning", 36, 540, 24, 24) } }),
        ]
        for (name, words, mutate) in cases {
            let rig = try s108Rig()
            try mutate(rig)
            let r = try rig.check("S10.8")
            #expect(r.verdict.hasPrefix("CHECK S10.8 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
            #expect(FileManager.default.isWritableFile(atPath: rig.kit + "/home/Library/Application Support/Sesame"), "\(name): the Sesame folder was left read-only")
            #expect(rig.log("mirror.log").last == "online", "\(name): the mirror was left offline")
        }
    }

    @Test("S10.8 is exit 4 when the helper cannot be killed, the state fails, or the download never shows its error, and the Sesame folder is writable again")
    func s108Reruns() throws {
        let kill = try s108Rig()
        rerun(try kill.check("S10.8", pre: "export FAKE_KILL_RC=4"), "S10.8")
        #expect(FileManager.default.isWritableFile(atPath: kill.kit + "/home/Library/Application Support/Sesame"), "left read-only")
        let state = try s108Rig()
        rerun(try state.check("S10.8", pre: "GOLDEN_RC=4"), "S10.8")
        let fresh = try s108Rig()
        rerun(try fresh.check("S10.8", pre: "FRESH_RC=4"), "S10.8")
        let never = try s108Rig()
        never.remove("setup-1-offline.txt")
        let n = try never.check("S10.8")
        rerun(n, "S10.8")
        #expect(never.log("mirror.log").last == "online", "the mirror was left offline")
    }

    @Test("S10.9 passes when every old dump and the new one are equal after the frame filter except the allowed removals and additions, which the check holds as hand-written lists")
    func s109Pass() throws {
        let rig = try Rig()
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 fails on an addition or a removal outside the allowed lists, naming the label, and on the tree cut line")
    func s109Fails() throws {
        let added = try Rig()
        try added.edit("settings-Search.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=316,400,100,16") }
        fail(try added.check("S10.9"), "S10.9", mentions: "Planted extra label")
        let removed = try Rig()
        try removed.edit("settings-Search.txt") { s10Without($0, containing: "Media app") }
        fail(try removed.check("S10.9"), "S10.9", mentions: "Media app")
        let renamed = try Rig()
        try renamed.edit("menu.txt") { $0.replacingOccurrences(of: "Quit Sesame", with: "Quit") }
        fail(try renamed.check("S10.9"), "S10.9", mentions: "Quit")
        let help = try Rig()
        try help.edit("setup-2.txt") { $0.replacingOccurrences(of: "help=\"\(help.kit)/home/Desktop\"", with: "help=\"\(help.kit)/home/Elsewhere\"") }
        fail(try help.check("S10.9"), "S10.9", mentions: "Desktop")
        let cut = try Rig()
        let many = (0..<1300).map { "  AXStaticText label=\"x\($0)\" frame=\(100 + $0 % 400),\(50 + $0 / 4),10,10" }.joined(separator: "\n")
        try cut.edit("panel-empty.txt") { $0 + many + "\n(tree cut at 1200 elements)\n" }
        fail(try cut.check("S10.9"), "S10.9", mentions: "tree cut")
    }

    @Test("S10.9 lets the menu dump lose the greyed Pause indexing, the Code count and the Last indexed row the baseline holds and gain the header AXGroup, because the person chose the tidy menu (guide 14.1) and removed the Last indexed row (guide 19): the old dump is the real baseline text, which holds the separators as label-less disabled items, a disabled Pause indexing, a Code line and the Last indexed row")
    func s109MenuTidyChange() throws {
        let rig = try Rig()
        let old = KC.read(rig.before + "/dump-menu.txt") ?? ""
        #expect(old.contains("AXMenuItem label=\"Pause indexing\" [disabled]") && old.contains("AXMenuItem label=\"Code: 12\" [disabled]") && old.contains("AXMenuItem [disabled]\n"), "the old menu dump holds no disabled Pause, no Code line and no separator, so the removals are not exercised")
        #expect(old.contains("AXMenuItem label=\"Last indexed: annual-report-60p.pdf\" [disabled]"), "the old menu dump does not hold the Last indexed row, so its removal (guide 19) is not exercised")
        #expect(!rig.read("menu.txt").contains("Last indexed"), "the new menu dump still holds a Last indexed row")
        if let real = KC.read(KC.root.path + "/.ril/evidence/ui/before/dump-menu.txt") {
            #expect(old.trimmingCharacters(in: .whitespacesAndNewlines) == real.trimmingCharacters(in: .whitespacesAndNewlines), "the hand-copied baseline menu differs from .ril/evidence/ui/before/dump-menu.txt")
        }
        let new = rig.read("menu.txt")
        #expect(!new.contains("Pause indexing") && !new.contains("Code") && new.contains("AXGroup label=\"Ready\""), "the new menu dump is not the tidy Ready one, so the additions are not exercised")
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 allows the header AXGroup label \"<state word>[, <detail>]\" for every header the menu can show, in the menu dump", arguments: ["Ready", "Ready, Indexing has not been started", "Indexing 62%", "Indexing 62%, 4,520 files left \u{00B7} about 12 min left", "Paused, By you", "Paused, Indexing stopped, press Resume", "Paused, The Mac is busy", "Downloading the model, 40%", "Model download failed"])
    func s109MenuHeaderGroupLabels(label: String) throws {
        let rig = try Rig()
        try rig.edit("menu.txt") { $0.replacingOccurrences(of: "AXGroup label=\"Ready\"", with: "AXGroup label=\"\(label)\"") }
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 keeps the menu allowances narrow: a planted extra item, a missing Quit Sesame, a missing count line, a new menu that still holds the Last indexed line (guide 19), an old enabled, differently named or colon-less item that went missing next to the allowed Last indexed row, a Pause indexing in a Ready new dump (enabled, as an addition, or greyed like the baseline's, as a disabled action the tidy menu no longer draws), a Resume or Retry greyed, Nothing indexed yet, a group with another label or a state word glued to a word, and an allowance used on another dump, each fail")
    func s109MenuStaysNarrow() throws {
        func beforeOpen(_ text: String, _ line: String) -> String { text.replacingOccurrences(of: "  AXMenuItem label=\"Open Sesame\"", with: "\(line)\n  AXMenuItem label=\"Open Sesame\"") }
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("a planted extra item", ["Planted extra item"], { try $0.edit("menu.txt") { beforeOpen($0, "  AXMenuItem label=\"Planted extra item\" frame=800,0,260,22") } }),
            ("a planted missing Quit Sesame", ["Quit Sesame"], { try $0.edit("menu.txt") { s10Without($0, containing: "Quit Sesame") } }),
            ("a planted missing count line", ["Photos: 42"], { try $0.edit("menu.txt") { s10Without($0, containing: "Photos: 42") } }),
            ("a planted new menu that still holds the Last indexed line", ["Last indexed", "guide 19"], { try $0.edit("menu.txt") { beforeOpen($0, "  AXMenuItem label=\"Last indexed: annual-report-60p.pdf\" [disabled] frame=800,0,260,22") } }),
            ("a planted new menu with a Last indexed line that has no file name", ["Last indexed", "guide 19"], { try $0.edit("menu.txt") { beforeOpen($0, "  AXMenuItem label=\"Last indexed\" [disabled] frame=800,0,260,22") } }),
            ("an old enabled Last indexed item that went missing", ["Last indexed: other.pdf"], {
                let f = $0.before + "/dump-menu.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXMenuItem label=\"Last indexed: other.pdf\""))
            }),
            ("an old disabled item of another name that went missing", ["Recently read: other.pdf"], {
                let f = $0.before + "/dump-menu.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXMenuItem label=\"Recently read: other.pdf\" [disabled]"))
            }),
            ("an old disabled Last indexed item with no colon that went missing", ["Last indexed other.pdf"], {
                let f = $0.before + "/dump-menu.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXMenuItem label=\"Last indexed other.pdf\" [disabled]"))
            }),
            ("the Last indexed removal used in another old dump", ["Last indexed"], {
                let f = $0.before + "/dump-settings-indexing.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXMenuItem label=\"Last indexed: annual-report-60p.pdf\" [disabled]"))
            }),
            ("a planted enabled Pause indexing in a Ready new dump", ["Pause indexing"], { try $0.edit("menu.txt") { beforeOpen($0, "  AXMenuItem label=\"Pause indexing\" frame=800,0,260,22") } }),
            ("a planted greyed Pause indexing in a Ready new dump", ["Pause indexing", "W19"], { try $0.edit("menu.txt") { beforeOpen($0, "  AXMenuItem label=\"Pause indexing\" [disabled] frame=800,0,260,22") } }),
            ("a planted greyed Resume indexing", ["Resume indexing"], { try $0.edit("menu.txt") { beforeOpen($0, "  AXMenuItem label=\"Resume indexing\" [disabled] frame=800,0,260,22") } }),
            ("a planted greyed Retry", ["Retry model download"], { try $0.edit("menu.txt") { beforeOpen($0, "  AXMenuItem label=\"Retry model download\" [disabled] frame=800,0,260,22") } }),
            ("a planted Nothing indexed yet", ["Nothing indexed yet"], { try $0.edit("menu.txt") { beforeOpen($0, "  AXMenuItem label=\"Nothing indexed yet\" [disabled] frame=800,0,260,22") } }),
            ("a group with another label", ["Planted group"], { try $0.edit("menu.txt") { $0.replacingOccurrences(of: "AXGroup label=\"Ready\"", with: "AXGroup label=\"Planted group\"") } }),
            ("a state word glued to a word", ["Ready now"], { try $0.edit("menu.txt") { $0.replacingOccurrences(of: "AXGroup label=\"Ready\"", with: "AXGroup label=\"Ready now\"") } }),
            ("the header group allowance used in Settings", ["Ready"], { try $0.edit("settings-Indexing.txt") { s10Append($0, "  AXGroup label=\"Ready\" frame=300,400,100,16") } }),
            ("the greyed Pause removal used in another old dump", ["Pause indexing"], {
                let f = $0.before + "/dump-settings-indexing.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXMenuItem label=\"Pause indexing\" [disabled]"))
            }),
            ("the Code line removal used in another old dump", ["Code: 12"], {
                let f = $0.before + "/dump-settings-indexing.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXMenuItem label=\"Code: 12\" [disabled]"))
            }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9 passes the new Setup (dots groups, Welcome promises, status line) against the old dumps, and also against an old dump whose model was whole and read \"The model is ready.\"")
    func s109SetupAllowances() throws {
        let whole = try Rig()
        let oldWelcome = whole.before + "/dump-setup-1.txt"
        let swapped = (KC.read(oldWelcome) ?? "").components(separatedBy: "\n").filter { !$0.contains("Model download") }.map { $0.replacingOccurrences(of: "The search model", with: "The model is ready.") }.joined(separator: "\n")
        try KC.write(oldWelcome, swapped)
        pass(try whole.check("S10.9"), "S10.9")
    }

    @Test("S10.9 still fails on a Setup change the lists do not name, and on a Setup allowance used outside the Setup dump it belongs to")
    func s109SetupFails() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("planted text on Welcome", ["Planted extra label"], { try $0.edit("setup-1.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=300,300,100,16") } }),
            ("planted missing Add folder", ["Add folder"], { try $0.edit("setup-2.txt") { s10Without($0, containing: "Add folder…") } }),
            ("planted missing Next", ["Next"], { try $0.edit("setup-3.txt") { s10Without($0, containing: "label=\"Next\"") } }),
            ("planted extra text on Permissions", ["Planted extra label"], { try $0.edit("setup-3.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=300,400,100,16") } }),
            ("planted missing intro line on Permissions", ["macOS asks once"], { try $0.edit("setup-3.txt") { s10Without($0, containing: "macOS asks once") } }),
            ("planted missing read note on Permissions", ["Sesame never asks"], { try $0.edit("setup-3.txt") { s10Without($0, containing: "Sesame never asks") } }),
            ("old title text kept as a title", ["Shortcut"], { try $0.edit("setup-4.txt") { s10Append($0, "  AXStaticText label=\"Shortcut\" frame=300,300,100,16") } }),
            ("promise text on Folders", ["Search by meaning"], { try $0.edit("setup-2.txt") { s10Append($0, "  AXStaticText label=\"Search by meaning\" frame=300,470,100,16") } }),
            ("Welcome title on Folders", ["Welcome to Sesame"], { try $0.edit("setup-2.txt") { s10Append($0, "  AXStaticText label=\"Welcome to Sesame\" frame=300,470,100,16") } }),
            ("dots group in Settings", ["Step 2 of 4: Folders"], { try $0.edit("settings-Indexing.txt") { s10Append($0, "  AXGroup label=\"Step 2 of 4: Folders\" frame=300,400,56,8") } }),
            ("dots group with a wrong title", ["Step 2 of 4"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "Step 2 of 4: Folders", with: "Step 2 of 4: Folder") } }),
            ("old caption removed in Settings", ["Step 1 of 4: Welcome"], {
                let f = $0.before + "/dump-settings-indexing.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXStaticText label=\"Step 1 of 4: Welcome\""))
            }),
            ("old text area removed in Settings", ["Welcome to Sesame"], {
                let f = $0.before + "/dump-settings-indexing.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXTextArea label=\"Welcome to Sesame\" value=\"x\""))
            }),
            ("old disabled Back removed on Folders", ["Back"], {
                let f = $0.before + "/dump-setup-2.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXButton label=\"Back\" [disabled]"))
            }),
            ("old model card removed in Settings", ["Model download"], {
                let f = $0.before + "/dump-settings-indexing.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXGroup label=\"Model download\" value=\"9 of 865 MB\""))
            }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9 needs no new entry for the Permissions step of Setup (guide 12.6): its texts are unchanged, so the new step 3 dump passes with the lists as task 10 left them, the old bullets going under the existing allowance")
    func s109PermissionsNeedsNothingNew() throws {
        let rig = try Rig()
        let old = KC.read(rig.before + "/dump-setup-3.txt") ?? ""
        #expect(old.contains("• Desktop") && old.contains("macOS asks once"), "the old Permissions dump holds no bullets and no intro, so the pass proves nothing")
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 lets the Shortcut step of Setup lose the old heading \"Open Sesame with\" and the old shortcut text \"Control Option Space\" as a static text, and gain the heading \"Open Sesame from anywhere\", the lead \"Press these keys together.\" and an AXGroup labelled \"Control Option Space\" with no children (guide 13.1 to 13.3), the old dump being the one the real baseline holds")
    func s109ShortcutTextsMayChange() throws {
        let rig = try Rig()
        let old = KC.read(rig.before + "/dump-setup-4.txt") ?? ""
        #expect(old.contains("label=\"Open Sesame with\"") && old.contains("AXStaticText label=\"Control Option Space\"") && old.contains("label=\"\(s10ShortcutNote)\""), "the old Shortcut dump holds no old heading, no old shortcut text and no note, so the removals are not exercised")
        let new = rig.read("setup-4.txt")
        #expect(new.contains("AXStaticText label=\"\(s10ShortcutHeading)\"") && new.contains("AXStaticText label=\"\(s10ShortcutLead)\"") && new.contains("AXGroup label=\"\(s10ShortcutKeys)\"") && !new.contains("Open Sesame with") && !new.contains("AXStaticText label=\"\(s10ShortcutKeys)\""), "the new Shortcut dump is not the keycaps one, so the additions are not exercised")
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 keeps the Shortcut allowances inside dump-setup-4.txt and inside their patterns: an extra text, an AXTextField or an AXStaticText for the shortcut, a key or a caption exposed as an element in the group, a missing note or Finish, the old heading or the old text kept in the new dump, a heading with another wording, and an allowance used on another step, each fail")
    func s109ShortcutStaysNarrow() throws {
        func underGroup(_ text: String, _ child: String) -> String {
            text.components(separatedBy: "\n").flatMap { $0.contains("AXGroup label=\"\(s10ShortcutKeys)\"") ? [$0, "    AXStaticText label=\"\(child)\" frame=276,340,44,15"] : [$0] }.joined(separator: "\n")
        }
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("planted extra text on Shortcut", ["Planted extra label"], { try $0.edit("setup-4.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=300,400,100,16") } }),
            ("planted AXTextField for the shortcut", ["AXTextField", s10ShortcutKeys], { try $0.edit("setup-4.txt") { $0.replacingOccurrences(of: "AXGroup label=\"\(s10ShortcutKeys)\"", with: "AXTextField label=\"\(s10ShortcutKeys)\"") } }),
            ("planted AXTextField beside the group", ["AXTextField", "Shortcut field"], { try $0.edit("setup-4.txt") { s10Append($0, "  AXTextField label=\"Shortcut field\" frame=300,400,100,16") } }),
            ("planted AXStaticText for the shortcut in place of the group", ["AXStaticText", s10ShortcutKeys], { try $0.edit("setup-4.txt") { $0.replacingOccurrences(of: "AXGroup label=\"\(s10ShortcutKeys)\"", with: "AXStaticText label=\"\(s10ShortcutKeys)\"") } }),
            ("planted key exposed in the group", ["Control"], { try $0.edit("setup-4.txt") { underGroup($0, "Control") } }),
            ("planted caption exposed in the group", ["Option"], { try $0.edit("setup-4.txt") { underGroup($0, "Option") } }),
            ("planted missing note", ["You can change the shortcut"], { try $0.edit("setup-4.txt") { s10Without($0, containing: "label=\"\(s10ShortcutNote)\"") } }),
            ("planted missing Finish", ["Finish"], { try $0.edit("setup-4.txt") { s10Without($0, containing: "label=\"Finish\"") } }),
            ("planted missing Back", ["Back"], { try $0.edit("setup-4.txt") { s10Without($0, containing: "label=\"Back\"") } }),
            ("planted old heading kept in the new dump", ["Open Sesame with"], { try $0.edit("setup-4.txt") { s10Append($0, "  AXStaticText label=\"Open Sesame with\" frame=330,150,200,16") } }),
            ("planted old shortcut text kept beside the group", [s10ShortcutKeys], { try $0.edit("setup-4.txt") { s10Append($0, "  AXStaticText label=\"\(s10ShortcutKeys)\" frame=330,150,200,16") } }),
            ("heading with another wording", ["Open Sesame from anywhere."], { try $0.edit("setup-4.txt") { $0.replacingOccurrences(of: "label=\"\(s10ShortcutHeading)\"", with: "label=\"Open Sesame from anywhere.\"") } }),
            ("lead with another wording", ["Press these keys"], { try $0.edit("setup-4.txt") { $0.replacingOccurrences(of: "label=\"\(s10ShortcutLead)\"", with: "label=\"Press these keys.\"") } }),
            ("the new heading on the Permissions step", [s10ShortcutHeading], { try $0.edit("setup-3.txt") { s10Append($0, "  AXStaticText label=\"\(s10ShortcutHeading)\" frame=300,400,100,16") } }),
            ("the new lead on the Folders step", [s10ShortcutLead], { try $0.edit("setup-2.txt") { s10Append($0, "  AXStaticText label=\"\(s10ShortcutLead)\" frame=300,470,100,16") } }),
            ("a keycaps group on the Welcome step", [s10ShortcutKeys], { try $0.edit("setup-1.txt") { s10Append($0, "  AXGroup label=\"\(s10ShortcutKeys)\" frame=300,470,100,16") } }),
            ("the old heading gone from the Permissions dump", ["Open Sesame with"], {
                let f = $0.before + "/dump-setup-3.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXStaticText label=\"Open Sesame with\""))
            }),
            ("the old shortcut text gone from the Folders dump", [s10ShortcutKeys], {
                let f = $0.before + "/dump-setup-2.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXStaticText label=\"\(s10ShortcutKeys)\""))
            }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9 lets the Folders step of Setup lose the baseline's Next button and its disabled Start indexing and gain Start indexing enabled, Not now and the two hint lines (guide 15.1 to 15.5, W22 to W24), the old dump being the baseline the real evidence holds: Start indexing [disabled], Next [focused]")
    func s109FoldersFooterMayChange() throws {
        let rig = try Rig()
        let old = KC.read(rig.before + "/dump-setup-2.txt") ?? ""
        #expect(old.contains("AXButton label=\"Start indexing\" [disabled]") && old.contains("AXButton label=\"Next\" [focused]"), "the old Folders dump holds no disabled Start indexing and no Next, so the removals are not exercised")
        if let real = KC.read(KC.root.path + "/.ril/evidence/ui/before/dump-setup-2.txt") {
            #expect(real.contains("\n  AXButton label=\"Start indexing\" [disabled]\n") && real.contains("\n  AXButton label=\"Next\" [focused]\n"), "the hand-copied baseline buttons differ from .ril/evidence/ui/before/dump-setup-2.txt")
        }
        let new = rig.read("setup-2.txt")
        #expect(new.contains("AXButton label=\"Not now\"") && new.contains("label=\"\(s10HintStart)\"") && new.contains("AXButton label=\"Start indexing\" frame") && !new.contains("AXButton label=\"Next\""), "the new Folders dump is not the footer Start indexing one, so the additions are not exercised")
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 keeps the Folders footer allowances inside dump-setup-2.txt and inside their patterns: an extra text, a missing Add folder or Back, a Next button beside Start indexing, Not now as a text, a hint with other words, and each allowance used on another step or another old dump, each fail")
    func s109FoldersFooterStaysNarrow() throws {
        func oldAppend(_ rig: Rig, _ name: String, _ line: String) throws {
            let f = rig.before + "/" + name
            try KC.write(f, s10Append(KC.read(f) ?? "", line))
        }
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("planted extra text on Folders", ["Planted extra label"], { try $0.edit("setup-2.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=300,470,100,16") } }),
            ("planted missing Add folder on Folders", ["Add folder"], { try $0.edit("setup-2.txt") { s10Without($0, containing: "Add folder…") } }),
            ("planted missing Back on Folders", ["Back"], { try $0.edit("setup-2.txt") { s10Without($0, containing: "label=\"Back\"") } }),
            ("planted Next beside Start indexing", ["Next", "W22"], { try $0.addLine("setup-2.txt", "AXButton", "Next", 440, 556, 100, 24) }),
            ("Not now as a static text", ["Not now"], { try $0.addLine("setup-2.txt", "AXStaticText", "Not now", 300, 470, 90, 20) }),
            ("hint with other words", ["Indexing starts when you press Start."], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "label=\"\(s10HintStart)\"", with: "label=\"Indexing starts when you press Start.\"") } }),
            ("the hint on the Permissions step", [s10HintStart], { try $0.addLine("setup-3.txt", "AXStaticText", s10HintStart, 300, 470, 100, 16) }),
            ("Not now on the Permissions step", ["Not now"], { try $0.addLine("setup-3.txt", "AXButton", "Not now", 300, 470, 90, 20) }),
            ("an enabled Start indexing on the Permissions step", ["Start indexing"], { try $0.addLine("setup-3.txt", "AXButton", "Start indexing", 300, 470, 110, 24) }),
            ("the running line on the Folders step", [s10Running], { try $0.addLine("setup-2.txt", "AXStaticText", s10Running, 300, 470, 100, 16) }),
            ("the Next removal used in another old dump", ["Next"], { try oldAppend($0, "dump-setup-3.txt", "  AXButton label=\"Next\"") }),
            ("the disabled Start indexing removal used in another old dump", ["Start indexing"], { try oldAppend($0, "dump-setup-3.txt", "  AXButton label=\"Start indexing\" [disabled]") }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9 lets the Shortcut step of Setup gain the running line \"Indexing is running. Watch it from the magnifier in the menu bar.\" after Start (guide 15.6, W25) and only that text and only in dump-setup-4.txt: the same line with other words, or on another step, fails")
    func s109ShortcutRunningLine() throws {
        let started = try Rig()
        try started.put("setup-4.txt", s10SetupDump(4, old: false, long: false, root: started.kit, started: true))
        #expect(started.read("setup-4.txt").contains("AXStaticText label=\"\(s10Running)\""), "the started Shortcut dump holds no running line, so the addition is not exercised")
        pass(try started.check("S10.9"), "S10.9")
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("the running line with other words", ["Indexing is running."], { try $0.edit("setup-4.txt") { s10Append($0, "  AXStaticText label=\"Indexing is running.\" frame=300,470,100,16") } }),
            ("the running line on the Folders step", [s10Running], { try $0.edit("setup-2.txt") { s10Append($0, "  AXStaticText label=\"\(s10Running)\" frame=300,470,100,16") } }),
            ("the running line as a button on the Shortcut step", ["AXButton", s10Running], { try $0.edit("setup-4.txt") { s10Append($0, "  AXButton label=\"\(s10Running)\" frame=300,470,100,16") } }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9 lets the Folders step of Setup lose the old summary \"<N> files in the ticked folders.\" and the speed line \"Photos: about <n> s each\" and gain \"<N> files in <M> folders\" with a thousands comma and the read note, because the person removed the speed line and the summary is reworded (guide 11.1)")
    func s109FoldersTextsMayChange() throws {
        let rig = try Rig()
        let old = KC.read(rig.before + "/dump-setup-2.txt") ?? ""
        #expect(old.contains("files in the ticked folders.") && old.contains("Photos: about 2 s each"), "the old Folders dump holds no old summary and no speed line, so the removals are not exercised")
        pass(try rig.check("S10.9"), "S10.9")
        for summary in ["4,233 files in 4 folders", "1 file in 1 folder", "16,310 files in 4 folders", "1,234,567 files in 12 folders"] {
            let r = try Rig()
            try r.edit("setup-2.txt") { $0.replacingOccurrences(of: "10 files in 5 folders", with: summary) }
            pass(try r.check("S10.9"), "S10.9")
        }
    }

    @Test("S10.9 keeps the Folders allowances inside dump-setup-2.txt and inside their patterns: a summary without the thousands comma, with a wrong shape or on another step, the speed line in the new dump, and the old summary or speed line gone from another old dump, each fail")
    func s109FoldersTextsStayNarrow() throws {
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("no thousands comma", ["4233 files in 4 folders"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "10 files in 5 folders", with: "4233 files in 4 folders") } }),
            ("comma in the wrong place", ["42,33 files in 4 folders"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "10 files in 5 folders", with: "42,33 files in 4 folders") } }),
            ("summary with words after the folders", ["10 files in 5 folders ticked"], { try $0.edit("setup-2.txt") { $0.replacingOccurrences(of: "10 files in 5 folders", with: "10 files in 5 folders ticked") } }),
            ("speed line planted in the new Folders dump", ["Photos: about 3 s each"], { try $0.edit("setup-2.txt") { s10Append($0, "  AXStaticText label=\"Photos: about 3 s each\" frame=330,150,200,16") } }),
            ("per-row detail text planted in the new Folders dump", ["100 photos, about 5 min"], { try $0.edit("setup-2.txt") { s10Append($0, "  AXStaticText label=\"100 photos, about 5 min\" frame=330,150,200,16") } }),
            ("new summary on the Permissions step", ["10 files in 5 folders"], { try $0.edit("setup-3.txt") { s10Append($0, "  AXStaticText label=\"10 files in 5 folders\" frame=300,400,100,16") } }),
            ("old speed line gone from the Permissions dump", ["Photos: about 3 s each"], {
                let f = $0.before + "/dump-setup-3.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXStaticText label=\"Photos: about 3 s each\""))
            }),
            ("old summary gone from the Welcome dump", ["10 files in the ticked folders."], {
                let f = $0.before + "/dump-setup-1.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXStaticText label=\"10 files in the ticked folders.\""))
            }),
            ("old speed line with a wrong shape gone from the Folders dump", ["Photos: roughly 3 s each"], {
                let f = $0.before + "/dump-setup-2.txt"
                try KC.write(f, s10Append(KC.read(f) ?? "", "  AXStaticText label=\"Photos: roughly 3 s each\""))
            }),
            ("a planted missing Add folder", ["Add folder"], { try $0.edit("setup-2.txt") { s10Without($0, containing: "Add folder…") } }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9 lets an old Folders baseline with 1000 or more files lose \"1500 files in the ticked folders.\" written with no comma, while a new summary with no thousands comma still fails")
    func s109OldSummaryWithoutCommaMayGo() throws {
        let rig = try Rig()
        let path = rig.before + "/dump-setup-2.txt"
        let old = KC.read(path) ?? ""
        #expect(old.contains("10 files in the ticked folders."), "the old Folders dump holds no old summary to rewrite")
        try KC.write(path, old.replacingOccurrences(of: "10 files in the ticked folders.", with: "1500 files in the ticked folders."))
        pass(try rig.check("S10.9"), "S10.9")
        let strict = try Rig()
        try strict.edit("setup-2.txt") { $0.replacingOccurrences(of: "10 files in 5 folders", with: "1500 files in 5 folders") }
        let r = try strict.check("S10.9")
        #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "a summary with no thousands comma was allowed: \(r.verdict) rc \(r.rc)")
    }

    @Test("S10.9 needs nothing new for \"Counting files…\" or \"The model is ready.\" on the old Folders dump: the first is the same in both, the second is already allowed")
    func s109FoldersCountingAndReady() throws {
        let rig = try Rig()
        let old = rig.before + "/dump-setup-2.txt"
        try KC.write(old, s10Append(s10Append(KC.read(old) ?? "", "  AXStaticText label=\"Counting files…\""), "  AXStaticText label=\"The model is ready.\""))
        try rig.edit("setup-2.txt") { s10Append($0, "  AXStaticText label=\"Counting files…\" frame=330,150,200,16") }
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 lets the Folders section of Settings lose the per-row Re-index and Remove buttons the baseline holds and gain the title \"Folders Sesame reads\", the note and a \"More actions for <name>\" control per row in either role, because the person chose the more menu (guide 16.4), the old dump being the baseline the real evidence holds, and lets every Settings dump lose the About sidebar button (guide 16.16)", arguments: ["AXPopUpButton", "AXMenuButton"])
    func s109SettingsFoldersMoreButton(role: String) throws {
        let rig = try Rig()
        try rig.put("settings-Folders.txt", s10SettingsDump("Folders", old: false, long: false, root: rig.kit, moreRole: role))
        let old = KC.read(rig.before + "/dump-settings-folders.txt") ?? ""
        #expect(old.contains("AXButton label=\"Re-index\" help=\"Desktop\"") && old.contains("AXButton label=\"Remove\" help=\"Desktop\"") && old.contains("AXCheckBox/AXToggle label=\"About\" value=\"0\""), "the old Folders dump holds no row buttons and no About button, so the removals are not exercised")
        if let real = KC.read(KC.root.path + "/.ril/evidence/ui/before/dump-settings-folders.txt") {
            #expect(real.contains("\n    AXButton label=\"Re-index\" help=\"golden\"\n") && real.contains("\n    AXButton label=\"Remove\" help=\"golden\"\n") && real.contains("\n  AXCheckBox/AXToggle label=\"About\" value=\"0\"\n") && real.contains("\n  AXButton label=\"Add folder…\"\n"), "the hand-copied baseline lines differ from .ril/evidence/ui/before/dump-settings-folders.txt")
        }
        let new = rig.read("settings-Folders.txt")
        #expect(new.contains("\(role) label=\"More actions for Desktop\"") && new.contains("label=\"\(s10FoldersTitle)\"") && new.contains("label=\"\(s10FoldersNote)\"") && !new.contains("label=\"Re-index\"") && !new.contains("label=\"About\""), "the new Folders dump is not the layout B one, so the additions are not exercised")
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 keeps the Settings Folders allowances inside dump-settings-folders.txt and inside their patterns: an extra text, a missing row checkbox, a Re-index or Remove button left in the new Folders dump (W32), a more control that is a plain AXButton, a title or note with other words, and each allowance used in another dump or another old dump, each fail")
    func s109SettingsFoldersStaysNarrow() throws {
        func oldAppend(_ rig: Rig, _ name: String, _ line: String) throws {
            let f = rig.before + "/" + name
            try KC.write(f, s10Append(KC.read(f) ?? "", line))
        }
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("a planted extra text in the Folders section", ["Planted extra label"], { try $0.edit("settings-Folders.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=316,400,100,16") } }),
            ("a planted missing row checkbox", ["Documents"], { try $0.edit("settings-Folders.txt") { s10Without($0, containing: "AXCheckBox label=\"Documents\"") } }),
            ("a Re-index button left in the new Folders dump", ["Re-index", "W32"], { try $0.addLine("settings-Folders.txt", "AXButton", "Re-index", 560, 130, 60, 20, flags: "help=\"Desktop\"", depth: 3) }),
            ("a Remove button left in the new Folders dump", ["Remove", "W32"], { try $0.addLine("settings-Folders.txt", "AXButton", "Remove", 600, 130, 60, 20, flags: "help=\"Desktop\"", depth: 3) }),
            ("a more control that is a plain AXButton", ["More actions for Desktop"], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: "AXPopUpButton label=\"More actions for Desktop\"", with: "AXButton label=\"More actions for Desktop\"") } }),
            ("a more control with an empty name", ["More actions for"], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: "label=\"More actions for Desktop\"", with: "label=\"More actions for\"") } }),
            ("the title with other words", ["Folders we read"], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: "label=\"\(s10FoldersTitle)\"", with: "label=\"Folders we read\"") } }),
            ("the note with other words", ["Tick a folder to read it."], { try $0.edit("settings-Folders.txt") { $0.replacingOccurrences(of: "label=\"\(s10FoldersNote)\"", with: "label=\"Tick a folder to read it.\"") } }),
            ("the title in the Search dump", [s10FoldersTitle], { try $0.addLine("settings-Search.txt", "AXStaticText", s10FoldersTitle, 300, 400, 100, 16, depth: 2) }),
            ("the note in the Indexing dump", ["Tick a folder to read it"], { try $0.addLine("settings-Indexing.txt", "AXStaticText", s10FoldersNote, 300, 400, 100, 16, depth: 2) }),
            ("a more control in the Search dump", ["More actions for Desktop"], { try $0.addLine("settings-Search.txt", "AXPopUpButton", "More actions for Desktop", 300, 400, 22, 22, depth: 2) }),
            ("the Re-index removal used in another old dump", ["Re-index"], { try oldAppend($0, "dump-settings-search.txt", "  AXButton label=\"Re-index\" help=\"golden\"") }),
            ("the Remove removal used in the Setup Folders old dump", ["Remove"], { try oldAppend($0, "dump-setup-2.txt", "  AXButton label=\"Remove\" help=\"golden\"") }),
            ("a Re-index removal with no help", ["Re-index"], { try oldAppend($0, "dump-settings-folders.txt", "  AXButton label=\"Re-index\"") }),
            ("the About button removal used in the Setup old dump", ["About"], { try oldAppend($0, "dump-setup-3.txt", "  AXCheckBox/AXToggle label=\"About\" value=\"0\"") }),
            ("the About button removal of the selected About", ["About"], { try oldAppend($0, "dump-settings-indexing.txt", "  AXCheckBox/AXToggle label=\"About\" value=\"1\"") }),
            ("a different sidebar button removed", ["Search"], { try $0.edit("settings-Indexing.txt") { s10Without($0, containing: "AXCheckBox/AXToggle label=\"Search\"") } }),
            ("an About pane title in the new Search dump", ["About"], { try $0.addLine("settings-Search.txt", "AXStaticText", "About", 197, 13, 100, 20) }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9 lets the File types section of Settings lose its five AXCheckBox kinds and gain five AXCheckBox/AXSwitch kinds and the title \"File types Sesame reads\", because the person chose system switches (guide 16.12), the old dump being the baseline the real evidence holds: the five kinds as AXCheckBox with value 1")
    func s109SettingsFileTypesSwitches() throws {
        let rig = try Rig()
        let old = KC.read(rig.before + "/dump-settings-file-types.txt") ?? ""
        #expect(s10Kinds.allSatisfy { old.contains("AXCheckBox label=\"\($0)\" ") } && old.contains("AXCheckBox label=\"Search my code\""), "the old File types dump does not hold the five kinds as AXCheckBox, so the removals are not exercised")
        if let real = KC.read(KC.root.path + "/.ril/evidence/ui/before/dump-settings-file-types.txt") {
            #expect(s10Kinds.allSatisfy { real.contains("\n  AXCheckBox label=\"\($0)\" value=\"1\"\n") }, "the hand-copied baseline kinds differ from .ril/evidence/ui/before/dump-settings-file-types.txt")
        }
        let new = rig.read("settings-File_types.txt")
        #expect(s10Kinds.allSatisfy { new.contains("AXCheckBox/AXSwitch label=\"\($0)\" value=\"1\"") } && new.contains("label=\"\(s10FileTypesTitle)\""), "the new File types dump is not the layout A one, so the additions are not exercised")
        pass(try rig.check("S10.9"), "S10.9")
        let off = try Rig()
        try off.edit("settings-File_types.txt") { $0.replacingOccurrences(of: "label=\"Video\" value=\"1\"", with: "label=\"Video\" value=\"0\"") }
        pass(try off.check("S10.9"), "S10.9")
    }

    @Test("S10.9 keeps the File types allowances inside dump-settings-file-types.txt and inside their patterns: a planted sixth switch, an extra static text, a missing kind, a kind left as an AXCheckBox in the new dump, a kind with a value that is not 1 or 0, the title in another dump, a kind switch in another dump, and the kind removal used in another old dump, each fail; the Code lines of the baseline were already allowed to go")
    func s109SettingsFileTypesStaysNarrow() throws {
        func oldAppend(_ rig: Rig, _ name: String, _ line: String) throws {
            let f = rig.before + "/" + name
            try KC.write(f, s10Append(KC.read(f) ?? "", line))
        }
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("a planted sixth switch", ["Code"], { try $0.edit("settings-File_types.txt") { s10Append($0, "  AXCheckBox/AXSwitch label=\"Code\" value=\"1\" frame=752,400,38,22") } }),
            ("a planted extra static text", ["Planted extra label"], { try $0.edit("settings-File_types.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=316,400,100,16") } }),
            ("a planted missing kind", ["Audio", "system switches"], { try $0.edit("settings-File_types.txt") { s10Without($0, containing: "label=\"Audio\"") } }),
            ("a kind left as an AXCheckBox", ["PDFs", "system switches", "16.12"], { try $0.edit("settings-File_types.txt") { $0.replacingOccurrences(of: "AXCheckBox/AXSwitch label=\"PDFs\"", with: "AXCheckBox label=\"PDFs\"") } }),
            ("a kind with a value that is not 1 or 0", ["Photos"], { try $0.edit("settings-File_types.txt") { $0.replacingOccurrences(of: "AXSwitch label=\"Photos\" value=\"1\"", with: "AXSwitch label=\"Photos\" value=\"2\"") } }),
            ("the title in the Folders dump", [s10FileTypesTitle], { try $0.addLine("settings-Folders.txt", "AXStaticText", s10FileTypesTitle, 300, 500, 100, 16, depth: 2) }),
            ("a kind switch in the Folders dump", ["Photos"], { try $0.addLine("settings-Folders.txt", "AXCheckBox/AXSwitch", "Photos", 300, 500, 38, 22, flags: "value=\"1\"", depth: 2) }),
            ("a kind switch in the Indexing dump", ["Audio"], { try $0.addLine("settings-Indexing.txt", "AXCheckBox/AXSwitch", "Audio", 300, 400, 38, 22, flags: "value=\"1\"", depth: 2) }),
            ("the kind removal used in another old dump", ["Photos"], { try oldAppend($0, "dump-settings-search.txt", "  AXCheckBox label=\"Photos\" value=\"1\"") }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9 still fails the menu allowances the Settings change leaves alone: a planted missing Quit Sesame in the menu dump and a planted Re-index left in a new Folders dump each fail, with the Settings worlds in place")
    func s109SettingsChangeLeavesMenuNarrow() throws {
        let menu = try Rig()
        try menu.edit("menu.txt") { s10Without($0, containing: "Quit Sesame") }
        fail(try menu.check("S10.9"), "S10.9", mentions: "Quit Sesame")
        let left = try Rig()
        try left.addLine("settings-Folders.txt", "AXButton", "Re-index", 560, 130, 60, 20, flags: "help=\"Desktop\"", depth: 3)
        fail(try left.check("S10.9"), "S10.9", mentions: "Re-index")
    }

    @Test("S10.9 lets the Search section of Settings lose the static text \"Keyboard shortcut\" (value \"Control Option Space\") the baseline holds and gain an AXGroup labelled \"Control Option Space\", because the person chose Search layout A with compact keycaps (guide 16.14), the old dump being the baseline the real evidence holds; the row name \"Shortcut\" is drawn but is not an element, so no text is added")
    func s109SettingsSearchKeycapsGroup() throws {
        let rig = try Rig()
        let old = KC.read(rig.before + "/dump-settings-search.txt") ?? ""
        #expect(old.contains("AXStaticText label=\"Keyboard shortcut\" value=\"Control Option Space\"") && old.contains("AXButton label=\"Record new shortcut\"") && old.contains("AXButton label=\"Back to default\"") && old.contains("AXStaticText label=\"Open files with\"") && old.contains("AXStaticText label=\"Open Sesame with\""), "the old Search dump is not the baseline's shape, so the removal is not exercised")
        if let real = KC.read(KC.root.path + "/.ril/evidence/ui/before/dump-settings-search.txt") {
            #expect(real.contains("\n  AXStaticText label=\"Keyboard shortcut\" value=\"Control Option Space\"\n") && real.contains("\n  AXButton label=\"Record new shortcut\"\n") && real.contains("\n  AXButton label=\"Back to default\"\n") && real.contains("\n  AXStaticText label=\"Open files with\"\n") && real.contains("\n  AXStaticText label=\"Open Sesame with\"\n"), "the hand-copied baseline lines differ from .ril/evidence/ui/before/dump-settings-search.txt")
        }
        let new = rig.read("settings-Search.txt")
        #expect(new.contains("AXGroup label=\"Control Option Space\"") && !new.contains("label=\"Keyboard shortcut\"") && !new.contains("AXStaticText label=\"Control Option Space\"") && !new.contains("label=\"Shortcut\""), "the new Search dump is not the layout A one, so the addition is not exercised")
        pass(try rig.check("S10.9"), "S10.9")
    }

    @Test("S10.9 keeps the Search allowances inside dump-settings-search.txt and inside their patterns: an extra static text (also \"Shortcut\"), a missing Back to default or Open files with, a group with a child element, a new dump that still holds the old static text \"Keyboard shortcut\" or a static text or text field equal to the combination, a group with another label, and each allowance used in another dump or another old dump, each fail")
    func s109SettingsSearchStaysNarrow() throws {
        func oldAppend(_ rig: Rig, _ name: String, _ line: String) throws {
            let f = rig.before + "/" + name
            try KC.write(f, s10Append(KC.read(f) ?? "", line))
        }
        let group = "AXGroup label=\"Control Option Space\""
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("a planted extra static text", ["Planted extra label"], { try $0.edit("settings-Search.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=316,400,100,16") } }),
            ("a planted Shortcut static text", ["Shortcut"], { try $0.addLine("settings-Search.txt", "AXStaticText", "Shortcut", 216, 100, 60, 16, depth: 2) }),
            ("a planted missing Back to default", ["Back to default"], { try $0.edit("settings-Search.txt") { s10Without($0, containing: "label=\"Back to default\"") } }),
            ("a planted missing Open files with", ["Open files with"], { try $0.edit("settings-Search.txt") { s10Without($0, containing: "label=\"Open files with\"") } }),
            ("a planted missing Open Sesame with", ["Open Sesame with"], { try $0.edit("settings-Search.txt") { s10Without($0, containing: "label=\"Open Sesame with\"") } }),
            ("a planted missing pop-up", ["Media app"], { try $0.edit("settings-Search.txt") { s10Without($0, containing: "Media app") } }),
            ("a group with a child element", ["children", "W39"], { try $0.edit("settings-Search.txt") { s10InsertAfter($0, containing: group, "      AXStaticText label=\"Open files with\" frame=520,150,40,18") } }),
            ("the old static text kept in the new dump", ["Keyboard shortcut", "W39"], { try $0.edit("settings-Search.txt") { s10Append($0, "  AXStaticText label=\"Keyboard shortcut\" value=\"Control Option Space\" frame=316,400,100,16") } }),
            ("a static text equal to the combination", ["Control Option Space"], { try $0.addLine("settings-Search.txt", "AXStaticText", "Control Option Space", 300, 400, 100, 16, depth: 2) }),
            ("a text field equal to the combination", ["Control Option Space"], { try $0.addLine("settings-Search.txt", "AXTextField", "Control Option Space", 300, 400, 100, 16, depth: 2) }),
            ("a group with another label", ["Control Option Tab"], { try $0.edit("settings-Search.txt") { $0.replacingOccurrences(of: group, with: "AXGroup label=\"Control Option Tab\"") } }),
            ("the group allowance used in the Indexing dump", ["Control Option Space"], { try $0.addLine("settings-Indexing.txt", "AXGroup", "Control Option Space", 300, 400, 100, 26, depth: 2) }),
            ("the group allowance used in the Folders dump", ["Control Option Space"], { try $0.addLine("settings-Folders.txt", "AXGroup", "Control Option Space", 300, 400, 100, 26, depth: 2) }),
            ("the old static text removal used in the Indexing old dump", ["Keyboard shortcut"], { try oldAppend($0, "dump-settings-indexing.txt", "  AXStaticText label=\"Keyboard shortcut\" value=\"Control Option Space\"") }),
            ("the old static text removal used in the Setup Shortcut old dump", ["Keyboard shortcut"], { try oldAppend($0, "dump-setup-4.txt", "  AXStaticText label=\"Keyboard shortcut\" value=\"Control Option Space\"") }),
            ("the old static text removal with another value", ["Keyboard shortcut"], { try oldAppend($0, "dump-settings-search.txt", "  AXStaticText label=\"Keyboard shortcut\" value=\"Option Command K\"") }),
            ("the old static text removal as a text field", ["Keyboard shortcut"], { try oldAppend($0, "dump-settings-search.txt", "  AXTextField label=\"Keyboard shortcut\" value=\"Control Option Space\"") }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9: a new Search dump with no Record new shortcut is exit 4 through the check (settings_section needs that button as the Search marker, so the section is never read as open), and s10_diff itself fails on it, naming the button, so the removal is not allowed")
    func s109SettingsSearchMissingRecord() throws {
        let rig = try Rig()
        try rig.put("settings-Search-norecord.txt", s10Without(rig.read("settings-Search.txt"), containing: "label=\"Record new shortcut\""))
        let r = try rig.run("""
        S6_WHY=""
        s10_diff dump-settings-search.txt "\(rig.before)/dump-settings-search.txt" "\(rig.fake)/settings-Search-norecord.txt"
        echo "WHY=[$S6_WHY]"
        """)
        let why = KC.lines(r.output).first { $0.hasPrefix("WHY=") } ?? ""
        #expect(why.contains("Record new shortcut") && why.contains("lacks"), "s10_diff did not fail on a missing Record new shortcut: \(r.output.suffix(500))")
        let gone = try Rig()
        try gone.edit("settings-Search.txt") { s10Without($0, containing: "label=\"Record new shortcut\"") }
        rerun(try gone.check("S10.9"), "S10.9")
    }

    @Test("S9.2 and the recipes read the Search tab of layout A unchanged: a Search dump with the keycaps group and no \"Keyboard shortcut\" static text still holds exactly two open-with pop-ups for s9_section_2, the S9 code-wording reader finds nothing in it, settings_section finds the section by Record new shortcut, and the Search sidebar toggles are untouched")
    func s92SearchKeycapsGroupReadUnchanged() throws {
        let rig = try Rig()
        let search = rig.fake + "/settings-Search.txt"
        let dump = rig.read("settings-Search.txt")
        #expect(dump.contains("AXGroup label=\"Control Option Space\"") && !dump.contains("AXStaticText label=\"Keyboard shortcut\"") && !dump.contains("AXStaticText label=\"Control Option Space\""), "the new Search world is not the keycaps group with no static text")
        let r = try rig.run("""
        S6_DUMP="$(cat "\(search)")"; S6_WHY=""
        s9_section_2 Search
        echo "S92 why=[$S6_WHY]"
        printf '%s\\n' "$S6_DUMP" | s9_code_hits | sed 's/^/code hit /'
        printf '%s\\n' "$S6_DUMP" | settings_section_has "Search" && echo "marker yes"
        printf '%s\\n' "$S6_DUMP" | settings_section_has "Indexing" || echo "indexing marker no"
        echo "end"
        """)
        let out = KC.lines(r.output)
        #expect(out.contains("S92 why=[]"), "S9.2 did not accept the Search dump with the keycaps group: \(r.output.suffix(500))")
        #expect(!out.contains { $0.hasPrefix("code hit") } && out.contains("end"), "S9.2's code-wording reader hit the new Search dump: \(r.output.suffix(500))")
        #expect(out.contains("marker yes") && out.contains("indexing marker no"), "settings_section_has did not read the Search dump: \(r.output.suffix(500))")
    }

    @Test("S10.9 lets the Indexing section of Settings lose the AXCheckBox \"Launch at login\" (value 1 or 0) the baseline holds and gain an AXCheckBox/AXSwitch of the same label (value 1 or 0), because the person chose Indexing layout A with a system switch (guide 16.15), the old dump being the baseline the real evidence holds; the pane title, the caption, Start indexing, Delete index…, the title \"Files Sesame could not read\" and each could-not-read row (one AXStaticText labelled \"<name>, <reason>\" with the lowercase reason) are the same in both, so nothing else changes")
    func s109SettingsIndexingLaunchSwitch() throws {
        let rig = try Rig()
        let old = KC.read(rig.before + "/dump-settings-indexing.txt") ?? ""
        #expect(old.contains("AXCheckBox label=\"Launch at login\" value=\"1\"") && old.contains("AXStaticText label=\"\(s10LoginCaption)\"") && old.contains("AXButton label=\"Delete index…\"") && old.contains("AXStaticText label=\"\(s10UnreadableTitle)\"") && s10UnreadableRows.allSatisfy { old.contains("AXStaticText label=\"\($0)\"") }, "the old Indexing dump is not the baseline's shape, so the removal is not exercised")
        if let real = KC.read(KC.root.path + "/.ril/evidence/ui/before/dump-settings-indexing.txt") {
            #expect(real.contains("\n  AXCheckBox label=\"Launch at login\" value=\"1\"\n") && real.contains("\n  AXStaticText label=\"\(s10LoginCaption)\"\n") && real.contains("\n  AXButton label=\"Delete index…\"\n") && real.contains("\n  AXStaticText label=\"\(s10UnreadableTitle)\"\n") && s10UnreadableRows.allSatisfy { real.contains("\n    AXStaticText label=\"\($0)\"\n") }, "the hand-copied baseline lines differ from .ril/evidence/ui/before/dump-settings-indexing.txt")
        }
        let new = rig.read("settings-Indexing.txt")
        #expect(new.contains("AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\"") && !new.contains("AXCheckBox label=\"Launch at login\"") && s10UnreadableRows.allSatisfy { new.contains("AXStaticText label=\"\($0)\"") }, "the new Indexing dump is not the layout A one, so the addition is not exercised")
        pass(try rig.check("S10.9"), "S10.9")
        let off = try Rig()
        try off.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: "label=\"Launch at login\" value=\"1\"", with: "label=\"Launch at login\" value=\"0\"") }
        pass(try off.check("S10.9"), "S10.9")
    }

    @Test("S10.9 keeps the Indexing allowances inside dump-settings-indexing.txt and inside their patterns: a planted extra static text (also a bare \"Launch at login\", a bare name, a bare reason \"Damaged\" or \"damaged\"), a missing Delete index…, caption, title or row, a row split into two static texts or with a capitalised reason, a second switch of another label or of the same label, a switch with value 2 or none, and a new dump that still holds the plain AXCheckBox each fail; the switch addition used in the Folders, File types, Search or Setup dump, and the checkbox removal used in another old dump or with another value or label, fail too")
    func s109SettingsIndexingStaysNarrow() throws {
        func oldAppend(_ rig: Rig, _ name: String, _ line: String) throws {
            let f = rig.before + "/" + name
            try KC.write(f, s10Append(KC.read(f) ?? "", line))
        }
        let sw = "AXCheckBox/AXSwitch label=\"Launch at login\" value=\"1\""
        let cases: [(String, [String], (Rig) throws -> Void)] = [
            ("a planted extra static text", ["Planted extra label"], { try $0.edit("settings-Indexing.txt") { s10Append($0, "  AXStaticText label=\"Planted extra label\" frame=316,420,100,16") } }),
            ("a bare Launch at login static text", ["AXStaticText", "Launch at login"], { try $0.addLine("settings-Indexing.txt", "AXStaticText", "Launch at login", 211, 70, 100, 16, depth: 2) }),
            ("a bare name static text", ["broken.m4a"], { try $0.addLine("settings-Indexing.txt", "AXStaticText", "broken.m4a", 211, 420, 100, 16, depth: 2) }),
            ("a bare reason Damaged", ["Damaged"], { try $0.addLine("settings-Indexing.txt", "AXStaticText", "Damaged", 211, 420, 100, 16, depth: 2) }),
            ("a bare reason damaged", ["\"damaged\""], { try $0.addLine("settings-Indexing.txt", "AXStaticText", "damaged", 211, 420, 100, 16, depth: 2) }),
            ("a missing Delete index…", ["Delete index…"], { try $0.edit("settings-Indexing.txt") { s10Without($0, containing: "label=\"Delete index…\"") } }),
            ("a missing caption", [s10LoginCaption], { try $0.edit("settings-Indexing.txt") { s10Without($0, containing: "label=\"\(s10LoginCaption)\"") } }),
            ("a missing Files Sesame could not read", [s10UnreadableTitle], { try $0.edit("settings-Indexing.txt") { s10Without($0, containing: "label=\"\(s10UnreadableTitle)\"") } }),
            ("a missing row", ["damaged-report.pdf, damaged"], { try $0.edit("settings-Indexing.txt") { s10Without($0, containing: "label=\"damaged-report.pdf, damaged\"") } }),
            ("a row split into two static texts", ["broken.m4a, damaged"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: "AXStaticText label=\"broken.m4a, damaged\" frame=", with: "AXStaticText label=\"broken.m4a\" frame=297,425,300,16\n      AXStaticText label=\"Damaged\" frame=") } }),
            ("a row with a capitalised reason", ["broken.m4a, Damaged"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: "label=\"broken.m4a, damaged\"", with: "label=\"broken.m4a, Damaged\"") } }),
            ("a second switch of another label", ["Planted switch"], { try $0.addLine("settings-Indexing.txt", "AXCheckBox/AXSwitch", "Planted switch", 636, 420, 54, 24, flags: "value=\"1\"", depth: 2) }),
            ("a second Launch at login switch", ["Launch at login", "16.15"], { try $0.addLine("settings-Indexing.txt", "AXCheckBox/AXSwitch", "Launch at login", 636, 420, 54, 24, flags: "value=\"1\"", depth: 2) }),
            ("a switch with value 2", ["Launch at login"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: sw, with: "AXCheckBox/AXSwitch label=\"Launch at login\" value=\"2\"") } }),
            ("a switch with no value", ["Launch at login"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: sw, with: "AXCheckBox/AXSwitch label=\"Launch at login\"") } }),
            ("a new dump that still holds the plain AXCheckBox", ["plain AXCheckBox", "Launch at login", "system switch by decision", "guide 16.15"], { try $0.edit("settings-Indexing.txt") { $0.replacingOccurrences(of: "AXCheckBox/AXSwitch label=\"Launch at login\"", with: "AXCheckBox label=\"Launch at login\"") } }),
            ("the plain AXCheckBox beside the switch", ["plain AXCheckBox", "guide 16.15"], { try $0.addLine("settings-Indexing.txt", "AXCheckBox", "Launch at login", 211, 420, 100, 16, flags: "value=\"1\"", depth: 2) }),
            ("the switch addition used in the Folders dump", ["Launch at login"], { try $0.addLine("settings-Folders.txt", "AXCheckBox/AXSwitch", "Launch at login", 636, 400, 54, 24, flags: "value=\"1\"", depth: 2) }),
            ("the switch addition used in the File types dump", ["Launch at login"], { try $0.addLine("settings-File_types.txt", "AXCheckBox/AXSwitch", "Launch at login", 636, 400, 54, 24, flags: "value=\"1\"", depth: 2) }),
            ("the switch addition used in the Search dump", ["Launch at login"], { try $0.addLine("settings-Search.txt", "AXCheckBox/AXSwitch", "Launch at login", 636, 400, 54, 24, flags: "value=\"1\"", depth: 2) }),
            ("the switch addition used in the Setup Folders dump", ["Launch at login"], { try $0.addLine("setup-2.txt", "AXCheckBox/AXSwitch", "Launch at login", 300, 470, 54, 24, flags: "value=\"1\"") }),
            ("the checkbox removal used in the Search old dump", ["Launch at login"], { try oldAppend($0, "dump-settings-search.txt", "  AXCheckBox label=\"Launch at login\" value=\"1\"") }),
            ("the checkbox removal used in the Folders old dump", ["Launch at login"], { try oldAppend($0, "dump-settings-folders.txt", "  AXCheckBox label=\"Launch at login\" value=\"1\"") }),
            ("the checkbox removal used in the File types old dump", ["Launch at login"], { try oldAppend($0, "dump-settings-file-types.txt", "  AXCheckBox label=\"Launch at login\" value=\"1\"") }),
            ("the checkbox removal used in the Setup Folders old dump", ["Launch at login"], { try oldAppend($0, "dump-setup-2.txt", "  AXCheckBox label=\"Launch at login\" value=\"1\"") }),
            ("a checkbox removal with value 2 in the Indexing old dump", ["Launch at login"], { try oldAppend($0, "dump-settings-indexing.txt", "  AXCheckBox label=\"Launch at login\" value=\"2\"") }),
            ("a checkbox removal of another label in the Indexing old dump", ["Open at login"], { try oldAppend($0, "dump-settings-indexing.txt", "  AXCheckBox label=\"Open at login\" value=\"1\"") }),
            ("a disabled checkbox removal in the Indexing old dump", ["Launch at login"], { try oldAppend($0, "dump-settings-indexing.txt", "  AXCheckBox label=\"Launch at login\" value=\"1\" [disabled]") }),
        ]
        for (name, words, mutate) in cases {
            let rig = try Rig()
            try mutate(rig)
            let r = try rig.check("S10.9")
            #expect(r.verdict.hasPrefix("CHECK S10.9 FAIL") && r.rc == 1, "\(name): not a FAIL: \(r.verdict) rc \(r.rc)")
            for w in words { #expect(r.verdict.localizedCaseInsensitiveContains(w), "\(name): the FAIL line does not mention \(w): \(r.verdict)") }
        }
    }

    @Test("S10.9: a new Indexing dump with no Start indexing is exit 4 through the check (settings_section needs that button as the Indexing marker, so the section is never read as open), and s10_diff itself fails on it, naming the button, so the removal is not allowed")
    func s109SettingsIndexingMissingStart() throws {
        let rig = try Rig()
        try rig.put("settings-Indexing-nostart.txt", s10Without(rig.read("settings-Indexing.txt"), containing: "label=\"Start indexing\""))
        let r = try rig.run("""
        S6_WHY=""
        s10_diff dump-settings-indexing.txt "\(rig.before)/dump-settings-indexing.txt" "\(rig.fake)/settings-Indexing-nostart.txt"
        echo "WHY=[$S6_WHY]"
        """)
        let why = KC.lines(r.output).first { $0.hasPrefix("WHY=") } ?? ""
        #expect(why.contains("Start indexing") && why.contains("lacks"), "s10_diff did not fail on a missing Start indexing: \(r.output.suffix(500))")
        let gone = try Rig()
        try gone.edit("settings-Indexing.txt") { s10Without($0, containing: "label=\"Start indexing\"") }
        rerun(try gone.check("S10.9"), "S10.9")
    }

    @Test("S3 and S4.9 read each could-not-read row of the Indexing dump through s3_in_dump, which matches the lowercase reason: the three rows of the layout A world, each one AXStaticText labelled \"<name>, <reason>\", satisfy it, and the shape the row must not give the kit, the name \"broken.m4a\" and the capitalised reason \"Damaged\" as two static texts, does not (this is why guide 16.15.3 makes the row one element)")
    func s3InDumpReadsTheOneElementRows() throws {
        let rig = try Rig()
        try rig.put("rows-one.txt", "window 700 x 508 at 100, 50 title Settings\nAXWindow label=\"Settings\"\n  AXStaticText label=\"broken.m4a, damaged\"\n")
        try rig.put("rows-two.txt", "window 700 x 508 at 100, 50 title Settings\nAXWindow label=\"Settings\"\n  AXStaticText label=\"broken.m4a\"\n  AXStaticText label=\"Damaged\"\n")
        let r = try rig.run("""
        s3_in_dump broken.m4a damaged < "\(rig.fake)/rows-one.txt"; echo "one $?"
        s3_in_dump broken.m4a damaged < "\(rig.fake)/rows-two.txt"; echo "two $?"
        s3_in_dump broken.m4a damaged < "\(rig.fake)/settings-Indexing.txt"; echo "world-broken $?"
        s3_in_dump damaged-report.pdf damaged < "\(rig.fake)/settings-Indexing.txt"; echo "world-damaged-report $?"
        s3_in_dump locked-contract.pdf password-protected < "\(rig.fake)/settings-Indexing.txt"; echo "world-locked $?"
        s3_in_dump locked-contract.pdf password-protected < "\(rig.fake)/rows-two.txt"; echo "world-locked-absent $?"
        """)
        let out = KC.lines(r.output)
        #expect(out.contains("one 0") && out.contains("world-broken 0") && out.contains("world-damaged-report 0") && out.contains("world-locked 0"), "s3_in_dump did not read the one-element rows: \(r.output.suffix(500))")
        #expect(out.contains("two 1") && out.contains("world-locked-absent 1"), "s3_in_dump read a name and a capitalised reason as two texts: \(r.output.suffix(500))")
    }

    @Test("S9.2, S7.14 and the recipes read the Indexing tab of layout A unchanged: an Indexing dump with the Launch at login switch (AXCheckBox/AXSwitch, value 1 or 0) and the two-line rows as one static text each passes s9_section_2, the S9 code-wording reader finds nothing in it, s7_switch and ax_switch read the switch on or off whatever its subrole, and settings_section finds the section by Start indexing")
    func s92IndexingLaunchSwitchReadUnchanged() throws {
        let rig = try Rig()
        let indexing = rig.fake + "/settings-Indexing.txt"
        let dump = rig.read("settings-Indexing.txt")
        #expect(dump.contains("AXCheckBox/AXSwitch label=\"Launch at login\"") && s10UnreadableRows.allSatisfy { dump.contains("AXStaticText label=\"\($0)\"") }, "the new Indexing world is not the switch with one static text per row")
        try rig.put("indexing-off.txt", dump.replacingOccurrences(of: "label=\"Launch at login\" value=\"1\"", with: "label=\"Launch at login\" value=\"0\""))
        let r = try rig.run("""
        S6_DUMP="$(cat "\(indexing)")"; S6_WHY=""
        s9_section_2 Indexing
        s9_hits "Settings Indexing"
        echo "S92 why=[$S6_WHY]"
        printf '%s\\n' "$S6_DUMP" | s9_code_hits | sed 's/^/code hit /'
        echo "s7 $(s7_switch)"
        printf '%s\\n' "$S6_DUMP" | ax_switch "Launch at login" | sed 's/^/ax /'
        printf '%s\\n' "$S6_DUMP" | settings_section_has "Indexing" && echo "marker yes"
        printf '%s\\n' "$S6_DUMP" | settings_section_has "Search" || echo "search marker no"
        S6_DUMP="$(cat "\(rig.fake)/indexing-off.txt")"
        echo "s7 off $(s7_switch)"
        printf '%s\\n' "$S6_DUMP" | ax_switch "Launch at login" | sed 's/^/ax off /'
        echo "end"
        """)
        let out = KC.lines(r.output)
        #expect(out.contains("S92 why=[]"), "S9.2 did not accept the Indexing dump with the switch: \(r.output.suffix(500))")
        #expect(!out.contains { $0.hasPrefix("code hit") } && out.contains("end"), "S9.2's code-wording reader hit the new Indexing dump: \(r.output.suffix(500))")
        #expect(out.contains("s7 on") && out.contains("ax on") && out.contains("s7 off off") && out.contains("ax off off"), "s7_switch or ax_switch did not read the switch on and off: \(r.output.suffix(500))")
        #expect(out.contains("marker yes") && out.contains("search marker no"), "settings_section_has did not read the Indexing dump: \(r.output.suffix(500))")
    }

    @Test("the Folders row of layout B is read unchanged by the row readers S6.4 uses: ax_rows lists each folder once from its checkbox, ax_row_detail gives the breakdown after the name, and ax_row_block holds the checkbox and the more button of that row and nothing of the next, so no count is read from the more button")
    func settingsFoldersRowReaders() throws {
        let rig = try Rig()
        let dump = rig.read("settings-Folders.txt")
        let rows = outAndRc(h("ax_rows", dump))
        #expect(rows.rc == 0 && rows.lines.count == 3 && rows.lines.map { $0.components(separatedBy: "\t")[1] } == ["Desktop", "Documents", "api-client"], "ax_rows read \(rows.lines)")
        let detail = outAndRc(h("ax_row_detail Documents", dump))
        #expect(detail.rc == 0 && detail.lines == ["2 photos, about 1 min"], "ax_row_detail read \(detail.lines)")
        let block = outAndRc(h("ax_row_block Desktop", dump))
        #expect(block.rc == 0 && block.lines.count == 2 && block.lines[0].contains("AXCheckBox label=\"Desktop\"") && block.lines[1].contains("label=\"More actions for Desktop\"") && !block.lines.joined().contains("Documents"), "ax_row_block read \(block.lines)")
    }

    @Test("S10.9 is NEEDS-A-PERSON when the kept old dumps are missing or an old dump was cut, and exit 4 when a new dump cannot be read")
    func s109Person() throws {
        let none = try Rig()
        try FileManager.default.removeItem(atPath: none.before)
        person(try none.check("S10.9"), "S10.9", mentions: "old")
        let one = try Rig()
        try FileManager.default.removeItem(atPath: one.before + "/dump-menu.txt")
        person(try one.check("S10.9"), "S10.9", mentions: "dump-menu.txt")
        let old = try Rig()
        try KC.write(old.before + "/dump-panel-empty.txt", (KC.read(old.before + "/dump-panel-empty.txt") ?? "") + "(tree cut at 600 elements)\n")
        person(try old.check("S10.9"), "S10.9", mentions: "cut")
        let gone = try Rig()
        gone.remove("setup-4.txt")
        rerun(try gone.check("S10.9"), "S10.9")
        let state = try Rig()
        rerun(try state.check("S10.9", pre: "GOLDEN_RC=4"), "S10.9")
    }

    @Test("every S10 check, run with --plant, prints CHECK <id> FAIL planted and exits 1")
    func plants() throws {
        for id in ids {
            let rig = try s108Rig()
            try rig.put(s10World(old: false, long: true, root: rig.kit))
            for (name, dump) in [("panel-failed.txt", rig.read("panel-failed.txt"))] { try rig.put(name, dump) }
            if id == "S10.7" {
                for name in ["setup-2.txt", "settings-Folders.txt", "panel-zqlongfile.txt"] {
                    try rig.edit(name) { $0.replacingOccurrences(of: s10LongFolder, with: String(s10LongFolder.prefix(40)) + "…").replacingOccurrences(of: s10LongFile, with: String(s10LongFile.prefix(40)) + "…") }
                }
            }
            let r = try rig.check(id, plant: true)
            #expect(r.verdict.hasPrefix("CHECK \(id) FAIL planted") && r.rc == 1, "\(id) --plant: rc \(r.rc), \(r.verdict) \(r.output.suffix(500))")
        }
    }

    @Test("a failed driver call prints the driver's output and the check ends exit 4, in each of the nine checks")
    func driverOutputPrinted() throws {
        for id in ids {
            let rig = try s108Rig()
            let fn = "check_" + id.replacingOccurrences(of: ".", with: "_")
            let r = try rig.run("""
            kq() { echo "driver says boom"; return 1; }
            \(fn) </dev/null; echo "RC $?"
            """)
            #expect(r.output.contains("driver says boom"), "\(id): the driver's output was not printed: \(r.output.suffix(400))")
            #expect(!r.output.contains("CHECK \(id) FAIL") && !r.output.contains("CHECK \(id) PASS") && r.output.contains("RC 4"), "\(id): a driver failure was not a RERUN: \(r.output.suffix(400))")
        }
    }

    @Test("a fake 1,300-element tree: the dump's cut line fails S10.9 and makes the geometry checks exit 4; the old kit's own 600 limit in an old dump is a person's")
    func budget() throws {
        let rig = try Rig()
        let many = (0..<1300).map { "  AXStaticText label=\"e\($0)\" frame=\(100 + $0 % 300),\(50 + $0 / 3),10,10" }.joined(separator: "\n")
        try rig.edit("settings-Indexing.txt") { $0 + many + "\n(tree cut at 1200 elements)\n" }
        fail(try rig.check("S10.9"), "S10.9", mentions: "1200")
        rerun(try rig.check("S10.3"), "S10.3")
    }
}

private func s10Unframed(_ text: String, _ needle: String) -> String {
    text.components(separatedBy: "\n").map { l in
        guard l.contains(needle), let r = l.range(of: " frame=") else { return l }
        return String(l[..<r.lowerBound])
    }.joined(separator: "\n")
}

private func s10InsertAfter(_ text: String, containing needle: String, _ line: String) -> String {
    var done = false
    return text.components(separatedBy: "\n").map { l in
        if !done && l.contains(needle) { done = true; return l + "\n" + line }
        return l
    }.joined(separator: "\n")
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
