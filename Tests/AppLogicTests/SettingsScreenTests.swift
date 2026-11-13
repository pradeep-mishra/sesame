import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t25, tester step. Written from the t25 entry of plan-2-tasks.md (its Tests paragraph), the Conventions and
// Decisions D11 of that file, spec S1.29, S1.30, S6.9, S6.10 and S7.9, verify.md K20, the F3 mockup (f3-settings.html,
// read as the picture of the screen, not as a contract) and the plan-1 and plan-2 test files as the one place the
// existing names are read (`SettingsModel`, `FoldersSender`, `FolderRow` and `Estimator` texts of `SettingsModelTests`,
// `SettingsWindow.isOpenCommand` of `ShortcutControlTests`, the offscreen key-view walk of `SetupScreenTests`).
// No product source was read. Every expected text, count and flag below is written by hand from the folders and the
// settings each test builds. The window is built and read offscreen as `PanelRig` does: it is never ordered front, never
// made key, and no app is launched. No helper is started: the model gets a recording `FoldersSender`.
//
// SUITE PLACEMENT. HOME is process-wide (SettingsFile and SesameFolder read it), so this suite is nested inside
// `ModelDownloadTests` like the other Settings and Setup suites and runs one at a time with them. Side effect:
// `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin. The entry names `SettingsScreen`, `SettingsWindow.isOpenCommand` and the section, row and
// control texts, and fixes no signatures. If a shape below is wrong, ask for a test change rather than guessing.
//   1. `SettingsScreen` (the `Sesame` target) is a pure value, built by
//        SettingsScreen(model: SettingsModel, section: SettingsScreen.Section = .folders, confirmingRemoval: String? = nil)
//      from the model as it is now (rows, kinds, code switch; it may read `settings.json` through `SettingsFile`) and the
//      window state: the selected section and the path of the folder whose Remove confirm is open (nil: none). It holds
//      no window and changes nothing.
//        - `SettingsScreen.Section`: an enum, `CaseIterable`, `Equatable`, with the cases `.folders`, `.fileTypes`,
//          `.search`, `.indexing`, `.about` and `var title: String` ("Folders", "File types", "Search", "Indexing",
//          "About"). `screen.sections: [Section]` is all five in the sidebar order; `screen.section` is the selected one.
//          Search, Indexing and About are t26's: here they only have to exist as containers (the tests count them).
//        - `screen.texts: [String]`: every text a person can read in the selected section, one entry per label.
//        - `screen.controls: [SettingsScreen.Control]`: every control a person can reach in the selected section, in
//          reading order. A `Control` has `label: String` (its accessibility label), `isEnabled: Bool` and
//          `isOn: Bool?` (nil for a control that is not a switch or tick).
//        - `screen.folderRows: [SettingsScreen.FolderRow]`: Folders only (empty in the other sections), one per folder of
//          `model.rows`, in that order. A `FolderRow` has `path`, `name`, `detail: String` (the line a person reads
//          under the name: the counts, then the estimate or "Waiting for Start indexing"), and three `Control`s: `tick`
//          (the untick control: `isOn` is the row's tick), `reindex` (label "Re-index") and `remove` (label "Remove").
//          The three are also in `screen.controls`.
//        - `screen.confirm: SettingsScreen.Confirm?`: nil unless `confirmingRemoval` names a folder row; then it holds
//          `message: String` (names the folder), `confirmTitle: String` (the button that removes: not empty, not
//          "Cancel") and `cancelTitle: String` ("Cancel"). The confirm is inline, as the F3 mockup shows it; its two
//          buttons are NSButtons in the window while it is open.
//   2. What the sections hold (the entry's): Folders, a row per folder with counts, the estimate or "Waiting for Start
//      indexing", an untick control, "Re-index" and "Remove". A folder that is ticked in the model but whose `reading`
//      on disk is false (added, or ticked again, after the file was made: design section 3 "waits for the next Start")
//      shows "Waiting for Start indexing" instead of the estimate; a folder that is reading shows the estimate (the
//      `Estimator` texts of t21: 40 photos at 3.0 s is "about 2 min"; "after the model download" while the model is not
//      whole). File types: one switch per kind, labels starting "Photos", "PDFs", "Documents", "Audio", "Video", "Code"
//      (the F3 mockup's longer "Photos and screenshots" fits); Photos is the only enabled one and reads `kindsOn.photo`;
//      the other five are disabled and each carries the text "Not read in this version" (five texts that contain it);
//      the "Search my code" switch (label exactly that) is enabled and reads `codeSearchOn`; and, with it, one tick per
//      folder of `model.rows` for "search this folder as code" whose label starts with the folder's name, disabled and
//      off whether the switch is on or off (plan 2; plan 6 enables them).
//   3. `SettingsContainerWindow` (new, an `NSWindow` subclass; `SettingsWindow` stays the plan-1 enum with `title` and
//      `isOpenCommand`), built by `SettingsContainerWindow(model: SettingsModel)`. Properties: `model`,
//      `settingsScreen: SettingsScreen` (the value it draws; `screen` is taken by NSWindow), `func select(_ section:
//      SettingsScreen.Section)` (what a click on the sidebar item does), `func refresh()` (redraws from a new
//      `SettingsScreen`). It starts on Folders. Controls are `NSControl`s in `contentView` found by their accessibility
//      label or, for an `NSButton`, its title; a press is `performClick(nil)`, so a switch must toggle and act on
//      `performClick` (an `NSButton` in switch or checkbox style does; an `NSSwitch` is the implementer's to prove).
//      Every enabled control has an explicit accessibility label (a plain `NSButton` title is not one). The window redraws
//      itself after an action: a test never calls `refresh()` after pressing. Pressing a folder's tick calls
//      `model.setTicked`, "Remove" opens the confirm (`settingsScreen.confirm` is set; nothing else happens), the confirm's
//      cancel closes it, its confirm button calls `model.removeFolder(_, confirmed: true)`; the "Photos" switch calls
//      `model.setKind("photo", on:)`; "Search my code" calls `model.setCodeSearch(on:)`. Nothing is ordered front.
//   4. `SettingsWindow.title` is "Settings" and `SettingsWindow.isOpenCommand` is true for Command+comma ("cmd+,",
//      "cmd+comma") and for nothing else, as in plan 1 (kept). `ShortcutControlTests` and `FocusStabilityTests` are
//      separate Run lines and are not re-tested here.
//   5. Not pinned, on purpose: the wording of the counts beyond the numbers and the kind words, the estimate of a folder
//      that holds only PDFs or documents, the detail of an unticked folder, whether "Re-index" is enabled for a folder
//      that is not ticked, what "Re-index" does, the order and layout of the controls, how the sidebar is drawn, the
//      wording of the confirm message beyond the folder's name, the content of Search, Indexing and About, the look
//      against mockup F3 (the person's call at the accept stage).
//
// ---------------------------------------------------------------------------------------------------------------------
// plan-2-t26, tester step (Search, Indexing, About, the shortcut notice). Written from the t26 entry and Decisions D11 and
// D16 of plan-2-tasks.md, spec S1, S7, S8 and S3, design sections 1 and 6, the F3 mockup (a picture, not a contract), and
// the sealed plan-2 test files t4, t22, t23, t24 and t25 as the one place their names are read. No product source was
// read. The compiler's own messages showed two facts about the product that the entry does not state: the window's
// initialiser takes only `model:` today, and `AppDelegate` has a private instance `makeSettingsWindow()` that returns the
// plan-1 `ShortcutSettingsWindow`. No app is launched: the window is built and read offscreen, never ordered front. The
// 14 t25 tests above are unchanged (only the helper `STEnv.seed` gained two defaulted parameters).
//
// API SHAPES the t26 tests pin (the entry fixes no signatures; each is this file's pick; if one is wrong, ask for a test
// change rather than guessing). All in the `Sesame` target.
//   1. `SettingsContainerWindow.init(model:)` is kept, and a second initialiser takes the services the sections use:
//        SettingsContainerWindow(model: SettingsModel, shortcut: ShortcutControl, loginItem: LoginItem,
//                                appChoices: AppChoices, deleteIndex: DeleteIndex)
//      `init(model:)` builds the same window with the real ones (ShortcutControl(), the real LoginService, the real app
//      lookup, a DeleteIndex over the real IndexReader, HelperClient and SesameFolder). Every t26 test that presses
//      something other than a plain model control goes through the second initialiser with stand-ins. Building or opening
//      the window never calls `register()`, `unregister()` or `applyFirstRunDefault()` (that is t32's), never runs the
//      delete, and writes nothing to settings.json.
//   2. The could-not-read list is read from the index by the window itself, with `CouldNotReadList(files:)` over
//      `IndexReader().couldNotRead()` (t24) at `refresh()` and `select(_:)`; the tests write the index with `IndexStore`
//      in the throwaway HOME before they build the window.
//   3. Search: the plan-1 shortcut control (buttons titled `ShortcutControl.recordTitle` "Record new shortcut" and
//      `ShortcutControl.backToDefaultTitle` "Back to default", a control with the accessibility label
//      `ShortcutControl.accessibilityLabel` "Keyboard shortcut", the combination in words as `ShortcutControl.displayText`
//      builds them, and `ShortcutControl.message` when it is set, read again at each redraw), then three `NSPopUpButton`s
//      with the accessibility labels "PDF app", "Media app" and "Code editor" whose items are the names of
//      `AppChoices.options(for: "pdf"|"media"|"code")` in that order and whose selected item is `openWith.<kind>` of
//      settings.json. A pick (select the item, then the control's action fires) stores the name through
//      `AppChoices.choose(_:for:)`, sends nothing to the helper, and the window redraws itself. Next to the chosen app the
//      window shows `AppChoices.note(for:)` when the app is not installed (a note for other, unchosen options is not
//      forbidden). All three are in `screen.controls` with `isOn == nil`.
//   4. The shortcut notice: `ShortcutControl.takeNotice()` is called once, while the window is being built (that is "when
//      Settings opens" for a test); its text is then shown somewhere on screen, in any section, and a second window over
//      the same control shows none.
//   5. Indexing: controls titled "Start indexing" (enabled exactly when the model is whole and `startPressed` is false:
//      the t18 rule, also with no folder ticked, also after Delete index; a press is `SettingsModel.startIndexing()`),
//      "Launch at login" (a switch: `isOn` is `LoginItem.isOn`, read again at every redraw, never kept; a press calls
//      `LoginItem.set(on: !isOn)`; `LoginItem.message` is shown while it is set; the note `LoginItem.note` "The shortcut
//      works only while Sesame is running." is shown) and "Delete index…" (U+2026, as the entry and the kit write it).
//      Pressing "Delete index…" sets `settingsScreen.confirm` (the t25 `Confirm` value: `message` says what is deleted and
//      holds the word "index", `cancelTitle` "Cancel", `confirmTitle` a non-empty button title other than "Cancel"), as
//      the F3 mockup shows it, inline, with two `NSButton`s in the window while it is open; Cancel closes it; the confirm
//      button calls `DeleteIndex.run(confirmed: true)` and closes it. Nothing runs before the confirm button.
//      Below them the could-not-read list: `CouldNotReadList.emptyText` or one text per `rows` entry.
//   5a. "Start indexing" is looked up by title among the window's controls; whether it is absent or disabled when it is
//      not available is not pinned.
//   6. About: the text "Version 0.1, local build" and one text that names Full Disk Access, camera and microphone and
//      holds the word "never" (any case).
//   7. The wiring: `AppDelegate.makeSettingsWindow(model: SettingsModel, shortcut: ShortcutControl) -> NSWindow` is a
//      `@MainActor static` function (it replaces the private instance method) that returns a `SettingsContainerWindow`
//      over that model, wired to that shortcut control, titled `SettingsWindow.title`, never shown. The app's
//      `showSettings(message:)` shows what it returns. A test cannot see `showSettings`; this seam is what it reads.
//   8. Re-index stays inert (pressing it changes nothing, sends nothing) and the Folders section holds a control titled
//      "Add folder…" (U+2026), enabled. The tests never press "Add folder…": it opens the macOS picker.
//   9. Not pinned, on purpose: where each control sits, the wording beyond the strings written in the tests, what
//      "Record new shortcut" does while recording (key events), the look against F3, what the window does when a delete
//      fails, whether "Delete index…" is disabled with no index (the tests that press it plant an index row first).
//
// WHAT THE RED MEANS. Before the change the Search, Indexing and About sections are empty containers (`controls: []`,
// `texts: []`), so the content tests fail on their first expectation; the tests that need the new initialiser or the
// delegate seam do not compile (`extra arguments ... in call`, `makeSettingsWindow` private and without the parameters), which
// stops the whole AppLogicTests target until the change is made. Two tests are guards that already hold (Add folder
// exists, Re-index is inert) and stay green.

