import AppKit
import Foundation
import Testing
@testable import SesameEngine
@testable import Sesame

private let sfHintTicked = "Indexing starts when you press Start indexing, and runs in the background."
private let sfHintNone = "Tick at least one folder to start."
private let sfReadNote = "Photos, PDFs, documents, audio and video are read."
private let sfStartError = "Could not save the settings, so indexing did not start."
private let sfRunning = "Indexing is running. Watch it from the magnifier in the menu bar."
private let sfShortcutNote = "You can change the shortcut later in Settings."
private let sfShortcutLead = "Press these keys together."
private let sfAdd = "Add folder\u{2026}"
private let sfLong = "Photos-from-the-summer-trip-to-the-coast"

private final class SFGate: @unchecked Sendable {
    private let cond = NSCondition()
    private var held = true

    func release() { cond.lock(); held = false; cond.broadcast(); cond.unlock() }

    func enter() {
        cond.lock()
        while held { cond.wait() }
        cond.unlock()
    }
}

private func sfStarted(_ env: SLEnv) throws -> Settings {
    var held = Settings()
    held.startPressed = true
    return held
}

@MainActor
private func sfEventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func sfRoot(_ rig: SLRig, _ look: DTLook = .light) -> NSView {
    let root = rig.window.contentView!
    root.appearance = dtAppearance(look)
    root.layoutSubtreeIfNeeded()
    return root
}

private func sfSettingsURL(_ rig: SLRig) -> URL {
    rig.env.models.deletingLastPathComponent().appendingPathComponent("settings.json")
}

