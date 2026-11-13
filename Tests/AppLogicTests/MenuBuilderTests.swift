import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t28, tester step: the menu bar's menu, its icons and the controller over a fake status item (S7.1, S7.16, S1.30,
// S1.29 the menu). Written from the t28 entry of plan-2-tasks.md (its Tests paragraph), design section 6 ("`NSStatusItem`,
// badge icon for Ready, Indexing, Paused, Downloading, VoiceOver label, an `NSMenu` led by one status line"), spec S7 and
// S1, the F2 mockup (f2-menubar.html, read as the picture of the menu, not as a contract) and the sealed t27 test file
// `MenuStateTests` (the only place `MenuInputs`, `MenuModel` and their texts are read). No product source was read. Every
// expected title, flag and count below is written by hand; none is computed by the code under test. No status item is
// created, no app is launched, no window is shown: the menu is built and read offscreen and is never attached to anything.
//
// THE SHAPE THESE TESTS PIN (new API; today `MenuBuilder` does not exist, so this file does not compile until it does).
// The entry names `MenuBuilder.build(MenuModel)`, `MenuActions`, `StatusIcons.image(for:)`, `MenuBarController` and
// `StatusItemHost`, not their signatures; these are this file's picks. If one is wrong, ask for a test change.
//
//   struct MenuActions                                     // the seam; in MenuBuilder.swift (t32 wires the real ones)
//     init(pause:, resume:, resumeAnyway:, open:, settings:, quit:)   // six `() -> Void` closures, in this order
//   enum MenuBuilder { static func build(_ model: MenuModel, actions: MenuActions) -> NSMenu }
//     Each action item holds target and action so that sending the action to the target (what a click does) runs the closure, once. The
//     menu sets `autoenablesItems = false` (or otherwise makes `isEnabled` the truth without a validation pass): the tests
//     read `isEnabled` as built.
//   enum StatusIcons { static func image(for state: MenuState) -> NSImage }      // non-optional or optional, both compile
//   protocol StatusItemHost: AnyObject {                   // the seam over the `NSStatusItem` and its button
//       var buttonAccessibilityLabel: String { get set }
//       var buttonTitle: String { get set }
//       var buttonImage: NSImage? { get set }
//       var menu: NSMenu? { get set }
//   }
//   final class MenuBarController { init(host: StatusItemHost, actions: MenuActions); func update(_ model: MenuModel) }
//     `update` sets the label, the title and the image from the model's state, and sets `host.menu` to a freshly built menu
//     only when the model differs from the one it showed last (so `MenuModel` is `Equatable`, or the controller compares
//     what the menu shows; the tests never rely on object identity).
//
// WHAT IS PINNED, AND WHAT IS NOT. From the entry: the order (the status line first and disabled, then Pause or Resume,
// then "Resume anyway, on battery" only with the battery reason, then the counts, then "Open Sesame",
// "Settings…", "Quit Sesame"), the titles and enabled flags of those items, and the accessibility description of each item.
// The accessibility description (`NSMenuItem.accessibilityLabel()`, what VoiceOver reads) is picked as the item's title
// for every action and navigation item, and for the other items it must be non-empty and hold the same words as the title
// (the status line's description starts with the status text). Pause or Resume is "Pause indexing" (enabled only while
// Indexing) or "Resume indexing" (enabled when "you" is among the reasons), as t27 fixed. The count rows carry the kind's
// word of the F2 mockup ("Photos", "PDFs", "Documents") and the done count with its thousands separator, one row per kind,
// disabled. Not pinned: the status line
// of Ready after Start and of Downloading beyond "downloading" and the percent, the header texts between the groups,
// separators, whether the second line ("4,520 files left · about 12 min left") is a second disabled item or part of the
// status item (it must come before Pause or Resume, and be disabled), the rows of kinds with no done file, the "Off" row of
// a kind that is switched off, the text when nothing was indexed yet, and where the "N files need permission" line sits
// (anywhere before "Open Sesame"). The label of the status item, the real icon at real size and the real menu are the
// accept stage's (S7.1, S7.16, S1.30, S1.29) and the person's call.

private let mbWalk = Date(timeIntervalSince1970: 1_700_000_000)

private func mbCounts(done: Int = 0, pending: [String: Int] = [:], partial: [String: Int] = [:], needs: Int = 0) -> IndexCounts {
    IndexCounts(done: done, pending: pending, partial: partial, needsPermission: needs)
}

private func mbInputs(model: ModelState = .whole, startPressed: Bool = true, walkDone: Bool = true,
                      counts: IndexCounts, reasons: Set<PauseReason> = []) -> MenuInputs {
    MenuInputs(model: model, startPressed: startPressed, indexDeleted: false, walkDoneAt: walkDone ? mbWalk : nil,
               counts: counts, pauseReasons: reasons)
}

private let mbAllOn: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]

private func mbModel(_ inputs: MenuInputs, percent: Int = 0, done: [String: Int] = [:],
                     speeds: [String: Double] = ["photo": 0.16]) -> MenuModel {
    MenuModel(inputs: inputs, downloadPercent: percent, doneByKind: done, speeds: speeds, kindsOn: mbAllOn)
}

/// Counts as the cached snapshot would hold them: 9,690 photos, 1,083 PDFs and 1,068 documents done.
private let mbDone: [String: Int] = ["photo": 9690, "pdf": 1083, "doc": 1068]
private let mbDoneRows: [(label: String, number: String)] = [("Photos", "9,690"), ("PDFs", "1,083"), ("Documents", "1,068"), ("Audio", "0"), ("Video", "0")]

/// Records which closure of `MenuActions` ran. Not tied to an actor, so it fits a closure of any isolation.
private final class MBRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var log: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    private func add(_ name: String) { lock.lock(); calls.append(name); lock.unlock() }
    var actions: MenuActions {
        // ROUND E (E1): `retryDownload` is the new closure, between `resumeAnyway` and `open` (see the round E block below).
        MenuActions(pause: { self.add("pause") }, resume: { self.add("resume") }, resumeAnyway: { self.add("resumeAnyway") },
                    retryDownload: { self.add("retryDownload") },
                    open: { self.add("open") }, settings: { self.add("settings") }, quit: { self.add("quit") })
    }
}

