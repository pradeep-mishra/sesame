import Foundation
import Testing
import SesameEngine

// plan-1-t24: Rules, FileGate and Walker, tested the way a caller uses them.
// Every tree is built by the test under a throwaway folder (FileManager, symlinks, utimensat) and
// removed again. Expected values are written by hand below or read with stat() by the test itself.

// MARK: - Hand-written expectations (design section 4)

private let kindsByExtension: [(kind: String, extensions: [String])] = [
    ("photo", ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]),
    ("pdf", ["pdf"]),
    ("doc", ["txt", "md", "rtf", "docx", "html", "odt"]),
    ("audio", ["mp3", "m4a", "wav", "aac", "flac"]),
    ("video", ["mp4", "mov", "m4v"]),
]

private let photoExtensions = ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]

private let codeExtensions = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]

// Not supported file types: never admitted, whatever the name. Key extensions are among them.
private let unsupportedExtensions = ["pptx", "xlsx", "pages", "dng", "pem", "key", "p12", "pfx", "kdbx", "zip", "xyz"] + codeExtensions

// Names that are key or password names (spec: .pem .key .p12 .pfx id_rsa* .env* *.kdbx, design adds
// id_dsa, id_ecdsa, id_ed25519), several carrying a photo extension.
private let keyNames = [
    "server.pem", "client.key", "bundle.p12", "bundle.pfx", "vault.kdbx",
    "id_rsa", "id_rsa.pub", "id_rsa_backup", "id_dsa", "id_ecdsa", "id_ed25519",
    ".env", ".env.local", ".envrc",
    "id_rsa.png", "id_dsa.jpg", "id_ecdsa.png", "id_ed25519.gif", ".env.png", ".env.local.jpeg",
]

// Names that only look a little like keys.
private let ordinaryNames = [
    "beach-dog.jpg", "monkey.jpg", "donkey.png", "keyboard.png", "key.png", "pemberton.jpg",
    "environment.png", "my_id.png", "rsa.png", "idea_rsa.png", "vault.png", "env.png",
]

// Photo-extension names that Rules must refuse because of the name.
private let keyNamedPhotos = ["id_rsa.png", "id_dsa.jpg", "id_ecdsa.png", "id_ed25519.gif", ".env.png", ".env.local.jpeg"]

// MARK: - Helpers (private, so nothing clashes with the other test files)

private func i64<T: BinaryInteger>(_ value: T) -> Int64 { Int64(truncatingIfNeeded: value) }

private struct StatValues: Equatable {
    var inode: Int64
    var size: Int64
    var mtimeNs: Int64
    var isRegular: Bool
    var isLink: Bool
    var isDirectory: Bool
}

private func lstatValues(_ path: String) -> StatValues? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let type = st.st_mode & S_IFMT
    return StatValues(
        inode: i64(st.st_ino),
        size: i64(st.st_size),
        mtimeNs: i64(st.st_mtimespec.tv_sec) * 1_000_000_000 + i64(st.st_mtimespec.tv_nsec),
        isRegular: type == S_IFREG,
        isLink: type == S_IFLNK,
        isDirectory: type == S_IFDIR)
}

private func setTimes(_ path: String, seconds: Int, nanoseconds: Int) throws {
    let stamp = timespec(tv_sec: seconds, tv_nsec: nanoseconds)
    let times = [stamp, stamp]
    guard utimensat(AT_FDCWD, path, times, 0) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func makeScratchFolder(_ label: String) throws -> String {
    let fm = FileManager.default
    let url = fm.temporaryDirectory.appendingPathComponent("sesame-rules-\(label)-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    // /var is a link to /private/var on macOS; hand the code the real path.
    return url.resolvingSymlinksInPath().path
}

// A deterministic, non-text byte pattern of the given length.
private func pattern(_ count: Int, seed: UInt8) -> Data {
    var data = Data(count: count)
    for index in 0..<count { data[index] = UInt8(truncatingIfNeeded: index &* 31 &+ Int(seed)) }
    return data
}

private func writeFile(_ path: String, _ data: Data) throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path))
}

private func removeQuietly(_ paths: String...) {
    for path in paths { try? FileManager.default.removeItem(atPath: path) }
}