private func sfSettings(_ rig: SLRig) -> NSDictionary? {
    guard let data = try? Data(contentsOf: sfSettingsURL(rig)) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

private func sfStartPressed(_ rig: SLRig) -> Bool {
    (sfSettings(rig)?["startPressed"] as? Bool) ?? false
}

private func sfEntry(_ rig: SLRig, _ name: String) -> NSDictionary? {
    let path = rig.env.home.appendingPathComponent(name).path
    return ((sfSettings(rig)?["folders"] as? [NSDictionary]) ?? []).first { ($0["path"] as? String) == path }
}

@MainActor
private func sfRows(_ root: NSView, _ rig: SLRig) -> [NSButton] {
    slButtons(root)
        .filter { ($0.accessibilityHelp() ?? "").hasPrefix(rig.env.home.path) }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func sfReading(_ root: NSView, _ title: String) -> [NSButton] {
    slButtons(root).filter { $0.title == title || $0.accessibilityLabel() == title || $0.accessibilityTitle() == title }
}

@MainActor
private func sfUntickAll(_ rig: SLRig) async -> Bool {
    let root = sfRoot(rig)
    for row in sfRows(root, rig) where row.state == .on && row.isEnabled { row.performClick(nil) }
    return await sfEventually { rig.folders.rows.allSatisfy { !$0.ticked } }
}

@MainActor
private func sfWaitStep(_ rig: SLRig, _ step: SetupFlow.Step) async -> Bool {
    await sfEventually { rig.window.flow.step == step }
}

@MainActor
private func sfTitleColour(_ button: NSButton) -> NSColor? {
    if button.attributedTitle.length > 0,
       let colour = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
        return colour
    }
    return button.contentTintColor
}

@MainActor
private func sfReturn(_ window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
}

@MainActor
private func sfModelBlock(_ root: NSView) -> PLBox? {
    guard let heading = plText(root, "The search model"), let card = slCard(of: heading) else { return nil }
    return [slButton(root, "Retry")].compactMap { $0 }.reduce(plBox(root, card)) { $0.union(plBox(root, $1)) }
}

@MainActor
private func sfElements(_ root: NSView, _ rig: SLRig) -> [String] {
    var out: [String] = []
    for view in prViews(root) where plVisible(view) {
        if let button = view as? SetupButton {
            out.append((button.accessibilityHelp() ?? "").hasPrefix(rig.env.home.path) ? "row:" + button.title : (button.accessibilityLabel() ?? button.title))
        } else if let dots = view as? StepDots {
            out.append(dots.accessibilityTitle() ?? "")
        } else if let figure = view as? FigureView {
            out.append(figure.accessibilityTitle() ?? "")
        } else if type(of: view) == NSTextField.self, let field = view as? NSTextField, !field.stringValue.isEmpty,
                  !slAncestors(field).contains(where: { $0 is NSScrollView }) {
            out.append(field.stringValue)
        }
    }
    return out
}

@MainActor
private func sfCheckHint(_ root: NSView, _ text: String, _ look: DTLook, _ tag: String) {
    guard let hint = plText(root, text) else {
        Issue.record("\(tag): no hint \"\(text)\" among \(plTexts(root).map(\.stringValue))")
        return
    }
    #expect(slFont(hint.font, size: 12, weight: .regular), "\(tag): hint font \(String(describing: hint.font))")
    #expect(slColour(hint.textColor, is: .secondaryLabelColor), "\(tag): hint colour")
    let mid = swlInkMid(root, hint, look)
    #expect(mid != nil && abs((mid ?? 0) - 280) <= 8, "\(tag): hint ink centre \(String(describing: mid)), window centre 280")
    #expect(!hint.isEditable, "\(tag): the hint is editable")
    let box = plBox(root, hint)
    #expect(box.minX >= 0 && box.maxX <= 560 && box.width <= 524.5, "\(tag): the hint spans \(box.minX) to \(box.maxX)")
    let needed = (text as NSString).boundingRect(
        with: NSSize(width: hint.frame.width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin], attributes: [.font: hint.font ?? NSFont.systemFont(ofSize: 12)]).height
    #expect(hint.frame.height + 0.5 >= needed, "\(tag): the hint frame is \(hint.frame.height) high, its text needs \(needed)")
}

extension ModelDownloadTests {
    @Suite("SetupStartFooterTests", .serialized)
    struct SetupStartFooterTests {

        @MainActor
        @Test(arguments: slPaths) func onFoldersWithAWholeModelAndATickedRowTheFooterIsTheOneAccentReturnButtonTitledStartIndexingAtTheRightTwentyFromTheEdgeAndTheBottom(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let welcomeNext = try #require(slButton(slLayout(rig), "Next"), "no Next on Welcome")
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "\(look)"
                    let start = try #require(slButton(root, "Start indexing"), "\(tag): no Start indexing")
                    #expect(start is SetupButton, "\(tag): not a SetupButton")
                    #expect(start === welcomeNext, "\(tag): the footer button of Folders is not the view that reads Next on Welcome")
                    #expect(start.title == "Start indexing" && start.accessibilityLabel() == "Start indexing", "\(tag): title \(start.title), label \(String(describing: start.accessibilityLabel()))")
                    #expect((start.accessibilityTitle() ?? "").isEmpty || start.accessibilityTitle() == "Start indexing", "\(tag): accessibility title \(String(describing: start.accessibilityTitle()))")
                    #expect(start.isEnabled, "\(tag): Start indexing is disabled with a ticked row and a whole model")
                    #expect(sfReading(root, "Start indexing").count == 1, "\(tag): \(sfReading(root, "Start indexing").count) buttons read Start indexing")
                    #expect(sfReading(root, "Next").isEmpty, "\(tag): a button reads Next beside Start indexing: \(slButtons(root).map { "\($0.title)|\($0.accessibilityLabel() ?? "")" })")
                    let primaries = slButtons(root).filter { $0.keyEquivalent == "\r" }.map(\.title)
                    #expect(primaries == ["Start indexing"], "\(tag): Return buttons \(primaries)")
                    let bezel = glass ? 16 : NSButton.BezelStyle.rounded.rawValue
                    #expect(start.bezelStyle.rawValue == bezel, "\(tag): bezel \(start.bezelStyle.rawValue), wanted \(bezel)")
                    if glass {
                        #expect(slColour(start.bezelColor, is: .controlAccentColor), "\(tag): bezel colour \(String(describing: start.bezelColor))")
                    } else {
                        #expect(start.bezelColor == nil, "\(tag): bezel colour \(String(describing: start.bezelColor))")
                    }
                    let frame = plBox(root, start)
                    let align = slAlignBox(root, start)
                    #expect(abs(frame.maxX - 540) <= 3 || abs(align.maxX - 540) <= 3, "\(tag): right edge \(frame.maxX) / \(align.maxX), wanted 540")
                    #expect(abs((600 - frame.bottom) - 20) <= 2 || abs((600 - align.bottom) - 20) <= 2, "\(tag): bottom gap \(600 - frame.bottom) / \(600 - align.bottom), wanted 20")
                    let back = try #require(slButton(root, "Back"), "\(tag): no Back")
                    #expect(abs((plBox(root, back).top + plBox(root, back).bottom) / 2 - (frame.top + frame.bottom) / 2) <= 1, "\(tag): Back and Start indexing are not in one row")
                    let found = swlPaletteViolations(root, look, allowError: false, glass: glass)
                    #expect(found.isEmpty, "\(tag): \(found)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func notNowIsABorderlessSecondaryTitledSetupButtonCentredTwelveUnderTheReadNoteWithNoKeyEquivalentBezelColourOrGlassBezel(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "\(look)"
                    let notNow = try #require(slButton(root, "Not now"), "\(tag): no Not now")
                    let note = try #require(plText(root, sfReadNote), "\(tag): no read note")
                    #expect(notNow is SetupButton, "\(tag): not a SetupButton")
                    #expect(notNow.title == "Not now" && notNow.accessibilityLabel() == "Not now", "\(tag): title \(notNow.title), label \(String(describing: notNow.accessibilityLabel()))")
                    #expect(notNow.isEnabled, "\(tag): Not now is disabled")
                    #expect(!notNow.isBordered, "\(tag): Not now is bordered")
                    #expect(notNow.keyEquivalent.isEmpty, "\(tag): key equivalent \(notNow.keyEquivalent.debugDescription)")
                    #expect(notNow.bezelColor == nil, "\(tag): bezel colour \(String(describing: notNow.bezelColor))")
                    #expect(notNow.bezelStyle.rawValue != 16, "\(tag): a glass bezel")
                    #expect(slColour(sfTitleColour(notNow), is: .secondaryLabelColor), "\(tag): title colour \(String(describing: sfTitleColour(notNow)))")
                    #expect(abs(plBox(root, notNow).midX - 280) <= 8, "\(tag): centre \(plBox(root, notNow).midX), window centre 280")
                    #expect(swlGap(root, upper: [note], lower: [notNow]).near(12, 1), "\(tag): Not now is \(swlGap(root, upper: [note], lower: [notNow]).frame) pt under the read note, wanted 12")
                    for view in slGlassViews(rig.window) { #expect(!prViews(notNow).contains { $0 === view } && !slAncestors(notNow).contains { $0 === view }, "\(tag): Not now is a glass site") }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func withAModelThatIsNotWholeTheFooterReadsNextAndFoldersShowsNoStartIndexingNoNotNowAndNoHintWithTheReadNoteTwelveUnderAddFolder(glass: Bool) async throws {
            for state in [SLState.downloading, SLState.damaged, SLState.failed] {
                try await slWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .folders)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let next = try #require(slButton(root, "Next"), "\(tag): no Next")
                        #expect(next.isEnabled && next.title == "Next" && next.accessibilityLabel() == "Next", "\(tag): Next title \(next.title), label \(String(describing: next.accessibilityLabel())), enabled \(next.isEnabled)")
                        #expect(slButtons(root).filter { $0.keyEquivalent == "\r" }.map(\.title) == ["Next"], "\(tag): Return buttons")
                        #expect(sfReading(root, "Start indexing").isEmpty, "\(tag): a button reads Start indexing")
                        #expect(slButton(root, "Not now") == nil, "\(tag): Not now is shown")
                        #expect(plText(root, sfHintTicked) == nil && plText(root, sfHintNone) == nil, "\(tag): a hint is shown: \(plTexts(root).map(\.stringValue))")
                        let add = try #require(slButton(root, sfAdd), "\(tag): no Add folder")
                        #expect(add.isEnabled, "\(tag): Add folder is disabled")
                        let note = try #require(plText(root, sfReadNote), "\(tag): no read note")
                        #expect(swlGap(root, upper: [add], lower: [note]).near(12, 1), "\(tag): the read note is \(swlGap(root, upper: [add], lower: [note]).frame) pt under Add folder, wanted 12")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func afterStartWasPressedTheFooterReadsNextAddFolderIsDisabledAndThereIsNoNotNowNoStartIndexingAndNoHint(glass: Bool) async throws {
            try await slWith(.whole, glass: glass, settings: sfStarted) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "\(look)"
                    let next = try #require(slButton(root, "Next"), "\(tag): no Next")
                    #expect(next.isEnabled, "\(tag): Next is disabled")
                    #expect(sfReading(root, "Start indexing").isEmpty, "\(tag): a button reads Start indexing")
                    #expect(slButton(root, "Not now") == nil, "\(tag): Not now is shown")
                    #expect(plText(root, sfHintTicked) == nil && plText(root, sfHintNone) == nil, "\(tag): a hint is shown")
                    let add = try #require(slButton(root, sfAdd), "\(tag): no Add folder")
                    #expect(!add.isEnabled, "\(tag): Add folder is enabled after Start")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func welcomePermissionsAndShortcutKeepNextAndFinishAndShowNoStartIndexingNoNotNowAndNoHint(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for entry in slStepNames where entry.step != .folders {
                    await slWalk(rig, to: entry.step)
                    let root = slLayout(rig)
                    let primary = entry.step == .shortcut ? "Finish" : "Next"
                    let other = entry.step == .shortcut ? "Next" : "Finish"
                    #expect(slButton(root, primary) != nil, "\(entry.label): no \(primary)")
                    #expect(slButton(root, other) == nil, "\(entry.label): \(other) is shown")
                    #expect(sfReading(root, "Start indexing").isEmpty, "\(entry.label): a button reads Start indexing")
                    #expect(slButton(root, "Not now") == nil, "\(entry.label): Not now is shown")
                    #expect(plText(root, sfHintTicked) == nil && plText(root, sfHintNone) == nil, "\(entry.label): a hint is shown")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func oneFooterPressStartsOnceWritesTheTicksMovesToPermissionsAndBackThenNextOnlyAdvances(glass: Bool) async throws {
            let hook = SLBox<Int>(0)
            try await slWith(.whole, glass: glass, onStarted: { hook.value += 1 }) { rig in
                await slWalk(rig, to: .folders)
                let start = try #require(slButton(slLayout(rig), "Start indexing"), "no Start indexing")
                #expect(start.isEnabled)
                #expect(!sfStartPressed(rig), "startPressed is on disk before the press")
                start.performClick(nil)
                #expect(await sfWaitStep(rig, .permissions), "the window is on \(rig.window.flow.step.title) after the press, wanted Permissions")
                #expect(await sfEventually { hook.value >= 1 }, "the Start hook was not called")
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(hook.value == 1, "the Start hook was called \(hook.value) times")
                #expect(sfStartPressed(rig), "startPressed is not true on disk after the press")
                for name in ["Desktop", "Documents", "Pictures"] {
                    #expect(sfEntry(rig, name)?["reading"] as? Bool == true, "\(name) is not reading: \(String(describing: sfEntry(rig, name)))")
                }
                var root = slLayout(rig)
                #expect(slButton(root, "Next") != nil && sfReading(root, "Start indexing").isEmpty, "Permissions: the footer is not Next")

                let back = try #require(slButton(root, "Back"), "no Back on Permissions")
                back.performClick(nil)
                #expect(await sfWaitStep(rig, .folders))
                root = slLayout(rig)
                let footer = try #require(slButtons(root).first { $0.title == "Next" }, "after Back the footer does not read Next: \(slButtons(root).map(\.title))")
                #expect(footer.accessibilityLabel() == "Next", "the footer label is \(String(describing: footer.accessibilityLabel())), wanted Next")
                #expect(sfReading(root, "Start indexing").isEmpty, "a button still reads Start indexing after Start")
                #expect(slButton(root, "Not now") == nil, "Not now is shown after Start")
                #expect(plText(root, sfHintTicked) == nil && plText(root, sfHintNone) == nil, "a hint is shown after Start")
                footer.performClick(nil)
                #expect(await sfWaitStep(rig, .permissions), "the second press of the footer left the window on \(rig.window.flow.step.title)")
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(hook.value == 1, "the second press started again: the Start hook was called \(hook.value) times")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func anUnwritableSettingsFileKeepsTheWindowOnFoldersShowsTheErrorRowTwelveUnderNotNowWritesNothingAndCallsNoHook(glass: Bool) async throws {
            let hook = SLBox<Int>(0)
            try await slWith(.whole, glass: glass, onStarted: { hook.value += 1 }) { rig in
                await slWalk(rig, to: .folders)
                try "not json".write(to: sfSettingsURL(rig), atomically: true, encoding: .utf8)
                let start = try #require(slButton(slLayout(rig), "Start indexing"), "no Start indexing")
                start.performClick(nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(rig.window.flow.step == .folders, "the window left Folders after a start error: \(rig.window.flow.step.title)")
                #expect(hook.value == 0, "the Start hook was called \(hook.value) times after a start error")
                #expect(try Data(contentsOf: sfSettingsURL(rig)) == Data("not json".utf8), "the settings file was rewritten")
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "\(look)"
                    let message = try #require(plText(root, sfStartError), "\(tag): no start error among \(plTexts(root).map(\.stringValue))")
                    let notNow = try #require(slButton(root, "Not now"), "\(tag): no Not now")
                    let warnings = plAccessibilityImages(root).filter { plVisible($0) }.compactMap { $0 as? NSImageView }
                    #expect(warnings.count == 1, "\(tag): \(warnings.count) warning symbols")
                    let row: [NSView] = [message as NSView] + warnings.map { $0 as NSView }
                    #expect(swlGap(root, upper: [notNow], lower: row).near(12, 1), "\(tag): the error row is \(swlGap(root, upper: [notNow], lower: row).frame) pt under Not now, wanted 12")
                    let below = swlGap(root, upper: row, lower: swlNav(root))
                    #expect(max(below.frame, below.aligned) >= 15.5, "\(tag): the error row ends \(below.frame) / \(below.aligned) pt above the footer")
                }
                #expect(rig.window.setupScreen.texts.last == sfStartError, "the start error is not the last text: \(rig.window.setupScreen.texts)")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func notNowMovesToPermissionsWithoutStartingAndAFinishLaterKeepsTheTicksAsWaitingTicks(glass: Bool) async throws {
            let hook = SLBox<Int>(0)
            try await slWith(.whole, glass: glass, onStarted: { hook.value += 1 }) { rig in
                await slWalk(rig, to: .folders)
                let notNow = try #require(slButton(slLayout(rig), "Not now"), "no Not now")
                notNow.performClick(nil)
                #expect(await sfWaitStep(rig, .permissions), "Not now left the window on \(rig.window.flow.step.title)")
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(!sfStartPressed(rig), "Not now wrote startPressed true")
                #expect(hook.value == 0, "Not now called the Start hook \(hook.value) times")
                #expect(((sfSettings(rig)?["folders"] as? [NSDictionary]) ?? []).allSatisfy { ($0["reading"] as? Bool) != true }, "Not now left a folder reading")

                await slWalk(rig, to: .shortcut)
                let finish = try #require(slButton(slLayout(rig), "Finish"), "no Finish")
                finish.performClick(nil)
                try? await Task.sleep(nanoseconds: 500_000_000)
                #expect(sfSettings(rig)?["setupFinished"] as? Bool == true, "setupFinished is \(String(describing: sfSettings(rig)?["setupFinished"]))")
                #expect(!sfStartPressed(rig), "Finish wrote startPressed true")
                for name in ["Desktop", "Documents", "Pictures"] {
                    let entry = sfEntry(rig, name)
                    #expect(entry?["ticked"] as? Bool == true && entry?["reading"] as? Bool == false, "\(name) is not a waiting tick: \(String(describing: entry))")
                }
                #expect(hook.value == 0, "Finish called the Start hook \(hook.value) times")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func returnOnFoldersWithATickedRowPressesTheFooterButtonOnceAndWithNoTickedRowStartsNothing(glass: Bool) async throws {
            let hook = SLBox<Int>(0)
            try await slWith(.whole, glass: glass, onStarted: { hook.value += 1 }) { rig in
                await slWalk(rig, to: .folders)
                _ = slLayout(rig)
                let handled = rig.window.performKeyEquivalent(with: sfReturn(rig.window))
                #expect(handled, "Return was not handled on Folders with a ticked row")
                #expect(await sfWaitStep(rig, .permissions), "Return left the window on \(rig.window.flow.step.title)")
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(hook.value == 1, "Return called the Start hook \(hook.value) times")
                #expect(sfStartPressed(rig), "Return did not write startPressed")
            }
            let none = SLBox<Int>(0)
            try await slWith(.whole, glass: glass, onStarted: { none.value += 1 }) { rig in
                await slWalk(rig, to: .folders)
                #expect(await sfUntickAll(rig), "the rows did not all untick")
                _ = sfRoot(rig)
                _ = rig.window.performKeyEquivalent(with: sfReturn(rig.window))
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(rig.window.flow.step == .folders, "Return with no ticked row left the window on \(rig.window.flow.step.title)")
                #expect(none.value == 0, "Return with no ticked row called the Start hook \(none.value) times")
                #expect(!sfStartPressed(rig), "Return with no ticked row wrote startPressed")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func withNoRowTickedTheFooterReadsStartIndexingDisabledTheHintSaysToTickOneAndNotNowAdvancesWithoutAStart(glass: Bool) async throws {
            let hook = SLBox<Int>(0)
            try await slWith(.whole, glass: glass, onStarted: { hook.value += 1 }) { rig in
                await slWalk(rig, to: .folders)
                #expect(await sfUntickAll(rig), "the rows did not all untick")
                #expect(await sfEventually { slButton(rig.window.contentView!, "Start indexing")?.isEnabled == false }, "the footer is not disabled with no row ticked")
                for look in DTLook.allCases {
                    let root = sfRoot(rig, look)
                    let tag = "\(look)"
                    let start = try #require(slButton(root, "Start indexing"), "\(tag): no Start indexing")
                    #expect(!start.isEnabled, "\(tag): Start indexing is enabled with no row ticked")
                    #expect(sfReading(root, "Next").isEmpty, "\(tag): a button reads Next")
                    #expect(swlTexts(root, sfHintNone).count == 1, "\(tag): the tick hint is shown \(swlTexts(root, sfHintNone).count) times in \(plTexts(root).map(\.stringValue))")
                    #expect(plText(root, sfHintTicked) == nil, "\(tag): the ticked hint is shown with no row ticked")
                    sfCheckHint(root, sfHintNone, look, tag)
                    let notNow = try #require(slButton(root, "Not now"), "\(tag): no Not now")
                    #expect(notNow.isEnabled, "\(tag): Not now is disabled")
                }
                let notNow = try #require(slButton(sfRoot(rig), "Not now"), "no Not now")
                notNow.performClick(nil)
                #expect(await sfWaitStep(rig, .permissions), "Not now left the window on \(rig.window.flow.step.title)")
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(hook.value == 0, "Not now called the Start hook \(hook.value) times")
                #expect(!sfStartPressed(rig), "Not now wrote startPressed")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func tickingARowEnablesTheFooterAndSwapsTheHintWithoutRebuildingTheList(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                #expect(await sfUntickAll(rig), "the rows did not all untick")
                #expect(await sfEventually { slButton(rig.window.contentView!, "Start indexing")?.isEnabled == false })
                let before = sfRows(sfRoot(rig), rig)
                #expect(before.count == 5, "\(before.count) rows")
                let row = try #require(before.first { $0.isEnabled }, "no enabled row to tick")
                row.performClick(nil)
                #expect(await sfEventually { slButton(rig.window.contentView!, "Start indexing")?.isEnabled == true }, "the footer stays disabled after a row is ticked")
                #expect(await sfEventually { plText(rig.window.contentView!, sfHintTicked) != nil }, "the hint did not change after a row was ticked")
                let root = sfRoot(rig)
                #expect(plText(root, sfHintNone) == nil, "the tick hint is still shown after a row was ticked")
                sfCheckHint(root, sfHintTicked, .light, "ticked")
                let after = sfRows(root, rig)
                #expect(after.count == before.count && zip(before, after).allSatisfy { $0 === $1 }, "the list was rebuilt when a row was ticked")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aTickedRowThatIsStillBeingCountedCountsAsTickedForTheFooterAndTheHint(glass: Bool) async throws {
            let gate = SFGate()
            defer { gate.release() }
            let counter: @Sendable ([String]) -> FolderCounts = { paths in
                gate.enter()
                var per: [String: [String: Int]] = [:]
                for path in paths { per[path] = ["photo": 1] }
                return FolderCounts(perFolder: per, summary: ["photo": paths.count], total: paths.count, unreadable: [])
            }
            try await slWith(.whole, glass: glass, counter: counter) { rig in
                await slWalk(rig, to: .folders)
                let root = slLayout(rig)
                let counting = rig.folders.rows.filter { $0.ticked }
                #expect(!counting.isEmpty && counting.allSatisfy { $0.state == .counting }, "the rows are not ticked and counting: \(rig.folders.rows.map { ($0.name, $0.ticked, $0.state) })")
                let start = try #require(slButton(root, "Start indexing"), "no Start indexing")
                #expect(start.isEnabled, "Start indexing is disabled while the ticked rows are counting")
                #expect(plText(root, sfHintTicked) != nil && plText(root, sfHintNone) == nil, "the hint is not the ticked one while the rows are counting: \(plTexts(root).map(\.stringValue))")
                gate.release()
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theHintIsTwelveRegularSecondaryCentredWrappedToTheContentWidthNeverTruncatedTwelveUnderAddFolderAndTwelveAboveTheReadNoteInTheOrderCardAddHintNoteNotNow(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "\(look)"
                    sfCheckHint(root, sfHintTicked, look, tag)
                    let hint = try #require(plText(root, sfHintTicked), "\(tag): no hint")
                    let add = try #require(slButton(root, sfAdd), "\(tag): no Add folder")
                    let note = try #require(plText(root, sfReadNote), "\(tag): no read note")
                    let notNow = try #require(slButton(root, "Not now"), "\(tag): no Not now")
                    let card = try #require(sfRows(root, rig).first.flatMap { slCard(of: $0) }, "\(tag): no list card")
                    #expect(swlGap(root, upper: [add], lower: [hint]).near(12, 1), "\(tag): the hint is \(swlGap(root, upper: [add], lower: [hint]).frame) pt under Add folder, wanted 12")
                    #expect(swlGap(root, upper: [hint], lower: [note]).near(12, 1), "\(tag): the read note is \(swlGap(root, upper: [hint], lower: [note]).frame) pt under the hint, wanted 12")
                    let tops = [card, add, hint, note, notNow].map { plBox(root, $0).top }
                    #expect(zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 }, "\(tag): the tops are not card, Add folder, hint, read note, Not now: \(tops)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theFoldersKeyLoopIsTheTickedRowsAddFolderNotNowRetryBackAndTheFooterButtonForEachState(glass: Bool) async throws {
            let cases: [(label: String, state: SLState, untick: Bool, tail: [String])] = [
                ("whole", .whole, false, [sfAdd, "Not now", "Back", "Start indexing"]),
                ("whole, none ticked", .whole, true, [sfAdd, "Not now", "Back"]),
                ("downloading", .downloading, false, [sfAdd, "Back", "Next"]),
                ("failed", .failed, false, [sfAdd, "Retry", "Back", "Next"]),
            ]
            for entry in cases {
                try await slWith(entry.state, glass: glass) { rig in
                    await slWalk(rig, to: .folders)
                    if entry.untick { #expect(await sfUntickAll(rig), "\(entry.label): the rows did not all untick") }
                    let root = sfRoot(rig)
                    let ticked = sfRows(root, rig).filter { $0.state == .on }.map(\.title)
                    let wanted = ticked + entry.tail
                    var loop = slKeyLoop(rig.window).compactMap { ($0 as? NSButton)?.title }.filter { wanted.contains($0) }
                    if let first = loop.firstIndex(of: wanted[0]) { loop = Array(loop[first...] + loop[..<first]) }
                    #expect(loop == wanted, "\(entry.label): key loop \(loop), wanted \(wanted)")
                    #expect(slKeyLoop(rig.window).count < 500, "\(entry.label): the key loop never closed")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theFoldersAccessibilityElementsAreTheTextsTheRowsAddFolderTheHintTheReadNoteNotNowTheBackButtonTheDotsGroupAndTheFooterButtonInThatOrder(glass: Bool) async throws {
            let rows = ["row:Desktop", "row:Documents", "row:Downloads", "row:Pictures", "row:Movies"]
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                let found = sfElements(slLayout(rig), rig)
                let wanted = ["Folders to read", "105 files in 3 folders", "About 5 min in total"] + rows
                    + [sfAdd, sfHintTicked, sfReadNote, "Not now", "Back", "Step 2 of 4: Folders", "Start indexing"]
                #expect(found == wanted, "whole: \(found), wanted \(wanted)")
                #expect(sfReading(slLayout(rig), "Next").isEmpty, "whole: a button reads Next")
            }
            try await slWith(.downloading, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                let found = sfElements(slLayout(rig), rig)
                let wanted = ["Folders to read", "105 files in 3 folders"] + rows
                    + [sfAdd, sfReadNote, "The search model", "Model download", "Back", "Step 2 of 4: Folders", "Next"]
                #expect(found == wanted, "downloading: \(found), wanted \(wanted)")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theScreenListsTheFoldersButtonsAsBackTheFooterAddFolderNotNowRetryAndTheHintSitsRightBeforeTheReadNote(glass: Bool) async throws {
            let cases: [(label: String, state: SLState, started: Bool, titles: [String], hint: String?)] = [
                ("whole", .whole, false, ["Back", "Start indexing", sfAdd, "Not now"], sfHintTicked),
                ("downloading", .downloading, false, ["Back", "Next", sfAdd], nil),
                ("failed", .failed, false, ["Back", "Next", sfAdd, "Retry"], nil),
                ("started", .whole, true, ["Back", "Next", sfAdd], nil),
            ]
            for entry in cases {
                var seed: ((SLEnv) throws -> Settings)?
                if entry.started { seed = sfStarted }
                try await slWith(entry.state, glass: glass, settings: seed) { rig in
                    await slWalk(rig, to: .folders)
                    let screen = rig.window.setupScreen
                    #expect(screen.buttons.map(\.title) == entry.titles, "\(entry.label): buttons \(screen.buttons.map(\.title)), wanted \(entry.titles)")
                    let labels = screen.controls.map(\.label).filter { entry.titles.contains($0) }
                    #expect(labels == entry.titles, "\(entry.label): the controls list the buttons as \(labels), wanted \(entry.titles)")
                    let lastRow = screen.controls.map(\.label).lastIndex { $0.hasPrefix("Pictures, ") || $0.hasPrefix("Movies, ") } ?? -1
                    let firstButton = screen.controls.map(\.label).firstIndex { entry.titles.contains($0) } ?? -1
                    #expect(lastRow < firstButton, "\(entry.label): a button comes before the last row in \(screen.controls.map(\.label))")
                    let hints = screen.texts.filter { $0 == sfHintTicked || $0 == sfHintNone }
                    #expect(hints == (entry.hint.map { [$0] } ?? []), "\(entry.label): hints \(hints)")
                    if let hint = entry.hint, let at = screen.texts.firstIndex(of: hint), let note = screen.texts.firstIndex(of: sfReadNote) {
                        #expect(at + 1 == note, "\(entry.label): the hint is not the text right before the read note: \(screen.texts)")
                    }
                    for step in [SetupFlow.Step.permissions, .shortcut] {
                        await slWalk(rig, to: step)
                        let other = rig.window.setupScreen
                        #expect(other.buttons.map(\.title).filter { $0 != "Retry" } == ["Back", step == .shortcut ? "Finish" : "Next"], "\(entry.label) / \(step.title): buttons \(other.buttons.map(\.title))")
                        #expect(!other.texts.contains(sfHintTicked) && !other.texts.contains(sfHintNone), "\(entry.label) / \(step.title): a hint is in the texts")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func inTheWholeModelWorstStateOfSixRowsAFortyCharacterNameAndAStartErrorTheFootEndsSixteenOrMoreAboveTheFooterWithNothingOverlapping(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let long = try rig.env.fill(sfLong, photo: 3)
                #expect(sfLong.count == 40)
                await slWalk(rig, to: .folders)
                rig.picks.value = [long]
                slButton(slLayout(rig), sfAdd)?.performClick(nil)
                #expect(await sfEventually(30) { rig.folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }, "the rows never became ready")
                try "not json".write(to: sfSettingsURL(rig), atomically: true, encoding: .utf8)
                slButton(slLayout(rig), "Start indexing")?.performClick(nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "\(look)"
                    #expect(sfRows(root, rig).count == 6, "\(tag): \(sfRows(root, rig).count) rows")
                    let message = try #require(plText(root, sfStartError), "\(tag): no start error")
                    let warnings = plAccessibilityImages(root).filter { plVisible($0) }.compactMap { $0 as? NSImageView }
                    let card = try #require(sfRows(root, rig).first.flatMap { slCard(of: $0) }, "\(tag): no list card")
                    let add = try #require(slButton(root, sfAdd), "\(tag): no Add folder")
                    let hint = try #require(plText(root, sfHintTicked), "\(tag): no hint")
                    let note = try #require(plText(root, sfReadNote), "\(tag): no read note")
                    let notNow = try #require(slButton(root, "Not now"), "\(tag): no Not now")
                    var content: [(String, PLBox)] = [("list card", plBox(root, card)), ("add folder", plBox(root, add)), ("hint", plBox(root, hint)), ("read note", plBox(root, note)), ("not now", plBox(root, notNow)), ("error text", plBox(root, message))]
                    for warning in warnings { content.append(("error symbol", plBox(root, warning))) }
                    for (upper, lower) in zip(content.prefix(5), content.dropFirst()) {
                        #expect(upper.1.bottom <= lower.1.top + 0.5, "\(tag): \(upper.0) ends at \(upper.1.bottom), \(lower.0) starts at \(lower.1.top)")
                    }
                    let lowest = content.map { $0.1.bottom }.max() ?? 0
                    let footer = swlNav(root).map { plBox(root, $0) }
                    #expect(!footer.isEmpty, "\(tag): no footer")
                    for box in footer {
                        #expect(box.top - lowest >= 15.5, "\(tag): the foot ends at \(lowest), the footer starts at \(box.top): margin \(box.top - lowest), wanted at least 16")
                        for part in content { #expect(!part.1.intersects(box), "\(tag): \(part.0) overlaps the footer") }
                        #expect(abs((600 - box.bottom) - 20) <= 2, "\(tag): a footer button is \(600 - box.bottom) pt from the bottom, wanted 20")
                    }
                    #expect(sfModelBlock(root) == nil, "\(tag): a model block is shown with a whole model")
                    let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                    #expect(size.width == 560 && size.height == 600, "\(tag): content size \(size)")
                    #expect(root.bounds.size.width == 560 && root.bounds.size.height == 600, "\(tag): content view \(root.bounds.size)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func inTheNotWholeWorstStateOfSixRowsAFailedAndDamagedModelAndAStartErrorTheFootEndsSixteenAboveTheModelBlockTheErrorRowSitsTwelveUnderTheReadNoteAndTheListCardKeepsAtLeastItsOldHeight(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let long = try rig.env.fill(sfLong, photo: 3)
                await slWalk(rig, to: .folders)
                rig.picks.value = [long]
                slButton(slLayout(rig), sfAdd)?.performClick(nil)
                #expect(await sfEventually(30) { rig.folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }, "the rows never became ready")
                try "not json".write(to: sfSettingsURL(rig), atomically: true, encoding: .utf8)
                slButton(slLayout(rig), "Start indexing")?.performClick(nil)
                try FileManager.default.removeItem(at: rig.env.models.appendingPathComponent("sl-whole.gguf"))
                rig.window.model.modelWasDamaged()
                rig.window.model.downloadFailed(slFailedMessage)
                rig.window.refresh()
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "\(look)"
                    #expect(sfRows(root, rig).count == 6, "\(tag): \(sfRows(root, rig).count) rows")
                    #expect(sfReading(root, "Start indexing").isEmpty, "\(tag): a button reads Start indexing after the model was lost")
                    let next = try #require(slButtons(root).first { $0.title == "Next" }, "\(tag): the footer does not read Next: \(slButtons(root).map(\.title))")
                    #expect(next.accessibilityLabel() == "Next", "\(tag): the footer label is \(String(describing: next.accessibilityLabel()))")
                    #expect(slButton(root, "Not now") == nil, "\(tag): Not now is shown")
                    #expect(plText(root, sfHintTicked) == nil && plText(root, sfHintNone) == nil, "\(tag): a hint is shown")
                    let message = try #require(plText(root, sfStartError), "\(tag): no start error")
                    let warnings = plAccessibilityImages(root).filter { plVisible($0) }.compactMap { $0 as? NSImageView }.filter { $0.accessibilityLabel() == "Warning" }
                    let card = try #require(sfRows(root, rig).first.flatMap { slCard(of: $0) }, "\(tag): no list card")
                    let add = try #require(slButton(root, sfAdd), "\(tag): no Add folder")
                    let note = try #require(plText(root, sfReadNote), "\(tag): no read note")
                    let block = try #require(sfModelBlock(root), "\(tag): no model block")
                    let modelCard = try #require(plText(root, "The search model").flatMap { slCard(of: $0) }, "\(tag): no model card")
                    var foot: [NSView] = [add, note, message]
                    foot.append(contentsOf: warnings.filter { !slAncestors($0).contains { $0 === modelCard } }.map { $0 as NSView })
                    for part in foot {
                        let box = plBox(root, part)
                        let align = slAlignBox(root, part)
                        #expect(block.top - max(box.bottom, align.bottom) >= 15.5, "\(tag): the foot ends at \(box.bottom), the model block starts at \(block.top)")
                        #expect(!box.intersects(block), "\(tag): the foot overlaps the model block")
                    }
                    let row = foot.filter { $0 !== add && $0 !== note }
                    #expect(swlGap(root, upper: [note], lower: row).near(12, 1), "\(tag): the error row is \(swlGap(root, upper: [note], lower: row).frame) pt under the read note, wanted 12")
                    #expect(plBox(root, card).height >= 109.5, "\(tag): the list card is \(plBox(root, card).height) pt high, the old layout kept 110")
                    #expect(!plBox(root, card).intersects(block), "\(tag): the list overlaps the model block")
                    for button in swlNav(root) {
                        let frame = plBox(root, button)
                        let align = slAlignBox(root, button)
                        #expect(abs((600 - frame.bottom) - 20) <= 2 || abs((600 - align.bottom) - 20) <= 2, "\(tag): a footer button is \(600 - frame.bottom) pt from the bottom, wanted 20")
                    }
                    let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                    #expect(size.width == 560 && size.height == 600, "\(tag): content size \(size)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func afterStartTheShortcutRunningLineIsTwelveSecondaryCentredEightUnderTheNoteAndSixteenAboveTheFooterOrTheModelBlock(glass: Bool) async throws {
            for state in SKState.allCases {
                try await skWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        #expect(swlTexts(root, sfRunning).isEmpty, "\(state) \(look): the running line is shown without Start")
                    }
                }
                try await skWith(state, glass: glass, started: true) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let lines = swlTexts(root, sfRunning)
                        #expect(lines.count == 1, "\(tag): \(lines.count) running lines in \(plTexts(root).map(\.stringValue))")
                        guard let line = lines.first else { continue }
                        let note = try #require(swlTexts(root, sfShortcutNote).first, "\(tag): no note")
                        let lead = try #require(swlTexts(root, sfShortcutLead).first, "\(tag): no lead")
                        #expect(slFont(line.font, size: 12, weight: .regular), "\(tag): running line font \(String(describing: line.font))")
                        #expect(slColour(line.textColor, is: .secondaryLabelColor), "\(tag): running line colour")
                        let mid = swlInkMid(root, line, look)
                        #expect(mid != nil && abs((mid ?? 0) - 280) <= 8, "\(tag): running line ink centre \(String(describing: mid)), window centre 280")
                        #expect(!line.isEditable, "\(tag): the running line is editable")
                        let underNote = swlGap(root, upper: [note], lower: [line])
                        #expect(underNote.near(8, 1), "\(tag): the running line is \(underNote.frame) / \(underNote.aligned) pt under the note, wanted 8")
                        let lineBox = plBox(root, line)
                        if state == .whole {
                            let toFooter = swlGap(root, upper: [line], lower: swlNav(root))
                            #expect(toFooter.near(16, 1), "\(tag): the running line ends \(toFooter.frame) / \(toFooter.aligned) pt above the footer, wanted 16")
                            #expect(slContentBottom(root).map { abs($0 - lineBox.bottom) <= 3 } == true, "\(tag): the running line is not the lowest content")
                        } else {
                            let model = try #require(sfModelBlock(root), "\(tag): no model block")
                            #expect(abs((model.top - lineBox.bottom) - 16) <= 1, "\(tag): the running line ends \(model.top - lineBox.bottom) pt above the model block, wanted 16")
                            #expect(!lineBox.intersects(model), "\(tag): the running line overlaps the model block")
                        }
                        let row = skRow(root)
                        let block = try #require(skBlock(root, row), "\(tag): no keys block")
                        let middle = (plBox(root, lead).bottom + plBox(root, note).top) / 2
                        #expect(abs((block.top + block.bottom) / 2 - middle) <= 2, "\(tag): the keys block centre is \((block.top + block.bottom) / 2), the space between the lead and the note is centred at \(middle)")
                        #expect(block.bottom <= plBox(root, note).top - 15.5 && plBox(root, lead).bottom <= block.top - 15.5, "\(tag): the keys block is closer than 16 to the lead or the note")
                        let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                        #expect(size.width == 560 && size.height == 600, "\(tag): content size \(size)")
                        for button in swlNav(root) {
                            let frame = plBox(root, button)
                            let align = slAlignBox(root, button)
                            #expect(abs((600 - frame.bottom) - 20) <= 2 || abs((600 - align.bottom) - 20) <= 2, "\(tag): a footer button is \(600 - frame.bottom) pt from the bottom, wanted 20")
                        }
                    }
                }
            }
        }
    }
}
