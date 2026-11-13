// The kit's key-event tool: posts real keyboard events at real speed (CGEvent), and answers the
// two permission questions the kit asks about the terminal it runs from.
//
//   keytool key "<combo>"                       e.g. "ctrl+opt+space", "cmd+enter", "esc"
//   keytool type "<text>" [--delay-ms N] [--then "<combo>"] [--then-delay-ms N] [--front-pids <p,p,...>] [--dry-run]
//                                               per-key delay: --delay-ms N, else env KIT_TYPE_DELAY_MS
//                                               (whole ms, 0 to 500; invalid = warning, ignored), else 10 ms
//   keytool trusted                             Accessibility for this terminal
//   keytool automation <bundle id>              Automation for that app, without asking
//   keytool pb-count|pb-save|pb-restore [--name <pasteboard>] [--only-if-change-count N]
//                                               the pasteboard commands of kit-ax.sh paste (see below)
//
// `pb-save` writes a summary line and then the base64 of every item and type of the pasteboard to stdout (never to
// a file, so a copied password is not left on disk); `pb-restore` reads that base64 from stdin and puts it all back,
// but only while the change count is still the one given (so a copy the person made meanwhile is never overwritten).
// The general pasteboard is the default; --name uses a private one, for the kit's own tests.
//
// `type` and a focus that moves (round C, F20): with --front-pids the caller names the pids that may receive the
// keys (the target app). The frontmost app (NSWorkspace, read again at every check) must be one of them before every 8th character (before characters 9, 17, 25, ...) and
// again before the --then combination (after its --then-delay-ms). When it is not, nothing more is posted: one
// "refused: ..." line on stdout and exit 4. The caller (kit-ax.sh type) makes the first check itself before it
// starts the tool, and always passes --front-pids. Without --front-pids there is no re-check (direct use only).
// --dry-run posts no key and sleeps no delay but runs every check and says what it read, for the kit's own tests.
//
// Exit codes: 0 done or granted; 1 error or not trusted; 2 usage; 3 NEEDS A PERSON; 4 the target was no longer
// frontmost (type, nothing more posted) or its pid could not be read.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func usage() -> Never {
    fail("""
    usage: keytool key "<combo>"
           keytool type "<text>" [--delay-ms N] [--then "<combo>"] [--then-delay-ms N] [--front-pids <p,p,...>] [--dry-run]
           keytool trusted
           keytool automation <bundle id>
           keytool pb-count|pb-save|pb-restore [--name <pasteboard>] [--only-if-change-count N]
    type delay: --delay-ms N, else env KIT_TYPE_DELAY_MS (whole ms, 0 to 500), else 10 ms
    type --front-pids: re-checks every 8 characters and before --then that the frontmost app is one of those
    pids; if not, nothing more is posted and the exit code is 4
    """, 2)
}

// US-layout virtual key codes.
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "equal": 24, "9": 25, "7": 26, "-": 27, "minus": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "enter": 36, "return": 36,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "comma": 43, "/": 44,
    "slash": 44, "n": 45, "m": 46, ".": 47, "period": 47, "tab": 48, "space": 49, "`": 50,
    "delete": 51, "backspace": 51, "esc": 53, "escape": 53, "left": 123, "right": 124,
    "down": 125, "up": 126, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
]

func parseCombo(_ combo: String) -> (CGKeyCode, CGEventFlags) {
    var flags: CGEventFlags = []
    var key: String?
    for part in combo.lowercased().split(separator: "+", omittingEmptySubsequences: true) {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "ctrl", "control": flags.insert(.maskControl)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        default:
            if key != nil { fail("more than one key in combo: \(combo)", 2) }
            key = String(part)
        }
    }
    guard let name = key, let code = keyCodes[name] else { fail("unknown key in combo: \(combo)", 2) }
    return (code, flags)
}

func requireTrusted() {
    if !AXIsProcessTrusted() {
        print("NEEDS A PERSON: Accessibility for this terminal")
        exit(3)
    }
}

// How long `key` stays alive after posting the key down and up (measured: 0 s fails, 1 s delivers).
let settleAfterPostMicroseconds: UInt32 = 1_000_000

