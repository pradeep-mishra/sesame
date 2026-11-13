import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let prkHelperScript = #"""
#!/bin/sh
dir=$(dirname "$0")
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$dir/$1-lines.log"
  case "$line" in
    *'"cmd":"embed"'*)
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      printf '{"event":"vector","id":%s,"ms":1,"vec":%s}\n' "$id" "$(cat "$dir/query-vector.json")"
      ;;
    *'"cmd":"preview"'*)
      ticket=$(printf '%s' "$line" | sed -n 's/.*"ticket":\([0-9]*\).*/\1/p')
      file=$(printf '%s' "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')
      printf '{"event":"preview","ticket":%s,"status":"ok","png":null,"name":"%s","kind":"photo","size":18,"mtime":1700000000}\n' "$ticket" "$(basename "$file")"
      ;;
  esac
done
"""#

private final class PRKCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var count = 0
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    func has(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.contains(name) }
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var bumps: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct PRKRig {
    let home: URL
    let folder: URL

    var photoPath: String { folder.appendingPathComponent("harbor-walk.jpg").path }

    private func indexLines() -> [[String: Any]] {
        guard let text = try? String(contentsOf: home.appendingPathComponent("index-lines.log"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private func panelLines(open: Bool) -> Int {
        indexLines().filter { ($0["cmd"] as? String) == "panel" && ($0["open"] as? Bool) == open }.count
    }

    var closeLines: Int { panelLines(open: false) }
    var openLines: Int { panelLines(open: true) }
    var previewLines: Int { indexLines().filter { ($0["cmd"] as? String) == "preview" }.count }
    var hasReset: Bool { indexLines().contains { ($0["cmd"] as? String) == "reset" } }
}

private struct PRKState: CustomStringConvertible {
    let shown: Bool
    let visible: Bool
    let key: Bool
    let policy: NSApplication.ActivationPolicy
    let closes: Int
    let opens: Int
    let text: String

    var description: String {
        "shown \(shown), visible \(visible), key \(key), policy \(policy.rawValue), close lines \(closes), open lines \(opens), text \"\(text)\""
    }
}

@MainActor
private func prkState(_ panel: Panel, _ rig: PRKRig) -> PRKState {
    PRKState(shown: panel.isShown, visible: panel.isVisible, key: panel.isKeyWindow, policy: NSApp.activationPolicy(),
             closes: rig.closeLines, opens: rig.openLines, text: panel.queryBox.text)
}

private func prkWrite(_ text: String, _ url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@MainActor
private func prkRun(withPhoto: Bool = false, _ body: @MainActor (Panel, PRKRig, PRKCalls) async throws -> Void) async throws {
    _ = NSApplication.shared
    try await spWithHome { home in
        let folder = home.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rig = PRKRig(home: home, folder: folder)
        var settings = Settings()
        settings.startPressed = true
        settings.folders = [Settings.Folder(path: folder.path, code: false, reading: true)]
        try SettingsFile().write(settings)
        if withPhoto {
            try Data("not a real picture".utf8).write(to: URL(fileURLWithPath: rig.photoPath))
            let store = try IndexStore()
            defer { store.close() }
            let id = try store.addFile(path: rig.photoPath, kind: "photo", size: 18, mtimeNs: 1_700_000_000_000_000_000,
                                       inode: 700, device: 16_777_220, status: "done")
            _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                     name: "harbor-walk", body: "")
            var vector = [Float](repeating: 0, count: 768)
            vector[1] = 1
            _ = try store.addPassage(fileID: id, source: "image", start: 0, end: 0, modality: "image", vector: vector,
                                     name: "", body: "the keeper repaired the lamp at the lighthouse")
        }
        let helper = home.appendingPathComponent("logging-helper")
        try prkWrite(prkHelperScript, helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let query = "[" + (0..<768).map { $0 == 0 ? "1" : "0" }.joined(separator: ",") + "]"
        try prkWrite(query, home.appendingPathComponent("query-vector.json"))

        let calls = PRKCalls()
        let previous = Probe.sink
        Probe.sink = { @Sendable event, _ in calls.add(event) }
        defer { Probe.sink = previous }
        let client = HelperClient(helper: helper, textModel: home, mmModel: home)
        let panel = Panel()
        panel.attach(helper: client)
        client.reset()
        let started = await spEventually(timeout: 6) { rig.hasReset }
        #expect(started, "setup: the index helper stand-in never got a line")
        try await body(panel, rig, calls)
        if panel.isShown {
            panel.hide(restoringPreviousApp: false)
            await spWait(0.4)
        }
    }
}

@MainActor
private func prkShow(_ panel: Panel, _ rig: PRKRig) async {
    let before = rig.openLines
    panel.show()
    _ = await spEventually(timeout: 4) { rig.openLines > before }
}

@MainActor
private func prkSpin(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
private func prkSettle() async {
    await spWait(0.4)
}

extension ModelDownloadTests {
    @Suite("PanelResignKeyTests", .serialized)
    struct PanelResignKeyTests {

        @MainActor
        @Test func whenTheShownPanelStopsBeingKeyItClosesAndTheAppDropsBackToAccessory() async throws {
            try await prkRun { panel, rig, _ in
                await prkShow(panel, rig)
                let before = prkState(panel, rig)
                #expect(before.shown, "setup: show() did not show the panel: \(before)")
                #expect(before.visible, "setup: the shown panel is not visible: \(before)")
                #expect(before.closes == 0, "setup: a close line before anything closed: \(before)")

                panel.resignKey()
                await prkSettle()
                let after = prkState(panel, rig)

                #expect(!after.shown, "the panel lost key and is still shown: \(after)")
                #expect(!after.visible, "the panel lost key and is still on screen: \(after)")
                #expect(after.policy == .accessory, "hide() puts the app back to accessory: \(after)")
                #expect(after.closes == 1, "the index helper must be told the panel closed once: \(after)")
            }
        }

        @MainActor
        @Test func losingKeyEndsInTheAccessoryPolicyThatHideGivesWithNoSettingsOrSetupWindow() async throws {
            try await prkRun { panel, rig, _ in
                await prkShow(panel, rig)
                let before = prkState(panel, rig)
                #expect(before.policy == .regular, "setup: show() leaves the app regular: \(before)")

                panel.resignKey()
                await prkSettle()
                let after = prkState(panel, rig)

                #expect(!after.shown, "\(after)")
                #expect(after.policy == .accessory, "the key loss goes through hide(restoringPreviousApp: false): \(after)")
            }
        }

        @MainActor
        @Test func resignKeyOnAPanelThatIsNotShownDoesNothing() async throws {
            try await prkRun { panel, rig, _ in
                let before = prkState(panel, rig)
                #expect(!before.shown, "setup: a new panel is shown: \(before)")

                panel.resignKey()
                await prkSettle()
                let after = prkState(panel, rig)

                #expect(!after.shown, "\(after)")
                #expect(!after.visible, "\(after)")
                #expect(after.policy == before.policy, "resignKey on a hidden panel changed the policy: \(before) then \(after)")
                #expect(after.closes == 0, "resignKey on a hidden panel told the index helper the panel closed: \(after)")
                #expect(after.opens == 0, "resignKey on a hidden panel told the index helper the panel opened: \(after)")
            }
        }

        @MainActor
        @Test func resignKeyAfterAHideChangesNothingAndClosesNothingAgain() async throws {
            try await prkRun { panel, rig, _ in
                await prkShow(panel, rig)
                panel.hide(restoringPreviousApp: false)
                await prkSettle()
                let hidden = prkState(panel, rig)
                #expect(hidden.closes == 1, "setup: hide() told the index helper \(hidden.closes) times: \(hidden)")

                panel.resignKey()
                panel.resignKey()
                await prkSettle()
                let after = prkState(panel, rig)

                #expect(!after.shown, "\(after)")
                #expect(after.closes == 1, "resignKey after a hide closed again: \(after)")
            }
        }

        @MainActor
        @Test func showingThePanelDoesNotCloseItItself() async throws {
            try await prkRun { panel, rig, _ in
                await prkShow(panel, rig)
                let before = prkState(panel, rig)
                #expect(before.shown, "setup: show() did not show the panel: \(before)")

                prkSpin(0.2)
                panel.becomeKey()
                prkSpin(0.2)
                await prkSettle()
                let after = prkState(panel, rig)

                #expect(after.shown, "the panel closed itself after show(): \(after)")
                #expect(after.visible, "the panel left the screen after show(): \(after)")
                #expect(after.closes == 0, "show() was followed by a close line: \(after)")
                #expect(after.opens == 1, "show() sent \(after.opens) open lines: \(after)")
            }
        }

        @MainActor
        @Test func showingAgainAfterALostKeyOpensTheEmptyPanelAndItStaysOpen() async throws {
            try await prkRun { panel, rig, _ in
                await prkShow(panel, rig)
                panel.queryBox.type("a dog on the beach")
                panel.resignKey()
                await prkSettle()
                let closed = prkState(panel, rig)
                #expect(!closed.shown, "setup: the lost key did not close the panel: \(closed)")

                await prkShow(panel, rig)
                prkSpin(0.2)
                let after = prkState(panel, rig)

                #expect(after.shown, "the panel did not stay open after the second show(): \(after)")
                #expect(after.visible, "\(after)")
                #expect(after.text == "", "the reopened box holds text: \(after)")
            }
        }

        @MainActor
        @Test func escapeWithTextClearsAndKeepsThePanelOpenAndEscapeOnAnEmptyBoxClosesIt() async throws {
            try await prkRun { panel, rig, _ in
                await prkShow(panel, rig)
                panel.queryBox.type("a dog on the beach")

                panel.pressEscape()
                await prkSettle()
                let first = prkState(panel, rig)
                #expect(first.text == "", "the first Esc left text: \(first)")
                #expect(first.shown, "the first Esc closed the panel: \(first)")
                #expect(first.closes == 0, "the first Esc told the index helper the panel closed: \(first)")

                panel.pressEscape()
                await prkSettle()
                let second = prkState(panel, rig)
                #expect(!second.shown, "Esc on an empty box did not close the panel: \(second)")
                #expect(second.closes == 1, "Esc on an empty box: \(second)")
            }
        }

        @MainActor
        @Test(arguments: ["Esc on an empty box", "the shortcut", "hide with no restore"])
        func aCloseFollowedByTheKeyLossIsOneClose(_ way: String) async throws {
            try await prkRun { panel, rig, _ in
                await prkShow(panel, rig)
                switch way {
                case "Esc on an empty box": panel.pressEscape()
                case "the shortcut": panel.shortcutPressed()
                default: panel.hide(restoringPreviousApp: false)
                }
                panel.resignKey()
                await prkSettle()
                let after = prkState(panel, rig)

                #expect(!after.shown, "\(way): the panel is still shown: \(after)")
                #expect(!after.visible, "\(way): the panel is still on screen: \(after)")
                #expect(after.closes == 1, "\(way) then the key loss: \(after)")
            }
        }

        @MainActor
        @Test func enterOpensTheFileAndThePanelEndsHiddenWithExactlyOneClose() async throws {
            try await prkRun(withPhoto: true) { panel, rig, calls in
                let fake = OMFakeScripting()
                panel.scripting = fake
                await prkShow(panel, rig)
                panel.queryBox.paste("lighthouse")
                let asked = await spEventually(timeout: 6) { rig.previewLines >= 1 }
                let ranked = await spEventually(timeout: 6) { calls.has("ranked") }
                let photoPath = rig.photoPath
                let root = panel.contentView!
                let shown = await spEventually(timeout: 6) { prShownTexts(root).contains(photoPath) }
                #expect(asked && ranked && shown, "setup: the hit never reached the pane: asked \(asked), ranked \(ranked), shown \(shown)")
                await spWait(0.6)
                let before = prkState(panel, rig)
                #expect(before.shown, "setup: the panel closed before Enter: \(before)")
                #expect(before.closes == 0, "setup: a close line before Enter: \(before)")

                panel.pressEnter()
                let opened = await spEventually(timeout: 4) { fake.count >= 1 }
                panel.resignKey()
                await prkSettle()
                let after = prkState(panel, rig)
                let opens = fake.opens

                #expect(opened, "Enter opened nothing: \(after)")
                #expect(opens == [URL(fileURLWithPath: photoPath)], "the default app got \(opens)")
                #expect(!after.shown, "the panel is still shown after Enter: \(after)")
                #expect(!after.visible, "the panel is still on screen after Enter: \(after)")
                #expect(after.closes == 1, "Enter then the key loss: \(after)")
            }
        }

        @MainActor
        @Test func commandCommaWithTheSettingsWindowTakingKeyClosesThePanelOnce() async throws {
            try await prkRun { panel, rig, _ in
                let settingsCalls = PRKCalls()
                panel.onOpenSettings = {
                    settingsCalls.bump()
                    panel.resignKey()
                }
                await prkShow(panel, rig)

                panel.sendEvent(prKey(",", in: panel, command: true, keyCode: 43))
                await prkSettle()
                let after = prkState(panel, rig)
                let asked = settingsCalls.bumps

                #expect(asked == 1, "Command+comma asked for Settings \(asked) times")
                #expect(!after.shown, "the panel is still shown after Command+comma: \(after)")
                #expect(after.closes == 1, "Command+comma with the key loss: \(after)")
            }
        }
    }
}