// ---------------------------------------------------------------------------------------------------------------------
// plan-2 fix round B, tester step (items B1, B3, B8): the Start rule below (t26 pin 5, "enabled exactly when the model is
// whole and `startPressed` is false") and pin 8 ("Re-index stays inert") are superseded by the round's rulings: Start is
// enabled when the model is whole and (Start was never pressed OR a folder's pending tick differs from what it reads); the
// per-folder Re-index applies that folder's pending tick like Start, and for a folder with nothing pending it is a plain
// sync request. The one sealed test that pinned the old Re-index (`theAddFolderButtonExists...`) was edited and is marked.
// The two Start tests at about lines 1216 and 1246 need NO edit: their folder has no pending tick, so Start is still
// disabled after a press. The new tests are at the end of the file (`extension ModelDownloadTests.SettingsScreenTests`).

// ---------------------------------------------------------------------------------------------------------------------
// plan-5-t7, tester step (the Audio, Video, PDF and Document switches; S4.6, S7, S1.29). The t25 pin 2 above ("Photos is the only
// enabled one ... the other five are disabled and each carries the text 'Not read in this version'") is SUPERSEDED for PDFs,
// Documents, Audio and Video: they are enabled switches, on when `kindsOn[key]` is true or missing, with no "not read" note; Code
// keeps its disabled state and its note (plan 6). The two sealed tests that held the old pin are amended in place and marked
// "plan-5-t7 AMENDMENT" with their reasons; two new tests are marked "plan-5-t7 (new)". No product source was read. The shapes
// pinned that the entry did not fix: Code's note is the only text that contains "not read" (any case) in File types while the code
// switch is off; pressing a reader switch off sends nothing, on sends `folders` once (the Photos switch's own send is not pinned).

// MARK: small helpers (file-private, so nothing collides with the other Settings and Setup test files)

private final class STBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// The recording `FoldersSender`.
private final class STSender: FoldersSender, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func sendFolders() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private let stKinds = ["photo", "pdf", "doc", "audio", "video"]
private let stWaiting = "Waiting for Start indexing"

private struct STEnv {
    let home: URL   // symlink-resolved, so a path compared as text cannot differ by a link
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

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

    func folderEntries() -> [NSDictionary] { (settingsDictionary()?["folders"] as? [NSDictionary]) ?? [] }

