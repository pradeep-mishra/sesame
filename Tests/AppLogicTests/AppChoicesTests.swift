import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t24, tester step. Written from the t24 entry (Tests: paragraph), mockup F3's three app choices, the spec's error
// variants ("if the chosen PDF app is not installed, Settings says so and Enter opens the file in the default app"),
// design section 1 (`settings.json` holds `openWith {pdf, media, code}`) and the plan-2 Conventions; no product source read.
//
// `AppChoices` is the pure model behind F3's three pickers: which apps each picker offers, whether an app is installed
// (asked through an injected `AppLookup`, never the real machine), and where a choice is stored (`openWith.pdf|media|code`
// of `settings.json`, through `SettingsFile`). It opens no app: Enter's behaviour is plan 4 and later.
//
// API SHAPES these tests pin (the entry names `AppChoices`, `AppLookup`, "a bundle id", the note text and the three
// `openWith` keys, and fixes no signatures; everything below is this file's pick; if one is wrong, ask for a test change
// rather than guessing):
//   1. `struct AppOption: Equatable` with `let name: String` (the label the person sees, also the text stored in
//      `settings.json`) and `let bundleID: String`.
//   2. `protocol AppLookup` with `func isInstalled(bundleID: String) -> Bool`. The real one asks macOS; tests give a fake.
//   3. `struct AppChoices` (a final class is as good):
//        `init(lookup: any AppLookup)`
//        `static let kinds: [String]`                          the three picker keys, "pdf", "media", "code" (order free)
//        `static func options(for kind: String) -> [AppOption]` the options of one picker, in the order shown
//        `func note(for option: AppOption) -> String?`          nil when installed; else "<App> is not installed. Enter
//                                                               opens the file in the default app." (<App> = `name`)
//        `func choose(_ option: AppOption, for kind: String) throws`   stores `option.name` in `openWith.<kind>` of
//                                                               `settings.json` through `SettingsFile` and changes
//                                                               nothing else in the file; allowed for an app that is not
//                                                               installed (no throw; the note is read from `note(for:)`)
//   4. Order of the options is the mockup's. PDF and media are pinned exactly as the entry lists them. For code the entry
//      lists VS Code, Cursor, Sublime Text, JetBrains IDE and Xcode; mockup F3 also lists Zed first, so the test pins those
//      five as present and in that order and does not say whether Zed is there.
//   5. Bundle ids: the seven well-known ones are pinned exactly (they are facts about the apps, written here by hand);
//      the other four (Acrobat has a Pro and a Reader id, Cursor's id is a generated one, Sublime Text has versions, a
//      JetBrains IDE has one id per product) are only required to be a non-empty reverse-DNS text that is unique.
//
// Suite placement: HOME is process-wide, so the suite is nested inside `ModelDownloadTests` like the other HOME-setting
// suites; `swift test --filter ModelDownloadTests` also runs it.

private let acNotInstalledSuffix = " is not installed. Enter opens the file in the default app."

private let acKnownIDs: [String: String] = [
    "Preview": "com.apple.Preview",
    "Skim": "net.sourceforge.skim-app.skim",
    "QuickTime Player": "com.apple.QuickTimePlayerX",
    "IINA": "com.colliderli.iina",
    "VLC": "org.videolan.vlc",
]

private let acPdfNames = ["Preview", "Adobe Acrobat", "Skim"]
private let acMediaNames = ["QuickTime Player", "IINA", "VLC"]

/// A stand-in for the machine's list of installed apps. It records every bundle id it is asked about.
private final class ACFakeLookup: AppLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Set<String>
    private var askedIDs: [String] = []

    init(installed: Set<String> = []) { self.installed = installed }

    var asked: [String] { lock.lock(); defer { lock.unlock() }; return askedIDs }

    func isInstalled(bundleID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        askedIDs.append(bundleID)
        return installed.contains(bundleID)
    }
}

