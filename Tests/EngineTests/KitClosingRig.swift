import Foundation
import Testing

// plan-6-t9, tester step: the child-process rig the five new closing suites share (KitIndex50kTests, KitRunClosingChecksTests,
// KitRunBatchesTests, KitVerifyOnlyTests, KitResetBaselineTests). Nothing here launches Sesame or runs a recipe: a test builds a temp kit root
// (a folder named sesame-kit*), runs the real scripts or a bash harness that sources them with every app-facing call replaced by a stub, and
// reads what came out. Expected values are written by hand in the tests, never read from the scripts under test.

enum KC {
    /// The project root. KC_ROOT (a folder that holds a scripts/ folder, e.g. a `git archive HEAD scripts` snapshot) points the suites at the
    /// kit as it was before a change, which is how a new suite is shown red without touching the repository.
    static let root = ProcessInfo.processInfo.environment["KC_ROOT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let scripts = root.appendingPathComponent("scripts").path
    static let lib = root.appendingPathComponent("scripts/kit-lib").path

    struct Ran: Sendable {
        let status: Int32
        let output: String
    }

    static func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("kitclosing-out-" + UUID().uuidString)
        fm.createFile(atPath: out.path, contents: nil)
        defer { try? fm.removeItem(at: out) }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["KIT_SCREEN_LOCK_READING"] = "<key>IOConsoleLocked</key>\n<false/>\n"
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

    private final class Cleanup: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        func run() {
            lock.lock(); let all = paths; lock.unlock()
            for p in all { try? FileManager.default.removeItem(atPath: p) }
        }
    }
    private static let cleanup = Cleanup()
    private static let registered: Void = { atexit { KC.cleanup.run() } }()

    /// A fresh temp folder, removed at exit. The `kitRoot` form is named sesame-kit*, as the kit's own safety check wants.
    static func tempDir(_ prefix: String = "kit-closing-") throws -> String {
        _ = registered
        let made = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        cleanup.add(made.path)
        return made.path
    }

    static func kitRoot() throws -> String {
        let base = try tempDir()
        let made = base + "/sesame-kit"
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        return made
    }

    static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    static func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    static func lines(_ text: String) -> [String] { text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
    static func has(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    /// A bash harness that sources the real common.sh, recipes.sh and every checks-*.sh (as kit-run.sh does) with `body` after it.
    static func bash(_ body: String, kit: String, env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
        let script = """
        #!/bin/bash
        export KIT_ROOT="\(kit)"
        . "\(lib)/common.sh"
        . "\(lib)/recipes.sh"
        for f in "\(lib)"/checks-*.sh; do [ -f "$f" ] && . "$f"; done
        \(body)
        """
        let path = try tempDir() + "/harness.sh"
        try write(path, script)
        return try run("/bin/bash", [path], env: env, limit: limit)
    }

    /// The ids of checks.tsv: (id, first slice, kind), in order.
    static func checksTSV() -> [(id: String, slice: Int, kind: String)] {
        (read(lib + "/checks.tsv") ?? "").split(separator: "\n").compactMap { l in
            let f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let s = Int(f[1]) else { return nil }
            return (f[0], s, f[2])
        }
    }

    /// The text of one shell function: from `name() {` to the first line that is just `}`.
    static func shellFunction(_ name: String, in text: String) -> String? {
        let ls = text.components(separatedBy: "\n")
        guard let start = ls.firstIndex(where: { $0.hasPrefix(name + "() {") || $0.hasPrefix(name + "()  {") }) else { return nil }
        var body: [String] = []
        for l in ls[start...] {
            body.append(l)
            if l == "}" { break }
        }
        return body.joined(separator: "\n")
    }
}
