import Foundation
import Testing

struct AboutPlant: Sendable {
    let kind: String
    let line: String
}

enum AboutScan {
    static let settingsDirectory = "Sources/Sesame/Settings/"
    static let settingsWindow = "Sources/Sesame/Settings/SettingsWindow.swift"
    static let aboutViewFile = "Sources/Sesame/Settings/" + "Settings" + "AboutView.swift"
    static let setupWindow = "Sources/Sesame/Setup/SetupWindow.swift"
    static let setupViews = "Sources/Sesame/Setup/SetupViews.swift"
    static let setupFlow = "Sources/Sesame/Setup/SetupFlow.swift"
    static let neverAsked = "never" + "AskedLine"

    static let tokens: [(kind: String, text: String)] = [
        ("view-type", "Settings" + "AboutView"),
        ("heading", "about" + "Heading"),
        ("version-property", "version" + "Text"),
        ("version-literal", "Version " + "0.1"),
        ("build-literal", "local " + "build"),
        ("symbol", "info." + "circle"),
        ("view-property", "about" + "View"),
    ]

    static let casePattern = #"\bcase\s+(?:\.?[A-Za-z]+,\s*)*\.?ab"# + "out" + #"\b"#

    static let plants: [AboutPlant] = [
        AboutPlant(kind: "view-type", line: "let planted = Settings" + "AboutView()"),
        AboutPlant(kind: "heading", line: "static let planted = SettingsScreen.about" + "Heading"),
        AboutPlant(kind: "version-property", line: "let planted = SettingsScreen.version" + "Text"),
        AboutPlant(kind: "version-literal", line: "let planted = \"Version " + "0.1, a build\""),
        AboutPlant(kind: "build-literal", line: "let planted = \"a local " + "build\""),
        AboutPlant(kind: "symbol", line: "let planted = \"info." + "circle\""),
        AboutPlant(kind: "view-property", line: "private let planted = about" + "View"),
        AboutPlant(kind: "case-about", line: "enum Planted { case folders, search, ab" + "out }"),
        AboutPlant(kind: "case-about", line: "func planted(_ s: Int) -> Int { switch s { case .ab" + "out: return 1 } }"),
    ]

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func violations(in root: URL) -> [String] {
        var out: [String] = []
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.appendingPathComponent(aboutViewFile).path) {
            out.append("exists: \(aboutViewFile)")
        }
        let sources = root.appendingPathComponent("Sources")
        let names = (try? fileManager.subpathsOfDirectory(atPath: sources.path)) ?? []
        for name in names.sorted() {
            let relative = "Sources/" + name
            var isDirectory: ObjCBool = false
            let path = root.appendingPathComponent(relative).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for token in tokens where text.contains(token.text) {
                out.append("\(token.kind): \(relative)")
            }
            if text.range(of: casePattern, options: .regularExpression) != nil {
                out.append("case-about: \(relative)")
            }
            if relative.hasPrefix(settingsDirectory), text.contains(neverAsked) {
                out.append("settings-never-asked: \(relative)")
            }
        }
        for relative in [setupWindow, setupViews] {
            let text = (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
            if !text.contains(neverAsked) { out.append("setup-line-missing: \(relative)") }
        }
        return out
    }

    static let baseFiles: [String: String] = [
        settingsWindow: "struct SettingsScreen {}\n",
        setupWindow: "let note = SetupFlow." + neverAsked + "\n",
        setupViews: "let note = SetupFlow." + neverAsked + "\n",
        setupFlow: "static let " + neverAsked + " = \"x\"\n",
    ]

    static func plant(_ changes: [String: String?]) throws -> [String] {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("about-guard-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        var files = baseFiles
        for (relative, text) in changes { files[relative] = text }
        for (relative, text) in files {
            let url = root.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return violations(in: root)
    }
}

@Suite("AboutRemovedGuardTests")
struct AboutRemovedGuardTests {

    @Test func theSourcesHoldNoAboutViewNoAboutCaseNoVersionTextNoInfoSymbolAndNoNeverAskedLineInSettingsWhileTheSetupFilesKeepTheLine() {
        #expect(AboutScan.violations(in: AboutScan.repoRoot()) == [])
    }

    @Test func aTreeWithTheLineInBothSetupFilesAndNothingAboutAboutPasses() throws {
        #expect(try AboutScan.plant([:]) == [])
    }

    @Test func theAboutViewFileFailsTheScanWhateverItHolds() throws {
        let found = try AboutScan.plant([AboutScan.aboutViewFile: "final class Planted {}\n"])
        #expect(found == ["exists: \(AboutScan.aboutViewFile)"])
    }

    @Test(arguments: AboutScan.plants)
    func aPlantedLineInTheSettingsWindowFailsTheScanWithItsOwnKind(plant: AboutPlant) throws {
        let found = try AboutScan.plant([AboutScan.settingsWindow: plant.line + "\n"])
        #expect(found.contains("\(plant.kind): \(AboutScan.settingsWindow)"), "found \(found) for \(plant.line)")
    }

    @Test(arguments: AboutScan.plants)
    func aPlantedLineInAnotherSourceFileFailsTheScanToo(plant: AboutPlant) throws {
        let found = try AboutScan.plant([AboutScan.setupFlow: AboutScan.baseFiles[AboutScan.setupFlow, default: ""] + plant.line + "\n"])
        #expect(found.contains("\(plant.kind): \(AboutScan.setupFlow)"), "found \(found) for \(plant.line)")
    }

    @Test func theNeverAskedLineInAFileOfTheSettingsFolderFailsTheScan() throws {
        let found = try AboutScan.plant([AboutScan.settingsWindow: "let planted = SetupFlow." + AboutScan.neverAsked + "\n"])
        #expect(found == ["settings-never-asked: \(AboutScan.settingsWindow)"])
    }

    @Test func theNeverAskedLineInANewFileOfTheSettingsFolderFailsTheScan() throws {
        let path = AboutScan.settingsDirectory + "SettingsNote.swift"
        let found = try AboutScan.plant([path: "let planted = SetupFlow." + AboutScan.neverAsked + "\n"])
        #expect(found == ["settings-never-asked: \(path)"])
    }

    @Test func theNeverAskedLineOutsideTheSettingsFolderPasses() throws {
        let found = try AboutScan.plant(["Sources/Sesame/Setup/SetupExtra.swift": "let planted = SetupFlow." + AboutScan.neverAsked + "\n"])
        #expect(found == [])
    }

    @Test func aSetupWindowWithoutTheNeverAskedLineFailsTheScan() throws {
        let found = try AboutScan.plant([AboutScan.setupWindow: "let note = 1\n"])
        #expect(found == ["setup-line-missing: \(AboutScan.setupWindow)"])
    }

    @Test func aSetupViewsFileWithoutTheNeverAskedLineFailsTheScan() throws {
        let found = try AboutScan.plant([AboutScan.setupViews: "let note = 1\n"])
        #expect(found == ["setup-line-missing: \(AboutScan.setupViews)"])
    }

    @Test func aMissingSetupWindowFailsTheScan() throws {
        let found = try AboutScan.plant([AboutScan.setupWindow: nil])
        #expect(found == ["setup-line-missing: \(AboutScan.setupWindow)"])
    }

    @Test func theWordAboutInProseAndInTheSetupTotalLineDoesNotFailTheScan() throws {
        let found = try AboutScan.plant([
            "Sources/Sesame/Setup/SetupExtra.swift": "let total = \"About 5 min in total\"\n// what a case is about\nlet estimate = \"about 2 min\"\n",
        ])
        #expect(found == [])
    }
}
