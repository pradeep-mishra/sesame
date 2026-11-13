import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let cfText = "Your settings file could not be read, so it was set aside and defaults are in use."
private let cfSaveError = "Could not save your settings."
private let cfPrefix = "settings.json.corrupt-"
private let cfNoFolders = "No folders. Add a folder to read it."
private let cfAddFolder = "Add folder\u{2026}"
private let cfDismiss = "Dismiss"
private let cfCut = Data("{ \"version\": ".utf8)
private let cfOther = Data("not json".utf8)

struct CFBad: Sendable, CustomTestStringConvertible {
    let name: String
    let bytes: Data
    var testDescription: String { name }
}

private let cfBad: [CFBad] = [
    CFBad(name: "cut off", bytes: cfCut),
    CFBad(name: "empty", bytes: Data()),
    CFBad(name: "not json", bytes: cfOther),
    CFBad(name: "wrong shape", bytes: Data("[]".utf8)),
    CFBad(name: "missing keys", bytes: Data("{\"version\": 1}".utf8)),
    CFBad(name: "one byte", bytes: Data("x".utf8)),
]

private struct CFEnv {
    let home: URL

    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

    func plant(_ data: Data) throws { try data.write(to: settings) }

    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func settingsFiles() -> [String] { names().filter { $0.hasPrefix("settings") } }
    func setAsides() -> [String] { names().filter { $0.hasPrefix(cfPrefix) } }
    func bytes(_ name: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent(name)) }

    func dir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class CFSender: FoldersSender, @unchecked Sendable {
    func sendFolders() {}
}

private final class CFCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func add() { lock.lock(); stored += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class CFLookup: AppLookup, @unchecked Sendable {
    func isInstalled(bundleID: String) -> Bool { true }
}

private final class CFLoginService: LoginService, @unchecked Sendable {
    var status: LoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class CFRegistrar: HotKeyRegistrar {
    func register(_ combination: String) -> Bool { true }
    func unregister() {}
}

@MainActor
private func cfRun(_ body: @MainActor (CFEnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-corrupt-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = CFEnv(home: base.resolvingSymlinksInPath())
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", env.home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        chmod(env.folder.path, 0o700)
        try? fm.removeItem(at: base)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try await body(env)
}

@MainActor
private func cfLockFolder(_ env: CFEnv) -> Bool {
    chmod(env.folder.path, 0o500)
    let probe = env.folder.appendingPathComponent("write-probe")
    if FileManager.default.createFile(atPath: probe.path, contents: Data()) {
        try? FileManager.default.removeItem(at: probe)
        chmod(env.folder.path, 0o700)
        Issue.record("this process can write into a read-only folder, so a failed rename cannot be made here")
        return false
    }
    return true
}

@MainActor
private func cfModel() -> SettingsModel {
    SettingsModel(sender: CFSender(), modelWhole: { true })
}

@MainActor
private func cfSettled(_ model: SettingsModel, rows: Int) async -> Bool {
    await sxEventually(10) { model.rows.count == rows && model.rows.allSatisfy { $0.state != .counting } }
}

@MainActor
private func cfWindow(_ model: SettingsModel, glass: Bool) -> SettingsContainerWindow {
    let window = SettingsContainerWindow(
        model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: SYLoginService()),
        appChoices: AppChoices(lookup: SYLookup(installed: [])), deleteIndex: SettingsContainerWindow.unwiredDeleteIndex(),
        glass: glass)
    window.isReleasedWhenClosed = false
    window.refresh()
    return window
}

@MainActor
private func cfNotices(_ root: NSView) -> [NSTextField] {
    plTexts(root).filter { $0.stringValue == cfText }
}

@MainActor
private func cfDismissButtons(_ root: NSView) -> [NSButton] {
    prViews(root).compactMap { $0 as? NSButton }.filter { plVisible($0) && ($0.title == cfDismiss || $0.accessibilityLabel() == cfDismiss) }
}

@MainActor
private func cfRow(_ root: NSView, _ field: NSTextField) -> NSView? {
    (([field] as [NSView]) + sxAncestors(field)).first { view in
        let box = plBox(root, view)
        return abs(box.minX - 181) <= 1 && abs(box.maxX - 720) <= 1
    }
}

@MainActor
private func cfScroll(_ root: NSView, _ section: SettingsScreen.Section) -> NSScrollView? {
    sgsSection(root, section).flatMap { sxAncestors($0).compactMap { $0 as? NSScrollView }.first }
}

@MainActor
private func cfWalk(_ window: NSWindow) -> [NSView] {
    var walked: [NSView] = []
    var current: NSView? = window.initialFirstResponder
    while let view = current, walked.count < 200, !walked.contains(where: { $0 === view }) {
        walked.append(view)
        current = view.nextKeyView
    }
    return walked
}

@MainActor
private func cfTitleFont(_ button: NSButton) -> NSFont? {
    if button.attributedTitle.length > 0, let font = button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
        return font
    }
    return button.font
}

@MainActor
private func cfTitleInk(_ button: NSButton) -> NSColor? {
    if button.attributedTitle.length > 0,
       let colour = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
        return colour
    }
    return button.contentTintColor
}

