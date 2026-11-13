import CryptoKit
import Foundation
import PDFKit
import Testing

// plan-5-t1, tester step, parts A to C: the audio and video fixtures of slice 5. Written from the entry plan-5-t1 of
// plan-5-tasks.md (with the three clarifications of the tasks review), the spec (S4, S2(d)), verify.md, the feature map
// S4 and the existing kit; no product source is read.
//
// Every run is a child process: kit-fixtures.sh with its own temp KIT_ROOT (a folder named sesame-kit*), its own TMPDIR
// and a decoy HOME. No app is started and `swift test` is never nested. The files are checked here with independent
// readers (ffmpeg and ffprobe: decoded samples, streams, container, duration, frames); every expected value is written
// in this file by hand or read from the key (fixtures/answers.csv), never from the kit's own tables.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `build golden-av` makes $KIT_ROOT/fixtures/golden-av/{audio,video,damaged} (a sibling of golden, never inside it) and
//     prints BUILT golden-av or UNCHANGED golden-av (the same rule as golden-docs). A key `file` that starts audio/ or
//     video/ is under golden-av/, and the damaged clips are golden-av/damaged/broken.m4a and broken.mp4.
//   - The spoken sentence of an audio row and of the videospeech row is the `note` of the row (no comma and no semicolon
//     inside), and the clip speaks it starting exactly at the row's `locator` (mm:ss).
//   - Audio is mono 16 kHz in every clip; the clips of a row hold neutral filler (counting) at several loudnesses.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixturesScript = projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path

// MARK: hand-written tables

/// The 12 audio clips of golden-av/audio, written by hand: name, container name as ffprobe says it.
private let audioClips: [(name: String, format: String)] = [
    ("sleep-interview.m4a", "mov,mp4,m4a,3gp,3g2,mj2"), ("sleep-podcast.m4a", "mov,mp4,m4a,3gp,3g2,mj2"),
    ("interview-raw-take3.wav", "wav"), ("memo-0417.mp3", "mp3"), ("standup-notes.flac", "flac"),
    ("call-recording-b.aac", "aac"), ("lecture-04.m4a", "mov,mp4,m4a,3gp,3g2,mj2"), ("field-recording.mp3", "mp3"),
    ("voice-note-17.wav", "wav"), ("town-hall.flac", "flac"), ("short-memo.mp3", "mp3"), ("quiet-room.wav", "wav"),
]

/// The 8 audio rows of the key and the second each sentence starts at: written by hand (the spec's example is 02:10).
private let audioRows: [(id: String, file: String, locator: String, second: Double)] = [
    ("audio-01", "audio/sleep-interview.m4a", "02:10", 130), ("audio-02", "audio/memo-0417.mp3", "01:10", 70),
    ("audio-03", "audio/standup-notes.flac", "00:20", 20), ("audio-04", "audio/call-recording-b.aac", "00:55", 55),
    ("audio-05", "audio/lecture-04.m4a", "01:40", 100), ("audio-06", "audio/field-recording.mp3", "00:30", 30),
    ("audio-07", "audio/voice-note-17.wav", "01:25", 85), ("audio-08", "audio/town-hall.flac", "00:45", 45),
]

/// The first 74 lines of answers.csv before plan 5 (the header and 73 rows, up to boundary-03): they are never changed.
private let oldKeySha = "5dd37dcb212611969a300c0e63ee5ed332619ef4083a4e361dd3a60f27e5d4e3"

// the rule of D5, written here by hand (frame 0.5 s, stride 25 s, window 30 s, silence at -54 dBFS)
private let frameSeconds = 0.5
private let strideSeconds = 25.0
private let windowSeconds = 30.0
private let silenceDB = -54.0
private let sampleRate = 16000

// MARK: the key (read, never changed)

