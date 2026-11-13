import Foundation
import Testing

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let axScriptURL = projectRoot.appendingPathComponent("scripts/kit-lib/ax.applescript")

private struct Ran {
    let status: Int32
    let output: String
}

private func axSource() -> String {
    (try? String(contentsOf: axScriptURL, encoding: .utf8)) ?? ""
}

private func handlerText(_ name: String, in source: String) -> String? {
    var out: [String] = []
    var inside = false
    for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if !inside, line.hasPrefix("on \(name)(") { inside = true }
        if inside {
            out.append(line)
            if line.hasPrefix("end \(name)") { return out.joined(separator: "\n") }
        }
    }
    return nil
}

private func osascript(_ script: String) throws -> Ran {
    let fm = FileManager.default
    let file = fm.temporaryDirectory.appendingPathComponent("kit-statusbar-" + UUID().uuidString + ".applescript")
    try Data(script.utf8).write(to: file)
    let out = fm.temporaryDirectory.appendingPathComponent("kit-statusbar-out-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    defer {
        try? fm.removeItem(at: file)
        try? fm.removeItem(at: out)
    }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = [file.path]
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let deadline = Date().addingTimeInterval(60)
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
    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    return Ran(status: status, output: text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func harness(handlers: [String], body: String) -> String? {
    let source = axSource()
    var parts: [String] = []
    for name in handlers {
        guard let text = handlerText(name, in: source) else {
            Issue.record("ax.applescript has no `\(name)` handler")
            return nil
        }
        parts.append(text)
    }
    parts.append("on run\n\(body)\nend run")
    return parts.joined(separator: "\n\n")
}

private func appleScriptList(_ items: [String]) -> String {
    "{" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
}

private func barIndex(forBarCount n: Int) throws -> String? {
    guard let script = harness(handlers: ["statusBarIndex"], body: "return (my statusBarIndex(\(n))) as text") else { return nil }
    let ran = try osascript(script)
    #expect(ran.status == 0, "osascript failed: \(ran.output)")
    return ran.output
}

private func itemIndexes(bar: Int, labels: [String], process: String = "Sesame") throws -> String? {
    let body = """
        set keep_ to my statusItemIndexes(\(bar), \(appleScriptList(labels)), "\(process)")
        set out to ""
        repeat with i in keep_
            set out to out & (i as text) & ","
        end repeat
        return out
        """
    guard let script = harness(handlers: ["statusItemIndexes"], body: body) else { return nil }
    let ran = try osascript(script)
    #expect(ran.status == 0, "osascript failed: \(ran.output)")
    return ran.output
}

@Suite("kit ax status item menu bar")
struct KitAxStatusBarTests {
    @Test("an accessory-only process has one menu bar and its status item is in bar 1; a process with a main menu bar has its status items in bar 2",
          arguments: [(0, "0"), (1, "1"), (2, "2"), (3, "2")])
    func barHoldingTheStatusItems(_ count: Int, _ expected: String) throws {
        let got = try barIndex(forBarCount: count)
        #expect(got == expected, "\(count) menu bar(s): the status item bar read as \(got ?? "nothing"), expected \(expected)")
    }

    @Test("with a main menu bar (bar 2) every item of the bar is a status item, as before")
    func barTwoKeepsEveryItem() throws {
        let got = try itemIndexes(bar: 2, labels: ["Sesame: ready", "Other"])
        #expect(got == "1,2,", "bar 2 items kept: \(got ?? "nothing")")
    }

    @Test("in bar 1 only the `Sesame: ...` item is the status item, not the Apple or app menus of a regular app")
    func barOneKeepsOnlyTheSesameItem() throws {
        let got = try itemIndexes(bar: 1, labels: ["Apple", "Sesame", "Sesame: paused"])
        #expect(got == "3,", "bar 1 items kept: \(got ?? "nothing")")
    }

    @Test("an accessory-only Sesame's single item in bar 1 is found")
    func accessoryOnlyItem() throws {
        let got = try itemIndexes(bar: 1, labels: ["Sesame: ready"])
        #expect(got == "1,", "bar 1 items kept: \(got ?? "nothing")")
    }

    @Test("a lone main menu bar with no `Sesame: ...` item has no status item")
    func mainMenuOnlyHasNone() throws {
        let got = try itemIndexes(bar: 1, labels: ["Apple", "Sesame", "File"])
        #expect(got == "", "bar 1 items kept: \(got ?? "nothing")")
    }

    @Test("statusItem and the statusitems and dumpmenubar command both read through statusItems, which chooses the bar and keeps `no status item`")
    func bothSitesUseTheHelper() {
        let source = axSource()
        guard let items = handlerText("statusItems", in: source), let item = handlerText("statusItem", in: source) else {
            Issue.record("ax.applescript has no `statusItems` and `statusItem` handlers")
            return
        }
        #expect(items.contains("statusBarIndex"), "statusItems does not choose its menu bar through statusBarIndex")
        #expect(items.contains("no status item"), "statusItems lost its `no status item` error")
        #expect(!items.contains("(count of menu bars) < 2"), "statusItems still gives up when there is only one menu bar")
        #expect(item.contains("my statusItems("), "statusItem does not read the status items through statusItems")
        guard let run = handlerText("run", in: source.replacingOccurrences(of: "on run argv", with: "on run(argv)")) else {
            Issue.record("ax.applescript has no run handler")
            return
        }
        guard let start = run.range(of: "cmd is \"statusitems\"") else {
            Issue.record("ax.applescript has no statusitems command")
            return
        }
        let branch = String(run[start.lowerBound...])
        let end = branch.range(of: "\n\telse\n")?.lowerBound ?? branch.endIndex
        let text = String(branch[..<end])
        #expect(text.contains("my statusItems("), "statusitems and dumpmenubar do not read the status items through statusItems")
        #expect(!text.contains("(count of menu bars) < 2"), "statusitems still gives up when there is only one menu bar")
    }
}
