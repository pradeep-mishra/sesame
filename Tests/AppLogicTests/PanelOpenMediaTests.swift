import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-5-t5, tester step. Written from the entry plan-5-t5 of plan-5-tasks.md (Tests, `PanelOpenMediaTests`), Decisions D6 and D12, the t4 reports
// (`PreviewReply.seconds`, the reply's `locator`) and the sealed rigs PanelRig.swift and PanelPassageRequestTests.swift only; no product source is read.
// The real `Panel` is made and never shown (as PanelRig does). No app is launched: the open goes through the `MediaScripting` fake of
// OpenerMediaTests.swift (`OMFakeScripting`).
//
// THE HELPER is a shell script (as PanelPassageRequestTests does) that answers `embed` and `preview` lines and writes every `preview` line to
// `previews.log`. Its `preview` answer is an audio or video reply with a spot (`"seconds"`) and a `locator`; `reply-mode.txt` says `answer`, `silent`
// (never answers) or `gone` (answers `status` gone, as the real helper does for a file that is not there) and `reply-delay.txt` how many seconds it
// waits before it answers. Enter is pressed only after the ranked list has arrived (the `ranked` probe event), because the ranked list replaces the
// rows and re-selects the first one [inferred; the Enter itself could not be reached in the rig, see shape 1]. The index holds one `done` media file per row with a name passage
// and one passage whose `source` is `audio` (window 25 to 55) or `frame` (second 42); the passage carries a body word only so that the panel's keyword
// list lands on that passage (the passage id a hit carries is the one the stored spot is read from); no spoken words are indexed by the product.
//
// SHAPES THIS FILE PINS THAT THE ENTRY DID NOT FIX:
//   1. `Panel.pressEnter()` is callable from a test (today it is `private`, and a key-down Enter sent to `Panel.sendEvent` of a panel that was never
//      shown does nothing, measured on a scratch copy: no state changed, `isShown` stays false; `pressEscape()` is internal for the same reason). It
//      does what the Enter key does, on a panel that is not shown; the open need not have happened when it returns (the wait for the reply is the
//      panel's own, probably a timer [inferred from the panel's stored properties]), so these tests poll. Showing the panel to reach Enter is not an option here (no
//      real window).
//   1b. `Panel` has a settable `var scripting: any MediaScripting` (a live value by default). Enter opens an audio or video file through it, with the
//      chosen app read from `openWith.media` of `settings.json` (""/missing means QuickTime Player), the reply's `seconds` when the reply came within the
//      wait, else the stored spot of the selected hit's passage (`IndexReader.passageSpot`).
//   2. Enter on a file that is not on disk shows "That file is no longer there", drops the row, selects the next one, and runs nothing and opens nothing.
//      The pane shows a file's full path as one text (PaneStaleTests reads it that way).
//   3. The pane's "Opens in <app>" is one text, "Opens in QuickTime Player" for an audio or video hit when `openWith.media` is "" or "QuickTime Player",
//      else "Opens in " plus the default app of the file's type, named the way Finder names it (the name of the app without ".app"), read here from
//      `NSWorkspace.urlForApplication(toOpen:)`. When this machine has no default app for the type, the other-app cases only check the QuickTime text is gone.
// The wait for the reply is the entry's "at most 1 s": the tests allow 2.5 s from the Enter key to the script, for a loaded machine [guess].

struct POMKind: Sendable, CustomStringConvertible {
    let kind: String
    let ext: String
    let source: String
    let modality: String
    let start: Double
    let end: Double
    let replySeconds: Int
    let locator: String
    var storedSecond: Int { Int(start) }
    var description: String { kind }
}

let pomAudio = POMKind(kind: "audio", ext: "m4a", source: "audio", modality: "audio", start: 25, end: 55, replySeconds: 130, locator: "Opens at 02:10")
let pomVideo = POMKind(kind: "video", ext: "mp4", source: "frame", modality: "image", start: 42, end: 42, replySeconds: 66, locator: "Opens at 01:06")

