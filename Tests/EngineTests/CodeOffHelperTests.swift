import Foundation
import Testing
import SesameEngine

private let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]

private let codeNames = ["tool.py", "tool.swift", "run.sh", "main.go", "app.ts"]

@Suite("CodeOffHelperTests", .serialized)
struct CodeOffHelperTests {

    @Test func aHelperRunOverATickedPlainFolderAndATickedRepoNeverQueuesReadsOrStoresACodeFile() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try tree.initRepo("repo")
        for place in ["plain", "repo"] {
            try tree.photo("\(place)/one.png")
            try tree.photo("\(place)/two.jpg")
            try tree.text("\(place)/note.txt", "a short note about the \(place) folder")
            for name in codeNames { try tree.text("\(place)/\(name)", "print(1)\n") }
        }
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: tree.path("plain")).sorted()
        #expect(onDisk.count == 8, "setup: the plain folder holds 3 files with a reader and 5 code files, holds \(onDisk)")

        let helper = try rxStartHelper(home: tree.home)
        defer { helper.stop() }
        helper.send(rxFoldersLine([(tree.path("plain"), true), (tree.path("repo"), true)]))
        let settled = rxSettle(helper, home: tree.home, expectRows: 6)
        #expect(settled.settled, "\(settled.note)")
        helper.closeStdin()
        let exit = helper.waitForExit(timeout: 60)
        #expect(exit?.status == 0, "the helper should exit 0 when its stdin ends; stderr: \(helper.errors)")

        let db = try #require(AtDB(path: rxIndexFile(home: tree.home)), "no index was written")
        let rows = try #require(db.rows("select path, status, kind from files"), "the files table cannot be read")
        let wanted = Set(["plain", "repo"].flatMap { place in
            ["one.png", "two.jpg", "note.txt"].map { rxResolved(tree.path("\(place)/\($0)")) }
        })
        let got = Set(rows.compactMap { $0[0] }.map(rxResolved))
        #expect(got == wanted, "rows: missing \(wanted.subtracting(got).map { ($0 as NSString).lastPathComponent }.sorted()), unexpected \(got.subtracting(wanted).sorted())")
        #expect(rows.count == 6, "\(rows.count) rows, want 6")
        for row in rows {
            #expect(row[1] == "done", "\(row[0] ?? "?") is \(row[1] ?? "nil"), want done")
        }
        #expect(db.int("select count(*) from files where kind = 'code'") == 0, "a row of kind code was written")
        let codePaths = rows.compactMap { $0[0] }.filter { codeExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        #expect(codePaths.isEmpty, "rows with a code extension: \(codePaths)")
        #expect(db.int("select count(*) from passages where source = 'code'") == 0, "a code passage was written")
        #expect(db.integrity() == "ok", "PRAGMA integrity_check gave \(db.integrity())")

        let support = URL(fileURLWithPath: tree.home).appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
        let log = (try? String(contentsOf: sesameLogURL(support, "index.log"), encoding: .utf8)) ?? ""
        for word in [tree.root, (tree.root as NSString).lastPathComponent, "note.txt", "tool.py"] {
            #expect(!log.contains(word), "index.log holds \"\(word)\"")
        }
    }
}
