import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-5-t4, tester step. Written from the entry plan-5-t4 of plan-5-tasks.md (Tests, `PaneMediaTests`), the Conventions and the Decisions
// only; no product source is read. The names used were found in Tests/: `Pane()`, `show(_:path:image:)`, `showPending(path:)`, `clear()` and
// `view` (PaneStaleTests, PanePassageTests), the walkers `prViews`, `prImages` and `prAccessibilityLabels` (PanelRig.swift), and
// `PreviewReply`'s initialiser, with `locator:` and `text:` as PanePassageTests uses them and the entry's new `seconds:`.
//
// What these pin, all pure state (no window is shown):
//   1. After `show` of an audio reply the pane shows the locator, "Opens at 02:10", the spoken words and the picture (the waveform).
//   2. With no words the pane shows the locator and no words text: the shown texts of the two replies differ by exactly the text that
//      holds the words.
//   3. After `show` of a video reply the pane shows the locator, "Opens at 00:42", and the picture.
//   4. After `clear()`, after `showPending(path:)`, after a photo reply and after another media reply replaces them, no locator, no words and
//      no picture of the earlier selection remains (the plan 1 stale-pane lesson), read as visible texts and accessibility labels.
//   5. An audio or video reply that is `.ok` with no picture and no locator is the file that no longer opens (G20): the pane says
//      "Can't preview this file", and nothing of an earlier selection stays.
//   6. A changed media reply shows the locator and the pane's "changed since indexed".
//
// SHAPES THIS FILE PINS (each is one place to edit, the helpers `pmReplyAudio`, `pmReplyVideo` and the walker `pmTexts`):
//   - `PreviewReply(ticket:status:png:name:kind:size:mtime:locator:text:seconds:)`: `seconds` comes after `text` (see PreviewMediaRig.swift);
//     this file never passes `marks:` with it.
//   - The words of an audio reply are the reply's `text`, shown as plain text (no mark colour) in a text view or a text field the walker
//     finds; the locator is shown as a text that contains it.
//   - The "Can't preview this file" text may use a straight or a curly apostrophe; both are read as the same.

// MARK: replies

private let pmWords = "the keeper repaired the lamp at the lighthouse"
private let pmOtherWords = "a quarterly review of the harbour budget"
private let pmAudioName = "harborwalk.wav"
private let pmAudioPath = "/media/harborwalk.wav"
private let pmVideoName = "vidcuts.mp4"
private let pmVideoPath = "/media/vidcuts.mp4"
private let pmAudioLocator = "Opens at 02:10"
private let pmVideoLocator = "Opens at 00:42"

private func pmReplyAudio(words: String? = pmWords, status: PreviewStatus = .ok, locator: String? = pmAudioLocator, png: String? = "/var/folders/ab/cdef/T/Sesame-4242/w1.png",
                          ticket: Int = 1) -> PreviewReply {
    PreviewReply(ticket: ticket, status: status, png: png, name: pmAudioName, kind: "audio", size: 7_040_044, mtime: 1_700_000_000,
                 locator: locator, text: words, seconds: locator == nil ? nil : 130)
}

private func pmReplyVideo(status: PreviewStatus = .ok, locator: String? = pmVideoLocator, png: String? = "/var/folders/ab/cdef/T/Sesame-4242/f1.png",
                          ticket: Int = 2) -> PreviewReply {
    PreviewReply(ticket: ticket, status: status, png: png, name: pmVideoName, kind: "video", size: 3_100_000, mtime: 1_700_000_500,
                 locator: locator, seconds: locator == nil ? nil : 42)
}

private func pmReplyPhoto() -> PreviewReply {
    PreviewReply(ticket: 3, status: .ok, png: nil, name: "screenshot-terminal.png", kind: "photo", size: 123_456, mtime: 1_700_100_000)
}

@MainActor
private func pmPicture() -> NSImage { NSImage(size: NSSize(width: 8, height: 8)) }

@MainActor
private func pmShowAudio(_ pane: Pane, _ reply: PreviewReply? = nil) { pane.show(reply ?? pmReplyAudio(), path: pmAudioPath, image: pmPicture()) }

@MainActor
private func pmShowVideo(_ pane: Pane) { pane.show(pmReplyVideo(), path: pmVideoPath, image: pmPicture()) }

