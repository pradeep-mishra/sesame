import CryptoKit
import Foundation
import Testing

// plan-3-t7, tester step: `scripts/kit-selfrun.sh` (the product-level self-runs 2 and 3 of verify.md) and the reset that
// keeps its app (`scripts/kit-reset.sh --bundle-only --id <id>`).
// Written from the plan-3-t7 entry, verify.md (Self-run), the design's anchors (the `Rules` table with its key names, and
// `FileGate` with `O_RDONLY | O_NOFOLLOW`) and the key names in scripts/check-static.sh. No file under Sources/ is read: the
// script runs over a hand-written mini project the test makes under $TMPDIR (named by KIT_SELFRUN_SOURCE), so the real
// project is never copied, never built and never broken.
//
// Nothing here starts an app, runs kit-reset.sh for real (only `--bundle-only`, with a temp KIT_ROOT), runs a real
// `swift build` or touches the project: `build` runs only against the mini project with a fake `swift` first on PATH, and its
// real text is checked.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - Exit codes: 0 done; 1 error (the source folder is missing, the build failed, the self-run app is missing); 2 usage;
//     4 a precondition does not hold (no copy yet, a design-anchor mismatch, a copy already broken).
//   - `break` checks every anchor before it changes any byte, so a mismatch changes nothing and records nothing.
//   - `break` prints one line `changed <path>:<line>: <new text>` per changed line.
//   - A design-anchor mismatch prints `design-anchor mismatch: <anchor>`: the anchor is the literal as written (`".pem"`),
//     the flags (`O_RDONLY | O_NOFOLLOW`) or the symbol (`Rules`, `FileGate`).
//   - `restore` copies back only the files `break` changed (so `.build` and `dist` of the copy survive for an incremental
//     build) and then proves byte equality with the source, exit 4 when it does not hold.
//   - `build` runs `swift build -c release` and `scripts/bundle.sh` inside the copy and keeps the copy's `dist/Sesame.app`
//     as `$KIT_ROOT/break/Sesame.app`; the marker `$KIT_ROOT/break/selfrun-app` holds that path and is written only after
//     the build succeeded.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitselfrun-out-" + UUID().uuidString)
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

private func scriptPath(_ name: String) -> String? {
    let url = projectRoot.appendingPathComponent("scripts/" + name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record(Comment(rawValue: "scripts/\(name) not found"))
        return nil
    }
    return url.path
}

/// The script's code: every line that is not a comment.
private func scriptCode(_ name: String) -> String? {
    guard let path = scriptPath(name), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

private func write(_ text: String, to path: String, executable: Bool = false) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
}

private func exists(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)) != nil
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// path (relative to `root`) -> sha256 of the bytes, or `link:<target>` for a symbolic link. Folders are not listed.
private func digest(_ root: String) -> [String: String] {
    var found: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(atPath: root) else { return found }
    for case let rel as String in walker {
        let full = root + "/" + rel
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: full) {
            found[rel] = "link:" + target
            continue
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
        found[rel] = sha256((try? Data(contentsOf: URL(fileURLWithPath: full))) ?? Data())
    }
    return found
}

/// What a copy does not hold (verify.md and the entry): `.build`, `dist`, `.git`, `.ril/evidence`; `third_party` is a link.
private func notCopied(_ rel: String) -> Bool {
    for skipped in [".build", "dist", ".git", ".ril/evidence", "third_party"] where rel == skipped || rel.hasPrefix(skipped + "/") {
        return true
    }
    return false
}

private func filtered(_ d: [String: String]) -> [String: String] {
    d.filter { !notCopied($0.key) }
}

// MARK: the mini project

private let keyLiterals = [".pem", ".key", ".p12", ".pfx", "id_rsa", ".env", ".kdbx"]
private let brokenLiterals = [".pem", "id_rsa", ".env"]
private let keptLiterals = [".key", ".p12", ".pfx", ".kdbx"]

private let rulesText = """
import Foundation

public enum Rules {
    // the never-read names, one literal each
    static let neverRead: [String] = [
        ".pem",
        ".key",
        ".p12",
        ".pfx",
        "id_rsa",
        ".env",
        ".kdbx",
    ]
    static let hiddenMark = "."
}

"""

private let gateText = """
import Foundation

enum FileGate {
    static let flags = O_RDONLY | O_NOFOLLOW
    static func open(_ path: String) -> Int32 { Foundation.open(path, flags) }
}

"""

private let fakeBundle = """
#!/bin/bash
set -eu
project="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project/dist/Sesame.app/Contents/MacOS"
cp "$project/Sources/SesameEngine/FileGate.swift" "$project/dist/Sesame.app/Contents/MacOS/Sesame"
echo "made $project/dist/Sesame.app"

"""

private let fakeSwift = """
#!/bin/bash
echo "$PWD" > "$FAKE_SWIFT_LOG.cwd"
echo "$*" >> "$FAKE_SWIFT_LOG.args"
if [ -n "${FAKE_SWIFT_FAIL:-}" ]; then echo "error: fake swift failed"; exit 1; fi
mkdir -p .build/release
echo built > .build/release/obj

"""