    func reading() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for entry in folderEntries() { if let path = entry["path"] as? String { result[path] = entry["reading"] as? Bool } }
        return result
    }

    func kindsOn() -> [String: Bool] { (settingsDictionary()?["kindsOn"] as? [String: Bool]) ?? [:] }

    // Writes settings.json through SettingsFile from JSON with the given folders: (path, reading, code).
    // (t26 added `indexDeleted` and `hotkey`, both defaulted, so every t25 call reads as before.)
    func seed(folders: [(path: String, reading: Bool, code: Bool)] = [], startPressed: Bool = true,
              indexDeleted: Bool = false, photoOn: Bool = true,
              hotkey: String = "cmd+opt+k") throws {
        let entries = folders.map { "{\"path\": \"\($0.path)\", \"code\": \($0.code), \"reading\": \($0.reading)}" }.joined(separator: ", ")
        let json = """
        {
          "version": 3,
          "startPressed": \(startPressed),
          "indexDeleted": \(indexDeleted),
          "folders": [\(entries)],
          "codeSearchOn": false,
          "kindsOn": {"photo": \(photoOn), "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
          "hotkey": "\(hotkey)",
          "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
          "speeds": {"photo": 3.0},
          "loginDefaultApplied": true
        }
        """
        let value = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        try SettingsFile().write(value)
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder, runs the body, puts HOME back and removes the folder.
@MainActor
private func stRun(_ body: (STEnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-settingsscreen-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = STEnv(home: base.resolvingSymlinksInPath())
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

// Polls the main actor until the condition holds; a generous slack, never a tight bound.
@MainActor
private func stEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func stReady(_ model: SettingsModel) async -> Bool {
    await stEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
}

// A moment for a wrongly sent command to show up. Generous, and only ever used to prove an absence.
private func stQuietPeriod() async { try? await Task.sleep(nanoseconds: 300_000_000) }

@MainActor
private func stModel(sender: STSender, modelWhole: Bool = true) -> SettingsModel {
    SettingsModel(sender: sender, modelWhole: { modelWhole })
}

// The folders the table tests share. Trips holds 40 photos (40 x 3.0 s = 120 s, "about 2 min"), Notes 7 PDFs and 5
// documents, Archive 3 photos. Trips and Notes are reading; Archive is not (it starts unticked).
private struct STFolders {
    let trips: URL
    let notes: URL
    let archive: URL
}

private func stBuildFolders(_ env: STEnv, photoOn: Bool = true) throws -> STFolders {
    let folders = STFolders(
        trips: try env.fill("Trips", photo: 40),
        notes: try env.fill("Notes", pdf: 7, doc: 5),
        archive: try env.fill("Archive", photo: 3))
    try env.seed(folders: [(folders.trips.path, true, false), (folders.notes.path, true, false), (folders.archive.path, false, false)],
                 photoOn: photoOn)
    return folders
}

private extension SettingsScreen {
    var stLabels: [String] { controls.map { $0.label } }
    func stControl(_ label: String) -> SettingsScreen.Control? { controls.first { $0.label == label } }
    func stControl(prefix: String) -> SettingsScreen.Control? { controls.first { $0.label.hasPrefix(prefix) } }
    func stRow(_ name: String) -> SettingsScreen.FolderRow? { folderRows.first { $0.name == name } }
}

private func stMore(_ row: SettingsScreen.FolderRow) -> SettingsScreen.Control? {
    Mirror(reflecting: row).children.first { $0.label == "more" }?.value as? SettingsScreen.Control
}

private let stBareRoleWords: Set<String> = [
    "button", "checkbox", "check box", "switch", "text field", "text", "static text", "label", "image", "progress",
    "progress indicator", "slider", "group", "radio button", "pop up button", "popup button", "scroll area", "table",
    "list", "row", "toggle", "stepper", "link",
]

private func stBare(_ label: String?) -> Bool {
    let text = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty || stBareRoleWords.contains(text.lowercased())
}

// MARK: the window, read offscreen

@MainActor
private func stViews(_ window: NSWindow) -> [NSView] {
    guard let root = window.contentView else { return [] }
    return prViews(root).filter { !$0.isHiddenOrHasHiddenAncestor }
}

@MainActor
private func stAllControls(in window: NSWindow) -> [NSControl] {
    stViews(window).compactMap { $0 as? NSControl }
}

@MainActor
private func stMatches(_ control: NSControl, _ label: String, prefix: Bool) -> Bool {
    let names = [(control as? NSButton)?.title, control.accessibilityLabel()].compactMap { $0 }
    return names.contains { prefix ? $0.hasPrefix(label) : $0 == label }
}

@MainActor
private func stControl(_ label: String, prefix: Bool = false, in window: NSWindow) -> NSControl? {
    stAllControls(in: window).first { stMatches($0, label, prefix: prefix) }
}

@MainActor
private func stDrawnEnabled(_ label: String, in window: NSWindow) -> Bool? {
    if let control = stControl(label, in: window) { return control.isEnabled }
    guard let root = window.contentView else { return nil }
    let items = smrMoreButtons(root).flatMap { smrVisibleItems($0) }.filter { $0.title == label }
    return items.isEmpty ? nil : items.allSatisfy(\.isEnabled)
}

// A press as a person makes it; false when there is no such enabled control.
@MainActor
@discardableResult
private func stPress(_ label: String, prefix: Bool = false, in window: NSWindow) async -> Bool {
    if !prefix, label == "Re-index" || label == "Remove", let root = window.contentView {
        return await smrChooseFirst(label, in: root)
    }
    guard let control = stControl(label, prefix: prefix, in: window), control.isEnabled else { return false }
    control.performClick(nil)
    await Task.yield()
    return true
}

// Every control a person could tab to: enabled, not hidden, a button-like control or an editable field. Scrollers are
// controls to AppKit but are never keyboard stops.
@MainActor
private func stEnabledControls(in window: NSWindow) -> [NSView] {
    stViews(window).filter { view in
        guard !(view is NSScroller) else { return false }
        if let field = view as? NSTextField { return field.isEditable && field.isEnabled }
        if let control = view as? NSControl { return control.isEnabled }
        return false
    }
}

// The loop `nextValidKeyView` walks from `initialFirstResponder`, and whether it came back to the start.
@MainActor
private func stKeyLoop(_ window: NSWindow) -> (visited: [NSView], closed: Bool, started: Bool) {
    guard let start = window.initialFirstResponder else { return ([], false, false) }
    var visited = [start]
    var next = start.nextValidKeyView
    while let current = next, current !== start, visited.count < 500 {
        visited.append(current)
        next = current.nextValidKeyView
    }
    return (visited, next === start, true)
}

@MainActor
private func stWindow(_ model: SettingsModel) -> SettingsContainerWindow {
    let window = SettingsContainerWindow(model: model)
    window.isReleasedWhenClosed = false
    window.refresh()
    return window
}

// MARK: plan-2-t26 helpers (file-private)

private let stDeleteTitle = "Delete index\u{2026}"
private let stAddFolderTitle = "Add folder\u{2026}"
private let stStartTitle = "Start indexing"
private let stLoginTitle = "Launch at login"
private let stLoginNote = "The shortcut works only while Sesame is running."
private let stLoginMessage = "Could not change Launch at login."
private let stNothingListed = "Nothing here. Files Sesame could not read are listed here."
private let stNoticeFragment = "is taken by another app"
private let stNotInstalledFragment = " is not installed. Enter opens the file in the default app."

private extension STEnv {
    func openWith() -> [String: String] { (settingsDictionary()?["openWith"] as? [String: String]) ?? [:] }
    func flag(_ key: String) -> Bool? { settingsDictionary()?[key] as? Bool }
    func hotkeyKeys() -> [String] {
        ((settingsDictionary()?["hotkey"] as? String) ?? "").lowercased().split(separator: "+").map(String.init).sorted()
    }
    func withoutKeys(_ keys: Set<String>) -> NSDictionary {
        let copy = NSMutableDictionary(dictionary: settingsDictionary() ?? [:])
        for key in keys { copy.removeObject(forKey: key) }
        return copy
    }
}

// Everything a person can read in the window as it is drawn: the screen value's texts and control labels, every text
// field, every button title and popup item, and every accessibility label. Placement is not pinned, so a check is
// "somewhere on screen".
@MainActor
private func stReadable(_ window: SettingsContainerWindow) -> [String] {
    var out = window.settingsScreen.texts + window.settingsScreen.controls.map { $0.label }
    for view in stViews(window) {
        if let field = view as? NSTextField { out.append(field.stringValue) }
        if let button = view as? NSButton { out.append(button.title) }
        if let popup = view as? NSPopUpButton { out.append(contentsOf: popup.itemTitles) }
        if let label = view.accessibilityLabel() { out.append(label) }
    }
    return out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@MainActor
private func stReads(_ window: SettingsContainerWindow, _ fragment: String) -> Bool {
    stReadable(window).contains { $0.contains(fragment) }
}

// The four sections in turn, each redrawn, with the texts of all of them; the window ends on the section it started on.
@MainActor
private func stEverywhere(_ window: SettingsContainerWindow) -> [String] {
    let start = window.settingsScreen.section
    var all: [String] = []
    for section in SettingsScreen.Section.allCases {
        window.select(section)
        window.refresh()
        all += stReadable(window)
    }
    window.select(start)
    window.refresh()
    return all
}

@MainActor
private func stEnabled(_ label: String, in window: SettingsContainerWindow) -> Bool {
    stControl(label, in: window)?.isEnabled == true
}

@MainActor
private func stPopup(_ label: String, in window: NSWindow) -> NSPopUpButton? {
    stAllControls(in: window).compactMap { $0 as? NSPopUpButton }.first { stMatches($0, label, prefix: false) }
}

// A person's pick in a popup: choose the item, then the control's action fires (never `performClick`, which would open
// the menu and wait for the mouse).
@MainActor
@discardableResult
private func stChoose(_ title: String, in popup: NSPopUpButton) async -> Bool {
    guard popup.isEnabled, popup.itemTitles.contains(title) else { return false }
    popup.selectItem(withTitle: title)
    _ = popup.sendAction(popup.action, to: popup.target)
    await Task.yield()
    return true
}

// What a switch or tick is drawn as, by the control itself.
@MainActor
private func stDrawnOn(_ control: NSControl?) -> Bool? {
    if let button = control as? NSButton { return button.state == .on }
    if let toggle = control as? NSSwitch { return toggle.state == .on }
    return nil
}

// Rows of an index in a throwaway HOME, written the way the helper writes them (the t24 tests' calls).
private func stIndexRow(_ store: IndexStore, _ path: String, status: String, inode: Int64) throws {
    _ = try store.addFile(path: path, kind: "photo", size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode,
                          device: 1, status: status)
}

private func stDamagedRow(_ store: IndexStore, _ path: String, reason: String, inode: Int64) throws {
    try stIndexRow(store, path, status: "pending", inode: inode)
    let queue = try store.pendingPhotos(limit: 50)
    let row = try #require(queue.first { $0.path == path }, "setup: pendingPhotos does not list \(path)")
    _ = try store.markCouldNotRead(row, reason: reason)
}

// MARK: t26 fakes: every service the window is given is a stand-in, so nothing real is registered, deleted or asked.

private final class STList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

// A stand-in for `SMAppService.mainApp`: a register or unregister leaves the status the test scripted, the way macOS does.
private final class STLoginService: LoginService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginStatus
    private var registered = 0
    private var unregistered = 0
    var statusAfterRegister: LoginStatus = .enabled
    var statusAfterUnregister: LoginStatus = .notRegistered
    var registerThrows = false
    var unregisterThrows = false
    struct Refused: Error {}

    init(_ status: LoginStatus) { current = status }
    var status: LoginStatus {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var registerCount: Int { lock.lock(); defer { lock.unlock() }; return registered }
    var unregisterCount: Int { lock.lock(); defer { lock.unlock() }; return unregistered }
    func register() throws {
        lock.lock(); registered += 1; lock.unlock()
        if registerThrows { throw Refused() }
        status = statusAfterRegister
    }
    func unregister() throws {
        lock.lock(); unregistered += 1; lock.unlock()
        if unregisterThrows { throw Refused() }
        status = statusAfterUnregister
    }
}

// A stand-in for the machine's installed apps.
private final class STLookup: AppLookup, @unchecked Sendable {
    private let installed: Set<String>
    init(installed: Set<String> = []) { self.installed = installed }
    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
}

// The recording seams of `DeleteIndex`; each call notes what settings.json held at that moment (step (2) is the real write).
private final class STDeleteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var flagsAtReset: (startPressed: Bool, indexDeleted: Bool)?

    func note(_ event: String) {
        let settings = try? SettingsFile().read()
        lock.lock()
        log.append(event)
        if event == "reset", flagsAtReset == nil, let settings { flagsAtReset = (settings.startPressed, settings.indexDeleted) }
        lock.unlock()
    }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var atReset: (startPressed: Bool, indexDeleted: Bool)? { lock.lock(); defer { lock.unlock() }; return flagsAtReset }
    func make() -> DeleteIndex {
        DeleteIndex(closeIndex: { self.note("close") }, sendReset: { self.note("reset") }, deleteCaches: { self.note("caches") })
    }
}

// The window with every service injected, and the stand-ins it was given.
private struct STRig {
    let model: SettingsModel
    let sender: STSender
    let shortcut: ShortcutControl
    let hotkeyCalls: STList
    let service: STLoginService
    let login: LoginItem
    let recorder: STDeleteRecorder
    let window: SettingsContainerWindow
}

@MainActor
private func stRig(modelWhole: Bool = true, installed: Set<String> = [], loginStatus: LoginStatus = .enabled,
                   shortcut givenShortcut: ShortcutControl? = nil, hotkeyCalls: STList = STList()) async -> STRig {
    let sender = STSender()
    let model = stModel(sender: sender, modelWhole: modelWhole)
    _ = await stReady(model)
    let shortcut = givenShortcut ?? ShortcutControl(onChange: { hotkeyCalls.add($0) })
    let service = STLoginService(loginStatus)
    let login = LoginItem(service: service)
    let recorder = STDeleteRecorder()
    let window = SettingsContainerWindow(model: model, shortcut: shortcut, loginItem: login,
                                         appChoices: AppChoices(lookup: STLookup(installed: installed)),
                                         deleteIndex: recorder.make())
    window.isReleasedWhenClosed = false
    window.refresh()
    return STRig(model: model, sender: sender, shortcut: shortcut, hotkeyCalls: hotkeyCalls, service: service, login: login,
                 recorder: recorder, window: window)
}

private func stWithout(_ dictionary: NSDictionary?, _ keys: Set<String>) -> NSDictionary {
    let copy = NSMutableDictionary(dictionary: dictionary ?? [:])
    for key in keys { copy.removeObject(forKey: key) }
    return copy
}

private func stParts(_ combination: String) -> [String] {
    combination.lowercased().split(separator: "+").map(String.init).sorted()
}

private let stDefaultParts = ["ctrl", "opt", "space"].sorted()

// One folder with 3 photos that reads, and settings written for the Start rule table.
private func stOneFolder(_ env: STEnv, startPressed: Bool, indexDeleted: Bool = false) throws -> URL {
    let pictures = try env.fill("Pictures", photo: 3)
    try env.seed(folders: [(pictures.path, true, false)], startPressed: startPressed, indexDeleted: indexDeleted)
    return pictures
}

extension ModelDownloadTests {
    @Suite("SettingsScreenTests", .serialized)
    struct SettingsScreenTests {

        // MARK: the container: four sections in order

        @MainActor
        @Test func theSidebarHasFourSectionsInTheEntrysOrderAndTheWindowStartsOnFolders() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))

                let screen = SettingsScreen(model: model)
                #expect(screen.sections.map { $0.title } == ["Folders", "File types", "Search", "Indexing"],
                        "sections: \(screen.sections.map { $0.title })")
                #expect(screen.sections.count == 4)
                #expect(screen.section == .folders, "the default section is \(screen.section.title)")
                #expect(SettingsScreen.Section.allCases.map { $0.title } == ["Folders", "File types", "Search", "Indexing"])

                // every section exists as a container and the selected one is the one asked for
                for section in SettingsScreen.Section.allCases {
                    let built = SettingsScreen(model: model, section: section)
                    #expect(built.section == section, "asked for \(section.title), got \(built.section.title)")
                    #expect(built.sections.count == 4, "\(section.title): the sidebar has \(built.sections.count) items")
                }

                // the window shows the same four and starts on Folders
                let window = stWindow(model)
                #expect(window.settingsScreen.sections.map { $0.title } == ["Folders", "File types", "Search", "Indexing"])
                #expect(window.settingsScreen.section == .folders, "the window starts on \(window.settingsScreen.section.title)")
                window.select(.fileTypes)
                #expect(window.settingsScreen.section == .fileTypes, "select(.fileTypes) left the window on \(window.settingsScreen.section.title)")
                window.select(.folders)
                #expect(window.settingsScreen.section == .folders)
            }
        }

        // MARK: Folders

        @MainActor
        @Test func foldersHoldsOneRowPerFolderInOrderWithCountsAndTheThreeControlsOfTheTable() async throws {
            try await stRun { env in
                let folders = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))

                let screen = SettingsScreen(model: model, section: .folders)
                #expect(screen.folderRows.map { $0.path } == [folders.trips.path, folders.notes.path, folders.archive.path],
                        "rows: \(screen.folderRows.map { $0.path })")
                #expect(screen.folderRows.map { $0.name } == ["Trips", "Notes", "Archive"], "names: \(screen.folderRows.map { $0.name })")
                #expect(screen.folderRows.map { $0.tick.isOn } == [true, true, false], "ticks: \(screen.folderRows.map { String(describing: $0.tick.isOn) })")

                // the row's tick control reads "<name>, <counts>": the name first, then the file counts by kind
                let trips = try #require(screen.stRow("Trips"), "no Trips row")
                #expect(trips.tick.label.hasPrefix("Trips, "), "Trips tick label \"\(trips.tick.label)\"")
                #expect(trips.tick.label.contains("40"), "Trips label \"\(trips.tick.label)\" lacks its 40 photos")
                #expect(trips.tick.label.lowercased().contains("photo"), "Trips label \"\(trips.tick.label)\" does not name photos")
                #expect(trips.detail.contains("40"), "Trips detail \"\(trips.detail)\" lacks its 40 photos")
                let notes = try #require(screen.stRow("Notes"), "no Notes row")
                #expect(notes.tick.label.hasPrefix("Notes, "), "Notes tick label \"\(notes.tick.label)\"")
                for (number, word) in [("7", "pdf"), ("5", "doc")] {
                    #expect(notes.tick.label.contains(number) && notes.tick.label.lowercased().contains(word),
                            "Notes label \"\(notes.tick.label)\" lacks \(number) \(word)")
                    #expect(notes.detail.contains(number) && notes.detail.lowercased().contains(word),
                            "Notes detail \"\(notes.detail)\" lacks \(number) \(word)")
                }
                let archive = try #require(screen.stRow("Archive"), "no Archive row")
                #expect(archive.tick.label.hasPrefix("Archive"), "Archive tick label \"\(archive.tick.label)\"")

                // every row has "Re-index" and "Remove" with exactly those labels, and they are in the screen's controls
                for row in screen.folderRows {
                    #expect(row.reindex.label == "Re-index", "\(row.name): re-index label \"\(row.reindex.label)\"")
                    #expect(row.remove.label == "Remove", "\(row.name): remove label \"\(row.remove.label)\"")
                    #expect(row.remove.isEnabled, "\(row.name): Remove is disabled")
                    #expect(row.reindex.isOn == nil && row.remove.isOn == nil, "\(row.name): a button reads as a switch")
                }
                #expect(screen.controls.filter { $0.label == "Re-index" }.count == 3, "Re-index controls: \(screen.stLabels)")
                #expect(screen.controls.filter { $0.label == "Remove" }.count == 3, "Remove controls: \(screen.stLabels)")
                for row in screen.folderRows {
                    let more = try #require(stMore(row), "\(row.name): the row has no stored `more` control")
                    #expect(more.label == "More actions for \(row.name)", "\(row.name): more label \"\(more.label)\"")
                    #expect(more.isEnabled, "\(row.name): the more control is disabled")
                    #expect(more.isOn == nil, "\(row.name): the more control reads as a switch")
                }
                #expect(screen.controls.filter { $0.label.hasPrefix("More actions for ") }.count == 3, "more controls: \(screen.stLabels)")
                #expect(screen.stLabels.prefix(4) == ["Trips, 40 photos, about 2 min", "More actions for Trips", "Re-index", "Remove"],
                        "the first row's controls: \(screen.stLabels)")
                // a folder that is ticked and reading can be re-indexed and untick-ed
                #expect(trips.reindex.isEnabled, "Re-index is disabled for a ticked, reading folder")
                #expect(trips.tick.isEnabled, "the tick of a reading folder is disabled")
                // the tick controls are in the screen's controls too
                for row in screen.folderRows {
                    #expect(screen.controls.contains { $0.label == row.tick.label }, "\(row.name): the tick is not among the controls \(screen.stLabels)")
                }
            }
        }

        @MainActor
        @Test func aReadingFolderShowsItsEstimateAndAFolderAddedOrTickedAfterwardsShowsWaitingForStartIndexingUntilStart() async throws {
            try await stRun { env in
                let folders = try stBuildFolders(env)
                let sender = STSender()
                let model = stModel(sender: sender)
                #expect(await stReady(model))

                // reading: the estimate, 40 photos x 3.0 s = 120 s
                let first = SettingsScreen(model: model).folderRows
                let trips = try #require(first.first { $0.name == "Trips" })
                #expect(trips.detail.contains("about 2 min"), "Trips detail \"\(trips.detail)\"")
                #expect(!trips.detail.contains(stWaiting), "a reading folder says it waits: \"\(trips.detail)\"")

                // added after the file was made: counted and timed, but it waits for Start
                let extra = try env.fill("Extra", photo: 40)
                model.addFolder(extra)
                #expect(await stReady(model))
                var screen = SettingsScreen(model: model)
                var added = try #require(screen.stRow("Extra"), "no row for the added folder in \(screen.folderRows.map { $0.name })")
                #expect(added.tick.isOn == true, "an added folder is not ticked")
                #expect(added.detail.contains(stWaiting), "added folder detail \"\(added.detail)\"")
                #expect(!added.detail.contains("about 2 min"), "added folder shows an estimate before Start: \"\(added.detail)\"")
                #expect(added.detail.contains("40"), "added folder detail \"\(added.detail)\" lacks its counts")

                // unticked and ticked again: the same
                model.setTicked(folders.trips.path, false)
                model.setTicked(folders.trips.path, true)
                #expect(await stReady(model))
                screen = SettingsScreen(model: model)
                let again = try #require(screen.stRow("Trips"))
                #expect(again.tick.isOn == true)
                #expect(again.detail.contains(stWaiting), "Trips after ticking again: \"\(again.detail)\"")
                #expect(!again.detail.contains("about 2 min"), "Trips shows an estimate while it waits: \"\(again.detail)\"")
                // the folder that was never touched still reads its estimate
                #expect(screen.stRow("Notes")?.detail.contains(stWaiting) == false, "Notes waits: \"\(screen.stRow("Notes")?.detail ?? "")\"")

                // Start: every ticked folder reads, the estimate is back and nothing waits
                model.startIndexing()
                #expect(await stReady(model))
                screen = SettingsScreen(model: model)
                added = try #require(screen.stRow("Extra"))
                #expect(!added.detail.contains(stWaiting), "Extra still waits after Start: \"\(added.detail)\"")
                #expect(added.detail.contains("about 2 min"), "Extra after Start: \"\(added.detail)\"")
                #expect(screen.folderRows.filter { $0.tick.isOn == true }.allSatisfy { !$0.detail.contains(stWaiting) },
                        "a ticked folder still waits after Start: \(screen.folderRows.map { $0.detail })")
                _ = sender
            }
        }

        @MainActor
        @Test func theEstimateReadsAfterTheModelDownloadWhileTheModelIsNotWhole() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let model = stModel(sender: STSender(), modelWhole: false)
                #expect(await stReady(model))
                let trips = try #require(SettingsScreen(model: model).stRow("Trips"))
                #expect(trips.detail.contains("after the model download"), "Trips detail with the model not whole: \"\(trips.detail)\"")
                #expect(!trips.detail.contains("about 2 min"), "an estimate is shown before the model is whole: \"\(trips.detail)\"")
            }
        }

        @MainActor
        @Test func theRemoveConfirmIsAValueNamingTheFolderAndBuildingItChangesNothing() async throws {
            try await stRun { env in
                let folders = try stBuildFolders(env)
                let sender = STSender()
                let model = stModel(sender: sender)
                #expect(await stReady(model))
                let before = try? Data(contentsOf: env.settings)
                let rowsBefore = model.rows.map { $0.path }

                #expect(SettingsScreen(model: model).confirm == nil, "a confirm is open with nothing asked")
                let screen = SettingsScreen(model: model, section: .folders, confirmingRemoval: folders.notes.path)
                let confirm = try #require(screen.confirm, "no confirm for a folder whose Remove was pressed")
                #expect(confirm.message.contains("Notes"), "the confirm does not name the folder: \"\(confirm.message)\"")
                #expect(!confirm.message.contains("Trips") && !confirm.message.contains("Archive"), "the confirm names another folder: \"\(confirm.message)\"")
                #expect(confirm.cancelTitle == "Cancel", "cancel title \"\(confirm.cancelTitle)\"")
                #expect(!confirm.confirmTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && confirm.confirmTitle != "Cancel",
                        "confirm title \"\(confirm.confirmTitle)\"")
                // a confirm for a path that is no row is no confirm
                #expect(SettingsScreen(model: model, section: .folders, confirmingRemoval: env.home.path + "/Nowhere").confirm == nil)

                // reading a screen changes nothing: not the rows, not the file, nothing sent
                await stQuietPeriod()
                #expect(model.rows.map { $0.path } == rowsBefore)
                #expect((try? Data(contentsOf: env.settings)) == before, "building the confirm wrote settings.json")
                #expect(sender.calls == 0, "building the confirm sent folders")
            }
        }

        // MARK: File types

        @MainActor
        @Test func fileTypesHoldsOneEnabledSwitchPerKindOfTheFiveAndNothingElse() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))

                let screen = SettingsScreen(model: model, section: .fileTypes)
                #expect(screen.folderRows.isEmpty, "File types holds folder rows")
                for prefix in ["Photos", "PDFs", "Documents", "Audio", "Video"] {
                    let control = try #require(screen.stControl(prefix: prefix), "no \(prefix) switch in \(screen.stLabels)")
                    #expect(control.isEnabled, "the \(prefix) switch is disabled")
                    #expect(control.isOn == true, "the \(prefix) switch is not on with its kind on in settings.json")
                }
                #expect(screen.controls.count == 5, "File types holds \(screen.controls.count) controls: \(screen.stLabels)")
                #expect(screen.stControl(prefix: "Code") == nil, "a Code row is in \(screen.stLabels)")
                #expect(screen.texts.filter { $0.lowercased().contains("not read") }.isEmpty,
                        "texts that say a kind is not read: \(screen.texts.filter { $0.lowercased().contains("not read") }) of all \(screen.texts)")
                #expect(!screen.stLabels.contains("Remove") && !screen.stLabels.contains("Re-index"), "folder buttons in File types: \(screen.stLabels)")
            }
        }

        // plan-5-t7 (new): a reader switch is on when its key is true or missing in settings.json (a missing key means on, as in
        // `Visible`) and off only when the key is false; every one of them is enabled whichever way it reads.
        @MainActor
        @Test func aReaderSwitchReadsOnWhenItsKeyIsTrueOrMissingAndOffOnlyWhenItIsFalse() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                var settings = try SettingsFile().read()
                settings.kindsOn = ["photo": true, "pdf": false, "audio": false]   // doc and video have no key
                try SettingsFile().write(settings)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))

                let screen = SettingsScreen(model: model, section: .fileTypes)
                let expected: [(String, Bool)] = [("Photos", true), ("PDFs", false), ("Documents", true), ("Audio", false), ("Video", true)]
                for (prefix, on) in expected {
                    let control = try #require(screen.stControl(prefix: prefix), "no \(prefix) switch in \(screen.stLabels)")
                    #expect(control.isEnabled, "the \(prefix) switch is disabled")
                    #expect(control.isOn == on, "the \(prefix) switch reads \(String(describing: control.isOn)), expected \(on)")
                }

                // an empty map: every reader switch is on
                settings.kindsOn = [:]
                try SettingsFile().write(settings)
                let again = stModel(sender: STSender())
                #expect(await stReady(again))
                let all = SettingsScreen(model: again, section: .fileTypes)
                for prefix in ["Photos", "PDFs", "Documents", "Audio", "Video"] {
                    #expect(all.stControl(prefix: prefix)?.isOn == true, "\(prefix) reads \(String(describing: all.stControl(prefix: prefix)?.isOn)) with no kindsOn key")
                }
            }
        }

        @MainActor
        @Test func thePhotosSwitchReadsTheStoredKindFlag() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env, photoOn: false)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                let photos = try #require(SettingsScreen(model: model, section: .fileTypes).stControl(prefix: "Photos"))
                #expect(photos.isOn == false, "Photos reads on with kindsOn.photo false")
                #expect(photos.isEnabled)

                model.setKind("photo", on: true)
                #expect(SettingsScreen(model: model, section: .fileTypes).stControl(prefix: "Photos")?.isOn == true,
                        "Photos is not on after the kind was switched on")
            }
        }

        // MARK: labels of every control built here

        @MainActor
        @Test func everyControlOfFoldersAndFileTypesHasANonEmptyLabelThatIsNotARoleWord() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                for section in [SettingsScreen.Section.folders, .fileTypes] {
                    let screen = SettingsScreen(model: model, section: section, confirmingRemoval: nil)
                    #expect(!screen.controls.isEmpty, "\(section.title): no controls")
                    for control in screen.controls {
                        #expect(!stBare(control.label), "\(section.title): the control \"\(control.label)\" has no usable label")
                    }
                    #expect(!screen.texts.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                            "\(section.title): an empty text among \(screen.texts)")
                }
            }
        }

        // MARK: the window, offscreen: key-view loop and labels

        @MainActor
        @Test func everyEnabledControlOfFoldersAndFileTypesIsInTheKeyViewLoopWithALabelThatIsNotARoleWord() async throws {
            try await stRun { env in
                let folders = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                // one folder waits for Start, one is unticked, one is reading
                model.addFolder(try env.fill("Extra", photo: 2))
                #expect(await stReady(model))
                let window = stWindow(model)

                let walks: [(String, SettingsScreen.Section)] = [("Folders", .folders), ("File types", .fileTypes)]
                for (title, section) in walks {
                    window.select(section)
                    window.refresh()
                    #expect(window.settingsScreen.section == section, "\(title): the window draws \(window.settingsScreen.section.title)")

                    let controls = stEnabledControls(in: window)
                    #expect(!controls.isEmpty, "\(title): the window has no enabled control")
                    let loop = stKeyLoop(window)
                    #expect(loop.started, "\(title): the window has no initialFirstResponder")
                    #expect(loop.closed, "\(title): the key-view loop never returned to its start (\(loop.visited.count) views)")
                    for control in controls {
                        let name = (control as? NSButton)?.title ?? control.accessibilityLabel() ?? String(describing: type(of: control))
                        #expect(loop.visited.contains { $0 === control },
                                "\(title): the enabled control \"\(name)\" is not in the key-view loop (full keyboard access: \(NSApp.isFullKeyboardAccessEnabled))")
                        #expect(!stBare(control.accessibilityLabel()),
                                "\(title): the control \"\(name)\" has the accessibility label \"\(control.accessibilityLabel() ?? "nil")\"")
                    }

                    // the enabled controls of the screen's table are really there, as controls with that label
                    for control in window.settingsScreen.controls where control.isEnabled {
                        #expect(stDrawnEnabled(control.label, in: window) == true, "\(title): no enabled control \"\(control.label)\" in the window")
                    }
                    // the disabled ones are there too, and not enabled
                    for control in window.settingsScreen.controls where !control.isEnabled {
                        if let found = stDrawnEnabled(control.label, in: window) {
                            #expect(!found, "\(title): \"\(control.label)\" is disabled in the table and enabled in the window")
                        } else {
                            Issue.record("\(title): the disabled control \"\(control.label)\" is not in the window")
                        }
                    }
                }
                _ = folders
            }
        }

        // MARK: the window: pressing

        @MainActor
        @Test func pressingAFoldersTickUnticksItWritesReadingFalseAndSendsOnce() async throws {
            try await stRun { env in
                let folders = try stBuildFolders(env)
                let sender = STSender()
                let model = stModel(sender: sender)
                #expect(await stReady(model))
                let window = stWindow(model)

                #expect(await stPress("Trips, ", prefix: true, in: window), "no enabled tick for Trips in the window")
                #expect(model.rows.first { $0.path == folders.trips.path }?.ticked == false, "the Trips row is still ticked")
                #expect(sender.calls == 1, "folders was sent \(sender.calls) times")
                #expect(env.reading()[folders.trips.path] == false, "reading on disk for Trips: \(String(describing: env.reading()[folders.trips.path]))")
                #expect(env.reading()[folders.notes.path] == true, "Notes changed: \(env.reading())")
                #expect(env.folderEntries().count == 3, "a folder left the list: \(env.folderEntries())")

                // the window drew it: the row's tick reads off without anyone calling refresh
                let redrawn = await stEventually { window.settingsScreen.stRow("Trips")?.tick.isOn == false }
                #expect(redrawn, "the window still draws the Trips tick as \(String(describing: window.settingsScreen.stRow("Trips")?.tick.isOn))")
            }
        }

        @MainActor
        @Test func pressingRemoveOpensTheConfirmAndOnlyItsConfirmButtonRemovesTheFolder() async throws {
            try await stRun { env in
                let pictures = try env.fill("Pictures", photo: 3)
                try env.seed(folders: [(pictures.path, true, false)])
                let sender = STSender()
                let model = stModel(sender: sender)
                #expect(await stReady(model))
                let window = stWindow(model)
                let bytes = try? Data(contentsOf: env.settings)

                // Remove opens the confirm and does nothing else
                #expect(await stPress("Remove", in: window), "no enabled Remove in the window: \(stAllControls(in: window).map { $0.accessibilityLabel() ?? "" })")
                let opened = await stEventually { window.settingsScreen.confirm != nil }
                #expect(opened, "pressing Remove opened no confirm")
                let confirm = try #require(window.settingsScreen.confirm)
                #expect(confirm.message.contains("Pictures"), "the confirm does not name the folder: \"\(confirm.message)\"")
                await stQuietPeriod()
                #expect(model.rows.map { $0.path } == [pictures.path], "the row left on Remove alone: \(model.rows.map { $0.path })")
                #expect((try? Data(contentsOf: env.settings)) == bytes, "Remove alone wrote settings.json")
                #expect(sender.calls == 0, "Remove alone sent folders")

                // Cancel closes it and nothing changes
                #expect(await stPress(confirm.cancelTitle, in: window), "no enabled \"\(confirm.cancelTitle)\" button while the confirm is open")
                let closed = await stEventually { window.settingsScreen.confirm == nil }
                #expect(closed, "Cancel left the confirm open")
                await stQuietPeriod()
                #expect(model.rows.map { $0.path } == [pictures.path], "the row left on Cancel")
                #expect((try? Data(contentsOf: env.settings)) == bytes, "Cancel wrote settings.json")
                #expect(sender.calls == 0, "Cancel sent folders")

                // Remove again, then the confirm button: written, then sent once
                #expect(await stPress("Remove", in: window), "no Remove after Cancel")
                #expect(await stEventually { window.settingsScreen.confirm != nil })
                let second = try #require(window.settingsScreen.confirm)
                #expect(await stPress(second.confirmTitle, in: window), "no enabled \"\(second.confirmTitle)\" button while the confirm is open")
                #expect(model.rows.isEmpty, "the folder is still listed after the confirm: \(model.rows.map { $0.path })")
                #expect(env.folderEntries().isEmpty, "the folder is still in settings.json: \(env.folderEntries())")
                #expect(sender.calls == 1, "folders was sent \(sender.calls) times by the confirmed removal")
                #expect(await stEventually { window.settingsScreen.confirm == nil }, "the confirm stayed open after removing")
                #expect(await stEventually { window.settingsScreen.folderRows.isEmpty }, "the window still draws a row: \(window.settingsScreen.folderRows.map { $0.name })")
                // the files themselves are not touched
                #expect(FileManager.default.fileExists(atPath: pictures.path + "/photo-0.jpg"), "a file of the removed folder was deleted")
            }
        }

        @MainActor
        @Test func theFiveKindSwitchesActWhenPressed() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let sender = STSender()
                let model = stModel(sender: sender)
                #expect(await stReady(model))
                let window = stWindow(model)
                window.select(.fileTypes)
                window.refresh()

                // Photos off, then on
                #expect(await stPress("Photos", prefix: true, in: window), "no enabled Photos switch in the window")
                #expect(env.kindsOn()["photo"] == false, "kindsOn on disk after pressing Photos: \(env.kindsOn())")
                #expect(await stEventually { window.settingsScreen.stControl(prefix: "Photos")?.isOn == false }, "the window still draws Photos as on")
                #expect(["pdf", "doc", "audio", "video"].allSatisfy { env.kindsOn()[$0] == true }, "another kind changed: \(env.kindsOn())")
                #expect(await stPress("Photos", prefix: true, in: window))
                #expect(env.kindsOn()["photo"] == true, "kindsOn on disk after pressing Photos again: \(env.kindsOn())")
                await stQuietPeriod()
                let baseline = sender.calls
                #expect(baseline == 0 || baseline == 1, "pressing Photos off and on sent folders \(baseline) times; at most one send (when it went on) is allowed")

                // PDFs, Documents, Audio and Video: off writes the flag and sends nothing, on writes it and sends folders once
                let readers: [(prefix: String, key: String)] = [("PDFs", "pdf"), ("Documents", "doc"), ("Audio", "audio"), ("Video", "video")]
                for (number, reader) in readers.enumerated() {
                    let others = stKinds.filter { $0 != reader.key }
                    #expect(await stPress(reader.prefix, prefix: true, in: window), "no enabled \(reader.prefix) switch in the window")
                    #expect(env.kindsOn()[reader.key] == false, "kindsOn on disk after pressing \(reader.prefix): \(env.kindsOn())")
                    #expect(others.allSatisfy { env.kindsOn()[$0] == true }, "pressing \(reader.prefix) changed another kind: \(env.kindsOn())")
                    #expect(await stEventually { window.settingsScreen.stControl(prefix: reader.prefix)?.isOn == false }, "the window still draws \(reader.prefix) as on")
                    await stQuietPeriod()
                    #expect(sender.calls == baseline + number, "\(reader.prefix) switched off sent folders: \(sender.calls) calls, expected \(baseline + number)")

                    #expect(await stPress(reader.prefix, prefix: true, in: window))
                    #expect(env.kindsOn()[reader.key] == true, "kindsOn on disk after pressing \(reader.prefix) again: \(env.kindsOn())")
                    #expect(await stEventually { window.settingsScreen.stControl(prefix: reader.prefix)?.isOn == true }, "the window still draws \(reader.prefix) as off")
                    #expect(await stEventually { sender.calls == baseline + number + 1 }, "\(reader.prefix) switched on sent folders \(sender.calls - baseline - number) times, expected 1")
                    await stQuietPeriod()
                    #expect(sender.calls == baseline + number + 1, "\(reader.prefix) switched on sent folders more than once: \(sender.calls - baseline - number)")
                }
                let afterReaders = sender.calls
                await stQuietPeriod()
                #expect(sender.calls == afterReaders, "folders was sent again with no press: \(sender.calls - afterReaders)")
                #expect(window.settingsScreen.controls.count == 5, "File types holds \(window.settingsScreen.controls.count) controls: \(window.settingsScreen.stLabels)")
            }
        }

        // plan-5-t7 (new): the Audio switch pressed in the window. Off: the flag is written and the helper hears nothing. On: the
        // flag is written first and `folders` is sent once after it (the reconcile that reads the files made meanwhile).
        @MainActor
        @Test func theAudioSwitchPressedOffSendsNothingAndPressedOnWritesTheFlagAndSendsFoldersOnce() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let sender = STSender()
                let model = stModel(sender: sender)
                #expect(await stReady(model))
                let window = stWindow(model)
                window.select(.fileTypes)
                window.refresh()

                #expect(await stPress("Audio", prefix: true, in: window))
                await stQuietPeriod()
                #expect(env.kindsOn()["audio"] == false)
                #expect(sender.calls == 0, "switching Audio off sent folders \(sender.calls) times")

                #expect(await stPress("Audio", prefix: true, in: window))
                #expect(await stEventually { sender.calls >= 1 }, "switching Audio on sent no folders")
                #expect(env.kindsOn()["audio"] == true, "the flag on disk when the send was seen: \(env.kindsOn())")
                await stQuietPeriod()
                #expect(sender.calls == 1, "switching Audio on sent folders \(sender.calls) times, expected once")
            }
        }

        // MARK: Command+comma, as in plan 1

        @MainActor
        @Test func commandCommaOpensSettingsAndNothingElseDoes() {
            #expect(SettingsWindow.title == "Settings")
            #expect(SettingsWindow.isOpenCommand("cmd+,"))
            #expect(SettingsWindow.isOpenCommand("cmd+comma"))
            for other in ["cmd+k", "opt+,", "ctrl+,", "shift+,", "cmd+shift+,", ",", "cmd+space", "cmd+."] {
                #expect(!SettingsWindow.isOpenCommand(other), "\(other) opened Settings")
            }
        }

        // ============================================================================================================
        // plan-2-t26, Settings window part 2: Search, Indexing, About, the shortcut notice. See the t26 note at the top.
        // ============================================================================================================

        // MARK: Search: the shortcut control

        @MainActor
        @Test func searchHoldsTheShortcutControlWithTheLabelsOfPlanOneAndReadsTheStoredCombination() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)   // hotkey "cmd+opt+k" in settings.json
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                let window = stWindow(model)
                window.select(.search)
                window.refresh()
                let screen = window.settingsScreen
                #expect(screen.section == .search, "the window draws \(screen.section.title)")

                // the plan-1 words, unchanged
                #expect(ShortcutControl.recordTitle == "Record new shortcut")
                #expect(ShortcutControl.backToDefaultTitle == "Back to default")
                #expect(ShortcutControl.accessibilityLabel == "Keyboard shortcut")
                for title in ["Record new shortcut", "Back to default"] {
                    #expect(screen.stControl(title) != nil, "no \"\(title)\" among the Search controls \(screen.stLabels)")
                    #expect(stControl(title, in: window) != nil, "no \"\(title)\" control in the Search window")
                }
                let keycaps = stViews(window).filter { $0.isAccessibilityElement() && $0.accessibilityRole() == .group && $0.accessibilityLabel() == "Option Command K" }
                #expect(keycaps.count == 1, "\(keycaps.count) accessibility groups labelled \"Option Command K\" in the Search window")

                // it reads the stored combination in words: Option, Command and K (the order of the words is not pinned)
                let readsCombination = stReadable(window).contains { text in
                    let words = Set(text.split(separator: " ").map(String.init))
                    return words.isSuperset(of: ["Option", "Command", "K"])
                }
                #expect(readsCombination, "Search does not read the stored shortcut Option Command K: \(stReadable(window))")
                // no other section's controls
                #expect(screen.folderRows.isEmpty)
                #expect(screen.stControl("Remove") == nil && screen.stControl(stDeleteTitle) == nil, "other sections' controls in Search: \(screen.stLabels)")
            }
        }

        // MARK: Search: the two app choices

        @MainActor
        @Test func searchHoldsThePdfAndMediaAppPickersWithTheOptionsOfTheAppChoicesTable() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)   // openWith: pdf Preview, media QuickTime Player, code VS Code
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                let window = stWindow(model)
                window.select(.search)
                window.refresh()

                let table: [(label: String, kind: String, chosen: String)] = [
                    ("PDF app", "pdf", "Preview"), ("Media app", "media", "QuickTime Player"),
                ]
                for row in table {
                    let control = window.settingsScreen.stControl(row.label)
                    #expect(control != nil, "no \"\(row.label)\" among the Search controls \(window.settingsScreen.stLabels)")
                    #expect(control?.isEnabled == true, "\"\(row.label)\" is disabled")
                    let popup = try #require(stPopup(row.label, in: window), "no popup button labelled \"\(row.label)\" in the Search window")
                    #expect(popup.itemTitles == AppChoices.options(for: row.kind).map(\.name),
                            "\(row.label) offers \(popup.itemTitles), the choices table has \(AppChoices.options(for: row.kind).map(\.name))")
                    #expect(popup.selectedItem?.title == row.chosen, "\(row.label) shows \(String(describing: popup.selectedItem?.title)) with settings.json holding \(row.chosen)")
                }
            }
        }

        // MARK: Indexing: Start indexing, Launch at login, Delete index…, the could-not-read list

        @MainActor
        @Test func indexingHoldsStartLaunchAtLoginDeleteIndexAndTheNoteWithTheLabelsOfTheEntry() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                let store = try IndexStore()
                defer { store.close() }
                try stIndexRow(store, "/photos/done.jpg", status: "done", inode: 1)   // an index exists, so Delete index has something to delete
                let window = stWindow(model)
                window.select(.indexing)
                window.refresh()
                let screen = window.settingsScreen
                #expect(screen.section == .indexing, "the window draws \(screen.section.title)")

                #expect(screen.stControl(stStartTitle) != nil, "no \"\(stStartTitle)\" among \(screen.stLabels)")
                let login = try #require(screen.stControl(stLoginTitle), "no \"\(stLoginTitle)\" among \(screen.stLabels)")
                #expect(login.isEnabled, "the Launch at login switch is disabled")
                #expect(login.isOn != nil, "Launch at login is not a switch")
                let delete = try #require(screen.stControl(stDeleteTitle), "no \"\(stDeleteTitle)\" among \(screen.stLabels)")
                #expect(delete.isEnabled, "Delete index… is disabled")
                for title in [stStartTitle, stLoginTitle, stDeleteTitle] {
                    #expect(stControl(title, in: window) != nil, "no \"\(title)\" control in the Indexing window")
                }
                #expect(stReads(window, stLoginNote), "the note \"\(stLoginNote)\" is not on screen: \(stReadable(window))")
                #expect(screen.stControl("Remove") == nil && screen.stControl("Record new shortcut") == nil, "other sections' controls in Indexing: \(screen.stLabels)")
            }
        }

        @MainActor
        @Test func theCouldNotReadListShowsItsEmptyStateWhenThereIsNoIndexAndWhenEveryFileWasRead() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))

                // no index file at all
                let first = stWindow(model)
                first.select(.indexing)
                first.refresh()
                #expect(stReads(first, stNothingListed), "no empty state with no index: \(stReadable(first))")

                // an index where nothing failed
                let store = try IndexStore()
                defer { store.close() }
                try stIndexRow(store, "/photos/done.jpg", status: "done", inode: 1)
                try stIndexRow(store, "/photos/waiting.jpg", status: "pending", inode: 2)
                let second = stWindow(model)
                second.select(.indexing)
                second.refresh()
                #expect(stReads(second, stNothingListed), "no empty state when every row is done or pending: \(stReadable(second))")
                #expect(!stReads(second, "done.jpg") && !stReads(second, "waiting.jpg"), "a done or pending file is listed: \(stReadable(second))")
            }
        }

        @MainActor
        @Test func theCouldNotReadListShowsOneRowPerUnreadableFileAsNameCommaReasonAndNoEmptyState() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                let store = try IndexStore()
                defer { store.close() }
                try stDamagedRow(store, "/photos/trip/broken.jpg", reason: "damaged", inode: 1)
                try stIndexRow(store, "/photos/locked.jpg", status: "needs_permission", inode: 2)
                try stIndexRow(store, "/photos/fine.jpg", status: "done", inode: 3)

                let window = stWindow(model)
                window.select(.indexing)
                window.refresh()
                // by path: /photos/locked.jpg, /photos/trip/broken.jpg
                for row in ["locked.jpg, needs permission", "broken.jpg, damaged"] {
                    #expect(stReadable(window).contains(row), "no row \"\(row)\" in \(stReadable(window))")
                }
                #expect(!stReads(window, "fine.jpg"), "a file that was read is listed: \(stReadable(window))")
                #expect(!stReads(window, stNothingListed), "the empty state is shown beside two rows: \(stReadable(window))")
                #expect(!stReadable(window).contains { $0.contains("/photos/") }, "a row shows a folder path: \(stReadable(window))")
            }
        }

        // The rule of the setup window: Start is available when the model is whole and Start was not yet pressed
        // (also with no folder ticked, D11); after Delete index it is available again; a press does what the model's
        // Start does (the plan-1 SettingsModel tests), once.
        @MainActor
        @Test func startIndexingIsEnabledOnlyWhenTheModelIsWholeAndStartWasNotPressedAndAPressStartsOnce() async throws {
            // pressed already, model whole: not available
            try await stRun { env in
                _ = try stOneFolder(env, startPressed: true)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                let window = stWindow(model)
                window.select(.indexing)
                window.refresh()
                #expect(!stEnabled(stStartTitle, in: window), "Start indexing is enabled after it was pressed")
                #expect(window.settingsScreen.stControl(stStartTitle)?.isEnabled != true)
            }
            // not pressed, model not whole: not available
            try await stRun { env in
                _ = try stOneFolder(env, startPressed: false)
                let model = stModel(sender: STSender(), modelWhole: false)
                #expect(await stReady(model))
                let window = stWindow(model)
                window.select(.indexing)
                window.refresh()
                #expect(!stEnabled(stStartTitle, in: window), "Start indexing is enabled while the model is not whole")
            }
            // not pressed, model whole: available, and the press starts once
            try await stRun { env in
                let pictures = try stOneFolder(env, startPressed: false)
                let sender = STSender()
                let model = stModel(sender: sender)
                #expect(await stReady(model))
                let window = stWindow(model)
                window.select(.indexing)
                window.refresh()
                #expect(stEnabled(stStartTitle, in: window), "Start indexing is disabled with the model whole and Start not pressed")
                #expect(env.flag("startPressed") == false)

                #expect(await stPress(stStartTitle, in: window))
                #expect(env.flag("startPressed") == true, "startPressed on disk: \(String(describing: env.flag("startPressed")))")
                #expect(env.flag("indexDeleted") == false)
                #expect(env.reading()[pictures.path] == true, "the ticked folder is not reading after Start: \(env.reading())")
                #expect(sender.calls == 1, "folders was sent \(sender.calls) times by Start")
                #expect(await stEventually { !stEnabled(stStartTitle, in: window) }, "Start indexing stays enabled after it was pressed")
                #expect(!(await stPress(stStartTitle, in: window)), "Start indexing could be pressed twice")
                #expect(sender.calls == 1)
            }
            // no folder ticked: still available (D11)
            try await stRun { env in
                try env.seed(folders: [], startPressed: false)
                let model = stModel(sender: STSender())
                let window = stWindow(model)
                window.select(.indexing)
                window.refresh()
                #expect(stEnabled(stStartTitle, in: window), "Start indexing is disabled with no folder ticked")
            }
        }

        // MARK: Folders: the Add folder button exists, Re-index on a folder with no pending tick is a plain sync request

        // plan-2 fix round B, item B1 (R2-01): RE-PINNED by the round's fresh tester. The old test pinned "Re-index is inert"
        // (an `onReindex = { _ in }` dead control). The ruling: the per-folder Re-index applies that folder's pending tick
        // the same way Start does, and for a folder whose tick is not pending it is a plain sync request.
        // The first enabled Re-index in the window is Trips's, a ticked folder that is already reading, so nothing is pending.
        //   was: `#expect(sender.calls == 0, "Re-index sent folders \(sender.calls) times")`
        //   now: `#expect(sender.calls == 1, ...)`        (settings.json, the rows and the confirm are still unchanged)
        // Renamed to say what it holds now. The pending-folder side is in the B1 tests at the end of this file.
        @MainActor
        @Test func theAddFolderButtonExistsAndReIndexOnAFolderWithNoPendingTickOnlyAsksForASync() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let sender = STSender()
                let model = stModel(sender: sender)
                #expect(await stReady(model))
                let window = stWindow(model)
                window.select(.folders)
                window.refresh()

                // The button is looked for and never pressed: it opens the macOS folder picker.
                #expect(window.settingsScreen.stControl(stAddFolderTitle) != nil, "no \"\(stAddFolderTitle)\" among \(window.settingsScreen.stLabels)")
                #expect(stControl(stAddFolderTitle, in: window) != nil, "no \"\(stAddFolderTitle)\" control in the Folders window")
                #expect(stEnabled(stAddFolderTitle, in: window), "\"\(stAddFolderTitle)\" is disabled")

                // Re-index on a folder with nothing pending: not settings.json, not the rows, no confirm; one folders request
                let bytes = try? Data(contentsOf: env.settings)
                let rows = model.rows.map { $0.path }
                #expect(await stPress("Re-index", in: window), "no enabled Re-index in the window")
                await stQuietPeriod()
                #expect((try? Data(contentsOf: env.settings)) == bytes, "Re-index wrote settings.json")
                #expect(model.rows.map { $0.path } == rows, "Re-index changed the rows")
                #expect(sender.calls == 1, "Re-index of a folder with nothing pending sent folders \(sender.calls) times, not one plain sync request")
                #expect(window.settingsScreen.confirm == nil, "Re-index opened a confirm")
            }
        }

        // MARK: the key-view loop and labels of the three new sections (the confirm sheets are not part of it)

        @MainActor
        @Test func everyEnabledControlOfSearchAndIndexingIsInTheKeyViewLoopWithALabelThatIsNotARoleWord() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                let store = try IndexStore()
                defer { store.close() }
                try stIndexRow(store, "/photos/locked.jpg", status: "needs_permission", inode: 1)
                let window = stWindow(model)

                // what each section must hold for the walk to mean anything (the sidebar's own buttons are always there)
                let own: [SettingsScreen.Section: [String]] = [
                    .search: ["Record new shortcut", "PDF app", "Media app"],
                    .indexing: [stStartTitle, stLoginTitle, stDeleteTitle],
                ]
                for section in [SettingsScreen.Section.search, .indexing] {
                    window.select(section)
                    window.refresh()
                    let title = section.title
                    #expect(window.settingsScreen.section == section, "\(title): the window draws \(window.settingsScreen.section.title)")
                    #expect(window.settingsScreen.confirm == nil, "\(title): a confirm is open")
                    for label in own[section] ?? [] {
                        #expect(window.settingsScreen.stControl(label) != nil, "\(title): no \"\(label)\" control in \(window.settingsScreen.stLabels)")
                        if let found = stControl(label, in: window), found.isEnabled {
                            let loop = stKeyLoop(window)
                            #expect(loop.visited.contains { $0 === found }, "\(title): \"\(label)\" is not in the key-view loop")
                        }
                    }

                    let controls = stEnabledControls(in: window)
                    #expect(!controls.isEmpty, "\(title): the window has no enabled control")
                    if !controls.isEmpty {
                        let loop = stKeyLoop(window)
                        #expect(loop.started, "\(title): the window has no initialFirstResponder")
                        #expect(loop.closed, "\(title): the key-view loop never returned to its start (\(loop.visited.count) views)")
                        for control in controls {
                            let name = (control as? NSButton)?.title ?? control.accessibilityLabel() ?? String(describing: type(of: control))
                            #expect(loop.visited.contains { $0 === control },
                                    "\(title): the enabled control \"\(name)\" is not in the key-view loop (full keyboard access: \(NSApp.isFullKeyboardAccessEnabled))")
                            #expect(!stBare(control.accessibilityLabel()),
                                    "\(title): the control \"\(name)\" has the accessibility label \"\(control.accessibilityLabel() ?? "nil")\"")
                        }
                    }
                    #expect(!window.settingsScreen.texts.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                            "\(title): an empty text among \(window.settingsScreen.texts)")
                    for control in window.settingsScreen.controls {
                        #expect(!stBare(control.label), "\(title): the control \"\(control.label)\" has no usable label")
                    }
                    // the enabled controls of the screen's table are really there, as controls with that label
                    for control in window.settingsScreen.controls where control.isEnabled {
                        #expect(stControl(control.label, in: window)?.isEnabled == true, "\(title): no enabled control \"\(control.label)\" in the window")
                    }
                }
            }
        }

        // ============================================================================================================
        // plan-2-t26, the tests that hand the window its services (new initialiser parameters, new AppDelegate seam)
        // ============================================================================================================

        // MARK: Search: the shortcut control acts on the control it was given, shows its message and the notice once

        @MainActor
        @Test func pressingBackToDefaultInSearchActsOnTheShortcutControlTheWindowWasGivenAndStoresTheDefault() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)   // hotkey "cmd+opt+k"
                let rig = await stRig()
                let before = env.settingsDictionary()
                rig.window.select(.search)
                rig.window.refresh()

                #expect(await stPress("Back to default", in: rig.window), "no enabled \"Back to default\" with a non-default shortcut stored")
                #expect(env.hotkeyKeys() == stDefaultParts, "hotkey on disk: \(String(describing: env.settingsDictionary()?["hotkey"]))")
                #expect(rig.shortcut.displayText == "Control Option Space", "the control reads \"\(rig.shortcut.displayText)\"")
                #expect(rig.hotkeyCalls.all.map(stParts) == [stDefaultParts], "the shortcut's onChange calls: \(rig.hotkeyCalls.all)")
                #expect(env.withoutKeys(["hotkey"]) == stWithout(before, ["hotkey"]), "Back to default changed another settings field")
                #expect(await stEventually { stReads(rig.window, "Control Option Space") }, "the window does not read Control Option Space: \(stReadable(rig.window))")
            }
        }

        @MainActor
        @Test func theShortcutMessageIsShownInSearchAndGoesWhenTheControlClearsIt() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let rig = await stRig()
                rig.window.select(.search)
                rig.window.refresh()
                let text = "Another app has that shortcut. Pick a different one."
                #expect(!stReads(rig.window, text))

                rig.shortcut.report(text)
                rig.window.refresh()
                #expect(stReads(rig.window, text), "a reported message is not on screen: \(stReadable(rig.window))")

                rig.shortcut.clearMessage()
                rig.window.refresh()
                #expect(!stReads(rig.window, text), "a cleared message is still on screen: \(stReadable(rig.window))")

                // a refusal by the closed list shows the control's own message
                rig.shortcut.record("cmd+space")
                let refusal = try #require(rig.shortcut.message, "a refused combination left no message")
                rig.window.refresh()
                #expect(stReads(rig.window, refusal), "the refusal \"\(refusal)\" is not on screen: \(stReadable(rig.window))")
                #expect(env.hotkeyKeys() == stParts("cmd+opt+k"), "a refusal changed the stored shortcut: \(env.hotkeyKeys())")
            }
        }

        @MainActor
        @Test func theShortcutNoticeOfT4ShowsOnceWhenSettingsOpensAndTheSecondOpenShowsNone() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)   // saved "cmd+opt+k"; the Mac refused it at launch and used the default
                let control = ShortcutControl()
                let refusedWords = control.displayText
                #expect(refusedWords != "Control Option Space", "the seed was not read: \(refusedWords)")
                control.adoptLive("ctrl+opt+space", refused: "cmd+opt+k")
                let expected = "The shortcut \(refusedWords) is taken by another app, so Sesame is using Control Option Space."

                // first open: the notice is on screen, and the control has none left
                let first = await stRig(shortcut: control)
                #expect(stEverywhere(first.window).contains { $0.contains(expected) },
                        "the notice \"\(expected)\" is not on screen when Settings opens: \(stEverywhere(first.window))")
                #expect(control.takeNotice() == nil, "the window left the notice in the control: it was not read at open")

                // second open over the same control: none
                let second = await stRig(shortcut: control)
                let everywhere = stEverywhere(second.window)
                #expect(!everywhere.contains { $0.contains(stNoticeFragment) }, "the notice came again on the second open: \(everywhere)")
                #expect(!everywhere.contains { $0.contains(ShortcutControl.notSavedText) })

                // and the combination in force is the live one
                #expect(env.hotkeyKeys() == stDefaultParts, "hotkey on disk: \(env.hotkeyKeys())")
            }
        }

        @MainActor
        @Test func theNotSavedNoticeShowsOnceToo() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let control = ShortcutControl()
                let before = try Data(contentsOf: env.settings)
                let fm = FileManager.default
                try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: env.settings.path)
                try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: env.folder.path)
                defer {
                    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.folder.path)
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.settings.path)
                }
                try #require(!fm.isWritableFile(atPath: env.folder.path), "the Sesame folder is still writable, so a failed write cannot be made here")
                control.adoptLive("ctrl+opt+space", refused: "cmd+opt+k")
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.folder.path)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.settings.path)
                #expect(try Data(contentsOf: env.settings) == before, "the old settings.json was changed by the failed write")

                let first = await stRig(shortcut: control)
                #expect(stEverywhere(first.window).contains { $0.contains(ShortcutControl.notSavedText) }, "the not-saved notice is not on screen: \(stEverywhere(first.window))")
                let second = await stRig(shortcut: control)
                #expect(!stEverywhere(second.window).contains { $0.contains(ShortcutControl.notSavedText) }, "the not-saved notice came a second time")
            }
        }

        // MARK: Search: the app choices and their "not installed" notes

        @MainActor
        @Test func eachChosenAppThatIsNotInstalledShowsItsNoteAndAnInstalledOneShowsNone() async throws {
            // nothing installed: the two stored choices (Preview, QuickTime Player) each carry the note, and the stored code editor none
            try await stRun { env in
                _ = try stBuildFolders(env)
                let rig = await stRig(installed: [])
                rig.window.select(.search)
                rig.window.refresh()
                for name in ["Preview", "QuickTime Player"] {
                    #expect(stReads(rig.window, name + stNotInstalledFragment), "no \"\(name)\(stNotInstalledFragment)\" in \(stReadable(rig.window))")
                }
                #expect(!stReads(rig.window, "VS Code"), "the stored code editor is shown: \(stReadable(rig.window))")
            }
            // Preview installed: only QuickTime Player is told
            try await stRun { env in
                _ = try stBuildFolders(env)
                let rig = await stRig(installed: ["com.apple.Preview"])
                rig.window.select(.search)
                rig.window.refresh()
                #expect(stReads(rig.window, "QuickTime Player" + stNotInstalledFragment), "no QuickTime Player note in \(stReadable(rig.window))")
                #expect(!stReads(rig.window, "Preview" + stNotInstalledFragment), "Preview is installed and still has a note")
            }
            // everything installed: no note at all
            try await stRun { env in
                _ = try stBuildFolders(env)
                let all = Set(AppChoices.kinds.flatMap { kind in AppChoices.options(for: kind).map(\.bundleID) })
                let rig = await stRig(installed: all)
                rig.window.select(.search)
                rig.window.refresh()
                #expect(!stReads(rig.window, " is not installed"), "a note with every app installed: \(stReadable(rig.window))")
            }
        }

        @MainActor
        @Test func choosingAnAppStoresItUnderItsOwnKeyAndAnAppThatIsNotInstalledIsAllowedWithItsNote() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)   // openWith: pdf Preview, media QuickTime Player, code VS Code
                let rig = await stRig(installed: [])
                let before = env.settingsDictionary()
                rig.window.select(.search)
                rig.window.refresh()

                let pdf = try #require(stPopup("PDF app", in: rig.window), "no \"PDF app\" popup")
                #expect(await stChoose("Skim", in: pdf), "no enabled \"Skim\" in \(pdf.itemTitles)")
                #expect(env.openWith() == ["pdf": "Skim", "media": "QuickTime Player", "code": "VS Code"], "openWith: \(env.openWith())")
                let media = try #require(stPopup("Media app", in: rig.window), "no \"Media app\" popup after a redraw")
                #expect(await stChoose("VLC", in: media))

                #expect(env.openWith() == ["pdf": "Skim", "media": "VLC", "code": "VS Code"], "openWith: \(env.openWith())")
                #expect(env.withoutKeys(["openWith"]) == stWithout(before, ["openWith"]), "a choice changed another settings field")
                for name in ["Skim", "VLC"] {
                    #expect(await stEventually { stReads(rig.window, name + stNotInstalledFragment) }, "no \"\(name)\(stNotInstalledFragment)\" after choosing it: \(stReadable(rig.window))")
                }
                // the popups show the choices
                #expect(stPopup("PDF app", in: rig.window)?.selectedItem?.title == "Skim")
                #expect(stPopup("Media app", in: rig.window)?.selectedItem?.title == "VLC")
                #expect(stPopup("Code editor", in: rig.window) == nil)
                // nothing was sent to the helper by a choice
                await stQuietPeriod()
                #expect(rig.sender.calls == 0, "a choice sent folders")
            }
        }

        // MARK: Indexing: Launch at login

        @MainActor
        @Test func theLaunchAtLoginSwitchReadsTheLiveStatusAndOpeningSettingsRegistersNothing() async throws {
            let table: [(LoginStatus, Bool)] = [(.enabled, true), (.requiresApproval, true), (.notRegistered, false), (.notFound, false)]
            for (status, expected) in table {
                try await stRun { env in
                    _ = try stBuildFolders(env)
                    let before = try Data(contentsOf: env.settings)
                    let rig = await stRig(loginStatus: status)
                    rig.window.select(.indexing)
                    rig.window.refresh()
                    let control = try #require(rig.window.settingsScreen.stControl(stLoginTitle), "[\(status.rawValue)] no \"\(stLoginTitle)\" in \(rig.window.settingsScreen.stLabels)")
                    #expect(control.isOn == expected, "[\(status.rawValue)] the switch reads \(String(describing: control.isOn))")
                    #expect(stDrawnOn(stControl(stLoginTitle, in: rig.window)) == expected, "[\(status.rawValue)] the switch is drawn \(String(describing: stDrawnOn(stControl(stLoginTitle, in: rig.window))))")
                    #expect(stReads(rig.window, stLoginNote), "[\(status.rawValue)] the note is not on screen")

                    _ = stEverywhere(rig.window)
                    #expect(rig.service.registerCount == 0 && rig.service.unregisterCount == 0,
                            "[\(status.rawValue)] opening Settings changed the login item: register \(rig.service.registerCount), unregister \(rig.service.unregisterCount)")
                    #expect(try Data(contentsOf: env.settings) == before, "[\(status.rawValue)] opening Settings wrote settings.json")
                }
            }
        }

        @MainActor
        @Test func pressingLaunchAtLoginUnregistersThenRegistersAndTheSwitchIsRedrawnFromTheLiveStatus() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let rig = await stRig(loginStatus: .enabled)
                rig.window.select(.indexing)
                rig.window.refresh()

                #expect(await stPress(stLoginTitle, in: rig.window), "no enabled \"\(stLoginTitle)\" switch")
                #expect(rig.service.unregisterCount == 1 && rig.service.registerCount == 0,
                        "register \(rig.service.registerCount), unregister \(rig.service.unregisterCount) after turning it off")
                #expect(await stEventually { rig.window.settingsScreen.stControl(stLoginTitle)?.isOn == false }, "the switch still reads on")
                #expect(stDrawnOn(stControl(stLoginTitle, in: rig.window)) == false, "the switch is still drawn on")

                #expect(await stPress(stLoginTitle, in: rig.window))
                #expect(rig.service.registerCount == 1 && rig.service.unregisterCount == 1,
                        "register \(rig.service.registerCount), unregister \(rig.service.unregisterCount) after turning it on again")
                #expect(await stEventually { rig.window.settingsScreen.stControl(stLoginTitle)?.isOn == true }, "the switch still reads off")
                #expect(stDrawnOn(stControl(stLoginTitle, in: rig.window)) == true)
                #expect(!stReads(rig.window, stLoginMessage), "an error is shown for changes that worked")
                #expect(stReads(rig.window, stLoginNote))
            }
        }

        @MainActor
        @Test func aLoginChangeThatThrowsLeavesTheSwitchAtTheLiveStatusAndShowsTheMessage() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let rig = await stRig(loginStatus: .notRegistered)
                rig.service.registerThrows = true
                rig.window.select(.indexing)
                rig.window.refresh()

                #expect(await stPress(stLoginTitle, in: rig.window))
                #expect(rig.service.registerCount == 1)
                #expect(await stEventually { stReads(rig.window, stLoginMessage) }, "no \"\(stLoginMessage)\" on screen: \(stReadable(rig.window))")
                #expect(rig.window.settingsScreen.stControl(stLoginTitle)?.isOn == false, "the switch reads on though register() threw")
                #expect(stDrawnOn(stControl(stLoginTitle, in: rig.window)) == false, "the switch is drawn on though register() threw")
            }
        }

        @MainActor
        @Test func theSwitchFollowsAChangeMadeBehindTheWindowsBackOnTheNextRedraw() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)
                let rig = await stRig(loginStatus: .enabled)
                rig.window.select(.indexing)
                rig.window.refresh()
                #expect(rig.window.settingsScreen.stControl(stLoginTitle)?.isOn == true)

                // the person turns the item off in System Settings; Sesame hears nothing
                rig.service.status = .notRegistered
                rig.window.refresh()
                #expect(rig.window.settingsScreen.stControl(stLoginTitle)?.isOn == false, "the switch kept an old answer")
                #expect(stDrawnOn(stControl(stLoginTitle, in: rig.window)) == false)
                rig.service.status = .requiresApproval
                rig.window.refresh()
                #expect(rig.window.settingsScreen.stControl(stLoginTitle)?.isOn == true, "requires_approval reads off")
                #expect(rig.service.registerCount == 0 && rig.service.unregisterCount == 0, "a redraw changed the login item")
            }
        }

        // MARK: Indexing: Delete index…

        @MainActor
        @Test func deleteIndexOpensAConfirmAndRunsTheDeleteOnlyAfterItsConfirmButton() async throws {
            try await stRun { env in
                let pictures = try stOneFolder(env, startPressed: true)
                let store = try IndexStore()
                defer { store.close() }
                try stIndexRow(store, "/photos/done.jpg", status: "done", inode: 1)
                let rig = await stRig()
                rig.window.select(.indexing)
                rig.window.refresh()
                let bytes = try? Data(contentsOf: env.settings)

                // Delete index… opens the confirm and does nothing else
                #expect(await stPress(stDeleteTitle, in: rig.window), "no enabled \"\(stDeleteTitle)\"")
                #expect(await stEventually { rig.window.settingsScreen.confirm != nil }, "pressing \(stDeleteTitle) opened no confirm")
                let confirm = try #require(rig.window.settingsScreen.confirm)
                #expect(confirm.message.lowercased().contains("index"), "the confirm does not say what is deleted: \"\(confirm.message)\"")
                #expect(confirm.cancelTitle == "Cancel", "cancel title \"\(confirm.cancelTitle)\"")
                #expect(!confirm.confirmTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && confirm.confirmTitle != "Cancel",
                        "confirm title \"\(confirm.confirmTitle)\"")
                await stQuietPeriod()
                #expect(rig.recorder.events.isEmpty, "the delete ran before its confirm: \(rig.recorder.events)")
                #expect((try? Data(contentsOf: env.settings)) == bytes, "opening the confirm wrote settings.json")
                #expect(rig.sender.calls == 0)

                // Cancel closes it and still nothing runs
                #expect(await stPress(confirm.cancelTitle, in: rig.window), "no enabled \"\(confirm.cancelTitle)\" button while the confirm is open")
                #expect(await stEventually { rig.window.settingsScreen.confirm == nil }, "Cancel left the confirm open")
                await stQuietPeriod()
                #expect(rig.recorder.events.isEmpty, "Cancel ran the delete: \(rig.recorder.events)")
                #expect((try? Data(contentsOf: env.settings)) == bytes, "Cancel wrote settings.json")

                // again, then the confirm button: the four steps of DeleteIndex.run(confirmed: true), in its order
                #expect(await stPress(stDeleteTitle, in: rig.window))
                #expect(await stEventually { rig.window.settingsScreen.confirm != nil })
                let second = try #require(rig.window.settingsScreen.confirm)
                #expect(await stPress(second.confirmTitle, in: rig.window), "no enabled \"\(second.confirmTitle)\" button while the confirm is open")
                #expect(await stEventually { rig.recorder.events.count >= 3 }, "the delete did not run after its confirm: \(rig.recorder.events)")
                await stQuietPeriod()
                #expect(rig.recorder.events == ["close", "reset", "caches"], "steps run: \(rig.recorder.events)")
                #expect(rig.recorder.atReset?.startPressed == false && rig.recorder.atReset?.indexDeleted == true,
                        "settings.json at the reset: \(String(describing: rig.recorder.atReset))")
                #expect(env.flag("startPressed") == false && env.flag("indexDeleted") == true, "flags on disk: \(String(describing: env.settingsDictionary()))")
                #expect(env.reading()[pictures.path] == true, "the folders were not kept: \(env.reading())")
                #expect(await stEventually { rig.window.settingsScreen.confirm == nil }, "the confirm stayed open after the delete")
                #expect(FileManager.default.fileExists(atPath: pictures.path + "/photo-0.jpg"), "a file of a picked folder was deleted")
            }
        }

        @MainActor
        @Test func afterDeleteIndexStartIndexingIsAvailableAgainAndStartsFromSettings() async throws {
            try await stRun { env in
                let pictures = try stOneFolder(env, startPressed: true)
                let store = try IndexStore()
                defer { store.close() }
                try stIndexRow(store, "/photos/done.jpg", status: "done", inode: 1)
                let rig = await stRig()
                rig.window.select(.indexing)
                rig.window.refresh()
                #expect(!stEnabled(stStartTitle, in: rig.window), "Start indexing is enabled before the delete")

                #expect(await stPress(stDeleteTitle, in: rig.window))
                #expect(await stEventually { rig.window.settingsScreen.confirm != nil })
                let confirm = try #require(rig.window.settingsScreen.confirm)
                #expect(await stPress(confirm.confirmTitle, in: rig.window))
                #expect(await stEventually { rig.recorder.events.count >= 3 }, "the delete did not run: \(rig.recorder.events)")
                #expect(await stEventually { stEnabled(stStartTitle, in: rig.window) }, "Start indexing is not available after Delete index")
                #expect(rig.sender.calls == 0, "Delete index sent folders")

                #expect(await stPress(stStartTitle, in: rig.window))
                #expect(env.flag("startPressed") == true && env.flag("indexDeleted") == false, "flags after Start: \(String(describing: env.settingsDictionary()))")
                #expect(env.reading()[pictures.path] == true)
                #expect(rig.sender.calls == 1, "folders was sent \(rig.sender.calls) times by Start")
            }
        }

        // MARK: the wiring: AppDelegate builds the container window in place of the plan-1 shortcut window

        @MainActor
        @Test func theAppDelegatesSettingsWindowIsTheContainerWindowOverTheModelAndTheShortcutControlItWasGiven() async throws {
            try await stRun { env in
                _ = try stBuildFolders(env)   // hotkey "cmd+opt+k"
                let model = stModel(sender: STSender())
                #expect(await stReady(model))
                let calls = STList()
                let shortcut = ShortcutControl(onChange: { calls.add($0) })

                let window: NSWindow = AppDelegate.makeSettingsWindow(model: model, shortcut: shortcut)
                window.isReleasedWhenClosed = false

                #expect(window is SettingsContainerWindow, "the delegate builds a \(type(of: window))")
                #expect(String(describing: type(of: window)) != "ShortcutSettingsWindow", "the delegate still builds the plan-1 window")
                #expect(window.title == SettingsWindow.title, "window title \"\(window.title)\"")
                let container = try #require(window as? SettingsContainerWindow, "not a SettingsContainerWindow")
                #expect(container.model === model, "the window holds another model")
                #expect(container.settingsScreen.sections.map { $0.title } == ["Folders", "File types", "Search", "Indexing"])
                #expect(container.settingsScreen.section == .folders)

                // it is wired to the control it was given: Back to default reaches it, and its onChange
                container.select(.search)
                container.refresh()
                #expect(await stPress("Back to default", in: container), "no enabled \"Back to default\" in the delegate's window")
                #expect(shortcut.displayText == "Control Option Space", "the control reads \"\(shortcut.displayText)\"")
                #expect(calls.all.map(stParts) == [stDefaultParts], "onChange calls: \(calls.all)")
                #expect(env.hotkeyKeys() == stDefaultParts)
                // and nothing was ordered front
                #expect(!window.isVisible, "the seam showed the window")
            }
        }
    }
}

