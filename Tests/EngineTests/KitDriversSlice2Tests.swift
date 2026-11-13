import Foundation
import Testing

// plan-2-t10, tester step: kit part 6, the launch driver (scripts/kit-launch.sh) and the accessibility driver
// (scripts/kit-ax.sh with scripts/kit-lib/ax.applescript) for the menu bar, setup and Settings. Written from
// verify.md (Surfaces and drivers, Kit scripts), the S1, S6 and S7 feature maps and the plan-2-t10 entry only; no
// product source is read, and neither script may read `Sources/`.
//
// Static proof only (plan-2-tasks.md, Conventions; the person's ruling "no app launch"): these two scripts start or
// drive the app, so NOTHING here executes either of them, not even with no mode. The only run is `bash -n` on each.
// Every other check reads the text of `scripts/kit-ax.sh`, `scripts/kit-launch.sh` and `scripts/kit-lib/ax.applescript`.
// What a text check reads is the code with its comment lines removed (`#` in shell, `--` in AppleScript), so a
// comment can never satisfy a check. Real behaviour is driven against the live app at the accept stage only.
//
// The contract read here (plan-2-t10, Tests):
//   - kit-ax.sh: `read menubar` (the status item's accessibility label), `dump menu` (the open menu's items with their
//     enabled state; no longer "not built yet"), `dump setup`, `dump settings`, `click "<label>"` reaching the status
//     item's menu items and the Settings controls by their visible label, `tab-walk settings|setup|menu`, `shot` of one
//     window by id; `click` never falls back to a screen position; an open menu is closed after a read; `key` and `type`
//     stay posted only while `frontmost` reads Sesame (the plan-1 guard text is unchanged); `type` honours
//     KIT_TYPE_DELAY_MS;
//   - kit-launch.sh: `start`, `quit`, `kill9 <app|encode|index>`, `freeze index`, `thaw index`, `pids [--names]`,
//     `relaunch` as plan 1 built them, and no new launch setting: HOME, SESAME_MODEL_HOST, SESAME_PROBE_FILE and
//     SESAME_FAKE_EMBEDDER are the only environment names the kit sets for the app.
// Red before the kit part: the new `dump menu`, `tab-walk menu` and menu-item `click` modes are missing.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let axName = "kit-ax.sh"
private let launchName = "kit-launch.sh"
private let asName = "kit-lib/ax.applescript"
private let bothScripts = [axName, launchName]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs a program that is not a kit script (only `/bin/bash -n` is run here).
private func run(_ exe: String, _ args: [String], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitdrv-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
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
    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    return Ran(status: status, output: text)
}

/// The path of scripts/<name>, or nil after recording the reason a missing file is red.
private func scriptPath(_ name: String) -> String? {
    let url = projectRoot.appendingPathComponent("scripts").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record("scripts/\(name) not found")
        return nil
    }
    return url.path
}

/// A shell script's code: every line that is not a comment (the shebang line is dropped too).
private func code(of name: String) -> String? {
    guard let path = scriptPath(name), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

/// The AppleScript's code: every line that is not a `--` comment.
private func appleScriptCode() -> String? {
    guard let path = scriptPath(asName), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        .joined(separator: "\n")
}

private func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

/// An expectation on a script's text. It records only the message on failure, never the whole script.
private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

/// The offset of the first match of the pattern, or nil.
private func firstIndex(_ text: String, _ pattern: String) -> Int? {
    guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
    return text.distance(from: text.startIndex, to: r.lowerBound)
}

/// Every first capture group of the pattern in the text.
private func captures(_ text: String, _ pattern: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
    }
}

/// The shell functions of a script: name to body, read from `name() {` to a line that is just `}`.
private func shellFunctions(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if let n = captures(line, "^([A-Za-z_][A-Za-z0-9_]*)\\(\\) \\{( #.*)?$").first {
                name = n
                body = []
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

/// `body` with every call to a function of the same script replaced, in place, by that function's own code
/// (a call inside a function is read as if written where it stands). Depth is capped.
private func expandShell(_ body: String, _ functions: [String: String], skipping: String = "", depth: Int = 0) -> String {
    guard depth < 5 else { return body }
    var out: [String] = []
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        out.append(line)
        for other in functions.keys.sorted() where other != skipping {
            if has(line, "(^|[^A-Za-z0-9_.-])\(NSRegularExpression.escapedPattern(for: other))([^A-Za-z0-9_.-]|$)") {
                out.append(expandShell(functions[other] ?? "", functions, skipping: other, depth: depth + 1))
            }
        }
    }
    return out.joined(separator: "\n")
}

private func expandedFunction(_ name: String, _ functions: [String: String]) -> String {
    guard let body = functions[name] else { return "" }
    return expandShell(body, functions, skipping: name)
}

/// Does the dispatch (`case` of main) have a line for the mode: `<mode>)` or `<mode>|...)` or `...|<mode>)`?
private func dispatches(_ mode: String, in text: String) -> Bool {
    let marker = "(^|[ \\t|(])\(NSRegularExpression.escapedPattern(for: mode))[|)]"
    return text.split(separator: "\n").map(String.init).contains { has($0, marker) }
}

/// The function a mode's dispatch line calls: the last word on the line that is a function of the script.
private func dispatchTarget(_ mode: String, in text: String, functions: [String: String]) -> String? {
    let marker = "(^|[ \\t|(])\(NSRegularExpression.escapedPattern(for: mode))[|)]"
    for line in text.split(separator: "\n").map(String.init) where has(line, marker) {
        let words = line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
        if let target = words.last(where: { functions[$0] != nil }) { return target }
    }
    return nil
}

/// The lines of a `case` branch inside a function body: from the line that opens `<label>)` to the line with `;;`.
private func caseBranch(_ label: String, in body: String) -> String? {
    let open = "^[ \\t]*(([A-Za-z0-9_-]+\\|)*)\(NSRegularExpression.escapedPattern(for: label))(\\|[A-Za-z0-9_|-]+)?\\)"
    var found: [String] = []
    var inside = false
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if !inside, has(line, open) { inside = true }
        if inside {
            found.append(line)
            if line.contains(";;") { break }
        }
    }
    return inside ? found.joined(separator: "\n") : nil
}

