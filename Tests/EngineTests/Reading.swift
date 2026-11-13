import Foundation
import Testing

// plan-1-t30, tester step. Written from the t30 entry, the Helper protocol table of the plan's Conventions and
// design sections 2 and 8 only; no product source read.
//
// Three things live here for the encode tests (and, for the first, for t34):
//   1. `Reading.check(name:value:bar:)`: the one way a reading test passes a figure. It prints
//      `READING <name>=<value>` and fails with `over bar` when the value is above the bar. A figure that is
//      not a number (no reply came, so nothing was measured) also fails, as `no reading`: never a pass.
//   2. `HelperProcess`: starts a SesameHelper binary, sends it one JSON line at a time on stdin and reads the
//      JSON lines it writes on stdout. It parses with JSONSerialization, so the wire shape (field names, an
//      integer `ms`, 768 numbers in `vec`) is checked from outside, with no engine type involved.
//   3. `KitPaths`: where the project, the kit's model cache and the helper binaries are.

/// The parent of the helper test suites of t30: `HelperEncodeTests` and `EncodeWarmEmbedReadingTests` are nested in it,
/// so the two never run at the same time (a second model load beside a reading would disturb its timing).
@Suite("EncodeHelperTests", .serialized)
enum EncodeHelperTests {}

enum Reading {
    /// Prints `READING <name>=<value>`, then fails with `over bar` when `value` is above `bar`.
    static func check(
        name: String, value: Double, bar: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        print("READING \(name)=\(format(value))")
        guard value.isFinite else {
            Issue.record("no reading: \(name) is \(value), nothing was measured (bar \(format(bar)))",
                         sourceLocation: sourceLocation)
            return
        }
        if value > bar {
            Issue.record("over bar: \(name)=\(format(value)) is above the bar \(format(bar))",
                         sourceLocation: sourceLocation)
        }
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

enum KitPaths {
    static let textModelName = "embeddinggemma-2-Q8_0.gguf"

    /// The package root: this file is `<root>/Tests/EngineTests/Reading.swift`.
    static let projectRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The bundled release helper: `dist/Sesame.app/Contents/MacOS/SesameHelper`, never the debug build.
    static var bundledHelper: URL {
        projectRoot.appendingPathComponent("dist/Sesame.app/Contents/MacOS/SesameHelper")
    }

    /// The debug helper `swift test` builds, next to the test bundle (the test target depends on it).
    static func debugHelper() -> URL? {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles + [Bundle.main] where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("SesameHelper"))
        }
        candidates.append(projectRoot.appendingPathComponent(".build/debug/SesameHelper"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The kit's model cache: `$KIT_ROOT/cache`, KIT_ROOT defaulting to `$TMPDIR/sesame-kit`.
    static func textModel() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let root: String
        if let kit = env["KIT_ROOT"], !kit.isEmpty {
            root = kit
        } else if let tmp = env["TMPDIR"], !tmp.isEmpty {
            root = (tmp as NSString).appendingPathComponent("sesame-kit")
        } else {
            return nil
        }
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true).appendingPathComponent(textModelName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// One line the helper wrote, parsed as JSON.
struct HelperReply {
    let raw: String
    let object: [String: Any]

    init?(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.raw = raw
        self.object = object
    }

    var event: String? { object["event"] as? String }
    var id: Int? { (object["id"] as? NSNumber).flatMap { $0.doubleValue == $0.doubleValue.rounded() ? $0.intValue : nil } }
    var ms: Int? { (object["ms"] as? NSNumber).flatMap { $0.doubleValue == $0.doubleValue.rounded() ? $0.intValue : nil } }
    var vec: [Double]? { (object["vec"] as? [NSNumber])?.map { $0.doubleValue } }
    var reason: String? { object["reason"] as? String }

    /// nil when this line is a valid `vector` reply for `expectedID` (768 finite numbers of unit length within
    /// 1e-4, a whole-number `ms`); otherwise what is wrong.
    func vectorProblem(expectedID: Int) -> String? {
        guard event == "vector" else { return "not a vector reply: \(String(raw.prefix(200)))" }
        guard id == expectedID else { return "id is \(String(describing: id)), expected \(expectedID)" }
        guard let ms, ms >= 0 else { return "ms is missing, negative or not a whole number" }
        guard let vec else { return "vec is missing" }
        guard vec.count == 768 else { return "vec has \(vec.count) numbers, expected 768 (ms \(ms))" }
        guard vec.allSatisfy({ $0.isFinite }) else { return "vec holds a number that is not finite" }
        let length = vec.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard abs(length - 1) <= 1e-4 else { return "vec length is \(length), expected 1 within 1e-4" }
        return nil
    }
}

/// A helper process with its stdin open. Lines are read by a background thread and stamped on arrival.
final class HelperProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let condition = NSCondition()
    private var lines: [(text: String, at: Date)] = []
    private var outputClosed = false
    private var stderrText = ""
    private var exitStatus: Int32?
    private var exitedAt: Date?

    var pid: Int32 { process.processIdentifier }

    init(executable: URL, arguments: [String]) throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [self] finished in
            condition.lock()
            exitStatus = finished.terminationStatus
            exitedAt = Date()
            condition.broadcast()
            condition.unlock()
        }
        try process.run()
        Thread.detachNewThread { [self] in readOutput() }
        Thread.detachNewThread { [self] in readErrors() }
    }

    private func readOutput() {
        var pending = Data()
        let handle = stdoutPipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                let text = String(decoding: lineData, as: UTF8.self)
                condition.lock()
                lines.append((text, Date()))
                condition.broadcast()
                condition.unlock()
            }
        }
        condition.lock()
        outputClosed = true
        condition.broadcast()
        condition.unlock()
    }

    private func readErrors() {
        let handle = stderrPipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            condition.lock()
            stderrText += String(decoding: chunk, as: UTF8.self)
            condition.unlock()
        }
    }

    /// What the process wrote on stderr so far (for failure messages).
    var errors: String {
        condition.lock(); defer { condition.unlock() }
        return String(stderrText.prefix(400))
    }

    func send(_ line: String) {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func closeStdin() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// The next line on stdout, or nil when none comes within `timeout` seconds or the output has ended.
    func nextLine(timeout: TimeInterval) -> (text: String, at: Date)? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while true {
            if !lines.isEmpty { return lines.removeFirst() }
            if outputClosed { return nil }
            if !condition.wait(until: deadline) { return lines.isEmpty ? nil : lines.removeFirst() }
        }
    }

    /// Sends one line and returns the reply with the seconds it took (nil reply: nothing came in time).
    func roundTrip(_ line: String, timeout: TimeInterval = 120) -> (reply: HelperReply?, seconds: Double, raw: String?) {
        let started = Date()
        send(line)
        guard let got = nextLine(timeout: timeout) else { return (nil, Date().timeIntervalSince(started), nil) }
        return (HelperReply(got.text), got.at.timeIntervalSince(started), got.text)
    }

    /// Waits for the process to exit; returns its status and the moment it was seen, or nil on timeout.
    func waitForExit(timeout: TimeInterval) -> (status: Int32, at: Date)? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while exitStatus == nil {
            if !condition.wait(until: deadline) { break }
        }
        guard let status = exitStatus, let at = exitedAt else { return nil }
        return (status, at)
    }

    var isRunning: Bool {
        condition.lock(); defer { condition.unlock() }
        return exitStatus == nil
    }

    /// Ends the process if it is still running (a test's cleanup).
    func stop() {
        closeStdin()
        if isRunning { process.terminate() }
        _ = waitForExit(timeout: 10)
    }
}

enum Tools {
    /// Runs a program to the end and returns its status and stdout.
    static func capture(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The kernel's resource-usage record for `pid` (`proc_pid_rusage`, flavor V4), or nil when the process is gone
    /// or cannot be read. Nothing is spawned and nothing can hang: `/usr/bin/footprint` was replaced by this because
    /// it blocks on every live process whenever `taskgated` is stuck. `ri_phys_footprint` is the same figure
    /// `footprint` prints as `phys_footprint`.
    private static func usage(pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info : nil
    }

    /// The process footprint now, in MB (`ri_phys_footprint`), or nil.
    static func footprintMB(pid: Int32) -> Double? {
        usage(pid: pid).map { Double($0.ri_phys_footprint) / 1_048_576 }
    }

    /// The highest footprint the process has reached since it started, in MB (`ri_lifetime_max_phys_footprint`),
    /// or nil. It cannot miss a spike between two samples, which a 250 ms sampler can.
    static func footprintLifetimeMaxMB(pid: Int32) -> Double? {
        usage(pid: pid).map { Double($0.ri_lifetime_max_phys_footprint) / 1_048_576 }
    }
}
