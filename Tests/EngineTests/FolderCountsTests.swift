import Foundation
import Testing
import SesameEngine

// plan-2-t14, tester step: Walker count mode and `FolderCounts`, the counts the setup shows before Start indexing.
// Written from plan-2-tasks.md (entry t14), spec S6 and S1 (a file counts once when folders overlap; counts use names,
// sizes and types only and do not apply the git-ignore rules), design section 3 ("Setup, before Start") and the plan-1
// tests as the one place the fixed names `Rules.admit` and `Walker.Mode.count` are read. No product source was read.
//
// THE SHAPE THESE TESTS PIN (new API; today `FolderCounts` does not exist, so this file does not compile until it does).
// The entry names `FolderCounts.count(folders:)` and the field `unreadable`; the rest of the shape is this file's pick:
//
//     public struct FolderCounts {
//         public let perFolder: [String: [String: Int]]   // picked folder path, as passed -> kind -> files under it
//         public let summary: [String: Int]                // kind -> files, each file once (by path) over all folders
//         public let total: Int                            // the unique total: the sum of `summary`
//         public let unreadable: [String]                  // folders that exist but could not be listed, as the walk spelled them
//         public static func count(folders: [String]) -> FolderCounts    // synchronous, never throws
//     }
//
// - Kinds are the plan-1 strings "photo", "pdf", "doc", "audio", "video", "code". A kind with no file may be absent
//   from a dictionary or present as 0; both mean 0 here.
// - A folder given twice, or a folder inside another given folder, is one set of files in `summary` and `total`.
// - Count mode opens no file, runs no git and reads no `.gitignore`.
//
// Permissions: `chmod 000` on a file or folder; every change is undone in a defer. Run as root, those tests say so and stop.

private let allKinds = ["photo", "pdf", "doc", "audio", "video", "code"]

// Extensions each kind cycles through when a file is made (design section 4, spec Goals), so no one extension carries the table.
private let extensionsByKind: [String: [String]] = [
    "photo": ["jpg", "png", "heic", "webp", "tiff", "gif", "jpeg", "tif"],
    "pdf": ["pdf"],
    "doc": ["txt", "md", "rtf", "docx", "html", "odt"],
    "audio": ["mp3", "m4a", "wav", "aac", "flac"],
    "video": ["mp4", "mov", "m4v"],
    "code": ["swift", "py", "js", "ts", "go", "rs", "java", "c", "rb", "sh"],
]

// MARK: - The hand-written table: five folders, files per kind, plus files that are not counted.
// Written by hand from the spec's list of supported types, not computed from anything.

private struct FolderSpec {
    let name: String
    let counts: [String: Int]      // the expected cells, hand-written
    let code: Int
    let ignored: [String]          // unsupported names that sit in the folder and must not be counted
}

private let fiveFolders: [FolderSpec] = [
    FolderSpec(name: "Desktop",
               counts: ["photo": 5, "pdf": 2, "doc": 3, "audio": 0, "video": 1, "code": 0],
               code: 0,
               ignored: ["slides.pptx", ".DS_Store", "README"]),
    FolderSpec(name: "Documents",
               counts: ["photo": 1, "pdf": 7, "doc": 6, "audio": 0, "video": 0, "code": 0],
               code: 2,
               ignored: ["budget.xlsx", "notes.pages", ".DS_Store", "sub/old.pptx"]),
    FolderSpec(name: "Downloads",
               counts: ["photo": 3, "pdf": 4, "doc": 0, "audio": 2, "video": 2, "code": 0],
               code: 1,
               ignored: ["archive.zip", "raw.dng", ".DS_Store"]),
    FolderSpec(name: "Pictures",
               counts: ["photo": 12, "pdf": 0, "doc": 1, "audio": 0, "video": 0, "code": 0],
               code: 0,
               ignored: ["scan.dng", ".DS_Store", "album/.DS_Store", "album/cover.pptx"]),
    FolderSpec(name: "Movies",
               counts: ["photo": 2, "pdf": 0, "doc": 0, "audio": 1, "video": 4, "code": 0],
               code: 0,
               ignored: [".DS_Store", "project.xyz"]),
]

// MARK: - Helpers (private, so nothing clashes with the other test files)