/// The usage lines of a script: the trimmed lines of its `usage` function.
private func usageLines(_ functions: [String: String]) -> [String] {
    (functions["usage"] ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

// MARK: AppleScript structure

private struct ASBranch {
    let names: [String]
    let body: String
}

/// The top-level branches of `on run argv`: each `if cmd is "x" [or cmd is "y"]` / `else if ...` up to the next one
/// or the final `else` (one tab deep).
private func appleScriptBranches(_ text: String) -> [ASBranch] {
    var branches: [ASBranch] = []
    var names: [String] = []
    var body: [String] = []
    var open = false
    func close() {
        if open { branches.append(ASBranch(names: names, body: body.joined(separator: "\n"))) }
        open = false
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("\t"), !line.hasPrefix("\t\t"), has(trimmed, "^(else )?if cmd is \"") {
            close()
            names = captures(trimmed, "cmd is \"([a-z]+)\"")
            body = [line]
            open = true
        } else if line == "\telse" {
            close()
        } else if open {
            body.append(line)
        }
    }
    close()
    return branches
}

/// AppleScript handlers (`on name(args)` ... `end name`), other than `run`.
private func appleScriptHandlers(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if let n = captures(line, "^on ([A-Za-z_][A-Za-z0-9_]*)\\(").first, n != "run" {
                name = n
                body = []
            }
        } else if line.hasPrefix("end \(name!)") {
            result[name!] = body.joined(separator: "\n")
            name = nil
        } else {
            body.append(line)
        }
    }
    return result
}

/// The branch text with every handler it calls (`my name(`) written in where it is called.
private func expandAppleScript(_ body: String, _ handlers: [String: String], depth: Int = 0) -> String {
    guard depth < 5 else { return body }
    var out: [String] = []
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        out.append(line)
        for name in captures(line, "my ([A-Za-z_][A-Za-z0-9_]*)\\(") {
            if let h = handlers[name] { out.append(expandAppleScript(h, handlers, depth: depth + 1)) }
        }
    }
    return out.joined(separator: "\n")
}

/// What the shell code of `cmd_dump`'s `menu)` branch asks System Events for: the `osa <command>` names it calls,
/// after the functions it calls are written in. nil (and a recorded reason) when there is no `menu)` branch.
private func dumpMenuBranch() -> (shell: String, osaCommands: [String])? {
    guard let text = code(of: axName) else { return nil }
    let functions = shellFunctions(in: text)
    guard let dump = functions["cmd_dump"], let branch = caseBranch("menu", in: dump) else {
        Issue.record("cmd_dump of kit-ax.sh has no `menu)` branch")
        return nil
    }
    let expanded = expandShell(branch, functions)
    return (expanded, captures(expanded, "(?:^|[^A-Za-z0-9_.-])osa[ \\t]+([A-Za-z][A-Za-z0-9_-]*)"))
}

/// The AppleScript those `osa` commands run, each branch with its handlers written in.
private func appleScriptFor(_ commands: [String]) -> String? {
    guard let text = appleScriptCode() else { return nil }
    let handlers = appleScriptHandlers(text)
    let branches = appleScriptBranches(text)
    var union: [String] = []
    for command in commands {
        guard let branch = branches.first(where: { $0.names.contains(command) }) else {
            Issue.record("kit-ax.sh calls `osa \(command)` but ax.applescript has no `cmd is \"\(command)\"` branch")
            continue
        }
        union.append(expandAppleScript(branch.body, handlers))
    }
    return union.joined(separator: "\n")
}

/// The shell branch of `dump menu` and the AppleScript it runs; records why when `dump menu` asks for nothing.
private func dumpMenuParts() -> (shell: String, script: String)? {
    guard let (shell, commands) = dumpMenuBranch() else { return nil }
    guard !commands.isEmpty else {
        Issue.record("`dump menu` never asks System Events for anything (no `osa <command>` in its branch)")
        return nil
    }
    guard let script = appleScriptFor(commands) else { return nil }
    return (shell, script)
}