@MainActor
private func pmShowPhoto(_ pane: Pane) { pane.show(pmReplyPhoto(), path: "/photos/screenshot-terminal.png", image: pmPicture()) }

// MARK: reading the pane

@MainActor
private func pmIsShown(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor }

/// The text of every text field and text view a person could see: not hidden, no hidden parent, not empty.
@MainActor
private func pmTexts(_ root: NSView) -> [String] {
    prViews(root).compactMap { view in
        guard pmIsShown(view) else { return nil }
        if let field = view as? NSTextField, !field.stringValue.isEmpty { return field.stringValue }
        if let textView = view as? NSTextView, !textView.string.isEmpty { return textView.string }
        return nil
    }
}

/// What the pane still shows or says about `needles`, as lines, so a failure names the leftover.
@MainActor
private func pmLeftovers(_ root: NSView, naming needles: [String]) -> [String] {
    var found: [String] = []
    for text in pmTexts(root) where needles.contains(where: { text.contains($0) }) { found.append("visible text \"\(text)\"") }
    for label in prAccessibilityLabels(root) where needles.contains(where: { label.contains($0) }) { found.append("accessibility label \"\(label)\"") }
    return found
}

@MainActor
private func pmHasBackgroundColour(_ root: NSView) -> Bool {
    for view in prViews(root) where pmIsShown(view) {
        let shown: NSAttributedString?
        if let textView = view as? NSTextView, !textView.string.isEmpty { shown = textView.textStorage } else if let field = view as? NSTextField, !field.stringValue.isEmpty { shown = field.attributedStringValue } else { shown = nil }
        guard let shown else { continue }
        var coloured = false
        shown.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: shown.length)) { value, _, _ in if value != nil { coloured = true } }
        if coloured { return true }
    }
    return false
}

private func pmStraight(_ text: String) -> String { text.replacingOccurrences(of: "\u{2019}", with: "'") }

// MARK: the tests

@Suite("PaneMediaTests", .serialized)
struct PaneMediaTests {

    // MARK: an audio reply

    @MainActor
    @Test func anAudioReplyShowsItsLocatorItsWordsAndItsWaveformPicture() {
        let pane = Pane()
        pmShowAudio(pane)
        let shown = pmTexts(pane.view)
        #expect(shown.contains { $0.contains(pmAudioLocator) }, "the pane shows \(shown), expected a text holding `\(pmAudioLocator)`")
        #expect(shown.contains { $0.contains(pmWords) }, "the pane shows \(shown), expected a text holding the words `\(pmWords)`")
        #expect(shown.contains { $0.contains(pmAudioName) }, "the pane shows \(shown), expected the file name")
        #expect(!prImages(pane.view).isEmpty, "the waveform picture is not set")
        #expect(!pmHasBackgroundColour(pane.view), "the spoken words carry a mark colour: audio words are plain text")
    }

    @MainActor
    @Test func anAudioReplyWithNoWordsShowsTheLocatorAndNoWordsText() {
        let withWords = Pane()
        pmShowAudio(withWords)
        let without = Pane()
        pmShowAudio(without, pmReplyAudio(words: nil))

        let shown = pmTexts(without.view)
        #expect(shown.contains { $0.contains(pmAudioLocator) }, "the pane shows \(shown), expected a text holding `\(pmAudioLocator)`")
        #expect(!shown.contains { $0.contains("keeper") || $0.contains("lamp") }, "the pane with no words still shows words: \(shown)")
        let extra = pmTexts(withWords.view).filter { text in !shown.contains(text) }
        #expect(extra.count == 1 && extra[0].contains(pmWords), "the pane with words shows \(extra) more than the pane without, expected exactly the text that holds the words")
        #expect(!prImages(without.view).isEmpty, "the waveform picture is not set when there are no words")
    }

    @MainActor
    @Test func aSecondAudioReplyWithNoWordsLeavesNoWordsOfTheFirst() {
        let pane = Pane()
        pmShowAudio(pane)
        #expect(pmTexts(pane.view).contains { $0.contains(pmWords) }, "setup: the words are not shown before the second reply")
        pmShowAudio(pane, pmReplyAudio(words: nil, ticket: 7))
        let left = pmLeftovers(pane.view, naming: [pmWords, "keeper", "lighthouse"])
        #expect(left.isEmpty, "the second reply (no words) still shows the first one's words: \(left)")
        #expect(pmTexts(pane.view).contains { $0.contains(pmAudioLocator) }, "the locator is gone: \(pmTexts(pane.view))")
    }

