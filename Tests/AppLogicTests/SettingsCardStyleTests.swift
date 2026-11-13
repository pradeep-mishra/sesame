import AppKit
import Foundation
import Testing
@testable import Sesame

@MainActor
private final class SCRow: NSView {
    private let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
}

@MainActor
private func scMake(style: CardStyle?, rows: Int = 3, contentHeight: CGFloat = 20) -> (card: GroupCard, contents: [NSView], height: CGFloat) {
    let contents: [NSView] = (0..<rows).map { _ in SCRow(height: contentHeight) }
    let card = style.map { GroupCard(rows: contents, style: $0) } ?? GroupCard(rows: contents)
    card.appearance = dtAppearance(.light)
    card.frame = NSRect(x: 0, y: 0, width: 400, height: 10)
    card.layoutSubtreeIfNeeded()
    let height = card.fittingSize.height
    card.frame = NSRect(x: 0, y: 0, width: 400, height: height)
    card.layoutSubtreeIfNeeded()
    return (card, contents, height)
}

@MainActor
private func scRect(_ card: NSView, _ view: NSView) -> NSRect {
    card.convert(view.bounds, from: view)
}

@MainActor
private func scTop(_ card: NSView, _ rect: NSRect) -> CGFloat {
    card.isFlipped ? rect.minY : card.bounds.height - rect.maxY
}

@MainActor
private func scSeparators(_ card: NSView) -> [NSView] {
    prViews(card).filter { $0 !== card && $0.frame.height > 0 && $0.frame.height <= 1 }
}

@MainActor
private func scBrightnessOverWindow(_ rgba: [CGFloat], _ look: DTLook) -> (card: CGFloat, window: CGFloat) {
    let window = dtRGBA(.windowBackgroundColor, look)
    let alpha = rgba[3]
    let over = (0..<3).map { rgba[$0] * alpha + window[$0] * (1 - alpha) }
    return (over.max() ?? 0, window[0..<3].max() ?? 0)
}

@Suite("SettingsCardStyleTests")
struct SettingsCardStyleTests {

    @MainActor
    @Test func theSettingsCardHasRadiusTwelveAndAHalfPointSeparatorBorderInBothLooksAndRepaintsWithNoRebuild() {
        let (card, _, _) = scMake(style: .settings)
        #expect(card.layer?.cornerRadius == 12, "radius \(String(describing: card.layer?.cornerRadius))")
        #expect(!(card is NSBox))
        #expect(!prViews(card).contains { $0 is NSBox || $0 is NSScrollView || $0 is NSVisualEffectView || slIsGlass($0) })
        for look in [DTLook.light, .dark, .light, .dark] {
            card.appearance = dtAppearance(look)
            card.layoutSubtreeIfNeeded()
            #expect(abs((card.layer?.borderWidth ?? 0) - 0.5) <= 0.01, "\(look): border width \(String(describing: card.layer?.borderWidth))")
            let border = dtRGBA(cgColor: card.layer?.borderColor)
            #expect(border != nil && dtSame(border ?? [], dtRGBA(.separatorColor, look)), "\(look): border \(String(describing: border)), wanted \(dtRGBA(.separatorColor, look))")
        }
    }

    @MainActor
    @Test func theSettingsCardFillIsLighterThanTheWindowByTheLiftTheWindowAllowsAndAtLeastNinetyFiveHundredthsBrightInLight() {
        let (card, _, _) = scMake(style: .settings)
        var seen: [[CGFloat]] = []
        for look in [DTLook.light, .dark, .light, .dark] {
            card.appearance = dtAppearance(look)
            card.layoutSubtreeIfNeeded()
            let fill = dtRGBA(cgColor: card.layer?.backgroundColor)
            #expect(fill != nil, "\(look): the card has no fill")
            guard let fill else { continue }
            seen.append(fill)
            #expect(sgsNeutral(fill), "\(look): the fill \(fill) has a hue")
            let measured = scBrightnessOverWindow(fill, look)
            let lift = min(0.02, 1 - measured.window)
            #expect(measured.card - measured.window >= lift - 0.0005, "\(look): card brightness \(measured.card), window \(measured.window), lift \(measured.card - measured.window), wanted at least \(lift)")
            if look == .light {
                #expect(measured.card >= 0.95, "Light: card brightness \(measured.card) is below 0.95")
            }
            if look == .dark {
                #expect(measured.card - measured.window >= 0.02 - 0.0005, "Dark: lift \(measured.card - measured.window) is below 0.02")
            }
        }
        #expect(seen.count == 4, "\(seen.count) fills read")
        if seen.count == 4 {
            #expect(!dtSame(seen[0], seen[1]), "the fill is the same in Light and Dark: \(seen[0])")
            #expect(dtSame(seen[0], seen[2]) && dtSame(seen[1], seen[3]), "a layer stayed on one look: \(seen)")
        }
    }

