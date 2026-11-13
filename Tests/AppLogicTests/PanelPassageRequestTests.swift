import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-4 review round 1, fix round, tester step (must-fix 3: the pane asks the helper for a preview only when the PATH changes).
// Written from the reviewer's report (the third must-fix), the brief, the rig (PanelRig.swift) and the compiler's own notes about
// what `Panel` keeps private; no product source read.
//
// STOP-ASK (the brief's own instruction for a missing seam). The rule to test is "ask again when the path, the passage id or the
// query text changes (for a photo only the path)". The requests are observable: the stand-in helper below is a shell script (as
// PanelRig's `prAnsweringHelper`, which is private to that file) that appends every `preview` request line it receives to
// `previews.log`, and answers it. The line already carries `"file"`, `"passage"` and `"query"` (measured). But the DECISION is not
// reachable from a test:
//   - `Panel.selectionChanged(_:)`, `Panel.results`, `Panel.pane` and `Panel.requested` are all `private` (the compiler said so),
//     so a test cannot hand the panel "the same path, another passage".
//   - Through the keyboard the only way to change the query is a new search, and a new search passes the list through "no
//     selection" first, which clears the panel's `requested` (measured below: the same text pasted over itself asks again).
//     So a key that includes the passage or the query cannot be told from today's rule across searches.
//   - Inside ONE search the text is fixed, and the ranked list names the same first row as the keyword list (they share the
//     tier-1 definition), so the passage cannot differ there either.
// WHAT IS MISSING, exactly: either (1) `Panel.selectionChanged(_:)` made internal (not private) together with a way to put the
// query text in the box WITHOUT starting a search or clearing the selection, or (2) the key moved out of `Panel` into a small
// pure internal type a test can call, for example `PreviewRequestKey(path:passageID:kind:query:)` with
// `func needsRequest(after previous: PreviewRequestKey?) -> Bool`. With (2) the four cases of the brief are four one-line tests.
//
// WHAT IS HERE: the cases that CAN be observed, all GREEN CONTROLS (no test in this file is red, and none can be today); they
// must stay green when the key is changed:
//   1. one search for a pdf text asks the helper once, though the keyword rows and the ranked rows both select the file;
//   2. a new search whose text changed, on the same pdf passage, asks again and the request carries the new text;
//   3. a new search that moves to another passage of the same pdf asks again, with the other passage id;
//   4. one search for a photo asks once.