    @MainActor
    @Test func aSecondAudioReplyWithOtherWordsReplacesTheFirstWordsCompletely() {
        let pane = Pane()
        pmShowAudio(pane)
        pmShowAudio(pane, pmReplyAudio(words: pmOtherWords, locator: "Opens at 03:25", ticket: 8))
        let left = pmLeftovers(pane.view, naming: [pmWords, pmAudioLocator])
        #expect(left.isEmpty, "the second reply still shows the first one's words or locator: \(left)")
        #expect(pmTexts(pane.view).contains { $0.contains(pmOtherWords) }, "the second words are not shown: \(pmTexts(pane.view))")
        #expect(pmTexts(pane.view).contains { $0.contains("Opens at 03:25") }, "the second locator is not shown: \(pmTexts(pane.view))")
    }

    // MARK: a video reply

    @MainActor
    @Test func aVideoReplyShowsItsLocatorAndItsPictureAndNoWords() {
        let pane = Pane()
        pmShowVideo(pane)
        let shown = pmTexts(pane.view)
        #expect(shown.contains { $0.contains(pmVideoLocator) }, "the pane shows \(shown), expected a text holding `\(pmVideoLocator)`")
        #expect(shown.contains { $0.contains(pmVideoName) }, "the pane shows \(shown), expected the file name")
        #expect(!prImages(pane.view).isEmpty, "the frame picture is not set")
    }

    // MARK: nothing of the earlier selection stays (plan 1's stale-pane lesson)

    @MainActor
    @Test func aClearedPaneHoldsNoLocatorNoWordsAndNoPictureAfterAnAudioReply() {
        let pane = Pane()
        pmShowAudio(pane)
        #expect(pmTexts(pane.view).contains { $0.contains(pmAudioLocator) }, "setup: the locator is not shown before clear")
        pane.clear()
        let left = pmLeftovers(pane.view, naming: [pmAudioLocator, pmWords, pmAudioName, pmAudioPath, "Opens at"])
        #expect(left.isEmpty, "the cleared pane still holds the audio file: \(left)")
        #expect(prImages(pane.view).isEmpty, "a picture is still set after clear")
    }

    @MainActor
    @Test func aClearedPaneHoldsNoLocatorAndNoPictureAfterAVideoReply() {
        let pane = Pane()
        pmShowVideo(pane)
        #expect(pmTexts(pane.view).contains { $0.contains(pmVideoLocator) }, "setup: the locator is not shown before clear")
        pane.clear()
        let left = pmLeftovers(pane.view, naming: [pmVideoLocator, pmVideoName, pmVideoPath, "Opens at"])
        #expect(left.isEmpty, "the cleared pane still holds the video: \(left)")
        #expect(prImages(pane.view).isEmpty, "a picture is still set after clear")
    }

    @MainActor
    @Test func aPaneWaitingForAnotherSelectionHoldsNoLocatorAndNoWords() {
        let pane = Pane()
        pmShowAudio(pane)
        pane.showPending(path: "/photos/next.jpg")
        let afterAudio = pmLeftovers(pane.view, naming: [pmAudioLocator, pmWords, pmAudioName])
        #expect(afterAudio.isEmpty, "the waiting pane still holds the audio file: \(afterAudio)")

        pmShowVideo(pane)
        pane.showPending(path: "/photos/next.jpg")
        let afterVideo = pmLeftovers(pane.view, naming: [pmVideoLocator, pmVideoName])
        #expect(afterVideo.isEmpty, "the waiting pane still holds the video: \(afterVideo)")
    }

