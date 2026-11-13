import AppKit
import Foundation
import Testing
@testable import Sesame

enum DTLook: CaseIterable {
    case light
    case dark
}

@MainActor
func dtAppearance(_ look: DTLook) -> NSAppearance {
    NSAppearance(named: look == .light ? .aqua : .darkAqua)!
}

@MainActor
func dtRGBA(_ color: @autoclosure () -> NSColor, _ look: DTLook) -> [CGFloat] {
    var out: [CGFloat] = []
    dtAppearance(look).performAsCurrentDrawingAppearance {
        out = dtRGBA(cgColor: color().cgColor) ?? []
    }
    return out
}

@MainActor
func dtRGBA(cgColor: CGColor?) -> [CGFloat]? {
    guard let cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
    return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
}

func dtSame(_ left: [CGFloat], _ right: [CGFloat], tolerance: CGFloat = 0.01) -> Bool {
    left.count == right.count && zip(left, right).allSatisfy { abs($0 - $1) <= tolerance }
}

func dtWeight(_ font: NSFont) -> CGFloat {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
    return (traits?[.weight] as? CGFloat) ?? -1
}

@Suite("DesignTokensTests")
struct DesignTokensTests {

    @Test func theEightSpacingValuesAreTheGuidesScale() {
        let actual: [CGFloat] = [Space.s1, Space.s2, Space.s3, Space.s4, Space.s5, Space.s6, Space.s7, Space.s8]
        let expected: [CGFloat] = [2, 4, 8, 12, 16, 20, 24, 32]
        #expect(actual == expected)
    }

    @Test func theThreeRadiiAreTenSevenAndSix() {
        #expect(Radius.group == 10)
        #expect(Radius.row == 7)
        #expect(Radius.chip == 6)
    }

    @MainActor
    @Test func theEightTypeTokensHaveTheGuidesSizesAndWeights() {
        let table: [(String, NSFont, CGFloat, NSFont.Weight)] = [
            ("query", Typeface.query, 22, .regular),
            ("sectionTitle", Typeface.sectionTitle, 17, .semibold),
            ("groupLabel", Typeface.groupLabel, 13, .semibold),
            ("body", Typeface.body, 13, .regular),
            ("rowName", Typeface.rowName, 13, .semibold),
            ("secondary", Typeface.secondary, 12, .regular),
            ("caption", Typeface.caption, 11, .regular),
            ("figure", Typeface.figure, 22, .semibold),
        ]
        for (name, font, size, weight) in table {
            #expect(font.pointSize == size, "\(name) size")
            #expect(abs(dtWeight(font) - weight.rawValue) < 0.05, "\(name) weight")
        }
    }

    @MainActor
    @Test func theHeroTitleTokenIsTwentyFourPointsBold() {
        #expect(Typeface.heroTitle.pointSize == 24)
        #expect(abs(dtWeight(Typeface.heroTitle) - NSFont.Weight.bold.rawValue) < 0.05)
    }

    @MainActor
    @Test func theHeroMetricsAreFiftySixSeventeenFourteenThreeSixtyEightAndEight() {
        let actual: [CGFloat] = [Hero.glyph, Hero.promiseGlyph, Hero.statusGlyph, Hero.column, Hero.dot, Hero.dotGap]
        let expected: [CGFloat] = [56, 17, 14, 360, 8, 8]
        #expect(actual == expected)
    }

    @MainActor
    @Test func theKeySymbolTokenIsTwentyRegularAndTheKeyNameTokenIsThirteenMedium() {
        #expect(Typeface.keySymbol.pointSize == 20)
        #expect(abs(dtWeight(Typeface.keySymbol) - NSFont.Weight.regular.rawValue) < 0.05)
        #expect(Typeface.keyName.pointSize == 13)
        #expect(abs(dtWeight(Typeface.keyName) - NSFont.Weight.medium.rawValue) < 0.05)
    }

    @MainActor
    @Test func theKeycapMetricsAreFortyFourHighFortyFourMinimumOneOhFourForSpaceRadiusEightEdgeOnePointFiveGapEightPaddingTwelveThenFourAndCaptionGapFour() {
        let actual: [CGFloat] = [Keycap.height, Keycap.minWidth, Keycap.spaceWidth, Keycap.radius, Keycap.lowerEdge,
                                 Keycap.gap, Keycap.padding, Keycap.tightPadding, Keycap.captionGap]
        let expected: [CGFloat] = [44, 44, 104, 8, 1.5, 8, 12, 4, 4]
        #expect(actual == expected)
    }