@MainActor
private func cfValidFile(folders: [String] = [], hotkey: String? = nil) throws {
    var settings = Settings()
    settings.folders = folders.map { Settings.Folder(path: $0, code: false, reading: true) }
    if let hotkey { settings.hotkey = hotkey }
    try SettingsFile().write(settings)
}

enum CFWriter: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case addFolder, setKind, setTicked, startIndexing, removeFolder
    case recordShortcut, backToDefault, adoptLive
    case chooseApp, deleteIndex, firstRunDefault
    case setupStartIndexing, setupFinishSetup

    var testDescription: String { rawValue }
}

@MainActor
private func cfWrite(_ writer: CFWriter, _ env: CFEnv) async throws {
    switch writer {
    case .addFolder, .setKind, .setTicked, .startIndexing, .removeFolder:
        let trips = try env.dir("Trips")
        let extra = try env.dir("Extra")
        try cfValidFile(folders: [trips.path])
        let model = cfModel()
        #expect(await cfSettled(model, rows: 1), "the row never settled")
        try env.plant(cfCut)
        switch writer {
        case .addFolder: model.addFolder(extra)
        case .setKind: model.setKind("photo", on: false)
        case .setTicked: model.setTicked(trips.path, false)
        case .startIndexing: model.startIndexing()
        default: model.removeFolder(trips.path, confirmed: true)
        }
        _ = await sxEventually(2) { model.rows.allSatisfy { $0.state != .counting } }
    case .recordShortcut:
        let control = ShortcutControl(registrar: CFRegistrar())
        try env.plant(cfCut)
        control.record("opt+cmd+k")
    case .backToDefault:
        try cfValidFile(hotkey: "cmd+opt+k")
        let control = ShortcutControl(registrar: CFRegistrar())
        try env.plant(cfCut)
        control.backToDefault()
    case .adoptLive:
        let control = ShortcutControl(registrar: CFRegistrar())
        try env.plant(cfCut)
        control.adoptLive("ctrl+opt+space", refused: "cmd+space")
    case .chooseApp:
        try env.plant(cfCut)
        let choices = AppChoices(lookup: CFLookup())
        let option = try #require(AppChoices.options(for: "pdf").first { $0.name == "Skim" }, "the pdf picker has no Skim")
        _ = try? choices.choose(option, for: "pdf")
    case .deleteIndex:
        try env.plant(cfCut)
        let reset = CFCount()
        let caches = CFCount()
        let delete = DeleteIndex(closeIndex: {}, sendReset: { reset.add() }, deleteCaches: { caches.add() })
        #expect(throws: (any Error).self) { try delete.run(confirmed: true) }
        #expect(reset.value == 0, "reset was sent \(reset.value) times after a failed write")
        #expect(caches.value == 0, "caches were deleted \(caches.value) times after a failed write")
    case .firstRunDefault:
        try env.plant(cfCut)
        LoginItem(service: CFLoginService()).applyFirstRunDefault()
    case .setupStartIndexing:
        let models = env.folder.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 10).write(to: models.appendingPathComponent("cf-model.gguf"))
        try env.plant(cfCut)
        let model = SetupModel(files: [ModelFile(name: "cf-model.gguf", size: 10, sha256: String(repeating: "0", count: 64))])
        #expect(model.canStartIndexing, "Start is not offered, so the pin would be hollow")
        model.startIndexing()
    case .setupFinishSetup:
        try env.plant(cfCut)
        SetupModel(files: []).finishSetup()
    }
}

extension ModelDownloadTests {
    @Suite("SettingsCorruptFileTests", .serialized)
    struct SettingsCorruptFileTests {

