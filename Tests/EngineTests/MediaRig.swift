import AVFoundation
import Foundation
import Testing
import SesameEngine

// plan-5-t2, tester step. Written from the entry plan-5-t2 of plan-5-tasks.md (Tests), the Conventions and the Decisions D3 to D8, the
// spec's S4 and the design only; no product source is read. Nothing here is product code. It is the shared rig of AudioReaderTests,
// HelperAudioTests, HelperAudioGiveUpTests (a suite of HelperAudioTests.swift), HelperExtavTests, HelperAudioGoldenTests and
// HelperAudioModelTests (and t3's video tests extend it).
//
// What it makes: WAV files of known tone bursts and silences, written byte by byte (the clip's own bytes are the independent witness
// of its own content), and m4a or aac copies of them made by the system's `afconvert` (a second encoder the product does not use).
// Every level is an RMS level in dBFS: a burst "at -30 dBFS" is a sine whose RMS is 10^(-30/20). Silence is digital zero.
//
// The independent readers: `frames(of:from:count:)` reads a WAV with AVAudioFile at the file's own rate (no resampling, so a 16 kHz
// mono WAV gives exactly the samples the test wrote); the golden clips are read with `ffmpeg` in HelperAudioGoldenTests.
//
// The helper harness at the bottom (`mr...`) reads the index of a throwaway HOME with the raw SQLite connection of IndexAttemptTests.swift
// (`AtDB`, `AtWorld`, `atStartHelper`, `atFoldersLine`, `atPast`, which this file reuses and never edits). The column names are the
// ones of design section 1: files(path, kind, size, status, reason, read_to, tries), passages(id, file_id, source, start, end, modality,
// vec), fts(name, body).

enum MediaRig {
    struct Part {
        let seconds: Double
        /// RMS level in dBFS; nil is digital silence.
        let level: Double?
        let hz: Double

        static func silence(_ seconds: Double) -> Part { Part(seconds: seconds, level: nil, hz: 0) }
        static func tone(_ seconds: Double, db: Double = -20, hz: Double = 440) -> Part { Part(seconds: seconds, level: db, hz: hz) }
    }

    struct Made {
        let path: String
        let rate: Int
        let channels: Int
        let seconds: Double
    }

    /// A 16-bit PCM WAV of the parts, in order. The header is written with the final sizes first, then the samples a second at a time.
    @discardableResult
    static func writeWav(_ path: String, rate: Int = 16000, channels: Int = 1, _ parts: [Part]) throws -> Made {
        let frameCounts = parts.map { Int(($0.seconds * Double(rate)).rounded()) }
        let totalFrames = frameCounts.reduce(0, +)
        let dataBytes = totalFrames * channels * 2
        var header = Data()
        func put32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + dataBytes))
        header.append(contentsOf: Array("WAVE".utf8)); header.append(contentsOf: Array("fmt ".utf8))
        put32(16); put16(1); put16(UInt16(channels)); put32(UInt32(rate)); put32(UInt32(rate * channels * 2))
        put16(UInt16(channels * 2)); put16(16)
        header.append(contentsOf: Array("data".utf8)); put32(UInt32(dataBytes))
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.write(contentsOf: header)
        for (part, frames) in zip(parts, frameCounts) {
            var written = 0
            while written < frames {
                let count = min(rate, frames - written)
                var block = [Int16](repeating: 0, count: count * channels)
                if let level = part.level {
                    let amplitude = pow(10.0, level / 20.0) * 2.0.squareRoot() * 32767.0
                    for index in 0..<count {
                        let phase = 2.0 * Double.pi * part.hz * Double(written + index) / Double(rate)
                        let value = Int16((amplitude * sin(phase)).rounded())
                        for channel in 0..<channels { block[index * channels + channel] = value }
                    }
                }
                try block.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
                written += count
            }
        }
        return Made(path: path, rate: rate, channels: channels, seconds: Double(totalFrames) / Double(rate))
    }

    /// The system encoder (`afconvert`) makes an m4a (`m4af`) or a raw AAC stream (`adts`) of a WAV. Throws when it fails.
    static func encode(_ wav: String, to path: String, container: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", container, "-d", "aac", wav, path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: path) else {
            throw MrError("afconvert (\(container)) failed with status \(process.terminationStatus)")
        }
    }

    /// `count` samples of the first channel from frame `from` of an audio file, at the file's own rate and format (float, -1 to 1).
    static func frames(of path: String, from: Int, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let available = max(0, Int(file.length) - from)
        let want = min(count, available)
        guard want > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(want)) else {
            throw MrError("no buffer of \(want) frames")
        }
        file.framePosition = AVAudioFramePosition(from)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(want))
        guard let channel = buffer.floatChannelData?[0] else { throw MrError("the file is not float") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// The 768 half floats of a `hex(vec)` text.
    static func halfVector(hex: String) -> [Double] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return (0..<(bytes.count / 2)).map { number in
            Double(Float(Float16(bitPattern: UInt16(bytes[2 * number]) | (UInt16(bytes[2 * number + 1]) << 8))))
        }
    }
}

