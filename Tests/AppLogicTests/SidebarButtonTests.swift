import AppKit
import Foundation
import Testing
@testable import Sesame

@MainActor
private final class SBTap: NSObject {
    var count = 0

    @objc func hit(_ sender: Any?) {
        count += 1
    }
}

@MainActor
private func sbMake(title: String = "File types", symbol: String = "doc.on.doc") -> SidebarButton {
    let button = SidebarButton(title: title, symbol: symbol)
    button.appearance = dtAppearance(.light)
    button.frame = NSRect(x: 0, y: 0, width: 164, height: 28)
    button.layoutSubtreeIfNeeded()
    return button
}

@MainActor
private func sbHeightInColumn(_ button: SidebarButton) -> CGFloat {
    let column = NSView(frame: NSRect(x: 0, y: 0, width: 164, height: 200))
    button.translatesAutoresizingMaskIntoConstraints = false
    column.addSubview(button)
    NSLayoutConstraint.activate([
        button.topAnchor.constraint(equalTo: column.topAnchor),
        button.leadingAnchor.constraint(equalTo: column.leadingAnchor),
        button.trailingAnchor.constraint(equalTo: column.trailingAnchor),
    ])
    column.layoutSubtreeIfNeeded()
    return button.alignmentRect(forFrame: button.frame).height
}

@MainActor
private func sbRole(_ button: NSButton) -> String? {
    button.cell?.accessibilityRole()?.rawValue
}

@MainActor
private func sbSubrole(_ button: NSButton) -> String? {
    button.cell?.accessibilitySubrole()?.rawValue
}

@MainActor
private func sbValue(_ button: NSButton) -> Int? {
    let value = button.cell?.accessibilityValue()
    if let number = value as? NSNumber { return number.intValue }
    if let integer = value as? Int { return integer }
    return nil
}

private func sbOwnSelectors(_ type: AnyClass) -> Set<String> {
    var count: UInt32 = 0
    guard let list = class_copyMethodList(type, &count) else { return [] }
    defer { free(list) }
    return Set((0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) })
}

@Suite("SidebarButtonTests")
struct SidebarButtonTests {

    @MainActor
    @Test func itIsAnUnborderedTwentyEightPointNSButtonNamedAfterTheSection() {
        for name in ["Folders", "File types", "Search", "Indexing"] {
            let button = sbMake(title: name)
            #expect(button is NSButton)
            #expect(!button.isBordered)
            #expect(button.isEnabled)
            #expect(sbHeightInColumn(button) == 28, "\(name)")
            #expect(button.title == name)
            #expect(button.accessibilityLabel() == name)
        }
    }

    @MainActor
    @Test func theSymbolLeadsAndIsSixteenPoints() {
        let button = sbMake(title: "Folders", symbol: "folder")
        #expect(button.imagePosition == .imageLeading)
        #expect(button.image?.description.contains("symbol = folder") == true)
        let reference = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        let size = button.image?.size ?? .zero
        #expect(abs(size.width - (reference?.size.width ?? -100)) <= 3)
        #expect(abs(size.height - (reference?.size.height ?? -100)) <= 3)
    }

    @MainActor
    @Test func selectedDrawsARadiusEightAccentPillWithTheSelectedTextColour() {
        let button = sbMake()
        #expect(!button.isSelected)
        button.isSelected = true
        for look in DTLook.allCases {
            button.appearance = dtAppearance(look)
            button.layoutSubtreeIfNeeded()
            #expect(button.layer?.cornerRadius == 8, "\(look)")
            let fill = dtRGBA(cgColor: button.layer?.backgroundColor)
            #expect(fill != nil && dtSame(fill ?? [], dtRGBA(.controlAccentColor, look)), "pill \(look)")
            #expect(dtSame(dtRGBA(button.contentTintColor ?? .clear, look), dtRGBA(.alternateSelectedControlTextColor, look)), "text \(look)")
        }
    }

    @MainActor
    @Test func unselectedDrawsNoPill() {
        let button = sbMake()
        button.isSelected = true
        button.isSelected = false
        for look in DTLook.allCases {
            button.appearance = dtAppearance(look)
            button.layoutSubtreeIfNeeded()
            let fill = dtRGBA(cgColor: button.layer?.backgroundColor)
            #expect(fill == nil || (fill?[3] ?? 1) < 0.01, "\(look)")
        }
    }

    @MainActor
    @Test func aPushOnPushOffAppKitButtonReadsAsAToggleCheckBoxWithValueOneWhenOnAndZeroWhenOff() {
        let reference = NSButton(title: "Folders", target: nil, action: nil)
        reference.setButtonType(.pushOnPushOff)
        reference.state = .on
        #expect(sbRole(reference) == "AXCheckBox", "role \(String(describing: sbRole(reference)))")
        #expect(sbSubrole(reference) == "AXToggle", "subrole \(String(describing: sbSubrole(reference)))")
        #expect(sbValue(reference) == 1, "value \(String(describing: reference.cell?.accessibilityValue()))")
        reference.state = .off
        #expect(sbValue(reference) == 0)
    }

    @MainActor
    @Test func itIsAToggleForAccessibilityAsTheOldSetupButtonWasCheckBoxToggleWithValueOneWhenSelectedAndZeroOtherwise() {
        let button = sbMake(title: "Folders", symbol: "folder")
        #expect(!button.isSelected)
        #expect(sbRole(button) == "AXCheckBox", "role \(String(describing: sbRole(button)))")
        #expect(sbSubrole(button) == "AXToggle", "subrole \(String(describing: sbSubrole(button)))")
        #expect(sbValue(button) == 0, "value \(String(describing: button.cell?.accessibilityValue())) while not selected")
        button.isSelected = true
        #expect(sbRole(button) == "AXCheckBox", "role while selected \(String(describing: sbRole(button)))")
        #expect(sbValue(button) == 1, "value \(String(describing: button.cell?.accessibilityValue())) while selected")
        button.isSelected = false
        #expect(sbValue(button) == 0, "value \(String(describing: button.cell?.accessibilityValue())) after it is deselected")
        #expect(button.accessibilityLabel() == "Folders")
    }

    @MainActor
    @Test func itTakesFocusAndStaysInTheKeyLoopWithoutFullKeyboardAccessLikeTheSetupButton() {
        let button = sbMake(title: "Folders", symbol: "folder")
        #expect(button.acceptsFirstResponder)
        #expect(button.canBecomeKeyView)
        let own = sbOwnSelectors(SidebarButton.self)
        #expect(own.contains("acceptsFirstResponder"), "SidebarButton does not override acceptsFirstResponder, so AppKit's own rule (Full Keyboard Access) decides")
        #expect(own.contains("canBecomeKeyView"), "SidebarButton does not override canBecomeKeyView, so AppKit's own rule (Full Keyboard Access) decides")
    }

    @MainActor
    @Test func performClickSendsTheAction() {
        let button = sbMake()
        let tap = SBTap()
        button.target = tap
        button.action = #selector(SBTap.hit(_:))
        button.performClick(nil)
        #expect(tap.count == 1)
        button.performClick(nil)
        #expect(tap.count == 2)
    }
}
