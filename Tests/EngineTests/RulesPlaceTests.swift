import Foundation
import Testing
import SesameEngine

// plan-3-t15, tester step: `Rules.admit(path:picks:)`, the one decision of what may be read from where. Written from the
// entry of plan-3-tasks.md (t15 Tests, Decisions D4 to D8), the spec and the design only; no product source is read.
// Names used, and how they were found: `HelperFolder(path:code:)` and `Admitted` (`.path`, `.kind`) are read the way the
// sealed ProtocolTests, RulesTests and RulesKeyNameCaseTests use them; `Rules.admit(path:picks:)` is the one name the
// entry fixes and the one that does not exist yet.
//
// Every tree is built by the test under $TMPDIR (a folder named `.git` is the repo marker; no `git` is run) and removed
// again. Every expected value is written by hand in the tests below. A control (the same kind of file in a plain place)
// sits beside each refusal, so a refusal is always the place or the name and never the extension or the pick.

private let photoExtensions = ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]

/// One file per kind, with the kind string `Admitted.kind` carries (the strings of the sealed RulesTests).
private let kindFiles: [(name: String, kind: String)] = [
    ("pic.png", "photo"), ("note.txt", "doc"), ("paper.pdf", "pdf"), ("song.wav", "audio"),
    ("clip.mp4", "video"),
]

private let codeFiles = ["tool.py", "a.swift", "b.js", "c.sh", "d.c"]

private let nonPhotoFiles = kindFiles.filter { $0.kind != "photo" }.map(\.name)

private func scratch() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-rules-place-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // /var is a link to /private/var on macOS; hand the code the real path.
    return url.resolvingSymlinksInPath().path
}

private func withScratch(_ body: (String) throws -> Void) throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try body(root)
}

@discardableResult
private func file(_ path: String) throws -> String {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: URL(fileURLWithPath: path))
    return path
}

private func folder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

/// `file` for use inside `#expect(...)`, where a `try` cannot sit; a tree that cannot be built stops the run.
private func made(_ path: String) -> String {
    do {
        return try file(path)
    } catch {
        fatalError("could not build \(path): \(error)")
    }
}

/// The repo marker: an entry named `.git`, a folder by default.
private func repoMarker(_ dir: String, asFile: Bool = false) throws {
    if asFile {
        try file(dir + "/.git")
    } else {
        try folder(dir + "/.git")
    }
}

private func pick(_ path: String, code: Bool = false) -> HelperFolder { HelperFolder(path: path, code: code) }

private func admits(_ path: String, _ picks: [HelperFolder]) -> Bool { Rules.admit(path: path, picks: picks) != nil }

@Suite("RulesPlaceTests")
struct RulesPlaceTests {

    // MARK: a plain photo, and paths no pick holds

    @Test func aPlainPhotoUnderAPickIsAdmittedAsAPhotoForEachPhotoExtension() throws {
        try withScratch { root in
            for ext in photoExtensions {
                let path = try file(root + "/album/shot.\(ext)")
                let admitted = Rules.admit(path: path, picks: [pick(root)])
                #expect(admitted != nil, "shot.\(ext) under a pick should be admitted")
                #expect(admitted?.kind == "photo", "shot.\(ext) should be a photo")
                #expect(admitted?.path == path)
            }
        }
    }

    @Test func aPathUnderNoPickIsNil() throws {
        try withScratch { root in
            let held = try file(root + "/held/a.png")
            let outside = try file(root + "/outside/b.png")
            #expect(admits(held, [pick(root + "/held")]), "control: the held photo is admitted")
            #expect(!admits(outside, [pick(root + "/held")]), "a photo under no pick is nil")
            #expect(!admits(held, []), "no picks at all: nil")
        }
    }

    @Test func aPickThatIsOnlyANamePrefixDoesNotHoldThePath() throws {
        try withScratch { root in
            let path = try file(root + "/Pictures/a.png")
            try folder(root + "/Pic")
            #expect(!admits(path, [pick(root + "/Pic")]), "/x/Pic does not hold /x/Pictures/a.png")
            #expect(!admits(path, [pick(root + "/Pic", code: true)]), "a ticked name-prefix pick holds nothing either")
            #expect(admits(path, [pick(root + "/Pictures")]), "control: the real pick holds it")
            let sibling = try file(root + "/Pictures2/b.png")
            #expect(!admits(sibling, [pick(root + "/Pictures")]), "/x/Pictures does not hold /x/Pictures2/b.png")
            #expect(admits(sibling, [pick(root + "/Pictures"), pick(root + "/Pictures2")]))
        }
    }