// The tree under test. `photos` is what a read-mode walk must return, written by hand.
private struct Tree {
    let root: String
    let outside: String
    let photos: [String]      // relative paths of the admitted photo files
    let others: [String]      // relative paths of every other regular file
    let links: [String]       // relative paths of symlinks
    let directories: [String] // relative paths of directories

    func path(_ relative: String) -> String { root + "/" + relative }
    var photoPaths: [String] { photos.map(path).sorted() }
}

private func buildTree() throws -> Tree {
    let root = try makeScratchFolder("tree")
    let outside = try makeScratchFolder("outside")
    let fm = FileManager.default

    var photos: [String] = []
    var others: [String] = []
    var seed: UInt8 = 1

    func add(_ relative: String, into list: inout [String], size: Int? = nil) throws {
        let path = root + "/" + relative
        try writeFile(path, pattern(size ?? (40 + Int(seed) * 7), seed: seed))
        // Whole seconds plus nonzero nanoseconds, so a walker that keeps only seconds is caught.
        try setTimes(path, seconds: 1_700_000_000 + Int(seed) * 3_600, nanoseconds: 123_456_700 + Int(seed))
        list.append(relative)
        seed += 1
    }

    // The eight photo extensions, at the top and nested.
    for ext in photoExtensions { try add("pic-\(ext).\(ext)", into: &photos) }
    try add("sub/deep/nested.png", into: &photos)
    // A directory whose name looks like a photo, holding a real photo.
    try add("folder.png/inner.png", into: &photos)

    // Admitted by name or kind elsewhere, but not photos: a read-mode walk of slice 1 never lists them.
    for name in ["sub/notes.txt", "sub/report.pdf", "sub/song.mp3", "sub/clip.mp4", "sub/main.swift"] {
        try add(name, into: &others)
    }
    // Key and password names, several wearing a photo extension.
    for name in keyNamedPhotos { try add("keys/" + name, into: &others) }
    for name in ["keys/id_rsa", "keys/server.pem", "keys/cert.p12", "keys/vault.kdbx"] {
        try add(name, into: &others)
    }
    // Unsupported types and a name with no extension.
    for name in ["misc/raw.dng", "misc/slides.pptx", "misc/README"] { try add(name, into: &others) }

    // A photo outside the tree, to be reached only through links.
    try writeFile(outside + "/out.png", pattern(64, seed: 200))
    try fm.createDirectory(atPath: outside + "/dir", withIntermediateDirectories: true)
    try writeFile(outside + "/dir/out2.png", pattern(64, seed: 201))

    // Links: to a photo in the tree, to a directory in the tree, dangling, and out of the tree.
    try fm.createSymbolicLink(atPath: root + "/link-photo.png", withDestinationPath: root + "/pic-jpg.jpg")
    try fm.createSymbolicLink(atPath: root + "/link-dir", withDestinationPath: root + "/sub")
    try fm.createSymbolicLink(atPath: root + "/dangling.png", withDestinationPath: root + "/no-such-file.png")
    try fm.createSymbolicLink(atPath: root + "/link-out.png", withDestinationPath: outside + "/out.png")
    try fm.createSymbolicLink(atPath: root + "/link-outdir", withDestinationPath: outside + "/dir")

    return Tree(
        root: root, outside: outside, photos: photos, others: others,
        links: ["link-photo.png", "link-dir", "dangling.png", "link-out.png", "link-outdir"],
        directories: ["sub", "sub/deep", "folder.png", "keys", "misc"])
}

private func withTree(_ body: (Tree) throws -> Void) throws {
    let tree = try buildTree()
    defer { removeQuietly(tree.root, tree.outside) }
    try body(tree)
}

private func withScratch(_ body: (String) throws -> Void) throws {
    let folder = try makeScratchFolder("single")
    defer { removeQuietly(folder) }
    try body(folder)
}

// MARK: - Tests

@Suite("RulesTests")
struct RulesTests {

    // MARK: Rules: extensions and kinds

    @Test func everyExtensionOfTheFiveListsMapsToItsKind() {
        for (kind, extensions) in kindsByExtension {
            for ext in extensions {
                #expect(Rules.kind(forExtension: ext) == kind, "\(ext) should be \(kind)")
            }
        }
    }

