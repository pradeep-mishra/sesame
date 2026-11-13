import AppKit
import Foundation
import Testing
@testable import Sesame

private let svTitle = "Nothing to show yet"
private let svBody = "Sesame is still reading your files. Search works as soon as the first photos and documents are ready, and the rest keep arriving while you type."
private let svCaption = "Press esc to close"

@MainActor
private func svLaidOut(_ view: StateView) -> StateView {
    view.appearance = dtAppearance(.light)
    view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
    view.layoutSubtreeIfNeeded()
    return view
}

@MainActor
private func svPlain(symbol: String = "magnifyingglass") -> StateView {
    svLaidOut(StateView(symbol: symbol, title: svTitle, body: svBody, caption: svCaption))
}

@MainActor
private func svError() -> StateView {
    svLaidOut(StateView.error(title: svTitle, body: svBody, caption: svCaption))
}

@MainActor
private func svField(_ view: NSView, _ text: String) -> NSTextField? {
    prViews(view).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
}

@MainActor
private func svSymbol(_ view: NSView) -> NSImageView? {
    let images = prViews(view).compactMap { $0 as? NSImageView }
    return images.count == 1 ? images[0] : nil
}

@MainActor
private func svRect(_ view: NSView, _ child: NSView) -> NSRect {
    guard let parent = child.superview else { return .zero }
    return view.convert(child.alignmentRect(forFrame: child.frame), from: parent)
}

@MainActor
private func svTop(_ view: NSView, _ rect: NSRect) -> CGFloat {
    view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
}

@Suite("StateViewTests")
struct StateViewTests {

    @MainActor
    @Test func theBodyWrapsAtThreeHundredTwentyPointsOrLess() throws {
        let view = svPlain()
        let body = try #require(svField(view, svBody))
        let rect = svRect(view, body)
        #expect(rect.width <= 320.5)
        #expect(rect.height >= 30)
        #expect(body.alignment == .center)
        let title = try #require(svField(view, svTitle))
        #expect(title.alignment == .center)
    }

    @MainActor
    @Test func theBlockIsCentredAcrossAndSitsBetweenThirtyAndFortyFivePercentDown() throws {
        let view = svPlain()
        let symbol = try #require(svSymbol(view))
        let rects = [symbol, try #require(svField(view, svTitle)), try #require(svField(view, svBody)),
                     try #require(svField(view, svCaption))].map { svRect(view, $0) }
        let block = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        #expect(abs(block.midX - 240) <= 8)
        let ratio = svTop(view, block) / 400
        #expect(ratio >= 0.30 && ratio <= 0.45, "top edge at \(ratio)")
    }

    @MainActor
    @Test func gapsAreEightFourAndEightPointsInOrder() throws {
        let view = svPlain()
        let symbol = svRect(view, try #require(svSymbol(view)))
        let title = svRect(view, try #require(svField(view, svTitle)))
        let body = svRect(view, try #require(svField(view, svBody)))
        let caption = svRect(view, try #require(svField(view, svCaption)))
        let tops = [symbol, title, body, caption].map { svTop(view, $0) }
        #expect(tops[0] < tops[1] && tops[1] < tops[2] && tops[2] < tops[3])
        #expect(abs((tops[1] - (tops[0] + symbol.height)) - 8) <= 1)
        #expect(abs((tops[2] - (tops[1] + title.height)) - 4) <= 1)
        #expect(abs((tops[3] - (tops[2] + body.height)) - 8) <= 1)
    }

    @MainActor
    @Test func theTextUsesTheGuidesTypeAndColoursAndThereIsNoProgressIndicator() throws {
        let view = svPlain()
        let title = try #require(svField(view, svTitle))
        let body = try #require(svField(view, svBody))
        let caption = try #require(svField(view, svCaption))
        #expect(title.font?.pointSize == 17)
        #expect(abs(dtWeight(title.font ?? .systemFont(ofSize: 17)) - NSFont.Weight.semibold.rawValue) < 0.05)
        #expect(body.font?.pointSize == 13)
        #expect(abs(dtWeight(body.font ?? .systemFont(ofSize: 13)) - NSFont.Weight.regular.rawValue) < 0.05)
        #expect(caption.font?.pointSize == 11)
        for look in DTLook.allCases {
            #expect(dtSame(dtRGBA(title.textColor ?? .clear, look), dtRGBA(.labelColor, look)), "title \(look)")
            #expect(dtSame(dtRGBA(body.textColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "body \(look)")
            #expect(dtSame(dtRGBA(caption.textColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "caption \(look)")
        }
        #expect(!prViews(view).contains { $0 is NSProgressIndicator })
    }

    @MainActor
    @Test func aDecorativeSymbolIsTintedSecondaryAndIsNotAnAccessibilityElement() throws {
        for name in ["magnifyingglass", "tray", "photo"] {
            let view = svPlain(symbol: name)
            let symbol = try #require(svSymbol(view))
            #expect(symbol.image?.description.contains("symbol = \(name)") == true, "\(name)")
            #expect(!symbol.isAccessibilityElement(), "\(name)")
            for look in DTLook.allCases {
                #expect(dtSame(dtRGBA(symbol.contentTintColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "\(name) \(look)")
            }
        }
    }

    @MainActor
    @Test func theErrorVariantUsesTheRedWarningTriangleAsTheOnlyAccessibilityImage() throws {
        let view = svError()
        let symbol = try #require(svSymbol(view))
        #expect(symbol is WarningSymbolView)
        #expect(symbol.image?.description.contains("symbol = exclamationmark.triangle") == true)
        #expect(symbol.isAccessibilityElement())
        #expect(symbol.accessibilityRole() == .image)
        #expect(symbol.accessibilityLabel() == "Warning")
        for look in DTLook.allCases {
            #expect(dtSame(dtRGBA(symbol.contentTintColor ?? .clear, look), dtRGBA(.systemRed, look)), "\(look)")
        }
        #expect(svField(view, svTitle) != nil)
        #expect(svField(view, svBody) != nil)
        #expect(svField(view, svCaption) != nil)
        #expect(!prViews(view).contains { $0 is NSProgressIndicator })
    }

    @MainActor
    @Test func theWarningViewOnItsOwnIsTheSameOneAccessibilityImage() {
        let warning = WarningSymbolView(pointSize: 16)
        #expect(warning.image?.description.contains("symbol = exclamationmark.triangle") == true)
        #expect(warning.isAccessibilityElement())
        #expect(warning.accessibilityRole() == .image)
        #expect(warning.accessibilityLabel() == "Warning")
        for look in DTLook.allCases {
            #expect(dtSame(dtRGBA(warning.contentTintColor ?? .clear, look), dtRGBA(.systemRed, look)), "\(look)")
        }
    }

    @MainActor
    @Test func theErrorVariantIsPlacedLikeTheOthers() throws {
        let view = svError()
        let symbol = svRect(view, try #require(svSymbol(view)))
        let body = svRect(view, try #require(svField(view, svBody)))
        #expect(body.width <= 320.5)
        #expect(abs(symbol.midX - 240) <= 8)
        let ratio = svTop(view, symbol) / 400
        #expect(ratio >= 0.30 && ratio <= 0.45, "top edge at \(ratio)")
    }
}