// =================================================================================================================
// plan-2 fix round B, tester step: B1 (the pending tick, Start indexing and Re-index in the window) and B3 (the code
// folders in Settings). Written from the fix-round document (Rulings: "Start indexing in Settings is enabled when the model
// is whole and (Start was never pressed OR any folder's `ticked` differs from its `reading`). Pressing it writes `reading =
// ticked` for every folder, sets `startPressed`, and sends `folders` ... The per-folder Re-index button applies that
// folder's pending tick the same way (it is not a destructive re-read), so it is no longer a dead control, and a folder
// whose tick is not pending makes it a plain sync request"; "Code folders ... in this build their ticks stay disabled with
// the line \"Code is not read in this version.\""), the review report (R2-01, R2-02, R2-09) and the sealed tests above.
// No product source was read. Every expected value is written by hand from the folders each test builds.
//
// API SHAPES (no new Swift name): a pending tick is a folder entry whose `ticked` is true and whose `reading` is false in
// settings.json (the key `ticked` is the document's; a missing key reads as `reading`). A folder row's "Re-index" is
// found the way the kit finds it: among the window's NSButtons titled "Re-index", the one whose accessibility help is the
// folder's name (item B8 pins that help), or, when no button carries that help, the one at the row's position in the
// screen's `folderRows` (so these tests do not fail twice for B8's reason).
// =================================================================================================================