struct MrError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: a temp folder

final class MrDir {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sesame-media-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }

    func file(_ name: String) -> String { path + "/" + name }

    func remove() {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: path) { for name in names { chmod(path + "/" + name, 0o600) } }
        try? fm.removeItem(atPath: path)
    }
}

func mrWithDir(_ body: (MrDir) throws -> Void) throws {
    let dir = try MrDir()
    defer { dir.remove() }
    try body(dir)
}

// MARK: identity, the way lstat gives it

struct MrSeen: Equatable {
    var size: Int64
    var mtimeNs: Int64
    var inode: UInt64
}

func mrSeen(_ path: String) -> MrSeen? {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0 else { return nil }
    return MrSeen(size: Int64(info.st_size),
                  mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                  inode: UInt64(info.st_ino))
}

func mrIdentity(_ value: MrSeen) -> FileIdentity {
    FileIdentity(size: value.size, mtimeNs: value.mtimeNs, inode: value.inode)
}

func mrSetMtime(_ path: String, ns: Int64) {
    let stamp = timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
    utimensat(AT_FDCWD, path, [stamp, stamp], 0)
}

func mrCanTestPermissions() -> Bool {
    if getuid() == 0 {
        Issue.record("this test runs as root, and root opens a file with mode 000: it cannot show anything; run it as the person")
        return false
    }
    return true
}

/// Sets a file's modified time `age` seconds before `atPast` (the helper reads the newest first).
func mrAge(_ path: String, _ age: Int) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(age))], ofItemAtPath: path)
}

// MARK: reading the index of a throwaway HOME

struct MrRow {
    let kind: String
    let status: String
    let reason: String?
    let readTo: Int?
    let tries: Int
    let size: Int?
}

func mrRows(_ db: AtDB) -> [String: MrRow]? {
    guard let rows = db.rows("select path, kind, status, reason, read_to, tries, size from files") else { return nil }
    var out: [String: MrRow] = [:]
    for row in rows {
        guard let path = row[0], let kind = row[1], let status = row[2] else { continue }
        out[(path as NSString).lastPathComponent] = MrRow(kind: kind, status: status, reason: row[3], readTo: row[4].flatMap { Int($0) },
                                                          tries: Int(row[5] ?? "") ?? -1, size: row[6].flatMap { Int($0) })
    }
    return out
}

struct MrPassage {
    let id: Int
    let source: String
    let start: Int?
    let end: Int?
    let modality: String
    let vecBytes: Int
    /// How many `fts` rows have this passage's id (1 is the rule), and the text of the body column.
    let ftsRows: Int
    let body: String
}

func mrPassages(_ db: AtDB) -> [String: [MrPassage]]? {
    guard let rows = db.rows("""
        select f.path, p.id, p.source, cast(p.start as integer), cast(p."end" as integer), p.modality, coalesce(length(p.vec), -1), \
        (select count(*) from fts where rowid = p.id), coalesce((select body from fts where rowid = p.id), '') \
        from passages p join files f on f.id = p.file_id order by p.id
        """) else { return nil }
    var out: [String: [MrPassage]] = [:]
    for row in rows {
        guard let path = row[0], let id = row[1].flatMap({ Int($0) }) else { continue }
        out[(path as NSString).lastPathComponent, default: []].append(
            MrPassage(id: id, source: row[2] ?? "", start: row[3].flatMap { Int($0) }, end: row[4].flatMap { Int($0) },
                      modality: row[5] ?? "", vecBytes: Int(row[6] ?? "") ?? -2, ftsRows: Int(row[7] ?? "") ?? -1, body: row[8] ?? ""))
    }
    return out
}

/// The file names (last components) whose passages an fts MATCH on `column:word` finds.
func mrFind(_ db: AtDB, column: String, _ word: String) -> [(file: String, source: String)]? {
    guard let rows = db.rows("""
        select f.path, p.source from fts join passages p on p.id = fts.rowid join files f on f.id = p.file_id \
        where fts match '\(column):\(word)'
        """) else { return nil }
    return rows.map { (file: (($0[0] ?? "") as NSString).lastPathComponent, source: $0[1] ?? "") }
}

func mrDescribe(_ rows: [String: MrRow]?) -> String {
    guard let rows else { return "index unreadable" }
    return rows.keys.sorted().map { key in
        let row = rows[key]!
        return "\(key)=\(row.kind)/\(row.status)\(row.reason.map { "(\($0))" } ?? "")\(row.readTo.map { " read_to \($0)" } ?? "") tries \(row.tries)"
    }.joined(separator: ", ")
}

func mrIsFinal(_ status: String) -> Bool { status == "done" || status == "could_not_read" || status == "needs_permission" }

struct MrSettled {
    let met: Bool
    let rows: [String: MrRow]
    let seconds: Double
}