@Suite("KitDriversSlice2Tests")
struct KitDriversSlice2Tests {

    // MARK: the files themselves

    @Test("the script exists, is executable and is a bash script (the kit is bash 3.2)", arguments: bothScripts)
    func existsExecutableBash(_ name: String) throws {
        guard let path = scriptPath(name) else { return }
        #expect(FileManager.default.isExecutableFile(atPath: path), "scripts/\(name) is not executable")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/bash\n"), "scripts/\(name) line 1 is not #!/bin/bash (the kit is bash 3.2)")
    }

    @Test("bash -n finds no syntax error in the two scripts (neither is run)", arguments: bothScripts)
    func bashSyntax(_ name: String) throws {
        guard let path = scriptPath(name) else { return }
        let ran = try run("/bin/bash", ["-n", path])
        #expect(ran.status == 0, "bash -n scripts/\(name) exited \(ran.status): \(ran.output)")
        #expect(ran.output.isEmpty, "bash -n scripts/\(name) printed: \(ran.output)")
    }

    @Test("no kit-ax or kit-launch file reads Sources/", arguments: [axName, launchName, asName])
    func neverReadsSources(_ name: String) throws {
        let text = name == asName ? appleScriptCode() : code(of: name)
        guard let text else { return }
        ok(!text.contains("Sources"), "scripts/\(name) names Sources: the kit never reads the product's source")
    }

    @Test("both scripts keep the kit's style: common.sh sourced and output saved through kit_wrap", arguments: bothScripts)
    func kitStyle(_ name: String) throws {
        guard let text = code(of: name) else { return }
        ok(text.contains("kit-lib/common.sh"), "scripts/\(name) does not source kit-lib/common.sh")
        ok(has(text, "\\bkit_wrap\\b"), "scripts/\(name) does not save its output through kit_wrap")
    }

    // MARK: kit-ax.sh keeps every plan-1 mode

    @Test("kit-ax.sh keeps every plan-1 mode in its dispatch",
          arguments: ["ping", "frontmost", "appearance", "shot", "kitwindow", "hotkey", "key", "type", "paste", "click",
                      "front-sesame", "gotofolder", "read", "dump", "tab-walk", "fullscreen"])
    func axKeepsPlan1Modes(_ mode: String) throws {
        guard let text = code(of: axName) else { return }
        ok(dispatches(mode, in: text), "kit-ax.sh lost its `\(mode)` mode: the dispatch has no line for it")
    }

    @Test("kit-ax.sh usage names the modes of verify.md: read, click, shot and the new dump and tab-walk windows")
    func axUsageNamesModes() throws {
        guard let text = code(of: axName) else { return }
        let usage = usageLines(shellFunctions(in: text))
        guard !usage.isEmpty else {
            Issue.record("kit-ax.sh has no usage function")
            return
        }
        func line(_ prefix: String) -> String? { usage.first { $0.hasPrefix(prefix) } }
        let word = { (w: String) in "(^|[ \\t|])\(w)($|[ \\t|])" }

        if let read = line("kit-ax.sh read ") {
            for w in ["panel", "windows", "focus", "menubar"] { ok(has(read, word(w)), "usage of `read` does not name \(w): \(read)") }
        } else { Issue.record("usage has no `kit-ax.sh read ...` line") }

        if let dump = line("kit-ax.sh dump ") {
            for w in ["panel", "setup", "settings", "menu", "menubar", "window"] {
                ok(has(dump, word(w)), "usage of `dump` does not name `\(w)` (verify.md: dump <panel|menubar|menu|settings|setup|window \"<title>\">): \(dump)")
            }
        } else { Issue.record("usage has no `kit-ax.sh dump ...` line") }

        if let walk = line("kit-ax.sh tab-walk ") {
            for w in ["panel", "setup", "settings", "menu", "window"] {
                ok(has(walk, word(w)), "usage of `tab-walk` does not name `\(w)` (plan-2-t10: tab-walk settings|setup|menu): \(walk)")
            }
        } else { Issue.record("usage has no `kit-ax.sh tab-walk ...` line") }

        ok(usage.contains { has($0, "^kit-ax\\.sh click \"<label>\"") }, "usage has no `kit-ax.sh click \"<label>\"` line")
        ok(usage.contains { has($0, "^kit-ax\\.sh shot <name>") }, "usage has no `kit-ax.sh shot <name> ...` line")
        ok(usage.contains { has($0, "^kit-ax\\.sh type \"<text>\" \\[--delay-ms N\\]") }, "usage of `type` lost `[--delay-ms N]`")
        ok(usage.contains { $0.contains("KIT_TYPE_DELAY_MS") }, "usage no longer names KIT_TYPE_DELAY_MS")
    }

    // MARK: read menubar