/// The fake status item: records what the controller sets and how many times it replaced the menu.
private final class MBFakeHost: StatusItemHost {
    var buttonAccessibilityLabel = ""
    var buttonTitle = ""
    var buttonImage: NSImage?
    var menuAssignments = 0
    var menu: NSMenu? { didSet { menuAssignments += 1 } }
}

private struct MBCase {
    let name: String
    let model: MenuModel
    let statusPrefix: String?
    let statusHas: [String]
    let header: String
    let permission: String?
    let actions: [String]
    let counts: [(label: String, number: String)]
}

private let mbPause = "Pause indexing"
private let mbResume = "Resume indexing"
private let mbAnyway = "Resume anyway, on battery"
private let mbRetry = "Retry model download"
private let mbOpen = "Open Sesame"
private let mbSettings = "Settings…"
private let mbQuit = "Quit Sesame"

private let mbPendingCounts = mbCounts(done: 7400, pending: ["photo": 4520])

private let mbDownloading = MBCase(
    name: "Downloading",
    model: mbModel(mbInputs(model: .downloading, startPressed: false, walkDone: false, counts: mbCounts()), percent: 34),
    statusPrefix: nil, statusHas: ["ownload", "34"], header: "Downloading the model, 34%", permission: nil,
    actions: [], counts: [])

private let mbIndexing = MBCase(
    name: "Indexing",
    model: mbModel(mbInputs(counts: mbPendingCounts), done: mbDone),
    statusPrefix: "Indexing 62%", statusHas: ["Indexing 62%"], header: "Indexing 62%, 4,520 files left · about 12 min left", permission: nil,
    actions: [mbPause], counts: mbDoneRows)

private let mbPausedByYou = MBCase(
    name: "Paused by you",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.you]), done: mbDone),
    statusPrefix: "Paused by you", statusHas: ["Paused by you"], header: "Paused, By you", permission: nil,
    actions: [mbResume], counts: mbDoneRows)

private let mbPausedOnBattery = MBCase(
    name: "Paused on battery",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.battery]), done: mbDone),
    statusPrefix: "Paused: on battery", statusHas: ["Paused: on battery"], header: "Paused, On battery", permission: nil,
    actions: [mbAnyway], counts: mbDoneRows)

private let mbPausedYouAndBattery = MBCase(
    name: "Paused by you and on battery",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.you, .battery]), done: mbDone),
    statusPrefix: "Paused", statusHas: ["Paused"], header: "Paused, By you", permission: nil,
    actions: [mbResume, mbAnyway], counts: mbDoneRows)

private let mbPausedByCPU = MBCase(
    name: "Paused, the Mac is busy",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.cpu]), done: mbDone),
    statusPrefix: "Paused: the Mac is busy", statusHas: ["Paused: the Mac is busy"], header: "Paused, The Mac is busy", permission: nil,
    actions: [], counts: mbDoneRows)

private let mbPausedLowPower = MBCase(
    name: "Paused, Low Power Mode",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.lowPower]), done: mbDone),
    statusPrefix: "Paused: Low Power Mode is on", statusHas: ["Paused: Low Power Mode is on"], header: "Paused, Low Power Mode is on", permission: nil,
    actions: [], counts: mbDoneRows)

private let mbReady = MBCase(
    name: "Ready",
    model: mbModel(mbInputs(counts: mbCounts(done: 11841)), done: mbDone),
    statusPrefix: nil, statusHas: [], header: "Ready", permission: nil,
    actions: [], counts: mbDoneRows)

private let mbReadyWithLockedFiles = MBCase(
    name: "Ready with files that need permission",
    model: mbModel(mbInputs(counts: mbCounts(done: 11841, needs: 2)), done: mbDone),
    statusPrefix: nil, statusHas: [], header: "Ready", permission: "2 files need permission to be read",
    actions: [], counts: mbDoneRows)

private let mbNotStarted = MBCase(
    name: "Not started",
    model: mbModel(mbInputs(startPressed: false, walkDone: false, counts: mbCounts())),
    statusPrefix: "Indexing has not been started", statusHas: ["Indexing has not been started"],
    header: "Ready, Indexing has not been started", permission: nil,
    actions: [], counts: [])

private let mbAllCases = [mbDownloading, mbIndexing, mbPausedByYou, mbPausedOnBattery, mbPausedYouAndBattery, mbPausedByCPU,
                          mbPausedLowPower, mbReady, mbReadyWithLockedFiles, mbNotStarted]

private func mbEntries(_ menu: NSMenu) -> [NSMenuItem] { menu.items.filter { !$0.isSeparatorItem } }

