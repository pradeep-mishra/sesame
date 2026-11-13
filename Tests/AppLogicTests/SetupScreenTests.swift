import AppKit
import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t20, tester step. Written from the t20 entry of plan-2-tasks.md (its Tests paragraph), Decisions D11, spec S6
// (S6.1, S6.2, S6.5, S6.9, S6.10), the F1 mockup and its design notes, design section 3 ("Setup, before Start": the app
// only counts and sends no `folders` command until Start) and the plan-1 and plan-2 test files as the one place the
// existing names are read (`SetupModel`, `SetupFlow`, `SetupFolders`, `StatusCache`, `HelperClient`, `PanelRig`'s helpers).
// No product source was read. Every expected text, count and flag below is written by hand from the folders and model
// states the test builds. The window is built and read offscreen as `PanelRig` does: it is never ordered front, never
// made key, and no app is launched. The helper is a shell stub that records its stdin; no model, no Vision.
//
// SUITE PLACEMENT. HOME is process-wide (SettingsFile and SesameFolder read it), so this suite is nested inside
// `ModelDownloadTests` like the other Setup suites and runs one at a time with them. Side effect:
// `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin. The entry names `SetupScreen`, `SetupWindow` and a decision function for `AppDelegate`
// and fixes no signatures. If a shape below is wrong, ask for a test change rather than guessing.
//   1. `SetupScreen` (the `Sesame` target) is a pure value, built by
//        SetupScreen(flow: SetupFlow, model: SetupModel, folders: SetupFolders)
//      from the flow's current step, the model's state as it is after `model.refresh()` (download progress, damaged
//      text, error text and Retry, whole) and the folder rows as `folders` holds them now. It holds no window.
//        - `step: SetupFlow.Step`, the flow's step.
//        - `texts: [String]`, every text a person can read on that step, one entry per label, in reading order.
//        - `buttons`: every push button shown. An element has `title: String` and `isEnabled: Bool`. The titles are
//          exactly "Back", "Next", "Finish", "Start indexing", "Add folder\u{2026}" (the ellipsis character) and
//          "Retry" (the last three are `SetupModel.startTitle`, `addFolderTitle` and `retryTitle` of plan 1).
//          A button that does not apply to a step may be absent or shown disabled: the tests read "is enabled" as
//          "present and enabled". On the last step "Next" may be replaced by "Finish".
//        - `controls`: every control a person can reach on that step, buttons included. An element has
//          `label: String` (its accessibility label) and `isEnabled: Bool`. A button's label is its title.
//   2. What the screen holds, by step. Folder rows, "Add folder\u{2026}" and "Start indexing" are on the Folders step only. The Permissions step carries `SetupFlow.permissionFolders` and
//      `SetupFlow.neverAskedLine` as texts. The model's state (progress text "<N> of <M> MB", damaged text, error text
//      and Retry) is on EVERY step, as the F1 mockup shows it (full on Welcome, small at the foot on the others).
//   3. Labels (the entry's): a folder row reads "<name>, <counts>, <estimate>" (the counts text is not pinned beyond
//      holding the file count of a one-kind folder), the model progress "Model download".
//   4. `SetupWindow` is an `NSWindow` subclass built by
//        SetupWindow(files: [ModelFile], folders: SetupFolders, helper: HelperClient, status: StatusCache)
//      It makes its own `SetupModel(files:)` and its own `SetupFlow`, and wires Start itself: Start writes the settings
//      (plan-1 `SetupModel.startIndexing()`), then `helper.sendFolders()` once, then `status.settingsChanged()`.
//      Properties: `model: SetupModel`, `flow: SetupFlow` (read), `setupScreen: SetupScreen` (the value the window
//      draws; `screen` is taken by NSWindow), `func refresh()` (re-reads the model from disk, redraws from a new
//      `SetupScreen`). The buttons are `NSButton`s in `contentView` whose `title` (or accessibility label) is the title
//      above; pressing one is `performClick(nil)`. Nothing is ordered front. Finish closes the window (`close()`, so
//      `NSWindow.willCloseNotification` is posted for it).
//   5. The first-window rule at launch: `AppDelegate.showsSetup(settings: Settings, modelWhole: Bool) -> Bool`, a static
//      function that answers what `SetupFlow.needed(settings:modelWhole:)` answers (plan-2 t18). No launch.
//   6. Not pinned, on purpose: any wording beyond what is stated above, the order and layout of the controls, the
//      shortcut step's controls, the look against mockup F1, whether a hidden step's views are removed or hidden.

// MARK: small helpers (file-private, so nothing collides with the other Setup test files)

private final class SSBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class SSCount: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0
    func add() { lock.lock(); number += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return number }
}

private func ssHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// A model file of a stated size whose bytes are never held: only a sparse `.partial` of it is made.
private func ssBigFile(_ name: String, size: Int) -> ModelFile {
    ModelFile(name: name, size: size, sha256: String(repeating: "0", count: 64))
}