private extension STEnv {
    func entry(_ path: String) -> NSDictionary? { folderEntries().first { ($0["path"] as? String) == path } }

    // The tick as the file holds it: the `ticked` key, else `reading`.
    func tickedOnDisk(_ path: String) -> Bool? {
        let found = entry(path)
        return (found?["ticked"] as? Bool) ?? (found?["reading"] as? Bool)
    }
}

@MainActor
private func stReindexItem(for name: String, in window: SettingsContainerWindow) -> NSMenuItem? {
    guard let root = window.contentView else { return nil }
    let buttons = smrMoreButtons(root)
    if let byLabel = buttons.first(where: { $0.accessibilityLabel() == smrMorePrefix + name }) { return smrItem("Re-index", of: byLabel) }
    guard let index = window.settingsScreen.folderRows.firstIndex(where: { $0.name == name }), index < buttons.count else { return nil }
    return smrItem("Re-index", of: buttons[index])
}

extension ModelDownloadTests.SettingsScreenTests {

    @MainActor
    @Test func startIndexingIsEnabledAfterStartWhileAFolderAddedLaterWaitsAndAPressReadsEveryTick() async throws {
        try await stRun { env in
            let pictures = try stOneFolder(env, startPressed: true)
            let sender = STSender()
            let model = stModel(sender: sender)
            #expect(await stReady(model))
            let window = stWindow(model)
            window.select(.indexing)
            window.refresh()
            #expect(!stEnabled(stStartTitle, in: window), "setup: with nothing pending Start must be unavailable after it was pressed")

            // a folder added in Settings after the first Start waits for Start indexing
            let extra = try env.fill("Extra", photo: 2)
            model.addFolder(extra)
            #expect(await stReady(model))
            window.refresh()
            #expect(stEnabled(stStartTitle, in: window), "Start indexing is disabled although a folder waits for it (R2-01)")
            #expect(sender.calls == 0, "adding a folder sent folders")

            #expect(await stPress(stStartTitle, in: window), "no enabled Start indexing to press")
            #expect(env.reading()[extra.path] == true, "the folder that waited is not read after Start: \(env.reading())")
            #expect(env.reading()[pictures.path] == true)
            #expect(env.flag("startPressed") == true)
            #expect(sender.calls == 1, "folders was sent \(sender.calls) times by Start")
            #expect(await stEventually { !stEnabled(stStartTitle, in: window) }, "Start indexing stays enabled with nothing left waiting")
            #expect(!(await stPress(stStartTitle, in: window)), "Start indexing could be pressed twice")
            #expect(sender.calls == 1)
            #expect(model.rows.first { $0.path == extra.path }?.ticked == true)
        }
    }