        @MainActor
        @Test(arguments: cfBad)
        func aSettingsFileThatCannotBeDecodedIsRenamedBesideItAndTheModelStartsEmpty(bad: CFBad) async throws {
            try await cfRun { env in
                try env.plant(bad.bytes)
                #expect(throws: (any Error).self) { try SettingsFile().read() }
                let before = Int(Date().timeIntervalSince1970)
                let model = cfModel()
                let after = Int(Date().timeIntervalSince1970)
                #expect(!FileManager.default.fileExists(atPath: env.settings.path), "\(bad.name): settings.json is still in place")
                let aside = env.setAsides()
                #expect(aside.count == 1, "\(bad.name): files named settings.json.corrupt-*: \(aside)")
                guard let name = aside.first else { return }
                let digits = String(name.dropFirst(cfPrefix.count))
                #expect(!digits.isEmpty && digits.allSatisfy { "0123456789".contains($0) }, "\(bad.name): the suffix is \"\(digits)\"")
                let number = Int(digits) ?? -1
                #expect(number >= before && number <= after, "\(bad.name): the number \(number) is outside \(before) to \(after)")
                #expect(env.bytes(name) == bad.bytes, "\(bad.name): the set-aside bytes differ from what was planted")
                #expect(model.rows.isEmpty, "\(bad.name): rows \(model.rows.map(\.path))")
                #expect(env.settingsFiles() == [name], "\(bad.name): settings files \(env.settingsFiles())")
            }
        }

