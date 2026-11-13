import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t35, tester step. Written from the t35 entry, the Conventions (Helper protocol table), design sections 1,
// 2 and 3 and the t28 and t29 reports only; no product source read. `HelperClient` is the one place the app talks
// to the helpers. These tests start it against a stub helper: a small shell script written into a temp folder that
// records what it is started with and every stdin line it reads, and prints scripted lines (events) on stdout.
// Everything runs against a throwaway HOME. No real model, no real helper, no network.
//
// SUITE PLACEMENT. This suite is nested inside `ModelDownloadTests` (as t27 and t28 did) so it runs one at a time
// with them. Reason: HOME is process-wide and these tests set it (the Start test reads and writes settings.json
// there), and `SESAME_MODEL_HOST` is process-wide and set by t26: a child process inherits both, and the "no
// SESAME_* setting is passed" test must not see another suite's value. Side effect: `swift test --filter
// ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin (the design names `HelperClient` and the entry fixes no signatures; if a shape is
// wrong, ask for a test change rather than guessing). `HelperCommand`, `HelperEvent`, `HelperFolder`,
// `PreviewReply`, `EmbedRole` are the t29 and t23 public types of SesameEngine.
//   1. `final class HelperClient` in the `Sesame` target. It may be `@MainActor` (every test here is). Every method
//      below is synchronous, non-throwing and returns at once: a command is queued and written by the client;
//      nothing here waits for a reply. The answer comes through the delegate.
//   2. `init(helper: URL, textModel: URL, mmModel: URL)`. `helper` is the executable (the real `SesameHelper`, or
//      the stub). A helper is started as `<helper> <mode> <flags...>` with mode `encode` or `index` as the first
//      argument. Model paths reach a helper only as flags (see 8).
//   3. `protocol HelperClientDelegate: AnyObject` with one method
//      `func helperClient(_ client: HelperClient, didReceive event: HelperEvent)`, and
//      `var delegate: HelperClientDelegate?` on the client (it may be weak: the test keeps the delegate alive). The
//      method is called for every event either helper prints, decoded with `HelperProtocol.event(from:)`, in the
//      order that helper printed them, on any thread. Two events in one read, or a line of about 10 KB (the
//      768-number vector), still arrive whole.
//   4. `func panelDidOpen()` and `func panelDidClose()`. Open sends `{"cmd":"prewarm"}` to `encode` (starting it if
//      it is not running: the panel opening is the work) and `{"cmd":"panel","open":true}` to `index`; close sends
//      `{"cmd":"panel","open":false}` to `index`. A panel line goes only to an `index` helper that is already
//      running: opening or closing the panel never starts `index` (design section 3: `index` is started for Start,
//      a folder change, a watcher event, reset, a resume and a preview, never for the panel), and closing the panel
//      never starts `encode`.
//   5. `func embed(id: Int, text: String, role: EmbedRole)` sends the `embed` line to `encode`, starting it if need be.
//   6. `func sendFolders()` is what the app connects to `SetupModel`'s Start hook (`onStart`, no arguments): it reads
//      `settings.json` through `SettingsFile` and sends ONE `folders` line to `index` (starting it if need be) holding
//      every folder of settings.json whose `reading` is true, each as `{"path":..,"code":false}`.
//      A folder with `reading` false is not sent (design section 3: a folder added or re-ticked later waits for the
//      next Start). The list is the whole list every time (it replaces the previous one). The order of the folders in
//      the line is not pinned.
//   7. `func reset()` sends `{"cmd":"reset"}` and `func preview(ticket: Int, file: String, passage: Int?, query:
//      String)` sends the `preview` line, both to `index`, starting it if need be. `passage` nil is a JSON null.
//   8. Model paths: `encode` is started with exactly `--text-model <text path>` and nothing else after the mode;
//      `index` with exactly `--text-model <text path>` and `--mm-model <mm path>` in either order (design section 2:
//      `encode` holds the text model only; the image model cannot run alone). Paths compare after symlink
//      resolution. No `SESAME_*` setting is passed on by the client: the stub's `SESAME_*` environment must be a
//      subset of the test process's own (the client may pass the test's own through, it must add none).
//   9. One process per mode serves consecutive commands. When it has exited (the test kills it), the next command
//      starts a new process of that mode; the client starts nothing by itself after an exit (the restart and its
//      attempt marker are plan 2, task list G39). Neither helper is started by creating the client, and the client
//      sends nothing the test did not ask for (no keep-alive, no polling lines).
//  10. Not pinned, on purpose: whether `sendFolders()` sends anything when settings.json holds no folder that is
//      reading; whether the client tells a newly started `index` the current panel state first (the tests count
//      panel lines from a baseline taken after start); what the client does with a stdout line that is not one JSON
//      object; what happens to a command written while a process is dying; how the helper's stderr is handled.

// MARK: JSON compared by meaning, written out by hand

private func hcParsed(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

// Booleans, numbers, nulls and strings stay apart; object keys are sorted.
private func hcCanonical(_ value: Any) -> String {
    if value is NSNull { return "null" }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool:\(number.boolValue)" }
        return "num:" + String(format: "%.17g", number.doubleValue)
    }
    if let text = value as? String { return "str:" + String(reflecting: text) }
    if let list = value as? [Any] { return "[" + list.map(hcCanonical).joined(separator: ",") + "]" }
    if let object = value as? [String: Any] {
        return "{" + object.keys.sorted().map { "\($0)=" + hcCanonical(object[$0]!) }.joined(separator: ",") + "}"
    }
    return "?\(value)"
}

private func hcSameJSON(_ line: String, _ expected: String) -> Bool {
    guard let a = try? hcParsed(line), let b = try? hcParsed(expected) else { return false }
    return hcCanonical(a) == hcCanonical(b)
}

private func hcIsInt(_ value: Any?) -> Bool {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
    return n.doubleValue == n.doubleValue.rounded()
}

private func hcIsBool(_ value: Any?) -> Bool {
    guard let n = value as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
}

// The shapes of the Conventions' Helper protocol table for the lines the app sends, and the helper each goes to.
// nil means the line is exactly one of the table's shapes and went to the right helper.
private func hcShapeProblem(_ line: String, mode: String) -> String? {
    guard let obj = (try? hcParsed(line)) as? [String: Any] else { return "not one JSON object: \(line)" }
    guard let cmd = obj["cmd"] as? String else { return "no `cmd` field: \(line)" }
    let keys = Set(obj.keys)
    switch cmd {
    case "prewarm":
        guard mode == "encode" else { return "prewarm went to \(mode)" }
        return keys == ["cmd"] ? nil : "prewarm has other fields: \(line)"
    case "embed":
        guard mode == "encode" else { return "embed went to \(mode)" }
        guard keys == ["cmd", "id", "text", "role"], hcIsInt(obj["id"]), obj["text"] is String,
              let role = obj["role"] as? String, role == "query" || role == "document"
        else { return "embed is not the table's shape: \(line)" }
        return nil
    case "panel":
        guard mode == "index" else { return "panel went to \(mode)" }
        return keys == ["cmd", "open"] && hcIsBool(obj["open"]) ? nil : "panel is not the table's shape: \(line)"
    case "folders":
        guard mode == "index" else { return "folders went to \(mode)" }
        guard keys == ["cmd", "folders"], let list = obj["folders"] as? [[String: Any]] else {
            return "folders is not the table's shape: \(line)"
        }
        for entry in list {
            guard Set(entry.keys) == ["path", "code"], let path = entry["path"] as? String, path.hasPrefix("/"),
                  hcIsBool(entry["code"])
            else { return "a folders entry is not {path (absolute), code (bool)}: \(line)" }
        }
        return nil
    case "reset":
        guard mode == "index" else { return "reset went to \(mode)" }
        return keys == ["cmd"] ? nil : "reset has other fields: \(line)"
    case "preview":
        guard mode == "index" else { return "preview went to \(mode)" }
        guard keys == ["cmd", "ticket", "file", "passage", "query"], hcIsInt(obj["ticket"]), obj["file"] is String,
              obj["query"] is String, obj["passage"] is NSNull || hcIsInt(obj["passage"])
        else { return "preview is not the table's shape (passage must be present, an int or null): \(line)" }
        return nil
    default:
        return "unknown cmd \(cmd): \(line)"
    }
}

// MARK: the stub helper and its folder

