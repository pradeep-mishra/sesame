import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import SesameEngine

// plan-3-t17, tester step: `GitFiles.list(repo:git:)` asks git which files of a repo may be read, and fails closed (nil) when
// git cannot answer. Written from the t17 entry of plan-3-tasks.md (Tests, Expected), design section 8 and the spec only; no
// product source is read.
//
// Names, and how they were found:
//   - `GitFiles.list(repo:git:)`, returning `Set<String>?` of repo-relative paths: the entry fixes the name, the two argument
//     labels and the result ("returns ... as a set, or nil when git cannot answer"). It does not exist yet.
//   - The types are my reading of the entry: `repo` is the repo folder path and `git` is the path of the git program, both
//     `String`. If the product takes another type, that is a spelling fix and not a change of what the tests check.
//   - No default for `git:` is assumed: every call here names the system git (`/usr/bin/git`) or a stub.
//
// Every repo is built by the test with the real `git` under $TMPDIR, with a temp HOME and no system or user config for the
// builder, and removed again. Every expected set is written by hand below. Where a test says git would run planted code, a
// control first runs plain git (no flags) on the same repo and shows the planted script really runs, so a missing marker means
// the product kept it from running and not that the plant never worked (the pager test has no control: see it). The tests that change the environment of the test
// process (HOME, GIT_*) are serialized, restore it, and rely on the whole suite running with `--no-parallel` (the Conventions).

private let realGit = "/usr/bin/git"

// MARK: running processes

private struct Ran {
    let status: Int32
    let output: Data
}

/// Runs a program; `environment` nil means the environment of this test process as it is now.
private func run(_ exe: String, _ args: [String], cwd: String? = nil, environment: [String: String]? = nil) throws -> Ran {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let environment { process.environment = environment }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Ran(status: process.terminationStatus, output: data)
}

/// The names of a `-z` listing.
private func names(_ data: Data) -> Set<String> {
    Set(data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) })
}

/// A scrubbed environment for the repos the test builds: no GIT_* variable, a temp HOME, no system or user config.
private func builderEnvironment(home: String) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["HOME"] = home
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    return environment
}

// MARK: the temp tree

private final class GitTree {
    let root: String
    let home: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-gitfiles-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath().path
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func write(_ relative: String, _ text: String = "x", executable: Bool = false) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
        if executable { chmod(full, 0o755) }
        return full
    }

    /// A real repo (`git init`) at `relative`.
    @discardableResult
    func repo(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        try git(relative, ["init", "-q", "-b", "main"])
        return full
    }

    @discardableResult
    func git(_ repoRelative: String, _ args: [String]) throws -> String {
        let ran = try run(realGit, ["-C", path(repoRelative)] + args, environment: builderEnvironment(home: home))
        try #require(ran.status == 0, "setup: git \(args.joined(separator: " ")) in \(repoRelative) exited \(ran.status)")
        return String(decoding: ran.output, as: UTF8.self)
    }

    func commit(_ repoRelative: String) throws {
        try git(repoRelative, ["-c", "user.name=tester", "-c", "user.email=tester@example.invalid",
                               "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one"])
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

private func withTree(_ body: (GitTree) throws -> Void) throws {
    let tree = try GitTree()
    defer { tree.remove() }
    try body(tree)
}

/// Sets and clears variables of this test process for the length of the body, then puts them back.
private func withProcessEnvironment(set values: [String: String], clearing cleared: [String] = [],
                                    _ body: () throws -> Void) rethrows {
    // An array of pairs, not a dictionary: assigning nil to a dictionary entry removes it, so an unset variable would never be
    // remembered as unset and would stay planted after the body.
    var before: [(key: String, old: String?)] = []
    for key in Array(values.keys) + cleared {
        let old: String? = getenv(key).map { String(cString: $0) }
        before.append((key, old))
    }
    for (key, value) in values { setenv(key, value, 1) }
    for key in cleared { unsetenv(key) }
    defer {
        for (key, old) in before.reversed() {
            if let old { setenv(key, old, 1) } else { unsetenv(key) }
        }
    }
    try body()
}

/// What plain git (no flags of ours) says for the same listing, in the environment of this process right now.
private func plainList(_ repo: String, extra: [String] = []) throws -> Set<String>? {
    let ran = try run(realGit, extra + ["-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
    return ran.status == 0 ? names(ran.output) : nil
}

/// A script that records that it ran by creating a file; `silent` scripts print nothing else.
private func markerScript(_ tree: GitTree, name: String, output: String = "") throws -> (script: String, marker: String) {
    let marker = tree.path("markers/" + name)
    try FileManager.default.createDirectory(atPath: tree.path("markers"), withIntermediateDirectories: true)
    let script = try tree.write("scripts/" + name + ".sh", "#!/bin/sh\ntouch \"\(marker)\"\n\(output)", executable: true)
    return (script, marker)
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

// MARK: the bundled helper alone (SESAME_FAKE_EMBEDDER=1), for the last test
//
// `PipeRig` (PipeRig.swift) starts the bundled release helper the way the app does, with a temp HOME and the fake embedder in
// the child's own environment; no app and no window. The `files` table is read with this file's own read-only connection.

/// `realpath`, so `/var/...` and `/private/var/...` are one place; a path that cannot be resolved stays as it is.
private func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
}

private func jsonString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

/// A small real photo with pixels of its own (a different seed gives different bytes).
private func photoBytes(seed: Int, type: String) -> Data {
    let side = 64
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    var state = UInt64(truncatingIfNeeded: seed) &* 2_654_435_761 &+ 12_345
    for index in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        pixels[index] = UInt8(truncatingIfNeeded: state >> 33)
        pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 41)
        pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 49)
        pixels[index + 3] = 255
    }
    let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
    let data = NSMutableData()
    if let image, let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return data as Data
}