private struct Kit {
    let root: String
    let src: String
    let aux: String
    var copy: String { root + "/break/project" }
    var rulesInCopy: String { copy + "/Sources/SesameEngine/Rules.swift" }
    var gateInCopy: String { copy + "/Sources/SesameEngine/FileGate.swift" }
    var rulesInSource: String { src + "/Sources/SesameEngine/Rules.swift" }
    var gateInSource: String { src + "/Sources/SesameEngine/FileGate.swift" }

    func env(_ extra: [String: String] = [:]) -> [String: String] {
        var e = [
            "KIT_ROOT": root,
            "KIT_SELFRUN_SOURCE": src,
            "PATH": aux + "/fakebin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            "FAKE_SWIFT_LOG": aux + "/swift",
        ]
        for (k, v) in extra { e[k] = v }
        return e
    }
}

/// A fresh KIT_ROOT (the kit needs a folder named sesame-kit*), a hand-written mini project and a fake `swift`, all removed afterwards.
private func withKit<T>(_ body: (Kit) throws -> T) throws -> T {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("kitselfrun-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let real = base.resolvingSymlinksInPath().path
    let kit = Kit(root: real + "/sesame-kit", src: real + "/src", aux: real + "/aux")
    try fm.createDirectory(atPath: kit.root, withIntermediateDirectories: true)
    try write(rulesText, to: kit.rulesInSource)
    try write(gateText, to: kit.gateInSource)
    try write("// another source file\nlet other = 1\n", to: kit.src + "/Sources/SesameEngine/Other.swift")
    try write("// mini package\n", to: kit.src + "/Package.swift")
    try write("name,value\nexact-01,a\n", to: kit.src + "/fixtures/answers.csv")
    try write(fakeBundle, to: kit.src + "/scripts/bundle.sh", executable: true)
    try write("not copied\n", to: kit.src + "/.build/junk.o")
    try write("the project bundle\n", to: kit.src + "/dist/Sesame.app/Contents/MacOS/Sesame")
    try write("ref: refs/heads/main\n", to: kit.src + "/.git/HEAD")
    try write("old evidence\n", to: kit.src + "/.ril/evidence/S8/v1/out.txt")
    try write("{\"state\":1}\n", to: kit.src + "/.ril/state.json")
    try write("a vendored file\n", to: kit.src + "/third_party/lib/lib.txt")
    try write(fakeSwift, to: kit.aux + "/fakebin/swift", executable: true)
    return try body(kit)
}

@discardableResult
private func selfrunArgs(_ kit: Kit, _ args: [String], env: [String: String] = [:]) throws -> Ran {
    guard let path = scriptPath("kit-selfrun.sh") else { return Ran(status: -1, output: "kit-selfrun.sh not found") }
    return try run(path, args, env: kit.env(env))
}

@discardableResult
private func selfrun(_ kit: Kit, _ args: String..., env: [String: String] = [:]) throws -> Ran {
    try selfrunArgs(kit, args, env: env)
}

/// The copy holds exactly the source's files that a copy holds, byte for byte, and links `third_party`.
private func copyEqualsSource(_ kit: Kit, sourceLocation: SourceLocation = #_sourceLocation) {
    let copyDigest = digest(kit.copy)
    ok(filtered(copyDigest) == filtered(digest(kit.src)),
       "the copy differs from the source: \(Set(filtered(copyDigest).keys).symmetricDifference(Set(filtered(digest(kit.src)).keys)).sorted()) or a file's bytes",
       sourceLocation: sourceLocation)
}

private func sourceDigest(_ kit: Kit) -> [String: String] { digest(kit.src) }

private func changedLines(_ a: String, _ b: String) -> [Int] {
    let x = a.split(separator: "\n", omittingEmptySubsequences: false)
    let y = b.split(separator: "\n", omittingEmptySubsequences: false)
    guard x.count == y.count else { return Array(0..<max(x.count, y.count)) }
    return (0..<x.count).filter { x[$0] != y[$0] }
}

// MARK: anchor mismatches

fileprivate struct Mismatch: Sendable, CustomStringConvertible {
    let name: String
    let mode: String
    let anchor: String
    let damage: @Sendable (Kit) throws -> Void
    var description: String { name }
}

fileprivate let mismatches: [Mismatch] = [
    Mismatch(name: "a key literal twice", mode: "key-names", anchor: ".pem") { kit in
        try write(read(kit.rulesInCopy).replacingOccurrences(of: "    static let hiddenMark", with: "    static let again = \".pem\"\n    static let hiddenMark"), to: kit.rulesInCopy)
    },
    Mismatch(name: "id_rsa twice", mode: "key-names", anchor: "id_rsa") { kit in
        try write(read(kit.rulesInCopy).replacingOccurrences(of: "    static let hiddenMark", with: "    static let again = \"id_rsa\"\n    static let hiddenMark"), to: kit.rulesInCopy)
    },
    Mismatch(name: ".env twice", mode: "key-names", anchor: ".env") { kit in
        try write(read(kit.rulesInCopy).replacingOccurrences(of: "    static let hiddenMark", with: "    static let again = \".env\"\n    static let hiddenMark"), to: kit.rulesInCopy)
    },
    Mismatch(name: "a key literal missing", mode: "key-names", anchor: ".env") { kit in
        try write(read(kit.rulesInCopy).replacingOccurrences(of: "        \".env\",\n", with: ""), to: kit.rulesInCopy)
    },
    Mismatch(name: "id_rsa missing", mode: "key-names", anchor: "id_rsa") { kit in
        try write(read(kit.rulesInCopy).replacingOccurrences(of: "        \"id_rsa\",\n", with: "        \"id_rsa_x\",\n"), to: kit.rulesInCopy)
    },
    Mismatch(name: "no file declares Rules", mode: "key-names", anchor: "Rules") { kit in
        try write(read(kit.rulesInCopy).replacingOccurrences(of: "enum Rules", with: "enum Ruleset"), to: kit.rulesInCopy)
    },
    Mismatch(name: "Rules declared in two files", mode: "key-names", anchor: "Rules") { kit in
        try write("enum Rules {\n}\n", to: kit.copy + "/Sources/SesameEngine/RulesToo.swift")
    },
    Mismatch(name: "the flags twice", mode: "write-picked", anchor: "O_RDONLY | O_NOFOLLOW") { kit in
        try write(read(kit.gateInCopy) + "let again = O_RDONLY | O_NOFOLLOW\n", to: kit.gateInCopy)
    },
    Mismatch(name: "the flags missing", mode: "write-picked", anchor: "O_RDONLY | O_NOFOLLOW") { kit in
        try write(read(kit.gateInCopy).replacingOccurrences(of: "O_RDONLY | O_NOFOLLOW", with: "O_RDONLY"), to: kit.gateInCopy)
    },
    Mismatch(name: "no file declares FileGate", mode: "write-picked", anchor: "FileGate") { kit in
        try write(read(kit.gateInCopy).replacingOccurrences(of: "enum FileGate", with: "enum Gate"), to: kit.gateInCopy)
    },
    Mismatch(name: "FileGate declared in two files", mode: "write-picked", anchor: "FileGate") { kit in
        try write("enum FileGate {\n}\n", to: kit.copy + "/Sources/SesameEngine/GateToo.swift")
    },
]


// MARK: the script

@Suite("KitSelfrunScriptTests")
struct KitSelfrunScriptTests {

    // MARK: bash -n, usage, text contract

    @Test("bash -n finds no syntax error in kit-selfrun.sh or kit-reset.sh")
    func bashSyntax() throws {
        for name in ["kit-selfrun.sh", "kit-reset.sh"] {
            guard let path = scriptPath(name) else { continue }
            let ran = try run("/bin/bash", ["-n", path])
            #expect(ran.status == 0, "bash -n \(name) exited \(ran.status): \(ran.output)")
            #expect(ran.output.isEmpty, "bash -n \(name) printed: \(ran.output)")
        }
    }

    @Test("the script is executable")
    func isExecutable() throws {
        guard let path = scriptPath("kit-selfrun.sh") else { return }
        #expect(FileManager.default.isExecutableFile(atPath: path), "kit-selfrun.sh is not executable")
    }

    @Test("no mode is usage, exit 2, naming every mode, and nothing is written")
    func noModeIsUsage() throws {
        try withKit { kit in
            let before = digest(kit.root)
            let ran = try selfrun(kit)
            #expect(ran.status == 2, "no mode exited \(ran.status), wanted 2: \(ran.output)")
            for word in ["copy-project", "break key-names|write-picked", "build", "restore", "clean"] {
                #expect(ran.output.contains(word), "the usage does not name `\(word)`: \(ran.output)")
            }
            #expect(digest(kit.root) == before, "files were written under KIT_ROOT")
            #expect(!exists(kit.root + "/break"), "break/ was made by a usage error")
        }
    }

    @Test("wrong arguments are usage, exit 2, and write nothing", arguments: [
        ["frobnicate"], ["break"], ["break", "everything"], ["break", "key-names", "extra"],
        ["copy-project", "extra"], ["build", "extra"], ["restore", "extra"], ["clean", "extra"],
    ])
    func wrongArgumentsAreUsage(_ args: [String]) throws {
        try withKit { kit in
            let ran = try selfrunArgs(kit, args)
            #expect(ran.status == 2, "kit-selfrun.sh \(args) exited \(ran.status), wanted 2: \(ran.output)")
            #expect(!exists(kit.root + "/break"), "break/ was made by a usage error")
        }
    }

    @Test("the script reads the source from KIT_SELFRUN_SOURCE and falls back to the project, and starts nothing")
    func textContract() throws {
        guard let code = scriptCode("kit-selfrun.sh") else { return }
        ok(code.contains("KIT_SELFRUN_SOURCE"), "the script does not read KIT_SELFRUN_SOURCE")
        ok(code.contains("KIT_PROJECT"), "the script has no fallback to the project (KIT_PROJECT) when KIT_SELFRUN_SOURCE is unset")
        ok(code.contains("swift build -c release"), "`build` does not run `swift build -c release`")
        ok(code.contains("scripts/bundle.sh"), "`build` does not run scripts/bundle.sh")
        ok(code.contains("selfrun-app"), "`build` does not write the keep-app marker selfrun-app")
        for word in ["kit-reset.sh", "kit-run.sh", "kit-launch.sh", "kit-ax.sh", "osascript", "sudo", "hdiutil"] {
            ok(!code.contains(word), "the script names `\(word)`: it starts nothing and resets nothing")
        }
        ok(code.range(of: "(^|[;&|(`]|\\$\\()[ \\t]*git[ \\t]", options: .regularExpression) == nil, "the script runs a git command")
        // every removal stays under the break folder or the kit's app
        for line in code.split(separator: "\n") where line.range(of: "(^|[^a-z])rm -", options: .regularExpression) != nil {
            ok(line.contains("$KIT_ROOT") || line.contains("${KIT_ROOT}") || line.contains("$BREAK") || line.contains("$COPY") || line.contains("$KIT_APP"),
               "a removal that is not visibly under $KIT_ROOT/break or the kit's app: \(line)")
        }
    }

    // MARK: copy-project

    @Test("copy-project copies the source to break/project without .build, dist, .git and .ril/evidence, and links third_party")
    func copyProject() throws {
        try withKit { kit in
            let before = sourceDigest(kit)
            let ran = try selfrun(kit, "copy-project")
            #expect(ran.status == 0, "copy-project exited \(ran.status): \(ran.output)")
            copyEqualsSource(kit)
            for gone in [".build", "dist", ".git", ".ril/evidence"] {
                #expect(!exists(kit.copy + "/" + gone), "\(gone) was copied")
            }
            #expect(exists(kit.copy + "/.ril/state.json"), ".ril/state.json was left out: only .ril/evidence is")
            #expect(exists(kit.copy + "/scripts/bundle.sh"), "scripts/bundle.sh was left out")
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: kit.copy + "/third_party")
            #expect(target != nil, "third_party is not a symbolic link in the copy")
            if let target {
                #expect(URL(fileURLWithPath: target).resolvingSymlinksInPath().path == URL(fileURLWithPath: kit.src + "/third_party").resolvingSymlinksInPath().path,
                        "third_party links to \(target), not the source's third_party")
            }
            #expect(FileManager.default.isExecutableFile(atPath: kit.copy + "/scripts/bundle.sh"), "the copy of bundle.sh lost its executable bit")
            #expect(sourceDigest(kit) == before, "the source changed")
        }
    }

    @Test("a second copy-project replaces the copy: a stray file in it is gone")
    func copyProjectTwice() throws {
        try withKit { kit in
            try selfrun(kit, "copy-project")
            try write("stray\n", to: kit.copy + "/Sources/SesameEngine/Stray.swift")
            try write("a broken byte\n", to: kit.gateInCopy)
            let ran = try selfrun(kit, "copy-project")
            #expect(ran.status == 0, "the second copy-project exited \(ran.status): \(ran.output)")
            #expect(!exists(kit.copy + "/Sources/SesameEngine/Stray.swift"), "the stray file is still in the copy")
            copyEqualsSource(kit)
        }
    }

    @Test("copy-project from a missing source is exit 1 and makes no copy")
    func copyProjectMissingSource() throws {
        try withKit { kit in
            let ran = try selfrun(kit, "copy-project", env: ["KIT_SELFRUN_SOURCE": kit.aux + "/no-such-folder"])
            #expect(ran.status == 1, "exited \(ran.status), wanted 1: \(ran.output)")
            #expect(!exists(kit.copy), "a copy was made from a missing source")
        }
    }

    // MARK: break key-names

    @Test("break key-names changes exactly the literals .pem, id_rsa and .env of the copy's Rules, one line each, and prints them")
    func breakKeyNames() throws {
        try withKit { kit in
            let before = sourceDigest(kit)
            try selfrun(kit, "copy-project")
            let ran = try selfrun(kit, "break", "key-names")
            #expect(ran.status == 0, "break key-names exited \(ran.status): \(ran.output)")
            let original = read(kit.rulesInSource)
            let broken = read(kit.rulesInCopy)
            let changed = changedLines(original, broken)
            let originalLines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let brokenLines = broken.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(changed.count == 3, "\(changed.count) lines changed, wanted 3: \(changed)")
            for index in changed where index < originalLines.count && index < brokenLines.count {
                let was = originalLines[index].trimmingCharacters(in: .whitespaces)
                #expect(["\".pem\",", "\"id_rsa\",", "\".env\","].contains(was), "line \(index + 1) was changed but held `\(was)`")
                let now = brokenLines[index].trimmingCharacters(in: .whitespaces)
                #expect(now.hasPrefix("\"") && now.hasSuffix("\","), "the new line is not a string literal in the same place: `\(now)`")
                for name in keyLiterals {
                    #expect(!now.contains("\"" + name + "\""), "the new line `\(now)` still holds the literal \"\(name)\"")
                }
                #expect(ran.output.contains(now), "break did not print the changed line `\(now)`: \(ran.output)")
            }
            for name in brokenLiterals {
                #expect(!broken.contains("\"" + name + "\""), "\"\(name)\" is still in the copy's Rules")
            }
            for name in keptLiterals {
                #expect(broken.components(separatedBy: "\"" + name + "\"").count == 2, "\"\(name)\" must stay once in the copy's Rules")
            }
            // nothing else moved
            let copyDigest = filtered(digest(kit.copy))
            let sourceFiltered = filtered(digest(kit.src))
            let different = copyDigest.filter { sourceFiltered[$0.key] != $0.value }.keys.sorted()
            #expect(different == ["Sources/SesameEngine/Rules.swift"], "files that differ from the source: \(different)")
            #expect(sourceDigest(kit) == before, "the source changed")
        }
    }

    // MARK: break write-picked

    @Test("break write-picked rewrites the one O_RDONLY | O_NOFOLLOW of the copy's FileGate and no other line")
    func breakWritePicked() throws {
        try withKit { kit in
            let before = sourceDigest(kit)
            try selfrun(kit, "copy-project")
            let ran = try selfrun(kit, "break", "write-picked")
            #expect(ran.status == 0, "break write-picked exited \(ran.status): \(ran.output)")
            let original = read(kit.gateInSource)
            let broken = read(kit.gateInCopy)
            let expected = original.replacingOccurrences(of: "O_RDONLY | O_NOFOLLOW", with: "O_RDWR | O_NOFOLLOW | O_TRUNC")
            #expect(broken == expected, "the broken FileGate is not the source with the flags replaced:\n\(broken)")
            #expect(changedLines(original, broken).count == 1, "a line diff shows \(changedLines(original, broken).count) lines, wanted exactly 1")
            #expect(!broken.contains("O_RDONLY"), "O_RDONLY is still in the copy's FileGate")
            let now = broken.split(separator: "\n").first { $0.contains("O_TRUNC") }.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            #expect(ran.output.contains(now), "break did not print the changed line `\(now)`: \(ran.output)")
            let copyDigest = filtered(digest(kit.copy))
            let sourceFiltered = filtered(digest(kit.src))
            let different = copyDigest.filter { sourceFiltered[$0.key] != $0.value }.keys.sorted()
            #expect(different == ["Sources/SesameEngine/FileGate.swift"], "files that differ from the source: \(different)")
            #expect(sourceDigest(kit) == before, "the source changed")
        }
    }

    // MARK: restore

    @Test("restore returns the copy to byte equality with the source after either break, and the copy can be broken again")
    func restoreAfterEachBreak() throws {
        try withKit { kit in
            let before = sourceDigest(kit)
            try selfrun(kit, "copy-project")
            for mode in ["key-names", "write-picked", "key-names"] {
                let broke = try selfrun(kit, "break", mode)
                #expect(broke.status == 0, "break \(mode) exited \(broke.status): \(broke.output)")
                let notEqual = filtered(digest(kit.copy)) != filtered(digest(kit.src))
                #expect(notEqual, "break \(mode) changed nothing")
                let ran = try selfrun(kit, "restore")
                #expect(ran.status == 0, "restore exited \(ran.status): \(ran.output)")
                copyEqualsSource(kit)
            }
            #expect(sourceDigest(kit) == before, "the source changed")
        }
    }

    @Test("restore on a copy that is not broken is exit 0 and leaves it equal")
    func restoreUnbroken() throws {
        try withKit { kit in
            try selfrun(kit, "copy-project")
            let ran = try selfrun(kit, "restore")
            #expect(ran.status == 0, "restore exited \(ran.status): \(ran.output)")
            copyEqualsSource(kit)
        }
    }

    @Test("restore with no copy is exit 4, not valid")
    func restoreWithoutCopy() throws {
        try withKit { kit in
            let ran = try selfrun(kit, "restore")
            #expect(ran.status == 4, "restore with no copy exited \(ran.status), wanted 4: \(ran.output)")
        }
    }

    @Test("restore proves byte equality: a file it did not break that differs from the source is exit 4")
    func restoreProvesEquality() throws {
        try withKit { kit in
            try selfrun(kit, "copy-project")
            try write("let other = 2\n", to: kit.copy + "/Sources/SesameEngine/Other.swift")
            let ran = try selfrun(kit, "restore")
            #expect(ran.status == 4, "restore exited \(ran.status), wanted 4 for a copy that still differs: \(ran.output)")
        }
    }

    // MARK: a copy that is already broken, a missing copy

    @Test("a second break on a broken copy is exit 4 and changes nothing, whichever mode it is")
    func secondBreak() throws {
        try withKit { kit in
            try selfrun(kit, "copy-project")
            for (first, second) in [("key-names", "key-names"), ("key-names", "write-picked"), ("write-picked", "write-picked"), ("write-picked", "key-names")] {
                try selfrun(kit, "break", first)
                let state = digest(kit.copy)
                let ran = try selfrun(kit, "break", second)
                #expect(ran.status == 4, "break \(second) on a copy broken by \(first) exited \(ran.status), wanted 4: \(ran.output)")
                #expect(digest(kit.copy) == state, "the second break changed the copy")
                try selfrun(kit, "restore")
            }
        }
    }

    @Test("break with no copy is exit 4, not valid")
    func breakWithoutCopy() throws {
        try withKit { kit in
            for mode in ["key-names", "write-picked"] {
                let ran = try selfrun(kit, "break", mode)
                #expect(ran.status == 4, "break \(mode) with no copy exited \(ran.status), wanted 4: \(ran.output)")
            }
        }
    }

    // MARK: design-anchor mismatches

    @Test("an anchor found twice or not at all is exit 4 `design-anchor mismatch: <anchor>`, and nothing is changed or recorded", arguments: mismatches)
    fileprivate func anchorMismatch(_ m: Mismatch) throws {
        try withKit { kit in
            try selfrun(kit, "copy-project")
            try m.damage(kit)
            let state = digest(kit.copy)
            let ran = try selfrun(kit, "break", m.mode)
            #expect(ran.status == 4, "\(m.name): break \(m.mode) exited \(ran.status), wanted 4: \(ran.output)")
            #expect(ran.output.contains("design-anchor mismatch:"), "\(m.name): no `design-anchor mismatch:` line: \(ran.output)")
            #expect(ran.output.contains(m.anchor), "\(m.name): the mismatch line does not name the anchor `\(m.anchor)`: \(ran.output)")
            #expect(digest(kit.copy) == state, "\(m.name): a mismatch changed the copy (every anchor is checked before any byte is changed)")
            // nothing was recorded as broken: after the damage is repaired the break works
            try selfrun(kit, "copy-project")
            let again = try selfrun(kit, "break", m.mode)
            #expect(again.status == 0, "\(m.name): the break after a repaired copy exited \(again.status): \(again.output)")
        }
    }

    @Test("break key-names checks all three anchors first: one bad anchor changes none of the three")
    func keyNamesIsAllOrNothing() throws {
        try withKit { kit in
            try selfrun(kit, "copy-project")
            try write(read(kit.rulesInCopy).replacingOccurrences(of: "        \".env\",\n", with: ""), to: kit.rulesInCopy)
            let state = read(kit.rulesInCopy)
            let ran = try selfrun(kit, "break", "key-names")
            #expect(ran.status == 4, "exited \(ran.status), wanted 4: \(ran.output)")
            #expect(read(kit.rulesInCopy) == state, "the literals before the bad one were changed")
        }
    }

    // MARK: build (text-checked and run only against the mini project with a fake swift)

    @Test("build with no copy is exit 4, runs no swift and writes no marker")
    func buildWithoutCopy() throws {
        try withKit { kit in
            let ran = try selfrun(kit, "build")
            #expect(ran.status == 4, "build with no copy exited \(ran.status), wanted 4: \(ran.output)")
            #expect(!exists(kit.aux + "/swift.args"), "swift was run")
            #expect(!exists(kit.root + "/break/selfrun-app"), "a marker was written")
        }
    }

    @Test("build runs swift build -c release and bundle.sh inside the copy, keeps the copy's app and the marker, and replaces apps/Sesame.app")
    func buildKeepsTheApp() throws {
        try withKit { kit in
            let before = sourceDigest(kit)
            try selfrun(kit, "copy-project")
            try selfrun(kit, "break", "write-picked")
            try write("an older app\n", to: kit.root + "/apps/Sesame.app/Contents/MacOS/Sesame")
            try write("left over\n", to: kit.root + "/apps/Sesame.app/Contents/MacOS/Old")
            let ran = try selfrun(kit, "build")
            #expect(ran.status == 0, "build exited \(ran.status): \(ran.output)")
            let args = read(kit.aux + "/swift.args")
            #expect(lines(args).contains { $0.hasPrefix("build") && $0.contains("-c release") }, "swift was run with: \(args)")
            let cwd = read(kit.aux + "/swift.cwd").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == URL(fileURLWithPath: kit.copy).resolvingSymlinksInPath().path,
                    "swift ran in \(cwd), not in the copy \(kit.copy)")
            let brokenGate = read(kit.gateInCopy)
            #expect(read(kit.root + "/break/Sesame.app/Contents/MacOS/Sesame") == brokenGate, "break/Sesame.app is not the copy's app (it must hold the broken FileGate)")
            #expect(read(kit.root + "/apps/Sesame.app/Contents/MacOS/Sesame") == brokenGate, "apps/Sesame.app is not the copy's app")
            #expect(!exists(kit.root + "/apps/Sesame.app/Contents/MacOS/Old"), "apps/Sesame.app still holds a file of the app it replaced")
            let marker = read(kit.root + "/break/selfrun-app")
            #expect(lines(marker) == [kit.root + "/break/Sesame.app"], "the marker is not one line holding the app's path: \(marker)")
            #expect(sourceDigest(kit) == before, "the source changed (its dist and .build must stay as they were)")
        }
    }

    @Test("after restore, a second build keeps the restored app and the copy's .build survives the restore")
    func buildAfterRestore() throws {
        try withKit { kit in
            try selfrun(kit, "copy-project")
            try selfrun(kit, "break", "write-picked")
            try selfrun(kit, "build")
            try selfrun(kit, "restore")
            #expect(exists(kit.copy + "/.build/release/obj"), "restore removed the copy's .build: every build would start from nothing")
            #expect(exists(kit.copy + "/dist/Sesame.app"), "restore removed the copy's dist")
            let ran = try selfrun(kit, "build")
            #expect(ran.status == 0, "the second build exited \(ran.status): \(ran.output)")
            let good = read(kit.gateInSource)
            #expect(read(kit.root + "/break/Sesame.app/Contents/MacOS/Sesame") == good, "break/Sesame.app is not the restored app")
            #expect(read(kit.root + "/apps/Sesame.app/Contents/MacOS/Sesame") == good, "apps/Sesame.app is not the restored app")
            #expect(exists(kit.root + "/break/selfrun-app"), "the marker is gone after the second build")
        }
    }

    @Test("a failed build is exit 1, writes no marker and leaves apps/Sesame.app as it was")
    func failedBuild() throws {
        try withKit { kit in
            try selfrun(kit, "copy-project")
            try write("the app of the last run\n", to: kit.root + "/apps/Sesame.app/Contents/MacOS/Sesame")
            let ran = try selfrun(kit, "build", env: ["FAKE_SWIFT_FAIL": "1"])
            #expect(ran.status == 1, "a failed swift build exited \(ran.status), wanted 1: \(ran.output)")
            #expect(!exists(kit.root + "/break/selfrun-app"), "a marker was written for a failed build")
            #expect(!exists(kit.root + "/break/Sesame.app"), "an app was kept for a failed build")
            #expect(read(kit.root + "/apps/Sesame.app/Contents/MacOS/Sesame") == "the app of the last run\n", "apps/Sesame.app was replaced by a failed build")
        }
    }

    // MARK: clean

    @Test("clean removes break/ with the marker and the kept app, and nothing else under KIT_ROOT")
    func cleanRemovesBreak() throws {
        try withKit { kit in
            let before = sourceDigest(kit)
            try selfrun(kit, "copy-project")
            try selfrun(kit, "break", "key-names")
            try selfrun(kit, "build")
            try write("other\n", to: kit.root + "/run/keep-me.txt")
            try write("other\n", to: kit.root + "/fixtures/keep-me.txt")
            let apps = digest(kit.root + "/apps")
            let ran = try selfrun(kit, "clean")
            #expect(ran.status == 0, "clean exited \(ran.status): \(ran.output)")
            #expect(!exists(kit.root + "/break"), "break/ is still there")
            #expect(!exists(kit.root + "/break/selfrun-app"), "the marker is still there")
            #expect(exists(kit.root + "/run/keep-me.txt") && exists(kit.root + "/fixtures/keep-me.txt"), "clean removed something outside break/")
            #expect(digest(kit.root + "/apps") == apps, "clean touched apps/")
            #expect(sourceDigest(kit) == before, "the source changed")
        }
    }

    @Test("clean with nothing to clean is exit 0")
    func cleanNothing() throws {
        try withKit { kit in
            let ran = try selfrun(kit, "clean")
            #expect(ran.status == 0, "clean with no break/ exited \(ran.status): \(ran.output)")
        }
    }

    // MARK: the whole sequence of verify.md self-run 2 and 3, source untouched

    @Test("the whole sequence: copy, break, build, restore, build, clean never changes the source")
    func wholeSequence() throws {
        try withKit { kit in
            let before = sourceDigest(kit)
            for step in [["copy-project"], ["break", "key-names"], ["build"], ["restore"], ["build"],
                         ["break", "write-picked"], ["build"], ["restore"], ["build"], ["clean"]] {
                let ran = try selfrunArgs(kit, step)
                #expect(ran.status == 0, "kit-selfrun.sh \(step) exited \(ran.status): \(ran.output)")
                #expect(sourceDigest(kit) == before, "the source changed after \(step)")
            }
            #expect(!exists(kit.root + "/break"), "break/ is left after clean")
        }
    }

    // MARK: kit-reset.sh --bundle-only (the reset that keeps the self-run app)

    private func resetPath() -> String? { scriptPath("kit-reset.sh") }

    private func withBreakApp<T>(_ body: (_ root: String, _ marker: String) throws -> T, marker: Bool = true, app: Bool = true) throws -> T {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kitselfrun-reset-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.resolvingSymlinksInPath().path + "/sesame-kit"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        if app {
            try write("SELFRUN-APP\n", to: root + "/break/Sesame.app/Contents/MacOS/Sesame")
            try write("SELFRUN-ONLY\n", to: root + "/break/Sesame.app/Contents/Resources/SELFRUN-ONLY.txt")
        }
        if marker {
            try write(root + "/break/Sesame.app\n", to: root + "/break/selfrun-app")
        }
        return try body(root, root + "/break/selfrun-app")
    }

    @Test("--bundle-only --id kit with the marker copies break/Sesame.app to apps/ and says so; the marker stays")
    func bundleOnlyKeepsSelfrunApp() throws {
        guard let path = resetPath() else { return }
        try withBreakApp { root, marker in
            let ran = try run(path, ["--bundle-only", "--id", "kit"], env: ["KIT_ROOT": root])
            #expect(ran.status == 0, "exited \(ran.status): \(ran.output)")
            #expect(ran.output.contains("bundle copied from the self-run copy"), "no `bundle copied from the self-run copy` line: \(ran.output)")
            #expect(read(root + "/apps/Sesame.app/Contents/MacOS/Sesame") == "SELFRUN-APP\n", "apps/Sesame.app is not the self-run app")
            #expect(read(root + "/apps/Sesame.app/Contents/Resources/SELFRUN-ONLY.txt") == "SELFRUN-ONLY\n", "a nested file of the self-run app was not copied")
            #expect(exists(marker), "the marker was removed: every reset of the block runs under id kit and must keep the app")
            #expect(exists(root + "/break/Sesame.app/Contents/MacOS/Sesame"), "break/Sesame.app was moved instead of copied")
        }
    }

    @Test("--bundle-only runs only the bundle step: nothing but apps/ and break/ exists under KIT_ROOT afterwards")
    func bundleOnlyRunsOnlyTheBundleStep() throws {
        guard let path = resetPath() else { return }
        try withBreakApp { root, _ in
            let ran = try run(path, ["--bundle-only", "--id", "kit"], env: ["KIT_ROOT": root])
            #expect(ran.status == 0, "exited \(ran.status): \(ran.output)")
            let top = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
            #expect(top == ["apps", "break"], "KIT_ROOT holds \(top): the other steps of a reset must not run")
        }
    }

    @Test("--bundle-only with the marker and a missing break/Sesame.app is exit 1 `self-run app missing`, and apps/ gets no app")
    func bundleOnlyMissingApp() throws {
        guard let path = resetPath() else { return }
        try withBreakApp({ root, _ in
            let ran = try run(path, ["--bundle-only", "--id", "kit"], env: ["KIT_ROOT": root])
            #expect(ran.status == 1, "exited \(ran.status), wanted 1: \(ran.output)")
            #expect(ran.output.contains("self-run app missing"), "no `self-run app missing` line: \(ran.output)")
            #expect(!exists(root + "/apps/Sesame.app"), "an app was put in apps/ although the self-run app is missing")
        }, app: false)
    }

    @Test("--bundle-only with the marker and another id removes the marker, says so and does not use the self-run app", arguments: ["S1", "S8"])
    func bundleOnlyStaleMarker(_ id: String) throws {
        guard let path = resetPath() else { return }
        try withBreakApp { root, marker in
            let ran = try run(path, ["--bundle-only", "--id", id], env: ["KIT_ROOT": root])
            #expect(ran.status == 0, "exited \(ran.status): \(ran.output)")
            #expect(ran.output.contains("note: stale self-run marker removed, the project bundle is used"), "no stale-marker note: \(ran.output)")
            #expect(!exists(marker), "the stale marker is still there: a later block would run the broken app")
            #expect(!exists(root + "/apps/Sesame.app/Contents/Resources/SELFRUN-ONLY.txt"), "the self-run app was used for id \(id)")
            #expect(ran.output.contains("bundle copied to ") || ran.output.contains("no bundle yet"), "the project bundle step did not run after the note: \(ran.output)")
        }
    }

    @Test("--bundle-only needs an id of S1 to S9 or kit and stands alone: anything else is usage, exit 2, and writes nothing (plan-7-t10 amended: S9 is an id now, S11 stands in for the unknown id)", arguments: [
        ["--bundle-only"], ["--bundle-only", "--id", "S11"], ["--bundle-only", "--id", ""], ["--bundle-only", "--cleanup"],
        ["--bundle-only", "--id", "kit", "--cleanup"], ["--bundle-only", "--id"],
    ])
    func bundleOnlyUsage(_ args: [String]) throws {
        guard let path = resetPath() else { return }
        try withBreakApp { root, marker in
            let ran = try run(path, args, env: ["KIT_ROOT": root])
            #expect(ran.status == 2, "kit-reset.sh \(args) exited \(ran.status), wanted 2: \(ran.output)")
            #expect(exists(marker), "the marker was touched by a usage error")
            #expect(!exists(root + "/apps"), "apps/ was made by a usage error")
        }
    }

    @Test("the usage of kit-reset.sh names --bundle-only")
    func resetUsageNamesBundleOnly() throws {
        guard let path = resetPath() else { return }
        try withBreakApp({ root, _ in
            let ran = try run(path, [], env: ["KIT_ROOT": root])
            #expect(ran.status == 2, "no arguments exited \(ran.status), wanted 2: \(ran.output)")
            #expect(ran.output.contains("--bundle-only"), "the usage does not name --bundle-only: \(ran.output)")
        }, marker: false, app: false)
    }

    @Test("the bundle step is a function reset_bundle called by do_reset; without the marker it is the plan 1 step (dist/Sesame.app)")
    func resetBundleText() throws {
        guard let code = scriptCode("kit-reset.sh") else { return }
        let functionStart = code.range(of: "reset_bundle()")
        ok(functionStart != nil, "kit-reset.sh has no function `reset_bundle`")
        guard let start = functionStart else { return }
        let rest = String(code[start.upperBound...])
        let body = String(rest.prefix(upTo: rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex))
        for phrase in ["selfrun-app", "bundle copied from the self-run copy", "self-run app missing",
                       "note: stale self-run marker removed, the project bundle is used",
                       "$KIT_PROJECT/dist/Sesame.app", "bundle copied to", "no bundle yet (dist/Sesame.app is made by scripts/bundle.sh)", "ditto"] {
            ok(body.contains(phrase), "reset_bundle does not hold `\(phrase)`")
        }
        let doReset = code.range(of: "do_reset()").map { String(code[$0.upperBound...]) } ?? ""
        let doResetBody = String(doReset.prefix(upTo: doReset.range(of: "\n}\n")?.lowerBound ?? doReset.endIndex))
        ok(doResetBody.contains("reset_bundle"), "do_reset does not call reset_bundle")
        ok(!doResetBody.contains("ditto"), "do_reset still copies the bundle itself")
        ok(code.contains("--bundle-only"), "the option --bundle-only is not handled")
        // the marker lives under break/, never under apps/ (every reset deletes apps/)
        ok(!body.contains("apps/selfrun-app"), "the marker must not live under apps/")
    }
}
