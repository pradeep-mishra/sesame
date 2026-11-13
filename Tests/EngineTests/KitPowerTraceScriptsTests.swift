import Foundation
import Testing

// plan-2-t6, tester step: kit part 2, Low Power Mode (scripts/kit-power.sh), the file and network trace
// (scripts/kit-trace.sh) and the cleanup of both in scripts/kit-reset.sh. Written from verify.md (Kit scripts, Drive
// exit codes, Cleanup, Doctor, guesses K24 to K26 and K31), the S6 and S7 feature maps and design section 11 only; no
// product source is read, and none of the three scripts may read `Sources/`.
//
// Static proof only (plan-2-tasks.md, Conventions): the real behaviour (`pmset` write-back, `fs_usage` seeing its own
// open and, with --net, its own connect) is read at the accept stage by the Doctor and by S6.8 and S7.4. Nothing here
// runs `kit-power.sh` in any mode that reads or writes the setting, runs `kit-trace.sh start`, asks for a password or
// launches Sesame. The only runs are `bash -n`, and each script with no mode, with an unknown mode and with arguments
// that are wrong before anything could start; those must print usage, exit 2, start nothing and write nothing.
//
// What a text assertion reads is the script's code with its comment lines removed, so a comment can never satisfy a
// check. Text checks are tied to the sentences of verify.md and of the plan-2-t6 entry:
//   - usage text: the exact mode lists "ping | lowpower on|off|get | record | restore" and
//     "start <name> [--net] | stop <name> | opens <name> --under <dir> --by <process> | writes <name> --under <dir> |
//     by-process <name> | net <name> [--except <host:port>...] | ping", on one line `usage: <script> <modes>`;
//   - kit-power.sh: `lowpower on|off` runs `sudo pmset -a lowpowermode 1|0` and prints the epoch, `get` reads
//     `pmset -g`, `record` saves the value under KIT_ROOT/run and `restore` puts it back, and a Mac with no
//     `lowpowermode` line makes every call but `ping` and `get` exit 3 with the one sentence
//     `NEEDS A PERSON: this Mac has no Low Power Mode setting`;
//   - kit-trace.sh: `fs_usage` output split by process name, opens of directories counted apart from opens of regular
//     files by a `stat` of each path, exit 4 when a trace that was meant to run saw nothing (the positive control),
//     network lines `connect`, `sendto` and `sendmsg` with `--except`, and the administrator session used only when
//     `kit-perms.sh ask-admin` has primed it: the script never asks for a password itself (every `sudo` is `sudo -n`,
//     a missing session is exit 3 `NEEDS A PERSON` that names `ask-admin`);
//   - kit-reset.sh: `--cleanup` and a plain reset both call `kit-power.sh restore`, stop the trace, run
//     `kit-volume.sh destroy` and `kit-load.sh stop`; the restore comes before the run folder is deleted (the value
//     it puts back lives there) and before `record` takes the new one; `--cleanup` still deletes KIT_ROOT except cache/.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private struct Script: Sendable, CustomStringConvertible {
    let name: String
    let modes: String
    let handlers: [String]
    var description: String { name }
}

private let powerScript = Script(
    name: "kit-power.sh",
    modes: "ping | lowpower on|off|get | record | restore",
    handlers: ["ping", "lowpower", "get", "record", "restore"])
private let traceScript = Script(
    name: "kit-trace.sh",
    modes: "start <name> [--net] | stop <name> | opens <name> --under <dir> --by <process> | writes <name> --under <dir> | by-process <name> | net <name> [--except <host:port>...] | ping",
    handlers: ["start", "stop", "opens", "writes", "by-process", "net", "ping"])
private let newScripts = [powerScript, traceScript]

/// Arguments that are wrong before anything could start: usage, exit 2, whatever the Mac or the session is.
private struct BadCall: Sendable, CustomStringConvertible {
    let script: Script
    let args: [String]
    var description: String { "\(script.name) \(args.joined(separator: " "))" }
}

private let badCalls: [BadCall] = [
    BadCall(script: powerScript, args: ["lowpower"]),
    BadCall(script: powerScript, args: ["lowpower", "sideways"]),
    BadCall(script: traceScript, args: ["start"]),
    BadCall(script: traceScript, args: ["stop"]),
    BadCall(script: traceScript, args: ["opens", "somename"]),
    BadCall(script: traceScript, args: ["opens", "somename", "--under", "/tmp"]),
    BadCall(script: traceScript, args: ["writes", "somename"]),
    BadCall(script: traceScript, args: ["by-process"]),
    BadCall(script: traceScript, args: ["net"]),
]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitpt-out-" + UUID().uuidString)
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
        .appendingPathComponent("sesame-kit-powertrace-" + UUID().uuidString, isDirectory: true)
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

