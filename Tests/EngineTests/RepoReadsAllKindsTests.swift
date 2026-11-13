import Foundation
import Testing
import SesameEngine

private func scratch() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-repoall-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath().path
}

private func withScratch(_ body: (String) throws -> Void) throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try body(root)
}

private func write(_ path: String, _ text: String = "x") throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func gitInit(_ dir: String, home: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", dir, "init", "-q", "-b", "main"]
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["HOME"] = home
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "setup: git init exited \(process.terminationStatus)")
}

private func fill(_ dir: String) throws {
    for name in ["a.png", "b.txt", "c.pdf", "d.md", "e.py"] { try write(dir + "/" + name) }
}

private func relative(_ paths: [String], under root: String) -> Set<String> {
    Set(paths.map { String($0.dropFirst(root.count + 1)) })
}

@Suite("RepoReadsAllKindsTests", .serialized)
struct RepoReadsAllKindsTests {

    private func buildRepo(_ root: String) throws -> String {
        let repo = root + "/repo"
        try gitInit(repo, home: root)
        try write(repo + "/.gitignore", "ign.txt\n")
        try fill(repo)
        try write(repo + "/ign.txt")
        try write(repo + "/node_modules/x.png")
        try write(repo + "/Pods/y.txt")
        return repo
    }

    @Test func aRepoPickReadsItsPicturePdfAndDocumentsAndNeitherCodeNorIgnoredNorVendored() throws {
        try withScratch { root in
            let repo = try buildRepo(root)
            let want: Set<String> = ["repo/a.png", "repo/b.txt", "repo/c.pdf", "repo/d.md"]
            for tick in [false, true] {
                let result = Walker.scan(root: repo, mode: .read, picks: [HelperFolder(path: repo, code: tick)])
                let got = relative(result.files.map(\.path), under: root)
                #expect(got == want, "pick code \(tick): missing \(want.subtracting(got).sorted()), unexpected \(got.subtracting(want).sorted())")
                #expect(result.unreadable.isEmpty, "pick code \(tick): unreadable \(result.unreadable)")
            }
        }
    }

    @Test func theKindsOfWhatTheRepoReturnsAreTheKindsOfTheirExtensions() throws {
        try withScratch { root in
            let repo = try buildRepo(root)
            let result = Walker.scan(root: repo, mode: .read, picks: [HelperFolder(path: repo, code: false)])
            let kinds = Dictionary(uniqueKeysWithValues: result.files.map { (relative([$0.path], under: root).first ?? "", $0.kind) })
            #expect(kinds == ["repo/a.png": "photo", "repo/b.txt": "doc", "repo/c.pdf": "pdf", "repo/d.md": "doc"], "got \(kinds)")
        }
    }

    @Test func aPickThatIsTheParentOfTheRepoReadsTheSameFour() throws {
        try withScratch { root in
            _ = try buildRepo(root)
            let want: Set<String> = ["repo/a.png", "repo/b.txt", "repo/c.pdf", "repo/d.md"]
            for tick in [false, true] {
                let result = Walker.scan(root: root, mode: .read, picks: [HelperFolder(path: root, code: tick)])
                let got = relative(result.files.map(\.path), under: root)
                #expect(got == want, "parent pick code \(tick): missing \(want.subtracting(got).sorted()), unexpected \(got.subtracting(want).sorted())")
            }
        }
    }

    @Test func aPickThatIsAFolderInsideTheRepoReadsItsPicturePdfAndDocumentsToo() throws {
        try withScratch { root in
            let repo = root + "/repo"
            try gitInit(repo, home: root)
            try fill(repo + "/inner")
            let inner = repo + "/inner"
            let want: Set<String> = ["repo/inner/a.png", "repo/inner/b.txt", "repo/inner/c.pdf", "repo/inner/d.md"]
            for tick in [false, true] {
                let result = Walker.scan(root: inner, mode: .read, picks: [HelperFolder(path: inner, code: tick)])
                let got = relative(result.files.map(\.path), under: root)
                #expect(got == want, "inner pick code \(tick): missing \(want.subtracting(got).sorted()), unexpected \(got.subtracting(want).sorted())")
            }
        }
    }

    @Test func rulesAdmitTheRepoFilesOfEveryKindButCodeWhateverTheTick() throws {
        try withScratch { root in
            let repo = try buildRepo(root)
            for tick in [false, true] {
                let picks = [HelperFolder(path: repo, code: tick)]
                for (name, kind) in [("a.png", "photo"), ("b.txt", "doc"), ("c.pdf", "pdf"), ("d.md", "doc")] {
                    #expect(Rules.admit(path: repo + "/" + name, picks: picks)?.kind == kind, "\(name) in the repo (tick \(tick))")
                }
                #expect(Rules.admit(path: repo + "/e.py", picks: picks) == nil, "e.py is code (tick \(tick))")
                #expect(Rules.admit(path: repo + "/node_modules/x.png", picks: picks) == nil, "vendored (tick \(tick))")
                #expect(Rules.admit(path: repo + "/Pods/y.txt", picks: picks) == nil, "vendored (tick \(tick))")
            }
        }
    }
}