/// Every `files` row as (path, status), or nil while the index cannot be read.
private func indexRows(_ indexFile: String) -> [(path: String, status: String)]? {
    var db: OpaquePointer?
    guard FileManager.default.fileExists(atPath: indexFile),
          sqlite3_open_v2(indexFile, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close_v2(db)
        return nil
    }
    defer { sqlite3_close_v2(db) }
    sqlite3_busy_timeout(db, 2000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "select path, status from files", -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    var out: [(path: String, status: String)] = []
    while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else { return nil }
        guard let path = sqlite3_column_text(statement, 0), let status = sqlite3_column_text(statement, 1) else { continue }
        out.append((String(cString: path), String(cString: status)))
    }
    return out
}

// MARK: a call that may never return (plan-3 fix round, t17-4)
//
// `GitFiles.list` on a repo whose `.gitignore` is a FIFO makes `git ls-files` block for ever. The call runs on a background thread
// and the test waits at most 120 s for it; after that the test fails and kills the git it started, so the suite never hangs.

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}

private struct Guarded<T> {
    let value: T?
    let timedOut: Bool
    let seconds: TimeInterval
}

private func runGuarded<T>(limit: TimeInterval = 120, _ work: @escaping @Sendable () -> T) -> Guarded<T> {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    let started = Date()
    let thread = Thread {
        box.set(work())
        done.signal()
    }
    thread.start()
    let timedOut = done.wait(timeout: .now() + limit) == .timedOut
    return Guarded(value: box.value, timedOut: timedOut, seconds: Date().timeIntervalSince(started))
}