    @MainActor
    @Test func theCompactKeycapStyleIsTwentySixHighTwentySixMinimumFiftyTwoForSpaceGapSixRadiusSixBorderHalfEdgeOnePaddingEightThenFourMaxTwoTwentyWithThirteenRegularSymbolsAndTwelveMediumWords() {
        let compact = KeycapStyle.compact
        let actual: [CGFloat] = [compact.height, compact.minWidth, compact.spaceWidth, compact.gap, compact.radius, compact.border,
                                 compact.lowerEdge, compact.padding, compact.tightPadding, compact.maxRow]
        let expected: [CGFloat] = [26, 26, 52, 6, 6, 0.5, 1, 8, 4, 220]
        #expect(actual == expected)
        #expect(compact.symbolFont.pointSize == 13)
        #expect(abs(dtWeight(compact.symbolFont) - NSFont.Weight.regular.rawValue) < 0.05)
        #expect(compact.wordFont.pointSize == 12)
        #expect(abs(dtWeight(compact.wordFont) - NSFont.Weight.medium.rawValue) < 0.05)
    }


    @Test func theCardAndSidebarRowRadiiAreTwelveAndEightAndTheOldThreeStay() {
        #expect(Radius.card == 12)
        #expect(Radius.sidebarRow == 8)
        #expect([Radius.group, Radius.row, Radius.chip] == [10, 7, 6])
    }

    @MainActor
    @Test func theSettingsTypeTokensAreFifteenBoldTwelvePointFiveSemiboldAndElevenPointFiveRegular() {
        let table: [(String, NSFont, CGFloat, NSFont.Weight)] = [
            ("paneTitle", Typeface.paneTitle, 15, .bold),
            ("settingsName", Typeface.settingsName, 12.5, .semibold),
            ("note", Typeface.note, 11.5, .regular),
        ]
        for (name, font, size, weight) in table {
            #expect(font.pointSize == size, "\(name) size")
            #expect(abs(dtWeight(font) - weight.rawValue) < 0.05, "\(name) weight")
        }
    }

    @Test func theSettingsShellMetricsAreInsetEightSidebarOneEightyRowStartFortySixStripFortySixMarginSixteenCardPaddingFourteenCardRowPaddingTenHairlineInsetFourteenAndMoreButtonTwentyTwoAndIconBoxTwentyTwoAndIconGapTenAndSeparatorOne() {
        let actual: [CGFloat] = [SettingsShell.inset, SettingsShell.sidebarWidth, SettingsShell.rowStart, SettingsShell.stripHeight,
                                 SettingsShell.contentMargin, SettingsShell.cardPadding, SettingsShell.cardRowPadding,
                                 SettingsShell.hairlineInset, SettingsShell.moreButton, SettingsShell.iconBox, SettingsShell.iconGap, SettingsShell.separator]
        let expected: [CGFloat] = [8, 180, 46, 46, 16, 14, 10, 14, 22, 22, 10, 1]
        #expect(actual == expected)
    }

    @MainActor
    @Test func theFourSettingsColourTokensAreNeutralInBothLooksAndTheCardAndSidebarFillsAreTranslucentAndDifferBetweenLooks() {
        let table: [(String, NSColor)] = [
            ("cardFill", Design.cardFill),
            ("cardLine", Design.cardLine),
            ("sidebarFill", Design.sidebarFill),
            ("moreFill", Design.moreFill),
        ]
        for (name, color) in table {
            for look in DTLook.allCases {
                let rgba = dtRGBA(color, look)
                #expect(rgba.count == 4 && abs(rgba[0] - rgba[1]) <= 0.01 && abs(rgba[1] - rgba[2]) <= 0.01, "\(name) \(look): \(rgba) has a hue")
                #expect(rgba.count == 4 && rgba[3] > 0, "\(name) \(look): \(rgba) is clear")
            }
        }
        for (name, color) in [("cardFill", Design.cardFill), ("sidebarFill", Design.sidebarFill)] {
            #expect(!dtSame(dtRGBA(color, .light), dtRGBA(color, .dark)), "\(name) is the same in Light and Dark")
        }
        for look in DTLook.allCases {
            let alpha = dtRGBA(Design.sidebarFill, look)[3]
            #expect(alpha < 1, "sidebarFill \(look) is opaque")
        }
    }

    @MainActor
    @Test func theMenuDetailTokenIsElevenPointFiveRegular() {
        #expect(Typeface.menuDetail.pointSize == 11.5)
        #expect(abs(dtWeight(Typeface.menuDetail) - NSFont.Weight.regular.rawValue) < 0.05)
    }

    @MainActor
    @Test func theMenuHeaderMetricsAreTwoEightyWideFourteenPaddingEightTopSixBottomEightDotEightDotGapAndTwoLineGap() {
        let actual: [CGFloat] = [MenuHeader.width, MenuHeader.padding, MenuHeader.top, MenuHeader.bottom,
                                 MenuHeader.dot, MenuHeader.dotGap, MenuHeader.lineGap]
        let expected: [CGFloat] = [280, 14, 8, 6, 8, 8, 2]
        #expect(actual == expected)
    }

    @MainActor
    @Test func theStatusReadyColourIsSystemGreenInBothLooksAndACatalogColour() {
        for look in DTLook.allCases {
            #expect(dtSame(dtRGBA(Design.statusReady, look), dtRGBA(.systemGreen, look)), "\(look)")
        }
        #expect(Design.statusReady.type == .catalog)
        #expect(Design.statusReady.colorNameComponent == NSColor.systemGreen.colorNameComponent)
    }

