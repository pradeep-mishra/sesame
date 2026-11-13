import AppKit
import Foundation
import Testing
@testable import Sesame

enum GlassSeamHost {
    static var major: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    static var glassOS: Bool { major >= 26 }
    static var olderOS: Bool { major < 26 }
}

@MainActor
func glassSeamButton() -> NSButton {
    let button = NSButton(title: "Seam", target: nil, action: nil)
    button.bezelStyle = .regularSquare
    return button
}

@Suite("GlassSeamTests")
struct GlassSeamTests {

    @Test func glassIsAvailableExactlyWhenTheOperatingSystemMajorVersionIsTwentySixOrMore() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #expect(Glass.isAvailable == (major >= 26))
    }

    @MainActor
    @Test func aDisabledBackdropIsNilOnEveryOperatingSystem() {
        #expect(Glass.backdrop(enabled: false) == nil)
    }

    @MainActor
    @Test(.enabled(if: GlassSeamHost.olderOS))
    func anEnabledBackdropIsNilWhenTheOperatingSystemIsOlderThanTwentySix() {
        #expect(Glass.backdrop(enabled: true) == nil)
    }

    @MainActor
    @Test(.enabled(if: GlassSeamHost.glassOS))
    func anEnabledBackdropIsARegularNSGlassEffectViewWithNoContentViewAndNoAccessibility() throws {
        let view = try #require(Glass.backdrop(enabled: true))
        #expect(NSStringFromClass(type(of: view)) == "NSGlassEffectView")
        #expect((view.value(forKey: "style") as? NSNumber)?.intValue == 0)
        #expect(view.value(forKey: "contentView") == nil)
        #expect(view.isAccessibilityElement() == false)
    }

    @MainActor
    @Test(.enabled(if: GlassSeamHost.glassOS))
    func eachEnabledBackdropCallBuildsItsOwnView() throws {
        let first = try #require(Glass.backdrop(enabled: true))
        let second = try #require(Glass.backdrop(enabled: true))
        #expect(first !== second)
    }

    @MainActor
    @Test func theFlatStyleOfAPlainButtonIsRoundedWithNoBezelColour() {
        let button = glassSeamButton()
        Glass.style(button, accent: false, glass: false)
        #expect(button.bezelStyle == .rounded)
        #expect(button.bezelColor == nil)
    }

    @MainActor
    @Test func theFlatStyleOfAnAccentButtonIsStillRoundedWithNoBezelColour() {
        let button = glassSeamButton()
        Glass.style(button, accent: true, glass: false)
        #expect(button.bezelStyle == .rounded)
        #expect(button.bezelColor == nil)
    }

    @MainActor
    @Test(.enabled(if: GlassSeamHost.glassOS))
    func theGlassStyleOfAPlainButtonIsBezelSixteenWithNoBezelColour() {
        let button = glassSeamButton()
        Glass.style(button, accent: false, glass: true)
        #expect(button.bezelStyle.rawValue == 16)
        #expect(button.bezelColor == nil)
    }

    @MainActor
    @Test(.enabled(if: GlassSeamHost.glassOS))
    func theGlassStyleOfAnAccentButtonIsBezelSixteenTintedWithTheAccentInBothLooks() throws {
        let button = glassSeamButton()
        Glass.style(button, accent: true, glass: true)
        #expect(button.bezelStyle.rawValue == 16)
        let tint = try #require(button.bezelColor)
        for look in DTLook.allCases {
            #expect(dtSame(dtRGBA(tint, look), dtRGBA(.controlAccentColor, look)), "\(look)")
        }
    }
}
