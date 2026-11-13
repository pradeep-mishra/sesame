import Foundation

// plan-2 fix round A, tester step: a helper process whose stdout the TEST may close (the read side), which
// `HelperProcess` (Reading.swift) cannot do, and whose stderr goes to a file that is read whole (`HelperProcess.errors` keeps
// 400 characters). Used by IndexAppGoneTests (A2) and HelperNoPathLogTests (A9). Nothing here is product code.
//
// The helper is started the way the app starts it: `SesameHelper index [--text-model <p> --mm-model <p>]`, HOME at a
// throwaway folder, `SESAME_FAKE_EMBEDDER=1` only when `models` is nil. The environment is given to the child through
// `Process.environment`, so no process-wide `setenv` is made.

final class PipeRig {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrFile: URL
    private var pending = Data()
    private var outputEnded = false
    private var stdoutClosedByTest = false

    private(set) var lines: [String] = []
    private(set) var changed = 0
    private(set) var walked = false

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// `models` is the text and the image model file; nil means the fake embedder.
    init(helper: URL, home: URL, models: (text: URL, mm: URL)?, scratch: URL) throws {
        signal(SIGPIPE, SIG_IGN)
        stderrFile = scratch.appendingPathComponent("helper-stderr-" + UUID().uuidString + ".txt")
        FileManager.default.createFile(atPath: stderrFile.path, contents: Data())
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        if models == nil { environment["SESAME_FAKE_EMBEDDER"] = "1" } else { environment.removeValue(forKey: "SESAME_FAKE_EMBEDDER") }
        process.executableURL = helper
        var arguments = ["index"]
        if let models { arguments += ["--text-model", models.text.path, "--mm-model", models.mm.path] }
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = try FileHandle(forWritingTo: stderrFile)
        try process.run()
    }

    func send(_ line: String) {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func closeStdin() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Reads stdout (poll, then read) until `stop` holds, the output ends or `cap` seconds pass. Returns whether `stop` held.
    @discardableResult
    func read(cap: TimeInterval, until stop: () -> Bool) -> Bool {
        if stop() { return true }
        let deadline = Date().addingTimeInterval(cap)
        let descriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline, !outputEnded, !stdoutClosedByTest {
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 200)
            if ready <= 0 { continue }
            let got = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if got <= 0 { outputEnded = true; break }
            pending.append(contentsOf: buffer[0..<got])
            while let newline = pending.firstIndex(of: 0x0A) {
                let text = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                lines.append(text)
                if let reply = HelperReply(text), let event = reply.event {
                    if event == "changed" { changed += 1 }
                    if event == "walked" { walked = true }
                }
                if stop() { return true }
            }
        }
        return stop()
    }

    /// Closes the read side of the helper's stdout pipe, the way an app that has died or closed the pipe does.
    func closeStdoutReader() {
        stdoutClosedByTest = true
        try? stdoutPipe.fileHandleForReading.close()
    }

    /// Waits for the process to exit; returns how it ended (status, and whether a signal ended it), or nil on timeout.
    func waitForExit(timeout: TimeInterval) -> (status: Int32, bySignal: Bool)? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard !process.isRunning else { return nil }
        return (process.terminationStatus, process.terminationReason == .uncaughtSignal)
    }

    func kill9() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        _ = waitForExit(timeout: 30)
    }

    /// Everything the helper wrote on stderr so far.
    var stderrText: String {
        (try? String(contentsOf: stderrFile, encoding: .utf8)) ?? ""
    }

    /// Ends the process if it is still running and removes the stderr file (a test's cleanup).
    func cleanup() {
        closeStdin()
        if process.isRunning { process.terminate() }
        if waitForExit(timeout: 10) == nil { kill9() }
        try? FileManager.default.removeItem(at: stderrFile)
    }
}