/// Process ids `pgrep` prints for these arguments (none when nothing matches).
private func pgrepIds(_ args: [String]) -> [Int32] {
    guard let ran = try? run("/usr/bin/pgrep", args) else { return [] }
    return String(decoding: ran.output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
}

/// Kills every git this test may have started: a direct child of this process running `ls-files`, and any process whose
/// command line names this test's own temp folder (a UUID name, so nothing else matches). Returns how many it killed.
@discardableResult
private func killGitLeftovers(tempFolderName: String) -> Int {
    var ids = Set(pgrepIds(["-P", String(getpid()), "-f", "ls-files"]))
    ids.formUnion(pgrepIds(["-f", tempFolderName]))
    ids.remove(getpid())
    for id in ids { kill(id, SIGKILL) }
    return ids.count
}

@Suite("GitFilesTests", .serialized)
struct GitFilesTests {

    // MARK: what is listed

    @Test func listsExactlyTheTrackedAndTheUntrackedNotIgnoredFiles() throws {
        try withTree { tree in
            try tree.repo("repo")
            try tree.write("repo/.gitignore", "ignored.png\nbuild-out/\n*.log\nforced.png\n")
            try tree.write("repo/tracked.png")
            try tree.write("repo/src/tracked.swift")
            try tree.write("repo/forced.png")
            try tree.git("repo", ["add", ".gitignore", "tracked.png", "src/tracked.swift"])
            try tree.git("repo", ["add", "-f", "forced.png"])
            try tree.commit("repo")
            // after the commit: untracked and not ignored, then ignored by a file rule and by a folder rule
            try tree.write("repo/untracked.png")
            try tree.write("repo/src/untracked.txt")
            try tree.write("repo/notes/new.md")
            try tree.write("repo/ignored.png")
            try tree.write("repo/src/ignored.png")
            try tree.write("repo/build-out/x.png")
            try tree.write("repo/build-out/deep/y.png")
            try tree.write("repo/run.log")
            try tree.write("repo/src/run.log")

            let got = GitFiles.list(repo: tree.path("repo"), git: realGit)
            // forced.png is ignored by the .gitignore but tracked, and tracked files are listed
            let want: Set<String> = [".gitignore", "tracked.png", "src/tracked.swift", "forced.png",
                                     "untracked.png", "src/untracked.txt", "notes/new.md"]
            #expect(got == want, "got \(got?.sorted() ?? ["nil"]), want \(want.sorted())")
        }
    }

    @Test func namesWithSpacesANewlineAndNonAsciiLettersComeBackExact() throws {
        try withTree { tree in
            try tree.repo("repo")
            let odd = [
                "with space.png",
                "line\nbreak.png",
                "caf\u{00E9} \u{00F1} \u{5199}\u{771F}.png",
                "tab\there.png",
                "quote\"s.png",
                "back\\slash.png",
                "dir with space/inner file.png",
                "\u{00FC}ber/\u{00DF}.png",
            ]
            for name in odd { try tree.write("repo/" + name) }
            let got = GitFiles.list(repo: tree.path("repo"), git: realGit)
            #expect(got == Set(odd), "got \(got?.sorted() ?? ["nil"]), want \(odd.sorted())")
        }
    }

    // MARK: a planted repo cannot run code

    @Test func aRepoWhoseConfigSetsFsmonitorRunsNothing() throws {
        try withTree { tree in
            try tree.repo("repo")
            try tree.write("repo/a.png")
            try tree.write("repo/b.txt")
            let plant = try markerScript(tree, name: "fsmonitor", output: "printf '\\0'\n")
            try tree.git("repo", ["config", "core.fsmonitor", plant.script])

            // control: plain git, on this repo, runs the script
            _ = try plainList(tree.path("repo"))
            try #require(exists(plant.marker), "setup: plain git did not run the fsmonitor script, so this test cannot show anything")
            try FileManager.default.removeItem(atPath: plant.marker)

            let got = GitFiles.list(repo: tree.path("repo"), git: realGit)
            #expect(!exists(plant.marker), "the repo's core.fsmonitor script ran")
            #expect(got == ["a.png", "b.txt"], "git still answers: got \(got?.sorted() ?? ["nil"])")
        }
    }

    @Test func aRepoWhoseConfigSetsAPagerRunsNothing() throws {
        try withTree { tree in
            try tree.repo("repo")
            try tree.write("repo/a.png")
            let plant = try markerScript(tree, name: "pager", output: "cat\n")
            try tree.git("repo", ["config", "core.pager", plant.script])

            // No control here: git pages only for a terminal, and `ls-files` with its output on a pipe never runs a pager even
            // with `--paginate` (measured), so this test is a guard that the entry asks for, not a proof of its own.
            let got = GitFiles.list(repo: tree.path("repo"), git: realGit)
            #expect(!exists(plant.marker), "the repo's core.pager script ran")
            #expect(got == ["a.png"], "git still answers: got \(got?.sorted() ?? ["nil"])")
        }
    }

    @Test func aHooksPathFolderAndTheRepoOwnHooksRunNothing() throws {
        try withTree { tree in
            let hookNames = ["post-index-change", "fsmonitor-watchman", "pre-commit", "post-checkout", "reference-transaction"]
            var markers: [String] = []
            for name in hookNames {
                let marker = tree.path("markers/hook-" + name)
                markers.append(marker)
                try tree.write("hooks/" + name, "#!/bin/sh\ntouch \"\(marker)\"\n", executable: true)
            }
            let ownMarker = tree.path("markers/own-hook")
            markers.append(ownMarker)
            try FileManager.default.createDirectory(atPath: tree.path("markers"), withIntermediateDirectories: true)

            // control repo: the same plant, and a `git add` (git writes the index, so post-index-change runs)
            try tree.repo("control")
            try tree.write("control/a.png")
            try tree.git("control", ["config", "core.hooksPath", tree.path("hooks")])
            try tree.git("control", ["add", "a.png"])
            try #require(exists(tree.path("markers/hook-post-index-change")),
                         "setup: git did not run the hook of core.hooksPath on `git add`, so this test cannot show anything")
            for marker in markers { try? FileManager.default.removeItem(atPath: marker) }

            try tree.repo("repo")
            try tree.write("repo/a.png")
            try tree.write("repo/b.png")
            try tree.git("repo", ["config", "core.hooksPath", tree.path("hooks")])
            try tree.write("repo/.git/hooks/post-index-change", "#!/bin/sh\ntouch \"\(ownMarker)\"\n", executable: true)

            let got = GitFiles.list(repo: tree.path("repo"), git: realGit)
            for marker in markers {
                #expect(!exists(marker), "a hook ran: \((marker as NSString).lastPathComponent)")
            }
            #expect(got == ["a.png", "b.png"], "git still answers: got \(got?.sorted() ?? ["nil"])")
        }
    }

    @Test func aUserGitconfigThatHidesPngFilesAndRunsAScriptChangesNothing() throws {
        try withTree { tree in
            try tree.repo("repo")
            try tree.write("repo/a.png")
            try tree.write("repo/b.png")
            try tree.write("repo/c.txt")
            try tree.write("userhome/hide-png", "*.png\n")
            try tree.write("userhome/.config/git/ignore", "*.png\n")
            let plant = try markerScript(tree, name: "user-fsmonitor", output: "printf '\\0'\n")
            try tree.write("userhome/.gitconfig",
                           "[core]\n\texcludesFile = \(tree.path("userhome/hide-png"))\n\tfsmonitor = \(plant.script)\n")

            try withProcessEnvironment(set: ["HOME": tree.path("userhome")],
                                       clearing: ["XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"]) {
                // control: plain git, with this HOME, hides the pictures and runs the script
                let plain = try plainList(tree.path("repo"))
                try #require(plain == ["c.txt"], "setup: plain git with this HOME should hide the pictures, got \(plain?.sorted() ?? ["nil"])")
                try #require(exists(plant.marker), "setup: plain git did not run the user's fsmonitor script")
                try FileManager.default.removeItem(atPath: plant.marker)

                let got = GitFiles.list(repo: tree.path("repo"), git: realGit)
                #expect(got == ["a.png", "b.png", "c.txt"], "the user's config must not matter: got \(got?.sorted() ?? ["nil"])")
                #expect(!exists(plant.marker), "the user's core.fsmonitor script ran")
            }
        }
    }

    @Test func gitDirWorkTreeAndConfigVariablesInTheCallingProcessChangeNothing() throws {
        try withTree { tree in
            try tree.repo("repo")
            try tree.write("repo/a.png")
            try tree.write("repo/b.png")
            try tree.write("repo/c.txt")
            try tree.repo("decoy")
            try tree.write("decoy/decoy-only.png")
            try tree.write("env/hide-png", "*.png\n")
            try tree.write("env/global", "[core]\n\texcludesFile = \(tree.path("env/hide-png"))\n")
            let countPlant = try markerScript(tree, name: "env-count", output: "printf '\\0'\n")
            let paramPlant = try markerScript(tree, name: "env-parameters", output: "printf '\\0'\n")
            let environment = [
                "GIT_DIR": tree.path("decoy/.git"),
                "GIT_WORK_TREE": tree.path("decoy"),
                "GIT_INDEX_FILE": tree.path("decoy/.git/no-such-index"),
                "GIT_CONFIG_COUNT": "2",
                "GIT_CONFIG_KEY_0": "core.excludesFile",
                "GIT_CONFIG_VALUE_0": tree.path("env/hide-png"),
                "GIT_CONFIG_KEY_1": "core.fsmonitor",
                "GIT_CONFIG_VALUE_1": countPlant.script,
                "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='\(paramPlant.script)'",
                "GIT_CONFIG_GLOBAL": tree.path("env/global"),
                "GIT_CONFIG_SYSTEM": tree.path("env/global"),
            ]
            try withProcessEnvironment(set: environment) {
                // control: plain git, in this environment, does not give this repo's listing
                let plain = try plainList(tree.path("repo"))
                try #require(plain != ["a.png", "b.png", "c.txt"], "setup: the planted variables change nothing for plain git, so this test cannot show anything")
                for marker in [countPlant.marker, paramPlant.marker] { try? FileManager.default.removeItem(atPath: marker) }

                let got = GitFiles.list(repo: tree.path("repo"), git: realGit)
                #expect(got == ["a.png", "b.png", "c.txt"], "the environment must be scrubbed: got \(got?.sorted() ?? ["nil"])")
                #expect(!exists(countPlant.marker), "a script named by GIT_CONFIG_COUNT/KEY/VALUE ran")
                #expect(!exists(paramPlant.marker), "a script named by GIT_CONFIG_PARAMETERS ran")
            }
        }
    }

    // MARK: through the bundled helper alone

    @Test func theHelperIndexesOnlyThePicturesGitListsInAHandBuiltRepo() throws {
        let executable = KitPaths.bundledHelper
        try #require(FileManager.default.isExecutableFile(atPath: executable.path),
                     "the bundled helper is missing: run `scripts/bundle.sh` (expected \(executable.path))")
        try withTree { tree in
            // the helper's HOME sits beside the picked folder, never inside it
            let support = tree.path("helperhome/Library/Application Support/Sesame")
            try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let jpeg = "public.jpeg"
            var seed = 500
            func photo(_ relative: String, type: String = jpeg) throws {
                seed += 1
                try tree.write("pick/" + relative)
                try photoBytes(seed: seed, type: type).write(to: URL(fileURLWithPath: tree.path("pick/" + relative)))
            }
            try tree.repo("pick/repo")
            try Data("ignored.jpg\nout/\n".utf8).write(to: URL(fileURLWithPath: tree.path("pick/repo/.gitignore")))
            try photo("repo/tracked.jpg")
            try tree.git("pick/repo", ["add", ".gitignore", "tracked.jpg"])
            try tree.commit("pick/repo")
            try photo("repo/fresh.jpg")
            try photo("repo/sub/fresh2.png", type: "public.png")
            try photo("repo/ignored.jpg")
            try photo("repo/sub/ignored.jpg")
            try photo("repo/out/x.jpg")
            try photo("repo/node_modules/n.jpg")
            try photo("loose/a.jpg")
            try photo("loose/node_modules/n.jpg")

            let rig = try PipeRig(helper: executable, home: URL(fileURLWithPath: tree.path("helperhome")), models: nil,
                                  scratch: URL(fileURLWithPath: tree.root))
            defer { rig.cleanup() }
            rig.send("{\"cmd\":\"folders\",\"folders\":[{\"path\":\(jsonString(tree.path("pick"))),\"code\":false}]}")

            // settle: rows exist, none pending, and the rows unchanged for 4 s (300 s of slack, never a tight bound)
            let indexFile = support + "/index.sqlite"
            let started = Date()
            var lastChange = Date()
            var lastKey = ""
            var rows: [(path: String, status: String)] = []
            var settled = false
            while Date().timeIntervalSince(started) < 300 {
                if let now = indexRows(indexFile) {
                    rows = now
                    let key = now.map { "\($0.path)|\($0.status)" }.sorted().joined(separator: "\n")
                    if key != lastKey { lastKey = key; lastChange = Date() }
                    if !now.isEmpty, !now.contains(where: { $0.status == "pending" }),
                       Date().timeIntervalSince(lastChange) >= 4 {
                        settled = true
                        break
                    }
                }
                if !rig.isRunning {
                    Thread.sleep(forTimeInterval: 0.2)
                    if !rig.isRunning { break }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            #expect(settled, "no settled index; rows \(rows.count); helper stderr: \(rig.stderrText.suffix(400))")

            let want = Set(["pick/repo/tracked.jpg", "pick/repo/fresh.jpg", "pick/repo/sub/fresh2.png",
                            "pick/loose/a.jpg", "pick/loose/node_modules/n.jpg"].map { resolved(tree.path($0)) })
            let got = Set(rows.map { resolved($0.path) })
            #expect(got == want, "rows for \(got.map { String($0.dropFirst(resolved(tree.path("pick")).count + 1)) }.sorted()); want \(want.map { String($0.dropFirst(resolved(tree.path("pick")).count + 1)) }.sorted())")
            #expect(rows.count == want.count, "\(rows.count) rows for \(want.count) listed pictures")
            #expect(rows.allSatisfy { $0.status == "done" }, "statuses: \(rows.map { $0.status })")
        }
    }

    // MARK: git cannot answer, so nil

    @Test func anEmptyDotGitFolderGivesNil() throws {
        try withTree { tree in
            try tree.write("fake/a.png")
            try FileManager.default.createDirectory(atPath: tree.path("fake/.git"), withIntermediateDirectories: true)
            #expect(GitFiles.list(repo: tree.path("fake"), git: realGit) == nil)
        }
    }

    @Test func aGitPathThatDoesNotExistGivesNilWhereTheRealGitAnswers() throws {
        try withTree { tree in
            try tree.repo("repo")
            try tree.write("repo/a.png")
            #expect(GitFiles.list(repo: tree.path("repo"), git: realGit) == ["a.png"], "control: the real git answers for this repo")
            #expect(GitFiles.list(repo: tree.path("repo"), git: tree.path("no-such-folder/git")) == nil)
        }
    }

    @Test func aGitThatExitsOneGivesNilEvenAfterPrintingNamesAndAGitThatExitsZeroIsParsed() throws {
        try withTree { tree in
            try tree.repo("repo")
            try tree.write("repo/a.png")
            let failing = try tree.write("stubs/git-fails", "#!/bin/sh\nprintf 'a.png\\0'\nexit 1\n", executable: true)
            let working = try tree.write("stubs/git-works", "#!/bin/sh\nprintf 'a.png\\0dir/b c.png\\0'\nexit 0\n", executable: true)
            // control: the same kind of stub, exiting 0, is run and its NUL-separated names are the answer
            let control = GitFiles.list(repo: tree.path("repo"), git: working)
            #expect(control == ["a.png", "dir/b c.png"], "control: a stub git that exits 0 is the answer, got \(control?.sorted() ?? ["nil"])")
            #expect(GitFiles.list(repo: tree.path("repo"), git: failing) == nil, "a git that exits 1 is no answer, not a partial one")
        }
    }

    // MARK: git that never answers, so nil within a bound

    @Test func aRepoWhoseGitignoreIsAFifoGivesNilWithinABoundedTime() throws {
        try withTree { tree in
            try tree.repo("repo")
            try tree.write("repo/a.png")
            let repo = tree.path("repo")
            // control: the same repo with a plain `.gitignore` is answered, so a hang below is the FIFO and not the setup
            try tree.write("repo/.gitignore", "ignored.png\n")
            let control = GitFiles.list(repo: repo, git: realGit)
            try #require(control == ["a.png", ".gitignore"], "setup: the control repo should be answered, got \(control?.sorted() ?? ["nil"])")

            let fifo = tree.path("repo/.gitignore")
            try FileManager.default.removeItem(atPath: fifo)
            try #require(mkfifo(fifo, 0o600) == 0, "setup: could not make the FIFO .gitignore")
            let folderName = (tree.root as NSString).lastPathComponent
            defer {
                unlink(fifo)
                killGitLeftovers(tempFolderName: folderName)
            }

            let guarded = runGuarded { GitFiles.list(repo: repo, git: realGit) }
            if guarded.timedOut {
                let killed = killGitLeftovers(tempFolderName: folderName)
                Issue.record("GitFiles.list had not returned after 120 s on a repo whose .gitignore is a FIFO (killed \(killed) git process(es) to clean up)")
                return
            }
            #expect(guarded.seconds <= 90, "it returned after \(Int(guarded.seconds)) s, more than the 90 s allowed")
            #expect(guarded.value! == nil, "a git that cannot read the repo's rules is no answer: got \(guarded.value!?.sorted() ?? ["nil"])")
        }
    }
}
