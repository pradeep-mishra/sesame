import Foundation
import Testing
import SesameEngine

// plan-3 fix round, t17-11, tester: the row paths keep the spelling of the pick (S8.3, S8.5, S7.x). Written from the
// reviewer's round 3 must-fix (reviewer-plan-3-3 report): the walker keeps the spelling of the pick in the paths of the rows
// it returns, so the plain-prefix match of `Visible.allows` on the settings folders keeps working; but every other test
// resolves paths with realpath before comparing, so a change that returned real paths would pass them all. Here nothing is
// resolved: every expected path is the pick's own string plus a relative name, written by hand.
//
// Tree (made with the rig of RepoEdgeCaseTests, same module): <tmp>/t/plain/a.png and <tmp>/t/plain/deep/b.png. No repo.
// The picks, in four spellings of that folder (pick = the string handed to the walker, the helper and the Visible filter):
//   (1) the raw temp spelling (`/var/folders/...` on a Mac whose temp folder is under /var; otherwise a symlink made for the
//       purpose), which differs from its realpath (checked in each test, so a Mac where both are equal fails loudly)
//   (3) a symlink to the folder, with a name of its own
//   (4) the raw spelling with a trailing slash
// What each must give: every row path starts with the pick's spelling (without the trailing slash), has no `//`, equals the
// pick plus the relative name, and is allowed by `Visible` built with that pick as its only ticked folder.
// Through `Walker.scan(root:mode:picks:)` and through the bundled helper alone (SESAME_FAKE_EMBEDDER=1, a temp HOME, no app).

private let rpNames = ["a.png", "deep/b.png"]

private func rpVisible(_ pick: String) -> Visible {
    Visible(folders: [Settings.Folder(path: pick, code: false, reading: true)], codeSearchOn: true,
            kindsOn: ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true])
}

private func rpBuild(_ tree: RXTree) throws {
    try tree.photo("plain/a.png")
    try tree.photo("plain/deep/b.png")
}

/// The raw temp spelling of `<tmp>/t/plain` when it differs from its real path, otherwise a symlink to it.
private func rpOtherSpellingPick(_ tree: RXTree) throws -> String {
    if tree.rawRoot != tree.root { return tree.rawRoot + "/t/plain" }
    return try tree.symlink("alias-of-plain", to: "plain")
}

private func rpScan(_ pick: String) -> [String] {
    Walker.scan(root: pick, mode: .read, picks: [HelperFolder(path: pick, code: false)]).files.map { $0.path }
}

/// The pick's own spelling plus each relative name, with trailing slashes of the pick dropped. Written by hand, never read
/// back from the code under test.
private func rpWant(_ pick: String) -> Set<String> {
    var base = pick
    while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
    return Set(rpNames.map { base + "/" + $0 })
}

private func rpCheck(_ got: [String], pick: String, label: String) {
    let want = rpWant(pick)
    var base = pick
    while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
    #expect(Set(got) == want, "\(label): got \(got.sorted()), want \(want.sorted())")
    #expect(got.count == want.count, "\(label): \(got.count) paths for \(want.count) pictures: \(got.sorted())")
    let visible = rpVisible(pick)
    for path in got {
        #expect(path.hasPrefix(base + "/"), "\(label): \(path) does not start with the pick's spelling \(base)/")
        #expect(!path.contains("//"), "\(label): \(path) holds a double slash")
        #expect(visible.allows(path: path, kind: "photo"),
                "\(label): Visible with the pick \(pick) hides \(path)")
    }
}

private func rpRun(_ tree: RXTree, pick: String) throws -> [String] {
    try rxRun(tree, picks: [pick], expectRows: rpNames.count).names
}

@Suite("RowPathSpellingTests", .serialized)
struct RowPathSpellingTests {

    // MARK: (1) the raw temp spelling (or a symlink) of a folder, which is not its real path

    @Test func theScanOfAPickInTheRawTempSpellingReturnsRowsSpelledWithThePick() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rpBuild(tree)
        let pick = try rpOtherSpellingPick(tree)
        try #require(pick != rxResolved(pick), "setup: the pick \(pick) is already its real path")
        rpCheck(rpScan(pick), pick: pick, label: "scan of \(pick)")
    }

    // MARK: (2) the same through the helper alone

    @Test func theHelperStoresRowsSpelledWithAPickInTheRawTempSpelling() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rpBuild(tree)
        let pick = try rpOtherSpellingPick(tree)
        try #require(pick != rxResolved(pick), "setup: the pick \(pick) is already its real path")
        rpCheck(try rpRun(tree, pick: pick), pick: pick, label: "helper rows for \(pick)")
    }

    // MARK: (3) a lone symlinked pick folder

    @Test func theScanOfALoneSymlinkedPickGivesRowsSpelledWithTheLinkNotItsTarget() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rpBuild(tree)
        let link = try tree.symlink("link-plain", to: "plain")
        try #require(link != rxResolved(link), "setup: the link is its own real path")
        let got = rpScan(link)
        rpCheck(got, pick: link, label: "scan of the link \(link)")
        for path in got {
            #expect(!path.hasPrefix(tree.path("plain") + "/"), "scan of the link: \(path) is spelled with the link's target")
        }
    }

    @Test func theHelperStoresRowsSpelledWithALoneSymlinkedPickNotItsTarget() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rpBuild(tree)
        let link = try tree.symlink("link-plain", to: "plain")
        try #require(link != rxResolved(link), "setup: the link is its own real path")
        let got = try rpRun(tree, pick: link)
        rpCheck(got, pick: link, label: "helper rows for the link \(link)")
        for path in got {
            #expect(!path.hasPrefix(tree.path("plain") + "/"), "helper: \(path) is spelled with the link's target")
        }
    }

    // MARK: (4) a pick with a trailing slash

    @Test func theScanOfAPickWithATrailingSlashGivesRowsWithoutADoubleSlashThatVisibleAllows() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rpBuild(tree)
        let pick = tree.rawRoot + "/t/plain/"
        rpCheck(rpScan(pick), pick: pick, label: "scan of \(pick)")
    }

    @Test func theHelperStoresRowsWithoutADoubleSlashForAPickWithATrailingSlash() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rpBuild(tree)
        let pick = tree.rawRoot + "/t/plain/"
        rpCheck(try rpRun(tree, pick: pick), pick: pick, label: "helper rows for \(pick)")
    }
}
