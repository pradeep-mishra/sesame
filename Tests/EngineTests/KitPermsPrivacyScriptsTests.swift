import Foundation
import Testing

// plan-2-t7, tester step: kit part 3, the administrator sentence (scripts/kit-perms.sh ask-admin) and the login-item
// reader (scripts/kit-privacy.sh login-item), plus the two Caches folders in the library scan's list. Written from
// verify.md (Drive, Kit scripts, Doctor, Guesses K24 and K31), the S6 and S7 feature maps and the plan-2-t7 entry only;
// no product source is read, and neither script may read `Sources/`.
//
// Static proof only (plan-2-tasks.md, Conventions): `sfltool` and the sentence are exercised for real at the accept
// stage (blocks A and C, S7.18). Nothing here runs `kit-perms.sh ask-admin`, `kit-privacy.sh login-item` with valid
// arguments, `sfltool` or `sudo`, asks for a password or launches Sesame. The only runs are `bash -n`, and each script
// with no mode, with an unknown mode and with arguments that are wrong before any probe, any `sudo` or any file could
// start; those must print usage, exit 2, start nothing and write nothing.
//
// What a text assertion reads is the script's code with its comment lines removed, so a comment can never satisfy a
// check. Text checks are tied to the sentences of verify.md and of the plan-2-t7 entry:
//   - kit-perms.sh `ask-admin`: prints exactly the sentence "macOS only lets an administrator watch which files and
//     connections Sesame uses, and read the login item record; you will be asked for your password once" (a final
//     full stop is allowed), to standard output, and only then primes the session with `sudo -v`; a refusal prints
//     `NEEDS A PERSON` and exits 3; the one `sudo -v` is the only `sudo` of the script without `-n`; the checks that
//     need administrator rights (S6.8, S7.4, S7.18, S8.2, S8.3, S8.7, S8.8, S4.8) still name the `admin` step, which
//     is read with `sudo -n true` and makes only those checks NEEDS-A-PERSON;
//   - kit-privacy.sh `login-item`: a mode of its own in the dispatch (no longer `not built yet`), named in the usage
//     text; runs `sudo -n true` first (no session is exit 3 `NEEDS A PERSON` naming `ask-admin`) and then
//     `sudo -n sfltool dumpbtm`; the identifier it looks for is read from the bundle's Info.plist, never typed; it
//     prints one line that is exactly `present and enabled`, `present and disabled`, `absent` or `unreadable`; it
//     also prints the last `login status=` line of `logs/app.log`; its control runs the same parser on a different
//     identifier that cannot exist (made with `$RANDOM` or `$$`), must read `absent`, and a control that does not is
//     exit 4 `not valid`; every `sudo` of the script is `sudo -n`;
//   - the library scan of plan 1 keeps its modes, flags, controls and verdict lines, and its scan list now names
//     `Caches/app.sesame.Sesame` and `Caches/SesameHelper` in code that is not a printed message.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private struct Script: Sendable, CustomStringConvertible {
    let name: String
    /// Lines the usage text must carry, each compared as a prefix of a trimmed usage line.
    let usageLines: [String]
    var description: String { name }
}

private let permsScript = Script(
    name: "kit-perms.sh",
    usageLines: [
        "usage: kit-perms.sh check [--for <check id>]",
        "kit-perms.sh ask-admin",
    ])
private let privacyScript = Script(
    name: "kit-privacy.sh",
    usageLines: [
        "usage: kit-privacy.sh ping | baseline | static-allowlist",
        "kit-privacy.sh plist [--file <Info.plist>]",
        "kit-privacy.sh entitlements [--app <Sesame.app> | --from <entitlements.xml>]",
        "kit-privacy.sh library-scan [--delete-first] [--ignore-sesame-folder] [--new-only]",
        "kit-privacy.sh layout [--dir <folder>]",
    ])
private let bothScripts = [permsScript, privacyScript]

/// Arguments that are wrong before any probe, any sudo or any file could start: usage, exit 2.
private struct BadCall: Sendable, CustomStringConvertible {
    let script: Script
    let args: [String]
    var description: String { "\(script.name) \(args.joined(separator: " "))" }
}

