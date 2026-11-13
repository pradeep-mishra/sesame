import AppKit
import Foundation
import Testing
@testable import Sesame

private let sgSevenTitles = ["Back", "Next", "Finish", "Add folder\u{2026}", "Start indexing", "Not now", "Retry"]
private let sgBorderless = ["Add folder\u{2026}", "Not now"]
private let sgTinted = ["Next", "Start indexing", "Finish"]
private let sgAllStates: [SLState] = [.whole, .downloading, .damaged, .failed]
private let sgGlassBezel = 16
private let sgAddFolder = "Add folder\u{2026}"

private struct SGSeen {
    let step: SetupFlow.Step
    let button: NSButton
    let title: String
    let visible: Bool
}

private final class SGHold: @unchecked Sendable {
    var value: [SGSeen] = []
}

private struct SGFrame {
    let tag: String
    let box: PLBox
}

@MainActor
private func sgSurvey(_ rig: SLRig) async -> [SGSeen] {
    var out: [SGSeen] = []
    for entry in slStepNames {
        await slWalk(rig, to: entry.step)
        let root = slLayout(rig)
        for view in prViews(root) {
            guard let button = view as? NSButton, sgSevenTitles.contains(button.title) else { continue }
            out.append(SGSeen(step: entry.step, button: button, title: button.title, visible: plVisible(button)))
        }
    }
    return out
}

@MainActor
private func sgSurveyOf(_ state: SLState, glass: Bool) async throws -> [SGSeen] {
    let seen = SGHold()
    try await slWith(state, glass: glass) { rig in
        let found = await sgSurvey(rig)
        seen.value = found
        let welcomeNext = found.first { $0.step == .welcome && $0.title == "Next" }
        let foldersStart = found.first { $0.step == .folders && $0.title == "Start indexing" }
        if state == .whole {
            #expect(welcomeNext != nil && foldersStart != nil && welcomeNext?.button === foldersStart?.button, "the footer button of Folders is not the view that reads Next on Welcome")
            #expect(!found.contains { $0.step == .folders && $0.visible && $0.title == "Next" }, "Next is visible on Folders beside Start indexing")
        } else {
            #expect(!found.contains { $0.visible && ($0.title == "Start indexing" || $0.title == "Not now") }, "\(state): Start indexing or Not now is visible with a model that is not whole")
        }
    }
    return seen.value
}

@MainActor
private func sgPair(_ state: SLState, _ body: @MainActor (SLRig, SLRig) async throws -> Void) async throws {
    try await slWith(state, glass: false) { flat in
        try await slWith(state, glass: true) { glass in
            let flatGlass = slGlassViews(flat.window).count
            let glassGlass = slGlassViews(glass.window).count
            #expect(flatGlass == 0 && glassGlass == 1, "\(state): \(flatGlass) glass views in the flat window, \(glassGlass) in the glass window")
            try await body(flat, glass)
        }
    }
}

@MainActor
private func sgNormal(_ text: String?, _ rig: SLRig) -> String {
    (text ?? "").replacingOccurrences(of: rig.env.home.path, with: "<home>")
}

@MainActor
private func sgButtons(_ rig: SLRig, _ root: NSView) -> [String] {
    slButtons(root).map { "\($0.title)|\(sgNormal($0.accessibilityLabel(), rig))|\(sgNormal($0.accessibilityHelp(), rig))|\($0.isEnabled)" }
}

@MainActor
private func sgKeyLoop(_ rig: SLRig) -> [String] {
    slKeyLoop(rig.window).map { view in
        "\(String(describing: type(of: view)))|\((view as? NSButton)?.title ?? sgNormal(view.accessibilityLabel(), rig))"
    }
}

@MainActor
private func sgElements(_ rig: SLRig, _ root: NSView) -> [String] {
    prViews(root).filter { $0.isAccessibilityElement() && plVisible($0) }.map { view in
        let role = view.accessibilityRole()?.rawValue ?? "none"
        let value = view.accessibilityValue().map { String(describing: $0) }
        return "\(role)|\(sgNormal(view.accessibilityLabel(), rig))|\(sgNormal(view.accessibilityTitle(), rig))|\(sgNormal(value, rig))|\(sgNormal(view.accessibilityHelp(), rig))"
    }
}