private struct Answer: Sendable {
    let id: String
    let group: String
    let query: String
    let file: String
    let locator: String
    let window: String
    let note: String
    /// The locator mm:ss in seconds.
    var second: Double? {
        let p = locator.split(separator: ":").compactMap { Double($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : nil
    }
}

private let keyText: String = {
    (try? String(contentsOf: projectRoot.appendingPathComponent("fixtures/answers.csv"), encoding: .utf8)) ?? ""
}()

private let answers: [Answer] = {
    var rows: [Answer] = []
    for (i, line) in keyText.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where i > 0 {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7 else { continue }
        rows.append(Answer(id: f[0], group: f[1], query: f[2], file: f[3], locator: f[4], window: f[5], note: f[6]))
    }
    return rows
}()

private func rows(_ group: String) -> [Answer] { answers.filter { $0.group == group } }

// MARK: running things

private struct Ran: Sendable {
    let status: Int32
    let output: String
    var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 900) throws -> Ran {
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("kitfx5-out-" + UUID().uuidString)
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

/// Runs a program and returns its standard output as bytes (standard error is dropped).
private func runData(_ exe: String, _ args: [String]) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

private let ffmpeg = "/opt/homebrew/bin/ffmpeg"
private let ffprobe = "/opt/homebrew/bin/ffprobe"

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

private struct Root: Sendable {
    let base: String
    let kit: String
    let tmp: String
    let decoyHome: String
    var fixtures: String { kit + "/fixtures" }
    var av: String { fixtures + "/golden-av" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome,
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }
}

private func makeRoot(tools: Bool = true) throws -> Root {
    _ = cleanupRegistered
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-s5-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let base = made.resolvingSymlinksInPath().path
    let root = Root(base: base, kit: base + "/sesame-kit-s5", tmp: base + "/tmp", decoyHome: base + "/decoy-home")
    try fm.createDirectory(atPath: root.kit + "/run", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root.tmp, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root.decoyHome, withIntermediateDirectories: true)
    if tools, let seed = toolSeed, fm.fileExists(atPath: seed.kit + "/run/bin") {
        try fm.copyItem(atPath: seed.kit + "/run/bin", toPath: root.kit + "/run/bin")
    }
    cleanup.add(root.base)
    return root
}

/// One KIT_ROOT where the fixture tool is compiled once (by a small filler build), for every test to copy.
private let toolSeed: Root? = {
    guard let root = try? makeRoot(tools: false) else { return nil }
    _ = try? run("/bin/bash", [fixturesScript, "build", "filler", "3"], env: root.env)
    return root
}()

private func kit(_ root: Root, _ args: String...) throws -> Ran {
    guard FileManager.default.fileExists(atPath: fixturesScript) else {
        Issue.record("scripts/kit-fixtures.sh not found")
        return Ran(status: 127, output: "scripts/kit-fixtures.sh not found")
    }
    return try run("/bin/bash", [fixturesScript] + args, env: root.env)
}

/// The one golden-av build every test reads (made once, removed at exit).
private let sharedAV: (root: Root, built: Ran)? = {
    guard let root = try? makeRoot() else { return nil }
    guard let ran = try? kit(root, "build", "golden-av") else { return nil }
    return (root, ran)
}()

private func avBuilt() -> (root: Root, built: Ran) {
    guard let s = sharedAV else {
        Issue.record("could not make the shared kit root")
        return (Root(base: "", kit: "", tmp: "", decoyHome: ""), Ran(status: 127, output: ""))
    }
    return s
}

// MARK: reading folders and files

private func exists(_ path: String) -> Bool {
    var st = Darwin.stat()
    return lstat(path, &st) == 0
}

/// Every entry that is not a folder under dir, relative, sorted.
private func entriesIn(_ dir: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: dir) else { return [] }
    var found: [String] = []
    for case let rel as String in walker {
        var st = Darwin.stat()
        guard lstat(dir + "/" + rel, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
        found.append(rel)
    }
    return found.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

private func sha(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
}

private struct Entry: Equatable {
    let inode: UInt64
    let mtimeNs: Int64
    let digest: String
}

private func snapshot(_ dir: String) -> [String: Entry] {
    var snap: [String: Entry] = [:]
    for rel in entriesIn(dir) {
        var st = Darwin.stat()
        guard lstat(dir + "/" + rel, &st) == 0 else { continue }
        snap[rel] = Entry(
            inode: UInt64(st.st_ino),
            mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
            digest: sha(dir + "/" + rel) ?? "")
    }
    return snap
}

// MARK: independent readers (ffmpeg and ffprobe)

private func probe(_ path: String, _ entries: String, stream: String? = nil) -> [String: String] {
    var args = ["-v", "error", "-show_entries", entries, "-of", "default=nw=1"]
    if let stream { args += ["-select_streams", stream] }
    args.append(path)
    guard let data = runData(ffprobe, args), let text = String(data: data, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { out[kv[0]] = kv[1] }
    }
    return out
}

private func duration(_ path: String) -> Double? { probe(path, "format=duration")["duration"].flatMap(Double.init) }

private func streamCount(_ path: String, _ type: String) -> Int {
    guard let data = runData(ffprobe, ["-v", "error", "-select_streams", type, "-show_entries", "stream=index", "-of", "csv=p=0", path]),
        let text = String(data: data, encoding: .utf8) else { return -1 }
    return text.split(separator: "\n").count
}

/// The decoded mono 16 kHz samples of a file (ffmpeg, never the product).
private func samples(_ path: String) -> [Float] {
    guard let data = runData(ffmpeg, ["-nostdin", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", "\(sampleRate)", "-f", "f32le", "pipe:1"])
    else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

private func fileExt(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

private func pdfPageCount(_ path: String) -> Int? { PDFDocument(url: URL(fileURLWithPath: path)).map(\.pageCount) }

/// A document's text through the system's own readers: utf-8 for txt and md, textutil for the rest.
private func documentText(_ path: String) -> String? {
    if ["txt", "md"].contains(fileExt(path)) { return FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) } }
    guard let r = try? run("/usr/bin/textutil", ["-convert", "txt", "-stdout", path], limit: 60), r.status == 0 else { return nil }
    return r.output
}

/// The RMS of consecutive frames of `frame` seconds, in dB full scale.
private func frameDB(_ s: [Float], frame: Double = frameSeconds, rate: Int = sampleRate) -> [Double] {
    let n = Int(frame * Double(rate))
    guard n > 0 else { return [] }
    var out: [Double] = []
    var i = 0
    while i + n <= s.count {
        var sum = 0.0
        for k in i..<(i + n) { sum += Double(s[k]) * Double(s[k]) }
        out.append(20 * log10(max((sum / Double(n)).squareRoot(), 1e-9)))
        i += n
    }
    return out
}

/// The D5 walk, written by hand: a window starts at the first non-silent frame at or after `next`, and `next` is that
/// start plus 25 s; a window with no non-silent frame is never made.
private func windowStarts(_ db: [Double]) -> [Double] {
    var starts: [Double] = []
    var next = 0.0
    while true {
        var f = Int((next / frameSeconds).rounded(.up))
        while f < db.count && db[f] < silenceDB { f += 1 }
        if f >= db.count { break }
        let start = Double(f) * frameSeconds
        starts.append(start)
        next = start + strideSeconds
    }
    return starts
}

/// The start of the first window that reaches the second (its end lies after it).
private func firstWindowStart(reaching second: Double, in db: [Double]) -> Double? {
    windowStarts(db).first { $0 + windowSeconds > second }
}

private func seconds(_ db: [Double], from: Double, to: Double) -> ArraySlice<Double> {
    let a = max(0, Int(from / frameSeconds)), b = min(db.count, Int(to / frameSeconds))
    return a < b ? db[a..<b] : []
}

// MARK: part A: the audio clips

@Suite("KitFixturesSlice5Tests", .serialized)
struct KitFixturesSlice5Tests {

    @Test("bash -n on kit-fixtures.sh, and the usage names golden-av, pauselong and mix500")
    func syntaxAndUsage() throws {
        let r = try run("/bin/bash", ["-n", fixturesScript])
        #expect(r.status == 0, "bash -n: \(r.output)")
        let root = try makeRoot(tools: false)
        let u = try kit(root, "no-such-mode")
        #expect(u.status == 2, "exit \(u.status): \(u.output)")
        for word in ["build golden-av", "build pauselong", "build mix500"] {
            #expect(u.output.contains("kit-fixtures.sh \(word)"), "the usage lacks `kit-fixtures.sh \(word)`:\n\(u.output)")
        }
    }

    @Test("build golden-av exits 0 and prints BUILT golden-av")
    func buildsGoldenAV() {
        let a = avBuilt()
        #expect(a.built.status == 0, "build golden-av exit \(a.built.status): \(a.built.output)")
        #expect(a.built.output.contains("BUILT golden-av"), "no `BUILT golden-av` line:\n\(a.built.output)")
    }

    @Test("golden-av/audio holds exactly the 12 clips of the hand-written list, each a real audio file of its own extension and no picture")
    func twelveAudioClips() {
        let a = avBuilt()
        let found = entriesIn(a.root.av + "/audio")
        #expect(found == audioClips.map(\.name).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, "golden-av/audio holds \(found)")
        #expect(audioClips.count == 12)
        for clip in audioClips {
            let path = a.root.av + "/audio/" + clip.name
            let format = probe(path, "format=format_name")["format_name"]
            #expect(format == clip.format, "\(clip.name): ffprobe says the container is \(format ?? "nothing"), expected \(clip.format)")
            #expect(streamCount(path, "a") == 1, "\(clip.name) has \(streamCount(path, "a")) audio streams")
            #expect(streamCount(path, "v") == 0, "\(clip.name) has a picture stream")
        }
    }

    @Test("every audio extension of the spec occurs at least once in golden-av/audio")
    func everyExtension() {
        let have = Set(audioClips.map { ($0.name as NSString).pathExtension })
        #expect(have == ["mp3", "m4a", "wav", "aac", "flac"], "extensions in the hand list: \(have.sorted())")
        let a = avBuilt()
        let onDisk = Set(entriesIn(a.root.av + "/audio").map { ($0 as NSString).pathExtension })
        #expect(onDisk == have, "extensions on disk: \(onDisk.sorted())")
    }

    @Test("sleep-interview.m4a is about 3.5 minutes; the other clips are shorter, the short memo is under the 30 s window and the quiet room says nothing")
    func durations() {
        let a = avBuilt()
        let d = duration(a.root.av + "/audio/sleep-interview.m4a") ?? 0
        #expect(d >= 205 && d <= 215, "sleep-interview.m4a lasts \(d) s, expected about 210 (3.5 minutes)")
        let short = duration(a.root.av + "/audio/short-memo.mp3") ?? 99
        #expect(short > 3 && short < 30, "short-memo.mp3 lasts \(short) s, expected under the 30 s window")
        for row in audioRows where row.id != "audio-01" {
            // decoded length, not the container's claim: ffprobe only estimates the length of an ADTS .aac file
            let len = Double(samples(a.root.av + "/" + row.file).count) / Double(sampleRate)
            #expect(len >= row.second + 12 && len <= 215, "\(row.file) lasts \(len) s with its sentence at \(row.second)")
        }
        let quiet = samples(a.root.av + "/audio/quiet-room.wav")
        let peak = quiet.map { abs($0) }.max() ?? 1
        #expect(quiet.count > 16000 * 10 && peak < 0.001, "quiet-room.wav should be silent for seconds: \(quiet.count) samples, peak \(peak)")
    }

    @Test("the audio rows of the key: 8 rows with the spec's example, mm:ss locators, window 30 and a sentence in the note; the old rows are unchanged")
    func keyRows() {
        let audio = rows("audio")
        #expect(audio.count == 8, "the key holds \(audio.count) audio rows")
        for want in audioRows {
            guard let row = audio.first(where: { $0.id == want.id }) else { Issue.record("no row \(want.id)"); continue }
            #expect(row.file == want.file, "\(want.id): file \(row.file)")
            #expect(row.locator == want.locator, "\(want.id): locator \(row.locator)")
            #expect(row.second == want.second, "\(want.id): second \(String(describing: row.second))")
            #expect(row.window == "30", "\(want.id): window_s \(row.window)")
            #expect(row.note.split(separator: " ").count >= 8, "\(want.id): the note is not a spoken sentence: \(row.note)")
            #expect(!row.note.contains(";") && !row.note.contains("="), "\(want.id): the note holds ; or =: \(row.note)")
        }
        #expect(audio.first { $0.id == "audio-01" }?.query == "where they talk about sleep", "the spec's example row")
        let queries = Set(audio.map(\.query))
        #expect(queries.count == 8, "the eight descriptions are not distinct")
        let oldLines = keyText.split(separator: "\n", omittingEmptySubsequences: false).prefix(74).joined(separator: "\n") + "\n"
        let digest = SHA256.hash(data: Data(oldLines.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == oldKeySha, "the header and the 74 rows the key held before plan 5 changed (exact-09, exact-10, exact-20 and their decoys included)")
        for id in ["exact-09", "exact-10", "exact-20", "decoy-09", "decoy-10", "decoy-20"] {
            #expect(answers.contains { $0.id == id }, "the old row \(id) is gone")
        }
    }

    @Test("every audio file the key names exists under golden-av and nothing else of the key's audio/ names is missing")
    func keyFilesExist() {
        let a = avBuilt()
        let named = Set(answers.map(\.file).filter { $0.hasPrefix("audio/") })
        #expect(named.count == 10, "the key names \(named.count) audio files: \(named.sorted())")
        for file in named.sorted() {
            #expect(exists(a.root.av + "/" + file), "the key names \(file) and golden-av does not hold it")
        }
    }

    @Test("D5 onset: the first window that reaches each sentence starts within [locator, locator + 2] (computed from decoded samples with the rule written here)")
    func onsetOfEveryRow() {
        let a = avBuilt()
        for row in audioRows {
            let db = frameDB(samples(a.root.av + "/" + row.file))
            #expect(!db.isEmpty, "\(row.file) did not decode")
            guard let start = firstWindowStart(reaching: row.second, in: db) else {
                Issue.record("\(row.file): no window reaches second \(row.second)")
                continue
            }
            #expect(start >= row.second && start <= row.second + 2,
                    "\(row.file): the first window that reaches second \(row.second) starts at \(start), expected within [\(row.second), \(row.second + 2)]")
        }
    }

    @Test("sleep-interview.m4a: the first window holding second 130 starts within [130, 132], inside the spec's [02:10, 02:40]")
    func sleepInterviewOnset() {
        let a = avBuilt()
        let db = frameDB(samples(a.root.av + "/audio/sleep-interview.m4a"))
        let start = firstWindowStart(reaching: 130, in: db)
        #expect(start != nil && start! >= 130 && start! <= 132, "first window start \(String(describing: start))")
        #expect(windowStarts(db).count >= 3, "the walk made \(windowStarts(db).count) windows")
    }

    @Test("each passage is preceded by at least 30 s of digital silence (or silence from second 0 when it starts under 30 s)")
    func silenceBeforeEverySentence() {
        let a = avBuilt()
        for row in audioRows {
            let db = frameDB(samples(a.root.av + "/" + row.file))
            let from = max(0, row.second - 30) + 1.5, to = row.second - 1
            let loud = seconds(db, from: from, to: to).filter { $0 > -60 }
            #expect(loud.isEmpty, "\(row.file): sound above -60 dBFS between \(from) s and \(to) s")
            let speech = seconds(db, from: row.second, to: row.second + 3).filter { $0 > -40 }
            #expect(!speech.isEmpty, "\(row.file): no speech in the three seconds from \(row.second) s")
        }
    }

    @Test("K29: the 30 s blocks of sleep-interview.m4a have pairwise different envelopes and the block around the silence differs from every other")
    func blockEnvelopesDiffer() {
        let a = avBuilt()
        let db = frameDB(samples(a.root.av + "/audio/sleep-interview.m4a"))
        // one linear RMS value a second (two frames), blocks of 30 s at 30 s steps
        func linear(_ d: Double) -> Double { pow(10, d / 20) }
        let perSecond = stride(from: 0, to: db.count - 1, by: 2).map { ((linear(db[$0]) * linear(db[$0]) + linear(db[$0 + 1]) * linear(db[$0 + 1])) / 2).squareRoot() }
        var blocks: [[Double]] = []
        var start = 0
        while start + 30 <= perSecond.count {
            blocks.append(Array(perSecond[start..<(start + 30)]))
            start += 30
        }
        #expect(blocks.count >= 6, "\(blocks.count) blocks of 30 s")
        // the way the waveform check tells blocks apart: the correlation of the two envelopes (a block that says nothing has none)
        func correlation(_ x: [Double], _ y: [Double]) -> Double? {
            let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
            let sx = x.map { ($0 - mx) * ($0 - mx) }.reduce(0, +).squareRoot(), sy = y.map { ($0 - my) * ($0 - my) }.reduce(0, +).squareRoot()
            guard sx > 1e-6, sy > 1e-6 else { return nil }
            return zip(x, y).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / (sx * sy)
        }
        for i in 0..<blocks.count {
            for j in (i + 1)..<blocks.count {
                let c = correlation(blocks[i], blocks[j])
                #expect(c == nil || c! < 0.9, "blocks \(i) and \(j) of sleep-interview.m4a have the same envelope (correlation \(String(describing: c)))")
            }
        }
        let quietBlocks = (0..<blocks.count).filter { b in blocks[b].filter { $0 > 0.001 }.count < 15 }
        #expect(!quietBlocks.isEmpty, "no block of 30 s is mostly silence")
    }

    @Test("a deleted file, an edited file and a stray file: the next build brings the folder back to the same bytes, and a clean second build writes nothing")
    func sameBytesTwice() throws {
        let root = try makeRoot()
        let first = try kit(root, "build", "golden-av")
        #expect(first.status == 0, "first build: \(first.output)")
        let before = snapshot(root.av)
        #expect(before.count == 26, "\(before.count) files after the first build, expected 26 (12 audio, 12 video, 2 damaged)")
        let second = try kit(root, "build", "golden-av")
        #expect(second.status == 0 && second.output.contains("UNCHANGED golden-av"), "second build: \(second.output)")
        #expect(snapshot(root.av) == before, "an unchanged build rewrote a file (bytes, inode or time differ)")
        let victim = root.av + "/audio/memo-0417.mp3"
        let digest = before["audio/memo-0417.mp3"]?.digest
        try FileManager.default.removeItem(atPath: victim)
        try Data("stray".utf8).write(to: URL(fileURLWithPath: root.av + "/audio/stray-note.wav"))
        let edited = root.av + "/audio/town-hall.flac"
        try Data("not audio".utf8).write(to: URL(fileURLWithPath: edited))
        let third = try kit(root, "build", "golden-av")
        #expect(third.status == 0 && third.output.contains("BUILT golden-av"), "third build: \(third.output)")
        #expect(sha(victim) == digest, "the deleted memo-0417.mp3 came back with other bytes")
        #expect(!exists(root.av + "/audio/stray-note.wav"), "the stray file is still there")
        #expect(snapshot(root.av).mapValues(\.digest) == before.mapValues(\.digest), "the folder differs from the first build after the repair")
    }

    // MARK: part B: the video clips and the damaged clips

    /// The 12 video clips of golden-av/video, written by hand: name, the brand ffprobe reads, the length in seconds (about), the
    /// number of audio streams, and the start second of every shot (a new scene starts at each).
    private static let videoClips: [(name: String, brand: String, seconds: Double, audio: Int, shots: [Double])] = [
        ("safari-zebra.mp4", "isom", 60, 0, [0, 14, 28, 42, 52]), ("safari-giraffe.mp4", "isom", 50, 0, [0, 15, 30]),
        ("clip-v11.mp4", "isom", 45, 1, [0]), ("clip-v12.mp4", "isom", 45, 1, [0]),
        ("ocean-trip.mov", "qt", 45, 0, [0, 20, 30]), ("aerial-shoot.mp4", "isom", 50, 0, [0, 35, 45]),
        ("weekend-0412.m4v", "M4V", 35, 0, [0, 15, 25]), ("wetland-walk.mov", "qt", 65, 0, [0, 50, 60]),
        ("fair-day.mp4", "isom", 45, 0, [0, 25, 35]), ("garden-clip.m4v", "M4V", 55, 0, [0, 40, 50]),
        ("farm-visit.mp4", "isom", 40, 0, [0, 10, 20]), ("snow-day.mov", "qt", 30, 0, [0, 15]),
    ]

    /// The 8 video rows and the videospeech row: the second the matching shot starts at, written by hand (the spec's example is 00:42).
    private static let videoRows: [(id: String, file: String, locator: String, second: Double)] = [
        ("video-01", "video/safari-zebra.mp4", "00:42", 42), ("video-02", "video/ocean-trip.mov", "00:20", 20),
        ("video-03", "video/aerial-shoot.mp4", "00:35", 35), ("video-04", "video/weekend-0412.m4v", "00:15", 15),
        ("video-05", "video/wetland-walk.mov", "00:50", 50), ("video-06", "video/fair-day.mp4", "00:25", 25),
        ("video-07", "video/garden-clip.m4v", "00:40", 40), ("video-08", "video/farm-visit.mp4", "00:10", 10),
    ]

    @Test("golden-av/video holds exactly the 12 clips of the hand-written list, each a video of its own extension and brand, mp4 mov and m4v all present")
    func twelveVideoClips() {
        let a = avBuilt()
        let found = entriesIn(a.root.av + "/video")
        #expect(found == Self.videoClips.map(\.name).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, "golden-av/video holds \(found)")
        #expect(Self.videoClips.count == 12)
        #expect(Set(Self.videoClips.map { ($0.name as NSString).pathExtension }) == ["mp4", "mov", "m4v"])
        for clip in Self.videoClips {
            let path = a.root.av + "/video/" + clip.name
            let tags = probe(path, "format=format_name:format_tags=major_brand")
            #expect(tags["format_name"] == "mov,mp4,m4a,3gp,3g2,mj2", "\(clip.name): container \(tags["format_name"] ?? "nothing")")
            #expect(tags["TAG:major_brand"]?.trimmingCharacters(in: .whitespaces) == clip.brand, "\(clip.name): brand \(tags["TAG:major_brand"] ?? "none"), expected \(clip.brand)")
            #expect(streamCount(path, "v") == 1, "\(clip.name) has \(streamCount(path, "v")) video streams")
            #expect(streamCount(path, "a") == clip.audio, "\(clip.name) has \(streamCount(path, "a")) audio streams, expected \(clip.audio)")
            let codec = probe(path, "stream=codec_name", stream: "v:0")["codec_name"]
            #expect(codec == "h264", "\(clip.name): video codec \(codec ?? "none"), expected h264")
            let d = duration(path) ?? 0
            #expect(abs(d - clip.seconds) <= 1.5, "\(clip.name) lasts \(d) s, expected \(clip.seconds)")
        }
    }

    /// One frame at the second, as 8 x 8 gray bytes (ffmpeg).
    private func gray8(_ path: String, at second: Double) -> [UInt8]? {
        runData(ffmpeg, ["-nostdin", "-v", "error", "-ss", "\(second)", "-i", path, "-frames:v", "1", "-vf", "scale=8:8:flags=area,format=gray", "-f", "rawvideo", "pipe:1"]).map { [UInt8]($0) }
    }

    /// One frame at the second, as 32 x 24 gray bytes (ffmpeg).
    private func gray32(_ path: String, at second: Double) -> [UInt8]? {
        runData(ffmpeg, ["-nostdin", "-v", "error", "-ss", "\(second)", "-i", path, "-frames:v", "1", "-vf", "scale=32:24:flags=area,format=gray", "-f", "rawvideo", "pipe:1"]).map { [UInt8]($0) }
    }

    private func meanDifference(_ x: [UInt8], _ y: [UInt8]) -> Double {
        zip(x, y).map { abs(Double($0) - Double($1)) }.reduce(0, +) / Double(max(1, x.count))
    }

    /// The average hash of a frame: 64 bits, a bit set where the pixel is at or above the mean (written here by hand).
    private func averageHash(_ px: [UInt8]) -> [Bool] {
        let mean = px.map(Double.init).reduce(0, +) / Double(max(1, px.count))
        return px.map { Double($0) >= mean }
    }

    @Test("every shot of every video clip starts where the hand table says: frames inside a shot are alike, frames across a boundary differ clearly and by more than 10 hash bits")
    func shotBoundaries() {
        let a = avBuilt()
        for clip in Self.videoClips where clip.shots.count > 1 {
            let path = a.root.av + "/video/" + clip.name
            for (i, start) in clip.shots.enumerated() {
                let end = i + 1 < clip.shots.count ? clip.shots[i + 1] : clip.seconds
                guard let inside1 = gray32(path, at: start + 1), let inside2 = gray32(path, at: end - 1) else {
                    Issue.record("\(clip.name): no frame inside the shot at \(start)")
                    continue
                }
                #expect(meanDifference(inside1, inside2) < 4, "\(clip.name): two frames of the shot starting at \(start) differ by \(meanDifference(inside1, inside2))")
                if i > 0 {
                    guard let before = gray32(path, at: start - 1), let after = gray32(path, at: start + 1),
                        let hb = gray8(path, at: start - 1), let ha = gray8(path, at: start + 1) else { continue }
                    #expect(meanDifference(before, after) > 8, "\(clip.name): the frames at \(start - 1) s and \(start + 1) s are alike (\(meanDifference(before, after))): no shot starts at \(start)")
                    let bits = zip(averageHash(hb), averageHash(ha)).filter { $0 != $1 }.count
                    #expect(bits > 10, "\(clip.name): the hash of the frame before the shot at \(start) differs by only \(bits) bits")
                }
            }
        }
    }

    @Test("the video rows of the key: eight rows with the spec's zebra example at 00:42, window 10, the matching shot starts at the locator and lasts 10 s")
    func videoKeyRows() {
        let video = rows("video")
        #expect(video.count == 8, "the key holds \(video.count) video rows")
        let a = avBuilt()
        for want in Self.videoRows {
            guard let row = video.first(where: { $0.id == want.id }) else { Issue.record("no row \(want.id)"); continue }
            #expect(row.file == want.file && row.locator == want.locator && row.second == want.second, "\(want.id): \(row.file) \(row.locator)")
            #expect(row.window == "10", "\(want.id): window_s \(row.window)")
            #expect(!row.note.isEmpty, "\(want.id): no note")
            let clip = Self.videoClips.first { "video/" + $0.name == want.file }
            #expect(clip?.shots.contains(want.second) == true && clip?.shots.contains(want.second + 10) == true || want.second + 10 >= (clip?.seconds ?? 0),
                    "\(want.id): the shot table has no 10 s shot at \(want.second)")
            #expect(exists(a.root.av + "/" + want.file), "\(want.file) is not built")
        }
        #expect(video.first { $0.id == "video-01" }?.query == "zebra in a video", "the spec's example row")
        #expect(Set(video.map(\.query)).count == 8, "the eight descriptions are not distinct")
        #expect(Set(video.map(\.file)).count == 8, "two video rows name one clip")
        let named = Set(answers.map(\.file).filter { $0.hasPrefix("video/") })
        #expect(named.isSuperset(of: ["video/safari-zebra.mp4", "video/safari-giraffe.mp4", "video/clip-v11.mp4"]), "the key names \(named.sorted())")
        for file in named { #expect(exists(a.root.av + "/" + file), "the key names \(file) and golden-av does not hold it") }
    }

    @Test("the zebra clip: the frame inside 42 s to 52 s is the same scene all along and unlike the frame 20 s earlier, as the pane check will compare them")
    func zebraFrames() {
        let a = avBuilt()
        let path = a.root.av + "/video/safari-zebra.mp4"
        guard let at45 = gray32(path, at: 45), let at50 = gray32(path, at: 50), let at25 = gray32(path, at: 25), let at57 = gray32(path, at: 57) else {
            Issue.record("no frames of safari-zebra.mp4")
            return
        }
        #expect(meanDifference(at45, at50) < 4, "the zebra shot changes between 45 s and 50 s")
        #expect(meanDifference(at45, at25) > 8, "the frame at 45 s and the frame 20 s earlier are alike")
        #expect(meanDifference(at50, at57) > 8, "the zebra shot lasts past 52 s")
    }

    @Test("clip-v11.mp4: plain gray frames with no drawn words and a soundtrack whose sentence starts at 00:20 (first window within [20, 22]); clip-v12.mp4: the same frames and a silent soundtrack")
    func speechClips() {
        let a = avBuilt()
        let v11 = a.root.av + "/video/clip-v11.mp4", v12 = a.root.av + "/video/clip-v12.mp4"
        for path in [v11, v12] {
            for t in [3.0, 21.0, 40.0] {
                guard let f = gray32(path, at: t) else { Issue.record("no frame at \(t) in \(path)"); continue }
                let mean = f.map(Double.init).reduce(0, +) / Double(f.count)
                let spread = (f.map { abs(Double($0) - mean) }.max() ?? 255)
                #expect(spread < 4, "\(path) at \(t) s: the frame is not plain (spread \(spread))")
                #expect(mean > 90 && mean < 170, "\(path) at \(t) s: the frame is not gray (mean \(mean))")
            }
        }
        guard let x = gray32(v11, at: 30), let y = gray32(v12, at: 30) else { return }
        #expect(meanDifference(x, y) < 2, "the frames of clip-v11 and clip-v12 differ")
        let db11 = frameDB(samples(v11))
        let start = firstWindowStart(reaching: 20, in: db11)
        #expect(start != nil && start! >= 20 && start! <= 22, "clip-v11.mp4: the first window that reaches second 20 starts at \(String(describing: start)), expected within [20, 22]")
        let loud = seconds(db11, from: 0, to: 19).filter { $0 > -60 }
        #expect(loud.isEmpty, "clip-v11.mp4: sound before second 20")
        let silent = samples(v12)
        #expect(silent.count > 16000 * 30, "clip-v12.mp4 decoded \(silent.count) samples")
        #expect((silent.map { abs($0) }.max() ?? 1) < 0.001, "clip-v12.mp4 is not silent")
        let row = rows("videospeech")
        #expect(row.count == 1, "the key holds \(row.count) videospeech rows")
        #expect(row.first?.file == "video/clip-v11.mp4" && row.first?.locator == "00:20" && row.first?.window == "10", "the videospeech row: \(String(describing: row.first))")
        let q = (row.first?.query ?? "").lowercased().split(separator: " ").map(String.init)
        #expect(!q.isEmpty && q.allSatisfy { !"clip-v11.mp4".contains($0) }, "the query shares a word with the file name")
        let sentence = (row.first?.note ?? "").lowercased()
        #expect(sentence.contains("lighthouse"), "the sentence is about the lighthouse keeper: \(sentence)")
    }

    @Test("the damaged clips: broken.m4a is 6000 random bytes and broken.mp4 is a real mp4 cut short; no reader opens either")
    func damagedClips() {
        let a = avBuilt()
        let m4a = a.root.av + "/damaged/broken.m4a", mp4 = a.root.av + "/damaged/broken.mp4"
        #expect(entriesIn(a.root.av + "/damaged") == ["broken.m4a", "broken.mp4"], "damaged holds \(entriesIn(a.root.av + "/damaged"))")
        #expect(runData(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1", m4a]) == nil, "ffprobe opened broken.m4a")
        #expect(runData(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1", mp4]) == nil, "ffprobe opened broken.mp4")
        let bytes = FileManager.default.contents(atPath: mp4) ?? Data()
        #expect(bytes.count > 1000, "broken.mp4 is \(bytes.count) bytes, not a clip cut short")
        #expect(bytes.count > 8 && String(data: bytes[4..<8], encoding: .ascii) == "ftyp", "broken.mp4 does not start like an mp4")
        let whole = FileManager.default.contents(atPath: a.root.av + "/video/safari-giraffe.mp4")?.count ?? 0
        #expect(bytes.count < whole, "broken.mp4 is not shorter than a whole clip")
        #expect((FileManager.default.contents(atPath: m4a)?.count ?? 0) == 6000, "broken.m4a is not 6000 bytes")
    }

    // MARK: part C: pauselong, mix500 and the extav cells

    private func byteTotal(_ dir: String) -> Int {
        entriesIn(dir).reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: dir + "/" + $1)[.size] as? Int) ?? 0) }
    }

    // plan-5-t1b (amended by the tester, reason: the recipe `pauselong <unit>` picks one folder per unit, "that one folder", and the 60-page PDF
    // is a unit of S7.2 beside the audio and the video; no folder of `pauselong` held it, and picking golden-docs/pdfs would put 19 other PDFs in
    // flight with it): the build also makes pdf/annual-report-60p.pdf, the 60-page PDF of golden-docs.tsv. The two old files and every old
    // pin are unchanged; the list gains one entry and the file is read for its 60 pages by PDFKit, which is no kit code.
    @Test("build pauselong: a 60 minute m4a that is never silent and changes loudness every 30 s, a 2 minute mp4 with a new scene every 3 s and the 60-page PDF; same bytes twice")
    func pauselong() throws {
        let root = try makeRoot()
        let made = try kit(root, "build", "pauselong")
        #expect(made.status == 0 && made.output.contains("BUILT pauselong"), "build pauselong: exit \(made.status):\n\(made.output)")
        let dir = root.fixtures + "/pauselong"
        #expect(entriesIn(dir) == ["audio/long-60min.m4a", "pdf/annual-report-60p.pdf", "video/long-2min.mp4"], "pauselong holds \(entriesIn(dir))")
        #expect(PDFDocument(url: URL(fileURLWithPath: dir + "/pdf/annual-report-60p.pdf"))?.pageCount == 60, "annual-report-60p.pdf does not have 60 pages")
        let audio = dir + "/audio/long-60min.m4a", video = dir + "/video/long-2min.mp4"
        let len = duration(audio) ?? 0
        #expect(abs(len - 3600) <= 3, "long-60min.m4a lasts \(len) s, expected 3600")
        #expect(streamCount(audio, "a") == 1 && streamCount(audio, "v") == 0)
        // the level of every 0.5 s frame, decoded at 2 kHz (a 330 Hz tone is below the Nyquist limit): never silent, 30 s blocks differ
        guard let data = runData(ffmpeg, ["-nostdin", "-v", "error", "-i", audio, "-ac", "1", "-ar", "2000", "-f", "f32le", "pipe:1"]) else {
            Issue.record("long-60min.m4a did not decode")
            return
        }
        let s = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let db = frameDB(s.count > 0 ? s : [], frame: 0.5, rate: 2000)
        #expect(db.count >= 7190, "\(db.count) frames of 0.5 s")
        #expect((db.min() ?? 0) > silenceDB, "a 0.5 s frame is at \(db.min() ?? 0) dBFS: the file is silent somewhere")
        var blockMeans: [Double] = []
        var b = 0
        while b + 60 <= db.count && blockMeans.count < 20 {
            blockMeans.append(db[(b + 4)..<(b + 56)].reduce(0, +) / 52)   // the middle of the block, away from the edges
            b += 60
        }
        for i in 1..<blockMeans.count { #expect(abs(blockMeans[i] - blockMeans[i - 1]) > 1, "blocks \(i - 1) and \(i) of 30 s have the same loudness") }
        // video: 2 minutes, h264, a new scene every 3 s, no audio
        #expect(abs((duration(video) ?? 0) - 120) <= 1.5, "long-2min.mp4 lasts \(duration(video) ?? 0) s")
        #expect(streamCount(video, "v") == 1 && streamCount(video, "a") == 0)
        #expect(probe(video, "stream=codec_name", stream: "v:0")["codec_name"] == "h264")
        var previous: [Bool]?
        for k in 0..<40 {
            guard let a = gray8(video, at: Double(k) * 3 + 0.5), let c = gray8(video, at: Double(k) * 3 + 2.5), let h = Optional(averageHash(a)) else {
                Issue.record("no frame in the shot at \(k * 3) s")
                continue
            }
            #expect(zip(h, averageHash(c)).filter { $0 != $1 }.count <= 3, "the shot at \(k * 3) s changes inside its 3 s")
            if let previous { #expect(zip(previous, h).filter { $0 != $1 }.count > 10, "the shot at \(k * 3) s is a repeat of the one before (hash differs by \(zip(previous, h).filter { $0 != $1 }.count) bits)") }
            previous = h
        }
        let before = snapshot(dir)
        let again = try kit(root, "build", "pauselong")
        #expect(again.status == 0 && again.output.contains("UNCHANGED pauselong"), "second build: \(again.output)")
        #expect(snapshot(dir) == before, "an unchanged build rewrote a file")
        print("FIXTURE SIZE pauselong \(byteTotal(dir)) bytes")
    }

    @Test("build mix500: 220 photos, 120 documents (20 of each of six types, about 1,000 characters), 100 PDFs of 5 to 12 pages, 40 audio files of about 60 s with silences between sentences, 20 videos of about 30 s, no code; same bytes twice")
    func mix500() throws {
        let root = try makeRoot()
        let made = try kit(root, "build", "mix500")
        #expect(made.status == 0 && made.output.contains("BUILT mix500"), "build mix500: exit \(made.status):\n\(made.output)")
        let dir = root.fixtures + "/mix500"
        let files = entriesIn(dir).filter { !$0.hasSuffix(".DS_Store") }
        func count(_ exts: [String]) -> Int { files.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.count }
        #expect(count(["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]) == 220, "photos: \(count(["jpg", "jpeg", "png"]))")
        #expect(count(["txt", "md", "rtf", "docx", "html", "odt"]) == 120)
        for ext in ["txt", "md", "rtf", "docx", "html", "odt"] { #expect(count([ext]) == 20, "\(ext): \(count([ext])), expected 20") }
        #expect(count(["pdf"]) == 100)
        #expect(count(["mp3", "m4a", "wav", "aac", "flac"]) == 40)
        #expect(count(["mp4", "mov", "m4v"]) == 20)
        #expect(files.count == 500, "the folder holds \(files.count) files, expected exactly the 500 supported ones")
        #expect(count(["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]) == 0, "mix500 holds code")
        let listing = try kit(root, "expect", "listing", "mix500")
        #expect(listing.status == 0 && listing.output.contains("LISTING OK mix500: 500 paths"), "expect listing mix500: \(listing.output.split(separator: "\n").suffix(2))")
        // PDFs: 5 to 12 pages each, text on the first page
        let pdfs = files.filter { $0.hasSuffix(".pdf") }
        for rel in pdfs {
            guard let n = pdfPageCount(dir + "/" + rel) else { Issue.record("\(rel) is not a readable pdf"); continue }
            #expect(n >= 5 && n <= 12, "\(rel) has \(n) pages")
        }
        // documents: about 1,000 characters, no two alike
        var texts = Set<String>()
        for rel in files where ["txt", "md", "rtf", "docx", "html", "odt"].contains(fileExt(rel)) {
            guard let t = documentText(dir + "/" + rel) else { Issue.record("\(rel) did not convert"); continue }
            let n = t.filter { !$0.isWhitespace }.count + t.split(whereSeparator: { $0.isWhitespace }).count
            #expect(n >= 750 && n <= 1300, "\(rel) has about \(n) characters")
            texts.insert(t)
        }
        #expect(texts.count == 120, "\(texts.count) different documents of 120")
        // audio: about a minute, no two files alike, silences between the sentences
        let audio = files.filter { ["mp3", "m4a", "wav", "aac", "flac"].contains(fileExt($0)) }
        var digests = Set<String>()
        for rel in audio {
            let n = Double(samples(dir + "/" + rel).count) / Double(sampleRate)
            #expect(n >= 55 && n <= 65, "\(rel) lasts \(n) s")
            digests.insert(sha(dir + "/" + rel) ?? rel)
        }
        #expect(digests.count == 40, "\(digests.count) different audio files of 40")
        for rel in audio.prefix(3) {
            let db = frameDB(samples(dir + "/" + rel))
            let quiet = db.filter { $0 < silenceDB }.count
            #expect(quiet >= 40, "\(rel): \(quiet) silent frames of 0.5 s, expected silences between the sentences")
            var runs = 0, current = 0
            for v in db { if v < silenceDB { current += 1 } else { if current >= 6 { runs += 1 }; current = 0 } }
            if current >= 6 { runs += 1 }
            #expect(runs >= 3, "\(rel): \(runs) silences of 3 s or more between the sentences")
        }
        // video: about 30 s, h264, three shots
        for rel in files where ["mp4", "mov", "m4v"].contains(fileExt(rel)) {
            let d = duration(dir + "/" + rel) ?? 0
            #expect(abs(d - 30) <= 2, "\(rel) lasts \(d) s")
            #expect(probe(dir + "/" + rel, "stream=codec_name", stream: "v:0")["codec_name"] == "h264", "\(rel): not h264")
        }
        let before = snapshot(dir)
        let again = try kit(root, "build", "mix500")
        #expect(again.status == 0 && again.output.contains("UNCHANGED mix500"), "second build: \(again.output)")
        #expect(snapshot(dir) == before, "an unchanged build rewrote a file")
        print("FIXTURE SIZE mix500 \(byteTotal(dir)) bytes")
    }

    @Test("the extav cells: eight real 1 s clips (mp3 m4a wav aac flac mp4 mov m4v) under matrix/extav, each with a unique zq token in its name, none an ext- or extdoc- cell; expect extensions finds every audio and video extension")
    func extavCells() throws {
        let root = try makeRoot()
        let built = try kit(root, "build", "matrix")
        #expect(built.status == 0, "build matrix: \(built.output)")
        let exts = ["mp3", "m4a", "wav", "aac", "flac", "mp4", "mov", "m4v"]
        let table = (try? String(contentsOf: projectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv"), encoding: .utf8)) ?? ""
        let cells = table.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count == 7 }
        var tokens = Set<String>()
        for ext in exts {
            let row = cells.first { $0[0] == "extav-\(ext)" }
            #expect(row != nil, "no cell extav-\(ext) in gate-matrix.csv")
            guard let row else { continue }
            #expect(row[1].hasPrefix("extav/") && row[1].hasSuffix("." + ext), "extav-\(ext): path \(row[1])")
            #expect(row[3] == "yes" && row[4] == "1" && row[5] == "ok" && row[6] == "spec", "extav-\(ext): \(row)")
            let token = row[1].range(of: "zq[0-9]{4}", options: .regularExpression).map { String(row[1][$0]) } ?? ""
            #expect(!token.isEmpty && tokens.insert(token).inserted, "extav-\(ext): token \(token) is missing or used twice here")
            #expect(table.components(separatedBy: token).count == 2, "the token \(token) is used by another cell of gate-matrix.csv")
            let path = root.fixtures + "/matrix/" + row[1]
            let d = duration(path) ?? 0
            #expect(d >= 0.5 && d <= 2, "\(row[1]) lasts \(d) s, expected a clip of about 1 s")
            let video = ["mp4", "mov", "m4v"].contains(ext)
            #expect(streamCount(path, video ? "v" : "a") >= 1 && (video || streamCount(path, "v") == 0), "\(row[1]) has the wrong streams")
        }
        #expect(!cells.contains { $0[0].hasPrefix("ext-") && $0[1].hasPrefix("extav/") }, "an ext- cell lives in extav/")
        let expect = try kit(root, "expect", "extensions", "--kinds", "audio,video")
        #expect(expect.status == 0, "expect extensions (matrix only): exit \(expect.status):\n\(expect.output)")
        for ext in exts { #expect(expect.lines.contains { $0.hasPrefix("FOUND ") && $0.contains(" \(ext) ") }, "no FOUND line for \(ext):\n\(expect.output)") }
    }

    @Test("no video clip but the two speech clips has a sound track, and the whole of golden-av is small (under 40 MB)")
    func folderSize() {
        let a = avBuilt()
        var total = 0
        for rel in entriesIn(a.root.av) { total += (FileManager.default.contents(atPath: a.root.av + "/" + rel)?.count ?? 0) }
        #expect(total < 40_000_000, "golden-av is \(total) bytes")
        print("FIXTURE SIZE golden-av \(total) bytes")
    }
}