private func makeScratchFolder(_ label: String) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-foldercounts-\(label)-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // /var is a link to /private/var on macOS; hand the code the real path.
    return url.resolvingSymlinksInPath().path
}

private func write(_ path: String, bytes: Int = 64) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try Data(repeating: 9, count: bytes).write(to: URL(fileURLWithPath: path))
}

private func removeQuietly(_ paths: String...) {
    for path in paths { try? FileManager.default.removeItem(atPath: path) }
}

// Makes `count` files of `kind` under `folder`, every other one in a nested folder, named kind-<n>.<ext>.
private func makeFiles(kind: String, count: Int, under folder: String, tag: String = "") throws {
    let extensions = extensionsByKind[kind] ?? []
    for n in 0..<count {
        let ext = extensions[n % extensions.count]
        let nested = n % 2 == 1 ? "level\(n % 3)/" : ""
        try write("\(folder)/\(nested)\(kind)\(tag)-\(n).\(ext)")
    }
}

private func makeFolder(_ spec: FolderSpec, in base: String) throws -> String {
    let folder = base + "/" + spec.name
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for kind in allKinds where kind != "code" { try makeFiles(kind: kind, count: spec.counts[kind] ?? 0, under: folder) }
    try makeFiles(kind: "code", count: spec.code, under: folder)
    for name in spec.ignored { try write(folder + "/" + name) }
    return folder
}

private func cell(_ counts: [String: Int]?, _ kind: String) -> Int { counts?[kind] ?? 0 }

private func expectCounts(_ actual: [String: Int]?, _ expected: [String: Int], _ label: String,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    for kind in allKinds {
        #expect(cell(actual, kind) == (expected[kind] ?? 0), "\(label), \(kind): got \(cell(actual, kind)), want \(expected[kind] ?? 0) (all: \(String(describing: actual)))",
                sourceLocation: sourceLocation)
    }
    let extras = (actual ?? [:]).filter { !allKinds.contains($0.key) && $0.value != 0 }
    #expect(extras.isEmpty, "\(label): counts for kinds that do not exist: \(extras)", sourceLocation: sourceLocation)
}

private func canTestPermissions() -> Bool {
    if getuid() == 0 {
        Issue.record("this test runs as root, and root lists and stats through chmod 000: it cannot show anything; run it as the person")
        return false
    }
    return true
}

// MARK: - Tests

@Suite("FolderCountsTests")
struct FolderCountsTests {

    // The hand table: every cell of five folders, then the summary, the total and nothing unreadable.
    @Test func fiveFoldersGiveEveryCellOfTheHandWrittenTable() throws {
        let base = try makeScratchFolder("five")
        defer { removeQuietly(base) }
        var paths: [String] = []
        for spec in fiveFolders { paths.append(try makeFolder(spec, in: base)) }

        let result = FolderCounts.count(folders: paths)

        for (spec, path) in zip(fiveFolders, paths) {
            expectCounts(result.perFolder[path], spec.counts, spec.name)
        }
        // Five distinct folders: nothing overlaps, so the summary is the column sums of the table, written by hand.
        let summary = ["photo": 23, "pdf": 13, "doc": 10, "audio": 3, "video": 7, "code": 0]
        expectCounts(result.summary, summary, "summary")
        #expect(result.total == 56, "unique total: got \(result.total), want 56")
        #expect(result.unreadable.isEmpty, "nothing is locked, got \(result.unreadable)")
    }

    // An empty folder, and a folder holding only unsupported files, count as zeros.
    @Test func anEmptyFolderAndAFolderOfUnsupportedFilesCountZero() throws {
        let base = try makeScratchFolder("zeros")
        defer { removeQuietly(base) }
        let empty = base + "/empty"
        let junk = base + "/junk"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        for name in ["a.pptx", ".DS_Store", "b.xlsx", "c.pages", "d.dng", "e.zip", "README", "f.xyz"] {
            try write(junk + "/" + name)
        }
        let result = FolderCounts.count(folders: [empty, junk])
        expectCounts(result.perFolder[empty], [:], "empty")
        expectCounts(result.perFolder[junk], [:], "junk")
        expectCounts(result.summary, [:], "summary")
        #expect(result.total == 0)
        #expect(result.unreadable.isEmpty)
    }