/// Everything wrong with the menu built for a case, in plain words; empty when the menu is as the hand-written table says.
@MainActor
private func mbProblems(_ c: MBCase) -> [String] {
    var bad: [String] = []
    func fail(_ text: String) { bad.append("\(c.name): \(text)") }

    let recorder = MBRecorder()
    let menu = MenuBuilder.build(c.model, actions: recorder.actions)
    guard let firstItem = menu.items.first, !firstItem.isSeparatorItem else { return ["\(c.name): the menu is empty or starts with a separator"] }
    if menu.supermenu != nil { fail("the menu is attached to another menu") }
    if menu.items.last?.isSeparatorItem == true { fail("the menu ends with a separator") }
    let items = mbEntries(menu)
    guard items.count >= 4 else {
        fail("only \(items.count) items, too few for the header and the last three")
        return bad
    }
    for item in items where item.title.isEmpty { fail("an item has an empty title") }

    let status = items[0]
    if status.isEnabled { fail("the status line is enabled") }
    if let prefix = c.statusPrefix, !status.title.hasPrefix(prefix) { fail("the status line is \(status.title.debugDescription), want it to start with \(prefix.debugDescription)") }
    for word in c.statusHas where !status.title.contains(word) { fail("the status line \(status.title.debugDescription) lacks \(word.debugDescription)") }
    if status.accessibilityLabel().orEmpty != c.header { fail("the header's accessibility label is \(status.accessibilityLabel().orEmpty.debugDescription), want \(c.header.debugDescription)") }
    if status.view == nil { fail("the status line has no header view") }
    for item in items.dropFirst() where item.view != nil { fail("\(item.title.debugDescription) has a custom view") }

    let tail = Array(items.suffix(3))
    for (item, title) in zip(tail, [mbOpen, mbSettings, mbQuit]) {
        if item.title != title { fail("the last three are \(tail.map(\.title)), want \(mbOpen), \(mbSettings), \(mbQuit)"); break }
        if !item.isEnabled { fail("\(title.debugDescription) is disabled") }
        if item.accessibilityLabel().orEmpty != title { fail("\(title.debugDescription) has the accessibility description \(item.accessibilityLabel().orEmpty.debugDescription)") }
    }

    let middle = Array(items[1..<(items.count - 3)])
    let infoTitles = (c.permission.map { [$0] } ?? []) + c.counts.map { "\($0.label): \($0.number)" }
    let wanted = c.actions + infoTitles
    if middle.map(\.title) != wanted { fail("between the header and \(mbOpen) the items are \(middle.map(\.title)), want \(wanted)") }
    for item in middle {
        if c.actions.contains(item.title) {
            if !item.isEnabled { fail("the action \(item.title.debugDescription) is disabled") }
            if item.accessibilityLabel().orEmpty != item.title { fail("\(item.title.debugDescription) has the accessibility description \(item.accessibilityLabel().orEmpty.debugDescription)") }
        } else if item.isEnabled {
            fail("the line \(item.title.debugDescription) is enabled")
        }
    }
    for row in c.counts {
        guard let item = middle.first(where: { $0.title == "\(row.label): \(row.number)" }) else { continue }
        let description = item.accessibilityLabel().orEmpty
        if !description.contains(row.label) || !description.contains(row.number) { fail("the row \(item.title.debugDescription) has the accessibility description \(description.debugDescription)") }
    }
    if let slash = items.first(where: { $0.title.contains("/") }) {
        fail("\(slash.title.debugDescription) shows a path")
    }
    if c.permission == nil, let stray = items.first(where: { $0.title.contains("need permission") || $0.title.contains("needs permission") }) {
        fail("\(stray.title.debugDescription) is shown but no file needs permission")
    }

    var shape = ["H"]
    for size in [c.actions.count, infoTitles.count, 2, 1] where size > 0 {
        shape.append("S")
        shape += Array(repeating: "I", count: size)
    }
    let actualShape = menu.items.enumerated().map { $0.element.isSeparatorItem ? "S" : ($0.offset == 0 ? "H" : "I") }
    if actualShape != shape { fail("the item kinds are \(actualShape), want \(shape)") }
    return bad
}

/// What a click on an item does: its action sent to its target. No window, no status item and no `NSApplication` is involved.
@MainActor
private func mbInvoke(_ menu: NSMenu, at index: Int) {
    let item = menu.items[index]
    guard let action = item.action, let target = item.target as? NSObject, target.responds(to: action) else {
        Issue.record("the item \(item.title.debugDescription) has no action, or its target does not respond to it")
        return
    }
    _ = target.perform(action, with: item)
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/// All the images of the four states, built once per call.
@MainActor
private func mbIcons() -> [(state: MenuState, image: NSImage?)] {
    [MenuState.downloading, .indexing, .paused, .ready].map { ($0, StatusIcons.image(for: $0)) }
}

private func mbHasInk(_ image: NSImage) -> Bool {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { return true }
        }
    }
    return false
}

@MainActor
@Suite("MenuBuilderTests", .serialized)
struct MenuBuilderTests {

    // MARK: the menu, state by state, against the hand-written table

    @Test func downloadingMenu() { mbExpectClean(mbDownloading) }
    @Test func indexingMenu() { mbExpectClean(mbIndexing) }
    @Test func pausedByYouMenu() { mbExpectClean(mbPausedByYou) }
    @Test func pausedOnBatteryMenuOffersOnlyResumeAnywayAndTheRest() { mbExpectClean(mbPausedOnBattery) }
    @Test func pausedByYouAndOnBatteryMenuOffersBothResumes() { mbExpectClean(mbPausedYouAndBattery) }
    @Test func pausedByTheCPUMenu() { mbExpectClean(mbPausedByCPU) }
    @Test func pausedByLowPowerModeMenu() { mbExpectClean(mbPausedLowPower) }
    @Test func readyMenu() { mbExpectClean(mbReady) }