private let badCalls: [BadCall] = [
    BadCall(script: permsScript, args: ["check", "extra"]),
    BadCall(script: permsScript, args: ["check", "--for"]),
    BadCall(script: permsScript, args: ["check", "--for", "NOSUCH.1"]),
    BadCall(script: permsScript, args: ["check", "--for", "S7.18", "extra"]),
    BadCall(script: permsScript, args: ["ask-admin", "extra"]),
    BadCall(script: privacyScript, args: ["login-item", "extra"]),
    BadCall(script: privacyScript, args: ["login-item", "--sideways"]),
    BadCall(script: privacyScript, args: ["ping", "extra"]),
    BadCall(script: privacyScript, args: ["baseline", "extra"]),
    BadCall(script: privacyScript, args: ["static-allowlist", "extra"]),
    BadCall(script: privacyScript, args: ["plist", "--sideways"]),
    BadCall(script: privacyScript, args: ["entitlements", "--sideways"]),
    BadCall(script: privacyScript, args: ["library-scan", "--sideways"]),
    BadCall(script: privacyScript, args: ["layout", "--sideways"]),
    BadCall(script: privacyScript, args: ["layout", "--dir"]),
]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitpp-out-" + UUID().uuidString)
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
    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    return Ran(status: status, output: text)
}

/// The path of scripts/<name>, or nil after recording the reason a missing script is red.
private func scriptPath(_ name: String) -> String? {
    let url = projectRoot.appendingPathComponent("scripts").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record("scripts/\(name) not found")
        return nil
    }
    return url.path
}

/// The script's code: every line that is not a comment (the shebang line is dropped too).
private func code(of name: String) -> String? {
    guard let path = scriptPath(name), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
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

/// A fresh, empty KIT_ROOT (the kit requires a folder named sesame-kit*), removed afterwards.
private func withKitRoot<T>(_ body: (String) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-kit-permsprivacy-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url.resolvingSymlinksInPath().path)
}

/// Every file or link under the folder (a folder alone is not a file).
private func filesUnder(_ root: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
    var found: [String] = []
    for case let rel as String in walker {
        var isDir: ObjCBool = false
        let full = root + "/" + rel
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) == nil { continue }
        found.append(rel)
    }
    return found
}

/// "<pid> <name>" of every process named `sfltool`, `sudo` or `fs_usage`: what a call that reached the
/// administrator part would leave running.
private func adminProcesses() throws -> Set<String> {
    var found: Set<String> = []
    let names = try run("/bin/ps", ["-axo", "pid=,comm="])
    for line in names.output.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { continue }
        let name = (parts[1].trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        if ["sfltool", "sudo", "fs_usage"].contains(name) { found.insert("\(parts[0]) \(name)") }
    }
    return found
}

