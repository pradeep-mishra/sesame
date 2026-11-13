import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

let syNextStep = "Try again in a moment."

struct SYRefused: Error {}

final class SYLookup: AppLookup, @unchecked Sendable {
    private let installed: Set<String>
    init(installed: Set<String>) { self.installed = installed }
    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
}

final class SYLoginService: LoginService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginStatus = .enabled
    private var refuses = false

    var status: LoginStatus {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func refuse(_ on: Bool) {
        lock.lock()
        refuses = on
        lock.unlock()
    }

    func register() throws {
        lock.lock()
        defer { lock.unlock() }
        if refuses { throw SYRefused() }
        current = .enabled
    }

    func unregister() throws {
        lock.lock()
        defer { lock.unlock() }
        if refuses { throw SYRefused() }
        current = .notRegistered
    }
}

@MainActor
final class SYServices {
    let login = SYLoginService()
    private(set) var shortcut: ShortcutControl?
    private let installed: Set<String>
    private let adoptNotice: Bool
    private let deleteFails: Bool

    init(installed: Set<String> = [], adoptNotice: Bool = false, deleteFails: Bool = false) {
        self.installed = installed
        self.adoptNotice = adoptNotice
        self.deleteFails = deleteFails
    }

    func window(_ model: SettingsModel) -> SettingsContainerWindow {
        let shortcut = ShortcutControl()
        if adoptNotice { shortcut.adoptLive("ctrl+opt+space", refused: "cmd+space") }
        self.shortcut = shortcut
        let fails = deleteFails
        return SettingsContainerWindow(
            model: model, shortcut: shortcut, loginItem: LoginItem(service: login),
            appChoices: AppChoices(lookup: SYLookup(installed: installed)),
            deleteIndex: DeleteIndex(closeIndex: {}, sendReset: {}, deleteCaches: { if fails { throw SYRefused() } }))
    }
}

@MainActor
func sySearchSection(_ root: NSView) -> SettingsSearchView? {
    prViews(root).compactMap { $0 as? SettingsSearchView }.first
}

@MainActor
func syIndexingSection(_ root: NSView) -> SettingsIndexingView? {
    prViews(root).compactMap { $0 as? SettingsIndexingView }.first
}

@MainActor
func syPopUps(_ section: NSView) -> [NSPopUpButton] {
    prViews(section).compactMap { $0 as? NSPopUpButton }.filter { plVisible($0) }
}

@MainActor
func syPopUp(_ section: NSView, labelled label: String) -> NSPopUpButton? {
    syPopUps(section).first { $0.accessibilityLabel() == label }
}

@MainActor
func syChoose(_ title: String, in popup: NSPopUpButton) async -> Bool {
    guard popup.isEnabled, popup.itemTitles.contains(title) else { return false }
    popup.selectItem(withTitle: title)
    _ = popup.sendAction(popup.action, to: popup.target)
    await Task.yield()
    return true
}

@MainActor
func syProvokePickError(_ title: String, in popup: NSPopUpButton) async -> Bool {
    let folder = SesameFolder.url
    chmod(folder.path, 0o500)
    let probe = folder.appendingPathComponent("write-probe")
    if FileManager.default.createFile(atPath: probe.path, contents: Data()) {
        try? FileManager.default.removeItem(at: probe)
        chmod(folder.path, 0o700)
        Issue.record("this process can write into a read-only folder, so a failed write cannot be made here")
        return false
    }
    let chosen = await syChoose(title, in: popup)
    chmod(folder.path, 0o700)
    return chosen
}

@MainActor
func syExpectPlainSection(_ root: NSView, _ section: NSView, name: String, _ look: DTLook) {
    #expect(plTexts(section).filter { $0.stringValue == name }.isEmpty, "\(look): the section draws its own \"\(name)\" heading")
    let titled = plTexts(section).filter { $0.font?.pointSize == 17 }
    #expect(titled.isEmpty, "\(look): the section draws a 17 pt text")
    #expect(!prViews(section).contains { $0 is NSScrollView }, "\(look): a scroll view inside the \(name) section")
    #expect(!prViews(section).contains { $0 is NSBox }, "\(look): an NSBox inside the \(name) section")
    for scroll in sxAncestors(section).compactMap({ $0 as? NSScrollView }) {
        #expect(scroll.borderType == .noBorder, "\(look): a scroll view around the \(name) section has a bezel border")
    }
    let images = prViews(section).compactMap { $0 as? NSImageView }.filter { plVisible($0) }
    #expect(images.allSatisfy { !$0.isEnabled }, "\(look): an enabled NSImageView in the \(name) section")
}

