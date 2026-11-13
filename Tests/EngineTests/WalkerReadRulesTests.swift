import Foundation
import Testing
import SesameEngine

// plan-3-t16, tester step: the walk in read mode uses the rules (`Rules.admit(path:picks:)`), so a file under an excluded
// place is never returned, a file without a reader is never returned, and a cloud-only file is set aside. Written from the
// t16 entry of plan-3-tasks.md (Tests, Decisions D4 to D7), the spec and the design only; no product source is read.
//
// Names, and how they were found:
//   - `Walker.scan(root:mode:flags:)`, `WalkResult.files` (`WalkedFile.path`), `WalkResult.unreadable`, `Walker.Mode`
//     (`.read`, `.count`): the sealed WalkerScanTests.
//   - `HelperFolder(path:code:)` and `Rules.admit(path:picks:)` (`Admitted.kind`): the sealed RulesPlaceTests (task 15, built).
//   - `WalkResult.dataless`: the entry names "`dataless`, not in `files`".
//   - `Walker.scan(root:mode:picks:flags:)` and `Walker.readerKinds`: the two names the entry fixes and that do not exist yet.
//
// Every tree is built by the test under $TMPDIR (a folder named `.git` is the repo marker; the t16 tests run no `git`: they pass
// `repoFiles` a hand-written list, since an empty `.git` is not a repo git can answer for) and removed again. Every expected list is written by hand below. A control (a plain photo, or the same name in a plain place) sits in
// each tree, so an absence is always the place or the kind and never the walk or the pick.

// plan-3-t17, tester step (added to this file): read mode asks git, once per repo, which files of a repo may be read, and a
// repo git cannot answer for is skipped and listed as unreadable. Written from the t17 entry of plan-3-tasks.md only; no
// product source is read. Names, and how they were found:
//   - `GitFiles.list(repo:git:)` returns `Set<String>?` of repo-relative paths: fixed by the entry; it does not exist yet.
//   - `Walker.scan(root:mode:picks:flags:repoFiles:)`: fixed by the entry (the Conventions spell the order). `repoFiles` is the
//     listing function of one repo: it takes the repo folder path (`String`) and returns `Set<String>?`, the repo-relative
//     paths or nil, so `GitFiles.list` fits it; its default is `GitFiles.list` (the entry), so the tests that leave it out use
//     the real thing. The tests that pass it wrap `GitFiles.list(repo:git:)` on the system git (`/usr/bin/git`) in a closure.
// The repos here are real (`git init`, files added and committed with the real git, a scrubbed environment), under $TMPDIR.

// plan-4-t4, tester step (amended in this file): PDFs now have a reader, so `Walker.readerKinds` is `["photo", "pdf"]` and read mode
// returns a PDF the rules admit (the entry of plan-4-tasks.md, "Sealed tests this changes"). Reason for every change below: the
// walk used to return photos only because no other kind had a reader; the rules (`Rules.admit`) are not changed, so a PDF is
// returned exactly where the rules admit it: in a plain place whatever the tick, in a repo only when a holding pick is ticked.
// Nothing about photos, places, key names, links, cloud-only files, git or count mode is weakened: every photo expectation is as
// before, and the other non-photo kinds (txt, wav, mp4, py) are still never returned (documents arrive in plan-4-t6).
//
// The new hand-written PDF expectations, for the mixed tree below:
//   `docs/paper.pdf`        plain place: returned for an unticked and a ticked pick
//   `repo/sub/paper.pdf`    in the repo marker folder `repo`: returned only when a holding pick is ticked
//   `repo/paper.pdf` (real repo tree of the git tests): returned only for the ticked pick of that repo

// plan-4-t6, tester step (amended in this file): documents (txt, md, rtf, docx, html, odt) now have a reader, so `Walker.readerKinds`
// holds `photo`, `pdf` and `doc`, and read mode returns a document the rules admit, exactly where it returns a PDF: in a plain place
// whatever the tick (`docs/note.txt`), in a repo only when a holding pick is ticked (`repo/note.txt`; the real-repo test's
// `repo/note.txt`, which git lists, likewise). Reason for every change below: the walk used to leave documents out because no reader
// existed; `Rules.admit` is not changed. Nothing about photos, PDFs, places, key names, links, cloud-only files, git or count mode
// is weakened; audio, video and code (`song.wav`, `clip.mp4`, `tool.py`) are still never returned.

// plan-5-t2, tester step (amended in this file): audio (mp3, m4a, wav, aac, flac) now has a reader, so `Walker.readerKinds` holds `photo`,
// `pdf`, `doc` and `audio`, and read mode returns an audio file the rules admit, exactly where it returns a PDF or a document: in a plain
// place whatever the tick (`docs/song.wav`), in a repo only when a holding pick is ticked (the real-repo test's `repo/song.wav`, which
// git lists, likewise). Reason for every change below: the walk used to leave audio out because no reader existed; `Rules.admit` is not
// changed. Nothing about photos, PDFs, documents, places, key names, links, cloud-only files, git or count mode is weakened; video and
// code (`clip.mp4`, `tool.py`) are still never returned (video arrives in plan-5-t3, code in plan 6).

