import Foundation
import Testing

// plan-3-t13, tester step. Written from .ril/docs/plans/plan-3-tasks.md (entry plan-3-t13, Conventions, Decisions D9 and
// D13), design.md section 12 and the existing scripts/check-static.sh, scripts/kit-static.sh and scripts/kit-privacy.sh.
// No file under Sources/ is read by this test. It runs the scripts as child processes only; nothing here starts an app.
//
// What the entry asks, and where it is proved:
//   - the allowlist: `check-static.sh --allowlist` equals scripts/kit-lib/static-allowlist.txt, and both hold plan 2's 16
//     lines plus `process-network Sources/SesameEngine/GitFiles.swift` and `log-write Log`;
//     `kit-privacy.sh static-allowlist` agrees;
//   - a 17th rule `log-typed`: `--quick` prints 17 STATIC lines, exit 0, the 16 plan 2 rules unchanged;
//   - the rule's behaviour (PENDING with no `Log`, FAIL for a log append outside the module `Log`, PASS inside it) and the
//     path-exact `process-network` entry are proved on small throwaway projects the test builds under $TMPDIR (a copy of
//     check-static.sh plus hand-written Swift text), so the verdicts do not depend on what the product holds today;
//   - `--selftest`: the two new plants are RED and every plan 2 plant stays RED.
//
// The real tree's `log-typed` is PENDING until plan-3-t22 adds Log.swift and PASS after it. The real-tree test therefore
// accepts exactly those two states and never FAIL (PENDING itself is pinned on the throwaway project, where it cannot move),
// so t22 does not turn this file red.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 300) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("static3-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
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

/// `/bin/bash <script> args`, so the test does not depend on the execute bit.
private func runScript(_ path: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 300) throws -> Ran {
    try run("/bin/bash", [path] + args, env: env, limit: limit)
}

private func realCheckStatic() -> String { scriptsDir.appendingPathComponent("check-static.sh").path }

/// `STATIC <rule> <STATUS>` lines in order: (rule, status). Indented detail lines and the STATIC-RESULT line are skipped.
private func staticLines(_ ran: Ran) -> [(rule: String, status: String)] {
    ran.lines.compactMap { line in
        guard line.hasPrefix("STATIC ") else { return nil }
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count == 3, parts[1] != "RESULT" else { return nil }
        return (parts[1], parts[2])
    }
}

private func status(of rule: String, in ran: Ran) -> String? {
    staticLines(ran).first { $0.rule == rule }?.status
}

/// The indented lines under `STATIC <rule> ...` up to the next STATIC line.
private func detail(of rule: String, in ran: Ran) -> [String] {
    var out: [String] = []
    var inside = false
    for line in ran.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line.hasPrefix("STATIC ") {
            inside = line.hasPrefix("STATIC \(rule) ")
        } else if inside, line.hasPrefix(" ") {
            out.append(line.trimmingCharacters(in: .whitespaces))
        }
    }
    return out
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

