import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let smaTitle = "Folders"
private let smaSectionTitle = "Folders Sesame reads"
private let smaNote = "Tick a folder to read it. Use the more button on a row to re-index or remove it."
private let smaEmpty = "No folders. Add a folder to read it."
private let smaAddFolder = "Add folder\u{2026}"
private let smaWaiting = "Waiting for Start indexing"

private final class SMASender: FoldersSender, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func sendFolders() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class SMAHold: @unchecked Sendable {
    private let cond = NSCondition()
    private var held = false
    func hold() { cond.lock(); held = true; cond.unlock() }
    func release() { cond.lock(); held = false; cond.broadcast(); cond.unlock() }
    func enter() { cond.lock(); while held { cond.wait() }; cond.unlock() }
}

private final class SMAInstalled: AppLookup, @unchecked Sendable {
    func isInstalled(bundleID: String) -> Bool { true }
}

private struct SMAEnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

    func fill(_ relative: String, photo: Int) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for n in 0..<photo {
            try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent("photo-\(n).\(n % 2 == 0 ? "jpg" : "png")"))
        }
        return url
    }

    func seed(folders: [(path: String, reading: Bool)]) throws {
        let entries = folders.map { "{\"path\": \"\($0.path)\", \"code\": false, \"reading\": \($0.reading)}" }.joined(separator: ", ")
        let json = """
        {
          "version": 3,
          "startPressed": true,
          "indexDeleted": false,
          "folders": [\(entries)],
          "codeSearchOn": false,
          "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
          "hotkey": "cmd+opt+k",
          "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
          "speeds": {"photo": 3.0},
          "loginDefaultApplied": true
        }
        """
        try SettingsFile().write(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)))
    }
}