// A small whole file: the bytes are real, so the size and SHA-256 are right.
private func ssWholeFile(_ name: String, size: Int) -> (data: Data, file: ModelFile) {
    var state: UInt64 = UInt64(size) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var bytes = [UInt8](repeating: 0, count: size)
    for i in 0..<size {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    let data = Data(bytes)
    return (data, ModelFile(name: name, size: size, sha256: ssHex(data)))
}

private struct SSEnv {
    let home: URL   // symlink-resolved, so a path compared as text cannot differ by a link
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }
    func whole(_ name: String) -> URL { models.appendingPathComponent(name) }
    func partial(_ name: String) -> URL { models.appendingPathComponent(name + ".partial") }
    func path(_ name: String) -> String { home.appendingPathComponent(name).path }

    func setPartial(_ name: String, bytes: Int) throws {
        let url = partial(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    func dir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Hand-made files: `photo` jpg/png, `pdf` pdf, `doc` txt/md, unique names.
    func fill(_ relative: String, photo: Int = 0, pdf: Int = 0, doc: Int = 0) throws -> URL {
        let url = try dir(relative)
        func write(_ name: String) throws {
            try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent(name))
        }
        for n in 0..<photo { try write("photo-\(n).\(n % 2 == 0 ? "jpg" : "png")") }
        for n in 0..<pdf { try write("paper-\(n).pdf") }
        for n in 0..<doc { try write("note-\(n).\(n % 2 == 0 ? "txt" : "md")") }
        return url
    }

    func settingsDictionary() -> NSDictionary? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    func startPressedOnDisk() -> Bool { (settingsDictionary()?["startPressed"] as? Bool) ?? false }

    func folderEntriesOnDisk() -> [NSDictionary] { (settingsDictionary()?["folders"] as? [NSDictionary]) ?? [] }

    // Lines the stub helper read on stdin, by mode.
    func helperLines(_ mode: String) -> [String] {
        let url = home.appendingPathComponent(mode + ".lines")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func foldersLines() -> [String] { helperLines("index").filter { $0.contains("\"cmd\":\"folders\"") } }

    var helperWasStarted: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("index.lines").path)
            || FileManager.default.fileExists(atPath: home.appendingPathComponent("encode.lines").path)
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder and `models/`, runs the body, puts HOME back and removes it all.
@MainActor
private func ssRun(_ body: (SSEnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-setupscreen-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = SSEnv(home: base.resolvingSymlinksInPath())
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

// Polls the main actor until the condition holds; a generous slack, never a tight bound.
@MainActor
private func ssEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func ssReady(_ folders: SetupFolders) async -> Bool {
    await ssEventually { folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
}

// The four model states of the entry.
private enum SSState: String, CaseIterable, CustomStringConvertible {
    case downloading, damaged, failed, whole
    var description: String { rawValue }
}

private let ssDamagedMessage = "The model file was damaged, so it was deleted. Downloading it again."
private let ssFailedMessage = "Could not download the model"
// 20,000,000 of 80,000,000 + 40,000,000 bytes, in decimal megabytes: the plan-1 rule of `progressText`.
private let ssProgressText = "20 of 120 MB"

private struct SSFiles {
    let files: [ModelFile]
    let state: SSState
}

// The files the model of `state` expects, with the bytes the state needs on disk.
private func ssPrepareFiles(_ state: SSState, env: SSEnv) throws -> SSFiles {
    if state == .whole {
        let whole = ssWholeFile("ss-whole.gguf", size: 300_000)
        try whole.data.write(to: env.whole(whole.file.name))
        return SSFiles(files: [whole.file], state: state)
    }
    let a = ssBigFile("ss-a.gguf", size: 80_000_000)
    let b = ssBigFile("ss-b.gguf", size: 40_000_000)
    try env.setPartial(a.name, bytes: 20_000_000)
    return SSFiles(files: [a, b], state: state)
}

// A model in `state`, refreshed, as the window would hold it.
@MainActor
private func ssMakeModel(_ prepared: SSFiles) -> SetupModel {
    let model = SetupModel(files: prepared.files)
    model.refresh()
    switch prepared.state {
    case .downloading, .whole: break
    case .damaged: model.modelWasDamaged()
    case .failed: model.downloadFailed(ssFailedMessage)
    }
    model.refresh()
    return model
}

private let ssKinds = ["photo", "pdf", "doc", "audio", "video", "code"]

@MainActor
private final class SSKit {
    let speeds = SSBox<[String: Double]>(["photo": 3.0])
    let kindsOn = SSBox<[String: Bool]>(Dictionary(uniqueKeysWithValues: ssKinds.map { ($0, true) }))
    let modelWhole: SSBox<Bool>
    let picks = SSBox<[URL]>([])

    init(modelWhole: Bool) { self.modelWhole = SSBox(modelWhole) }

    // The real counter is the default of the initializer.
    func makeFolders(home: URL) -> SetupFolders {
        let speeds = self.speeds, kindsOn = self.kindsOn, modelWhole = self.modelWhole, picks = self.picks
        return SetupFolders(
            home: home,
            picker: { picks.value },
            speeds: { speeds.value },
            kindsOn: { kindsOn.value },
            modelWhole: { modelWhole.value })
    }
}

// The folders every table test starts from: Pictures holds 100 photos, Desktop 3 documents, Documents 2 PDFs; Downloads
// and Movies do not exist.
@MainActor
private func ssBuildFolders(_ env: SSEnv, state: SSState) throws -> (SetupFolders, SSKit) {
    _ = try env.fill("Pictures", photo: 100)
    _ = try env.fill("Desktop", doc: 3)
    _ = try env.fill("Documents", pdf: 2)
    let kit = SSKit(modelWhole: state == .whole)
    return (kit.makeFolders(home: env.home), kit)
}

private extension SetupScreen {
    func ssEnabled(_ title: String) -> Bool { buttons.contains { $0.title == title && $0.isEnabled } }
    func ssShows(_ title: String) -> Bool { buttons.contains { $0.title == title } }
    var ssText: String { texts.joined(separator: "\n") }
    var ssLabels: [String] { controls.map { $0.label } }
}

private let ssSteps: [(title: String, step: SetupFlow.Step)] = [
    ("Welcome", .welcome), ("Folders", .folders), ("Permissions", .permissions), ("Shortcut", .shortcut),
]

// A flow standing on `step`, reached by Next, as a person gets there.
private func ssFlow(at step: SetupFlow.Step) -> SetupFlow {
    var flow = SetupFlow()
    while flow.step != step && flow.canGoNext { flow.next() }
    return flow
}

// MARK: the window, read offscreen

private let ssStubScript = #"""
#!/bin/sh
# Stub helper: records every stdin line under <mode>.lines beside itself (mode is the first argument), and prints nothing.
dir=$(dirname "$0")
mode="$1"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$dir/$mode.lines"
done
"""#

@MainActor
private func ssStubClient(_ env: SSEnv) throws -> HelperClient {
    let stub = env.home.appendingPathComponent("ss-stub-helper")
    try ssStubScript.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    return HelperClient(helper: stub, textModel: env.home, mmModel: env.home)
}

private func ssQuietStatus(counter: SSCount) -> StatusCache {
    let sources = StatusSources(
        settings: { counter.add(); return Settings() },
        counts: { IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 0) },
        meta: { _ in nil },
        modelState: { .whole })
    return StatusCache(sources: sources, queue: DispatchQueue(label: "sesame.setupscreen.test.status", qos: .utility))
}

@MainActor
private func ssButtons(in window: NSWindow) -> [NSButton] {
    guard let root = window.contentView else { return [] }
    return prViews(root).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
}

@MainActor
private func ssButton(_ title: String, in window: NSWindow) -> NSButton? {
    ssButtons(in: window).first { $0.title == title || $0.accessibilityLabel() == title }
}

// A press as a person makes it; false when there is no such enabled button.
@MainActor
@discardableResult
private func ssPress(_ title: String, in window: NSWindow) async -> Bool {
    guard let button = ssButton(title, in: window), button.isEnabled else { return false }
    button.performClick(nil)
    await Task.yield()
    return true
}

@MainActor
@discardableResult
private func ssAdvance(in window: NSWindow) async -> Bool {
    if await ssPress("Next", in: window) { return true }
    return await ssPress("Not now", in: window)
}

// Every control a person could tab to: enabled, not hidden, a button-like control or an editable field. Scrollers are
// controls to AppKit but are never keyboard stops.
@MainActor
private func ssEnabledControls(in window: NSWindow) -> [NSView] {
    guard let root = window.contentView else { return [] }
    return prViews(root).filter { view in
        guard !view.isHiddenOrHasHiddenAncestor, !(view is NSScroller) else { return false }
        if let field = view as? NSTextField { return field.isEditable && field.isEnabled }
        if let control = view as? NSControl { return control.isEnabled }
        return false
    }
}

// The loop `nextValidKeyView` walks from `initialFirstResponder`, and whether it came back to the start.
@MainActor
private func ssKeyLoop(_ window: NSWindow) -> (visited: [NSView], closed: Bool, started: Bool) {
    guard let start = window.initialFirstResponder else { return ([], false, false) }
    var visited = [start]
    var next = start.nextValidKeyView
    while let current = next, current !== start, visited.count < 500 {
        visited.append(current)
        next = current.nextValidKeyView
    }
    return (visited, visited.count == 1 || next === start, true)
}

private let ssBareRoleWords: Set<String> = [
    "button", "checkbox", "check box", "switch", "text field", "text", "static text", "label", "image", "progress",
    "progress indicator", "slider", "group", "radio button", "pop up button", "popup button", "scroll area", "table",
    "list", "row", "toggle", "stepper", "link",
]

private func ssBare(_ label: String?) -> Bool {
    let text = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty || ssBareRoleWords.contains(text.lowercased())
}

private func ssSettingsJSON(startPressed: Bool, indexDeleted: Bool) -> String {
    """
    {
      "version": 3,
      "startPressed": \(startPressed),
      "indexDeleted": \(indexDeleted),
      "folders": [],
      "codeSearchOn": false,
      "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
      "hotkey": "cmd+opt+k",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 1.5},
      "loginDefaultApplied": true
    }
    """
}

extension ModelDownloadTests {
    @Suite("SetupScreenTests", .serialized)
    struct SetupScreenTests {

        // MARK: the table: buttons and their enabled state, for each step and each model state

        @MainActor
        @Test func theButtonsAndTheirEnabledStateForEveryStepAndEveryModelState() async throws {
            for state in SSState.allCases {
                try await ssRun { env in
                    let prepared = try ssPrepareFiles(state, env: env)
                    let model = ssMakeModel(prepared)
                    let (folders, _) = try ssBuildFolders(env, state: state)
                    #expect(await ssReady(folders), "\(state): the rows never became ready")

                    for (title, step) in ssSteps {
                        let screen = SetupScreen(flow: ssFlow(at: step), model: model, folders: folders)
                        let where_ = "\(state) / \(title)"
                        #expect(screen.step == step, "\(where_): the screen is on \(screen.step.title)")

                        // Next, Back and the folder step stay usable whatever the model is doing (S6.5)
                        #expect(screen.ssEnabled("Back") == (step != .welcome), "\(where_): Back \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                        let footerIsStart = step == .folders && state == .whole
                        #expect(screen.ssEnabled("Next") == (step != .shortcut && !footerIsStart), "\(where_): Next \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                        #expect(screen.ssShows("Next") == (step != .shortcut && !footerIsStart), "\(where_): Next shown \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                        #expect(screen.ssEnabled("Finish") == (step == .shortcut), "\(where_): Finish \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                        // Add folder... is the folder step's, and works while the model downloads
                        #expect(screen.ssEnabled("Add folder\u{2026}") == (step == .folders), "\(where_): Add folder")
                        #expect(screen.ssEnabled("Start indexing") == (step == .folders && state == .whole),
                                "\(where_): Start indexing \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                        #expect(screen.ssShows("Start indexing") == (step == .folders && state == .whole),
                                "\(where_): Start indexing shown \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                        #expect(screen.ssEnabled("Not now") == (step == .folders && state == .whole), "\(where_): Not now \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                        #expect(screen.ssShows("Not now") == (step == .folders && state == .whole), "\(where_): Not now shown \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                        // Retry only after a failed download
                        #expect(screen.ssEnabled("Retry") == (state == .failed), "\(where_): Retry \(screen.buttons.map { ($0.title, $0.isEnabled) })")

                        // every button is a control with its title as its label
                        for button in screen.buttons {
                            #expect(screen.ssLabels.contains(button.title), "\(where_): button \"\(button.title)\" is not among the controls \(screen.ssLabels)")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test func withNoFolderTickedStartIndexingIsShownDisabledNotNowIsEnabledTheHintSaysToTickOneAndTheSummaryStillSaysNothingWillBeIndexed() async throws {
            try await ssRun { env in
                // Pictures exists before the rows are built, so its row has no note; it is unticked right after building.
                // The other suggested folders do not exist, so their rows read "not found".
                let prepared = try ssPrepareFiles(.whole, env: env)
                let model = ssMakeModel(prepared)
                _ = try env.fill("Pictures", photo: 3)
                let kit = SSKit(modelWhole: true)
                let folders = kit.makeFolders(home: env.home)
                folders.setTicked(env.path("Pictures"), false)
                #expect(folders.rows.allSatisfy { !$0.ticked }, "a missing folder is ticked: \(folders.rows.map { ($0.name, $0.ticked) })")
                #expect(await ssReady(folders))

                let screen = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
                #expect(screen.ssShows("Start indexing") && !screen.ssEnabled("Start indexing"), "Start indexing is not shown disabled with no folder ticked: \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(screen.ssEnabled("Not now"), "Not now is not enabled with no folder ticked: \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(!screen.ssShows("Next"), "Next is shown beside Start indexing: \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(screen.texts.contains("Tick at least one folder to start."), "no tick hint in: \(screen.texts)")
                #expect(!screen.texts.contains("Indexing starts when you press Start indexing, and runs in the background."), "the ticked hint with no folder ticked: \(screen.texts)")
                if let hint = screen.texts.firstIndex(of: "Tick at least one folder to start."), let note = screen.texts.firstIndex(of: ssReadNote) {
                    #expect(hint + 1 == note, "the hint is not the text right before the read note: \(screen.texts)")
                }
                #expect(screen.ssText.lowercased().contains("nothing will be indexed"), "no such summary in: \(screen.texts)")
                #expect(screen.ssText.lowercased().contains("not found"), "no \"not found\" for a missing folder in: \(screen.texts)")

                // with a folder ticked the summary no longer says it
                folders.setTicked(env.path("Pictures"), true)
                #expect(await ssReady(folders))
                let ticked = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
                #expect(!ticked.ssText.lowercased().contains("nothing will be indexed"), "still says nothing will be indexed: \(ticked.texts)")
                #expect(ticked.ssEnabled("Start indexing"))
                #expect(ticked.ssEnabled("Not now"))
                #expect(ticked.texts.contains("Indexing starts when you press Start indexing, and runs in the background."), "no hint in: \(ticked.texts)")
                #expect(!ticked.texts.contains("Tick at least one folder to start."), "the tick hint with a folder ticked: \(ticked.texts)")
            }
        }

        // MARK: the table: visible texts, for each step and each model state

        @MainActor
        @Test func theModelStateIsShownInsideEveryStepWithItsExactTexts() async throws {
            for state in SSState.allCases {
                try await ssRun { env in
                    let prepared = try ssPrepareFiles(state, env: env)
                    let model = ssMakeModel(prepared)
                    let (folders, _) = try ssBuildFolders(env, state: state)
                    #expect(await ssReady(folders))

                    for (title, step) in ssSteps {
                        let screen = SetupScreen(flow: ssFlow(at: step), model: model, folders: folders)
                        let text = screen.ssText
                        let where_ = "\(state) / \(title)"
                        #expect(!screen.texts.isEmpty && screen.texts.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                                "\(where_): texts \(screen.texts)")
                        switch state {
                        case .downloading:
                            #expect(text.contains(ssProgressText), "\(where_): no \"\(ssProgressText)\" in \(screen.texts)")
                            #expect(screen.ssLabels.contains("Model download"), "\(where_): no \"Model download\" control in \(screen.ssLabels)")
                            #expect(!text.contains(ssDamagedMessage) && !text.contains(ssFailedMessage), "\(where_): an error text while downloading: \(screen.texts)")
                        case .damaged:
                            #expect(text.contains(ssDamagedMessage), "\(where_): the damaged message is not in \(screen.texts)")
                            #expect(!text.contains(ssFailedMessage), "\(where_): the failure text next to the damaged one: \(screen.texts)")
                        case .failed:
                            #expect(text.contains(ssFailedMessage), "\(where_): \"\(ssFailedMessage)\" is not in \(screen.texts)")
                            #expect(!text.contains(ssDamagedMessage), "\(where_): the damaged text with a failed download: \(screen.texts)")
                        case .whole:
                            #expect(!text.contains(ssDamagedMessage) && !text.contains(ssFailedMessage), "\(where_): an error text with a whole model: \(screen.texts)")
                            #expect(!screen.ssShows("Retry"), "\(where_): Retry with a whole model")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test func thePermissionsStepNamesTheFoldersAndTheNeverAskedLineAndNoOtherStepDoes() async throws {
            try await ssRun { env in
                let model = ssMakeModel(try ssPrepareFiles(.whole, env: env))
                let (folders, _) = try ssBuildFolders(env, state: .whole)
                #expect(await ssReady(folders))

                let permissions = SetupScreen(flow: ssFlow(at: .permissions), model: model, folders: folders)
                let lower = permissions.ssText.lowercased()
                for name in ["desktop", "documents", "downloads", "removable"] {
                    #expect(lower.contains(name), "the Permissions step does not name \(name): \(permissions.texts)")
                }
                for word in ["full disk access", "camera", "microphone", "never"] {
                    #expect(lower.contains(word), "the Permissions step lacks \"\(word)\": \(permissions.texts)")
                }
                // the static values of the flow are carried whole
                for line in SetupFlow.permissionFolders { #expect(permissions.texts.contains(line), "missing line \"\(line)\" in \(permissions.texts)") }
                #expect(permissions.texts.contains(SetupFlow.neverAskedLine), "the never-asked line is missing in \(permissions.texts)")

                for (title, step) in ssSteps where step != .permissions {
                    let other = SetupScreen(flow: ssFlow(at: step), model: model, folders: folders)
                    #expect(!other.texts.contains(SetupFlow.neverAskedLine), "\(title) carries the Permissions line")
                }
            }
        }

        // MARK: the table: accessibility labels of the folder step

        @MainActor
        @Test func theFolderStepLabelsEachRowNameCountsAndEstimateAndNoOtherStepHasThem() async throws {
            for state in [SSState.downloading, SSState.whole] {
                try await ssRun { env in
                    let model = ssMakeModel(try ssPrepareFiles(state, env: env))
                    let (folders, _) = try ssBuildFolders(env, state: state)
                    #expect(await ssReady(folders))
                    let estimate = state == .whole ? "about 5 min" : "after the model download"   // 100 photos x 3.0 s, hand-computed

                    let screen = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
                    // the Pictures row: "<name>, <counts>, <estimate>"
                    let row = try #require(screen.controls.first { $0.label.hasPrefix("Pictures") },
                                           "\(state): no control for the Pictures row in \(screen.ssLabels)")
                    #expect(row.label.hasPrefix("Pictures, "), "\(state): row label \"\(row.label)\"")
                    #expect(row.label.hasSuffix(", " + estimate), "\(state): row label \"\(row.label)\" does not end with the estimate \"\(estimate)\"")
                    let counts = String(row.label.dropFirst("Pictures, ".count).dropLast((", " + estimate).count))
                    #expect(counts.contains("100"), "\(state): counts \"\(counts)\" in \"\(row.label)\" lack the 100 photos")
                    #expect(counts.lowercased().contains("photo"), "\(state): counts \"\(counts)\" do not name photos")
                    #expect(row.isEnabled, "\(state): a ticked folder's row is disabled")

                    // the other folders that exist are rows too, with their names first
                    for name in ["Desktop", "Documents"] {
                        #expect(screen.ssLabels.contains { $0.hasPrefix(name + ", ") }, "\(state): no row for \(name) in \(screen.ssLabels)")
                    }

                    if state == .downloading {
                        #expect(screen.ssLabels.contains("Model download"))
                    }
                    #expect(screen.controls.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                            "\(state): a control without a label: \(screen.ssLabels)")

                    for (title, step) in ssSteps where step != .folders {
                        let other = SetupScreen(flow: ssFlow(at: step), model: model, folders: folders)
                        #expect(!other.ssLabels.contains { $0.hasPrefix("Pictures") }, "\(state) / \(title): a folder row is on this step: \(other.ssLabels)")
                    }
                }
            }
        }

        // MARK: the window, offscreen: key-view loop and labels

        @MainActor
        @Test func everyEnabledControlOfEveryStepIsInTheKeyViewLoopWithAnAccessibilityLabelThatIsNotARoleWord() async throws {
            for state in [SSState.downloading, SSState.failed, SSState.whole] {
                try await ssRun { env in
                    let prepared = try ssPrepareFiles(state, env: env)
                    let (folders, _) = try ssBuildFolders(env, state: state)
                    #expect(await ssReady(folders))
                    let window = SetupWindow(files: prepared.files, folders: folders, helper: try ssStubClient(env),
                                             status: ssQuietStatus(counter: SSCount()))
                    window.isReleasedWhenClosed = false
                    window.refresh()
                    if state == .failed { window.model.downloadFailed(ssFailedMessage); window.refresh() }

                    for (title, step) in ssSteps {
                        // walk there by the buttons a person presses
                        while window.flow.step != step {
                            let pressed = await ssAdvance(in: window)
                            #expect(pressed, "\(state): no enabled Next or Not now on \(window.flow.step.title)")
                            if !pressed { return }
                        }
                        window.refresh()
                        let where_ = "\(state) / \(title)"
                        #expect(window.setupScreen.step == step, "\(where_): the window draws \(window.setupScreen.step.title)")

                        let controls = ssEnabledControls(in: window)
                        #expect(!controls.isEmpty, "\(where_): the window has no enabled control")
                        let loop = ssKeyLoop(window)
                        #expect(loop.started, "\(where_): the window has no initialFirstResponder")
                        #expect(loop.closed, "\(where_): the key-view loop never returned to its start (\(loop.visited.count) views)")
                        for control in controls {
                            let name = (control as? NSButton)?.title ?? control.accessibilityLabel() ?? String(describing: type(of: control))
                            #expect(loop.visited.contains { $0 === control },
                                    "\(where_): the enabled control \"\(name)\" is not in the key-view loop (full keyboard access: \(NSApp.isFullKeyboardAccessEnabled))")
                            #expect(!ssBare(control.accessibilityLabel()),
                                    "\(where_): the control \"\(name)\" has the accessibility label \"\(control.accessibilityLabel() ?? "nil")\"")
                        }
                        // the buttons of the table are really there, as buttons, on this step
                        for button in window.setupScreen.buttons where button.isEnabled {
                            #expect(ssButton(button.title, in: window)?.isEnabled == true, "\(where_): no enabled NSButton \"\(button.title)\" in the window")
                        }
                    }
                }
            }
        }

        // MARK: the window: Next, Back and the folder step while the model downloads

        @MainActor
        @Test func nextBackAndAddFolderWorkInTheWindowWhileTheModelDownloadsAndStartDoesNot() async throws {
            try await ssRun { env in
                let prepared = try ssPrepareFiles(.downloading, env: env)
                let (folders, kit) = try ssBuildFolders(env, state: .downloading)
                #expect(await ssReady(folders))
                let counter = SSCount()
                let client = try ssStubClient(env)
                let window = SetupWindow(files: prepared.files, folders: folders, helper: client, status: ssQuietStatus(counter: counter))
                window.isReleasedWhenClosed = false
                window.refresh()

                #expect(window.flow.step == .welcome)
                #expect(window.setupScreen.texts.joined().contains(ssProgressText), "the progress is not on Welcome: \(window.setupScreen.texts)")
                #expect(await ssPress("Next", in: window))
                #expect(window.flow.step == .folders, "Next moved to \(window.flow.step.title)")
                window.refresh()

                #expect(!window.setupScreen.ssShows("Start indexing"), "Start indexing is shown while the model downloads: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(!window.setupScreen.ssShows("Not now"), "Not now is shown while the model downloads: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(window.setupScreen.ssEnabled("Next"), "no enabled Next on Folders while the model downloads: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(!(await ssPress("Start indexing", in: window)), "Start indexing was pressable while the model downloads")
                #expect(!env.startPressedOnDisk())

                // a folder can be added while the bytes arrive
                let extra = try env.fill("Extra", photo: 4)
                kit.picks.value = [extra]
                #expect(await ssPress("Add folder\u{2026}", in: window), "no enabled Add folder\u{2026} while downloading")
                #expect(folders.rows.last?.path == extra.path, "the picked folder is not the last row: \(folders.rows.map { $0.path })")
                #expect(await ssReady(folders))
                window.refresh()
                #expect(window.setupScreen.ssLabels.contains { $0.hasPrefix("Extra, ") }, "no row for the added folder in \(window.setupScreen.ssLabels)")

                // forward and back all the way, still downloading
                #expect(await ssPress("Next", in: window)); #expect(window.flow.step == .permissions)
                #expect(await ssPress("Next", in: window)); #expect(window.flow.step == .shortcut)
                #expect(!(await ssPress("Next", in: window)) || window.flow.step == .shortcut, "Next moved past Shortcut")
                #expect(await ssPress("Back", in: window)); #expect(window.flow.step == .permissions)
                #expect(await ssPress("Back", in: window)); #expect(window.flow.step == .folders)
                #expect(await ssPress("Back", in: window)); #expect(window.flow.step == .welcome)
                #expect(!(await ssPress("Back", in: window)), "Back was enabled on Welcome")

                // none of it started anything: no helper, no Start, no folder reading
                try? await Task.sleep(nanoseconds: 400_000_000)
                #expect(!env.helperWasStarted, "a helper was started before Start: \(env.helperLines("index")) \(env.helperLines("encode"))")
                #expect(env.foldersLines().isEmpty)
                #expect(!env.startPressedOnDisk())
                #expect(env.folderEntriesOnDisk().allSatisfy { ($0["reading"] as? Bool) != true }, "a folder is reading: \(env.folderEntriesOnDisk())")
            }
        }

        // MARK: the window: nothing before Start, with the model whole

        @MainActor
        @Test func steppingPickingAndTickingSendNothingEvenWithAWholeModel() async throws {
            try await ssRun { env in
                let prepared = try ssPrepareFiles(.whole, env: env)
                let (folders, kit) = try ssBuildFolders(env, state: .whole)
                #expect(await ssReady(folders))
                let counter = SSCount()
                let window = SetupWindow(files: prepared.files, folders: folders, helper: try ssStubClient(env), status: ssQuietStatus(counter: counter))
                window.isReleasedWhenClosed = false
                window.refresh()
                #expect(window.setupScreen.ssEnabled("Next"))

                func assertQuiet(_ stage: String) async {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    #expect(!env.helperWasStarted, "\(stage): a helper was started: \(env.helperLines("index"))")
                    #expect(env.foldersLines().isEmpty, "\(stage): a folders command was sent")
                    #expect(!env.startPressedOnDisk(), "\(stage): startPressed is true on disk")
                    #expect(env.folderEntriesOnDisk().allSatisfy { ($0["reading"] as? Bool) != true }, "\(stage): a folder is reading")
                }

                #expect(await ssPress("Next", in: window))
                let extra = try env.fill("Extra", doc: 2)
                kit.picks.value = [extra]
                #expect(await ssPress("Add folder\u{2026}", in: window))
                #expect(await ssReady(folders))
                await assertQuiet("a folder added")

                folders.setTicked(env.path("Pictures"), false)
                folders.setTicked(env.path("Pictures"), true)
                #expect(await ssReady(folders))
                await assertQuiet("a folder unticked and ticked again")

                #expect(await ssAdvance(in: window))
                #expect(await ssAdvance(in: window))
                #expect(window.flow.step == .shortcut)
                await assertQuiet("every step visited")
            }
        }

        // MARK: the window: Start

        @MainActor
        @Test func startWritesTheTicksSendsFoldersOnceAndTellsTheStatusCache() async throws {
            try await ssRun { env in
                let prepared = try ssPrepareFiles(.whole, env: env)
                let (folders, _) = try ssBuildFolders(env, state: .whole)
                #expect(await ssReady(folders))
                let counter = SSCount()
                let status = ssQuietStatus(counter: counter)
                let window = SetupWindow(files: prepared.files, folders: folders, helper: try ssStubClient(env), status: status)
                window.isReleasedWhenClosed = false
                window.refresh()

                #expect(await ssPress("Next", in: window))
                #expect(window.flow.step == .folders)
                // Documents is unticked; Desktop and Pictures stay ticked; Downloads and Movies do not exist
                folders.setTicked(env.path("Documents"), false)
                window.refresh()
                #expect(window.setupScreen.ssEnabled("Start indexing"), "Start indexing unavailable with a whole model: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(!env.helperWasStarted)

                let before = counter.value
                #expect(await ssPress("Start indexing", in: window), "Start indexing could not be pressed")

                // exactly one folders command, naming the ticked folders and no other
                let arrived = await ssEventually { !env.foldersLines().isEmpty }
                #expect(arrived, "no folders command reached the helper: \(env.helperLines("index"))")
                try? await Task.sleep(nanoseconds: 700_000_000)
                let lines = env.foldersLines()
                #expect(lines.count == 1, "\(lines.count) folders commands were sent: \(lines)")
                if let line = lines.first,
                   let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                   let sent = object["folders"] as? [[String: Any]] {
                    let paths = Set(sent.compactMap { $0["path"] as? String })
                    #expect(paths == [env.path("Desktop"), env.path("Pictures")], "the folders command named \(paths.sorted())")
                    #expect(sent.allSatisfy { ($0["code"] as? Bool) == false }, "a folder was sent with code on: \(sent)")
                } else {
                    Issue.record("the folders command is not a JSON object with a folders list: \(lines)")
                }

                // settings.json: Start pressed, the index not deleted, reading as ticked, code off
                let onDisk = try #require(env.settingsDictionary(), "no settings.json after Start")
                #expect(onDisk["startPressed"] as? Bool == true)
                #expect(onDisk["indexDeleted"] as? Bool == false)
                var reading: [String: Bool] = [:]
                for entry in env.folderEntriesOnDisk() {
                    if let path = entry["path"] as? String { reading[path] = entry["reading"] as? Bool }
                    #expect(entry["code"] as? Bool == false, "code is on for \(entry)")
                }
                #expect(reading[env.path("Desktop")] == true && reading[env.path("Pictures")] == true && reading[env.path("Documents")] == false,
                        "reading on disk: \(reading)")

                // the status cache was told: its settings source is read again off the main thread
                let refreshed = await ssEventually { counter.value > before }
                #expect(refreshed, "StatusCache.settingsChanged() was not called by Start (settings source calls: \(counter.value), before \(before))")

                window.refresh()
                #expect(window.flow.step == .permissions, "after Start the window is on \(window.flow.step.title), wanted Permissions")
                #expect(!SetupFlow.needed(settings: try SettingsFile().read(), modelWhole: true), "the rule still wants setup after Start")
                #expect(await ssPress("Back", in: window))
                window.refresh()
                #expect(window.flow.step == .folders)
                #expect(!window.setupScreen.ssShows("Start indexing"), "Start indexing is still shown after Start: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(!window.setupScreen.ssShows("Not now"), "Not now is still shown after Start: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(window.setupScreen.ssEnabled("Next"), "the footer does not read Next after Start: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(!(await ssPress("Start indexing", in: window)))
                #expect(await ssPress("Next", in: window))
                #expect(window.flow.step == .permissions, "Next on Folders after Start moved to \(window.flow.step.title)")
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(env.foldersLines().count == 1, "a second press sent another folders command")
            }
        }

        @MainActor
        @Test func finishClosesTheWindowAndOnlyOnTheShortcutStep() async throws {
            try await ssRun { env in
                let prepared = try ssPrepareFiles(.whole, env: env)
                let (folders, _) = try ssBuildFolders(env, state: .whole)
                #expect(await ssReady(folders))
                let window = SetupWindow(files: prepared.files, folders: folders, helper: try ssStubClient(env),
                                         status: ssQuietStatus(counter: SSCount()))
                window.isReleasedWhenClosed = false
                window.refresh()

                let closed = SSBox<Bool>(false)
                let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    closed.value = true
                }
                defer { NotificationCenter.default.removeObserver(token) }

                #expect(!(await ssPress("Finish", in: window)), "Finish was pressable on Welcome")
                for _ in 0..<3 {
                    #expect(await ssAdvance(in: window))
                    #expect(!closed.value, "the window closed on \(window.flow.step.title)")
                }
                #expect(window.flow.step == .shortcut)
                window.refresh()
                #expect(window.setupScreen.ssEnabled("Finish"))
                #expect(await ssPress("Finish", in: window), "no enabled Finish on Shortcut")
                let didClose = await ssEventually { closed.value }
                #expect(didClose, "Finish did not close the window")

                // Finish is not Start: nothing was started by closing the window
                try? await Task.sleep(nanoseconds: 300_000_000)
                #expect(!env.startPressedOnDisk(), "Finish pressed Start")
                #expect(!env.helperWasStarted, "Finish started a helper")
            }
        }

        // MARK: the first-window rule, as AppDelegate decides it at launch

        @MainActor
        @Test func theLaunchShowsSetupByTheFirstWindowRuleAndNeverAgainAfterStartOrDeleteIndex() async throws {
            try await ssRun { _ in
                let fresh = Settings()
                let neverPressed = try JSONDecoder().decode(Settings.self, from: Data(ssSettingsJSON(startPressed: false, indexDeleted: false).utf8))
                let pressed = try JSONDecoder().decode(Settings.self, from: Data(ssSettingsJSON(startPressed: true, indexDeleted: false).utf8))
                let deleted = try JSONDecoder().decode(Settings.self, from: Data(ssSettingsJSON(startPressed: false, indexDeleted: true).utf8))

                // (settings, modelWhole, shows setup), written by hand from D11 and the entry
                // plan-2 fix round B, item B2 (R2-07): two rows RE-PINNED by the round's fresh tester. The old rows said setup
                // shows again after Start, or after Delete index, while the model is not whole. The ruling: setup shows only
                // until it is finished or Start is pressed; a model that is not whole after that is shown by the panel and
                // the menu as Downloading, never by the setup window.
                //   was: ("pressed, model not whole (the download is shown)", pressed, false, true)
                //   now: ("pressed, model not whole (the panel and the menu show the download)", pressed, false, false)
                //   was: ("index deleted, model not whole", deleted, false, true)
                //   now: ("index deleted, model not whole", deleted, false, false)
                let table: [(name: String, settings: Settings, whole: Bool, shows: Bool)] = [
                    ("fresh, model whole", fresh, true, true),
                    ("fresh, model not whole", fresh, false, true),
                    ("never pressed, model whole", neverPressed, true, true),
                    ("never pressed, model not whole", neverPressed, false, true),
                    ("pressed, model not whole (the panel and the menu show the download)", pressed, false, false),
                    ("pressed, model whole (after Finish and a relaunch)", pressed, true, false),
                    ("index deleted, model not whole", deleted, false, false),
                    ("index deleted, model whole (the person starts again from Settings)", deleted, true, false),
                ]
                for row in table {
                    #expect(AppDelegate.showsSetup(settings: row.settings, modelWhole: row.whole) == row.shows, "launch with \(row.name)")
                    #expect(AppDelegate.showsSetup(settings: row.settings, modelWhole: row.whole)
                                == SetupFlow.needed(settings: row.settings, modelWhole: row.whole),
                            "the delegate and the rule disagree for \(row.name)")
                }
            }
        }
    }
}

// =================================================================================================================
// plan-2 fix round B, tester step: B2 (Finish, `setupFinished`, step names), B4 (the total
// line and the per-photo note), B6 (the damaged model after Start, settings.folders never rewritten from the defaults),
// B9 (Start goes through the supervisor). Written from the fix-round document (Rulings and items B2, B4, B6, B9), the
// review report (R2-07, R2-09, R2-10, R2-13 and the noted Setup-Start item) and the sealed tests above. No product
// source was read. Every expected text, count and flag is written by hand from the folders each test builds.
//
// API SHAPES these tests pin (new unless said):
//   B2. Finish (on the Shortcut step) writes `setupFinished` true to settings.json and, for every ticked row of the
//       folder step, a folder entry with `ticked` true and `reading` false (a pending tick: Settings shows it ticked and
//       waiting). It never writes `startPressed` and starts nothing. Start also writes `setupFinished` true. A row that is
//       not ticked is either not written or written with `ticked` false and `reading` false. `SetupFlow.needed` and
//       `AppDelegate.showsSetup` know `setupFinished` (SetupFlowTests). The step header names are drawn: a text that is
//       exactly the step's name, or one that holds the name beside "Step <n> of 4".
//   B4. On the Folders step, once the model is whole and a photo speed is known, a text reads "About <time> in total" (the
//       time is the Estimator's words for the ticked folders' counts, `about 5 min` for 100 photos at 3.0 s, so the line
//       is "About 5 min in total"). Plan-9-t8 amended B4: the text "Photos: about <n> s each" left the screen text, so
//       "Photos: about" is in no step's texts. While the speed is not known, or the model is not whole, no total text is
//       shown and the existing wording stays ("measuring speed", "after the model download"), now read from the control
//       labels only: neither phrase is in any text.
//   B6. `SetupFolders` takes its rows from `settings.folders` merged with the five suggestions: a folder the settings hold
//       is a row, ticked as its `ticked` (else `reading`) says; a suggestion the settings do not hold is a row, unticked
//       when the settings hold any folder. With empty `settings.folders` the rows are the suggestions, ticked, as the sealed
//       tests pin. Start in a setup window then writes the rows, so it never drops the person's folders or turns the
//       defaults on. After Start was pressed the window offers no enabled Start (SetupModelTests pins the model).
//   B9. `SetupWindow.init` gains a last parameter, `onStarted: (@MainActor () -> Void)? = nil`. When it is given, Start
//       (after writing settings.json and telling the status cache) calls it once INSTEAD of `helper.sendFolders()`; the app
//       passes the supervisor's `reevaluate()`. When it is nil the window keeps today's direct `helper.sendFolders()`, so
//       every sealed test above still passes.
// =================================================================================================================

private let ssReadNote = "Photos, PDFs, documents, audio and video are read."

private final class SSSender: FoldersSender, @unchecked Sendable {
    func sendFolders() {}
}

@MainActor
private final class SSHost: IndexHost {
    private(set) var isRunning = false
    var onExit: ((HelperExit) -> Void)?
    private(set) var log: [String] = []
    func start() { log.append("start"); isRunning = true }
    func stopClean() { log.append("stop") }
}

private extension SSEnv {
    func entry(_ path: String) -> NSDictionary? { folderEntriesOnDisk().first { ($0["path"] as? String) == path } }

    // The tick as the file holds it: the `ticked` key, else `reading`.
    func tickedOnDisk(_ path: String) -> Bool? {
        let found = entry(path)
        return (found?["ticked"] as? Bool) ?? (found?["reading"] as? Bool)
    }

    func readingOnDisk(_ path: String) -> Bool? { entry(path)?["reading"] as? Bool }

    // Writes settings.json through SettingsFile. `ticked` nil leaves the key out (the older shape).
    func seed(folders: [(path: String, reading: Bool, ticked: Bool?)] = [], startPressed: Bool, indexDeleted: Bool = false) throws {
        let entries = folders.map { folder -> String in
            let tick = folder.ticked.map { ", \"ticked\": \($0)" } ?? ""
            return "{\"path\": \"\(folder.path)\", \"code\": false, \"reading\": \(folder.reading)\(tick)}"
        }.joined(separator: ", ")
        let json = """
        {
          "version": 3,
          "startPressed": \(startPressed),
          "indexDeleted": \(indexDeleted),
          "folders": [\(entries)],
          "codeSearchOn": false,
          "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
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
private func ssWindow(_ env: SSEnv, prepared: SSFiles, folders: SetupFolders, onStarted: (@MainActor () -> Void)? = nil) throws -> SetupWindow {
    let window: SetupWindow
    if let onStarted {
        window = SetupWindow(files: prepared.files, folders: folders, helper: try ssStubClient(env),
                             status: ssQuietStatus(counter: SSCount()), onStarted: onStarted)
    } else {
        window = SetupWindow(files: prepared.files, folders: folders, helper: try ssStubClient(env),
                             status: ssQuietStatus(counter: SSCount()))
    }
    window.isReleasedWhenClosed = false
    window.refresh()
    return window
}

// Walks to `step` by pressing Next, as a person does.
@MainActor
@discardableResult
private func ssWalk(_ window: SetupWindow, to step: SetupFlow.Step) async -> Bool {
    while window.flow.step != step {
        guard await ssAdvance(in: window) else { return false }
    }
    window.refresh()
    return true
}

extension ModelDownloadTests.SetupScreenTests {

    // MARK: B2: Finish, setupFinished, the step names

    @MainActor
    @Test func finishKeepsTheTickedFoldersAsWaitingTicksMarksSetupFinishedAndStartsNothing() async throws {
        try await ssRun { env in
            // the model is still downloading when the person finishes, and never pressed Start
            let prepared = try ssPrepareFiles(.downloading, env: env)
            let (folders, _) = try ssBuildFolders(env, state: .downloading)   // Pictures 100 photos, Desktop 3 docs, Documents 2 pdfs
            #expect(await ssReady(folders))
            let window = try ssWindow(env, prepared: prepared, folders: folders)
            folders.setTicked(env.path("Documents"), false)

            #expect(await ssWalk(window, to: .shortcut), "could not walk to the Shortcut step")
            #expect(await ssPress("Finish", in: window), "no enabled Finish on Shortcut")
            try? await Task.sleep(nanoseconds: 400_000_000)

            let onDisk = try #require(env.settingsDictionary(), "Finish wrote no settings.json: the picked folders are lost")
            #expect(onDisk["setupFinished"] as? Bool == true, "setupFinished on disk: \(String(describing: onDisk["setupFinished"]))")
            #expect((onDisk["startPressed"] as? Bool ?? false) == false, "Finish pressed Start")
            #expect((onDisk["indexDeleted"] as? Bool ?? false) == false)
            for name in ["Desktop", "Pictures"] {
                #expect(env.entry(env.path(name)) != nil, "the picked folder \(name) is not in settings.json: \(env.folderEntriesOnDisk())")
                #expect(env.tickedOnDisk(env.path(name)) == true, "\(name) is not stored as a pending tick: \(env.folderEntriesOnDisk())")
                #expect(env.readingOnDisk(env.path(name)) == false, "\(name) is reading although Start was never pressed")
            }
            // the unticked folder is either left out or stored unticked, and never reads
            #expect(env.entry(env.path("Documents")) == nil || env.tickedOnDisk(env.path("Documents")) == false,
                    "Documents was unticked, yet: \(String(describing: env.entry(env.path("Documents"))))")
            #expect(env.folderEntriesOnDisk().allSatisfy { ($0["reading"] as? Bool) != true }, "a folder is reading: \(env.folderEntriesOnDisk())")
            #expect(!env.helperWasStarted, "Finish started a helper")

            // the rule: setup is done, with the model whole or not
            let settings = try SettingsFile().read()
            #expect(!SetupFlow.needed(settings: settings, modelWhole: false), "setup comes back after Finish with the model not whole")
            #expect(!SetupFlow.needed(settings: settings, modelWhole: true), "setup comes back after Finish with the model whole")
            #expect(!AppDelegate.showsSetup(settings: settings, modelWhole: false))

            // Settings shows the picked folders ticked and waiting for Start indexing
            let model = SettingsModel(sender: SSSender(), modelWhole: { false })
            #expect(await ssEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } })
            let screen = SettingsScreen(model: model)
            for name in ["Desktop", "Pictures"] {
                let row = try #require(screen.folderRows.first { $0.name == name }, "Settings has no row for \(name): \(screen.folderRows.map { $0.name })")
                #expect(row.tick.isOn == true, "\(name) is not ticked in Settings")
                #expect(row.detail.contains("Waiting for Start indexing"), "\(name) detail: \"\(row.detail)\"")
            }
        }
    }

    @MainActor
    @Test func startAlsoMarksSetupFinished() async throws {
        try await ssRun { env in
            let prepared = try ssPrepareFiles(.whole, env: env)
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))
            let window = try ssWindow(env, prepared: prepared, folders: folders)
            #expect(await ssWalk(window, to: .folders))
            #expect(await ssPress("Start indexing", in: window), "Start indexing could not be pressed")
            let onDisk = try #require(env.settingsDictionary())
            #expect(onDisk["startPressed"] as? Bool == true)
            #expect(onDisk["setupFinished"] as? Bool == true, "setupFinished on disk after Start: \(String(describing: onDisk["setupFinished"]))")
        }
    }

    @MainActor
    @Test func theLaunchRuleKnowsSetupFinished() async throws {
        try await ssRun { env in
            let finished = try JSONDecoder().decode(Settings.self, from: Data("""
            {"version": 3, "startPressed": false, "indexDeleted": false, "folders": [], "codeSearchOn": false,
             "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
             "hotkey": "cmd+opt+k", "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
             "speeds": {"photo": 1.5}, "loginDefaultApplied": true, "setupFinished": true}
            """.utf8))
            for whole in [true, false] {
                #expect(!AppDelegate.showsSetup(settings: finished, modelWhole: whole), "setup is shown after Finish, model whole \(whole)")
            }
            _ = env
        }
    }

    @MainActor
    @Test func eachStepDrawsItsNameAsTheHeader() async throws {
        try await ssRun { env in
            let model = ssMakeModel(try ssPrepareFiles(.whole, env: env))
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))
            for (index, entry) in ssSteps.enumerated() {
                let screen = SetupScreen(flow: ssFlow(at: entry.step), model: model, folders: folders)
                let drawn = screen.texts.contains { $0 == entry.title || ($0.contains(entry.title) && $0.contains("Step \(index + 1) of 4")) }
                #expect(drawn, "\(entry.title): no header text names the step, texts: \(screen.texts)")
            }
        }
    }

    // MARK: the read note

    @MainActor
    @Test func theFoldersStepSaysWhatIsReadOnceAndNeverSaysOnlyPhotosAreRead() async throws {
        try await ssRun { env in
            let model = ssMakeModel(try ssPrepareFiles(.whole, env: env))
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))
            let screen = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
            #expect(screen.texts.filter { $0 == ssReadNote }.count == 1, "the read note is not exactly once in \(screen.texts)")
            for (title, step) in ssSteps {
                let other = SetupScreen(flow: ssFlow(at: step), model: model, folders: folders)
                #expect(!other.texts.contains { $0.contains("Only photos are read") }, "\(title): the old line is shown: \(other.texts)")
                if step != .folders { #expect(!other.texts.contains(ssReadNote), "\(title) carries the read note") }
            }
        }
    }

    @MainActor
    @Test func theSetupWindowShowsTheReadNoteOnceAndNotTheOldLine() async throws {
        try await ssRun { env in
            let prepared = try ssPrepareFiles(.whole, env: env)
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))
            let window = try ssWindow(env, prepared: prepared, folders: folders)
            #expect(await ssWalk(window, to: .folders))
            let root = try #require(window.contentView, "no content view")
            window.refresh()
            root.layoutSubtreeIfNeeded()
            let shown = prShownTexts(root)
            #expect(shown.filter { $0 == ssReadNote }.count == 1, "the read note is not shown exactly once in \(shown)")
            #expect(!shown.contains { $0.contains("Only photos are read") }, "the old line is shown: \(shown)")
        }
    }

    // MARK: B4: the total line and the per-photo note

    @MainActor
    @Test func theFolderStepShowsATotalAndAPerPhotoSpeedOnceTheModelIsWholeAndASpeedIsKnown() async throws {
        try await ssRun { env in
            let model = ssMakeModel(try ssPrepareFiles(.whole, env: env))
            let (folders, kit) = try ssBuildFolders(env, state: .whole)   // photo 3.0 s; Pictures 100 photos, Desktop 3 docs, Documents 2 pdfs
            #expect(await ssReady(folders))

            // 100 photos x 3.0 s = 300 s
            let screen = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
            #expect(screen.texts.contains("About 5 min in total"), "no total line among \(screen.texts)")
            #expect(!screen.texts.contains { $0.hasPrefix("Photos: about") }, "the per-photo note is still among \(screen.texts)")

            // a speed with a decimal: 100 x 1.5 s = 150 s
            kit.speeds.value = ["photo": 1.5]
            folders.refreshEstimates()
            let slower = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
            #expect(!slower.texts.contains { $0.hasPrefix("Photos: about") }, "the per-photo note is still among \(slower.texts)")
            #expect(slower.texts.contains { $0.hasPrefix("About ") && $0.hasSuffix(" in total") }, "no total line among \(slower.texts)")

            // the total and the note belong to the folder step
            for (title, step) in ssSteps where step != .folders {
                let other = SetupScreen(flow: ssFlow(at: step), model: model, folders: folders)
                #expect(!other.texts.contains { $0.hasSuffix(" in total") || $0.hasPrefix("Photos: about") }, "\(title) carries the total or the note: \(other.texts)")
            }
        }
    }

    @MainActor
    @Test func untilTheSpeedsAreKnownOrWhileTheModelIsNotWholeTheOldWordsStayAndThereIsNoTotal() async throws {
        // the model is whole but no speed is measured yet
        try await ssRun { env in
            let model = ssMakeModel(try ssPrepareFiles(.whole, env: env))
            let (folders, kit) = try ssBuildFolders(env, state: .whole)
            kit.speeds.value = [:]
            folders.refreshEstimates()
            #expect(await ssReady(folders))
            let screen = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
            #expect(screen.ssLabels.contains { $0.contains("measuring speed") }, "no \"measuring speed\" among the labels \(screen.ssLabels)")
            #expect(!screen.texts.contains { $0.contains("measuring speed") }, "\"measuring speed\" is in the texts \(screen.texts)")
            #expect(!screen.texts.contains { $0.hasSuffix(" in total") }, "a total without speeds: \(screen.texts)")
            #expect(!screen.texts.contains { $0.hasPrefix("Photos: about") }, "a per-photo note without speeds: \(screen.texts)")
        }
        // the model is not whole
        try await ssRun { env in
            let model = ssMakeModel(try ssPrepareFiles(.downloading, env: env))
            let (folders, _) = try ssBuildFolders(env, state: .downloading)
            #expect(await ssReady(folders))
            let screen = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
            #expect(screen.ssLabels.contains { $0.contains("after the model download") }, "no \"after the model download\" among the labels \(screen.ssLabels)")
            #expect(!screen.texts.contains { $0.contains("after the model download") }, "\"after the model download\" is in the texts \(screen.texts)")
            #expect(!screen.texts.contains { $0.hasSuffix(" in total") }, "a total before the model download: \(screen.texts)")
            #expect(!screen.texts.contains { $0.hasPrefix("Photos: about") }, "a per-photo note before the model download: \(screen.texts)")
        }
    }

    // MARK: B6: the damaged model after Start, and the person's folders

    @MainActor
    @Test func aSetupWindowBuiltAfterStartOffersNoEnabledStartWhileDamagedAndNoneOnceTheModelIsWholeAgain() async throws {
        try await ssRun { env in
            let prepared = try ssPrepareFiles(.whole, env: env)
            // Start was pressed earlier and the person's folder is in the settings before the window is built
            let trips = try env.fill("Trips", photo: 2)
            try env.seed(folders: [(trips.path, true, nil)], startPressed: true)
            let bytes = try Data(contentsOf: env.settings)
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))

            // the re-show after the model was found damaged: a new window, built after Start was pressed
            let window = try ssWindow(env, prepared: prepared, folders: folders)
            let wholeFile = env.whole(prepared.files[0].name)
            let kept = try Data(contentsOf: wholeFile)
            try FileManager.default.removeItem(at: wholeFile)
            window.model.modelWasDamaged()
            #expect(await ssWalk(window, to: .folders))
            #expect(window.setupScreen.texts.joined(separator: "\n").contains(ssDamagedMessage), "no damaged message: \(window.setupScreen.texts)")
            #expect(window.setupScreen.ssLabels.contains("Model download"), "no download progress: \(window.setupScreen.ssLabels)")
            #expect(!window.setupScreen.ssEnabled("Start indexing"), "an enabled Start while the model is damaged")

            // the model is whole again: still no Start
            try kept.write(to: wholeFile)
            window.refresh()
            #expect(!window.setupScreen.ssEnabled("Start indexing"), "an enabled Start once the model is whole again after Start was pressed (R2-13)")
            #expect(!window.setupScreen.ssShows("Start indexing") && !window.setupScreen.ssShows("Not now"), "Start indexing or Not now is shown after Start was pressed: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
            #expect(window.setupScreen.ssEnabled("Next"), "the footer does not read Next after Start was pressed: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
            #expect(!(await ssPress("Start indexing", in: window)), "Start indexing could be pressed")
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(try Data(contentsOf: env.settings) == bytes, "the person's folders were rewritten: \(env.folderEntriesOnDisk())")
            #expect(!env.helperWasStarted && env.foldersLines().isEmpty, "a folders command was sent")
        }
    }

    // GUARD: passes today. A setup where Start was never pressed keeps offering Start once the model is whole.
    @MainActor
    @Test func aSetupWhereStartWasNeverPressedStillOffersStartOnceTheModelIsWhole() async throws {
        try await ssRun { env in
            let prepared = try ssPrepareFiles(.whole, env: env)
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))
            let window = try ssWindow(env, prepared: prepared, folders: folders)
            #expect(await ssWalk(window, to: .folders))
            #expect(window.setupScreen.ssEnabled("Start indexing"))
        }
    }

    @MainActor
    @Test func theRowsComeFromSettingsFoldersMergedWithTheSuggestionsAsUnticked() async throws {
        try await ssRun { env in
            _ = try env.fill("Desktop", photo: 4)
            _ = try env.fill("Documents", pdf: 2)
            let pictures = try env.fill("Pictures", photo: 6)
            let trips = try env.fill("Trips", photo: 10)
            // the person picked Pictures and Trips only
            try env.seed(folders: [(pictures.path, true, nil), (trips.path, true, nil)], startPressed: true)
            let kit = SSKit(modelWhole: true)
            let folders = kit.makeFolders(home: env.home)
            #expect(await ssReady(folders))

            let byPath = Dictionary(grouping: folders.rows, by: { $0.path })
            #expect(byPath.values.allSatisfy { $0.count == 1 }, "a folder is listed twice: \(folders.rows.map { $0.path })")
            #expect(byPath[trips.path]?.first?.ticked == true, "the person's own folder is missing or unticked: \(folders.rows.map { ($0.name, $0.ticked) })")
            #expect(byPath[pictures.path]?.first?.ticked == true, "Pictures was picked and is unticked: \(folders.rows.map { ($0.name, $0.ticked) })")
            for name in ["Desktop", "Documents"] {
                let row = byPath[env.path(name)]?.first
                #expect(row != nil, "the suggestion \(name) is not listed")
                #expect(row?.ticked == false, "the suggestion \(name) is ticked although the person's folders are in the settings")
            }
            #expect(Set(folders.rows.filter { $0.ticked }.map { $0.path }) == [pictures.path, trips.path],
                    "ticked rows: \(folders.rows.filter { $0.ticked }.map { $0.name })")
            if let tripsRow = byPath[trips.path]?.first {
                #expect(tripsRow.counts["photo"] == 10, "Trips counts: \(tripsRow.counts)")
            }
        }
    }

    @MainActor
    @Test func startInASetupWindowNeverDropsThePersonsFoldersOrTurnsTheDefaultsOn() async throws {
        try await ssRun { env in
            let prepared = try ssPrepareFiles(.whole, env: env)
            let (folders, _) = try ssBuildFolders(env, state: .whole)   // Pictures, Desktop and Documents exist
            let trips = try env.fill("Trips", photo: 2)
            // settings that already hold the person's folders; Start was not pressed (a setup shown again)
            try env.seed(folders: [(trips.path, true, nil)], startPressed: false)
            let rebuilt = SSKit(modelWhole: true).makeFolders(home: env.home)
            #expect(await ssReady(rebuilt))
            _ = folders
            let window = try ssWindow(env, prepared: prepared, folders: rebuilt)
            #expect(await ssWalk(window, to: .folders))
            #expect(window.setupScreen.ssEnabled("Start indexing"), "setup: Start must be available here")
            #expect(await ssPress("Start indexing", in: window))

            #expect(env.readingOnDisk(trips.path) == true, "the person's folder is not read after Start: \(env.folderEntriesOnDisk())")
            for name in ["Desktop", "Documents", "Pictures"] {
                #expect(env.readingOnDisk(env.path(name)) != true, "the default \(name) was turned on by Start: \(env.folderEntriesOnDisk())")
            }
            let arrived = await ssEventually { !env.foldersLines().isEmpty }
            #expect(arrived, "no folders command reached the helper")
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let line = env.foldersLines().first,
               let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               let sent = object["folders"] as? [[String: Any]] {
                #expect(Set(sent.compactMap { $0["path"] as? String }) == [trips.path], "the folders command named \(sent)")
            } else {
                Issue.record("the folders command is not a JSON object with a folders list: \(env.foldersLines())")
            }
        }
    }

    // MARK: B9: Start goes through the supervisor

    @MainActor
    @Test func startInTheSetupWindowStartsNoHelperWhileAPauseReasonHoldsAndOneAfterItIsGone() async throws {
        try await ssRun { env in
            let prepared = try ssPrepareFiles(.whole, env: env)
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))
            let host = SSHost()
            let pauses = SSBox<Set<PauseReason>>([.battery])
            let supervisor = HelperSupervisor(host: host, inputs: {
                let settings = (try? SettingsFile().read()) ?? Settings()
                return HelperSupervisor.Inputs(startPressed: settings.startPressed, indexDeleted: settings.indexDeleted,
                                               modelWhole: true, pauseReasons: pauses.value, quitting: false)
            })
            let window = try ssWindow(env, prepared: prepared, folders: folders, onStarted: { supervisor.reevaluate() })
            #expect(await ssWalk(window, to: .folders))

            #expect(await ssPress("Start indexing", in: window), "Start indexing could not be pressed")
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(env.startPressedOnDisk(), "Start did not write startPressed")
            #expect(host.log.isEmpty, "the supervisor started the helper while the battery pause holds: \(host.log)")
            #expect(!env.helperWasStarted, "Start sent folders to a helper directly while paused (S7.3, S7.17): \(env.helperLines("index"))")
            #expect(env.foldersLines().isEmpty, "a folders command was sent while paused: \(env.foldersLines())")

            // the pause is over: the one start comes from the supervisor
            pauses.value = []
            supervisor.reevaluate()
            #expect(host.log == ["start"], "after the pause the supervisor made \(host.log)")
        }
    }

    @MainActor
    @Test func startInTheSetupWindowWithNoPauseMakesExactlyOneStartThroughTheSupervisorAndNoDirectSend() async throws {
        try await ssRun { env in
            let prepared = try ssPrepareFiles(.whole, env: env)
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))
            let host = SSHost()
            let supervisor = HelperSupervisor(host: host, inputs: {
                let settings = (try? SettingsFile().read()) ?? Settings()
                return HelperSupervisor.Inputs(startPressed: settings.startPressed, indexDeleted: settings.indexDeleted,
                                               modelWhole: true, pauseReasons: [], quitting: false)
            })
            let window = try ssWindow(env, prepared: prepared, folders: folders, onStarted: { supervisor.reevaluate() })
            #expect(await ssWalk(window, to: .folders))
            #expect(await ssPress("Start indexing", in: window))
            try? await Task.sleep(nanoseconds: 500_000_000)

            #expect(host.log == ["start"], "the supervisor's start: \(host.log)")
            #expect(!env.helperWasStarted, "the window also sent folders to the helper itself: \(env.helperLines("index"))")
            #expect(env.foldersLines().isEmpty, "a direct folders command: \(env.foldersLines())")
        }
    }
}