    @MainActor
    @Test func aFolderUntickedAndTickedAgainMakesStartAvailableAndAPressReadsItAgain() async throws {
        try await stRun { env in
            let folders = try stBuildFolders(env)   // Trips and Notes read, Archive does not; startPressed true
            let sender = STSender()
            let model = stModel(sender: sender)
            #expect(await stReady(model))
            let window = stWindow(model)
            window.select(.indexing)
            window.refresh()
            #expect(!stEnabled(stStartTitle, in: window), "setup: nothing pending")

            // unticked: it stops reading at once and nothing waits, so Start stays unavailable
            model.setTicked(folders.trips.path, false)
            window.refresh()
            #expect(env.reading()[folders.trips.path] == false)
            #expect(!stEnabled(stStartTitle, in: window), "Start indexing is available with the only change an untick")

            // ticked again: it waits for Start
            model.setTicked(folders.trips.path, true)
            #expect(await stReady(model))
            window.refresh()
            #expect(stEnabled(stStartTitle, in: window), "Start indexing is disabled although a re-ticked folder waits for it (R2-01)")
            #expect(await stPress(stStartTitle, in: window))
            #expect(env.reading()[folders.trips.path] == true, "the re-ticked folder is not read after Start: \(env.reading())")
            #expect(env.reading()[folders.notes.path] == true)
            #expect(env.reading()[folders.archive.path] == false, "an unticked folder started reading: \(env.reading())")
            #expect(sender.calls == 2, "one send for the untick and one for Start, got \(sender.calls)")
        }
    }