/// "<pid> <what>" of every process that is a trace or one of the two scripts: a process named `fs_usage`, or one
/// whose command line names kit-power.sh or kit-trace.sh.
private func traceProcesses() throws -> Set<String> {
    var found: Set<String> = []
    let names = try run("/bin/ps", ["-axo", "pid=,comm="])
    for line in names.output.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { continue }
        let name = (parts[1].trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        if name == "fs_usage" { found.insert("\(parts[0]) \(name)") }
    }
    let commands = try run("/bin/ps", ["-axo", "pid=,args="])
    for line in commands.output.split(separator: "\n") {
        let text = String(line)
        if text.contains("kit-power.sh") || text.contains("kit-trace.sh") {
            let pid = text.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "?"
            found.insert("\(pid) script")
        }
    }
    return found
}

/// The line of `pmset -g` that names the Low Power Mode setting ("" when this Mac has none). A read only.
private func lowPowerLine() throws -> String {
    let ran = try run("/usr/bin/pmset", ["-g"])
    return ran.output.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("lowpowermode") } ?? ""
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

@Suite("KitPowerTraceScriptsTests")
struct KitPowerTraceScriptsTests {

    // MARK: the files themselves

    @Test("the script exists, is executable and is a bash script (the cleanup runs it only when executable)",
          arguments: newScripts)
    fileprivate func existsExecutableBash(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        #expect(FileManager.default.isExecutableFile(atPath: path), "scripts/\(script.name) is not executable")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/bash\n"), "scripts/\(script.name) line 1 is not #!/bin/bash (the kit is bash 3.2)")
    }

    @Test("bash -n finds no syntax error in the three scripts",
          arguments: ["kit-power.sh", "kit-trace.sh", "kit-reset.sh"])
    func bashSyntax(_ name: String) throws {
        guard let path = scriptPath(name) else { return }
        let ran = try run("/bin/bash", ["-n", path])
        #expect(ran.status == 0, "bash -n scripts/\(name) exited \(ran.status): \(ran.output)")
        #expect(ran.output.isEmpty, "bash -n scripts/\(name) printed: \(ran.output)")
    }

    // MARK: no mode, an unknown mode, arguments wrong before anything starts: usage, exit 2, nothing started

    @Test("no mode prints the verify.md mode list, exits 2, starts nothing and writes nothing", arguments: newScripts)
    fileprivate func noModeIsUsage(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        let before = try traceProcesses()
        let lowPowerBefore = try lowPowerLine()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, [], env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        let after = try traceProcesses()
        #expect(ran.status == 2, "scripts/\(script.name) with no mode exited \(ran.status), wanted 2: \(ran.output)")
        let usage = ran.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(usage.contains("usage: \(script.name) \(script.modes)"),
                "no line reads `usage: \(script.name) \(script.modes)`; the output was: \(ran.output)")
        #expect(after.subtracting(before).isEmpty, "a process was left behind: \(after.subtracting(before).sorted())")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
        #expect(try lowPowerLine() == lowPowerBefore, "the Low Power Mode setting changed")
    }

    @Test("an unknown mode is usage too: exit 2, nothing started, nothing written", arguments: newScripts)
    fileprivate func unknownModeIsUsage(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        let before = try traceProcesses()
        let lowPowerBefore = try lowPowerLine()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, ["frobnicate"], env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        let after = try traceProcesses()
        #expect(ran.status == 2, "scripts/\(script.name) frobnicate exited \(ran.status), wanted 2: \(ran.output)")
        #expect(ran.output.contains("usage: \(script.name) \(script.modes)"), "no usage text: \(ran.output)")
        #expect(after.subtracting(before).isEmpty, "a process was left behind: \(after.subtracting(before).sorted())")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
        #expect(try lowPowerLine() == lowPowerBefore, "the Low Power Mode setting changed")
    }

    @Test("a mode with arguments that are missing or wrong is usage, exit 2, before anything starts", arguments: badCalls)
    fileprivate func badArgumentsAreUsage(_ call: BadCall) throws {
        guard let path = scriptPath(call.script.name) else { return }
        let before = try traceProcesses()
        let lowPowerBefore = try lowPowerLine()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, call.args, env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        let after = try traceProcesses()
        #expect(ran.status == 2, "scripts/\(call) exited \(ran.status), wanted 2 (usage): \(ran.output)")
        #expect(ran.output.contains("usage: \(call.script.name) \(call.script.modes)"), "no usage text: \(ran.output)")
        #expect(after.subtracting(before).isEmpty, "a process was left behind: \(after.subtracting(before).sorted())")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
        #expect(try lowPowerLine() == lowPowerBefore, "the Low Power Mode setting changed")
    }