@MainActor
private func sgFrames(_ root: NSView) -> [SGFrame] {
    prViews(root).filter { view in
        guard plVisible(view), !slIsGlass(view), !slAncestors(view).contains(where: { slIsGlass($0) }) else { return false }
        if let field = view as? NSTextField { return !field.stringValue.isEmpty }
        return view is NSButton || view is NSImageView || view is NSProgressIndicator || view is FigureView
            || view is GroupCard || view is StepDots
    }.map { view in
        var text = ""
        if let field = view as? NSTextField { text = field.stringValue }
        if let button = view as? NSButton { text = button.title }
        return SGFrame(tag: "\(String(describing: type(of: view)))|\(text)", box: plBox(root, view))
    }
}

@MainActor
private func sgClear(_ color: NSColor) -> Bool {
    DTLook.allCases.allSatisfy { (dtRGBA(color, $0).last ?? 1) < 0.001 }
}

extension ModelDownloadTests {
    @Suite("SetupGlassTests", .serialized)
    struct SetupGlassTests {

        @MainActor
        @Test func theFlatWindowIsOpaqueWithTheWindowBackgroundColourTheTitleSetUpSesameAndTheLayoutContentView() async throws {
            try await slWith(.whole, glass: false) { rig in
                let opaque = rig.window.isOpaque
                let background: NSColor = rig.window.backgroundColor
                let title = rig.window.title
                #expect(opaque, "the flat window is not opaque")
                #expect(slColour(background, is: .windowBackgroundColor), "flat window background \(background)")
                #expect(title == "Set up Sesame", "title \(title)")
                let content = try #require(rig.window.contentView, "no content view")
                let isGlass = slIsGlass(content)
                let sameView = slLayout(rig) === content
                #expect(!isGlass, "the content view is a glass view")
                #expect(sameView, "the layout tests walk another view than window.contentView")
                #expect(slButton(content, "Next") != nil, "Next is not under window.contentView")
            }
        }

        @MainActor
        @Test func noGlassViewIsFoundByClassNameAnywhereInTheFlatWindowOnAnyStepOrModelState() async throws {
            for state in sgAllStates {
                try await slWith(state, glass: false) { rig in
                    for entry in slStepNames {
                        await slWalk(rig, to: entry.step)
                        _ = slLayout(rig)
                        let count = slGlassViews(rig.window).count
                        #expect(count == 0, "\(state) / \(entry.label): \(count) glass views in the flat window")
                    }
                }
            }
        }

        @MainActor
        @Test func fourSetupButtonsAreRoundedOnTheFlatPathAddFolderAndNotNowAreBorderlessAndAllSevenTitlesAreFound() async throws {
            let failed = try await sgSurveyOf(.failed, glass: false)
            let whole = try await sgSurveyOf(.whole, glass: false)
            let seen = failed + whole
            #expect(Set(seen.map(\.title)) == Set(sgSevenTitles), "found \(Set(seen.map(\.title)).sorted())")
            for item in seen {
                let isSetup = item.button is SetupButton
                #expect(isSetup, "\(item.title) is not a SetupButton")
                if sgBorderless.contains(item.title) {
                    #expect(!item.button.isBordered, "\(item.step) \(item.title): the button is bordered")
                } else {
                    #expect(item.button.bezelStyle == .rounded, "\(item.step) \(item.title): bezel \(item.button.bezelStyle.rawValue)")
                }
            }
        }