    @Test func thePhotoExtensionsAreExactlyTheEightAndMapToPhoto() {
        let photos = kindsByExtension.first { $0.kind == "photo" }?.extensions ?? []
        #expect(Set(photos) == Set(photoExtensions))
        for ext in photoExtensions {
            #expect(Rules.kind(forExtension: ext) == "photo", "\(ext) should be photo")
        }
    }

    @Test func unsupportedExtensionsHaveNoKind() {
        for ext in unsupportedExtensions {
            #expect(Rules.kind(forExtension: ext) == nil, "\(ext) is not a supported type")
        }
        #expect(Rules.kind(forExtension: "") == nil)
    }

    // MARK: Rules: key and password names

    @Test func keyAndPasswordNamesAreKeyNames() {
        for name in keyNames {
            #expect(Rules.isKeyName(name), "\(name) is a key or password name")
        }
    }

    @Test func ordinaryNamesAreNotKeyNames() {
        for name in ordinaryNames {
            #expect(!Rules.isKeyName(name), "\(name) is an ordinary name")
        }
    }

    // MARK: Rules.admit on real files

    @Test func admitMakesAPhotoValueForEachPhotoExtension() throws {
        try withScratch { folder in
            for ext in photoExtensions {
                let path = folder + "/shot.\(ext)"
                try writeFile(path, pattern(120, seed: 5))
                let admitted = Rules.admit(path: path)
                #expect(admitted != nil, "shot.\(ext) should be admitted")
                #expect(admitted?.kind == "photo", "shot.\(ext) should be a photo")
                #expect(admitted?.path == path)
            }
        }
    }

    @Test func admitNeverAdmitsAKeyOrPasswordNameEvenWithAPhotoExtension() throws {
        try withScratch { folder in
            for name in keyNames {
                let path = folder + "/" + name
                try writeFile(path, pattern(90, seed: 9))
                #expect(Rules.admit(path: path) == nil, "\(name) must never be admitted")
            }
            // The same bytes under an ordinary photo name are admitted, so the refusal is the name.
            let plain = folder + "/ordinary.png"
            try writeFile(plain, pattern(90, seed: 9))
            #expect(Rules.admit(path: plain) != nil)
        }
    }

    @Test func admitRefusesSymlinksDirectoriesMissingAndUnsupportedFiles() throws {
        try withScratch { folder in
            let fm = FileManager.default
            let real = folder + "/real.png"
            try writeFile(real, pattern(80, seed: 3))
            #expect(Rules.admit(path: real) != nil)

            // A symlink to an admitted photo is not admitted.
            let link = folder + "/link.png"
            try fm.createSymbolicLink(atPath: link, withDestinationPath: real)
            #expect(Rules.admit(path: link) == nil)

            // A directory named like a photo is not admitted.
            let directory = folder + "/dir.png"
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            #expect(Rules.admit(path: directory) == nil)

            // A path with nothing at it, and a dangling link.
            #expect(Rules.admit(path: folder + "/missing.png") == nil)
            try fm.createSymbolicLink(atPath: folder + "/dangling.png", withDestinationPath: folder + "/gone.png")
            #expect(Rules.admit(path: folder + "/dangling.png") == nil)

            // Files of types Sesame does not read, and a name with no extension.
            for name in ["raw.dng", "slides.pptx", "sheet.xlsx", "doc.pages", "README", "main.swift", "tool.py", "run.sh"] {
                try writeFile(folder + "/" + name, pattern(50, seed: 4))
                #expect(Rules.admit(path: folder + "/" + name) == nil, "\(name) is not a supported type")
            }
        }
    }

    // MARK: Walker, read mode