    // MARK: the kit's own style (read from the text)

    @Test("each mode of the usage text has a handler, and the script uses the kit's common.sh and evidence wrapper",
          arguments: newScripts)
    fileprivate func kitStyle(_ script: Script) throws {
        guard let text = code(of: script.name) else { return }
        ok(text.contains("kit-lib/common.sh"), "scripts/\(script.name) does not source kit-lib/common.sh")
        ok(has(text, "\\bkit_wrap\\b"), "scripts/\(script.name) does not save its output through kit_wrap (verify.md: every kit script saves its output)")
        for mode in script.handlers {
            ok(has(text, "(^|[ \\t|(])\(mode)[ \\t]*[|)]"), "scripts/\(script.name) has no handler for the mode `\(mode)`")
        }
    }

    @Test("none of the three scripts reads Sources/", arguments: ["kit-power.sh", "kit-trace.sh", "kit-reset.sh"])
    func neverReadsSources(_ name: String) throws {
        guard let text = code(of: name) else { return }
        ok(!text.contains("Sources"), "scripts/\(name) names Sources: the kit never reads the product's source")
    }

    @Test("neither script asks for a password: every sudo is `sudo -n`, none primes a session (Drive: asked once, by kit-perms.sh ask-admin)",
          arguments: newScripts)
    fileprivate func neverAsksForAPassword(_ script: Script) throws {
        guard let text = code(of: script.name) else { return }
        ok(has(text, "\\bsudo\\b"), "scripts/\(script.name) never uses sudo: the administrator session is the point of it")
        // Plan 2 fix round C, C2-1 (a sealed check that changes with the product): a failed restore prints the command the
        // person is to run, "`sudo pmset -a lowpowermode 0`", inside escaped backticks of a quoted message. That text is
        // printed, not run, so it is cut out of the line before the line is read; a call of sudo without -n, in a command
        // substitution or on a line of its own, is still found (the plant is a line `sudo pmset -a lowpowermode 0`).
        for original in text.split(separator: "\n").map(String.init) {
            let line = original.replacingOccurrences(of: "\\\\`[^`]*\\\\`", with: "", options: .regularExpression)
            guard has(line, "(^|[^A-Za-z0-9_.-])sudo[ \\t]") else { continue }
            ok(has(line, "sudo[ \\t]+(-[A-Za-z]+[ \\t]+)*-n\\b") || has(line, "sudo[ \\t]+-[A-Za-z]*n[A-Za-z]*\\b"),
                    "scripts/\(script.name) calls sudo without -n, so it could stop to ask for a password: \(line)")
            ok(!has(line, "sudo[ \\t]+(-[A-Za-z]+[ \\t]+)*-(v|S|k|K)\\b"),
                    "scripts/\(script.name) primes or resets the administrator session itself: \(line)")
        }
    }

    // MARK: kit-power.sh

    @Test("kit-power.sh lowpower on|off runs `sudo pmset -a lowpowermode 1|0` and prints the epoch")
    func lowpowerWritesAndPrintsEpoch() throws {
        guard let text = code(of: powerScript.name) else { return }
        ok(has(text, "sudo[ \\t]+(-[A-Za-z]+[ \\t]+)*pmset[ \\t]+-a[ \\t]+lowpowermode[ \\t]+"),
                "no `sudo pmset -a lowpowermode <value>`")
        ok(has(text, "\\bon\\)[^\\n]*\\n?[^\\n]*\\b1\\b"), "`on` does not give the value 1")
        ok(has(text, "\\boff\\)[^\\n]*\\n?[^\\n]*\\b0\\b"), "`off` does not give the value 0")
        ok(has(text, "date[ \\t]+\\+%s"), "the epoch (date +%s) is never printed: S7.4 counts its 5 s and 10 s from it")
    }

    @Test("kit-power.sh get reads `pmset -g`")
    func getReadsPmset() throws {
        guard let text = code(of: powerScript.name) else { return }
        ok(has(text, "pmset[ \\t]+-g\\b"), "no `pmset -g` read")
        ok(has(text, "lowpowermode"), "the lowpowermode line of `pmset -g` is never looked for")
    }