        @MainActor
        @Test func aLaterCorruptFileIsSetAsideUnderANewNameAndTheFirstIsKept() async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                _ = cfModel()
                let first = env.setAsides()
                #expect(first.count == 1, "first round: \(first)")
                try await Task.sleep(nanoseconds: 1_200_000_000)
                try env.plant(cfOther)
                _ = cfModel()
                let both = env.setAsides()
                #expect(both.count == 2, "second round: \(both)")
                #expect(Set(both).count == 2)
                if let name = first.first {
                    #expect(both.contains(name), "the first set-aside file is gone: \(both)")
                    #expect(env.bytes(name) == cfCut, "the first set-aside file changed")
                    if let second = both.first(where: { $0 != name }) {
                        #expect(env.bytes(second) == cfOther, "the second set-aside file holds other bytes")
                        #expect((Int(second.dropFirst(cfPrefix.count)) ?? 0) > (Int(name.dropFirst(cfPrefix.count)) ?? 0), "the second name is not later")
                    }
                }
                #expect(!FileManager.default.fileExists(atPath: env.settings.path))
            }
        }

        @MainActor
        @Test func noFileMeansNoRenameAndNoFileIsMade() async throws {
            try await cfRun { env in
                let model = cfModel()
                #expect(env.settingsFiles().isEmpty, "settings files \(env.settingsFiles())")
                #expect(model.rows.isEmpty)
            }
        }

        @MainActor
        @Test func aValidFileWrittenFromDefaultsIsLeftAloneByteForByte() async throws {
            try await cfRun { env in
                try SettingsFile().write(Settings())
                let before = try #require(env.bytes("settings.json"))
                let model = cfModel()
                #expect(env.bytes("settings.json") == before, "the file changed")
                #expect(env.settingsFiles() == ["settings.json"], "settings files \(env.settingsFiles())")
                #expect(model.rows.isEmpty)
            }
        }

        @MainActor
        @Test func aValidFileWithTwoFoldersAndAnotherHotkeyIsLeftAloneAndKeepsItsRows() async throws {
            try await cfRun { env in
                let trips = try env.dir("Trips")
                let notes = try env.dir("Notes")
                try cfValidFile(folders: [trips.path, notes.path], hotkey: "cmd+opt+k")
                let before = try #require(env.bytes("settings.json"))
                let model = cfModel()
                #expect(await cfSettled(model, rows: 2), "the rows never settled: \(model.rows.map(\.path))")
                #expect(model.rows.map(\.path) == [env.home.path + "/Trips", env.home.path + "/Notes"], "rows \(model.rows.map(\.path))")
                #expect(env.bytes("settings.json") == before, "the file changed")
                #expect(env.settingsFiles() == ["settings.json"], "settings files \(env.settingsFiles())")
                #expect(try SettingsFile().read().hotkey == "cmd+opt+k")
            }
        }

        @MainActor
        @Test func afterTheSetAsideTheFoldersTabReadsNoFoldersAndAddingAFolderWritesAWholeNewFileBesideIt() async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                let model = cfModel()
                let window = cfWindow(model, glass: false)
                let root = sxLayout(window, .folders)
                let section = try #require(sxFoldersSection(root))
                #expect(plTexts(section).filter { $0.stringValue == cfNoFolders }.count == 1, "texts \(plTexts(section).map(\.stringValue))")
                let add = sxButtons(section, titled: cfAddFolder)
                #expect(add.count == 1 && add.first?.isEnabled == true, "Add folder buttons \(add.map(\.isEnabled))")
                let aside = env.setAsides()
                #expect(aside.count == 1, "set-aside files \(aside)")
                let planted = try env.dir("Pictures")
                model.addFolder(planted)
                #expect(await cfSettled(model, rows: 1), "the row never settled")
                let written = try #require(env.bytes("settings.json"), "no settings.json was written")
                #expect(try SettingsFile().read().folders.map(\.path) == [planted.path])
                #expect((try? JSONSerialization.jsonObject(with: written)) is NSDictionary, "the new settings.json is not a JSON object")
                if let name = aside.first { #expect(env.bytes(name) == cfCut, "the set-aside file changed") }
                #expect(env.setAsides() == aside, "set-aside files \(env.setAsides())")
            }
        }

        @MainActor
        @Test func aFailedRenameLeavesTheFileInPlaceShowsNoNoticeAndWritesStillFailWithTheSaveError() async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                guard cfLockFolder(env) else { return }
                defer { chmod(env.folder.path, 0o700) }
                let model = cfModel()
                #expect(env.bytes("settings.json") == cfCut, "the file changed")
                #expect(env.setAsides().isEmpty, "set-aside files \(env.setAsides())")
                #expect(model.rows.isEmpty)
                model.setKind("photo", on: false)
                #expect(model.errorText == cfSaveError, "error text \(String(describing: model.errorText))")
                for glass in slPaths {
                    let window = cfWindow(model, glass: glass)
                    for section in SettingsScreen.Section.allCases {
                        let root = sxLayout(window, section)
                        #expect(cfNotices(root).isEmpty, "\(section.title) glass \(glass): the notice shows though nothing was set aside")
                        #expect(cfDismissButtons(root).isEmpty, "\(section.title) glass \(glass): a Dismiss control shows")
                    }
                }
            }
        }

        @MainActor
        @Test func screenValuesCarryTheNoticeOnceAndDismissFirstOnEverySectionAndNeitherWithoutIt() async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                let model = cfModel()
                for section in SettingsScreen.Section.allCases {
                    let screen = SettingsScreen(model: model, section: section)
                    #expect(screen.texts.filter { $0 == cfText }.count == 1, "\(section.title): texts \(screen.texts)")
                    #expect(screen.controls.first?.label == cfDismiss, "\(section.title): controls \(screen.controls.map(\.label))")
                    #expect(screen.controls.first?.isEnabled == true, "\(section.title): Dismiss is disabled")
                    #expect(screen.controls.filter { $0.label == cfDismiss }.count == 1, "\(section.title): controls \(screen.controls.map(\.label))")
                }
            }
            try await cfRun { _ in
                try SettingsFile().write(Settings())
                let model = cfModel()
                for section in SettingsScreen.Section.allCases {
                    let screen = SettingsScreen(model: model, section: section)
                    #expect(!screen.texts.contains(cfText), "\(section.title): the notice is in \(screen.texts)")
                    #expect(!screen.controls.contains { $0.label == cfDismiss }, "\(section.title): Dismiss is in \(screen.controls.map(\.label))")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func everyTabShowsTheNoticeOnceUnderTheTitleStripAtFullPaneWidthWithTheContentBelowIt(glass: Bool) async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                let window = cfWindow(cfModel(), glass: glass)
                for look in DTLook.allCases {
                    for section in SettingsScreen.Section.allCases {
                        let root = sxLayout(window, section, look)
                        let tag = "\(section.title) \(look)"
                        let notices = cfNotices(root)
                        #expect(notices.count == 1, "\(tag): \(notices.count) texts equal the notice")
                        guard let field = notices.first else { continue }
                        let title = try #require(sgsTitles(root, section.title).first, "\(tag): no pane title")
                        let strip = try #require(sgsStrip(root, title: title), "\(tag): no strip")
                        let stripBox = plBox(root, strip)
                        let row = try #require(cfRow(root, field), "\(tag): no row of the pane's width holds the notice")
                        let rowBox = plBox(root, row)
                        #expect(abs(rowBox.top - stripBox.bottom) <= 1, "\(tag): the row starts at \(rowBox.top), the strip ends at \(stripBox.bottom)")
                        #expect(abs(rowBox.minX - 181) <= 1 && abs(rowBox.maxX - 720) <= 1, "\(tag): the row spans \(rowBox.minX) to \(rowBox.maxX)")
                        let fieldBox = plBox(root, field)
                        #expect(fieldBox.minX >= rowBox.minX - 0.5 && fieldBox.maxX <= rowBox.maxX + 0.5, "\(tag): the text leaves the row")
                        #expect(fieldBox.top >= rowBox.top - 0.5 && fieldBox.bottom <= rowBox.bottom + 0.5, "\(tag): the text leaves the row vertically")
                        let scroll = try #require(cfScroll(root, section), "\(tag): no scroll view")
                        let scrollBox = plBox(root, scroll)
                        #expect(scrollBox.top >= rowBox.bottom - 0.5, "\(tag): the scroll view starts at \(scrollBox.top), the row ends at \(rowBox.bottom)")
                        #expect(abs(scrollBox.maxX - 720) <= 0.5 && scrollBox.bottom <= 548.5, "\(tag): the scroll view ends at \(scrollBox.maxX), \(scrollBox.bottom)")
                        let content = try #require(sgsSection(root, section), "\(tag): no section view")
                        #expect(plBox(root, content).top >= rowBox.bottom - 0.5, "\(tag): the content starts at \(plBox(root, content).top), the row ends at \(rowBox.bottom)")
                        #expect(!scroll.isDescendant(of: row) && !row.isDescendant(of: scroll), "\(tag): the row and the scroll view nest")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theNoticeIsAtMostTwoLinesOfSecondaryNoteTextWithAQuietDismissAtItsRightAndNoFillOrIcon(glass: Bool) async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                let window = cfWindow(cfModel(), glass: glass)
                for look in DTLook.allCases {
                    for section in SettingsScreen.Section.allCases {
                        let root = sxLayout(window, section, look)
                        let tag = "\(section.title) \(look)"
                        let field = try #require(cfNotices(root).first, "\(tag): no notice")
                        #expect(sxFont(field.font, size: 11.5, weight: .regular), "\(tag): font \(String(describing: field.font))")
                        #expect(sxColour(field.textColor, is: .secondaryLabelColor), "\(tag): colour \(String(describing: field.textColor))")
                        let font = try #require(field.font)
                        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
                        let needed = (field.stringValue as NSString).boundingRect(
                            with: NSSize(width: field.frame.width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
                        #expect(needed <= 2 * lineHeight + 1, "\(tag): the text needs \(needed) pt of \(lineHeight) pt lines in \(field.frame.width) pt")
                        #expect(field.frame.height + 1 >= needed, "\(tag): the field is \(field.frame.height) pt tall, the text needs \(needed)")
                        #expect(field.frame.height <= 2 * lineHeight + 4, "\(tag): the field is \(field.frame.height) pt tall")

                        let buttons = cfDismissButtons(root)
                        #expect(buttons.count == 1, "\(tag): \(buttons.count) Dismiss controls")
                        guard let button = buttons.first else { continue }
                        let row = try #require(cfRow(root, field), "\(tag): no row")
                        #expect(button.isDescendant(of: row), "\(tag): Dismiss is outside the row")
                        #expect(button.isEnabled)
                        #expect(!button.isBordered, "\(tag): Dismiss has a bezel")
                        #expect(button.keyEquivalent.isEmpty, "\(tag): Dismiss key equivalent \"\(button.keyEquivalent)\"")
                        #expect(button.bezelColor == nil, "\(tag): Dismiss has a bezel colour")
                        #expect(button.image == nil, "\(tag): Dismiss has an icon")
                        #expect(sxColour(cfTitleInk(button), is: .secondaryLabelColor), "\(tag): Dismiss ink \(String(describing: cfTitleInk(button)))")
                        #expect(sxFont(cfTitleFont(button), size: 11.5, weight: .regular), "\(tag): Dismiss font \(String(describing: cfTitleFont(button)))")
                        let fieldBox = plBox(root, field)
                        let buttonBox = sxAlignBox(root, button)
                        #expect(buttonBox.minX >= fieldBox.maxX - 0.5, "\(tag): Dismiss starts at \(buttonBox.minX), the text ends at \(fieldBox.maxX)")
                        #expect(buttonBox.maxX <= 720.5, "\(tag): Dismiss ends at \(buttonBox.maxX)")
                        #expect(buttonBox.top < fieldBox.bottom && fieldBox.top < buttonBox.bottom, "\(tag): Dismiss and the text share no line")

                        let icons = prViews(row).compactMap { $0 as? NSImageView }.filter { plVisible($0) }
                        #expect(icons.isEmpty, "\(tag): \(icons.count) images in the row")
                        #expect(!prViews(row).contains { $0 is NSBox }, "\(tag): an NSBox in the row")
                        #expect(!(row is NSBox), "\(tag): the row is an NSBox")
                        let fills = ([row] + prViews(row)).compactMap { view -> CGFloat? in
                            guard let cg = view.layer?.backgroundColor else { return nil }
                            return NSColor(cgColor: cg)?.alphaComponent
                        }
                        #expect(fills.allSatisfy { $0 == 0 }, "\(tag): the row draws a fill \(fills)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theNoticeTextIsAStaticTextLabelledWithItselfDismissIsLabelledDismissAndTabReachesItFirstInThePane(glass: Bool) async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                let window = cfWindow(cfModel(), glass: glass)
                for section in SettingsScreen.Section.allCases {
                    let root = sxLayout(window, section)
                    let tag = section.title
                    let field = try #require(cfNotices(root).first, "\(tag): no notice")
                    #expect(field.accessibilityRole() == .staticText, "\(tag): role \(String(describing: field.accessibilityRole()))")
                    #expect(field.accessibilityLabel() == cfText, "\(tag): label \(String(describing: field.accessibilityLabel()))")
                    let button = try #require(cfDismissButtons(root).first, "\(tag): no Dismiss")
                    #expect(button.accessibilityLabel() == cfDismiss, "\(tag): Dismiss label \(String(describing: button.accessibilityLabel()))")

                    let walked = cfWalk(window)
                    #expect(walked.prefix(4).compactMap { ($0 as? SidebarButton)?.title } == ["Folders", "File types", "Search", "Indexing"],
                            "\(tag): the first four stops are \(walked.prefix(4).map { NSStringFromClass(type(of: $0)) })")
                    #expect(walked.count > 4 && walked[4] === button, "\(tag): the fifth stop is \(walked.count > 4 ? NSStringFromClass(type(of: walked[4])) : "missing"), not Dismiss")
                    #expect(walked.filter { $0 is SidebarButton }.count == 4, "\(tag): sidebar stops \(walked.filter { $0 is SidebarButton }.count)")
                    let pane = try #require(sgsSection(root, section), "\(tag): no section view")
                    for view in walked.dropFirst(5) {
                        #expect(view.isDescendant(of: pane), "\(tag): the stop \(NSStringFromClass(type(of: view))) is outside the section")
                        #expect((view as? NSControl)?.isEnabled == true, "\(tag): the stop \(NSStringFromClass(type(of: view))) is not an enabled control")
                    }
                    #expect(walked.last?.nextKeyView === walked.first, "\(tag): Tab from the last stop does not return to the start")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func dismissRemovesTheTextTheControlAndTheSpaceAndItStaysGoneOnEveryTabAndAfterTwentyRefreshes(glass: Bool) async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                let window = cfWindow(cfModel(), glass: glass)
                var rowBottom: CGFloat = 0
                do {
                    let root = sxLayout(window, .search)
                    let field = try #require(cfNotices(root).first, "no notice before the press")
                    rowBottom = try #require(cfRow(root, field).map { plBox(root, $0).bottom }, "no row")
                    let scroll = try #require(cfScroll(root, .search))
                    #expect(plBox(root, scroll).top >= rowBottom - 0.5, "before: the scroll view starts at \(plBox(root, scroll).top)")
                    let button = try #require(cfDismissButtons(root).first, "no Dismiss before the press")
                    button.performClick(nil)
                    let after = window.contentView!
                    after.layoutSubtreeIfNeeded()
                    #expect(cfNotices(after).isEmpty, "the text stays after Dismiss")
                    #expect(cfDismissButtons(after).isEmpty, "the Dismiss control stays after Dismiss")
                    #expect(!window.settingsScreen.texts.contains(cfText), "the screen still holds the text")
                    #expect(!window.settingsScreen.controls.contains { $0.label == cfDismiss }, "the screen still holds Dismiss")
                    let title = try #require(sgsTitles(after, "Search").first, "no pane title")
                    let strip = try #require(sgsStrip(after, title: title), "no strip")
                    let scrollBox = plBox(after, try #require(cfScroll(after, .search)))
                    #expect(abs(scrollBox.top - plBox(after, strip).bottom) <= 1, "after: the scroll view starts at \(scrollBox.top), the strip ends at \(plBox(after, strip).bottom)")
                }
                #expect(rowBottom > 46 + 8, "the row was not taller than 8 pt, so its space cannot be seen going")
                for _ in 0..<20 { window.refresh() }
                for section in SettingsScreen.Section.allCases {
                    let root = sxLayout(window, section)
                    #expect(cfNotices(root).isEmpty, "\(section.title): the text came back")
                    #expect(cfDismissButtons(root).isEmpty, "\(section.title): Dismiss came back")
                    let content = try #require(sgsSection(root, section))
                    #expect(abs(plBox(root, content).top - 46 - 16) <= 2, "\(section.title): the section starts \(plBox(root, content).top - 46) under the strip")
                    let scroll = try #require(cfScroll(root, section))
                    #expect(abs(plBox(root, scroll).top - 46) <= 1, "\(section.title): the scroll view starts at \(plBox(root, scroll).top)")
                }
                for _ in 0..<20 { window.refresh() }
                #expect(cfNotices(window.contentView!).isEmpty, "the text came back after 20 refreshes")
                window.close()
                #expect(env.setAsides().count == 1, "set-aside files \(env.setAsides())")
                let later = cfWindow(cfModel(), glass: glass)
                for section in SettingsScreen.Section.allCases {
                    let root = sxLayout(later, section)
                    #expect(cfNotices(root).isEmpty, "\(section.title): a new window shows the notice")
                    #expect(cfDismissButtons(root).isEmpty, "\(section.title): a new window shows Dismiss")
                }
                #expect(env.setAsides().count == 1, "set-aside files \(env.setAsides())")
                #expect(!FileManager.default.fileExists(atPath: env.settings.path))
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func withAGoodFileNoRowExistsAndTheContentStartsWhereItDid(glass: Bool) async throws {
            try await cfRun { env in
                try SettingsFile().write(Settings())
                let window = cfWindow(cfModel(), glass: glass)
                for look in DTLook.allCases {
                    for section in SettingsScreen.Section.allCases {
                        let root = sxLayout(window, section, look)
                        let tag = "\(section.title) \(look)"
                        #expect(cfNotices(root).isEmpty, "\(tag): the notice shows")
                        #expect(cfDismissButtons(root).isEmpty, "\(tag): Dismiss shows")
                        let scroll = try #require(cfScroll(root, section))
                        #expect(abs(plBox(root, scroll).top - 46) <= 1, "\(tag): the scroll view starts at \(plBox(root, scroll).top)")
                        let content = try #require(sgsSection(root, section))
                        #expect(abs(plBox(root, content).top - 46 - 16) <= 2, "\(tag): the section starts \(plBox(root, content).top - 46) under the strip")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theWindowsRefreshReadNeverRenamesAFileThatTurnsBadAfterTheModelWasBuilt(glass: Bool) async throws {
            try await cfRun { env in
                try SettingsFile().write(Settings())
                let model = cfModel()
                let window = cfWindow(model, glass: glass)
                try env.plant(cfCut)
                for _ in 0..<20 { window.refresh() }
                for section in SettingsScreen.Section.allCases {
                    _ = SettingsScreen(model: model, section: section)
                    _ = sxLayout(window, section)
                }
                #expect(env.bytes("settings.json") == cfCut, "the file changed")
                #expect(env.setAsides().isEmpty, "set-aside files \(env.setAsides())")
                #expect(env.settingsFiles() == ["settings.json"], "settings files \(env.settingsFiles())")
                #expect(cfNotices(window.contentView!).isEmpty, "a notice appeared from a refresh")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aSecondBadFileLaidDownWhileTheWindowIsOpenIsNeverRenamedByItsRefreshes(glass: Bool) async throws {
            try await cfRun { env in
                try env.plant(cfCut)
                let model = cfModel()
                let window = cfWindow(model, glass: glass)
                let first = env.setAsides()
                #expect(first.count == 1, "set-aside files \(first)")
                try env.plant(cfOther)
                for _ in 0..<20 { window.refresh() }
                for section in SettingsScreen.Section.allCases {
                    _ = SettingsScreen(model: model, section: section)
                    _ = sxLayout(window, section)
                }
                #expect(env.bytes("settings.json") == cfOther, "the second bad file changed")
                #expect(env.setAsides() == first, "set-aside files \(env.setAsides())")
            }
        }

        @MainActor
        @Test(arguments: CFWriter.allCases)
        func noWriterChangesACorruptFileBeforeItIsSetAside(writer: CFWriter) async throws {
            try await cfRun { env in
                try await cfWrite(writer, env)
                #expect(env.bytes("settings.json") == cfCut, "\(writer.rawValue): the corrupt file's bytes changed")
                #expect(env.settingsFiles() == ["settings.json"], "\(writer.rawValue): settings files \(env.settingsFiles())")
                #expect(env.setAsides().isEmpty, "\(writer.rawValue): a set-aside file appeared \(env.setAsides())")
            }
        }
    }
}

extension ModelDownloadTests.SettingsCorruptFileTests {

    @Test func theNoticeTextIsExactlyTheSentenceAndTheSaveErrorIsUnchanged() {
        #expect(SettingsScreen.settingsSetAsideText == "Your settings file could not be read, so it was set aside and defaults are in use.")
        #expect(SettingsScreen.settingsSetAsideText == cfText)
        #expect(!SettingsScreen.settingsSetAsideText.hasSuffix(" "))
        #expect(SettingsScreen.settingsSetAsideText.filter { $0 == "." }.count == 1)
    }

    @MainActor
    @Test(arguments: cfBad)
    func theModelCarriesTheExactNoticeAfterASetAside(bad: CFBad) async throws {
        try await cfRun { env in
            try env.plant(bad.bytes)
            let model = cfModel()
            #expect(model.setAsideNotice == cfText, "\(bad.name): notice \(String(describing: model.setAsideNotice))")
            #expect(SettingsScreen(model: model).setAsideNotice == cfText, "\(bad.name): the screen holds \(String(describing: SettingsScreen(model: model).setAsideNotice))")
        }
    }

    @MainActor
    @Test func theModelHasNoNoticeForNoFileAValidFileOrARenameThatFailed() async throws {
        try await cfRun { env in
            #expect(cfModel().setAsideNotice == nil, "no file: a notice")
            try SettingsFile().write(Settings())
            #expect(cfModel().setAsideNotice == nil, "a valid file: a notice")
            try env.plant(cfCut)
            guard cfLockFolder(env) else { return }
            defer { chmod(env.folder.path, 0o700) }
            #expect(cfModel().setAsideNotice == nil, "a failed rename: a notice")
        }
    }

    @MainActor
    @Test func dismissClearsTheNoticeAndALaterModelFindsNone() async throws {
        try await cfRun { env in
            try env.plant(cfCut)
            let model = cfModel()
            #expect(model.setAsideNotice == cfText)
            model.dismissSetAsideNotice()
            #expect(model.setAsideNotice == nil, "notice after Dismiss: \(String(describing: model.setAsideNotice))")
            #expect(SettingsScreen(model: model).setAsideNotice == nil)
            #expect(cfModel().setAsideNotice == nil, "a later model shows a notice")
            #expect(env.setAsides().count == 1)
        }
    }

    @MainActor
    @Test func theFileLevelCallRenamesACorruptFileToTheUnixSecondsNameAndReturnsTrue() async throws {
        try await cfRun { env in
            try env.plant(cfCut)
            let done = SettingsFile().setAsideIfCorrupt(now: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(done, "the call returned false")
            #expect(env.names().filter { $0.hasPrefix("settings") } == ["settings.json.corrupt-1700000000"], "settings files \(env.settingsFiles())")
            #expect(env.bytes("settings.json.corrupt-1700000000") == cfCut, "the bytes differ")
        }
    }

    @MainActor
    @Test func theNumberIsWholeSecondsCutNotRounded() async throws {
        try await cfRun { env in
            try env.plant(cfCut)
            #expect(SettingsFile().setAsideIfCorrupt(now: Date(timeIntervalSince1970: 1_700_000_000.9)))
            #expect(env.settingsFiles() == ["settings.json.corrupt-1700000000"], "settings files \(env.settingsFiles())")
        }
    }

    @MainActor
    @Test func theFileLevelCallReturnsFalseAndTouchesNothingForNoFileAndForAValidFile() async throws {
        try await cfRun { env in
            #expect(!SettingsFile().setAsideIfCorrupt(now: Date(timeIntervalSince1970: 1_700_000_000)), "no file: true")
            #expect(env.settingsFiles().isEmpty, "no file: settings files \(env.settingsFiles())")
            try SettingsFile().write(Settings())
            let before = try #require(env.bytes("settings.json"))
            #expect(!SettingsFile().setAsideIfCorrupt(now: Date(timeIntervalSince1970: 1_700_000_000)), "a valid file: true")
            #expect(env.settingsFiles() == ["settings.json"], "settings files \(env.settingsFiles())")
            #expect(env.bytes("settings.json") == before, "the valid file changed")
        }
    }

    @MainActor
    @Test func aSecondCallAfterTheSetAsideReturnsFalseAndMakesNoSecondFile() async throws {
        try await cfRun { env in
            try env.plant(cfCut)
            let at = Date(timeIntervalSince1970: 1_700_000_000)
            #expect(SettingsFile().setAsideIfCorrupt(now: at))
            #expect(!SettingsFile().setAsideIfCorrupt(now: at.addingTimeInterval(5)), "the second call returned true")
            #expect(env.settingsFiles() == ["settings.json.corrupt-1700000000"], "settings files \(env.settingsFiles())")
        }
    }

    @MainActor
    @Test func aCorruptFileSetAsideInTheSameSecondReplacesTheEarlierOne() async throws {
        try await cfRun { env in
            let at = Date(timeIntervalSince1970: 1_700_000_000)
            try env.plant(cfCut)
            #expect(SettingsFile().setAsideIfCorrupt(now: at))
            try env.plant(cfOther)
            #expect(SettingsFile().setAsideIfCorrupt(now: at), "the second call returned false")
            #expect(env.settingsFiles() == ["settings.json.corrupt-1700000000"], "settings files \(env.settingsFiles())")
            #expect(env.bytes("settings.json.corrupt-1700000000") == cfOther, "the same-second file was not replaced")
        }
    }

    @MainActor
    @Test func aRenameThatThrowsReturnsFalseAndLeavesTheFileWhereItIs() async throws {
        try await cfRun { env in
            try env.plant(cfCut)
            guard cfLockFolder(env) else { return }
            defer { chmod(env.folder.path, 0o700) }
            #expect(!SettingsFile().setAsideIfCorrupt(now: Date(timeIntervalSince1970: 1_700_000_000)), "the call returned true")
            #expect(env.bytes("settings.json") == cfCut, "the file changed")
            #expect(env.setAsides().isEmpty, "set-aside files \(env.setAsides())")
        }
    }
}
