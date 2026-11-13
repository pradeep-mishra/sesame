import AppKit
import Foundation
@testable import Sesame

let smrMorePrefix = "More actions for "

@MainActor
func smrMoreButtons(_ root: NSView) -> [NSPopUpButton] {
    prViews(root)
        .compactMap { $0 as? NSPopUpButton }
        .filter { plVisible($0) && ($0.accessibilityLabel() ?? "").hasPrefix(smrMorePrefix) }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
func smrMoreButton(_ root: NSView, folder name: String) -> NSPopUpButton? {
    smrMoreButtons(root).first { $0.accessibilityLabel() == smrMorePrefix + name }
}

@MainActor
func smrVisibleItems(_ button: NSPopUpButton) -> [NSMenuItem] {
    (button.menu?.items ?? []).filter { !$0.isHidden }
}

@MainActor
func smrItem(_ title: String, of button: NSPopUpButton?) -> NSMenuItem? {
    button.flatMap { smrVisibleItems($0).first { $0.title == title } }
}

@MainActor
@discardableResult
func smrPerform(_ item: NSMenuItem?) async -> Bool {
    guard let item, item.isEnabled, let menu = item.menu else { return false }
    let index = menu.index(of: item)
    guard index >= 0 else { return false }
    menu.performActionForItem(at: index)
    await Task.yield()
    return true
}

@MainActor
@discardableResult
func smrChoose(_ title: String, folder name: String, in root: NSView) async -> Bool {
    await smrPerform(smrItem(title, of: smrMoreButton(root, folder: name)))
}

@MainActor
@discardableResult
func smrChooseFirst(_ title: String, in root: NSView) async -> Bool {
    await smrPerform(smrItem(title, of: smrMoreButtons(root).first))
}