    @Test("kit-power.sh on a Mac with no lowpowermode line: every call but ping and get exits 3 with the one sentence")
    func noSettingIsNeedsAPerson() throws {
        guard let text = code(of: powerScript.name) else { return }
        ok(text.contains("NEEDS A PERSON: this Mac has no Low Power Mode setting"),
                "the sentence `NEEDS A PERSON: this Mac has no Low Power Mode setting` is missing")
        ok(has(text, "(exit|return)[ \\t]+3\\b"), "no exit 3 (a person-step is missing)")
    }

    // Plan 2 fix round C, C2-1 (a sealed pin that changes with the product): the recorded value moved from KIT_ROOT/run to
    // KIT_ROOT/keep, which a reset does not delete (it deletes run/) and a cleanup keeps; KitRoundC2Tests.KitC2LowPowerTests
    // runs the functions and shows where the file really is. A baseline still under run/ fails this check and that suite.
    @Test("kit-power.sh record keeps the current value under KIT_ROOT/keep and restore puts it back with sudo pmset")
    func recordAndRestore() throws {
        guard let text = code(of: powerScript.name) else { return }
        ok(has(text, "SAVED=\"\\$KIT_ROOT\\}?/keep/"), "the recorded value is kept nowhere under KIT_ROOT/keep, so a reset deletes it and restore has nothing to read")
        ok(has(text, "(^|[ \\t|(])record[ \\t]*[|)]"), "no record handler")
        ok(has(text, "(^|[ \\t|(])restore[ \\t]*[|)]"), "no restore handler")
    }

    // MARK: kit-trace.sh

    @Test("kit-trace.sh splits fs_usage output by process name and saves the trace to the evidence folder")
    func splitsByProcess() throws {
        guard let text = code(of: traceScript.name) else { return }
        ok(has(text, "\\bfs_usage\\b"), "fs_usage is never run")
        ok(has(text, "\\bawk\\b"), "the fs_usage lines are not split by an awk or similar filter")
        ok(text.contains("Sesame"), "the process names Sesame and SesameHelper are never named")
        ok(has(text, "trace-"), "the trace is not saved as trace-<name>.txt (verify.md, Evidence)")
        ok(has(text, "\\bby-process\\b"), "no by-process mode")
        ok(has(text, "run/pids/"), "a background fs_usage is not recorded under KIT_ROOT/run/pids")
    }

    @Test("kit-trace.sh separates opens of directories (counted apart) from opens of regular files by a stat of each path")
    func directoriesApartFromFiles() throws {
        guard let text = code(of: traceScript.name) else { return }
        ok(has(text, "\\bstat\\b"), "no stat of the opened paths")
        ok(has(text, "(%HT|[ \\t]-d[ \\t]|Directory|director)"), "directories are not told from files")
        ok(has(text, "(?i)directories"), "the count of opened directories is never printed")
        ok(has(text, "(?i)regular[ \\t]+files?"), "the count of opened regular files is never printed apart")
        ok(has(text, "--under"), "no --under <dir>")
        ok(has(text, "--by\\b"), "no --by <process>")
    }

    @Test("kit-trace.sh exits 4 when a trace that was meant to run saw nothing (the positive control)")
    func positiveControlExitsFour() throws {
        guard let text = code(of: traceScript.name) else { return }
        ok(has(text, "(exit|return)[ \\t]+4\\b"), "no exit 4 (the run is invalid: the trace saw nothing)")
        ok(has(text, "(?i)saw[ \\t]+nothing|no[ \\t]+(lines|events)|empty|positive[ \\t]+control"),
                "nothing says what the exit 4 is for")
    }

    @Test("kit-trace.sh net lists connect, sendto and sendmsg with --except, and start has --net")
    func networkTrace() throws {
        guard let text = code(of: traceScript.name) else { return }
        for word in ["connect", "sendto", "sendmsg"] {
            ok(has(text, "\\b\(word)\\b"), "the network trace never reads `\(word)`")
        }
        ok(text.contains("--except"), "net has no --except <host:port>")
        ok(text.contains("--net"), "start has no --net")
        ok(has(text, "trace-net-"), "the network trace is not saved as trace-net-<name>.txt (verify.md, Evidence)")
        ok(has(text, "(-f[ \\t]+network|network)"), "fs_usage is not asked for network events")
    }

    @Test("kit-trace.sh runs under the administrator session only: a missing session is exit 3 naming ask-admin")
    func administratorSessionOnly() throws {
        guard let text = code(of: traceScript.name) else { return }
        ok(has(text, "sudo[ \\t]+-n[ \\t]+true\\b"), "the session is never probed with `sudo -n true`")
        ok(text.contains("ask-admin"), "the NEEDS A PERSON line does not tell the person to run kit-perms.sh ask-admin")
        ok(text.contains("NEEDS A PERSON"), "a missing administrator session is not reported as NEEDS A PERSON")
        ok(has(text, "(exit|return)[ \\t]+3\\b"), "no exit 3 (a person-step is missing)")
    }

