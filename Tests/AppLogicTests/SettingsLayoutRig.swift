import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private final class SXSender: FoldersSender, @unchecked Sendable {
    func sendFolders() {}
}

struct SXFolder {
    let path: String
    let photos: Int
    var pdfs = 0
    var documents = 0
    var audio = 0
    var videos = 0
    var name: String { (path as NSString).lastPathComponent }
}

let sxLongName = String(repeating: "Holiday-", count: 7) + "Trip"
let sxLongParent = "Parent-folder-with-a-long-name-to-lengthen-the-path"

let sxDefaultFolders = [
    SXFolder(path: "Trips", photos: 40),
    SXFolder(path: "Notes", photos: 3),
    SXFolder(path: "Extra", photos: 2),
    SXFolder(path: sxLongParent + "/" + sxLongName, photos: 3),
]

struct SXEnv {
    let home: URL
    let folders: [SXFolder]

    var names: [String] { folders.map(\.name) }

    func path(_ name: String) -> String {
        home.appendingPathComponent(folders.first { $0.name == name }?.path ?? name).path
    }
}

@MainActor
func sxEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
func sxWith(
    _ folders: [SXFolder] = sxDefaultFolders,
    _ body: @MainActor (SettingsContainerWindow, SXEnv) async throws -> Void
) async throws {
    try await sxWithWindow(folders, make: { SettingsContainerWindow(model: $0) }, body)
}

@MainActor
func sxWithWindow(
    _ folders: [SXFolder] = sxDefaultFolders,
    make: @MainActor (SettingsModel) -> SettingsContainerWindow,
    _ body: @MainActor (SettingsContainerWindow, SXEnv) async throws -> Void
) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-settingslayout-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let home = base.resolvingSymlinksInPath()
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: base)
    }
    _ = try SesameFolder.create()
    let model = SettingsModel(sender: SXSender(), modelWhole: { true })
    for folder in folders {
        let url = home.appendingPathComponent(folder.path, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let kinds: [(prefix: String, ext: String, count: Int)] = [
            ("photo", "jpg", folder.photos), ("paper", "pdf", folder.pdfs), ("note", "txt", folder.documents),
            ("song", "mp3", folder.audio), ("clip", "mp4", folder.videos),
        ]
        for kind in kinds {
            for number in 0..<kind.count {
                try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent("\(kind.prefix)-\(number).\(kind.ext)"))
            }
        }
        model.addFolder(url)
    }
    #expect(await sxEventually { model.rows.count == folders.count && model.rows.allSatisfy { $0.state != .counting } }, "the rows never settled")
    let window = make(model)
    window.isReleasedWhenClosed = false
    window.refresh()
    try await body(window, SXEnv(home: home, folders: folders))
}

@MainActor
func sxLayout(_ window: SettingsContainerWindow, _ section: SettingsScreen.Section, _ look: DTLook = .light) -> NSView {
    window.select(section)
    return sxRelayout(window, look)
}

@MainActor
func sxRelayout(_ window: SettingsContainerWindow, _ look: DTLook = .light) -> NSView {
    window.refresh()
    let root = window.contentView!
    root.appearance = dtAppearance(look)
    for button in prViews(root).compactMap({ $0 as? SidebarButton }) { button.appearance = dtAppearance(look) }
    root.layoutSubtreeIfNeeded()
    return root
}

@MainActor
func sxFoldersSection(_ root: NSView) -> SettingsFoldersView? {
    prViews(root).compactMap { $0 as? SettingsFoldersView }.first
}

@MainActor
func sxFileTypesSection(_ root: NSView) -> SettingsFileTypesView? {
    prViews(root).compactMap { $0 as? SettingsFileTypesView }.first
}

@MainActor
func sxAncestors(_ view: NSView) -> [NSView] {
    var out: [NSView] = []
    var current = view.superview
    while let next = current {
        out.append(next)
        current = next.superview
    }
    return out
}

@MainActor
func sxCard(of view: NSView) -> GroupCard? {
    sxAncestors(view).first { $0 is GroupCard } as? GroupCard
}

@MainActor
func sxVisibleCards(_ section: NSView) -> [GroupCard] {
    prViews(section).compactMap { $0 as? GroupCard }.filter { plVisible($0) }
}

@MainActor
func sxVisibleButtons(_ section: NSView) -> [NSButton] {
    prViews(section).compactMap { $0 as? NSButton }.filter { plVisible($0) }
}

@MainActor
func sxButtons(_ section: NSView, titled title: String) -> [NSButton] {
    sxVisibleButtons(section).filter { $0.title == title }
}

@MainActor
func sxChecks(_ root: NSView, _ section: NSView, _ env: SXEnv) -> [NSButton] {
    let paths = Set(env.folders.map { env.path($0.name) })
    return sxVisibleButtons(section)
        .filter { !($0 is NSPopUpButton) && $0.title != "Cancel" && $0.title != "Remove folder" && paths.contains($0.accessibilityHelp() ?? "") }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
func sxAlignBox(_ root: NSView, _ view: NSView) -> PLBox {
    guard let parent = view.superview else { return plBox(root, view) }
    let rect = root.convert(view.alignmentRect(forFrame: view.frame), from: parent)
    let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
    return PLBox(minX: rect.minX, maxX: rect.maxX, top: top, bottom: top + rect.height)
}

func sxFont(_ font: NSFont?, size: CGFloat, weight: NSFont.Weight) -> Bool {
    guard let font else { return false }
    return abs(font.pointSize - size) < 0.01 && abs(dtWeight(font) - weight.rawValue) < 0.05
}

@MainActor
func sxColour(_ color: NSColor?, is expected: NSColor) -> Bool {
    guard let color else { return false }
    return DTLook.allCases.allSatisfy { dtSame(dtRGBA(color, $0), dtRGBA(expected, $0)) }
}

@MainActor
func sxInks(_ button: NSButton) -> [NSColor] {
    var out: [NSColor] = []
    let text = button.attributedTitle
    if text.length > 0, let color = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor { out.append(color) }
    if let tint = button.contentTintColor { out.append(tint) }
    return out
}

@MainActor
func sxIsSwitchTyped(_ button: NSButton) -> Bool {
    let reference = NSButton()
    reference.setButtonType(.switch)
    let cell = button.cell as? NSButtonCell
    let want = reference.cell as? NSButtonCell
    return cell?.showsStateBy == want?.showsStateBy && cell?.highlightsBy == want?.highlightsBy
        && cell?.isBordered == want?.isBordered && cell?.bezelStyle == want?.bezelStyle
}

@MainActor
func sxIsPlainPush(_ button: NSButton) -> Bool {
    button.isBordered && button.bezelStyle == .rounded && button.bezelColor == nil && button.keyEquivalent.isEmpty
}

@MainActor
func sxProvokeSaveError(pressing button: NSControl) async -> Bool {
    let folder = SesameFolder.url
    chmod(folder.path, 0o500)
    let probe = folder.appendingPathComponent("write-probe")
    if FileManager.default.createFile(atPath: probe.path, contents: Data()) {
        try? FileManager.default.removeItem(at: probe)
        chmod(folder.path, 0o700)
        Issue.record("this process can write into a read-only folder, so a failed write cannot be made here")
        return false
    }
    button.performClick(nil)
    await Task.yield()
    chmod(folder.path, 0o700)
    return true
}