    // A pair A and A/inner: each row holds what lies under it; the summary is the unique count, not the sum.
    @Test func anOverlappingPairGivesRowsThatEachHoldWhatLiesUnderThemAndASummaryThatCountsOnce() throws {
        let base = try makeScratchFolder("overlap")
        defer { removeQuietly(base) }
        let outer = base + "/A"
        let inner = outer + "/inner"
        try makeFiles(kind: "photo", count: 3, under: outer)
        try makeFiles(kind: "pdf", count: 1, under: outer)
        try makeFiles(kind: "photo", count: 2, under: inner, tag: "-in")
        try makeFiles(kind: "doc", count: 4, under: inner, tag: "-in")

        for folders in [[outer, inner], [inner, outer]] {
            let result = FolderCounts.count(folders: folders)
            expectCounts(result.perFolder[outer], ["photo": 5, "pdf": 1, "doc": 4], "A (order \(folders.map { ($0 as NSString).lastPathComponent }))")
            expectCounts(result.perFolder[inner], ["photo": 2, "doc": 4], "A/inner")
            expectCounts(result.summary, ["photo": 5, "pdf": 1, "doc": 4], "summary")
            #expect(result.total == 10, "unique total is 10, not the sum 16: got \(result.total)")
            #expect(result.unreadable.isEmpty)
        }
    }

    // Overlap with a third, separate folder: only the shared files are counted once.
    @Test func anOverlapBesideASeparateFolderAddsOnlyTheSeparateFoldersFiles() throws {
        let base = try makeScratchFolder("overlap3")
        defer { removeQuietly(base) }
        let outer = base + "/Documents"
        let inner = outer + "/Work"
        let other = base + "/Pictures"
        try makeFiles(kind: "pdf", count: 2, under: outer)
        try makeFiles(kind: "doc", count: 3, under: inner, tag: "-w")
        try makeFiles(kind: "photo", count: 6, under: other)

        let result = FolderCounts.count(folders: [outer, other, inner])
        expectCounts(result.perFolder[outer], ["pdf": 2, "doc": 3], "Documents")
        expectCounts(result.perFolder[inner], ["doc": 3], "Documents/Work")
        expectCounts(result.perFolder[other], ["photo": 6], "Pictures")
        expectCounts(result.summary, ["pdf": 2, "doc": 3, "photo": 6], "summary")
        #expect(result.total == 11, "got \(result.total)")
    }

    // The same folder given twice is one set of files.
    @Test func theSameFolderGivenTwiceCountsItsFilesOnce() throws {
        let base = try makeScratchFolder("twice")
        defer { removeQuietly(base) }
        let folder = base + "/Downloads"
        try makeFiles(kind: "photo", count: 4, under: folder)
        try makeFiles(kind: "audio", count: 2, under: folder)

        let result = FolderCounts.count(folders: [folder, folder])
        expectCounts(result.perFolder[folder], ["photo": 4, "audio": 2], "Downloads")
        expectCounts(result.summary, ["photo": 4, "audio": 2], "summary")
        #expect(result.total == 6, "got \(result.total)")
    }

    // A repo: `.git` is a folder with no real repository in it, and `.gitignore` lists *.jpg. Counting runs no git and reads
    // no `.gitignore`: the photos are counted, and so is every other kind. (Real git on this `.git` would fail; a `.gitignore`
    // reader would drop the jpg files.)
    @Test func aRepoFolderCountsFilesItsGitignoreListsAndNeedsNoGit() throws {
        let base = try makeScratchFolder("repo")
        defer { removeQuietly(base) }
        let repo = base + "/repo"
        try write(repo + "/.git/HEAD", bytes: 23)
        try write(repo + "/.gitignore", bytes: 12)
        try Data("*.jpg\n*.png\n".utf8).write(to: URL(fileURLWithPath: repo + "/.gitignore"))
        for n in 0..<4 { try write("\(repo)/docs/ignored-\(n).jpg") }
        try write(repo + "/docs/also-ignored.png")
        try write(repo + "/docs/guide.md")
        try write(repo + "/src/main.swift")
        try write(repo + "/src/util.py")
        try write(repo + "/manual.pdf")

        let result = FolderCounts.count(folders: [repo])
        expectCounts(result.perFolder[repo], ["photo": 5, "doc": 1, "pdf": 1], "repo")
        expectCounts(result.summary, ["photo": 5, "doc": 1, "pdf": 1], "summary")
        #expect(result.total == 7, "got \(result.total)")
        #expect(result.unreadable.isEmpty)
    }

