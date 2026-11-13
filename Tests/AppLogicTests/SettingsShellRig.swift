import AppKit
import Foundation
import Testing
@testable import Sesame

@MainActor
func sgsButtons(_ root: NSView) -> [SidebarButton] {
    prViews(root).compactMap { $0 as? SidebarButton }.sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
func sgsPanel(_ root: NSView) -> NSView? {
    let buttons = sgsButtons(root)
    guard buttons.count == 4 else { return nil }
    var common = sxAncestors(buttons[0])
    for button in buttons.dropFirst() {
        let above = sxAncestors(button)
        common = common.filter { view in above.contains { $0 === view } }
    }
    return common.first { abs(plBox(root, $0).width - 180) <= 0.5 }
}

@MainActor
func sgsSection(_ root: NSView, _ section: SettingsScreen.Section) -> NSView? {
    prViews(root).first { view in
        switch section.rawValue {
        case "folders": return view is SettingsFoldersView
        case "fileTypes": return view is SettingsFileTypesView
        case "search": return view is SettingsSearchView
        case "indexing": return view is SettingsIndexingView
        default: return false
        }
    }
}

@MainActor
func sgsTitles(_ root: NSView, _ name: String) -> [NSTextField] {
    prViews(root).compactMap { $0 as? NSTextField }.filter { field in
        plVisible(field) && field.stringValue == name && sxFont(field.font, size: 15, weight: .bold)
            && !sxAncestors(field).contains { $0 is NSButton }
    }
}

@MainActor
func sgsStrip(_ root: NSView, title: NSView) -> NSView? {
    sxAncestors(title).first { view in
        let box = plBox(root, view)
        return abs(box.minX - 181) <= 0.5 && abs(box.maxX - 720) <= 0.5 && abs(box.top) <= 0.5 && abs(box.height - 46) <= 0.5
    }
}

@MainActor
func sgsHairlines(_ root: NSView, panel: NSView?) -> [NSView] {
    prViews(root).filter { view in
        guard plVisible(view), view.frame.height > 0, view.frame.height <= 1 else { return false }
        if let panel, view === panel || view.isDescendant(of: panel) { return false }
        let box = plBox(root, view)
        return abs(box.minX - 181) <= 1 && abs(box.width - 539) <= 1 && abs(box.bottom - 46) <= 1
    }
}

func sgsNeutral(_ rgba: [CGFloat]) -> Bool {
    rgba.count == 4 && abs(rgba[0] - rgba[1]) <= 0.01 && abs(rgba[1] - rgba[2]) <= 0.01
}