@MainActor
private func smaRun(_ body: (SMAEnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-moreactions-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = SMAEnv(home: base.resolvingSymlinksInPath())
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
private func smaEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func smaReady(_ model: SettingsModel) async -> Bool {
    await smaEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
}

@MainActor
private func smaModel() -> SettingsModel {
    SettingsModel(sender: SMASender(), modelWhole: { true })
}

private func smaMore(_ row: SettingsScreen.FolderRow) -> SettingsScreen.Control? {
    Mirror(reflecting: row).children.first { $0.label == "more" }?.value as? SettingsScreen.Control
}

private func smaLabels(_ screen: SettingsScreen) -> [String] { screen.controls.map { $0.label } }

private struct SMAThree {
    let trips: URL
    let pictures: URL
    let archive: URL
}

private func smaThree(_ env: SMAEnv) throws -> SMAThree {
    let three = SMAThree(
        trips: try env.fill("Trips", photo: 40),
        pictures: try env.fill("Pictures", photo: 2),
        archive: try env.fill("Archive", photo: 3))
    try env.seed(folders: [(three.trips.path, true), (three.pictures.path, true), (three.archive.path, false)])
    return three
}

extension ModelDownloadTests {
    @Suite("SettingsMoreActionsTextTests", .serialized)
    struct SettingsMoreActionsTextTests {

        @MainActor
        @Test func everyFolderRowHasAnEnabledMoreControlLabelledMoreActionsForItsNameThatIsNotASwitch() async throws {
            try await smaRun { env in
                let three = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))
                model.addFolder(try env.fill("Holiday photos", photo: 2))
                #expect(await smaReady(model))

                let screen = SettingsScreen(model: model, section: .folders)
                #expect(screen.folderRows.map { $0.name } == ["Trips", "Pictures", "Archive", "Holiday photos"], "rows \(screen.folderRows.map { $0.name })")
                let expected = ["More actions for Trips", "More actions for Pictures", "More actions for Archive", "More actions for Holiday photos"]
                for (row, label) in zip(screen.folderRows, expected) {
                    let more = try #require(smaMore(row), "\(row.name): the row has no stored `more` control")
                    #expect(more.label == label, "\(row.name): more label \"\(more.label)\"")
                    #expect(more.isEnabled, "\(row.name): the more control is disabled")
                    #expect(more.isOn == nil, "\(row.name): the more control reads as a switch: \(String(describing: more.isOn))")
                }
                _ = three
            }
        }

        @MainActor
        @Test func reindexAndRemoveKeepTheirLabelsAndAreEnabledForEveryRow() async throws {
            try await smaRun { env in
                _ = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))

                let screen = SettingsScreen(model: model, section: .folders)
                #expect(screen.folderRows.count == 3)
                for row in screen.folderRows {
                    #expect(row.reindex.label == "Re-index", "\(row.name): re-index label \"\(row.reindex.label)\"")
                    #expect(row.remove.label == "Remove", "\(row.name): remove label \"\(row.remove.label)\"")
                    #expect(row.reindex.isEnabled, "\(row.name): Re-index is disabled")
                    #expect(row.remove.isEnabled, "\(row.name): Remove is disabled")
                    #expect(row.reindex.isOn == nil && row.remove.isOn == nil, "\(row.name): a menu item reads as a switch")
                    #expect(row.tick.isEnabled, "\(row.name): the tick is disabled")
                }
                #expect(screen.folderRows.map { $0.tick.isOn } == [true, true, false], "ticks \(screen.folderRows.map { String(describing: $0.tick.isOn) })")
                #expect(screen.controls.filter { $0.label == "Re-index" }.count == 3, "Re-index controls \(smaLabels(screen))")
                #expect(screen.controls.filter { $0.label == "Remove" }.count == 3, "Remove controls \(smaLabels(screen))")
            }
        }

        @MainActor
        @Test func theTickAndTheDetailTextsOfReadingUntickedAndWaitingRowsAreUnchanged() async throws {
            try await smaRun { env in
                let three = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))
                model.addFolder(try env.fill("Extra", photo: 40))
                #expect(await smaReady(model))

                let screen = SettingsScreen(model: model, section: .folders)
                let rows = Dictionary(uniqueKeysWithValues: screen.folderRows.map { ($0.name, $0) })
                let trips = try #require(rows["Trips"])
                #expect(trips.detail == "40 photos, about 2 min", "Trips detail \"\(trips.detail)\"")
                #expect(trips.tick.label == "Trips, 40 photos, about 2 min", "Trips tick label \"\(trips.tick.label)\"")
                #expect(trips.tick.isOn == true)
                let pictures = try #require(rows["Pictures"])
                #expect(pictures.detail == "2 photos, under a minute", "Pictures detail \"\(pictures.detail)\"")
                #expect(pictures.tick.label == "Pictures, 2 photos, under a minute", "Pictures tick label \"\(pictures.tick.label)\"")
                let archive = try #require(rows["Archive"])
                #expect(archive.detail == "not read", "Archive detail \"\(archive.detail)\"")
                #expect(archive.tick.label == "Archive, not read", "Archive tick label \"\(archive.tick.label)\"")
                #expect(archive.tick.isOn == false)
                let extra = try #require(rows["Extra"])
                #expect(extra.detail == "40 photos, " + smaWaiting, "Extra detail \"\(extra.detail)\"")
                #expect(extra.tick.label == "Extra, 40 photos, " + smaWaiting, "Extra tick label \"\(extra.tick.label)\"")
                #expect(extra.tick.isOn == true)
                _ = three
            }
        }

        @MainActor
        @Test func aCountingRowKeepsItsCountingDetailAndItsEnabledMoreControl() async throws {
            try await smaRun { env in
                let three = try smaThree(env)
                let hold = SMAHold()
                hold.hold()
                defer { hold.release() }
                let model = SettingsModel(
                    sender: SMASender(),
                    counter: { folders in
                        hold.enter()
                        return FolderCounts.count(folders: folders)
                    },
                    modelWhole: { true })

                let screen = SettingsScreen(model: model, section: .folders)
                let trips = try #require(screen.folderRows.first { $0.name == "Trips" })
                #expect(trips.detail == "counting\u{2026}", "Trips detail \"\(trips.detail)\"")
                #expect(trips.tick.label == "Trips, counting\u{2026}", "Trips tick label \"\(trips.tick.label)\"")
                let more = try #require(smaMore(trips), "the row has no stored `more` control")
                #expect(more.label == "More actions for Trips", "more label \"\(more.label)\"")
                #expect(more.isEnabled, "the more control of a counting row is disabled")
                #expect(screen.texts.contains("Trips: counting\u{2026}"), "texts \(screen.texts)")
                _ = three
            }
        }

        @MainActor
        @Test func theFoldersControlsAreTickMoreReindexRemovePerRowThenAddFolder() async throws {
            try await smaRun { env in
                _ = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))

                let screen = SettingsScreen(model: model, section: .folders)
                #expect(smaLabels(screen) == [
                    "Trips, 40 photos, about 2 min", "More actions for Trips", "Re-index", "Remove",
                    "Pictures, 2 photos, under a minute", "More actions for Pictures", "Re-index", "Remove",
                    "Archive, not read", "More actions for Archive", "Re-index", "Remove",
                    smaAddFolder,
                ], "controls \(smaLabels(screen))")
                #expect(screen.controls.map { $0.isEnabled } == Array(repeating: true, count: 13), "enabled flags \(screen.controls.map { $0.isEnabled })")
                #expect(screen.controls.map { $0.isOn } == [true, nil, nil, nil, true, nil, nil, nil, false, nil, nil, nil, nil],
                        "isOn flags \(screen.controls.map { String(describing: $0.isOn) })")
            }
        }

        @MainActor
        @Test func anEmptyFoldersListHoldsOnlyAddFolderAndAnOpenConfirmAddsCancelAndRemoveFolderAfterIt() async throws {
            try await smaRun { env in
                try env.seed(folders: [])
                let empty = SettingsScreen(model: smaModel(), section: .folders)
                #expect(smaLabels(empty) == [smaAddFolder], "empty controls \(smaLabels(empty))")
            }
            try await smaRun { env in
                let three = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))

                let screen = SettingsScreen(model: model, section: .folders, confirmingRemoval: three.pictures.path)
                #expect(smaLabels(screen) == [
                    "Trips, 40 photos, about 2 min", "More actions for Trips", "Re-index", "Remove",
                    "Pictures, 2 photos, under a minute", "More actions for Pictures", "Re-index", "Remove",
                    "Archive, not read", "More actions for Archive", "Re-index", "Remove",
                    smaAddFolder, "Cancel", "Remove folder",
                ], "controls with the confirm open \(smaLabels(screen))")
            }
        }

        @MainActor
        @Test func noOtherSectionHoldsAMoreControl() async throws {
            try await smaRun { env in
                _ = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))
                for section in SettingsScreen.Section.allCases where section != .folders {
                    let screen = SettingsScreen(model: model, section: section)
                    #expect(screen.folderRows.isEmpty, "\(section.title): folder rows")
                    #expect(!screen.controls.contains { $0.label.hasPrefix("More actions for") }, "\(section.title): controls \(smaLabels(screen))")
                    #expect(!screen.texts.contains { $0.contains("Folders Sesame reads") || $0.contains("Tick a folder") }, "\(section.title): texts \(screen.texts)")
                }
                let fileTypes = SettingsScreen(model: model, section: .fileTypes)
                #expect(smaLabels(fileTypes) == ["Photos", "PDFs", "Documents", "Audio", "Video"], "File types controls \(smaLabels(fileTypes))")
            }
        }

        @MainActor
        @Test func theFoldersTextsAreTheTabTitleTheSectionTitleOneLinePerRowAndTheNote() async throws {
            try await smaRun { env in
                _ = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))

                let screen = SettingsScreen(model: model, section: .folders)
                #expect(screen.texts == [
                    smaTitle, smaSectionTitle,
                    "Trips: 40 photos, about 2 min", "Pictures: 2 photos, under a minute", "Archive: not read",
                    smaNote,
                ], "texts \(screen.texts)")
            }
        }

        @MainActor
        @Test func anEmptyFoldersListShowsTheEmptyTextBetweenTheSectionTitleAndTheNote() async throws {
            try await smaRun { env in
                try env.seed(folders: [])
                let screen = SettingsScreen(model: smaModel(), section: .folders)
                #expect(screen.texts == [smaTitle, smaSectionTitle, smaEmpty, smaNote], "texts \(screen.texts)")
            }
        }

        @MainActor
        @Test func theConfirmMessageAndThenTheErrorTextFollowTheNote() async throws {
            try await smaRun { env in
                let three = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))

                let confirming = SettingsScreen(model: model, section: .folders, confirmingRemoval: three.trips.path)
                let message = try #require(confirming.confirm?.message, "no confirm")
                #expect(message.contains("Trips"), "confirm message \"\(message)\"")
                #expect(confirming.texts == [
                    smaTitle, smaSectionTitle,
                    "Trips: 40 photos, about 2 min", "Pictures: 2 photos, under a minute", "Archive: not read",
                    smaNote, message,
                ], "texts with the confirm open \(confirming.texts)")

                let problem = "Could not save that change."
                let failed = SettingsScreen(model: model, section: .folders, problem: problem)
                #expect(failed.texts == [
                    smaTitle, smaSectionTitle,
                    "Trips: 40 photos, about 2 min", "Pictures: 2 photos, under a minute", "Archive: not read",
                    smaNote, problem,
                ], "texts with an error \(failed.texts)")

                let both = SettingsScreen(model: model, section: .folders, confirmingRemoval: three.trips.path, problem: problem)
                #expect(both.texts.suffix(3) == [smaNote, message, problem], "texts with both \(both.texts)")
            }
        }

        @MainActor
        @Test func theOtherSectionsTextsAreTheirExistingLists() async throws {
            try await smaRun { env in
                _ = try smaThree(env)
                let model = smaModel()
                #expect(await smaReady(model))

                #expect(SettingsScreen(model: model, section: .fileTypes).texts == ["File types", "File types Sesame reads"])
                let search = SettingsScreen(model: model, section: .search, appChoices: AppChoices(lookup: SMAInstalled()))
                #expect(search.texts == ["Search", "Open files with", "PDF app", "Media app"], "Search texts \(search.texts)")
                let indexing = SettingsScreen(model: model, section: .indexing)
                #expect(indexing.texts == ["Indexing", "Files Sesame could not read", "Nothing here. Files Sesame could not read are listed here."],
                        "Indexing texts \(indexing.texts)")
            }
        }

        @MainActor
        @Test func theSearchTextsWithTheShortcutControlGainTheRowNameAfterTheHeadingAndBeforeTheCombinationAndAMessageOrNoticeFollowsIt() async throws {
            try await smaRun { env in
                try env.seed(folders: [])
                let model = smaModel()
                let screen = SettingsScreen(model: model, section: .search, shortcut: ShortcutControl(), appChoices: AppChoices(lookup: SMAInstalled()))
                #expect(screen.texts == ["Search", "Open Sesame with", "Shortcut", "Option Command K", "Open files with", "PDF app", "Media app"], "Search texts with the shortcut control \(screen.texts)")

                let control = ShortcutControl()
                control.refuseUnnamedKey()
                let refused = SettingsScreen(model: model, section: .search, shortcut: control, appChoices: AppChoices(lookup: SMAInstalled()))
                #expect(refused.texts == ["Search", "Open Sesame with", "Shortcut", "Option Command K", "That key can't be used as a shortcut. Pick another.", "Open files with", "PDF app", "Media app"], "Search texts with a refusal \(refused.texts)")

                let noticed = SettingsScreen(model: model, section: .search, shortcut: ShortcutControl(), notice: "A notice.", appChoices: AppChoices(lookup: SMAInstalled()))
                #expect(noticed.texts == ["Search", "Open Sesame with", "Shortcut", "Option Command K", "A notice.", "Open files with", "PDF app", "Media app"], "Search texts with a notice \(noticed.texts)")
            }
        }
    }
}