// =================================================================================================================
// plan-2 fix round D, tester step, item D4 (R3-05): in a setup window shown after Start was pressed (the launch rule
// "Start pressed, model not whole -> setup shown", and the damaged-model re-show), the folder rows' ticks and Add folder are
// disabled, display only, because Finish then writes only the flag and a tick or a folder added there would be lost
// silently. Written from the fix-round document (D4) and the review report (R3-05: `SetupModel.swift:132-151` Finish writes
// only the flag after Start). No product source was read. Every expected flag is written by hand.
//
// NO NEW NAME. The rule uses what the model already knows: `SetupModel` reads `startPressed` from settings.json at `init`
// and at each `refresh()` (fix round B6). So in `SetupScreen(flow:model:folders:)` built over such a model, on the Folders
// step:
//   - the button "Add folder\u{2026}" is still shown and is not enabled (display only: it is not removed),
//   - every folder row's control (label "<name>, <counts>, <estimate>", the ordinary rows) is not enabled,
//   - "Start indexing" is not enabled (B6, sealed), Back and Next stay enabled (S6.5), and Finish on the Shortcut step stays
//     enabled.
// It holds for every model state, whole included: a window built after Start offers no change of the folders at all.
// Through the window: the NSButton "Add folder\u{2026}" and the row controls are disabled, so a press changes no row.
// =================================================================================================================