private let acSettingsText = """
{
  "version": 3,
  "startPressed": true,
  "indexDeleted": false,
  "folders": [
    {"path": "/Users/test/Pictures", "code": false, "reading": true},
    {"path": "/Users/test/Developer/api-client", "code": true, "reading": false}
  ],
  "codeSearchOn": true,
  "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
  "hotkey": "cmd+opt+k",
  "openWith": {"pdf": "Skim", "media": "IINA", "code": "Cursor"},
  "speeds": {"photo": 0.5},
  "loginDefaultApplied": true
}
"""

private func acFolder(_ home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
}

private func acWriteSettings(_ home: URL) throws {
    try acSettingsText.write(to: acFolder(home).appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
}

private func acSettingsOnDisk(_ home: URL) throws -> NSMutableDictionary {
    let data = try Data(contentsOf: acFolder(home).appendingPathComponent("settings.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    return NSMutableDictionary(dictionary: object)
}

private func acOpenWith(_ settings: NSDictionary) -> [String: String] {
    (settings["openWith"] as? [String: String]) ?? [:]
}

/// The settings with the `openWith` object removed, to compare "nothing else changed".
private func acWithoutOpenWith(_ settings: NSDictionary) -> NSDictionary {
    let copy = NSMutableDictionary(dictionary: settings)
    copy.removeObject(forKey: "openWith")
    return copy
}

private func acOption(_ kind: String, _ name: String) throws -> AppOption {
    try #require(AppChoices.options(for: kind).first { $0.name == name }, "the \(kind) picker has no option named \(name)")
}

private func acAllOptions() -> [(kind: String, option: AppOption)] {
    ["pdf", "media"].flatMap { kind in AppChoices.options(for: kind).map { (kind: kind, option: $0) } }
}

extension ModelDownloadTests {
    @Suite("AppChoicesTests", .serialized)
    struct AppChoicesTests {

        // MARK: the three entries and their options

        @Test func thereAreTwoEntriesPdfAndMedia() {
            #expect(AppChoices.kinds == ["pdf", "media"], "kinds: \(AppChoices.kinds)")
        }

        @Test func thePdfAndMediaPickersOfferExactlyTheAppsOfMockupF3InOrder() {
            #expect(AppChoices.options(for: "pdf").map(\.name) == acPdfNames, "pdf: \(AppChoices.options(for: "pdf").map(\.name))")
            #expect(AppChoices.options(for: "media").map(\.name) == acMediaNames,
                    "media: \(AppChoices.options(for: "media").map(\.name))")
        }

        @Test func anOptionNameIsNeverListedTwiceInOnePicker() {
            for kind in AppChoices.kinds {
                let names = AppChoices.options(for: kind).map(\.name)
                #expect(Set(names).count == names.count, "\(kind): \(names)")
            }
        }

        // MARK: bundle ids

        @Test func theFiveWellKnownAppsCarryTheirRealBundleIds() throws {
            for (kind, names) in [("pdf", acPdfNames), ("media", acMediaNames)] {
                for name in names {
                    guard let wanted = acKnownIDs[name] else { continue }
                    let option = try acOption(kind, name)
                    #expect(option.bundleID == wanted, "\(name): bundle id is \(option.bundleID)")
                }
            }
        }

        @Test func everyOptionHasANonEmptyReverseDnsBundleIdAndNoIdIsSharedByTwoApps() {
            let all = acAllOptions()
            for (kind, option) in all {
                #expect(!option.bundleID.isEmpty, "\(kind) \(option.name) has no bundle id")
                #expect(option.bundleID.contains(".") && !option.bundleID.contains(" "),
                        "\(kind) \(option.name): \(option.bundleID) is not a bundle id")
            }
            let ids = all.map(\.option.bundleID)
            #expect(Set(ids).count == ids.count, "two options share a bundle id: \(ids)")
        }

        // MARK: "<App> is not installed. Enter opens the file in the default app."

        @Test func withNothingInstalledEveryOptionReadsTheNotInstalledNote() {
            let choices = AppChoices(lookup: ACFakeLookup(installed: []))
            for (kind, option) in acAllOptions() {
                #expect(choices.note(for: option) == option.name + acNotInstalledSuffix, "\(kind) \(option.name): \(String(describing: choices.note(for: option)))")
            }
        }

        @Test func withEveryAppInstalledNoOptionHasANote() {
            let everything = Set(acAllOptions().map(\.option.bundleID))
            let choices = AppChoices(lookup: ACFakeLookup(installed: everything))
            for (kind, option) in acAllOptions() {
                #expect(choices.note(for: option) == nil, "\(kind) \(option.name): \(String(describing: choices.note(for: option)))")
            }
        }

        @Test func onlyTheAppsThatAreMissingGetANoteAndItNamesThatApp() throws {
            // Preview and QuickTime Player are here; Skim, IINA and Adobe Acrobat are not.
            let lookup = ACFakeLookup(installed: ["com.apple.Preview", "com.apple.QuickTimePlayerX"])
            let choices = AppChoices(lookup: lookup)
            let preview = try acOption("pdf", "Preview")
            let quickTime = try acOption("media", "QuickTime Player")
            let skim = try acOption("pdf", "Skim")
            let iina = try acOption("media", "IINA")
            let acrobat = try acOption("pdf", "Adobe Acrobat")
            #expect(choices.note(for: preview) == nil)
            #expect(choices.note(for: quickTime) == nil)
            #expect(choices.note(for: skim) == "Skim is not installed. Enter opens the file in the default app.")
            #expect(choices.note(for: iina) == "IINA is not installed. Enter opens the file in the default app.")
            #expect(choices.note(for: acrobat) == "Adobe Acrobat is not installed. Enter opens the file in the default app.")
        }

        @Test func theLookupIsAskedByTheOptionsBundleIdAndTheAnswerIsNotKeptWhenTheMachineChanges() throws {
            let lookup = ACFakeLookup(installed: [])
            let choices = AppChoices(lookup: lookup)
            let skim = try acOption("pdf", "Skim")
            #expect(choices.note(for: skim) != nil)
            #expect(lookup.asked.last == "net.sourceforge.skim-app.skim", "asked \(lookup.asked)")

            // The person installs Skim while Settings is open: the next read must see it.
            let nowInstalled = AppChoices(lookup: ACFakeLookup(installed: ["net.sourceforge.skim-app.skim"]))
            #expect(nowInstalled.note(for: skim) == nil)
        }

        // MARK: a choice is stored in openWith.<kind> of settings.json, through SettingsFile

        @MainActor
        @Test func choosingAnAppStoresItsNameUnderTheRightKeyAndChangesNothingElse() async throws {
            try await spWithHome { home in
                try acWriteSettings(home)
                let before = try acSettingsOnDisk(home)
                #expect(acOpenWith(before) == ["pdf": "Skim", "media": "IINA", "code": "Cursor"], "the starting file is wrong")
                let choices = AppChoices(lookup: ACFakeLookup(installed: Set(acAllOptions().map(\.option.bundleID))))

                try choices.choose(try acOption("media", "VLC"), for: "media")

                let after = try acSettingsOnDisk(home)
                #expect(acOpenWith(after) == ["pdf": "Skim", "media": "VLC", "code": "Cursor"],
                        "openWith is \(acOpenWith(after)); only media should have changed")
                #expect(acWithoutOpenWith(after) == acWithoutOpenWith(before),
                        "a key other than openWith changed: before \(acWithoutOpenWith(before)), after \(acWithoutOpenWith(after))")
            }
        }

        @MainActor
        @Test func eachOfTheTwoPickersWritesItsOwnKeyAndLeavesTheStoredCodeEditorAsFound() async throws {
            try await spWithHome { home in
                try acWriteSettings(home)
                let before = try acSettingsOnDisk(home)
                let choices = AppChoices(lookup: ACFakeLookup(installed: Set(acAllOptions().map(\.option.bundleID))))

                try choices.choose(try acOption("pdf", "Adobe Acrobat"), for: "pdf")
                #expect(acOpenWith(try acSettingsOnDisk(home)) == ["pdf": "Adobe Acrobat", "media": "IINA", "code": "Cursor"])

                try choices.choose(try acOption("media", "VLC"), for: "media")
                let after = try acSettingsOnDisk(home)
                #expect(acOpenWith(after) == ["pdf": "Adobe Acrobat", "media": "VLC", "code": "Cursor"])
                #expect(acWithoutOpenWith(after) == acWithoutOpenWith(before), "a key other than openWith changed")
            }
        }

        @MainActor
        @Test func choosingTheSameAppAgainAndSwitchingBackLeavesTheFileAsTheLastChoiceSaid() async throws {
            try await spWithHome { home in
                try acWriteSettings(home)
                let choices = AppChoices(lookup: ACFakeLookup(installed: Set(acAllOptions().map(\.option.bundleID))))
                try choices.choose(try acOption("pdf", "Preview"), for: "pdf")
                try choices.choose(try acOption("pdf", "Preview"), for: "pdf")
                #expect(acOpenWith(try acSettingsOnDisk(home))["pdf"] == "Preview")
                try choices.choose(try acOption("pdf", "Skim"), for: "pdf")
                #expect(acOpenWith(try acSettingsOnDisk(home))["pdf"] == "Skim")
            }
        }

        @MainActor
        @Test func savingAnAppThatIsNotInstalledIsAllowedAndTheNoteStaysForSettingsToShow() async throws {
            try await spWithHome { home in
                try acWriteSettings(home)
                let before = try acSettingsOnDisk(home)
                let choices = AppChoices(lookup: ACFakeLookup(installed: []))
                let iina = try acOption("media", "IINA")
                let vlc = try acOption("media", "VLC")

                try choices.choose(vlc, for: "media")

                let after = try acSettingsOnDisk(home)
                #expect(acOpenWith(after)["media"] == "VLC", "a not-installed choice was not stored: \(acOpenWith(after))")
                #expect(acOpenWith(after)["pdf"] == "Skim" && acOpenWith(after)["code"] == "Cursor")
                #expect(acWithoutOpenWith(after) == acWithoutOpenWith(before))
                #expect(choices.note(for: vlc) == "VLC is not installed. Enter opens the file in the default app.",
                        "note after saving: \(String(describing: choices.note(for: vlc)))")
                #expect(choices.note(for: iina) == "IINA is not installed. Enter opens the file in the default app.")
            }
        }

        @MainActor
        @Test func withNoSettingsFileAChoiceCreatesItAndWritesNothingElseInTheFolder() async throws {
            try await spWithHome { home in
                let file = acFolder(home).appendingPathComponent("settings.json")
                #expect(!FileManager.default.fileExists(atPath: file.path), "the test should start with no settings file")
                let namesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: acFolder(home).path))
                let choices = AppChoices(lookup: ACFakeLookup(installed: Set(acAllOptions().map(\.option.bundleID))))

                try choices.choose(try acOption("pdf", "Skim"), for: "pdf")

                #expect(acOpenWith(try acSettingsOnDisk(home))["pdf"] == "Skim")
                let namesAfter = Set(try FileManager.default.contentsOfDirectory(atPath: acFolder(home).path))
                #expect(namesAfter.subtracting(namesBefore) == ["settings.json"], "new entries in the Sesame folder: \(namesAfter.subtracting(namesBefore))")
            }
        }

        @MainActor
        @Test func theStoredValueReadsBackThroughSettingsFileAsTheDesignKeyOpenWith() async throws {
            try await spWithHome { home in
                try acWriteSettings(home)
                let choices = AppChoices(lookup: ACFakeLookup(installed: []))
                try choices.choose(try acOption("media", "QuickTime Player"), for: "media")

                // read the way the rest of the app reads settings: SettingsFile, then its JSON form
                let value = try SettingsFile().read()
                let data = try JSONEncoder().encode(value)
                let object = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
                #expect(acOpenWith(object) == ["pdf": "Skim", "media": "QuickTime Player", "code": "Cursor"],
                        "SettingsFile reads openWith as \(acOpenWith(object))")
            }
        }
    }
}