    @Test("kit-ax.sh read menubar prints the status item's label, and says `no status item` when there is none")
    func readMenubar() throws {
        guard let text = code(of: axName), let script = appleScriptCode() else { return }
        let functions = shellFunctions(in: text)
        guard let read = functions["cmd_read"], let branch = caseBranch("menubar", in: read) else {
            Issue.record("cmd_read of kit-ax.sh has no `menubar)` branch")
            return
        }
        ok(has(branch, "osa[ \\t]+statusitems"), "`read menubar` does not read the status items through `osa statusitems`")
        ok(branch.contains("status item: "), "`read menubar` does not print `status item: <label>`")
        ok(branch.contains("no status item"), "`read menubar` does not say `no status item` when there is none")
        let branches = appleScriptBranches(script)
        let reader = branches.first { $0.names.contains("statusitems") }
        ok(reader != nil, "ax.applescript has no `statusitems` command")
        if let reader {
            let body = expandAppleScript(reader.body, appleScriptHandlers(script))
            ok(body.contains("menu bar 2"), "`statusitems` does not read the status items (menu bar 2 of the process)")
            ok(has(body, "labelOf|AXDescription|AXTitle"), "`statusitems` does not read each item's accessibility label")
        }
    }

    // MARK: dump menu

    @Test("kit-ax.sh dump menu is built: it is no longer `not built yet`, and it asks System Events for a command that exists")
    func dumpMenuIsBuilt() throws {
        guard let (shell, commands) = dumpMenuBranch() else { return }
        ok(!shell.contains("not built yet"), "`dump menu` still says `not built yet`")
        ok(!commands.isEmpty, "`dump menu` never asks System Events for anything (no `osa <command>` in its branch)")
        _ = appleScriptFor(commands)
    }

    @Test("dump menu opens the status item's menu by pressing the status item, then lists its items")
    func dumpMenuOpensAndLists() throws {
        guard let (_, script) = dumpMenuParts() else { return }
        ok(script.contains("menu bar 2"), "the menu command does not start from the status items (menu bar 2 of the process)")
        ok(has(script, "AXPress|AXShowMenu"), "the menu command never presses or opens the status item (AXPress or AXShowMenu)")
        ok(has(script, "menu items? of|menu 1 of|AXMenu\\b"), "the menu command never reads the items of the status item's menu")
    }

    @Test("dump menu prints each item's enabled state, so a disabled item reads as disabled")
    func dumpMenuShowsEnabledState() throws {
        guard let (_, script) = dumpMenuParts() else { return }
        ok(has(script, "AXEnabled|dumpTree"), "the menu command does not read AXEnabled of each item (it prints no enabled state)")
    }

    @Test("an open menu is closed with Esc after a read (AXCancel or the guarded Esc key), never left open")
    func dumpMenuClosesAfterRead() throws {
        guard let (shell, script) = dumpMenuParts() else { return }
        let closes = has(script, "AXCancel") || has(shell, "(?i)(^|[^A-Za-z])esc(ape)?([^A-Za-z]|$)")
        ok(closes, "`dump menu` never closes the menu it opened: no AXCancel in the AppleScript and no Esc in the shell branch")
    }

    @Test("no key is posted from AppleScript: keys go only through the guarded key tool")
    func noKeysFromAppleScript() throws {
        guard let script = appleScriptCode() else { return }
        ok(!has(script, "\\bkeystroke\\b|\\bkey code\\b|\\bkey down\\b|\\bkey up\\b"),
           "ax.applescript posts a key straight to the frontmost app, past the guard (verify.md: keys only while Sesame is frontmost)")
    }

    // MARK: dump setup, dump settings

    @Test("dump setup and dump settings are accepted by kit-ax.sh and picked by their windows in ax.applescript",
          arguments: ["setup", "settings"])
    func dumpSetupSettings(_ kind: String) throws {
        guard let text = code(of: axName), let script = appleScriptCode() else { return }
        let functions = shellFunctions(in: text)
        let accepted = (functions["window_args"] ?? "") + (functions["cmd_dump"] ?? "")
        ok(has(accepted, "(^|[ \\t|])\(kind)([|)]| )"), "kit-ax.sh does not accept `dump \(kind)`")
        ok(has(script, "wkind is \"\(kind)\""), "ax.applescript has no window pick for `\(kind)`")
        let branches = appleScriptBranches(script)
        ok(branches.contains { $0.names.contains("dump") }, "ax.applescript has no `dump` command")
        guard let dump = functions["cmd_dump"] else { return }
        ok(has(dump, "osa[ \\t]+dump"), "`dump \(kind)` does not read the window's element tree through `osa dump`")
    }

    // MARK: click