    // A photo with mode 000 cannot be opened by the person's own process; it is still counted, because count mode opens no file.
    @Test func aPhotoWithMode000IsStillCounted() throws {
        guard canTestPermissions() else { return }
        let base = try makeScratchFolder("mode000")
        let folder = base + "/Pictures"
        var locked: [String] = []
        defer {
            for path in locked { chmod(path, 0o644) }
            removeQuietly(base)
        }
        try write(folder + "/open.jpg")
        try write(folder + "/private-1.jpg")
        try write(folder + "/sub/private-2.png")
        try write(folder + "/sub/private-3.pdf")
        for relative in ["private-1.jpg", "sub/private-2.png", "sub/private-3.pdf"] {
            let path = folder + "/" + relative
            #expect(chmod(path, 0) == 0, "could not chmod \(relative)")
            locked.append(path)
        }
        // The proof that the lock bites: this process cannot open the file.
        #expect(open(folder + "/private-1.jpg", O_RDONLY) < 0, "mode 000 should refuse an open; the test would prove nothing")

        let result = FolderCounts.count(folders: [folder])
        expectCounts(result.perFolder[folder], ["photo": 3, "pdf": 1], "Pictures")
        expectCounts(result.summary, ["photo": 3, "pdf": 1], "summary")
        #expect(result.total == 4, "got \(result.total)")
        #expect(result.unreadable.isEmpty, "a locked file is not a folder that could not be listed, got \(result.unreadable)")
    }

    // A symlink is not followed: not a link to a photo, not a link to a folder of photos, not a link out of the folder.
    @Test func aSymlinkIsNotFollowedAndNotCounted() throws {
        let base = try makeScratchFolder("links")
        defer { removeQuietly(base) }
        let folder = base + "/Pictures"
        let outside = base + "/outside"
        let fm = FileManager.default
        try write(folder + "/real.png")
        try write(folder + "/inside/deep.jpg")
        try makeFiles(kind: "photo", count: 3, under: outside, tag: "-out")
        try write(outside + "/paper.pdf")
        try fm.createSymbolicLink(atPath: folder + "/link-photo.png", withDestinationPath: folder + "/real.png")
        try fm.createSymbolicLink(atPath: folder + "/link-inside", withDestinationPath: folder + "/inside")
        try fm.createSymbolicLink(atPath: folder + "/link-outside", withDestinationPath: outside)
        try fm.createSymbolicLink(atPath: folder + "/link-out.pdf", withDestinationPath: outside + "/paper.pdf")
        try fm.createSymbolicLink(atPath: folder + "/dangling.png", withDestinationPath: folder + "/no-such.png")
        try fm.createSymbolicLink(atPath: folder + "/loop", withDestinationPath: folder)

        let result = FolderCounts.count(folders: [folder])
        expectCounts(result.perFolder[folder], ["photo": 2], "Pictures")
        expectCounts(result.summary, ["photo": 2], "summary")
        #expect(result.total == 2, "got \(result.total)")
        #expect(result.unreadable.isEmpty, "got \(result.unreadable)")
    }

    // A picked folder that cannot be listed is reported; the other folders are counted.
    @Test func aPickedFolderItCannotListIsReportedAndTheRestIsCounted() throws {
        guard canTestPermissions() else { return }
        let base = try makeScratchFolder("lockedroot")
        let good = base + "/Documents"
        let bad = base + "/Locked"
        defer {
            chmod(bad, 0o755)
            removeQuietly(base)
        }
        try makeFiles(kind: "pdf", count: 3, under: good)
        try makeFiles(kind: "photo", count: 2, under: good)
        try makeFiles(kind: "photo", count: 5, under: bad)
        #expect(chmod(bad, 0) == 0)

        let result = FolderCounts.count(folders: [bad, good])
        #expect(result.unreadable == [bad], "unreadable should be exactly the locked folder, got \(result.unreadable)")
        expectCounts(result.perFolder[good], ["pdf": 3, "photo": 2], "Documents")
        expectCounts(result.perFolder[bad], [:], "Locked")
        expectCounts(result.summary, ["pdf": 3, "photo": 2], "summary")
        #expect(result.total == 5, "got \(result.total)")
    }