        @MainActor
        @Test func onTheFlatPathTheFooterButtonAndFinishHaveReturnAndNoBezelColourAndTheOthersHaveNeither() async throws {
            for state in [SLState.failed, SLState.whole] {
                let seen = try await sgSurveyOf(state, glass: false)
                #expect(!seen.isEmpty, "\(state): no buttons found")
                for item in seen {
                    let name = "\(state) \(item.step) \(item.title)"
                    #expect(item.button.bezelColor == nil, "\(name): bezel colour \(String(describing: item.button.bezelColor))")
                    if sgTinted.contains(item.title) {
                        if item.visible { #expect(item.button.keyEquivalent == "\r", "\(name): key equivalent \(item.button.keyEquivalent.debugDescription)") }
                    } else {
                        #expect(item.button.keyEquivalent.isEmpty, "\(name): key equivalent \(item.button.keyEquivalent.debugDescription)")
                    }
                }
                for entry in slStepNames {
                    let primary = entry.step == .shortcut ? "Finish" : (entry.step == .folders && state == .whole ? "Start indexing" : "Next")
                    #expect(seen.contains { $0.step == entry.step && $0.visible && $0.title == primary && $0.button.keyEquivalent == "\r" }, "\(state) \(entry.label): no visible \(primary) with Return")
                }
            }
        }

        @MainActor
        @Test func aWindowBuiltWithoutTheGlassArgumentTakesTheGlassPathExactlyWhenGlassIsAvailable() async throws {
            try await slWith(.whole) { rig in
                _ = slLayout(rig)
                let want = Glass.isAvailable
                let count = slGlassViews(rig.window).count
                let opaque = rig.window.isOpaque
                #expect(count == (want ? 1 : 0), "\(count) glass views, glass available \(want)")
                #expect(opaque == !want, "isOpaque \(opaque), glass available \(want)")
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func theGlassWindowIsNotOpaqueAndItsBackgroundIsClearWithTheTitleSetUpSesame() async throws {
            try await slWith(.whole, glass: true) { rig in
                let opaque = rig.window.isOpaque
                let background: NSColor = rig.window.backgroundColor
                let title = rig.window.title
                #expect(!opaque, "the glass window is opaque")
                #expect(sgClear(background), "glass window background \(background)")
                #expect(title == "Set up Sesame", "title \(title)")
                let content = try #require(rig.window.contentView, "no content view")
                let isGlass = slIsGlass(content)
                let sameView = slLayout(rig) === content
                #expect(!isGlass, "the content view is the glass view")
                #expect(sameView, "the layout tests walk another view than window.contentView")
                #expect(slButton(content, "Next") != nil, "Next is not under window.contentView")
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func exactlyOneRegularEmptyGlassViewIsTheLowestSubviewOfTheContentViewFillingItsBounds() async throws {
            for state in sgAllStates {
                try await slWith(state, glass: true) { rig in
                    for entry in slStepNames {
                        await slWalk(rig, to: entry.step)
                        for look in DTLook.allCases {
                            let root = slLayout(rig, look)
                            let tag = "\(state) / \(entry.label) \(look)"
                            let found = slGlassViews(rig.window)
                            #expect(found.count == 1, "\(tag): \(found.count) glass views")
                            guard let glass = found.first else { continue }
                            let lowest = root.subviews.first === glass
                            let direct = glass.superview === root
                            #expect(lowest, "\(tag): the glass view is not the lowest subview of the content view")
                            #expect(direct, "\(tag): the glass view is not a direct subview of the content view")
                            #expect(abs(glass.frame.minX) <= 0.5 && abs(glass.frame.minY) <= 0.5
                                    && abs(glass.frame.width - root.bounds.width) <= 0.5 && abs(glass.frame.height - root.bounds.height) <= 0.5,
                                    "\(tag): glass frame \(glass.frame), content bounds \(root.bounds)")
                            #expect((glass.value(forKey: "style") as? NSNumber)?.intValue == 0, "\(tag): glass style \(String(describing: glass.value(forKey: "style")))")
                            #expect(glass.value(forKey: "contentView") == nil, "\(tag): the glass view has a content view")
                            #expect(!glass.isAccessibilityElement(), "\(tag): the glass view is an accessibility element")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func theGlassViewStaysPinnedToAllFourEdgesWhenTheContentSizeChanges() async throws {
            try await slWith(.whole, glass: true) { rig in
                let original = rig.window.contentRect(forFrameRect: rig.window.frame).size
                defer { rig.window.setContentSize(original) }
                for size in [NSSize(width: 640, height: 700), NSSize(width: 520, height: 560)] {
                    rig.window.setContentSize(size)
                    let root = slLayout(rig)
                    let glass = try #require(slGlassViews(rig.window).first, "no glass view")
                    #expect(abs(root.bounds.width - size.width) <= 0.5 && abs(root.bounds.height - size.height) <= 0.5, "content bounds \(root.bounds) for \(size)")
                    #expect(abs(glass.frame.minX) <= 0.5 && abs(glass.frame.minY) <= 0.5
                            && abs(glass.frame.width - root.bounds.width) <= 0.5 && abs(glass.frame.height - root.bounds.height) <= 0.5,
                            "glass frame \(glass.frame), content bounds \(root.bounds) at \(size)")
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func noGlassViewSitsInsideAGroupCardOrAnyCardOnAnyStepOrModelState() async throws {
            for state in sgAllStates {
                try await slWith(state, glass: true) { rig in
                    for entry in slStepNames {
                        await slWalk(rig, to: entry.step)
                        let root = slLayout(rig)
                        let tag = "\(state) / \(entry.label)"
                        let cards = prViews(root).compactMap { $0 as? GroupCard }
                        for card in cards {
                            let inside = prViews(card).contains { slIsGlass($0) }
                            #expect(!inside, "\(tag): a glass view is inside a GroupCard")
                        }
                        for glass in slGlassViews(rig.window) {
                            let under = slCard(of: glass) != nil
                            #expect(!under, "\(tag): the glass view has a GroupCard above it")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func fourSetupButtonsAreBezelSixteenOnTheGlassPathAndAddFolderAndNotNowAreBorderlessNotGlass() async throws {
            let failed = try await sgSurveyOf(.failed, glass: true)
            let whole = try await sgSurveyOf(.whole, glass: true)
            let seen = failed + whole
            #expect(Set(seen.map(\.title)) == Set(sgSevenTitles), "found \(Set(seen.map(\.title)).sorted())")
            for item in seen {
                let isSetup = item.button is SetupButton
                #expect(isSetup, "\(item.title) is not a SetupButton")
                if sgBorderless.contains(item.title) {
                    #expect(!item.button.isBordered, "\(item.step) \(item.title): the button is bordered")
                    #expect(item.button.bezelStyle.rawValue != sgGlassBezel, "\(item.step) \(item.title): a glass bezel")
                } else {
                    #expect(item.button.bezelStyle.rawValue == sgGlassBezel, "\(item.step) \(item.title): bezel \(item.button.bezelStyle.rawValue)")
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func onTheGlassPathTheFooterButtonAndFinishAreTintedWithTheAccentAndHaveReturnAndTheOthersHaveNeither() async throws {
            for state in [SLState.failed, SLState.whole] {
                let seen = try await sgSurveyOf(state, glass: true)
                #expect(!seen.isEmpty, "\(state): no buttons found")
                for item in seen {
                    let name = "\(state) \(item.step) \(item.title)"
                    if sgTinted.contains(item.title) {
                        #expect(slColour(item.button.bezelColor, is: .controlAccentColor), "\(name): bezel colour \(String(describing: item.button.bezelColor))")
                        if item.visible { #expect(item.button.keyEquivalent == "\r", "\(name): key equivalent \(item.button.keyEquivalent.debugDescription)") }
                    } else {
                        #expect(item.button.bezelColor == nil, "\(name): bezel colour \(String(describing: item.button.bezelColor))")
                        #expect(item.button.keyEquivalent.isEmpty, "\(name): key equivalent \(item.button.keyEquivalent.debugDescription)")
                    }
                }
                for entry in slStepNames {
                    let primary = entry.step == .shortcut ? "Finish" : (entry.step == .folders && state == .whole ? "Start indexing" : "Next")
                    #expect(seen.contains { $0.step == entry.step && $0.visible && $0.title == primary && $0.button.keyEquivalent == "\r" }, "\(state) \(entry.label): no visible \(primary) with Return")
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func theGlassWindowHasTheSameButtonsTitlesLabelsHelpsAndKeyLoopAsTheFlatWindowOnEveryStepAndModelState() async throws {
            for state in sgAllStates {
                try await sgPair(state) { flat, glass in
                    for entry in slStepNames {
                        await slWalk(flat, to: entry.step)
                        await slWalk(glass, to: entry.step)
                        let flatRoot = slLayout(flat)
                        let glassRoot = slLayout(glass)
                        let tag = "\(state) / \(entry.label)"
                        let flatButtons = sgButtons(flat, flatRoot)
                        let glassButtons = sgButtons(glass, glassRoot)
                        #expect(!flatButtons.isEmpty, "\(tag): the flat window has no buttons")
                        #expect(flatButtons.count == glassButtons.count, "\(tag): \(flatButtons.count) flat buttons, \(glassButtons.count) glass buttons")
                        #expect(flatButtons == glassButtons, "\(tag): flat \(flatButtons), glass \(glassButtons)")
                        let flatLoop = sgKeyLoop(flat)
                        let glassLoop = sgKeyLoop(glass)
                        #expect(!flatLoop.isEmpty, "\(tag): the flat key loop is empty")
                        #expect(flatLoop == glassLoop, "\(tag): flat key loop \(flatLoop), glass key loop \(glassLoop)")
                    }
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func everyControlAndTitleFrameOfTheGlassWindowMatchesTheFlatWindowWithinOnePointOnEveryStepAndModelState() async throws {
            for state in sgAllStates {
                try await sgPair(state) { flat, glass in
                    for entry in slStepNames {
                        await slWalk(flat, to: entry.step)
                        await slWalk(glass, to: entry.step)
                        for look in DTLook.allCases {
                            let flatFrames = sgFrames(slLayout(flat, look))
                            let glassFrames = sgFrames(slLayout(glass, look))
                            let tag = "\(state) / \(entry.label) \(look)"
                            #expect(!flatFrames.isEmpty, "\(tag): no frames in the flat window")
                            #expect(flatFrames.map(\.tag) == glassFrames.map(\.tag), "\(tag): flat \(flatFrames.map(\.tag)), glass \(glassFrames.map(\.tag))")
                            for (left, right) in zip(flatFrames, glassFrames) where left.tag == right.tag {
                                let near = abs(left.box.minX - right.box.minX) <= 1 && abs(left.box.maxX - right.box.maxX) <= 1
                                    && abs(left.box.top - right.box.top) <= 1 && abs(left.box.bottom - right.box.bottom) <= 1
                                #expect(near, "\(tag): \(left.tag) flat \(left.box) glass \(right.box)")
                            }
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func theAccessibilityElementsOfTheGlassWindowEqualTheFlatWindowsInRoleLabelTitleValueAndHelpAndTheGlassViewAddsNone() async throws {
            for state in sgAllStates {
                try await sgPair(state) { flat, glass in
                    for entry in slStepNames {
                        await slWalk(flat, to: entry.step)
                        await slWalk(glass, to: entry.step)
                        let flatRoot = slLayout(flat)
                        let glassRoot = slLayout(glass)
                        let tag = "\(state) / \(entry.label)"
                        let flatElements = sgElements(flat, flatRoot)
                        let glassElements = sgElements(glass, glassRoot)
                        #expect(!flatElements.isEmpty, "\(tag): the flat window has no accessibility elements")
                        #expect(flatElements == glassElements, "\(tag): flat \(flatElements), glass \(glassElements)")
                        for view in slGlassViews(glass.window) {
                            let adds = prViews(view).contains { $0.isAccessibilityElement() }
                            #expect(!adds, "\(tag): the glass view or one of its subviews is an accessibility element")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func theScanFlagsAGlassViewOnTheFlatPathAndAllowsTheOneGlassViewOnTheGlassPath() async throws {
            try await slWith(.whole, glass: false) { rig in
                let root = slLayout(rig)
                #expect(swlPaletteViolations(root, .light, allowError: false, glass: false).isEmpty, "the untouched flat window already reports violations")
                let planted = try #require(Glass.backdrop(enabled: true), "no glass view to plant")
                planted.frame = root.bounds
                root.addSubview(planted, positioned: .below, relativeTo: nil)
                let flatScan = swlPaletteViolations(root, .light, allowError: false, glass: false)
                #expect(flatScan.contains { $0.contains("NSGlassEffectView") }, "a glass view on the flat path was not found: \(flatScan)")
                let glassScan = swlPaletteViolations(root, .light, allowError: false, glass: true)
                #expect(!glassScan.contains { $0.contains("NSGlassEffectView") }, "the scan flags the glass view on the glass path: \(glassScan)")
                planted.removeFromSuperview()
            }
        }
    }
}
