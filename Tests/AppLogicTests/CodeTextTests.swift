import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let ctOffText = "Code search is off. Turn it on in Settings, File types."
private let ctNoFoldersText = "No code folders are ticked."
private let ctNoMatchesHint = "Describe what is in the file, or type part of its exact name or text."
private let ctKinds: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true]

private func ctDot(_ a: [Float], _ b: [Float]) -> Double {
    var sum = 0.0
    for index in 0..<min(a.count, b.count) { sum += Double(a[index]) * Double(b[index]) }
    return sum
}

private func ctUnit(orthogonalTo q: [Float], axis k: Int) -> [Float] {
    var v = [Double](repeating: 0, count: q.count)
    v[k] = 1
    let along = Double(q[k])
    for i in 0..<q.count { v[i] -= along * Double(q[i]) }
    let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { Float($0 / length) }
}

private func ctVector(_ q: [Float], dot a: Float, axis k: Int) -> [Float] {
    let u = ctUnit(orthogonalTo: q, axis: k)
    let side = (1 - a * a).squareRoot()
    return (0..<q.count).map { a * q[$0] + side * u[$0] }
}

private let ctSunrise = "/photos/a/Sunrise.jpg"
private let ctTerms = "/photos/b/Terms.pdf"
private let ctBoard = "/photos/a/Board.jpg"
private let ctLedger = "/photos/b/Ledger.pdf"
private let ctPier = "/photos/a/Pier.jpg"
private let ctCodeFile = "/code/src/Retry.swift"

private struct CTRow {
    let path: String
    let dot: Double
    let passage: Int64
    var hit: SPHit { SPHit(path: path, passageID: passage) }
}

private struct CTFixture {
    let docs: [CTRow]
    let board: CTRow
    let code: CTRow

    var rankedList: [SPHit] {
        [board.hit] + docs.filter { $0.path != board.path }.sorted { $0.dot > $1.dot }.map(\.hit)
    }
}

private func ctWriteIndex(for text: String) throws -> CTFixture {
    let query = try FakeEmbedder().embed(text, role: .query)
    let store = try IndexStore()
    defer { store.close() }
    var inode: Int64 = 100
    var axis = 100

    func add(_ path: String, kind: String, dot: Float, body: String) throws -> CTRow {
        inode += 1
        axis += 1
        let isCode = kind == "code"
        let file = try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                     inode: inode, device: 16_777_220, status: "done")
        _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                 name: URL(fileURLWithPath: path).lastPathComponent, body: "")
        let vector = ctVector(query, dot: dot, axis: axis)
        let source = isCode ? "code" : kind == "photo" ? "image" : "page"
        let id = try store.addPassage(fileID: file, source: source, start: isCode ? 1 : 0, end: isCode ? 20 : 0,
                                      modality: isCode ? "text" : "image", vector: vector, name: "", body: body)
        return CTRow(path: path, dot: ctDot(vector, query), passage: id)
    }

    let code = try add(ctCodeFile, kind: "code", dot: 0.95, body: text)
    let sunrise = try add(ctSunrise, kind: "photo", dot: 0.90, body: "a calm sunrise over water")
    let terms = try add(ctTerms, kind: "pdf", dot: 0.80, body: "")
    let board = try add(ctBoard, kind: "photo", dot: 0.70, body: "notes: \(text)")
    let ledger = try add(ctLedger, kind: "pdf", dot: 0.60, body: "")
    let pier = try add(ctPier, kind: "photo", dot: 0.50, body: "boats retry a failed call at the pier")
    for k in 1...100 {
        _ = try add(String(format: "/photos/noise/n%03d.pdf", k), kind: "pdf", dot: 0, body: "")
    }
    return CTFixture(docs: [sunrise, terms, board, ledger, pier], board: board, code: code)
}

private func ctVisible(switchOn: Bool, codeTicked: Bool) -> Visible {
    Visible(folders: [Settings.Folder(path: "/photos", code: false, reading: true),
                      Settings.Folder(path: "/code", code: codeTicked, reading: true)],
            codeSearchOn: switchOn, kindsOn: ctKinds)
}

private func ctSettings(switchOn: Bool, codeTicked: Bool) -> Settings {
    var settings = Settings()
    settings.startPressed = true
    settings.codeSearchOn = switchOn
    settings.kindsOn = ctKinds
    settings.folders = [Settings.Folder(path: "/photos", code: false, reading: true),
                        Settings.Folder(path: "/code", code: codeTicked, reading: true)]
    return settings
}