    // PDFs (plan-4-t4) and documents (plan-4-t6, amended by the fresh tester: `sub/notes.txt` is now listed, kind "doc", because
    // documents have a reader) are the non-photo kinds with a reader (Walker.readerKinds holds photo, pdf and doc). Audio now has a
    // reader too (plan-5-t2: Walker.readerKinds adds "audio"), so `sub/song.mp3` is listed, kind "audio"; amended by the plan-5-t2
    // tester for that reason only. plan-5-t3, amended by the fresh tester: video has a reader too (Walker.readerKinds adds "video"), so
    // `sub/clip.mp4` is listed, kind "video"; the old line "video has no reader" is gone for that reason only. Code (`sub/main.swift`) is
    // still never listed. The three pins amended in this file (this test, the stat test and the key-name test) change by that one file.
    @Test func readModeWalkReturnsExactlyTheAdmittedPhotoFilesAndThePdfTheDocumentTheAudioAndTheVideo() throws {
        try withTree { tree in
            let walked = try Walker.walk(root: tree.root, mode: .read)
            let paths = walked.map(\.path).sorted()
            #expect(paths == (tree.photoPaths + [tree.path("sub/report.pdf"), tree.path("sub/notes.txt"), tree.path("sub/song.mp3"), tree.path("sub/clip.mp4")]).sorted())
            #expect(Set(paths).count == paths.count, "a file is listed once")
            let notPhotos: Set<String> = [tree.path("sub/report.pdf"), tree.path("sub/notes.txt"), tree.path("sub/song.mp3"), tree.path("sub/clip.mp4")]
            #expect(walked.filter { !notPhotos.contains($0.path) }.allSatisfy { $0.kind == "photo" })
            #expect(walked.first { $0.path == tree.path("sub/report.pdf") }?.kind == "pdf")
            #expect(walked.first { $0.path == tree.path("sub/notes.txt") }?.kind == "doc")
            #expect(walked.first { $0.path == tree.path("sub/song.mp3") }?.kind == "audio")
            #expect(walked.first { $0.path == tree.path("sub/clip.mp4") }?.kind == "video")
            #expect(!paths.contains(tree.path("sub/main.swift")), "code has no reader")
        }
    }

    @Test func eachWalkedEntryCarriesInodeMtimeNsAndSizeEqualToStat() throws {
        try withTree { tree in
            let walked = try Walker.walk(root: tree.root, mode: .read)
            #expect(walked.count == tree.photos.count + 4, "the photos, sub/report.pdf, sub/notes.txt, sub/song.mp3 (audio, plan-5-t2) and sub/clip.mp4 (video, plan-5-t3)")
            for entry in walked {
                let expected = try #require(lstatValues(entry.path), "\(entry.path) can be statted")
                #expect(i64(entry.inode) == expected.inode, "inode of \(entry.path)")
                #expect(i64(entry.mtimeNs) == expected.mtimeNs, "mtime_ns of \(entry.path)")
                #expect(i64(entry.size) == expected.size, "size of \(entry.path)")
            }
            // The times the test set carry nonzero nanoseconds, so whole seconds would differ.
            #expect(walked.allSatisfy { i64($0.mtimeNs) % 1_000_000_000 != 0 })
        }
    }

    @Test func eachPhotoOfTheTreeIsReportedWithItsOwnStatNotAnotherFilesValues() throws {
        try withTree { tree in
            let walked = try Walker.walk(root: tree.root, mode: .read)
            let byPath = Dictionary(uniqueKeysWithValues: walked.map { ($0.path, $0) })
            for relative in tree.photos {
                let path = tree.path(relative)
                let entry = try #require(byPath[path], "\(relative) is walked")
                let expected = try #require(lstatValues(path))
                #expect(i64(entry.inode) == expected.inode)
                #expect(i64(entry.mtimeNs) == expected.mtimeNs)
                #expect(i64(entry.size) == expected.size)
            }
            let inodes = Set(walked.map { i64($0.inode) })
            #expect(inodes.count == walked.count, "ten different files have ten different inodes")
        }
    }

    @Test func aWalkListsNoSymlinkNoDirectoryAndNothingReachedThroughALink() throws {
        try withTree { tree in
            let walked = try Walker.walk(root: tree.root, mode: .read)
            for entry in walked {
                let values = try #require(lstatValues(entry.path))
                #expect(values.isRegular, "\(entry.path) must be a regular file")
                #expect(!values.isLink, "\(entry.path) must not be a symlink")
                #expect(!values.isDirectory, "\(entry.path) must not be a directory")
                #expect(!entry.path.hasPrefix(tree.root + "/link-dir/"), "walked through a link: \(entry.path)")
                #expect(!entry.path.hasPrefix(tree.root + "/link-outdir/"), "walked through a link: \(entry.path)")
                #expect(!entry.path.hasPrefix(tree.outside), "left the tree: \(entry.path)")
            }
            for relative in tree.links + tree.directories {
                #expect(!walked.contains { $0.path == tree.path(relative) }, "\(relative) must not be listed")
            }
        }
    }