    @Test func aDoneCodeCountIsNeverAMenuLineAndFiveCountLinesRemainInOrder() {
        let done = ["photo": 3, "pdf": 2, "doc": 1, "audio": 1, "video": 1, "code": 5]
        let model = mbModel(mbInputs(counts: mbCounts(done: 13)), done: done)
        let items = mbEntries(MenuBuilder.build(model, actions: MBRecorder().actions))
        #expect(!items.contains { $0.title.localizedCaseInsensitiveContains("code") || ($0.accessibilityLabel() ?? "").localizedCaseInsensitiveContains("code") },
                "an item names code: \(items.map(\.title))")
        #expect(!items.contains { $0.title == mbPause }, "a Ready menu holds \(mbPause): \(items.map(\.title))")
        let middle = Array(items[1..<(items.count - 3)])
        let lines = middle.filter { $0.title.contains { $0.isNumber } }
        #expect(lines.map(\.title) == ["Photos: 3", "PDFs: 2", "Documents: 1", "Audio: 1", "Video: 1"],
                "count lines: \(lines.map(\.title)); the middle holds \(middle.map(\.title))")
        #expect(middle.count == 5, "the middle holds \(middle.map(\.title))")
        #expect(lines.allSatisfy { !$0.isEnabled }, "a count line is enabled: \(lines.map(\.title))")
        #expect(items.suffix(3).map(\.title) == [mbOpen, mbSettings, mbQuit], "the last three: \(items.suffix(3).map(\.title))")
    }

    @Test func aDoneCodeCountBesideNoOtherKindLeavesNoCountLine() {
        let model = mbModel(mbInputs(counts: mbCounts(done: 5)), done: ["code": 5])
        let items = mbEntries(MenuBuilder.build(model, actions: MBRecorder().actions))
        #expect(!items.contains { $0.title.localizedCaseInsensitiveContains("code") }, "an item names code: \(items.map(\.title))")
        #expect(!items.contains { $0.title.contains("5") && !$0.title.contains("%") }, "a line shows the code count: \(items.map(\.title))")
    }
    @Test func readyMenuNamesTheFilesThatNeedPermission() { mbExpectClean(mbReadyWithLockedFiles) }
    @Test func notStartedMenu() { mbExpectClean(mbNotStarted) }

    private func mbExpectClean(_ c: MBCase) {
        let bad = mbProblems(c)
        #expect(bad.isEmpty, "\(bad.count) problems: \(bad)")
    }

    @Test func theTableCoversTheSixStatesOfTheEntry() {
        #expect(mbAllCases.count >= 8, "the table has \(mbAllCases.count) cases")
        let names = Set(mbAllCases.map(\.name))
        for state in ["Downloading", "Indexing", "Paused by you", "Paused on battery", "Ready", "Not started"] {
            #expect(names.contains(state), "no case for \(state)")
        }
    }

    @Test func theResumeAnywayItemIsInNoMenuButTheBatteryOnes() {
        for c in mbAllCases {
            let titles = mbEntries(MenuBuilder.build(c.model, actions: MBRecorder().actions)).map(\.title)
            let count = titles.filter { $0 == mbAnyway }.count
            let wantsIt = c.actions.contains(mbAnyway)
            #expect(count == (wantsIt ? 1 : 0), "\(c.name): \"\(mbAnyway)\" appears \(count) times in \(titles)")
        }
    }

    @Test func aBuiltMenuIsNotAttachedToAnything() {
        for c in mbAllCases {
            let menu = MenuBuilder.build(c.model, actions: MBRecorder().actions)
            #expect(menu.supermenu == nil, "\(c.name): the menu has a supermenu")
            #expect(!menu.items.isEmpty, "\(c.name): the menu is empty")
        }
    }

    // MARK: invoking each item runs its own closure, once

    @Test func eachActionItemRunsItsOwnClosureOnce() {
        let rows: [(MBCase, String, String)] = [
            (mbIndexing, mbPause, "pause"),
            (mbPausedByYou, mbResume, "resume"),
            (mbPausedYouAndBattery, mbResume, "resume"),
            (mbPausedOnBattery, mbAnyway, "resumeAnyway"),
            (mbPausedYouAndBattery, mbAnyway, "resumeAnyway"),
        ] + mbAllCases.flatMap { c in [(c, mbOpen, "open"), (c, mbSettings, "settings"), (c, mbQuit, "quit")] }
        var bad: [String] = []
        for (c, title, want) in rows {
            let recorder = MBRecorder()
            let menu = MenuBuilder.build(c.model, actions: recorder.actions)
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                bad.append("\(c.name): no item \(title.debugDescription)")
                continue
            }
            mbInvoke(menu, at: index)
            if recorder.log != [want] { bad.append("\(c.name): \(title.debugDescription) ran \(recorder.log), want [\(want)]") }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong: \(bad)")
    }

    @Test func invokingEveryItemOfOneMenuInTurnRunsEachClosureOnceInThatOrder() {
        let recorder = MBRecorder()
        let menu = MenuBuilder.build(mbPausedYouAndBattery.model, actions: recorder.actions)
        var want: [String] = []
        for (title, name) in [(mbResume, "resume"), (mbAnyway, "resumeAnyway"), (mbOpen, "open"), (mbSettings, "settings"), (mbQuit, "quit")] {
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                Issue.record("no item \(title.debugDescription)")
                continue
            }
            mbInvoke(menu, at: index)
            want.append(name)
            #expect(recorder.log == want, "after \(title.debugDescription): \(recorder.log), want \(want)")
        }
    }

    @Test func buildingAMenuRunsNoClosure() {
        for c in mbAllCases {
            let recorder = MBRecorder()
            _ = MenuBuilder.build(c.model, actions: recorder.actions)
            #expect(recorder.log.isEmpty, "\(c.name): building ran \(recorder.log)")
        }
    }

    // MARK: the icons

    @Test func eachOfTheFourStatesHasANonNilTemplateImageOfMenuBarSize() {
        let icons = mbIcons()
        #expect(icons.count == 4)
        for (state, image) in icons {
            guard let image else { Issue.record("\(state): image(for:) is nil"); continue }
            #expect(image.isTemplate, "\(state): the image is not a template image")
            #expect((14...24).contains(image.size.width) && (14...24).contains(image.size.height),
                    "\(state): size \(image.size) is not a menu bar size")
            #expect(mbHasInk(image), "\(state): the image draws nothing")
        }
    }

    @Test func theFourImagesAreDistinctFromEachOther() {
        let icons = mbIcons()
        let data = icons.map { $0.image?.tiffRepresentation }
        for i in icons.indices {
            #expect(data[i] != nil, "\(icons[i].state): no pixels")
            for j in icons.indices where j > i {
                #expect(data[i] != data[j], "\(icons[i].state) and \(icons[j].state) draw the same image")
            }
        }
    }

    @Test func theFourImagesShareOneSize() {
        let sizes = mbIcons().compactMap { $0.image?.size }
        #expect(sizes.count == 4)
        #expect(Set(sizes.map { "\($0.width)x\($0.height)" }).count == 1, "sizes differ: \(sizes)")
    }

    // MARK: the controller over a fake status item

    private let mbLabelRows: [(name: String, model: MenuModel, label: String)] = [
        ("Ready", mbModel(mbInputs(counts: mbCounts(done: 4))), "Sesame: ready"),
        ("not started", mbModel(mbInputs(startPressed: false, walkDone: false, counts: mbCounts())), "Sesame: ready"),
        ("Indexing", mbModel(mbInputs(counts: mbPendingCounts)), "Sesame: indexing, 62 percent"),
        ("Indexing at 0", mbModel(mbInputs(walkDone: false, counts: mbCounts())), "Sesame: indexing, 0 percent"),
        ("Paused by you", mbModel(mbInputs(counts: mbPendingCounts, reasons: [.you])), "Sesame: paused"),
        ("Paused on battery", mbModel(mbInputs(counts: mbPendingCounts, reasons: [.battery])), "Sesame: paused"),
        ("Downloading", mbModel(mbInputs(model: .downloading, startPressed: false, walkDone: false, counts: mbCounts()), percent: 34),
         "Sesame: downloading the model, 34 percent"),
    ]

    @Test func theButtonGetsTheAccessibilityLabelAndTheTitleOfEachState() {
        var bad: [String] = []
        for row in mbLabelRows {
            let host = MBFakeHost()
            let controller = MenuBarController(host: host, actions: MBRecorder().actions)
            controller.update(row.model)
            if host.buttonAccessibilityLabel != row.label { bad.append("\(row.name): label \(host.buttonAccessibilityLabel.debugDescription), want \(row.label.debugDescription)") }
            if host.buttonTitle != row.label { bad.append("\(row.name): title \(host.buttonTitle.debugDescription), want \(row.label.debugDescription)") }
            if host.buttonAccessibilityLabel.isEmpty || host.buttonTitle.isEmpty { bad.append("\(row.name): the label or the title is empty") }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong: \(bad)")
    }

    @Test func theLabelAndTheTitleFollowTheModelAcrossUpdatesOnOneController() {
        let host = MBFakeHost()
        let controller = MenuBarController(host: host, actions: MBRecorder().actions)
        for row in mbLabelRows + mbLabelRows.reversed() {
            controller.update(row.model)
            #expect(host.buttonAccessibilityLabel == row.label, "\(row.name): label \(host.buttonAccessibilityLabel.debugDescription)")
            #expect(host.buttonTitle == row.label, "\(row.name): title \(host.buttonTitle.debugDescription)")
        }
    }

    @Test func theButtonImageIsATemplateImageThatDiffersForEachOfTheFourStates() {
        var images: [(String, Data?)] = []
        for (name, model) in [("Ready", mbReady.model), ("Indexing", mbIndexing.model), ("Paused", mbPausedByYou.model),
                              ("Downloading", mbDownloading.model)] {
            let host = MBFakeHost()
            let controller = MenuBarController(host: host, actions: MBRecorder().actions)
            controller.update(model)
            guard let image = host.buttonImage else { Issue.record("\(name): the button has no image"); continue }
            #expect(image.isTemplate, "\(name): the button image is not a template image")
            images.append((name, image.tiffRepresentation))
        }
        #expect(images.count == 4)
        for i in images.indices {
            for j in images.indices where j > i {
                #expect(images[i].1 != images[j].1, "\(images[i].0) and \(images[j].0) show the same image on the button")
            }
        }
    }

    @Test func theButtonImageChangesWhenTheStateChangesOnOneController() {
        let host = MBFakeHost()
        let controller = MenuBarController(host: host, actions: MBRecorder().actions)
        controller.update(mbIndexing.model)
        let indexing = host.buttonImage?.tiffRepresentation
        controller.update(mbPausedByYou.model)
        let paused = host.buttonImage?.tiffRepresentation
        controller.update(mbIndexing.model)
        let again = host.buttonImage?.tiffRepresentation
        #expect(indexing != nil && paused != nil)
        #expect(indexing != paused, "Indexing and Paused show the same image")
        #expect(again == indexing, "Indexing again does not show the Indexing image")
    }

    @Test func theMenuTheControllerSetsIsTheBuiltMenuAndItsItemsRunTheActions() {
        let host = MBFakeHost()
        let recorder = MBRecorder()
        let controller = MenuBarController(host: host, actions: recorder.actions)
        controller.update(mbIndexing.model)
        guard let menu = host.menu else { Issue.record("the controller set no menu"); return }
        let items = mbEntries(menu)
        #expect(items.first?.title.hasPrefix("Indexing 62%") == true, "first item is \(String(describing: items.first?.title))")
        #expect(items.suffix(3).map(\.title) == [mbOpen, mbSettings, mbQuit], "last three are \(items.suffix(3).map(\.title))")
        for (title, name) in [(mbPause, "pause"), (mbSettings, "settings"), (mbQuit, "quit"), (mbOpen, "open")] {
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else { Issue.record("no item \(title)"); continue }
            let before = recorder.log.count
            mbInvoke(menu, at: index)
            #expect(Array(recorder.log.dropFirst(before)) == [name], "\(title): ran \(recorder.log.dropFirst(before))")
        }
    }

    @Test func theMenuIsReplacedOnlyWhenTheModelChanged() {
        let host = MBFakeHost()
        let controller = MenuBarController(host: host, actions: MBRecorder().actions)
        func fresh(percent: Int = 7400, done: [String: Int] = mbDone, reasons: Set<PauseReason> = []) -> MenuModel {
            // each call builds the model again from the same numbers, so the test never relies on object identity
            mbModel(mbInputs(counts: mbCounts(done: percent, pending: ["photo": 4520]), reasons: reasons), done: done)
        }
        controller.update(fresh())
        let first = host.menuAssignments
        #expect(first >= 1, "the first update set no menu")

        controller.update(fresh())
        controller.update(fresh())
        #expect(host.menuAssignments == first, "the same model again replaced the menu: \(host.menuAssignments) assignments, was \(first)")

        let steps: [(String, MenuModel)] = [
            ("the percent moved", fresh(percent: 7600)),
            ("a count changed, the label did not", fresh(percent: 7600, done: ["photo": 9691, "pdf": 1083, "doc": 1068])),
            ("a pause reason was added", fresh(percent: 7600, done: ["photo": 9691, "pdf": 1083, "doc": 1068], reasons: [.you])),
        ]
        var count = host.menuAssignments
        for (what, model) in steps {
            controller.update(model)
            #expect(host.menuAssignments == count + 1, "\(what): \(host.menuAssignments) assignments, want \(count + 1)")
            count = host.menuAssignments
            controller.update(model)
            #expect(host.menuAssignments == count, "\(what): the same model again replaced the menu")
        }
    }

    @Test func aReplacedMenuShowsTheNewModel() {
        let host = MBFakeHost()
        let controller = MenuBarController(host: host, actions: MBRecorder().actions)
        controller.update(mbIndexing.model)
        controller.update(mbPausedOnBattery.model)
        let titles = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(titles.first?.hasPrefix("Paused: on battery") == true, "first item is \(String(describing: titles.first))")
        #expect(titles.contains(mbAnyway), "\"\(mbAnyway)\" is not in \(titles)")
        controller.update(mbIndexing.model)
        let back = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(back.first?.hasPrefix("Indexing 62%") == true, "first item is \(String(describing: back.first))")
        #expect(!back.contains(mbAnyway), "\"\(mbAnyway)\" is still in \(back)")
    }
}

