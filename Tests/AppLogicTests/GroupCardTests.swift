import AppKit
import Foundation
import Testing
@testable import Sesame

@MainActor
private final class GCRow: NSView {
    private let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
}

@MainActor
private func gcMake(rows: Int = 3, contentHeight: CGFloat = 20) -> (card: GroupCard, contents: [NSView], height: CGFloat) {
    let contents: [NSView] = (0..<rows).map { _ in GCRow(height: contentHeight) }
    let card = GroupCard(rows: contents)
    card.appearance = dtAppearance(.light)
    card.frame = NSRect(x: 0, y: 0, width: 400, height: 10)
    card.layoutSubtreeIfNeeded()
    let height = card.fittingSize.height
    card.frame = NSRect(x: 0, y: 0, width: 400, height: height)
    card.layoutSubtreeIfNeeded()
    return (card, contents, height)
}

@MainActor
private func gcRect(_ card: NSView, _ view: NSView) -> NSRect {
    card.convert(view.bounds, from: view)
}

@MainActor
private func gcTop(_ card: NSView, _ rect: NSRect) -> CGFloat {
    card.isFlipped ? rect.minY : card.bounds.height - rect.maxY
}

@MainActor
private func gcSeparators(_ card: NSView) -> [NSView] {
    prViews(card).filter { $0 !== card && $0.frame.height > 0 && $0.frame.height <= 1 }
}

@Suite("GroupCardTests")
struct GroupCardTests {

    @MainActor
    @Test func aCardOf400PointsPadsEachRowSixteenAcrossAndTwelveDown() {
        let (card, contents, height) = gcMake()
        let rects = contents.map { gcRect(card, $0) }
        for rect in rects {
            #expect(abs(rect.minX - 16) <= 0.5)
            #expect(abs((400 - rect.maxX) - 16) <= 0.5)
            #expect(abs(rect.height - 20) <= 0.5)
        }
        let tops = rects.map { gcTop(card, $0) }
        #expect(abs(tops[0] - 12) <= 0.5)
        #expect(abs((height - (tops[2] + 20)) - 12) <= 0.5)
        for index in 0..<2 {
            let gap = tops[index + 1] - (tops[index] + 20)
            #expect(gap >= 24 - 0.5 && gap <= 25.5)
        }
    }

    @MainActor
    @Test func everyRowCellIsAtLeastFortyPointsTall() {
        let (card, contents, _) = gcMake()
        let tops = contents.map { gcTop(card, gcRect(card, $0)) }
        for index in 0..<2 {
            #expect(tops[index + 1] - tops[index] >= 40)
        }
        let (shortCard, _, shortHeight) = gcMake(rows: 1, contentHeight: 10)
        #expect(shortHeight >= 40 && shortHeight <= 41)
        #expect(shortCard.fittingSize.height >= 40)
    }

    @MainActor
    @Test func threeRowsHaveTwoHairlineSeparatorsBetweenThemInSeparatorColour() {
        let (card, contents, _) = gcMake()
        let separators = gcSeparators(card)
        #expect(separators.count == 2)
        let rects = contents.map { gcRect(card, $0) }
        let tops = rects.map { gcTop(card, $0) }
        let ordered = separators.sorted { gcTop(card, gcRect(card, $0)) < gcTop(card, gcRect(card, $1)) }
        for (index, separator) in ordered.enumerated() where index < 2 {
            let rect = gcRect(card, separator)
            #expect([0.5, 1.0].contains(rect.height), "hairline height \(rect.height)")
            #expect(rect.width >= 368 - 0.5)
            let top = gcTop(card, rect)
            #expect(top >= tops[index] + 20 - 0.5)
            #expect(top + rect.height <= tops[index + 1] + 0.5)
        }
        for look in DTLook.allCases {
            card.appearance = dtAppearance(look)
            card.layoutSubtreeIfNeeded()
            let expected = dtRGBA(.separatorColor, look)
            for separator in separators {
                let actual = dtRGBA(cgColor: separator.layer?.backgroundColor)
                #expect(actual != nil && dtSame(actual ?? [], expected), "separator \(look)")
            }
        }
    }

    @MainActor
    @Test func theCardHasRadiusTenGroupFillAndNoBezelBorderOrNestedScrollView() {
        let (card, _, _) = gcMake()
        #expect(card.layer?.cornerRadius == 10)
        #expect(card.layer?.borderWidth == 0)
        #expect(!(card is NSBox))
        #expect(!prViews(card).contains { $0 is NSBox })
        #expect(!prViews(card).contains { $0 is NSScrollView })
        for look in DTLook.allCases {
            card.appearance = dtAppearance(look)
            card.layoutSubtreeIfNeeded()
            let label = dtRGBA(.labelColor, look)
            let expected = [label[0], label[1], label[2], 0.05]
            let actual = dtRGBA(cgColor: card.layer?.backgroundColor)
            #expect(actual != nil && dtSame(actual ?? [], expected), "fill \(look)")
        }
    }
}
