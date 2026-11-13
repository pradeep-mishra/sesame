import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let ssgReady = "Search model ready"
private let ssgSummary = "105 files in 3 folders"
private let ssgTotal = "About 5 min in total"
private let ssgReadNote = "Photos, PDFs, documents, audio and video are read."
private let ssgPermissionsIntro = "macOS asks once, the first time Sesame reads each of these:"
private let ssgNeverAsked = "Sesame never asks for Full Disk Access, camera or microphone."
private let ssgShortcutLead = "Press these keys together."
private let ssgShortcutNote = "You can change the shortcut later in Settings."
private let ssgShortcutHeading = "Open Sesame from anywhere"
private let ssgHintTicked = "Indexing starts when you press Start indexing, and runs in the background."
private let ssgHintNone = "Tick at least one folder to start."
private let ssgRunning = "Indexing is running. Watch it from the magnifier in the menu bar."
private let ssgSteps = slStepNames.filter { $0.step != .welcome }
private let ssgAllStates: [SLState] = [.whole, .downloading, .damaged, .failed]
private let ssgLongName = "Photos-from-the-summer-trip-to-the-coast"

@MainActor
private func ssgCentred(_ root: NSView, _ field: NSTextField, _ look: DTLook) -> Bool {
    guard let mid = swlInkMid(root, field, look) else { return false }
    return abs(mid - 280) <= 8
}

@MainActor
private func ssgCard(_ root: NSView, _ step: SetupFlow.Step) -> GroupCard? {
    switch step {
    case .folders: return slButton(root, "Pictures").flatMap { slCard(of: $0) }
    case .permissions: return plText(root, "Desktop").flatMap { slCard(of: $0) }
    case .welcome, .shortcut: return nil
    }
}