@MainActor
func syExpectHugs(_ root: NSView, _ card: GroupCard, _ look: DTLook) {
    let parts: [NSView] = prViews(card).filter { view in
        guard plVisible(view), view !== card else { return false }
        if let field = view as? NSTextField { return !field.stringValue.isEmpty && !(field.superview is NSButton) }
        return view is NSButton
    }
    guard let first = parts.first else {
        Issue.record("\(look): a card holds no text or button")
        return
    }
    let content = parts.dropFirst().reduce(sxAlignBox(root, first)) { $0.union(sxAlignBox(root, $1)) }
    let cardBox = plBox(root, card)
    #expect(content.top - cardBox.top >= 0 && content.top - cardBox.top <= 20, "\(look): the content starts \(content.top - cardBox.top) pt below the card top")
    #expect(cardBox.bottom - content.bottom >= 0 && cardBox.bottom - content.bottom <= 20, "\(look): the card ends \(cardBox.bottom - content.bottom) pt below its content")
}

@MainActor
func syExpectNoWarning(_ section: NSView, _ look: DTLook) {
    #expect(plAccessibilityImages(section).filter { plVisible($0) }.isEmpty, "\(look): a warning symbol with nothing wrong")
    #expect(plText(section, syNextStep) == nil, "\(look): the next-step line with nothing wrong")
}

@MainActor
func syExpectWarningLine(_ root: NSView, _ section: NSView, text: String, red: Bool, _ look: DTLook) {
    let lines = plTexts(section).filter { $0.stringValue == text }
    #expect(lines.count == 1, "\(look): \(lines.count) visible texts equal \"\(text)\": \(plTexts(section).map(\.stringValue))")
    guard let line = lines.first else { return }
    if red {
        #expect(sxColour(line.textColor, is: .systemRed), "\(look): \"\(text)\" is not red")
    }
    let sectionBox = plBox(root, section)
    let lineBox = sxAlignBox(root, line)
    #expect(lineBox.minX >= sectionBox.minX - 0.5 && lineBox.maxX <= sectionBox.maxX + 0.5, "\(look): \"\(text)\" leaves the section")

    let symbols = plAccessibilityImages(section).filter { plVisible($0) }
    #expect(symbols.count == 1, "\(look): \(symbols.count) accessibility images beside \"\(text)\"")
    if let symbol = symbols.first {
        #expect(symbol.accessibilityLabel() == "Warning", "\(look): symbol label \"\(symbol.accessibilityLabel() ?? "nil")\"")
        #expect(symbol.accessibilityRole() == .image)
        #expect(symbol is NSImageView, "\(look): the symbol is a \(type(of: symbol))")
        #expect((symbol as? NSImageView)?.isEnabled == false, "\(look): the warning symbol is an enabled control")
        let symbolBox = plBox(root, symbol)
        #expect(symbolBox.maxX <= lineBox.minX + 0.5, "\(look): the symbol ends at \(symbolBox.maxX), the text starts at \(lineBox.minX)")
        #expect(symbolBox.top < lineBox.bottom && lineBox.top < symbolBox.bottom, "\(look): the symbol and \"\(text)\" share no line")
        #expect(symbolBox.minX >= sectionBox.minX - 0.5, "\(look): the symbol leaves the section")
    }
    let images = prViews(section).compactMap { $0 as? NSImageView }.filter { plVisible($0) }
    #expect(images.allSatisfy { !$0.isEnabled }, "\(look): an enabled NSImageView in the section")

    let nexts = plTexts(section).filter { $0.stringValue == syNextStep }
    #expect(nexts.count == 1, "\(look): \(nexts.count) next-step lines beside \"\(text)\"")
    if let next = nexts.first {
        let nextBox = sxAlignBox(root, next)
        #expect(sxColour(next.textColor, is: .secondaryLabelColor), "\(look): next-step colour")
        #expect(sxFont(next.font, size: 12, weight: .regular), "\(look): next-step font \(String(describing: next.font))")
        #expect(nextBox.top >= lineBox.bottom - 0.5 && nextBox.top - lineBox.bottom <= 12, "\(look): the next-step line starts \(nextBox.top - lineBox.bottom) pt below \"\(text)\"")
        #expect(nextBox.minX >= lineBox.minX - 0.5, "\(look): the next-step line starts left of \"\(text)\"")
        #expect(nextBox.maxX <= sectionBox.maxX + 0.5, "\(look): the next-step line leaves the section")
    }
}