func post(code: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            fail("could not create a key event")
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

// The pid of the frontmost app, from NSWorkspace (the same Launch Services answer System Events gives). A command
// line tool only hears of an activation when its run loop turns, so the loop is turned for 30 ms before every read.
// (The Accessibility "focused application" is not used: it answers "cannot complete" when the frontmost app, such as
// a browser, does not serve Accessibility, which measured here.) nil when it cannot be read.
func frontmostPid() -> pid_t? {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

// How many characters `type` posts between two checks of the frontmost app.
let typeRecheckEvery = 8

// The re-check of `type`: with no `allowed` set there is none. When the frontmost app is not one of `allowed` (or
// cannot be read) this prints one "refused: ..." line and exits 4, so nothing more is posted.
func requireFront(_ allowed: Set<pid_t>?, dryRun: Bool, _ place: String, typed: Int, total: Int) {
    guard let allowed else { return }
    let front = frontmostPid()
    let ok = front.map { allowed.contains($0) } ?? false
    if dryRun {
        print("check \(place): frontmost pid \(front.map(String.init) ?? "unreadable"), allowed \(allowed.sorted()), \(ok ? "ok" : "REFUSED")")
    }
    guard let front else {
        print("refused: the frontmost app could not be read \(place); typed \(typed) of \(total) characters, nothing more was posted")
        exit(4)
    }
    guard ok else {
        print("refused: the frontmost app (pid \(front)) is no longer the target \(place); typed \(typed) of \(total) characters, nothing more was posted")
        exit(4)
    }
}

func typeText(_ text: String, delayMs: Int, allowed: Set<pid_t>?, dryRun: Bool) {
    let source = CGEventSource(stateID: .hidSystemState)
    let total = text.count
    for (index, character) in text.enumerated() {
        if index > 0 && index % typeRecheckEvery == 0 {
            requireFront(allowed, dryRun: dryRun, "before character \(index + 1)", typed: index, total: total)
        }
        if dryRun { continue }
        var units = Array(String(character).utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                fail("could not create a key event")
            }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.post(tap: .cghidEventTap)
        }
        if delayMs > 0 { usleep(UInt32(delayMs) * 1000) }
    }
}

// The per-key delay of `type` when no --delay-ms is given: KIT_TYPE_DELAY_MS (whole ms, 0 to 500), else 10.
// An invalid value is ignored with one warning line on stderr.
func envTypeDelayMs() -> Int {
    guard let raw = ProcessInfo.processInfo.environment["KIT_TYPE_DELAY_MS"], !raw.isEmpty else { return 10 }
    if raw.allSatisfy({ $0 >= "0" && $0 <= "9" }), raw.count <= 3, let n = Int(raw), n <= 500 { return n }
    FileHandle.standardError.write(
        "warning: KIT_TYPE_DELAY_MS=\"\(raw)\" is not a whole number of ms from 0 to 500; ignored, typing at 10 ms\n"
            .data(using: .utf8)!)
    return 10
}

// Pasteboard commands (F21): save and restore every item and type of a pasteboard around kit-ax.sh paste. The
// general pasteboard is the default; --name <name> picks a private named one, so a test never touches the person's.
let pasteboardSaveCap = 16 * 1_048_576

func pasteboard(_ name: String?) -> NSPasteboard {
    guard let name else { return .general }
    return NSPasteboard(name: NSPasteboard.Name(name))
}

// "--name <n>" and the options in `allowed` (each takes one value). Returns the name and the first allowed value.
func pasteboardOptions(_ rest: [String], allowed: [String]) -> (String?, String?) {
    var name: String?
    var value: String?
    var i = 0
    while i < rest.count {
        guard i + 1 < rest.count else { usage() }
        if rest[i] == "--name" { name = rest[i + 1] }
        else if allowed.contains(rest[i]) { value = rest[i + 1] }
        else { usage() }
        i += 2
    }
    return (name, value)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "key":
    guard args.count == 2 else { usage() }
    requireTrusted()
    let (code, flags) = parseCombo(args[1])
    post(code: code, flags: flags)
    // A global shortcut is often not delivered when this process exits at once after the post.
    usleep(settleAfterPostMicroseconds)
    print("posted \(args[1])")

case "type":
    guard args.count >= 2 else { usage() }
    var explicitDelayMs: Int?
    var then: String?
    var thenDelayMs = 0
    var allowed: Set<pid_t>?
    var dryRun = false
    var index = 2
    while index < args.count {
        switch args[index] {
        case "--front-pids":
            guard index + 1 < args.count else { usage() }
            let pids = args[index + 1].split(separator: ",").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            guard !pids.isEmpty, pids.count == args[index + 1].split(separator: ",").count else { usage() }
            allowed = Set(pids); index += 2
        case "--dry-run":
            dryRun = true; index += 1
        case "--delay-ms":
            guard index + 1 < args.count, let n = Int(args[index + 1]), n >= 0 else { usage() }
            explicitDelayMs = n; index += 2
        case "--then":
            guard index + 1 < args.count else { usage() }
            then = args[index + 1]; index += 2
        case "--then-delay-ms":
            guard index + 1 < args.count, let n = Int(args[index + 1]), n >= 0 else { usage() }
            thenDelayMs = n; index += 2
        default:
            usage()
        }
    }
    let delayMs = explicitDelayMs ?? envTypeDelayMs()
    requireTrusted()
    let thenKey = then.map(parseCombo)
    typeText(args[1], delayMs: delayMs, allowed: allowed, dryRun: dryRun)
    print(dryRun ? "dry run: nothing posted, \(args[1].count) characters checked" : "typed \(args[1].count) characters")
    if let (code, flags) = thenKey {
        if thenDelayMs > 0 && !dryRun { usleep(UInt32(thenDelayMs) * 1000) }
        // The last check: after the typing and the wait, right before the combination (Return, as a rule).
        requireFront(allowed, dryRun: dryRun, "before \(then ?? "the combination")", typed: args[1].count, total: args[1].count)
        if !dryRun { post(code: code, flags: flags) }
        print(dryRun ? "dry run: \(then ?? "") not posted" : "posted \(then ?? "")")
    }

case "pb-count":
    // The change count of a pasteboard (general unless --name). Needs no permission.
    let (name, _) = pasteboardOptions(Array(args.dropFirst()), allowed: [])
    print(pasteboard(name).changeCount)

case "pb-save":
    // Round C, F21. Prints two lines on stdout: a summary, then the base64 of a property list holding every item of
    // the pasteboard with every type's bytes (nothing is written to disk). Exit 4, nothing printed but a refusal,
    // when it holds more than pasteboardSaveCap bytes: the caller then does not touch the pasteboard.
    let (name, _) = pasteboardOptions(Array(args.dropFirst()), allowed: [])
    let board = pasteboard(name)
    var items: [[String: Data]] = []
    var bytes = 0
    var skipped = 0
    for item in board.pasteboardItems ?? [] {
        var entry: [String: Data] = [:]
        for type in item.types {
            if let data = item.data(forType: type) {
                entry[type.rawValue] = data
                bytes += data.count
            } else {
                skipped += 1
            }
        }
        if bytes > pasteboardSaveCap {
            print("refused: the pasteboard holds more than \(pasteboardSaveCap / 1_048_576) MB, so it cannot be saved and was not touched")
            exit(4)
        }
        items.append(entry)
    }
    guard let list = try? PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0) else {
        fail("could not serialize the pasteboard")
    }
    print("saved \(items.count) items, \(items.reduce(0) { $0 + $1.count }) types, \(bytes) bytes, \(skipped) types unreadable, change count \(board.changeCount)")
    print(list.base64EncodedString())

case "pb-restore":
    // Reads the base64 of pb-save on stdin and puts every item back. With --only-if-change-count N it does so only
    // when the pasteboard still has change count N (nothing else has copied since); otherwise it leaves the newer
    // contents alone and says so (exit 0).
    let (name, expected) = pasteboardOptions(Array(args.dropFirst()), allowed: ["--only-if-change-count"])
    let board = pasteboard(name)
    if let expected, let want = Int(expected), board.changeCount != want {
        print("not restored: something else was copied meanwhile (change count \(board.changeCount), expected \(want)); the newer contents were left alone")
        exit(0)
    }
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let raw = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)),
          let list = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [[String: Data]] else {
        fail("restore: stdin is not the output of pb-save")
    }
    let restored: [NSPasteboardItem] = list.map { entry in
        let item = NSPasteboardItem()
        for (type, data) in entry { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        return item
    }
    board.clearContents()
    if !restored.isEmpty && !board.writeObjects(restored) { fail("could not write the saved items back to the pasteboard") }
    print("restored \(restored.count) items")

case "trusted":
    if AXIsProcessTrusted() {
        print("trusted")
    } else {
        print("not trusted")
        exit(1)
    }

case "automation":
    guard args.count == 2 else { usage() }
    let descriptor = NSAppleEventDescriptor(bundleIdentifier: args[1])
    guard let target = descriptor.aeDesc else { fail("could not address \(args[1])") }
    // '****' is the wildcard event class and id: the question is about the app, not one event.
    let status = AEDeterminePermissionToAutomateTarget(
        target, AEEventClass(0x2A2A_2A2A), AEEventID(0x2A2A_2A2A), false)
    switch status {
    case 0:
        print("granted")
    case -1744:
        print("not asked yet (macOS asks the first time the kit controls it)")
        exit(3)
    case -1743:
        print("denied")
        exit(3)
    case -600:
        print("target not running, so macOS cannot say")
        exit(4)
    default:
        print("status \(status)")
        exit(1)
    }

default:
    usage()
}