@MainActor
private func ssgIntro(_ root: NSView, title: NSTextField, card: GroupCard) -> [NSTextField] {
    let titleBox = plBox(root, title)
    let cardBox = plBox(root, card)
    return plTexts(root)
        .filter { $0 !== title }
        .filter { plBox(root, $0).top >= titleBox.bottom - 1 && plBox(root, $0).bottom <= cardBox.top + 1 }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func ssgFooter(_ root: NSView) -> [NSView] {
    swlNav(root) + prViews(root).filter { $0 is StepDots && plVisible($0) }
}

@MainActor
private func ssgModelBlock(_ root: NSView) -> PLBox? {
    if let ready = plText(root, ssgReady), let check = swlImages(root, "checkmark.circle.fill").first {
        return plBox(root, check).union(plBox(root, ready))
    }
    if let heading = plText(root, "The search model"), let card = slCard(of: heading) { return plBox(root, card) }
    return nil
}

extension ModelDownloadTests {
    @Suite("SetupStepsGrammarTests", .serialized)
    struct SetupStepsGrammarTests {

        @MainActor
        @Test(arguments: slPaths) func theTitleIsTwentyFourBoldInLabelColourCentredAndTwentyToThirtyTwoFromTheTop(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    for entry in ssgSteps {
                        await slWalk(rig, to: entry.step)
                        for look in DTLook.allCases {
                            let root = slLayout(rig, look)
                            let tag = "\(state) / \(entry.label) \(look)"
                            let titles = swlTexts(root, entry.heading)
                            #expect(titles.count == 1, "\(tag): \(titles.count) titles \"\(entry.heading)\"")
                            guard let title = titles.first else { continue }
                            #expect(slFont(title.font, size: 24, weight: .bold), "\(tag): title font \(String(describing: title.font))")
                            #expect(slColour(title.textColor, is: .labelColor), "\(tag): title colour")
                            #expect(ssgCentred(root, title, look), "\(tag): title ink centre \(String(describing: swlInkMid(root, title, look))), window centre 280")
                            let top = plBox(root, title).top
                            #expect(top >= 19.5 && top <= 32.5, "\(tag): title top \(top), wanted 20 to 32")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func noTextFieldOrTextViewOnStepsTwoToFourStartsWithStep(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    for entry in ssgSteps {
                        await slWalk(rig, to: entry.step)
                        let root = slLayout(rig)
                        let fields = plTexts(root).filter { $0.stringValue.hasPrefix("Step ") }
                        #expect(fields.isEmpty, "\(state) / \(entry.label): a text field holds \(fields.map(\.stringValue))")
                        let views = prViews(root).compactMap { $0 as? NSTextView }.filter { plVisible($0) && $0.string.hasPrefix("Step ") }
                        #expect(views.isEmpty, "\(state) / \(entry.label): a text view starts with Step")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theFoldersIntroIsCentredSummaryInThirteenLabelColourAndTotalInTwelveSecondaryWithNoSpeedLine(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let title = try #require(swlTexts(root, "Folders to read").first, "\(look): no title")
                    let card = try #require(ssgCard(root, .folders), "\(look): no folders card")
                    let intro = ssgIntro(root, title: title, card: card)
                    #expect(intro.map(\.stringValue) == [ssgSummary, ssgTotal], "\(look): intro lines \(intro.map(\.stringValue))")
                    for field in intro {
                        #expect(ssgCentred(root, field, look), "\(look): \"\(field.stringValue)\" ink centre \(String(describing: swlInkMid(root, field, look))), window centre 280")
                        if field.stringValue == ssgTotal {
                            #expect(slFont(field.font, size: 12, weight: .regular), "\(look): total font \(String(describing: field.font))")
                            #expect(slColour(field.textColor, is: .secondaryLabelColor), "\(look): total colour")
                        } else {
                            #expect(slFont(field.font, size: 13, weight: .regular), "\(look): \"\(field.stringValue)\" font \(String(describing: field.font))")
                            #expect(slColour(field.textColor, is: .labelColor), "\(look): \"\(field.stringValue)\" colour")
                        }
                    }
                }
            }
            try await slWith(.downloading, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let title = try #require(swlTexts(root, "Folders to read").first, "\(look): no title")
                    let card = try #require(ssgCard(root, .folders), "\(look): no folders card")
                    let intro = ssgIntro(root, title: title, card: card)
                    #expect(intro.map(\.stringValue) == [ssgSummary], "downloading \(look): intro lines \(intro.map(\.stringValue))")
                    for field in intro {
                        #expect(ssgCentred(root, field, look), "downloading \(look): \"\(field.stringValue)\" is not centred")
                        #expect(slFont(field.font, size: 13, weight: .regular) && slColour(field.textColor, is: .labelColor), "downloading \(look): summary style")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func thePermissionsIntroIsOneCentredThirteenPointLineUnderTheTitleAboveTheCard(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .permissions)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let title = try #require(swlTexts(root, "Permissions").first, "\(tag): no title")
                        let card = try #require(ssgCard(root, .permissions), "\(tag): no permissions card")
                        let intro = ssgIntro(root, title: title, card: card)
                        #expect(intro.map(\.stringValue) == [ssgPermissionsIntro], "\(tag): intro lines \(intro.map(\.stringValue))")
                        guard let line = intro.first else { continue }
                        #expect(ssgCentred(root, line, look), "\(tag): intro ink centre \(String(describing: swlInkMid(root, line, look))), window centre 280")
                        #expect(slFont(line.font, size: 13, weight: .regular), "\(tag): intro font \(String(describing: line.font))")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theShortcutStepsLeadLineFollowsTheTitleAndIsTheOnlyTextBetweenTheTitleAndTheKeys(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let title = try #require(swlTexts(root, ssgShortcutHeading).first, "\(tag): no title")
                        let lead = try #require(swlTexts(root, ssgShortcutLead).first, "\(tag): no lead")
                        let keys = skRow(root).keys
                        #expect(keys.count == 3, "\(tag): \(keys.count) keys")
                        let keysTop = keys.map { plBox(root, $0).top }.min() ?? 0
                        let titleBox = plBox(root, title)
                        let between = plTexts(root)
                            .filter { $0 !== title && plBox(root, $0).top >= titleBox.bottom - 1 && plBox(root, $0).bottom <= keysTop + 1 }
                            .sorted { plBox(root, $0).top < plBox(root, $1).top }
                        #expect(between.map(\.stringValue) == [ssgShortcutLead], "\(tag): texts between the title and the keys \(between.map(\.stringValue))")
                        #expect(plBox(root, lead).top >= titleBox.bottom - 1, "\(tag): the lead starts above the title ends")                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theFooterButtonTitledStartIndexingOnFoldersWithAWholeModelIsTheOnlyAccentButtonWithTheReturnKeyAndAddFolderAndNotNowArePlain(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    for entry in ssgSteps {
                        await slWalk(rig, to: entry.step)
                        let primary = entry.step == .shortcut ? "Finish" : (entry.step == .folders && state == .whole ? "Start indexing" : "Next")
                        for look in DTLook.allCases {
                            let root = slLayout(rig, look)
                            let tag = "\(state) / \(entry.label) \(look)"
                            let buttons = slButtons(root)
                            #expect(buttons.filter { $0.keyEquivalent == "\r" }.map(\.title) == [primary], "\(tag): Return buttons \(buttons.filter { $0.keyEquivalent == "\r" }.map(\.title))")
                            for button in buttons where button.title != primary {
                                #expect(button.keyEquivalent.isEmpty, "\(tag): \"\(button.title)\" key equivalent \(button.keyEquivalent.debugDescription)")
                                #expect(button.bezelColor == nil, "\(tag): \"\(button.title)\" bezel colour \(String(describing: button.bezelColor))")
                            }
                            if entry.step == .folders {
                                for plain in ["Add folder\u{2026}"] + (state == .whole ? ["Not now"] : []) {
                                    let button = try #require(slButton(root, plain), "\(tag): no \(plain)")
                                    #expect(!button.isBordered, "\(tag): \(plain) is bordered")
                                }
                                let footer = try #require(slButton(root, primary), "\(tag): no \(primary)")
                                let bezel = glass ? 16 : NSButton.BezelStyle.rounded.rawValue
                                #expect(footer.bezelStyle.rawValue == bezel, "\(tag): \(primary) bezel \(footer.bezelStyle.rawValue), wanted \(bezel)")
                                #expect(footer.keyEquivalent == "\r", "\(tag): \(primary) key equivalent \(footer.keyEquivalent.debugDescription)")
                                if glass {
                                    #expect(slColour(footer.bezelColor, is: .controlAccentColor), "\(tag): \(primary) bezel colour \(String(describing: footer.bezelColor))")
                                } else {
                                    #expect(footer.bezelColor == nil, "\(tag): \(primary) bezel colour \(String(describing: footer.bezelColor))")
                                }
                            }
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func addFolderIsAboveTheHintAboveTheReadNoteAboveNotNowAndNoneOverlapAndWithAModelThatIsNotWholeThereIsNoHintAndNoNotNow(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .folders)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let add = try #require(slButton(root, "Add folder\u{2026}"), "\(state) \(look): no Add folder")
                        let note = try #require(plText(root, ssgReadNote), "\(state) \(look): no read note")
                        let addBox = plBox(root, add)
                        let noteBox = plBox(root, note)
                        if state == .whole {
                            let hint = try #require(plText(root, ssgHintTicked), "\(state) \(look): no hint")
                            let notNow = try #require(slButton(root, "Not now"), "\(state) \(look): no Not now")
                            let hintBox = plBox(root, hint)
                            let notNowBox = plBox(root, notNow)
                            #expect(addBox.bottom <= hintBox.top + 0.5, "\(state) \(look): Add folder ends at \(addBox.bottom), the hint starts at \(hintBox.top)")
                            #expect(hintBox.bottom <= noteBox.top + 0.5, "\(state) \(look): the hint ends at \(hintBox.bottom), the read note starts at \(noteBox.top)")
                            #expect(noteBox.bottom <= notNowBox.top + 0.5, "\(state) \(look): the read note ends at \(noteBox.bottom), Not now starts at \(notNowBox.top)")
                            #expect(!addBox.intersects(hintBox) && !hintBox.intersects(noteBox) && !noteBox.intersects(notNowBox) && !addBox.intersects(notNowBox), "\(state) \(look): the foot overlaps")
                        } else {
                            #expect(plText(root, ssgHintTicked) == nil && plText(root, ssgHintNone) == nil, "\(state) \(look): a hint is shown with a model that is not whole")
                            #expect(slButton(root, "Not now") == nil, "\(state) \(look): Not now is shown with a model that is not whole")
                            #expect(addBox.bottom <= noteBox.top + 0.5, "\(state) \(look): Add folder ends at \(addBox.bottom), the read note starts at \(noteBox.top)")
                            #expect(!addBox.intersects(noteBox), "\(state) \(look): the foot overlaps")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func thePaletteOnStepsTwoToFourIsLabelSecondaryTertiaryGroupFillAndAccentOnlyOnTheCurrentDotAndTheFooterButtonStartIndexingNextOrFinish(glass: Bool) async throws {
            for state in ssgAllStates {
                try await slWith(state, glass: glass) { rig in
                    for entry in ssgSteps {
                        await slWalk(rig, to: entry.step)
                        for look in DTLook.allCases {
                            let root = slLayout(rig, look)
                            let found = swlPaletteViolations(root, look, allowError: state == .failed, glass: glass)
                            #expect(found.isEmpty, "\(state) / \(entry.label) \(look): \(found)")
                            if entry.step == .folders && state == .whole && glass {
                                let footer = slButton(root, "Start indexing")
                                #expect(slColour(footer?.bezelColor, is: .controlAccentColor), "\(state) / \(entry.label) \(look): the footer button Start indexing has bezel colour \(String(describing: footer?.bezelColor))")
                                #expect(slButton(root, "Not now")?.bezelColor == nil, "\(state) / \(entry.label) \(look): Not now has a bezel colour")
                            }
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theGradientAndVisualEffectRulesStillFailWhenAGradientLayerOrAnEffectViewIsPlanted(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                let root = slLayout(rig)
                let clean = swlPaletteViolations(root, .light, allowError: false, glass: glass).filter { $0.contains("gradient") || $0.contains("NSVisualEffectView") }
                #expect(clean.isEmpty, "the untouched window already reports \(clean)")
                root.wantsLayer = true
                let planted = CAGradientLayer()
                planted.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
                root.layer?.addSublayer(planted)
                let withGradient = swlPaletteViolations(root, .light, allowError: false, glass: glass)
                #expect(withGradient.contains { $0.contains("gradient") }, "a planted gradient layer was not found: \(withGradient)")
                planted.removeFromSuperlayer()
                let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                root.addSubview(effect)
                let withEffect = swlPaletteViolations(root, .light, allowError: false, glass: glass)
                #expect(withEffect.contains { $0.contains("NSVisualEffectView") }, "a planted effect view was not found: \(withEffect)")
                effect.removeFromSuperview()
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aWholeModelShowsNoStatusLineOnFoldersPermissionsAndShortcutWhoseFootOrNoteEndsSixteenOrMoreAboveTheFooter(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for entry in ssgSteps {
                    await slWalk(rig, to: entry.step)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(entry.label) \(look)"
                        #expect(plText(root, ssgReady) == nil, "\(tag): the ready line is shown")
                        #expect(swlImages(root, "checkmark.circle.fill").isEmpty, "\(tag): the status check is shown")
                        #expect(slStyle(root, "The search model") == nil, "\(tag): the model card heading is shown")
                        #expect(!prViews(root).contains { ($0 is NSProgressIndicator || $0 is FigureView) && plVisible($0) }, "\(tag): a bar or figure is shown")
                        #expect(slButton(root, "Retry") == nil, "\(tag): Retry is shown")
                        let foot: [NSView]
                        switch entry.step {
                        case .folders:
                            foot = ["Add folder\u{2026}", "Not now"].compactMap { slButton(root, $0) } + [plText(root, ssgReadNote), plText(root, ssgHintTicked)].compactMap { $0 }
                            #expect(foot.count == 4, "\(tag): the foot has \(foot.count) of its 4 parts")
                        case .permissions:
                            foot = [plText(root, ssgNeverAsked)].compactMap { $0 }
                            #expect(foot.count == 1, "\(tag): the note is shown \(foot.count) times")
                        default:
                            foot = [plText(root, ssgShortcutNote)].compactMap { $0 }
                            #expect(foot.count == 1, "\(tag): the note is shown \(foot.count) times")
                        }
                        let gap = swlGap(root, upper: foot, lower: swlNav(root))
                        #expect(max(gap.frame, gap.aligned) >= 15.5, "\(tag): the foot ends \(gap.frame) / \(gap.aligned) pt above the footer, wanted at least 16")
                    }
                }
            }
            let started: (SLEnv) throws -> Settings = { _ in
                var held = Settings()
                held.startPressed = true
                return held
            }
            try await slWith(.whole, glass: glass, settings: started) { rig in
                await slWalk(rig, to: .shortcut)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "started, Shortcut \(look)"
                    #expect(plText(root, ssgReady) == nil, "\(tag): the ready line is shown")
                    let running = try #require(plText(root, ssgRunning), "\(tag): no running line")
                    let note = try #require(plText(root, ssgShortcutNote), "\(tag): no note")
                    #expect(plBox(root, note).bottom <= plBox(root, running).top + 0.5, "\(tag): the note is not above the running line")
                    let gap = swlGap(root, upper: [running], lower: swlNav(root))
                    #expect(max(gap.frame, gap.aligned) >= 15.5, "\(tag): the running line, the lowest content, ends \(gap.frame) / \(gap.aligned) pt above the footer, wanted at least 16")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aModelThatIsNotWholeShowsTheModelCardAndNoStatusLineOnStepsTwoToFour(glass: Bool) async throws {
            for state in [SLState.downloading, SLState.damaged, SLState.failed] {
                try await slWith(state, glass: glass) { rig in
                    for entry in ssgSteps {
                        await slWalk(rig, to: entry.step)
                        for look in DTLook.allCases {
                            let root = slLayout(rig, look)
                            let tag = "\(state) / \(entry.label) \(look)"
                            #expect(plText(root, ssgReady) == nil, "\(tag): the ready line is shown")
                            #expect(swlImages(root, "checkmark.circle.fill").isEmpty, "\(tag): the status check is shown")
                            let heading = slStyle(root, "The search model")
                            #expect(heading != nil && slFont(heading?.font, size: 13, weight: .semibold), "\(tag): heading \(String(describing: heading?.font))")
                            let bars = prViews(root).compactMap { $0 as? NSProgressIndicator }.filter { plVisible($0) }
                            let figures = prViews(root).compactMap { $0 as? FigureView }.filter { plVisible($0) }
                            #expect(bars.count == 1 && figures.count == 1, "\(tag): \(bars.count) bars, \(figures.count) figures")
                            guard let bar = bars.first, let figure = figures.first,
                                  let text = plText(root, "The search model"), let card = slCard(of: text) else { continue }
                            #expect(!bar.isIndeterminate && bar.style == .bar && bar.controlSize == .small, "\(tag): the bar is not a small determinate bar")
                            #expect(figure.isAccessibilityElement() && figure.accessibilityTitle() == "Model download", "\(tag): figure title \(String(describing: figure.accessibilityTitle()))")
                            #expect(abs(plBox(root, figure).maxX - plBox(root, bar).maxX) <= 1, "\(tag): figure right edge \(plBox(root, figure).maxX), bar right edge \(plBox(root, bar).maxX)")
                            #expect(slCard(of: bar) === card && slCard(of: figure) === card, "\(tag): the bar or figure is outside the heading's card")
                            var upper: [NSView] = [card]
                            if state == .failed {
                                let retry = slButton(root, "Retry")
                                #expect(retry != nil && retry?.isEnabled == true, "\(tag): no enabled Retry")
                                #expect(plText(root, "Try again in a moment.") != nil, "\(tag): no next-step line")
                                if let retry { upper.append(retry) }
                            } else {
                                #expect(slButton(root, "Retry") == nil, "\(tag): Retry is shown")
                            }
                            let gap = swlGap(root, upper: upper, lower: swlNav(root))
                            #expect(max(gap.frame, gap.aligned) >= 15.5, "\(tag): the lowest model content ends \(gap.frame) / \(gap.aligned) pt above the footer, wanted at least 16")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func withAFortyCharacterFolderNameAndFourAddedFoldersNothingOverlapsTheModelBlockOrTheFooter(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    let names = [ssgLongName, "Projects", "Receipts", "Travel"]
                    #expect(ssgLongName.count == 40)
                    let added = try names.map { try rig.env.fill($0, photo: 3) }
                    await slWalk(rig, to: .folders)
                    rig.picks.value = added
                    var root = slLayout(rig)
                    slButton(root, "Add folder\u{2026}")?.performClick(nil)
                    let ready = SLBox<Bool>(false)
                    let deadline = Date().addingTimeInterval(30)
                    while Date() < deadline, !ready.value {
                        ready.value = rig.folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    #expect(ready.value, "\(state): the rows never became ready")
                    for look in DTLook.allCases {
                        root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let checks = slButtons(root).filter { ($0.accessibilityHelp() ?? "").hasPrefix(rig.env.home.path) }
                        for name in names { #expect(checks.contains { $0.title == name }, "\(tag): no row named \(name): \(checks.map(\.title))") }
                        let title = try #require(swlTexts(root, "Folders to read").first, "\(tag): no title")
                        let card = try #require(ssgCard(root, .folders), "\(tag): no folders card")
                        let add = try #require(slButton(root, "Add folder\u{2026}"), "\(tag): no Add folder")
                        let footerTitle = state == .whole ? "Start indexing" : "Next"
                        _ = try #require(slButton(root, footerTitle), "\(tag): no \(footerTitle)")
                        let hint = plText(root, ssgHintTicked)
                        let notNow = slButton(root, "Not now")
                        #expect((hint != nil) == (state == .whole) && (notNow != nil) == (state == .whole), "\(tag): hint \(hint != nil), Not now \(notNow != nil)")
                        let note = try #require(plText(root, ssgReadNote), "\(tag): no read note")
                        let block = ssgModelBlock(root)
                        if state == .whole {
                            #expect(block == nil, "\(tag): a model block is shown on Folders with a whole model")
                        } else {
                            #expect(block != nil, "\(tag): no model block")
                        }
                        var content: [(String, PLBox)] = [("title", plBox(root, title))]
                        for field in ssgIntro(root, title: title, card: card) { content.append(("intro \"\(field.stringValue)\"", plBox(root, field))) }
                        content.append(("card", plBox(root, card)))
                        content.append(("add folder", plBox(root, add)))
                        if let hint { content.append(("hint", plBox(root, hint))) }
                        content.append(("read note", plBox(root, note)))
                        if let notNow { content.append(("not now", plBox(root, notNow))) }
                        for (upper, lower) in zip(content, content.dropFirst()) {
                            #expect(upper.1.bottom <= lower.1.top + 0.5, "\(tag): \(upper.0) ends at \(upper.1.bottom), \(lower.0) starts at \(lower.1.top)")
                        }
                        for part in content {
                            #expect(part.1.minX >= 0 && part.1.maxX <= 560 && part.1.top >= 0, "\(tag): \(part.0) leaves the window")
                            if let block { #expect(!part.1.intersects(block), "\(tag): \(part.0) overlaps the model block") }
                        }
                        let lowest = content.map { $0.1.bottom }.max() ?? 0
                        if let block { #expect(lowest <= block.top + 0.5, "\(tag): content ends at \(lowest), the model block starts at \(block.top)") }
                        let footer = ssgFooter(root).map { plBox(root, $0) }
                        #expect(!footer.isEmpty, "\(tag): no footer")
                        for box in footer {
                            if let block { #expect(block.bottom <= box.top + 0.5, "\(tag): the model block ends at \(block.bottom), the footer starts at \(box.top)") }
                            #expect(lowest <= box.top + 0.5, "\(tag): content ends at \(lowest), the footer starts at \(box.top)")
                            for part in content { #expect(!part.1.intersects(box), "\(tag): \(part.0) overlaps the footer") }
                        }
                        for scroll in prViews(root).compactMap({ $0 as? NSScrollView }).filter({ plVisible($0) }) {
                            #expect(slAncestors(scroll).contains { $0 === card }, "\(tag): a visible scroll view is outside the card")
                        }
                    }
                    await slWalk(rig, to: .permissions)
                    for look in DTLook.allCases {
                        root = slLayout(rig, look)
                        let tag = "\(state) permissions \(look)"
                        let title = try #require(swlTexts(root, "Permissions").first, "\(tag): no title")
                        let card = try #require(ssgCard(root, .permissions), "\(tag): no permissions card")
                        let note = try #require(plText(root, ssgNeverAsked), "\(tag): no note")
                        let block = ssgModelBlock(root)
                        if state == .whole {
                            #expect(block == nil, "\(tag): a model block is shown on Permissions with a whole model")
                        } else {
                            #expect(block != nil, "\(tag): no model block")
                        }
                        var content: [(String, PLBox)] = [("title", plBox(root, title))]
                        for field in ssgIntro(root, title: title, card: card) { content.append(("intro \"\(field.stringValue)\"", plBox(root, field))) }
                        content.append(("card", plBox(root, card)))
                        content.append(("note", plBox(root, note)))
                        for (upper, lower) in zip(content, content.dropFirst()) {
                            #expect(upper.1.bottom <= lower.1.top + 0.5, "\(tag): \(upper.0) ends at \(upper.1.bottom), \(lower.0) starts at \(lower.1.top)")
                        }
                        for part in content {
                            #expect(part.1.minX >= 0 && part.1.maxX <= 560 && part.1.top >= 0, "\(tag): \(part.0) leaves the window")
                            if let block { #expect(!part.1.intersects(block), "\(tag): \(part.0) overlaps the model block") }
                        }
                        let lowest = content.map { $0.1.bottom }.max() ?? 0
                        if let block { #expect(lowest <= block.top + 0.5, "\(tag): content ends at \(lowest), the model block starts at \(block.top)") }
                        let footer = ssgFooter(root).map { plBox(root, $0) }
                        #expect(!footer.isEmpty, "\(tag): no footer")
                        for box in footer {
                            if let block { #expect(block.bottom <= box.top + 0.5, "\(tag): the model block ends at \(block.bottom), the footer starts at \(box.top)") }
                            #expect(lowest <= box.top + 0.5, "\(tag): content ends at \(lowest), the footer starts at \(box.top)")
                            for part in content { #expect(!part.1.intersects(box), "\(tag): \(part.0) overlaps the footer") }
                        }
                    }
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        root = slLayout(rig, look)
                        let tag = "\(state) shortcut \(look)"
                        let title = try #require(swlTexts(root, ssgShortcutHeading).first, "\(tag): no title")
                        let lead = try #require(swlTexts(root, ssgShortcutLead).first, "\(tag): no lead")
                        let note = try #require(plText(root, ssgShortcutNote), "\(tag): no note")
                        let keys = skRow(root)
                        let keysBlock = try #require(skBlock(root, keys), "\(tag): no keys block")
                        let block = ssgModelBlock(root)
                        if state == .whole {
                            #expect(block == nil, "\(tag): a model block is shown on Shortcut with a whole model")
                        } else {
                            #expect(block != nil, "\(tag): no model block")
                        }
                        let content: [(String, PLBox)] = [
                            ("title", plBox(root, title)),
                            ("lead", plBox(root, lead)),
                            ("keys block", keysBlock),
                            ("note", plBox(root, note)),
                        ]
                        for (upper, lower) in zip(content, content.dropFirst()) {
                            #expect(upper.1.bottom <= lower.1.top + 0.5, "\(tag): \(upper.0) ends at \(upper.1.bottom), \(lower.0) starts at \(lower.1.top)")
                        }
                        for part in content {
                            #expect(part.1.minX >= 0 && part.1.maxX <= 560 && part.1.top >= 0, "\(tag): \(part.0) leaves the window")
                            if let block { #expect(!part.1.intersects(block), "\(tag): \(part.0) overlaps the model block") }
                        }
                        let lowest = content.map { $0.1.bottom }.max() ?? 0
                        if let block { #expect(lowest <= block.top + 0.5, "\(tag): content ends at \(lowest), the model block starts at \(block.top)") }
                        let footer = ssgFooter(root).map { plBox(root, $0) }
                        #expect(!footer.isEmpty, "\(tag): no footer")
                        for box in footer {
                            if let block { #expect(block.bottom <= box.top + 0.5, "\(tag): the model block ends at \(block.bottom), the footer starts at \(box.top)") }
                            #expect(lowest <= box.top + 0.5, "\(tag): content ends at \(lowest), the footer starts at \(box.top)")
                            for part in content { #expect(!part.1.intersects(box), "\(tag): \(part.0) overlaps the footer") }
                        }
                    }
                }
            }
        }
    }
}