// plan-5-t3, tester step (amended in this file): video (mp4, mov, m4v) now has a reader, so `Walker.readerKinds` holds `photo`, `pdf`,
// `doc`, `audio` and `video`, and read mode returns a video file the rules admit, exactly where it returns audio: in a plain place
// whatever the tick (`docs/clip.mp4`), in a repo only when a holding pick is ticked (the real-repo test's `repo/clip.mp4`, which git
// lists, likewise). Reason for every change below: the walk used to leave video out because no reader existed; `Rules.admit` is not
// changed. Nothing about photos, PDFs, documents, audio, places, key names, links, cloud-only files, git or count mode is weakened; only
// code (`tool.py`) is still never returned (plan 6). The real-repo test gains the file `repo/clip.mp4` (one more control, untracked and
// not ignored) and its ticked list gains it; the unticked list is unchanged.

// plan-6-t2, tester step (amended in this file): code (swift, py, js, ts, tsx, jsx, go, rs, java, kt, c, h, cpp, rb, sh) now has a reader, so
// `Walker.readerKinds` holds `photo`, `pdf`, `doc`, `audio`, `video` and `code`, and read mode returns a code file the rules admit, exactly where
// it returns the other kinds that the tick governs: only under a pick whose code tick is on (the mixed tree's `docs/tool.py` for a ticked root,
// `repo/tool.py` for a ticked root or a ticked repo pick) and still not for an unticked pick. Reason for every change below: the walk used to
// leave code out because no reader existed (the `mixedNoReaderFiles` list); `Rules.admit` is not changed (D1, D2), so a code file is returned
// exactly where the rules admit it. Nothing about photos, PDFs, documents, audio, video, places, key names, links, cloud-only files, git or
// count mode is weakened: every other expectation is as before, and `tool.py` is still absent for an unticked pick.

private let sfDataless: UInt32 = 0x4000_0000

private let realGit = "/usr/bin/git"

/// Records the repos the listing was asked for.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ repo: String) { lock.lock(); all.append(repo); lock.unlock() }
    var repos: [String] { lock.lock(); defer { lock.unlock() }; return all }
    func count(ofRepoNamed name: String) -> Int { repos.filter { ($0 as NSString).lastPathComponent == name }.count }
}

/// The real listing, with every call recorded. `failing` names repo folders (by last path component) git is made to fail for.
private func countingList(_ calls: Calls, failing: Set<String> = []) -> @Sendable (String) -> Set<String>? {
    { repo in
        calls.add(repo)
        if failing.contains((repo as NSString).lastPathComponent) { return nil }
        return GitFiles.list(repo: repo, git: realGit)
    }
}

private final class RTree {
    let root: String
    private var locked: [(path: String, mode: mode_t)] = []

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-walkread-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath().path
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func dir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func file(_ relative: String, bytes: Int = 64) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: full))
    }

    func link(_ relative: String, to target: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: path(target))
    }

    func fifo(_ relative: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try #require(mkfifo(full, 0o600) == 0, "could not make the FIFO \(relative)")
    }

    /// A file with a size and no blocks; false when this volume does not make one.
    func sparse(_ relative: String) throws -> Bool {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let fd = open(full, O_CREAT | O_WRONLY, 0o600)
        try #require(fd >= 0, "could not create the sparse file")
        ftruncate(fd, 1_048_576)
        close(fd)
        var info = stat()
        try #require(stat(full, &info) == 0)
        return info.st_size > 0 && info.st_blocks == 0
    }

    func lock(_ relative: String) {
        let full = path(relative)
        var info = stat()
        guard stat(full, &info) == 0 else { return }
        locked.append((full, info.st_mode & 0o7777))
        chmod(full, 0)
    }

    func remove() {
        for item in locked.reversed() { chmod(item.path, item.mode) }
        try? FileManager.default.removeItem(atPath: root)
    }
}

extension RTree {
    /// A real repo (`git init`) at `relative`.
    func repo(_ relative: String) throws {
        try dir(relative)
        try git(relative, ["init", "-q", "-b", "main"])
    }

    func git(_ repoRelative: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: realGit)
        process.arguments = ["-C", path(repoRelative)] + args
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["HOME"] = "/var/empty"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "setup: git \(args.joined(separator: " ")) in \(repoRelative) exited \(process.terminationStatus)")
    }

    func commit(_ repoRelative: String) throws {
        try git(repoRelative, ["-c", "user.name=tester", "-c", "user.email=tester@example.invalid",
                               "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one"])
    }
}

private func withTree(_ body: (RTree) throws -> Void) throws {
    let tree = try RTree()
    defer { tree.remove() }
    try body(tree)
}

private func canTestPermissions() -> Bool {
    if getuid() == 0 {
        Issue.record("this test runs as root, and root lists through chmod 000: it cannot show anything; run it as the person")
        return false
    }
    return true
}

private func pick(_ path: String, code: Bool = false) -> HelperFolder { HelperFolder(path: path, code: code) }

private func relative(_ paths: [String], under root: String) -> Set<String> {
    Set(paths.map { String($0.dropFirst(root.count + 1)) })
}

private func readNames(_ tree: RTree, picks: [HelperFolder], root: String? = nil,
                       flags: @escaping (String) -> UInt32 = { _ in 0 },
                       repoFiles: @escaping @Sendable (String) -> Set<String>? = { GitFiles.list(repo: $0, git: realGit) }) -> Set<String> {
    let result = Walker.scan(root: root ?? tree.root, mode: .read, picks: picks, flags: flags, repoFiles: repoFiles)
    let paths: [String] = result.files.map { $0.path }
    return relative(paths, under: tree.root)
}