private let hcStubScript = #"""
#!/bin/sh
# Stub helper for HelperClientTests. First argument is the mode (encode or index); the rest are flags.
# Records its start, records every stdin line, and after each line prints the lines of <mode>.out it has not printed.
dir=$(dirname "$0")
mode="$1"
shift
# plan-2-t17: `index bench ...` is the one-shot run. It records itself in bench.starts (never in index.starts), reads no
# stdin, and behaves as bench.behavior says (ok when the file is absent): ok, exit1, silent, notbench, garbage, wait-go.
if [ "$mode" = "index" ] && [ "$1" = "bench" ]; then
  {
    echo "pid=$$"
    for a in "$@"; do echo "arg=$a"; done
    env | grep '^SESAME_' | sed 's/^/env=/'
    echo "--"
  } >> "$dir/bench.starts"
  behavior=$(cat "$dir/bench.behavior" 2>/dev/null)
  if [ "$behavior" = "wait-go" ]; then
    while [ ! -f "$dir/bench.go" ]; do sleep 0.05; done
    behavior=ok
  fi
  case "$behavior" in
    exit1) exit 1 ;;
    silent) exit 0 ;;
    notbench) echo '{"event":"unit","size":4}'; exit 0 ;;
    garbage) echo 'this is not json'; exit 0 ;;
    *) echo '{"event":"bench","speeds":{"photo":0.31}}'; exit 0 ;;
  esac
fi
{
  echo "pid=$$"
  echo "mode=$mode"
  for a in "$@"; do echo "arg=$a"; done
  env | grep '^SESAME_' | sed 's/^/env=/'
  echo "--"
} >> "$dir/$mode.starts"
emit() {
  f="$dir/$mode.out"
  [ -f "$f" ] || return 0
  sent=0
  [ -f "$dir/$mode.sent" ] && sent=$(( $(cat "$dir/$mode.sent") ))
  total=$(( $(wc -l < "$f") ))
  if [ "$total" -gt "$sent" ]; then
    tail -n +$((sent + 1)) "$f" | head -n $((total - sent))
    echo "$total" > "$dir/$mode.sent"
  fi
}
while IFS= read -r line; do
  printf '%s\t%s\n' "$$" "$line" >> "$dir/$mode.stdin"
  emit
  # plan-2-t31: a stub that exits by itself, with the status in <mode>.exit-code, after the first line it reads.
  if [ -f "$dir/$mode.exit-code" ]; then exit $(( $(cat "$dir/$mode.exit-code") )); fi
