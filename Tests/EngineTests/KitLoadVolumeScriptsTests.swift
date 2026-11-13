import Foundation
import Testing

// plan-2-t5, tester step: kit part 1, the busy stand-in (scripts/kit-load.sh) and the disk-image stand-in
// (scripts/kit-volume.sh). Written from verify.md (Kit scripts, Drive exit codes, Cleanup, Doctor), the S7 feature
// map and design section 11 only; no product source is read, and neither script may read `Sources/`.
//
// Static proof only (plan-2-tasks.md, Conventions): the real behaviour of both scripts (a three-second busy run
// measured above 50 percent, a disk image attached and detached) is read at the accept stage by the Doctor and by
// S7.3, S7.8 and S7.17. Nothing here starts a busy loop, mounts an image or launches Sesame. The only runs are
// `bash -n` and each script with no mode (and with an unknown mode), which must print usage and start nothing.
//
// What a text assertion reads is the script's code with its comment lines removed, so a comment can never satisfy
// a check. Text checks are tied to the sentences of verify.md:
//   - usage text: the exact mode lists "start <percent> | stop | measure <seconds> | ping" and
//     "make | detach | attach | destroy | ping" (Kit scripts), on one line `usage: <script> <modes>`;
//   - exit codes: 2 usage, 4 "the run is invalid because a precondition did not hold (... a busy stand-in below
//     its load)" (Drive);
//   - every kit script saves its output through the evidence wrapper (`kit_wrap`) and sources kit-lib/common.sh;
//   - background processes record their pid under run/pids/ (common.sh), which `kit-reset.sh --cleanup` reads, and
//     the cleanup calls `kit-load.sh stop` and `kit-volume.sh destroy` (Cleanup);
//   - the image lives under KIT_ROOT/run, `detach` then `attach` give the same mount path (a fixed `-mountpoint`),
//     and `make` fills the volume with generated photos through kit-fixtures.sh (S7.8).

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private struct Script: Sendable, CustomStringConvertible {
    let name: String
    let modes: String
    let handlers: [String]
    var description: String { name }
}

private let loadScript = Script(
    name: "kit-load.sh",
    modes: "start <percent> | stop | measure <seconds> | ping",
    handlers: ["start", "stop", "measure", "ping"])
private let volumeScript = Script(
    name: "kit-volume.sh",
    modes: "make | detach | attach | destroy | ping",
    handlers: ["make", "detach", "attach", "destroy", "ping"])
private let bothScripts = [loadScript, volumeScript]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitlv-out-" + UUID().uuidString)
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