extension ModelDownloadTests.SetupScreenTests {

    // MARK: D4, the screen

    @MainActor
    @Test func inASetupShownAfterStartTheFolderTicksAndAddFolderAreDisabledForEveryModelState() async throws {
        for state in SSState.allCases {
            try await ssRun { env in
                let prepared = try ssPrepareFiles(state, env: env)
                // Start was pressed earlier; the person's folder Trips is in settings.json, read as it was ticked
                let trips = try env.fill("Trips", photo: 2)
                try env.seed(folders: [(trips.path, true, nil)], startPressed: true)
                let (folders, _) = try ssBuildFolders(env, state: state)   // Pictures, Desktop, Documents exist (suggestions)
                #expect(await ssReady(folders), "\(state): the rows never became ready")
                let model = ssMakeModel(prepared)

                let screen = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
                let where_ = "\(state)"
                #expect(screen.ssShows("Add folder\u{2026}"), "\(where_): Add folder\u{2026} was removed; it must stay, disabled: \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(!screen.ssEnabled("Add folder\u{2026}"), "\(where_): Add folder\u{2026} is enabled in a setup shown after Start: a folder added there is lost (R3-05)")
                for name in ["Trips", "Pictures", "Desktop", "Documents"] {
                    let row = screen.controls.first { $0.label.hasPrefix(name + ", ") }
                    #expect(row != nil, "\(where_): no row for \(name) in \(screen.ssLabels)")
                    #expect(row?.isEnabled == false, "\(where_): the tick of \(name) is enabled in a setup shown after Start: a change there is lost (R3-05)")
                }
                #expect(!screen.ssEnabled("Start indexing"), "\(where_): Start indexing is enabled after Start was pressed")
                #expect(!screen.ssShows("Start indexing") && !screen.ssShows("Not now"), "\(where_): Start indexing or Not now is shown after Start was pressed: \(screen.buttons.map { ($0.title, $0.isEnabled) })")
                #expect(screen.ssEnabled("Back") && screen.ssEnabled("Next"), "\(where_): Back or Next lost: \(screen.buttons.map { ($0.title, $0.isEnabled) })")

                let last = SetupScreen(flow: ssFlow(at: .shortcut), model: model, folders: folders)
                #expect(last.ssEnabled("Finish"), "\(where_): Finish is not enabled on the Shortcut step")
            }
        }
    }