/// The tree of the entry: a plain photo, a hidden folder, Caches, `.app` bundles, `node_modules` and `Pods` inside a repo
/// marker folder and outside one, a link, a FIFO, a key-name picture, and non-photo kinds. No sparse and no dataless file
/// here (their tests have their own trees); `special/evicted.png` is a normal file the flags closure of a test marks.
private func buildMixedTree(_ tree: RTree) throws {
    try tree.file("plain/shot.png")
    try tree.file("plain/deep/snap.heic")
    try tree.file(".hidden/h.png")
    try tree.file("plain/.ssh/s.png")
    try tree.file("Caches/c.png")
    try tree.file("Thing.app/Contents/Resources/icon.png")
    try tree.file("Upper.APP/pic.png")
    try tree.file("loose/node_modules/n.png")
    try tree.file("loose/Pods/p.png")
    try tree.dir("repo/.git")
    try tree.file("repo/shot.png")
    try tree.file("repo/sub/deep.png")
    try tree.file("repo/node_modules/n.png")
    try tree.file("repo/Pods/p.png")
    try tree.link("links/link.png", to: "plain/shot.png")
    try tree.fifo("special/pipe.png")
    try tree.file("special/evicted.png")
    try tree.file("keys/id_rsa.png")
    try tree.file("keys/.env.png")
    try tree.file("keys/ID_RSA.PNG")
    for name in ["docs/note.txt", "docs/paper.pdf", "docs/song.wav", "docs/clip.mp4", "docs/tool.py",
                 "repo/note.txt", "repo/tool.py", "repo/sub/paper.pdf"] {
        try tree.file(name)
    }
}

/// Hand-written: the photos read mode returns for the mixed tree, whatever the code ticks are.
private let mixedExpected: Set<String> = [
    "plain/shot.png", "plain/deep/snap.heic",
    "loose/node_modules/n.png", "loose/Pods/p.png",
    "repo/shot.png", "repo/sub/deep.png",
]

/// Hand-written: what git would list for the mixed tree's fake repo marker `repo` (repo-relative paths, every file in it). The
/// marker folder is not a real repo, so these tests are about the rules and name the list by hand instead of running git.
private let mixedRepoFiles: @Sendable (String) -> Set<String>? = { _ in
    ["shot.png", "sub/deep.png", "node_modules/n.png", "Pods/p.png", "note.txt", "tool.py", "sub/paper.pdf"]
}
private let mixedNonPhotoFiles = [
    "docs/note.txt", "docs/paper.pdf", "docs/song.wav", "docs/clip.mp4",
    "repo/note.txt", "repo/sub/paper.pdf",
]

private let mixedCodeFiles: Set<String> = ["docs/tool.py", "repo/tool.py"]

/// plan-5-t2, hand-written: the audio files read mode returns for the mixed tree whatever the tick (a plain place).
private let mixedAudioAlways: Set<String> = ["docs/song.wav"]

/// plan-5-t3, hand-written: the video files read mode returns for the mixed tree whatever the tick (a plain place).
private let mixedVideoAlways: Set<String> = ["docs/clip.mp4"]

/// plan-4-t4, hand-written: the PDFs read mode returns for the mixed tree whatever the tick.
private let mixedPdfsAlways: Set<String> = ["docs/paper.pdf"]

/// plan-4-t4, hand-written: the PDFs read mode returns for the mixed tree only when a pick holding the repo is ticked.
private let mixedPdfsWhenRepoTicked: Set<String> = ["repo/sub/paper.pdf"]

/// plan-4-t6, hand-written: the documents read mode returns for the mixed tree whatever the tick (a plain place).
private let mixedDocsAlways: Set<String> = ["docs/note.txt"]

/// plan-4-t6, hand-written: the documents read mode returns for the mixed tree only when a pick holding the repo is ticked.
private let mixedDocsWhenRepoTicked: Set<String> = ["repo/note.txt"]

private let documentExtensions: Set<String> = ["txt", "md", "rtf", "docx", "html", "odt"]

private let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac"]

private let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

/// The kind the rules give a returned file, by extension, written by hand: pdf, a document extension, an audio extension, a video
/// extension, a code extension, else a photo.
private func expectedKind(of path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    if ext == "pdf" { return "pdf" }
    if audioExtensions.contains(ext) { return "audio" }
    if videoExtensions.contains(ext) { return "video" }
    return documentExtensions.contains(ext) ? "doc" : "photo"
}

private let mixedAllKinds: Set<String> = mixedExpected.union(mixedPdfsAlways).union(mixedPdfsWhenRepoTicked)
    .union(mixedDocsAlways).union(mixedDocsWhenRepoTicked).union(mixedAudioAlways).union(mixedVideoAlways)

/// plan-4-t6: the pictures of a set of returned paths (the PDFs, the documents and the audio files taken out).
private func picturesOnly(_ names: Set<String>) -> Set<String> {
    names.filter { expectedKind(of: $0) == "photo" }
}

@Suite("WalkerReadRulesTests")
struct WalkerReadRulesTests {

    // MARK: the whole tree

    @Test func readModeReturnsExactlyTheHandWrittenPhotosPdfsDocumentsAudioAndVideoOfTheMixedTree() throws {
        try withTree { tree in
            try buildMixedTree(tree)
            let flags: (String) -> UInt32 = { ($0 as NSString).lastPathComponent == "evicted.png" ? sfDataless : 0 }
            let got = readNames(tree, picks: [pick(tree.root)], flags: flags, repoFiles: mixedRepoFiles)
            #expect(got == mixedAllKinds, "missing \(mixedAllKinds.subtracting(got).sorted()), unexpected \(got.subtracting(mixedAllKinds).sorted())")
            for name in mixedCodeFiles {
                #expect(!got.contains(name), "\(name) is code: it must not be returned")
            }
        }
    }