    @Test("click reaches the status item's menu items as well as window controls, by visible label, and needs no window to start")
    func clickReachesMenuItems() throws {
        guard let text = code(of: axName), let script = appleScriptCode() else { return }
        let functions = shellFunctions(in: text)
        let click = expandedFunction("cmd_click", functions)
        ok(!click.isEmpty, "kit-ax.sh has no cmd_click")
        ok(has(click, "osa[ \\t]+click"), "`click` does not press through `osa click`")
        ok(!has(click, "(^|[^A-Za-z0-9_.-])need_window([^A-Za-z0-9_.-]|$)"),
           "`click` needs an on-screen window before it starts, so a menu item (the menu bar holds no window) can never be pressed")
        guard let branch = appleScriptBranches(script).first(where: { $0.names.contains("click") }) else {
            Issue.record("ax.applescript has no `click` command")
            return
        }
        let body = expandAppleScript(branch.body, appleScriptHandlers(script))
        ok(body.contains("menu bar 2"), "`click` never looks at the status item's menu (menu bar 2), so \"Pause indexing\", \"Resume indexing\", \"Open Sesame\", \"Settings…\", \"Quit Sesame\" are unreachable")
        ok(has(body, "menu items? of|menu 1 of|AXMenu\\b"), "`click` never reads the items of the status item's menu")
        ok(body.contains("AXPress"), "`click` does not press the element (AXPress)")
        ok(has(body, "considering case"), "`click` does not compare the label exactly (considering case)")
        ok(has(body, "windows? of process|window i of process"), "`click` no longer looks through the app's windows for Settings and setup controls")
    }

    @Test("click never falls back to a screen position")
    func clickNeverUsesPosition() throws {
        guard let text = code(of: axName), let script = appleScriptCode() else { return }
        let click = expandedFunction("cmd_click", shellFunctions(in: text))
        ok(!has(click, "cliclick|\\bmouse\\b|CGEvent|\\bclick at\\b|--position|\\bposition\\b"), "kit-ax.sh `click` uses a position or a mouse event")
        guard let branch = appleScriptBranches(script).first(where: { $0.names.contains("click") }) else { return }
        let body = expandAppleScript(branch.body, appleScriptHandlers(script))
        ok(!has(body, "\\bclick at\\b|\\bposition of\\b|\\bmouse\\b|\\{[ ]*[0-9-]+[ ]*,[ ]*[0-9-]+[ ]*\\}"),
           "the AppleScript `click` command clicks at a screen position")
        ok(!has(script, "\\bclick at\\b"), "ax.applescript has a `click at` (a coordinate click)")
    }

    // MARK: tab-walk

    @Test("tab-walk takes settings, setup and menu as well as panel and window, and still checks the focus before every Tab",
          arguments: ["settings", "setup", "menu"])
    func tabWalkWindows(_ kind: String) throws {
        guard let text = code(of: axName) else { return }
        let functions = shellFunctions(in: text)
        let accepted = (functions["window_args"] ?? "") + (functions["cmd_tab_walk"] ?? "")
        ok(has(accepted, "(^|[ \\t|])\(kind)([|)]| )"), "kit-ax.sh does not accept `tab-walk \(kind)`")
    }

    @Test("tab-walk menu reaches the menu: it asks System Events for a command that exists in ax.applescript")
    func tabWalkMenuReachesMenu() throws {
        guard let text = code(of: axName) else { return }
        let functions = shellFunctions(in: text)
        let walk = (functions["cmd_tab_walk"] ?? "") + "\n" + (functions["window_args"] ?? "")
        ok(has(walk, "(^|[^A-Za-z])menu([^A-Za-z]|$)"), "`tab-walk` never mentions the menu: it cannot walk it")
        let commands = captures(walk, "(?:^|[^A-Za-z0-9_.-])osa[ \\t]+([A-Za-z][A-Za-z0-9_-]*)")
        guard let script = appleScriptFor(commands) else { return }
        ok(script.contains("menu bar 2"), "the System Events commands `tab-walk` uses never reach the status item's menu (menu bar 2), so `tab-walk menu` has nothing to walk")
    }

    @Test("tab-walk keeps its guard: Sesame must be frontmost before the walk and re-read before every key it posts")
    func tabWalkKeepsGuard() throws {
        guard let text = code(of: axName) else { return }
        let walk = shellFunctions(in: text)["cmd_tab_walk"] ?? ""
        ok(walk.contains("need_frontmost_window"), "tab-walk no longer calls need_frontmost_window before the walk")
        ok(walk.contains("the frontmost app became $FRONT_NAME, so the walk stopped before posting Tab"), "tab-walk lost its refusal line (the focus moved mid-walk)")
        if let reread = firstIndex(walk, "read_front"), let post = firstIndex(walk, "\"\\$bin\" key"), let check = firstIndex(walk, "front_is_sesame") {
            ok(reread < post && check < post, "tab-walk no longer re-reads who is frontmost before it posts a key")
        } else {
            Issue.record("tab-walk no longer reads `frontmost` (read_front, front_is_sesame) before posting a key")
        }
    }

    // MARK: key and type: the plan-1 guard is untouched

    @Test("the plan-1 typing guard text is still present, word for word")
    func guardTextPresent() throws {
        guard let text = code(of: axName) else { return }
        let lines = [
            "refused: the frontmost Sesame (pid $FRONT_PID) is not the copy the kit started ($KIT_APP); no key was posted",
            "refused: Sesame is not the frontmost app (the frontmost app is $FRONT_NAME); no key was posted",
            "(a $AX_APP window is on screen, but the frontmost app is $FRONT_NAME, so the keys would reach it; nothing was posted)",
            "refused: no pid of the $AX_APP target to re-check while typing; nothing was posted",
            "type stopped: the target was no longer the frontmost app, so no more keys were posted",
            "paste stopped: the target was no longer the frontmost app, so Command+V was not posted",
            "refused: Sesame is not the frontmost app (the frontmost app is $FRONT_NAME); the Go to field was not set",
        ]
        for line in lines { ok(text.contains(line), "the guard text is gone or changed: \(line)") }
        let functions = shellFunctions(in: text)
        for name in ["guard_key", "guard_hotkey", "need_frontmost_window", "front_is_sesame", "front_is_kitwindow", "read_front"] {
            ok(functions[name] != nil, "the guard function `\(name)` is gone")
        }
    }