    // GUARD: passes today. Before Start the ticks and Add folder work, with the model downloading or whole.
    @MainActor
    @Test func beforeStartTheFolderTicksAndAddFolderStayEnabledWithTheModelDownloadingOrWhole() async throws {
        for state in [SSState.downloading, SSState.whole] {
            try await ssRun { env in
                let prepared = try ssPrepareFiles(state, env: env)
                try env.seed(folders: [], startPressed: false)
                let (folders, _) = try ssBuildFolders(env, state: state)
                #expect(await ssReady(folders), "\(state): the rows never became ready")
                let model = ssMakeModel(prepared)
                let screen = SetupScreen(flow: ssFlow(at: .folders), model: model, folders: folders)
                #expect(screen.ssEnabled("Add folder\u{2026}"), "\(state): Add folder\u{2026} is disabled before Start")
                for name in ["Pictures", "Desktop", "Documents"] {
                    #expect(screen.controls.first { $0.label.hasPrefix(name + ", ") }?.isEnabled == true, "\(state): the tick of \(name) is disabled before Start")
                }
            }
        }
    }

    // MARK: D4, the window

    @MainActor
    @Test func aSetupWindowShownAfterStartCannotAddAFolderOrChangeATick() async throws {
        try await ssRun { env in
            let prepared = try ssPrepareFiles(.downloading, env: env)
            let trips = try env.fill("Trips", photo: 2)
            try env.seed(folders: [(trips.path, true, nil)], startPressed: true)
            let bytes = try Data(contentsOf: env.settings)
            let (folders, kit) = try ssBuildFolders(env, state: .downloading)
            #expect(await ssReady(folders))
            let window = try ssWindow(env, prepared: prepared, folders: folders)
            #expect(await ssWalk(window, to: .folders))

            let rowsBefore = folders.rows.map { ($0.path, $0.ticked) }
            #expect(!rowsBefore.isEmpty)

            // Add folder is there and cannot be pressed: the picker is never asked, no row is added
            let extra = try env.fill("Extra", photo: 4)
            kit.picks.value = [extra]
            #expect(ssButton("Add folder\u{2026}", in: window) != nil, "the Add folder\u{2026} button was removed")
            #expect(!(await ssPress("Add folder\u{2026}", in: window)), "Add folder\u{2026} could be pressed after Start")
            #expect(folders.rows.map { $0.path } == rowsBefore.map { $0.0 }, "a folder was added after Start: \(folders.rows.map { $0.path })")

            // every row's control in the window is disabled, and a press on one changes no tick
            guard let root = window.contentView else { Issue.record("the window has no content view"); return }
            let rowControls = prViews(root).compactMap { $0 as? NSControl }.filter { control in
                !control.isHiddenOrHasHiddenAncestor && ["Trips", "Pictures", "Desktop", "Documents"].contains { (control.accessibilityLabel() ?? "").hasPrefix($0 + ", ") }
            }
            #expect(rowControls.count >= 4, "found \(rowControls.count) row controls in the window")
            for control in rowControls {
                #expect(!control.isEnabled, "the row control \"\(control.accessibilityLabel() ?? "")\" is enabled in a window shown after Start")
                (control as? NSButton)?.performClick(nil)
            }
            #expect(folders.rows.map { $0.ticked } == rowsBefore.map { $0.1 }, "a tick changed after Start: \(folders.rows.map { ($0.name, $0.ticked) })")
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(try Data(contentsOf: env.settings) == bytes, "settings.json changed in a window shown after Start")
        }
    }
}

