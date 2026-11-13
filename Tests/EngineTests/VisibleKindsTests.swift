import Foundation
import Testing
import SesameEngine

// plan-5-t7, tester step. Written from the entry plan-5-t7 of plan-5-tasks.md (its Tests paragraph: "a VisibleTests-style case:
// kindsOn["audio"] == false hides audio and keeps video, photo and PDF visible") and spec S4.6 and S7. No product source is read.
// There is no VisibleTests file; the Visible predicate is tested inside SearchTests.swift, so these cases are a new file next to it.
//
// The names are the ones SearchTests.swift pins and that exist today: `Visible(folders:codeSearchOn:kindsOn:)` and
// `allows(path:kind:)`; `Settings.Folder(path:code:reading:)`. The entry says `Visible.allows` is unchanged, so these cases are guards:
// they hold before the change and must still hold after it (they cannot be red: nothing in `Visible` is new). Every expected answer is
// written by hand: a key that is false hides that kind, a missing key or a true key shows it, and no other kind is touched.

private let folders = [Settings.Folder(path: "/media", code: false, reading: true)]

private func visible(_ kindsOn: [String: Bool]) -> Visible {
    Visible(folders: folders, codeSearchOn: false, kindsOn: kindsOn)
}

private let samples: [(kind: String, path: String)] = [
    ("photo", "/media/beach.jpg"),
    ("pdf", "/media/lease.pdf"),
    ("doc", "/media/notes.txt"),
    ("audio", "/media/interview.m4a"),
    ("video", "/media/safari.mp4"),
]

private func shown(_ filter: Visible) -> [String] {
    samples.filter { filter.allows(path: $0.path, kind: $0.kind) }.map(\.kind)
}

@Suite("VisibleKindsTests")
struct VisibleKindsTests {

    @Test func audioOffHidesAudioAndKeepsVideoPhotoPdfAndDocumentsVisible() {
        let all = ["photo": true, "pdf": true, "doc": true, "audio": false, "video": true, "code": true]
        #expect(shown(visible(all)) == ["photo", "pdf", "doc", "video"], "audio off: shown \(shown(visible(all)))")
    }

    @Test func videoOffHidesVideoAndKeepsAudioPhotoPdfAndDocumentsVisible() {
        let all = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": false, "code": true]
        #expect(shown(visible(all)) == ["photo", "pdf", "doc", "audio"], "video off: shown \(shown(visible(all)))")
    }

    @Test func pdfOffAndDocumentsOffEachHideOnlyTheirOwnKind() {
        let noPdf = ["photo": true, "pdf": false, "doc": true, "audio": true, "video": true, "code": true]
        #expect(shown(visible(noPdf)) == ["photo", "doc", "audio", "video"], "pdf off: shown \(shown(visible(noPdf)))")
        let noDoc = ["photo": true, "pdf": true, "doc": false, "audio": true, "video": true, "code": true]
        #expect(shown(visible(noDoc)) == ["photo", "pdf", "audio", "video"], "doc off: shown \(shown(visible(noDoc)))")
    }

    @Test func audioAndVideoBothOffHideBothAndKeepTheRest() {
        let both = ["photo": true, "pdf": true, "doc": true, "audio": false, "video": false, "code": true]
        #expect(shown(visible(both)) == ["photo", "pdf", "doc"], "audio and video off: shown \(shown(visible(both)))")
    }

    @Test func aKindWithNoKeyIsShownAndOnlyAFalseKeyHides() {
        #expect(shown(visible([:])) == ["photo", "pdf", "doc", "audio", "video"], "an empty kindsOn: shown \(shown(visible([:])))")
        let onlyAudioOff = ["audio": false]
        #expect(shown(visible(onlyAudioOff)) == ["photo", "pdf", "doc", "video"], "only the audio key, false: shown \(shown(visible(onlyAudioOff)))")
        let onlyPhoto = ["photo": true]
        #expect(shown(visible(onlyPhoto)) == ["photo", "pdf", "doc", "audio", "video"], "only the photo key: shown \(shown(visible(onlyPhoto)))")
    }

    @Test func aKindSwitchedBackOnShowsAgainAtOnce() {
        let off = ["photo": true, "pdf": true, "doc": true, "audio": false, "video": true]
        let on = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true]
        #expect(!visible(off).allows(path: "/media/interview.m4a", kind: "audio"))
        #expect(visible(on).allows(path: "/media/interview.m4a", kind: "audio"), "audio is still hidden with its key true")
    }

    @Test func aFileOutsideEveryFolderStaysHiddenWhateverTheKinds() {
        let all = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true]
        #expect(!visible(all).allows(path: "/elsewhere/interview.m4a", kind: "audio"), "an audio file under no folder is visible")
    }
}
