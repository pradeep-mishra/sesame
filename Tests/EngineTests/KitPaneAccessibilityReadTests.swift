import Foundation
import Testing

// plan-6 fix round 1 (review item M3), tester step. The product's code passage and its "Line numbers" gutter are NSTextViews, which the
// accessibility tree reports as AXTextArea (measured in a unit probe of `Pane`: the gutter has the label "Line numbers", the passage view the
// label "Passage", both role AXTextArea, the gutter's value is "12\n13\n14"). `pn_pane` skipped every AXTextArea, so S5.5 read no number and no
// mark, and S3.3 (a document passage is the same text view) read no passage. What these pin, on hand-written dumps with the real roles:
//   1. ax.applescript prints a multi-line AXValue on ONE dump line, each line break written as the unit separator (ASCII 31), so no
//      continuation line can be dropped by the dump readers (the dump readers keep only lines that start with an AX role).
//   2. `pn_pane` prints, for an AXTextArea that is not the search box, its label and then each line of its value, one pane line each, blank
//      lines kept and no line trimmed, so a gutter is the lines after "Line numbers" and the passage is the lines after its label.
//   3. A value that holds `" ` (a quote and a space, as in `let s = "a" + b`) is read whole: the value is the last quoted attribute of the line.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let libDir = projectRoot.appendingPathComponent("scripts/kit-lib")
private let sep = "\u{1F}"

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ script: String, limit: TimeInterval = 90) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitpaneax-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["KIT_NO_EVIDENCE"] = "1"
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    try? handle.synchronize()
    return Ran(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitpaneax-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sesame-kit-t/run"), withIntermediateDirectories: true)
    return dir
}

