import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2 fix round B, tester step, item B8 (R2-04, product side; also R2-03, R2-06, R2-11): what a screen reader, and the
// kit's AX dump, read from the real Setup and Settings windows. The kit reads folder rows by absolute path and counts, but
// the product exposed the folder name only; it clicks "Remove" and "Re-index" by label, so every row's buttons carried the
// same label; and it never selected a Settings section, so it could not reach "Start indexing", "Delete index…" or
// "Launch at login". Written from the fix-round document (B8: every folder row's tick control keeps the accessibility label
// "<name>, <counts>" and also exposes the folder's full path as its accessibility help, in Setup and in Settings; the
// per-row Re-index and Remove keep their exact labels and expose "<folder name>" as accessibility help; build the real
// views offscreen, read `accessibilityTitle`, `accessibilityLabel`, `accessibilityHelp`, assert them as hand-written
// strings; the sidebar buttons are reachable and selecting a section makes its controls appear in the accessibility
// children), the review report (the probe: checkbox title "Desktop", label "Desktop, 5 photos, about 1 min", the detail
// text field not an accessibility element) and the sealed Setup and Settings tests (names of the screens, windows and
// buttons). No product source was read. Every expected string is written here by hand. No window is ordered front, made
// key or shown; no app is launched; no helper starts (the helper file does not exist, and Start is never pressed).
//
// SUITE PLACEMENT. HOME is process-wide: nested inside `ModelDownloadTests` like the other Setup and Settings suites.
//
// WHAT THIS FILE READS. The "kit label" of a control is what `ax.applescript` prints: the accessibility title when it is
// not empty, else the accessibility label (the review report: `labelOf` prints the title first). A press is
// `performClick(nil)`. "The accessibility children" are the content view's subviews that are accessibility
// elements and not hidden (nor under a hidden view), as the AX server lists them.
//
// API SHAPES pinned (strings, no new Swift name):
//   - Setup and Settings folder row tick (an NSButton): `accessibilityLabel()` starts with "<name>, " (Setup's goes on with
//     the counts, "Desktop, 5 photos" for five photos, and the estimate), and `accessibilityHelp()` is exactly the folder's
//     full path.
//   - Settings row more buttons: label "More actions for <name>", `accessibilityHelp()` exactly the folder's full path;
//     the set of helps over the rows' more buttons is the set of the folders' full paths.
//   - The confirm that "Remove" opens has the buttons "Remove folder" and "Cancel"; the one "Delete index…" opens has
//     "Delete index" and "Cancel" (kit labels), and both are in the accessibility children while the confirm is open.
//
// WHAT THE RED MEANS. The help strings are not set today, so the tick and row-button help tests fail on their first
// expectation. The sidebar, the section walk and the plain button labels are guards that pass today (list in the report).

// MARK: helpers (file-private)

private let faKinds = ["photo", "pdf", "doc", "audio", "video"]

private final class FASender: FoldersSender, @unchecked Sendable {
    func sendFolders() {}
}