// =================================================================================================================
// plan-2 fix round D, tester step, item D1 (R3-01): the menu of a failed model download. Written from the fix-round
// document ("add a failed state to `MenuState`/`MenuModel` ... the status line 'Model download failed', the first action
// disabled") and the shapes pinned in MenuStateTests (round D block: `ModelState.failed`, `MenuState.failed`, the texts).
// ROUND E (E1) re-pin: "Pause indexing" disabled is now an enabled "Retry model download" (see the round E block at the end).
// No product source was read. The menu: the status line first and disabled, "Pause indexing" disabled (never "Resume
// indexing" or "Resume anyway"), then "Open Sesame", "Settings…" and "Quit Sesame" enabled, so the person can reach
// Settings. Not pinned: the count rows while the download failed. The icon of `.failed` is a template
// menu bar image like the others.
// =================================================================================================================

private let mbFailed = MBCase(
    name: "Download failed",
    model: mbModel(mbInputs(model: .failed, startPressed: true, walkDone: false, counts: mbCounts()), percent: 34),
    statusPrefix: "Model download failed", statusHas: ["Model download failed"], header: "Model download failed", permission: nil,
    actions: [mbRetry], counts: [])

private let mbFailedWhileBatteryPause = MBCase(
    name: "Download failed while paused on battery",
    model: mbModel(mbInputs(model: .failed, counts: mbPendingCounts, reasons: [.battery]), done: mbDone),
    statusPrefix: "Model download failed", statusHas: ["Model download failed"], header: "Model download failed", permission: nil,
    actions: [mbRetry], counts: mbDoneRows)

