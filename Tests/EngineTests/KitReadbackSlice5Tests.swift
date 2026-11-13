import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// plan-5-t1, tester step, part D: the three readbacks of slice 5 (`kit-readback.sh quicktime-time`, `waveform-check`,
// `speech-assets`) and `kit-net.sh speech`. Written from the entry plan-5-t1 of plan-5-tasks.md, the feature map S4 and S8
// (S4.2, S4.5, S4.8), verify.md and the existing kit; no product source is read.
//
// Nothing here starts an app, QuickTime Player, nettop or the speech service. What runs: `bash -n`, the usage lines, and
// the pure runs on hand-written input: a scripting reply, an on-device answer, a nettop log, and a picture of bars that this
// test draws (CoreGraphics) beside a WAV file that this test writes by hand sample by sample (no ffmpeg, no kit table).
// Every expected value is written here by hand.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `kit-readback.sh quicktime-time [--from <file>]`: the live path pauses QuickTime Player's front document and asks
//     for its name and `current time` (text-checked, never run). `--from <file>` (test-only) reads that reply instead:
//     two lines, `document <name>` and `time <seconds>`. Prints `document <name>` and `time <seconds, one decimal>`,
//     exit 0; a reply that says Apple events are refused (`-1743`, "not authorized") is exit 3 with a line starting
//     `NEEDS A PERSON:`; `no document` or a reply with no number is exit 1.
//   - `kit-readback.sh speech-assets [--from <file>]`: the live path asks SFSpeechRecognizer for the system language's
//     `supportsOnDeviceRecognition` (text-checked, never run). `--from <file>` reads one line, `true <locale>` or
//     `false <locale>`. true prints `speech-assets true <locale>` and exits 0; false prints `NEEDS A PERSON: install that
//     language's on-device dictation` and exits 3; anything else is exit 1.
//   - `kit-readback.sh waveform-check <pane-shot> <audio> <start-s>`: the picture is the bars of the window the pane
//     shows (the whole waveform when the pane shows only the window). Prints `best <s> correlation <c>`, `earlier
//     <c|none>`, `later <c|none>` and writes compare-s4-waveform.txt in the run folder. Exit 0 when the best block of the
//     file (30 s blocks at 5 s steps, linear RMS a second) starts within 2 s of <start-s>, its correlation is at least 0.7
//     and it beats the block 30 s earlier and the block 30 s later (a missing block is skipped); exit 1 for a blank
//     picture, a flat one, or any miss; exit 4 when the shot is not a readable picture.
//   - `kit-net.sh speech <name> [--from <dir>]`: reads the full nettop log `<dir>/<name>.nettop.csv` (default run/net)
//     and every process whose name holds `speech`. Prints `SPEECH <process> <local> -> <peer> local|REMOTE` for each
//     connection; exit 1 when one is REMOTE (anything but 127.x, ::1 and localhost); exit 0 when the daemon is in the
//     log and none is REMOTE; no daemon line at all prints `NEEDS-A-PERSON: cannot attribute` and exits 3; no log exits 4.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let readbackScript = projectRoot.appendingPathComponent("scripts/kit-readback.sh").path
private let netScript = projectRoot.appendingPathComponent("scripts/kit-net.sh").path
private let readbackSwift = projectRoot.appendingPathComponent("scripts/kit-lib/readback.swift").path

// MARK: running things

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 300) throws -> Ran {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("kitrb5-out-" + UUID().uuidString)
    fm.createFile(atPath: out.path, contents: nil)
    defer { try? fm.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
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

private final class Cleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }
    func run() {
        lock.lock()
        let all = paths
        lock.unlock()
        for p in all { try? FileManager.default.removeItem(atPath: p) }
    }
}
private let cleanup = Cleanup()
private let cleanupRegistered: Void = { atexit { cleanup.run() } }()