@MainActor
private func ctWithPipeline(text: String, switchOn: Bool = true, codeTicked: Bool = true,
                            _ body: @MainActor (SPHarness, CTFixture) async throws -> Void) async throws {
    try await spWithHome { _ in
        try SettingsFile().write(ctSettings(switchOn: switchOn, codeTicked: codeTicked))
        let fixture = try ctWriteIndex(for: text)
        let harness = SPHarness(fixture: nil, visible: ctVisible(switchOn: switchOn, codeTicked: codeTicked))
        defer { harness.close() }
        try await body(harness, fixture)
    }
}

private let ctAnsweringHelper = #"""
#!/bin/sh
dir=$(dirname "$0")
while IFS= read -r line; do
  case "$line" in
    *'"cmd":"embed"'*)
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      printf '{"event":"vector","id":%s,"ms":1,"vec":%s}\n' "$id" "$(cat "$dir/query-vector.json")"
      ;;
    *'"cmd":"preview"'*)
      ticket=$(printf '%s' "$line" | sed -n 's/.*"ticket":\([0-9]*\).*/\1/p')
      file=$(printf '%s' "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')
      printf '{"event":"preview","ticket":%s,"status":"ok","png":null,"name":"%s","kind":"photo","size":1234,"mtime":1700000000}\n' "$ticket" "$(basename "$file")"
      ;;
  esac
done
"""#

@MainActor
private func ctWithPanel(queryAxis: Int, photoCount: Int,
                         _ body: @MainActor (Panel) async throws -> Void) async throws {
    _ = NSApplication.shared
    try await spWithHome { home in
        var settings = Settings()
        settings.startPressed = true
        settings.folders = [Settings.Folder(path: "/photos", code: false, reading: true)]
        try SettingsFile().write(settings)
        let store = try IndexStore()
        for position in 0..<photoCount {
            let file = try store.addFile(path: "/photos/p\(position).jpg", kind: "photo", size: 1000,
                                         mtimeNs: 1_700_000_000_000_000_000, inode: Int64(500 + position),
                                         device: 16_777_220, status: "done")
            _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                                     vector: nil, name: "p\(position).jpg", body: "")
            var vector = [Float](repeating: 0, count: 768)
            vector[position] = 1
            _ = try store.addPassage(fileID: file, source: "image", start: 0, end: 0, modality: "image",
                                     vector: vector, name: "", body: "harbour")
        }
        store.close()
        let helper = home.appendingPathComponent("answering-helper")
        try ctAnsweringHelper.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let vector = "[" + (0..<768).map { $0 == queryAxis ? "1" : "0" }.joined(separator: ",") + "]"
        try vector.write(to: home.appendingPathComponent("query-vector.json"), atomically: true, encoding: .utf8)
        let panel = Panel()
        panel.attach(helper: HelperClient(helper: helper, textModel: home, mmModel: home))
        _ = panel.makeFirstResponder(panel.queryBox.field)
        try await body(panel)
    }
}

@MainActor
private func ctAllTexts(_ panel: Panel) -> [String] {
    guard let root = panel.contentView else { return [] }
    return prViews(root).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
}

@MainActor
private func ctNoticeViews(_ panel: Panel) -> [NSView] {
    guard let root = panel.contentView else { return [] }
    return prViews(root).filter { $0.accessibilityIdentifier() == "CodeNotice" }
}

extension ModelDownloadTests {
    @Suite("CodeTextTests", .serialized)
    struct CodeTextTests {

        @MainActor
        @Test(arguments: ["code: retry a failed call", "code:retry a failed call"])
        func aCodeTextGoesWholeToTheEmbedderAndToTheExactWordMatchAsPlainText(typed: String) async throws {
            try await ctWithPipeline(text: typed) { h, fixture in
                let ticket = h.submit(typed)
                let arrived = await spEventually { h.log.rankedList(ticket) != nil }
                #expect(arrived, "\"\(typed)\": no ranked list arrived; events: \(h.log.events)")
                #expect(h.embedder.texts == [typed], "\"\(typed)\": embedded \(h.embedder.texts)")
                #expect(h.embedder.roles == [.query], "roles: \(h.embedder.roles)")
                #expect(h.log.keywordList(ticket) == [fixture.board.hit],
                        "\"\(typed)\": keyword list \(String(describing: h.log.keywordList(ticket)?.map(\.path))), expected only Board.jpg")
                let exact = h.search.exactHits(text: typed, visible: h.visible.value, scope: .plain)
                    .map { SPHit(path: $0.path, passageID: $0.passageID) }
                #expect(h.log.keywordList(ticket) == exact, "the keyword list is not the plain exact-word match of the typed text")
                #expect(h.log.rankedList(ticket) == fixture.rankedList,
                        "got \(String(describing: h.log.rankedList(ticket)?.map(\.path))), expected \(fixture.rankedList.map(\.path))")
                #expect(h.log.events == ["keyword:\(ticket)", "ranked:\(ticket)"], "events: \(h.log.events)")
            }
        }

        @MainActor
        @Test func aSixHundredCharacterCodeTextIsCutToItsFirstFiveHundredWithThePrefixKept() async throws {
            let typed = "code: " + String(repeating: "x", count: 594)
            let expected = "code: " + String(repeating: "x", count: 494)
            #expect(typed.count == 600 && expected.count == 500, "control: the lengths")
            try await ctWithPipeline(text: expected) { h, _ in
                let ticket = h.submit(typed)
                let arrived = await spEventually { h.log.rankedList(ticket) != nil }
                #expect(arrived, "no ranked list arrived; events: \(h.log.events)")
                let embedded = h.embedder.texts
                #expect(embedded == [expected], "the embedder got \(embedded.map(\.count)) characters, expected the first 500 with the prefix kept")
            }
        }

        @MainActor
        @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
        func anOldCodeRowIsNeverListedWhateverTheOldSettingsSay(_ state: (Bool, Bool)) async throws {
            let typed = "code: retry a failed call"
            try await ctWithPipeline(text: typed, switchOn: state.0, codeTicked: state.1) { h, fixture in
                let ticket = h.submit(typed)
                let arrived = await spEventually { h.log.rankedList(ticket) != nil }
                #expect(arrived, "switch \(state.0) ticked \(state.1): no ranked list; events: \(h.log.events)")
                let ranked = h.log.rankedList(ticket) ?? []
                let keyword = h.log.keywordList(ticket) ?? []
                #expect(!ranked.contains { $0.path == ctCodeFile } && !keyword.contains { $0.path == ctCodeFile },
                        "switch \(state.0) ticked \(state.1): the code row is listed: ranked \(ranked.map(\.path)), keyword \(keyword.map(\.path))")
                #expect(keyword == [fixture.board.hit], "keyword list \(keyword.map(\.path)), expected the document alone")
                #expect(ranked == fixture.rankedList, "ranked \(ranked.map(\.path)), expected \(fixture.rankedList.map(\.path))")
            }
        }

        @MainActor
        @Test func aCodeSearchShowsItsRowsAndNoCodeNoticeNorItsTexts() async throws {
            let photos = (0..<8).map { PRPhoto(name: "p\($0).jpg", words: "harbour") }
            try await prWithPanel(photos: photos, answering: true) { panel in
                panel.pressEscape()
                await spWait(0.1)
                await prType("code: x", into: panel, pauseMilliseconds: 40)
                let listed = await spEventually(timeout: 15) { prShownTexts(panel.contentView!).contains { $0.contains("p0.jpg") } }
                let shown = prShownTexts(panel.contentView!)
                let tree = ctAllTexts(panel)
                #expect(listed, "control: the ranked photo never showed; the panel shows \(shown)")
                #expect(ctNoticeViews(panel).isEmpty, "a CodeNotice view is in the tree")
                #expect(!tree.contains { $0.contains(ctOffText) || $0.contains(ctNoFoldersText) }, "a code notice text is in the tree: \(tree)")
            }
        }

        @MainActor
        @Test(arguments: ["qwv zzkx lorp mnb", "code: qwv zzkx lorp mnb"])
        func aSearchThatFindsNothingShowsNoMatchesWithItsHintAndNoNoticeOrEmptyHint(typed: String) async throws {
            try await ctWithPanel(queryAxis: 700, photoCount: 8) { panel in
                panel.pressEscape()
                await spWait(0.1)
                await prType(typed, into: panel, pauseMilliseconds: 40)
                let arrived = await spEventually(timeout: 15) { prShownTexts(panel.contentView!).contains("No matches") }
                let shown = prShownTexts(panel.contentView!)
                let tree = ctAllTexts(panel)
                #expect(arrived, "\"\(typed)\": No matches never showed; the panel shows \(shown)")
                #expect(shown.contains(ctNoMatchesHint), "\"\(typed)\": the one-line suggestion is missing: \(shown)")
                #expect(ctNoticeViews(panel).isEmpty, "\"\(typed)\": a CodeNotice view is in the tree")
                #expect(!tree.contains { $0.contains(ctOffText) || $0.contains(ctNoFoldersText) }, "\"\(typed)\": a code notice text is in the tree: \(tree)")
                #expect(!shown.contains("Describe what you want, or type part of a name or text."), "\"\(typed)\": the empty-box hint is shown: \(shown)")
                #expect(!shown.contains { $0.contains("p0.jpg") || $0.contains("p1.jpg") }, "\"\(typed)\": a row is listed under No matches: \(shown)")
            }
        }

        @MainActor
        @Test func aBareCodeColonIsOnePlainWordAndBehavesLikeAnyOtherOneWordSearchWithNothingExact() async throws {
            func settle(_ typed: String) async throws -> (rows: [String], shown: [String], tree: [String], notices: Int) {
                var result: (rows: [String], shown: [String], tree: [String], notices: Int) = ([], [], [], 0)
                try await ctWithPanel(queryAxis: 700, photoCount: 8) { panel in
                    panel.pressEscape()
                    await spWait(0.1)
                    await prType(typed, into: panel, pauseMilliseconds: 40)
                    _ = await spEventually(timeout: 15) { prShownTexts(panel.contentView!).contains { $0.contains(".jpg") } }
                    await spWait(0.5)
                    let shown = prShownTexts(panel.contentView!)
                    result = (shown.filter { $0.contains(".jpg") }, shown, ctAllTexts(panel), ctNoticeViews(panel).count)
                }
                return result
            }
            let word = try await settle("qwv")
            let bare = try await settle("code:")
            #expect(!bare.rows.isEmpty, "\"code:\": the one-word fallback listed no rows: \(bare.shown)")
            #expect(bare.rows == word.rows, "\"code:\" rows \(bare.rows) differ from \"qwv\" rows \(word.rows)")
            #expect(!bare.shown.contains(ctNoMatchesHint), "\"code:\": the no-matches hint is shown: \(bare.shown)")
            #expect(!bare.shown.contains("No matches"), "\"code:\": No matches is shown: \(bare.shown)")
            #expect(!bare.shown.contains("Describe what you want, or type part of a name or text."), "\"code:\": the empty-box hint is shown: \(bare.shown)")
            #expect(bare.notices == 0, "\"code:\": a CodeNotice view is in the tree")
            #expect(!bare.tree.contains { $0.contains(ctOffText) || $0.contains(ctNoFoldersText) }, "\"code:\": a code notice text is in the tree: \(bare.tree)")
        }

        @MainActor
        @Test(arguments: ["", "VS Code", "Zed", "Cursor"])
        func enterOnACodeHitOpensTheFileInTheDefaultAppWithNoLineAndNoScript(_ chosen: String) {
            let path = "/Users/test/Developer/api-client/retry.swift"
            let fake = OMFakeScripting()
            Opener.open(kind: "code", path: path, spot: 12, chosen: chosen, using: fake)
            #expect(fake.opens == [URL(fileURLWithPath: path)], "chosen \"\(chosen)\": the seam saw opens \(fake.opens)")
            #expect(fake.scripts.isEmpty, "chosen \"\(chosen)\": a script ran: \(fake.scripts)")
            #expect(!fake.opens.contains { $0.scheme == "vscode" }, "a vscode URL was opened: \(fake.opens)")
        }

        @MainActor
        @Test(arguments: ["", "VS Code", "Zed"])
        func opensInNamesTheDefaultAppForACodeFileWhateverTheOldSettingsHold(_ chosen: String) async throws {
            try await spWithHome { _ in
                var settings = Settings()
                settings.openWith = Settings.OpenWith(pdf: "", media: "", code: chosen)
                try SettingsFile().write(settings)
                #expect(Opener.opensInText(kind: "code", defaultAppName: "Xcode") == "Opens in Xcode")
                #expect(Opener.opensInText(kind: "code", defaultAppName: "TextEdit") == "Opens in TextEdit")
            }
        }

        @MainActor
        @Test func opensInForACodeFileWithNoSettingsFileIsTheDefaultAppToo() async throws {
            try await spWithHome { _ in
                #expect(Opener.opensInText(kind: "code", defaultAppName: "Xcode") == "Opens in Xcode")
            }
        }
    }
}
