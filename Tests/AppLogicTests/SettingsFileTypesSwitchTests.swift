import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let ftsKinds = ["Photos", "PDFs", "Documents", "Audio", "Video"]
private let ftsKeys = ["photo", "pdf", "doc", "audio", "video"]
private let ftsSidebar = ["Folders", "File types", "Search", "Indexing"]
private let ftsTitle = "File types Sesame reads"
private let ftsSaveError = "Could not save your settings."
private let ftsNextStep = "Try again in a moment."

private final class FTSCount: NSObject, @unchecked Sendable {
    private let real: AnyObject
    private let action: Selector
    private(set) var calls = 0

    init(real: AnyObject, action: Selector) {
        self.real = real
        self.action = action
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        aSelector == action || super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == action {
            calls += 1
            return real
        }
        return super.forwardingTarget(for: aSelector)
    }
}

@MainActor
private func ftsWith(
    glass: Bool,
    _ body: @MainActor (SettingsContainerWindow, SXEnv) async throws -> Void
) async throws {
    try await sxWithWindow(sxDefaultFolders, make: { model in
        SettingsContainerWindow(
            model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: MainAppLoginService()),
            appChoices: AppChoices(), deleteIndex: SettingsContainerWindow.unwiredDeleteIndex(), glass: glass)
    }, body)
}