    @Test("key posts only after guard_key; type and paste only after need_frontmost_window; type re-checks by pid")
    func guardsRunBeforeKeys() throws {
        guard let text = code(of: axName) else { return }
        let functions = shellFunctions(in: text)
        func before(_ fn: String, _ guardName: String, _ post: String) {
            let body = functions[fn] ?? ""
            guard let g = firstIndex(body, "(^|[^A-Za-z0-9_.-])\(guardName)([^A-Za-z0-9_.-]|$)"),
                  let p = firstIndex(body, post) else {
                Issue.record("\(fn) does not call \(guardName) before it posts (\(post))")
                return
            }
            ok(g < p, "\(fn) posts before it has called \(guardName)")
        }
        before("cmd_key", "guard_key", "\"\\$bin\" key")
        before("cmd_type", "need_frontmost_window", "\"\\$bin\" type")
        before("cmd_paste", "need_frontmost_window", "\"\\$bin\" key")
        ok((functions["cmd_type"] ?? "").contains("--front-pids"), "type no longer hands the key tool the pids to re-check (--front-pids)")
    }

    @Test("every key-tool post in kit-ax.sh sits in a function that runs a frontmost guard first")
    func everyPostIsGuarded() throws {
        guard let text = code(of: axName) else { return }
        let functions = shellFunctions(in: text)
        // close_menu is the one exception since commit 080db8e: an open status item menu takes Esc whichever app is
        // frontmost, and the menu is the kit's own Sesame's (found open by `osa menuopen` just before). The test below
        // pins what stands in the place of the guard, so it is exempt here and nowhere else.
        for (name, body) in functions.sorted(by: { $0.key < $1.key }) where name != "close_menu" && has(body, "\"\\$bin\" (key|type)\\b") {
            let guarded = has(body, "guard_key|guard_hotkey|need_frontmost_window|front_is_sesame|front_is_kitwindow")
            ok(guarded, "\(name) posts a key or typed text with no frontmost guard in it")
        }
    }

    @Test("close_menu posts Esc to a menu it found open, whichever app is frontmost: no frontmost guard, the menu read first, and read again after")
    func closeMenuHasNoFrontmostGuard() throws {
        guard let text = code(of: axName) else { return }
        let body = shellFunctions(in: text)["close_menu"] ?? ""
        ok(!body.isEmpty, "kit-ax.sh has no close_menu")
        // the old behaviour is gone: no guard of any kind, and no note that Esc was not posted for want of Sesame in front
        ok(!has(body, "guard_key|guard_hotkey|need_frontmost_window|front_is_sesame|front_is_kitwindow|read_front"), "close_menu still runs a frontmost guard before it posts Esc")
        ok(!body.contains("Esc was not posted"), "close_menu still says Esc was not posted because Sesame is not frontmost")
        // the accessibility cancel comes first, then the menu is read open, and only an open menu gets the key
        let cancel = firstIndex(body, "osa[ ]+menuclose")
        let open = firstIndex(body, "osa[ ]+menuopen")
        let esc = firstIndex(body, "\"\\$bin\"[ ]+key[ ]+esc")
        ok(cancel != nil && open != nil && esc != nil, "close_menu lacks the accessibility cancel (menuclose), the open read (menuopen) or the Esc post (`key esc`)")
        if let c = cancel, let o = open, let e = esc {
            ok(c < o && o < e, "close_menu does not run menuclose, then read the menu open (menuopen), then post Esc")
            // a menu not found open is left alone: the return sits between the read and the post
            let between = String(body.dropFirst(o).prefix(e - o))
            ok(has(between, "OSA_OUT[^\\n]*=[ ]*1[^\\n]*\\|\\|[ ]*return 0"), "close_menu posts Esc even when the menu was not found open")
            // after the key the menu is read once more, and a menu still open is noted, never hidden
            let after = String(body.dropFirst(e))
            ok(has(after, "osa[ ]+menuopen"), "close_menu does not read the menu again after the Esc")
        }
        ok(body.contains("the status item menu is still open after a posted Esc"), "close_menu does not note a menu that is still open after the Esc")
        ok(body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("return 0"), "close_menu must end with return 0 so the caller never fails on it")
    }