    @MainActor
    @Test func startIndexingStaysUnavailableWhileTheModelIsNotWholeEvenWithAFolderWaiting() async throws {
        try await stRun { env in
            _ = try stOneFolder(env, startPressed: true)
            let model = stModel(sender: STSender(), modelWhole: false)
            #expect(await stReady(model))
            model.addFolder(try env.fill("Extra", photo: 2))
            #expect(await stReady(model))
            let window = stWindow(model)
            window.select(.indexing)
            window.refresh()
            #expect(!stEnabled(stStartTitle, in: window), "Start indexing is enabled while the model is not whole")
        }
    }

    @MainActor
    @Test func aWaitingFolderIsStillWaitingWhenSettingsIsOpenedAgain() async throws {
        try await stRun { env in
            _ = try stOneFolder(env, startPressed: true)
            let first = stModel(sender: STSender())
            #expect(await stReady(first))
            let extra = try env.fill("Extra", photo: 40)
            first.addFolder(extra)
            #expect(await stReady(first))

            // the window is closed and a new one opened over a new model (R2-02)
            let second = stModel(sender: STSender())
            #expect(await stReady(second))
            let screen = SettingsScreen(model: second)
            let row = try #require(screen.stRow("Extra"), "the added folder is gone when Settings opens again: \(screen.folderRows.map { $0.name })")
            #expect(row.tick.isOn == true, "the added folder comes back unticked")
            #expect(row.detail.contains(stWaiting), "the added folder does not say it waits: \"\(row.detail)\"")
            #expect(row.detail.contains("40"), "the added folder's counts are missing: \"\(row.detail)\"")
            #expect(!row.detail.contains("about 2 min"), "the added folder shows an estimate before Start: \"\(row.detail)\"")
            let window = stWindow(second)
            window.select(.indexing)
            window.refresh()
            #expect(stEnabled(stStartTitle, in: window), "Start indexing is unavailable in the reopened window")
        }
    }

