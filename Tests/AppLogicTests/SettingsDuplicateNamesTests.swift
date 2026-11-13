import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let dnMessage = "Remove Docs from search? Its files leave the index. The files themselves are not touched."
private let dnLabel = "More actions for Docs"

private let dnFolders = [
    SXFolder(path: "a/Docs", photos: 2),
    SXFolder(path: "b/Docs", photos: 3),
]

@MainActor
private func dnWith(
    glass: Bool,
    _ body: @MainActor (SettingsContainerWindow, SXEnv) async throws -> Void
) async throws {
    try await sxWithWindow(dnFolders, make: { model in
        SettingsContainerWindow(
            model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: MainAppLoginService()),
            appChoices: AppChoices(), deleteIndex: SettingsContainerWindow.unwiredDeleteIndex(), glass: glass)
    }, body)
}

extension ModelDownloadTests {
    @Suite("SettingsDuplicateNamesTests", .serialized)
    struct SettingsDuplicateNamesTests {
        @MainActor
        @Test(arguments: slPaths)
        func twoFoldersNamedDocsGiveTwoMoreButtonsWithTheSameLabelAndTheirFullPathsAsHelp(glass: Bool) async throws {
            try await dnWith(glass: glass) { window, env in
                let first = env.home.appendingPathComponent("a/Docs").path
                let second = env.home.appendingPathComponent("b/Docs").path
                let root = sxLayout(window, .folders)
                let buttons = smrMoreButtons(root)
                #expect(buttons.count == 2, "\(buttons.count) more buttons for two rows")
                #expect(buttons.map { $0.accessibilityLabel() ?? "" } == [dnLabel, dnLabel], "labels \(buttons.map { $0.accessibilityLabel() ?? "nil" })")
                let helps = buttons.map { $0.accessibilityHelp() ?? "" }
                #expect(helps == [first, second], "the more buttons carry the helps \(helps), wanted [\(first), \(second)]")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theConfirmForTheSecondDocsKeepsTheVisibleMessageAndGivesCancelAndRemoveFolderItsFullPathAsHelp(glass: Bool) async throws {
            try await dnWith(glass: glass) { window, env in
                let first = env.home.appendingPathComponent("a/Docs").path
                let second = env.home.appendingPathComponent("b/Docs").path
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                #expect(sxButtons(section, titled: "Cancel").isEmpty && sxButtons(section, titled: "Remove folder").isEmpty, "the confirm is visible before a Remove choice")
                let secondButton = try #require(smrMoreButtons(root).dropFirst().first, "no second more button")
                #expect(await smrPerform(smrItem("Remove", of: secondButton)), "no Remove item under the second more button")
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                #expect(plText(section, dnMessage) != nil, "the message is not shown as today's text: \(plTexts(section).map(\.stringValue))")
                let cancel = try #require(sxButtons(section, titled: "Cancel").first, "no Cancel")
                let remove = try #require(sxButtons(section, titled: "Remove folder").first, "no Remove folder")
                #expect(cancel.accessibilityHelp() == second, "Cancel help \"\(cancel.accessibilityHelp() ?? "nil")\", wanted \"\(second)\"")
                #expect(remove.accessibilityHelp() == second, "Remove folder help \"\(remove.accessibilityHelp() ?? "nil")\", wanted \"\(second)\"")
                #expect(cancel.accessibilityLabel() == "Cancel" && remove.accessibilityLabel() == "Remove folder")

                cancel.performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                let firstButton = try #require(smrMoreButtons(root).first, "no first more button")
                #expect(await smrPerform(smrItem("Remove", of: firstButton)), "no Remove item under the first more button")
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                let cancelAgain = try #require(sxButtons(section, titled: "Cancel").first, "no Cancel for the first folder")
                let removeAgain = try #require(sxButtons(section, titled: "Remove folder").first, "no Remove folder for the first folder")
                #expect(plText(section, dnMessage) != nil, "the message is not shown for the first folder")
                #expect(cancelAgain.accessibilityHelp() == first, "Cancel help \"\(cancelAgain.accessibilityHelp() ?? "nil")\", wanted \"\(first)\"")
                #expect(removeAgain.accessibilityHelp() == first, "Remove folder help \"\(removeAgain.accessibilityHelp() ?? "nil")\", wanted \"\(first)\"")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theTickButtonsStillCarryTheirFullPathsAndTheVisibleNamesStayDocs(glass: Bool) async throws {
            try await dnWith(glass: glass) { window, env in
                let paths = [env.home.appendingPathComponent("a/Docs").path, env.home.appendingPathComponent("b/Docs").path]
                let root = sxLayout(window, .folders)
                let section = try #require(sxFoldersSection(root))
                let ticks = sxVisibleButtons(section)
                    .filter { !($0 is NSPopUpButton) && paths.contains($0.accessibilityHelp() ?? "") }
                    .sorted { plBox(root, $0).top < plBox(root, $1).top }
                #expect(ticks.map { $0.accessibilityHelp() ?? "" } == paths, "tick helps \(ticks.map { $0.accessibilityHelp() ?? "nil" })")
                #expect(ticks.map(\.title) == ["Docs", "Docs"], "tick titles \(ticks.map(\.title))")
            }
        }
    }
}