extension MenuBuilderTests {

    @Test func failedMenu() { mbExpectClean(mbFailed) }

    @Test func aFailedDownloadWithPauseReasonsAndCountsStillShowsOnlyTheFailureAndThePlainActions() {
        mbExpectClean(mbFailedWhileBatteryPause)
        let titles = mbEntries(MenuBuilder.build(mbFailedWhileBatteryPause.model, actions: MBRecorder().actions)).map(\.title)
        #expect(!titles.contains(mbAnyway), "\"\(mbAnyway)\" is offered while the download failed: \(titles)")
        #expect(!titles.contains(mbResume), "\"\(mbResume)\" is offered while the download failed: \(titles)")
    }

    @Test func theFailedMenusOpenSettingsAndQuitRunTheirOwnClosureOnce() {
        for (title, want) in [(mbOpen, "open"), (mbSettings, "settings"), (mbQuit, "quit")] {
            let recorder = MBRecorder()
            let menu = MenuBuilder.build(mbFailed.model, actions: recorder.actions)
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                Issue.record("no item \(title.debugDescription) in the failed menu")
                continue
            }
            mbInvoke(menu, at: index)
            #expect(recorder.log == [want], "\(title.debugDescription) ran \(recorder.log), want [\(want)]")
        }
    }

    @Test func theFailedStateHasANonNilTemplateImageOfTheSameSizeAsTheOthers() {
        let made: NSImage? = StatusIcons.image(for: .failed)
        guard let image = made else { Issue.record("image(for: .failed) is nil"); return }
        #expect(image.isTemplate, "the failed image is not a template image")
        #expect((14...24).contains(image.size.width) && (14...24).contains(image.size.height), "size \(image.size) is not a menu bar size")
        #expect(mbHasInk(image), "the failed image draws nothing")
        let others = mbIcons().compactMap { $0.image?.size }
        #expect(others.allSatisfy { $0 == image.size }, "sizes differ: failed \(image.size), others \(others)")
    }

    @Test func theButtonOfAFailedDownloadReadsModelDownloadFailedAndShowsATemplateImage() {
        let host = MBFakeHost()
        let controller = MenuBarController(host: host, actions: MBRecorder().actions)
        controller.update(mbFailed.model)
        #expect(host.buttonAccessibilityLabel == "Sesame: model download failed", "label \(host.buttonAccessibilityLabel.debugDescription)")
        #expect(host.buttonTitle == "Sesame: model download failed", "title \(host.buttonTitle.debugDescription)")
        #expect(host.buttonImage?.isTemplate == true, "the button image is missing or not a template")
        let titles = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(titles.first?.hasPrefix("Model download failed") == true, "first item is \(String(describing: titles.first))")

        // the menu follows: back to downloading, the failure line is gone
        controller.update(mbDownloading.model)
        #expect(host.buttonAccessibilityLabel == "Sesame: downloading the model, 34 percent", "label \(host.buttonAccessibilityLabel.debugDescription)")
        let again = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(again.first?.hasPrefix("Model download failed") == false, "the failure line stays after the download restarted: \(again)")
    }
}

// =================================================================================================================
// plan-2 fix round E, tester step, item E1 (R4-01): the failed menu gives the person the way back to Retry. Written from
// the fix-round document ("the failed menu's first action becomes an enabled 'Retry model download' (in place of the
// disabled 'Pause indexing') ... `MenuActions` gets a `retryDownload` closure"). No product source was read.
//
// SHAPE E1 pins here (new): `MenuActions.init(pause:, resume:, resumeAnyway:, retryDownload:, open:, settings:, quit:)`,
// seven `() -> Void` closures in this order; `retryDownload` sits between `resumeAnyway` and `open`. It has no default
// value, so a missing closure is a compile error at the one real call (MenuActions.swift). The failed menu is: the status
// line "Model download failed" (first, disabled), then "Retry model download" (enabled, its accessibility description is
// its title), then the rest as in round D (no Pause, no Resume, no "Resume anyway", then Open Sesame, Settings…, Quit
// Sesame). Choosing "Retry model download" runs `retryDownload` once and nothing else. No other state's menu holds the
// item. The sealed round D tests above that said "Pause indexing disabled" for the failed menu are re-pinned (`mbFailed`,
// `mbFailedWhileBatteryPause`, and the first-action search of `mbProblems`); every other sealed test is unchanged.
// =================================================================================================================