    @Test("type honours KIT_TYPE_DELAY_MS (0 to 500 ms, an invalid value ignored with a warning, else 10 ms) unless --delay-ms is given")
    func typeHonoursDelay() throws {
        guard let text = code(of: axName) else { return }
        let type = shellFunctions(in: text)["cmd_type"] ?? ""
        ok(type.contains("KIT_TYPE_DELAY_MS"), "`type` does not read KIT_TYPE_DELAY_MS")
        ok(type.contains("--delay-ms"), "`type` lost --delay-ms")
        ok(has(type, "delay=10"), "`type` lost its 10 ms default")
        ok(has(type, "-le 500"), "`type` lost the 500 ms ceiling")
        ok(type.contains("is not a whole number of ms from 0 to 500; ignored, typing at 10 ms"), "`type` lost its warning for an invalid KIT_TYPE_DELAY_MS")
    }

    @Test("type posts nothing but the key tool's `type`: no F6 press and no other key call before it, after the same guard and with the pids handed over")
    func typePostsNoF6() throws {
        guard let text = code(of: axName) else { return }
        let type = shellFunctions(in: text)["cmd_type"] ?? ""
        ok(!type.isEmpty, "kit-ax.sh has no cmd_type")
        ok(!has(type, "\\b[Ff]6\\b"), "cmd_type still names F6: the stuck modifiers are cleared inside the key tool, not by a key press")
        ok(!has(type, "\"\\$bin\"[ \\t]+key\\b"), "cmd_type still posts a key call besides the typed text")
        ok(captures(type, "\"\\$bin\"[ \\t]+(key|type)\\b").count == 1, "cmd_type must post exactly once, the key tool's `type`")
        let guardAt = firstIndex(type, "(^|[^A-Za-z0-9_.-])need_frontmost_window([^A-Za-z0-9_.-]|$)")
        let postAt = firstIndex(type, "\"\\$bin\"[ \\t]+type\\b")
        ok(guardAt != nil && postAt != nil && guardAt! < postAt!, "cmd_type must call need_frontmost_window before it posts")
        ok(type.contains("--front-pids \"$pids\""), "cmd_type must hand the key tool the pids to re-check")
        ok(has(type, "\"\\$bin\"[ \\t]+type[^\\n]*\\n[ \\t]*rc=\\$\\?"), "the status of the `type` post must be read on the next line")
    }