    // MARK: the cleanup calls both

    @Test("kit-reset.sh --cleanup calls power restore, stops the trace, destroys the image, stops the busy stand-in and still deletes everything but cache/")
    func cleanupCallsAll() throws {
        guard let text = code(of: "kit-reset.sh") else { return }
        let functions = shellFunctions(in: text)
        guard functions["do_cleanup"] != nil else {
            Issue.record("kit-reset.sh has no do_cleanup function")
            return
        }
        let cleanup = expanded("do_cleanup", functions)
        ok(has(cleanup, "kit-power\\.sh[\"']?[ \\t]+restore\\b"), "--cleanup does not call kit-power.sh restore")
        ok(has(cleanup, "kit-trace\\.sh[\"']?[ \\t]+stop\\b"), "--cleanup does not stop the trace (kit-trace.sh stop)")
        ok(has(cleanup, "kit-volume\\.sh[\"']?[ \\t]+destroy\\b"), "--cleanup does not call kit-volume.sh destroy")
        ok(has(cleanup, "kit-load\\.sh[\"']?[ \\t]+stop\\b"), "--cleanup does not call kit-load.sh stop")
        guard let deleted = firstIndex(cleanup, "find[^\\n]*KIT_ROOT[^\\n]*!\\s+-name\\s+cache") else {
            Issue.record("--cleanup no longer deletes KIT_ROOT except cache/")
            return
        }
        for (what, pattern) in [("power restore", "kit-power\\.sh[\"']?[ \\t]+restore\\b"),
                                ("trace stop", "kit-trace\\.sh[\"']?[ \\t]+stop\\b"),
                                ("volume destroy", "kit-volume\\.sh[\"']?[ \\t]+destroy\\b"),
                                ("load stop", "kit-load\\.sh[\"']?[ \\t]+stop\\b")] {
            if let at = firstIndex(cleanup, pattern) {
                #expect(at < deleted, "--cleanup runs \(what) only after it has deleted KIT_ROOT: its pid files and saved value are gone by then")
            }
        }
    }

    @Test("a plain kit-reset.sh does the same first: power restore, trace stop, volume destroy, load stop, before the run folder is deleted and before record")
    func plainResetCallsAll() throws {
        guard let text = code(of: "kit-reset.sh") else { return }
        let functions = shellFunctions(in: text)
        guard functions["do_reset"] != nil else {
            Issue.record("kit-reset.sh has no do_reset function")
            return
        }
        let reset = expanded("do_reset", functions)
        ok(has(reset, "kit-power\\.sh[\"']?[ \\t]+restore\\b"), "a plain reset does not call kit-power.sh restore")
        ok(has(reset, "kit-trace\\.sh[\"']?[ \\t]+stop\\b"), "a plain reset does not stop the trace (kit-trace.sh stop)")
        ok(has(reset, "kit-volume\\.sh[\"']?[ \\t]+destroy\\b"), "a plain reset does not call kit-volume.sh destroy")
        ok(has(reset, "kit-load\\.sh[\"']?[ \\t]+stop\\b"), "a plain reset does not call kit-load.sh stop")
        guard let deleted = firstIndex(reset, "rm[ \\t]+-rf[^\\n]*KIT_ROOT\\}?/run") else {
            Issue.record("a plain reset no longer deletes the run folder")
            return
        }
        for (what, pattern) in [("power restore", "kit-power\\.sh[\"']?[ \\t]+restore\\b"),
                                ("trace stop", "kit-trace\\.sh[\"']?[ \\t]+stop\\b"),
                                ("volume destroy", "kit-volume\\.sh[\"']?[ \\t]+destroy\\b"),
                                ("load stop", "kit-load\\.sh[\"']?[ \\t]+stop\\b")] {
            if let at = firstIndex(reset, pattern) {
                #expect(at < deleted, "a plain reset runs \(what) only after it has deleted the run folder, where the pid files, the image and the saved value live")
            }
        }
        if let restore = firstIndex(reset, "kit-power\\.sh[\"']?[ \\t]+restore\\b"),
           let record = firstIndex(reset, "kit-power\\.sh[\"']?[ \\t]+record\\b") {
            #expect(restore < record, "a plain reset records the new Low Power Mode value before it put the old one back")
        }
    }
}