extension MenuBuilderTests {

    @Test func theFailedMenuHasNoPauseOrResumeAndOneEnabledRetryModelDownload() {
        for c in [mbFailed, mbFailedWhileBatteryPause] {
            let titles = mbEntries(MenuBuilder.build(c.model, actions: MBRecorder().actions)).map(\.title)
            #expect(!titles.contains(mbPause), "\(c.name): \"\(mbPause)\" is still in \(titles)")
            #expect(!titles.contains(mbResume), "\(c.name): \"\(mbResume)\" is in \(titles)")
            #expect(!titles.contains(mbAnyway), "\(c.name): \"\(mbAnyway)\" is in \(titles)")
            #expect(titles.filter { $0 == mbRetry }.count == 1, "\(c.name): \"\(mbRetry)\" appears \(titles.filter { $0 == mbRetry }.count) times in \(titles)")
            let menu = MenuBuilder.build(c.model, actions: MBRecorder().actions)
            let item = menu.items.first { $0.title == mbRetry }
            #expect(item?.isEnabled == true, "\(c.name): the Retry item is missing or disabled")
            #expect(item?.accessibilityLabel() == mbRetry, "\(c.name): the Retry item's accessibility description is \(String(describing: item?.accessibilityLabel()))")
        }
    }

    @Test func choosingRetryModelDownloadRunsTheRetryClosureOnceAndNothingElse() {
        for c in [mbFailed, mbFailedWhileBatteryPause] {
            let recorder = MBRecorder()
            let menu = MenuBuilder.build(c.model, actions: recorder.actions)
            guard let index = menu.items.firstIndex(where: { $0.title == mbRetry }) else {
                Issue.record("\(c.name): no item \(mbRetry.debugDescription)")
                continue
            }
            mbInvoke(menu, at: index)
            #expect(recorder.log == ["retryDownload"], "\(c.name): choosing Retry ran \(recorder.log), want [retryDownload]")
        }
    }

    @Test func theRetryItemIsInNoMenuButTheFailedOnes() {
        for c in mbAllCases {
            let titles = mbEntries(MenuBuilder.build(c.model, actions: MBRecorder().actions)).map(\.title)
            #expect(!titles.contains(mbRetry), "\(c.name): \"\(mbRetry)\" is in \(titles)")
        }
    }

    @Test func theControllerOfAFailedDownloadBuildsTheMenuWithRetryAndTheItemRunsTheClosure() {
        let host = MBFakeHost()
        let recorder = MBRecorder()
        let controller = MenuBarController(host: host, actions: recorder.actions)
        controller.update(mbFailed.model)
        guard let menu = host.menu, let index = menu.items.firstIndex(where: { $0.title == mbRetry }) else {
            Issue.record("the controller's failed menu has no \(mbRetry.debugDescription) item")
            return
        }
        mbInvoke(menu, at: index)
        #expect(recorder.log == ["retryDownload"], "choosing Retry ran \(recorder.log)")
        // the menu follows the model: back to downloading, no Retry
        controller.update(mbDownloading.model)
        let again = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(!again.contains(mbRetry), "Retry stays in the menu after the download restarted: \(again)")
    }
}

// =================================================================================================================
// plan-3-t21, tester step: the menu of a stalled helper (S7.1, S7.2, S7.12). Written from the t21 entry of plan-3-tasks.md
// (its Tests paragraph) and the shapes pinned in MenuStateTests (the t21 block at its end: `PauseReason.stalled`, the one
// status text). No product source was read. Every expected title and flag is written by hand.
//
// The menu: the status line "Paused: indexing stopped, press Resume to try again" first and disabled (its accessibility
// description holds the same words), then "Resume indexing" ENABLED (with its accessibility description, its title), then
// the rest as in any paused menu. Choosing it runs the `resume` closure once, so `MenuActions.live` can clear the stall
// (AppLifecycleTests). No other closure runs. With the battery reason also set, "Resume anyway, on battery" follows, enabled.
// =================================================================================================================

private let mbStalledText = "Paused: indexing stopped, press Resume to try again"
private let mbStalledHeader = "Paused, Indexing stopped, press Resume"

private let mbStalled = MBCase(
    name: "Stalled",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.stalled]), done: mbDone),
    statusPrefix: mbStalledText, statusHas: [mbStalledText], header: mbStalledHeader, permission: nil,
    actions: [mbResume], counts: mbDoneRows)

private let mbStalledAndBusy = MBCase(
    name: "Stalled and the Mac is busy",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.stalled, .cpu]), done: mbDone),
    statusPrefix: mbStalledText, statusHas: [mbStalledText], header: mbStalledHeader, permission: nil,
    actions: [mbResume], counts: mbDoneRows)

private let mbStalledOnBattery = MBCase(
    name: "Stalled and on battery",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.stalled, .battery]), done: mbDone),
    statusPrefix: mbStalledText, statusHas: [mbStalledText], header: mbStalledHeader, permission: nil,
    actions: [mbResume, mbAnyway], counts: mbDoneRows)

private let mbStalledAndYou = MBCase(
    name: "Stalled and paused by you",
    model: mbModel(mbInputs(counts: mbPendingCounts, reasons: [.you, .stalled]), done: mbDone),
    statusPrefix: "Paused by you", statusHas: ["Paused by you"], header: "Paused, By you", permission: nil,
    actions: [mbResume], counts: mbDoneRows)

private let mbStalledCases = [mbStalled, mbStalledAndBusy, mbStalledOnBattery, mbStalledAndYou]

extension MenuBuilderTests {

    @Test func stalledMenu() { mbExpectClean(mbStalled) }
    @Test func stalledWhileTheMacIsBusyMenuStillOffersAnEnabledResume() { mbExpectClean(mbStalledAndBusy) }
    @Test func stalledOnBatteryMenuOffersBothEnabledResumes() { mbExpectClean(mbStalledOnBattery) }
    @Test func stalledAndPausedByYouMenuSaysPausedByYouAndOffersResume() { mbExpectClean(mbStalledAndYou) }