private struct Rig: Sendable {
    let base: String
    var kit: String { base + "/sesame-kit-rb5" }
    var tmp: String { base + "/tmp" }
    var home: String { base + "/decoy-home" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": home, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
}

private func makeRig(tools: Bool = false) throws -> Rig {
    _ = cleanupRegistered
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-rb5-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let rig = Rig(base: made.resolvingSymlinksInPath().path)
    for dir in [rig.kit + "/run", rig.tmp, rig.home] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    if tools, let seed = toolSeed, fm.fileExists(atPath: seed.kit + "/run/bin") {
        try fm.copyItem(atPath: seed.kit + "/run/bin", toPath: rig.kit + "/run/bin")
    }
    cleanup.add(rig.base)
    return rig
}

/// One KIT_ROOT where the readback tool is compiled once (by a pure run that needs it), for every test to copy.
private let toolSeed: Rig? = {
    guard let rig = try? makeRig(), let png = try? makeBarsPicture(in: rig, name: "seed.png", heights: [0.5, 0.9, 0.3, 0.7]),
        let wav = try? writeWav(in: rig, name: "seed.wav", levels: (0..<40).map { _ in 0.5 }) else { return nil }
    _ = try? run("/bin/bash", [readbackScript, "waveform-check", png, wav, "0"], env: rig.env)
    return rig
}()

private func readback(_ rig: Rig, _ args: [String]) throws -> Ran { try run("/bin/bash", [readbackScript] + args, env: rig.env) }
private func net(_ rig: Rig, _ args: [String]) throws -> Ran { try run("/bin/bash", [netScript] + args, env: rig.env) }

private func readText(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

private func put(_ text: String, _ path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: a known clip and the picture of one of its windows, both made here by hand

/// The loudness of second i of the known clip, by a formula written here (period 23 s, so blocks 5 s apart differ).
private func level(_ i: Int) -> Double { 0.08 + 0.9 * Double((i * 7 + 3) % 23) / 22 }

/// A clip whose blocks 30 s apart are the same (period 30 s): no picture can beat the block 30 s earlier.
private func periodicLevel(_ i: Int) -> Double { 0.08 + 0.9 * Double((i * 11) % 30) / 29 }

/// A mono 16 kHz 16-bit WAV, one level a second (a 440 Hz sine at that amplitude), written byte by byte.
private func writeWav(in rig: Rig, name: String, levels: [Double]) throws -> String {
    let rate = 16000
    var samples = [Int16]()
    samples.reserveCapacity(levels.count * rate)
    for (sec, lv) in levels.enumerated() {
        for k in 0..<rate {
            let t: Double = Double(sec * rate + k) / Double(rate)
            let wave: Double = sin(2 * Double.pi * 440 * t)
            let amplitude: Double = lv * 0.8 * 32767
            samples.append(Int16(amplitude * wave))
        }
    }
    var d = Data()
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
    samples.withUnsafeBytes { d.append(contentsOf: $0) }
    let path = rig.tmp + "/" + name
    try d.write(to: URL(fileURLWithPath: path))
    return path
}

/// A picture of bars, one bar a value (a height from 0 to 1), dark on light, centred on a middle line, with a thin rule
/// at the top like the edge of a pane; returns the path.
private func makeBarsPicture(in rig: Rig, name: String, heights: [Double], blank: Bool = false) throws -> String {
    let w = 30 * 13 + 20, h = 140
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if !blank {
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 3, width: w, height: 1))
        for (i, v) in heights.enumerated() {
            let bar: Double = max(4.0, v * 100)
            let x: Double = Double(10 + i * 13)
            let y: Double = (Double(h) - bar) / 2 - 4
            ctx.fill(CGRect(x: x, y: y, width: 8.0, height: bar))
        }
    }
    let path = rig.tmp + "/" + name
    let url = URL(fileURLWithPath: path) as CFURL
    guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "bars", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "bars", code: 2) }
    return path
}

private func heights(from start: Int, of f: (Int) -> Double = level) -> [Double] { (start..<(start + 30)).map(f) }

/// The text of a nettop log (hand-written; the shape of kit-net.sh's own logs).
private let nettopHeader = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,"
private func ntProcess(_ s: Int, _ name: String, _ pid: Int) -> String { "10:00:\(String(format: "%02d", s)).100000,\(name).\(pid),,,0,64,0,0,0,,,,,,,,,,,," }
private func ntConn(_ s: Int, _ local: String, _ peer: String, v6: Bool = false) -> String {
    "10:00:\(String(format: "%02d", s)).100000,\(v6 ? "tcp6" : "tcp4") \(local)<->\(peer),en0,Established,0,64,0,0,0,10.00 ms,131072,131072,BE,-,cubic,-,-,-,-,so,"
}

// MARK: the suite

@Suite("KitReadbackSlice5Tests", .serialized)
struct KitReadbackSlice5Tests {