    @Test func aWalkNeverListsKeyNamedPhotosOrNonPhotoFilesExceptPdfsDocumentsAudioAndVideoTheNonPhotoKindsWithAReader() throws {
        try withTree { tree in
            let walked = Set(try Walker.walk(root: tree.root, mode: .read).map(\.path))
            #expect(walked.contains(tree.path("sub/report.pdf")), "sub/report.pdf must be listed: PDFs have a reader")
            #expect(walked.contains(tree.path("sub/notes.txt")), "sub/notes.txt must be listed: documents have a reader")
            #expect(walked.contains(tree.path("sub/song.mp3")), "sub/song.mp3 must be listed: audio has a reader since plan-5-t2")
            #expect(walked.contains(tree.path("sub/clip.mp4")), "sub/clip.mp4 must be listed: video has a reader since plan-5-t3")
            let withReader: Set<String> = ["sub/report.pdf", "sub/notes.txt", "sub/song.mp3", "sub/clip.mp4"]
            for relative in tree.others where !withReader.contains(relative) {
                #expect(!walked.contains(tree.path(relative)), "\(relative) must not be listed")
            }
        }
    }

    @Test func aWalkLeavesEveryFileExactlyAsItWas() throws {
        try withTree { tree in
            let everything = tree.photos + tree.others
            let before = everything.map { lstatValues(tree.path($0)) }
            _ = try Walker.walk(root: tree.root, mode: .read)
            let after = everything.map { lstatValues(tree.path($0)) }
            #expect(before == after)
            #expect(before.allSatisfy { $0 != nil })
        }
    }

    @Test func aWalkOfAnEmptyFolderReturnsNothing() throws {
        try withScratch { folder in
            let walked = try Walker.walk(root: folder, mode: .read)
            #expect(walked.isEmpty)
        }
    }

    // MARK: FileGate

    @Test func fileGateReturnsTheBytesOfAnAdmittedRegularFile() throws {
        try withScratch { folder in
            let path = folder + "/big.png"
            let content = pattern(2_000_003, seed: 17)
            try writeFile(path, content)
            let admitted = try #require(Rules.admit(path: path))
            let read = try FileGate.read(admitted)
            #expect(read.count == content.count)
            #expect(read == content)
        }
    }

    @Test func fileGateReturnsTheBytesOfAOneByteFile() throws {
        try withScratch { folder in
            let small = folder + "/small.jpg"
            try writeFile(small, Data("x".utf8))
            let admitted = try #require(Rules.admit(path: small))
            let read = try FileGate.read(admitted)
            #expect(read == Data("x".utf8))
        }
    }

    @Test func fileGateRefusesAPathThatBecameASymlinkAfterItWasAdmitted() throws {
        try withScratch { folder in
            let fm = FileManager.default
            let path = folder + "/swapped.png"
            let secret = folder + "/secret.png"
            try writeFile(path, pattern(100, seed: 1))
            try writeFile(secret, Data("SECRET-NOT-TO-BE-READ".utf8))
            let admitted = try #require(Rules.admit(path: path))

            try fm.removeItem(atPath: path)
            try fm.createSymbolicLink(atPath: path, withDestinationPath: secret)

            #expect(throws: (any Error).self) { try FileGate.read(admitted) }
        }
    }

    @Test func fileGateRefusesAPathThatBecameADirectoryAfterItWasAdmitted() throws {
        try withScratch { folder in
            let fm = FileManager.default
            let path = folder + "/swapped.png"
            try writeFile(path, pattern(100, seed: 2))
            let admitted = try #require(Rules.admit(path: path))

            try fm.removeItem(atPath: path)
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)

            #expect(throws: (any Error).self) { try FileGate.read(admitted) }
        }
    }

    @Test func fileGateRefusesAFileThatIsGoneAfterItWasAdmitted() throws {
        try withScratch { folder in
            let path = folder + "/vanished.png"
            try writeFile(path, pattern(100, seed: 6))
            let admitted = try #require(Rules.admit(path: path))
            try FileManager.default.removeItem(atPath: path)

            #expect(throws: (any Error).self) { try FileGate.read(admitted) }
        }
    }
}