private let pomHelper = #"""
#!/bin/sh
dir=$(dirname "$0")
mode=$(cat "$dir/reply-mode.txt")
delay=$(cat "$dir/reply-delay.txt")
kind=$(cat "$dir/reply-kind.txt")
seconds=$(cat "$dir/reply-seconds.txt")
locator=$(cat "$dir/reply-locator.txt")
while IFS= read -r line; do
  case "$line" in
    *'"cmd":"embed"'*)
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      printf '{"event":"vector","id":%s,"ms":1,"vec":%s}\n' "$id" "$(cat "$dir/query-vector.json")"
      ;;
    *'"cmd":"preview"'*)
      printf '%s\n' "$line" >> "$dir/previews.log"
      if [ "$mode" = "silent" ]; then continue; fi
      ticket=$(printf '%s' "$line" | sed -n 's/.*"ticket":\([0-9]*\).*/\1/p')
      file=$(printf '%s' "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')
      if [ "$mode" = "gone" ]; then
        printf '{"event":"preview","ticket":%s,"status":"gone","png":null,"name":"%s","kind":"%s"}\n' "$ticket" "$(basename "$file")" "$kind"
        continue
      fi
      sleep "$delay"
      printf '{"event":"preview","ticket":%s,"status":"ok","png":null,"name":"%s","kind":"%s","size":1234,"mtime":1700000000,"locator":"%s","seconds":%s}\n' "$ticket" "$(basename "$file")" "$kind" "$locator" "$seconds"
      ;;
  esac
done
"""#

private func pomSettings(folder: String, chosen: String) -> String {
    """
    {
      "version": 3,
      "startPressed": true,
      "indexDeleted": false,
      "folders": [
        {"path": "\(folder)", "code": false, "reading": true}
      ],
      "codeSearchOn": false,
      "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": false},
      "hotkey": "cmd+opt+k",
      "openWith": {"pdf": "Preview", "media": "\(chosen)", "code": "VS Code"},
      "speeds": {"photo": 0.5},
      "loginDefaultApplied": true
    }
    """
}

private struct POMFile {
    let name: String
    let onDisk: Bool
}

final class POMEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    func has(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.contains(name) }
}

private struct POMRig {
    let home: URL
    let folder: URL
    let events: POMEvents
    func path(_ file: POMFile) -> String { folder.appendingPathComponent(file.name).path }
}

private func pomRequests(_ home: URL) -> [String] {
    guard let text = try? String(contentsOf: home.appendingPathComponent("previews.log"), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

private func pomLastRequestedFile(_ home: URL) -> String? {
    guard let line = pomRequests(home).last,
          let fields = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
    return fields["file"] as? String
}

private func pomWrite(_ text: String, _ url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }

private func pomDefaultAppName(forFileAt path: String) -> String? {
    guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) else { return nil }
    return app.deletingPathExtension().lastPathComponent
}

@MainActor
private func pomWithPanel(_ spec: POMKind, files: [POMFile], chosen: String, mode: String = "answer", delay: String = "0",
                          _ body: @MainActor (Panel, POMRig, OMFakeScripting) async throws -> Void) async throws {
    _ = NSApplication.shared
    try await spWithHome { home in
        let folder = home.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let support = home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try pomWrite(pomSettings(folder: folder.path, chosen: chosen), support.appendingPathComponent("settings.json"))

        let store = try IndexStore()
        defer { store.close() }
        for (number, file) in files.enumerated() {
            let path = folder.appendingPathComponent(file.name).path
            if file.onDisk { try Data("not a real clip".utf8).write(to: URL(fileURLWithPath: path)) }
            let id = try store.addFile(path: path, kind: spec.kind, size: 15, mtimeNs: 1_700_000_000_000_000_000,
                                       inode: Int64(700 + number), device: 16_777_220, status: "done")
            _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                     name: (file.name as NSString).deletingPathExtension, body: "")
            var vector = [Float](repeating: 0, count: 768)
            vector[number + 1] = 1
            _ = try store.addPassage(fileID: id, source: spec.source, start: spec.start, end: spec.end, modality: spec.modality,
                                     vector: vector, name: "", body: "the keeper repaired the lamp at the lighthouse")
        }

        let helper = home.appendingPathComponent("media-helper")
        try pomWrite(pomHelper, helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try pomWrite(mode, home.appendingPathComponent("reply-mode.txt"))
        try pomWrite(delay, home.appendingPathComponent("reply-delay.txt"))
        try pomWrite(spec.kind, home.appendingPathComponent("reply-kind.txt"))
        try pomWrite(String(spec.replySeconds), home.appendingPathComponent("reply-seconds.txt"))
        try pomWrite(spec.locator, home.appendingPathComponent("reply-locator.txt"))
        let query = "[" + (0..<768).map { $0 == 0 ? "1" : "0" }.joined(separator: ",") + "]"
        try pomWrite(query, home.appendingPathComponent("query-vector.json"))

        let panel = Panel()
        let fake = OMFakeScripting()
        panel.scripting = fake
        let events = POMEvents()
        let previous = Probe.sink
        Probe.sink = { @Sendable event, _ in events.add(event) }
        defer { Probe.sink = previous }
        panel.attach(helper: HelperClient(helper: helper, textModel: home, mmModel: home))
        _ = panel.makeFirstResponder(panel.queryBox.field)
        try await body(panel, POMRig(home: home, folder: folder, events: events), fake)
    }
}

/// Pastes the query and waits until the helper has been asked to preview the first row (the panel selects it), the ranked list has arrived (it
/// replaces the rows and re-selects the first one, so a key pressed before it is undone) and the pane shows a row's path.
@MainActor
private func pomSearch(_ panel: Panel, _ rig: POMRig, shows paths: [String]) async -> Bool {
    panel.queryBox.paste("lighthouse")
    let asked = await spEventually(timeout: 6) { !pomRequests(rig.home).isEmpty }
    let ranked = await spEventually(timeout: 6) { rig.events.has("ranked") }
    let shown = await spEventually(timeout: 6) { prShownTexts(panel.contentView!).contains { text in paths.contains(text) } }
    return asked && ranked && shown
}

@MainActor
private func pomPressEnter(_ panel: Panel) {
    panel.pressEnter()
}

private func pomQuoted(_ path: String) -> String {
    "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

extension ModelDownloadTests {
    @Suite("PanelOpenMediaTests", .serialized)
    struct PanelOpenMediaTests {

        // MARK: Enter with the reply's seconds

        @MainActor
        @Test(arguments: [(pomAudio, ""), (pomAudio, "QuickTime Player"), (pomVideo, ""), (pomVideo, "QuickTime Player")])
        func enterWithTheRepliesSecondsRunsTheScriptAtThatSecond(_ spec: POMKind, _ chosen: String) async throws {
            let file = POMFile(name: "harbor-walk.\(spec.ext)", onDisk: true)
            try await pomWithPanel(spec, files: [file], chosen: chosen) { panel, rig, fake in
                let path = rig.path(file)
                let ready = await pomSearch(panel, rig, shows: [path])
                #expect(ready, "setup: the hit never reached the pane: \(prShownTexts(panel.contentView!))")
                await spWait(0.6)

                pomPressEnter(panel)
                let ran = await spEventually(timeout: 4) { fake.count >= 1 }
                await spWait(0.5)

                #expect(ran, "Enter ran nothing")
                #expect(fake.count == 1, "the seam saw \(fake.scripts.count) scripts and \(fake.opens.count) opens: \(fake.opens)")
                #expect(fake.opens.isEmpty, "the default app was opened: \(fake.opens)")
                if let script = fake.scripts.first {
                    #expect(omSeconds(in: script) == String(spec.replySeconds),
                            "the script was written for \(String(describing: omSeconds(in: script))), wanted the reply's \(spec.replySeconds) and not the stored \(spec.storedSecond): \(script)")
                    #expect(omInOrder(script, ["open POSIX file", pomQuoted(path), "set current time", "play", "activate"]), "the script is \(script)")
                }
            }
        }

        // MARK: Enter before the reply

        @MainActor
        @Test(arguments: [pomAudio, pomVideo])
        func enterBeforeTheReplyThatComesWithinTheWaitUsesTheRepliesSeconds(_ spec: POMKind) async throws {
            let file = POMFile(name: "harbor-walk.\(spec.ext)", onDisk: true)
            try await pomWithPanel(spec, files: [file], chosen: "QuickTime Player", delay: "0.5") { panel, rig, fake in
                panel.queryBox.paste("lighthouse")
                let asked = await spEventually(timeout: 6) { !pomRequests(rig.home).isEmpty }
                #expect(asked, "setup: the helper was never asked for a preview")
                let ranked = await spEventually(timeout: 6) { rig.events.has("ranked") }
                #expect(ranked, "setup: the ranked list never arrived")

                let started = ContinuousClock.now
                pomPressEnter(panel)
                let ran = await spEventually(timeout: 4) { fake.count >= 1 }
                let elapsed = started.duration(to: .now)
                await spWait(0.3)

                #expect(ran, "Enter ran nothing")
                #expect(elapsed < .milliseconds(2_500), "Enter took \(elapsed) to run the script")
                #expect(fake.count == 1 && fake.opens.isEmpty, "the seam saw \(fake.scripts.count) scripts and \(fake.opens)")
                if let script = fake.scripts.first {
                    #expect(omSeconds(in: script) == String(spec.replySeconds),
                            "the reply came after 0.5 s, inside the 1 s wait; the script was written for \(String(describing: omSeconds(in: script))), wanted \(spec.replySeconds): \(script)")
                }
            }
        }

        @MainActor
        @Test(arguments: [pomAudio, pomVideo])
        func enterWhenNoReplyComesWaitsAtMostOneSecondAndUsesTheStoredStart(_ spec: POMKind) async throws {
            let file = POMFile(name: "harbor-walk.\(spec.ext)", onDisk: true)
            try await pomWithPanel(spec, files: [file], chosen: "QuickTime Player", mode: "silent") { panel, rig, fake in
                panel.queryBox.paste("lighthouse")
                let asked = await spEventually(timeout: 6) { !pomRequests(rig.home).isEmpty }
                #expect(asked, "setup: the helper was never asked for a preview")
                let ranked = await spEventually(timeout: 6) { rig.events.has("ranked") }
                #expect(ranked, "setup: the ranked list never arrived")

                let started = ContinuousClock.now
                pomPressEnter(panel)
                let ran = await spEventually(timeout: 5) { fake.count >= 1 }
                let elapsed = started.duration(to: .now)
                await spWait(0.5)

                #expect(ran, "Enter ran nothing while no reply came")
                #expect(elapsed < .milliseconds(2_500), "Enter waited \(elapsed) for a reply that never comes (the wait is 1 s)")
                #expect(fake.count == 1, "the seam saw \(fake.scripts.count) scripts and \(fake.opens.count) opens: \(fake.opens)")
                #expect(fake.opens.isEmpty, "Enter opened the default app instead of running the script: \(fake.opens)")
                if let script = fake.scripts.first {
                    #expect(omSeconds(in: script) == String(spec.storedSecond),
                            "the script was written for \(String(describing: omSeconds(in: script))), wanted the stored start \(spec.storedSecond), not 0: \(script)")
                }
            }
        }

        @MainActor
        @Test func aSecondEnterOnTheSameFileRunsTheScriptAgain() async throws {
            let spec = pomAudio
            let file = POMFile(name: "harbor-walk.\(spec.ext)", onDisk: true)
            try await pomWithPanel(spec, files: [file], chosen: "QuickTime Player") { panel, rig, fake in
                let ready = await pomSearch(panel, rig, shows: [rig.path(file)])
                #expect(ready, "setup: the hit never reached the pane")
                await spWait(0.6)
                pomPressEnter(panel)
                _ = await spEventually(timeout: 4) { fake.count >= 1 }
                pomPressEnter(panel)
                let twice = await spEventually(timeout: 4) { fake.count >= 2 }
                #expect(twice, "the second Enter ran nothing: \(fake.scripts.count) script(s)")
                #expect(fake.opens.isEmpty, "the default app was opened: \(fake.opens)")
            }
        }

        // MARK: another app, a script that fails

        @MainActor
        @Test(arguments: ["IINA", "VLC"])
        func anotherListedAppOpensTheDefaultAppWithNoScript(_ chosen: String) async throws {
            let spec = pomAudio
            let file = POMFile(name: "harbor-walk.\(spec.ext)", onDisk: true)
            try await pomWithPanel(spec, files: [file], chosen: chosen) { panel, rig, fake in
                let path = rig.path(file)
                let ready = await pomSearch(panel, rig, shows: [path])
                #expect(ready, "setup: the hit never reached the pane")
                await spWait(0.6)
                pomPressEnter(panel)
                _ = await spEventually(timeout: 4) { fake.count >= 1 }
                await spWait(0.5)

                #expect(fake.scripts.isEmpty, "\"\(chosen)\" chosen and a script ran: \(fake.scripts)")
                #expect(fake.opens == [URL(fileURLWithPath: path)], "the default app got \(fake.opens)")
            }
        }

        // MARK: a gone file

        @MainActor
        @Test(arguments: [pomAudio, pomVideo], ["answer", "gone"])
        func aGoneFileShowsTheNoticeDropsTheRowSelectsTheNextAndRunsNothing(_ spec: POMKind, _ helperSays: String) async throws {
            let first = POMFile(name: "harborwalk-one.\(spec.ext)", onDisk: false)
            let second = POMFile(name: "lighthouse-tour-two.\(spec.ext)", onDisk: false)
            try await pomWithPanel(spec, files: [first, second], chosen: "QuickTime Player", mode: helperSays) { panel, rig, fake in
                let paths = [rig.path(first), rig.path(second)]
                let ready = await pomSearch(panel, rig, shows: paths)
                #expect(ready, "setup: no hit reached the pane: \(prShownTexts(panel.contentView!))")
                guard let gone = pomLastRequestedFile(rig.home), paths.contains(gone), let next = paths.first(where: { $0 != gone }) else {
                    Issue.record("setup: the helper's last preview request names no one of the two files: \(pomRequests(rig.home))")
                    return
                }

                pomPressEnter(panel)
                let notice = await spEventually(timeout: 4) { prShownTexts(panel.contentView!).contains { $0.contains("That file is no longer there") } }
                #expect(notice, "the pane never said `That file is no longer there`: \(prShownTexts(panel.contentView!))")
                let moved = await spEventually(timeout: 4) { pomLastRequestedFile(rig.home) == next }
                #expect(moved, "the next row was not selected: the helper's last preview request is for \(String(describing: pomLastRequestedFile(rig.home))), wanted \(next)")
                await spWait(0.5)
                #expect(prShownTexts(panel.contentView!).contains(next), "the pane does not show the next file: \(prShownTexts(panel.contentView!))")

                let goneName = (gone as NSString).lastPathComponent
                let left = prShownTexts(panel.contentView!).filter { $0.contains(goneName) }
                #expect(left.isEmpty, "the dropped row still shows: \(left)")
                #expect(fake.count == 0, "a gone file ran \(fake.scripts.count) script(s) and opened \(fake.opens)")
            }
        }

        // MARK: "Opens in <app>"

        @MainActor
        @Test(arguments: [(pomAudio, ""), (pomAudio, "QuickTime Player"), (pomVideo, ""), (pomVideo, "QuickTime Player")])
        func opensInNamesQuickTimePlayerWhenItIsChosenOrNothingIsChosen(_ spec: POMKind, _ chosen: String) async throws {
            let file = POMFile(name: "harbor-walk.\(spec.ext)", onDisk: true)
            try await pomWithPanel(spec, files: [file], chosen: chosen) { panel, rig, _ in
                let ready = await pomSearch(panel, rig, shows: [rig.path(file)])
                #expect(ready, "setup: the hit never reached the pane")
                let said = await spEventually(timeout: 6) { prShownTexts(panel.contentView!).contains("Opens in QuickTime Player") }
                #expect(said, "the pane shows \(prShownTexts(panel.contentView!)), wanted `Opens in QuickTime Player`")
            }
        }

        @MainActor
        @Test(arguments: [(pomAudio, "IINA"), (pomAudio, "VLC"), (pomVideo, "IINA"), (pomVideo, "VLC")])
        func opensInNamesTheDefaultAppWhenAnotherListedAppIsChosen(_ spec: POMKind, _ chosen: String) async throws {
            let file = POMFile(name: "harbor-walk.\(spec.ext)", onDisk: true)
            try await pomWithPanel(spec, files: [file], chosen: chosen) { panel, rig, _ in
                let path = rig.path(file)
                let ready = await pomSearch(panel, rig, shows: [path])
                #expect(ready, "setup: the hit never reached the pane")
                let opens = await spEventually(timeout: 6) { prShownTexts(panel.contentView!).contains { $0.hasPrefix("Opens in ") } }
                #expect(opens, "the pane shows no `Opens in` text: \(prShownTexts(panel.contentView!))")
                if let name = pomDefaultAppName(forFileAt: path) {
                    #expect(prShownTexts(panel.contentView!).contains("Opens in \(name)"),
                            "the pane shows \(prShownTexts(panel.contentView!)), wanted `Opens in \(name)` (the default app of .\(spec.ext))")
                } else {
                    #expect(!prShownTexts(panel.contentView!).contains("Opens in QuickTime Player"),
                            "\"\(chosen)\" is chosen and the pane still says QuickTime Player")
                }
            }
        }
    }
}