    @Test("bash -n on kit-readback.sh and kit-net.sh, and the usage lines name the new modes")
    func syntaxAndUsage() throws {
        for path in [readbackScript, netScript] {
            let r = try run("/bin/bash", ["-n", path])
            #expect(r.status == 0, "bash -n \(path): \(r.output)")
        }
        let rig = try makeRig()
        let u = try readback(rig, ["no-such-mode"])
        #expect(u.status == 2, "exit \(u.status): \(u.output)")
        for word in ["kit-readback.sh quicktime-time", "kit-readback.sh waveform-check <pane-shot> <audio> <start-s>", "kit-readback.sh speech-assets"] {
            #expect(u.output.contains(word), "the usage lacks `\(word)`:\n\(u.output)")
        }
        let n = try net(rig, ["no-such-mode"])
        #expect(n.status == 2, "exit \(n.status): \(n.output)")
        #expect(n.output.contains("kit-net.sh speech <name>"), "the usage of kit-net.sh lacks `kit-net.sh speech <name>`:\n\(n.output)")
        #expect(!n.output.contains("speech comes with the S8.8 check"), "kit-net.sh still says speech comes later")
    }

    // MARK: quicktime-time

    @Test("quicktime-time on a hand-written reply: the document and the time to one decimal, exit 0")
    func quicktimeReply() throws {
        let rig = try makeRig()
        try put("document sleep-interview.m4a\ntime 130.4172\n", rig.base + "/reply.txt")
        let r = try readback(rig, ["quicktime-time", "--from", rig.base + "/reply.txt"])
        #expect(r.status == 0, "exit \(r.status): \(r.output)")
        #expect(r.lines.contains("time 130.4"), "no `time 130.4` line:\n\(r.output)")
        #expect(r.lines.contains("document sleep-interview.m4a"), "no document line:\n\(r.output)")
    }