private func put(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private let prelude = """
. '\(libDir.path)/common.sh' && . '\(libDir.path)/panel.sh' && . '\(libDir.path)/recipes.sh' && . '\(libDir.path)/checks-s1.sh'
"""

/// A panel dump as `kit-ax.sh dump panel` prints it for a code result. The gutter and the passage are AXTextAreas inside AXScrollAreas, each
/// value on one line with the unit separator for a line break.
private func codeDump(gutter: [String], label: String, passage: [String]) -> String {
    """
    windows 1
    window 960 x 560 at 512,153 title Sesame
    AXWindow/AXDialog label="Sesame"
      AXImage label="Search"
      AXTextField label="Search your files" value="code: retry a failed call with backoff" [focused]
      AXScrollArea
        AXTable label="Results"
          AXRow/AXTableRow [selected]
            AXCell [focused] [selected]
              AXStaticText label="retry.swift"
              AXStaticText label="/k/home/Developer/api-client/retry.swift"
          AXColumn
      AXGroup label="Preview"
        AXImage label="Preview of retry.swift"
        AXStaticText label="retry.swift"
        AXStaticText label="/k/home/Developer/api-client/retry.swift"
        AXStaticText label="code · 412 bytes · Jan 15, 2026"
        AXScrollArea
          AXTextArea label="Line numbers" value="\(gutter.joined(separator: sep))"
          AXScrollBar
        AXScrollArea
          AXTextArea label="\(label)" value="\(passage.joined(separator: sep))"
          AXScrollBar
        AXStaticText label="Opens in VS Code"

    """
}

private let retryPassage = ["// one", "// two", "// three", "func retryWithBackoff(attempts: Int) {", "}"]

/// Runs `pn_pane` on `dump` and returns its lines (empty lines kept).
private func paneLines(_ dump: String) throws -> [String] {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    try put(dump, dir.appendingPathComponent("dump.txt"))
    let ran = try run("export KIT_ROOT='\(dir.path)/sesame-kit-t'; \(prelude); PN_DUMP=\"$(cat '\(dir.path)/dump.txt')\"; pn_pane")
    var lines = ran.output.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
}

@Suite("KitPaneAccessibilityReadTests", .serialized)
struct KitPaneAccessibilityReadTests {

    // MARK: the dump

    @Test("ax.applescript flattens line breaks in a value to ASCII 31 before it prints the value, so a multi-line AXValue is one dump line")
    func dumpFlattensValues() throws {
        let text = try String(contentsOf: libDir.appendingPathComponent("ax.applescript"), encoding: .utf8)
        ok(text.range(of: "(ASCII character|character id) 31", options: .regularExpression) != nil,
           "ax.applescript never writes the unit separator (ASCII character 31): a multi-line AXValue of a text area still spans dump lines, and every line after the first is lost to the dump readers")
        guard let start = text.range(of: "on dumpTree(el, depth)"), let end = text.range(of: "end dumpTree") else {
            ok(false, "ax.applescript has no dumpTree handler")
            return
        }
        let body = String(text[start.lowerBound..<end.upperBound])
        ok(!body.contains("set v to my attr(el, \"AXValue\")"), "dumpTree still prints the raw AXValue (line breaks included)")
    }

    // MARK: pn_pane

    @Test("pn_pane prints an AXTextArea of the pane as its label and then one line for each line of its value: the gutter then the passage")
    func paneHoldsTheCodeTextAreas() throws {
        let lines = try paneLines(codeDump(gutter: ["1", "2", "3", "4", "5"], label: "Match line 4", passage: retryPassage))
        let expected = ["Search", "Preview", "Preview of retry.swift", "retry.swift", "/k/home/Developer/api-client/retry.swift", "code · 412 bytes · Jan 15, 2026",
                        "Line numbers", "1", "2", "3", "4", "5",
                        "Match line 4", "// one", "// two", "// three", "func retryWithBackoff(attempts: Int) {", "}",
                        "Opens in VS Code"]
        ok(lines == expected, "pn_pane printed \(lines), expected \(expected)")
    }

    @Test("pn_pane keeps blank lines, tabs and indentation of a passage and reads a value that holds a quote followed by a space whole")
    func paneKeepsBlankLinesIndentAndQuotes() throws {
        let passage = ["func a() {", "", "\tlet s = \"a\" + b", "    return", "}"]
        let lines = try paneLines(codeDump(gutter: ["7", "8", "9", "10", "11"], label: "Match line 9", passage: passage))
        guard let at = lines.firstIndex(of: "Match line 9") else { ok(false, "pn_pane printed no `Match line 9` line: \(lines)"); return }
        ok(Array(lines[(at + 1)...].prefix(5)) == passage, "the passage lines after the label: \(Array(lines[(at + 1)...].prefix(6))), expected \(passage)")
        guard let gutter = lines.firstIndex(of: "Line numbers") else { ok(false, "pn_pane printed no `Line numbers` line: \(lines)"); return }
        ok(Array(lines[(gutter + 1)...].prefix(5)) == ["7", "8", "9", "10", "11"], "the gutter lines: \(Array(lines[(gutter + 1)...].prefix(5)))")
    }

    @Test("pn_pane holds a document passage too (S3.3): the label `Passage` and the passage lines with the anchor and the words around it")
    func paneHoldsADocumentPassage() throws {
        let dump = """
        windows 1
        window 960 x 560 at 512,153 title Sesame
        AXWindow/AXDialog label="Sesame"
          AXTextField label="Search your files" value="cat" [focused]
          AXGroup label="Preview"
            AXStaticText label="tenancy.docx"
            AXScrollArea
              AXTextArea label="Passage" value="Clause 4. The tenant may keep one cat with written landlord consent,\(sep)and no other animal.\(sep)Clause 5. Rent is due monthly."
              AXScrollBar
            AXStaticText label="Opens in Pages"

        """
        let lines = try paneLines(dump)
        let expected = ["Preview", "tenancy.docx", "Passage", "Clause 4. The tenant may keep one cat with written landlord consent,", "and no other animal.",
                        "Clause 5. Rent is due monthly.", "Opens in Pages"]
        ok(lines == expected, "pn_pane printed \(lines), expected \(expected)")
    }
}