/// Polls until `files` rows exist, every row is in a final state and nothing has changed for `quiet` seconds, or `cap` seconds pass,
/// or the helper is gone. `expected` (when given) is the number of rows wanted.
func mrWaitSettled(_ world: AtWorld, _ helper: HelperProcess, expected: Int?, quiet: TimeInterval = 1.5, stall: TimeInterval = 120,
                   cap: TimeInterval = 900) -> MrSettled {
    let started = Date()
    var lastChange = started
    var lastSignature = ""
    var db: AtDB?
    var rows: [String: MrRow] = [:]
    var settledSince: Date?
    while true {
        if db == nil { db = world.db() }
        if let db, let found = mrRows(db), let count = db.int("select count(*) from passages") {
            rows = found
            let signature = found.keys.sorted().map { "\($0)=\(found[$0]!.status)/\(found[$0]!.readTo ?? -1)" }.joined(separator: ",") + "|\(count)"
            if signature != lastSignature { lastSignature = signature; lastChange = Date(); settledSince = nil }
            let allFinal = !found.isEmpty && found.values.allSatisfy { mrIsFinal($0.status) } && (expected == nil || found.count == expected)
            if allFinal {
                if settledSince == nil { settledSince = Date() }
                if Date().timeIntervalSince(settledSince!) >= quiet { return MrSettled(met: true, rows: found, seconds: Date().timeIntervalSince(started)) }
            } else {
                settledSince = nil
            }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > stall || now.timeIntervalSince(started) > cap { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return MrSettled(met: false, rows: rows, seconds: Date().timeIntervalSince(started))
}

/// The helper's own log (`index.log` under the Sesame folder of the throwaway HOME), whole.
func mrIndexLog(_ world: AtWorld) -> String {
    (try? String(contentsOf: sesameLogURL(world.support, "index.log"), encoding: .utf8)) ?? ""
}

/// What is wrong with the index as a whole for audio: every passage has exactly one fts row, no fts row is left over, integrity is ok.
func mrWholeProblems(_ db: AtDB) -> [String] {
    var problems: [String] = []
    let lost = db.int("select count(*) from passages where id not in (select rowid from fts)") ?? -1
    if lost != 0 { problems.append("\(lost) passages have no fts row") }
    let left = db.int("select count(*) from fts where rowid not in (select id from passages)") ?? -1
    if left != 0 { problems.append("\(left) fts rows belong to no passage") }
    let integrity = db.integrity()
    if integrity != "ok" { problems.append("integrity_check: \(integrity)") }
    return problems
}

/// The helper CPU seconds used so far (user plus system), or nil when the process is gone.
func mrCPUSeconds(pid: Int32) -> Double? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return nil }
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    return Double(info.ri_user_time &+ info.ri_system_time) * Double(base.numer) / Double(base.denom) / 1_000_000_000
}

// MARK: the kit as a child process (golden-av, matrix), outside the sandbox

struct MrRan {
    let status: Int32
    let output: String
}

func mrRun(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 1800) -> MrRan? {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("mrrun-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    guard let handle = try? FileHandle(forWritingTo: out) else { return nil }
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(limit)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    var status: Int32
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        status = 124
    } else {
        status = process.terminationStatus
    }
    try? handle.synchronize()
    return MrRan(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

/// A throwaway KIT_ROOT with its own TMPDIR and a decoy HOME; `fixtures` is where `kit-fixtures.sh build` writes. Removed at exit.
final class MrKit: @unchecked Sendable {
    let base: String
    let kit: String
    let tmp: String
    let decoyHome: String
    var fixtures: String { kit + "/fixtures" }
    var env: [String: String] {
        ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": decoyHome, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    }

    init?() {
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("mrkit-" + UUID().uuidString, isDirectory: true)
        guard (try? fm.createDirectory(at: made, withIntermediateDirectories: true)) != nil else { return nil }
        base = made.resolvingSymlinksInPath().path
        kit = base + "/sesame-kit-t2"
        tmp = base + "/tmp"
        decoyHome = base + "/decoy-home"
        for dir in [kit + "/run", tmp, decoyHome] {
            guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else { return nil }
        }
        MrKit.register(base)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var hooked = false

    private static func register(_ path: String) {
        lock.lock()
        paths.append(path)
        if !hooked {
            hooked = true
            atexit { MrKit.cleanAll() }
        }
        lock.unlock()
    }

    private static func cleanAll() {
        lock.lock()
        let all = paths
        lock.unlock()
        for path in all { try? FileManager.default.removeItem(atPath: path) }
    }

    func build(_ target: String, limit: TimeInterval = 1800) -> MrRan? {
        let script = KitPaths.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path
        return mrRun("/bin/bash", [script, "build", target], env: env, limit: limit)
    }
}

/// The text a failure message shows of a kit build: the last lines.
func mrTail(_ text: String, _ lines: Int = 8) -> String {
    text.split(separator: "\n").suffix(lines).joined(separator: " / ")
}
