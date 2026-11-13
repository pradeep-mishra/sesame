import Foundation
import Testing
import SesameEngine

private let codeExtensions = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]

private let keptKinds: [(kind: String, extensions: [String])] = [
    ("photo", ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]),
    ("pdf", ["pdf"]),
    ("doc", ["txt", "md", "rtf", "docx", "html", "odt"]),
    ("audio", ["mp3", "m4a", "wav", "aac", "flac"]),
    ("video", ["mp4", "mov", "m4v"]),
]

private func scratch() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-codeoff-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

private func repoMarker(_ dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
}

private func pick(_ path: String, code: Bool) -> HelperFolder { HelperFolder(path: path, code: code) }

private func relative(_ paths: [String], under root: String) -> Set<String> {
    Set(paths.map { String($0.dropFirst(root.count + 1)) })
}

@Suite("CodeOffTests")
struct CodeOffTests {

    @Test func theFifteenCodeExtensionsHaveNoKind() {
        for ext in codeExtensions {
            #expect(Rules.kind(forExtension: ext) == nil, "\(ext) is code: it must have no kind")
        }
    }

    @Test func theTwentyThreeOtherExtensionsKeepTheirKind() {
        var seen = 0
        for (kind, extensions) in keptKinds {
            for ext in extensions {
                seen += 1
                #expect(Rules.kind(forExtension: ext) == kind, "\(ext) should be \(kind)")
            }
        }
        #expect(seen == 23, "the hand table holds 23 extensions, holds \(seen)")
    }

    @Test func admitByNameGivesNilForCodeFilesAndTheKindForAPhotoAndATxt() throws {
        try withScratch { root in
            for name in ["tool.swift", "tool.py", "tool.sh"] {
                let path = try file(root + "/plain/" + name)
                #expect(Rules.admit(path: path) == nil, "\(name) is code: nil")
            }
            let photo = try file(root + "/plain/shot.png")
            let text = try file(root + "/plain/note.txt")
            #expect(Rules.admit(path: photo)?.kind == "photo")
            #expect(Rules.admit(path: text)?.kind == "doc")
        }
    }

    @Test func admitWithPicksGivesNilForCodeInAPlainFolderATickedFolderAndATickedRepo() throws {
        try withScratch { root in
            try repoMarker(root + "/repo")
            let places: [(label: String, dir: String, picks: [HelperFolder])] = [
                ("plain folder, tick off", root + "/plain", [pick(root + "/plain", code: false)]),
                ("plain folder, tick on", root + "/plain", [pick(root + "/plain", code: true)]),
                ("repo, tick on", root + "/repo", [pick(root + "/repo", code: true)]),
                ("repo, tick off", root + "/repo", [pick(root + "/repo", code: false)]),
            ]
            for place in places {
                for name in ["tool.swift", "tool.py", "tool.sh"] {
                    let path = try file(place.dir + "/" + name)
                    #expect(Rules.admit(path: path, picks: place.picks) == nil, "\(name) in a \(place.label) is code: nil")
                }
                let photo = Rules.admit(path: try file(place.dir + "/shot.png"), picks: place.picks)
                #expect(photo?.kind == "photo", "a .png in a \(place.label) is a photo")
                let text = Rules.admit(path: try file(place.dir + "/note.txt"), picks: place.picks)
                #expect(text?.kind == "doc", "a .txt in a \(place.label) is a doc")
            }
        }
    }

    @Test func aScanInCountModeAndReadModeListsTheOnePhotoAndTheOneTxtAndNoneOfTheFifteenCodeFiles() throws {
        try withScratch { root in
            for ext in codeExtensions { try file(root + "/mixed/code-\(ext).\(ext)") }
            try file(root + "/mixed/shot.png")
            try file(root + "/mixed/note.txt")
            let want: Set<String> = ["mixed/shot.png", "mixed/note.txt"]
            let folder = root + "/mixed"
            let count = Walker.scan(root: folder, mode: .count)
            #expect(relative(count.files.map(\.path), under: root) == want, "count mode: \(count.files.map(\.path).sorted())")
            let read = Walker.scan(root: folder, mode: .read)
            #expect(relative(read.files.map(\.path), under: root) == want, "read mode: \(read.files.map(\.path).sorted())")
            for tick in [false, true] {
                let picks = [pick(folder, code: tick)]
                let countPicked = Walker.scan(root: folder, mode: .count, picks: picks)
                #expect(relative(countPicked.files.map(\.path), under: root) == want, "count mode, tick \(tick)")
                let readPicked = Walker.scan(root: folder, mode: .read, picks: picks)
                #expect(relative(readPicked.files.map(\.path), under: root) == want, "read mode, tick \(tick)")
            }
        }
    }

    @Test func visibleRefusesKindCodeUnderAFolderAndAllowsAPhotoThere() {
        let p = "/Users/test/Developer/proj"
        let visible = Visible(folders: [Settings.Folder(path: p, code: true, reading: true)], codeSearchOn: true, kindsOn: [:])
        for name in ["main.swift", "deep/er/tool.py", "run.sh"] {
            #expect(!visible.allows(path: p + "/" + name, kind: "code"), "\(name): kind code is never allowed")
        }
        #expect(visible.allows(path: p + "/shot.png", kind: "photo"))
        #expect(visible.allows(path: p + "/deep/note.txt", kind: "doc"))
    }

    @Test func theTwoByTwoByTwoTableOfSwitchFolderTickAndKindAgreesWithTheHandWrittenAnswer() {
        let p = "/Users/test/Developer/proj"
        let table: [(switchOn: Bool, tick: Bool, kind: String, shown: Bool)] = [
            (false, false, "code", false), (false, false, "photo", true),
            (false, true, "code", false), (false, true, "photo", true),
            (true, false, "code", false), (true, false, "photo", true),
            (true, true, "code", false), (true, true, "photo", true),
        ]
        for row in table {
            let visible = Visible(folders: [Settings.Folder(path: p, code: row.tick, reading: true)],
                                  codeSearchOn: row.switchOn, kindsOn: [:])
            let path = p + (row.kind == "code" ? "/main.swift" : "/shot.png")
            #expect(visible.allows(path: path, kind: row.kind) == row.shown,
                    "switch \(row.switchOn), tick \(row.tick), kind \(row.kind): should be \(row.shown ? "shown" : "hidden")")
        }
    }
}