/// A throwaway project: scripts/check-static.sh (a copy of the real one) and the given Swift files under it.
private func withProject<T>(_ files: [String: String], _ body: (_ root: String, _ script: String) throws -> T) throws -> T {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("static3-proj-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let script = root.appendingPathComponent("scripts/check-static.sh")
    try fm.copyItem(at: scriptsDir.appendingPathComponent("check-static.sh"), to: script)
    for (rel, text) in files {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    return try body(root.path, script.path)
}

private let plainFile = ["Sources/SesameEngine/Other.swift": "enum Other {}\n"]

// MARK: the allowlist

private let planTwoAllowlist = [
    "file-open-parse FileGate",
    "file-open-parse IndexReader",
    "file-open-parse ModelFiles",
    "file-open-parse PreviewReader",
    "file-open-parse Probe",
    "file-open-parse Readers",
    "file-open-parse ScratchPNG",
    "file-open-parse SettingsFile",
    "sqlite-write IndexStore",
    "url-session ModelDownload",
    "write-open Probe",
    "write-delete Scratch",
    "write-delete ScratchPNG",
    "write-delete SesameFolder",
    "process-network Sources/Sesame/Setup/FolderPicker.swift",
    "process-network Sources/Sesame/HelperClient.swift",
]
private let planThreeAllowlist = [
    "process-network Sources/SesameEngine/GitFiles.swift",
    "log-write Log",
]

private let planEightAllowlist = [
    "literal-colours Sources/Sesame/UI/Design.swift",
]

private func entries(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

@Suite("StaticRulesPlan3Tests")
struct StaticRulesPlan3Tests {

    @Test("the allowlist of check-static.sh equals static-allowlist.txt and holds plan 2's 16 lines plus the two plan 3 lines plus the one plan 8 line (plan-8-t9 amended: literal-colours), once each")
    func allowlistHoldsEighteenLines() throws {
        let ran = try runScript(realCheckStatic(), ["--allowlist"])
        #expect(ran.status == 0, "check-static.sh --allowlist exited \(ran.status): \(ran.output)")
        let printed = entries(ran.output)
        let file = (try? String(contentsOf: scriptsDir.appendingPathComponent("kit-lib/static-allowlist.txt"), encoding: .utf8)) ?? ""
        ok(!file.isEmpty, "scripts/kit-lib/static-allowlist.txt is missing or empty")
        let written = entries(file)
        #expect(Set(printed) == Set(written), "the script prints \(printed.sorted()) and the file holds \(written.sorted())")
        #expect(printed.count == Set(printed).count, "the script prints a line twice: \(printed)")
        #expect(written.count == Set(written).count, "the file holds a line twice: \(written)")
        for (name, list) in [("the script's allowlist", printed), ("static-allowlist.txt", written)] {
            #expect(list.count == 19, "\(name) holds \(list.count) lines, expected 19 (16 of plan 2, 2 of plan 3 and 1 of plan 8): \(list)")
            for line in planTwoAllowlist + planThreeAllowlist + planEightAllowlist {
                #expect(list.contains(line), "\(name) lacks the line `\(line)`")
            }
            let extra = Set(list).subtracting(planTwoAllowlist + planThreeAllowlist + planEightAllowlist)
            #expect(extra.isEmpty, "\(name) holds lines no plan names: \(extra.sorted())")
        }
    }

    @Test("kit-privacy.sh static-allowlist agrees: ALLOWLIST OK with 19 entries (plan-8-t9 amended, was 18)")
    func kitPrivacyAgrees() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sesame-kit-static3-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let ran = try runScript(scriptsDir.appendingPathComponent("kit-privacy.sh").path, ["static-allowlist"],
                                env: ["KIT_ROOT": root.resolvingSymlinksInPath().path])
        #expect(ran.status == 0, "kit-privacy.sh static-allowlist exited \(ran.status): \(ran.output)")
        #expect(ran.output.contains("ALLOWLIST OK") && ran.output.contains("(19 entries)"),
                "expected `ALLOWLIST OK ... (19 entries)`, got: \(ran.output)")
    }

    // MARK: the 17th rule on the real tree

    @Test("--quick prints 18 STATIC lines, exit 0: the 16 plan 2 rules PASS in their order, then log-typed (PENDING until t22 adds Log, never FAIL), then literal-colours (plan-8-t9 amended: 17 to 18)")
    func quickPrintsSeventeenRules() throws {
        let ran = try runScript(realCheckStatic(), ["--quick"])
        let lines = staticLines(ran)
        #expect(lines.count == 18, "--quick printed \(lines.count) STATIC lines, expected 18: \(lines.map { $0.rule })")
        let planTwoRules = ["plist-lint", "no-camera-mic", "entitlements", "url-session", "file-open-parse", "write-delete", "sqlite-write",
                            "sqlite-app-open", "process-network", "app-imports", "user-defaults", "schema-columns", "anchor-keynames",
                            "anchor-filegate", "fake-embedder-readers", "test-only-launch-settings"]
        #expect(lines.map { $0.rule } == planTwoRules + ["log-typed", "literal-colours"], "the rules, in order: \(lines.map { $0.rule })")
        for rule in planTwoRules {
            #expect(status(of: rule, in: ran) == "PASS", "plan 2 rule \(rule) is \(status(of: rule, in: ran) ?? "missing"), expected PASS")
        }
        let logStatus = status(of: "log-typed", in: ran)
        #expect(logStatus == "PENDING" || logStatus == "PASS", "log-typed is \(logStatus ?? "missing"), expected PENDING (no Log yet) or PASS (after t22)")
        #expect(ran.status == 0, "--quick exited \(ran.status): \(ran.output)")
        let pending = logStatus == "PENDING" ? 1 : 0
        #expect(ran.output.contains("STATIC-RESULT ok (\(18 - pending) pass, 0 fail, \(pending) pending, 0 warn, quick)"),
                "the STATIC-RESULT line is wrong: \(ran.lines.last ?? "")")
    }

    // MARK: log-typed, on throwaway projects

    @Test("log-typed is PENDING (`no source file declares Log yet`) while no file declares Log: --quick exits 0, a full run exits 1")
    func logTypedPendingWithoutLog() throws {
        try withProject(plainFile) { _, script in
            let quick = try runScript(script, ["--quick"])
            #expect(status(of: "log-typed", in: quick) == "PENDING", "log-typed is \(status(of: "log-typed", in: quick) ?? "missing"): \(quick.output)")
            #expect(detail(of: "log-typed", in: quick) == ["no source file declares Log yet"], "detail: \(detail(of: "log-typed", in: quick))")
            #expect(quick.status == 0, "--quick exited \(quick.status): \(quick.output)")
            let full = try runScript(script, [])
            #expect(status(of: "log-typed", in: full) == "PENDING")
            #expect(full.status == 1, "a full run with log-typed PENDING exited \(full.status), expected 1")
        }
    }

    @Test("with Log declared, a log append outside the module Log fails log-typed and names the file; for each of the three log names",
          arguments: ["app.log", "index.log", "encode.log"])
    func appendOutsideLogFails(name: String) throws {
        let files = [
            "Sources/SesameEngine/Log.swift": "enum Log {}\n",
            "Sources/SesameHelper/Writer.swift": """
            import Foundation
            func plantedAppend(_ data: Data) {
                SesameFolder.append(data, to: SesameFolder.logs.appendingPathComponent("\(name)"))
            }

            """,
        ]
        try withProject(files) { _, script in
            let ran = try runScript(script, ["--quick"])
            #expect(status(of: "log-typed", in: ran) == "FAIL", "log-typed is \(status(of: "log-typed", in: ran) ?? "missing"): \(ran.output)")
            #expect(detail(of: "log-typed", in: ran).contains { $0.contains("Sources/SesameHelper/Writer.swift") },
                    "no detail line names Writer.swift: \(detail(of: "log-typed", in: ran))")
            #expect(ran.status == 1, "--quick with log-typed FAIL exited \(ran.status)")
        }
    }

    @Test("a plain write to a log name outside Log fails too (Data.write, a literal path)")
    func writeOutsideLogFails() throws {
        let files = [
            "Sources/SesameEngine/Log.swift": "enum Log {}\n",
            "Sources/Sesame/Writer.swift": """
            import Foundation
            func plantedWrite(_ data: Data) throws {
                try data.write(to: URL(fileURLWithPath: "/tmp/x/logs/app.log"))
            }

            """,
        ]
        try withProject(files) { _, script in
            let ran = try runScript(script, ["--quick"])
            #expect(status(of: "log-typed", in: ran) == "FAIL", "log-typed is \(status(of: "log-typed", in: ran) ?? "missing"): \(ran.output)")
            #expect(detail(of: "log-typed", in: ran).contains { $0.contains("Sources/Sesame/Writer.swift") },
                    "no detail line names Writer.swift: \(detail(of: "log-typed", in: ran))")
        }
    }

    @Test("a log name kept in a constant and then handed to SesameFolder.append in the same file fails")
    func nameInAConstantFails() throws {
        let files = [
            "Sources/SesameEngine/Log.swift": "enum Log {}\n",
            "Sources/SesameHelper/Writer.swift": """
            import Foundation
            let planted = "index.log"
            func plantedAppend(_ data: Data) {
                SesameFolder.append(data, to: SesameFolder.logs.appendingPathComponent(planted))
            }

            """,
        ]
        try withProject(files) { _, script in
            let ran = try runScript(script, ["--quick"])
            #expect(status(of: "log-typed", in: ran) == "FAIL", "log-typed is \(status(of: "log-typed", in: ran) ?? "missing"): \(ran.output)")
        }
    }

    @Test("the same append inside the module Log (a file named Log.swift, or a folder named Log) passes")
    func appendInsideLogPasses() throws {
        let body = """
        import Foundation
        enum Log {
            static func write(_ data: Data) {
                SesameFolder.append(data, to: SesameFolder.logs.appendingPathComponent("index.log"))
                SesameFolder.append(data, to: SesameFolder.logs.appendingPathComponent("app.log"))
                SesameFolder.append(data, to: SesameFolder.logs.appendingPathComponent("encode.log"))
            }
        }

        """
        try withProject(["Sources/SesameEngine/Log.swift": body].merging(plainFile) { a, _ in a }) { _, script in
            let ran = try runScript(script, ["--quick"])
            #expect(status(of: "log-typed", in: ran) == "PASS", "Log.swift: log-typed is \(status(of: "log-typed", in: ran) ?? "missing"): \(ran.output)")
            #expect(detail(of: "log-typed", in: ran).isEmpty, "Log.swift: detail \(detail(of: "log-typed", in: ran))")
        }
        let folder = [
            "Sources/SesameEngine/Log/Log.swift": "enum Log {}\n",
            "Sources/SesameEngine/Log/Writer.swift": body.replacingOccurrences(of: "enum Log {", with: "enum LogWriter {"),
        ]
        try withProject(folder.merging(plainFile) { a, _ in a }) { _, script in
            let ran = try runScript(script, ["--quick"])
            #expect(status(of: "log-typed", in: ran) == "PASS", "Log/ folder: log-typed is \(status(of: "log-typed", in: ran) ?? "missing"): \(ran.output)")
        }
    }

    @Test("log-typed is not over broad: reading a log, a comment, another .log name and an append to another file all pass")
    func notOverBroad() throws {
        let files = [
            "Sources/SesameEngine/Log.swift": "enum Log {}\n",
            "Sources/SesameEngine/Reader.swift": """
            import Foundation
            // SesameFolder.append(data, to: logs.appendingPathComponent("index.log")) is only a comment here
            func plantedLook() -> Bool {
                FileManager.default.fileExists(atPath: "logs/index.log") || FileManager.default.fileExists(atPath: "logs/app.log")
            }
            func plantedOtherAppend(_ data: Data) {
                SesameFolder.append(data, to: SesameFolder.root.appendingPathComponent("notes.txt"))
                SesameFolder.append(data, to: SesameFolder.root.appendingPathComponent("debug.log"))
                SesameFolder.append(data, to: SesameFolder.root.appendingPathComponent("myindex.log"))
            }

            """,
        ]
        try withProject(files) { _, script in
            let ran = try runScript(script, ["--quick"])
            #expect(status(of: "log-typed", in: ran) == "PASS", "log-typed is \(status(of: "log-typed", in: ran) ?? "missing"): \(ran.output)\n\(detail(of: "log-typed", in: ran))")
        }
    }

    // MARK: process-network, the path of GitFiles.swift

    @Test("process-network: Process( is allowed in the three exact paths and fails in any other file, including a GitFiles.swift of another folder")
    func processNetworkPaths() throws {
        let spawn = "import Foundation\nfunc plantedSpawn() {\n    let p = Process()\n    _ = p\n}\n"
        let allowed = [
            "Sources/SesameEngine/GitFiles.swift",
            "Sources/Sesame/Setup/FolderPicker.swift",
            "Sources/Sesame/HelperClient.swift",
        ]
        let refused = [
            "Sources/SesameEngine/Other.swift",
            "Sources/SesameHelper/GitFiles.swift",
            "Sources/Sesame/GitFiles.swift",
            "Sources/SesameEngine/Git/GitFiles.swift",
        ]
        for rel in allowed {
            try withProject([rel: spawn]) { _, script in
                let ran = try runScript(script, ["--quick"])
                #expect(status(of: "process-network", in: ran) == "PASS", "Process( in \(rel): process-network is \(status(of: "process-network", in: ran) ?? "missing"): \(detail(of: "process-network", in: ran))")
            }
        }
        for rel in refused {
            try withProject([rel: spawn]) { _, script in
                let ran = try runScript(script, ["--quick"])
                #expect(status(of: "process-network", in: ran) == "FAIL", "Process( in \(rel): process-network is \(status(of: "process-network", in: ran) ?? "missing"), expected FAIL")
                #expect(detail(of: "process-network", in: ran).contains { $0.contains(rel) }, "no detail line names \(rel): \(detail(of: "process-network", in: ran))")
            }
        }
    }

    // MARK: --selftest

    @Test("--selftest: git-process-elsewhere and log-append-elsewhere are RED, and every plan 2 plant stays RED")
    func selftestPlants() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("static3-selftest-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let ran = try runScript(realCheckStatic(), ["--selftest"], env: ["TMPDIR": tmp.resolvingSymlinksInPath().path + "/"])
        #expect(ran.status == 0, "--selftest exited \(ran.status): \(ran.output)")
        let planTwoPlants = [
            "urlsession", "second-o_rdonly-o_nofollow", "model-host-fallback", "removeitem", "probe-removeitem", "probe-unlink",
            "probe-rename", "removeitem-in-another-app-file", "app-sqlite-open", "app-process-and-network-apis", "helper-process",
            "helper-file-named-folderpicker", "probe-second-open", "probe-other-path", "fake-embedder-third-reader",
        ]
        for name in planTwoPlants + ["git-process-elsewhere", "log-append-elsewhere", "literal-colour-elsewhere"] {
            #expect(ran.lines.contains("SELFTEST \(name) RED"), "no line `SELFTEST \(name) RED` in the selftest output")
        }
        #expect(ran.lines.contains("SELFTEST OK"), "no `SELFTEST OK` line")
        for bad in ["NOT RED", "INVALID", "SELFTEST ERROR"] {
            #expect(!ran.output.contains(bad), "the selftest printed `\(bad)`")
        }
    }
}