    // A subfolder it cannot list inside a picked folder is reported too, and its siblings are counted.
    @Test func aSubfolderItCannotListIsReportedAndItsSiblingsAreCounted() throws {
        guard canTestPermissions() else { return }
        let base = try makeScratchFolder("lockedsub")
        let folder = base + "/Desktop"
        let bad = folder + "/private"
        defer {
            chmod(bad, 0o755)
            removeQuietly(base)
        }
        try write(folder + "/a.jpg")
        try write(folder + "/ok/b.pdf")
        try write(folder + "/ok/deeper/c.mp3")
        try write(bad + "/d.jpg")
        try write(bad + "/inner/e.mov")
        #expect(chmod(bad, 0) == 0)

        let result = FolderCounts.count(folders: [folder])
        #expect(result.unreadable == [bad], "got \(result.unreadable)")
        expectCounts(result.perFolder[folder], ["photo": 1, "pdf": 1, "audio": 1], "Desktop")
        expectCounts(result.summary, ["photo": 1, "pdf": 1, "audio": 1], "summary")
        #expect(result.total == 3, "got \(result.total)")
    }

    // `Rules.admit` is the one rule: key and password names are not counted, even with a photo extension; look-alikes are.
    @Test func keyAndPasswordNamesAreNotCountedAndLookAlikesAre() throws {
        let base = try makeScratchFolder("keys")
        defer { removeQuietly(base) }
        let folder = base + "/Documents"
        for name in ["id_rsa.png", "id_dsa.jpg", "id_ecdsa.png", "id_ed25519.gif", ".env.png", ".env.local.jpeg",
                     "id_rsa", "server.pem", "client.key", "bundle.p12", "vault.kdbx", "keys/id_rsa.png"] {
            try write(folder + "/" + name)
        }
        for name in ["key.png", "keyboard.png", "monkey.jpg", "environment.png", "my_id.png", "keys/rsa.png"] {
            try write(folder + "/" + name)
        }

        let result = FolderCounts.count(folders: [folder])
        expectCounts(result.perFolder[folder], ["photo": 6], "Documents")
        expectCounts(result.summary, ["photo": 6], "summary")
        #expect(result.total == 6, "got \(result.total)")
    }

    // 20,000 empty files are counted well inside a 30 s slack (the expected time is a fraction of a second).
    @Test func twentyThousandEmptyFilesAreCountedWithinAGenerousSlack() throws {
        let base = try makeScratchFolder("many")
        defer { removeQuietly(base) }
        let folder = base + "/Pictures"
        let fm = FileManager.default
        for group in 0..<20 {
            let directory = folder + "/group\(group)"
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for n in 0..<1000 {
                let fd = open("\(directory)/img-\(n).jpg", O_CREAT | O_WRONLY, 0o644)
                try #require(fd >= 0, "could not create the empty file group\(group)/img-\(n).jpg")
                close(fd)
            }
        }

        let started = Date()
        let result = FolderCounts.count(folders: [folder])
        let seconds = Date().timeIntervalSince(started)

        expectCounts(result.perFolder[folder], ["photo": 20_000], "Pictures")
        expectCounts(result.summary, ["photo": 20_000], "summary")
        #expect(result.total == 20_000, "got \(result.total)")
        #expect(seconds < 30, "counting 20,000 files took \(seconds) s")
    }

    // Counting leaves every file as it was: no file touched, no file added.
    @Test func countingChangesNothingOnDisk() throws {
        let base = try makeScratchFolder("readonly")
        defer { removeQuietly(base) }
        let folder = try makeFolder(fiveFolders[0], in: base)
        func snapshot() -> [String: String] {
            var out: [String: String] = [:]
            let walker = FileManager.default.enumerator(atPath: folder)
            while let relative = walker?.nextObject() as? String {
                var info = stat()
                if lstat(folder + "/" + relative, &info) == 0 {
                    out[relative] = "\(info.st_ino) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_mode)"
                }
            }
            return out
        }
        let before = snapshot()
        _ = FolderCounts.count(folders: [folder])
        #expect(snapshot() == before)
        #expect(!before.isEmpty)
    }
}