    // MARK: hidden folders, Caches, .app bundles

    @Test func aFileInAHiddenFolderBelowThePickIsNilForEveryKind() throws {
        try withScratch { root in
            let picks = [pick(root, code: true)]
            for hidden in [".ssh", ".config", ".cache", ".hidden-pics"] {
                for entry in kindFiles {
                    let path = try file(root + "/\(hidden)/\(entry.name)")
                    #expect(!admits(path, picks), "\(hidden)/\(entry.name) is in a hidden folder")
                }
                let deep = try file(root + "/plain/\(hidden)/deeper/pic.png")
                #expect(!admits(deep, picks), "plain/\(hidden)/deeper/pic.png is below a hidden folder")
            }
            for entry in kindFiles {
                #expect(admits(made(root + "/plain/\(entry.name)"), picks), "control: plain/\(entry.name) is admitted")
            }
        }
    }

    @Test func aHiddenFileInAPlainFolderIsNotExcludedOnlyHiddenFoldersAre() throws {
        try withScratch { root in
            let path = try file(root + "/plain/.snapshot.png")
            #expect(admits(path, [pick(root)]), "D6: hidden files are not excluded, only hidden folders")
        }
    }

    @Test func aFileInCachesBelowThePickIsNilForEveryKind() throws {
        try withScratch { root in
            let picks = [pick(root, code: true)]
            for entry in kindFiles {
                #expect(!admits(made(root + "/Caches/\(entry.name)"), picks), "Caches/\(entry.name)")
                #expect(!admits(made(root + "/app/Caches/deeper/\(entry.name)"), picks), "app/Caches/deeper/\(entry.name)")
            }
            // The name is exact: folders that only contain or start with it are ordinary.
            for ordinary in ["Caches2", "MyCaches", "Cache"] {
                #expect(admits(made(root + "/\(ordinary)/pic.png"), picks), "\(ordinary)/pic.png is an ordinary folder")
            }
        }
    }

    @Test func aFileInsideAnAppBundleBelowThePickIsNilForEveryKindWhateverTheLetterCase() throws {
        try withScratch { root in
            let picks = [pick(root, code: true)]
            for bundle in ["Sample.app", "Sample.APP", "Sample.App", "sample.aPp"] {
                for entry in kindFiles {
                    let path = try file(root + "/\(bundle)/Contents/Resources/\(entry.name)")
                    #expect(!admits(path, picks), "\(bundle)/Contents/Resources/\(entry.name) is inside an app bundle")
                }
            }
            // A folder that only has `app` in its name is not a bundle.
            for ordinary in ["myapp", "Sample.application", "app", "Sample.app.old"] {
                #expect(admits(made(root + "/\(ordinary)/pic.png"), picks), "\(ordinary)/pic.png is not in a bundle")
            }
        }
    }

    @Test func aHiddenCachesOrAppNameAboveThePickDoesNotCount() throws {
        try withScratch { root in
            let hiddenPick = root + "/.cache/pics"
            let hiddenPhoto = try file(hiddenPick + "/a.png")
            let hiddenCode = try file(hiddenPick + "/b.py")
            #expect(admits(hiddenPhoto, [pick(hiddenPick)]), "the pick is itself /x/.cache/pics: the name above it does not count")
            #expect(!admits(hiddenCode, [pick(hiddenPick, code: true)]), "code is never admitted, even under a ticked pick")
            #expect(!admits(made(hiddenPick + "/.inner/c.png"), [pick(hiddenPick)]), "control: a hidden folder below the pick still counts")

            let cachesPick = root + "/Caches/pics"
            #expect(admits(made(cachesPick + "/a.png"), [pick(cachesPick)]), "Caches above the pick does not count")
            let appPick = root + "/Big.app/pics"
            #expect(admits(made(appPick + "/a.png"), [pick(appPick)]), "an .app above the pick does not count")
        }
    }

    // MARK: key and password names, unsupported types, directories, links, FIFOs, sparse files

    @Test func keyAndPasswordNamesStayNilWithASupportedExtension() throws {
        try withScratch { root in
            let picks = [pick(root, code: true)]
            for name in ["id_rsa.png", ".env.txt", ".env.local.md", ".env.png", "ID_RSA.PNG"] {
                #expect(!admits(made(root + "/keys/" + name), picks), "\(name) is refused because of its name")
            }
            #expect(admits(made(root + "/keys/ordinary.png"), picks), "control: the same folder admits an ordinary photo")
        }
    }