@MainActor
private func ftsSwitches(_ root: NSView, _ section: NSView) -> [NSSwitch] {
    prViews(section)
        .compactMap { $0 as? NSSwitch }
        .filter { plVisible($0) }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func ftsLabel(_ view: NSView) -> String {
    view.accessibilityLabel() ?? ""
}

@MainActor
private func ftsValue(_ control: NSControl) -> Int? {
    ((control as NSAccessibilityProtocol).accessibilityValue() as? NSNumber)?.intValue
}

private func ftsMid(_ box: PLBox) -> CGFloat {
    (box.top + box.bottom) / 2
}

@MainActor
private func ftsName(_ section: NSView, _ kind: String) -> NSTextField? {
    let fields = plTexts(section).filter { $0.stringValue == kind }
    return fields.count == 1 ? fields.first : nil
}

@MainActor
private func ftsSeparators(_ root: NSView, _ card: GroupCard) -> [NSView] {
    let width = plBox(root, card).width
    return prViews(card)
        .filter { $0 !== card && plVisible($0) && $0.frame.height > 0 && $0.frame.height <= 1 && $0.frame.width >= width - 14 - 0.5 }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func ftsExpectSettingsCard(_ card: GroupCard, _ look: DTLook) {
    #expect(card.layer?.cornerRadius == 12, "\(look): radius \(String(describing: card.layer?.cornerRadius))")
    #expect(abs((card.layer?.borderWidth ?? 0) - 0.5) <= 0.01, "\(look): border width \(String(describing: card.layer?.borderWidth))")
    let border = dtRGBA(cgColor: card.layer?.borderColor)
    #expect(border != nil && dtSame(border ?? [], dtRGBA(.separatorColor, look)), "\(look): border \(String(describing: border))")
}

@MainActor
private func ftsKeyOrder(_ section: NSView, from start: NSView) -> [String] {
    var names: [String] = []
    var current: NSView? = start
    while let view = current, view.isDescendant(of: section), names.count < 40 {
        names.append(ftsLabel(view))
        current = view.nextValidKeyView
        if current === start { break }
    }
    return names
}

@MainActor
private func ftsHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    return (layer.sublayers ?? []).contains { ftsHasGradient($0) }
}

@MainActor
private func ftsPress(_ control: NSSwitch, accessibility: Bool) async -> (calls: Int, handled: Bool?) {
    guard let real = control.target, let action = control.action else {
        Issue.record("\(ftsLabel(control)): the switch has no target or no action")
        return (0, nil)
    }
    let counter = FTSCount(real: real, action: action)
    control.target = counter
    defer { control.target = real }
    var handled: Bool?
    if accessibility {
        handled = control.accessibilityPerformPress()
    } else {
        control.performClick(nil)
    }
    await Task.yield()
    return (counter.calls, handled)
}

@MainActor
private func ftsSavedKinds() throws -> [String: Bool] {
    try SettingsFile().read().kindsOn
}

@MainActor
private func ftsPressEveryKind(_ window: SettingsContainerWindow, accessibility: Bool) async throws {
    var root = sxLayout(window, .fileTypes)
    for (index, kind) in ftsKinds.enumerated() {
        let key = ftsKeys[index]
        var section = try #require(sxFileTypesSection(root), "no File types section view")
        var control = try #require(ftsSwitches(root, section).first { ftsLabel($0) == kind }, "no \(kind) switch")
        #expect(control.state == .on, "\(kind): state before the press \(control.state.rawValue)")

        let first = await ftsPress(control, accessibility: accessibility)
        #expect(first.calls == 1, "\(kind): the first press called the action \(first.calls) times")
        if accessibility { #expect(first.handled == true, "\(kind): the accessibility press returned \(String(describing: first.handled))") }
        #expect(control.state == .off, "\(kind): state after the first press \(control.state.rawValue)")
        #expect(ftsValue(control) == 0, "\(kind): value after the first press \(String(describing: ftsValue(control)))")
        var saved = try ftsSavedKinds()
        #expect(saved[key] == false, "\(kind): the first press saved \(String(describing: saved[key]))")
        for other in ftsKeys where other != key {
            #expect(saved[other] != false, "pressing \(kind) changed \(other): \(saved)")
        }

        root = sxRelayout(window)
        section = try #require(sxFileTypesSection(root))
        control = try #require(ftsSwitches(root, section).first { ftsLabel($0) == kind }, "no \(kind) switch after a redraw")
        #expect(control.state == .off && ftsValue(control) == 0, "\(kind): drawn \(control.state.rawValue) after the redraw")

        let second = await ftsPress(control, accessibility: accessibility)
        #expect(second.calls == 1, "\(kind): the second press called the action \(second.calls) times")
        if accessibility { #expect(second.handled == true, "\(kind): the second accessibility press returned \(String(describing: second.handled))") }
        #expect(control.state == .on, "\(kind): state after the second press \(control.state.rawValue)")
        #expect(ftsValue(control) == 1, "\(kind): value after the second press \(String(describing: ftsValue(control)))")
        saved = try ftsSavedKinds()
        #expect(saved[key] == true, "\(kind): the second press saved \(String(describing: saved[key]))")

        root = sxRelayout(window)
        section = try #require(sxFileTypesSection(root))
        #expect(ftsSwitches(root, section).first { ftsLabel($0) == kind }?.state == .on, "\(kind): drawn off after the second redraw")
    }
}

extension ModelDownloadTests {
    @Suite("SettingsFileTypesSwitchTests", .serialized)
    struct SettingsFileTypesSwitchTests {

        @MainActor
        @Test(arguments: slPaths)
        func theTitleThenOneSettingsCardRunTopToBottomWithNoNoteAndNoTextBeyondTheTitleAndTheFiveNames(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .fileTypes, look)
                    let section = try #require(sxFileTypesSection(root), "no File types section view")
                    #expect(plVisible(section), "\(look): the section is hidden")
                    let cards = sxVisibleCards(section)
                    #expect(cards.count == 1, "\(look): \(cards.count) visible cards, wanted one")
                    guard cards.count == 1, let card = cards.first else { continue }
                    ftsExpectSettingsCard(card, look)
                    let cardBox = plBox(root, card)
                    #expect(abs(cardBox.minX - 197) <= 1 && abs(cardBox.maxX - 704) <= 1, "\(look): the card spans \(cardBox.minX) to \(cardBox.maxX)")

                    let title = try #require(plText(section, ftsTitle), "\(look): no \"\(ftsTitle)\": \(plTexts(section).map(\.stringValue))")
                    #expect(sxFont(title.font, size: 13, weight: .semibold), "\(look): title font \(String(describing: title.font))")
                    #expect(sxColour(title.textColor, is: .labelColor), "\(look): title colour")
                    #expect(sxCard(of: title) == nil, "\(look): the title is inside a card")
                    let titleBox = plBox(root, title)
                    #expect(titleBox.top < cardBox.top && titleBox.bottom <= cardBox.top + 0.5, "\(look): the title spans \(titleBox.top) to \(titleBox.bottom), the card starts at \(cardBox.top)")

                    let texts = plTexts(section)
                    #expect(texts.filter { sxCard(of: $0) == nil }.map(\.stringValue) == [ftsTitle], "\(look): texts outside the card \(texts.filter { sxCard(of: $0) == nil }.map(\.stringValue))")
                    let inside = texts.filter { sxCard(of: $0) === card }.sorted { plBox(root, $0).top < plBox(root, $1).top }
                    #expect(inside.map(\.stringValue) == ftsKinds, "\(look): texts in the card \(inside.map(\.stringValue))")
                    #expect(texts.count == 6, "\(look): \(texts.count) texts in the section: \(texts.map(\.stringValue))")
                    #expect(texts.allSatisfy { plBox(root, $0).top < cardBox.bottom }, "\(look): a text sits under the card")
                    let named = texts.filter { $0.stringValue == "File types" }
                    #expect(named.isEmpty, "\(look): the section draws \"File types\"")
                    let titled = texts.filter { $0.font?.pointSize == 17 }
                    #expect(titled.isEmpty, "\(look): the section draws a 17 pt text")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theErrorLineComesAfterTheCardWithNothingBetween(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                var root = sxLayout(window, .fileTypes)
                var section = try #require(sxFileTypesSection(root), "no File types section view")
                let video = try #require(ftsSwitches(root, section).first { ftsLabel($0) == "Video" })
                #expect(await sxProvokeSaveError(pressing: video), "could not make a failed write")
                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFileTypesSection(root))
                    let cards = sxVisibleCards(section)
                    #expect(cards.count == 1, "\(look): \(cards.count) visible cards with an error")
                    guard let card = cards.first else { continue }
                    let cardBox = plBox(root, card)
                    let outside = plTexts(section).filter { sxCard(of: $0) == nil }.sorted { plBox(root, $0).top < plBox(root, $1).top }
                    #expect(outside.map(\.stringValue) == [ftsTitle, ftsSaveError, ftsNextStep], "\(look): texts outside the card \(outside.map(\.stringValue))")
                    guard outside.count == 3 else { continue }
                    #expect(plBox(root, outside[0]).bottom <= cardBox.top + 0.5, "\(look): the title is not above the card")
                    #expect(plBox(root, outside[1]).top >= cardBox.bottom - 0.5, "\(look): the error starts at \(plBox(root, outside[1]).top), the card ends at \(cardBox.bottom)")
                    #expect(plBox(root, outside[2]).top >= plBox(root, outside[1]).bottom - 0.5, "\(look): the next-step line is above the error")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func fiveRowsRunPhotosPDFsDocumentsAudioVideoEachWithTheNameAtTheLeftAndTheSystemSwitchAtTheRight(glass: Bool) async throws {
            let reference = NSSwitch().intrinsicContentSize
            try await ftsWith(glass: glass) { window, _ in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .fileTypes, look)
                    let section = try #require(sxFileTypesSection(root), "no File types section view")
                    let cards = sxVisibleCards(section)
                    guard cards.count == 1, let card = cards.first else {
                        Issue.record("\(look): \(cards.count) visible cards")
                        continue
                    }
                    let cardBox = plBox(root, card)
                    let switches = ftsSwitches(root, section)
                    #expect(switches.map(ftsLabel) == ftsKinds, "\(look): switches \(switches.map(ftsLabel))")
                    #expect(prViews(section).compactMap { $0 as? NSSwitch }.count == 5, "\(look): \(prViews(section).compactMap { $0 as? NSSwitch }.count) NSSwitch in the section")
                    let kindButtons = prViews(section).compactMap { $0 as? NSButton }.filter { ftsKinds.contains($0.title) || ftsKinds.contains($0.accessibilityLabel() ?? "") }
                    #expect(kindButtons.isEmpty, "\(look): NSButton for a kind: \(kindButtons.map(\.title))")
                    let separators = ftsSeparators(root, card)
                    #expect(separators.count == 4, "\(look): \(separators.count) hairlines for five rows")
                    guard switches.count == 5, separators.count == 4 else { continue }
                    let lines = separators.map { plBox(root, $0) }
                    var spanTop = CGFloat.greatestFiniteMagnitude
                    var spanBottom = -CGFloat.greatestFiniteMagnitude

                    for (index, control) in switches.enumerated() {
                        let kind = ftsKinds[index]
                        let tag = "\(look) \(kind)"
                        let rowTop = index == 0 ? cardBox.top : ftsMid(lines[index - 1])
                        let rowBottom = index == 4 ? cardBox.bottom : ftsMid(lines[index])
                        let rowMid = (rowTop + rowBottom) / 2
                        #expect(rowBottom - rowTop >= 40 - 0.5, "\(tag): the row is \(rowBottom - rowTop) tall")

                        let box = plBox(root, control)
                        #expect(sxCard(of: control) === card, "\(tag): the switch is not in the card")
                        #expect(control.controlSize == .regular, "\(tag): control size \(control.controlSize.rawValue)")
                        #expect(abs(box.width - reference.width) <= 0.5 && abs(box.height - reference.height) <= 0.5, "\(tag): the switch is \(box.width) x \(box.height), a system switch is \(reference.width) x \(reference.height)")
                        #expect(abs((cardBox.maxX - box.maxX) - 14) <= 1, "\(tag): the switch ends \(cardBox.maxX - box.maxX) from the card's right edge")
                        #expect(abs(ftsMid(box) - rowMid) <= 1.5, "\(tag): the switch centre is \(ftsMid(box)), the row's \(rowMid)")

                        let name = try #require(ftsName(section, kind), "\(tag): no single text \"\(kind)\": \(plTexts(section).map(\.stringValue))")
                        let nameBox = plBox(root, name)
                        #expect(sxFont(name.font, size: 12.5, weight: .semibold), "\(tag): name font \(String(describing: name.font))")
                        #expect(sxColour(name.textColor, is: .labelColor), "\(tag): name colour")
                        #expect(sxCard(of: name) === card, "\(tag): the name is not in the card")
                        #expect(!name.isAccessibilityElement(), "\(tag): the name is an accessibility element")
                        #expect(abs((nameBox.minX - cardBox.minX) - 14) <= 1, "\(tag): the name starts \(nameBox.minX - cardBox.minX) in from the card edge")
                        #expect(abs(ftsMid(nameBox) - rowMid) <= 1.5, "\(tag): the name centre is \(ftsMid(nameBox)), the row's \(rowMid)")
                        #expect(!nameBox.intersects(box) && nameBox.maxX <= box.minX + 0.5, "\(tag): the name reaches \(nameBox.maxX), the switch starts at \(box.minX)")

                        let part = nameBox.union(box)
                        spanTop = min(spanTop, part.top)
                        spanBottom = max(spanBottom, part.bottom)
                        if index < 4 {
                            #expect(lines[index].top >= part.bottom - 0.5, "\(tag): the hairline below starts at \(lines[index].top), the row ends at \(part.bottom)")
                        }
                        if index > 0 {
                            #expect(lines[index - 1].bottom <= part.top + 0.5, "\(tag): the hairline above ends at \(lines[index - 1].bottom), the row starts at \(part.top)")
                        }
                    }
                    #expect(abs(cardBox.height - (spanBottom - spanTop + 20)) <= 1, "\(look): the card is \(cardBox.height) tall for rows spanning \(spanBottom - spanTop)")

                    for (index, line) in separators.enumerated() {
                        let box = lines[index]
                        #expect(line.frame.height >= 0.5 && line.frame.height <= 1, "\(look): hairline \(index) is \(line.frame.height) tall")
                        #expect(abs((box.minX - cardBox.minX) - 14) <= 1, "\(look): hairline \(index) starts \(box.minX - cardBox.minX) in from the card edge")
                        #expect(abs(cardBox.maxX - box.maxX) <= 1, "\(look): hairline \(index) ends \(cardBox.maxX - box.maxX) from the card's right edge")
                        let fill = dtRGBA(cgColor: line.layer?.backgroundColor)
                        #expect(fill != nil && dtSame(fill ?? [], dtRGBA(.separatorColor, look)), "\(look): hairline \(index) colour \(String(describing: fill))")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aKindThatIsOffDrawsItsNameInLabelColourToo(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                var root = sxLayout(window, .fileTypes)
                var section = try #require(sxFileTypesSection(root), "no File types section view")
                let audio = try #require(ftsSwitches(root, section).first { ftsLabel($0) == "Audio" })
                audio.performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFileTypesSection(root))
                    let switches = ftsSwitches(root, section)
                    #expect(switches.first { ftsLabel($0) == "Audio" }?.state == .off, "\(look): Audio is not off")
                    #expect(switches.first { ftsLabel($0) == "Audio" }?.isEnabled == true, "\(look): an off Audio switch is disabled")
                    for kind in ftsKinds {
                        let name = try #require(ftsName(section, kind), "\(look): no text \"\(kind)\"")
                        #expect(sxColour(name.textColor, is: .labelColor), "\(look): \(kind) is not in the label colour")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theKitReadsFiveCheckBoxSwitchesLabelledByKindWithValueOneOrZeroAndNoStaticTextForAKindName(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                let root = sxLayout(window, .fileTypes)
                let section = try #require(sxFileTypesSection(root), "no File types section view")
                let switches = ftsSwitches(root, section)
                #expect(switches.map(ftsLabel) == ftsKinds, "labels \(switches.map(ftsLabel))")
                for control in switches {
                    let kind = ftsLabel(control)
                    #expect(control.isAccessibilityElement(), "\(kind): not an accessibility element")
                    #expect(control.accessibilityRole()?.rawValue == "AXCheckBox", "\(kind): role \(String(describing: control.accessibilityRole()?.rawValue))")
                    #expect(control.accessibilitySubrole()?.rawValue == "AXSwitch", "\(kind): subrole \(String(describing: control.accessibilitySubrole()?.rawValue))")
                    let title = control.accessibilityTitle() ?? ""
                    #expect(title.isEmpty || title == kind, "\(kind): the title \"\(title)\" would be read before the label")
                    #expect((control.accessibilityHelp() ?? "").isEmpty, "\(kind): help \"\(control.accessibilityHelp() ?? "nil")\"")
                    #expect(control.isEnabled, "\(kind): disabled")
                    #expect(control.state == .on && ftsValue(control) == 1, "\(kind): state \(control.state.rawValue) value \(String(describing: ftsValue(control)))")
                    control.state = .off
                    #expect(ftsValue(control) == 0, "\(kind): value \(String(describing: ftsValue(control))) while off")
                    control.state = .on
                    #expect(ftsValue(control) == 1, "\(kind): value \(String(describing: ftsValue(control))) while on")
                }

                let elements = prViews(section).filter { plVisible($0) && $0.isAccessibilityElement() }
                let dumped = elements.filter { $0.accessibilityRole()?.rawValue == "AXCheckBox" && $0.accessibilitySubrole()?.rawValue == "AXSwitch" }
                #expect(dumped.count == 5, "\(dumped.count) AXCheckBox/AXSwitch elements in the section")
                #expect(dumped.allSatisfy { $0 is NSSwitch }, "an AXCheckBox/AXSwitch element is not an NSSwitch")
                #expect(elements.filter { ftsKinds.contains(ftsLabel($0)) }.count == 5, "elements labelled with a kind: \(elements.filter { ftsKinds.contains(ftsLabel($0)) }.map { String(describing: type(of: $0)) })")
                let staticNames = elements.filter { view in
                    view.accessibilityRole() == .staticText
                        && (ftsKinds.contains(ftsLabel(view)) || ftsKinds.contains((view as? NSTextField)?.stringValue ?? ""))
                }
                #expect(staticNames.isEmpty, "AXStaticText for a kind name: \(staticNames.map { ftsLabel($0) })")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func performClickOnASwitchFlipsItCallsTheActionOnceAndSavesTheChoiceForEachOfTheFiveKinds(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                try await ftsPressEveryKind(window, accessibility: false)
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theAccessibilityPressOnASwitchDoesTheSameAndReportsItWasHandled(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                try await ftsPressEveryKind(window, accessibility: true)
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aDisabledSwitchIsNeitherClickedNorPressedThroughAccessibility(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                let root = sxLayout(window, .fileTypes)
                let section = try #require(sxFileTypesSection(root), "no File types section view")
                let photos = try #require(ftsSwitches(root, section).first { ftsLabel($0) == "Photos" })
                photos.isEnabled = false
                let clicked = await ftsPress(photos, accessibility: false)
                #expect(clicked.calls == 0, "performClick on a disabled switch called the action \(clicked.calls) times")
                #expect(photos.state == .on, "performClick on a disabled switch left it \(photos.state.rawValue)")
                let pressed = await ftsPress(photos, accessibility: true)
                #expect(pressed.calls == 0, "the accessibility press on a disabled switch called the action \(pressed.calls) times")
                #expect(pressed.handled != true, "the accessibility press on a disabled switch returned \(String(describing: pressed.handled))")
                #expect(photos.state == .on, "the accessibility press on a disabled switch left it \(photos.state.rawValue)")
                #expect(try ftsSavedKinds()["photo"] != false, "a disabled switch saved a change")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theKeyViewsAreTheFiveSwitchesInOrderEachAKeyStopOfItsOwnClassAndTheTabWalkFromTheSidebarClosesTheLoop(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                let root = sxLayout(window, .fileTypes)
                let section = try #require(sxFileTypesSection(root), "no File types section view")
                let switches = ftsSwitches(root, section)
                #expect(switches.map(ftsLabel) == ftsKinds, "switches \(switches.map(ftsLabel))")
                for control in switches {
                    let kind = ftsLabel(control)
                    #expect(control.acceptsFirstResponder && !control.refusesFirstResponder, "\(kind): acceptsFirstResponder \(control.acceptsFirstResponder)")
                    #expect(control.canBecomeKeyView, "\(kind): canBecomeKeyView \(control.canBecomeKeyView)")
                    #expect(type(of: control) != NSSwitch.self, "\(kind): a plain NSSwitch, a key stop only while Full Keyboard Access is on")
                }
                if let start = switches.first {
                    #expect(ftsKeyOrder(section, from: start) == ftsKinds, "key views from the first switch \(ftsKeyOrder(section, from: start))")
                }

                let first = try #require(window.initialFirstResponder, "the window has no initialFirstResponder")
                var visited: [NSView] = []
                var current: NSView? = first
                while let view = current, visited.count < 200, !visited.contains(where: { $0 === view }) {
                    visited.append(view)
                    current = view.nextValidKeyView
                }
                #expect(current === first, "the walk never came back to the start after \(visited.count) views")
                let walked = visited.filter { $0 is NSSwitch || $0 is SidebarButton }.map(ftsLabel)
                #expect(walked.filter { ftsSidebar.contains($0) } == ftsSidebar, "sidebar stops \(walked)")
                #expect(walked.filter { ftsKinds.contains($0) } == ftsKinds, "kind stops \(walked)")
                #expect(walked.count == 9, "\(walked.count) stops: \(walked)")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSectionDrawsOnlyLabelSecondaryAndRedWithNoGradientEffectViewOrGlassInTheCard(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                var root = sxLayout(window, .fileTypes)
                var section = try #require(sxFileTypesSection(root), "no File types section view")
                let video = try #require(ftsSwitches(root, section).first { ftsLabel($0) == "Video" })
                #expect(await sxProvokeSaveError(pressing: video), "could not make a failed write")
                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFileTypesSection(root))
                    let allowed: [NSColor] = [.labelColor, .secondaryLabelColor, .systemRed]
                    for field in plTexts(section) {
                        #expect(allowed.contains { sxColour(field.textColor, is: $0) }, "\(look): \"\(field.stringValue)\" is drawn in \(String(describing: field.textColor))")
                        if sxColour(field.textColor, is: .systemRed) {
                            #expect(field.stringValue == ftsSaveError, "\(look): \"\(field.stringValue)\" is red")
                        }
                    }
                    for kind in ftsKinds + [ftsTitle] {
                        let field = try #require(plText(section, kind), "\(look): no text \"\(kind)\"")
                        #expect(sxColour(field.textColor, is: .labelColor), "\(look): \"\(kind)\" is not in the label colour")
                    }
                    let views = prViews(section)
                    #expect(!views.contains { $0 is NSVisualEffectView || slIsGlass($0) }, "\(look): an effect or glass view in the section")
                    #expect(!views.contains { ftsHasGradient($0.layer) }, "\(look): a gradient layer in the section")
                    let accent = dtRGBA(.controlAccentColor, look)
                    let own = views.filter { view in !(view is NSSwitch) && !sxAncestors(view).contains { $0 is NSSwitch } }
                    for view in own {
                        for cgColor in [view.layer?.backgroundColor, view.layer?.borderColor] {
                            let rgba = dtRGBA(cgColor: cgColor)
                            #expect(rgba == nil || !dtSame(rgba ?? [], accent), "\(look): a \(type(of: view)) layer is drawn in the accent colour")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theErrorLineKeepsTheWarningSymbolTheMessageAndTheNextStepLineAfterAFailedSave(glass: Bool) async throws {
            try await ftsWith(glass: glass) { window, _ in
                var root = sxLayout(window, .fileTypes)
                var section = try #require(sxFileTypesSection(root), "no File types section view")
                syExpectNoWarning(section, .light)
                let video = try #require(ftsSwitches(root, section).first { ftsLabel($0) == "Video" })
                #expect(await sxProvokeSaveError(pressing: video), "could not make a failed write")
                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFileTypesSection(root))
                    syExpectWarningLine(root, section, text: ftsSaveError, red: false, look)
                }
            }
        }
    }
}
