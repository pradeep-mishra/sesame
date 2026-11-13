import CryptoKit
import Foundation
import Testing

// plan-2 fix round C, part C2 (kit safety and the model cache), tester step. Written from
// .ril/docs/plans/plan-2-fix-round-C.md (items C2-1 to C2-5) and the kit scripts as they stood before the part; the labels a
// kit step clicks or reads were checked against the Swift sources read-only (SettingsScreen: "Launch at login", "Indexing";
// FolderRowAccessibilityTests: the sidebar buttons), the product is not touched.
//
// Static and pure proof only (the person's ruling "no app launch", plan-2-fix-round-C.md): nothing here runs kit-run.sh,
// kit-launch.sh, kit-ax.sh, verify.sh or kit-doctor.sh, starts Sesame, asks for a password, runs sudo, pmset (except as a shell
// function the test defines), fs_usage, osascript or hdiutil. What runs:
//   - the kit's own shell functions, cut out of the script text and run in a throwaway `bash -c` with `pmset`, `sudo`, `ps`,
//     `curl` and the like defined as shell functions of the test, in a throwaway KIT_ROOT (a folder named sesame-kit-c2-*);
//   - `scripts/kit-mirror.sh seed --selftest`, whose fixture server is the kit's own local mirrorserver on 127.0.0.1, in a
//     throwaway KIT_ROOT (the real kit cache is never named);
//   - `bash -n`, and the script text read with its comment lines removed.
//
// Each behaviour check is a function that returns the list of problems it found. The real script must return none, and a
// PLANT (the code as it stood before the part, or the same code with the safeguard taken out) must return the problem: a
// check that cannot fail on the broken code is not a check.
//
// Guesses that only the accept stage can settle are marked GUESS in the comments below.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

// MARK: helpers

private struct Ran {
    let status: Int32
    let out: String
    let err: String
    var lines: [String] { out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

/// `/bin/bash -c script`, standard output and standard error kept apart, never reading standard input.
private func bash(_ script: String, env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let fm = FileManager.default
    let id = UUID().uuidString
    let outURL = fm.temporaryDirectory.appendingPathComponent("kitc2-out-" + id)
    let errURL = fm.temporaryDirectory.appendingPathComponent("kitc2-err-" + id)
    fm.createFile(atPath: outURL.path, contents: nil)
    fm.createFile(atPath: errURL.path, contents: nil)
    defer {
        try? fm.removeItem(at: outURL)
        try? fm.removeItem(at: errURL)
    }
    let outHandle = try FileHandle(forWritingTo: outURL)
    let errHandle = try FileHandle(forWritingTo: errURL)
    defer {
        try? outHandle.close()
        try? errHandle.close()
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["KIT_NO_EVIDENCE"] = "1"
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = outHandle
    p.standardError = errHandle
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
    try? outHandle.synchronize()
    try? errHandle.synchronize()
    return Ran(status: status,
               out: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
               err: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
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

/// The text of scripts/<relative>; records the reason and returns "" when it is missing.
private func scriptText(_ relative: String) -> String {
    guard let text = read(scriptsDir.appendingPathComponent(relative)) else {
        Issue.record(Comment(rawValue: "scripts/\(relative) not found"))
        return ""
    }
    return text
}

private func stripComments(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

/// The function definitions of a script (`name() {` to a line that is just `}`, or a one-line `name() { ...; }`), as text, so
/// a test can run them. `only` limits them to those names; `main` and `usage` are always left out.
private func shellDefinitions(_ text: String, only: Set<String>? = nil) -> String {
    var out: [String] = []
    var name: String?
    var block: [String] = []
    func wanted(_ n: String) -> Bool { n != "main" && n != "usage" && (only?.contains(n) ?? true) }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if let n = name {
            block.append(line)
            if line == "}" {
                if wanted(n) { out.append(block.joined(separator: "\n")) }
                name = nil
            }
        } else if has(line, "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{ .* \\}$") {
            let n = String(line.prefix { $0 != "(" })
            if wanted(n) { out.append(line) }
        } else if has(line, "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{( #.*)?$") {
            name = String(line.prefix { $0 != "(" })
            block = [line]
        }
    }
    return out.joined(separator: "\n")
}

/// The one-line top-level assignments (`SAVED="$KIT_ROOT/..."`), as text.
private func topLevelAssignments(_ text: String) -> String {
    text.split(separator: "\n").map(String.init)
        .filter { has($0, "^[A-Z][A-Z0-9_]*=") }
        .joined(separator: "\n")
}

/// The body lines of one function of a comment-free text ("" when there is none).
private func functionBody(_ name: String, in text: String) -> String {
    var found = false
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if !found {
            if has(line, "^\(NSRegularExpression.escapedPattern(for: name))\\(\\) \\{( #.*)?$") { found = true }
        } else if line == "}" {
            return body.joined(separator: "\n")
        } else {
            body.append(line)
        }
    }
    return body.joined(separator: "\n")
}

/// A throwaway KIT_ROOT (the kit demands a folder named sesame-kit*) and an aux folder next to it, both removed afterwards.
private struct Work {
    let root: String
    let aux: String
}

private func withWork<T>(_ body: (Work) throws -> T) throws -> T {
    let fm = FileManager.default
    let id = UUID().uuidString
    let root = fm.temporaryDirectory.appendingPathComponent("sesame-kit-c2-" + id, isDirectory: true)
    let aux = fm.temporaryDirectory.appendingPathComponent("kitc2-aux-" + id, isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: aux, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: root)
        try? fm.removeItem(at: aux)
    }
    return try body(Work(root: root.resolvingSymlinksInPath().path, aux: aux.resolvingSymlinksInPath().path))
}

/// The value of a tagged line `TAG value` of a script's output ("" when there is none).
private func tagged(_ ran: Ran, _ tag: String) -> String {
    for line in ran.lines where line.hasPrefix(tag + " ") || line == tag {
        return String(line.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces)
    }
    return ""
}

// MARK: the kit text, read the way the shell would run it (comments removed, calls written in)

private func kitShellFiles() -> [(name: String, code: String)] {
    var all: [(String, String)] = []
    if let t = read(scriptsDir.appendingPathComponent("kit-run.sh")) { all.append(("kit-run.sh", stripComments(t))) }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: libDir.path)) ?? []).filter { $0.hasSuffix(".sh") }.sorted()
    for n in names { if let t = read(libDir.appendingPathComponent(n)) { all.append(("kit-lib/" + n, stripComments(t))) } }
    return all
}

/// Every function of a comment-free text: name to body (a one-line `name() { ...; }` has the text between the braces).
private func functionBodies(_ code: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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

/// Every function of the runner and of the kit-lib shell files. A later file never replaces an earlier name.
private func kitFunctions() -> [String: String] {
    var merged: [String: String] = [:]
    for (_, code) in kitShellFiles() {
        for (k, v) in functionBodies(code) where merged[k] == nil { merged[k] = v }
    }
    return merged
}

private func kitTopLevelValues() -> [String: String] {
    var values: [String: String] = [:]
    for (_, code) in kitShellFiles() {
        for line in code.split(separator: "\n").map(String.init) {
            if let g = groups(line, "^([A-Z][A-Z0-9_]*)=\"([^\"]*)\"").first, g.count == 2, !g[1].contains("$("), !g[1].contains("`") {
                values[g[0]] = g[1]
            }
        }
    }
    return values
}

private let callWord = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_.:-])")

/// `body` with every call to a function of the kit written in, in place, after the line that calls it.
private func expandShell(_ body: String, _ functions: [String: String], skipping: [String] = [], depth: Int = 0) -> String {
    guard depth < 6 else { return body }
    var out: [String] = []
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        out.append(line)
        let ns = line as NSString
        var seen = Set<String>()
        for m in callWord.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            guard let function = functions[word], !skipping.contains(word), seen.insert(word).inserted else { continue }
            out.append(expandShell(function, functions, skipping: skipping + [word], depth: depth + 1))
        }
    }
    return out.joined(separator: "\n")
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

/// The check named, as the shell would run it: calls and variables written in (the wrapper `s7_run s7_check_n` included).
private func expandedCheck(_ function: String) -> String? {
    let all = kitFunctions()
    guard let body = all[function] else {
        Issue.record(Comment(rawValue: "\(function) is not defined in scripts/kit-run.sh or scripts/kit-lib/*.sh"))
        return nil
    }
    return substitute(expandShell(body, all, skipping: [function]), kitTopLevelValues())
}

// =====================================================================================================================
// C2-1: Low Power Mode is never left on, and its original value is never lost
// =====================================================================================================================