    @MainActor
    @Test func aCardOf400PointsPadsEachRowFourteenAcrossAndTenDown() {
        let (card, contents, height) = scMake(style: .settings)
        let rects = contents.map { scRect(card, $0) }
        for rect in rects {
            #expect(abs(rect.minX - 14) <= 0.5, "row left edge \(rect.minX)")
            #expect(abs((400 - rect.maxX) - 14) <= 0.5, "row right inset \(400 - rect.maxX)")
            #expect(abs(rect.height - 20) <= 0.5, "row height \(rect.height)")
        }
        let tops = rects.map { scTop(card, $0) }
        #expect(abs(tops[0] - 10) <= 0.5, "first row top \(tops[0])")
        #expect(abs((height - (tops[2] + 20)) - 10) <= 0.5, "last row bottom gap \(height - (tops[2] + 20))")
        for index in 0..<2 {
            let gap = tops[index + 1] - (tops[index] + 20)
            #expect(gap >= 20 - 0.5 && gap <= 21.5, "gap \(gap)")
        }
    }

    @MainActor
    @Test func everySettingsRowCellIsAtLeastFortyPointsTall() {
        let (card, contents, _) = scMake(style: .settings)
        let tops = contents.map { scTop(card, scRect(card, $0)) }
        for index in 0..<2 {
            #expect(tops[index + 1] - tops[index] >= 40, "rows \(index) and \(index + 1) are \(tops[index + 1] - tops[index]) apart")
        }
        let (shortCard, _, shortHeight) = scMake(style: .settings, rows: 1, contentHeight: 10)
        #expect(shortHeight >= 40 && shortHeight <= 41, "one short row: \(shortHeight)")
        #expect(shortCard.fittingSize.height >= 40)
    }

    @MainActor
    @Test func threeSettingsRowsHaveTwoOnePointHairlinesFourteenInFromTheLeftReachingTheRightEdgeInSeparatorColourAndNoneAboveOrBelow() {
        let (card, contents, height) = scMake(style: .settings)
        let separators = scSeparators(card)
        #expect(separators.count == 2, "\(separators.count) hairlines for three rows")
        let rects = contents.map { scRect(card, $0) }
        let tops = rects.map { scTop(card, $0) }
        let ordered = separators.sorted { scTop(card, scRect(card, $0)) < scTop(card, scRect(card, $1)) }
        for (index, separator) in ordered.enumerated() where index < 2 {
            let rect = scRect(card, separator)
            #expect([0.5, 1.0].contains(rect.height), "hairline height \(rect.height)")
            #expect(abs(rect.minX - 14) <= 0.5, "hairline starts at \(rect.minX)")
            #expect(abs(rect.maxX - 400) <= 0.5, "hairline ends at \(rect.maxX)")
            let top = scTop(card, rect)
            #expect(top >= tops[index] + 20 - 0.5, "hairline \(index) starts above its row's bottom: \(top)")
            #expect(top + rect.height <= tops[index + 1] + 0.5, "hairline \(index) reaches the next row")
        }
        #expect(ordered.allSatisfy { scTop(card, scRect(card, $0)) > tops[0] + 20 - 0.5 }, "a hairline above the first row's bottom")
        #expect(ordered.allSatisfy { scTop(card, scRect(card, $0)) + $0.frame.height < height - 10 + 0.5 }, "a hairline below the last row")
        for look in [DTLook.light, .dark, .light, .dark] {
            card.appearance = dtAppearance(look)
            card.layoutSubtreeIfNeeded()
            let expected = dtRGBA(.separatorColor, look)
            for separator in separators {
                let actual = dtRGBA(cgColor: separator.layer?.backgroundColor)
                #expect(actual != nil && dtSame(actual ?? [], expected), "hairline \(look): \(String(describing: actual)), wanted \(expected)")
            }
        }
    }

    @MainActor
    @Test func oneRowHasNoHairlineAndTheSetupStyleIsTodaysCardOfRadiusTenFillLabelAtFivePercentNoBorderAndPaddingSixteenAndTwelve() {
        let (one, _, _) = scMake(style: .settings, rows: 1)
        #expect(scSeparators(one).isEmpty, "a hairline in a one-row settings card")
        let (card, contents, height) = scMake(style: .setup)
        #expect(card.layer?.cornerRadius == 10)
        #expect(card.layer?.borderWidth == 0)
        let label = dtRGBA(.labelColor, .light)
        let fill = dtRGBA(cgColor: card.layer?.backgroundColor)
        #expect(fill != nil && dtSame(fill ?? [], [label[0], label[1], label[2], 0.05]), "setup fill \(String(describing: fill))")
        let rects = contents.map { scRect(card, $0) }
        for rect in rects {
            #expect(abs(rect.minX - 16) <= 0.5 && abs((400 - rect.maxX) - 16) <= 0.5, "setup padding \(rect.minX), \(400 - rect.maxX)")
        }
        #expect(abs(scTop(card, rects[0]) - 12) <= 0.5)
        #expect(abs((height - (scTop(card, rects[2]) + 20)) - 12) <= 0.5)
        #expect(scSeparators(card).count == 2)
        let (plain, plainContents, plainHeight) = scMake(style: nil)
        #expect(plain.layer?.cornerRadius == 10 && plain.layer?.borderWidth == 0, "the default style is not the setup card")
        #expect(abs(plainHeight - height) <= 0.5, "the default card is \(plainHeight) tall, the setup card \(height)")
        #expect(abs(scRect(plain, plainContents[0]).minX - 16) <= 0.5)
    }
}