    @Test("quicktime-time: scripting refused is NEEDS A PERSON (exit 3), no document or no number is exit 1, extra arguments are exit 2")
    func quicktimeRefusals() throws {
        let rig = try makeRig()
        let cases: [(String, String, Int32)] = [
            ("error -1743 Not authorized to send Apple events to QuickTime Player.\n", "refused", 3),
            ("execution error: Not authorized to send Apple events to QuickTime Player. (-1743)\n", "refused long", 3),
            ("no document\n", "no document", 1),
            ("document a.m4a\ntime abc\n", "no number", 1),
            ("", "empty", 1),
        ]
        for (reply, label, want) in cases {
            try put(reply, rig.base + "/reply.txt")
            let r = try readback(rig, ["quicktime-time", "--from", rig.base + "/reply.txt"])
            #expect(r.status == want, "\(label): exit \(r.status), expected \(want):\n\(r.output)")
            if want == 3 { #expect(r.output.contains("NEEDS A PERSON:"), "\(label): no NEEDS A PERSON line:\n\(r.output)") }
        }
        #expect(try readback(rig, ["quicktime-time", "extra"]).status == 2)
        #expect(try readback(rig, ["quicktime-time", "--from"]).status == 2)
    }

    @Test("quicktime-time live path (text only, never run): pauses QuickTime Player, reads the front document's current time and name")
    func quicktimeLiveText() {
        let text = readText(readbackScript)
        #expect(text.contains("QuickTime Player"), "kit-readback.sh does not name QuickTime Player")
        #expect(text.contains("current time"), "the live path does not read `current time`")
        #expect(text.range(of: "pause", options: .caseInsensitive) != nil, "the live path does not pause QuickTime Player first")
        #expect(!text.contains("not built yet: quicktime-time"), "quicktime-time still says not built yet")
    }

    // MARK: speech-assets

    @Test("speech-assets on hand-written answers: true is exit 0, false is NEEDS A PERSON (exit 3), anything else exit 1")
    func speechAssets() throws {
        let rig = try makeRig()
        try put("true en_US\n", rig.base + "/a.txt")
        let yes = try readback(rig, ["speech-assets", "--from", rig.base + "/a.txt"])
        #expect(yes.status == 0 && yes.lines.contains("speech-assets true en_US"), "true: exit \(yes.status): \(yes.output)")
        try put("false en_US\n", rig.base + "/a.txt")
        let no = try readback(rig, ["speech-assets", "--from", rig.base + "/a.txt"])
        #expect(no.status == 3, "false: exit \(no.status): \(no.output)")
        #expect(no.output.contains("NEEDS A PERSON: install that language's on-device dictation"), "false: \(no.output)")
        try put("maybe\n", rig.base + "/a.txt")
        #expect(try readback(rig, ["speech-assets", "--from", rig.base + "/a.txt"]).status == 1)
        #expect(try readback(rig, ["speech-assets", "extra"]).status == 2)
    }

    @Test("speech-assets live path (text only, never run): the kit's Swift tool asks SFSpeechRecognizer for supportsOnDeviceRecognition")
    func speechAssetsLiveText() {
        let swift = readText(readbackSwift)
        #expect(swift.contains("supportsOnDeviceRecognition"), "readback.swift never reads supportsOnDeviceRecognition")
        #expect(swift.contains("SFSpeechRecognizer"), "readback.swift does not use SFSpeechRecognizer")
        #expect(!readText(readbackScript).contains("not built yet: speech-assets"))
    }

    // MARK: waveform-check

    @Test("waveform-check passes on the picture of the right block, within 2 s of the stated start, and writes compare-s4-waveform.txt")
    func waveformRight() throws {
        let rig = try makeRig(tools: true)
        let wav = try writeWav(in: rig, name: "known.wav", levels: (0..<120).map(level))
        let png = try makeBarsPicture(in: rig, name: "pane.png", heights: heights(from: 60))
        for (arg, want) in [("60", Int32(0)), ("62", 0), ("58", 0), ("65", 1), ("55", 1), ("90", 1)] {
            let r = try readback(rig, ["waveform-check", png, wav, arg])
            #expect(r.status == want, "stated start \(arg): exit \(r.status), expected \(want):\n\(r.output)")
            if arg == "60" {
                #expect(r.lines.contains { $0.hasPrefix("best 60 correlation") }, "no `best 60 correlation` line:\n\(r.output)")
                #expect(r.lines.contains { $0.hasPrefix("earlier ") } && r.lines.contains { $0.hasPrefix("later ") }, "no earlier and later lines:\n\(r.output)")
            }
        }
        let file = readText(rig.kit + "/run/compare-s4-waveform.txt")
        #expect(file.contains("best 60"), "compare-s4-waveform.txt does not say the best block starts at 60:\n\(file)")
    }

    @Test("waveform-check: the picture of the block 30 s earlier, bars that no block holds, a flat picture and a blank one all fail (exit 1)")
    func waveformWrong() throws {
        let rig = try makeRig(tools: true)
        let wav = try writeWav(in: rig, name: "known.wav", levels: (0..<120).map(level))
        let earlier = try makeBarsPicture(in: rig, name: "earlier.png", heights: heights(from: 30))
        #expect(try readback(rig, ["waveform-check", earlier, wav, "60"]).status == 1, "the picture of the block at 30 passed for 60")
        var noiseHeights: [Double] = []
        for i in 0..<30 {
            let step: Int = (i * i * 13 + 5) % 17
            noiseHeights.append(0.1 + 0.8 * Double(step) / 16.0)
        }
        let noise = try makeBarsPicture(in: rig, name: "noise.png", heights: noiseHeights)
        #expect(try readback(rig, ["waveform-check", noise, wav, "60"]).status == 1, "bars that match no block passed")
        let flat = try makeBarsPicture(in: rig, name: "flat.png", heights: Array(repeating: 0.6, count: 30))
        #expect(try readback(rig, ["waveform-check", flat, wav, "60"]).status == 1, "a flat picture passed")
        let blank = try makeBarsPicture(in: rig, name: "blank.png", heights: [], blank: true)
        let r = try readback(rig, ["waveform-check", blank, wav, "60"])
        #expect(r.status == 1, "a blank picture: exit \(r.status):\n\(r.output)")
    }

    @Test("waveform-check: when blocks 30 s apart are the same, no picture beats the block 30 s earlier (exit 1); the first block has no earlier one and can pass")
    func waveformBeatsNeighbours() throws {
        let rig = try makeRig(tools: true)
        let periodic = try writeWav(in: rig, name: "periodic.wav", levels: (0..<120).map(periodicLevel))
        let png = try makeBarsPicture(in: rig, name: "periodic.png", heights: heights(from: 60, of: periodicLevel))
        let r = try readback(rig, ["waveform-check", png, periodic, "60"])
        #expect(r.status == 1, "a picture that the block 30 s earlier matches as well passed: exit \(r.status):\n\(r.output)")
        let wav = try writeWav(in: rig, name: "known.wav", levels: (0..<120).map(level))
        let first = try makeBarsPicture(in: rig, name: "first.png", heights: heights(from: 0))
        let ok = try readback(rig, ["waveform-check", first, wav, "0"])
        #expect(ok.status == 0, "the first block of the file: exit \(ok.status):\n\(ok.output)")
        #expect(ok.lines.contains { $0 == "earlier none" }, "no `earlier none` for the first block:\n\(ok.output)")
    }

    @Test("waveform-check: a shot that is not a picture or does not exist is exit 4 (never a pass), a missing audio file is exit 1, bad arguments exit 2")
    func waveformInputs() throws {
        let rig = try makeRig(tools: true)
        let wav = try writeWav(in: rig, name: "known.wav", levels: (0..<60).map(level))
        try put("not a picture", rig.base + "/shot.png")
        #expect(try readback(rig, ["waveform-check", rig.base + "/shot.png", wav, "0"]).status == 4)
        #expect(try readback(rig, ["waveform-check", rig.base + "/missing.png", wav, "0"]).status == 4)
        let png = try makeBarsPicture(in: rig, name: "pane.png", heights: heights(from: 0))
        #expect(try readback(rig, ["waveform-check", png, rig.base + "/missing.wav", "0"]).status == 1)
        #expect(try readback(rig, ["waveform-check", png, wav]).status == 2)
        #expect(try readback(rig, ["waveform-check", png, wav, "abc"]).status == 2)
    }

    // MARK: kit-net.sh speech

    private func speechLog(_ rig: Rig, _ rows: [String]) throws {
        try put(([nettopHeader] + rows).joined(separator: "\n") + "\n", rig.base + "/s4.nettop.csv")
    }

    @Test("kit-net.sh speech: a daemon connection to a non-local host fails (exit 1) and says REMOTE")
    func speechRemote() throws {
        let rig = try makeRig()
        try speechLog(rig, [
            ntProcess(1, "SesameHelper", 6001), ntConn(1, "127.0.0.1:51000", "127.0.0.1:41002"),
            ntProcess(1, "speechrecognitiond", 777), ntConn(1, "192.168.1.5:50123", "93.184.216.34:443"),
        ])
        let r = try net(rig, ["speech", "s4", "--from", rig.base])
        #expect(r.status == 1, "exit \(r.status):\n\(r.output)")
        #expect(r.lines.contains { $0.hasPrefix("SPEECH speechrecognitiond") && $0.contains("93.184.216.34:443") && $0.hasSuffix("REMOTE") }, "no REMOTE line:\n\(r.output)")
    }

    @Test("kit-net.sh speech: a daemon that only talks to a local listener passes (exit 0), whatever a Sesame process does")
    func speechLocal() throws {
        let rig = try makeRig()
        try speechLog(rig, [
            ntProcess(1, "localspeechrecognition", 778), ntConn(1, "127.0.0.1:50999", "127.0.0.1:41002"),
            ntConn(2, "[::1].50111", "[::1].41002", v6: true),
            ntProcess(1, "SesameHelper", 6001), ntConn(1, "192.168.1.5:50124", "93.184.216.34:443"),
        ])
        let r = try net(rig, ["speech", "s4", "--from", rig.base])
        #expect(r.status == 0, "exit \(r.status):\n\(r.output)")
        #expect(r.lines.filter { $0.hasPrefix("SPEECH localspeechrecognition") }.allSatisfy { $0.hasSuffix("local") } && r.lines.contains { $0.hasPrefix("SPEECH localspeechrecognition") }, "lines:\n\(r.output)")
        #expect(!r.output.contains("REMOTE"), "a REMOTE line for a daemon that only talked locally:\n\(r.output)")
    }

    @Test("kit-net.sh speech: a daemon row with no connection passes; no daemon line at all prints NEEDS-A-PERSON: cannot attribute and exits 3; no log exits 4")
    func speechUnattributed() throws {
        let rig = try makeRig()
        try speechLog(rig, [ntProcess(1, "corespeechd", 779)])
        let none = try net(rig, ["speech", "s4", "--from", rig.base])
        #expect(none.status == 0, "a daemon with no connection: exit \(none.status):\n\(none.output)")
        try speechLog(rig, [ntProcess(1, "SesameHelper", 6001), ntConn(1, "127.0.0.1:51000", "127.0.0.1:41002"), ntProcess(1, "Safari", 5)])
        let lost = try net(rig, ["speech", "s4", "--from", rig.base])
        #expect(lost.status == 3, "no daemon line: exit \(lost.status):\n\(lost.output)")
        #expect(lost.output.contains("NEEDS-A-PERSON: cannot attribute"), "no cannot-attribute line:\n\(lost.output)")
        #expect(try net(rig, ["speech", "nolog", "--from", rig.base]).status == 4)
        #expect(try net(rig, ["speech"]).status == 2)
    }

    @Test("kit-net.sh speech reads the full nettop log, not the Sesame-scoped one, so `start` must keep the speech rows (text check)")
    func speechReadsFullLog() {
        let text = readText(netScript)
        #expect(text.contains("speech)") || text.contains("cmd_speech"), "kit-net.sh has no speech mode")
        #expect(text.contains(".nettop.csv"), "kit-net.sh never names the full nettop log")
    }
}
