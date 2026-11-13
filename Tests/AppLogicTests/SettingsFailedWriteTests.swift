import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let fwSaveError = "Could not save your settings."
private let fwStart = "Start indexing"
private let fwGarbage = Data("not json".utf8)
private let fwOthers: [SettingsScreen.Section] = [.fileTypes, .search, .indexing]

private struct FWEnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

    func dir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func plantGarbage() throws { try fwGarbage.write(to: settings) }
    func bytes() -> Data? { try? Data(contentsOf: settings) }

    func seed(folderPath: String, startPressed: Bool) throws {
        let json = """
        {
          "version": 3,
          "startPressed": \(startPressed),
          "indexDeleted": false,
          "folders": [{"path": "\(folderPath)", "code": false, "reading": true}],
          "codeSearchOn": false,
          "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
          "hotkey": "cmd+opt+k",
          "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
          "speeds": {"photo": 3.0},
          "loginDefaultApplied": true
        }
        """
        let value = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        try SettingsFile().write(value)
    }
}

private final class FWSender: FoldersSender, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func sendFolders() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class FWCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func add() { lock.lock(); stored += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
}

@MainActor
private func fwRun(_ body: @MainActor (FWEnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-failedwrite-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = FWEnv(home: base.resolvingSymlinksInPath())
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
private func fwBuild(_ env: FWEnv, startPressed: Bool, sender: FWSender) async throws -> (model: SettingsModel, trips: String) {
    let trips = try env.dir("Trips")
    try env.seed(folderPath: trips.path, startPressed: startPressed)
    let model = SettingsModel(sender: sender, modelWhole: { true })
    #expect(await sxEventually(10) { model.rows.count == 1 && model.rows.allSatisfy { $0.state != .counting } }, "the row never settled")
    return (model, trips.path)
}

@MainActor
private func fwWindow(_ model: SettingsModel, glass: Bool, installed: Set<String> = []) -> SettingsContainerWindow {
    let window = SettingsContainerWindow(
        model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: SYLoginService()),
        appChoices: AppChoices(lookup: SYLookup(installed: installed)), deleteIndex: SettingsContainerWindow.unwiredDeleteIndex(),
        glass: glass)
    window.isReleasedWhenClosed = false
    window.refresh()
    return window
}

@MainActor
private func fwControl(_ label: String, in window: NSWindow) -> NSControl? {
    guard let root = window.contentView else { return nil }
    return prViews(root).compactMap { $0 as? NSControl }.filter { plVisible($0) }.first { control in
        [(control as? NSButton)?.title, control.accessibilityLabel()].compactMap { $0 }.contains(label)
    }
}

@MainActor
private func fwShown(_ window: SettingsContainerWindow, _ section: SettingsScreen.Section) -> Bool? {
    let root = sxRelayout(window)
    guard let view = sgsSection(root, section) else { return nil }
    return plText(view, fwSaveError) != nil
}

@MainActor
private func fwScreenHas(_ window: SettingsContainerWindow) -> Bool {
    window.settingsScreen.texts.contains(fwSaveError)
}

@MainActor
private func fwFolderCheck(_ window: SettingsContainerWindow, path: String) -> NSButton? {
    let root = sxRelayout(window)
    guard let section = sxFoldersSection(root) else { return nil }
    return sxVisibleButtons(section).first { !($0 is NSPopUpButton) && $0.title != "Cancel" && $0.title != "Remove folder" && $0.accessibilityHelp() == path }
}

@MainActor
private func fwVideoSwitch(_ window: SettingsContainerWindow) -> NSSwitch? {
    let root = sxRelayout(window)
    guard let section = sxFileTypesSection(root) else { return nil }
    return prViews(section).compactMap { $0 as? NSSwitch }.filter { plVisible($0) }.first { $0.accessibilityLabel() == "Video" }
}

@MainActor
private func fwFailOnFolders(_ window: SettingsContainerWindow, path: String) async throws {
    _ = sxLayout(window, .folders)
    let check = try #require(fwFolderCheck(window, path: path), "no tick for the folder")
    check.performClick(nil)
    await Task.yield()
    _ = sxRelayout(window)
}

@MainActor
private func fwFailOnFileTypes(_ window: SettingsContainerWindow) async throws {
    _ = sxLayout(window, .fileTypes)
    let video = try #require(fwVideoSwitch(window), "no Video switch")
    video.performClick(nil)
    await Task.yield()
    _ = sxRelayout(window)
}

@MainActor
private func fwExpectGone(_ window: SettingsContainerWindow, _ model: SettingsModel, on sections: [SettingsScreen.Section], _ tag: String) {
    for section in sections {
        #expect(fwShown(window, section) == false, "\(tag): the save error shows on \(section.title)")
        #expect(!fwScreenHas(window), "\(tag): the \(section.title) screen holds the save error: \(window.settingsScreen.texts)")
        for _ in 0..<3 { window.refresh() }
        #expect(fwShown(window, section) == false, "\(tag): a refresh brought the save error back on \(section.title)")
    }
    #expect(model.errorText == nil, "\(tag): the model still holds \(String(describing: model.errorText))")
}

extension ModelDownloadTests {
    @Suite("SettingsFailedWriteTests", .serialized)
    struct SettingsFailedWriteTests {

        @MainActor
        @Test(arguments: slPaths)
        func startAfterAFailedWriteDoesNotAnnounceItselfAndShowsTheSaveErrorOnIndexing(glass: Bool) async throws {
            try await fwRun { env in
                let sender = FWSender()
                let (model, _) = try await fwBuild(env, startPressed: false, sender: sender)
                let window = fwWindow(model, glass: glass)
                let started = FWCount()
                window.onStarted = { started.add() }
                _ = sxLayout(window, .indexing)
                let start = try #require(fwControl(fwStart, in: window), "no Start indexing control")
                #expect(start.isEnabled, "Start indexing is not enabled before the write is made to fail")
                try env.plantGarbage()

                start.performClick(nil)
                await Task.yield()

                #expect(started.value == 0, "onStarted ran \(started.value) times after a failed write")
                #expect(model.errorText == fwSaveError, "error text \(String(describing: model.errorText))")
                #expect(sender.calls == 0, "folders was sent \(sender.calls) times after a failed write")
                #expect(env.bytes() == fwGarbage, "settings.json changed although the write failed")
                #expect(fwShown(window, .indexing) == true, "the Indexing section does not show the save error")
                #expect(fwScreenHas(window), "the Indexing screen does not hold the save error: \(window.settingsScreen.texts)")
                try await Task.sleep(nanoseconds: 300_000_000)
                #expect(started.value == 0, "onStarted ran after a failed write, late")
                #expect(sender.calls == 0, "folders was sent after a failed write, late")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func startAfterAGoodWriteCallsOnStartedOnceSendsOnceAndCannotBePressedAgain(glass: Bool) async throws {
            try await fwRun { env in
                let sender = FWSender()
                let (model, trips) = try await fwBuild(env, startPressed: false, sender: sender)
                let window = fwWindow(model, glass: glass)
                let started = FWCount()
                window.onStarted = { started.add() }
                _ = sxLayout(window, .indexing)
                let start = try #require(fwControl(fwStart, in: window), "no Start indexing control")
                #expect(start.isEnabled, "Start indexing is not enabled")

                start.performClick(nil)
                await Task.yield()

                #expect(started.value == 1, "onStarted ran \(started.value) times after a good write")
                #expect(sender.calls == 1, "folders was sent \(sender.calls) times")
                #expect(model.errorText == nil, "error text \(String(describing: model.errorText))")
                #expect(fwShown(window, .indexing) == false, "the save error shows after a good write")
                let saved = try #require(try? Data(contentsOf: env.settings), "no settings.json")
                let parsed = try #require(try? JSONSerialization.jsonObject(with: saved) as? NSDictionary, "settings.json does not parse")
                #expect(parsed["startPressed"] as? Bool == true, "startPressed on disk: \(String(describing: parsed["startPressed"]))")
                #expect(((parsed["folders"] as? [NSDictionary])?.first?["path"] as? String) == trips)

                #expect(await sxEventually(10) { !(fwControl(fwStart, in: window)?.isEnabled ?? false) }, "Start indexing stays enabled after it was pressed")
                if let again = fwControl(fwStart, in: window) { again.performClick(nil) }
                await Task.yield()
                #expect(started.value == 1, "onStarted ran \(started.value) times after a second press")
                #expect(sender.calls == 1, "folders was sent \(sender.calls) times after a second press")
            }
        }

        @MainActor
        @Test func theModelsStartIndexingReturnsTrueAfterAGoodWriteAndFalseAfterAFailedOne() async throws {
            try await fwRun { env in
                let sender = FWSender()
                let (model, _) = try await fwBuild(env, startPressed: false, sender: sender)
                let started = model.startIndexing()
                #expect(started == true, "startIndexing returned \(started) after a good write")
                #expect(sender.calls == 1, "folders was sent \(sender.calls) times")
                #expect(model.errorText == nil)
            }
            try await fwRun { env in
                let sender = FWSender()
                let (model, _) = try await fwBuild(env, startPressed: false, sender: sender)
                try env.plantGarbage()
                let started = model.startIndexing()
                #expect(started == false, "startIndexing returned \(started) after a failed write")
                #expect(sender.calls == 0, "folders was sent \(sender.calls) times after a failed write")
                #expect(model.errorText == fwSaveError, "error text \(String(describing: model.errorText))")
                #expect(env.bytes() == fwGarbage, "settings.json changed although the write failed")
            }
        }

        @MainActor
        @Test func clearErrorEmptiesTheErrorTextAndIsHarmlessWithNone() async throws {
            try await fwRun { env in
                let (model, trips) = try await fwBuild(env, startPressed: true, sender: FWSender())
                model.clearError()
                #expect(model.errorText == nil)
                try env.plantGarbage()
                model.setTicked(trips, false)
                #expect(model.errorText == fwSaveError, "error text \(String(describing: model.errorText))")
                model.clearError()
                #expect(model.errorText == nil, "clearError left \(String(describing: model.errorText))")
                model.clearError()
                #expect(model.errorText == nil)
            }
        }

        @MainActor
        @Test func aSuccessfulWriteStillClearsTheErrorText() async throws {
            try await fwRun { env in
                let (model, trips) = try await fwBuild(env, startPressed: true, sender: FWSender())
                try env.plantGarbage()
                model.setTicked(trips, false)
                #expect(model.errorText == fwSaveError)
                try env.seed(folderPath: trips, startPressed: true)
                model.setTicked(trips, false)
                #expect(model.errorText == nil, "a good write left \(String(describing: model.errorText))")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aFailedTickOnFoldersShowsTheErrorThereAndNotOnTheOtherTabsOrWhenBackOnFoldersUntilItFailsAgain(glass: Bool) async throws {
            try await fwRun { env in
                let (model, trips) = try await fwBuild(env, startPressed: true, sender: FWSender())
                let window = fwWindow(model, glass: glass)
                _ = sxLayout(window, .folders)
                #expect(fwShown(window, .folders) == false, "an error before anything went wrong")
                try env.plantGarbage()

                try await fwFailOnFolders(window, path: trips)
                #expect(model.errorText == fwSaveError, "error text \(String(describing: model.errorText))")
                #expect(fwShown(window, .folders) == true, "Folders does not show the save error")
                #expect(fwScreenHas(window), "the Folders screen does not hold the save error: \(window.settingsScreen.texts)")

                for other in fwOthers {
                    _ = sxLayout(window, other)
                    fwExpectGone(window, model, on: [other], "after Folders failed, on \(other.title)")
                }
                _ = sxLayout(window, .folders)
                fwExpectGone(window, model, on: [.folders], "back on Folders")

                try await fwFailOnFolders(window, path: trips)
                #expect(model.errorText == fwSaveError, "a second failure: error text \(String(describing: model.errorText))")
                #expect(fwShown(window, .folders) == true, "Folders does not show a new failure")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aFailedKindSwitchOnFileTypesShowsTheErrorThereAndNotOnSearchFoldersOrIndexingUntilItFailsAgain(glass: Bool) async throws {
            try await fwRun { env in
                let (model, _) = try await fwBuild(env, startPressed: true, sender: FWSender())
                let window = fwWindow(model, glass: glass)
                _ = sxLayout(window, .fileTypes)
                #expect(fwShown(window, .fileTypes) == false, "an error before anything went wrong")
                try env.plantGarbage()

                try await fwFailOnFileTypes(window)
                #expect(model.errorText == fwSaveError, "error text \(String(describing: model.errorText))")
                #expect(fwShown(window, .fileTypes) == true, "File types does not show the save error")
                #expect(fwScreenHas(window), "the File types screen does not hold the save error: \(window.settingsScreen.texts)")

                for other in [SettingsScreen.Section.search, .folders, .indexing] {
                    _ = sxLayout(window, other)
                    fwExpectGone(window, model, on: [other], "after File types failed, on \(other.title)")
                }
                _ = sxLayout(window, .fileTypes)
                fwExpectGone(window, model, on: [.fileTypes], "back on File types")

                try await fwFailOnFileTypes(window)
                #expect(model.errorText == fwSaveError, "a second failure: error text \(String(describing: model.errorText))")
                #expect(fwShown(window, .fileTypes) == true, "File types does not show a new failure")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aFailedStartShowsOnIndexingAndNotOnTheOtherTabs(glass: Bool) async throws {
            try await fwRun { env in
                let (model, _) = try await fwBuild(env, startPressed: false, sender: FWSender())
                let window = fwWindow(model, glass: glass)
                _ = sxLayout(window, .indexing)
                let start = try #require(fwControl(fwStart, in: window), "no Start indexing control")
                #expect(start.isEnabled)
                try env.plantGarbage()
                start.performClick(nil)
                await Task.yield()
                #expect(fwShown(window, .indexing) == true, "Indexing does not show the save error")

                for other in [SettingsScreen.Section.folders, .fileTypes, .search] {
                    _ = sxLayout(window, other)
                    fwExpectGone(window, model, on: [other], "after Start failed, on \(other.title)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aFailedAppPickStillShowsOnSearchAndClearsWhenTheSectionChanges(glass: Bool) async throws {
            try await fwRun { env in
                let (model, _) = try await fwBuild(env, startPressed: true, sender: FWSender())
                let window = fwWindow(model, glass: glass, installed: ["com.apple.Preview", "com.apple.QuickTimePlayerX"])
                var root = sxLayout(window, .search)
                var section = try #require(sySearchSection(root), "no Search section view")
                let pdf = try #require(syPopUp(section, labelled: "PDF app"))
                try env.plantGarbage()
                #expect(await syChoose("Skim", in: pdf), "could not choose Skim")
                root = sxRelayout(window)
                section = try #require(sySearchSection(root))
                #expect(plText(section, fwSaveError) != nil, "Search does not show the failed pick: \(plTexts(section).map(\.stringValue))")

                window.select(.indexing)
                root = sxRelayout(window)
                let indexing = try #require(syIndexingSection(root))
                #expect(plText(indexing, fwSaveError) == nil, "the failed pick shows on Indexing")

                window.select(.search)
                root = sxRelayout(window)
                section = try #require(sySearchSection(root))
                #expect(plText(section, fwSaveError) == nil, "the failed pick stayed after the section changed")
            }
        }
    }
}