private struct FAEnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }

    func fill(_ relative: String, photo: Int = 0, pdf: Int = 0) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for n in 0..<photo { try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent("photo-\(n).\(n % 2 == 0 ? "jpg" : "png")")) }
        for n in 0..<pdf { try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent("paper-\(n).pdf")) }
        return url
    }

    // folders: (path, reading, ticked)
    func seed(_ folders: [(path: String, reading: Bool, ticked: Bool)], startPressed: Bool = true) throws {
        let entries = folders.map { "{\"path\": \"\($0.path)\", \"code\": false, \"reading\": \($0.reading), \"ticked\": \($0.ticked)}" }.joined(separator: ", ")
        let json = """
        {
          "version": 3,
          "startPressed": \(startPressed),
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
private func faRun(_ body: (FAEnv) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-folderrowax-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = FAEnv(home: base.resolvingSymlinksInPath())
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
private func faEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// What the kit prints for a control: the title when it is not empty, else the label.
@MainActor
private func faKitLabel(_ view: NSView) -> String {
    let title = view.accessibilityTitle() ?? ""
    return title.isEmpty ? (view.accessibilityLabel() ?? "") : title
}

@MainActor
private func faButtons(in window: NSWindow) -> [NSButton] {
    guard let root = window.contentView else { return [] }
    return prViews(root).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
}

@MainActor
private func faButton(_ label: String, in window: NSWindow) -> NSButton? {
    faButtons(in: window).first { faKitLabel($0) == label }
}

@MainActor
@discardableResult
private func faPress(_ button: NSButton?) async -> Bool {
    guard let button, button.isEnabled else { return false }
    button.performClick(nil)
    await Task.yield()
    return true
}

// What the AX server would list for the window: the views that are accessibility elements and are not hidden (a hidden
// view, or one under a hidden view, is left out). The tree of `accessibilityChildren()` is not used: for a window that is
// never shown AppKit answers it with an empty list (measured), and `isAccessibilityElement()` is false for a plain NSButton
// there (measured), so the view tree is walked: every NSControl and every view that says it is an element, not hidden.
@MainActor
private func faAXLabels(_ window: NSWindow) -> [String] {
    guard let root = window.contentView else { return [] }
    return prViews(root)
        .filter { !$0.isHiddenOrHasHiddenAncestor && ($0 is NSControl || $0.isAccessibilityElement()) }
        .map { faKitLabel($0) }
        .filter { !$0.isEmpty }
}

// MARK: Setup

private func faBigFile(_ name: String) -> ModelFile {
    ModelFile(name: name, size: 80_000_000, sha256: String(repeating: "0", count: 64))
}

@MainActor
private func faStatus() -> StatusCache {
    let sources = StatusSources(
        settings: { Settings() },
        counts: { IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 0) },
        meta: { _ in nil },
        modelState: { .downloading })
    return StatusCache(sources: sources, queue: DispatchQueue(label: "sesame.folderrowax.test.status", qos: .utility))
}

@MainActor
private func faSetupWindow(_ env: FAEnv) async throws -> (SetupWindow, SetupFolders) {
    _ = try env.fill("Desktop", photo: 5)
    _ = try env.fill("Documents", pdf: 2)
    let folders = SetupFolders(home: env.home, picker: { [] }, speeds: { ["photo": 3.0] }, kindsOn: { Dictionary(uniqueKeysWithValues: faKinds.map { ($0, true) }) },
                               modelWhole: { false })
    #expect(await faEventually { folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }, "the Setup rows never became ready")
    let client = HelperClient(helper: env.home.appendingPathComponent("no-such-helper"), textModel: env.home, mmModel: env.home)
    let window = SetupWindow(files: [faBigFile("fa-a.gguf")], folders: folders, helper: client, status: faStatus())
    window.isReleasedWhenClosed = false
    window.refresh()
    while window.flow.step != .folders {
        guard await faPress(faButton("Next", in: window)) else { break }
    }
    window.refresh()
    return (window, folders)
}

// MARK: Settings

@MainActor
private func faSettingsWindow(_ env: FAEnv) async throws -> (SettingsContainerWindow, SettingsModel, [String: URL]) {
    let trips = try env.fill("Trips", photo: 40)
    let notes = try env.fill("Notes", pdf: 7)
    let extra = try env.fill("Extra", photo: 2)
    try env.seed([(trips.path, true, true), (notes.path, true, true), (extra.path, false, true)])
    let model = SettingsModel(sender: FASender(), modelWhole: { true })
    #expect(await faEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }, "the Settings rows never became ready")
    let window = SettingsContainerWindow(model: model)
    window.isReleasedWhenClosed = false
    window.refresh()
    return (window, model, ["Trips": trips, "Notes": notes, "Extra": extra])
}

extension ModelDownloadTests {
    @Suite("FolderRowAccessibilityTests", .serialized)
    struct FolderRowAccessibilityTests {

        // MARK: Setup

        @MainActor
        @Test func theSetupFolderRowsKeepTheirLabelAndExposeTheFullPathAsHelp() async throws {
            try await faRun { env in
                let (window, _) = try await faSetupWindow(env)
                let desktop = env.home.appendingPathComponent("Desktop").path
                let documents = env.home.appendingPathComponent("Documents").path
                let ticks = faButtons(in: window).filter { ($0.accessibilityLabel() ?? "").hasPrefix("Desktop, ") || ($0.accessibilityLabel() ?? "").hasPrefix("Documents, ") }
                let desktopTick = try #require(ticks.first { ($0.accessibilityLabel() ?? "").hasPrefix("Desktop, ") }, "no Desktop row tick; buttons: \(faButtons(in: window).map { faKitLabel($0) })")
                let documentsTick = try #require(ticks.first { ($0.accessibilityLabel() ?? "").hasPrefix("Documents, ") }, "no Documents row tick")

                // the label keeps "<name>, <counts>": five photos in Desktop
                #expect(desktopTick.accessibilityLabel()?.hasPrefix("Desktop, 5 photos") == true, "Desktop label \"\(desktopTick.accessibilityLabel() ?? "nil")\"")
                // the full path is the help, exactly
                #expect(desktopTick.accessibilityHelp() == desktop, "Desktop help \"\(desktopTick.accessibilityHelp() ?? "nil")\", wanted \"\(desktop)\"")
                #expect(documentsTick.accessibilityHelp() == documents, "Documents help \"\(documentsTick.accessibilityHelp() ?? "nil")\", wanted \"\(documents)\"")
            }
        }

        @MainActor
        @Test func theSetupButtonsReadAsTheirTitlesToTheKitPerStateOfTheFoldersFooter() async throws {
            try await faRun { env in
                let (window, _) = try await faSetupWindow(env)
                #expect(window.flow.step == .folders, "setup: the window is on \(window.flow.step.title)")
                for label in ["Back", "Next", "Add folder\u{2026}"] {
                    #expect(faButton(label, in: window) != nil, "model not whole: no control read as \"\(label)\" on the folder step: \(faButtons(in: window).map { faKitLabel($0) })")
                }
                for label in ["Start indexing", "Not now"] {
                    #expect(faButton(label, in: window) == nil, "model not whole: a control reads as \"\(label)\" on the folder step: \(faButtons(in: window).map { faKitLabel($0) })")
                    #expect(!faAXLabels(window).contains(label), "model not whole: \"\(label)\" is in the accessibility children: \(faAXLabels(window))")
                }

                while window.flow.step != .shortcut { guard await faPress(faButton("Next", in: window)) else { break } }
                window.refresh()
                #expect(faButton("Finish", in: window) != nil, "no \"Finish\" on the Shortcut step: \(faButtons(in: window).map { faKitLabel($0) })")
                #expect(faAXLabels(window).contains("Finish"))
            }
            try await slWith(.whole, glass: false) { rig in
                await slWalk(rig, to: .folders)
                let window = rig.window
                _ = slLayout(rig)
                for label in ["Back", "Add folder\u{2026}", "Start indexing", "Not now"] {
                    #expect(faButton(label, in: window) != nil, "whole model, not started: no control read as \"\(label)\" on the folder step: \(faButtons(in: window).map { faKitLabel($0) })")
                    #expect(faAXLabels(window).contains(label), "whole model, not started: \"\(label)\" is not in the accessibility children: \(faAXLabels(window))")
                }
                #expect(faButton("Next", in: window) == nil, "whole model, not started: a control reads as \"Next\" beside \"Start indexing\": \(faButtons(in: window).map { faKitLabel($0) })")
                #expect(!faAXLabels(window).contains("Next"), "whole model, not started: \"Next\" is in the accessibility children: \(faAXLabels(window))")
            }
            let started: (SLEnv) throws -> Settings = { _ in
                var held = Settings()
                held.startPressed = true
                return held
            }
            try await slWith(.whole, glass: false, settings: started) { rig in
                await slWalk(rig, to: .folders)
                let window = rig.window
                _ = slLayout(rig)
                for label in ["Back", "Next", "Add folder\u{2026}"] {
                    #expect(faButton(label, in: window) != nil, "whole model, started: no control read as \"\(label)\" on the folder step: \(faButtons(in: window).map { faKitLabel($0) })")
                }
                for label in ["Start indexing", "Not now"] {
                    #expect(faButton(label, in: window) == nil, "whole model, started: a control reads as \"\(label)\" on the folder step: \(faButtons(in: window).map { faKitLabel($0) })")
                }
            }
        }

        // MARK: Settings: folder rows

        @MainActor
        @Test func theSettingsFolderRowsKeepTheirLabelAndExposeTheFullPathAsHelp() async throws {
            try await faRun { env in
                let (window, _, urls) = try await faSettingsWindow(env)
                #expect(window.settingsScreen.section == .folders)
                for name in ["Trips", "Notes", "Extra"] {
                    let path = try #require(urls[name]).path
                    let tick = faButtons(in: window).first { ($0.accessibilityLabel() ?? "").hasPrefix(name + ", ") }
                    #expect(tick != nil, "no row tick for \(name); labels: \(faButtons(in: window).map { $0.accessibilityLabel() ?? "" })")
                    #expect(tick?.accessibilityHelp() == path, "\(name) tick help \"\(tick?.accessibilityHelp() ?? "nil")\", wanted \"\(path)\"")
                }
                // the counts stay in the label: forty photos in Trips
                let trips = faButtons(in: window).first { ($0.accessibilityLabel() ?? "").hasPrefix("Trips, ") }
                #expect(trips?.accessibilityLabel()?.hasPrefix("Trips, 40 photos") == true, "Trips label \"\(trips?.accessibilityLabel() ?? "nil")\"")
            }
        }

        @MainActor
        @Test func eachRowsMoreButtonReadsAsMoreActionsForItsFolderWithTheFoldersFullPathAsHelpAndItsMenuHoldsReIndexAndRemove() async throws {
            try await faRun { env in
                let (window, _, urls) = try await faSettingsWindow(env)
                let paths = try ["Trips", "Notes", "Extra"].map { try #require(urls[$0]).path }
                let root = try #require(window.contentView)
                let buttons = faButtons(in: window).filter { faKitLabel($0).hasPrefix("More actions for ") }
                #expect(buttons.count == 3, "\(buttons.count) buttons read as \"More actions for \u{2026}\", one per folder expected")
                let labels = buttons.map { faKitLabel($0) }
                #expect(Set(labels) == ["More actions for Trips", "More actions for Notes", "More actions for Extra"] && labels.count == 3,
                        "the more buttons read as \(labels)")
                let helps = buttons.map { $0.accessibilityHelp() ?? "" }
                #expect(Set(helps) == Set(paths) && helps.count == 3,
                        "the more buttons carry the helps \(helps): VoiceOver and the kit cannot tell the rows apart")
                for name in ["Trips", "Notes", "Extra"] {
                    let button = smrMoreButton(root, folder: name)
                    #expect(button != nil, "no more button for \(name)")
                    for title in ["Re-index", "Remove"] {
                        #expect(smrItem(title, of: button) != nil, "\(name): no \"\(title)\" menu item under the more button")
                    }
                }
                for label in ["Re-index", "Remove"] {
                    #expect(faButtons(in: window).filter { faKitLabel($0) == label }.isEmpty, "a button still reads as \"\(label)\"")
                }
            }
        }

        // MARK: Settings: the sidebar and the section walk (R2-03, R2-06)

        // GUARD: passes today. The four sidebar buttons are reachable and a press selects the section.
        @MainActor
        @Test func theFourSidebarButtonsAreReachableByTheirNamesAndAPressSelectsTheSection() async throws {
            try await faRun { env in
                let (window, _, _) = try await faSettingsWindow(env)
                let table: [(String, SettingsScreen.Section)] = [
                    ("Folders", .folders), ("File types", .fileTypes), ("Search", .search), ("Indexing", .indexing),
                ]
                for (label, section) in table {
                    let button = faButton(label, in: window)
                    #expect(button != nil, "no sidebar button read as \"\(label)\"; buttons: \(faButtons(in: window).map { faKitLabel($0) })")
                    #expect(button?.isEnabled == true, "the sidebar button \"\(label)\" is disabled")
                    #expect(await faPress(button), "could not press \"\(label)\"")
                    #expect(await faEventually { window.settingsScreen.section == section }, "pressing \"\(label)\" left the window on \(window.settingsScreen.section.title)")
                    // the sidebar stays reachable from every section
                    for other in table { #expect(faButton(other.0, in: window) != nil, "after \(label), no sidebar button \"\(other.0)\"") }
                }
            }
        }

        // GUARD: passes today. Selecting a section puts its controls in the accessibility children and takes the others out,
        // so a kit can press "Indexing" and then "Start indexing", "Delete index…" and "Launch at login".
        @MainActor
        @Test func selectingASectionPutsItsControlsInTheAccessibilityChildrenAndTakesTheOthersOut() async throws {
            try await faRun { env in
                let (window, _, _) = try await faSettingsWindow(env)
                let startTitle = "Start indexing", deleteTitle = "Delete index\u{2026}", loginTitle = "Launch at login"

                var labels = faAXLabels(window)
                let root = try #require(window.contentView)
                #expect(["Trips", "Notes", "Extra"].allSatisfy { labels.contains("More actions for " + $0) }, "Folders: the more buttons are not in the accessibility children: \(labels)")
                #expect(["Trips", "Notes", "Extra"].allSatisfy { name in
                    ["Re-index", "Remove"].allSatisfy { smrItem($0, of: smrMoreButton(root, folder: name)) != nil }
                }, "Folders: a more button's menu lacks Re-index or Remove")
                #expect(labels.contains("Add folder\u{2026}"), "Folders: no \"Add folder\u{2026}\" in \(labels)")
                for hidden in [startTitle, deleteTitle, loginTitle] {
                    #expect(!labels.contains(hidden), "Folders: \"\(hidden)\" is in the accessibility children although Indexing is not selected")
                }

                #expect(await faPress(faButton("Indexing", in: window)))
                labels = faAXLabels(window)
                for shown in [startTitle, deleteTitle, loginTitle] {
                    #expect(labels.contains(shown), "Indexing: \"\(shown)\" is not in the accessibility children: \(labels)")
                }
                #expect(!labels.contains("Re-index") && !labels.contains("Remove"), "Indexing: the folder rows' buttons are still in the accessibility children")
                #expect(!labels.contains { $0.hasPrefix("More actions for ") } && smrMoreButtons(root).isEmpty, "Indexing: a folder row's more button is still in the accessibility children: \(labels)")

                #expect(await faPress(faButton("File types", in: window)))
                labels = faAXLabels(window)
                #expect(labels.contains("PDFs"), "File types: no \"PDFs\" in \(labels)")
                #expect(!labels.contains("Search my code"), "File types: \"Search my code\" is in \(labels)")
                #expect(!["Trips", "Notes", "Extra"].contains { labels.contains($0) }, "File types: a folder's code tick is in \(labels)")
                #expect(!labels.contains(startTitle), "File types: \"\(startTitle)\" is in the accessibility children")

                #expect(await faPress(faButton("Search", in: window)))
                labels = faAXLabels(window)
                #expect(labels.contains("Back to default") && labels.contains("Record new shortcut"), "Search: the shortcut buttons are not in \(labels)")
            }
        }

        // MARK: Settings: the two confirms

        @MainActor
        @Test func theRemoveConfirmHasRemoveFolderAndCancelInTheAccessibilityChildren() async throws {
            try await faRun { env in
                let (window, _, _) = try await faSettingsWindow(env)
                let root = try #require(window.contentView)
                #expect(await smrChoose("Remove", folder: "Extra", in: root), "could not choose Remove under the more button of Extra")
                #expect(await faEventually { window.settingsScreen.confirm != nil }, "Remove opened no confirm")
                let confirm = try #require(window.settingsScreen.confirm)
                #expect(confirm.confirmTitle == "Remove folder", "the confirm button is \"\(confirm.confirmTitle)\"")
                #expect(confirm.cancelTitle == "Cancel")
                let labels = faAXLabels(window)
                #expect(labels.contains("Remove folder"), "no \"Remove folder\" in the accessibility children: \(labels)")
                #expect(labels.contains("Cancel"), "no \"Cancel\" in the accessibility children: \(labels)")
                #expect(faButton("Remove folder", in: window) != nil)
            }
        }

        @MainActor
        @Test func theDeleteIndexConfirmHasDeleteIndexAndCancelInTheAccessibilityChildren() async throws {
            try await faRun { env in
                let (window, _, _) = try await faSettingsWindow(env)
                // an index exists, so Delete index has something to delete
                let store = try IndexStore()
                defer { store.close() }
                _ = try store.addFile(path: "/photos/done.jpg", kind: "photo", size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: 1, device: 1, status: "done")

                #expect(await faPress(faButton("Indexing", in: window)))
                window.refresh()
                #expect(await faPress(faButton("Delete index\u{2026}", in: window)), "could not press Delete index\u{2026}")
                #expect(await faEventually { window.settingsScreen.confirm != nil }, "Delete index\u{2026} opened no confirm")
                let confirm = try #require(window.settingsScreen.confirm)
                #expect(confirm.confirmTitle == "Delete index", "the confirm button is \"\(confirm.confirmTitle)\"")
                #expect(confirm.cancelTitle == "Cancel")
                let labels = faAXLabels(window)
                #expect(labels.contains("Delete index"), "no \"Delete index\" in the accessibility children: \(labels)")
                #expect(labels.contains("Cancel"), "no \"Cancel\" in the accessibility children: \(labels)")
                // nothing was deleted: only the confirm is open
                #expect(FileManager.default.fileExists(atPath: env.folder.appendingPathComponent("index.sqlite").path), "the index was deleted by opening the confirm")
            }
        }
    }
}