/// The shell functions of a script: name to body, read from `name() {` to a line that is just `}`.
private func shellFunctions(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if line.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{$", options: .regularExpression) != nil {
                name = String(line.dropLast(4))
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

/// The function's code with every call to another function of the same script replaced, in place, by that
/// function's own code (a call inside a function is read as if written where it stands). Depth is capped.
private func expanded(_ name: String, _ functions: [String: String], depth: Int = 0) -> String {
    guard depth < 5, let body = functions[name] else { return "" }
    var out: [String] = []
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        out.append(line)
        for other in functions.keys.sorted() where other != name {
            if has(line, "(^|[^A-Za-z0-9_.-])\(NSRegularExpression.escapedPattern(for: other))([^A-Za-z0-9_.-]|$)") {
                out.append(expanded(other, functions, depth: depth + 1))
            }
        }
    }
    return out.joined(separator: "\n")
}

/// The function a mode's dispatch line calls: the line holding `<mode>)` (not `<mode>|`), and the last word on it
/// that is a function of the script. nil when the dispatch has no line of its own for the mode.
private func dispatchTarget(_ mode: String, in text: String, functions: [String: String]) -> String? {
    let marker = "(^|[ \\t|(])\(NSRegularExpression.escapedPattern(for: mode))\\)"
    for line in text.split(separator: "\n").map(String.init) where has(line, marker) {
        let words = line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
        if let target = words.last(where: { functions[$0] != nil }) { return target }
    }
    return nil
}

/// The lines of `text` that call sudo, one string each.
private func sudoLines(_ text: String) -> [String] {
    text.split(separator: "\n").map(String.init).filter { has($0, "(^|[^A-Za-z0-9_.-])sudo[ \\t]") }
}

private func usageLines(_ output: String) -> [String] {
    output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

@Suite("KitPermsPrivacyScriptsTests")
struct KitPermsPrivacyScriptsTests {

    // MARK: the files themselves

    @Test("the script exists, is executable and is a bash script (the kit is bash 3.2)", arguments: bothScripts)
    fileprivate func existsExecutableBash(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        #expect(FileManager.default.isExecutableFile(atPath: path), "scripts/\(script.name) is not executable")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/bash\n"), "scripts/\(script.name) line 1 is not #!/bin/bash (the kit is bash 3.2)")
    }

    @Test("bash -n finds no syntax error in the two scripts", arguments: bothScripts)
    fileprivate func bashSyntax(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        let ran = try run("/bin/bash", ["-n", path])
        #expect(ran.status == 0, "bash -n scripts/\(script.name) exited \(ran.status): \(ran.output)")
        #expect(ran.output.isEmpty, "bash -n scripts/\(script.name) printed: \(ran.output)")
    }

    @Test("neither script reads Sources/", arguments: bothScripts)
    fileprivate func neverReadsSources(_ script: Script) throws {
        guard let text = code(of: script.name) else { return }
        ok(!text.contains("Sources"), "scripts/\(script.name) names Sources: the kit never reads the product's source")
    }

    // MARK: no mode, an unknown mode, arguments wrong before anything starts: usage, exit 2, nothing started

    @Test("no mode prints the usage text, exits 2, starts nothing and writes nothing", arguments: bothScripts)
    fileprivate func noModeIsUsage(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        let before = try adminProcesses()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, [], env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        let after = try adminProcesses()
        #expect(ran.status == 2, "scripts/\(script.name) with no mode exited \(ran.status), wanted 2: \(ran.output)")
        let usage = usageLines(ran.output)
        for line in script.usageLines {
            #expect(usage.contains { $0.hasPrefix(line) }, "no usage line starts `\(line)`; the output was: \(ran.output)")
        }
        #expect(after.subtracting(before).isEmpty, "a process was left behind: \(after.subtracting(before).sorted())")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
    }

    @Test("an unknown mode is usage too: exit 2, nothing started, nothing written", arguments: bothScripts)
    fileprivate func unknownModeIsUsage(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        let before = try adminProcesses()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, ["frobnicate"], env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        let after = try adminProcesses()
        #expect(ran.status == 2, "scripts/\(script.name) frobnicate exited \(ran.status), wanted 2: \(ran.output)")
        #expect(ran.output.contains("usage: \(script.name) "), "no usage text: \(ran.output)")
        #expect(after.subtracting(before).isEmpty, "a process was left behind: \(after.subtracting(before).sorted())")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
    }

    @Test("a mode with arguments that are missing or wrong is usage, exit 2, before any probe or sudo", arguments: badCalls)
    fileprivate func badArgumentsAreUsage(_ call: BadCall) throws {
        guard let path = scriptPath(call.script.name) else { return }
        let before = try adminProcesses()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, call.args, env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        let after = try adminProcesses()
        #expect(ran.status == 2, "scripts/\(call) exited \(ran.status), wanted 2 (usage): \(ran.output)")
        #expect(ran.output.contains("usage: \(call.script.name) "), "no usage text: \(ran.output)")
        #expect(after.subtracting(before).isEmpty, "a process was left behind: \(after.subtracting(before).sorted())")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
    }

    @Test("the usage text of kit-privacy.sh names the login-item mode")
    func usageNamesLoginItem() throws {
        guard let path = scriptPath(privacyScript.name) else { return }
        let ran = try withKitRoot { root in try run(path, [], env: ["KIT_ROOT": root]) }
        #expect(ran.status == 2, "kit-privacy.sh with no mode exited \(ran.status), wanted 2: \(ran.output)")
        #expect(usageLines(ran.output).contains { has($0, "(^|[ \\t|])login-item($|[ \\t|])") },
                "no usage line names `login-item`; the output was: \(ran.output)")
    }

    // MARK: kit-perms.sh ask-admin: the plain sentence, then the one prompt

    private static let sentence = "macOS only lets an administrator watch which files and connections Sesame uses, and read the login item record; you will be asked for your password once"

    @Test("kit-perms.sh ask-admin prints exactly the plain sentence, to standard output, and only then primes sudo")
    func askAdminSentenceThenPrime() throws {
        guard let text = code(of: permsScript.name) else { return }
        let functions = shellFunctions(in: text)
        guard let handler = dispatchTarget("ask-admin", in: text, functions: functions) else {
            Issue.record("the dispatch of kit-perms.sh has no `ask-admin)` line calling a function")
            return
        }
        let body = expanded(handler, functions)
        let escaped = NSRegularExpression.escapedPattern(for: Self.sentence)
        let printed = "(echo|printf)[ \\t]+(-[A-Za-z]+[ \\t]+)?[\"']\(escaped)\\.?(\\\\n)?[\"']"
        guard let said = firstIndex(body, printed) else {
            Issue.record("`ask-admin` never prints exactly the sentence \"\(Self.sentence)\" as the whole of a quoted echo or printf string")
            return
        }
        let sayLine = body.split(separator: "\n").map(String.init).first { has($0, printed) } ?? ""
        ok(!has(sayLine, ">&2"), "the sentence goes to standard error: a person who pipes the output never sees why the password is asked")
        guard let primed = firstIndex(body, "(^|[^A-Za-z0-9_.-])sudo[ \\t]+-v\\b") else {
            Issue.record("`ask-admin` never primes the session with `sudo -v`")
            return
        }
        #expect(said < primed, "`ask-admin` primes sudo before it has printed the sentence")
    }

    @Test("kit-perms.sh ask-admin: a refusal prints NEEDS A PERSON and exits 3, a yes prints OK")
    func askAdminRefusal() throws {
        guard let text = code(of: permsScript.name) else { return }
        let functions = shellFunctions(in: text)
        guard let handler = dispatchTarget("ask-admin", in: text, functions: functions) else {
            Issue.record("the dispatch of kit-perms.sh has no `ask-admin)` line calling a function")
            return
        }
        let body = expanded(handler, functions)
        ok(has(body, "NEEDS A PERSON: administrator rights"), "a refused password is not reported as `NEEDS A PERSON: administrator rights ...`")
        ok(has(body, "(exit|return)[ \\t]+3\\b"), "a refused password does not exit 3")
        ok(has(body, "OK administrator rights"), "a granted password does not print `OK administrator rights`")
        if let refused = firstIndex(body, "NEEDS A PERSON: administrator rights"),
           let primed = firstIndex(body, "(^|[^A-Za-z0-9_.-])sudo[ \\t]+-v\\b") {
            #expect(primed < refused, "the refusal line is printed before the session was ever primed")
        }
    }

    @Test("kit-perms.sh: the one `sudo -v` is the only sudo that can prompt, and it lives in the ask-admin handler")
    func onlyAskAdminPrompts() throws {
        guard let text = code(of: permsScript.name) else { return }
        let functions = shellFunctions(in: text)
        let lines = sudoLines(text)
        ok(!lines.isEmpty, "kit-perms.sh never uses sudo: the session is the point of ask-admin")
        var primes = 0
        for line in lines {
            if has(line, "sudo[ \\t]+-v\\b") { primes += 1; continue }
            ok(has(line, "sudo[ \\t]+(-[A-Za-z]+[ \\t]+)*-n\\b") || has(line, "sudo[ \\t]+-[A-Za-z]*n[A-Za-z]*\\b"),
               "kit-perms.sh calls sudo without -n, so a check could stop to ask for a password: \(line)")
        }
        #expect(primes == 1, "kit-perms.sh has \(primes) `sudo -v` lines, wanted exactly 1 (administrator rights are asked once)")
        guard let handler = dispatchTarget("ask-admin", in: text, functions: functions) else { return }
        ok(has(expanded(handler, functions), "sudo[ \\t]+-v\\b"), "the `sudo -v` is not reached from the `ask-admin` mode")
        if functions["do_check"] != nil {
            ok(!has(expanded("do_check", functions), "sudo[ \\t]+-v\\b"), "the `check` mode primes sudo: a check must never ask for a password")
        }
    }

    @Test("kit-perms.sh: the checks that need administrator rights still name the admin step, read without a prompt",
          arguments: ["S6.8", "S7.4", "S7.18", "S8.2", "S8.3", "S8.7", "S8.8", "S4.8"])
    func adminStepPerCheck(_ id: String) throws {
        guard let text = code(of: permsScript.name) else { return }
        let functions = shellFunctions(in: text)
        guard let keys = functions["keys_for"] else {
            Issue.record("kit-perms.sh has no keys_for function: `check --for <id>` cannot say what each check needs")
            return
        }
        let escaped = NSRegularExpression.escapedPattern(for: id)
        let named = keys.split(separator: "\n").map(String.init).contains {
            has($0, "(^|[ \\t|])\(escaped)([ \\t|)]|$)") && has($0, "\\badmin\\b")
        }
        ok(named, "`check --for \(id)` does not list the admin step (a missing session would not make \(id) NEEDS-A-PERSON)")
    }

    @Test("kit-perms.sh: a missing administrator session is a NEEDS A PERSON line naming ask-admin, read with `sudo -n true`")
    func adminStepIsReadWithoutPrompt() throws {
        guard let text = code(of: permsScript.name) else { return }
        let functions = shellFunctions(in: text)
        guard let step = functions["step_admin"] else {
            Issue.record("kit-perms.sh has no step_admin function")
            return
        }
        ok(has(step, "sudo[ \\t]+-n[ \\t]+true\\b"), "the admin step does not probe with `sudo -n true`")
        ok(has(step, "NEEDS A PERSON|need[ \\t]+[\"']administrator rights") || has(step, "\\bneed\\b"),
           "a missing session is not reported as NEEDS A PERSON")
        ok(step.contains("ask-admin"), "the admin step does not tell the person to run kit-perms.sh ask-admin")
        ok(step.contains("administrator"), "the admin step does not say what is missing")
    }

    // MARK: kit-privacy.sh login-item

    private func loginItemCode() -> String? {
        guard let text = code(of: privacyScript.name) else { return nil }
        let functions = shellFunctions(in: text)
        guard let handler = dispatchTarget("login-item", in: text, functions: functions) else {
            Issue.record("the dispatch of kit-privacy.sh has no `login-item)` line of its own calling a function (it is still `not built yet`)")
            return nil
        }
        return expanded(handler, functions)
    }

    @Test("kit-privacy.sh login-item is a mode of its own, no longer `not built yet`")
    func loginItemIsBuilt() throws {
        guard let text = code(of: privacyScript.name) else { return }
        for line in text.split(separator: "\n").map(String.init) where has(line, "login-item[ \\t]*\\|") {
            Issue.record("`login-item` still shares a dispatch line with modes that are `not built yet`: \(line)")
        }
        let functions = shellFunctions(in: text)
        ok(dispatchTarget("login-item", in: text, functions: functions) != nil,
           "the dispatch of kit-privacy.sh has no `login-item)` line of its own calling a function")
    }

    @Test("kit-privacy.sh login-item runs `sudo -n sfltool dumpbtm` under the administrator session, probed first with `sudo -n true`")
    func loginItemUsesSession() throws {
        guard let body = loginItemCode() else { return }
        guard let probe = firstIndex(body, "sudo[ \\t]+-n[ \\t]+true\\b") else {
            Issue.record("login-item never probes the session with `sudo -n true`")
            return
        }
        guard let dump = firstIndex(body, "sudo[ \\t]+-n[ \\t]+sfltool[ \\t]+dumpbtm\\b") else {
            Issue.record("login-item never runs `sudo -n sfltool dumpbtm`")
            return
        }
        #expect(probe < dump, "login-item runs sfltool before it has looked for the administrator session")
        ok(body.contains("ask-admin"), "the NEEDS A PERSON line of login-item does not tell the person to run kit-perms.sh ask-admin")
        ok(body.contains("NEEDS A PERSON"), "a missing administrator session is not reported as NEEDS A PERSON")
        ok(has(body, "(exit|return)[ \\t]+3\\b"), "a missing administrator session is not exit 3")
    }

    @Test("kit-privacy.sh: every sudo is `sudo -n`, none prompts or primes a session (asked once, by kit-perms.sh ask-admin)")
    func neverAsksForAPassword() throws {
        guard let text = code(of: privacyScript.name) else { return }
        ok(!sudoLines(text).isEmpty, "kit-privacy.sh never uses sudo: login-item and ping need the administrator session")
        for line in sudoLines(text) {
            ok(has(line, "sudo[ \\t]+(-[A-Za-z]+[ \\t]+)*-n\\b") || has(line, "sudo[ \\t]+-[A-Za-z]*n[A-Za-z]*\\b"),
               "kit-privacy.sh calls sudo without -n, so it could stop to ask for a password: \(line)")
            ok(!has(line, "sudo[ \\t]+(-[A-Za-z]+[ \\t]+)*-(v|S|k|K)\\b"),
               "kit-privacy.sh primes or resets the administrator session itself: \(line)")
        }
    }

    @Test("kit-privacy.sh login-item reads Sesame's identifier from the bundle's Info.plist and never types it")
    func identifierFromInfoPlist() throws {
        guard let body = loginItemCode() else { return }
        ok(body.contains("Info.plist"), "login-item does not read the identifier from the bundle's Info.plist")
        ok(body.contains("CFBundleIdentifier"), "login-item does not read CFBundleIdentifier")
        ok(!body.lowercased().contains("app.sesame.sesame"), "login-item types the identifier app.sesame.Sesame instead of reading it")
        ok(has(body, "\\$\\{?[A-Za-z_]*(APP_ID|app_id|IDENT|ident|bundle_id|BUNDLE_ID)[A-Za-z_]*\\}?|app_identifier"),
           "login-item holds the identifier in no variable and calls no reader for it")
    }

    @Test("kit-privacy.sh login-item prints exactly one of `present and enabled`, `present and disabled`, `absent` or `unreadable`",
          arguments: ["present and enabled", "present and disabled", "absent", "unreadable"])
    func loginItemAnswers(_ phrase: String) throws {
        guard let body = loginItemCode() else { return }
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        ok(has(body, "[\"']\(escaped)(\\\\n)?[\"']"),
           "login-item has no string that is exactly `\(phrase)` (the answer must be the whole printed word or phrase)")
    }

    @Test("kit-privacy.sh login-item also prints the last `login status=` line of logs/app.log (the app's own record, U6)")
    func loginItemPrintsLoggedStatus() throws {
        guard let body = loginItemCode() else { return }
        ok(body.contains("login status="), "login-item never looks for the `login status=` lines")
        ok(body.contains("logs/app.log"), "login-item never reads logs/app.log")
        ok(has(body, "tail[ \\t]+-(n[ \\t]*)?1\\b|\\$p|\\bEND\\b"), "login-item does not take the LAST `login status=` line (tail -1, `$p` or an awk END)")
    }

    @Test("kit-privacy.sh login-item has a control: a different, absent identifier must read `absent`, else exit 4 not valid")
    func loginItemControl() throws {
        guard let body = loginItemCode() else { return }
        ok(has(body, "(?i)control"), "login-item has no control run of the parser")
        ok(has(body, "\\$RANDOM|\\$\\$"), "the control identifier is not made unique (`$RANDOM` or `$$`), so it could name a real entry")
        ok(has(body, "(return|exit)[ \\t]+4\\b"), "a control that does not read `absent` is not exit 4")
        ok(has(body, "(?i)not valid"), "a failed control does not say `not valid`")
        ok(body.contains("CONTROL"), "the control prints no `CONTROL ...` line (the library scan's style) to show it ran")
    }

    // MARK: the library scan of plan 1 is unchanged; the two Caches folders are named in its list

    @Test("kit-privacy.sh names Library/Caches/app.sesame.Sesame and Library/Caches/SesameHelper in its scan list, not only in a message",
          arguments: ["Caches/app.sesame.Sesame", "Caches/SesameHelper"])
    func cachesFoldersAreNamed(_ folder: String) throws {
        guard let text = code(of: privacyScript.name) else { return }
        let escaped = NSRegularExpression.escapedPattern(for: folder)
        let named = text.split(separator: "\n").map(String.init).contains { line in
            has(line, escaped) && !has(line.trimmingCharacters(in: .whitespaces), "^(echo|printf)\\b")
        }
        ok(named, "`\(folder)` is named in no line that is not a printed message: the scan list does not name Sesame's Caches folders")
    }

    @Test("kit-privacy.sh keeps the plan-1 library scan: modes, flags, controls and verdict lines")
    func libraryScanKept() throws {
        guard let text = code(of: privacyScript.name) else { return }
        for flag in ["--delete-first", "--ignore-sesame-folder", "--new-only"] {
            ok(text.contains(flag), "library-scan lost its \(flag) flag")
        }
        for mode in ["ping", "baseline", "plist", "entitlements", "static-allowlist", "library-scan", "layout"] {
            ok(has(text, "(^|[ \\t|(])\(mode)\\)"), "kit-privacy.sh lost its `\(mode)` handler")
        }
        for words in ["LIBRARY-SCAN CLEAN", "LIBRARY-SCAN FAILED", "CONTROL", "not valid: a scan control failed",
                      "Application Support", "Preferences", "HTTPStorages", "Saved Application State", "LaunchAgents"] {
            ok(text.contains(words), "library-scan lost `\(words)`")
        }
    }

    @Test("kit-privacy.sh and kit-perms.sh keep the kit's style: common.sh sourced and output saved through kit_wrap", arguments: bothScripts)
    fileprivate func kitStyle(_ script: Script) throws {
        guard let text = code(of: script.name) else { return }
        ok(text.contains("kit-lib/common.sh"), "scripts/\(script.name) does not source kit-lib/common.sh")
        ok(has(text, "\\bkit_wrap\\b"), "scripts/\(script.name) does not save its output through kit_wrap (verify.md: every kit script saves its output)")
    }
}
