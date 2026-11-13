import Foundation
import Testing
import SesameEngine

private let root = "/Users/test/Developer"
private let noCodeKey: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true]

private func folder(_ path: String, code: Bool) -> Settings.Folder {
    Settings.Folder(path: root + "/" + path, code: code, reading: true)
}

private func visible(_ folders: [Settings.Folder], switchOn: Bool = true,
                     kindsOn: [String: Bool] = noCodeKey) -> Visible {
    Visible(folders: folders, codeSearchOn: switchOn, kindsOn: kindsOn)
}

struct VCCell: Sendable {
    let path: String
    let kind: String
    let shown: Bool
}

struct VCShape: Sendable, CustomTestStringConvertible {
    let name: String
    let outerCode: Bool
    let innerCode: Bool
    let cells: [VCCell]
    var testDescription: String { name }

    func folders(innerFirst: Bool) -> [Settings.Folder] {
        let outer = folder("\(name)/outer", code: outerCode)
        let inner = folder("\(name)/outer/inner", code: innerCode)
        return innerFirst ? [inner, outer] : [outer, inner]
    }
}

private func cell(_ shape: String, _ file: String, _ kind: String, _ shown: Bool) -> VCCell {
    VCCell(path: "\(root)/\(shape)/\(file)", kind: kind, shown: shown)
}

private let shapes: [VCShape] = [
    VCShape(name: "ov-a", outerCode: false, innerCode: true, cells: [
        cell("ov-a", "outer/inner/ovainner.py", "code", false),
        cell("ov-a", "outer/ovaouter.py", "code", false),
        cell("ov-a", "outer/inner/ovaphoto.png", "photo", true),
        cell("ov-a", "outer/ovaouter.png", "photo", true),
    ]),
    VCShape(name: "ov-b", outerCode: true, innerCode: false, cells: [
        cell("ov-b", "outer/inner/ovbinner.py", "code", false),
        cell("ov-b", "outer/ovbouter.py", "code", false),
        cell("ov-b", "outer/inner/ovbphoto.png", "photo", true),
    ]),
    VCShape(name: "ov-c", outerCode: false, innerCode: false, cells: [
        cell("ov-c", "outer/inner/ovcinner.py", "code", false),
        cell("ov-c", "outer/ovcouter.py", "code", false),
        cell("ov-c", "outer/inner/ovcphoto.png", "photo", true),
        cell("ov-c", "outer/ovcouter.png", "photo", true),
    ]),
    VCShape(name: "ov-d", outerCode: true, innerCode: true, cells: [
        cell("ov-d", "outer/inner/ovdinner.py", "code", false),
        cell("ov-d", "outer/ovdouter.py", "code", false),
        cell("ov-d", "outer/inner/ovdphoto.png", "photo", true),
        cell("ov-d", "outer/ovdouter.png", "photo", true),
    ]),
]

@Suite("VisibleCodeTests")
struct VisibleCodeTests {