private let prqScript = #"""
#!/bin/sh
dir=$(dirname "$0")
while IFS= read -r line; do
  case "$line" in
    *'"cmd":"embed"'*)
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      printf '{"event":"vector","id":%s,"ms":1,"vec":%s}\n' "$id" "$(cat "$dir/query-vector.json")"
      ;;
    *'"cmd":"preview"'*)
      printf '%s\n' "$line" >> "$dir/previews.log"
      ticket=$(printf '%s' "$line" | sed -n 's/.*"ticket":\([0-9]*\).*/\1/p')
      file=$(printf '%s' "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')
      printf '{"event":"preview","ticket":%s,"status":"ok","png":null,"name":"%s","kind":"photo","size":1234,"mtime":1700000000}\n' "$ticket" "$(basename "$file")"
      ;;
  esac
done
"""#

private struct PRQPassage {
    let source: String
    let modality: String
    let body: String
}

private struct PRQFile {
    let path: String
    let kind: String
    let passages: [PRQPassage]
}

private let prqLease = PRQFile(path: "/docs/lease.pdf", kind: "pdf", passages: [
    PRQPassage(source: "page", modality: "text", body: "tenant pays deposit monthly"),
    PRQPassage(source: "page", modality: "text", body: "landlord keeps the spare keys"),
])

private let prqReceipt = PRQFile(path: "/photos/receipt.jpg", kind: "photo", passages: [
    PRQPassage(source: "image", modality: "image", body: "kettle price list for march"),
])

/// What the stand-in helper has been asked to preview so far: one line per request.
private func prqRequests(_ home: URL) -> [String] {
    let log = home.appendingPathComponent("previews.log")
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

/// One request line as a dictionary (the helper's input is one JSON object per line).
private func prqFields(_ line: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
}

@MainActor
private func prqWithPanel(files: [PRQFile], _ body: @MainActor (Panel, URL) async throws -> Void) async throws {
    _ = NSApplication.shared
    try await spWithHome { home in
        var settings = Settings()
        settings.startPressed = true
        settings.folders = [Settings.Folder(path: "/docs", code: false, reading: true),
                            Settings.Folder(path: "/photos", code: false, reading: true)]
        try SettingsFile().write(settings)
        let store = try IndexStore()
        defer { store.close() }
        var axis = 0
        for (number, file) in files.enumerated() {
            let id = try store.addFile(path: file.path, kind: file.kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                       inode: Int64(500 + number), device: 16_777_220, status: "done")
            _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                     name: (file.path as NSString).lastPathComponent.replacingOccurrences(of: ".", with: " "), body: "")
            for passage in file.passages {
                var vector = [Float](repeating: 0, count: 768)
                vector[axis] = 1
                axis += 1
                _ = try store.addPassage(fileID: id, source: passage.source, start: 0, end: 0, modality: passage.modality,
                                         vector: vector, name: "", body: passage.body)
            }
        }
        let helper = home.appendingPathComponent("recording-helper")
        try prqScript.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let vector = "[" + (0..<768).map { $0 == 0 ? "1" : "0" }.joined(separator: ",") + "]"
        try vector.write(to: home.appendingPathComponent("query-vector.json"), atomically: true, encoding: .utf8)

        let panel = Panel()
        panel.attach(helper: HelperClient(helper: helper, textModel: home, mmModel: home))
        _ = panel.makeFirstResponder(panel.queryBox.field)
        try await body(panel, home)
    }
}

/// Pastes `text` over `range` of the box (one keystroke: one search), waits until the helper has had `atLeast` requests, then lets
/// the main loop run 0.8 s more so a second request, if one is coming, has come. Returns the requests.
@MainActor
private func prqStep(_ panel: Panel, _ home: URL, paste text: String, replacing range: NSRange? = nil, atLeast: Int) async -> [String] {
    if let range { panel.queryBox.paste(text, replacing: range) } else { panel.queryBox.paste(text) }
    _ = await spEventually(timeout: 4) { prqRequests(home).count >= atLeast }
    await spWait(0.8)
    return prqRequests(home)
}

extension ModelDownloadTests {
    @Suite("PanelPassageRequestTests", .serialized)
    struct PanelPassageRequestTests {

        // 1 (green control): the keyword rows and then the ranked rows select the same pdf passage: one request
        @MainActor
        @Test func oneSearchForAPdfTextAsksTheHelperOnce() async throws {
            try await prqWithPanel(files: [prqLease, prqReceipt]) { panel, home in
                let requests = await prqStep(panel, home, paste: "tenant", atLeast: 1)
                #expect(requests.count == 1, "one search for \"tenant\" made \(requests.count) requests: \(requests)")
                let fields = prqFields(requests.first ?? "")
                #expect(fields["file"] as? String == "/docs/lease.pdf", "the request is not for the pdf: \(requests)")
                #expect(fields["query"] as? String == "tenant", "the request does not carry the typed text: \(requests)")
                #expect(fields["passage"] is Int, "the request does not carry a passage id: \(requests)")
            }
        }

        // 2 (green control): the same pdf and passage, another text (another search)
        @MainActor
        @Test func aNewTextOnTheSamePdfPassageAsksAgainWithTheNewText() async throws {
            try await prqWithPanel(files: [prqLease, prqReceipt]) { panel, home in
                let first = await prqStep(panel, home, paste: "tenant", atLeast: 1)
                #expect(first.count == 1, "setup: one request for \"tenant\", got \(first)")
                // "tenant pays" is held by the same page-1 passage as "tenant"
                let second = await prqStep(panel, home, paste: " pays", atLeast: 2)
                #expect(panel.queryBox.text == "tenant pays")
                #expect(second.count == 2, "the text changed and the pane asked \(second.count) time(s): \(second)")
                if second.count == 2 {
                    let one = prqFields(second[0]), two = prqFields(second[1])
                    #expect(two["file"] as? String == "/docs/lease.pdf" && two["query"] as? String == "tenant pays",
                            "the second request is not the pdf with the new text: \(second[1])")
                    #expect(one["passage"] as? Int == two["passage"] as? Int, "setup: the two searches should name the same passage: \(second)")
                }
            }
        }

        // 3 (green control): the same pdf, another passage (another search)
        @MainActor
        @Test func aNewSearchOnAnotherPassageOfTheSamePdfAsksAgainWithTheOtherPassage() async throws {
            try await prqWithPanel(files: [prqLease, prqReceipt]) { panel, home in
                let first = await prqStep(panel, home, paste: "tenant", atLeast: 1)
                #expect(first.count == 1, "setup: one request for \"tenant\", got \(first)")
                // "landlord" is held by page 2 only: the first row is the same file with another passage
                let second = await prqStep(panel, home, paste: "landlord", replacing: NSRange(location: 0, length: 6), atLeast: 2)
                #expect(panel.queryBox.text == "landlord")
                #expect(second.count == 2, "the passage changed on the same pdf and the pane asked \(second.count) time(s): \(second)")
                if second.count == 2 {
                    let one = prqFields(second[0]), two = prqFields(second[1])
                    #expect(two["file"] as? String == "/docs/lease.pdf", "the second request is not for the pdf: \(second[1])")
                    #expect(one["passage"] as? Int != nil && two["passage"] as? Int != nil && one["passage"] as? Int != two["passage"] as? Int,
                            "the two requests name the same passage: \(second)")
                }
            }
        }

        // 4 (green control): one search for a photo asks once
        @MainActor
        @Test func oneSearchForAPhotoAsksTheHelperOnce() async throws {
            try await prqWithPanel(files: [prqLease, prqReceipt]) { panel, home in
                let requests = await prqStep(panel, home, paste: "kettle", atLeast: 1)
                #expect(requests.count == 1, "one search for \"kettle\" made \(requests.count) requests: \(requests)")
                #expect(prqFields(requests.first ?? "")["file"] as? String == "/photos/receipt.jpg", "the request is not for the photo: \(requests)")
            }
        }
    }
}
