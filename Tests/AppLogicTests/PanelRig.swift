import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t39, tester step for the real-app batch defects (tasks 36 to 39). Shared by QueryBoxTypingTests,
// QueryBoxPasteTests and PaneStaleTests. No tests here.
//
// The rig makes the app's real `Panel` (never shown: it is not ordered front, not made key, and `show()` is never
// called, so nothing appears on screen and no app is launched), points its search at a temp HOME and a temp index, and
// gives it a `HelperClient` whose helper file does not exist, so no helper process is ever started. Keys are real
// `NSEvent` key-down events handed to `Panel.sendEvent`, the same entry the window server uses, so the panel's own key
// handling and the text field's field editor both run.
//
// WHAT IT READS OF THE PRODUCT (names only): `Panel`, `Panel.queryBox`, `Panel.attach(helper:)`, `Panel.sendEvent`,
// `HelperClient(helper:textModel:mmModel:)`, `IndexStore`, `Settings`, `SettingsFile`. The expected values in the
// tests come from the spec scenarios and the design, never from this code.

struct PRPhoto {
    let name: String
    /// The words stored for the picture (its OCR text); the keyword match finds a file through them.
    let words: String
}

/// A key press as the window server delivers it. `characters` is what the key types.
@MainActor
func prKey(_ characters: String, in window: NSWindow, command: Bool = false, keyCode: UInt16 = 0) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

/// A stand-in for the helper binary: a shell script (as HelperClientTests uses) that answers each `embed` line with a
/// `vector` event holding the vector in `query-vector.json` beside it, and each `preview` line with a `preview` event for
/// that file (no picture). It is never the real SesameHelper and loads no model.
private let prAnsweringHelper = #"""
#!/bin/sh
dir=$(dirname "$0")
while IFS= read -r line; do
  case "$line" in
    *'"cmd":"embed"'*)
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      printf '{"event":"vector","id":%s,"ms":1,"vec":%s}\n' "$id" "$(cat "$dir/query-vector.json")"
      ;;
    *'"cmd":"preview"'*)
      ticket=$(printf '%s' "$line" | sed -n 's/.*"ticket":\([0-9]*\).*/\1/p')
      file=$(printf '%s' "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')
      printf '{"event":"preview","ticket":%s,"status":"ok","png":null,"name":"%s","kind":"photo","size":1234,"mtime":1700000000}\n' "$ticket" "$(basename "$file")"
      ;;
  esac
done
"""#

/// Writes the answering helper into `home` with a query vector that points along axis 0, and returns its path.
private func prWriteAnsweringHelper(in home: URL) throws -> URL {
    let helper = home.appendingPathComponent("answering-helper")
    try prAnsweringHelper.write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let vector = "[" + (0..<768).map { $0 == 0 ? "1" : "0" }.joined(separator: ",") + "]"
    try vector.write(to: home.appendingPathComponent("query-vector.json"), atomically: true, encoding: .utf8)
    return helper
}

/// A temp HOME with a `settings.json` that ticks `/photos`, an index of `photos` (all under /photos, one vector each:
/// photo k points along axis k), the real `Panel` over them with its search attached to a helper, and the search box
/// focused. The helper cannot start (`answering` false), or is the stand-in above (true): then every text is embedded
/// as axis 0, so with six or more photos the first photo stands out and the ranked list is that one file, and every
/// selection gets a preview reply, both arriving on the main queue as in the app.
@MainActor
func prWithPanel(photos: [PRPhoto] = [], answering: Bool = false,
                 _ body: @MainActor (Panel) async throws -> Void) async throws {
    _ = NSApplication.shared
    try await spWithHome { home in
        var settings = Settings()
        settings.startPressed = true
        settings.folders = [Settings.Folder(path: "/photos", code: false, reading: true)]
        try SettingsFile().write(settings)
        if !photos.isEmpty {
            let store = try IndexStore()
            defer { store.close() }
            for (position, photo) in photos.enumerated() {
                let file = try store.addFile(
                    path: "/photos/" + photo.name, kind: "photo", size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                    inode: Int64(500 + position), device: 16_777_220, status: "done")
                _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none",
                                         vector: nil, name: photo.name, body: "")
                var vector = [Float](repeating: 0, count: 768)
                vector[position] = 1
                _ = try store.addPassage(fileID: file, source: "image", start: 0, end: 0, modality: "image",
                                         vector: vector, name: "", body: photo.words)
            }
        }
        let panel = Panel()
        let helperFile = answering ? try prWriteAnsweringHelper(in: home) : home.appendingPathComponent("no-such-helper")
        let client = HelperClient(helper: helperFile, textModel: home, mmModel: home)
        panel.attach(helper: client)
        _ = panel.makeFirstResponder(panel.queryBox.field)
        try await body(panel)
    }
}

/// Types `text` one key at a time. After each key the main loop runs for `pauseMilliseconds` (0: one yield), which is
/// when a list the pipeline produced is delivered to the panel.
@MainActor
func prType(_ text: String, into panel: Panel, pauseMilliseconds: UInt64 = 0,
            afterEach: (@MainActor (Int) -> Void)? = nil) async {
    var count = 0
    for character in text {
        panel.sendEvent(prKey(String(character), in: panel))
        count += 1
        if pauseMilliseconds == 0 {
            await Task.yield()
        } else {
            try? await Task.sleep(nanoseconds: pauseMilliseconds * 1_000_000)
        }
        afterEach?(count)
    }
}

@MainActor
func prViews(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { prViews($0) }
}

/// The text of every text field a person could see: not hidden, no hidden parent, not empty.
@MainActor
func prShownTexts(_ root: NSView) -> [String] {
    prViews(root).compactMap { view in
        guard let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }
}

/// Every picture currently set on an image view under `root`.
@MainActor
func prImages(_ root: NSView) -> [NSImage] {
    prViews(root).compactMap { ($0 as? NSImageView)?.image }
}

/// Every accessibility label under `root` (a screen reader or the kit's AX dump reads these).
@MainActor
func prAccessibilityLabels(_ root: NSView) -> [String] {
    prViews(root).compactMap { $0.accessibilityLabel() }.filter { !$0.isEmpty }
}

/// The field editor's selection while the box is being edited.
@MainActor
func prSelection(of field: NSTextField) -> NSRange? {
    field.currentEditor()?.selectedRange
}

final class PRKeyEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(event: String, ticket: Int)] = []
    func add(_ event: String, _ ticket: Int) { lock.lock(); list.append((event, ticket)); lock.unlock() }
    var keys: [Int] { lock.lock(); defer { lock.unlock() }; return list.filter { $0.event == "key" }.map(\.ticket) }
}

/// Records the probe's `key` events while `body` runs, then puts the probe back.
@MainActor
func prRecordingKeys(_ body: @MainActor (PRKeyEvents) async throws -> Void) async throws {
    let events = PRKeyEvents()
    let previous = Probe.sink
    Probe.sink = { @Sendable event, ticket in events.add(event, ticket) }
    defer { Probe.sink = previous }
    try await body(events)
}