/// What kit-power.sh and kit-reset.sh did before the part (a PLANT): the baseline in run/, `record` overwriting it, a failed
/// restore that says only "put it back by hand".
private let oldPowerDefinitions = #"""
SAVED="$KIT_ROOT/run/lowpower.saved"
current_value() {
  local v
  v="$(pmset -g 2>/dev/null | awk '$1 == "lowpowermode" { print $2; exit }')"
  case "$v" in
    0|1) echo "$v"; return 0 ;;
  esac
  return 1
}
need_setting() {
  if ! current_value >/dev/null; then
    echo "NEEDS A PERSON: this Mac has no Low Power Mode setting"
    return 3
  fi
  return 0
}
need_admin() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  echo "NEEDS A PERSON: administrator rights: run scripts/kit-perms.sh ask-admin from a Terminal window you can type in, then run this again"
  return 3
}
write_value() {
  local want="$1" got
  sudo -n pmset -a lowpowermode "$want" || { echo "pmset did not accept lowpowermode $want"; return 1; }
  got="$(current_value)"
  if [ "$got" != "$want" ]; then
    echo "pmset -g reads lowpowermode ${got:-nothing} after writing $want"
    return 1
  fi
  return 0
}
word_of() { if [ "$1" = 1 ]; then echo on; else echo off; fi; }
cmd_record() {
  local v
  need_setting || return 3
  v="$(current_value)"
  mkdir -p "$KIT_ROOT/run" || return 1
  printf '%s\n' "$v" > "$SAVED" || return 1
  echo "recorded lowpowermode $(word_of "$v")"
  return 0
}
cmd_restore() {
  local want now
  need_setting || return 3
  if [ ! -f "$SAVED" ]; then
    echo "no recorded Low Power Mode value, nothing to restore"
    return 0
  fi
  want="$(cat "$SAVED")"
  now="$(current_value)"
  if [ "$want" = "$now" ]; then
    rm -f "$SAVED"
    echo "lowpowermode is already $(word_of "$want"), nothing to restore"
    return 0
  fi
  if ! need_admin; then
    echo "NEEDS A PERSON: put Low Power Mode back to $(word_of "$want") by hand (System Settings, Battery)"
    return 3
  fi
  write_value "$want" || return 1
  rm -f "$SAVED"
  echo "lowpowermode restored to $(word_of "$want") epoch $(date +%s)"
  return 0
}
"""#

/// The shell around the Low Power Mode functions: `pmset` and `sudo` are functions of the test. The Mac's setting is the
/// number in $STATE; a file $AUX/lapsed makes `sudo -n` refuse (the ticket ran out), $AUX/pmset-refuses makes the write fail,
/// $AUX/writes lists every value written. `snap TAG` prints the files under KIT_ROOT and their text.
private func powerScript(_ w: Work, definitions: String, body: String) -> String {
    #"""
    export KIT_ROOT='\#(w.root)'
    AUX='\#(w.aux)'
    STATE="$AUX/state"
    . '\#(libDir.path)/common.sh'
    pmset() {
      [ "$1" = "-g" ] || return 1
      printf ' sleep                1\n lowpowermode         %s\n' "$(cat "$STATE")"
    }
    sudo() {
      if [ "$1" != "-n" ]; then echo "sudo without -n: $*" >> "$AUX/violations"; return 99; fi
      shift
      case "$1" in
        true) [ ! -f "$AUX/lapsed" ] ;;
        pmset)
          [ ! -f "$AUX/lapsed" ] || return 1
          [ ! -f "$AUX/pmset-refuses" ] || return 1
          [ "$2 $3" = "-a lowpowermode" ] || return 2
          echo "$4" > "$STATE"
          echo "$4" >> "$AUX/writes" ;;
        *) return 98 ;;
      esac
    }
    snap() {
      echo "$1 FILES $(cd "$KIT_ROOT" && find . -type f | sed 's|^\./||' | sort | tr '\n' ',')"
      echo "$1 TEXT $(find "$KIT_ROOT" -type f -exec cat {} + 2>/dev/null | tr '\n' ',')"
    }
    \#(definitions)
    \#(body)
    """#
}

/// The names kit-reset.sh removes at a plain reset and keeps at a cleanup, read from its text.
private func resetAndCleanupNames() -> (resetRemoves: Set<String>, cleanupKeeps: Set<String>, cleanupFindLine: String) {
    let text = stripComments(scriptText("kit-reset.sh"))
    var removes = Set<String>()
    for line in text.split(separator: "\n").map(String.init) where has(line, "^\\s*rm -rf\\s+\"\\$KIT_ROOT/") {
        for g in groups(line, "\"\\$KIT_ROOT/([A-Za-z0-9_.-]+)\"") { removes.insert(g[0]) }
    }
    var keeps = Set<String>()
    var findLine = ""
    for line in text.split(separator: "\n").map(String.init) where has(line, "find\\s+\"\\$KIT_ROOT\"\\s+-mindepth 1\\s+-maxdepth 1") {
        findLine = line.trimmingCharacters(in: .whitespaces)
        for g in groups(line, "!\\s+-name\\s+([A-Za-z0-9_.-]+)") { keeps.insert(g[0]) }
    }
    return (removes, keeps, findLine)
}

/// Every problem the Low Power Mode functions `definitions` have with the contract of C2-1 (empty: none).
private func powerProblems(_ definitions: String) throws -> [String] {
    var problems: [String] = []
    let names = resetAndCleanupNames()

    // P1 and P2: `record` saves where a reset does not delete it, and never overwrites a saved value.
    try withWork { w in
        let ran = try bash(powerScript(w, definitions: definitions, body: #"""
        echo 0 > "$STATE"
        cmd_record; echo "R1 rc $?"
        snap A
        echo 1 > "$STATE"
        cmd_record; echo "R2 rc $?"
        snap B
        """#))
        let files = tagged(ran, "A FILES").split(separator: ",").map(String.init)
        if files.count != 1 {
            problems.append("record saved \(files.count) files, expected exactly one: \(files)")
        } else {
            let top = String(files[0].split(separator: "/").first ?? "")
            if files[0].split(separator: "/").count < 2 || names.resetRemoves.contains(top) {
                problems.append("the baseline is saved in \(files[0]), under a folder a plain reset deletes (\(names.resetRemoves.sorted()))")
            } else if !names.cleanupKeeps.subtracting(["cache"]).contains(top) {
                problems.append("the baseline is saved in \(files[0]), and --cleanup keeps only \(names.cleanupKeeps.sorted()) (cache/ is emptied by --wipe-cache)")
            }
        }
        if tagged(ran, "A TEXT").trimmingCharacters(in: CharacterSet(charactersIn: ", ")) != "0" {
            problems.append("record did not save the value 0: \(tagged(ran, "A TEXT"))")
        }
        if tagged(ran, "B TEXT").trimmingCharacters(in: CharacterSet(charactersIn: ", ")) != "0" {
            problems.append("a second record overwrote the saved baseline (was 0, now \(tagged(ran, "B TEXT")))")
        }
        if tagged(ran, "R2 rc") != "0" { problems.append("the second record exited \(tagged(ran, "R2 rc")), expected 0") }
    }

    // P3: a failed restore is loud, keeps the baseline, and a later restore with rights puts the value back.
    let loud = "NEEDS A PERSON: Low Power Mode is still on, run `sudo pmset -a lowpowermode 0`"
    for how in ["lapsed", "pmset-refuses"] {
        try withWork { w in
            let ran = try bash(powerScript(w, definitions: definitions, body: #"""
            echo 0 > "$STATE"
            cmd_record >/dev/null
            echo 1 > "$STATE"
            touch "$AUX/\#(how)"
            cmd_restore; echo "F1 rc $?"
            snap A
            cmd_record >/dev/null
            snap B
            rm -f "$AUX/lapsed" "$AUX/pmset-refuses"
            cmd_restore; echo "F2 rc $?"
            snap C
            echo "STATE $(cat "$STATE")"
            """#))
            let all = ran.lines + ran.err.split(separator: "\n").map(String.init)
            if !all.contains(loud) { problems.append("[\(how)] a failed restore printed no line \"\(loud)\": \(ran.lines)") }
            if tagged(ran, "F1 rc") == "0" { problems.append("[\(how)] a failed restore exited 0") }
            if tagged(ran, "A TEXT").trimmingCharacters(in: CharacterSet(charactersIn: ", ")) != "0" {
                problems.append("[\(how)] the baseline is gone after a failed restore: \(tagged(ran, "A TEXT"))")
            }
            if tagged(ran, "B TEXT").trimmingCharacters(in: CharacterSet(charactersIn: ", ")) != "0" {
                problems.append("[\(how)] a record after the failed restore lost the baseline: \(tagged(ran, "B TEXT"))")
            }
            if tagged(ran, "F2 rc") != "0" || tagged(ran, "STATE") != "0" {
                problems.append("[\(how)] with rights again restore left Low Power Mode at \(tagged(ran, "STATE")) (rc \(tagged(ran, "F2 rc")))")
            }
            if !tagged(ran, "C FILES").isEmpty { problems.append("[\(how)] the baseline stays after a restore that worked: \(tagged(ran, "C FILES"))") }
        }
    }
    return problems
}

@Suite("KitC2LowPowerTests")
struct KitC2LowPowerTests {

    @Test("the saved baseline lives where neither a reset nor a cleanup deletes it; record never overwrites it; a failed restore is loud and keeps it")
    func contract() throws {
        let problems = try powerProblems(
            shellDefinitions(scriptText("kit-power.sh")) + "\n" + topLevelAssignments(scriptText("kit-power.sh")))
        #expect(problems.isEmpty, "kit-power.sh: \(problems)")
    }

    // PLANT: the script as it stood before the part must be found wrong, for each of the three problems.
    @Test("the check can fail: the old kit-power.sh (baseline under run/, record overwrites, silent failed restore) is found wrong three ways")
    func oldScriptIsFound() throws {
        let problems = try powerProblems(oldPowerDefinitions)
        #expect(problems.contains { $0.contains("under a folder a plain reset deletes") }, "the old location under run/ was not found: \(problems)")
        #expect(problems.contains { $0.contains("overwrote the saved baseline") }, "the old overwrite was not found: \(problems)")
        #expect(problems.contains { $0.contains("printed no line") }, "the old silent failed restore was not found: \(problems)")
    }

    @Test("a baseline an earlier kit left under run/ is adopted: restore puts that value back instead of losing it at the next reset")
    func legacyBaselineIsAdopted() throws {
        let definitions = shellDefinitions(scriptText("kit-power.sh")) + "\n" + topLevelAssignments(scriptText("kit-power.sh"))
        try withWork { w in
            let ran = try bash(powerScript(w, definitions: definitions, body: #"""
            mkdir -p "$KIT_ROOT/run"
            echo 0 > "$KIT_ROOT/run/lowpower.saved"
            echo 1 > "$STATE"
            cmd_restore; echo "RC $?"
            echo "STATE $(cat "$STATE")"
            """#))
            #expect(tagged(ran, "RC") == "0" && tagged(ran, "STATE") == "0",
                    "a baseline of 0 left under run/ by an earlier kit was not put back (rc \(tagged(ran, "RC")), state \(tagged(ran, "STATE")))")
        }
    }

    @Test("a restore with nothing recorded, or with the value already back, writes nothing")
    func nothingToRestoreWritesNothing() throws {
        let definitions = shellDefinitions(scriptText("kit-power.sh")) + "\n" + topLevelAssignments(scriptText("kit-power.sh"))
        try withWork { w in
            let ran = try bash(powerScript(w, definitions: definitions, body: #"""
            echo 1 > "$STATE"
            cmd_restore; echo "NONE rc $?"
            echo 0 > "$STATE"
            cmd_record >/dev/null
            cmd_restore; echo "BACK rc $?"
            snap A
            echo "WRITES $(cat "$AUX/writes" 2>/dev/null | tr '\n' ',')"
            echo "VIOLATIONS $(cat "$AUX/violations" 2>/dev/null)"
            """#))
            #expect(tagged(ran, "NONE rc") == "0" && tagged(ran, "BACK rc") == "0", "a restore that has nothing to do failed: \(ran.lines)")
            #expect(tagged(ran, "WRITES").isEmpty, "a restore with nothing to do wrote the setting: \(tagged(ran, "WRITES"))")
            #expect(tagged(ran, "A FILES").isEmpty, "the baseline stays after the value was found already back: \(tagged(ran, "A FILES"))")
            #expect(tagged(ran, "VIOLATIONS").isEmpty, "a sudo without -n: \(tagged(ran, "VIOLATIONS"))")
        }
    }

    @Test("--cleanup deletes everything under KIT_ROOT except cache/ and the folder that holds the baseline; a plain reset's rm leaves it too")
    func cleanupAndResetKeepTheBaseline() throws {
        let names = resetAndCleanupNames()
        ok(!names.cleanupFindLine.isEmpty, "kit-reset.sh has no `find \"$KIT_ROOT\" -mindepth 1 -maxdepth 1 ! -name cache ...` line")
        ok(names.cleanupKeeps.contains("cache"), "--cleanup no longer keeps cache/: \(names.cleanupKeeps)")
        ok(names.cleanupKeeps.count >= 2, "--cleanup keeps only \(names.cleanupKeeps.sorted()): there is no folder left for the Low Power Mode baseline")
        guard !names.cleanupFindLine.isEmpty else { return }
        try withWork { w in
            let keep = names.cleanupKeeps.subtracting(["cache"]).sorted().first ?? "keep"
            let ran = try bash(#"""
            export KIT_ROOT='\#(w.root)'
            mkdir -p "$KIT_ROOT/home" "$KIT_ROOT/apps" "$KIT_ROOT/run/pids" "$KIT_ROOT/fixtures" "$KIT_ROOT/mirror" "$KIT_ROOT/cache" "$KIT_ROOT/\#(keep)"
            echo 0 > "$KIT_ROOT/\#(keep)/baseline"
            echo model > "$KIT_ROOT/cache/m.gguf"
            echo x > "$KIT_ROOT/run/pids/a.pid"
            \#(names.cleanupFindLine)
            echo "LEFT $(cd "$KIT_ROOT" && find . -type f | sed 's|^\./||' | sort | tr '\n' ',')"
            """#)
            #expect(tagged(ran, "LEFT").split(separator: ",").map(String.init).sorted() == ["cache/m.gguf", "\(keep)/baseline"].sorted(),
                    "after the cleanup's find, the files left are \(tagged(ran, "LEFT")), expected the cache and \(keep)/baseline only")
        }
        // a plain reset deletes home, apps and run only
        let removes = names.resetRemoves
        ok(removes == ["home", "apps", "run"], "a plain reset removes \(removes.sorted()), expected home, apps and run")
    }

    @Test("--cleanup says so and exits 3 when a recorded Low Power Mode value is still waiting to be put back")
    func cleanupReportsAPendingBaseline() {
        let text = stripComments(scriptText("kit-reset.sh"))
        let names = resetAndCleanupNames()
        let functions = functionBodies(text)
        let expanded = expandShell(functions["do_cleanup"] ?? "", functions, skipping: ["do_cleanup"])
        ok(functions["do_cleanup"] != nil, "kit-reset.sh has no do_cleanup function")
        let keepFolder = names.cleanupKeeps.subtracting(["cache"]).sorted().first ?? "keep"
        ok(has(expanded, "NEEDS A PERSON"), "--cleanup never prints a NEEDS A PERSON line for a baseline that was not restored")
        ok(expanded.contains(keepFolder), "--cleanup does not look in \(keepFolder)/ for the baseline that was not restored")
        ok(has(expanded, "return 3"), "--cleanup does not exit 3 (a person-step is missing) when the baseline was not restored")
        ok(has(expanded, "sudo pmset -a lowpowermode"), "the cleanup line does not give the command to run: `sudo pmset -a lowpowermode <saved>`")
    }

    // The S7 cleanup ran `kit-power.sh restore >/dev/null 2>&1`: a failed restore was thrown away.
    private static let s7Cleanup = """
    s7_cleanup() {
      kq "$S7_LOAD" stop >/dev/null 2>&1
      kq "$S7_MR" online >/dev/null 2>&1
      [ -z "$S7_USED_POWER" ] || kq "$S7_PW" restore >/dev/null 2>&1
      [ -z "$S7_USED_VOL" ] || kq "$S7_VOL" destroy >/dev/null 2>&1
      [ -z "$S7_MUTATED" ] || kq "$S7_FX" restore >/dev/null 2>&1
      [ -z "$S7_TMPFILES" ] || rm -f $S7_TMPFILES
      [ -z "$S7_MUTATED$S7_DIRTY" ] || rm -f "$S7_MARK"
      s1_cleanup
      return 0
    }
    """

    private func s7CleanupProblems(_ definitions: String) throws -> [String] {
        var problems: [String] = []
        let loud = "NEEDS A PERSON: Low Power Mode is still on, run `sudo pmset -a lowpowermode 0`"
        try withWork { w in
            let ran = try bash(#"""
            export KIT_ROOT='\#(w.root)'
            AUX='\#(w.aux)'
            . '\#(libDir.path)/common.sh'
            S7_LOAD=kit-load.sh; S7_MR=kit-mirror.sh; S7_PW=kit-power.sh; S7_VOL=kit-volume.sh; S7_FX=kit-fixtures.sh
            S7_USED_POWER=1; S7_USED_VOL=""; S7_MUTATED=""; S7_DIRTY=""; S7_TMPFILES=""
            kq() {
              echo "$*" >> "$AUX/calls"
              case "$*" in
                *"kit-power.sh restore"*) echo '\#(loud)'; return 3 ;;
              esac
              return 0
            }
            s1_cleanup() { :; }
            \#(definitions)
            s7_cleanup; echo "RC $?"
            """#)
            let shown = ran.lines + ran.err.split(separator: "\n").map(String.init)
            if !shown.contains(where: { $0.contains(loud) }) { problems.append("s7_cleanup threw away the output of a failed `kit-power.sh restore`: it showed \(shown)") }
            let calls = (read(URL(fileURLWithPath: w.aux + "/calls")) ?? "")
            if !calls.contains("kit-power.sh restore") { problems.append("s7_cleanup never called kit-power.sh restore: \(calls)") }
        }
        return problems
    }

    @Test("s7_cleanup shows what a failed `kit-power.sh restore` said, and still restores")
    func s7CleanupShowsRestore() throws {
        let text = scriptText("kit-lib/checks-s7.sh")
        let definitions = shellDefinitions(text, only: ["s7_cleanup"])
        ok(!definitions.isEmpty, "s7_cleanup is not defined in checks-s7.sh")
        let problems = try s7CleanupProblems(definitions)
        #expect(problems.isEmpty, "s7_cleanup: \(problems)")
    }

    @Test("the check can fail: the old s7_cleanup (restore output to /dev/null) hides a failed restore")
    func oldS7CleanupIsFound() throws {
        let problems = try s7CleanupProblems(Self.s7Cleanup)
        #expect(problems.contains { $0.contains("threw away") }, "the old cleanup was not found hiding the failed restore: \(problems)")
    }

    // Before every `lowpower on|off` of S7.4 the check re-verifies the administrator session (`sudo -n true`) and asks again
    // through kit-perms.sh ask-admin (the plain sentence) when it lapsed. An "admin step" is a line whose written-in code does both.
    private func adminProblems(inCheckBody body: String) -> [String] {
        var problems: [String] = []
        let all = kitFunctions()
        let values = kitTopLevelValues()
        var sinceLast = false
        var index = 0
        var turns = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            index += 1
            let expanded = substitute(expandShell(line, all), values)
            let isAdminStep = has(expanded, "sudo[ \\t]+-n[ \\t]+true\\b") && has(expanded, "kit-perms\\.sh\"[ ]+ask-admin")
            if isAdminStep { sinceLast = true }
            if has(expanded, "kit-power\\.sh\"[ ]+lowpower[ ]+(on|off)\\b") {
                turns += 1
                if !sinceLast { problems.append("line \(index) turns Low Power Mode without an administrator step before it: \(line.trimmingCharacters(in: .whitespaces))") }
                sinceLast = false
            }
        }
        if turns < 4 { problems.append("s7_check_4 turns Low Power Mode \(turns) times, expected at least four (on, off, then on and off for the pause by you)") }
        return problems
    }

    @Test("S7.4: an administrator step comes before every lowpower on and off, so a lapsed session is asked for again")
    func s74ReverifiesBeforeEveryTurn() {
        let body = functionBody("s7_check_4", in: stripComments(scriptText("kit-lib/checks-s7.sh")))
        ok(!body.isEmpty, "s7_check_4 is not defined in checks-s7.sh")
        let problems = adminProblems(inCheckBody: body)
        #expect(problems.isEmpty, "S7.4: \(problems)")
    }

    // PLANT: the same check with its administrator steps taken out.
    @Test("the check can fail: S7.4 without its administrator steps is found")
    func s74WithoutStepsIsFound() {
        let all = kitFunctions()
        let values = kitTopLevelValues()
        let body = functionBody("s7_check_4", in: stripComments(scriptText("kit-lib/checks-s7.sh")))
        let stripped = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            let expanded = substitute(expandShell(line, all), values)
            return !(has(expanded, "sudo[ \\t]+-n[ \\t]+true\\b") && has(expanded, "kit-perms\\.sh\"[ ]+ask-admin"))
        }.joined(separator: "\n")
        #expect(!adminProblems(inCheckBody: stripped).isEmpty, "S7.4 without any administrator step was not found wrong")
    }
}

// =====================================================================================================================
// C2-2: ask-admin says the plain sentence to the terminal before it asks for the password
// =====================================================================================================================

private let adminSentence = "macOS only lets an administrator watch which files and connections Sesame uses, and read the login item record; you will be asked for your password once"

/// ask_admin as it stood before the part (a PLANT): the sentence goes to standard output, which a caller can capture.
private let oldAskAdmin = #"""
ask_admin() {
  echo "macOS only lets an administrator watch which files and connections Sesame uses, and read the login item record; you will be asked for your password once."
  if sudo -v; then
    echo "OK administrator rights"
    return 0
  fi
  echo "NEEDS A PERSON: administrator rights: type your password when macOS asks, from a Terminal window you can type in"
  return 3
}
"""#

/// `ask_admin` with KIT_TTY standing for the terminal. `sudo -v` is a function that records what the "terminal" held when it ran.
private func askAdminRun(_ w: Work, definitions: String, tty: String, sudoV: Int) throws -> Ran {
    try bash(#"""
    export KIT_ROOT='\#(w.root)'
    AUX='\#(w.aux)'
    . '\#(libDir.path)/common.sh'
    export KIT_TTY='\#(tty)'
    : > "$AUX/tty"
    sudo() {
      if [ "$1" = "-v" ]; then
        echo "tty at sudo -v: $(cat "$AUX/tty" 2>/dev/null)" >> "$AUX/log"
        echo "stdout-file at sudo -v: $(cat "$AUX/stdout" 2>/dev/null)" >> "$AUX/log"
        echo "stderr-file at sudo -v: $(cat "$AUX/stderr" 2>/dev/null)" >> "$AUX/log"
        return \#(sudoV)
      fi
      echo "other sudo: $*" >> "$AUX/log"
      return 99
    }
    \#(definitions)
    ask_admin >"$AUX/stdout" 2>"$AUX/stderr"
    echo "RC $?"
    """#)
}

private func askAdminProblems(_ definitions: String) throws -> [String] {
    var problems: [String] = []
    // the person's terminal is a file the test can read
    try withWork { w in
        let tty = w.aux + "/tty"
        let ran = try askAdminRun(w, definitions: definitions, tty: tty, sudoV: 0)
        let ttyText = read(URL(fileURLWithPath: tty)) ?? ""
        let stdout = read(URL(fileURLWithPath: w.aux + "/stdout")) ?? ""
        let log = read(URL(fileURLWithPath: w.aux + "/log")) ?? ""
        if !ttyText.contains(adminSentence) { problems.append("the sentence did not reach the terminal: \(ttyText.debugDescription)") }
        if stdout.contains(adminSentence) { problems.append("the sentence went to standard output, where a caller that captures the output never shows it") }
        if !log.contains("tty at sudo -v: \(adminSentence)") { problems.append("the terminal did not hold the sentence yet when `sudo -v` ran: \(log)") }
        if tagged(ran, "RC") != "0" { problems.append("a granted password exited \(tagged(ran, "RC"))") }
        if !stdout.contains("OK administrator rights") { problems.append("a granted password printed no `OK administrator rights`") }
    }
    // no terminal at all (a pipe, a cron job): the sentence goes to standard error, still before the prompt
    try withWork { w in
        let ran = try askAdminRun(w, definitions: definitions, tty: "/nonexistent-kit-folder/tty", sudoV: 1)
        let stdout = read(URL(fileURLWithPath: w.aux + "/stdout")) ?? ""
        let stderr = read(URL(fileURLWithPath: w.aux + "/stderr")) ?? ""
        let log = read(URL(fileURLWithPath: w.aux + "/log")) ?? ""
        if !stderr.contains(adminSentence) { problems.append("with no terminal the sentence did not go to standard error: \(stderr.debugDescription)") }
        if stdout.contains(adminSentence) { problems.append("with no terminal the sentence went to standard output") }
        if !log.contains("stderr-file at sudo -v: \(adminSentence)") { problems.append("with no terminal the sentence was not on standard error before `sudo -v` ran") }
        if tagged(ran, "RC") != "3" { problems.append("a refused password exited \(tagged(ran, "RC")), expected 3") }
        if !stdout.contains("NEEDS A PERSON: administrator rights") { problems.append("a refused password printed no NEEDS A PERSON line") }
    }
    return problems
}

@Suite("KitC2AskAdminTests")
struct KitC2AskAdminTests {

    @Test("ask-admin prints the plain sentence to the terminal (standard error without one) before `sudo -v`, never to a standard output a caller can capture")
    func askAdminSaysItToTheTerminal() throws {
        let text = scriptText("kit-perms.sh")
        let problems = try askAdminProblems(shellDefinitions(text, only: ["ask_admin"]))
        #expect(problems.isEmpty, "kit-perms.sh ask_admin: \(problems)")
    }

    @Test("the check can fail: the old ask_admin (sentence to standard output) is found")
    func oldAskAdminIsFound() throws {
        let problems = try askAdminProblems(oldAskAdmin)
        #expect(problems.contains { $0.contains("standard output") }, "the old sentence on standard output was not found: \(problems)")
        #expect(problems.contains { $0.contains("did not reach the terminal") }, "the old sentence missing from the terminal was not found: \(problems)")
    }

    @Test("kit-perms.sh still has exactly one `sudo -v` and every other sudo is `sudo -n`")
    func oneSudoV() {
        let lines = stripComments(scriptText("kit-perms.sh")).split(separator: "\n").map(String.init)
            .filter { has($0, "(^|[^A-Za-z0-9_.-])sudo[ \\t]") }
        ok(lines.filter { has($0, "sudo[ \\t]+-v\\b") }.count == 1, "kit-perms.sh must have exactly one `sudo -v`: \(lines)")
        for l in lines where !has(l, "sudo[ \\t]+-v\\b") { ok(has(l, "sudo[ \\t]+-n\\b"), "a sudo without -n: \(l)") }
    }

    /// A line of a check that runs ask-admin inside `$(...)` or backticks hides its sentence. A line is bad when it holds
    /// `ask-admin` and a capture.
    private func capturedAskAdmin(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
            .filter { $0.contains("ask-admin") && ($0.contains("$(") || $0.contains("`")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test("no check captures the output of ask-admin: S6.8, S7.4 and S7.18 do not call it inside $(...)")
    func checksDoNotCaptureAskAdmin() {
        for file in ["checks-s6b.sh", "checks-s7.sh"] {
            let text = stripComments(scriptText("kit-lib/" + file))
            ok(capturedAskAdmin(text).isEmpty, "\(file) calls ask-admin inside a capture: \(capturedAskAdmin(text))")
        }
        for function in ["check_S6_8", "check_S7_4", "check_S7_18"] {
            guard let t = expandedCheck(function) else { continue }
            ok(has(t, "kit-perms\\.sh\"?[ ]+ask-admin"), "\(function) never reaches `kit-perms.sh ask-admin`")
            ok(capturedAskAdmin(t).isEmpty, "\(function), as the shell runs it, calls ask-admin inside a capture: \(capturedAskAdmin(t))")
        }
    }

    // PLANT: the lines the checks held before the part.
    @Test("the check can fail: the old `out=\"$(kq \"$S7_PERMS\" ask-admin 2>&1)\"` lines are found")
    func oldCapturedLinesAreFound() {
        let old = """
          out="$(kq "$S7_PERMS" ask-admin 2>&1)"; rc=$?
          printf '%s\\n' "$out" | sed 's/^/  | /'
        """
        #expect(capturedAskAdmin(old).count == 1, "the captured ask-admin of the old check was not found")
    }

    // admin_session <fake kit-perms.sh>: the shared helper of recipes.sh. `sudo -n true` succeeds while $AUX/session exists;
    // the fake kit-perms.sh logs "ask-admin" and, when FAKE_ASK_RC is 0, opens the session.
    private func helperRun(_ w: Work, helper: String?, sessionOpen: Bool, askRc: Int) throws -> (ran: Ran, asked: Int) {
        let fakeScripts = w.aux + "/scripts"
        try FileManager.default.createDirectory(atPath: fakeScripts, withIntermediateDirectories: true)
        let fake = fakeScripts + "/kit-perms.sh"
        try Data("""
        #!/bin/bash
        echo "$*" >> "\(w.aux)/asked"
        [ "$FAKE_ASK_RC" = 0 ] && touch "\(w.aux)/session"
        exit "$FAKE_ASK_RC"
        """.utf8).write(to: URL(fileURLWithPath: fake))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        if sessionOpen { FileManager.default.createFile(atPath: w.aux + "/session", contents: nil) }
        let text = scriptText("kit-lib/recipes.sh")
        let defs = shellDefinitions(text, only: ["kq", "admin_session"])
        let ran = try bash(#"""
        export KIT_ROOT='\#(w.root)'
        . '\#(libDir.path)/common.sh'
        KIT_SCRIPTS='\#(fakeScripts)'
        export FAKE_ASK_RC=\#(askRc)
        sudo() {
          [ "$1" = "-n" ] || { echo "sudo without -n: $*" >> '\#(w.aux)/violations'; return 99; }
          shift
          [ "$1" = true ] && [ -f '\#(w.aux)/session' ]
        }
        \#(helper ?? defs)
        admin_session; echo "RC $?"
        """#)
        let asked = (read(URL(fileURLWithPath: w.aux + "/asked")) ?? "").split(separator: "\n").count
        return (ran, asked)
    }

    @Test("admin_session (recipes.sh): a primed session asks nothing; a lapsed one asks through ask-admin once; a refusal is a non-zero status")
    func adminSessionHelper() throws {
        try withWork { w in
            let r = try helperRun(w, helper: nil, sessionOpen: true, askRc: 3)
            #expect(tagged(r.ran, "RC") == "0" && r.asked == 0, "with a primed session admin_session asked \(r.asked) time(s), rc \(tagged(r.ran, "RC")): \(r.ran.lines)")
        }
        try withWork { w in
            let r = try helperRun(w, helper: nil, sessionOpen: false, askRc: 0)
            #expect(tagged(r.ran, "RC") == "0" && r.asked == 1, "with a lapsed session admin_session asked \(r.asked) time(s), rc \(tagged(r.ran, "RC")): \(r.ran.lines)")
        }
        try withWork { w in
            let r = try helperRun(w, helper: nil, sessionOpen: false, askRc: 3)
            #expect(tagged(r.ran, "RC") != "0" && r.asked == 1, "a refusal was not a failure (asked \(r.asked), rc \(tagged(r.ran, "RC")))")
        }
    }

    // PLANT: a helper that always asks, without looking at the session first.
    @Test("the check can fail: a helper that asks without testing `sudo -n true` first is found")
    func alwaysAskingHelperIsFound() throws {
        try withWork { w in
            let naive = #"""
            kq() { KIT_NO_EVIDENCE=1 "$@"; }
            admin_session() { kq "$KIT_SCRIPTS/kit-perms.sh" ask-admin; }
            """#
            let r = try helperRun(w, helper: naive, sessionOpen: true, askRc: 3)
            #expect(r.asked == 1, "the naive helper did not ask with a primed session, so the test cannot tell the two apart")
        }
    }

    /// Every use of the administrator session in the three checks is reached through an admin step in the same function (the
    /// lines before it): trace start and stop, lowpower on and off, login-item. An admin step is a line whose written-in code
    /// holds `sudo -n true` and `ask-admin`.
    private func lateStepProblems(function: String, in text: String, uses: String) -> [String] {
        var problems: [String] = []
        let all = kitFunctions()
        let values = kitTopLevelValues()
        var covered = false
        var n = 0
        for line in functionBody(function, in: text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            n += 1
            let expanded = substitute(expandShell(line, all), values)
            if has(expanded, "sudo[ \\t]+-n[ \\t]+true\\b") && has(expanded, "kit-perms\\.sh\"[ ]+ask-admin") { covered = true }
            if has(substitute(line, values), uses) {
                if !covered { problems.append("\(function) line \(n) uses the administrator session with no administrator step before it: \(line.trimmingCharacters(in: .whitespaces))") }
                covered = false
            }
        }
        return problems
    }

    @Test("S6.8: the trace starts and stops each follow an administrator step (the session may lapse in the 120 s wait)")
    func s68LaterStepsReverify() {
        let text = stripComments(scriptText("kit-lib/checks-s6b.sh"))
        let uses = "kit-trace\\.sh\"[ ]+(start|stop)\\b"
        let uses2 = functionBody("s6_check_8", in: text).split(separator: "\n").map(String.init).filter { has(substitute($0, kitTopLevelValues()), uses) }
        ok(uses2.count >= 3, "s6_check_8 starts or stops a trace only \(uses2.count) time(s) by hand, expected the stops of s6-setup and s6-after-start and the start of s6-after-start")
        let problems = lateStepProblems(function: "s6_check_8", in: text, uses: uses)
        #expect(problems.isEmpty, "S6.8: \(problems)")
    }

    @Test("S7.18: every login-item reading follows an administrator step (the recipe before it takes minutes)")
    func s718LaterStepsReverify() {
        let text = stripComments(scriptText("kit-lib/checks-s7.sh"))
        let problems = lateStepProblems(function: "s7_login_item", in: text, uses: "kit-privacy\\.sh\"[ ]+login-item\\b")
        #expect(problems.isEmpty, "S7.18: \(problems)")
    }

    // PLANT: s7_login_item as it stood (no administrator step).
    @Test("the check can fail: the old s7_login_item (no administrator step before login-item) is found")
    func oldLoginItemIsFound() {
        let old = """
        s7_login_item() {
          local out rc
          out="$(kq "$S7_PRIV" login-item 2>&1)"; rc=$?
          return 0
        }
        """
        let problems = lateStepProblems(function: "s7_login_item", in: old, uses: "kit-privacy\\.sh\"[ ]+login-item\\b")
        #expect(!problems.isEmpty, "the old reading with no administrator step before it was not found")
    }
}

// =====================================================================================================================
// C2-3: the model cache is never emptied before a download has succeeded
// =====================================================================================================================

/// seed_run as it stood before the part (a PLANT): it deletes the cached file before the download and downloads every time.
private let oldSeedRun = #"""
seed_run() {
  local table="$1" base="$2" dest="$3" clog="$4" name size sha url head hops rc part len lsize etag got gsha bad=0
  mkdir -p "$dest" || return 1
  : > "$clog"
  while IFS=$'\t' read -r name size sha; do
    [ -n "$name" ] || continue
    url="$base/$name"
    head="$(curl -sSIL -v --max-time 120 "$url" 2>>"$clog" </dev/null)"
    rc=$?
    if [ $rc != 0 ]; then
      echo "HEAD $name failed (curl exit $rc)"; bad=1; continue
    fi
    part="$dest/$name.partial"
    rm -f "$part" "$dest/$name"
    echo "downloading $name"
    curl -sS -L --fail -v --connect-timeout 30 --speed-limit 1000 --speed-time 60 -o "$part" "$url" 2>>"$clog" </dev/null
    rc=$?
    if [ $rc != 0 ]; then
      echo "download of $name failed (curl exit $rc; connection log: $clog)"; rm -f "$part"; bad=1; continue
    fi
    got="$(stat -f %z "$part")"
    gsha="$(shasum -a 256 "$part" | awk '{ print $1 }')"
    if [ "$got" = "$size" ] && [ "$gsha" = "$sha" ]; then
      mv "$part" "$dest/$name"
      echo "U1 OK $name"
    else
      rm -f "$part"
      echo "U1 DIFFERS $name"
      bad=1
    fi
  done < "$table"
  return $bad
}
"""#

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct Model {
    let name: String
    let data: Data
    var table: String { "\(name)\t\(data.count)\t\(sha256(data))" }
}

private func randomModel(_ name: String, bytes: Int) -> Model {
    var g = SystemRandomNumberGenerator()
    return Model(name: name, data: Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &g) }))
}

/// Runs `seed_run` for the models with a fake `curl`: HEAD answers 200 with the payload's size; a GET writes the payload
/// to the -o file as CURL_MODE says (good, interrupted: 40 bytes and exit 18, wrongsize: one byte too many, badsha: one byte
/// changed). Every call is logged to $AUX/curl.log. `previous` is what dest/<name> holds before the run.
private func seedRun(_ w: Work, definitions: String, models: [Model], previous: [String: Data], mode: String) throws -> (ran: Ran, curlCalls: [String], dest: String) {
    let fm = FileManager.default
    let dest = w.aux + "/dest"
    let payload = w.aux + "/payload"
    try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: payload, withIntermediateDirectories: true)
    for m in models { try m.data.write(to: URL(fileURLWithPath: payload + "/" + m.name)) }
    for (n, d) in previous { try d.write(to: URL(fileURLWithPath: dest + "/" + n)) }
    try Data((models.map(\.table).joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: w.aux + "/table.tsv"))
    let ran = try bash(#"""
    export KIT_ROOT='\#(w.root)'
    AUX='\#(w.aux)'
    . '\#(libDir.path)/common.sh'
    export CURL_MODE='\#(mode)'
    curl() {
      local a mode=get out="" url="" prev="" name
      for a in "$@"; do
        [ "$prev" = "-o" ] && out="$a"
        case "$a" in -sSIL) mode=head ;; esac
        prev="$a"; url="$a"
      done
      name="${url##*/}"
      echo "$mode $name" >> "$AUX/curl.log"
      if [ "$mode" = head ]; then
        printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$(stat -f %z "$AUX/payload/$name")"
        return 0
      fi
      case "$CURL_MODE" in
        interrupted) head -c 40 "$AUX/payload/$name" > "$out"; return 18 ;;
        wrongsize) { cat "$AUX/payload/$name"; printf X; } > "$out" ;;
        badsha) cp "$AUX/payload/$name" "$out"; printf 'Z' | dd of="$out" bs=1 seek=3 conv=notrunc 2>/dev/null ;;
        *) cp "$AUX/payload/$name" "$out" ;;
      esac
    }
    \#(definitions)
    seed_run "$AUX/table.tsv" http://fixture.invalid "$AUX/dest" "$AUX/clog"
    echo "RC $?"
    """#)
    let calls = (read(URL(fileURLWithPath: w.aux + "/curl.log")) ?? "").split(separator: "\n").map(String.init)
    return (ran, calls, dest)
}

private func partials(in dest: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dest)) ?? []).filter { $0.hasSuffix(".partial") }
}

/// Every problem `seed_run` (as `definitions`) has with C2-3 (empty: none).
private func seedProblems(_ definitions: String) throws -> [String] {
    var problems: [String] = []
    let a = randomModel("model-a.gguf", bytes: 3000)
    let b = randomModel("model-b.gguf", bytes: 5000)
    let previous = Data("a previous model, not the one in the table".utf8)

    // a good cache downloads nothing
    try withWork { w in
        let r = try seedRun(w, definitions: definitions, models: [a], previous: [a.name: a.data], mode: "good")
        if !r.curlCalls.isEmpty { problems.append("a cache that matched the table's size and SHA-256 made \(r.curlCalls.count) curl call(s): \(r.curlCalls)") }
        if tagged(r.ran, "RC") != "0" { problems.append("a good cache exited \(tagged(r.ran, "RC")), expected 0") }
        if (try? Data(contentsOf: URL(fileURLWithPath: r.dest + "/" + a.name))) != a.data { problems.append("a good cached file was changed") }
    }
    // only the model that is missing or wrong is downloaded
    try withWork { w in
        let r = try seedRun(w, definitions: definitions, models: [a, b], previous: [a.name: a.data], mode: "good")
        if r.curlCalls.contains(where: { $0.hasSuffix(a.name) }) { problems.append("the good cached model \(a.name) was asked for again: \(r.curlCalls)") }
        if !r.curlCalls.contains("get \(b.name)") { problems.append("the missing model \(b.name) was never downloaded: \(r.curlCalls)") }
        if (try? Data(contentsOf: URL(fileURLWithPath: r.dest + "/" + b.name))) != b.data { problems.append("the missing model was not put in place whole") }
    }
    // a failed download leaves the previous file untouched and removes only the .partial
    for (mode, label) in [("interrupted", "an interrupted download"), ("wrongsize", "a download of the wrong size"), ("badsha", "a download with the wrong SHA-256")] {
        try withWork { w in
            let r = try seedRun(w, definitions: definitions, models: [a], previous: [a.name: previous], mode: mode)
            if (try? Data(contentsOf: URL(fileURLWithPath: r.dest + "/" + a.name))) != previous {
                problems.append("\(label) lost or changed the previous cached file")
            }
            if !partials(in: r.dest).isEmpty { problems.append("\(label) left a .partial behind: \(partials(in: r.dest))") }
            if tagged(r.ran, "RC") == "0" { problems.append("\(label) exited 0") }
        }
    }
    // a good download replaces the previous file, over it, and leaves no .partial
    try withWork { w in
        let r = try seedRun(w, definitions: definitions, models: [a], previous: [a.name: previous], mode: "good")
        if (try? Data(contentsOf: URL(fileURLWithPath: r.dest + "/" + a.name))) != a.data { problems.append("a good download did not replace the previous file") }
        if !partials(in: r.dest).isEmpty { problems.append("a good download left a .partial behind") }
        if tagged(r.ran, "RC") != "0" { problems.append("a good download exited \(tagged(r.ran, "RC"))") }
    }
    return problems
}

@Suite("KitC2ModelCacheTests")
struct KitC2ModelCacheTests {

    @Test("bash -n finds no syntax error in kit-mirror.sh")
    func bashSyntax() throws {
        let ran = try bash("bash -n '\(scriptsDir.path)/kit-mirror.sh'")
        #expect(ran.status == 0 && ran.out.isEmpty && ran.err.isEmpty, "bash -n kit-mirror.sh exited \(ran.status): \(ran.err)")
    }

    @Test("seed_run skips a model whose cached file matches the table, and a failed download keeps the previous file and removes only the .partial")
    func seedRunKeepsGoodFiles() throws {
        let text = scriptText("kit-mirror.sh")
        let problems = try seedProblems(shellDefinitions(text) + "\n" + topLevelAssignments(text))
        #expect(problems.isEmpty, "kit-mirror.sh seed_run: \(problems)")
    }

    // PLANT: the code as it stood.
    @Test("the check can fail: the old seed_run (rm -f of the cached file, then download) is found losing the cache and downloading again")
    func oldSeedRunIsFound() throws {
        let problems = try seedProblems(oldSeedRun)
        #expect(problems.contains { $0.contains("lost or changed the previous cached file") }, "the old loss of the cached file was not found: \(problems)")
        #expect(problems.contains { $0.contains("curl call(s)") }, "the old download of a good cache was not found: \(problems)")
    }

    @Test("the text: no `rm` in kit-mirror.sh names the cached file under its real name, and nothing under cache/ is removed")
    func noRmOfTheCache() {
        let text = stripComments(scriptText("kit-mirror.sh"))
        for line in text.split(separator: "\n").map(String.init) where has(line, "(^|[ \\t;&|(])rm[ \\t]") {
            ok(!has(line, "\\$dest/\\$name\"?([ \\t;]|$)"), "kit-mirror.sh removes the cached file under its real name: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    // The kit's own local fixture server: `seed --selftest` runs seed_run against it in run/seed-selftest/ of a throwaway
    // KIT_ROOT. The test reads what the fixture server logged and what is left on disk, not only the script's own verdict.
    @Test("seed --selftest against the local fixture server: a good cache downloads nothing (the server's request log), a failed download keeps the previous file")
    func selftestAgainstTheFixtureServer() throws {
        try withWork { w in
            let ran = try bash("'\(scriptsDir.path)/kit-mirror.sh' seed --selftest", env: ["KIT_ROOT": w.root], limit: 300)
            let text = ran.out + ran.err
            #expect(ran.status == 0 && text.contains("SEED SELFTEST OK"), "seed --selftest exited \(ran.status): \(text.suffix(900))")
            let dir = w.root + "/run/seed-selftest"
            let log = read(URL(fileURLWithPath: dir + "/fixture.log")) ?? ""
            let fm = FileManager.default
            let served = ((try? fm.contentsOfDirectory(atPath: dir + "/served")) ?? []).sorted()
            let got = dir + "/got"
            var wholeFiles = 0
            for name in served {
                let servedData = try? Data(contentsOf: URL(fileURLWithPath: dir + "/served/" + name))
                let gotData = try? Data(contentsOf: URL(fileURLWithPath: got + "/" + name))
                if let g = gotData, g == servedData {
                    wholeFiles += 1
                    let bodies = log.split(separator: "\n").filter { $0.contains(" GET /blob/\(name) 200 ") }.count
                    #expect(bodies == 1, "the good file \(name) was served \(bodies) times by the fixture server: a good cache must download nothing")
                }
            }
            #expect(wholeFiles >= 1, "no good file was cached by the selftest (served \(served))")
            #expect(partials(in: got).isEmpty, "a .partial is left in \(got): \(partials(in: got))")
            // the previous files the selftest put in place before a failing download are still there, byte for byte
            let prev = dir + "/previous"
            let previous = ((try? fm.contentsOfDirectory(atPath: prev)) ?? []).sorted()
            #expect(previous.count >= 2, "the selftest keeps no previous files (a differing and a wrong-size download): \(previous)")
            for name in previous {
                let before = try? Data(contentsOf: URL(fileURLWithPath: prev + "/" + name))
                let after = try? Data(contentsOf: URL(fileURLWithPath: got + "/" + name))
                #expect(before != nil && before == after, "the previous file \(name) was lost or changed by a failed download")
            }
            #expect(text.contains("U1 CACHED"), "the second run of the selftest never said a model was already cached (U1 CACHED)")
            // the real cache of the kit is never named: the selftest only touched its own KIT_ROOT
            #expect(!text.contains("/sesame-kit/cache"), "the selftest names the real kit cache: \(text)")
        }
    }
}

// =====================================================================================================================
// C2-4: kit-trace.sh kills only an fs_usage of its own
// =====================================================================================================================

/// stop_pids as it stood before the part (a PLANT): it kills whatever pid the file names, if the pid is alive.
private let oldStopPids = #"""
stop_pids() {
  local pidf="$1" alive="" p sig i still
  for p in $(cat "$pidf" 2>/dev/null); do pid_alive "$p" && alive="$alive $p"; done
  if [ -n "$alive" ]; then
    need_admin || { echo "the fs_usage processes keep running (pids:$alive)"; return 3; }
    for sig in INT TERM KILL; do
      for p in $alive; do sudo -n kill -"$sig" "$p" 2>/dev/null; done
      for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        still=""
        for p in $alive; do pid_alive "$p" && still="$still $p"; done
        [ -z "$still" ] && break
        sleep 0.2
      done
      alive="$still"
      [ -z "$alive" ] && break
    done
    [ -z "$alive" ] || { echo "the fs_usage processes did not end (pids:$alive)"; return 1; }
  fi
  rm -f "$pidf"
  sleep 0.5
  return 0
}
"""#

/// stop_pids with a fake `ps` and `sudo`: $AUX/procs.tsv holds "<pid><TAB><command line>" for every live process; `sudo -n kill`
/// logs the signal and the pid to $AUX/kills and ends the process. Returns the pids killed, the status and whether the pid file is left.
private func stopPidsRun(_ w: Work, definitions: String, procs: [(pid: Int, command: String)], pidFile: [Int]) throws -> (killed: [Int], rc: String, pidFileLeft: Bool, out: String) {
    let pidf = w.aux + "/trace-x.pid"
    try Data((pidFile.map(String.init).joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: pidf))
    try Data(procs.map { "\($0.pid)\t\($0.command)" }.joined(separator: "\n").appending("\n").utf8).write(to: URL(fileURLWithPath: w.aux + "/procs.tsv"))
    let ran = try bash(#"""
    export KIT_ROOT='\#(w.root)'
    AUX='\#(w.aux)'
    . '\#(libDir.path)/common.sh'
    ps() {
      local pid="" what="" a prev=""
      for a in "$@"; do
        [ "$prev" = "-p" ] && pid="$a"
        [ "$prev" = "-o" ] && what="$a"
        prev="$a"
      done
      local line
      line="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; f = 1 } END { exit f ? 0 : 1 }' "$AUX/procs.tsv")" || return 1
      case "$what" in
        pid=*) echo "$pid" ;;
        command=*|args=*) echo "$line" ;;
        comm=*) echo "${line%% *}" ;;
        *) echo "$line" ;;
      esac
    }
    sudo() {
      [ "$1" = "-n" ] || { echo "sudo without -n: $*" >> "$AUX/violations"; return 99; }
      shift
      case "$1" in
        true) return 0 ;;
        kill) echo "$2 $3" >> "$AUX/kills"; awk -F'\t' -v p="$3" '$1 != p' "$AUX/procs.tsv" > "$AUX/procs.new"; mv "$AUX/procs.new" "$AUX/procs.tsv" ;;
        *) return 98 ;;
      esac
    }
    \#(definitions)
    stop_pids '\#(pidf)'; echo "RC $?"
    """#)
    let kills = (read(URL(fileURLWithPath: w.aux + "/kills")) ?? "").split(separator: "\n")
        .compactMap { Int($0.split(separator: " ").last ?? "") }
    return (kills, tagged(ran, "RC"), FileManager.default.fileExists(atPath: pidf), ran.out + ran.err)
}

private func stopPidsProblems(_ definitions: String) throws -> [String] {
    var problems: [String] = []
    let ours = "/usr/bin/fs_usage -w -f filesys"
    // our own fs_usage (file and network) is stopped
    try withWork { w in
        let r = try stopPidsRun(w, definitions: definitions, procs: [(501, ours), (502, "/usr/bin/fs_usage -w -f network")], pidFile: [501, 502])
        if Set(r.killed) != [501, 502] { problems.append("our two fs_usage processes were not both stopped (killed \(r.killed))") }
        if r.rc != "0" || r.pidFileLeft { problems.append("after stopping our traces the status was \(r.rc) and the pid file left: \(r.pidFileLeft)") }
    }
    // a live process that is not fs_usage (a stale pid, reused by something else) is never killed
    try withWork { w in
        let r = try stopPidsRun(w, definitions: definitions, procs: [(777, "/Applications/Xcode.app/Contents/MacOS/Xcode")], pidFile: [777])
        if !r.killed.isEmpty { problems.append("a stale pid file made it kill pid 777, which is not fs_usage (killed \(r.killed))") }
        if r.rc != "0" || r.pidFileLeft { problems.append("a stale pid file was not removed quietly (status \(r.rc), file left: \(r.pidFileLeft))") }
    }
    // an fs_usage that is not ours (another trace, other flags) is never killed
    try withWork { w in
        let r = try stopPidsRun(w, definitions: definitions, procs: [(888, "/usr/bin/fs_usage -w -f pathname Safari")], pidFile: [888])
        if !r.killed.isEmpty { problems.append("it killed pid 888, an fs_usage that is not ours (killed \(r.killed))") }
    }
    // GUESS: if macOS hides the arguments of a process that runs as administrator, `ps` shows the bare executable; it is still
    // an fs_usage recorded in our own pid file, so it is stopped (a trace is never left running as administrator)
    try withWork { w in
        let r = try stopPidsRun(w, definitions: definitions, procs: [(601, "/usr/bin/fs_usage")], pidFile: [601])
        if r.killed != [601] { problems.append("an fs_usage whose arguments ps cannot show was not stopped (killed \(r.killed))") }
    }
    // a dead pid is removed without a kill
    try withWork { w in
        let r = try stopPidsRun(w, definitions: definitions, procs: [(1, "/sbin/launchd")], pidFile: [4242])
        if !r.killed.isEmpty || r.pidFileLeft || r.rc != "0" { problems.append("a dead pid in the file was killed or left behind (killed \(r.killed), left \(r.pidFileLeft), rc \(r.rc))") }
    }
    // a mixed file: ours is stopped, the stranger is left alone
    try withWork { w in
        let r = try stopPidsRun(w, definitions: definitions, procs: [(501, ours), (999, "/usr/bin/vim notes.txt")], pidFile: [501, 999])
        if r.killed != [501] { problems.append("with one of ours and one stranger the kills were \(r.killed), expected [501]") }
    }
    return problems
}

@Suite("KitC2TraceStopTests")
struct KitC2TraceStopTests {

    @Test("stop_pids kills a pid only when the process there is our fs_usage; a stale or foreign pid is removed from the file without a kill")
    func stopsOnlyOurs() throws {
        let text = scriptText("kit-trace.sh")
        let definitions = shellDefinitions(text) + "\n" + topLevelAssignments(text)
        let problems = try stopPidsProblems(definitions)
        #expect(problems.isEmpty, "kit-trace.sh stop_pids: \(problems)")
    }

    // PLANT: the code as it stood.
    @Test("the check can fail: the old stop_pids (kill whatever pid the file names) is found killing a stranger")
    func oldStopPidsIsFound() throws {
        let text = scriptText("kit-trace.sh")
        let others = shellDefinitions(text).replacingOccurrences(of: functionDefinition("stop_pids", in: text), with: "")
        let problems = try stopPidsProblems(others + "\n" + oldStopPids + "\n" + topLevelAssignments(text))
        #expect(problems.contains { $0.contains("not fs_usage") }, "the old kill of a stale pid was not found: \(problems)")
        #expect(problems.contains { $0.contains("not ours") }, "the old kill of a foreign fs_usage was not found: \(problems)")
    }

    private func functionDefinition(_ name: String, in text: String) -> String {
        shellDefinitions(text, only: [name])
    }

    @Test("kit-trace.sh still runs every administrator call as sudo -n, and the kill is `sudo -n kill`")
    func sudoNOnly() {
        let lines = stripComments(scriptText("kit-trace.sh")).split(separator: "\n").map(String.init)
            .filter { has($0, "(^|[^A-Za-z0-9_.-])sudo[ \\t]") }
        ok(!lines.isEmpty, "kit-trace.sh never uses sudo")
        for l in lines { ok(has(l, "sudo[ \\t]+-n\\b"), "a sudo without -n: \(l)") }
        ok(lines.contains { has($0, "sudo[ \\t]+-n[ \\t]+kill\\b") }, "kit-trace.sh no longer stops fs_usage with `sudo -n kill`")
    }
}

// =====================================================================================================================
// C2-5: the login item the kit's copy of the app registers is unregistered, and login-item reads only that copy's record
// =====================================================================================================================

// A hand-written `sfltool dumpbtm` text. GUESS (K24, settled at the accept stage): a record starts at `#<n>:`, carries
// `Identifier:` (with a number and a dot in front for some types), `Disposition:` and the path as `URL:` and/or
// `Executable Path:`; the path may be spelled /private/var for a /var folder.
private let kitApp = "/var/folders/zz/T/sesame-kit/apps/Sesame.app"
private let kitAppReal = "/private/var/folders/zz/T/sesame-kit/apps/Sesame.app"

private func record(_ n: Int, identifier: String, disposition: String, path: String?, urlOnly: Bool = false) -> String {
    var s = """
     #\(n):
                     UUID: 6C0F0F4D-0000-4000-8000-00000000000\(n)
                     Name: Sesame
           Developer Name: (null)
          Team Identifier: (null)
                     Type: app (0x2)
                    Flags: [ ] (0)
              Disposition: \(disposition)
               Identifier: 2.\(identifier)

    """
    if let path {
        s += "                      URL: file://\(path)/\n"
        if !urlOnly { s += "          Executable Path: \(path)/Contents/MacOS/Sesame\n" }
    }
    s += "               Generation: 1\n"
    return s
}

private func dump(_ records: [String]) -> String {
    """
    ========================
     Records for UID 501 : 11111111-2222-3333-4444-555555555555
    ========================

     Items:

    \(records.joined(separator: "\n"))
    """
}

private let enabled = "[enabled, allowed, visible, not notified] (0xb)"
private let disabled = "[disabled, allowed, visible, not notified] (0xa)"
private let appId = "app.sesame.Sesame"
private let other = "com.example.Other"

/// btm_state as it stood before the part (a PLANT): the identifier alone decides.
private let oldBtmState = #"""
btm_state() {
  awk -v id="$2" '
    function flush(   v) {
      if (ident != "") {
        v = ident; sub(/^[0-9]+\./, "", v)
        if (ident == id || v == id) {
          if (disp ~ /enabled/) en = 1
          else if (disp ~ /disabled/) dis = 1
          else bad = 1
        }
      }
      ident = ""; disp = ""
    }
    /^[ \t]*#[0-9]+:/ { flush(); next }
    /^[ \t]*Identifier:/ { ident = $0; sub(/^[ \t]*Identifier:[ \t]*/, "", ident); sub(/[ \t]+$/, "", ident); next }
    /^[ \t]*Disposition:/ { disp = $0; sawdisp = 1; next }
    END {
      flush()
      if (!sawdisp) print "unparsed"
      else if (en) print "enabled"
      else if (dis) print "disabled"
      else if (bad) print "unparsed"
      else print "none"
    }' "$1"
}
"""#

/// `btm_state <dump> <identifier> <kit app> <kit app, real path>` on a hand-written dump.
private func btm(_ definitions: String, _ text: String, id: String = appId) throws -> String {
    try withWork { w in
        try Data(text.utf8).write(to: URL(fileURLWithPath: w.aux + "/dump.txt"))
        let ran = try bash(#"""
        \#(definitions)
        btm_state '\#(w.aux)/dump.txt' '\#(id)' '\#(kitApp)' '\#(kitAppReal)'
        """#)
        return ran.lines.last ?? ""
    }
}

private func btmProblems(_ definitions: String) throws -> [String] {
    var problems: [String] = []
    func expect(_ got: String, _ want: String, _ what: String) { if got != want { problems.append("\(what): read \"\(got)\", expected \"\(want)\"") } }
    // the kit's own record, spelled either way
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: kitApp)])), "enabled", "our record, enabled (/var spelling)")
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: kitAppReal)])), "enabled", "our record, enabled (/private/var spelling)")
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: disabled, path: kitApp)])), "disabled", "our record, disabled")
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: kitApp, urlOnly: true)])), "enabled", "our record with only a URL")
    // a stale record of another build, same identifier: not ours
    let stale = projectRoot.appendingPathComponent("dist/Sesame.app").path
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: stale)])), "none", "a stale record of the dist build, enabled")
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: "/var/folders/qq/T/sesame-kit/apps/Sesame.app")])), "none", "a stale record of an earlier kit root, enabled")
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: "/var/folders/zz/T/sesame-kit/apps/Sesame.app.old")])), "none", "a record whose path only starts like ours")
    // both: the answer is the kit copy's, not the stale record's
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: stale), record(2, identifier: appId, disposition: disabled, path: kitApp)])), "disabled", "a stale enabled record and our disabled one")
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: disabled, path: stale), record(2, identifier: appId, disposition: enabled, path: kitApp)])), "enabled", "a stale disabled record and our enabled one")
    // other apps and the control: an identifier that cannot exist
    expect(try btm(definitions, dump([record(1, identifier: other, disposition: enabled, path: kitApp)])), "none", "another identifier at our path")
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: kitApp)]), id: "app.sesame.Absent-1-2"), "none", "the control identifier")
    // GUESS: a record of our identifier that names no path cannot be told from a stale one; it is unreadable, never a pass
    expect(try btm(definitions, dump([record(1, identifier: appId, disposition: enabled, path: nil)])), "unparsed", "our identifier with no path in the record")
    return problems
}

@Suite("KitC2LoginItemTests")
struct KitC2LoginItemTests {

    @Test("bash -n finds no syntax error in kit-privacy.sh and kit-reset.sh")
    func bashSyntax() throws {
        for name in ["kit-privacy.sh", "kit-reset.sh"] {
            let ran = try bash("bash -n '\(scriptsDir.path)/\(name)'")
            #expect(ran.status == 0 && ran.err.isEmpty, "bash -n \(name) exited \(ran.status): \(ran.err)")
        }
    }

    @Test("btm_state compares the record's executable path (or URL) with the kit's app path: a stale record from another build reads none, and the answer is the kit copy's")
    func btmStateComparesThePath() throws {
        let definitions = shellDefinitions(scriptText("kit-privacy.sh"), only: ["btm_state"])
        ok(!definitions.isEmpty, "btm_state is not defined in kit-privacy.sh")
        let problems = try btmProblems(definitions)
        #expect(problems.isEmpty, "btm_state: \(problems)")
    }

    // PLANT: the parser as it stood reads a stale record as the kit's own.
    @Test("the check can fail: the old btm_state (identifier only) reads a stale enabled record as enabled")
    func oldBtmStateIsFound() throws {
        let problems = try btmProblems(oldBtmState)
        #expect(problems.contains { $0.contains("stale record") && $0.contains("read \"enabled\"") }, "the old stale-record read was not found: \(problems)")
    }

    @Test("btm_state with no app path still reads by identifier alone, as the control does")
    func btmStateWithoutPath() throws {
        let definitions = shellDefinitions(scriptText("kit-privacy.sh"), only: ["btm_state"])
        try withWork { w in
            try Data(dump([record(1, identifier: appId, disposition: enabled, path: "/anywhere/Sesame.app")]).utf8).write(to: URL(fileURLWithPath: w.aux + "/dump.txt"))
            let ran = try bash(#"""
            \#(definitions)
            echo "PRESENT $(btm_state '\#(w.aux)/dump.txt' '\#(appId)')"
            echo "ABSENT $(btm_state '\#(w.aux)/dump.txt' 'app.sesame.Absent-9-9')"
            """#)
            #expect(tagged(ran, "PRESENT") == "enabled" && tagged(ran, "ABSENT") == "none", "no-path reads: \(ran.lines)")
        }
    }

    @Test("login-item gives btm_state the kit's app path, both spellings, when it reads Sesame's own record")
    func loginItemPassesTheKitApp() {
        let text = stripComments(scriptText("kit-privacy.sh"))
        let body = functionBody("cmd_login_item", in: text)
        let call = body.split(separator: "\n").map(String.init).first { has($0, "btm_state[^\\n]*\"\\$id\"") } ?? ""
        ok(!call.isEmpty, "cmd_login_item never calls btm_state with the app's identifier")
        ok(call.contains("KIT_APP\"") || call.contains("$KIT_APP ") || call.contains("${KIT_APP}"), "the read of Sesame's record does not pass the kit's app path (KIT_APP): \(call)")
        ok(call.contains("KIT_APP_REAL"), "the read of Sesame's record does not pass the /private spelling of the kit's app path (KIT_APP_REAL): \(call)")
        let control = body.split(separator: "\n").map(String.init).first { has($0, "btm_state[^\\n]*\"\\$cid\"") } ?? ""
        ok(!control.isEmpty, "cmd_login_item lost its control read of an absent identifier")
    }

    // MARK: S7.18 and the cleanup unregister the login item through the app's own switch

    @Test("S7.18 ends by turning Launch at login off again and reading that no entry is left enabled")
    func s718TurnsTheSwitchOffAtTheEnd() {
        let text = stripComments(scriptText("kit-lib/checks-s7.sh"))
        let body = functionBody("s7_check_18", in: text)
        let lines = body.split(separator: "\n").map(String.init)
        let clicks = lines.indices.filter { has(lines[$0], "click[ ]+\"Launch at login\"") }
        let readings = lines.indices.filter { has(lines[$0], "s7_login_item[ ]+[a-z-]+") }
        ok(clicks.count >= 3, "S7.18 presses Launch at login \(clicks.count) time(s), expected three (off, on again, and off at the end)")
        ok(readings.count >= 4, "S7.18 reads the login item \(readings.count) time(s), expected four (on, off, on again, and after the final off)")
        if let lastClick = clicks.last, let lastReading = readings.last {
            ok(lastReading > lastClick, "S7.18's last reading comes before its last press of the switch: it does not read what the final off left")
            let tail = lines[lastReading...].joined(separator: "\n")
            ok(has(tail, "absent") && has(tail, "present and disabled"), "after the final off S7.18 does not accept exactly absent or disabled")
            ok(has(tail, "s7_why"), "after the final off S7.18 does not fail when the entry is still enabled")
        }
    }

    // unregister_login_item <fake kit-ax.sh>: Settings, the Indexing section, the switch read from the dump, one press if it is on.
    private func unregisterRun(_ w: Work, running: Bool, switchValue: String?, definitions: String? = nil) throws -> (ran: Ran, calls: [String]) {
        let text = scriptText("kit-reset.sh")
        let defs = definitions ?? shellDefinitions(text, only: ["unregister_login_item"])
        let fake = w.aux + "/fake-ax.sh"
        let dumpLine = switchValue.map { "    AXCheckBox label=\"Launch at login\" value=\"\($0)\"" } ?? "    AXButton label=\"Start indexing\""
        try Data("""
        #!/bin/bash
        echo "$1 $2 $3" >> "\(w.aux)/calls"
        case "$1" in
          dump)
            echo 'window 700 x 480 at 100,100 title Settings'
            echo '  AXWindow/AXStandardWindow label="Settings"'
            echo '\(dumpLine)' ;;
        esac
        exit 0
        """.utf8).write(to: URL(fileURLWithPath: fake))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        let pidCommand = running ? "echo 4242" : "true"
        let ran = try bash(#"""
        export KIT_ROOT='\#(w.root)'
        . '\#(libDir.path)/common.sh'
        . '\#(libDir.path)/axdump.sh'
        kq() { KIT_NO_EVIDENCE=1 "$@"; }
        sleep() { :; }
        kit_ps_ok() { true; }
        kit_pid_of() { \#(pidCommand); }
        settings_section() { echo "section $1" >> '\#(w.aux)/calls'; return 0; }
        \#(defs)
        unregister_login_item '\#(fake)'; echo "RC $?"
        """#)
        let calls = (read(URL(fileURLWithPath: w.aux + "/calls")) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return (ran, calls)
    }

    @Test("kit-reset.sh unregister_login_item: with the app running and the switch on it presses Launch at login once, after selecting Indexing")
    func unregisterPressesWhenOn() throws {
        try withWork { w in
            let r = try unregisterRun(w, running: true, switchValue: "1")
            #expect(tagged(r.ran, "RC") == "0", "it exited \(tagged(r.ran, "RC")): \(r.ran.lines)")
            #expect(r.calls.filter { $0.hasPrefix("click Launch at login") }.count == 1, "the switch was pressed \(r.calls.filter { $0.hasPrefix("click Launch at login") }.count) time(s): \(r.calls)")
            if let s = r.calls.firstIndex(of: "section Indexing"), let c = r.calls.firstIndex(where: { $0.hasPrefix("click Launch at login") }) {
                #expect(s < c, "Launch at login was pressed before the Indexing section was selected: \(r.calls)")
            } else {
                Issue.record("no settings_section Indexing before the press: \(r.calls)")
            }
            #expect(r.calls.contains { $0.hasPrefix("click Settings") }, "Settings was never opened: \(r.calls)")
        }
    }

    // PLANT: a version that presses without reading would turn an off switch on.
    @Test("unregister_login_item presses nothing when the switch is already off or absent, or when the app is not running")
    func unregisterLeavesAnOffSwitchAlone() throws {
        try withWork { w in
            let r = try unregisterRun(w, running: true, switchValue: "0")
            #expect(!r.calls.contains { $0.hasPrefix("click Launch at login") }, "an off switch was pressed (it would register the login item): \(r.calls)")
        }
        try withWork { w in
            let r = try unregisterRun(w, running: true, switchValue: nil)
            #expect(!r.calls.contains { $0.hasPrefix("click Launch at login") }, "a missing switch was pressed: \(r.calls)")
        }
        try withWork { w in
            let r = try unregisterRun(w, running: false, switchValue: "1")
            #expect(r.calls.isEmpty, "the app was not running and yet the driver was called: \(r.calls)")
            #expect(tagged(r.ran, "RC") == "0", "no running app is not an error: \(r.ran.lines)")
        }
    }

    @Test("the check can fail: a version that presses the switch without reading it is found pressing an off switch")
    func pressingWithoutReadingIsFound() throws {
        let blind = #"""
        unregister_login_item() {
          kq "$1" click "Settings…" >/dev/null 2>&1
          settings_section Indexing
          kq "$1" click "Launch at login" >/dev/null 2>&1
        }
        """#
        try withWork { w in
            let r = try unregisterRun(w, running: true, switchValue: "0", definitions: blind)
            #expect(r.calls.contains { $0.hasPrefix("click Launch at login") }, "the blind version did not press, so the test cannot tell it from the real one")
        }
    }

    @Test("--cleanup unregisters the login item while the app still runs: before kit-launch.sh stop, never through osascript")
    func cleanupUnregistersBeforeQuit() {
        let text = stripComments(scriptText("kit-reset.sh"))
        let cleanup = functionBody("do_cleanup", in: text)
        guard let unregister = firstIndex(cleanup, "unregister_login_item"), let stop = firstIndex(cleanup, "kit-launch\\.sh\"?[ ]+stop") else {
            Issue.record("do_cleanup does not call unregister_login_item before `kit-launch.sh stop`")
            return
        }
        #expect(unregister < stop, "the login item is unregistered after the app was quit")
        #expect(!has(text, "osascript"), "kit-reset.sh calls osascript itself instead of kit-ax.sh")
        let body = functionBody("unregister_login_item", in: text)
        ok(has(body, "click[ ]+\"Launch at login\""), "unregister_login_item never presses \"Launch at login\"")
        ok(has(body, "settings_section[ ]+Indexing"), "unregister_login_item does not select the Indexing section first")
        ok(has(body, "ax_switch"), "unregister_login_item does not read the switch before it presses it")
    }
}