    @MainActor
    @Test func aPhotoReplyThatReplacesAnAudioReplyLeavesNoLocatorAndNoWords() {
        let pane = Pane()
        pmShowAudio(pane)
        #expect(pmTexts(pane.view).contains { $0.contains(pmAudioLocator) }, "setup: the locator is not shown before the photo replaces it")
        pmShowPhoto(pane)
        let left = pmLeftovers(pane.view, naming: [pmAudioLocator, pmWords, pmAudioName, pmAudioPath, "Opens at"])
        #expect(left.isEmpty, "the photo's pane still holds the audio file: \(left)")
        #expect(pmTexts(pane.view).contains("screenshot-terminal.png"), "the photo is not shown: \(pmTexts(pane.view))")
    }

    @MainActor
    @Test func aPhotoReplyThatReplacesAVideoReplyLeavesNoLocator() {
        let pane = Pane()
        pmShowVideo(pane)
        pmShowPhoto(pane)
        let left = pmLeftovers(pane.view, naming: [pmVideoLocator, pmVideoName, pmVideoPath, "Opens at"])
        #expect(left.isEmpty, "the photo's pane still holds the video: \(left)")
    }

    @MainActor
    @Test func aVideoReplyThatReplacesAnAudioReplyAndTheOtherWayRoundLeaveNothingOfTheFirst() {
        let pane = Pane()
        pmShowAudio(pane)
        pmShowVideo(pane)
        let afterVideo = pmLeftovers(pane.view, naming: [pmAudioLocator, pmWords, pmAudioName])
        #expect(afterVideo.isEmpty, "the video's pane still holds the audio file: \(afterVideo)")
        #expect(pmTexts(pane.view).contains { $0.contains(pmVideoLocator) }, "the video's locator is not shown: \(pmTexts(pane.view))")

        pmShowAudio(pane)
        let afterAudio = pmLeftovers(pane.view, naming: [pmVideoLocator, pmVideoName])
        #expect(afterAudio.isEmpty, "the audio's pane still holds the video: \(afterAudio)")
        #expect(pmTexts(pane.view).contains { $0.contains(pmAudioLocator) }, "the audio's locator is not shown: \(pmTexts(pane.view))")
    }

    // MARK: a file that no longer opens (G20), and a changed one

    @MainActor
    @Test(arguments: ["audio", "video"])
    func aMediaReplyThatIsOkWithNoPictureAndNoLocatorSaysItCannotPreviewTheFileAndKeepsNothingOfTheEarlierOne(_ kind: String) {
        let pane = Pane()
        pmShowAudio(pane)
        pmShowVideo(pane)
        let name = kind == "audio" ? pmAudioName : pmVideoName
        let broken = PreviewReply(ticket: 9, status: .ok, png: nil, name: name, kind: kind, size: 5_000, mtime: 1_700_000_900)
        pane.show(broken, path: "/media/" + name, image: nil)

        let shown = pmTexts(pane.view).map(pmStraight)
        #expect(shown.contains { $0.contains("Can't preview this file") }, "the pane shows \(shown), expected `Can't preview this file`")
        let left = pmLeftovers(pane.view, naming: [pmAudioLocator, pmVideoLocator, pmWords, "Opens at"])
        #expect(left.isEmpty, "the pane still holds an earlier selection: \(left)")
        #expect(prImages(pane.view).isEmpty, "a picture of an earlier selection is still set")
    }

    @MainActor
    @Test func aChangedAudioReplyShowsTheLocatorTheWordsAndTheChangedNote() {
        let pane = Pane()
        pmShowAudio(pane, pmReplyAudio(status: .changed))
        let shown = pmTexts(pane.view)
        #expect(shown.contains { $0.contains(pmAudioLocator) }, "the pane shows \(shown), expected the locator")
        #expect(shown.contains { $0.contains(pmWords) }, "the pane shows \(shown), expected the words")
        #expect(shown.contains { $0.contains("changed since indexed") }, "the pane shows \(shown), expected `changed since indexed`")
    }

    @MainActor
    @Test func aChangedVideoReplyShowsTheLocatorAndTheChangedNote() {
        let pane = Pane()
        pane.show(pmReplyVideo(status: .changed), path: pmVideoPath, image: pmPicture())
        let shown = pmTexts(pane.view)
        #expect(shown.contains { $0.contains(pmVideoLocator) }, "the pane shows \(shown), expected the locator")
        #expect(shown.contains { $0.contains("changed since indexed") }, "the pane shows \(shown), expected `changed since indexed`")
    }
}