done
# plan-2-t31: stdin ended. Record the pid; a stub with <mode>.ignore-eof then carries on until it is killed.
printf '%s\n' "$$" >> "$dir/$mode.eof"
while [ -f "$dir/$mode.ignore-eof" ]; do sleep 0.2; done
"""#

private struct HCStart {
    var pid: Int
    var args: [String]
    var env: [String]
}

@MainActor
private final class HCEnv {
    let dir: URL
    let helper: URL
    let textModel: URL
    let mmModel: URL
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

    init(home: URL) throws {
        let fm = FileManager.default
        self.home = home
        dir = fm.temporaryDirectory.appendingPathComponent("sesame-helperclient-stub-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        helper = dir.appendingPathComponent("stub-helper")
        try hcStubScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        textModel = dir.appendingPathComponent("text-model.gguf")
        mmModel = dir.appendingPathComponent("mm-model.gguf")
        fm.createFile(atPath: textModel.path, contents: Data("t".utf8))
        fm.createFile(atPath: mmModel.path, contents: Data("m".utf8))
    }

    func makeClient() -> HelperClient {
        HelperClient(helper: helper, textModel: textModel, mmModel: mmModel)
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func starts(_ mode: String) -> [HCStart] {
        var result: [HCStart] = []
        var current = HCStart(pid: 0, args: [], env: [])
        for line in read(mode + ".starts").split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line == "--" { result.append(current); current = HCStart(pid: 0, args: [], env: []); continue }
            if line.hasPrefix("pid=") { current.pid = Int(line.dropFirst(4)) ?? 0 }
            else if line.hasPrefix("arg=") { current.args.append(String(line.dropFirst(4))) }
            else if line.hasPrefix("env=") { current.env.append(String(line.dropFirst(4))) }
        }
        return result
    }

    // (pid of the stub process that read it, the line)
    func stdin(_ mode: String) -> [(pid: Int, line: String)] {
        read(mode + ".stdin").split(separator: "\n", omittingEmptySubsequences: true).compactMap { entry in
            let parts = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
            return (pid, String(parts[1]))
        }
    }

    func lines(_ mode: String) -> [String] { stdin(mode).map(\.line) }

    func setOut(_ mode: String, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(mode + ".out"),
                                                          atomically: true, encoding: .utf8)
    }

    func killLast(_ mode: String) {
        if let last = starts(mode).last { _ = Darwin.kill(pid_t(last.pid), SIGKILL) }
    }

    func isGone(_ pid: Int) -> Bool {
        Darwin.kill(pid_t(pid), 0) != 0 && errno == ESRCH
    }

    // plan-2-t17: what `index bench` does next (see the stub), and the file that lets a `wait-go` run finish.
    func setBench(_ behavior: String) throws {
        try behavior.write(to: dir.appendingPathComponent("bench.behavior"), atomically: true, encoding: .utf8)
    }

    func releaseBench() {
        FileManager.default.createFile(atPath: dir.appendingPathComponent("bench.go").path, contents: Data())
    }

    // plan-2-t31: the pids of the stubs that saw their stdin end, and the switches that change how a stub ends.
    func eofPids(_ mode: String) -> [Int] {
        read(mode + ".eof").split(separator: "\n", omittingEmptySubsequences: true).compactMap { Int($0) }
    }

    func setExitCode(_ mode: String, _ code: Int) throws {
        try String(code).write(to: dir.appendingPathComponent(mode + ".exit-code"), atomically: true, encoding: .utf8)
    }

    func setIgnoreEOF(_ mode: String) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(mode + ".ignore-eof").path, contents: Data())
    }

    func cleanup() {
        for mode in ["encode", "index", "bench"] {
            for start in starts(mode) { _ = Darwin.kill(pid_t(start.pid), SIGKILL) }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func writeSettings(_ json: String) throws {
        try json.write(to: settings, atomically: true, encoding: .utf8)
    }

    func makeFolder(_ name: String) throws -> URL {
        let url = home.resolvingSymlinksInPath().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder and `models/`, runs the body, kills any stub, puts HOME back.
@MainActor
private func hcRun(_ body: @MainActor (HCEnv) async throws -> Void) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-helperclient-home-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    let env = try HCEnv(home: home)
    defer {
        env.cleanup()
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: home)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try fm.createDirectory(at: env.models, withIntermediateDirectories: true)
    try await body(env)
}

private final class HCRecorder: HelperClientDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HelperEvent] = []
    func helperClient(_ client: HelperClient, didReceive event: HelperEvent) {
        lock.lock(); items.append(event); lock.unlock()
    }
    var events: [HelperEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

// plan-2-t17: what `runBench`'s completion was given, kept by any thread, read by the test.
private final class HCBenchResults: @unchecked Sendable {
    private let lock = NSLock()
    private var speedsList: [[String: Double]] = []
    private var failures = 0
    func record(_ result: Result<[String: Double], Error>) {
        lock.lock(); defer { lock.unlock() }
        switch result {
        case .success(let speeds): speedsList.append(speeds)
        case .failure: failures += 1
        }
    }
    var successes: [[String: Double]] { lock.lock(); defer { lock.unlock() }; return speedsList }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }
    var total: Int { lock.lock(); defer { lock.unlock() }; return speedsList.count + failures }
}

// plan-2-t31: every (helper, exit) `HelperClient.onExit` reported, in order, kept by any thread, read by the test.
private final class HCExits: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(helper: String, exit: HelperExit)] = []
    func record(_ helper: String, _ exit: HelperExit) {
        lock.lock(); items.append((helper, exit)); lock.unlock()
    }
    var all: [(helper: String, exit: HelperExit)] { lock.lock(); defer { lock.unlock() }; return items }
    func of(_ helper: String) -> [HelperExit] { all.filter { $0.helper == helper }.map(\.exit) }
}

// plan-2-t31: how often a `shutdown` completion was called.
private final class HCDone: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private func hcEventually(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func hcWait(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// Every line either stub recorded is one of the table's shapes and went to the right helper.
@MainActor
private func hcVerifyRecording(_ env: HCEnv, sourceLocation: SourceLocation = #_sourceLocation) {
    for mode in ["encode", "index"] {
        for line in env.lines(mode) {
            if let problem = hcShapeProblem(line, mode: mode) {
                Issue.record("\(mode) stub recorded a line that does not match the Helper protocol table: \(problem)",
                             sourceLocation: sourceLocation)
            }
        }
    }
}

private func hcResolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

// The folders of a recorded `folders` line as sorted (path, code) pairs; nil if the line is not one.
private func hcFolderPairs(_ line: String) -> [(String, Bool)]? {
    guard let obj = (try? hcParsed(line)) as? [String: Any], obj["cmd"] as? String == "folders",
          let list = obj["folders"] as? [[String: Any]] else { return nil }
    let pairs = list.compactMap { entry -> (String, Bool)? in
        guard let path = entry["path"] as? String, let code = entry["code"] as? Bool else { return nil }
        return (path, code)
    }
    return pairs.count == list.count ? pairs.sorted { $0.0 < $1.0 } : nil
}

private func hcSamePairs(_ a: [(String, Bool)]?, _ b: [(String, Bool)]) -> Bool {
    guard let a, a.count == b.count else { return false }
    return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

private func hcSettingsJSON(startPressed: Bool, folders: [(path: String, code: Bool, reading: Bool)]) -> String {
    let entries = folders.map { entry in
        let path = String(data: try! JSONSerialization.data(withJSONObject: [entry.path]), encoding: .utf8)!
            .dropFirst().dropLast()
        return #"{"path":\#(path),"code":\#(entry.code),"reading":\#(entry.reading)}"#
    }.joined(separator: ",")
    return """
    {
      "version": 3,
      "startPressed": \(startPressed),
      "indexDeleted": false,
      "folders": [\(entries)],
      "codeSearchOn": true,
      "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
      "hotkey": "ctrl+opt+space",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {},
      "loginDefaultApplied": true
    }
    """
}

// 768 numbers a Float holds exactly (k / 16), as in ProtocolTests, written out as JSON by hand.
private let hcVectorNumbers: [Float] = (0..<768).map { Float(($0 * 7) % 33 - 16) / 16 }
private let hcVectorLine: String =
    #"{"event":"vector","id":7,"ms":23,"vec":["# + hcVectorNumbers.map { String(Double($0)) }.joined(separator: ",") + #"]}"#
private let hcPreviewPath = "/var/folders/ab/cdef/T/Sesame-4242/p1.png"
private let hcPreviewLine: String =
    #"{"event":"preview","ticket":12,"status":"ok","png":""# + hcPreviewPath
    + #"","name":"beach-dog.jpg","kind":"photo","size":48213,"mtime":1760000000}"#

extension ModelDownloadTests {
    @Suite("HelperClientTests", .serialized)
    struct HelperClientTests {

        // MARK: nothing starts without work

        @MainActor
        @Test func creatingTheClientAndClosingThePanelStartsNoHelperAndSendsNothing() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                await hcWait(0.4)
                #expect(env.starts("encode").isEmpty && env.starts("index").isEmpty,
                        "a helper was started by creating the client")

                // closing a panel that was never opened is not work for either helper
                client.panelDidClose()
                await hcWait(0.4)
                #expect(env.starts("encode").isEmpty, "encode was started by a panel close")
                #expect(env.starts("index").isEmpty, "index was started by a panel close (no index is running)")
                #expect(env.lines("encode").isEmpty && env.lines("index").isEmpty, "a line was sent with no work")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func theIndexCommandsNeverStartOrFeedEncode() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.reset()
                client.preview(ticket: 1, file: "/Users/me/Pictures/beach-dog.jpg", passage: nil, query: "a dog")
                try env.writeSettings(hcSettingsJSON(startPressed: true,
                                                     folders: [(path: try env.makeFolder("Pictures").path, code: false, reading: true)]))
                client.sendFolders()
                client.panelDidClose()
                let arrived = await hcEventually { env.lines("index").filter { !$0.contains("\"panel\"") }.count >= 3 }
                #expect(arrived, "the index stub got \(env.lines("index"))")
                await hcWait(0.4)
                #expect(env.starts("encode").isEmpty, "encode was started by reset, preview, Start or a panel close")
                #expect(env.lines("encode").isEmpty, "encode was sent \(env.lines("encode"))")
                hcVerifyRecording(env)
            }
        }

        // MARK: prewarm on panel open

        @MainActor
        @Test func openingThePanelSendsPrewarmToEncodeOnEveryOpenAndStartsNoIndex() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.panelDidOpen()
                let first = await hcEventually { env.lines("encode").count >= 1 }
                #expect(first, "no prewarm reached encode")
                #expect(env.lines("encode").first.map { hcSameJSON($0, #"{"cmd":"prewarm"}"#) } == true,
                        "first encode line: \(env.lines("encode"))")

                client.panelDidClose()
                client.panelDidOpen()
                let second = await hcEventually { env.lines("encode").count >= 2 }
                #expect(second, "the second open sent no prewarm: \(env.lines("encode"))")
                await hcWait(0.4)
                #expect(env.lines("encode").count == 2 && env.lines("encode").allSatisfy { hcSameJSON($0, #"{"cmd":"prewarm"}"#) },
                        "encode lines: \(env.lines("encode"))")
                #expect(env.starts("encode").count == 1, "encode was started \(env.starts("encode").count) times")
                #expect(env.starts("index").isEmpty, "the panel started index")
                #expect(env.lines("index").isEmpty, "index was sent \(env.lines("index"))")
                hcVerifyRecording(env)
            }
        }

        // MARK: embed goes to encode

        @MainActor
        @Test func embedGoesToEncodeAsTheTablesLineInOrderAndNeverToIndex() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.embed(id: 1, text: "a dog on the beach", role: .query)
                client.embed(id: 2, text: "title: none", role: .document)
                client.embed(id: 3, text: "line one\nline \"two\" café 犬", role: .query)
                let arrived = await hcEventually { env.lines("encode").count >= 3 }
                #expect(arrived, "encode got \(env.lines("encode"))")
                let expected = [
                    #"{"cmd":"embed","id":1,"text":"a dog on the beach","role":"query"}"#,
                    #"{"cmd":"embed","id":2,"text":"title: none","role":"document"}"#,
                    #"{"cmd":"embed","id":3,"text":"line one\nline \"two\" café 犬","role":"query"}"#,
                ]
                let got = env.lines("encode")
                #expect(got.count == 3, "encode got \(got.count) lines")
                for (line, want) in zip(got, expected) {
                    #expect(hcSameJSON(line, want), "recorded \(line), the table says \(want)")
                }
                #expect(env.starts("encode").count == 1, "one encode process should serve all three")
                #expect(env.starts("index").isEmpty, "embed started index")
                hcVerifyRecording(env)
            }
        }

        // MARK: index commands: reset, preview

        @MainActor
        @Test func resetAndPreviewGoToIndexAndStartItWhenItIsNotRunning() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.reset()
                let first = await hcEventually { env.lines("index").contains { hcSameJSON($0, #"{"cmd":"reset"}"#) } }
                #expect(first, "reset did not reach index: \(env.lines("index"))")
                #expect(env.starts("index").count == 1)

                client.preview(ticket: 12, file: "/Users/me/Pictures/beach-dog.jpg", passage: nil, query: "a dog on the beach")
                client.preview(ticket: 13, file: "/Users/me/Pictures/beach-dog.jpg", passage: 345, query: "a dog on the beach")
                let arrived = await hcEventually { env.lines("index").filter { $0.contains("\"preview\"") }.count >= 2 }
                #expect(arrived, "index got \(env.lines("index"))")
                let previews = env.lines("index").filter { $0.contains("\"preview\"") }
                #expect(previews.count == 2)
                if previews.count == 2 {
                    #expect(hcSameJSON(previews[0], #"{"cmd":"preview","ticket":12,"file":"/Users/me/Pictures/beach-dog.jpg","passage":null,"query":"a dog on the beach"}"#),
                            "passage nil must be a JSON null: \(previews[0])")
                    #expect(hcSameJSON(previews[1], #"{"cmd":"preview","ticket":13,"file":"/Users/me/Pictures/beach-dog.jpg","passage":345,"query":"a dog on the beach"}"#),
                            "got \(previews[1])")
                }

                // a preview with no index running also starts one
                let second = env.makeClient()
                second.preview(ticket: 20, file: "/Users/me/Pictures/other.jpg", passage: nil, query: "x")
                let started = await hcEventually { env.starts("index").count == 2 }
                #expect(started, "a preview with no index running did not start one: \(env.starts("index").count) starts")
                hcVerifyRecording(env)
            }
        }

        // MARK: panel lines to index, each open and close

        @MainActor
        @Test func aPanelLineGoesToARunningIndexOnEachOpenAndCloseAndPrewarmOnEachOpen() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.reset() // starts index; the panel lines are counted from here
                let started = await hcEventually { !env.lines("index").isEmpty }
                #expect(started)
                await hcWait(0.4)
                let baseline = env.lines("index").count

                client.panelDidOpen()
                client.panelDidClose()
                client.panelDidOpen()
                client.panelDidClose()
                let arrived = await hcEventually { env.lines("index").count >= baseline + 4 }
                #expect(arrived, "index got \(env.lines("index").dropFirst(baseline))")
                await hcWait(0.4)
                let panelLines = Array(env.lines("index").dropFirst(baseline))
                let expected = [#"{"cmd":"panel","open":true}"#, #"{"cmd":"panel","open":false}"#,
                                #"{"cmd":"panel","open":true}"#, #"{"cmd":"panel","open":false}"#]
                #expect(panelLines.count == 4, "after the baseline index got \(panelLines)")
                for (line, want) in zip(panelLines, expected) {
                    #expect(hcSameJSON(line, want), "recorded \(line), the table says \(want)")
                }
                let prewarms = env.lines("encode")
                #expect(prewarms.count == 2 && prewarms.allSatisfy { hcSameJSON($0, #"{"cmd":"prewarm"}"#) },
                        "two opens should send two prewarms to encode: \(prewarms)")
                #expect(env.starts("index").count == 1, "the panel restarted index")
                hcVerifyRecording(env)
            }
        }

        // MARK: Start hook -> folders

        @MainActor
        @Test func theStartHookOfSetupModelSendsOneFoldersLineWithThePickedFoldersToIndexOnly() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let fileA = ModelFile(name: "hc-model-a.gguf", size: 4_000, sha256: String(repeating: "0", count: 64))
                let fileB = ModelFile(name: "hc-model-b.gguf", size: 3_000, sha256: String(repeating: "0", count: 64))
                try Data(count: 4_000).write(to: env.models.appendingPathComponent(fileA.name))
                try Data(count: 3_000).write(to: env.models.appendingPathComponent(fileB.name))
                try env.writeSettings(hcSettingsJSON(startPressed: false, folders: []))

                let model = SetupModel(files: [fileA, fileB], onStart: { client.sendFolders() })
                let pictures = try env.makeFolder("Pictures")
                let notes = try env.makeFolder("My Notes")
                let work = try env.makeFolder("Work")
                for url in [pictures, notes, work] { model.addFolder(url) }
                model.refresh()
                #expect(model.canStartIndexing, "the model is whole and three folders are picked")

                // adding a folder starts nothing
                await hcWait(0.3)
                #expect(env.starts("index").isEmpty && env.starts("encode").isEmpty, "a helper started before Start")

                model.startIndexing()
                let arrived = await hcEventually { env.lines("index").contains { $0.contains("\"folders\"") } }
                #expect(arrived, "Start did not send folders to index: \(env.lines("index"))")
                await hcWait(0.4)

                let folderLines = env.lines("index").filter { $0.contains("\"cmd\"") && $0.contains("\"folders\"") }
                #expect(folderLines.count == 1, "Start sent \(folderLines.count) folders lines")
                let want = [pictures.path, notes.path, work.path].sorted().map { ($0, false) }
                #expect(hcSamePairs(folderLines.first.flatMap(hcFolderPairs), want),
                        "folders line \(folderLines.first ?? "none"), expected the three picked folders, code false")
                #expect(env.lines("index").filter { !$0.contains("\"panel\"") }.count == 1,
                        "index got more than the one folders line: \(env.lines("index"))")
                #expect(env.starts("encode").isEmpty, "Start started encode")
                #expect(env.starts("index").count == 1)
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func sendFoldersReadsSettingsJSONSendsReadingFoldersWithCodeFalseWhateverTheStoredTickAndTheWholeListEachTime() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let pictures = try env.makeFolder("Pictures")
                let repo = try env.makeFolder("Developer app")
                let later = try env.makeFolder("Added Later")
                try env.writeSettings(hcSettingsJSON(startPressed: true, folders: [
                    (path: pictures.path, code: false, reading: true),
                    (path: repo.path, code: true, reading: true),
                    (path: later.path, code: false, reading: false),
                ]))
                client.sendFolders()
                let first = await hcEventually { env.lines("index").contains { $0.contains("\"folders\"") } }
                #expect(first, "no folders line: \(env.lines("index"))")
                let line1 = env.lines("index").last { $0.contains("\"folders\"") }
                let want1 = [pictures.path, repo.path].sorted().map { ($0, false) }
                #expect(hcSamePairs(line1.flatMap(hcFolderPairs), want1),
                        "first list \(line1 ?? "none"); expected Pictures and the repo, both code false, and not the folder that is not reading")

                // the list changes: the next line is the whole new list and replaces the old one
                try env.writeSettings(hcSettingsJSON(startPressed: true, folders: [
                    (path: repo.path, code: true, reading: true),
                ]))
                client.sendFolders()
                let second = await hcEventually { env.lines("index").filter { $0.contains("\"folders\"") }.count >= 2 }
                #expect(second, "the second Start sent no second folders line: \(env.lines("index"))")
                let line2 = env.lines("index").last { $0.contains("\"folders\"") }
                #expect(hcSamePairs(line2.flatMap(hcFolderPairs), [(repo.path, false)]),
                        "second list \(line2 ?? "none"); expected only the repo, code false")
                #expect(env.starts("index").count == 1, "the second list was sent to a new process")
                hcVerifyRecording(env)
            }
        }

        // MARK: one process serves consecutive commands; a command after an exit starts a new one

        @MainActor
        @Test func oneProcessPerHelperServesConsecutiveCommands() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                try env.writeSettings(hcSettingsJSON(startPressed: true,
                                                     folders: [(path: try env.makeFolder("Pictures").path, code: false, reading: true)]))
                client.panelDidOpen()
                client.embed(id: 1, text: "one", role: .query)
                client.sendFolders()
                client.reset()
                client.preview(ticket: 2, file: "/Users/me/a.jpg", passage: nil, query: "one")
                client.panelDidClose()
                client.embed(id: 2, text: "two", role: .query)
                client.panelDidOpen()
                client.embed(id: 3, text: "three", role: .document)
                let arrived = await hcEventually {
                    env.lines("encode").count >= 5 && env.lines("index").filter { !$0.contains("\"panel\"") }.count >= 3
                }
                #expect(arrived, "encode \(env.lines("encode")), index \(env.lines("index"))")
                await hcWait(0.4)
                #expect(env.starts("encode").count == 1, "encode was started \(env.starts("encode").count) times")
                #expect(env.starts("index").count == 1, "index was started \(env.starts("index").count) times")
                #expect(Set(env.stdin("encode").map(\.pid)).count == 1, "encode lines came from several processes")
                #expect(Set(env.stdin("index").map(\.pid)).count == 1, "index lines came from several processes")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func aCommandAfterTheHelperExitedStartsANewProcessAndNothingRestartsItByItself() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.embed(id: 1, text: "before", role: .query)
                client.reset()
                let both = await hcEventually { env.lines("encode").count == 1 && env.lines("index").count == 1 }
                #expect(both, "encode \(env.lines("encode")), index \(env.lines("index"))")
                let encodePid = env.starts("encode").first?.pid ?? 0
                let indexPid = env.starts("index").first?.pid ?? 0
                #expect(encodePid > 0 && indexPid > 0 && encodePid != indexPid)

                env.killLast("encode")
                env.killLast("index")
                let gone = await hcEventually { env.isGone(encodePid) && env.isGone(indexPid) }
                #expect(gone, "the stub processes did not die")
                await hcWait(0.8)
                #expect(env.starts("encode").count == 1 && env.starts("index").count == 1,
                        "the client restarted a helper by itself (no work was asked for)")

                client.embed(id: 2, text: "after", role: .query)
                client.preview(ticket: 5, file: "/Users/me/a.jpg", passage: nil, query: "after")
                let again = await hcEventually { env.starts("encode").count == 2 && env.starts("index").count == 2 }
                #expect(again, "encode starts \(env.starts("encode").count), index starts \(env.starts("index").count)")
                let delivered = await hcEventually {
                    env.stdin("encode").contains { $0.pid != encodePid && hcSameJSON($0.line, #"{"cmd":"embed","id":2,"text":"after","role":"query"}"#) }
                        && env.stdin("index").contains { $0.pid != indexPid && $0.line.contains("\"preview\"") }
                }
                #expect(delivered, "the command after the exit did not reach the new process: encode \(env.stdin("encode")), index \(env.stdin("index"))")
                #expect(env.starts("encode").map(\.pid).count == Set(env.starts("encode").map(\.pid)).count)
                hcVerifyRecording(env)
            }
        }

        // MARK: model paths and settings

        @MainActor
        @Test func modelPathsReachTheHelpersOnlyAsTextModelAndMmModelFlagsAndNoSesameSettingIsPassed() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.embed(id: 1, text: "x", role: .query)
                client.reset()
                let started = await hcEventually { !env.starts("encode").isEmpty && !env.starts("index").isEmpty }
                #expect(started)

                let encode = try #require(env.starts("encode").first, "encode was never started")
                #expect(encode.args.count == 2 && encode.args[0] == "--text-model"
                            && hcResolved(encode.args[1]) == hcResolved(env.textModel.path),
                        "encode was started with \(encode.args); expected exactly --text-model <text model>")

                let index = try #require(env.starts("index").first, "index was never started")
                var pairs: [String: String] = [:]
                var odd = index.args.count % 2 != 0
                var position = 0
                while position + 1 < index.args.count {
                    if pairs[index.args[position]] != nil { odd = true }
                    pairs[index.args[position]] = hcResolved(index.args[position + 1])
                    position += 2
                }
                #expect(!odd && Set(pairs.keys) == ["--text-model", "--mm-model"],
                        "index was started with \(index.args); expected exactly --text-model and --mm-model")
                #expect(pairs["--text-model"] == hcResolved(env.textModel.path), "index text model \(pairs["--text-model"] ?? "none")")
                #expect(pairs["--mm-model"] == hcResolved(env.mmModel.path), "index image model \(pairs["--mm-model"] ?? "none")")

                // the client adds no SESAME_* name or value to the environment it was started in
                let own = Set(ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("SESAME_") }
                    .map { "\($0.key)=\($0.value)" })
                #expect(Set(encode.env).isSubset(of: own), "encode got SESAME settings the client added: \(encode.env)")
                #expect(Set(index.env).isSubset(of: own), "index got SESAME settings the client added: \(index.env)")
                hcVerifyRecording(env)
            }
        }

        // MARK: events reach the delegate decoded

        @MainActor
        @Test func theEventsEitherHelperPrintsReachTheDelegateDecodedInOrder() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let delegate = HCRecorder()
                client.delegate = delegate

                // what each stub prints after the first line it reads; written by hand, one JSON object per line
                try env.setOut("encode", [
                    hcVectorLine,
                    #"{"event":"refused","id":8,"reason":"no model path was given"}"#,
                ])
                try env.setOut("index", [
                    #"{"event":"unit","size":4}"#,
                    #"{"event":"changed"}"#,
                    #"{"event":"walked"}"#,
                    hcPreviewLine,
                    #"{"event":"unit","size":16,"zzz":{"nested":[1,null,"x"]}}"#,
                ])

                client.embed(id: 7, text: "a dog on the beach", role: .query)
                client.reset()

                let arrived = await hcEventually { delegate.events.count >= 7 }
                #expect(arrived, "the delegate got \(delegate.events.count) of 7 events: \(delegate.events)")

                let events = delegate.events
                let fromEncode = events.filter {
                    switch $0 { case .vector, .refused: true; default: false }
                }
                let fromIndex = events.filter {
                    switch $0 { case .vector, .refused: false; default: true }
                }
                #expect(fromEncode == [
                    .vector(id: 7, ms: 23, vec: hcVectorNumbers),
                    .refused(id: 8, reason: "no model path was given"),
                ], "encode events: \(fromEncode)")
                #expect(fromIndex == [
                    .unit(size: 4), .changed, .walked,
                    .preview(PreviewReply(ticket: 12, status: .ok, png: hcPreviewPath, name: "beach-dog.jpg",
                                          kind: "photo", size: 48213, mtime: 1_760_000_000)),
                    .unit(size: 16),
                ], "index events (the last line carries an extra field the client must tolerate): \(fromIndex)")
                hcVerifyRecording(env)
            }
        }

        // MARK: no traffic nobody asked for

        @MainActor
        @Test func theClientSendsNothingBetweenCommands() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.embed(id: 1, text: "x", role: .query)
                client.reset()
                let started = await hcEventually { env.lines("encode").count == 1 && env.lines("index").count == 1 }
                #expect(started)
                await hcWait(1.2)
                #expect(env.lines("encode").count == 1, "encode was sent more than asked: \(env.lines("encode"))")
                #expect(env.lines("index").count == 1, "index was sent more than asked: \(env.lines("index"))")
                #expect(env.starts("encode").count == 1 && env.starts("index").count == 1)
                hcVerifyRecording(env)
            }
        }

        // MARK: plan-2-t17, the one-shot bench
        //
        // API SHAPE these tests pin (the entry names `HelperClient.runBench(completion:)` and fixes no signature): the
        // method is synchronous and returns at once; `completion` is `@escaping (Result<[String: Double], Error>) -> Void`,
        // called once per call, on any thread, with the `speeds` object of the helper's one `bench` line (seconds per
        // file, by kind) or a failure. The helper is started as `<helper> index bench --text-model <p> --mm-model <p>`
        // (the two flags in either order, and nothing else: no folder, no other flag). The stub records it in
        // `bench.starts`; a bench start is never counted in `index.starts`, which holds only the persistent `index`.

        @MainActor
        @Test func runBenchStartsIndexBenchWithBothModelFlagsAndNoFolderAndDeliversTheSpeeds() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let results = HCBenchResults()
                client.runBench { results.record($0) }
                let arrived = await hcEventually { results.total >= 1 }
                #expect(arrived, "the completion was never called; bench starts \(env.starts("bench").count)")
                await hcWait(0.4)

                #expect(results.total == 1, "the completion was called \(results.total) times for one call")
                #expect(results.failureCount == 0, "a bench that printed one valid line completed with a failure")
                #expect(results.successes == [["photo": 0.31]], "the completion got \(results.successes); the stub printed photo 0.31")

                let started = env.starts("bench")
                #expect(started.count == 1, "the bench was started \(started.count) times")
                let args = try #require(started.first, "no bench process was started").args
                #expect(args.first == "bench", "the helper was started with \(args); expected `index bench ...`")
                let flags = Array(args.dropFirst())
                var pairs: [String: String] = [:]
                var odd = flags.count % 2 != 0
                var position = 0
                while position + 1 < flags.count {
                    if pairs[flags[position]] != nil { odd = true }
                    pairs[flags[position]] = hcResolved(flags[position + 1])
                    position += 2
                }
                #expect(!odd && Set(pairs.keys) == ["--text-model", "--mm-model"],
                        "the bench was started with \(args); expected only --text-model and --mm-model after `bench` (no folder)")
                #expect(pairs["--text-model"] == hcResolved(env.textModel.path), "bench text model \(pairs["--text-model"] ?? "none")")
                #expect(pairs["--mm-model"] == hcResolved(env.mmModel.path), "bench image model \(pairs["--mm-model"] ?? "none")")
                let own = Set(ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("SESAME_") }
                    .map { "\($0.key)=\($0.value)" })
                #expect(Set(try #require(started.first).env).isSubset(of: own), "the bench got SESAME settings the client added")

                // the bench is not the persistent helpers: nothing was started or sent to encode or index
                #expect(env.starts("index").isEmpty && env.starts("encode").isEmpty,
                        "the bench started a persistent helper: index \(env.starts("index").count), encode \(env.starts("encode").count)")
                #expect(env.lines("index").isEmpty && env.lines("encode").isEmpty, "a line was sent to a persistent helper")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func aBenchThatExitsOneOrPrintsNoBenchEventCompletesOnceWithAFailure() async throws {
            for behavior in ["exit1", "silent", "notbench", "garbage"] {
                try await hcRun { env in
                    try env.setBench(behavior)
                    let client = env.makeClient()
                    let results = HCBenchResults()
                    client.runBench { results.record($0) }
                    let arrived = await hcEventually { results.total >= 1 }
                    #expect(arrived, "[\(behavior)] the completion was never called")
                    await hcWait(0.6)
                    #expect(results.total == 1, "[\(behavior)] the completion was called \(results.total) times")
                    #expect(results.failureCount == 1 && results.successes.isEmpty,
                            "[\(behavior)] expected one failure, got successes \(results.successes) and \(results.failureCount) failures")
                    #expect(env.starts("bench").count == 1, "[\(behavior)] the client started the bench \(env.starts("bench").count) times (no retry in the client)")
                }
            }
        }

        @MainActor
        @Test func theBenchProcessIsNotKeptAliveOrReusedByLaterCommands() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let results = HCBenchResults()
                client.runBench { results.record($0) }
                #expect(await hcEventually { results.total >= 1 })
                let benchPid = env.starts("bench").first?.pid ?? 0
                #expect(benchPid > 0)
                let gone = await hcEventually { env.isGone(benchPid) }
                #expect(gone, "the bench process \(benchPid) is still running after its completion")

                // a later index command starts its own persistent helper, not the bench, and sends the bench nothing
                client.reset()
                let started = await hcEventually { env.starts("index").count == 1 && !env.lines("index").isEmpty }
                #expect(started, "reset after a bench did not start index: \(env.starts("index").count) starts")
                let index = try #require(env.starts("index").first, "index was never started")
                #expect(index.pid != benchPid)
                #expect(index.args.first != "bench" && !index.args.contains("bench"), "index was started as \(index.args)")
                #expect(env.starts("bench").count == 1, "a later command restarted the bench")

                // a second call after the first finished is a new run, not a replay of the old one
                client.runBench { results.record($0) }
                #expect(await hcEventually { results.total >= 2 && env.starts("bench").count == 2 },
                        "the second call did not run: \(env.starts("bench").count) bench starts, \(results.total) completions")
                #expect(Set(env.starts("bench").map(\.pid)).count == 2, "the two bench runs share a process")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func twoCallsWhileOneBenchRunsShareOneProcessAndBothGetTheSpeeds() async throws {
            try await hcRun { env in
                try env.setBench("wait-go")
                let client = env.makeClient()
                let first = HCBenchResults()
                let second = HCBenchResults()
                client.runBench { first.record($0) }
                #expect(await hcEventually { env.starts("bench").count == 1 }, "the bench never started")
                client.runBench { second.record($0) }
                await hcWait(0.6)
                #expect(env.starts("bench").count == 1, "a second call started a second process while one ran: \(env.starts("bench").count)")
                #expect(first.total == 0 && second.total == 0, "a completion came before the bench had printed")

                env.releaseBench()
                let both = await hcEventually { first.total >= 1 && second.total >= 1 }
                #expect(both, "first \(first.total), second \(second.total) completions")
                await hcWait(0.4)
                #expect(first.successes == [["photo": 0.31]], "first completion: \(first.successes), failures \(first.failureCount)")
                #expect(second.successes == [["photo": 0.31]], "second completion: \(second.successes), failures \(second.failureCount)")
                #expect(first.total == 1 && second.total == 1, "a completion was called more than once")
                #expect(env.starts("bench").count == 1, "the two calls used \(env.starts("bench").count) processes")
                hcVerifyRecording(env)
            }
        }

        // MARK: plan-2-t31, the clean stop, the exit report and the shutdown
        //
        // API SHAPES these tests pin (the entry names `stopIndex()`, `onExit`, `shutdown(timeout:)` and "planned" and
        // "unplanned with its status", and fixes no signatures; if a shape is wrong, ask for a test change rather than
        // guessing). The stub, as above, records its starts and stdin lines; for these tests it also records the pid of a
        // stub whose stdin ended (`<mode>.eof`), can exit by itself with a status (`<mode>.exit-code`) and can ignore the
        // end of stdin and run on (`<mode>.ignore-eof`).
        //   1. `enum HelperExit: Equatable, Sendable { case planned; case unplanned(status: Int32) }` (see
        //      HelperSupervisorTests, pin 2).
        //   2. `var onExit: ((String, HelperExit) -> Void)?` on `HelperClient`: called once per exit of an `encode` or an
        //      `index` process, after the process is gone, with the helper's mode name ("encode" or "index") and the
        //      exit. It may be called on any thread (the tests collect it under a lock). The one-shot bench is not
        //      reported. Exit status: for an exit with a status (the stub's `exit 3`) `.unplanned(status: 3)`; for a
        //      process killed by a signal a non-zero status (the tests do not pin which number).
        //   3. `func stopIndex()`: synchronous, returns at once. Closes the stdin of the running `index` process and
        //      nothing else: no line is written, `encode` is not touched, nothing is started. The process exits 0 when it
        //      sees the end, and that exit is reported as `.planned`. With no `index` running it does nothing. The next
        //      `index` command (`sendFolders()`, `reset()`, a preview) starts a new process, as after any exit.
        //   4. `func shutdown(timeout: TimeInterval, completion: @escaping () -> Void)`: synchronous, returns at once.
        //      Ends the stdin of both running helpers, waits for both to exit, kills one still alive `timeout` seconds
        //      later, and calls `completion` once, after both processes are gone (or at the latest soon after the kill).
        //      It starts neither helper and writes no line. With no helper running `completion` is called (it never
        //      waits for the timeout then; the tests allow 10 s of slack either way).

        @MainActor
        @Test func stopIndexClosesStdinTheStubSeesTheEndAndExitsZeroAndOnExitReportsItPlanned() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let exits = HCExits()
                client.onExit = { helper, exit in exits.record(helper, exit) }
                client.reset()
                let started = await hcEventually { !env.lines("index").isEmpty }
                #expect(started, "index never got the reset")
                let pid = env.starts("index").first?.pid ?? 0
                #expect(pid > 0)
                let linesBefore = env.lines("index")

                client.stopIndex()
                let ended = await hcEventually { env.eofPids("index").contains(pid) }
                #expect(ended, "the index stub never saw its stdin end")
                let gone = await hcEventually { env.isGone(pid) }
                #expect(gone, "the index stub did not exit after its stdin ended")
                let reported = await hcEventually { exits.all.count >= 1 }
                #expect(reported, "onExit was never called")
                await hcWait(0.6)
                #expect(exits.all.count == 1, "onExit was called \(exits.all.count) times for one exit: \(exits.all)")
                #expect(exits.of("index") == [.planned], "a stop the app asked for must be planned, got \(exits.of("index"))")
                #expect(env.lines("index") == linesBefore, "stopIndex wrote a line: \(env.lines("index"))")
                #expect(env.starts("index").count == 1, "stopIndex started a process")
                #expect(env.starts("encode").isEmpty, "stopIndex started encode")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func stopIndexLeavesTheEncodeHelperAloneAndReportsNothingForIt() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let exits = HCExits()
                client.onExit = { helper, exit in exits.record(helper, exit) }
                client.embed(id: 1, text: "x", role: .query)
                client.reset()
                let both = await hcEventually { env.lines("encode").count == 1 && env.lines("index").count == 1 }
                #expect(both)
                let encodePid = env.starts("encode").first?.pid ?? 0
                let indexPid = env.starts("index").first?.pid ?? 0

                client.stopIndex()
                #expect(await hcEventually { env.isGone(indexPid) }, "index did not exit")
                await hcWait(0.6)
                #expect(env.isGone(encodePid) == false, "encode was stopped with index")
                #expect(env.eofPids("encode").isEmpty, "encode's stdin was closed")
                #expect(exits.of("encode").isEmpty, "encode never exited, yet onExit said \(exits.of("encode"))")
                #expect(exits.of("index") == [.planned])
                #expect(env.lines("encode").count == 1, "encode was sent a line: \(env.lines("encode"))")

                // encode still serves a command
                client.embed(id: 2, text: "y", role: .query)
                #expect(await hcEventually { env.lines("encode").count == 2 })
                #expect(env.starts("encode").count == 1)
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func stopIndexWithNoIndexRunningStartsNothingAndReportsNothing() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let exits = HCExits()
                client.onExit = { helper, exit in exits.record(helper, exit) }
                client.stopIndex()
                await hcWait(0.5)
                #expect(env.starts("index").isEmpty && env.starts("encode").isEmpty, "stopIndex started a helper")
                #expect(exits.all.isEmpty, "onExit said \(exits.all) with nothing running")

                // after a clean stop has finished, a second stopIndex does nothing either
                client.reset()
                #expect(await hcEventually { !env.lines("index").isEmpty })
                let pid = env.starts("index").first?.pid ?? 0
                client.stopIndex()
                #expect(await hcEventually { env.isGone(pid) && exits.all.count == 1 })
                client.stopIndex()
                await hcWait(0.5)
                #expect(exits.all.count == 1, "a second stopIndex reported another exit: \(exits.all)")
                #expect(env.starts("index").count == 1, "a second stopIndex started a process")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func aCommandAfterACleanStopStartsANewIndexProcessAndTheNextExitIsNotPlanned() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let exits = HCExits()
                client.onExit = { helper, exit in exits.record(helper, exit) }
                let pictures = try env.makeFolder("Pictures")
                try env.writeSettings(hcSettingsJSON(startPressed: true,
                                                     folders: [(path: pictures.path, code: false, reading: true)]))
                client.sendFolders()
                #expect(await hcEventually { env.lines("index").filter { $0.contains("\"folders\"") }.count == 1 })
                let first = env.starts("index").first?.pid ?? 0

                client.stopIndex()
                #expect(await hcEventually { env.isGone(first) && exits.of("index").count == 1 })

                // a resume: a new process, and the whole list once
                client.sendFolders()
                #expect(await hcEventually { env.starts("index").count == 2 }, "no new index process after the clean stop")
                let second = env.starts("index").last?.pid ?? 0
                #expect(second > 0 && second != first)
                let delivered = await hcEventually {
                    env.stdin("index").contains { $0.pid == second && $0.line.contains("\"folders\"") }
                }
                #expect(delivered, "the folders line did not reach the new process: \(env.stdin("index"))")
                await hcWait(0.4)
                #expect(env.stdin("index").filter { $0.pid == second }.count == 1, "the new process got more than the one folders line")
                #expect(exits.of("index") == [.planned], "the new process has not exited: \(exits.of("index"))")

                // the new process is killed from outside: that exit is not planned, the earlier stop does not carry over
                env.killLast("index")
                #expect(await hcEventually { exits.of("index").count == 2 })
                if exits.of("index").count == 2, case .unplanned(let status) = exits.of("index")[1] {
                    #expect(status != 0, "a kill has a non-zero status")
                } else {
                    Issue.record("the second exit should be unplanned, got \(exits.of("index"))")
                }
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func aStubKilledFromOutsideIsReportedAsAnUnplannedExitWithItsStatusAndNothingRestartsIt() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let exits = HCExits()
                client.onExit = { helper, exit in exits.record(helper, exit) }
                client.embed(id: 1, text: "x", role: .query)
                client.reset()
                let both = await hcEventually { env.lines("encode").count == 1 && env.lines("index").count == 1 }
                #expect(both)

                env.killLast("index")
                #expect(await hcEventually { exits.of("index").count == 1 }, "onExit was not called for the killed index")
                if let exit = exits.of("index").first {
                    if case .unplanned(let status) = exit {
                        #expect(status != 0, "a process killed by a signal has a non-zero status, got \(status)")
                    } else {
                        Issue.record("a kill from outside is not planned, got \(exit)")
                    }
                }
                #expect(exits.of("encode").isEmpty, "encode was alive but onExit said \(exits.of("encode"))")

                env.killLast("encode")
                #expect(await hcEventually { exits.of("encode").count == 1 }, "onExit was not called for the killed encode")
                if let exit = exits.of("encode").first {
                    if case .unplanned = exit {} else { Issue.record("a kill from outside is not planned, got \(exit)") }
                }
                await hcWait(0.8)
                #expect(exits.all.count == 2, "each exit is reported once: \(exits.all)")
                #expect(env.starts("index").count == 1 && env.starts("encode").count == 1,
                        "the client restarted a helper by itself (the supervisor decides that)")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func aStubThatExitsOnItsOwnWithStatusThreeIsAnUnplannedExitWithStatusThree() async throws {
            try await hcRun { env in
                try env.setExitCode("index", 3)
                let client = env.makeClient()
                let exits = HCExits()
                client.onExit = { helper, exit in exits.record(helper, exit) }
                client.reset()
                #expect(await hcEventually { exits.of("index").count == 1 }, "onExit was not called")
                await hcWait(0.4)
                #expect(exits.of("index") == [.unplanned(status: 3)], "got \(exits.of("index"))")
                #expect(env.eofPids("index").isEmpty, "the client closed stdin though nothing asked for a stop")
                hcVerifyRecording(env)
            }
        }

        // MARK: shutdown

        @MainActor
        @Test func shutdownEndsBothChannelsAndCompletesOnceBothHelpersHaveExited() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.embed(id: 1, text: "x", role: .query)
                client.reset()
                let both = await hcEventually { env.lines("encode").count == 1 && env.lines("index").count == 1 }
                #expect(both)
                let encodePid = env.starts("encode").first?.pid ?? 0
                let indexPid = env.starts("index").first?.pid ?? 0
                let encodeBefore = env.lines("encode")
                let indexBefore = env.lines("index")

                let done = HCDone()
                client.shutdown(timeout: 5) { done.mark() }
                #expect(await hcEventually { env.eofPids("encode").contains(encodePid) && env.eofPids("index").contains(indexPid) },
                        "both stubs should see their stdin end")
                #expect(await hcEventually(timeout: 15) { env.isGone(encodePid) && env.isGone(indexPid) }, "a stub is still running")
                #expect(await hcEventually(timeout: 15) { done.calls >= 1 }, "the completion was never called")
                await hcWait(0.6)
                #expect(done.calls == 1, "the completion was called \(done.calls) times")
                #expect(env.isGone(encodePid) && env.isGone(indexPid), "the completion came while a helper was still alive")
                #expect(env.lines("encode") == encodeBefore && env.lines("index") == indexBefore, "shutdown wrote a line")
                #expect(env.starts("encode").count == 1 && env.starts("index").count == 1, "shutdown started a helper")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func shutdownKillsAStubThatIgnoresTheEndOfStdinAfterTheTimeout() async throws {
            try await hcRun { env in
                env.setIgnoreEOF("index")
                let client = env.makeClient()
                client.embed(id: 1, text: "x", role: .query)
                client.reset()
                let both = await hcEventually { env.lines("encode").count == 1 && env.lines("index").count == 1 }
                #expect(both)
                let encodePid = env.starts("encode").first?.pid ?? 0
                let indexPid = env.starts("index").first?.pid ?? 0

                let done = HCDone()
                client.shutdown(timeout: 6) { done.mark() }
                #expect(await hcEventually { env.eofPids("index").contains(indexPid) }, "the stub never saw its stdin end")
                #expect(await hcEventually { env.isGone(encodePid) }, "the well-behaved encode stub did not exit at the end of stdin")

                // not killed before the timeout (the lower bound has 5 s of slack), and the completion waits for it
                await hcWait(0.5)
                #expect(env.isGone(indexPid) == false, "the stub that ignores the end was killed long before the 6 s timeout")
                #expect(done.calls == 0, "the completion was called while a helper was alive")

                // killed after it (the upper bound has 10 s of slack)
                #expect(await hcEventually(timeout: 16) { env.isGone(indexPid) }, "the stub was not killed after the timeout")
                #expect(await hcEventually(timeout: 16) { done.calls >= 1 }, "the completion was never called after the kill")
                await hcWait(0.6)
                #expect(done.calls == 1, "the completion was called \(done.calls) times")
                #expect(env.starts("index").count == 1 && env.starts("encode").count == 1, "shutdown started a helper")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func shutdownStartsNeitherHelperAndCompletesWhenNothingRuns() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                let done = HCDone()
                client.shutdown(timeout: 2) { done.mark() }
                #expect(await hcEventually(timeout: 12) { done.calls >= 1 }, "the completion was never called with nothing running")
                await hcWait(0.6)
                #expect(done.calls == 1, "the completion was called \(done.calls) times")
                #expect(env.starts("encode").isEmpty && env.starts("index").isEmpty, "shutdown started a helper")
                #expect(env.lines("encode").isEmpty && env.lines("index").isEmpty, "shutdown wrote a line")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func shutdownWithOnlyEncodeRunningEndsItAndNeverStartsIndex() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.embed(id: 1, text: "x", role: .query)
                #expect(await hcEventually { env.lines("encode").count == 1 })
                let encodePid = env.starts("encode").first?.pid ?? 0
                let done = HCDone()
                client.shutdown(timeout: 3) { done.mark() }
                #expect(await hcEventually(timeout: 15) { env.isGone(encodePid) && done.calls >= 1 })
                await hcWait(0.5)
                #expect(done.calls == 1)
                #expect(env.starts("index").isEmpty, "shutdown started index")
                #expect(env.starts("encode").count == 1, "shutdown started a second encode")
                hcVerifyRecording(env)
            }
        }

        @MainActor
        @Test func shutdownAfterACleanStopCompletesAtOnceWithNothingLeftToWaitFor() async throws {
            try await hcRun { env in
                let client = env.makeClient()
                client.reset()
                #expect(await hcEventually { !env.lines("index").isEmpty })
                let pid = env.starts("index").first?.pid ?? 0
                client.stopIndex()
                #expect(await hcEventually { env.isGone(pid) })
                let done = HCDone()
                client.shutdown(timeout: 3) { done.mark() }
                #expect(await hcEventually(timeout: 12) { done.calls >= 1 }, "the completion was never called")
                await hcWait(0.5)
                #expect(done.calls == 1)
                #expect(env.starts("index").count == 1, "shutdown started an index process")
                hcVerifyRecording(env)
            }
        }
    }
}

// MARK: plan-3-t20, tester step: the helper's idle exit is not a death
//
// Everything above this line is sealed and unchanged. This section is written from the t20 entry of plan-3-tasks.md (its
// Tests paragraph, first sentence), Decision D11 and the sealed t31 tests above (the stub, its `<mode>.exit-code` switch and
// `HCExits`); no product source was read.
//
// API SHAPE t20 adds (the entry fixes the name): `HelperExit` gains the case `idle`, so
//     enum HelperExit: Equatable, Sendable { case planned; case unplanned(status: Int32); case idle }
// `.idle` is what `HelperClient.onExit` hands over for an `encode` or an `index` process that exited with status 0 although
// nobody asked it to stop (the helper's own 60 s idle exit). Everything else keeps its report: a non-zero status, a kill
// from outside and a helper that could not be started are `.unplanned`; an exit after `stopIndex()` or `shutdown` is
// `.planned`.
//
// The stub of this file exits by itself with the status in `<mode>.exit-code` after the first line it reads: with the code 0
// it is the idle helper.

extension ModelDownloadTests.HelperClientTests {

    @MainActor
    @Test func aStubThatExitsZeroOnItsOwnIsAnIdleExitForIndexAndForEncode() async throws {
        try await hcRun { env in
            try env.setExitCode("index", 0)
            try env.setExitCode("encode", 0)
            let client = env.makeClient()
            let exits = HCExits()
            client.onExit = { helper, exit in exits.record(helper, exit) }
            client.reset()
            client.embed(id: 1, text: "x", role: .query)
            #expect(await hcEventually { exits.of("index").count == 1 && exits.of("encode").count == 1 },
                    "onExit was not called for both stubs: \(exits.all)")
            await hcWait(0.6)
            #expect(exits.of("index") == [.idle], "an exit 0 nobody asked for is idle, not a death; got \(exits.of("index"))")
            #expect(exits.of("encode") == [.idle], "an exit 0 nobody asked for is idle, not a death; got \(exits.of("encode"))")
            #expect(env.eofPids("index").isEmpty && env.eofPids("encode").isEmpty,
                    "the client closed a stdin though nothing asked for a stop")
            #expect(env.starts("index").count == 1 && env.starts("encode").count == 1,
                    "the client started a helper again by itself (the supervisor decides that)")
            hcVerifyRecording(env)
        }
    }

    @MainActor
    @Test func aStubThatExitsWithStatusOneIsStillAnUnplannedExitNotAnIdleOne() async throws {
        try await hcRun { env in
            try env.setExitCode("index", 1)
            try env.setExitCode("encode", 2)
            let client = env.makeClient()
            let exits = HCExits()
            client.onExit = { helper, exit in exits.record(helper, exit) }
            client.reset()
            client.embed(id: 1, text: "x", role: .query)
            #expect(await hcEventually { exits.of("index").count == 1 && exits.of("encode").count == 1 },
                    "onExit was not called for both stubs: \(exits.all)")
            await hcWait(0.6)
            #expect(exits.of("index") == [.unplanned(status: 1)], "got \(exits.of("index"))")
            #expect(exits.of("encode") == [.unplanned(status: 2)], "got \(exits.of("encode"))")
            hcVerifyRecording(env)
        }
    }

    @MainActor
    @Test func aStubKilledFromOutsideWithSigtermOrSigkillIsStillUnplannedNotIdle() async throws {
        try await hcRun { env in
            let client = env.makeClient()
            let exits = HCExits()
            client.onExit = { helper, exit in exits.record(helper, exit) }
            client.reset()
            client.embed(id: 1, text: "x", role: .query)
            #expect(await hcEventually { env.lines("index").count == 1 && env.lines("encode").count == 1 })
            let indexPid = env.starts("index").first?.pid ?? 0
            #expect(indexPid > 0)
            _ = Darwin.kill(pid_t(indexPid), SIGTERM)
            env.killLast("encode")
            #expect(await hcEventually { exits.of("index").count == 1 && exits.of("encode").count == 1 },
                    "onExit was not called for both killed stubs: \(exits.all)")
            await hcWait(0.6)
            for helper in ["index", "encode"] {
                let reported = exits.of(helper)
                if reported.count == 1, case .unplanned(let status) = reported[0] {
                    #expect(status != 0, "\(helper): a process killed by a signal has a non-zero status, got \(status)")
                } else {
                    Issue.record("\(helper): a kill from outside must be one .unplanned exit, got \(reported)")
                }
            }
            hcVerifyRecording(env)
        }
    }

    @MainActor
    @Test func aHelperThatCouldNotBeStartedIsAnUnplannedExitNotAnIdleOne() async throws {
        try await hcRun { env in
            let missing = env.dir.appendingPathComponent("no-such-helper")
            let client = HelperClient(helper: missing, textModel: env.textModel, mmModel: env.mmModel)
            let exits = HCExits()
            client.onExit = { helper, exit in exits.record(helper, exit) }
            client.reset()
            client.embed(id: 1, text: "x", role: .query)
            #expect(await hcEventually { exits.of("index").count >= 1 && exits.of("encode").count >= 1 },
                    "onExit was not called for a helper that could not start: \(exits.all)")
            await hcWait(0.4)
            for helper in ["index", "encode"] {
                let reported = exits.of(helper)
                if let first = reported.first, case .unplanned = first {} else {
                    Issue.record("\(helper): a helper that could not be started must be .unplanned, got \(reported)")
                }
                #expect(reported.allSatisfy { $0 != .idle && $0 != .planned }, "\(helper): got \(reported)")
            }
        }
    }

    @MainActor
    @Test func anExitZeroAfterStopIndexIsPlannedAndNotIdleAndTheStopDoesNotCarryOverToALaterOwnExit() async throws {
        try await hcRun { env in
            let client = env.makeClient()
            let exits = HCExits()
            client.onExit = { helper, exit in exits.record(helper, exit) }
            client.reset()
            #expect(await hcEventually { !env.lines("index").isEmpty })
            let first = env.starts("index").first?.pid ?? 0
            client.stopIndex()
            #expect(await hcEventually { env.isGone(first) && exits.of("index").count == 1 })
            await hcWait(0.4)
            #expect(exits.of("index") == [.planned], "the stub exited 0 after the app closed its stdin; got \(exits.of("index"))")

            // a new process that then exits 0 by itself is an idle exit: the earlier stop does not make it planned
            try env.setExitCode("index", 0)
            client.reset()
            #expect(await hcEventually { exits.of("index").count == 2 }, "the second exit was not reported: \(exits.of("index"))")
            await hcWait(0.4)
            #expect(exits.of("index") == [.planned, .idle], "got \(exits.of("index"))")
            #expect(env.starts("index").count == 2)
            hcVerifyRecording(env)
        }
    }

    @MainActor
    @Test func theExitsAfterShutdownAreBothPlannedAndNeitherIsIdle() async throws {
        try await hcRun { env in
            let client = env.makeClient()
            let exits = HCExits()
            client.onExit = { helper, exit in exits.record(helper, exit) }
            client.embed(id: 1, text: "x", role: .query)
            client.reset()
            #expect(await hcEventually { env.lines("encode").count == 1 && env.lines("index").count == 1 })
            let encodePid = env.starts("encode").first?.pid ?? 0
            let indexPid = env.starts("index").first?.pid ?? 0

            let done = HCDone()
            client.shutdown(timeout: 5) { done.mark() }
            #expect(await hcEventually(timeout: 15) { env.isGone(encodePid) && env.isGone(indexPid) && done.calls >= 1 },
                    "the stubs did not end or the completion was never called")
            await hcWait(0.6)
            #expect(done.calls == 1)
            #expect(exits.of("index") == [.planned], "got \(exits.of("index"))")
            #expect(exits.of("encode") == [.planned], "got \(exits.of("encode"))")
            hcVerifyRecording(env)
        }
    }
}