    @Test func anUnsupportedExtensionIsNil() throws {
        try withScratch { root in
            let picks = [pick(root, code: true)]
            for name in ["deck.pptx", "sheet.xlsx", "book.pages", "raw.dng", "README", "server.pem", "vault.kdbx", "archive.zip"] {
                #expect(!admits(made(root + "/unsup/" + name), picks), "\(name) is not a supported type")
            }
            #expect(admits(made(root + "/unsup/ok.png"), picks), "control")
        }
    }

    @Test func aDirectoryNamedLikeAPhotoIsNil() throws {
        try withScratch { root in
            try folder(root + "/dir.png")
            #expect(!admits(root + "/dir.png", [pick(root)]), "a directory is not a file")
            #expect(admits(made(root + "/dir.png/inner.png"), [pick(root)]), "control: a photo inside it is admitted")
        }
    }

    @Test func aSymbolicLinkToAPhotoIsNilAndItsTargetIsAdmittedOnce() throws {
        try withScratch { root in
            let target = try file(root + "/plain/photo.png")
            let link = root + "/plain/link.png"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            #expect(!admits(link, [pick(root)]), "a symbolic link is not admitted")
            #expect(admits(target, [pick(root)]), "control: the target is")
            let dangling = root + "/plain/dangling.png"
            try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: root + "/plain/gone.png")
            #expect(!admits(dangling, [pick(root)]), "a dangling link is not admitted")
        }
    }

    @Test func aFIFONamedLikeAPhotoIsNil() throws {
        try withScratch { root in
            try folder(root + "/plain")
            let fifo = root + "/plain/pipe.png"
            try #require(mkfifo(fifo, 0o600) == 0, "could not make the FIFO")
            #expect(!admits(fifo, [pick(root)]), "a FIFO is not a regular file")
            #expect(admits(made(root + "/plain/real.png"), [pick(root)]), "control")
        }
    }

    @Test func aSparseFileIsNilWithPicksButStillAdmittedByTheNameLevelRule() throws {
        try withScratch { root in
            try folder(root + "/cloud")
            let sparse = root + "/cloud/vacation.jpg"
            let fd = open(sparse, O_CREAT | O_WRONLY, 0o600)
            try #require(fd >= 0, "could not create the sparse file")
            ftruncate(fd, 1_048_576)
            close(fd)
            var info = stat()
            try #require(stat(sparse, &info) == 0)
            guard info.st_size > 0 && info.st_blocks == 0 else {
                print("NOTE sparse stand-in not creatable on this volume (blocks \(info.st_blocks)); test not exercised")
                return
            }
            #expect(!admits(sparse, [pick(root)]), "a file with a size and no blocks is a cloud-only stand-in: nil")
            #expect(!admits(sparse, [pick(root, code: true)]), "a ticked pick changes nothing for it")
            #expect(Rules.admit(path: sparse) != nil, "counts are unchanged: the name-level rule still admits it")
            #expect(admits(made(root + "/cloud/top.png"), [pick(root)]), "control")
        }
    }

    @Test func theNameLevelRuleStaysAsItWasForCountMode() throws {
        try withScratch { root in
            // Count mode keeps names, sizes and types only (D4): places are not looked at, key names still are.
            for path in [
                root + "/.ssh/a.png", root + "/Caches/b.png", root + "/Sample.app/c.png",
                root + "/node_modules/d.png", root + "/plain/e.png",
            ] {
                #expect(Rules.admit(path: made(path)) != nil, "\(path) is admitted at the name level")
            }
            #expect(Rules.admit(path: made(root + "/keys/id_rsa.png")) == nil)
            #expect(Rules.admit(path: made(root + "/keys/raw.dng")) == nil)
        }
    }

    // MARK: repos

    @Test func aFolderIsARepoWhenItHoldsAnEntryNamedDotGitAtOrBelowThePickRoot() throws {
        try withScratch { root in
            let picks = [pick(root)]
            // At the pick root, as a folder.
            try repoMarker(root + "/atroot")
            #expect(admits(made(root + "/atroot/notes.txt"), [pick(root + "/atroot")]), "repo at the pick root: a document is admitted")
            #expect(admits(made(root + "/atroot/logo.png"), [pick(root + "/atroot")]), "a photo in it is admitted")
            // Below the pick root, as a folder and as a file (a worktree or submodule).
            try repoMarker(root + "/below/proj")
            try repoMarker(root + "/below/wt", asFile: true)
            #expect(admits(made(root + "/below/proj/notes.txt"), picks), "repo below the pick root (.git folder): a document is admitted")
            #expect(admits(made(root + "/below/wt/notes.txt"), picks), "repo below the pick root (.git file): a document is admitted")
            #expect(!admits(made(root + "/below/proj/node_modules/logo.png"), picks), "and it is a repo for the vendored names")
            // Beside it, outside any repo: the same files are admitted.
            #expect(admits(made(root + "/below/loose/notes.txt"), picks), "control: no repo, a document is admitted")
            #expect(admits(made(root + "/below/loose/node_modules/logo.png"), picks), "control: no repo, node_modules is not vendored")
        }
    }

    @Test func aPickThatLiesInsideARepoIsNotTreatedAsOne() throws {
        try withScratch { root in
            try repoMarker(root)
            let inner = root + "/pics"
            #expect(admits(made(inner + "/notes.txt"), [pick(inner)]), "D5: we do not look above the pick, so no repo")
            #expect(admits(made(inner + "/node_modules/logo.png"), [pick(inner)]), "and no vendored name counts")
        }
    }

    @Test func aNestedRepoKeepsItsOwnMarkerButNeverEscapesTheOuterReposVendoredNames() throws {
        try withScratch { root in
            let picks = [pick(root)]
            try repoMarker(root)                      // outer repo at the pick root
            try repoMarker(root + "/vendor/lib")      // inner repo inside a vendored folder
            // The outer repo covers `vendor`: a nested repo under a vendored name is vendored too.
            #expect(!admits(made(root + "/vendor/lib/logo.png"), picks), "outer repo covers vendor: a nested repo under a vendored name is vendored too")
            // Measured from the inner repo `node_modules` lies between it and the file: nil.
            #expect(!admits(made(root + "/vendor/lib/node_modules/logo.png"), picks), "node_modules is between the nearest repo and the file")
            #expect(!admits(made(root + "/vendor/lib/notes.txt"), picks), "a document under a vendored name is nil")
            // The outer repo still covers what the inner one does not: `vendor` directly under it is vendored.
            #expect(!admits(made(root + "/vendor/plain/logo.png"), picks), "outer repo: vendor between it and the file")
            #expect(admits(made(root + "/src/logo.png"), picks), "control: a plain photo in the outer repo")
        }
    }

    @Test func aVendoredNameAboveTheRepoMarkerDoesNotCount() throws {
        try withScratch { root in
            try repoMarker(root + "/node_modules/proj")
            #expect(admits(made(root + "/node_modules/proj/logo.png"), [pick(root)]), "nothing vendored between the repo and the file")
            #expect(!admits(made(root + "/node_modules/proj/dist/logo.png"), [pick(root)]), "dist is between the repo and the file")
        }
    }

    // MARK: vendored folders

    @Test func insideARepoTheVendoredNamesBetweenTheRepoAndTheFileMakeItNilForEveryKind() throws {
        try withScratch { root in
            try repoMarker(root)
            for tick in [false, true] {
                let picks = [pick(root, code: tick)]
                for vendored in ["node_modules", "Pods", "build", "dist", "vendor", ".build"] {
                    for name in ["pic.png", "tool.py", "note.txt"] {
                        let path = try file(root + "/\(vendored)/\(name)")
                        #expect(!admits(path, picks), "\(vendored)/\(name) in a repo (ticked \(tick))")
                    }
                    let deep = try file(root + "/src/\(vendored)/a/b/pic.png")
                    #expect(!admits(deep, picks), "src/\(vendored)/a/b/pic.png in a repo (ticked \(tick))")
                }
            }
            // Near names are ordinary.
            for ordinary in ["builds", "node_modules2", "my-vendor", "distro", "Pod"] {
                #expect(admits(made(root + "/\(ordinary)/pic.png"), [pick(root)]), "\(ordinary)/pic.png is not vendored")
            }
        }
    }

    @Test func outsideAnyRepoTheVendoredNamesAreAdmittedExceptDotBuildWhichIsHidden() throws {
        try withScratch { root in
            let picks = [pick(root, code: true)]
            for vendored in ["node_modules", "Pods", "build", "dist", "vendor"] {
                #expect(admits(made(root + "/\(vendored)/pic.png"), picks), "\(vendored)/pic.png outside a repo is admitted")
                #expect(admits(made(root + "/\(vendored)/note.txt"), picks), "\(vendored)/note.txt outside a repo is admitted")
                #expect(!admits(made(root + "/\(vendored)/tool.py"), picks), "\(vendored)/tool.py is code: never admitted")
            }
            #expect(!admits(made(root + "/.build/pic.png"), picks), ".build is a hidden folder wherever it is")
        }
    }

    // MARK: the code tick

    @Test func inARepoEveryKindButCodeIsAdmittedWhateverTheTick() throws {
        try withScratch { root in
            try repoMarker(root)
            for tick in [false, true] {
                let picks = [pick(root, code: tick)]
                for entry in kindFiles {
                    let admitted = Rules.admit(path: try file(root + "/" + entry.name), picks: picks)
                    #expect(admitted != nil, "\(entry.name) in a repo is admitted (ticked \(tick))")
                    #expect(admitted?.kind == entry.kind, "\(entry.name) should be \(entry.kind) (ticked \(tick))")
                }
                for name in codeFiles {
                    #expect(!admits(try file(root + "/" + name), picks), "\(name) in a repo is code: nil (ticked \(tick))")
                }
            }
        }
    }

    @Test func outsideARepoACodeFileIsNeverAdmittedWhateverTheTick() throws {
        try withScratch { root in
            var others: [String] = []
            for name in nonPhotoFiles { others.append(try file(root + "/" + name)) }
            others.append(try file(root + "/pic.png"))
            for name in codeFiles {
                let path = try file(root + "/" + name)
                #expect(!admits(path, [pick(root, code: false)]), "\(name) with the pick not ticked is nil")
                #expect(!admits(path, [pick(root, code: true)]), "\(name) with the pick ticked is nil too")
            }
            for path in others {
                #expect(admits(path, [pick(root, code: false)]), "\((path as NSString).lastPathComponent) is not code: admitted whatever the tick")
                #expect(admits(path, [pick(root, code: true)]), "\((path as NSString).lastPathComponent) is not code: admitted whatever the tick")
            }
        }
    }

    // MARK: overlapping picks

    @Test func overlappingPicksNeverAdmitCodeWhateverTheTicksAndAdmitTheRestInAnyOrder() throws {
        try withScratch { root in
            let outer = root + "/outer"
            let inner = outer + "/inner"
            let innerCode = try file(inner + "/inner.py")
            let outerCode = try file(outer + "/outer.py")
            let innerPhoto = try file(inner + "/inner.png")
            let outerPhoto = try file(outer + "/outer.png")
            let innerDoc = try file(inner + "/inner.txt")

            let table: [(outerOn: Bool, innerOn: Bool)] = [(false, true), (true, false), (false, false), (true, true)]
            for row in table {
                let ordered = [pick(outer, code: row.outerOn), pick(inner, code: row.innerOn)]
                for picks in [ordered, Array(ordered.reversed())] {
                    let label = "outer \(row.outerOn ? "on" : "off"), inner \(row.innerOn ? "on" : "off"), first pick \(picks[0].path == outer ? "outer" : "inner")"
                    #expect(!admits(innerCode, picks), "inner .py is code: \(label)")
                    #expect(!admits(outerCode, picks), "outer-only .py is code: \(label)")
                    #expect(admits(innerPhoto, picks), "inner photo: \(label)")
                    #expect(admits(outerPhoto, picks), "outer photo: \(label)")
                    #expect(admits(innerDoc, picks), "a document outside a repo is admitted whatever the ticks: \(label)")
                }
            }
        }
    }

    @Test func aRepoInsideOverlappingPicksAdmitsItsPhotosAndDocumentsAndNeverItsCode() throws {
        try withScratch { root in
            let outer = root + "/outer"
            let inner = outer + "/inner"
            try repoMarker(inner)
            let innerCode = try file(inner + "/tool.py")
            let innerPhoto = try file(inner + "/pic.png")
            let innerDoc = try file(inner + "/notes.txt")
            let ticks: [(Bool, Bool)] = [(true, false), (false, true), (false, false), (true, true)]
            for (outerOn, innerOn) in ticks {
                let ordered = [pick(outer, code: outerOn), pick(inner, code: innerOn)]
                for picks in [ordered, Array(ordered.reversed())] {
                    #expect(!admits(innerCode, picks), "the repo's code is nil (outer \(outerOn), inner \(innerOn))")
                    #expect(admits(innerPhoto, picks), "the repo's photo is admitted (outer \(outerOn), inner \(innerOn))")
                    #expect(admits(innerDoc, picks), "the repo's document is admitted (outer \(outerOn), inner \(innerOn))")
                }
            }
        }
    }
}