/// A fresh, empty KIT_ROOT (the kit requires a folder named sesame-kit*), removed afterwards.
private func withKitRoot<T>(_ body: (String) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-kit-loadvol-" + UUID().uuidString, isDirectory: true)
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

/// "<pid> <what>" of every process that is a stand-in or one of the two scripts: a process named `yes`, `kit-load`
/// or `hdiutil`, or one whose command line names kit-load.sh or kit-volume.sh.
private func standInProcesses() throws -> Set<String> {
    var found: Set<String> = []
    let names = try run("/bin/ps", ["-axo", "pid=,comm="])
    for line in names.output.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { continue }
        let name = (parts[1].trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        if ["yes", "kit-load", "hdiutil"].contains(name) { found.insert("\(parts[0]) \(name)") }
    }
    let commands = try run("/bin/ps", ["-axo", "pid=,args="])
    for line in commands.output.split(separator: "\n") {
        let text = String(line)
        if text.contains("kit-load.sh") || text.contains("kit-volume.sh") {
            let pid = text.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "?"
            found.insert("\(pid) script")
        }
    }
    return found
}

@Suite("KitLoadVolumeScriptsTests")
struct KitLoadVolumeScriptsTests {

    // MARK: the files themselves

    @Test("the script exists, is executable and is a bash script (the cleanup runs it only when executable)",
          arguments: bothScripts)
    fileprivate func existsExecutableBash(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        #expect(FileManager.default.isExecutableFile(atPath: path), "scripts/\(script.name) is not executable")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/bash\n"), "scripts/\(script.name) line 1 is not #!/bin/bash (the kit is bash 3.2)")
    }

    @Test("bash -n finds no syntax error", arguments: bothScripts)
    fileprivate func bashSyntax(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        let ran = try run("/bin/bash", ["-n", path])
        #expect(ran.status == 0, "bash -n scripts/\(script.name) exited \(ran.status): \(ran.output)")
        #expect(ran.output.isEmpty, "bash -n scripts/\(script.name) printed: \(ran.output)")
    }

    // MARK: no mode, an unknown mode: usage, exit 2, nothing started

    @Test("no mode prints the verify.md mode list, exits 2 and starts nothing", arguments: bothScripts)
    fileprivate func noModeIsUsage(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        let before = try standInProcesses()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, [], env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        let after = try standInProcesses()
        #expect(ran.status == 2, "scripts/\(script.name) with no mode exited \(ran.status), wanted 2: \(ran.output)")
        let usage = ran.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(usage.contains("usage: \(script.name) \(script.modes)"),
                "no line reads `usage: \(script.name) \(script.modes)`; the output was: \(ran.output)")
        #expect(after.subtracting(before).isEmpty, "a process was left behind: \(after.subtracting(before).sorted())")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
    }

    @Test("an unknown mode is usage too: exit 2, nothing started", arguments: bothScripts)
    fileprivate func unknownModeIsUsage(_ script: Script) throws {
        guard let path = scriptPath(script.name) else { return }
        let before = try standInProcesses()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, ["frobnicate"], env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        let after = try standInProcesses()
        #expect(ran.status == 2, "scripts/\(script.name) frobnicate exited \(ran.status), wanted 2: \(ran.output)")
        #expect(ran.output.contains("usage: \(script.name) \(script.modes)"), "no usage text: \(ran.output)")
        #expect(after.subtracting(before).isEmpty, "a process was left behind: \(after.subtracting(before).sorted())")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
    }

    // MARK: the kit's own style (read from the text)

    @Test("each mode of the usage text has a handler, and the script uses the kit's common.sh and evidence wrapper",
          arguments: bothScripts)
    fileprivate func kitStyle(_ script: Script) throws {
        guard let text = code(of: script.name) else { return }
        #expect(text.contains("kit-lib/common.sh"), "scripts/\(script.name) does not source kit-lib/common.sh")
        #expect(has(text, "\\bkit_wrap\\b"), "scripts/\(script.name) does not save its output through kit_wrap (verify.md: every kit script saves its output)")
        for mode in script.handlers {
            #expect(has(text, "(^|[ \\t|(])\(mode)[ \\t]*[|)]"), "scripts/\(script.name) has no handler for the mode `\(mode)`")
        }
    }

    @Test("neither script reads Sources/", arguments: bothScripts)
    fileprivate func neverReadsSources(_ script: Script) throws {
        guard let text = code(of: script.name) else { return }
        #expect(!text.contains("Sources"), "scripts/\(script.name) names Sources: the kit never reads the product's source")
    }

    // MARK: kit-load.sh

    @Test("kit-load.sh measure reports whole-system CPU apart from Sesame's processes each second")
    func measureReportsCPUApartFromSesame() throws {
        guard let text = code(of: loadScript.name) else { return }
        #expect(has(text, "\\b(ps|top|iostat)\\b"), "measure reads no CPU figure (ps, top or iostat)")
        #expect(text.contains("Sesame"), "measure never names the Sesame processes it must leave out")
        #expect(has(text, "(sleep[ \\t]+1\\b|-s[ \\t]+1\\b|-w[ \\t]+1\\b|-i[ \\t]+1\\b)"), "measure does not sample once a second")
    }

    @Test("kit-load.sh measure exits 4 when the load fell short of the percent asked; start remembers that percent")
    func measureExitsFourWhenShort() throws {
        guard let text = code(of: loadScript.name) else { return }
        #expect(has(text, "(exit|return)[ \\t]+4\\b"), "no exit 4 (run invalid: the busy stand-in is below its load)")
        #expect(has(text, "KIT_ROOT\\}?/run/"), "the percent asked is kept nowhere under KIT_ROOT/run, so measure cannot compare with it")
    }

    @Test("kit-load.sh start records every stand-in pid under run/pids and stop kills them and what they started")
    func startRecordsStopKills() throws {
        guard let text = code(of: loadScript.name) else { return }
        #expect(has(text, "run/pids/"), "start does not record a pid under KIT_ROOT/run/pids (kit-reset.sh --cleanup reads that folder)")
        #expect(text.contains(".pid"), "no <name>.pid file is written")
        #expect(has(text, "\\bkill\\b"), "stop never kills anything")
        #expect(has(text, "(kit_descendants|pkill|pgrep|killall|\\bps\\b)"), "stop does not look for the children of a stand-in, so a busy child could outlive it")
        #expect(has(text, "(nproc|hw\\.(logicalcpu|ncpu|activecpu)|_NPROCESSORS_ONLN)"), "the stand-in is not started on every core")
    }

    // MARK: kit-volume.sh

    @Test("kit-volume.sh make builds the image under KIT_ROOT/run, mounts it and fills it through kit-fixtures.sh")
    func makeBuildsMountsFills() throws {
        guard let text = code(of: volumeScript.name) else { return }
        #expect(has(text, "hdiutil[ \\t]+create"), "make builds no disk image (hdiutil create)")
        #expect(has(text, "KIT_ROOT\\}?/run/"), "the image is not placed under KIT_ROOT/run")
        #expect(has(text, "\\.(dmg|sparseimage|sparsebundle)"), "the image file has no disk image extension")
        #expect(has(text, "hdiutil[ \\t]+attach"), "make mounts nothing (hdiutil attach)")
        #expect(text.contains("kit-fixtures.sh"), "the volume is not filled through kit-fixtures.sh")
        #expect(has(text, "kit-fixtures\\.sh[^\\n]*\\bbuild\\b"), "kit-fixtures.sh is not asked to build the photos")
    }

    @Test("kit-volume.sh detach and attach give the same mount path, destroy detaches and deletes the image")
    func detachAttachDestroy() throws {
        guard let text = code(of: volumeScript.name) else { return }
        #expect(has(text, "hdiutil[ \\t]+detach"), "detach and destroy never run hdiutil detach")
        #expect(has(text, "-mountpoint\\b"), "attach does not pin the mount path with -mountpoint, so attach could return another path than make")
        #expect(has(text, "\\brm\\b"), "destroy deletes no image file")
    }

    // MARK: the cleanup calls the scripts

    @Test("kit-reset.sh --cleanup stops the stand-ins by calling kit-load.sh stop and kit-volume.sh destroy")
    func cleanupCallsBoth() throws {
        for script in bothScripts {
            guard let path = scriptPath(script.name) else { return }
            #expect(FileManager.default.isExecutableFile(atPath: path), "scripts/\(script.name) is not executable: the cleanup skips it")
        }
        guard let reset = code(of: "kit-reset.sh") else { return }
        #expect(reset.contains("kit-load.sh stop"), "kit-reset.sh --cleanup does not call kit-load.sh stop")
        #expect(reset.contains("kit-volume.sh destroy"), "kit-reset.sh --cleanup does not call kit-volume.sh destroy")
        #expect(has(reset, "run/pids"), "kit-reset.sh --cleanup does not read the pid files under run/pids")
    }
}
