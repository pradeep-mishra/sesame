import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let scnFiveKinds = ["Photos", "PDFs", "Documents", "Audio", "Video"]
private let scnPdfNames = ["Preview", "Adobe Acrobat", "Skim"]
private let scnMediaNames = ["QuickTime Player", "IINA", "VLC"]
private let scnOldOpenWith = ["pdf": "Preview", "media": "QuickTime Player", "code": "Zed"]
private let scnOldSpeeds: [String: Double] = ["photo": 3.0, "code": 15.0]
private let scnAllKindsOn: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]

private final class SCNSender: FoldersSender, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func sendFolders() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class SCNLookup: AppLookup, @unchecked Sendable {
    func isInstalled(bundleID: String) -> Bool { false }
}

private struct SCNEnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

    @discardableResult
    func files(_ relative: String, _ names: [String]) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names { try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent(name)) }
        return url
    }

    func settingsDictionary() -> NSDictionary? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    func entry(_ path: String) -> NSDictionary? {
        ((settingsDictionary()?["folders"] as? [NSDictionary]) ?? []).first { ($0["path"] as? String) == path }
    }

    func seed(folders: [URL], old: Bool) throws {
        let entries = folders.map { "{\"path\": \"\($0.path)\", \"code\": \(old), \"reading\": true}" }.joined(separator: ", ")
        let json = """
        {
          "version": 3,
          "startPressed": true,
          "indexDeleted": false,
          "folders": [\(entries)],
          "codeSearchOn": \(old),
          "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
          "hotkey": "cmd+opt+k",
          "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "\(old ? "Zed" : "VS Code")"},
          "speeds": {"photo": 3.0\(old ? ", \"code\": 15.0" : "")},
          "loginDefaultApplied": true
        }
        """
        try SettingsFile().write(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)))
    }

    func mixedAndPictures() throws -> [URL] {
        [try files("Mixed", ["a.png", "b.jpg", "x.py", "y.py", "z.py"]),
         try files("Pictures", ["c.png", "d.jpg", "e.jpg"])]
    }
}