    @Test("keytool typeText gives every typed key event empty flags: the event it creates is assigned `flags = []` before it is posted, with no extra key press and no extra settle")
    func typeTextClearsEventFlags() throws {
        let url = projectRoot.appendingPathComponent("scripts/kit-lib/keytool.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("scripts/kit-lib/keytool.swift not found")
            return
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("func typeText(") }),
              let end = lines[start...].firstIndex(of: "}") else {
            Issue.record("keytool.swift has no typeText function")
            return
        }
        let body = lines[start..<end].filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let made = captures(body, "(?:let|var)[ \\t]+([A-Za-z_][A-Za-z0-9_]*)[ \\t]*=[ \\t]*CGEvent\\(keyboardEventSource")
        ok(made.count == 1, "typeText must create its key events in one place: \(made)")
        guard let name = made.first else { return }
        let createdAt = firstIndex(body, "CGEvent\\(keyboardEventSource")
        let clearAt = firstIndex(body, "(^|[^A-Za-z0-9_])\(name)\\.flags[ \\t]*=[ \\t]*(\\[[ \\t]*\\]|CGEventFlags\\(\\)|\\.init\\(\\)|CGEventFlags\\(rawValue:[ \\t]*0\\))")
        let postAt = firstIndex(body, "\(name)\\.post\\(")
        ok(clearAt != nil, "typeText never sets `\(name).flags` to empty, so the typed events carry the stuck Ctrl+Opt of the last hotkey")
        ok(createdAt != nil && clearAt != nil && postAt != nil && createdAt! < clearAt! && clearAt! < postAt!, "the flags must be cleared after the event is created and before it is posted")
        ok(!has(body, "\\.flags[ \\t]*(=|\\|=)[ \\t]*\\.?(mask|\\[[ \\t]*\\.)"), "typeText sets a non-empty flag on an event")
        ok(!has(body, "\\b[Ff]6\\b|key[ \\t]*:[ \\t]*\"f6\""), "typeText must not press F6")
        ok(body.components(separatedBy: ".post(").count - 1 == 1, "typeText must post only the typed key events, one post in the loop")
        ok(body.components(separatedBy: "usleep(").count - 1 == 1, "typeText must keep only the per-key delay, no extra settle")
    }

    // MARK: shot

    @Test("shot is a picture of one window by its id, never the whole screen")
    func shotIsOneWindow() throws {
        guard let text = code(of: axName) else { return }
        let shots = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { has($0, "^screencapture[ \\t]") }
        ok(!shots.isEmpty, "kit-ax.sh never takes a picture")
        for line in shots { ok(has(line, "[ \\t]-l[ \\t]"), "a screencapture call has no -l <window id>, so it could take the whole screen: \(line)") }
        let shot = shellFunctions(in: text)["cmd_shot"] ?? ""
        ok(has(shot, "window-id"), "`shot` does not pick the window by its id (pixelpoll window-id)")
        ok(shot.contains("no $owner window"), "`shot` lost its `no <app> window` line")
    }

    // MARK: kit-launch.sh keeps every plan-1 mode

    @Test("kit-launch.sh keeps every plan-1 mode in its dispatch",
          arguments: ["start", "stop", "quit", "kill9", "freeze", "thaw", "pids", "helper", "probe", "where", "relaunch"])
    func launchKeepsPlan1Modes(_ mode: String) throws {
        guard let text = code(of: launchName) else { return }
        ok(dispatches(mode, in: text), "kit-launch.sh lost its `\(mode)` mode: the dispatch has no line for it")
    }

    @Test("kit-launch.sh usage still names start, quit, kill9 <app|encode|index>, freeze index, thaw index, pids [--names] and relaunch")
    func launchUsageKept() throws {
        guard let text = code(of: launchName) else { return }
        let usage = usageLines(shellFunctions(in: text))
        for prefix in ["usage: kit-launch.sh start [--mirror|--mirror-full|--plain] [--fake-embedder]",
                       "kit-launch.sh quit",
                       "kit-launch.sh kill9 <app|encode|index>",
                       "kit-launch.sh freeze index",
                       "kit-launch.sh thaw index",
                       "kit-launch.sh pids [--names]",
                       "kit-launch.sh relaunch"] {
            ok(usage.contains { $0.hasPrefix(prefix) }, "usage has no line starting `\(prefix)`")
        }
    }

    @Test("kit-launch.sh keeps the plan-1 behaviour of kill9, freeze, thaw, pids and relaunch (text)")
    func launchPlan1Behaviour() throws {
        guard let text = code(of: launchName) else { return }
        let functions = shellFunctions(in: text)
        let kill = functions["cmd_kill9"] ?? ""
        for part in ["app", "encode", "index"] { ok(has(kill, "(^|[ \\t|])\(part)[|)]"), "kill9 lost `\(part)`") }
        ok(kill.contains("kill -9"), "kill9 no longer sends SIGKILL")
        ok(has(kill, "return 4"), "kill9 of something not running is no longer exit 4")
        let signal = functions["cmd_signal"] ?? ""
        ok(signal.contains("kill -\"$sig\"") && signal.contains("sig=STOP") && signal.contains("sig=CONT"), "freeze and thaw are no longer kill -STOP and kill -CONT")
        ok(has(signal, "return 4"), "freeze or thaw of a helper that is not running is no longer exit 4")
        ok(has(functions["cmd_pids"] ?? "", "--names"), "pids lost --names")
        let relaunch = functions["cmd_relaunch"] ?? ""
        ok(relaunch.contains("start-flags"), "relaunch no longer repeats the flags of the last start")
        ok(has(relaunch, "return 4"), "relaunch with the app still running or no earlier start is no longer exit 4")
    }

    // MARK: kit-launch.sh adds no launch setting

    private static let allowedNames: Set<String> = ["HOME", "SESAME_MODEL_HOST", "SESAME_PROBE_FILE", "SESAME_FAKE_EMBEDDER"]

    @Test("the only environment names kit-launch.sh sets for the app are HOME, SESAME_MODEL_HOST, SESAME_PROBE_FILE and SESAME_FAKE_EMBEDDER")
    func onlyTestOnlyNames() throws {
        guard let text = code(of: launchName) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        var set: Set<String> = []
        for line in lines where has(line, "(^|[^A-Za-z0-9_])envs(\\+?=|\\[)|(^|[^A-Za-z0-9_.-])env[ \\t]+[A-Z]") {
            for name in captures(line, "[\"']([A-Za-z_][A-Za-z0-9_]*)=") { set.insert(name) }
        }
        let extra = set.subtracting(Self.allowedNames)
        ok(extra.isEmpty, "kit-launch.sh sets environment names beyond the four test-only ones: \(extra.sorted())")
        ok(set.isSuperset(of: Self.allowedNames), "kit-launch.sh no longer sets \(Self.allowedNames.subtracting(set).sorted())")
        let sesameNames = Set(captures(text, "\\b(SESAME_[A-Z0-9_]+)"))
        let strayNames = sesameNames.subtracting(Self.allowedNames)
        ok(strayNames.isEmpty, "kit-launch.sh names a SESAME_ setting that is not one of the test-only names: \(strayNames.sorted())")
    }

    @Test("every --env the launch passes comes from the envs list; no other way of setting the app's environment is used")
    func noOtherEnvironmentRoute() throws {
        guard let text = code(of: launchName) else { return }
        let envFlags = text.split(separator: "\n").map(String.init).filter { has($0, "--env\\b") && !has($0.trimmingCharacters(in: .whitespaces), "^(echo|printf)\\b") }
        for line in envFlags where !has(line, "--env[ \\t]+\"\\$i\"|open --help") {
            Issue.record(Comment(rawValue: "an --env that does not come from the envs list: \(line)"))
        }
        ok(!has(text, "launchctl[ \\t]+setenv|defaults[ \\t]+write|(^|[\\n;])[ \\t]*export[ \\t]+SESAME|plutil[ \\t]+-insert[ \\t]+LSEnvironment"),
           "kit-launch.sh sets the app's environment by a route other than the envs list (launchctl setenv, defaults write, export or LSEnvironment)")
    }
}