    @Test func theStalledMenuHasOneEnabledResumeIndexingAndNoPauseRetryOrDownloadLine() {
        for c in mbStalledCases {
            let menu = MenuBuilder.build(c.model, actions: MBRecorder().actions)
            let titles = mbEntries(menu).map(\.title)
            #expect(titles.filter { $0 == mbResume }.count == 1, "\(c.name): \"\(mbResume)\" appears \(titles.filter { $0 == mbResume }.count) times in \(titles)")
            #expect(!titles.contains(mbPause), "\(c.name): \"\(mbPause)\" is in \(titles)")
            #expect(!titles.contains(mbRetry), "\(c.name): \"\(mbRetry)\" is in \(titles)")
            let item = menu.items.first { $0.title == mbResume }
            #expect(item?.isEnabled == true, "\(c.name): the Resume item is missing or disabled")
            #expect(item?.accessibilityLabel() == mbResume, "\(c.name): the Resume item's accessibility description is \(String(describing: item?.accessibilityLabel()))")
        }
    }

    @Test func theStalledStatusLineIsDisabledAndItsAccessibilityDescriptionHoldsTheText() {
        let menu = MenuBuilder.build(mbStalled.model, actions: MBRecorder().actions)
        guard let first = mbEntries(menu).first else { Issue.record("the stalled menu is empty"); return }
        #expect(first.title == mbStalledText, "first item is \(first.title.debugDescription)")
        #expect(!first.isEnabled, "the status line is enabled")
        #expect(first.accessibilityLabel() == mbStalledHeader, "accessibility description \(String(describing: first.accessibilityLabel()))")
    }

    @Test func choosingResumeInTheStalledMenuRunsTheResumeClosureOnceAndNothingElse() {
        for c in mbStalledCases {
            let recorder = MBRecorder()
            let menu = MenuBuilder.build(c.model, actions: recorder.actions)
            guard let index = menu.items.firstIndex(where: { $0.title == mbResume }) else {
                Issue.record("\(c.name): no item \(mbResume.debugDescription)")
                continue
            }
            mbInvoke(menu, at: index)
            #expect(recorder.log == ["resume"], "\(c.name): choosing Resume ran \(recorder.log), want [resume]")
        }
    }

    @Test func theStalledMenusOpenSettingsAndQuitRunTheirOwnClosureOnce() {
        for (title, want) in [(mbOpen, "open"), (mbSettings, "settings"), (mbQuit, "quit")] {
            let recorder = MBRecorder()
            let menu = MenuBuilder.build(mbStalled.model, actions: recorder.actions)
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                Issue.record("no item \(title.debugDescription) in the stalled menu")
                continue
            }
            mbInvoke(menu, at: index)
            #expect(recorder.log == [want], "\(title.debugDescription) ran \(recorder.log), want [\(want)]")
        }
    }

    @Test func theResumeAnywayItemIsInTheStalledMenuOnlyWithTheBatteryReason() {
        for c in mbStalledCases {
            let titles = mbEntries(MenuBuilder.build(c.model, actions: MBRecorder().actions)).map(\.title)
            let count = titles.filter { $0 == mbAnyway }.count
            let wantsIt = c.actions.contains(mbAnyway)
            #expect(count == (wantsIt ? 1 : 0), "\(c.name): \"\(mbAnyway)\" appears \(count) times in \(titles)")
        }
    }

    @Test func theButtonOfAStalledHelperReadsSesamePausedAndShowsThePausedImage() {
        let host = MBFakeHost()
        let controller = MenuBarController(host: host, actions: MBRecorder().actions)
        controller.update(mbStalled.model)
        #expect(host.buttonAccessibilityLabel == "Sesame: paused", "label \(host.buttonAccessibilityLabel.debugDescription)")
        #expect(host.buttonTitle == "Sesame: paused", "title \(host.buttonTitle.debugDescription)")
        guard let image = host.buttonImage else { Issue.record("the button has no image"); return }
        #expect(image.isTemplate, "the button image is not a template image")
        let paused: NSImage? = StatusIcons.image(for: .paused)
        #expect(image.tiffRepresentation == paused?.tiffRepresentation, "the stalled button does not show the Paused image")
    }

    @Test func theControllerReplacesTheMenuWhenAStallStartsAndWhenItIsCleared() {
        let host = MBFakeHost()
        let controller = MenuBarController(host: host, actions: MBRecorder().actions)
        controller.update(mbIndexing.model)
        #expect(host.buttonAccessibilityLabel == "Sesame: indexing, 62 percent", "label \(host.buttonAccessibilityLabel.debugDescription)")
        let before = host.menuAssignments

        // the label does not say why, so a stall changes the menu while the label is the same as "paused by you"
        controller.update(mbStalled.model)
        #expect(host.menuAssignments == before + 1, "the stall did not replace the menu: \(host.menuAssignments) assignments, was \(before)")
        let stalled = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(stalled.first == mbStalledText, "first item is \(String(describing: stalled.first))")
        #expect(stalled.contains(mbResume), "\"\(mbResume)\" is not in \(stalled)")

        controller.update(mbStalled.model)
        #expect(host.menuAssignments == before + 1, "the same stalled model replaced the menu again")

        // paused by you, then stalled: the status line changes though the label is "Sesame: paused" both times
        controller.update(mbPausedByYou.model)
        let byYou = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(byYou.first?.hasPrefix("Paused by you") == true, "first item is \(String(describing: byYou.first))")
        controller.update(mbStalled.model)
        let again = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(again.first == mbStalledText, "paused by you to stalled left the status line at \(String(describing: again.first))")

        // Resume cleared the stall: indexing again, the stalled line is gone
        controller.update(mbIndexing.model)
        let back = host.menu.map { mbEntries($0).map(\.title) } ?? []
        #expect(back.first?.hasPrefix("Indexing 62%") == true, "first item is \(String(describing: back.first))")
        #expect(!back.contains(mbStalledText), "the stalled line stays after the stall was cleared: \(back)")
    }
}