    @MainActor
    @Test func noTypeTokenIsBelowElevenPointsOrLighterThanRegular() {
        let all = [Typeface.query, Typeface.sectionTitle, Typeface.groupLabel, Typeface.body,
                   Typeface.rowName, Typeface.secondary, Typeface.caption, Typeface.figure,
                   Typeface.heroTitle, Typeface.keySymbol, Typeface.keyName, Typeface.menuDetail,
                   Typeface.paneTitle, Typeface.settingsName, Typeface.note]
        for font in all {
            #expect(font.pointSize >= 11)
            #expect(dtWeight(font) >= NSFont.Weight.regular.rawValue - 0.01)
        }
    }

    @MainActor
    @Test func theColourHelpersResolveToTheNamedSystemColours() {
        let table: [(String, NSColor, NSColor)] = [
            ("label", Design.label, .labelColor),
            ("secondaryLabel", Design.secondaryLabel, .secondaryLabelColor),
            ("tertiaryLabel", Design.tertiaryLabel, .tertiaryLabelColor),
            ("separator", Design.separator, .separatorColor),
            ("accent", Design.accent, .controlAccentColor),
            ("selectedText", Design.selectedText, .alternateSelectedControlTextColor),
            ("windowBackground", Design.windowBackground, .windowBackgroundColor),
            ("controlBackground", Design.controlBackground, .controlBackgroundColor),
            ("error", Design.error, .systemRed),
        ]
        for (name, helper, system) in table {
            for look in DTLook.allCases {
                #expect(dtSame(dtRGBA(helper, look), dtRGBA(system, look)), "\(name) \(look)")
            }
            guard helper.type == .catalog else {
                Issue.record("\(name) is not a catalog colour")
                continue
            }
            #expect(helper.colorNameComponent == system.colorNameComponent, "\(name) catalog name")
        }
    }

    @MainActor
    @Test func theGroupFillIsLabelColourAtFivePercentAndDiffersBetweenLooks() {
        let light = dtRGBA(Design.groupFill, .light)
        let dark = dtRGBA(Design.groupFill, .dark)
        #expect(abs(light[3] - 0.05) <= 0.005)
        #expect(abs(dark[3] - 0.05) <= 0.005)
        #expect(dtSame(Array(light[0..<3]), Array(dtRGBA(.labelColor, .light)[0..<3])))
        #expect(dtSame(Array(dark[0..<3]), Array(dtRGBA(.labelColor, .dark)[0..<3])))
        #expect(zip(light[0..<3], dark[0..<3]).contains { abs($0 - $1) > 0.5 })
    }

    @MainActor
    @Test func theBannerFillIsLabelColourAtSixPercentAndDiffersBetweenLooks() {
        let light = dtRGBA(Design.bannerFill, .light)
        let dark = dtRGBA(Design.bannerFill, .dark)
        #expect(abs(light[3] - 0.06) <= 0.005)
        #expect(abs(dark[3] - 0.06) <= 0.005)
        #expect(dtSame(Array(light[0..<3]), Array(dtRGBA(.labelColor, .light)[0..<3])))
        #expect(dtSame(Array(dark[0..<3]), Array(dtRGBA(.labelColor, .dark)[0..<3])))
        #expect(zip(light[0..<3], dark[0..<3]).contains { abs($0 - $1) > 0.5 })
    }

    @MainActor
    @Test func templateInkIsOpaqueBlackInBothLooksAndItsAlphaFormKeepsTheAlpha() {
        for look in DTLook.allCases {
            #expect(dtSame(dtRGBA(Design.templateInk, look), [0, 0, 0, 1]), "\(look)")
            #expect(dtSame(dtRGBA(Design.templateInk(alpha: 0.35), look), [0, 0, 0, 0.35]), "\(look) 0.35")
            #expect(dtSame(dtRGBA(Design.templateInk(alpha: 0.5), look), [0, 0, 0, 0.5]), "\(look) 0.5")
        }
    }

    @MainActor
    @Test func selectedTextIsTheAlternateSelectedControlTextColourInBothLooks() {
        for look in DTLook.allCases {
            #expect(dtSame(dtRGBA(Design.selectedText, look), dtRGBA(.alternateSelectedControlTextColor, look)), "\(look)")
        }
    }

    @MainActor
    @Test func selectedSecondaryTextIsTheSameColourAtEightyTwoPercent() {
        for look in DTLook.allCases {
            let base = dtRGBA(.alternateSelectedControlTextColor, look)
            let actual = dtRGBA(Design.selectedSecondaryText, look)
            #expect(dtSame(Array(actual[0..<3]), Array(base[0..<3])), "\(look) colour")
            #expect(abs(actual[3] - 0.82) <= 0.005, "\(look) alpha")
        }
    }
}