    @Test func theCodeTickChangesNothingTheWalkReturnsAndNoPickEverReturnsACodeFile() throws {
        try withTree { tree in
            try buildMixedTree(tree)
            let flags: (String) -> UInt32 = { ($0 as NSString).lastPathComponent == "evicted.png" ? sfDataless : 0 }
            let configurations: [(label: String, picks: [HelperFolder])] = [
                ("root not ticked", [pick(tree.root)]),
                ("root ticked", [pick(tree.root, code: true)]),
                ("repo ticked under an unticked root", [pick(tree.root), pick(tree.path("repo"), code: true)]),
                ("both ticked", [pick(tree.root, code: true), pick(tree.path("repo"), code: true)]),
            ]
            for configuration in configurations {
                let got = readNames(tree, picks: configuration.picks, flags: flags, repoFiles: mixedRepoFiles)
                #expect(got == mixedAllKinds,
                        "\(configuration.label): missing \(mixedAllKinds.subtracting(got).sorted()), unexpected \(got.subtracting(mixedAllKinds).sorted())")
                #expect(picturesOnly(got) == mixedExpected, "\(configuration.label): the pictures differ")
            }
        }
    }

    @Test func aRepoReturnsItsPdfAndDocumentWhateverTheTickAndCodeIsNeverReturned() throws {
        try withTree { tree in
            try buildMixedTree(tree)
            for tick in [false, true] {
                let picks = [pick(tree.root, code: tick)]
                for name in mixedNonPhotoFiles {
                    let admitted = Rules.admit(path: tree.path(name), picks: picks)
                    #expect(admitted != nil, "setup: \(name) should be admitted (ticked \(tick))")
                    #expect(admitted?.kind != "photo", "setup: \(name) is not a photo")
                }
                for name in mixedCodeFiles {
                    #expect(Rules.admit(path: tree.path(name), picks: picks) == nil, "\(name) is code: not admitted (ticked \(tick))")
                }
                let flags: (String) -> UInt32 = { ($0 as NSString).lastPathComponent == "evicted.png" ? sfDataless : 0 }
                let got = readNames(tree, picks: picks, flags: flags, repoFiles: mixedRepoFiles)
                for name in mixedPdfsAlways.union(mixedPdfsWhenRepoTicked) {
                    #expect(got.contains(name), "\(name) is a PDF: it must be returned (ticked \(tick))")
                }
                for name in mixedDocsAlways.union(mixedDocsWhenRepoTicked) {
                    #expect(got.contains(name), "\(name) is a document: it must be returned (ticked \(tick))")
                }
                for name in mixedAudioAlways.union(mixedVideoAlways) {
                    #expect(got.contains(name), "\(name) must be returned (ticked \(tick))")
                }
                for name in mixedCodeFiles {
                    #expect(!got.contains(name), "\(name) is code: it must not be returned (ticked \(tick))")
                }
                #expect(got == mixedAllKinds, "got \(got.sorted()) (ticked \(tick))")
            }
            #expect(Set(Walker.readerKinds) == ["photo", "pdf", "doc", "audio", "video", "code"] && Array(Walker.readerKinds).count == 6,
                    "the kinds with a reader are photo, pdf, doc, audio, video and code, got \(Array(Walker.readerKinds))")
        }
    }

    @Test func everyReturnedFileIsOneThePlaceRulesAdmitAsAPhotoAPdfADocumentAnAudioFileOrAVideo() throws {
        try withTree { tree in
            try buildMixedTree(tree)
            let picks = [pick(tree.root, code: true)]
            let result = Walker.scan(root: tree.root, mode: .read, picks: picks, flags: { _ in 0 }, repoFiles: mixedRepoFiles)
            #expect(result.files.isEmpty == false, "the mixed tree holds photos")
            for file in result.files {
                let admitted = Rules.admit(path: file.path, picks: picks)
                #expect(admitted != nil, "\(file.path) was returned but Rules.admit(path:picks:) says nil")
                let wanted = expectedKind(of: file.path)
                #expect(admitted?.kind == wanted, "\(file.path) was returned and is a \(admitted?.kind ?? "nothing"), expected \(wanted)")
            }
        }
    }

    // MARK: places

    @Test func aHiddenFolderCachesAndAnAppBundleHideTheirPicturesInReadMode() throws {
        try withTree { tree in
            try tree.file("plain/shot.png")
            try tree.file(".hidden/h.png")
            try tree.file(".hidden/deeper/h2.png")
            try tree.file("plain/.ssh/s.png")
            try tree.file("Caches/c.png")
            try tree.file("plain/Caches/deeper/c2.png")
            try tree.file("Thing.app/Contents/Resources/icon.png")
            try tree.file("Upper.APP/pic.png")
            try tree.file("Mixed.App/pic.png")
            try tree.file("Caches2/ok.png")
            try tree.file("MyCaches/ok.png")
            try tree.file("hidden-name-file/.dot-photo.png")
            let got = readNames(tree, picks: [pick(tree.root)])
            #expect(got == ["plain/shot.png", "Caches2/ok.png", "MyCaches/ok.png", "hidden-name-file/.dot-photo.png"],
                    "got \(got.sorted())")
        }
    }

    @Test func aHiddenNameAboveThePickDoesNotCount() throws {
        try withTree { tree in
            try tree.file(".cache/pics/a.png")
            try tree.file(".cache/pics/sub/b.png")
            try tree.file(".cache/pics/.inner/c.png")
            let pickRoot = tree.path(".cache/pics")
            let got = readNames(tree, picks: [pick(pickRoot)], root: pickRoot)
            #expect(got == [".cache/pics/a.png", ".cache/pics/sub/b.png"], "got \(got.sorted())")
        }
    }

    @Test func vendoredFoldersHideTheirPicturesInsideARepoAndNotOutsideOne() throws {
        try withTree { tree in
            try tree.dir("repo/.git")
            try tree.file("repo/shot.png")
            for name in ["node_modules", "Pods", "build", "dist", "vendor"] {
                try tree.file("repo/\(name)/in.png")
                try tree.file("repo/src/\(name)/deep/in2.png")
                try tree.file("loose/\(name)/out.png")
            }
            try tree.file("repo/.build/b.png")
            try tree.file("loose/.build/b.png")
            // the fake repo marker's list, by hand: every file the test made in it (git is not run)
            var listed: Set<String> = ["shot.png", ".build/b.png"]
            for name in ["node_modules", "Pods", "build", "dist", "vendor"] { listed.formUnion(["\(name)/in.png", "src/\(name)/deep/in2.png"]) }
            let repoList = listed
            let got = readNames(tree, picks: [pick(tree.root)], repoFiles: { _ in repoList })
            var want: Set<String> = ["repo/shot.png"]
            for name in ["node_modules", "Pods", "build", "dist", "vendor"] { want.insert("loose/\(name)/out.png") }
            #expect(got == want, "missing \(want.subtracting(got).sorted()), unexpected \(got.subtracting(want).sorted())")
        }
    }

    @Test func theNearestRepoMarkerDecidesWhereTheVendoredNamesApply() throws {
        try withTree { tree in
            // a repo marker file (a worktree's `.git` is a file) counts too
            try tree.file("wt/.git")
            try tree.file("wt/node_modules/in.png")
            try tree.file("wt/keep.png")
            try tree.dir("plain/node_modules")
            try tree.file("plain/node_modules/out.png")
            // the fake marker's list, by hand: every file the test made in `wt` (git is not run)
            let got = readNames(tree, picks: [pick(tree.root)], repoFiles: { _ in ["node_modules/in.png", "keep.png"] })
            #expect(got == ["wt/keep.png", "plain/node_modules/out.png"], "got \(got.sorted())")
        }
    }

    // MARK: kinds of entry

    @Test func aSymbolicLinkToAPhotoAndAFIFOAreNotReturnedAndTheTargetIsReturnedOnce() throws {
        try withTree { tree in
            try tree.file("plain/shot.png")
            try tree.link("links/link.png", to: "plain/shot.png")
            try tree.link("links/link-to-folder", to: "plain")
            try tree.fifo("special/pipe.png")
            let got = readNames(tree, picks: [pick(tree.root)])
            #expect(got == ["plain/shot.png"], "got \(got.sorted())")
        }
    }

    @Test func aKeyNamePictureIsNotReturnedAndTheSameNameInAPlainFolderIsNotAKey() throws {
        try withTree { tree in
            try tree.file("keys/id_rsa.png")
            try tree.file("keys/.env.png")
            try tree.file("keys/.env.local.png")
            try tree.file("keys/ID_RSA.PNG")
            try tree.file("keys/shot.png")
            let got = readNames(tree, picks: [pick(tree.root)])
            #expect(got == ["keys/shot.png"], "got \(got.sorted())")
        }
    }

    // MARK: cloud-only files

    @Test func aSparsePhotoAndAPhotoTheFlagsClosureCallsDatalessAreSetAsideNotReturned() throws {
        try withTree { tree in
            try tree.file("keep.png")
            try tree.file("evicted.png")
            let isSparse = try tree.sparse("cloud.png")
            let flags: (String) -> UInt32 = { ($0 as NSString).lastPathComponent == "evicted.png" ? sfDataless : 0 }
            let result = Walker.scan(root: tree.root, mode: .read, picks: [pick(tree.root)], flags: flags)
            let files = relative(result.files.map(\.path), under: tree.root)
            let aside = "\(result.dataless)"
            #expect(files.contains("keep.png"), "control: the plain photo is returned, got \(files.sorted())")
            #expect(!files.contains("evicted.png"), "a photo the flags closure calls dataless is not in files")
            #expect(aside.contains(tree.path("evicted.png")), "the dataless photo is in dataless, got \(aside)")
            if isSparse {
                #expect(!files.contains("cloud.png"), "a sparse photo (a size, no blocks) is not in files")
                #expect(aside.contains(tree.path("cloud.png")), "the sparse photo is in dataless, got \(aside)")
                #expect(!aside.contains(tree.path("keep.png")), "the plain photo is not in dataless, got \(aside)")
                #expect(files == ["keep.png"], "got \(files.sorted())")
            } else {
                print("NOTE sparse stand-in not creatable on this volume; the sparse half is not exercised")
                #expect(files == ["keep.png", "cloud.png"], "got \(files.sorted())")
            }
        }
    }

    // MARK: unreadable folders

    @Test func aModeZeroHiddenFolderIsNeverListedSoItIsNotUnreadableButAModeZeroOrdinaryFolderStillIs() throws {
        try withTree { tree in
            guard canTestPermissions() else { return }
            try tree.file("ok/a.png")
            try tree.file(".locked/x.png")
            try tree.file("locked/y.png")
            tree.lock(".locked")
            tree.lock("locked")
            let result = Walker.scan(root: tree.root, mode: .read, picks: [pick(tree.root)], flags: { _ in 0 })
            #expect(relative(result.files.map(\.path), under: tree.root) == ["ok/a.png"],
                    "got \(relative(result.files.map(\.path), under: tree.root).sorted())")
            #expect(result.unreadable == [tree.path("locked")],
                    "only the ordinary locked folder is unreadable, got \(result.unreadable)")
        }
    }

    // MARK: picks

    @Test func withNoPicksGivenTheRootIsTheOnePickAndNotTicked() throws {
        try withTree { tree in
            try buildMixedTree(tree)
            let flags: (String) -> UInt32 = { ($0 as NSString).lastPathComponent == "evicted.png" ? sfDataless : 0 }
            let byDefault = Walker.scan(root: tree.root, mode: .read, flags: flags, repoFiles: mixedRepoFiles)
            let named = Walker.scan(root: tree.root, mode: .read, picks: [pick(tree.root)], flags: flags, repoFiles: mixedRepoFiles)
            let defaultNames = relative(byDefault.files.map(\.path), under: tree.root)
            let want = mixedAllKinds
            #expect(defaultNames == want,
                    "missing \(want.subtracting(defaultNames).sorted()), unexpected \(defaultNames.subtracting(want).sorted())")
            #expect(defaultNames == relative(named.files.map(\.path), under: tree.root))
            #expect(byDefault.unreadable == named.unreadable)
        }
    }

    @Test func aScanRootInsideASeveralPickListReturnsItsOwnPhotosByTheSameRules() throws {
        try withTree { tree in
            try tree.file("outer/a.png")
            try tree.file("outer/inner/b.png")
            try tree.file("outer/inner/.hid/c.png")
            try tree.file("outer/Caches/d.png")
            let picks = [pick(tree.path("outer"), code: false), pick(tree.path("outer/inner"), code: true)]
            let inner = readNames(tree, picks: picks, root: tree.path("outer/inner"))
            #expect(inner == ["outer/inner/b.png"], "got \(inner.sorted())")
            let outer = readNames(tree, picks: picks, root: tree.path("outer"))
            #expect(outer == ["outer/a.png", "outer/inner/b.png"], "got \(outer.sorted())")
        }
    }

    // MARK: count mode is unchanged

    @Test func countModeStillCountsHiddenCachesAppVendoredAndEveryKindByNamesAndTypes() throws {
        try withTree { tree in
            try tree.file("plain/shot.png")
            try tree.file("plain/note.txt")
            try tree.file(".hidden/h.png")
            try tree.file("Caches/c.png")
            try tree.file("Thing.app/Contents/icon.png")
            try tree.file("loose/node_modules/n.png")
            try tree.dir("repo/.git")
            try tree.file("repo/node_modules/n.png")
            try tree.file("repo/Pods/p.png")
            try tree.file("keys/id_rsa.png")
            try tree.file("plain/skip.unknownext")
            let want: Set<String> = [
                "plain/shot.png", "plain/note.txt", ".hidden/h.png", "Caches/c.png", "Thing.app/Contents/icon.png",
                "loose/node_modules/n.png", "repo/node_modules/n.png", "repo/Pods/p.png",
            ]
            let byDefault = Walker.scan(root: tree.root, mode: .count)
            let named = Walker.scan(root: tree.root, mode: .count, picks: [pick(tree.root)], flags: { _ in 0 })
            let defaultNames = relative(byDefault.files.map(\.path), under: tree.root)
            let namedNames = relative(named.files.map(\.path), under: tree.root)
            #expect(defaultNames == want, "missing \(want.subtracting(defaultNames).sorted()), unexpected \(defaultNames.subtracting(want).sorted())")
            #expect(namedNames == want, "with picks given: missing \(want.subtracting(namedNames).sorted()), unexpected \(namedNames.subtracting(want).sorted())")
        }
    }

    // MARK: git file lists (plan-3-t17)

    /// A real repo `repo` (tracked, untracked-not-ignored, ignored by a file rule, by a folder rule, and tracked though the
    /// `.gitignore` names it) next to `loose`, a folder with no repo marker whose `.gitignore` means nothing.
    private func buildRealRepoTree(_ tree: RTree) throws {
        try tree.dir("loose")
        try tree.repo("repo")
        try Data("ignored.png\nout/\nforced.png\n".utf8).write(to: URL(fileURLWithPath: tree.path("repo/.gitignore")))
        try tree.file("repo/tracked.png")
        try tree.file("repo/sub/tracked2.png")
        try tree.file("repo/forced.png")
        try tree.git("repo", ["add", ".gitignore", "tracked.png", "sub/tracked2.png"])
        try tree.git("repo", ["add", "-f", "forced.png"])
        try tree.commit("repo")
        for name in ["fresh.png", "sub/fresh2.png", "ignored.png", "sub/ignored.png", "out/x.png", "out/deep/y.png",
                     "node_modules/n.png", "Pods/p.png", "build/b.png", "dist/d.png", "vendor/v.png", ".build/b.png",
                     "note.txt"] {
            try tree.file("repo/" + name)
        }
        try Data("ignored.png\n".utf8).write(to: URL(fileURLWithPath: tree.path("loose/.gitignore")), options: [])
    }

    @Test func readModeOverARealRepoDropsIgnoredPicturesAndVendoredFoldersAndKeepsTheRestAndTheSameNamesOutsideARepo() throws {
        try withTree { tree in
            try tree.dir("loose")
            try buildRealRepoTree(tree)
            try tree.file("loose/ignored.png")
            try tree.file("loose/node_modules/n.png")
            try tree.file("loose/shot.png")
            let got = readNames(tree, picks: [pick(tree.root)])
            // tracked and untracked-not-ignored pictures; the ignored ones (a file rule, a folder rule) are absent, the
            // tracked-though-named-in-.gitignore one is present; vendored names are the rules'; `loose` is not a repo
            let want: Set<String> = [
                "repo/tracked.png", "repo/sub/tracked2.png", "repo/forced.png", "repo/fresh.png", "repo/sub/fresh2.png",
                "repo/note.txt",
                "loose/ignored.png", "loose/node_modules/n.png", "loose/shot.png",
            ]
            #expect(got == want, "missing \(want.subtracting(got).sorted()), unexpected \(got.subtracting(want).sorted())")
        }
    }

    @Test func aRepoNotTickedAndATickedRepoReturnTheSameFilesOfEveryKindExceptCodeAndAskGitOnce() throws {
        try withTree { tree in
            try tree.dir("loose")
            try buildRealRepoTree(tree)
            for name in ["tool.py", "paper.pdf", "song.wav", "clip.mp4"] { try tree.file("repo/" + name) }
            let want: Set<String> = ["repo/tracked.png", "repo/sub/tracked2.png", "repo/forced.png", "repo/fresh.png", "repo/sub/fresh2.png",
                                     "repo/paper.pdf", "repo/note.txt", "repo/song.wav", "repo/clip.mp4"]
            let wantTicked = want

            let notTicked = [pick(tree.root)]
            let ticked = [pick(tree.root), pick(tree.path("repo"), code: true)]
            #expect(Rules.admit(path: tree.path("repo/tool.py"), picks: notTicked) == nil, "setup: a code file in an unticked repo is not admitted")
            #expect(Rules.admit(path: tree.path("repo/tool.py"), picks: ticked) == nil, "setup: a code file in a ticked repo is not admitted either")
            #expect(Rules.admit(path: tree.path("repo/paper.pdf"), picks: notTicked) != nil, "setup: a PDF in an unticked repo is admitted")

            let askedUnticked = Calls()
            let askedTicked = Calls()
            let gotUnticked = Set(relative(Walker.scan(root: tree.root, mode: .read, picks: notTicked, repoFiles: countingList(askedUnticked)).files.map(\.path), under: tree.root))
            let gotTicked = Set(relative(Walker.scan(root: tree.root, mode: .read, picks: ticked, repoFiles: countingList(askedTicked)).files.map(\.path), under: tree.root))
            #expect(gotUnticked == want, "not ticked: missing \(want.subtracting(gotUnticked).sorted()), unexpected \(gotUnticked.subtracting(want).sorted())")
            #expect(gotTicked == wantTicked, "ticked: missing \(wantTicked.subtracting(gotTicked).sorted()), unexpected \(gotTicked.subtracting(wantTicked).sorted())")
            #expect(askedUnticked.count(ofRepoNamed: "repo") == 1, "asked for repo \(askedUnticked.count(ofRepoNamed: "repo")) times, not once (not ticked)")
            #expect(askedTicked.count(ofRepoNamed: "repo") == 1, "asked for repo \(askedTicked.count(ofRepoNamed: "repo")) times, not once (ticked)")
            #expect(askedUnticked.repos.count == 1, "only the one repo is asked for, got \(askedUnticked.repos)")
        }
    }

    @Test func theListingIsAskedOncePerRepoPerScanNotOncePerFile() throws {
        try withTree { tree in
            try tree.repo("one")
            try tree.repo("two")
            for index in 0..<6 { try tree.file("one/d\(index)/p\(index).png") }
            for index in 0..<4 { try tree.file("two/q\(index).png") }
            try tree.file("plain/shot.png")
            let first = Calls()
            let result = Walker.scan(root: tree.root, mode: .read, picks: [pick(tree.root)], repoFiles: countingList(first))
            #expect(result.files.count == 11, "10 pictures in the two repos and one plain, got \(result.files.count)")
            #expect(first.count(ofRepoNamed: "one") == 1, "repo one asked \(first.count(ofRepoNamed: "one")) times")
            #expect(first.count(ofRepoNamed: "two") == 1, "repo two asked \(first.count(ofRepoNamed: "two")) times")
            #expect(first.repos.count == 2, "only the two repos are asked for, got \(first.repos)")
            let second = Calls()
            _ = Walker.scan(root: tree.root, mode: .read, picks: [pick(tree.root)], repoFiles: countingList(second))
            #expect(second.repos.count == 2, "a second scan asks again, once per repo, got \(second.repos)")
        }
    }

    @Test func nestedReposUseTheirNearestDotGit() throws {
        try withTree { tree in
            try tree.repo("outer")
            try tree.repo("outer/inner")
            try Data("outer-ignored.png\n".utf8).write(to: URL(fileURLWithPath: tree.path("outer/.gitignore")))
            try Data("inner-ignored.png\n".utf8).write(to: URL(fileURLWithPath: tree.path("outer/inner/.gitignore")))
            for name in ["outer/a.png", "outer/outer-ignored.png", "outer/inner/b.png", "outer/inner/inner-ignored.png",
                         "outer/inner/deep/c.png"] {
                try tree.file(name)
            }
            let calls = Calls()
            let got = Set(relative(Walker.scan(root: tree.root, mode: .read, picks: [pick(tree.root)], repoFiles: countingList(calls)).files.map(\.path), under: tree.root))
            // the inner repo's files come from the inner repo's own list (the outer list holds the inner folder as one entry)
            let want: Set<String> = ["outer/a.png", "outer/inner/b.png", "outer/inner/deep/c.png"]
            #expect(got == want, "missing \(want.subtracting(got).sorted()), unexpected \(got.subtracting(want).sorted())")
            #expect(calls.count(ofRepoNamed: "outer") == 1 && calls.count(ofRepoNamed: "inner") == 1,
                    "each repo is asked for once, got \(calls.repos)")
        }
    }

    @Test func aRepoGitCannotAnswerForIsSkippedAndListedUnreadableWhileTheRestIsStillReturned() throws {
        try withTree { tree in
            try tree.repo("bad")
            try tree.repo("good")
            try tree.file("bad/tracked.png")
            try tree.git("bad", ["add", "tracked.png"])
            try tree.commit("bad")
            try tree.file("bad/fresh.png")
            try tree.file("bad/sub/deep.png")
            try tree.file("good/fresh.png")
            try tree.file("plain/shot.png")
            let calls = Calls()
            let result = Walker.scan(root: tree.root, mode: .read, picks: [pick(tree.root)],
                                     repoFiles: countingList(calls, failing: ["bad"]))
            let got = Set(relative(result.files.map(\.path), under: tree.root))
            #expect(got == ["good/fresh.png", "plain/shot.png"], "got \(got.sorted())")
            let unreadable = "\(result.unreadable)"
            #expect(unreadable.contains(tree.path("bad")), "the skipped repo is in unreadable, got \(unreadable)")
            #expect(!unreadable.contains(tree.path("good")), "the answered repo is not unreadable, got \(unreadable)")
            #expect(calls.count(ofRepoNamed: "bad") == 1 && calls.count(ofRepoNamed: "good") == 1, "got \(calls.repos)")
        }
    }

    @Test func countModeNeverAsksForAGitListingAndStillCountsTheIgnoredPictures() throws {
        try withTree { tree in
            try tree.dir("loose")
            try buildRealRepoTree(tree)
            let calls = Calls()
            let result = Walker.scan(root: tree.root, mode: .count, picks: [pick(tree.root)], repoFiles: countingList(calls))
            #expect(calls.repos.isEmpty, "count mode asked git for \(calls.repos)")
            let got = Set(relative(result.files.map(\.path), under: tree.root))
            // counts use names, sizes and types only: the git-ignored and the vendored pictures are counted (D4)
            let want: Set<String> = [
                "repo/tracked.png", "repo/sub/tracked2.png", "repo/forced.png", "repo/fresh.png", "repo/sub/fresh2.png",
                "repo/ignored.png", "repo/sub/ignored.png", "repo/out/x.png", "repo/out/deep/y.png",
                "repo/node_modules/n.png", "repo/Pods/p.png", "repo/build/b.png", "repo/dist/d.png", "repo/vendor/v.png",
                "repo/.build/b.png", "repo/note.txt",
            ]
            #expect(got == want, "missing \(want.subtracting(got).sorted()), unexpected \(got.subtracting(want).sorted())")
        }
    }

    // MARK: a repo whose git never answers (plan-3 fix round, t17-4)

    @Test func aRepoWhoseGitignoreIsAFifoIsSkippedAndListedUnreadableWhileAPlainSiblingIsStillReturned() throws {
        try withTree { tree in
            try tree.repo("hung")
            try tree.file("hung/a.png")
            try tree.file("plain/shot.png")
            try tree.file("plain/sub/other.png")
            let fifo = tree.path("hung/.gitignore")
            try #require(mkfifo(fifo, 0o600) == 0, "setup: could not make the FIFO .gitignore")
            let folderName = (tree.root as NSString).lastPathComponent
            defer {
                unlink(fifo)
                killGitLeftovers(tempFolderName: folderName)
            }

            let root = tree.root
            let picks = [pick(root)]
            // default `repoFiles`: the real git, with no argument from the caller; the call runs on a background thread
            let guarded = runGuarded { () -> (names: Set<String>, unreadable: String) in
                let result = Walker.scan(root: root, mode: .read, picks: picks)
                return (relative(result.files.map(\.path), under: root), "\(result.unreadable)")
            }
            if guarded.timedOut {
                let killed = killGitLeftovers(tempFolderName: folderName)
                Issue.record("Walker.scan had not returned after 120 s over a repo whose .gitignore is a FIFO (killed \(killed) git process(es) to clean up)")
                return
            }
            #expect(guarded.seconds <= 90, "it returned after \(Int(guarded.seconds)) s, more than the 90 s allowed")
            let outcome = try #require(guarded.value)
            #expect(outcome.names == ["plain/shot.png", "plain/sub/other.png"], "got \(outcome.names.sorted())")
            #expect(outcome.unreadable.contains(tree.path("hung")), "the skipped repo is in unreadable, got \(outcome.unreadable)")
            #expect(!outcome.unreadable.contains(tree.path("plain")), "the plain sibling is not unreadable, got \(outcome.unreadable)")
        }
    }
}

// MARK: a call that may never return (plan-3 fix round, t17-4)
//
// Same guard as in GitFilesTests.swift (private to that file): the call runs on a background thread, the test waits at most
// 120 s, then fails and kills the git it started, so the suite never hangs.

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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
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