    @MainActor
    @Test func reIndexOnAWaitingFolderAppliesThatFoldersTickAndLeavesTheOthersWaiting() async throws {
        try await stRun { env in
            let folders = try stBuildFolders(env)   // Trips and Notes read, Archive unticked
            let sender = STSender()
            let model = stModel(sender: sender)
            #expect(await stReady(model))
            let first = try env.fill("Extra1", photo: 3)
            let second = try env.fill("Extra2", photo: 3)
            model.addFolder(first)
            model.addFolder(second)
            #expect(await stReady(model))
            let window = stWindow(model)
            window.refresh()
            #expect(env.reading()[first.path] == false && env.reading()[second.path] == false, "setup: both wait")

            let item = stReindexItem(for: "Extra1", in: window)
            #expect(item != nil, "no Re-index menu item for Extra1")
            #expect(await smrPerform(item), "the Re-index of a waiting folder cannot be chosen")

            #expect(env.reading()[first.path] == true, "Re-index did not apply the folder's tick: \(env.reading())")
            #expect(env.tickedOnDisk(first.path) == true)
            #expect(env.reading()[second.path] == false, "Re-index of one folder started another: \(env.reading())")
            #expect(env.tickedOnDisk(second.path) == true, "Re-index of one folder dropped another folder's waiting tick: \(env.folderEntries())")
            #expect(env.reading()[folders.trips.path] == true && env.reading()[folders.notes.path] == true && env.reading()[folders.archive.path] == false,
                    "the other folders changed: \(env.reading())")
            #expect(sender.calls == 1, "folders was sent \(sender.calls) times by Re-index")
            #expect(env.flag("startPressed") == true)
            #expect(await stEventually { window.settingsScreen.stRow("Extra1")?.detail.contains(stWaiting) == false }, "Extra1 still says it waits")
            #expect(window.settingsScreen.stRow("Extra2")?.detail.contains(stWaiting) == true, "Extra2 stopped waiting")
        }
    }

    @MainActor
    @Test func reIndexOnAFolderThatIsReadingWritesNothingAndLeavesAWaitingFolderWaiting() async throws {
        try await stRun { env in
            let folders = try stBuildFolders(env)
            let sender = STSender()
            let model = stModel(sender: sender)
            #expect(await stReady(model))
            let extra = try env.fill("Extra", photo: 3)
            model.addFolder(extra)
            #expect(await stReady(model))
            let window = stWindow(model)
            window.refresh()
            let before = try? Data(contentsOf: env.settings)

            #expect(await smrPerform(stReindexItem(for: "Trips", in: window)), "no Re-index to choose for Trips")
            await stQuietPeriod()
            #expect((try? Data(contentsOf: env.settings)) == before, "Re-index of a folder with nothing pending wrote settings.json")
            #expect(sender.calls == 1, "a plain sync request is one folders send, got \(sender.calls)")
            #expect(env.reading()[extra.path] == false, "Re-index of Trips started the waiting folder: \(env.reading())")
            #expect(env.reading()[folders.trips.path] == true)
        }
    }
}