@MainActor
private func scnRun(_ body: (SCNEnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-scn-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = SCNEnv(home: base.resolvingSymlinksInPath())
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", env.home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
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
private func scnEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func scnModel(_ sender: SCNSender = SCNSender()) async -> SettingsModel {
    let model = SettingsModel(sender: sender, modelWhole: { true })
    _ = await scnEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
    return model
}

@MainActor
private func scnWindow(_ model: SettingsModel, _ section: SettingsScreen.Section) -> SettingsContainerWindow {
    let window = SettingsContainerWindow(model: model)
    window.isReleasedWhenClosed = false
    window.select(section)
    window.refresh()
    return window
}

@MainActor
private func scnViews(_ window: NSWindow) -> [NSView] {
    guard let root = window.contentView else { return [] }
    return prViews(root).filter { !$0.isHiddenOrHasHiddenAncestor }
}

@MainActor
private func scnReadable(_ window: SettingsContainerWindow) -> [String] {
    var out = window.settingsScreen.texts + window.settingsScreen.controls.map { $0.label }
    for view in scnViews(window) {
        if let field = view as? NSTextField { out.append(field.stringValue) }
        if let button = view as? NSButton { out.append(button.title) }
        if let popup = view as? NSPopUpButton { out.append(contentsOf: popup.itemTitles) }
        if let label = view.accessibilityLabel() { out.append(label) }
        if let title = view.accessibilityTitle() { out.append(title) }
    }
    return out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@MainActor
private func scnPopup(_ label: String, in window: NSWindow) -> NSPopUpButton? {
    scnViews(window).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label }
}

@MainActor
private func scnChoose(_ title: String, in popup: NSPopUpButton) async -> Bool {
    guard popup.isEnabled, popup.itemTitles.contains(title) else { return false }
    popup.selectItem(withTitle: title)
    _ = popup.sendAction(popup.action, to: popup.target)
    await Task.yield()
    return true
}

private func scnSnapshot(_ screen: SettingsScreen) -> [String] {
    ["texts: \(screen.texts)"] + screen.controls.map { "control: \($0.label) | \($0.isEnabled) | \(String(describing: $0.isOn))" }
}

private func scnNamesCode(_ strings: [String]) -> [String] {
    strings.filter { $0.lowercased().contains("code") }
}

extension ModelDownloadTests {
    @Suite("SettingsNoCodeTests", .serialized)
    struct SettingsNoCodeTests {

        @MainActor
        @Test func fileTypesListsExactlyPhotosPdfsDocumentsAudioAndVideoWhateverTheFileSays() async throws {
            for old in [false, true] {
                try await scnRun { env in
                    try env.seed(folders: try env.mixedAndPictures(), old: old)
                    let model = await scnModel()
                    let screen = SettingsScreen(model: model, section: .fileTypes)
                    let context = old ? "old settings file" : "default settings file"

                    #expect(screen.controls.map { $0.label } == scnFiveKinds, "\(context): File types controls \(screen.controls.map { $0.label })")
                    #expect(screen.controls.allSatisfy { $0.isEnabled && $0.isOn == true }, "\(context): a kind is disabled or off: \(scnSnapshot(screen))")
                    #expect(screen.texts.contains("File types"), "\(context): no heading in \(screen.texts)")
                    #expect(screen.folderRows.isEmpty, "\(context): File types holds folder rows")
                    #expect(scnNamesCode(screen.texts + screen.controls.map { $0.label }).isEmpty, "\(context): File types names code: \(scnSnapshot(screen))")
                    #expect(screen.texts.filter { $0.lowercased().contains("not read") || $0.contains("Set with") || $0.contains("Tick a folder") }.isEmpty,
                            "\(context): a note about a kind or a code folder is there: \(screen.texts)")
                    #expect(!screen.controls.contains { $0.label == "Search my code" || $0.label.hasSuffix(", code folder") || $0.label.hasPrefix("Code") },
                            "\(context): a code switch, tick or row is there: \(screen.controls.map { $0.label })")

                    let window = scnWindow(model, .fileTypes)
                    let labels = scnViews(window).compactMap { $0 as? NSControl }.flatMap { [($0 as? NSButton)?.title, $0.accessibilityLabel()].compactMap { $0 } }
                    for kind in scnFiveKinds {
                        #expect(labels.contains(kind), "\(context): no \(kind) control in the window: \(labels)")
                    }
                    #expect(!labels.contains { $0 == "Search my code" || $0.hasSuffix(", code folder") }, "\(context): a code control is in the window: \(labels)")
                }
            }
        }

        @MainActor
        @Test func noSectionOfSettingsNamesCodeInAnyTextControlOrViewWhateverTheFileSays() async throws {
            for old in [false, true] {
                try await scnRun { env in
                    try env.seed(folders: try env.mixedAndPictures(), old: old)
                    let model = await scnModel()
                    let window = scnWindow(model, .folders)
                    for section in SettingsScreen.Section.allCases {
                        let context = "\(old ? "old" : "default") settings file / \(section.title)"
                        let screen = SettingsScreen(model: model, section: section)
                        #expect(scnNamesCode(screen.texts + screen.controls.map { $0.label }).isEmpty, "\(context): \(scnSnapshot(screen))")
                        window.select(section)
                        window.refresh()
                        #expect(scnNamesCode(scnReadable(window)).isEmpty, "\(context): the window shows \(scnNamesCode(scnReadable(window)))")
                    }
                    let folders = SettingsScreen(model: model, section: .folders)
                    for text in ["Folders Sesame reads", "Tick a folder to read it. Use the more button on a row to re-index or remove it."] {
                        #expect(folders.texts.contains(text), "\(old ? "old" : "default") settings file: Folders texts lack \"\(text)\": \(folders.texts)")
                        #expect(scnNamesCode([text]).isEmpty, "\(old ? "old" : "default") settings file: \"\(text)\" names code")
                    }
                    #expect(scnNamesCode(folders.controls.map { $0.label }).isEmpty, "Folders controls name code: \(folders.controls.map { $0.label })")
                }
            }
        }

        @MainActor
        @Test func searchHoldsExactlyThePdfAndMediaPopUpsAndTheStoredCodeEditorStaysAsFound() async throws {
            for old in [false, true] {
                try await scnRun { env in
                    try env.seed(folders: try env.mixedAndPictures(), old: old)
                    let model = await scnModel()
                    let window = scnWindow(model, .search)
                    let context = old ? "old settings file" : "default settings file"

                    let shortcutLabels = ["Record new shortcut", "Back to default"]
                    let pickerLabels = window.settingsScreen.controls.map { $0.label }.filter { !shortcutLabels.contains($0) }
                    #expect(pickerLabels == ["PDF app", "Media app"], "\(context): Search controls \(window.settingsScreen.controls.map { $0.label })")
                    #expect(window.settingsScreen.controls.allSatisfy { $0.isEnabled && $0.isOn == nil }, "\(context): \(scnSnapshot(window.settingsScreen))")
                    let popups = scnViews(window).compactMap { $0 as? NSPopUpButton }
                    #expect(popups.count == 2, "\(context): \(popups.count) pop-up buttons: \(popups.map { $0.accessibilityLabel() ?? "" })")
                    let pdf = try #require(scnPopup("PDF app", in: window), "\(context): no PDF app pop-up")
                    let media = try #require(scnPopup("Media app", in: window), "\(context): no Media app pop-up")
                    #expect(pdf.itemTitles == scnPdfNames, "\(context): PDF app offers \(pdf.itemTitles)")
                    #expect(media.itemTitles == scnMediaNames, "\(context): Media app offers \(media.itemTitles)")
                    #expect(pdf.selectedItem?.title == "Preview", "\(context): PDF app shows \(String(describing: pdf.selectedItem?.title))")
                    #expect(media.selectedItem?.title == "QuickTime Player", "\(context): Media app shows \(String(describing: media.selectedItem?.title))")
                    #expect(scnPopup("Code editor", in: window) == nil, "\(context): a Code editor pop-up is there")
                    #expect(!scnReadable(window).contains { $0.contains("Code editor") }, "\(context): the words Code editor are on screen")

                    #expect(await scnChoose("Skim", in: pdf), "\(context): could not choose Skim in \(pdf.itemTitles)")
                    let stored = env.settingsDictionary()?["openWith"] as? [String: String]
                    #expect(stored == ["pdf": "Skim", "media": "QuickTime Player", "code": old ? "Zed" : "VS Code"], "\(context): openWith on disk \(String(describing: stored))")
                }
            }
        }

        @MainActor
        @Test func appChoicesHasOnlyPdfAndMediaAndRefusesTheCodeKindWithoutTouchingTheFile() async throws {
            #expect(AppChoices.kinds == ["pdf", "media"], "kinds: \(AppChoices.kinds)")
            #expect(AppChoices.options(for: "code").isEmpty, "code options: \(AppChoices.options(for: "code").map(\.name))")
            #expect(AppChoices.options(for: "pdf").map(\.name) == scnPdfNames)
            #expect(AppChoices.options(for: "media").map(\.name) == scnMediaNames)

            try await scnRun { env in
                try env.seed(folders: try env.mixedAndPictures(), old: true)
                let before = try Data(contentsOf: env.settings)
                let choices = AppChoices(lookup: SCNLookup())
                var refused = false
                do {
                    try choices.choose(AppOption(name: "Zed", bundleID: "dev.zed.Zed"), for: "code")
                } catch let error as AppChoicesError {
                    if case .unknownKind(let kind) = error { refused = kind == "code" }
                } catch {
                    Issue.record("choose for code threw \(error), not AppChoicesError.unknownKind")
                }
                #expect(refused, "choose(_, for: \"code\") did not throw AppChoicesError.unknownKind(\"code\")")
                #expect(try Data(contentsOf: env.settings) == before, "a refused choice changed settings.json")
            }
        }

        @MainActor
        @Test func aFoldersRowOfAFolderTickedForCodeReadsLikeAnyOtherFolderWhateverTheFileSays() async throws {
            for old in [true, false] {
                try await scnRun { env in
                    let mixed = try env.files("Mixed", ["a.png", "b.jpg", "x.py", "y.py", "z.py"])
                    try env.seed(folders: [mixed], old: old)
                    let model = await scnModel()
                    let screen = SettingsScreen(model: model, section: .folders)
                    let context = old ? "old settings file" : "default settings file"

                    let row = try #require(screen.folderRows.first { $0.name == "Mixed" }, "\(context): no Mixed row in \(screen.folderRows.map { $0.name })")
                    #expect(row.detail == "2 photos, under a minute", "\(context): detail \"\(row.detail)\"")
                    #expect(row.tick.label == "Mixed, 2 photos, under a minute", "\(context): tick label \"\(row.tick.label)\"")
                    #expect(screen.texts.contains("Mixed: 2 photos, under a minute"), "\(context): texts \(screen.texts)")
                    #expect(!screen.texts.contains { $0.contains("not read yet") || $0.contains("nothing to read") }, "\(context): texts \(screen.texts)")
                    #expect(screen.controls.map { $0.label } == ["Mixed, 2 photos, under a minute", "More actions for Mixed", "Re-index", "Remove", "Add folder\u{2026}"],
                            "\(context): controls \(screen.controls.map { $0.label })")
                }
            }
        }

        @MainActor
        @Test func everySectionBuiltFromAnOldFileEqualsTheSameSectionBuiltFromADefaultFile() async throws {
            try await scnRun { env in
                let folders = try env.mixedAndPictures()

                try env.seed(folders: folders, old: false)
                let defaultModel = await scnModel()
                var fromDefault: [SettingsScreen.Section: [String]] = [:]
                for section in SettingsScreen.Section.allCases { fromDefault[section] = scnSnapshot(SettingsScreen(model: defaultModel, section: section)) }

                try env.seed(folders: folders, old: true)
                let oldModel = await scnModel()
                for section in SettingsScreen.Section.allCases {
                    let fromOld = scnSnapshot(SettingsScreen(model: oldModel, section: section))
                    #expect(fromOld == fromDefault[section], "\(section.title): old file \(fromOld), default file \(String(describing: fromDefault[section]))")
                }
            }
        }

        @MainActor
        @Test func addingAFolderAndSwitchingKindsLeaveEveryOldCodeValueOnDiskAsFound() async throws {
            try await scnRun { env in
                let folders = try env.mixedAndPictures()
                try env.seed(folders: folders, old: true)
                let sender = SCNSender()
                let model = await scnModel(sender)
                let extra = try env.files("Extra", ["f.png"])

                model.addFolder(extra)
                #expect(await scnEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } })
                for kind in ["pdf", "doc", "audio", "video", "photo"] {
                    model.setKind(kind, on: false)
                    model.setKind(kind, on: true)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)

                let after = env.settingsDictionary()
                #expect(after?["codeSearchOn"] as? Bool == true, "codeSearchOn is \(String(describing: after?["codeSearchOn"]))")
                #expect(after?["kindsOn"] as? [String: Bool] == scnAllKindsOn, "kindsOn is \(String(describing: after?["kindsOn"]))")
                #expect(after?["openWith"] as? [String: String] == scnOldOpenWith, "openWith is \(String(describing: after?["openWith"]))")
                #expect(after?["speeds"] as? [String: Double] == scnOldSpeeds, "speeds is \(String(describing: after?["speeds"]))")
                for folder in folders {
                    #expect(env.entry(folder.path)?["code"] as? Bool == true, "\(folder.lastPathComponent) lost its code value: \(String(describing: env.entry(folder.path)))")
                }
                #expect(env.entry(extra.path)?["code"] as? Bool == false, "the added folder is saved with code \(String(describing: env.entry(extra.path)?["code"]))")
                #expect(env.entry(extra.path)?["reading"] as? Bool == false, "the added folder reads before Start: \(String(describing: env.entry(extra.path)))")
            }
        }
    }
}
