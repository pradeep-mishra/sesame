import AppKit
import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let sncKindsOnAll: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]
private let sncOldKindsOn: [String: Bool] = ["photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true]
private let sncOldOpenWith: [String: String] = ["pdf": "Preview", "media": "QuickTime Player", "code": "Zed"]
private let sncOldSpeeds: [String: Double] = ["photo": 1.5, "pdf": 2.25, "code": 3.5]

private let sncStubScript = #"""
#!/bin/sh
dir=$(dirname "$0")
mode="$1"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$dir/$mode.lines"
done
"""#

private final class SNCBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private struct SNCEnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

    func dir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func files(_ relative: String, _ names: [String]) throws -> URL {
        let url = try dir(relative)
        for name in names { try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent(name)) }
        return url
    }

    func photos(_ relative: String, count: Int) throws -> URL {
        try files(relative, (0..<count).map { "photo-\($0).\($0 % 2 == 0 ? "jpg" : "png")" })
    }

    func repo(_ relative: String, asFile: Bool = false) throws -> URL {
        let url = try dir(relative)
        let entry = url.appendingPathComponent(".git")
        if asFile { try Data("gitdir: /nonexistent\n".utf8).write(to: entry) }
        else { try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true) }
        return url
    }

    func path(_ name: String) -> String { home.appendingPathComponent(name).path }

    func settingsDictionary() -> NSDictionary? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    func entry(_ path: String) -> NSDictionary? {
        ((settingsDictionary()?["folders"] as? [NSDictionary]) ?? []).first { ($0["path"] as? String) == path }
    }

    func writeSettings(_ json: String) throws {
        try SettingsFile().write(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)))
    }

    func helperLines(_ mode: String) -> [String] {
        guard let text = try? String(contentsOf: home.appendingPathComponent(mode + ".lines"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

@MainActor
private func sncRun(_ body: (SNCEnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-snc-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = SNCEnv(home: base.resolvingSymlinksInPath())
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
private func sncEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func sncReady(_ folders: SetupFolders) async -> Bool {
    await sncEventually { folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
}

private func sncModelFiles(_ env: SNCEnv, whole: Bool) throws -> [ModelFile] {
    if whole {
        let data = Data(repeating: 9, count: 280_000)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = ModelFile(name: "snc-whole.gguf", size: data.count, sha256: hash)
        try data.write(to: env.models.appendingPathComponent(file.name))
        return [file]
    }
    let a = ModelFile(name: "snc-a.gguf", size: 80_000_000, sha256: String(repeating: "0", count: 64))
    let b = ModelFile(name: "snc-b.gguf", size: 40_000_000, sha256: String(repeating: "0", count: 64))
    let partial = env.models.appendingPathComponent(a.name + ".partial")
    FileManager.default.createFile(atPath: partial.path, contents: nil)
    let handle = try FileHandle(forWritingTo: partial)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 20_000_000)
    return [a, b]
}

@MainActor
private func sncModel(_ files: [ModelFile]) -> SetupModel {
    let model = SetupModel(files: files)
    model.refresh()
    return model
}

@MainActor
private func sncFolders(
    _ env: SNCEnv,
    speeds: [String: Double] = ["photo": 3.0],
    whole: Bool = true,
    picks: SNCBox<[URL]> = SNCBox([])
) -> SetupFolders {
    SetupFolders(
        home: env.home,
        picker: { picks.value },
        speeds: { speeds },
        kindsOn: { sncKindsOnAll },
        modelWhole: { whole })
}

private func sncFlow(at step: SetupFlow.Step) -> SetupFlow {
    var flow = SetupFlow()
    while flow.step != step && flow.canGoNext { flow.next() }
    return flow
}

private let sncSteps: [(title: String, step: SetupFlow.Step)] = [
    ("Welcome", .welcome), ("Folders", .folders), ("Permissions", .permissions), ("Shortcut", .shortcut),
]

private func sncStrings(_ screen: SetupScreen) -> [String] {
    screen.texts + screen.controls.map { $0.label } + screen.buttons.map { $0.title }
}

@MainActor
private func sncClient(_ env: SNCEnv) throws -> HelperClient {
    let stub = env.home.appendingPathComponent("snc-stub-helper")
    try sncStubScript.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    return HelperClient(helper: stub, textModel: env.home, mmModel: env.home)
}

@MainActor
private func sncStatus() -> StatusCache {
    let sources = StatusSources(
        settings: { Settings() },
        counts: { IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 0) },
        meta: { _ in nil },
        modelState: { .whole })
    return StatusCache(sources: sources, queue: DispatchQueue(label: "sesame.snc.test.status", qos: .utility))
}

@MainActor
private func sncWindow(_ env: SNCEnv, files: [ModelFile], folders: SetupFolders) throws -> SetupWindow {
    let window = SetupWindow(files: files, folders: folders, helper: try sncClient(env), status: sncStatus())
    window.isReleasedWhenClosed = false
    window.refresh()
    return window
}

@MainActor
private func sncButton(_ title: String, in window: NSWindow) -> NSButton? {
    guard let root = window.contentView else { return nil }
    return prViews(root).compactMap { $0 as? NSButton }
        .filter { !$0.isHiddenOrHasHiddenAncestor }
        .first { $0.title == title || $0.accessibilityLabel() == title }
}

@MainActor
@discardableResult
private func sncPress(_ title: String, in window: NSWindow) async -> Bool {
    guard let button = sncButton(title, in: window), button.isEnabled else { return false }
    button.performClick(nil)
    await Task.yield()
    return true
}

@MainActor
@discardableResult
private func sncWalk(_ window: SetupWindow, to step: SetupFlow.Step) async -> Bool {
    while window.flow.step != step {
        if await sncPress("Next", in: window) { continue }
        guard await sncPress("Not now", in: window) else { return false }
    }
    window.refresh()
    return true
}

@MainActor
private func sncKeyLoop(_ window: NSWindow) -> (visited: [NSView], closed: Bool, started: Bool) {
    guard let start = window.initialFirstResponder else { return ([], false, false) }
    var visited = [start]
    var next = start.nextValidKeyView
    while let current = next, current !== start, visited.count < 500 {
        visited.append(current)
        next = current.nextValidKeyView
    }
    return (visited, visited.count == 1 || next === start, true)
}

@MainActor
private func sncReads(_ view: NSView) -> [String] {
    var out: [String] = []
    if let title = view.accessibilityTitle(), !title.isEmpty { out.append(title) }
    if let label = view.accessibilityLabel(), !label.isEmpty { out.append(label) }
    if let help = view.accessibilityHelp(), !help.isEmpty { out.append(help) }
    if let button = view as? NSButton, !button.title.isEmpty { out.append(button.title) }
    if let field = view as? NSTextField, !field.stringValue.isEmpty { out.append(field.stringValue) }
    return out
}

private func sncOldSettingsJSON(folders: [String], ticked: Bool?, codeSearchOn: Bool, startPressed: Bool = false) -> String {
    let tick = ticked.map { ", \"ticked\": \($0)" } ?? ""
    let entries = folders.map { "{\"path\": \"\($0)\", \"code\": true, \"reading\": false\(tick)}" }.joined(separator: ", ")
    return """
    {
      "version": 3,
      "startPressed": \(startPressed),
      "indexDeleted": false,
      "folders": [\(entries)],
      "codeSearchOn": \(codeSearchOn),
      "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
      "hotkey": "cmd+opt+k",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "Zed"},
      "speeds": {"photo": 1.5, "pdf": 2.25, "code": 3.5},
      "loginDefaultApplied": true
    }
    """
}

private func sncExpectOldValuesKept(_ after: NSDictionary?, codeSearchOn: Bool, _ context: String) {
    #expect(after?["codeSearchOn"] as? Bool == codeSearchOn, "\(context): codeSearchOn is \(String(describing: after?["codeSearchOn"]))")
    #expect(after?["kindsOn"] as? [String: Bool] == sncOldKindsOn, "\(context): kindsOn is \(String(describing: after?["kindsOn"]))")
    #expect(after?["openWith"] as? [String: String] == sncOldOpenWith, "\(context): openWith is \(String(describing: after?["openWith"]))")
    #expect(after?["speeds"] as? [String: Double] == sncOldSpeeds, "\(context): speeds is \(String(describing: after?["speeds"]))")
    #expect(after?["hotkey"] as? String == "cmd+opt+k", "\(context): hotkey is \(String(describing: after?["hotkey"]))")
    #expect(after?["version"] as? Int == 3, "\(context): version is \(String(describing: after?["version"]))")
    #expect(after?["loginDefaultApplied"] as? Bool == true, "\(context): loginDefaultApplied is \(String(describing: after?["loginDefaultApplied"]))")
}

extension ModelDownloadTests {
    @Suite("SetupNoCodeTests", .serialized)
    struct SetupNoCodeTests {

        @MainActor
        @Test func noStepOfSetupHoldsTheWordCodeInAnyTextOrControlWhateverTheModelIsDoing() async throws {
            for whole in [true, false] {
                try await sncRun { env in
                    _ = try env.photos("Pictures", count: 4)
                    _ = try env.files("Desktop", ["a.txt"])
                    _ = try env.repo("Developer/api-client")
                    _ = try env.repo("Developer/legacy-sync", asFile: true)
                    _ = try env.repo("Developer/tools/scratch-lab")
                    let model = sncModel(try sncModelFiles(env, whole: whole))
                    let folders = sncFolders(env, whole: whole)
                    #expect(await sncReady(folders), "model whole \(whole): the rows never became ready")

                    for (title, step) in sncSteps {
                        let screen = SetupScreen(flow: sncFlow(at: step), model: model, folders: folders)
                        let where_ = "model whole \(whole) / \(title)"
                        let strings = sncStrings(screen)
                        #expect(!screen.texts.isEmpty, "\(where_): the step holds no text")
                        #expect(!strings.contains { $0.lowercased().contains("code") }, "\(where_): a text or control names code: \(strings.filter { $0.lowercased().contains("code") })")
                        #expect(!strings.contains("Search my code"), "\(where_): the code switch is there")
                        #expect(!strings.contains { $0.hasSuffix(", code folder") }, "\(where_): a code folder row is there: \(strings.filter { $0.hasSuffix(", code folder") })")
                        #expect(!strings.contains { $0.lowercased() == "code folders" }, "\(where_): the Code folders heading is there")
                    }
                }
            }
        }

        @MainActor
        @Test func theReadNoteNamesTheFiveKindsAndSaysNothingOfCodeOnTheFoldersStepOnly() async throws {
            #expect(SetupFolders.readNote == "Photos, PDFs, documents, audio and video are read.")
            try await sncRun { env in
                _ = try env.photos("Pictures", count: 2)
                let model = sncModel(try sncModelFiles(env, whole: true))
                let folders = sncFolders(env)
                #expect(await sncReady(folders))
                for (title, step) in sncSteps {
                    let screen = SetupScreen(flow: sncFlow(at: step), model: model, folders: folders)
                    let count = screen.texts.filter { $0 == "Photos, PDFs, documents, audio and video are read." }.count
                    #expect(count == (step == .folders ? 1 : 0), "\(title): the read note is shown \(count) times in \(screen.texts)")
                }
            }
        }

        @MainActor
        @Test func withThreeReposUnderDeveloperTheFolderListShowsTheFiveSuggestedFoldersOnly() async throws {
            let settingsVariants: [(name: String, old: Bool)] = [("default settings", false), ("old settings with the code switch on", true)]
            for variant in settingsVariants {
                try await sncRun { env in
                    _ = try env.photos("Pictures", count: 3)
                    let apiClient = try env.repo("Developer/api-client")
                    _ = try env.repo("Developer/legacy-sync", asFile: true)
                    _ = try env.repo("Developer/tools/scratch-lab")
                    if variant.old {
                        try env.writeSettings(sncOldSettingsJSON(folders: [env.path("Pictures")], ticked: true, codeSearchOn: true))
                    }
                    let files = try sncModelFiles(env, whole: true)
                    let folders = sncFolders(env)
                    #expect(await sncReady(folders), "\(variant.name): the rows never became ready")

                    #expect(folders.rows.count == 5 && Set(folders.rows.map { $0.name }) == ["Desktop", "Documents", "Downloads", "Pictures", "Movies"],
                            "\(variant.name): rows \(folders.rows.map { $0.name })")
                    #expect(!folders.rows.contains { $0.path == apiClient.path }, "\(variant.name): a repo is a row")

                    let screen = SetupScreen(flow: sncFlow(at: .folders), model: sncModel(files), folders: folders)
                    let strings = sncStrings(screen)
                    for word in ["api-client", "legacy-sync", "scratch-lab", "Developer"] {
                        #expect(!strings.contains { $0.contains(word) }, "\(variant.name): \"\(word)\" is shown: \(strings.filter { $0.contains(word) })")
                    }
                    #expect(screen.buttons.contains { $0.title == "Start indexing" && $0.isEnabled }, "\(variant.name): Start indexing: \(screen.buttons.map { ($0.title, $0.isEnabled) })")

                    let window = try sncWindow(env, files: files, folders: folders)
                    #expect(await sncWalk(window, to: .folders))
                    let root = try #require(window.contentView, "no content view")
                    let reads = prViews(root).filter { !$0.isHiddenOrHasHiddenAncestor }.flatMap { sncReads($0) }
                    for word in ["api-client", "legacy-sync", "scratch-lab"] {
                        #expect(!reads.contains { $0.contains(word) }, "\(variant.name): the window shows \"\(word)\": \(reads.filter { $0.contains(word) })")
                    }
                }
            }
        }

        @MainActor
        @Test func aPickedFolderWithTwoPicturesATextAndThreeCodeFilesShowsPhotoAndDocumentCountsAndTimesNoCode() async throws {
            try await sncRun { env in
                let mixed = try env.files("Mixed", ["a.png", "b.png", "notes.txt", "x.py", "y.py", "z.py"])
                let picks = SNCBox<[URL]>([mixed])
                let folders = sncFolders(env, speeds: ["photo": 3.0, "code": 60.0], picks: picks)
                folders.addFolder()
                #expect(await sncReady(folders), "the added row never became ready")

                let row = try #require(folders.rows.first { $0.path == mixed.path }, "no row for the picked folder: \(folders.rows.map { $0.path })")
                #expect(row.counts["photo"] == 2, "photos: \(row.counts)")
                #expect(row.counts["doc"] == 1, "documents: \(row.counts)")
                #expect((row.counts["code"] ?? 0) == 0, "code: \(row.counts)")
                #expect(row.counts.values.reduce(0, +) == 3, "the row counts \(row.counts), want 3 files")
                #expect(row.estimateText == "under a minute", "the estimate is \"\(row.estimateText)\"; 2 photos at 3 s is 6 s, 3 code files at 60 s would make it minutes")

                #expect(await sncEventually { folders.summaryTotal == 3 }, "summary total \(folders.summaryTotal), want 3")
                #expect(folders.summaryCounts["photo"] == 2 && folders.summaryCounts["doc"] == 1, "summary \(folders.summaryCounts)")
                #expect((folders.summaryCounts["code"] ?? 0) == 0, "summary code \(folders.summaryCounts)")

                let model = sncModel(try sncModelFiles(env, whole: true))
                let screen = SetupScreen(flow: sncFlow(at: .folders), model: model, folders: folders)
                let label = try #require(screen.controls.first { $0.label.hasPrefix("Mixed, ") }, "no row for Mixed in \(screen.controls.map { $0.label })").label
                #expect(label.contains("2 photos"), "the row reads \"\(label)\"")
                #expect(label.contains("1 doc"), "the row reads \"\(label)\"")
                #expect(!label.lowercased().contains("code"), "the row reads \"\(label)\"")
                #expect(label.hasSuffix(", under a minute"), "the row reads \"\(label)\"")
                #expect(!sncStrings(screen).contains { $0.lowercased().contains("code") }, "the screen names code: \(sncStrings(screen))")
            }
        }

        @MainActor
        @Test func startIndexingInTheModelKeepsEveryOldCodeValueAsFoundAndSavesAFolderItAddsWithCodeFalse() async throws {
            for codeSearchOn in [true, false] {
                try await sncRun { env in
                    let files = try sncModelFiles(env, whole: true)
                    let first = try env.dir("First")
                    let second = try env.dir("Second")
                    let added = try env.dir("Added")
                    try env.writeSettings(sncOldSettingsJSON(folders: [first.path, second.path], ticked: nil, codeSearchOn: codeSearchOn))
                    let seeded = env.settingsDictionary()
                    #expect(((seeded?["folders"] as? [NSDictionary]) ?? []).allSatisfy { ($0["code"] as? Bool) == true }, "the seed is not what the test says: \(String(describing: seeded))")

                    let starts = SNCBox(0)
                    let model = SetupModel(files: files, onStart: { starts.value += 1 })
                    model.addFolder(first)
                    model.addFolder(second)
                    model.addFolder(added)
                    model.refresh()
                    #expect(model.canStartIndexing)
                    model.startIndexing()
                    #expect(starts.value == 1, "the Start hook was called \(starts.value) times")

                    let after = env.settingsDictionary()
                    let context = "codeSearchOn \(codeSearchOn)"
                    #expect(after?["startPressed"] as? Bool == true, "\(context): startPressed is \(String(describing: after?["startPressed"]))")
                    for folder in [first, second, added] {
                        #expect(env.entry(folder.path)?["reading"] as? Bool == true, "\(context): \(folder.lastPathComponent) is not reading: \(String(describing: env.entry(folder.path)))")
                    }
                    #expect(env.entry(first.path)?["code"] as? Bool == true, "\(context): First lost its code value: \(String(describing: env.entry(first.path)))")
                    #expect(env.entry(second.path)?["code"] as? Bool == true, "\(context): Second lost its code value: \(String(describing: env.entry(second.path)))")
                    #expect(env.entry(added.path)?["code"] as? Bool == false, "\(context): the added folder is saved with code \(String(describing: env.entry(added.path)?["code"]))")
                    sncExpectOldValuesKept(after, codeSearchOn: codeSearchOn, context)
                }
            }
        }

        @MainActor
        @Test func startAndFinishInTheSetupWindowKeepEveryOldCodeValueAsFoundAndSaveAnAddedFolderWithCodeFalse() async throws {
            for button in ["Start indexing", "Finish"] {
                for codeSearchOn in [true, false] {
                    try await sncRun { env in
                        let files = try sncModelFiles(env, whole: true)
                        let first = try env.photos("First", count: 2)
                        let second = try env.files("Second", ["n.txt"])
                        let added = try env.photos("Added", count: 1)
                        try env.writeSettings(sncOldSettingsJSON(folders: [first.path, second.path], ticked: true, codeSearchOn: codeSearchOn))
                        let picks = SNCBox<[URL]>([])
                        let folders = sncFolders(env, picks: picks)
                        #expect(await sncReady(folders), "the rows never became ready")
                        let window = try sncWindow(env, files: files, folders: folders)
                        #expect(await sncWalk(window, to: .folders))

                        picks.value = [added]
                        #expect(await sncPress("Add folder\u{2026}", in: window), "no enabled Add folder\u{2026}")
                        #expect(await sncReady(folders))
                        window.refresh()

                        let context = "\(button) / codeSearchOn \(codeSearchOn)"
                        if button == "Finish" {
                            #expect(await sncWalk(window, to: .shortcut), "\(context): could not walk to Shortcut")
                        }
                        #expect(await sncPress(button, in: window), "\(context): no enabled \(button)")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if button == "Start indexing" { #expect(window.flow.step == .permissions, "\(context): Start indexing left the window on \(window.flow.step.title)") }

                        let after = env.settingsDictionary()
                        #expect(env.entry(first.path)?["code"] as? Bool == true, "\(context): First lost its code value: \(String(describing: env.entry(first.path)))")
                        #expect(env.entry(second.path)?["code"] as? Bool == true, "\(context): Second lost its code value: \(String(describing: env.entry(second.path)))")
                        #expect(env.entry(added.path)?["code"] as? Bool == false, "\(context): the added folder is saved with code \(String(describing: env.entry(added.path)?["code"]))")
                        let reading = button == "Start indexing"
                        for folder in [first, second, added] {
                            #expect(env.entry(folder.path)?["reading"] as? Bool == reading, "\(context): \(folder.lastPathComponent): \(String(describing: env.entry(folder.path)))")
                        }
                        sncExpectOldValuesKept(after, codeSearchOn: codeSearchOn, context)
                    }
                }
            }
        }

        @MainActor
        @Test func theKeyViewLoopOfEveryStepHoldsNoControlAndNoViewThatNamesCode() async throws {
            try await sncRun { env in
                _ = try env.photos("Pictures", count: 3)
                _ = try env.repo("Developer/api-client")
                _ = try env.repo("Developer/legacy-sync")
                let files = try sncModelFiles(env, whole: true)
                let folders = sncFolders(env)
                #expect(await sncReady(folders))
                let window = try sncWindow(env, files: files, folders: folders)

                for (title, step) in sncSteps {
                    #expect(await sncWalk(window, to: step), "could not walk to \(title)")
                    let loop = sncKeyLoop(window)
                    #expect(loop.started, "\(title): the window has no initialFirstResponder")
                    #expect(loop.closed, "\(title): the key-view loop never returned to its start (\(loop.visited.count) views)")
                    let loopReads = loop.visited.flatMap { sncReads($0) }
                    #expect(!loopReads.contains { $0.lowercased().contains("code") }, "\(title): the key-view loop holds \(loopReads.filter { $0.lowercased().contains("code") })")
                    #expect(!loopReads.contains("Search my code"), "\(title): the code switch is in the key-view loop")

                    let root = try #require(window.contentView, "no content view")
                    let shown = prViews(root).filter { !$0.isHiddenOrHasHiddenAncestor }.flatMap { sncReads($0) }
                    #expect(!shown.contains { $0.lowercased().contains("code") }, "\(title): the window shows \(shown.filter { $0.lowercased().contains("code") })")
                }
            }
        }

        @MainActor
        @Test func theHeadersTheTotalTheSpeedNoteAndTheTickLabelAndHelpAreAsTheyWere() async throws {
            try await sncRun { env in
                let pictures = try env.photos("Pictures", count: 100)
                let files = try sncModelFiles(env, whole: true)
                let model = sncModel(files)
                let folders = sncFolders(env, speeds: ["photo": 3.0])
                #expect(await sncReady(folders))

                let headers = ["Step 1 of 4: Welcome", "Step 2 of 4: Folders", "Step 3 of 4: Permissions", "Step 4 of 4: Shortcut"]
                for (index, entry) in sncSteps.enumerated() {
                    let screen = SetupScreen(flow: sncFlow(at: entry.step), model: model, folders: folders)
                    #expect(screen.texts.contains(headers[index]), "\(entry.title): no \"\(headers[index])\" in \(screen.texts)")
                    #expect(screen.texts.contains { $0.hasSuffix(" in total") } == (entry.step == .folders), "\(entry.title): total line in \(screen.texts)")
                }

                let screen = SetupScreen(flow: sncFlow(at: .folders), model: model, folders: folders)
                #expect(screen.texts.contains("About 5 min in total"), "no total line among \(screen.texts)")
                #expect(!screen.texts.contains("Photos: about 3 s each"), "the speed note is still among \(screen.texts)")
                let row = try #require(screen.controls.first { $0.label.hasPrefix("Pictures, ") }, "no Pictures row in \(screen.controls.map { $0.label })")
                #expect(row.label.hasPrefix("Pictures, 100 photos"), "the row reads \"\(row.label)\"")
                #expect(row.label.hasSuffix(", about 5 min"), "the row reads \"\(row.label)\"")
                #expect(row.isEnabled)
                for title in ["Back", "Add folder\u{2026}", "Start indexing", "Not now"] {
                    #expect(screen.buttons.contains { $0.title == title }, "no \"\(title)\" button in \(screen.buttons.map { $0.title })")
                }
                #expect(!screen.buttons.contains { $0.title == "Next" }, "a Next button beside Start indexing in \(screen.buttons.map { $0.title })")

                let window = try sncWindow(env, files: files, folders: folders)
                #expect(await sncWalk(window, to: .folders))
                let root = try #require(window.contentView, "no content view")
                let tick = try #require(prViews(root).compactMap { $0 as? NSButton }.first { ($0.accessibilityLabel() ?? "").hasPrefix("Pictures, ") },
                                        "no tick for Pictures in the window")
                #expect(tick.accessibilityLabel()?.hasPrefix("Pictures, 100 photos") == true, "tick label \"\(tick.accessibilityLabel() ?? "nil")\"")
                #expect(tick.accessibilityHelp() == pictures.path, "tick help \"\(tick.accessibilityHelp() ?? "nil")\", wanted \"\(pictures.path)\"")
            }
        }
    }
}