    @Test(arguments: shapes, [false, true])
    func inEachOverlapShapeACodeRowIsNeverShownWhateverTheTicksTheSwitchAndTheFolderOrder(
        _ shape: VCShape, _ innerFirst: Bool
    ) {
        for switchOn in [false, true] {
            let v = visible(shape.folders(innerFirst: innerFirst), switchOn: switchOn)
            for c in shape.cells {
                #expect(v.allows(path: c.path, kind: c.kind) == c.shown,
                        "\(shape.name), inner folder first \(innerFirst), switch \(switchOn): \(c.kind) \(c.path) should be \(c.shown ? "shown" : "hidden")")
            }
        }
    }

    @Test func aCodeRowIsNeverShownEvenWhenEveryFolderIsTickedForCodeAndTheSwitchIsOn() {
        let folders = shapes.flatMap { $0.folders(innerFirst: false) }.map {
            Settings.Folder(path: $0.path, code: true, reading: true)
        }
        let v = visible(folders)
        #expect(!v.allows(path: "/Users/test/elsewhere/main.swift", kind: "code"))
        #expect(!v.allows(path: "\(root)/main.swift", kind: "code"), "the parent of the folders")
        #expect(!v.allows(path: "\(root)/ov-a/other/main.swift", kind: "code"), "a sibling of ov-a/outer")
        #expect(!v.allows(path: "\(root)/ov-a/outer/main.swift", kind: "code"), "under a folder ticked for code")
        #expect(!v.allows(path: "\(root)/ov-a/outer/inner/deep/main.py", kind: "code"), "deep under a folder ticked for code")
        #expect(v.allows(path: "\(root)/ov-a/outer/shot.png", kind: "photo"), "control: a photo under the same folder")
        let none = visible([])
        #expect(!none.allows(path: "\(root)/ov-a/outer/main.swift", kind: "code"), "no folder at all")
    }

    @Test func aFileWithKindPhotoInAnUntickedRepoStaysVisibleWhileItsCodeIsHidden() {
        let folders = [
            folder("legacy-sync", code: false),
            folder("api-client", code: true),
        ]
        let v = visible(folders)
        #expect(v.allows(path: "\(root)/legacy-sync/docs/diagram.png", kind: "photo"), "a repo reads its pictures")
        #expect(!v.allows(path: "\(root)/legacy-sync/src/mergeStaleRecords.swift", kind: "code"))
        #expect(!v.allows(path: "\(root)/api-client/src/retry.swift", kind: "code"), "a tick does not show code")
        #expect(v.allows(path: "\(root)/api-client/docs/retry-diagram.png", kind: "photo"))
        #expect(v.allows(path: "\(root)/api-client/docs/retry-notes.md", kind: "doc"))
        #expect(!v.allows(path: "\(root)/scratch-lab/main.py", kind: "code"), "a repo never picked")
        #expect(!v.allows(path: "\(root)/scratch-lab/shot.png", kind: "photo"), "a repo never picked")
    }

    @Test func aFolderTakesFilesByAWholePathComponent() {
        let v = visible([folder("api", code: true)])
        #expect(v.allows(path: "\(root)/api/shot.png", kind: "photo"))
        #expect(!v.allows(path: "\(root)/api-client/shot.png", kind: "photo"))
        #expect(!v.allows(path: "\(root)/apiary/shot.png", kind: "photo"))
        #expect(!v.allows(path: "\(root)/api/main.swift", kind: "code"))
    }

    @Test func noKindsOnValueMakesCodeVisible() {
        let folders = [folder("api-client", code: true), folder("legacy-sync", code: false)]
        for kindsOn in [noCodeKey, [:], ["code": true], ["code": true, "photo": true]] as [[String: Bool]] {
            for switchOn in [false, true] {
                let v = visible(folders, switchOn: switchOn, kindsOn: kindsOn)
                #expect(!v.allows(path: "\(root)/api-client/src/retry.swift", kind: "code"),
                        "ticked folder, switch \(switchOn), kindsOn \(kindsOn)")
                #expect(!v.allows(path: "\(root)/legacy-sync/src/merge.swift", kind: "code"),
                        "unticked folder, switch \(switchOn), kindsOn \(kindsOn)")
            }
        }
    }

    @Test func noStoredCodeSearchOnAndNoFolderCodeTickChangesWhatCodeShows() {
        let paths = ["\(root)/api-client/src/retry.swift", "\(root)/legacy-sync/src/merge.py", "\(root)/scratch-lab/dates.go"]
        let tickSets: [[Settings.Folder]] = [
            [],
            [folder("api-client", code: false), folder("legacy-sync", code: false), folder("scratch-lab", code: false)],
            [folder("api-client", code: true), folder("legacy-sync", code: false), folder("scratch-lab", code: false)],
            [folder("api-client", code: true), folder("legacy-sync", code: true), folder("scratch-lab", code: true)],
        ]
        var shown: [String] = []
        for folders in tickSets {
            for switchOn in [false, true] {
                let v = visible(folders, switchOn: switchOn, kindsOn: ["code": true, "photo": true, "doc": true])
                for path in paths where v.allows(path: path, kind: "code") { shown.append("\(folders.map(\.code)) switch \(switchOn) \(path)") }
            }
        }
        #expect(shown.isEmpty, "code was shown for \(shown.count) of \(tickSets.count * 2 * paths.count) combinations: \(shown.prefix(3))")
    }

    @Test func visibleRefusesKindCodeBecauseItReadsTheRulesFlagNotAHardCodedKindTest() {
        let text = KC.read(KC.root.path + "/Sources/SesameEngine/Visible.swift") ?? ""
        #expect(!text.isEmpty, "Sources/SesameEngine/Visible.swift is missing")
        #expect(text.contains("Rules.codeKindOn"), "Visible.swift never reads Rules.codeKindOn: switching the flag on would not bring code back")
    }

    @Test func kindsOnAudioFalseHidesAudioAndLeavesTheOtherKindsAlone() {
        let folders = [folder("api-client", code: true), folder("legacy-sync", code: false)]
        var kinds = noCodeKey
        kinds["audio"] = false
        let v = visible(folders, kindsOn: kinds)
        #expect(!v.allows(path: "\(root)/api-client/talk.m4a", kind: "audio"), "audio is off")
        #expect(!v.allows(path: "\(root)/api-client/src/retry.swift", kind: "code"), "code stays hidden")
        for (kind, file) in [("photo", "a.png"), ("pdf", "a.pdf"), ("doc", "a.md"), ("video", "a.mp4")] {
            #expect(v.allows(path: "\(root)/api-client/docs/" + file, kind: kind), "\(kind) stays on when audio is off")
        }
        let both = visible(folders, switchOn: false, kindsOn: kinds)
        #expect(!both.allows(path: "\(root)/api-client/src/retry.swift", kind: "code"))
        #expect(both.allows(path: "\(root)/api-client/docs/a.png", kind: "photo"))
        #expect(!both.allows(path: "\(root)/api-client/talk.m4a", kind: "audio"))
    }
}