private let ssWelcomeTexts = [
    "Step 1 of 4: Welcome",
    "Welcome to Sesame",
    "Search your files by what is inside them.",
    "Search by meaning",
    "Type what a photo shows or what a document says.",
    "Private by design",
    "Everything stays on this Mac.",
    "You choose when",
    "Nothing is read until you press Start indexing.",
]

private let ssOldWelcomeBody = "Sesame finds files by what is inside them. Everything stays on this Mac."
private let ssOldReadyLine = "The model is ready."

extension ModelDownloadTests.SetupScreenTests {

    @MainActor
    @Test func theWelcomeStringsAreTheSublineTheThreePromisesAndTheReadyLine() {
        #expect(SetupScreen.welcomeSubline == "Search your files by what is inside them.")
        #expect(SetupScreen.modelReadyText == "Search model ready")
        let promises = SetupScreen.welcomePromises.map { [$0.symbol, $0.title, $0.detail] }
        #expect(promises == [
            ["doc.text", "Search by meaning", "Type what a photo shows or what a document says."],
            ["lock", "Private by design", "Everything stays on this Mac."],
            ["play.circle", "You choose when", "Nothing is read until you press Start indexing."],
        ], "the promises read \(promises)")
    }

    @MainActor
    @Test func theWelcomeTextsWithAWholeModelAreTheStepTheTitleTheSublineThePromisesAndTheReadyLineInThatOrder() async throws {
        try await ssRun { env in
            let model = ssMakeModel(try ssPrepareFiles(.whole, env: env))
            let (folders, _) = try ssBuildFolders(env, state: .whole)
            #expect(await ssReady(folders))
            let screen = SetupScreen(flow: ssFlow(at: .welcome), model: model, folders: folders)
            #expect(screen.texts == ssWelcomeTexts + ["Search model ready"], "the Welcome texts are \(screen.texts)")
        }
    }

    @MainActor
    @Test func theWelcomeTextsWithAModelThatIsNotWholeKeepTheNineLinesAndThenTheModelCardTexts() async throws {
        for state in [SSState.downloading, SSState.damaged, SSState.failed] {
            try await ssRun { env in
                let model = ssMakeModel(try ssPrepareFiles(state, env: env))
                let (folders, _) = try ssBuildFolders(env, state: state)
                #expect(await ssReady(folders), "\(state): the rows never became ready")
                let screen = SetupScreen(flow: ssFlow(at: .welcome), model: model, folders: folders)
                #expect(Array(screen.texts.prefix(9)) == ssWelcomeTexts, "\(state): the Welcome texts start \(screen.texts.prefix(9))")
                let rest = Array(screen.texts.dropFirst(9))
                #expect(rest.contains("The search model"), "\(state): no \"The search model\" after the nine lines in \(rest)")
                #expect(!screen.texts.contains("Search model ready"), "\(state): the ready line with a model that is not whole: \(screen.texts)")
                switch state {
                case .downloading: #expect(rest.contains { $0.contains(ssProgressText) }, "\(state): no \"\(ssProgressText)\" in \(rest)")
                case .damaged: #expect(rest.contains(ssDamagedMessage), "\(state): no damaged message in \(rest)")
                case .failed: #expect(rest.contains { $0.contains(ssFailedMessage) }, "\(state): no failure text in \(rest)")
                case .whole: break
                }
            }
        }
    }

    @MainActor
    @Test func theOldWelcomeBodyAndTheOldReadyLineAreGoneAndTheNoteIsShownOnceOnWelcomeOnly() async throws {
        for state in SSState.allCases {
            try await ssRun { env in
                let model = ssMakeModel(try ssPrepareFiles(state, env: env))
                let (folders, _) = try ssBuildFolders(env, state: state)
                #expect(await ssReady(folders), "\(state): the rows never became ready")
                for (title, step) in ssSteps {
                    let screen = SetupScreen(flow: ssFlow(at: step), model: model, folders: folders)
                    #expect(!screen.texts.contains(ssOldWelcomeBody), "\(state) / \(title): the old Welcome body is shown")
                    #expect(!screen.texts.contains(ssOldReadyLine), "\(state) / \(title): the old ready line is shown")
                    let notes = screen.texts.filter { $0 == "Nothing is read until you press Start indexing." }.count
                    #expect(notes == (step == .welcome ? 1 : 0), "\(state) / \(title): the note is shown \(notes) times")
                }
            }
        }
    }

    @MainActor
    @Test func theOtherStepsHaveNoWelcomeTextsAndTheirModelLineIsTheReadyLineOrTheModelCard() async throws {
        for state in SSState.allCases {
            try await ssRun { env in
                let model = ssMakeModel(try ssPrepareFiles(state, env: env))
                let (folders, _) = try ssBuildFolders(env, state: state)
                #expect(await ssReady(folders), "\(state): the rows never became ready")
                for (index, entry) in ssSteps.enumerated() where entry.step != .welcome {
                    let screen = SetupScreen(flow: ssFlow(at: entry.step), model: model, folders: folders)
                    let where_ = "\(state) / \(entry.title)"
                    #expect(screen.texts.contains("Step \(index + 1) of 4: \(entry.title)"), "\(where_): the step text is gone from \(screen.texts)")
                    for line in ssWelcomeTexts.dropFirst() where line != "Nothing is read until you press Start indexing." {
                        #expect(!screen.texts.contains(line), "\(where_): the Welcome line \"\(line)\" is on this step")
                    }
                    if state == .whole {
                        #expect(screen.texts.contains("Search model ready"), "\(where_): no ready line in \(screen.texts)")
                        #expect(!screen.texts.contains("The search model"), "\(where_): the model heading with a whole model")
                    } else {
                        #expect(screen.texts.contains("The search model"), "\(where_): no model heading in \(screen.texts)")
                        #expect(!screen.texts.contains("Search model ready"), "\(where_): the ready line with a model that is not whole")
                    }
                }
            }
        }
    }

    @MainActor
    @Test func theStepTextIsInTheTextsOfAllFourStepsForEveryModelState() async throws {
        for state in SSState.allCases {
            try await ssRun { env in
                let model = ssMakeModel(try ssPrepareFiles(state, env: env))
                let (folders, _) = try ssBuildFolders(env, state: state)
                #expect(await ssReady(folders), "\(state): the rows never became ready")
                let names = ["Welcome", "Folders", "Permissions", "Shortcut"]
                for (index, entry) in ssSteps.enumerated() {
                    let screen = SetupScreen(flow: ssFlow(at: entry.step), model: model, folders: folders)
                    #expect(screen.texts.contains("Step \(index + 1) of 4: \(names[index])"), "\(state) / \(entry.title): no step text in \(screen.texts)")
                }
            }
        }
    }
}
