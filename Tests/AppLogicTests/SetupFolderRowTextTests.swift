import AppKit
import CryptoKit
import Foundation
import Testing
@testable import SesameEngine
@testable import Sesame

private final class SFRGate: @unchecked Sendable {
    private let cond = NSCondition()
    private var held = true

    func release() { cond.lock(); held = false; cond.broadcast(); cond.unlock() }

    func enter() {
        cond.lock()
        while held { cond.wait() }
        cond.unlock()
    }
}

private struct SFREnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    func path(_ name: String) -> String { home.appendingPathComponent(name).path }

    func dir(_ name: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
    }
}

@MainActor
private func sfrRun(_ body: (SFREnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-folderrowtext-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = SFREnv(home: base.resolvingSymlinksInPath())
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
    try fm.createDirectory(at: env.models, withIntermediateDirectories: true)
    try await body(env)
}

@MainActor
private func sfrEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func sfrReady(_ folders: SetupFolders) async -> Bool {
    await sfrEventually { folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
}

@MainActor
private func sfrModel(_ env: SFREnv, whole: Bool) throws -> SetupModel {
    if whole {
        let data = Data(repeating: 9, count: 1_000)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = ModelFile(name: "sfr-whole.gguf", size: 1_000, sha256: hex)
        try data.write(to: env.models.appendingPathComponent(file.name))
        let model = SetupModel(files: [file])
        model.refresh()
        return model
    }
    let a = ModelFile(name: "sfr-a.gguf", size: 80_000_000, sha256: String(repeating: "0", count: 64))
    let b = ModelFile(name: "sfr-b.gguf", size: 40_000_000, sha256: String(repeating: "0", count: 64))
    let partial = env.models.appendingPathComponent(a.name + ".partial")
    FileManager.default.createFile(atPath: partial.path, contents: nil)
    let handle = try FileHandle(forWritingTo: partial)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 20_000_000)
    let model = SetupModel(files: [a, b])
    model.refresh()
    return model
}

@MainActor
private func sfrFolders(
    _ counts: [String: [String: Int]],
    in env: SFREnv,
    speeds: [String: Double] = ["photo": 3.0],
    modelWhole: Bool = true,
    gate: SFRGate? = nil,
    picks: [String] = []
) throws -> SetupFolders {
    for name in counts.keys { try env.dir(name) }
    let urls = picks.map { env.home.appendingPathComponent($0, isDirectory: true) }
    let kinds = ["photo", "pdf", "doc", "audio", "video", "code"]
    let folders = SetupFolders(
        home: env.home,
        counter: { paths in
            gate?.enter()
            var perFolder: [String: [String: Int]] = [:]
            for path in paths { perFolder[path] = counts[(path as NSString).lastPathComponent] ?? [:] }
            var summary: [String: Int] = [:]
            for kindCounts in perFolder.values { summary.merge(kindCounts, uniquingKeysWith: +) }
            return FolderCounts(perFolder: perFolder, summary: summary, total: summary.values.reduce(0, +), unreadable: [])
        },
        picker: { urls },
        speeds: { speeds },
        kindsOn: { Dictionary(uniqueKeysWithValues: kinds.map { ($0, true) }) },
        modelWhole: { modelWhole })
    if !picks.isEmpty { folders.addFolder() }
    return folders
}

@MainActor
private func sfrScreen(_ model: SetupModel, _ folders: SetupFolders) -> SetupScreen {
    var flow = SetupFlow()
    while flow.step != .folders && flow.canGoNext { flow.next() }
    return SetupScreen(flow: flow, model: model, folders: folders)
}

private let sfrDefaultCounts: [String: [String: Int]] = [
    "Desktop": ["doc": 3], "Documents": ["pdf": 2], "Pictures": ["photo": 100],
]

private let sfrReadNote = "Photos, PDFs, documents, audio and video are read."
private let sfrHint = "Indexing starts when you press Start indexing, and runs in the background."

private let sfrSettingsJSON = """
{
  "version": 3,
  "startPressed": false,
  "indexDeleted": false,
  "folders": [{"path": "%PATH%", "code": false, "reading": true}],
  "codeSearchOn": false,
  "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
  "hotkey": "cmd+opt+k",
  "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
  "speeds": {"photo": 3.0},
  "loginDefaultApplied": true
}
"""

private let sfrEstimateWords = ["about", "min", "measuring", "after the model", "nothing to read", "speed"]

extension ModelDownloadTests {
    @Suite("SetupFolderRowTextTests", .serialized)
    struct SetupFolderRowTextTests {

        @MainActor
        @Test func fileCountTextWritesTheNumberWithACommaAtEveryThousand() {
            let table: [(number: Int, text: String)] = [
                (0, "0"), (7, "7"), (999, "999"), (1_000, "1,000"), (4_233, "4,233"), (1_234_567, "1,234,567"),
            ]
            for entry in table {
                #expect(SetupScreen.fileCountText(entry.number) == entry.text, "\(entry.number) reads \"\(SetupScreen.fileCountText(entry.number))\"")
            }
        }

        @MainActor
        @Test func aReadyRowCountIsTheSumOfAllItsKindsAndItsTooltipIsTheBreakdown() async throws {
            try await sfrRun { env in
                let counts: [String: [String: Int]] = [
                    "Desktop": [:], "Documents": ["pdf": 3], "Pictures": ["photo": 100],
                    "Mixed": ["photo": 100, "pdf": 3], "One": ["photo": 1], "Large": ["photo": 1_000], "Huge": ["doc": 1_234_567],
                ]
                let folders = try sfrFolders(counts, in: env, picks: ["Mixed", "One", "Large", "Huge"])
                #expect(await sfrReady(folders))
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)

                let table: [(name: String, count: String, tooltip: String?)] = [
                    ("Desktop", "0", "no files"),
                    ("Documents", "3", "3 PDFs"),
                    ("Pictures", "100", "100 photos"),
                    ("Mixed", "103", "100 photos, 3 PDFs"),
                    ("One", "1", "1 photo"),
                    ("Large", "1,000", nil),
                    ("Huge", "1,234,567", nil),
                ]
                for entry in table {
                    let row = try #require(screen.rows.first { $0.name == entry.name }, "no row \(entry.name) in \(screen.rows.map { $0.name })")
                    #expect(row.count == entry.count, "\(entry.name): count \"\(row.count)\", want \"\(entry.count)\"")
                    if let tooltip = entry.tooltip {
                        #expect(row.tooltip == tooltip, "\(entry.name): tooltip \"\(row.tooltip)\", want \"\(tooltip)\"")
                    }
                    #expect(screen.texts.contains("\(entry.name): \(entry.count)"), "no text \"\(entry.name): \(entry.count)\" in \(screen.texts)")
                }
            }
        }

        @MainActor
        @Test func aRowThatWasCountedAndThenUntickedKeepsItsFigureAndBreakdown() async throws {
            try await sfrRun { env in
                let folders = try sfrFolders(sfrDefaultCounts, in: env)
                #expect(await sfrReady(folders))
                folders.setTicked(env.path("Pictures"), false)
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)
                let row = try #require(screen.rows.first { $0.name == "Pictures" })
                #expect(!row.ticked)
                #expect(row.count == "100", "count \"\(row.count)\"")
                #expect(row.tooltip == "100 photos", "tooltip \"\(row.tooltip)\"")
            }
        }

        @MainActor
        @Test func aRowBeingCountedReadsCountingInTheCountTheTooltipTheLabelAndTheTextWithNoEllipsisAndNoEstimate() async throws {
            try await sfrRun { env in
                let gate = SFRGate()
                defer { gate.release() }
                let folders = try sfrFolders(sfrDefaultCounts, in: env, gate: gate)
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)

                for name in ["Desktop", "Documents", "Pictures"] {
                    let row = try #require(screen.rows.first { $0.name == name })
                    #expect(row.ticked)
                    #expect(row.count == "counting", "\(name): count \"\(row.count)\"")
                    #expect(row.tooltip == "counting", "\(name): tooltip \"\(row.tooltip)\"")
                    #expect(row.label == "\(name), counting", "\(name): label \"\(row.label)\"")
                    #expect(screen.texts.contains("\(name): counting"), "no text \"\(name): counting\" in \(screen.texts)")
                }
                #expect(screen.texts.count > 2 && screen.texts[2] == "Counting files\u{2026}", "summary: \(screen.texts)")
                #expect(!screen.texts.contains { $0.hasSuffix(" in total") }, "a total while counting: \(screen.texts)")

                gate.release()
                #expect(await sfrReady(folders))
                let after = sfrScreen(try sfrModel(env, whole: true), folders)
                #expect(after.rows.first { $0.name == "Pictures" }?.count == "100")
            }
        }

        @MainActor
        @Test func aMissingFolderReadsNotFoundInTheCountTheTooltipTheLabelAndTheText() async throws {
            try await sfrRun { env in
                let folders = try sfrFolders(sfrDefaultCounts, in: env)
                #expect(await sfrReady(folders))
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)
                for name in ["Downloads", "Movies"] {
                    let row = try #require(screen.rows.first { $0.name == name }, "no row \(name) in \(screen.rows.map { $0.name })")
                    #expect(row.count == "not found", "\(name): count \"\(row.count)\"")
                    #expect(row.tooltip == "not found", "\(name): tooltip \"\(row.tooltip)\"")
                    #expect(row.label == "\(name), not found", "\(name): label \"\(row.label)\"")
                    #expect(screen.texts.contains("\(name): not found"), "no text \"\(name): not found\" in \(screen.texts)")
                }
            }
        }

        @MainActor
        @Test func anUntickedRowThatWasNeverCountedHasNoCountATooltipOfNotCountedAndATextOfJustItsName() async throws {
            try await sfrRun { env in
                let counts: [String: [String: Int]] = ["Desktop": ["doc": 3], "Trips": ["photo": 2]]
                try env.dir("Trips")
                let json = sfrSettingsJSON.replacingOccurrences(of: "%PATH%", with: env.path("Trips"))
                try SettingsFile().write(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)))
                let folders = try sfrFolders(counts, in: env)
                #expect(await sfrReady(folders))
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)

                let desktop = try #require(screen.rows.first { $0.name == "Desktop" }, "no Desktop row in \(screen.rows.map { $0.name })")
                #expect(!desktop.ticked, "Desktop is ticked")
                #expect(desktop.count == "", "count \"\(desktop.count)\"")
                #expect(desktop.tooltip == "not counted", "tooltip \"\(desktop.tooltip)\"")
                #expect(desktop.label == "Desktop, not counted", "label \"\(desktop.label)\"")
                #expect(screen.texts.contains("Desktop"), "no text \"Desktop\" in \(screen.texts)")
                #expect(!screen.texts.contains { $0.hasPrefix("Desktop:") }, "a colon text for Desktop in \(screen.texts)")
                let trips = try #require(screen.rows.first { $0.name == "Trips" })
                #expect(trips.count == "2", "Trips count \"\(trips.count)\"")
            }
        }

        @MainActor
        @Test func noCountAndNoTooltipHoldsAnEstimateAndTheEstimateStaysInTheLabelOnly() async throws {
            let configs: [(name: String, speeds: [String: Double], whole: Bool, suffix: String)] = [
                ("whole model, speed known", ["photo": 3.0], true, ", about 5 min"),
                ("whole model, no speed", [:], true, ", measuring speed"),
                ("model not whole", ["photo": 3.0], false, ", after the model download"),
            ]
            for config in configs {
                try await sfrRun { env in
                    let folders = try sfrFolders(sfrDefaultCounts, in: env, speeds: config.speeds, modelWhole: config.whole)
                    #expect(await sfrReady(folders))
                    let screen = sfrScreen(try sfrModel(env, whole: config.whole), folders)
                    #expect(screen.rows.count >= 5, "\(config.name): rows \(screen.rows.map { $0.name })")
                    for row in screen.rows {
                        for word in sfrEstimateWords {
                            #expect(!row.count.lowercased().contains(word), "\(config.name) / \(row.name): count \"\(row.count)\" holds \"\(word)\"")
                            #expect(!row.tooltip.lowercased().contains(word), "\(config.name) / \(row.name): tooltip \"\(row.tooltip)\" holds \"\(word)\"")
                        }
                    }
                    let pictures = try #require(screen.rows.first { $0.name == "Pictures" })
                    #expect(pictures.count == "100", "\(config.name): count \"\(pictures.count)\"")
                    #expect(pictures.tooltip == "100 photos", "\(config.name): tooltip \"\(pictures.tooltip)\"")
                    #expect(pictures.label.hasPrefix("Pictures, 100 photos"), "\(config.name): label \"\(pictures.label)\"")
                    #expect(pictures.label.hasSuffix(config.suffix), "\(config.name): label \"\(pictures.label)\" does not end with \"\(config.suffix)\"")
                }
            }
        }

        @MainActor
        @Test func theRowLabelsAndTheCheckboxControlsKeepTheirTextOrderAndEnabledFlags() async throws {
            try await sfrRun { env in
                let folders = try sfrFolders(sfrDefaultCounts, in: env)
                #expect(await sfrReady(folders))
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)

                let labels = screen.controls.prefix(5).map { $0.label }
                #expect(labels.count == 5)
                #expect(labels[0].hasPrefix("Desktop, 3 documents, "), "label \"\(labels[0])\"")
                #expect(labels[1].hasPrefix("Documents, 2 PDFs, "), "label \"\(labels[1])\"")
                #expect(labels[2] == "Downloads, not found", "label \"\(labels[2])\"")
                #expect(labels[3] == "Pictures, 100 photos, about 5 min", "label \"\(labels[3])\"")
                #expect(labels[4] == "Movies, not found", "label \"\(labels[4])\"")
                #expect(screen.controls.prefix(5).map { $0.isEnabled } == [true, true, false, true, false],
                        "enabled flags \(screen.controls.prefix(5).map { $0.isEnabled })")
            }
        }

        @MainActor
        @Test func theSummaryReadsNFilesInMFoldersWithTheThousandsCommaAndTheOldTwoStates() async throws {
            let cases: [(name: String, counts: [String: [String: Int]], summary: String)] = [
                ("one file in one folder", ["Pictures": ["photo": 1]], "1 file in 1 folder"),
                ("five files in one folder", ["Pictures": ["photo": 5]], "5 files in 1 folder"),
                ("one file in two folders", ["Desktop": ["doc": 1], "Documents": [:]], "1 file in 2 folders"),
                ("three folders", sfrDefaultCounts, "105 files in 3 folders"),
                ("four folders over a thousand", [
                    "Desktop": ["doc": 310], "Documents": ["pdf": 1_000], "Downloads": ["doc": 5_000], "Pictures": ["photo": 10_000],
                ], "16,310 files in 4 folders"),
            ]
            for entry in cases {
                try await sfrRun { env in
                    let folders = try sfrFolders(entry.counts, in: env)
                    #expect(await sfrReady(folders))
                    let screen = sfrScreen(try sfrModel(env, whole: true), folders)
                    #expect(screen.texts.count > 2, "\(entry.name): texts \(screen.texts)")
                    #expect(screen.texts.count > 2 && screen.texts[2] == entry.summary, "\(entry.name): summary \"\(screen.texts.count > 2 ? screen.texts[2] : "none")\", want \"\(entry.summary)\"")
                }
            }
            try await sfrRun { env in
                let folders = try sfrFolders(sfrDefaultCounts, in: env)
                #expect(await sfrReady(folders))
                for name in ["Desktop", "Documents", "Pictures"] { folders.setTicked(env.path(name), false) }
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)
                #expect(screen.texts.count > 2 && screen.texts[2] == "Nothing will be indexed.", "none ticked: \(screen.texts)")
            }
        }

        @MainActor
        @Test func theFoldersTextsAreTheStepTheHeadingTheSummaryTheTotalTheRowTextsTheHintAndTheReadNoteInThatOrder() async throws {
            let rowTexts = ["Desktop: 3", "Documents: 2", "Downloads: not found", "Pictures: 100", "Movies: not found"]
            let head = ["Step 2 of 4: Folders", "Folders to read", "105 files in 3 folders"]

            try await sfrRun { env in
                let folders = try sfrFolders(sfrDefaultCounts, in: env)
                #expect(await sfrReady(folders))
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)
                #expect(screen.texts == head + ["About 5 min in total"] + rowTexts + [sfrHint, sfrReadNote, "Search model ready"], "texts \(screen.texts)")
            }
            try await sfrRun { env in
                let folders = try sfrFolders(sfrDefaultCounts, in: env, speeds: [:])
                #expect(await sfrReady(folders))
                let screen = sfrScreen(try sfrModel(env, whole: true), folders)
                #expect(screen.texts == head + rowTexts + [sfrHint, sfrReadNote, "Search model ready"], "no total expected, texts \(screen.texts)")
            }
            try await sfrRun { env in
                let folders = try sfrFolders(sfrDefaultCounts, in: env, modelWhole: false)
                #expect(await sfrReady(folders))
                let screen = sfrScreen(try sfrModel(env, whole: false), folders)
                let expected = head + rowTexts + [sfrReadNote]
                #expect(Array(screen.texts.prefix(expected.count)) == expected, "no total expected, texts \(screen.texts)")
                #expect(!screen.texts.contains { $0.hasSuffix(" in total") }, "a total before the model download: \(screen.texts)")
            }
        }

        @MainActor
        @Test func noFoldersTextHoldsThePerPhotoNoteMeasuringSpeedOrAnEstimateExceptTheTotalLine() async throws {
            let configs: [(name: String, speeds: [String: Double], whole: Bool)] = [
                ("whole model, speed known", ["photo": 3.0], true),
                ("whole model, no speed", [:], true),
                ("model not whole", ["photo": 3.0], false),
            ]
            for config in configs {
                try await sfrRun { env in
                    let folders = try sfrFolders(sfrDefaultCounts, in: env, speeds: config.speeds, modelWhole: config.whole)
                    #expect(await sfrReady(folders))
                    let screen = sfrScreen(try sfrModel(env, whole: config.whole), folders)
                    for phrase in ["Photos: about", "measuring speed", "after the model download", "nothing to read"] {
                        #expect(!screen.texts.contains { $0.contains(phrase) }, "\(config.name): a text holds \"\(phrase)\": \(screen.texts)")
                    }
                    let estimates = screen.texts.filter { $0.lowercased().contains("about") }
                    #expect(estimates.allSatisfy { $0.hasSuffix(" in total") }, "\(config.name): estimate texts \(estimates)")
                }
            }
        }
    }
}
